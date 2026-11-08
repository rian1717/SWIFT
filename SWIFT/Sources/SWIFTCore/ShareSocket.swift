import Darwin
import Foundation

/// The share sheet is sandboxed and cannot open the phone's port, and it
/// cannot connect to a Unix socket either. It drops a request file here.
/// The running app, which already sends successfully, picks that file up.
public enum ShareSocket {
    public static let directory = "/private/tmp/swift-share"
    public static let jobs = "/private/tmp/swift-share/jobs"

    public static func prepareDirectory() {
        for path in [directory, jobs] {
            try? FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true)
            chmod(path, 0o777)
        }
    }

    public static func jobURL(_ id: String, _ kind: String) -> URL {
        URL(fileURLWithPath: jobs).appendingPathComponent("\(id).\(kind)")
    }
}
