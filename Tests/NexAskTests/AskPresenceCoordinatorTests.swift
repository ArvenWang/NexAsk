import XCTest
@testable import NexShared
@testable import NexAskCore

@MainActor
final class AskPresenceCoordinatorTests: XCTestCase {
    func testPolicySuppressesImmediatePopupDuringFullScreen() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let engine = AskPresencePolicyEngine(nowProvider: { now })
        let signal = AskPresenceSignal(
            id: "signal-1",
            kind: .selection,
            reason: .selectionSuggestion,
            recordedAt: now,
            title: "Selection",
            summary: "Some selected text that is worth continuing from.",
            dedupeKey: "selection:1",
            confidence: 0.7,
            sourceBundleID: "com.apple.Safari",
            sourceAppName: "Safari",
            sessionOrigin: .user,
            invocationSurface: .askBox,
            requestedMode: .interactive,
            compatibilityPersistenceKey: nil,
            suggestedPrompt: "Continue from my current selection.",
            metadata: [:]
        )

        let decision = engine.evaluate(
            signal: signal,
            interruptibility: AskInterruptibilitySnapshot(
                isFrontmostFullScreen: true,
                secondsSinceLastUserInteraction: 8,
                isAskVisible: false,
                isAskStreaming: false,
                hasPendingApproval: false,
                isProactivePopupVisible: false
            ),
            suppressionState: AskPresenceSuppressionState()
        )

        XCTAssertFalse(try XCTUnwrap(decision).shouldPresentImmediately)
        XCTAssertTrue(try XCTUnwrap(decision).shouldKeepUnread)
    }

    func testPolicyAllowsHighPriorityAutomationOpportunityWhenIdle() throws {
        let now = Date(timeIntervalSince1970: 1_775_000_100)
        let engine = AskPresencePolicyEngine(nowProvider: { now })
        let signal = AskPresenceSignal(
            id: "signal-2",
            kind: .automationRun,
            reason: .automationDecision,
            recordedAt: now,
            title: "Automation result",
            summary: "A follow-up decision is needed.",
            dedupeKey: "automation:1",
            confidence: 0.92,
            sourceBundleID: nil,
            sourceAppName: nil,
            sessionOrigin: .automation,
            invocationSurface: .proactivePopup,
            requestedMode: .interactive,
            compatibilityPersistenceKey: "task:automation-1",
            suggestedPrompt: "Continue from the latest automation result.",
            metadata: [:]
        )

        let decision = try XCTUnwrap(
            engine.evaluate(
                signal: signal,
                interruptibility: AskInterruptibilitySnapshot(
                    isFrontmostFullScreen: false,
                    secondsSinceLastUserInteraction: 12,
                    isAskVisible: false,
                    isAskStreaming: false,
                    hasPendingApproval: false,
                    isProactivePopupVisible: false
                ),
                suppressionState: AskPresenceSuppressionState()
            )
        )

        XCTAssertTrue(decision.shouldPresentImmediately)
        XCTAssertEqual(decision.opportunity.reason, .automationDecision)
    }

    func testPolicyKeepsClipboardOpportunityUnreadDuringActiveInteraction() throws {
        let now = Date(timeIntervalSince1970: 1_775_000_150)
        let engine = AskPresencePolicyEngine(nowProvider: { now })
        let signal = AskPresenceSignal(
            id: "signal-clipboard",
            kind: .clipboard,
            reason: .clipboardSuggestion,
            recordedAt: now,
            title: "Clipboard",
            summary: "A copied snippet worth continuing from.",
            dedupeKey: "clipboard:1",
            confidence: 0.66,
            sourceBundleID: "com.apple.TextEdit",
            sourceAppName: "TextEdit",
            sessionOrigin: .user,
            invocationSurface: .proactivePopup,
            requestedMode: .interactive,
            compatibilityPersistenceKey: nil,
            suggestedPrompt: "Continue from my latest clipboard.",
            metadata: [:]
        )

        let decision = try XCTUnwrap(
            engine.evaluate(
                signal: signal,
                interruptibility: AskInterruptibilitySnapshot(
                    isFrontmostFullScreen: false,
                    secondsSinceLastUserInteraction: 0.4,
                    isAskVisible: false,
                    isAskStreaming: false,
                    hasPendingApproval: false,
                    isProactivePopupVisible: false
                ),
                suppressionState: AskPresenceSuppressionState()
            )
        )

        XCTAssertFalse(decision.shouldPresentImmediately)
        XCTAssertTrue(decision.shouldKeepUnread)
        XCTAssertEqual(decision.opportunity.reason, .clipboardSuggestion)
    }

    func testCoordinatorPromotesUnreadInboxItemIntoOpportunity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let automationStore = AskAutomationStore(
            fileManager: .default,
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: root
        )
        let inboxStore = AskInboxStore(automationStore: automationStore)
        let coordinator = AskPresenceCoordinator(
            diagnosticsLogger: .shared,
            inboxStore: inboxStore,
            automationStore: automationStore,
            knowledgeBaseStore: ReplyKnowledgeBaseStore.shared,
            browserPageCaptureProvider: nil,
            fullScreenStatusProvider: { false },
            policyEngine: AskPresencePolicyEngine(nowProvider: { Date(timeIntervalSince1970: 1_775_000_200) }),
            nowProvider: { Date(timeIntervalSince1970: 1_775_000_200) }
        )

        var presentedOpportunity: AskProactiveOpportunity?
        coordinator.onOpportunityReady = { opportunity, _ in
            presentedOpportunity = opportunity
        }

        automationStore.saveInboxItem(
            AskInboxItem(
                id: "inbox-1",
                kind: "assistant_update",
                title: "继续 ASK 任务",
                summary: "需要你确认下一步。",
                createdAt: Date(timeIntervalSince1970: 1_775_000_200),
                sourceJobID: nil,
                sourceRunID: "run-1",
                sourceTaskID: "task-1",
                sourceTaskStatus: "waitingApproval",
                assistantDeliveryChannel: AskAssistantDeliveryChannel.inbox.rawValue,
                activeTaskID: "task-1",
                activeTaskResumeToken: "task:1",
                workspaceRoot: "/tmp/demo",
                actions: [],
                isRead: false
            )
        )

        coordinator.handleInboxDidChange()

        let unread = try XCTUnwrap(coordinator.currentUnreadOpportunity())
        XCTAssertEqual(unread.reason, .inboxFollowUp)
        XCTAssertEqual(unread.compatibilityPersistenceKey, "resume:task:1")
        XCTAssertEqual(presentedOpportunity?.id, unread.id)
    }

    func testTakingUnreadOpportunityMarksItPresentedAndSuppressesImmediateRepeat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let automationStore = AskAutomationStore(
            fileManager: .default,
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: root
        )
        let inboxStore = AskInboxStore(automationStore: automationStore)
        let timestamp = Date(timeIntervalSince1970: 1_775_000_260)
        let coordinator = AskPresenceCoordinator(
            diagnosticsLogger: .shared,
            inboxStore: inboxStore,
            automationStore: automationStore,
            knowledgeBaseStore: ReplyKnowledgeBaseStore.shared,
            browserPageCaptureProvider: nil,
            fullScreenStatusProvider: { false },
            policyEngine: AskPresencePolicyEngine(nowProvider: { timestamp }),
            nowProvider: { timestamp }
        )

        automationStore.saveInboxItem(
            AskInboxItem(
                id: "inbox-repeat",
                kind: "assistant_update",
                title: "继续 ASK 任务",
                summary: "需要你确认下一步。",
                createdAt: timestamp,
                sourceJobID: nil,
                sourceRunID: "run-repeat",
                sourceTaskID: "task-repeat",
                sourceTaskStatus: "waitingApproval",
                assistantDeliveryChannel: AskAssistantDeliveryChannel.inbox.rawValue,
                activeTaskID: "task-repeat",
                activeTaskResumeToken: "task:repeat",
                workspaceRoot: "/tmp/demo",
                actions: [],
                isRead: false
            )
        )

        coordinator.handleInboxDidChange()
        XCTAssertNotNil(coordinator.takeUnreadOpportunity())
        XCTAssertNil(coordinator.currentUnreadOpportunity())

        coordinator.handleInboxDidChange()
        XCTAssertNil(coordinator.currentUnreadOpportunity())
    }
}
