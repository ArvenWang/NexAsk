import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskMCPConnectionStoreTests: XCTestCase {
    func testUpsertNormalizesServerNameAndPersistsAcrossReload() throws {
        let root = makeTemporaryRoot()
        let notificationCenter = NotificationCenter()
        let store = AskMCPConnectionStore(
            fileManager: .default,
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )

        let syncedAt = Date(timeIntervalSince1970: 1_775_149_200)
        let record = AskMCPConnectionRecord(
            serverName: "  Demo-Server  ",
            displayName: " Demo Server ",
            status: .connected,
            endpointSummary: " https://demo.internal ",
            readableResourceCount: 7,
            lastSyncedAt: syncedAt,
            metadata: ["region": "cn"]
        )
        store.upsert(record)

        let reloaded = AskMCPConnectionStore(
            fileManager: .default,
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )
        let persisted = try XCTUnwrap(reloaded.connection(serverName: "demo-server"))
        XCTAssertEqual(persisted.serverName, "demo-server")
        XCTAssertEqual(persisted.displayName, "Demo Server")
        XCTAssertEqual(persisted.endpointSummary, "https://demo.internal")
        XCTAssertEqual(persisted.readableResourceCount, 7)
        XCTAssertEqual(persisted.lastSyncedAt, syncedAt)
        XCTAssertEqual(persisted.metadata["region"], "cn")
    }

    func testListConnectionsSortsByStatusThenMostRecentUpdate() {
        let root = makeTemporaryRoot()
        let store = AskMCPConnectionStore(
            fileManager: .default,
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: root
        )

        store.replaceConnections([
            AskMCPConnectionRecord(
                serverName: "offline",
                status: .disconnected,
                updatedAt: Date(timeIntervalSince1970: 30)
            ),
            AskMCPConnectionRecord(
                serverName: "warmup",
                status: .connecting,
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
            AskMCPConnectionRecord(
                serverName: "primary",
                status: .connected,
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            AskMCPConnectionRecord(
                serverName: "secondary",
                status: .connected,
                updatedAt: Date(timeIntervalSince1970: 40)
            ),
            AskMCPConnectionRecord(
                serverName: "degraded",
                status: .degraded,
                updatedAt: Date(timeIntervalSince1970: 50)
            )
        ])

        XCTAssertEqual(
            store.listConnections().map(\.serverName),
            ["secondary", "primary", "warmup", "degraded", "offline"]
        )
    }

    func testUpdateAndRemoveConnection() {
        let root = makeTemporaryRoot()
        let store = AskMCPConnectionStore(
            fileManager: .default,
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: root
        )

        store.upsert(
            AskMCPConnectionRecord(
                serverName: "edge",
                status: .connecting,
                readableResourceCount: 0
            )
        )

        let updated = store.updateConnection(serverName: "EDGE") { record in
            record.status = .connected
            record.readableResourceCount = 12
            record.lastError = nil
        }
        XCTAssertEqual(updated?.status, .connected)
        XCTAssertEqual(updated?.readableResourceCount, 12)

        XCTAssertTrue(store.removeConnection(serverName: "edge"))
        XCTAssertNil(store.connection(serverName: "edge"))
    }

    func testDiagnosticsSnapshotTracksRefreshAndRemoval() {
        let root = makeTemporaryRoot()
        let store = AskMCPConnectionStore(
            fileManager: .default,
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: root
        )

        store.upsert(
            AskMCPConnectionRecord(
                serverName: "Docs",
                status: .connecting,
                readableResourceCount: 0
            )
        )
        store.recordMirrorRefresh(
            serverName: "Docs",
            displayName: "Docs",
            resourceCount: 3
        )
        store.upsert(
            AskMCPConnectionRecord(
                serverName: "Repo",
                status: .failed,
                readableResourceCount: 0,
                lastError: "timeout"
            )
        )

        var diagnostics = store.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.totalConnections, 2)
        XCTAssertEqual(diagnostics.connectedCount, 1)
        XCTAssertEqual(diagnostics.failedCount, 1)
        XCTAssertEqual(diagnostics.mirroredReadableResourceCount, 3)
        XCTAssertEqual(diagnostics.mirroredServerCount, 1)

        store.clearMirroredResourceCounts()
        diagnostics = store.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.mirroredReadableResourceCount, 0)
        XCTAssertEqual(diagnostics.mirroredServerCount, 0)

        XCTAssertTrue(store.removeConnection(serverName: "Repo"))
        diagnostics = store.diagnosticsSnapshot()
        XCTAssertEqual(diagnostics.totalConnections, 1)
        XCTAssertEqual(diagnostics.failedCount, 0)
    }

    func testStorePostsChangeNotificationsForAddRefreshAndRemove() {
        let root = makeTemporaryRoot()
        let notificationCenter = NotificationCenter()
        let store = AskMCPConnectionStore(
            fileManager: .default,
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )
        var observedChanges = 0
        let token = notificationCenter.addObserver(
            forName: .askMCPConnectionsDidChange,
            object: store,
            queue: nil
        ) { _ in
            observedChanges += 1
        }
        defer { notificationCenter.removeObserver(token) }

        store.upsert(
            AskMCPConnectionRecord(
                serverName: "Docs",
                status: .connecting
            )
        )
        store.recordMirrorRefresh(
            serverName: "Docs",
            resourceCount: 2
        )
        _ = store.removeConnection(serverName: "Docs")

        XCTAssertEqual(observedChanges, 3)
    }

    private func makeTemporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-mcp-connection-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
