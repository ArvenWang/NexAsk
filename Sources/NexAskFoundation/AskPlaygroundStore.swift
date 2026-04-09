import Foundation

package struct AskPlaygroundArtifactRecord: Codable, Equatable, Sendable {
    package let id: String
    package let title: String
    package let summary: String
    package let rootPath: String
    package let entryFile: String
    package let languageRuntime: String
    package let tags: [String]
    package let createdAt: Date
    package let lastUsedAt: Date
    package let reusableScore: Double
    package let promotedToolID: String?

    package init(
        id: String,
        title: String,
        summary: String,
        rootPath: String,
        entryFile: String,
        languageRuntime: String,
        tags: [String],
        createdAt: Date,
        lastUsedAt: Date,
        reusableScore: Double,
        promotedToolID: String?
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.rootPath = rootPath
        self.entryFile = entryFile
        self.languageRuntime = languageRuntime
        self.tags = tags
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.reusableScore = reusableScore
        self.promotedToolID = promotedToolID
    }
}

package struct AskLocalPromotedToolDescriptor: Codable, Equatable, Sendable {
    package let id: String
    package let name: String
    package let summary: String
    package let rootPath: String
    package let entryFile: String
    package let languageRuntime: String

    package init(
        id: String,
        name: String,
        summary: String,
        rootPath: String,
        entryFile: String,
        languageRuntime: String
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.rootPath = rootPath
        self.entryFile = entryFile
        self.languageRuntime = languageRuntime
    }
}

package struct AskPlaygroundCatalogSnapshot: Codable, Equatable, Sendable {
    package let version: Int
    package let artifacts: [AskPlaygroundArtifactRecord]

    package init(version: Int, artifacts: [AskPlaygroundArtifactRecord]) {
        self.version = version
        self.artifacts = artifacts
    }
}

package struct AskPlaygroundStore {
    package static let shared = AskPlaygroundStore()

    private let fileManager: FileManager

    package init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    package func ensureTaskWorkspace(for task: AskAgentTask) -> String? {
        if let existing = [
            task.metadata["active_task_workspace_root"],
            task.metadata["workspace_root"],
            task.context.workspaceRootPath
        ]
        .compactMap(AskWorkspaceRootSupport.normalizedWorkspaceRoot)
        .first {
            let standardized = URL(fileURLWithPath: existing, isDirectory: true).standardizedFileURL.path
            try? fileManager.createDirectory(atPath: standardized, withIntermediateDirectories: true)
            return standardized
        }

        let workspaceURL = taskWorkspaceURL(for: task)
        do {
            try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            return workspaceURL.path
        } catch {
            return nil
        }
    }

    package func recordArtifact(
        task: AskAgentTask,
        filePath: String,
        content: String
    ) -> AskPlaygroundArtifactRecord? {
        let workspaceRoot = ensureTaskWorkspace(for: task) ?? task.context.workspaceRootPath
        let standardizedFilePath = URL(fileURLWithPath: filePath).standardizedFileURL.path
        guard let workspaceRoot else { return nil }
        let standardizedRoot = URL(fileURLWithPath: workspaceRoot, isDirectory: true).standardizedFileURL.path
        guard standardizedFilePath == standardizedRoot || standardizedFilePath.hasPrefix(standardizedRoot + "/") else {
            return nil
        }

        let relativeEntryFile = standardizedFilePath.replacingOccurrences(of: standardizedRoot + "/", with: "")
        let now = Date()
        let loaded = loadCatalog()
        var records = loaded.artifacts
        let languageRuntime = Self.languageRuntime(for: standardizedFilePath)
        let tags = Self.tags(for: standardizedFilePath, content: content)
        let summary = String(task.objective.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
        let title = String((task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? URL(fileURLWithPath: standardizedFilePath).lastPathComponent
            : task.title).prefix(120))
        let reusableScore = Self.reusableScore(for: standardizedFilePath, content: content)

        if let index = records.firstIndex(where: { record in
            record.rootPath == standardizedRoot && record.entryFile == relativeEntryFile
        }) {
            let existing = records[index]
            records[index] = AskPlaygroundArtifactRecord(
                id: existing.id,
                title: title,
                summary: summary,
                rootPath: standardizedRoot,
                entryFile: relativeEntryFile,
                languageRuntime: languageRuntime,
                tags: tags,
                createdAt: existing.createdAt,
                lastUsedAt: now,
                reusableScore: max(existing.reusableScore, reusableScore),
                promotedToolID: existing.promotedToolID
            )
        } else {
            records.append(
                AskPlaygroundArtifactRecord(
                    id: UUID().uuidString.lowercased(),
                    title: title,
                    summary: summary,
                    rootPath: standardizedRoot,
                    entryFile: relativeEntryFile,
                    languageRuntime: languageRuntime,
                    tags: tags,
                    createdAt: now,
                    lastUsedAt: now,
                    reusableScore: reusableScore,
                    promotedToolID: nil
                )
            )
        }

        let snapshot = AskPlaygroundCatalogSnapshot(version: 1, artifacts: records.sorted { $0.lastUsedAt > $1.lastUsedAt })
        saveCatalog(snapshot)
        return snapshot.artifacts.first(where: { $0.rootPath == standardizedRoot && $0.entryFile == relativeEntryFile })
    }

    package func searchArtifacts(matching query: String, limit: Int = 5) -> [AskPlaygroundArtifactRecord] {
        let tokens = Set(Self.searchTokens(from: query))
        guard !tokens.isEmpty else { return [] }
        return loadCatalog().artifacts
            .map { record in
                let haystack = Set(Self.searchTokens(from: [record.title, record.summary, record.entryFile, record.tags.joined(separator: " ")].joined(separator: " ")))
                let score = Double(tokens.intersection(haystack).count) + record.reusableScore
                return (record, score)
            }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.lastUsedAt > rhs.0.lastUsedAt
                }
                return lhs.1 > rhs.1
            }
            .prefix(max(1, limit))
            .map(\.0)
    }

    package func promotedToolDescriptors() -> [AskLocalPromotedToolDescriptor] {
        loadCatalog().artifacts.compactMap { record in
            guard let promotedToolID = record.promotedToolID,
                  !promotedToolID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return AskLocalPromotedToolDescriptor(
                id: promotedToolID,
                name: promotedToolID,
                summary: record.summary,
                rootPath: record.rootPath,
                entryFile: record.entryFile,
                languageRuntime: record.languageRuntime
            )
        }
    }

    package func promotedToolDescriptor(id: String) -> AskLocalPromotedToolDescriptor? {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return nil }
        return promotedToolDescriptors().first(where: { $0.id == normalizedID })
    }

    package func artifact(forPromotedToolID toolID: String) -> AskPlaygroundArtifactRecord? {
        let normalizedID = toolID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return nil }
        return loadCatalog().artifacts.first(where: { $0.promotedToolID == normalizedID })
    }

    package func artifact(id: String) -> AskPlaygroundArtifactRecord? {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return nil }
        return loadCatalog().artifacts.first(where: { $0.id == normalizedID })
    }

    package func promoteArtifact(
        artifactID: String,
        preferredToolID: String? = nil
    ) -> AskLocalPromotedToolDescriptor? {
        let normalizedArtifactID = artifactID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedArtifactID.isEmpty else { return nil }

        let loaded = loadCatalog()
        guard let targetIndex = loaded.artifacts.firstIndex(where: { $0.id == normalizedArtifactID }) else {
            return nil
        }

        var records = loaded.artifacts
        let targetRecord = records[targetIndex]
        let toolID = sanitizedToolID(
            preferredToolID ?? targetRecord.title,
            fallbackArtifactID: targetRecord.id,
            existingRecords: records
        )
        records[targetIndex] = AskPlaygroundArtifactRecord(
            id: targetRecord.id,
            title: targetRecord.title,
            summary: targetRecord.summary,
            rootPath: targetRecord.rootPath,
            entryFile: targetRecord.entryFile,
            languageRuntime: targetRecord.languageRuntime,
            tags: targetRecord.tags,
            createdAt: targetRecord.createdAt,
            lastUsedAt: Date(),
            reusableScore: targetRecord.reusableScore,
            promotedToolID: toolID
        )
        let snapshot = AskPlaygroundCatalogSnapshot(version: 1, artifacts: records.sorted { $0.lastUsedAt > $1.lastUsedAt })
        saveCatalog(snapshot)
        return promotedToolDescriptor(id: toolID)
    }

    package func markArtifactUsed(id: String) {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        let loaded = loadCatalog()
        guard let targetIndex = loaded.artifacts.firstIndex(where: { $0.id == normalizedID }) else {
            return
        }
        var records = loaded.artifacts
        let record = records[targetIndex]
        records[targetIndex] = AskPlaygroundArtifactRecord(
            id: record.id,
            title: record.title,
            summary: record.summary,
            rootPath: record.rootPath,
            entryFile: record.entryFile,
            languageRuntime: record.languageRuntime,
            tags: record.tags,
            createdAt: record.createdAt,
            lastUsedAt: Date(),
            reusableScore: record.reusableScore,
            promotedToolID: record.promotedToolID
        )
        saveCatalog(AskPlaygroundCatalogSnapshot(version: 1, artifacts: records.sorted { $0.lastUsedAt > $1.lastUsedAt }))
    }

    package func isInsidePlayground(path: String) -> Bool {
        let rootPath = playgroundRootURL().standardizedFileURL.path
        let candidatePath = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    package func catalogURL() -> URL {
        playgroundRootURL().appendingPathComponent("catalog.json")
    }

    package func playgroundRootURL() -> URL {
        AskKernelPersistencePaths
            .askRoot(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("AskPlayground", isDirectory: true)
    }

    private func taskWorkspaceURL(for task: AskAgentTask) -> URL {
        let timestamp = Self.taskTimestampFormatter.string(from: task.createdAt)
        let slug = Self.slug(from: task.objective.isEmpty ? task.title : task.objective)
        let taskPrefix = String(task.id.prefix(8))
        return playgroundRootURL()
            .appendingPathComponent("Tasks", isDirectory: true)
            .appendingPathComponent("\(timestamp)-\(slug)-\(taskPrefix)", isDirectory: true)
    }

    private func loadCatalog() -> AskPlaygroundCatalogSnapshot {
        let url = catalogURL()
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? Self.decoder.decode(AskPlaygroundCatalogSnapshot.self, from: data) else {
            return AskPlaygroundCatalogSnapshot(version: 1, artifacts: [])
        }
        return snapshot
    }

    private func saveCatalog(_ snapshot: AskPlaygroundCatalogSnapshot) {
        let root = playgroundRootURL()
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        try? data.write(to: catalogURL(), options: .atomic)
    }

    private static func slug(from text: String) -> String {
        let normalized = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: "-")
        return normalized.isEmpty ? "task" : String(normalized.prefix(48))
    }

    private static func searchTokens(from text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func languageRuntime(for filePath: String) -> String {
        switch URL(fileURLWithPath: filePath).pathExtension.lowercased() {
        case "py":
            return "python"
        case "js":
            return "javascript"
        case "ts":
            return "typescript"
        case "sh":
            return "shell"
        case "html":
            return "html"
        case "css":
            return "css"
        case "json":
            return "json"
        case "swift":
            return "swift"
        default:
            return "text"
        }
    }

    private static func tags(for filePath: String, content: String) -> [String] {
        var tags: [String] = [languageRuntime(for: filePath)]
        let lowercasedContent = content.lowercased()
        if lowercasedContent.contains("<html") || lowercasedContent.contains("<!doctype html") {
            tags.append("webapp")
        }
        if lowercasedContent.contains("import argparse") || lowercasedContent.contains("def main") {
            tags.append("script")
        }
        if lowercasedContent.contains("playwright") || lowercasedContent.contains("selenium") {
            tags.append("browser-automation")
        }
        return Array(NSOrderedSet(array: tags).compactMap { $0 as? String })
    }

    private static func reusableScore(for filePath: String, content: String) -> Double {
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        let base: Double
        switch ext {
        case "py", "js", "ts", "sh":
            base = 0.72
        case "html":
            base = 0.58
        default:
            base = 0.4
        }
        if content.contains("def main") || content.contains("if __name__ == \"__main__\"") {
            return min(1, base + 0.12)
        }
        return base
    }

    private static let taskTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func sanitizedToolID(
        _ rawValue: String,
        fallbackArtifactID: String,
        existingRecords: [AskPlaygroundArtifactRecord]
    ) -> String {
        let base = rawValue
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: "_")
        let fallback = "playground_tool_\(fallbackArtifactID.prefix(8))"
        var candidate = base.isEmpty ? fallback : "playground_tool_\(String(base.prefix(40)))"
        let taken = Set(existingRecords.compactMap(\.promotedToolID))
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base.isEmpty ? fallback : "playground_tool_\(String(base.prefix(40)))")_\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
