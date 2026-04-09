import AppKit
import NexShared
import UserNotifications

final class AskProductExperienceController: NSObject, AppProductExperienceController {
    private enum SmokeNotificationAction: String {
        case runAsk
        case openAssistantFollowUp
        case dumpAskState
        case recordAutomationRun
        case saveInboxItem
    }

    private let runtime: NexHubRuntime
    private lazy var askSessionService = AskSessionService()
    private lazy var askPresenceBrowserPageCaptureService = BrowserPageCaptureService()
    private lazy var askConversationController = AskConversationWindowController(
        askSessionService: askSessionService,
        diagnosticsLogger: runtime.diagnosticsLogger
    )
    private lazy var askPresenceCoordinator = AskPresenceCoordinator(
        diagnosticsLogger: runtime.diagnosticsLogger,
        browserPageCaptureProvider: { [weak self] bundleID in
            guard let self else { return nil }
            switch await self.askPresenceBrowserPageCaptureService.captureReadableCurrentPage(fromBundleID: bundleID) {
            case .success(let result):
                return result
            case .failure:
                return nil
            }
        }
    )
    private lazy var askBoxSelectionController = AskBoxSelectionOverlayController()
    private lazy var askBoxInputInterceptor = AskBoxInputInterceptor(
        diagnosticsLogger: runtime.diagnosticsLogger,
        isEnabled: { [unowned self] in
            AppProductProfile.current.supportsConversationBoxEntry && self.runtime.settings.conversationBoxEnabled
        },
        shouldBeginCapture: { [unowned self] in
            AppProductProfile.current.supportsConversationBoxEntry
                && self.runtime.settings.conversationBoxEnabled
                && !self.runtime.isScreenshotSelectionActive
                && !self.isSelectionOverlayActive
        },
        onCaptureBegan: { [unowned self] point in
            self.handleAskBoxCaptureBegan(at: point)
        },
        onCaptureChanged: { [unowned self] point in
            self.handleAskBoxCaptureChanged(to: point)
        },
        onCaptureEnded: { [unowned self] point in
            self.handleAskBoxCaptureEnded(at: point)
        },
        onCaptureCancelled: { [unowned self] in
            self.handleAskBoxCaptureCancelled()
        }
    )

    private var pendingSourceBundleID: String?
    private var pendingSourceAppName: String?
    private var selectionOverlayActive = false

    init(runtime: NexHubRuntime) {
        self.runtime = runtime
        super.init()
    }

    var isSelectionOverlayActive: Bool { selectionOverlayActive }
    var isConversationVisible: Bool {
        AppProductProfile.current.supportsConversationExperience && askConversationController.isVisible
    }

    func applicationDidFinishLaunching() {
        configureCallbacks()
        registerObservers()
        if AppProductProfile.current.supportsConversationPresence {
            askPresenceCoordinator.start()
        }
        if AppProductProfile.current.supportsAutomationFeatures {
            AskAutomationScheduler.shared.start()
        }
        if AppProductProfile.current.supportsConversationBoxEntry {
            askBoxSelectionController.prepare()
        }
        syncPresenceState()
    }

    func applicationWillTerminate() {
        if AppProductProfile.current.supportsConversationBoxEntry {
            askBoxInputInterceptor.stop()
        }
        if AppProductProfile.current.supportsConversationExperience {
            dismissConversation()
        }
        removeObservers()
        if AppProductProfile.current.supportsAutomationFeatures {
            AskAutomationScheduler.shared.stop()
        }
        if AppProductProfile.current.supportsConversationPresence {
            askPresenceCoordinator.stop()
        }
    }

    func handleSelectionSnapshot(_ snapshot: SelectionSnapshot) {
        askPresenceCoordinator.handleSelectionSnapshot(snapshot)
    }

    func handleSelectionCleared() {}

    func handleFileSelectionSnapshot(_ snapshot: FileSelectionSnapshot) {
        askPresenceCoordinator.handleFinderSelection(snapshot)
    }

    func handleKnowledgeBaseDidChange() {
        guard AppProductProfile.current.supportsConversationPresence else { return }
        askPresenceCoordinator.handleKnowledgeBaseDidChange()
    }

    func handleApplicationDidBecomeActive() {
        guard AppProductProfile.current.supportsConversationBoxEntry else { return }
        askPresenceCoordinator.registerUserInteraction()
        guard runtime.settings.conversationBoxEnabled,
              runtime.permissionManager.isAccessibilityTrusted(),
              !askBoxInputInterceptor.isMonitoring else {
            return
        }
        runtime.diagnosticsLogger.log("ask.entry", "retrying event taps on app activation")
        askBoxInputInterceptor.start()
    }

    func handleRuntimeSettingsChanged() {
        let productProfile = AppProductProfile.current
        if productProfile.supportsConversationBoxEntry {
            if runtime.settings.conversationBoxEnabled {
                askBoxInputInterceptor.start()
            } else {
                askBoxInputInterceptor.stop()
                dismissSelection()
            }
        } else if selectionOverlayActive {
            dismissSelection()
        }
    }

    func dismissSelection() {
        handleAskBoxCaptureCancelled()
    }

    func dismissConversation() {
        askConversationController.hide()
        syncPresenceState()
    }

    func contains(screenPoint: CGPoint) -> Bool {
        guard AppProductProfile.current.supportsConversationExperience else { return false }
        return askConversationController.contains(screenPoint: screenPoint)
    }

    @discardableResult
    func presentPrimaryStatusItemExperience(anchorFrame: CGRect?) -> Bool {
        guard AppProductProfile.current.supportsConversationMenuBarEntry else { return false }
        askPresenceCoordinator.registerUserInteraction()
        let targetFrame = runtime.statusItemPopupFrame(anchorFrame: anchorFrame)

        if let unreadOpportunity = askPresenceCoordinator.takeUnreadOpportunity() {
            askConversationController.presentProactiveAskContact(
                unreadOpportunity,
                targetFrame: targetFrame,
                fallbackFrame: targetFrame
            )
            syncPresenceState()
            return true
        }

        askConversationController.beginPersistentAskSession(
            frame: targetFrame,
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            sourceAppName: NSWorkspace.shared.frontmostApplication?.localizedName,
            sessionOrigin: .user,
            invocationSurface: .menuBar,
            requestedMode: .interactive
        )
        syncPresenceState()
        return true
    }

    func beginAskAssistantFollowUp(from item: AskInboxItem) {
        guard let activation = item.assistantFollowUpActivation else { return }
        beginAskAssistantFollowUp(from: activation)
    }

    func beginAskAssistantFollowUp(from activation: AskAssistantFollowUpActivation) {
        guard AppProductProfile.current.supportsConversationExperience else { return }
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 240, y: 220, width: 960, height: 720)
        let targetSize = AskWindowGeometry.minimumSize
        let targetFrame = NSRect(
            x: visibleFrame.midX - targetSize.width / 2,
            y: visibleFrame.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        askPresenceCoordinator.registerUserInteraction()
        askConversationController.beginPersistentAskSession(
            frame: targetFrame,
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: nil,
            sourceAppName: nil,
            initialKernelMetadata: activation.initialKernelMetadata,
            sessionOrigin: activation.sessionOrigin,
            invocationSurface: activation.invocationSurface,
            requestedMode: activation.requestedMode,
            captureLiveSelection: false,
            compatibilityPersistenceKey: activation.persistenceKey,
            suggestedPrompt: activation.suggestedPrompt(responseLanguage: AppSettings.shared.appLanguage.languageCode)
        )
        syncPresenceState()
    }

    func handleAskBoxCaptureBegan(at point: CGPoint) {
        guard AppProductProfile.current.supportsConversationBoxEntry, runtime.settings.conversationBoxEnabled else { return }
        askPresenceCoordinator.registerUserInteraction()
        let captureStartedAt = CFAbsoluteTimeGetCurrent()
        runtime.prepareForConversationSelectionCapture()
        let afterRuntimeReset = CFAbsoluteTimeGetCurrent()
        askConversationController.hide()
        let afterHideAsk = CFAbsoluteTimeGetCurrent()

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        pendingSourceBundleID = frontmostApp?.bundleIdentifier
        pendingSourceAppName = frontmostApp?.localizedName
        selectionOverlayActive = true
        askBoxSelectionController.begin(at: point)
        runtime.diagnosticsLogger.log("ask.entry", "overlay begin bundle=\(pendingSourceBundleID ?? "unknown")")
        runtime.diagnosticsLogger.log(
            "ask.entry",
            """
            capture began point=(\(Int(point.x)),\(Int(point.y))) total_ms=\(elapsedMilliseconds(since: captureStartedAt)) \
            runtimeReset_ms=\(elapsedMilliseconds(from: captureStartedAt, to: afterRuntimeReset)) \
            hideAsk_ms=\(elapsedMilliseconds(from: afterRuntimeReset, to: afterHideAsk)) \
            beginOverlay_ms=\(elapsedMilliseconds(from: afterHideAsk, to: CFAbsoluteTimeGetCurrent()))
            """
        )
    }

    func handleAskBoxCaptureChanged(to point: CGPoint) {
        guard selectionOverlayActive else { return }
        askBoxSelectionController.updateCurrentPoint(point)
    }

    func handleAskBoxCaptureEnded(at point: CGPoint) {
        guard selectionOverlayActive else { return }
        let finishedAt = CFAbsoluteTimeGetCurrent()
        let selection = askBoxSelectionController.finish(at: point)
        selectionOverlayActive = false
        guard let selection else { return }
        runtime.diagnosticsLogger.log(
            "ask.entry",
            "capture ended point=(\(Int(point.x)),\(Int(point.y))) rect=(\(Int(selection.rect.minX)),\(Int(selection.rect.minY)),\(Int(selection.rect.width))x\(Int(selection.rect.height))) finish_ms=\(elapsedMilliseconds(since: finishedAt))"
        )
        beginAskConversation(from: selection)
    }

    func handleAskBoxCaptureCancelled() {
        askBoxSelectionController.cancel()
        selectionOverlayActive = false
        pendingSourceBundleID = nil
        pendingSourceAppName = nil
    }

    func beginAskConversation(from selection: AskBoxSelection) {
        guard AppProductProfile.current.supportsConversationExperience else { return }
        let startedAt = CFAbsoluteTimeGetCurrent()
        askPresenceCoordinator.registerUserInteraction()
        askConversationController.beginPersistentAskSession(
            frame: selection.rect,
            transitionStartPoint: selection.startPoint,
            transitionEndPoint: selection.endPoint,
            sourceBundleID: pendingSourceBundleID,
            sourceAppName: pendingSourceAppName,
            invocationSurface: .askBox
        )
        syncPresenceState()
        runtime.diagnosticsLogger.log(
            "ask.entry",
            "begin session rect=(\(Int(selection.rect.minX)),\(Int(selection.rect.minY)),\(Int(selection.rect.width))x\(Int(selection.rect.height))) beginSession_ms=\(elapsedMilliseconds(since: startedAt))"
        )
        pendingSourceBundleID = nil
        pendingSourceAppName = nil
    }

    private func configureCallbacks() {
        askPresenceCoordinator.onOpportunityReady = { [weak self] opportunity, _ in
            guard let self else { return }
            let anchorFrame = self.runtime.statusItemAnchorFrame()
            let targetFrame = self.runtime.statusItemPopupFrame(anchorFrame: anchorFrame)
            self.askConversationController.presentProactiveAskContact(
                opportunity,
                targetFrame: targetFrame,
                fallbackFrame: targetFrame
            )
            self.syncPresenceState()
        }
        askConversationController.onVisibilityChanged = { [weak self] isVisible in
            guard let self else { return }
            if !isVisible {
                self.pendingSourceBundleID = nil
                self.pendingSourceAppName = nil
            }
            self.syncPresenceState()
        }
    }

    private func registerObservers() {
        let notificationCenter = NotificationCenter.default
        if AppProductProfile.current.supportsConversationExperience {
            notificationCenter.addObserver(
                self,
                selector: #selector(handleOpenAssistantFollowUpNotification(_:)),
                name: .nexhubOpenAssistantFollowUp,
                object: nil
            )
        }
        if AppProductProfile.current.supportsConversationPresence {
            notificationCenter.addObserver(
                self,
                selector: #selector(handleAskInboxDidChange),
                name: .askInboxDidChange,
                object: nil
            )
            notificationCenter.addObserver(
                self,
                selector: #selector(handleAskAutomationRunsDidChange),
                name: .askAutomationRunsDidChange,
                object: nil
            )
            notificationCenter.addObserver(
                self,
                selector: #selector(handleAskCalendarActivityDidChange(_:)),
                name: .productCalendarActivityDidChange,
                object: nil
            )
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(handleWorkspaceDidActivateApplication(_:)),
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil
            )
        }
        if AppProductProfile.current.supportsConversationExperience {
            addSmokeObserver(.runAsk, selector: #selector(handleSmokeRunAskNotification(_:)))
            addSmokeObserver(.openAssistantFollowUp, selector: #selector(handleSmokeOpenAssistantFollowUpNotification(_:)))
            addSmokeObserver(.dumpAskState, selector: #selector(handleSmokeDumpAskStateNotification(_:)))
        }
        if AppProductProfile.current.supportsAutomationFeatures {
            addSmokeObserver(.recordAutomationRun, selector: #selector(handleSmokeRecordAutomationRunNotification(_:)))
        }
        if AppProductProfile.current.supportsConversationPresence {
            addSmokeObserver(.saveInboxItem, selector: #selector(handleSmokeSaveInboxItemNotification(_:)))
        }
    }

    private func removeObservers() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if AppProductProfile.current.supportsConversationExperience {
            removeSmokeObserver(.runAsk)
            removeSmokeObserver(.openAssistantFollowUp)
            removeSmokeObserver(.dumpAskState)
        }
        if AppProductProfile.current.supportsAutomationFeatures {
            removeSmokeObserver(.recordAutomationRun)
        }
        if AppProductProfile.current.supportsConversationPresence {
            removeSmokeObserver(.saveInboxItem)
        }
    }

    private func addSmokeObserver(_ action: SmokeNotificationAction, selector: Selector) {
        let center = DistributedNotificationCenter.default()
        for name in AppBrand.smokeNotificationNames(action.rawValue) {
            center.addObserver(self, selector: selector, name: name, object: nil)
        }
    }

    private func removeSmokeObserver(_ action: SmokeNotificationAction) {
        let center = DistributedNotificationCenter.default()
        for name in AppBrand.smokeNotificationNames(action.rawValue) {
            center.removeObserver(self, name: name, object: nil)
        }
    }

    @objc private func handleOpenAssistantFollowUpNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let activation = assistantFollowUpActivation(from: userInfo) else {
            return
        }
        beginAskAssistantFollowUp(from: activation)
    }

    @objc private func handleAskInboxDidChange() {
        guard AppProductProfile.current.supportsConversationPresence else { return }
        askPresenceCoordinator.handleInboxDidChange()
    }

    @objc private func handleAskAutomationRunsDidChange() {
        guard AppProductProfile.current.supportsConversationPresence else { return }
        askPresenceCoordinator.handleAutomationRunsDidChange()
    }

    @objc private func handleAskCalendarActivityDidChange(_ notification: Notification) {
        guard AppProductProfile.current.supportsConversationPresence else { return }
        let title = (notification.userInfo?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = (notification.userInfo?["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let metadata = notification.userInfo?["metadata"] as? [String: String] ?? [:]
        askPresenceCoordinator.handleCalendarActivity(
            title: title,
            summary: summary,
            metadata: metadata
        )
    }

    @objc private func handleWorkspaceDidActivateApplication(_ notification: Notification) {
        guard AppProductProfile.current.supportsConversationPresence else { return }
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        askPresenceCoordinator.registerUserInteraction()
        askPresenceCoordinator.handleFrontmostApplicationDidChange(app)
        askPresenceCoordinator.tryCaptureBrowserPage(for: app?.bundleIdentifier)
    }

    @objc private func handleSmokeRunAskNotification(_ notification: Notification) {
        guard AppProductProfile.current.supportsConversationExperience else { return }
        let prompt = ((notification.userInfo?["prompt"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let shouldSubmit = smokeBooleanValue(notification.userInfo?["submit"], defaultValue: true)
        let reuseVisibleConversation = smokeBooleanValue(notification.userInfo?["reuse_visible"], defaultValue: false)
        let usePersistentAskSession = smokeBooleanValue(notification.userInfo?["persistent_session"], defaultValue: false)
        guard !prompt.isEmpty || !shouldSubmit else {
            return
        }

        let traceFilePath = (notification.userInfo?["trace_file"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if reuseVisibleConversation, askConversationController.isVisible {
            if !shouldSubmit {
                if !prompt.isEmpty {
                    askConversationController.prepareSmokePrompt(
                        prompt,
                        traceFilePath: traceFilePath
                    )
                }
                return
            }
            if let response = (notification.userInfo?["response"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !response.isEmpty {
                let chunkSize = max(1, smokeIntegerValue(notification.userInfo?["chunk_size"], defaultValue: 8))
                let chunkIntervalMilliseconds = max(
                    1,
                    smokeIntegerValue(notification.userInfo?["chunk_interval_ms"], defaultValue: 16)
                )
                askConversationController.runSyntheticSmokeReply(
                    prompt: prompt,
                    response: response,
                    chunkSize: chunkSize,
                    chunkInterval: Double(chunkIntervalMilliseconds) / 1000,
                    traceFilePath: traceFilePath
                )
                return
            }
            askConversationController.runSmokePrompt(
                prompt,
                traceFilePath: traceFilePath
            )
            return
        }

        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 240, y: 220, width: 960, height: 720)
        let defaultTargetSize = AskWindowGeometry.minimumSize
        let defaultOrigin = NSPoint(
            x: visibleFrame.midX - defaultTargetSize.width / 2,
            y: visibleFrame.midY - defaultTargetSize.height / 2
        )
        let requestedFrame = smokeRectValue(notification.userInfo, visibleFrame: visibleFrame)
            ?? NSRect(origin: defaultOrigin, size: defaultTargetSize)
        let transitionStartPoint = smokePointValue(notification.userInfo, xKey: "start_x", yKey: "start_y")
        let transitionEndPoint = smokePointValue(notification.userInfo, xKey: "end_x", yKey: "end_y")

        if usePersistentAskSession {
            askConversationController.beginPersistentAskSession(
                frame: requestedFrame,
                transitionStartPoint: transitionStartPoint,
                transitionEndPoint: transitionEndPoint,
                sourceBundleID: AppBrand.smokeSourceBundleIdentifier,
                sourceAppName: "Smoke",
                sessionOrigin: .user,
                invocationSurface: .askWindow
            )
        } else {
            askConversationController.beginNewSession(
                frame: requestedFrame,
                transitionStartPoint: transitionStartPoint,
                transitionEndPoint: transitionEndPoint,
                sourceBundleID: AppBrand.smokeSourceBundleIdentifier,
                sourceAppName: "Smoke"
            )
        }
        syncPresenceState()
        if !shouldSubmit {
            if !prompt.isEmpty {
                askConversationController.prepareSmokePrompt(
                    prompt,
                    traceFilePath: traceFilePath
                )
            }
            return
        }
        if let response = (notification.userInfo?["response"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !response.isEmpty {
            let chunkSize = max(1, smokeIntegerValue(notification.userInfo?["chunk_size"], defaultValue: 8))
            let chunkIntervalMilliseconds = max(
                1,
                smokeIntegerValue(notification.userInfo?["chunk_interval_ms"], defaultValue: 16)
            )
            askConversationController.runSyntheticSmokeReply(
                prompt: prompt,
                response: response,
                chunkSize: chunkSize,
                chunkInterval: Double(chunkIntervalMilliseconds) / 1000,
                traceFilePath: traceFilePath
            )
            return
        }
        askConversationController.runSmokePrompt(
            prompt,
            traceFilePath: traceFilePath
        )
    }

    @objc private func handleSmokeOpenAssistantFollowUpNotification(_ notification: Notification) {
        guard let payload = notification.userInfo?["assistant_followup_activation_payload"] as? String,
              let activation = AskAssistantFollowUpActivation.decodePayload(payload) else {
            return
        }
        beginAskAssistantFollowUp(from: activation)
    }

    @objc private func handleSmokeDumpAskStateNotification(_ notification: Notification) {
        guard let rawPath = notification.userInfo?["file_path"] as? String else { return }
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }
        askConversationController.configureSmokeStateSnapshot(filePath: trimmedPath)
        askConversationController.writeSmokeStateSnapshot(to: URL(fileURLWithPath: trimmedPath))
    }

    @objc private func handleSmokeRecordAutomationRunNotification(_ notification: Notification) {
        guard let payload = notification.userInfo?["automation_run_payload"] as? String,
              let data = payload.data(using: .utf8) else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let run = try? decoder.decode(AskAutomationRunRecord.self, from: data) else {
            return
        }
        AskAutomationStore.shared.recordRun(run)
    }

    @objc private func handleSmokeSaveInboxItemNotification(_ notification: Notification) {
        guard let payload = notification.userInfo?["inbox_item_payload"] as? String,
              let data = payload.data(using: .utf8) else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let item = try? decoder.decode(AskInboxItem.self, from: data) else {
            return
        }
        AskInboxStore.shared.save(item)
    }

    private func assistantFollowUpActivation(from userInfo: [AnyHashable: Any]) -> AskAssistantFollowUpActivation? {
        guard let payload = userInfo["assistant_followup_activation_payload"] as? String else {
            return nil
        }
        return AskAssistantFollowUpActivation.decodePayload(payload)
    }

    private func syncPresenceState() {
        guard AppProductProfile.current.supportsConversationPresence else { return }
        askPresenceCoordinator.updatePrimarySessionID(askConversationController.currentPersistentAskSessionID)
        askPresenceCoordinator.updateAskWindowState(
            isVisible: askConversationController.isVisible,
            isStreaming: askConversationController.isStreamingForPresence,
            hasPendingApproval: askConversationController.hasPendingApprovalForPresence,
            isProactivePopupVisible: askConversationController.isShowingProactivePopup
        )
    }

    private func elapsedMilliseconds(since start: CFAbsoluteTime) -> Int {
        Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
    }

    private func elapsedMilliseconds(from start: CFAbsoluteTime, to end: CFAbsoluteTime) -> Int {
        Int(((end - start) * 1000).rounded())
    }

    private func smokeIntegerValue(_ value: Any?, defaultValue: Int) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String,
           let parsed = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return defaultValue
    }

    private func smokeBooleanValue(_ value: Any?, defaultValue: Bool) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "y", "on":
                return true
            case "0", "false", "no", "n", "off":
                return false
            default:
                break
            }
        }
        return defaultValue
    }

    private func smokeDoubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func smokePointValue(_ userInfo: [AnyHashable: Any]?, xKey: String, yKey: String) -> CGPoint? {
        guard let x = smokeDoubleValue(userInfo?[xKey]),
              let y = smokeDoubleValue(userInfo?[yKey]) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    private func smokeRectValue(_ userInfo: [AnyHashable: Any]?, visibleFrame: CGRect) -> CGRect? {
        guard let x = smokeDoubleValue(userInfo?["frame_x"]),
              let y = smokeDoubleValue(userInfo?["frame_y"]),
              let width = smokeDoubleValue(userInfo?["frame_width"]),
              let height = smokeDoubleValue(userInfo?["frame_height"]) else {
            return nil
        }

        let requested = CGRect(x: x, y: y, width: width, height: height)
        return requested.isNull || requested.isEmpty ? visibleFrame : requested
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        guard let activation = assistantFollowUpActivation(from: userInfo) else {
            return
        }
        Task { @MainActor [weak self] in
            self?.beginAskAssistantFollowUp(from: activation)
        }
    }
}

public enum NexAskProductBootstrap {
    public static func register() {
        AppProductFeatureRegistry.makeExperienceController = { runtime in
            AskProductExperienceController(runtime: runtime)
        }
        AppProductFeatureRegistry.makeAutomationPageView = {
            AskSettingsAutomationPageView(frame: .zero)
        }
    }
}
