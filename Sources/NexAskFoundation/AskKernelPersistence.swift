import Foundation

package enum AskKernelPersistencePaths {
    private static let supportDirectoryNameInfoKey = "NexHubSupportDirectoryName"

    package static func askRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let supportDirectoryName = resolvedSupportDirectoryName()
        let root = base
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
            .appendingPathComponent("Ask", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    package static func fileURL(
        named filename: String,
        fileManager: FileManager = .default
    ) -> URL {
        askRoot(fileManager: fileManager).appendingPathComponent(filename)
    }

    private static func resolvedSupportDirectoryName() -> String {
        if let value = Bundle.main.object(forInfoDictionaryKey: supportDirectoryNameInfoKey) as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "NexHub"
    }
}
