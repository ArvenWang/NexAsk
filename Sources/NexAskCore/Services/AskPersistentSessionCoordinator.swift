import Foundation
import NexShared

struct AskPersistentInvocationRecord: Codable, Equatable, Sendable {
    let id: String
    let recordedAt: Date
    let sessionOrigin: AskSessionOrigin
    let invocationSurface: AskInvocationSurface
    let sourceBundleID: String?
    let sourceAppName: String?
    let requestedMode: AskExecutionMode?
    let assistantDeliveryChannel: String?
    let sourceTaskID: String?
    let sourceRunID: String?
    let sourceJobID: String?
    let activeTaskID: String?
    let activeTaskResumeToken: String?
    let workspaceRoot: String?
    let isProactive: Bool?
    let proactiveReason: AskProactiveReason?
    let presentationMode: AskProactivePresentationMode?
}

struct AskPersistentSessionSnapshot: Codable, Equatable {
    let persistenceKey: String
    let savedAt: Date
    let sessionID: String
    let sourceBundleID: String?
    let sourceAppName: String?
    let sessionOrigin: AskSessionOrigin
    let invocationSurface: AskInvocationSurface
    let requestedMode: AskExecutionMode?
    let frame: AskAssistantFollowUpWindowFrameSnapshot?
    let kernelMetadata: [String: String]
    let latestResponseMetadata: [String: String]
    let messages: [AskMessage]
    let messageCards: [AskAssistantFollowUpMessageCardsSnapshot]
    let pendingApproval: AskAssistantFollowUpApprovalSnapshot?
    let composerDraft: String?
    let invocations: [AskPersistentInvocationRecord]
}

struct AskPersistentSessionEntry: Equatable, Sendable {
    let sessionOrigin: AskSessionOrigin
    let invocationSurface: AskInvocationSurface
    let requestedMode: AskExecutionMode?
    let sourceBundleID: String?
    let sourceAppName: String?
    let compatibilityPersistenceKey: String?
    let activeTaskID: String?
    let activeTaskResumeToken: String?
    let isProactive: Bool
    let proactiveReason: AskProactiveReason?
    let presentationMode: AskProactivePresentationMode?
}

enum AskPersistentSessionBootstrap: Equatable {
    case fresh
    case restoreMain(AskPersistentSessionSnapshot)
    case restoreLegacy(AskAssistantFollowUpSessionSnapshot)
}

final class AskPersistentSessionStore {
    static let shared = AskPersistentSessionStore()

    private struct Payload: Codable {
        let version: Int
        let snapshot: AskPersistentSessionSnapshot?
    }

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.nexhub.ask-persistent-session-store", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let rootDirectoryURLOverride: URL?

    init(
        fileManager: FileManager = .default,
        rootDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.rootDirectoryURLOverride = rootDirectoryURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        ensureDirectories()
    }

    func snapshot() -> AskPersistentSessionSnapshot? {
        queue.sync {
            loadPayload().snapshot
        }
    }

    func save(_ snapshot: AskPersistentSessionSnapshot) {
        queue.sync {
            persistPayload(Payload(version: 1, snapshot: snapshot))
        }
    }

    func clear() {
        queue.sync {
            persistPayload(Payload(version: 1, snapshot: nil))
        }
    }

    private var rootDirectoryURL: URL {
        if let rootDirectoryURLOverride {
            return rootDirectoryURLOverride
        }
        return SkillStorePaths.appSupportRoot(fileManager: fileManager)
            .appendingPathComponent("Ask", isDirectory: true)
    }

    private var snapshotFileURL: URL {
        rootDirectoryURL.appendingPathComponent("ask_persistent_session.json")
    }

    private var legacySnapshotFileURL: URL {
        rootDirectoryURL.appendingPathComponent("kairos_session.json")
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
    }

    private func loadPayload() -> Payload {
        let resolvedURL: URL?
        if fileManager.fileExists(atPath: snapshotFileURL.path) {
            resolvedURL = snapshotFileURL
        } else if fileManager.fileExists(atPath: legacySnapshotFileURL.path) {
            resolvedURL = legacySnapshotFileURL
        } else {
            resolvedURL = nil
        }

        guard let resolvedURL,
              let data = try? Data(contentsOf: resolvedURL),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            return Payload(version: 1, snapshot: nil)
        }
        return payload
    }

    private func persistPayload(_ payload: Payload) {
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: snapshotFileURL, options: .atomic)
    }
}

final class AskPersistentSessionCoordinator {
    static let primarySessionKey = "primary"
    static let shared = AskPersistentSessionCoordinator()

    private let store: AskPersistentSessionStore
    private let legacyAssistantFollowUpSessionStore: AskAssistantFollowUpSessionStore

    init(
        store: AskPersistentSessionStore = .shared,
        legacyAssistantFollowUpSessionStore: AskAssistantFollowUpSessionStore = .shared
    ) {
        self.store = store
        self.legacyAssistantFollowUpSessionStore = legacyAssistantFollowUpSessionStore
    }

    func bootstrap(for entry: AskPersistentSessionEntry) -> AskPersistentSessionBootstrap {
        if let snapshot = store.snapshot(),
           Self.shouldRestorePersistedMainSnapshot(snapshot, for: entry) {
            return .restoreMain(snapshot)
        }
        if let compatibilityPersistenceKey = entry.compatibilityPersistenceKey,
           let snapshot = legacyAssistantFollowUpSessionStore.snapshot(for: compatibilityPersistenceKey) {
            return .restoreLegacy(snapshot)
        }
        return .fresh
    }

    func currentSnapshot() -> AskPersistentSessionSnapshot? {
        store.snapshot()
    }

    func persist(_ snapshot: AskPersistentSessionSnapshot) {
        store.save(snapshot)
    }

    func clearPersistedSession() {
        store.clear()
    }

    static func shouldRestorePersistedMainSnapshot(
        _ snapshot: AskPersistentSessionSnapshot,
        for entry: AskPersistentSessionEntry
    ) -> Bool {
        snapshot.hasContinuationState || entry.hasExplicitContinuationHint
    }
}

private extension AskPersistentSessionSnapshot {
    var hasContinuationState: Bool {
        pendingApproval != nil
            || !(composerDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(kernelMetadata["active_task_resume_token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(kernelMetadata["active_task_id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension AskPersistentSessionEntry {
    var hasExplicitContinuationHint: Bool {
        isProactive
            || compatibilityPersistenceKey != nil
            || !(activeTaskResumeToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(activeTaskID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
