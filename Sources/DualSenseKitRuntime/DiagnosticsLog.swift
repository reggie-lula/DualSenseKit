import Foundation

public enum DiagnosticsLog {
    private static let queue = DispatchQueue(label: "DualSenseKit.DiagnosticsLog")
    private static let appStartedAt = DispatchTime.now()

    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DualSenseKit", isDirectory: true)
            .appendingPathComponent("diagnostics.log")
    }

    public static func millisecondsSinceAppStart() -> Int {
        milliseconds(since: appStartedAt)
    }

    public static func milliseconds(since start: DispatchTime?) -> Int {
        guard let start else { return -1 }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Int(elapsed / 1_000_000)
    }

    public static func write(event: String, _ payload: [String: String] = [:]) {
        let fields = payload
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        write(fields.isEmpty ? event : "\(event) \(fields)")
    }

    public static func write(_ message: String) {
        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(timestamp) \(message)\n"
            do {
                try FileManager.default.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: logURL.path),
                   let handle = try? FileHandle(forWritingTo: logURL) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(line.utf8))
                    try handle.close()
                } else {
                    try Data(line.utf8).write(to: logURL, options: [.atomic])
                }
            } catch {
                NSLog("DualSenseKit diagnostics log failed: \(error)")
            }
        }
    }
}
