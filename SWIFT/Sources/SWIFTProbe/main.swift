import SWIFTCore
import Foundation
import Network

@main
@MainActor
struct SWIFTProbe {
    private static let defaultTimeout: Duration = .seconds(60)

    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("SWIFTProbe: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        let downloads = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let engine = SWIFTEngine(
            deviceName: Host.current().localizedName ?? "SWIFT Mac",
            receiveDirectory: downloads)

        switch command {
        case "discover":
            let seconds = Int(arguments.dropFirst().first ?? "") ?? 30
            try await discover(using: engine, seconds: seconds)
        case "receive":
            let directory = value(after: "--directory", in: arguments)
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? downloads
            let accept = arguments.contains("--accept")
            let seconds = Int(value(after: "--timeout", in: arguments) ?? "") ?? 120
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            engine.receiveDirectory = directory
            try await receive(using: engine, accept: accept, seconds: seconds)
        case "send":
            guard arguments.count >= 2,
                  let target = value(after: "--to", in: arguments) else {
                throw ProbeError.usage("send requires files and --to <device name>")
            }
            let optionNames = Set(["--to", "--timeout"])
            var paths: [String] = []
            var index = 1
            while index < arguments.count {
                if optionNames.contains(arguments[index]) {
                    index += 2
                } else {
                    paths.append(arguments[index])
                    index += 1
                }
            }
            guard !paths.isEmpty else {
                throw ProbeError.usage("send requires at least one file")
            }
            let files = try paths.map {
                try OutgoingFile.from(
                    url: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath))
            }
            let seconds = Int(value(after: "--timeout", in: arguments) ?? "") ?? 120
            try await send(files, to: target, using: engine, seconds: seconds)
        case "dial":
            guard let host = value(after: "--host", in: arguments),
                  let portText = value(after: "--port", in: arguments),
                  let portNumber = UInt16(portText),
                  let port = NWEndpoint.Port(rawValue: portNumber) else {
                throw ProbeError.usage("dial requires --host, --port, and a file")
            }
            let optionNames = Set(["--host", "--port", "--timeout"])
            var paths: [String] = []
            var index = 1
            while index < arguments.count {
                if optionNames.contains(arguments[index]) {
                    index += 2
                } else {
                    paths.append(arguments[index])
                    index += 1
                }
            }
            guard !paths.isEmpty else {
                throw ProbeError.usage("dial requires at least one file")
            }
            let files = try paths.map {
                try OutgoingFile.from(
                    url: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath))
            }
            let seconds = Int(value(after: "--timeout", in: arguments) ?? "") ?? 90
            try await dial(files, host: host, port: port, seconds: seconds)
        case "help", "--help", "-h":
            printUsage()
        default:
            throw ProbeError.usage("unknown command \(command)")
        }
    }

    private static func discover(
        using engine: SWIFTEngine, seconds: Int
    ) async throws {
        engine.onDeviceFound = { device in
            print("FOUND\t\(device.id)\t\(device.name)\t\(device.type)")
            fflush(stdout)
        }
        engine.onDeviceLost = { id in
            print("LOST\t\(id)")
            fflush(stdout)
        }
        engine.startDiscovery()
        print("Discovering for \(seconds)s…")
        try await Task.sleep(for: .seconds(seconds))
        engine.stopDiscovery()
    }

    private static func receive(
        using engine: SWIFTEngine, accept: Bool, seconds: Int
    ) async throws {
        let completion = Completion<Void>()
        engine.onVisibilityChange = { visible in
            print(visible ? "VISIBLE" : "HIDDEN")
            fflush(stdout)
        }
        engine.onOfferReceived = { offer in
            let names = offer.files.map(\.name).joined(separator: ", ")
            print("OFFER\t\(offer.device.name)\tPIN \(offer.pinCode)\t\(names)")
            print(accept ? "ACCEPTING (--accept)" : "REJECTING (pass --accept to test a transfer)")
            fflush(stdout)
            engine.respondToOffer(id: offer.id, accept: accept)
        }
        engine.onIncomingProgress = { _, fraction in
            print("PROGRESS\t\(Int(fraction * 100))%")
        }
        engine.onIncomingFinished = { _, urls, error in
            if let error {
                completion.resolve(.failure(error))
            } else {
                print("RECEIVED\t\(urls.map(\.path).joined(separator: "\t"))")
                completion.resolve(.success(()))
            }
        }
        engine.startAdvertising()
        let result = await race(completion.value(), timeout: .seconds(seconds))
        engine.stopAdvertising()
        try result.get()
    }

    private static func send(
        _ files: [OutgoingFile],
        to target: String,
        using engine: SWIFTEngine,
        seconds: Int
    ) async throws {
        let found = Completion<SWIFTDevice>()
        engine.onDeviceFound = { device in
            print("FOUND\t\(device.id)\t\(device.name)")
            if device.id == target || device.name.localizedCaseInsensitiveCompare(target) == .orderedSame {
                found.resolve(.success(device))
            }
        }
        engine.startDiscovery()
        let device = try await race(
            found.value(), timeout: .seconds(min(seconds, 45))).get()

        let transfer = Completion<Void>()
        engine.onOutgoingEvent = { _, event in
            switch event {
            case .connected(let pin):
                print("PIN\t\(pin)")
            case .accepted:
                print("ACCEPTED")
            case .progress(let fraction):
                print("PROGRESS\t\(Int(fraction * 100))%")
            case .finished:
                transfer.resolve(.success(()))
            case .failed(let error):
                transfer.resolve(.failure(error))
            }
            fflush(stdout)
        }
        engine.send(files: files, to: device)
        let result = await race(transfer.value(), timeout: .seconds(seconds))
        engine.stopDiscovery()
        try result.get()
        print("SENT")
    }

    /// Speaks Quick Share to a listener we already have an address for.
    /// The emulator's advertisement stays inside its virtual network, so the
    /// share sheet cannot see it; this reaches the same listener directly.
    private static func dial(
        _ files: [OutgoingFile],
        host: String,
        port: NWEndpoint.Port,
        seconds: Int
    ) async throws {
        guard let ip = IPv4Address(host) else {
            throw ProbeError.usage("\(host) is not an IPv4 address")
        }
        let connection = NWConnection(host: .ipv4(ip), port: port, using: .tcp)
        let session = OutboundSession(
            connection: connection,
            id: "dial",
            files: files,
            localName: Host.current().localizedName ?? "SWIFT Mac",
            localEndpointID: "Mac1")
        let transfer = Completion<Void>()
        let stream = await session.events()
        let collect = Task {
            for await event in stream {
                switch event {
                case .connected(let pin):
                    print("PIN\t\(pin)")
                case .accepted:
                    print("ACCEPTED")
                case .progress(let fraction):
                    print("PROGRESS\t\(Int(fraction * 100))%")
                case .finished:
                    transfer.resolve(.success(()))
                case .failed(let error):
                    transfer.resolve(.failure(error))
                }
                fflush(stdout)
            }
        }
        let result = await race(transfer.value(), timeout: .seconds(seconds))
        collect.cancel()
        try result.get()
        print("SENT")
    }

    private static func race<T: Sendable>(
        _ operation: @escaping @Sendable () async -> Result<T, Error>,
        timeout: Duration = defaultTimeout
    ) async -> Result<T, Error> {
        await withTaskGroup(of: Result<T, Error>.self) { group in
            group.addTask { await operation() }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .failure(ProbeError.timedOut)
                } catch {
                    return .failure(error)
                }
            }
            let result = await group.next() ?? .failure(ProbeError.timedOut)
            group.cancelAll()
            return result
        }
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func printUsage() {
        print("""
        SWIFT real-device protocol probe

          swift run SWIFTProbe discover [seconds]
          swift run SWIFTProbe receive [--directory PATH] [--timeout SECONDS] [--accept]
          swift run SWIFTProbe send FILE... --to DEVICE [--timeout SECONDS]
          swift run SWIFTProbe dial FILE... --host IPV4 --port PORT [--timeout SECONDS]

        The packaged app is required if macOS denies local-network access to a
        bare terminal binary. --accept is intentionally explicit.
        """)
    }
}

private enum ProbeError: LocalizedError {
    case usage(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .usage(let message): message
        case .timedOut: "timed out"
        }
    }
}

private final class Completion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Result<Value, Error>, Never>?

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func value() -> @Sendable () async -> Result<Value, Error> {
        {
            await withCheckedContinuation { continuation in
                self.lock.lock()
                if let result = self.result {
                    self.lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    self.lock.unlock()
                }
            }
        }
    }
}
