import Foundation

package final class DiagnosticsLogger {
    package static let shared = DiagnosticsLogger()

    private let fileURL: URL
    private let backupFileURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.nexhub.diagnostics")
    private let formatter: ISO8601DateFormatter
    private let maxFileSizeBytes: Int

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        maxFileSizeBytes: Int = 512 * 1024
    ) {
        self.fileManager = fileManager
        let resolvedFileURL = fileURL ?? Self.defaultLogFileURL(fileManager: fileManager)
        self.fileURL = resolvedFileURL
        self.backupFileURL = resolvedFileURL.deletingPathExtension().appendingPathExtension("previous.log")
        self.maxFileSizeBytes = maxFileSizeBytes
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
    }

    package var logFileDisplayPath: String {
        fileURL.path
    }

    package func log(_ category: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(category)] \(Self.sanitized(message))\n"
        queue.async {
            let data = Data(line.utf8)
            self.ensureLogDirectoryExists()
            self.rotateIfNeeded(forAppendingBytes: data.count)
            if self.fileManager.fileExists(atPath: self.fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    return
                }
            }
            try? data.write(to: self.fileURL, options: .atomic)
        }
    }

    func flush() {
        queue.sync {}
    }

    static func sanitized(_ message: String) -> String {
        var result = message
        let replacements: [(String, String)] = [
            (#"(?i)(authorization:\s*bearer\s+)[^\s]+"#, "$1[REDACTED]"),
            (#"(?i)(x-llm-api-key=)[^\s]+"#, "$1[REDACTED]"),
            (#"(?i)(api[_-]?key[\"'=:\s]+)[^\s\",]+"#, "$1[REDACTED]"),
            (#"(?i)(token[\"'=:\s]+)[^\s\",]+"#, "$1[REDACTED]")
        ]

        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }

        if result.count > 4000 {
            result = String(result.prefix(4000)) + "...[truncated]"
        }
        return result
    }

    static func defaultLogFileURL(fileManager: FileManager = .default) -> URL {
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return applicationSupport
                .appendingPathComponent(AppBrand.supportDirectoryName, isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("runtime.log", isDirectory: false)
        }
        return URL(fileURLWithPath: "/tmp/nexhub_runtime.log")
    }

    private func ensureLogDirectoryExists() {
        let directoryURL = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func rotateIfNeeded(forAppendingBytes byteCount: Int) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let currentSize = attributes[.size] as? NSNumber,
              currentSize.intValue + byteCount > maxFileSizeBytes else {
            return
        }

        try? fileManager.removeItem(at: backupFileURL)
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.moveItem(at: fileURL, to: backupFileURL)
        }
    }
}
