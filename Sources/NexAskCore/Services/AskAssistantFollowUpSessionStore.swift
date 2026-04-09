import Foundation
import NexShared

struct AskAssistantFollowUpWindowFrameSnapshot: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct AskAssistantFollowUpMessageCardsSnapshot: Codable, Equatable {
    let messageIndex: Int
    let cards: [SkillResultCard]
}

struct AskAssistantFollowUpApprovalSnapshot: Codable, Equatable {
    let actionID: String
    let summaryText: String?
    let messageText: String?
    let previewCards: [SkillResultCard]
}

struct AskAssistantFollowUpSessionSnapshot: Codable, Equatable {
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
}

final class AskAssistantFollowUpSessionStore {
    static let shared = AskAssistantFollowUpSessionStore()

    private struct Payload: Codable {
        let version: Int
        let snapshots: [AskAssistantFollowUpSessionSnapshot]
    }

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.nexhub.ask-assistant-followup-sessions", qos: .utility)
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

    func snapshot(for persistenceKey: String) -> AskAssistantFollowUpSessionSnapshot? {
        queue.sync {
            loadSnapshots()[persistenceKey]
        }
    }

    func save(_ snapshot: AskAssistantFollowUpSessionSnapshot) {
        queue.sync {
            var snapshots = loadSnapshots()
            snapshots[snapshot.persistenceKey] = snapshot
            persistSnapshots(snapshots)
        }
    }

    func removeSnapshot(for persistenceKey: String) {
        queue.sync {
            var snapshots = loadSnapshots()
            guard snapshots.removeValue(forKey: persistenceKey) != nil else { return }
            persistSnapshots(snapshots)
        }
    }

    private var rootDirectoryURL: URL {
        if let rootDirectoryURLOverride {
            return rootDirectoryURLOverride
        }
        return SkillStorePaths.appSupportRoot(fileManager: fileManager)
            .appendingPathComponent("Ask", isDirectory: true)
    }

    private var snapshotsFileURL: URL {
        rootDirectoryURL.appendingPathComponent("assistant_followup_sessions.json")
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
    }

    private func loadSnapshots() -> [String: AskAssistantFollowUpSessionSnapshot] {
        guard let data = try? Data(contentsOf: snapshotsFileURL),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: payload.snapshots.map { ($0.persistenceKey, $0) })
    }

    private func persistSnapshots(_ snapshots: [String: AskAssistantFollowUpSessionSnapshot]) {
        let ordered = snapshots.values.sorted { lhs, rhs in
            if lhs.savedAt == rhs.savedAt {
                return lhs.persistenceKey < rhs.persistenceKey
            }
            return lhs.savedAt > rhs.savedAt
        }
        let payload = Payload(version: 1, snapshots: ordered)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: snapshotsFileURL, options: .atomic)
    }
}
