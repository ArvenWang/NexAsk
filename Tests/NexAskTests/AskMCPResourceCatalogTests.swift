import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskMCPResourceCatalogTests: XCTestCase {
    func testReplaceResourcesUpdatesConnectionStoreMirrorState() throws {
        let root = makeTemporaryRoot()
        let notificationCenter = NotificationCenter()
        let connectionStore = AskMCPConnectionStore(
            fileManager: .default,
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )
        let catalog = AskSharedMCPResourceCatalog(
            fileManager: .default,
            notificationCenter: notificationCenter,
            persistToDisk: true,
            rootDirectoryURL: root,
            connectionStore: connectionStore
        )

        catalog.replaceResources(
            serverName: "Docs",
            resources: [
                makeResource(server: "Docs", uri: "mcp://docs/guide"),
                makeResource(server: "Docs", uri: "mcp://docs/spec")
            ]
        )

        let connection = try XCTUnwrap(connectionStore.connection(serverName: "docs"))
        XCTAssertEqual(connection.status, .connected)
        XCTAssertEqual(connection.readableResourceCount, 2)
        XCTAssertNotNil(connection.lastSyncedAt)
        XCTAssertEqual(catalog.listServers(), ["docs"])
    }

    func testReplaceAllResourcesZeroesMissingServerMirrorCounts() throws {
        let root = makeTemporaryRoot()
        let notificationCenter = NotificationCenter()
        let connectionStore = AskMCPConnectionStore(
            fileManager: .default,
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )
        _ = connectionStore.upsert(
            AskMCPConnectionRecord(
                serverName: "legacy",
                status: .degraded,
                readableResourceCount: 9
            )
        )

        let catalog = AskSharedMCPResourceCatalog(
            fileManager: .default,
            notificationCenter: notificationCenter,
            persistToDisk: true,
            rootDirectoryURL: root,
            connectionStore: connectionStore
        )

        catalog.replaceAllResources([
            makeResource(server: "fresh", uri: "mcp://fresh/one"),
            makeResource(server: "fresh", uri: "mcp://fresh/two"),
            makeResource(server: "fresh", uri: "mcp://fresh/three")
        ])

        let legacyConnection = try XCTUnwrap(connectionStore.connection(serverName: "legacy"))
        XCTAssertEqual(legacyConnection.status, .degraded)
        XCTAssertEqual(legacyConnection.readableResourceCount, 0)

        let freshConnection = try XCTUnwrap(connectionStore.connection(serverName: "fresh"))
        XCTAssertEqual(freshConnection.status, .connected)
        XCTAssertEqual(freshConnection.readableResourceCount, 3)
    }

    func testClearRemovesMirroredResourcesAndKeepsConnectionRecordsAtZero() throws {
        let root = makeTemporaryRoot()
        let notificationCenter = NotificationCenter()
        let connectionStore = AskMCPConnectionStore(
            fileManager: .default,
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )
        let catalog = AskSharedMCPResourceCatalog(
            fileManager: .default,
            notificationCenter: notificationCenter,
            persistToDisk: true,
            rootDirectoryURL: root,
            connectionStore: connectionStore
        )

        catalog.replaceResources(
            serverName: "alpha",
            resources: [makeResource(server: "alpha", uri: "mcp://alpha/readme")]
        )
        XCTAssertTrue(catalog.hasAvailableResources)

        catalog.clear()

        XCTAssertFalse(catalog.hasAvailableResources)
        XCTAssertEqual(catalog.listResources(serverName: nil).count, 0)
        let connection = try XCTUnwrap(connectionStore.connection(serverName: "alpha"))
        XCTAssertEqual(connection.readableResourceCount, 0)
    }

    private func makeResource(server: String, uri: String) -> AskMCPResourceRecord {
        AskMCPResourceRecord(
            serverName: server,
            uri: uri,
            name: nil,
            description: nil,
            mimeType: "text/plain",
            textContent: "demo",
            updatedAt: Date(timeIntervalSince1970: 1_775_149_200),
            metadata: [:]
        )
    }

    private func makeTemporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-mcp-catalog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
