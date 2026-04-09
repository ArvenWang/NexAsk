import AppKit
import Foundation
import NexShared

#if !NEXHUB_PRODUCT_NEXHUB

enum AskProactivePresentationMode: String, Codable, CaseIterable, Sendable {
    case interactive
    case statusItemPopup
    case fallbackPopup
}

enum AskProactiveReason: String, Codable, CaseIterable, Sendable {
    case automationDecision
    case inboxFollowUp
    case notificationFollowUp
    case knowledgeUpdate
    case clipboardSuggestion
    case selectionSuggestion
    case browserSuggestion
    case finderSuggestion
    case calendarSuggestion
    case frontmostContext
}

enum AskPresenceSignalKind: String, Codable, CaseIterable, Sendable {
    case frontmostApp
    case selection
    case browserPage
    case finderSelection
    case automationRun
    case inboxItem
    case notificationActivation
    case calendarResult
    case knowledgeBase
    case clipboard
}

struct AskPresenceSignal: Equatable, Sendable {
    let id: String
    let kind: AskPresenceSignalKind
    let reason: AskProactiveReason
    let recordedAt: Date
    let title: String
    let summary: String
    let dedupeKey: String
    let confidence: Double
    let sourceBundleID: String?
    let sourceAppName: String?
    let sessionOrigin: AskSessionOrigin
    let invocationSurface: AskInvocationSurface
    let requestedMode: AskExecutionMode?
    let compatibilityPersistenceKey: String?
    let suggestedPrompt: String?
    let metadata: [String: String]
}

struct AskProactiveOpportunity: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let createdAt: Date
    let reason: AskProactiveReason
    let title: String
    let summary: String
    let dedupeKey: String
    let confidence: Double
    let sourceBundleID: String?
    let sourceAppName: String?
    let sessionOrigin: AskSessionOrigin
    let invocationSurface: AskInvocationSurface
    let requestedMode: AskExecutionMode?
    let compatibilityPersistenceKey: String?
    let suggestedPrompt: String?
    let metadata: [String: String]

    var hintText: String {
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summary.replacingOccurrences(of: "\n", with: " ")
        }
        return title.replacingOccurrences(of: "\n", with: " ")
    }

    var isHighPriority: Bool {
        switch reason {
        case .automationDecision, .inboxFollowUp, .notificationFollowUp, .calendarSuggestion:
            return true
        case .knowledgeUpdate, .clipboardSuggestion, .selectionSuggestion, .browserSuggestion, .finderSuggestion, .frontmostContext:
            return false
        }
    }
}

struct AskInterruptibilitySnapshot: Equatable, Sendable {
    let isFrontmostFullScreen: Bool
    let secondsSinceLastUserInteraction: TimeInterval
    let isAskVisible: Bool
    let isAskStreaming: Bool
    let hasPendingApproval: Bool
    let isProactivePopupVisible: Bool
}

struct AskPresenceSuppressionState: Equatable, Sendable {
    var lastPresentedAtByDedupeKey: [String: Date] = [:]
    var lastQueuedAtByDedupeKey: [String: Date] = [:]
}

struct AskPresenceState: Equatable, Sendable {
    var primarySessionID: String?
    var unreadOpportunity: AskProactiveOpportunity?
    var latestPresentedOpportunityID: String?
    var latestPresentedReason: AskProactiveReason?
    var latestPresentedAt: Date?
    var isProactivePopupVisible: Bool = false
    var lastSignalAt: Date?

    var hasUnreadOpportunity: Bool {
        unreadOpportunity != nil
    }
}

struct AskPresencePolicyDecision: Equatable, Sendable {
    let opportunity: AskProactiveOpportunity
    let shouldPresentImmediately: Bool
    let shouldKeepUnread: Bool
}

struct AskPresencePolicyEngine {
    private let nowProvider: () -> Date

    init(nowProvider: @escaping () -> Date = Date.init) {
        self.nowProvider = nowProvider
    }

    func evaluate(
        signal: AskPresenceSignal,
        interruptibility: AskInterruptibilitySnapshot,
        suppressionState: AskPresenceSuppressionState
    ) -> AskPresencePolicyDecision? {
        let opportunity = AskProactiveOpportunity(
            id: signal.id,
            createdAt: signal.recordedAt,
            reason: signal.reason,
            title: signal.title,
            summary: signal.summary,
            dedupeKey: signal.dedupeKey,
            confidence: signal.confidence,
            sourceBundleID: signal.sourceBundleID,
            sourceAppName: signal.sourceAppName,
            sessionOrigin: signal.sessionOrigin,
            invocationSurface: signal.invocationSurface,
            requestedMode: signal.requestedMode,
            compatibilityPersistenceKey: signal.compatibilityPersistenceKey,
            suggestedPrompt: signal.suggestedPrompt,
            metadata: signal.metadata
        )

        let highPriority = opportunity.isHighPriority
        let minimumConfidence = highPriority ? 0.4 : 0.55
        guard signal.confidence >= minimumConfidence else { return nil }

        let now = nowProvider()
        if let lastPresentedAt = suppressionState.lastPresentedAtByDedupeKey[signal.dedupeKey] {
            let cooldown = highPriority ? 90.0 : 240.0
            if now.timeIntervalSince(lastPresentedAt) < cooldown {
                return AskPresencePolicyDecision(
                    opportunity: opportunity,
                    shouldPresentImmediately: false,
                    shouldKeepUnread: false
                )
            }
        }

        let blockedByCriticalAsk =
            interruptibility.isAskVisible
            && (interruptibility.isAskStreaming || interruptibility.hasPendingApproval)
        let blockedByDuplicatePopup = interruptibility.isProactivePopupVisible
        let blockedByFullScreen = interruptibility.isFrontmostFullScreen
        let blockedByRecentInteraction = interruptibility.secondsSinceLastUserInteraction < (highPriority ? 1.1 : 3.5)

        let shouldPresentImmediately =
            !blockedByCriticalAsk
            && !blockedByDuplicatePopup
            && !blockedByFullScreen
            && !(blockedByRecentInteraction && !highPriority)

        return AskPresencePolicyDecision(
            opportunity: opportunity,
            shouldPresentImmediately: shouldPresentImmediately,
            shouldKeepUnread: true
        )
    }
}

final class AskPresenceCoordinator {
    typealias BrowserPageCaptureProvider = (String?) async -> BrowserPageCaptureResult?
    typealias FullScreenStatusProvider = () -> Bool

    private let diagnosticsLogger: DiagnosticsLogger
    private let inboxStore: AskInboxStore
    private let automationStore: AskAutomationStore
    private let knowledgeBaseStore: ReplyKnowledgeBaseStore
    private let browserPageCaptureProvider: BrowserPageCaptureProvider?
    private let fullScreenStatusProvider: FullScreenStatusProvider
    private let policyEngine: AskPresencePolicyEngine
    private let nowProvider: () -> Date
    private var clipboardPollTimer: Timer?
    private var localInteractionMonitor: Any?
    private var globalInteractionMonitor: Any?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var lastClipboardPreview: String?
    private var suppressionState = AskPresenceSuppressionState()
    private var lastUserInteractionAt = Date.distantPast
    private var isAskVisible = false
    private var isAskStreaming = false
    private var hasPendingApproval = false
    private var state = AskPresenceState()

    var onOpportunityReady: ((AskProactiveOpportunity, AskProactivePresentationMode) -> Void)?
    var onStateChanged: ((AskPresenceState) -> Void)?

    init(
        diagnosticsLogger: DiagnosticsLogger = .shared,
        inboxStore: AskInboxStore = .shared,
        automationStore: AskAutomationStore = .shared,
        knowledgeBaseStore: ReplyKnowledgeBaseStore = .shared,
        browserPageCaptureProvider: BrowserPageCaptureProvider? = nil,
        fullScreenStatusProvider: FullScreenStatusProvider? = nil,
        policyEngine: AskPresencePolicyEngine = AskPresencePolicyEngine(),
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.diagnosticsLogger = diagnosticsLogger
        self.inboxStore = inboxStore
        self.automationStore = automationStore
        self.knowledgeBaseStore = knowledgeBaseStore
        self.browserPageCaptureProvider = browserPageCaptureProvider
        self.fullScreenStatusProvider = fullScreenStatusProvider ?? AskPresenceCoordinator.defaultFullScreenStatus
        self.policyEngine = policyEngine
        self.nowProvider = nowProvider
    }

    func start() {
        stop()
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        registerInteractionMonitors()
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollClipboardIfNeeded()
            }
        }
        clipboardPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        clipboardPollTimer?.invalidate()
        clipboardPollTimer = nil
        if let localInteractionMonitor {
            NSEvent.removeMonitor(localInteractionMonitor)
            self.localInteractionMonitor = nil
        }
        if let globalInteractionMonitor {
            NSEvent.removeMonitor(globalInteractionMonitor)
            self.globalInteractionMonitor = nil
        }
    }

    func registerUserInteraction() {
        lastUserInteractionAt = nowProvider()
    }

    func updatePrimarySessionID(_ sessionID: String?) {
        guard state.primarySessionID != sessionID else { return }
        state.primarySessionID = sessionID
        publishState()
    }

    func updateAskWindowState(
        isVisible: Bool,
        isStreaming: Bool,
        hasPendingApproval: Bool,
        isProactivePopupVisible: Bool
    ) {
        self.isAskVisible = isVisible
        self.isAskStreaming = isStreaming
        self.hasPendingApproval = hasPendingApproval
        state.isProactivePopupVisible = isProactivePopupVisible
        publishState()
    }

    func currentUnreadOpportunity() -> AskProactiveOpportunity? {
        state.unreadOpportunity
    }

    func takeUnreadOpportunity() -> AskProactiveOpportunity? {
        let opportunity = state.unreadOpportunity
        state.unreadOpportunity = nil
        if let opportunity {
            let presentedAt = nowProvider()
            state.latestPresentedOpportunityID = opportunity.id
            state.latestPresentedReason = opportunity.reason
            state.latestPresentedAt = presentedAt
            suppressionState.lastPresentedAtByDedupeKey[opportunity.dedupeKey] = presentedAt
        }
        publishState()
        return opportunity
    }

    func handleSelectionSnapshot(_ snapshot: SelectionSnapshot) {
        let preview = trimmedPreview(snapshot.text, limit: 180)
        guard !preview.isEmpty else { return }
        recordSignal(
            AskPresenceSignal(
                id: UUID().uuidString.lowercased(),
                kind: .selection,
                reason: .selectionSuggestion,
                recordedAt: nowProvider(),
                title: L10n.text(zhHans: "你刚选中了一段内容", en: "You just selected some text"),
                summary: preview,
                dedupeKey: "selection:\(snapshot.sourceBundleID ?? "unknown"):\(preview)",
                confidence: preview.count >= 18 ? 0.61 : 0.48,
                sourceBundleID: snapshot.sourceBundleID,
                sourceAppName: nil,
                sessionOrigin: .user,
                invocationSurface: .askBox,
                requestedMode: .interactive,
                compatibilityPersistenceKey: nil,
                suggestedPrompt: AppLanguage.from(languageCode: AppSettings.shared.appLanguage.languageCode) == .english
                    ? "Use the current selection and help me continue from it."
                    : "基于我刚选中的内容继续帮我处理。",
                metadata: [
                    "selection_preview": preview
                ]
            )
        )
    }

    func handleFinderSelection(_ snapshot: FileSelectionSnapshot) {
        guard !snapshot.fileURLs.isEmpty else { return }
        let preview = trimmedPreview(snapshot.displayText, limit: 180)
        recordSignal(
            AskPresenceSignal(
                id: UUID().uuidString.lowercased(),
                kind: .finderSelection,
                reason: .finderSuggestion,
                recordedAt: nowProvider(),
                title: L10n.text(zhHans: "Finder 里有新的文件选择", en: "New Finder file selection"),
                summary: preview,
                dedupeKey: "finder:\(snapshot.fileURLs.map { $0.path }.joined(separator: "|"))",
                confidence: snapshot.fileURLs.count > 1 ? 0.67 : 0.52,
                sourceBundleID: snapshot.sourceBundleID,
                sourceAppName: "Finder",
                sessionOrigin: .user,
                invocationSurface: .menuBar,
                requestedMode: .interactive,
                compatibilityPersistenceKey: nil,
                suggestedPrompt: AppLanguage.from(languageCode: AppSettings.shared.appLanguage.languageCode) == .english
                    ? "Help me work with the files currently selected in Finder."
                    : "基于我现在在 Finder 里选中的文件继续帮我处理。",
                metadata: [
                    "selection_preview": preview
                ]
            )
        )
    }

    func handleFrontmostApplicationDidChange(_ app: NSRunningApplication?) {
        guard let app,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else {
            return
        }
        let appName = app.localizedName
        recordSignal(
            AskPresenceSignal(
                id: UUID().uuidString.lowercased(),
                kind: .frontmostApp,
                reason: .frontmostContext,
                recordedAt: nowProvider(),
                title: L10n.text(zhHans: "你切换到了新的前台应用", en: "You switched to a new frontmost app"),
                summary: appName ?? bundleID,
                dedupeKey: "frontmost:\(bundleID)",
                confidence: 0.46,
                sourceBundleID: bundleID,
                sourceAppName: appName,
                sessionOrigin: .user,
                invocationSurface: .menuBar,
                requestedMode: .interactive,
                compatibilityPersistenceKey: nil,
                suggestedPrompt: nil,
                metadata: [
                    "source_bundle_id": bundleID,
                    "source_app_name": appName ?? bundleID
                ]
            )
        )
    }

    func handleBrowserPageCapture(_ result: BrowserPageCaptureResult) {
        let preview = trimmedPreview(result.text, limit: 220)
        recordSignal(
            AskPresenceSignal(
                id: UUID().uuidString.lowercased(),
                kind: .browserPage,
                reason: .browserSuggestion,
                recordedAt: nowProvider(),
                title: result.title,
                summary: preview,
                dedupeKey: "browser:\(result.pageURL.absoluteString)",
                confidence: 0.68,
                sourceBundleID: result.browserBundleID,
                sourceAppName: nil,
                sessionOrigin: .user,
                invocationSurface: .menuBar,
                requestedMode: .interactive,
                compatibilityPersistenceKey: nil,
                suggestedPrompt: AppLanguage.from(languageCode: AppSettings.shared.appLanguage.languageCode) == .english
                    ? "Use the current browser page and help me continue from it."
                    : "基于我当前浏览器页面的内容继续帮我处理。",
                metadata: [
                    "current_page_url": result.pageURL.absoluteString,
                    "current_page_title": result.title,
                    "current_page_text_preview": preview
                ]
            )
        )
    }

    func handleInboxDidChange() {
        guard let item = inboxStore.items(limit: 8).first(where: { !$0.isRead }),
              let activation = item.assistantFollowUpActivation else {
            return
        }
        recordSignal(
            AskPresenceSignal(
                id: UUID().uuidString.lowercased(),
                kind: .inboxItem,
                reason: .inboxFollowUp,
                recordedAt: nowProvider(),
                title: activation.title,
                summary: activation.summary,
                dedupeKey: "inbox:\(item.id)",
                confidence: 0.95,
                sourceBundleID: nil,
                sourceAppName: nil,
                sessionOrigin: activation.sessionOrigin,
                invocationSurface: .proactivePopup,
                requestedMode: activation.requestedMode,
                compatibilityPersistenceKey: activation.persistenceKey,
                suggestedPrompt: activation.suggestedPrompt(responseLanguage: AppSettings.shared.appLanguage.languageCode),
                metadata: activation.initialKernelMetadata
            )
        )
    }

    func handleAutomationRunsDidChange() {
        guard let run = automationStore.listRuns(limit: 8).first else { return }
        let shouldPrompt: Bool
        switch run.status {
        case .completed, .partial, .blocked, .failed:
            shouldPrompt = true
        case .running, .skipped:
            shouldPrompt = false
        }
        guard shouldPrompt else { return }

        var metadata: [String: String] = [:]
        if let jobID = run.jobID as String? {
            metadata["assistant_delivery_source_job_id"] = jobID
        }
        metadata["assistant_delivery_source_run_id"] = run.runID
        if let taskID = run.kernelTaskID {
            metadata["active_task_id"] = taskID
        }
        if let workspaceRoot = run.workspaceRoot {
            metadata["workspace_root"] = workspaceRoot
            metadata["active_task_workspace_root"] = workspaceRoot
        }

        recordSignal(
            AskPresenceSignal(
                id: UUID().uuidString.lowercased(),
                kind: .automationRun,
                reason: .automationDecision,
                recordedAt: nowProvider(),
                title: L10n.text(zhHans: "有新的 ASK 自动化结果", en: "New ASK automation result"),
                summary: run.summary,
                dedupeKey: "automation:\(run.runID)",
                confidence: 0.9,
                sourceBundleID: nil,
                sourceAppName: nil,
                sessionOrigin: .automation,
                invocationSurface: .proactivePopup,
                requestedMode: .interactive,
                compatibilityPersistenceKey: run.kernelTaskID.map { "task:\($0)" },
                suggestedPrompt: AppLanguage.from(languageCode: AppSettings.shared.appLanguage.languageCode) == .english
                    ? "Continue from the latest automation result and tell me what I should do next."
                    : "基于最新的 ASK 自动化结果继续，并告诉我下一步该做什么。",
                metadata: metadata
            )
        )
    }

    func handleKnowledgeBaseDidChange() {
        guard let latestEntry = knowledgeBaseStore.entries()
            .sorted(by: { ($0.lastRefreshedAt ?? $0.importedAt) > ($1.lastRefreshedAt ?? $1.importedAt) })
            .first else {
            return
        }

        let preview = trimmedPreview(latestEntry.preview, limit: 180)
        recordSignal(
            AskPresenceSignal(
                id: UUID().uuidString.lowercased(),
                kind: .knowledgeBase,
                reason: .knowledgeUpdate,
                recordedAt: nowProvider(),
                title: latestEntry.title,
                summary: preview,
                dedupeKey: "knowledge:\(latestEntry.id)",
                confidence: 0.58,
                sourceBundleID: nil,
                sourceAppName: nil,
                sessionOrigin: .user,
                invocationSurface: .proactivePopup,
                requestedMode: .interactive,
                compatibilityPersistenceKey: nil,
                suggestedPrompt: AppLanguage.from(languageCode: AppSettings.shared.appLanguage.languageCode) == .english
                    ? "Use the latest knowledge update and help me act on it."
                    : "基于刚刚更新的知识内容继续帮我处理。",
                metadata: [
                    "knowledge_title": latestEntry.title,
                    "selection_preview": preview
                ]
            )
        )
    }

    func handleCalendarActivity(
        title: String,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = trimmedPreview(summary, limit: 180)
        guard !trimmedTitle.isEmpty || !trimmedSummary.isEmpty else { return }

        let resolvedTitle = trimmedTitle.isEmpty
            ? L10n.text(zhHans: "有新的日程结果", en: "New schedule result")
            : trimmedTitle
        let dedupeSeed = metadata["calendar_activity_id"] ?? "\(resolvedTitle)|\(trimmedSummary)"
        recordSignal(
            AskPresenceSignal(
                id: UUID().uuidString.lowercased(),
                kind: .calendarResult,
                reason: .calendarSuggestion,
                recordedAt: nowProvider(),
                title: resolvedTitle,
                summary: trimmedSummary,
                dedupeKey: "calendar:\(dedupeSeed)",
                confidence: 0.9,
                sourceBundleID: "com.apple.iCal",
                sourceAppName: L10n.text(zhHans: "日历", en: "Calendar"),
                sessionOrigin: .assistantFollowUp,
                invocationSurface: .proactivePopup,
                requestedMode: .interactive,
                compatibilityPersistenceKey: nil,
                suggestedPrompt: AppLanguage.from(languageCode: AppSettings.shared.appLanguage.languageCode) == .english
                    ? "Use the latest schedule result and help me decide what to do next."
                    : "基于最新的日程结果继续，并告诉我下一步该怎么做。",
                metadata: metadata
            )
        )
    }

    func handleNotificationActivation(_ activation: AskAssistantFollowUpActivation) {
        recordSignal(
            AskPresenceSignal(
                id: UUID().uuidString.lowercased(),
                kind: .notificationActivation,
                reason: .notificationFollowUp,
                recordedAt: nowProvider(),
                title: activation.title,
                summary: activation.summary,
                dedupeKey: "notification:\(activation.persistenceKey ?? activation.title)",
                confidence: 0.94,
                sourceBundleID: nil,
                sourceAppName: nil,
                sessionOrigin: activation.sessionOrigin,
                invocationSurface: .proactivePopup,
                requestedMode: activation.requestedMode,
                compatibilityPersistenceKey: activation.persistenceKey,
                suggestedPrompt: activation.suggestedPrompt(responseLanguage: AppSettings.shared.appLanguage.languageCode),
                metadata: activation.initialKernelMetadata
            )
        )
    }

    func tryCaptureBrowserPage(for bundleID: String?) {
        guard let browserPageCaptureProvider else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let result = await browserPageCaptureProvider(bundleID) else {
                return
            }
            self.handleBrowserPageCapture(result)
        }
    }

    private func recordSignal(_ signal: AskPresenceSignal) {
        let interruptibility = AskInterruptibilitySnapshot(
            isFrontmostFullScreen: fullScreenStatusProvider(),
            secondsSinceLastUserInteraction: nowProvider().timeIntervalSince(lastUserInteractionAt),
            isAskVisible: isAskVisible,
            isAskStreaming: isAskStreaming,
            hasPendingApproval: hasPendingApproval,
            isProactivePopupVisible: state.isProactivePopupVisible
        )
        guard let decision = policyEngine.evaluate(
            signal: signal,
            interruptibility: interruptibility,
            suppressionState: suppressionState
        ) else {
            return
        }

        state.lastSignalAt = signal.recordedAt
        if decision.shouldKeepUnread {
            state.unreadOpportunity = decision.opportunity
            suppressionState.lastQueuedAtByDedupeKey[signal.dedupeKey] = signal.recordedAt
        }

        diagnosticsLogger.log(
            "ask.presence",
            "signal=\(signal.kind.rawValue) reason=\(signal.reason.rawValue) present=\(decision.shouldPresentImmediately) dedupe=\(signal.dedupeKey)"
        )

        if decision.shouldPresentImmediately {
            state.latestPresentedOpportunityID = decision.opportunity.id
            state.latestPresentedReason = decision.opportunity.reason
            state.latestPresentedAt = signal.recordedAt
            suppressionState.lastPresentedAtByDedupeKey[signal.dedupeKey] = signal.recordedAt
            onOpportunityReady?(decision.opportunity, .statusItemPopup)
        }
        publishState()
    }

    private func pollClipboardIfNeeded() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = changeCount
        guard let text = SelectionAccess.readPasteboardText() else { return }
        let preview = trimmedPreview(text, limit: 180)
        guard !preview.isEmpty, preview != lastClipboardPreview else { return }
        lastClipboardPreview = preview
        recordSignal(
            AskPresenceSignal(
                id: UUID().uuidString.lowercased(),
                kind: .clipboard,
                reason: .clipboardSuggestion,
                recordedAt: nowProvider(),
                title: L10n.text(zhHans: "你刚复制了一段内容", en: "You just copied something"),
                summary: preview,
                dedupeKey: "clipboard:\(preview)",
                confidence: preview.count >= 20 ? 0.63 : 0.52,
                sourceBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                sourceAppName: NSWorkspace.shared.frontmostApplication?.localizedName,
                sessionOrigin: .user,
                invocationSurface: .proactivePopup,
                requestedMode: .interactive,
                compatibilityPersistenceKey: nil,
                suggestedPrompt: AppLanguage.from(languageCode: AppSettings.shared.appLanguage.languageCode) == .english
                    ? "Use the latest clipboard content and help me continue from it."
                    : "基于我刚复制的内容继续帮我处理。",
                metadata: [
                    "selection_preview": preview
                ]
            )
        )
    }

    private func publishState() {
        onStateChanged?(state)
    }

    private func registerInteractionMonitors() {
        localInteractionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.registerUserInteraction()
            }
            return event
        }
        globalInteractionMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.registerUserInteraction()
            }
        }
    }

    private func trimmedPreview(_ text: String, limit: Int) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(limit)
            .description
    }

    private static func defaultFullScreenStatus() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return false }
        let ownerPID = frontmostApp.processIdentifier
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return false
        }

        for info in infoList {
            guard let windowOwnerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  windowOwnerPID == ownerPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsValue = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsValue) else {
                continue
            }
            let cocoaBounds = CGRect(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.width,
                height: bounds.height
            )
            guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(cocoaBounds) }) else {
                continue
            }
            let screenFrame = screen.frame.insetBy(dx: 2, dy: 2)
            if cocoaBounds.width >= screenFrame.width && cocoaBounds.height >= screenFrame.height {
                return true
            }
        }
        return false
    }
}

#endif
