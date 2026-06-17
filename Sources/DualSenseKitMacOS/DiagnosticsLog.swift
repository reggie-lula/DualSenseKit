import Foundation

enum DiagnosticsLog {
    private static let queue = DispatchQueue(label: "DualSenseKitDemo.DiagnosticsLog")

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DualSenseKitDemo", isDirectory: true)
            .appendingPathComponent("diagnostics.log")
    }

    static func write(_ message: String) {
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
                NSLog("DualSenseKitDemo diagnostics log failed: \(error)")
            }
        }
    }
}
