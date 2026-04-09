import Foundation

package struct AskMCPResourceRecord: Codable, Equatable, Sendable {
    package let serverName: String
    package let uri: String
    package let name: String?
    package let description: String?
    package let mimeType: String?
    package let textContent: String?
    package let updatedAt: Date
    package let metadata: [String: String]

    package init(
        serverName: String,
        uri: String,
        name: String?,
        description: String?,
        mimeType: String?,
        textContent: String?,
        updatedAt: Date,
        metadata: [String: String]
    ) {
        self.serverName = serverName
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.textContent = textContent
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

package protocol AskMCPResourceCatalogProviding {
    var hasAvailableResources: Bool { get }
    func listServers() -> [String]
    func listResources(serverName: String?) -> [AskMCPResourceRecord]
    func readResource(serverName: String, uri: String) -> AskMCPResourceRecord?
}

package protocol AskMCPResourceCatalogBacked {
    var mcpResourceCatalog: any AskMCPResourceCatalogProviding { get }
}

package protocol AskMCPConnectionStoreBacked {
    var mcpConnectionStore: AskMCPConnectionStore { get }
}

package struct AskNoopMCPResourceCatalog: AskMCPResourceCatalogProviding {
    package let hasAvailableResources = false

    package init() {}

    package func listServers() -> [String] {
        []
    }

    package func listResources(serverName: String?) -> [AskMCPResourceRecord] {
        _ = serverName
        return []
    }

    package func readResource(serverName: String, uri: String) -> AskMCPResourceRecord? {
        _ = serverName
        _ = uri
        return nil
    }
}

package final class AskSharedMCPResourceCatalog: AskMCPResourceCatalogProviding {
    package static let shared = AskSharedMCPResourceCatalog(persistToDisk: true)

    private struct Payload: Codable {
        let version: Int
        let servers: [String]?
        let resources: [AskMCPResourceRecord]
    }

    private let lock = NSLock()
    private let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let persistToDisk: Bool
    private let catalogFileURL: URL
    private let connectionStore: AskMCPConnectionStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var resourcesByServer: [String: [AskMCPResourceRecord]] = [:]
    private var knownServers: Set<String> = []
    private var lastKnownModificationDate: Date?

    package init(
        fileManager: FileManager = .default,
        notificationCenter: NotificationCenter = .default,
        persistToDisk: Bool = false,
        rootDirectoryURL: URL? = nil,
        connectionStore: AskMCPConnectionStore = .shared
    ) {
        self.fileManager = fileManager
        self.notificationCenter = notificationCenter
        self.persistToDisk = persistToDisk
        self.connectionStore = connectionStore
        let root = rootDirectoryURL ?? AskKernelPersistencePaths.askRoot(fileManager: fileManager)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.catalogFileURL = root.appendingPathComponent("kernel_mcp_resources.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        reloadFromDiskIfNeeded(force: true)
        syncConnectionStoreWithCurrentCatalog()
    }

    package var hasAvailableResources: Bool {
        reloadFromDiskIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return !knownServers.isEmpty
    }

    package func listServers() -> [String] {
        reloadFromDiskIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return knownServers.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    package func listResources(serverName: String?) -> [AskMCPResourceRecord] {
        reloadFromDiskIfNeeded()
        let normalizedServerName = normalizedServer(serverName)
        lock.lock()
        defer { lock.unlock() }

        let resources: [AskMCPResourceRecord]
        if let serverName, !serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resources = resourcesByServer[normalizedServerName] ?? []
        } else {
            resources = resourcesByServer.values.flatMap { $0 }
        }
        return resources.sorted(by: compareResources)
    }

    package func readResource(serverName: String, uri: String) -> AskMCPResourceRecord? {
        reloadFromDiskIfNeeded()
        let normalizedServerName = normalizedServer(serverName)
        let targetURI = normalizedURI(uri)
        lock.lock()
        defer { lock.unlock() }
        return (resourcesByServer[normalizedServerName] ?? []).first { resource in
            normalizedURI(resource.uri) == targetURI
        }
    }

    package func replaceResources(serverName: String, resources: [AskMCPResourceRecord]) {
        let normalizedServerName = normalizedServer(serverName)
        let now = Date()
        lock.lock()
        knownServers.insert(normalizedServerName)
        resourcesByServer[normalizedServerName] = resources
        lock.unlock()
        persistIfNeeded()
        connectionStore.recordMirrorRefresh(
            serverName: normalizedServerName,
            resourceCount: resources.count,
            now: now
        )
        postDidChange()
    }

    package func replaceAllResources(_ resources: [AskMCPResourceRecord]) {
        let now = Date()
        lock.lock()
        resourcesByServer = Dictionary(grouping: resources, by: { normalizedServer($0.serverName) })
        knownServers = Set(resourcesByServer.keys)
        lock.unlock()
        persistIfNeeded()
        connectionStore.mergeMirroredResourceCounts(
            Dictionary(grouping: resources, by: { normalizedServer($0.serverName) })
                .mapValues(\.count),
            now: now
        )
        postDidChange()
    }

    package func clear() {
        let now = Date()
        lock.lock()
        resourcesByServer = [:]
        knownServers = []
        lock.unlock()
        persistIfNeeded()
        connectionStore.clearMirroredResourceCounts(now: now)
        postDidChange()
    }

    private func compareResources(lhs: AskMCPResourceRecord, rhs: AskMCPResourceRecord) -> Bool {
        if lhs.serverName != rhs.serverName {
            return lhs.serverName.localizedCaseInsensitiveCompare(rhs.serverName) == .orderedAscending
        }
        if lhs.name != rhs.name {
            return (lhs.name ?? lhs.uri).localizedCaseInsensitiveCompare(rhs.name ?? rhs.uri) == .orderedAscending
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.uri.localizedCaseInsensitiveCompare(rhs.uri) == .orderedAscending
    }

    private func reloadFromDiskIfNeeded(force: Bool = false) {
        guard persistToDisk else { return }

        let modificationDate = (try? fileManager.attributesOfItem(atPath: catalogFileURL.path)[.modificationDate]) as? Date
        let shouldReload: Bool = {
            if force {
                return true
            }
            lock.lock()
            defer { lock.unlock() }
            return modificationDate != lastKnownModificationDate
        }()

        guard shouldReload else { return }

        guard let data = try? Data(contentsOf: catalogFileURL),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            lock.lock()
            resourcesByServer = [:]
            knownServers = []
            lastKnownModificationDate = modificationDate
            lock.unlock()
            return
        }

        lock.lock()
        resourcesByServer = Dictionary(grouping: payload.resources, by: { normalizedServer($0.serverName) })
        knownServers = Set((payload.servers ?? []).map(normalizedServer)).union(resourcesByServer.keys)
        lastKnownModificationDate = modificationDate
        lock.unlock()
    }

    private func persistIfNeeded() {
        guard persistToDisk else { return }
        let resources: [AskMCPResourceRecord] = {
            lock.lock()
            defer { lock.unlock() }
            return resourcesByServer.values
                .flatMap { $0 }
                .sorted(by: compareResources)
        }()
        let servers: [String] = {
            lock.lock()
            defer { lock.unlock() }
            return knownServers.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        }()
        let payload = Payload(version: 2, servers: servers, resources: resources)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: catalogFileURL, options: .atomic)
        let modificationDate = (try? fileManager.attributesOfItem(atPath: catalogFileURL.path)[.modificationDate]) as? Date
        lock.lock()
        lastKnownModificationDate = modificationDate
        lock.unlock()
    }

    private func syncConnectionStoreWithCurrentCatalog() {
        let counts: [String: Int] = {
            lock.lock()
            defer { lock.unlock() }
            return resourcesByServer.mapValues(\.count)
        }()
        guard !counts.isEmpty else { return }
        connectionStore.mergeMirroredResourceCounts(counts)
    }

    private func postDidChange() {
        notificationCenter.post(name: AskMCPNotificationNames.resourceCatalogDidChange, object: self)
    }

    private func normalizedServer(_ rawValue: String?) -> String {
        rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
        ?? ""
    }

    private func normalizedURI(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
