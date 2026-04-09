import Foundation

package enum AskMCPNotificationNames {
    package static let connectionsDidChange = Notification.Name("nexhub.askMCP.connectionsDidChange")
    package static let resourceCatalogDidChange = Notification.Name("nexhub.askMCP.resourceCatalogDidChange")
}

package enum AskMCPConnectionStatus: String, Codable, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case degraded
    case failed
}

package struct AskMCPConnectionDiagnosticsSnapshot: Equatable, Sendable {
    package let totalConnections: Int
    package let connectedCount: Int
    package let connectingCount: Int
    package let degradedCount: Int
    package let failedCount: Int
    package let disconnectedCount: Int
    package let mirroredReadableResourceCount: Int
    package let mirroredServerCount: Int

    package var payload: [String: Any] {
        [
            "total_connections": totalConnections,
            "connected_count": connectedCount,
            "connecting_count": connectingCount,
            "degraded_count": degradedCount,
            "failed_count": failedCount,
            "disconnected_count": disconnectedCount,
            "mirrored_readable_resource_count": mirroredReadableResourceCount,
            "mirrored_server_count": mirroredServerCount
        ]
    }

    package init(
        totalConnections: Int,
        connectedCount: Int,
        connectingCount: Int,
        degradedCount: Int,
        failedCount: Int,
        disconnectedCount: Int,
        mirroredReadableResourceCount: Int,
        mirroredServerCount: Int
    ) {
        self.totalConnections = totalConnections
        self.connectedCount = connectedCount
        self.connectingCount = connectingCount
        self.degradedCount = degradedCount
        self.failedCount = failedCount
        self.disconnectedCount = disconnectedCount
        self.mirroredReadableResourceCount = mirroredReadableResourceCount
        self.mirroredServerCount = mirroredServerCount
    }
}

package struct AskMCPConnectionRecord: Codable, Equatable, Sendable {
    package let serverName: String
    package var displayName: String?
    package var status: AskMCPConnectionStatus
    package var endpointSummary: String?
    package var readableResourceCount: Int
    package var lastSyncedAt: Date?
    package var lastError: String?
    package var updatedAt: Date
    package var metadata: [String: String]

    package init(
        serverName: String,
        displayName: String? = nil,
        status: AskMCPConnectionStatus,
        endpointSummary: String? = nil,
        readableResourceCount: Int = 0,
        lastSyncedAt: Date? = nil,
        lastError: String? = nil,
        updatedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.serverName = AskMCPConnectionRecord.normalizedServerName(serverName)
        self.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.status = status
        self.endpointSummary = endpointSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.readableResourceCount = max(0, readableResourceCount)
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    package static func normalizedServerName(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

package final class AskMCPConnectionStore {
    package static let shared = AskMCPConnectionStore()

    private struct Payload: Codable {
        let version: Int
        let connections: [AskMCPConnectionRecord]
    }

    private let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let queue = DispatchQueue(label: "com.nexask.ask-mcp-connection-store", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let rootDirectoryURLOverride: URL?

    package init(
        fileManager: FileManager = .default,
        notificationCenter: NotificationCenter = .default,
        rootDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.notificationCenter = notificationCenter
        self.rootDirectoryURLOverride = rootDirectoryURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        ensureDirectories()
    }

    package func listConnections() -> [AskMCPConnectionRecord] {
        queue.sync {
            loadConnections().sorted(by: sortConnections)
        }
    }

    package func connection(serverName: String) -> AskMCPConnectionRecord? {
        let normalized = AskMCPConnectionRecord.normalizedServerName(serverName)
        return queue.sync {
            loadConnections().first { $0.serverName == normalized }
        }
    }

    package func diagnosticsSnapshot() -> AskMCPConnectionDiagnosticsSnapshot {
        queue.sync {
            makeDiagnosticsSnapshot(from: loadConnections())
        }
    }

    @discardableResult
    package func upsert(_ record: AskMCPConnectionRecord) -> AskMCPConnectionRecord {
        queue.sync {
            var connections = loadConnections()
            if let index = connections.firstIndex(where: { $0.serverName == record.serverName }) {
                connections[index] = record
            } else {
                connections.append(record)
            }
            persistConnections(connections)
            postDidChange()
            return record
        }
    }

    @discardableResult
    package func recordMirrorRefresh(
        serverName: String,
        displayName: String? = nil,
        endpointSummary: String? = nil,
        resourceCount: Int,
        metadata: [String: String] = [:],
        now: Date = Date()
    ) -> AskMCPConnectionRecord {
        let normalized = AskMCPConnectionRecord.normalizedServerName(serverName)
        return queue.sync {
            var connections = loadConnections()
            let record: AskMCPConnectionRecord
            if let index = connections.firstIndex(where: { $0.serverName == normalized }) {
                var existing = connections[index]
                existing.displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? existing.displayName
                existing.endpointSummary = endpointSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? existing.endpointSummary
                existing.status = .connected
                existing.readableResourceCount = max(0, resourceCount)
                existing.lastSyncedAt = now
                existing.lastError = nil
                existing.updatedAt = now
                if !metadata.isEmpty {
                    existing.metadata.merge(metadata) { _, new in new }
                }
                connections[index] = existing
                record = existing
            } else {
                record = AskMCPConnectionRecord(
                    serverName: normalized,
                    displayName: displayName,
                    status: .connected,
                    endpointSummary: endpointSummary,
                    readableResourceCount: resourceCount,
                    lastSyncedAt: now,
                    lastError: nil,
                    updatedAt: now,
                    metadata: metadata
                )
                connections.append(record)
            }
            persistConnections(connections)
            postDidChange()
            return record
        }
    }

    package func mergeMirroredResourceCounts(
        _ countsByServer: [String: Int],
        now: Date = Date()
    ) {
        queue.sync {
            var connections = loadConnections()
            var seenServers: Set<String> = []

            for index in connections.indices {
                let serverName = connections[index].serverName
                guard let resourceCount = countsByServer[serverName] else {
                    connections[index].readableResourceCount = 0
                    continue
                }
                seenServers.insert(serverName)
                connections[index].status = .connected
                connections[index].readableResourceCount = max(0, resourceCount)
                connections[index].lastSyncedAt = now
                connections[index].lastError = nil
                connections[index].updatedAt = now
            }

            for (serverName, resourceCount) in countsByServer where !seenServers.contains(serverName) {
                connections.append(
                    AskMCPConnectionRecord(
                        serverName: serverName,
                        status: .connected,
                        readableResourceCount: resourceCount,
                        lastSyncedAt: now,
                        updatedAt: now
                    )
                )
            }

            persistConnections(connections)
            postDidChange()
        }
    }

    package func clearMirroredResourceCounts(now: Date = Date()) {
        queue.sync {
            var connections = loadConnections()
            guard !connections.isEmpty else { return }
            for index in connections.indices {
                connections[index].readableResourceCount = 0
                connections[index].updatedAt = now
            }
            persistConnections(connections)
            postDidChange()
        }
    }

    @discardableResult
    package func updateConnection(
        serverName: String,
        now: Date = Date(),
        mutate: (inout AskMCPConnectionRecord) -> Void
    ) -> AskMCPConnectionRecord? {
        let normalized = AskMCPConnectionRecord.normalizedServerName(serverName)
        return queue.sync {
            var connections = loadConnections()
            guard let index = connections.firstIndex(where: { $0.serverName == normalized }) else {
                return nil
            }
            mutate(&connections[index])
            connections[index].updatedAt = now
            persistConnections(connections)
            postDidChange()
            return connections[index]
        }
    }

    @discardableResult
    package func replaceConnections(_ records: [AskMCPConnectionRecord]) -> [AskMCPConnectionRecord] {
        queue.sync {
            let normalizedRecords = records.reduce(into: [String: AskMCPConnectionRecord]()) { partialResult, record in
                partialResult[record.serverName] = record
            }
            let ordered = Array(normalizedRecords.values).sorted(by: sortConnections)
            persistConnections(ordered)
            postDidChange()
            return ordered
        }
    }

    @discardableResult
    package func removeConnection(serverName: String) -> Bool {
        let normalized = AskMCPConnectionRecord.normalizedServerName(serverName)
        return queue.sync {
            var connections = loadConnections()
            let originalCount = connections.count
            connections.removeAll { $0.serverName == normalized }
            guard connections.count != originalCount else { return false }
            persistConnections(connections)
            postDidChange()
            return true
        }
    }

    package func clear() {
        queue.sync {
            persistConnections([])
            postDidChange()
        }
    }

    private var rootDirectoryURL: URL {
        if let rootDirectoryURLOverride {
            return rootDirectoryURLOverride
        }
        return AskKernelPersistencePaths.askRoot(fileManager: fileManager)
    }

    private var connectionsFileURL: URL {
        rootDirectoryURL.appendingPathComponent("kernel_mcp_connections.json")
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
    }

    private func loadConnections() -> [AskMCPConnectionRecord] {
        guard let data = try? Data(contentsOf: connectionsFileURL),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            return []
        }
        return payload.connections
    }

    private func persistConnections(_ connections: [AskMCPConnectionRecord]) {
        let payload = Payload(
            version: 1,
            connections: connections.sorted(by: sortConnections)
        )
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: connectionsFileURL, options: .atomic)
    }

    private func sortConnections(lhs: AskMCPConnectionRecord, rhs: AskMCPConnectionRecord) -> Bool {
        if lhs.status != rhs.status {
            return statusRank(lhs.status) < statusRank(rhs.status)
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.serverName.localizedCaseInsensitiveCompare(rhs.serverName) == .orderedAscending
    }

    private func statusRank(_ status: AskMCPConnectionStatus) -> Int {
        switch status {
        case .connected:
            return 0
        case .connecting:
            return 1
        case .degraded:
            return 2
        case .failed:
            return 3
        case .disconnected:
            return 4
        }
    }

    private func makeDiagnosticsSnapshot(from connections: [AskMCPConnectionRecord]) -> AskMCPConnectionDiagnosticsSnapshot {
        AskMCPConnectionDiagnosticsSnapshot(
            totalConnections: connections.count,
            connectedCount: connections.filter { $0.status == .connected }.count,
            connectingCount: connections.filter { $0.status == .connecting }.count,
            degradedCount: connections.filter { $0.status == .degraded }.count,
            failedCount: connections.filter { $0.status == .failed }.count,
            disconnectedCount: connections.filter { $0.status == .disconnected }.count,
            mirroredReadableResourceCount: connections.reduce(0) { $0 + max(0, $1.readableResourceCount) },
            mirroredServerCount: connections.filter { $0.readableResourceCount > 0 }.count
        )
    }

    private func postDidChange() {
        notificationCenter.post(name: AskMCPNotificationNames.connectionsDidChange, object: self)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
