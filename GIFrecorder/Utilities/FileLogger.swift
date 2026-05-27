import Foundation

/// Writes timestamped log lines to ~/Library/Logs/com.lasakondrej.gifrecorder/gifrecorder.log.
/// Rotates automatically when the file exceeds 5 MB (keeps the last 1 MB).
/// Thread-safe — all I/O runs on a dedicated serial queue.
final class FileLogger {

    static let shared = FileLogger()

    /// Public URL so UI can open the file directly.
    static var logFileURL: URL {
        let logsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/com.lasakondrej.gifrecorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir.appendingPathComponent("gifrecorder.log")
    }

    private let queue = DispatchQueue(label: "com.lasakondrej.gifrecorder.filelogger", qos: .utility)
    private var fileHandle: FileHandle?
    private let maxBytes = 5 * 1024 * 1024   // 5 MB
    private let keepBytes = 1 * 1024 * 1024  // 1 MB kept after rotation

    private init() {
        queue.async {
            let url = Self.logFileURL
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            self.fileHandle = try? FileHandle(forWritingTo: url)
            self.fileHandle?.seekToEndOfFile()
            self.append("──── session start \(self.timestamp()) ────\n")
        }
    }

    /// Log a message. Call via the global `flog()` function for brevity.
    func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        queue.async {
            let src = URL(fileURLWithPath: file).lastPathComponent
            self.append("[\(self.timestamp())] [\(src):\(line)] \(message)\n")
            self.rotateIfNeeded()
        }
    }

    // MARK: - Private

    private func append(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }

    private func rotateIfNeeded() {
        let url = Self.logFileURL
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size  = attrs[.size] as? Int,
            size > maxBytes,
            let handle = fileHandle,
            let all = try? Data(contentsOf: url)
        else { return }

        let trimmed = all.suffix(keepBytes)
        handle.seek(toFileOffset: 0)
        handle.write(trimmed)
        handle.truncateFile(atOffset: UInt64(trimmed.count))
        handle.seekToEndOfFile()
        append("──── log rotated \(timestamp()) ────\n")
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}

/// Convenience global — mirrors the message to the on-disk log file.
func flog(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    FileLogger.shared.log(message, file: file, function: function, line: line)
}
