import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskPersistentSessionCoordinatorTests: XCTestCase {
    func testBootstrapStartsFreshWhenMainSnapshotOnlyContainsHistoricalTranscript() throws {
        let root = try makeRoot()
        let store = AskPersistentSessionStore(fileManager: .default, rootDirectoryURL: root.appendingPathComponent("ask-persistent", isDirectory: true))
        let legacyStore = AskAssistantFollowUpSessionStore(fileManager: .default, rootDirectoryURL: root.appendingPathComponent("legacy", isDirectory: true))
        let coordinator = AskPersistentSessionCoordinator(store: store, legacyAssistantFollowUpSessionStore: legacyStore)

        store.save(
            AskPersistentSessionSnapshot(
                persistenceKey: AskPersistentSessionCoordinator.primarySessionKey,
                savedAt: Date(),
                sessionID: "main-session",
                sourceBundleID: "com.apple.Safari",
                sourceAppName: "Safari",
                sessionOrigin: .user,
                invocationSurface: .askWindow,
                requestedMode: .interactive,
                frame: nil,
                kernelMetadata: [:],
                latestResponseMetadata: [:],
                messages: [AskMessage(role: .assistant, content: "main")],
                messageCards: [],
                pendingApproval: nil,
                composerDraft: nil,
                invocations: []
            )
        )

        legacyStore.save(
            AskAssistantFollowUpSessionSnapshot(
                persistenceKey: "resume:task:legacy",
                savedAt: Date(),
                sessionID: "legacy-session",
                sourceBundleID: nil,
                sourceAppName: nil,
                sessionOrigin: .assistantFollowUp,
                invocationSurface: .inbox,
                requestedMode: .interactive,
                frame: nil,
                kernelMetadata: [:],
                latestResponseMetadata: [:],
                messages: [AskMessage(role: .assistant, content: "legacy")],
                messageCards: [],
                pendingApproval: nil,
                composerDraft: nil
            )
        )

        let entry = AskPersistentSessionEntry(
            sessionOrigin: .user,
            invocationSurface: .askWindow,
            requestedMode: .interactive,
            sourceBundleID: nil,
            sourceAppName: nil,
            compatibilityPersistenceKey: nil,
            activeTaskID: nil,
            activeTaskResumeToken: nil,
            isProactive: false,
            proactiveReason: nil,
            presentationMode: nil
        )

        XCTAssertEqual(coordinator.bootstrap(for: entry), .fresh)
    }

    func testBootstrapRestoresMainSnapshotWhenMainSnapshotHasContinuationState() throws {
        let root = try makeRoot()
        let store = AskPersistentSessionStore(fileManager: .default, rootDirectoryURL: root.appendingPathComponent("ask-persistent", isDirectory: true))
        let legacyStore = AskAssistantFollowUpSessionStore(fileManager: .default, rootDirectoryURL: root.appendingPathComponent("legacy", isDirectory: true))
        let coordinator = AskPersistentSessionCoordinator(store: store, legacyAssistantFollowUpSessionStore: legacyStore)

        store.save(
            AskPersistentSessionSnapshot(
                persistenceKey: AskPersistentSessionCoordinator.primarySessionKey,
                savedAt: Date(),
                sessionID: "main-session",
                sourceBundleID: "com.apple.Safari",
                sourceAppName: "Safari",
                sessionOrigin: .user,
                invocationSurface: .askWindow,
                requestedMode: .interactive,
                frame: nil,
                kernelMetadata: ["active_task_resume_token": "task:123"],
                latestResponseMetadata: [:],
                messages: [AskMessage(role: .assistant, content: "main")],
                messageCards: [],
                pendingApproval: nil,
                composerDraft: nil,
                invocations: []
            )
        )

        let entry = AskPersistentSessionEntry(
            sessionOrigin: .user,
            invocationSurface: .askWindow,
            requestedMode: .interactive,
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari",
            compatibilityPersistenceKey: nil,
            activeTaskID: nil,
            activeTaskResumeToken: nil,
            isProactive: false,
            proactiveReason: nil,
            presentationMode: nil
        )

        let bootstrap = coordinator.bootstrap(for: entry)
        guard case .restoreMain(let snapshot) = bootstrap else {
            return XCTFail("Expected main snapshot restoration for unfinished continuity.")
        }
        XCTAssertEqual(snapshot.sessionID, "main-session")
    }

    func testBootstrapUsesLegacySnapshotWhenNoMainSnapshotExists() throws {
        let root = try makeRoot()
        let store = AskPersistentSessionStore(fileManager: .default, rootDirectoryURL: root.appendingPathComponent("ask-persistent", isDirectory: true))
        let legacyStore = AskAssistantFollowUpSessionStore(fileManager: .default, rootDirectoryURL: root.appendingPathComponent("legacy", isDirectory: true))
        let coordinator = AskPersistentSessionCoordinator(store: store, legacyAssistantFollowUpSessionStore: legacyStore)

        legacyStore.save(
            AskAssistantFollowUpSessionSnapshot(
                persistenceKey: "resume:task:legacy",
                savedAt: Date(),
                sessionID: "legacy-session",
                sourceBundleID: nil,
                sourceAppName: nil,
                sessionOrigin: .assistantFollowUp,
                invocationSurface: .inbox,
                requestedMode: .interactive,
                frame: nil,
                kernelMetadata: ["active_task_resume_token": "task:legacy"],
                latestResponseMetadata: [:],
                messages: [AskMessage(role: .assistant, content: "legacy")],
                messageCards: [],
                pendingApproval: nil,
                composerDraft: nil
            )
        )

        let entry = AskPersistentSessionEntry(
            sessionOrigin: .assistantFollowUp,
            invocationSurface: .inbox,
            requestedMode: .interactive,
            sourceBundleID: nil,
            sourceAppName: nil,
            compatibilityPersistenceKey: "resume:task:legacy",
            activeTaskID: "legacy-session",
            activeTaskResumeToken: "task:legacy",
            isProactive: false,
            proactiveReason: nil,
            presentationMode: nil
        )

        let bootstrap = coordinator.bootstrap(for: entry)
        guard case .restoreLegacy(let snapshot) = bootstrap else {
            return XCTFail("Expected legacy snapshot restoration.")
        }
        XCTAssertEqual(snapshot.sessionID, "legacy-session")
    }

    func testBootstrapStartsFreshWithoutAnySnapshot() throws {
        let root = try makeRoot()
        let store = AskPersistentSessionStore(fileManager: .default, rootDirectoryURL: root.appendingPathComponent("ask-persistent", isDirectory: true))
        let legacyStore = AskAssistantFollowUpSessionStore(fileManager: .default, rootDirectoryURL: root.appendingPathComponent("legacy", isDirectory: true))
        let coordinator = AskPersistentSessionCoordinator(store: store, legacyAssistantFollowUpSessionStore: legacyStore)

        let entry = AskPersistentSessionEntry(
            sessionOrigin: .user,
            invocationSurface: .askBox,
            requestedMode: .interactive,
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari",
            compatibilityPersistenceKey: nil,
            activeTaskID: nil,
            activeTaskResumeToken: nil,
            isProactive: false,
            proactiveReason: nil,
            presentationMode: nil
        )

        XCTAssertEqual(coordinator.bootstrap(for: entry), .fresh)
    }

    func testStoreCanReadLegacyPersistentSessionFallbackFileName() throws {
        let root = try makeRoot().appendingPathComponent("ask-persistent", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let payload = """
        {
          "snapshot" : {
            "composerDraft" : "restore me",
            "frame" : null,
            "invocations" : [ ],
            "invocationSurface" : "askWindow",
            "kernelMetadata" : { },
            "latestResponseMetadata" : { },
            "messageCards" : [ ],
            "messages" : [ ],
            "pendingApproval" : null,
            "persistenceKey" : "primary",
            "requestedMode" : "interactive",
            "savedAt" : "2026-04-03T10:00:00Z",
            "sessionID" : "legacy-main",
            "sessionOrigin" : "user",
            "sourceAppName" : "Safari",
            "sourceBundleID" : "com.apple.Safari"
          },
          "version" : 1
        }
        """

        try payload.data(using: .utf8)?.write(to: root.appendingPathComponent("kairos_session.json"))

        let store = AskPersistentSessionStore(fileManager: .default, rootDirectoryURL: root)
        let snapshot = try XCTUnwrap(store.snapshot())
        XCTAssertEqual(snapshot.sessionID, "legacy-main")
        XCTAssertEqual(snapshot.composerDraft, "restore me")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
