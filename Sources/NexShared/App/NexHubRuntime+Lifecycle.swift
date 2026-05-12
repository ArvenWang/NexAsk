import AppKit
import UserNotifications

private enum SmokeNotificationAction: String {
    case openSettings
}

extension NexHubRuntime {
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

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let productProfile = AppProductProfile.current
        applyApplicationIcon()
        setupStatusBar()
        appUpdateCoordinator.startIfConfigured()
        refreshUpdateMenuItemBinding()
        reconcileLaunchAtLoginStatus()
        ensureDefaultLaunchAtLoginIfNeeded()
        setupObservers()
        setupSettingsCallbacks()
        if productProfile.supportsGlobalInputEventMonitoring {
            setupEventMonitors()
        }
        SkillHotReloadCoordinator.shared.start()
        if productProfile.supportsConversationExperience {
            UNUserNotificationCenter.current().delegate = productExperienceController
        }

        configureDelegates()
        configureResultPanelCallbacks()
        if productProfile.supportsScreenshotEntry {
            configureScreenshotCallbacks()
        }
        productExperienceController.applicationDidFinishLaunching()

        commerceService.start()
        ReplyKnowledgeBaseAutoSyncCoordinator.shared.start()
        let shouldPromptAccessibility = productProfile.requiresAccessibilityPermission
            && !permissionManager.isAccessibilityTrusted()
        _ = permissionManager.requestAccessibilityTrust(prompt: shouldPromptAccessibility)
        if productProfile.supportsScreenshotEntry {
            screenshotSelectionController.prepare()
            logScreenshotPlatformBaseline()
        }
        applyRuntimeSettings()
        startBackgroundRuntimeTasks()
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        selectionPresentationCoordinator.cancelPendingPresentation()
        inputEventCoordinator.stop()
        productExperienceController.applicationWillTerminate()
        screenshotHotkeyMonitor.stop()
        SkillHotReloadCoordinator.shared.stop()

        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeSmokeObserver(.openSettings)
        ReplyKnowledgeBaseAutoSyncCoordinator.shared.stop()
        gatewayRuntime.stopIfStartedByApp()
    }

    func applyApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let iconImage = NSImage(contentsOf: iconURL) else {
            return
        }

        iconImage.size = NSSize(width: 1024, height: 1024)
        NSApp.applicationIconImage = iconImage
    }

    func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: .appSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCommerceStateChanged),
            name: .commerceStateDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGatewayRuntimeDidChange(_:)),
            name: .gatewayRuntimeDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKnowledgeBaseDidChange),
            name: .knowledgeBaseDidChange,
            object: nil
        )
        addSmokeObserver(.openSettings, selector: #selector(handleSmokeOpenSettingsNotification(_:)))
    }

    func configureDelegates() {
        toolbarController.delegate = self
        selectionMonitor.delegate = self
        skillInvocationCoordinator.delegate = self
        screenshotSessionCoordinator.delegate = self
    }

    func configureResultPanelCallbacks() {
        resultController.onStreamingDismissed = { [weak self] in
            self?.skillInvocationCoordinator.cancelCurrentAction(resetToolbar: true)
        }
        resultController.onRegenerateRequested = { [weak self] skillID, sourceText in
            guard let self else { return }
            self.runSkill(
                skillID,
                inputOverride: sourceText,
                anchorOverride: self.resultController.frame,
                keepConversation: false,
                preserveResultPanelPosition: true
            )
        }
        resultController.onSkillShortcutRequested = { [weak self] skillID, sourceText, followupDepth, followupSourceSkillID in
            guard let self else { return }
            self.runSkill(
                skillID,
                inputOverride: sourceText,
                anchorOverride: self.resultController.frame,
                keepConversation: false,
                preserveResultPanelPosition: true,
                followupDepth: followupDepth,
                followupSourceSkillID: followupSourceSkillID
            )
        }
    }

    func configureScreenshotCallbacks() {
        screenshotSelectionController.setMouseEventPassthroughHandler { [weak self] screenPoint in
            guard let self else { return false }
            return self.toolbarController.contains(screenPoint: screenPoint)
                || self.resultController.contains(screenPoint: screenPoint)
                || self.productExperienceController.contains(screenPoint: screenPoint)
                || self.inlinePromptController.contains(screenPoint: screenPoint)
        }
        screenshotScrollCoordinator.onStateChanged = { [weak self] state in
            self?.diagnosticsLogger.log("screenshot.scroll", "state=\(String(describing: state))")
            guard let self else { return }
            self.screenshotSessionCoordinator.handleScrollStateChanged(
                state,
                currentImageSnapshot: self.currentImageSnapshot
            )
        }
        screenshotScrollCoordinator.onPreviewUpdated = { [weak self] image in
            guard let self,
                  case .capturing = self.screenshotScrollCoordinator.state,
                  let selectionRect = self.currentImageSnapshot?.selectionRect else {
                self?.screenshotScrollPreviewController.hide()
                return
            }
            self.screenshotScrollPreviewController.update(image: image, near: selectionRect)
        }
    }

    func startBackgroundRuntimeTasks() {
        Task.detached(priority: .utility) {
            GatewayRuntimeManager.shared.startIfNeeded()
            let snapshot = GatewayRuntimeManager.shared.currentSnapshot()
            if snapshot.phase != .starting {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .gatewayRuntimeDidChange, object: snapshot)
                }
            }
        }
        Task {
            let snapshot = await SkillCatalogService.shared.refreshCatalog()
            SkillRegistry.shared.setCatalogSnapshot(snapshot)
        }
    }

    func logScreenshotPlatformBaseline() {
        let missing = screenshotFeaturePlatform.missingTargetCapabilities.map(\.rawValue).joined(separator: ",")
        diagnosticsLogger.log(
            "screenshot.platform",
            "capture=\(screenshotFeaturePlatform.captureEngine.identifier) scrolling=\(screenshotFeaturePlatform.scrollingEngine.identifier) annotation=\(screenshotFeaturePlatform.annotationEngine.identifier) ocr=\(screenshotFeaturePlatform.ocrService.identifier) export=\(screenshotFeaturePlatform.exportPipeline.identifier) missing=[\(missing)]"
        )
    }

    func setupSettingsCallbacks() {
        settingsWindowShell.onRequestLaunchAtLoginToggle = { [weak self] enabled in
            self?.setLaunchAtLogin(enabled)
        }
        settingsWindowShell.onRequestTriggerScreenshotCapture = { [weak self] in
            self?.triggerScreenshotCaptureFlow()
        }
    }

    func setupEventMonitors() {
        guard AppProductProfile.current.supportsGlobalInputEventMonitoring else {
            inputEventCoordinator.stop()
            return
        }
        inputEventCoordinator.start()
    }

    @objc func handleSettingsChanged() {
        applyRuntimeSettings()
    }

    @objc func handleCommerceStateChanged() {
        refreshToolbarSkillLineup(
            textSnapshot: currentSnapshot,
            fileSnapshot: currentFileSnapshot,
            imageSnapshot: currentImageSnapshot
        )
    }

    @objc func handleApplicationDidBecomeActive() {
        resultController.restorePersistentStreamingPresentationIfNeeded()
        toolbarController.restoreLoadingPresentationIfNeeded()
        productExperienceController.handleApplicationDidBecomeActive()
    }

    @objc func handleSmokeOpenSettingsNotification(_ notification: Notification) {
        guard let rawTab = notification.userInfo?["tab"] as? String,
              let tab = smokeSettingsTab(for: rawTab) else { return }
        presentSettings(tab: tab)
    }

    @objc func handleKnowledgeBaseDidChange() {
        productExperienceController.handleKnowledgeBaseDidChange()
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

    private func smokeSettingsTab(for rawValue: String) -> SettingsShellTab? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ai":
            return .ai
        case "privacy":
            return .privacy
        case "knowledgebase", "knowledge_base", "knowledge-base":
            return .knowledgeBase
        case "skills":
            return .skills
        case "general":
            return .general
        case "shortcuts":
            return .shortcuts
        case "membership":
            return .membership
        case "stats":
            return .stats
        case "automation":
            return .automation
        default:
            return nil
        }
    }

    func applyRuntimeSettings() {
        let productProfile = AppProductProfile.current
        autoToolbarMenuItem?.state = settings.textSelectionEnabled ? .on : .off
        configureScreenshotHotkey()
        productExperienceController.handleRuntimeSettingsChanged()
        refreshToolbarSkillLineup(
            textSnapshot: currentSnapshot,
            fileSnapshot: currentFileSnapshot,
            imageSnapshot: currentImageSnapshot
        )

        if productProfile.supportsTextSelectionEntry && settings.textSelectionEnabled {
            selectionMonitor.start()
        } else {
            selectionMonitor.stop()
            toolbarController.hide()
        }
    }

    func configureScreenshotHotkey() {
        guard AppProductProfile.current.supportsScreenshotEntry else {
            screenshotHotkeyMonitor.stop()
            return
        }
        guard settings.screenshotEnabled else {
            screenshotHotkeyMonitor.stop()
            return
        }
        let shortcut = settings.screenshotShortcut
        let consume = settings.screenshotShortcutReplaceConflicts
        screenshotHotkeyMonitor.start(shortcut: shortcut, consumeMatch: consume) { [weak self] in
            self?.triggerScreenshotCaptureFlow()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.shared.setEnabled(enabled)
            settings.launchAtLoginPreferred = enabled
        } catch {
            settings.launchAtLoginPreferred = false
            showInfoAlert(
                title: L10n.text(zhHans: "启动项设置失败", en: "Failed to update launch at login"),
                message: error.localizedDescription
            )
        }
    }

    func reconcileLaunchAtLoginStatus() {
        settings.launchAtLoginPreferred = LaunchAtLoginManager.shared.currentStatus()
    }

    func ensureDefaultLaunchAtLoginIfNeeded() {
        guard settings.didAttemptDefaultLaunchAtLoginSetup == false else { return }

        settings.didAttemptDefaultLaunchAtLoginSetup = true

        guard LaunchAtLoginManager.shared.currentStatus() == false else {
            settings.launchAtLoginPreferred = true
            return
        }

        do {
            try LaunchAtLoginManager.shared.setEnabled(true)
            settings.launchAtLoginPreferred = true
        } catch {
            settings.launchAtLoginPreferred = false
            diagnosticsLogger.log("launchAtLogin.default", "failed=\(error.localizedDescription)")
        }
    }

    @objc func handleGatewayRuntimeDidChange(_ notification: Notification) {
        guard let snapshot = notification.object as? GatewayRuntimeSnapshot else { return }
        if snapshot.isUsable {
            didPresentRuntimeStartupAlert = false
            return
        }
        guard snapshot.phase == .failed else { return }
        presentGatewayStartupAlertIfNeeded(snapshot: snapshot)
    }

    func presentGatewayStartupAlertIfNeeded(snapshot: GatewayRuntimeSnapshot) {
        guard snapshot.phase == .failed, !didPresentRuntimeStartupAlert else { return }
        didPresentRuntimeStartupAlert = true
        let alert = NSAlert()
        alert.messageText = L10n.text(
            zhHans: "本地 AI 运行时当前不可用",
            en: "The local AI runtime is currently unavailable"
        )
        alert.informativeText = "\(snapshot.userVisibleSummary)\n\n\(snapshot.recoverySuggestion)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.text(zhHans: "打开设置", en: "Open Settings"))
        alert.addButton(withTitle: L10n.text(zhHans: "稍后处理", en: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            showSettings()
        }
    }

}
