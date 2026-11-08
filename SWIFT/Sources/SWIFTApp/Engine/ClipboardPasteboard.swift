import AppKit
import Foundation

struct ClipFile: Equatable, Sendable {
    var name: String
    var mime: String
    var data: Data
}

/// One phone clipboard snapshot, ready to put on the Mac pasteboard.
struct ClipboardPayload: Equatable, Sendable {
    var source: String
    var text: String?
    var html: String?
    var files: [ClipFile]
}

enum ClipboardDecodeError: Error, Equatable {
    case badRequest
    case tooLarge
}

enum ClipboardDecode {
    static let maxBytes = 32 * 1024 * 1024

    static func parse(headers: [String: String], body: Data) throws -> ClipboardPayload {
        guard body.count <= maxBytes else { throw ClipboardDecodeError.tooLarge }
        let type = headers["content-type"] ?? ""
        if type.contains("json") || body.first == UInt8(ascii: "{") {
            return try parseJSON(body)
        }
        return try parseBlob(headers: headers, body: body)
    }

    static func cleanSource(_ raw: String) -> String {
        let filtered = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Android" }
        return String(text.prefix(80))
    }

    /// Leaf name only. A phone-supplied path must not choose a directory.
    static func sanitizeFileName(_ raw: String) -> String {
        let leaf = ((raw as NSString).lastPathComponent.removingPercentEncoding) ?? raw
        var out = ""
        for scalar in leaf.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "_" || scalar == "." || scalar == " " {
                out.unicodeScalars.append(scalar)
            } else {
                out.unicodeScalars.append("_")
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ".")))
        if trimmed.isEmpty { return "clipboard" }
        return String(trimmed.prefix(120))
    }

    private static func parseJSON(_ body: Data) throws -> ClipboardPayload {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ClipboardDecodeError.badRequest
        }
        let source = cleanSource(obj["source"] as? String ?? "")
        switch (obj["kind"] as? String) ?? "text" {
        case "text":
            let text = (obj["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let html = obj["html"] as? String
            let visible = text.isEmpty ? (html ?? "") : text
            guard !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClipboardDecodeError.badRequest
            }
            return ClipboardPayload(source: source, text: visible, html: html, files: [])
        case "image", "file":
            let file = try file(from: obj, fallback: "clipboard")
            return ClipboardPayload(source: source, text: nil, html: nil, files: [file])
        case "files":
            guard let rows = obj["files"] as? [[String: Any]], !rows.isEmpty else {
                throw ClipboardDecodeError.badRequest
            }
            var files: [ClipFile] = []
            var total = 0
            for row in rows.prefix(20) {
                let file = try file(from: row, fallback: "clipboard")
                total += file.data.count
                guard total <= maxBytes else { throw ClipboardDecodeError.tooLarge }
                files.append(file)
            }
            guard !files.isEmpty else { throw ClipboardDecodeError.badRequest }
            return ClipboardPayload(source: source, text: nil, html: nil, files: files)
        default:
            throw ClipboardDecodeError.badRequest
        }
    }

    private static func file(from row: [String: Any], fallback: String) throws -> ClipFile {
        guard let encoded = row["data"] as? String,
              let data = Data(base64Encoded: encoded),
              !data.isEmpty, data.count <= maxBytes else {
            throw ClipboardDecodeError.badRequest
        }
        let name = sanitizeFileName((row["name"] as? String) ?? (row["filename"] as? String) ?? fallback)
        let mime = (row["mime"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "application/octet-stream"
        return ClipFile(name: name, mime: mime, data: data)
    }

    private static func parseBlob(headers: [String: String], body: Data) throws -> ClipboardPayload {
        guard !body.isEmpty else { throw ClipboardDecodeError.badRequest }
        let source = cleanSource((headers["x-swift-source"] ?? "").removingPercentEncoding ?? "")
        if (headers["x-swift-kind"] ?? "file") == "text" {
            guard let text = String(data: body, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw ClipboardDecodeError.badRequest
            }
            return ClipboardPayload(source: source, text: text, html: nil, files: [])
        }
        let name = sanitizeFileName((headers["x-swift-name"] ?? "clipboard").removingPercentEncoding ?? "clipboard")
        let mime = headers["x-swift-mime"] ?? "application/octet-stream"
        return ClipboardPayload(source: source, text: nil, html: nil,
                                files: [ClipFile(name: name, mime: mime, data: body)])
    }
}

@MainActor
enum ClipboardPasteboard {
    static func summary(for payload: ClipboardPayload) -> String {
        let who = payload.source
        if payload.files.isEmpty, let text = payload.text {
            let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            let preview = oneLine.count > 42 ? String(oneLine.prefix(42)) + "…" : oneLine
            return "Text from \(who) · \(preview)"
        }
        if payload.files.count == 1 {
            return "\(payload.files[0].name) from \(who)"
        }
        return "\(payload.files.count) files from \(who)"
    }

    /// Replaces the general pasteboard so the next ⌘V pastes this phone copy.
    @discardableResult
    static func apply(_ payload: ClipboardPayload, to pasteboard: NSPasteboard = .general) throws -> String {
        pasteboard.clearContents()
        if payload.files.isEmpty {
            guard let text = payload.text, !text.isEmpty else { throw ClipboardDecodeError.badRequest }
            guard pasteboard.setString(text, forType: .string) else { throw ClipboardDecodeError.badRequest }
            return summary(for: payload)
        }

        let urls = try payload.files.map(store)
        var writers: [NSPasteboardWriting] = []
        if payload.files.count == 1, let image = NSImage(data: payload.files[0].data), image.isValid {
            writers.append(image)
        }
        writers.append(contentsOf: urls.map { $0 as NSURL })
        guard pasteboard.writeObjects(writers) else { throw ClipboardDecodeError.badRequest }
        return summary(for: payload)
    }

    private static func store(_ file: ClipFile) throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SWIFT/Clipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clean = ClipboardDecode.sanitizeFileName(file.name)
        var url = directory.appendingPathComponent(clean)
        if FileManager.default.fileExists(atPath: url.path) {
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let suffix = String(UUID().uuidString.prefix(4))
            let name = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            url = directory.appendingPathComponent(name)
        }
        try file.data.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.quarantineProperties = [
            "LSQuarantineAgentName": "SWIFT",
            "LSQuarantineType": "LSQuarantineTypeOtherDownload",
        ]
        var quarantined = url
        try? quarantined.setResourceValues(values)
        return url
    }
}
