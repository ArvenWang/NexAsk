import AppKit
import CryptoKit
import Foundation
import PDFKit

extension Notification.Name {
    static let knowledgeBaseDidChange = Notification.Name("nexhub.knowledgeBaseDidChange")
}

package struct ReplyKnowledgeBaseChunk: Codable, Equatable {
    package let id: String
    package let text: String
    package let preview: String
    package let characterCount: Int
}

package enum ReplyKnowledgeBaseSourceKind: String, Codable, Equatable {
    case file
    case notion
    case selectionText = "selection_text"
    case url
}

package struct ReplyKnowledgeBaseEntry: Codable, Equatable, Identifiable {
    package let id: String
    package let title: String
    package let originalFilename: String
    package let storedFilename: String
    package let sourceFilePath: String
    package let contentType: String
    package let byteCount: Int64
    package let importedAt: Date
    package let summary: String
    package let preview: String
    package let fullText: String?
    package let parsedCharacterCount: Int
    package let chunkCount: Int
    package let chunks: [ReplyKnowledgeBaseChunk]
    package let sourceKind: ReplyKnowledgeBaseSourceKind?
    package let sourceIdentifier: String?
    package let externalURL: String?
    package let syncLabel: String?
    package let isEnabled: Bool?
    package let captureBehavior: KnowledgeBaseCaptureBehavior?
    package let contentKind: KnowledgeBaseContentKind?
    package let languageCode: String?
    package let topics: [String]?
    package let entities: [String]?
    package let sectionHeaders: [String]?
    package let searchFacets: [String: [String]]?
    package let capturePipeline: [String]?
    package let captureFailures: [KnowledgeBaseCaptureFailure]?
    package let sourceActions: [KnowledgeBaseSourceAction]?
    package let status: String?
    package let failureReason: String?
    package let qualityScore: Double?
    package let qualityLabel: String?
    package let providerLabel: String?
    package let lastRefreshedAt: Date?
    package let refreshable: Bool?
    package let canonicalURL: String?
    package let readableSnapshotStatus: KnowledgeBaseSnapshotStatus?
    package let sourceSnapshotStatus: KnowledgeBaseSnapshotStatus?
    package let captureAttempts: [KnowledgeBaseCaptureAttempt]?
    package let retentionScore: Double?
    package let provenanceQuality: String?
    package let refreshState: KnowledgeBaseRefreshState?
    package let ingestionReport: KnowledgeBaseIngestionReport?
}

package struct ReplyKnowledgeBaseImportFailure: Equatable {
    package let fileName: String
    package let reason: String
}

package struct ReplyKnowledgeBaseImportResult: Equatable {
    package let imported: [ReplyKnowledgeBaseEntry]
    package let failures: [ReplyKnowledgeBaseImportFailure]
}

package struct ReplyKnowledgeBaseBatchImportResult: Equatable {
    package let inserted: [ReplyKnowledgeBaseEntry]
    package let updated: [ReplyKnowledgeBaseEntry]
    package let failures: [ReplyKnowledgeBaseImportFailure]
}

package struct ReplyKnowledgeBaseNotionDocument {
    package let sourceIdentifier: String
    package let title: String
    package let pageURL: String
    package let plainText: String
    package let lastEditedAt: Date
    package let sourceLabel: String
}

package struct ReplyKnowledgeBaseSyncResult: Equatable {
    package let imported: [ReplyKnowledgeBaseEntry]
    package let updated: [ReplyKnowledgeBaseEntry]
    package let skippedCount: Int
    package let failures: [ReplyKnowledgeBaseImportFailure]
}

package final class ReplyKnowledgeBaseStore: @unchecked Sendable {
    package static let shared = ReplyKnowledgeBaseStore()

    static let supportedFilenameExtensions: [String] = [
        "txt", "md", "markdown", "text", "rtf", "rtfd", "pdf", "json", "csv", "tsv", "log", "yaml", "yml", "xml", "html", "htm", "docx", "pptx", "xlsx", "epub", "eml"
    ]

    private let fileManager: FileManager
    private let rootDirectoryURLOverride: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "com.nexhub.reply-knowledge-base", qos: .userInitiated)
    private let gatewayClient: KnowledgeBaseGatewayClient
    private let archiveReader: ZIPArchiveReader

    init(
        fileManager: FileManager = .default,
        rootDirectoryURL: URL? = nil,
        gatewayClient: KnowledgeBaseGatewayClient = .shared,
        archiveReader: ZIPArchiveReader = ZIPArchiveReader()
    ) {
        self.fileManager = fileManager
        self.rootDirectoryURLOverride = rootDirectoryURL
        self.gatewayClient = gatewayClient
        self.archiveReader = archiveReader
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = Self.gatewayDateDecodingStrategy
        migrateLegacyRootIfNeeded()
        ensureDirectories()
    }

    private static var gatewayDateDecodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = fractionalISO8601Formatter.date(from: raw) ?? plainISO8601Formatter.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(raw)")
        }
    }

    private static let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var supportedFormatsDescription: String {
        L10n.format(
            zhHans: "支持 %@，以及 URL 采集",
            en: "Supports %@, plus URL collection",
            Self.supportedFilenameExtensions.joined(separator: " / ")
        )
    }

    private var usesGatewayBackend: Bool {
        false
    }

    private func postKnowledgeBaseDidChange() {
        let post = {
            NotificationCenter.default.post(name: .knowledgeBaseDidChange, object: nil)
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    package func entries() -> [ReplyKnowledgeBaseEntry] {
        if usesGatewayBackend {
            return gatewayClient.listSources()
        }
        return queue.sync { loadEntries() }
    }

    func entry(id: String) -> ReplyKnowledgeBaseEntry? {
        if usesGatewayBackend {
            return gatewayClient.source(id: id)
        }
        return queue.sync { loadEntry(from: indexFileURL(for: id)) }
    }

    func sourceSnapshot(id: String, kind: String = "readable") -> KnowledgeBaseSnapshot? {
        if usesGatewayBackend {
            return gatewayClient.sourceSnapshot(id: id, kind: kind)
        }
        return queue.sync {
            guard let entry = loadEntry(from: indexFileURL(for: id)) else {
                return nil
            }
            let plainText = entry.fullText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? entry.fullText!
                : entry.preview
            let markdown = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdown.isEmpty else {
                return nil
            }
            return KnowledgeBaseSnapshot(
                id: "\(entry.id):\(kind)",
                sourceID: entry.id,
                revision: 1,
                createdAt: entry.lastRefreshedAt ?? entry.importedAt,
                snapshotKind: kind,
                markdownText: markdown,
                plainText: markdown,
                metadata: [
                    "source_kind": entry.sourceKind?.rawValue ?? "",
                    "content_kind": entry.contentKind?.rawValue ?? ""
                ]
            )
        }
    }

    func importFiles(urls: [URL]) async -> ReplyKnowledgeBaseImportResult {
        let result = await upsertFiles(urls: urls)
        return ReplyKnowledgeBaseImportResult(
            imported: result.inserted + result.updated,
            failures: result.failures
        )
    }

    package func upsertFiles(urls: [URL]) async -> ReplyKnowledgeBaseBatchImportResult {
        if usesGatewayBackend {
            let result = await gatewayClient.importFiles(urls: urls)
            if !result.inserted.isEmpty || !result.updated.isEmpty {
                postKnowledgeBaseDidChange()
            }
            return result
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let result = self.upsertFilesSynchronously(urls: urls)
                DispatchQueue.main.async {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    package func collectSelectedText(_ text: String, title: String? = nil) async -> ReplyKnowledgeBaseBatchImportResult {
        if usesGatewayBackend {
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: [],
                updated: [],
                failures: [.init(
                    fileName: title ?? L10n.text(zhHans: "选中文本", en: "Selected Text"),
                    reason: L10n.text(zhHans: "普通文本采集已停用。", en: "Plain-text collection is no longer supported.")
                )]
            )
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let result = self.collectSelectedTextSynchronously(text, title: title)
                DispatchQueue.main.async {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    package func collectURL(
        _ url: URL,
        title: String? = nil,
        text: String? = nil,
        summaryOverride: String? = nil,
        capturePipeline: [String]? = nil,
        captureFailures: [KnowledgeBaseCaptureFailure]? = nil
    ) async -> ReplyKnowledgeBaseBatchImportResult {
        if usesGatewayBackend {
            let result = await gatewayClient.importURL(
                url,
                title: title,
                text: text,
                capturePipeline: capturePipeline,
                captureFailures: captureFailures
            )
            if !result.inserted.isEmpty || !result.updated.isEmpty {
                postKnowledgeBaseDidChange()
            }
            return result
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let result = self.collectURLSynchronously(
                    url,
                    title: title,
                    text: text,
                    summaryOverride: summaryOverride,
                    capturePipeline: capturePipeline,
                    captureFailures: captureFailures
                )
                DispatchQueue.main.async {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    func syncNotionDocuments(_ documents: [ReplyKnowledgeBaseNotionDocument]) async -> ReplyKnowledgeBaseSyncResult {
        if usesGatewayBackend {
            return ReplyKnowledgeBaseSyncResult(
                imported: [],
                updated: [],
                skippedCount: documents.count,
                failures: []
            )
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let result = self.syncNotionDocumentsSynchronously(documents)
                DispatchQueue.main.async {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    func deleteEntry(id: String) -> Bool {
        if usesGatewayBackend {
            let deleted = gatewayClient.deleteSource(id: id)
            if deleted {
                postKnowledgeBaseDidChange()
            }
            return deleted
        }
        return queue.sync {
            let indexURL = self.indexFileURL(for: id)
            guard let entry = self.loadEntry(from: indexURL) else {
                return false
            }

            do {
                if self.fileManager.fileExists(atPath: indexURL.path) {
                    try self.fileManager.removeItem(at: indexURL)
                }
                let sourceURL = self.sourcesDirectoryURL.appendingPathComponent(entry.storedFilename)
                if entry.sourceKind != .notion, self.fileManager.fileExists(atPath: sourceURL.path) {
                    try self.fileManager.removeItem(at: sourceURL)
                }
                DispatchQueue.main.async {
                    self.postKnowledgeBaseDidChange()
                }
                return true
            } catch {
                return false
            }
        }
    }

    func setEntryEnabled(id: String, isEnabled: Bool) -> Bool {
        if usesGatewayBackend {
            let updated = gatewayClient.setSourceEnabled(id: id, isEnabled: isEnabled)
            if updated {
                postKnowledgeBaseDidChange()
            }
            return updated
        }
        return queue.sync {
            let indexURL = self.indexFileURL(for: id)
            guard let entry = self.loadEntry(from: indexURL) else {
                return false
            }

            let updatedEntry = ReplyKnowledgeBaseEntry(
                id: entry.id,
                title: entry.title,
                originalFilename: entry.originalFilename,
                storedFilename: entry.storedFilename,
                sourceFilePath: entry.sourceFilePath,
                contentType: entry.contentType,
                byteCount: entry.byteCount,
                importedAt: entry.importedAt,
                summary: entry.summary,
                preview: entry.preview,
                fullText: entry.fullText,
                parsedCharacterCount: entry.parsedCharacterCount,
                chunkCount: entry.chunkCount,
                chunks: entry.chunks,
                sourceKind: entry.sourceKind,
                sourceIdentifier: entry.sourceIdentifier,
                externalURL: entry.externalURL,
                syncLabel: entry.syncLabel,
                isEnabled: isEnabled,
                captureBehavior: entry.captureBehavior,
                contentKind: entry.contentKind,
                languageCode: entry.languageCode,
                topics: entry.topics,
                entities: entry.entities,
                sectionHeaders: entry.sectionHeaders,
                searchFacets: entry.searchFacets,
                capturePipeline: entry.capturePipeline,
                captureFailures: entry.captureFailures,
                sourceActions: entry.sourceActions,
                status: entry.status,
                failureReason: entry.failureReason,
                qualityScore: entry.qualityScore,
                qualityLabel: entry.qualityLabel,
                providerLabel: entry.providerLabel,
                lastRefreshedAt: entry.lastRefreshedAt,
                refreshable: entry.refreshable,
                canonicalURL: entry.canonicalURL,
                readableSnapshotStatus: entry.readableSnapshotStatus,
                sourceSnapshotStatus: entry.sourceSnapshotStatus,
                captureAttempts: entry.captureAttempts,
                retentionScore: entry.retentionScore,
                provenanceQuality: entry.provenanceQuality,
                refreshState: entry.refreshState,
                ingestionReport: entry.ingestionReport
            )

            do {
                let data = try encoder.encode(updatedEntry)
                try data.write(to: indexURL, options: .atomic)
                DispatchQueue.main.async {
                    self.postKnowledgeBaseDidChange()
                }
                return true
            } catch {
                return false
            }
        }
    }

    package func requestPayload() -> [String: Any]? {
        let currentEntries = entries()
        guard !currentEntries.isEmpty else { return nil }
        return [
            "enabled": true,
            "backend": "swift_local",
            "entry_count": currentEntries.count,
            "enabled_entry_count": currentEntries.filter { $0.isEnabled != false }.count,
            "facet_keys": ["source_kind", "content_kind", "language", "topic", "entity", "capture_behavior"]
        ]
    }

    package func searchEntries(
        query: String,
        filters: [String: [String]] = [:],
        limit: Int = 8
    ) -> [KnowledgeBaseSearchMatch] {
        if usesGatewayBackend {
            return gatewayClient.search(query: query, filters: filters, limit: limit)
        }
        return queue.sync {
            self.searchEntriesSynchronously(query: query, filters: filters, limit: limit)
        }
    }

    func refreshEntry(id: String) async -> ReplyKnowledgeBaseEntry? {
        guard usesGatewayBackend else { return entry(id: id) }
        let refreshed = await gatewayClient.refreshSource(id: id)
        if refreshed != nil {
            postKnowledgeBaseDidChange()
        }
        return refreshed
    }

    func reindexEntry(id: String) async -> ReplyKnowledgeBaseEntry? {
        guard usesGatewayBackend else { return entry(id: id) }
        let refreshed = await gatewayClient.reindexSource(id: id)
        if refreshed != nil {
            postKnowledgeBaseDidChange()
        }
        return refreshed
    }

    private var rootDirectoryURL: URL {
        if let rootDirectoryURLOverride {
            return rootDirectoryURLOverride
        }
        return SkillStorePaths.appSupportRoot(fileManager: fileManager)
            .appendingPathComponent("KnowledgeBase", isDirectory: true)
    }

    private var legacyRootDirectoryURL: URL {
        SkillStorePaths.appSupportRoot(fileManager: fileManager)
            .appendingPathComponent("ReplyKnowledgeBase", isDirectory: true)
    }

    private var sourcesDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("Sources", isDirectory: true)
    }

    private var indexDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("Index", isDirectory: true)
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: sourcesDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: indexDirectoryURL, withIntermediateDirectories: true)
    }

    private func migrateLegacyRootIfNeeded() {
        let legacyRoot = legacyRootDirectoryURL
        let newRoot = rootDirectoryURL
        guard !fileManager.fileExists(atPath: newRoot.path),
              fileManager.fileExists(atPath: legacyRoot.path) else {
            return
        }

        try? fileManager.moveItem(at: legacyRoot, to: newRoot)
    }

    private func upsertFilesSynchronously(urls: [URL]) -> ReplyKnowledgeBaseBatchImportResult {
        ensureDirectories()

        var inserted: [ReplyKnowledgeBaseEntry] = []
        var updated: [ReplyKnowledgeBaseEntry] = []
        var failures: [ReplyKnowledgeBaseImportFailure] = []
        let existingEntries = loadEntries()
        var existingByIdentifier = Dictionary(
            uniqueKeysWithValues: existingEntries.compactMap { entry -> (String, ReplyKnowledgeBaseEntry)? in
                guard entry.sourceKind == .file, let identifier = entry.sourceIdentifier else { return nil }
                return (identifier, entry)
            }
        )

        for url in urls {
            let fileName = url.lastPathComponent
            do {
                let extracted = try extractText(from: url)
                let normalizedText = normalize(text: extracted)
                guard !normalizedText.isEmpty else {
                    failures.append(.init(fileName: fileName, reason: L10n.text(zhHans: "文件里没有可用文本", en: "No usable text was found in the file")))
                    continue
                }

                let sourceIdentifier = standardizedSourceIdentifier(forFileURL: url)
                let reusedEntry = existingByIdentifier[sourceIdentifier]
                let entryID = reusedEntry?.id ?? UUID().uuidString.lowercased()
                let storedFilename = reusedEntry?.storedFilename ?? makeStoredFilename(for: entryID, originalFilename: fileName)
                let destinationURL = sourcesDirectoryURL.appendingPathComponent(storedFilename)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: url, to: destinationURL)

                let entry = makeEntry(
                    id: entryID,
                    title: url.deletingPathExtension().lastPathComponent,
                    originalFilename: fileName,
                    storedFilename: storedFilename,
                    sourceFilePath: destinationURL.path,
                    contentType: contentTypeLabel(for: url),
                    importedAt: reusedEntry?.importedAt ?? Date(),
                    text: normalizedText,
                    sourceKind: .file,
                    sourceIdentifier: sourceIdentifier,
                    externalURL: nil,
                    syncLabel: nil,
                    isEnabled: reusedEntry?.isEnabled ?? true,
                    byteCount: byteCount(for: destinationURL),
                    summaryOverride: nil,
                    captureBehavior: reusedEntry == nil ? .archive : .update,
                    contentKind: contentKind(for: url),
                    capturePipeline: ["file_extract", "normalize", "chunk"]
                )

                try writeEntry(entry)
                existingByIdentifier[sourceIdentifier] = entry
                if reusedEntry == nil {
                    inserted.append(entry)
                } else {
                    updated.append(entry)
                }
            } catch let error as ReplyKnowledgeBaseError {
                failures.append(.init(fileName: fileName, reason: error.localizedDescription))
            } catch {
                failures.append(.init(fileName: fileName, reason: L10n.text(zhHans: "导入失败", en: "Import failed")))
            }
        }

        if !inserted.isEmpty || !updated.isEmpty {
            DispatchQueue.main.async {
                self.postKnowledgeBaseDidChange()
            }
        }

        return ReplyKnowledgeBaseBatchImportResult(
            inserted: inserted.sorted(by: { $0.originalFilename.localizedCaseInsensitiveCompare($1.originalFilename) == .orderedAscending }),
            updated: updated.sorted(by: { $0.originalFilename.localizedCaseInsensitiveCompare($1.originalFilename) == .orderedAscending }),
            failures: failures
        )
    }

    private func collectSelectedTextSynchronously(_ text: String, title: String?) -> ReplyKnowledgeBaseBatchImportResult {
        let normalizedText = normalize(text: text)
        guard !normalizedText.isEmpty else {
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: [],
                updated: [],
                failures: [.init(fileName: title ?? L10n.text(zhHans: "选中文本", en: "Selected Text"), reason: L10n.text(zhHans: "没有可采集的文本", en: "There is no usable text to collect"))]
            )
        }

        let sourceIdentifier = stableTextSourceIdentifier(for: normalizedText)
        let existing = existingEntry(for: .selectionText, sourceIdentifier: sourceIdentifier)
        let entryID = existing?.id ?? UUID().uuidString.lowercased()
        let now = Date()
        let entry = makeEntry(
            id: entryID,
            title: resolvedSelectionTitle(from: normalizedText, preferredTitle: title),
            originalFilename: "\(resolvedSelectionTitle(from: normalizedText, preferredTitle: title)).txt",
            storedFilename: existing?.storedFilename ?? makeStoredFilename(for: entryID, originalFilename: "selection.txt"),
            sourceFilePath: "selection://\(entryID)",
            contentType: "TEXT",
            importedAt: existing?.importedAt ?? now,
            text: normalizedText,
            sourceKind: .selectionText,
            sourceIdentifier: sourceIdentifier,
            externalURL: nil,
            syncLabel: nil,
            isEnabled: existing?.isEnabled ?? true,
            byteCount: Int64(normalizedText.utf8.count),
            summaryOverride: nil,
            captureBehavior: classifySelectionBehavior(text: normalizedText, preferredTitle: title, isUpdate: existing != nil),
            contentKind: .note,
            capturePipeline: ["selection_capture", "normalize", "chunk"]
        )

        do {
            try writeEntry(entry)
            DispatchQueue.main.async {
                self.postKnowledgeBaseDidChange()
            }
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: existing == nil ? [entry] : [],
                updated: existing == nil ? [] : [entry],
                failures: []
            )
        } catch {
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: [],
                updated: [],
                failures: [.init(fileName: title ?? L10n.text(zhHans: "选中文本", en: "Selected Text"), reason: L10n.text(zhHans: "导入失败", en: "Import failed"))]
            )
        }
    }

    private func collectURLSynchronously(
        _ url: URL,
        title: String?,
        text: String?,
        summaryOverride: String?,
        capturePipeline: [String]?,
        captureFailures: [KnowledgeBaseCaptureFailure]?
    ) -> ReplyKnowledgeBaseBatchImportResult {
        let normalizedText = normalize(text: text ?? url.absoluteString)
        guard !normalizedText.isEmpty else {
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: [],
                updated: [],
                failures: [.init(fileName: url.absoluteString, reason: L10n.text(zhHans: "没有可采集的链接内容", en: "There is no usable link content to collect"))]
            )
        }

        let sourceIdentifier = canonicalSourceIdentifier(for: url)
        let existing = existingEntry(for: .url, sourceIdentifier: sourceIdentifier)
        let entryID = existing?.id ?? UUID().uuidString.lowercased()
        let resolvedTitle = resolvedURLTitle(url: url, preferredTitle: title, text: normalizedText)
        let entry = makeEntry(
            id: entryID,
            title: resolvedTitle,
            originalFilename: "\(resolvedTitle).url",
            storedFilename: existing?.storedFilename ?? makeStoredFilename(for: entryID, originalFilename: "link.url"),
            sourceFilePath: url.absoluteString,
            contentType: "URL",
            importedAt: existing?.importedAt ?? Date(),
            text: normalizedText,
            sourceKind: .url,
            sourceIdentifier: sourceIdentifier,
            externalURL: url.absoluteString,
            syncLabel: nil,
            isEnabled: existing?.isEnabled ?? true,
            byteCount: Int64(normalizedText.utf8.count),
            summaryOverride: summaryOverride,
            captureBehavior: existing == nil ? .archive : .update,
            contentKind: .webpage,
            capturePipeline: capturePipeline ?? ["url_collect", "normalize", "chunk"],
            captureFailures: captureFailures
        )

        do {
            try writeEntry(entry)
            DispatchQueue.main.async {
                self.postKnowledgeBaseDidChange()
            }
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: existing == nil ? [entry] : [],
                updated: existing == nil ? [] : [entry],
                failures: []
            )
        } catch {
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: [],
                updated: [],
                failures: [.init(fileName: url.absoluteString, reason: L10n.text(zhHans: "导入失败", en: "Import failed"))]
            )
        }
    }

    private func syncNotionDocumentsSynchronously(_ documents: [ReplyKnowledgeBaseNotionDocument]) -> ReplyKnowledgeBaseSyncResult {
        ensureDirectories()
        let existingEntries = loadEntries()
        let existingByIdentifier: [String: ReplyKnowledgeBaseEntry] = Dictionary(
            uniqueKeysWithValues: existingEntries.compactMap { entry -> (String, ReplyKnowledgeBaseEntry)? in
                guard entry.sourceKind == .notion, let identifier = entry.sourceIdentifier else { return nil }
                return (identifier, entry)
            }
        )

        var imported: [ReplyKnowledgeBaseEntry] = []
        var updated: [ReplyKnowledgeBaseEntry] = []
        var skippedCount = 0
        var failures: [ReplyKnowledgeBaseImportFailure] = []

        for document in documents {
            let normalizedText = normalize(text: document.plainText)
            guard !normalizedText.isEmpty else {
                failures.append(.init(fileName: document.title, reason: L10n.text(zhHans: "Notion 页面里没有可用文本", en: "No usable text was found in the Notion page")))
                continue
            }

            do {
                let chunks = makeChunks(from: normalizedText)
                let preview = shortPreview(for: normalizedText, limit: 120)
                let reusedEntry = existingByIdentifier[document.sourceIdentifier]
                let entryID = reusedEntry?.id ?? UUID().uuidString.lowercased()
                let virtualFilename = "\(document.title).notion"
                let entry = ReplyKnowledgeBaseEntry(
                    id: entryID,
                    title: document.title,
                    originalFilename: virtualFilename,
                    storedFilename: reusedEntry?.storedFilename ?? "notion-\(entryID).json",
                    sourceFilePath: document.pageURL,
                    contentType: "NOTION",
                    byteCount: Int64(normalizedText.utf8.count),
                    importedAt: reusedEntry?.importedAt ?? Date(),
                    summary: summaryText(for: normalizedText, fileName: document.title),
                    preview: preview,
                    fullText: normalizedText,
                    parsedCharacterCount: normalizedText.count,
                    chunkCount: chunks.count,
                    chunks: chunks,
                    sourceKind: .notion,
                    sourceIdentifier: document.sourceIdentifier,
                    externalURL: document.pageURL,
                    syncLabel: document.sourceLabel,
                    isEnabled: reusedEntry?.isEnabled ?? true,
                    captureBehavior: reusedEntry == nil ? .distill : .update,
                    contentKind: .reference,
                    languageCode: detectLanguageCode(for: normalizedText),
                    topics: extractTopics(from: normalizedText, title: document.title),
                    entities: extractEntities(from: normalizedText),
                    sectionHeaders: extractSectionHeaders(from: normalizedText),
                    searchFacets: buildSearchFacets(
                        sourceKind: .notion,
                        contentKind: .reference,
                        languageCode: detectLanguageCode(for: normalizedText),
                        captureBehavior: reusedEntry == nil ? .distill : .update,
                        title: document.title,
                        text: normalizedText
                    ),
                    capturePipeline: ["notion_sync", "normalize", "chunk"],
                    captureFailures: nil,
                    sourceActions: [
                        KnowledgeBaseSourceAction(
                            kind: .openURL,
                            label: L10n.text(zhHans: "打开来源", en: "Open Source"),
                            value: document.pageURL
                        )
                    ],
                    status: "ready",
                    failureReason: nil,
                    qualityScore: nil,
                    qualityLabel: nil,
                    providerLabel: "notion_sync",
                    lastRefreshedAt: reusedEntry?.lastRefreshedAt ?? Date(),
                    refreshable: false,
                    canonicalURL: document.pageURL,
                    readableSnapshotStatus: nil,
                    sourceSnapshotStatus: nil,
                    captureAttempts: nil,
                    retentionScore: nil,
                    provenanceQuality: nil,
                    refreshState: nil,
                    ingestionReport: nil
                )
                if let reusedEntry, reusedEntry == entry {
                    skippedCount += 1
                    continue
                }
                let data = try encoder.encode(entry)
                try data.write(to: indexFileURL(for: entryID), options: Data.WritingOptions.atomic)
                if reusedEntry == nil {
                    imported.append(entry)
                } else {
                    updated.append(entry)
                }
            } catch {
                failures.append(.init(fileName: document.title, reason: L10n.text(zhHans: "Notion 同步失败", en: "Notion sync failed")))
            }
        }

        if !imported.isEmpty || !updated.isEmpty {
            DispatchQueue.main.async {
                self.postKnowledgeBaseDidChange()
            }
        }

        return ReplyKnowledgeBaseSyncResult(
            imported: imported.sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }),
            updated: updated.sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }),
            skippedCount: skippedCount,
            failures: failures
        )
    }

    private func loadEntries() -> [ReplyKnowledgeBaseEntry] {
        ensureDirectories()
        let urls = (try? fileManager.contentsOfDirectory(
            at: indexDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap(loadEntry)
            .sorted { lhs, rhs in
                if lhs.importedAt == rhs.importedAt {
                    return lhs.originalFilename.localizedCaseInsensitiveCompare(rhs.originalFilename) == .orderedAscending
                }
                return lhs.importedAt > rhs.importedAt
            }
    }

    private func loadEntry(from url: URL) -> ReplyKnowledgeBaseEntry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(ReplyKnowledgeBaseEntry.self, from: data)
    }

    private func indexFileURL(for entryID: String) -> URL {
        indexDirectoryURL.appendingPathComponent("\(entryID).json")
    }

    private func existingEntry(
        for sourceKind: ReplyKnowledgeBaseSourceKind,
        sourceIdentifier: String
    ) -> ReplyKnowledgeBaseEntry? {
        loadEntries().first {
            $0.sourceKind == sourceKind && $0.sourceIdentifier == sourceIdentifier
        }
    }

    private func writeEntry(_ entry: ReplyKnowledgeBaseEntry) throws {
        let data = try encoder.encode(entry)
        try data.write(to: indexFileURL(for: entry.id), options: .atomic)
    }

    private func searchEntriesSynchronously(
        query: String,
        filters: [String: [String]],
        limit: Int
    ) -> [KnowledgeBaseSearchMatch] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = searchTokens(from: trimmedQuery)
        let normalizedFilters = filters.mapValues { Set($0.map { $0.lowercased() }) }

        let matches = loadEntries()
            .filter { $0.isEnabled != false }
            .compactMap { entry -> KnowledgeBaseSearchMatch? in
                let facets = effectiveSearchFacets(for: entry)
                guard matchesFilters(facets: facets, filters: normalizedFilters) else {
                    return nil
                }

                guard !tokens.isEmpty else {
                    return KnowledgeBaseSearchMatch(
                        entry: entry,
                        score: 0.1,
                        matchedChunk: nil,
                        matchedFacets: Array(normalizedFilters.keys).sorted(),
                        reason: L10n.text(zhHans: "按筛选条件命中", en: "Matched by facet filters"),
                        citation: nil
                    )
                }

                let titleScore = score(text: entry.title, tokens: tokens) * 2.6
                let topicScore = score(text: (entry.topics ?? []).joined(separator: " "), tokens: tokens) * 2.1
                let entityScore = score(text: (entry.entities ?? []).joined(separator: " "), tokens: tokens) * 2.0
                let summaryScore = score(text: entry.summary, tokens: tokens) * 1.5
                let bodyScore = score(text: entry.fullText ?? entry.preview, tokens: tokens) * 1.2
                let chunkMatch = bestChunkMatch(in: entry.chunks, tokens: tokens)
                let chunkScore = chunkMatch?.score ?? 0
                let facetHits = Array(Set(matchedFacetKeys(facets: facets, tokens: tokens) + Array(normalizedFilters.keys))).sorted()
                let facetScore = Double(facetHits.count) * 0.5
                let total = titleScore + topicScore + entityScore + summaryScore + bodyScore + chunkScore + facetScore
                guard total > 0.01 else { return nil }

                return KnowledgeBaseSearchMatch(
                    entry: entry,
                    score: total,
                    matchedChunk: chunkMatch?.chunk,
                    matchedFacets: facetHits,
                    reason: matchReason(
                        titleScore: titleScore,
                        topicScore: topicScore,
                        entityScore: entityScore,
                        chunkScore: chunkScore,
                        facetHits: facetHits
                    ),
                    citation: nil
                )
            }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.entry.importedAt > $1.entry.importedAt
            }

        return Array(matches.prefix(max(1, limit)))
    }

    private func makeEntry(
        id: String,
        title: String,
        originalFilename: String,
        storedFilename: String,
        sourceFilePath: String,
        contentType: String,
        importedAt: Date,
        text: String,
        sourceKind: ReplyKnowledgeBaseSourceKind,
        sourceIdentifier: String?,
        externalURL: String?,
        syncLabel: String?,
        isEnabled: Bool,
        byteCount: Int64,
        summaryOverride: String?,
        captureBehavior: KnowledgeBaseCaptureBehavior,
        contentKind: KnowledgeBaseContentKind,
        capturePipeline: [String],
        captureFailures: [KnowledgeBaseCaptureFailure]? = nil
    ) -> ReplyKnowledgeBaseEntry {
        let chunks = makeChunks(from: text)
        let preview = shortPreview(for: text, limit: 120)
        let languageCode = detectLanguageCode(for: text)
        let sectionHeaders = extractSectionHeaders(from: text)
        let topics = extractTopics(from: text, title: title)
        let entities = extractEntities(from: text)
        return ReplyKnowledgeBaseEntry(
            id: id,
            title: title,
            originalFilename: originalFilename,
            storedFilename: storedFilename,
            sourceFilePath: sourceFilePath,
            contentType: contentType,
            byteCount: byteCount,
            importedAt: importedAt,
            summary: summaryOverride ?? summaryText(for: text, fileName: originalFilename),
            preview: preview,
            fullText: text,
            parsedCharacterCount: text.count,
            chunkCount: chunks.count,
            chunks: chunks,
            sourceKind: sourceKind,
            sourceIdentifier: sourceIdentifier,
            externalURL: externalURL,
            syncLabel: syncLabel,
            isEnabled: isEnabled,
            captureBehavior: captureBehavior,
            contentKind: contentKind,
            languageCode: languageCode,
            topics: topics,
            entities: entities,
            sectionHeaders: sectionHeaders,
            searchFacets: buildSearchFacets(
                sourceKind: sourceKind,
                contentKind: contentKind,
                languageCode: languageCode,
                captureBehavior: captureBehavior,
                title: title,
                text: text
            ),
            capturePipeline: capturePipeline,
            captureFailures: captureFailures,
            sourceActions: buildSourceActions(
                entryID: id,
                sourceKind: sourceKind,
                sourceFilePath: sourceFilePath,
                externalURL: externalURL,
                text: text
            ),
            status: "ready",
            failureReason: nil,
            qualityScore: nil,
            qualityLabel: nil,
            providerLabel: capturePipeline.first,
            lastRefreshedAt: importedAt,
            refreshable: sourceKind == .url,
            canonicalURL: externalURL,
            readableSnapshotStatus: nil,
            sourceSnapshotStatus: nil,
            captureAttempts: nil,
            retentionScore: nil,
            provenanceQuality: nil,
            refreshState: nil,
            ingestionReport: nil
        )
    }

    private func makeStoredFilename(for entryID: String, originalFilename: String) -> String {
        let sanitized = sanitizedFilename(originalFilename)
        return "\(entryID)-\(sanitized)"
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
        let scalarView = filename.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(scalarView).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "document.txt" : cleaned
    }

    private func byteCount(for url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private func standardizedSourceIdentifier(forFileURL url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func stableTextSourceIdentifier(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func canonicalSourceIdentifier(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let normalizedScheme = components?.scheme?.lowercased()
        let normalizedHost = components?.host?.lowercased()
        components?.scheme = normalizedScheme
        components?.host = normalizedHost
        return components?.url?.absoluteString ?? url.absoluteString
    }

    private func classifySelectionBehavior(
        text: String,
        preferredTitle: String?,
        isUpdate: Bool
    ) -> KnowledgeBaseCaptureBehavior {
        if isUpdate {
            return .update
        }
        if let preferredTitle, !preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .distill
        }
        let lower = text.lowercased()
        if lower.contains("todo") || lower.contains("稍后") || lower.contains("later") || text.count < 140 {
            return .stash
        }
        return text.count > 260 ? .distill : .stash
    }

    private func contentKind(for url: URL) -> KnowledgeBaseContentKind {
        switch url.pathExtension.lowercased() {
        case "docx", "pdf", "md", "markdown", "txt", "json", "xml", "html", "htm":
            return .document
        case "pptx":
            return .presentation
        case "xlsx", "csv", "tsv":
            return .spreadsheet
        case "rtf", "rtfd":
            return .richText
        case "epub":
            return .article
        case "eml":
            return .email
        default:
            return .document
        }
    }

    private func detectLanguageCode(for text: String) -> String {
        let latinCount = text.unicodeScalars.filter { CharacterSet.letters.contains($0) && $0.isASCII }.count
        let chineseCount = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains(Int($0.value)) }.count
        if chineseCount > latinCount {
            return "zh"
        }
        if latinCount > 0 {
            return "en"
        }
        return Locale.current.language.languageCode?.identifier ?? "und"
    }

    private func extractTopics(from text: String, title: String) -> [String] {
        var candidates: [String] = []
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            candidates.append(trimmedTitle)
        }
        candidates.append(contentsOf: extractSectionHeaders(from: text))
        candidates.append(contentsOf: topKeywordCandidates(from: title))
        candidates.append(contentsOf: topKeywordCandidates(from: text))
        return Array(NSOrderedSet(array: candidates.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).compactMap { $0 as? String }.prefix(6).map { $0 }
    }

    private func extractEntities(from text: String) -> [String] {
        let pattern = #"(?:[A-Z][A-Za-z0-9\.\-\+]{1,}|[A-Z]{2,}|[\p{Han}]{2,12})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let values = regex.matches(in: text, range: nsRange).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.count >= 2 else { return nil }
            if candidate.lowercased() == candidate && !candidate.contains(where: \.isUppercase) {
                return nil
            }
            return candidate
        }
        return Array(NSOrderedSet(array: values)).compactMap { $0 as? String }.prefix(8).map { $0 }
    }

    private func extractSectionHeaders(from text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line.hasPrefix("#") || line.hasSuffix(":") || line.hasSuffix("：") {
                    return true
                }
                return line.count <= 42 && !line.contains("。") && !line.contains(". ")
            }
            .map { line in
                line
                    .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "[:：]$", with: "", options: .regularExpression)
            }
            .prefix(8)
            .map { $0 }
    }

    private func buildSearchFacets(
        sourceKind: ReplyKnowledgeBaseSourceKind,
        contentKind: KnowledgeBaseContentKind,
        languageCode: String,
        captureBehavior: KnowledgeBaseCaptureBehavior,
        title: String,
        text: String
    ) -> [String: [String]] {
        [
            "source_kind": [sourceKind.rawValue],
            "content_kind": [contentKind.rawValue],
            "language": [languageCode],
            "capture_behavior": [captureBehavior.rawValue],
            "topic": extractTopics(from: text, title: title),
            "entity": extractEntities(from: text)
        ]
    }

    private func buildSourceActions(
        entryID: String,
        sourceKind: ReplyKnowledgeBaseSourceKind,
        sourceFilePath: String,
        externalURL: String?,
        text: String
    ) -> [KnowledgeBaseSourceAction] {
        switch sourceKind {
        case .url, .notion:
            if let externalURL {
                return [KnowledgeBaseSourceAction(kind: .openURL, label: L10n.text(zhHans: "打开来源", en: "Open Source"), value: externalURL)]
            }
        case .file:
            return [
                KnowledgeBaseSourceAction(kind: .openFile, label: L10n.text(zhHans: "打开文件", en: "Open File"), value: sourceFilePath),
                KnowledgeBaseSourceAction(kind: .revealInFinder, label: L10n.text(zhHans: "在 Finder 中显示", en: "Reveal in Finder"), value: sourceFilePath)
            ]
        case .selectionText:
            return [
                KnowledgeBaseSourceAction(
                    kind: .showCapturedText,
                    label: L10n.text(zhHans: "查看原文", en: "View Original"),
                    value: KnowledgeBaseSourceActionResolver.capturedTextReference(forEntryID: entryID)
                )
            ]
        }
        return []
    }

    private func effectiveSearchFacets(for entry: ReplyKnowledgeBaseEntry) -> [String: [String]] {
        if let searchFacets = entry.searchFacets {
            return searchFacets
        }

        var facets: [String: [String]] = [:]
        if let sourceKind = entry.sourceKind?.rawValue {
            facets["source_kind"] = [sourceKind]
        }
        if let contentKind = entry.contentKind?.rawValue {
            facets["content_kind"] = [contentKind]
        }
        if let languageCode = entry.languageCode {
            facets["language"] = [languageCode]
        }
        if let captureBehavior = entry.captureBehavior?.rawValue {
            facets["capture_behavior"] = [captureBehavior]
        }
        facets["topic"] = entry.topics ?? []
        facets["entity"] = entry.entities ?? []
        return facets
    }

    private func matchesFilters(
        facets: [String: [String]],
        filters: [String: Set<String>]
    ) -> Bool {
        for (key, expectedValues) in filters {
            let actualValues = Set((facets[key] ?? []).map { $0.lowercased() })
            if actualValues.isDisjoint(with: expectedValues) {
                return false
            }
        }
        return true
    }

    private func matchedFacetKeys(facets: [String: [String]], tokens: [String]) -> [String] {
        let loweredTokens = Set(tokens)
        return facets.compactMap { key, values in
            let loweredValues = values.joined(separator: " ").lowercased()
            return loweredTokens.contains { loweredValues.contains($0) } ? key : nil
        }.sorted()
    }

    private func searchTokens(from query: String) -> [String] {
        query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private func score(text: String, tokens: [String]) -> Double {
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return 0 }
        var score = 0.0
        for token in tokens {
            if lowered.contains(token) {
                score += lowered.hasPrefix(token) ? 1.0 : 0.6
            }
        }
        return score
    }

    private func bestChunkMatch(in chunks: [ReplyKnowledgeBaseChunk], tokens: [String]) -> (chunk: ReplyKnowledgeBaseChunk, score: Double)? {
        chunks
            .map { chunk in (chunk, score(text: chunk.text, tokens: tokens)) }
            .filter { $0.1 > 0 }
            .max(by: { $0.1 < $1.1 })
    }

    private func matchReason(
        titleScore: Double,
        topicScore: Double,
        entityScore: Double,
        chunkScore: Double,
        facetHits: [String]
    ) -> String {
        if titleScore >= max(topicScore, entityScore, chunkScore) && titleScore > 0 {
            return L10n.text(zhHans: "标题最匹配", en: "Title matched best")
        }
        if topicScore >= max(entityScore, chunkScore) && topicScore > 0 {
            return L10n.text(zhHans: "主题最匹配", en: "Topics matched best")
        }
        if entityScore >= chunkScore && entityScore > 0 {
            return L10n.text(zhHans: "实体最匹配", en: "Entities matched best")
        }
        if !facetHits.isEmpty {
            return L10n.format(zhHans: "命中维度：%@", en: "Matched facets: %@", facetHits.joined(separator: ", "))
        }
        return L10n.text(zhHans: "正文片段匹配", en: "Body chunks matched")
    }

    private func topKeywordCandidates(from text: String) -> [String] {
        let lowered = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        let counts = lowered.reduce(into: [String: Int]()) { partialResult, token in
            partialResult[token, default: 0] += 1
        }
        return counts
            .sorted {
                if $0.value != $1.value {
                    return $0.value > $1.value
                }
                return $0.key < $1.key
            }
            .prefix(6)
            .map(\.key)
    }

    private func resolvedSelectionTitle(from text: String, preferredTitle: String?) -> String {
        if let preferredTitle {
            let trimmed = preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let preview = shortPreview(for: text, limit: 32)
        return preview.isEmpty
            ? L10n.text(zhHans: "选中文本", en: "Selected Text")
            : preview
    }

    private func resolvedURLTitle(url: URL, preferredTitle: String?, text: String) -> String {
        if let preferredTitle {
            let trimmed = preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let host = url.host, !host.isEmpty {
            return host
        }
        let preview = shortPreview(for: text, limit: 40)
        return preview.isEmpty ? url.absoluteString : preview
    }

    private func contentTypeLabel(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return "PDF"
        case "rtf":
            return "RTF"
        case "rtfd":
            return "RTFD"
        case "md", "markdown":
            return "Markdown"
        case "json":
            return "JSON"
        case "csv":
            return "CSV"
        case "tsv":
            return "TSV"
        case "html", "htm":
            return "HTML"
        case "docx":
            return "DOCX"
        case "pptx":
            return "PPTX"
        case "xlsx":
            return "XLSX"
        case "epub":
            return "EPUB"
        case "eml":
            return "EML"
        default:
            return ext.uppercased().isEmpty ? "TEXT" : ext.uppercased()
        }
    }

    private func extractText(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedFilenameExtensions.contains(ext) else {
            throw ReplyKnowledgeBaseError.unsupportedFormat
        }

        switch ext {
        case "txt", "md", "markdown", "text", "json", "csv", "tsv", "log", "yaml", "yml", "xml":
            return try readPlainText(from: url)
        case "rtf":
            return try readRichText(from: url)
        case "rtfd":
            return try readRichTextDocument(from: url)
        case "pdf":
            return try readPDFText(from: url)
        case "html", "htm":
            return try readHTMLText(from: url)
        case "docx":
            return try readDOCXText(from: url)
        case "pptx":
            return try readPPTXText(from: url)
        case "xlsx":
            return try readXLSXText(from: url)
        case "epub":
            return try readEPUBText(from: url)
        case "eml":
            return try readEMLText(from: url)
        default:
            throw ReplyKnowledgeBaseError.unsupportedFormat
        }
    }

    private func readPlainText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .unicode, .utf16LittleEndian, .utf16BigEndian, .ascii] {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        throw ReplyKnowledgeBaseError.parseFailed
    }

    private func readRichText(from url: URL) throws -> String {
        let attributed = try NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        return attributed.string
    }

    private func readRichTextDocument(from url: URL) throws -> String {
        let attributed = try NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
        return attributed.string
    }

    private func readHTMLText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let attributed = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        )
        return attributed.string
    }

    private func readPDFText(from url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ReplyKnowledgeBaseError.parseFailed
        }
        var pieces: [String] = []
        for pageIndex in 0..<document.pageCount {
            if let pageText = document.page(at: pageIndex)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pageText.isEmpty {
                pieces.append(pageText)
            }
        }
        return pieces.joined(separator: "\n\n")
    }

    private func readDOCXText(from url: URL) throws -> String {
        let archive = try openArchive(at: url)
        let xml = try decodeArchiveText(at: "word/document.xml", in: archive)
        return flattenWordProcessingML(xml)
    }

    private func readPPTXText(from url: URL) throws -> String {
        let archive = try openArchive(at: url)
        let slidePaths = archiveReader.entryPaths(in: archive)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted()
        guard !slidePaths.isEmpty else {
            throw ReplyKnowledgeBaseError.parseFailed
        }
        let slides = try slidePaths.map { path in
            try flattenPresentationML(decodeArchiveText(at: path, in: archive))
        }
        return slides.joined(separator: "\n\n")
    }

    private func readXLSXText(from url: URL) throws -> String {
        let archive = try openArchive(at: url)
        let entryPaths = archiveReader.entryPaths(in: archive)
        let sharedStrings: [String]
        if entryPaths.contains("xl/sharedStrings.xml") {
            sharedStrings = flattenSpreadsheetSharedStrings(try decodeArchiveText(at: "xl/sharedStrings.xml", in: archive))
        } else {
            sharedStrings = []
        }

        let sheetPaths = entryPaths
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()
        guard !sheetPaths.isEmpty else {
            throw ReplyKnowledgeBaseError.parseFailed
        }

        let sheetTexts = try sheetPaths.enumerated().map { index, path in
            let xml = try decodeArchiveText(at: path, in: archive)
            let text = flattenSpreadsheetWorksheet(xml, sharedStrings: sharedStrings)
            return "Sheet \(index + 1)\n\(text)"
        }
        return sheetTexts.joined(separator: "\n\n")
    }

    private func readEPUBText(from url: URL) throws -> String {
        let archive = try openArchive(at: url)
        let contentPaths = archiveReader.entryPaths(in: archive)
            .filter {
                ($0.hasSuffix(".xhtml") || $0.hasSuffix(".html") || $0.hasSuffix(".htm"))
                    && !$0.contains("/nav")
            }
            .sorted()
        guard !contentPaths.isEmpty else {
            throw ReplyKnowledgeBaseError.parseFailed
        }

        let parts = try contentPaths.compactMap { path -> String? in
            let html = try decodeArchiveText(at: path, in: archive)
            let text = try? htmlToPlainText(html)
            return text?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            throw ReplyKnowledgeBaseError.parseFailed
        }
        return parts.joined(separator: "\n\n")
    }

    private func readEMLText(from url: URL) throws -> String {
        let raw = try readPlainText(from: url)
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.components(separatedBy: "\n\n")
        let headerBlock = parts.first ?? ""
        let headers = headerBlock.components(separatedBy: "\n")
        let subject = headers.first(where: { $0.lowercased().hasPrefix("subject:") })?
            .replacingOccurrences(of: #"(?i)^subject:\s*"#, with: "", options: .regularExpression)
        let from = headers.first(where: { $0.lowercased().hasPrefix("from:") })?
            .replacingOccurrences(of: #"(?i)^from:\s*"#, with: "", options: .regularExpression)

        if let boundary = mimeBoundary(from: headerBlock) {
            let sections = normalized.components(separatedBy: "--\(boundary)")
            if let plainSection = sections.first(where: { $0.lowercased().contains("content-type: text/plain") }),
               let body = plainSection.components(separatedBy: "\n\n").dropFirst().first {
                return [subject, from, body].compactMap { $0 }.joined(separator: "\n")
            }
            if let htmlSection = sections.first(where: { $0.lowercased().contains("content-type: text/html") }),
               let body = nonEmpty(htmlSection.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")),
               let text = try? htmlToPlainText(body) {
                return [subject, from, text].compactMap { $0 }.joined(separator: "\n")
            }
        }

        let body = parts.dropFirst().joined(separator: "\n\n")
        return [subject, from, body].compactMap { $0 }.joined(separator: "\n")
    }

    private func openArchive(at url: URL) throws -> ZIPArchive {
        do {
            return try archiveReader.open(url)
        } catch {
            throw ReplyKnowledgeBaseError.parseFailed
        }
    }

    private func decodeArchiveText(at path: String, in archive: ZIPArchive) throws -> String {
        let data: Data
        do {
            data = try archiveReader.data(for: path, in: archive)
        } catch {
            throw ReplyKnowledgeBaseError.parseFailed
        }
        guard !data.isEmpty else {
            throw ReplyKnowledgeBaseError.parseFailed
        }
        return decodedString(from: data) ?? String(decoding: data, as: UTF8.self)
    }

    private func decodedString(from data: Data) -> String? {
        for encoding in [String.Encoding.utf8, .unicode, .utf16LittleEndian, .utf16BigEndian, .ascii] {
            if let string = String(data: data, encoding: encoding) {
                return string
            }
        }
        return nil
    }

    private func flattenWordProcessingML(_ xml: String) -> String {
        let prepared = xml
            .replacingOccurrences(of: "<w:tab/>", with: "\t")
            .replacingOccurrences(of: "<w:br/>", with: "\n")
            .replacingOccurrences(of: "</w:p>", with: "\n\n")
        return stripXML(prepared)
    }

    private func flattenPresentationML(_ xml: String) -> String {
        let prepared = xml
            .replacingOccurrences(of: "<a:br/>", with: "\n")
            .replacingOccurrences(of: "</a:p>", with: "\n\n")
        return stripXML(prepared)
    }

    private func flattenSpreadsheetSharedStrings(_ xml: String) -> [String] {
        let pattern = #"<(?:\w+:)?t[^>]*>(.*?)</(?:\w+:)?t>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        return regex.matches(in: xml, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: xml) else { return nil }
            return decodeXMLEntities(String(xml[valueRange]))
        }
    }

    private func flattenSpreadsheetWorksheet(_ xml: String, sharedStrings: [String]) -> String {
        let inlinePrepared = xml.replacingOccurrences(of: "</row>", with: "\n")
        var rows = stripXML(inlinePrepared)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !sharedStrings.isEmpty {
            rows.insert(contentsOf: sharedStrings, at: 0)
        }
        return Array(NSOrderedSet(array: rows)).compactMap { $0 as? String }.joined(separator: "\n")
    }

    private func htmlToPlainText(_ html: String) throws -> String {
        let data = Data(html.utf8)
        let attributed = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        )
        return attributed.string
    }

    private func stripXML(_ xml: String) -> String {
        let withoutTags = xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeXMLEntities(withoutTags)
            .replacingOccurrences(of: #"[ ]{2,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    private func decodeXMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private func mimeBoundary(from headers: String) -> String? {
        guard let match = headers.range(of: #"boundary="?([^"\n;]+)"?"#, options: .regularExpression) else {
            return nil
        }
        let text = String(headers[match])
        return text
            .replacingOccurrences(of: #"(?i)^boundary="?|"?$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "boundary=", with: "")
    }

    private func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalize(text: String) -> String {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\t", with: " ")
        normalized = normalized.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"[ ]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeChunks(from text: String) -> [ReplyKnowledgeBaseChunk] {
        let maxCharacters = 900
        let overlapCharacters = 120
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paragraphs.isEmpty else {
            return [
                ReplyKnowledgeBaseChunk(
                    id: "chunk_1",
                    text: text,
                    preview: shortPreview(for: text, limit: 100),
                    characterCount: text.count
                )
            ]
        }

        var chunks: [ReplyKnowledgeBaseChunk] = []
        var buffer = ""

        func appendBuffer() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            chunks.append(
                ReplyKnowledgeBaseChunk(
                    id: "chunk_\(chunks.count + 1)",
                    text: trimmed,
                    preview: shortPreview(for: trimmed, limit: 100),
                    characterCount: trimmed.count
                )
            )
            buffer = trimmed.suffix(overlapCharacters).description
        }

        for paragraph in paragraphs {
            if paragraph.count > maxCharacters {
                if !buffer.isEmpty {
                    appendBuffer()
                }
                var startIndex = paragraph.startIndex
                while startIndex < paragraph.endIndex {
                    let endIndex = paragraph.index(startIndex, offsetBy: maxCharacters, limitedBy: paragraph.endIndex) ?? paragraph.endIndex
                    let slice = String(paragraph[startIndex..<endIndex])
                    chunks.append(
                        ReplyKnowledgeBaseChunk(
                            id: "chunk_\(chunks.count + 1)",
                            text: slice,
                            preview: shortPreview(for: slice, limit: 100),
                            characterCount: slice.count
                        )
                    )
                    guard endIndex < paragraph.endIndex else { break }
                    startIndex = paragraph.index(endIndex, offsetBy: -min(overlapCharacters, slice.count))
                }
                buffer = ""
                continue
            }

            let candidate = buffer.isEmpty ? paragraph : "\(buffer)\n\n\(paragraph)"
            if candidate.count <= maxCharacters {
                buffer = candidate
            } else {
                appendBuffer()
                buffer = paragraph
            }
        }

        if !buffer.isEmpty {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            chunks.append(
                ReplyKnowledgeBaseChunk(
                    id: "chunk_\(chunks.count + 1)",
                    text: trimmed,
                    preview: shortPreview(for: trimmed, limit: 100),
                    characterCount: trimmed.count
                )
            )
        }

        return chunks
    }

    private func summaryText(for text: String, fileName: String) -> String {
        let preview = shortPreview(for: text, limit: 180)
        if preview.isEmpty {
            return fileName
        }
        return preview
    }

    private func shortPreview(for text: String, limit: Int) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        let index = compact.index(compact.startIndex, offsetBy: limit)
        return "\(compact[..<index])..."
    }
}

private enum ReplyKnowledgeBaseError: LocalizedError {
    case unsupportedFormat
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return L10n.text(zhHans: "暂不支持这个文件格式", en: "This file format is not supported yet")
        case .parseFailed:
            return L10n.text(zhHans: "文件解析失败", en: "File parsing failed")
        }
    }
}
