import AppKit
import EventKit
import UniformTypeIdentifiers

@MainActor
final class SettingsScreenshotShortcutCoordinator {
    private let settings: AppSettings
    private let shortcutLabel: NSTextField
    private let hintLabel: NSTextField
    private let recordButton: NSButton
    private lazy var recorder = SettingsScreenshotShortcutRecorder { [weak self] keyCode, flags in
        Task { @MainActor [weak self] in
            self?.handleRecordingEvent(keyCode: keyCode, flags: flags)
        }
    }
    private var isRecording = false

    init(
        settings: AppSettings,
        shortcutLabel: NSTextField,
        hintLabel: NSTextField,
        recordButton: NSButton
    ) {
        self.settings = settings
        self.shortcutLabel = shortcutLabel
        self.hintLabel = hintLabel
        self.recordButton = recordButton
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            beginRecording()
        }
    }

    func resetToDefault() {
        settings.screenshotShortcut = .defaultScreenshot
        settings.screenshotShortcutReplaceConflicts = false
        refreshDisplay()
    }

    func stopRecording() {
        isRecording = false
        recordButton.title = L10n.Settings.Shortcuts.recordButton
        recorder.stop()
        refreshDisplay()
    }

    func refreshDisplay() {
        let appName = AppBrand.displayName
        shortcutLabel.stringValue = ShortcutSupport.displayText(for: settings.screenshotShortcut)
        if isRecording {
            hintLabel.stringValue = L10n.text(
                key: "settings.shortcuts.hint.recording",
                zhHans: "请按组合键（至少包含一个修饰键）",
                en: "Press a shortcut with at least one modifier key."
            )
            hintLabel.textColor = DesignTokens.Settings.Status.warning
            return
        }
        if settings.screenshotShortcutReplaceConflicts {
            hintLabel.stringValue = L10n.format(
                key: "settings.shortcuts.hint.takeover_enabled",
                zhHans: "冲突策略：已启用接管模式（同键优先触发 %@）",
                en: "Conflict mode: takeover is on. %@ gets this shortcut first.",
                appName
            )
        } else {
            hintLabel.stringValue = L10n.format(
                key: "settings.shortcuts.hint.standard_mode",
                zhHans: "冲突策略：标准模式（%@ 不接管系统快捷键）",
                en: "Conflict mode: standard. %@ won't override system shortcuts.",
                appName
            )
        }
        hintLabel.textColor = DesignTokens.Settings.Status.neutral
    }

    private func beginRecording() {
        guard !recorder.isActive else { return }
        isRecording = true
        recordButton.title = L10n.text(key: "settings.shortcuts.record_button.active", zhHans: "按下新快捷键…", en: "Press new shortcut...")
        hintLabel.stringValue = L10n.text(
            key: "settings.shortcuts.hint.recording",
            zhHans: "请按组合键（至少包含一个修饰键）",
            en: "Press a shortcut with at least one modifier key."
        )
        hintLabel.textColor = DesignTokens.Settings.Status.warning
        guard recorder.start() else {
            hintLabel.stringValue = L10n.text(
                key: "settings.shortcuts.hint.recording_failed",
                zhHans: "录制失败：请先授予辅助功能权限",
                en: "Recording failed. Grant Accessibility access first."
            )
            hintLabel.textColor = DesignTokens.Settings.Status.warning
            isRecording = false
            recordButton.title = L10n.Settings.Shortcuts.recordButton
            return
        }
    }

    private func handleRecordingEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        if keyCode == 53 {
            stopRecording()
            return
        }

        let modifiers = ShortcutSupport.normalizedModifiers(flags)
        guard !modifiers.isEmpty else {
            hintLabel.stringValue = L10n.text(
                key: "settings.shortcuts.hint.requires_modifier",
                zhHans: "快捷键必须包含 ⌘ / ⇧ / ⌥ / ⌃ 中至少一个",
                en: "The shortcut must include at least one modifier: ⌘, ⇧, ⌥, or ⌃."
            )
            hintLabel.textColor = DesignTokens.Settings.Status.warning
            return
        }

        let shortcut = KeyboardShortcut(keyCode: keyCode, modifierFlags: modifiers)
        guard let replaceConflicts = resolveConflictStrategy(for: shortcut) else { return }
        settings.screenshotShortcutReplaceConflicts = replaceConflicts
        settings.screenshotShortcut = shortcut
        stopRecording()
    }

    private func resolveConflictStrategy(for shortcut: KeyboardShortcut) -> Bool? {
        let appName = AppBrand.displayName
        if let conflict = ShortcutSupport.conflict(for: shortcut) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.text(key: "settings.shortcuts.alert.conflict_title", zhHans: "检测到快捷键冲突", en: "Shortcut conflict detected")
            alert.informativeText = L10n.format(
                key: "settings.shortcuts.alert.conflict_body",
                zhHans: "%@。\n\n是否由 %@ 接管该快捷键？确认后将优先触发 %@ 截图。",
                en: "%@.\n\nLet %@ take over this shortcut? If you continue, %@ will respond first when you use it.",
                conflict.detail,
                appName,
                appName
            )
            alert.addButton(withTitle: L10n.format(key: "settings.shortcuts.alert.take_over", zhHans: "交给 %@", en: "Use in %@", appName))
            alert.addButton(withTitle: L10n.text(key: "settings.shortcuts.alert.cancel", zhHans: "取消", en: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                hintLabel.stringValue = L10n.text(key: "settings.shortcuts.hint.change_canceled", zhHans: "已取消变更", en: "Change canceled")
                hintLabel.textColor = DesignTokens.Settings.Status.neutral
                stopRecording()
                return nil
            }
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text(key: "settings.shortcuts.alert.enable_takeover_title", zhHans: "是否启用快捷键接管模式？", en: "Enable shortcut takeover?")
        alert.informativeText = L10n.format(
            key: "settings.shortcuts.alert.enable_takeover_body",
            zhHans: "该快捷键可能与其他应用冲突。启用后，%@ 会优先响应该快捷键。",
            en: "This shortcut may conflict with another app. If enabled, %@ will respond first.",
            appName
        )
        alert.addButton(withTitle: L10n.text(key: "settings.shortcuts.alert.enable_takeover", zhHans: "启用接管", en: "Enable takeover"))
        alert.addButton(withTitle: L10n.text(key: "settings.shortcuts.alert.standard_mode", zhHans: "标准模式", en: "Standard mode"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
final class SettingsPermissionCoordinator {
    private let settings: AppSettings
    private let permissionManager: PermissionManager
    private let statusLabel: NSTextField
    private let actionLabel: NSTextField
    private let diagnosticsLabel: NSTextField
    private let accessibilityRow: SettingsPermissionRowView
    private let calendarRow: SettingsPermissionRowView
    private let automationRow: SettingsPermissionRowView
    private let inputMonitoringRow: SettingsPermissionRowView
    private let screenRecordingRow: SettingsPermissionRowView
    private let filesAndFoldersRow: SettingsPermissionRowView
    private let fullDiskAccessRow: SettingsPermissionRowView
    private let activateApp: () -> Void
    private var isRefreshingAutomationStatus = false
    private var diagnosticHistory: [String] = []
    private var productProfile: AppProductProfile { .current }
    private var appName: String { AppBrand.displayName }

    init(
        settings: AppSettings,
        permissionManager: PermissionManager,
        statusLabel: NSTextField,
        actionLabel: NSTextField,
        diagnosticsLabel: NSTextField,
        accessibilityRow: SettingsPermissionRowView,
        calendarRow: SettingsPermissionRowView,
        automationRow: SettingsPermissionRowView,
        inputMonitoringRow: SettingsPermissionRowView,
        screenRecordingRow: SettingsPermissionRowView,
        filesAndFoldersRow: SettingsPermissionRowView,
        fullDiskAccessRow: SettingsPermissionRowView,
        activateApp: @escaping () -> Void
    ) {
        self.settings = settings
        self.permissionManager = permissionManager
        self.statusLabel = statusLabel
        self.actionLabel = actionLabel
        self.diagnosticsLabel = diagnosticsLabel
        self.accessibilityRow = accessibilityRow
        self.calendarRow = calendarRow
        self.automationRow = automationRow
        self.inputMonitoringRow = inputMonitoringRow
        self.screenRecordingRow = screenRecordingRow
        self.filesAndFoldersRow = filesAndFoldersRow
        self.fullDiskAccessRow = fullDiskAccessRow
        self.activateApp = activateApp
    }

    func refreshStatus(logDiagnostic: Bool = false) {
        if logDiagnostic {
            appendDiagnostic(L10n.text(zhHans: "刷新权限状态", en: "Refresh permission status"))
        }

        let readiness = permissionManager.firstUseReadinessSnapshot(
            calendarAutomationGranted: settings.calendarAutomationPermissionGranted,
            productProfile: productProfile
        )
        let accessibilityGranted = permissionManager.isAccessibilityTrusted()
        let calendarStatus = permissionManager.calendarAuthorizationStatus()
        let inputMonitoringStatus = permissionManager.inputMonitoringAuthorizationStatus()
        let screenRecordingStatus = permissionManager.screenRecordingAuthorizationStatus()
        let calendarGranted: Bool
        if #available(macOS 14.0, *) {
            calendarGranted = (calendarStatus == .fullAccess || calendarStatus == .writeOnly)
        } else {
            calendarGranted = (calendarStatus == .authorized)
        }

        let automationGranted = settings.calendarAutomationPermissionGranted
        let automationText: String
        if let automationGranted {
            automationText = automationGranted
                ? L10n.text(key: "settings.permissions.authorized", zhHans: "已授权", en: "Authorized")
                : L10n.text(key: "settings.permissions.not_authorized", zhHans: "未授权", en: "Not enabled")
        } else {
            automationText = L10n.text(key: "settings.permissions.automation_pending", zhHans: "正在检测或尚未确认", en: "Checking or waiting for confirmation")
        }

        statusLabel.stringValue = readiness.headline
        actionLabel.stringValue = readiness.actionHint

        accessibilityRow.setAuthorized(accessibilityGranted)
        accessibilityRow.setStatusNote(nil)
        calendarRow.setAuthorized(calendarGranted)
        switch calendarStatus {
        case .denied:
            calendarRow.setButtonTitle(L10n.text(zhHans: "打开设置", en: "Open Settings"))
            calendarRow.setStatusNote(L10n.text(key: "settings.permissions.calendar.denied", zhHans: "系统已拒绝日历访问，请在系统设置里手动开启。", en: "Calendar access was denied. Enable it manually in System Settings."))
        case .restricted:
            calendarRow.setButtonTitle(L10n.text(zhHans: "打开设置", en: "Open Settings"))
            calendarRow.setStatusNote(L10n.text(key: "settings.permissions.calendar.restricted", zhHans: "当前设备限制了日历访问，请先检查系统限制。", en: "Calendar access is restricted on this device. Check system restrictions first."))
        case .notDetermined:
            calendarRow.setButtonTitle(L10n.text(key: "settings.permissions.grant_access", zhHans: "授权", en: "Grant Access"))
            calendarRow.setStatusNote(L10n.text(key: "settings.permissions.calendar.first_prompt", zhHans: "首次点击会触发系统授权弹窗。", en: "The first click will trigger the system permission prompt."))
        case .authorized, .fullAccess, .writeOnly:
            calendarRow.setButtonTitle(L10n.text(key: "settings.permissions.grant_access", zhHans: "授权", en: "Grant Access"))
            calendarRow.setStatusNote(nil)
        @unknown default:
            calendarRow.setButtonTitle(L10n.text(key: "settings.permissions.grant_access", zhHans: "授权", en: "Grant Access"))
            calendarRow.setStatusNote(L10n.text(key: "settings.permissions.calendar.abnormal", zhHans: "当前权限状态异常，请重试或打开系统设置检查。", en: "The current permission state looks unusual. Try again or check it in System Settings."))
        }

        automationRow.setAuthorized(automationGranted == true)
        automationRow.setButtonTitle(automationGranted == true
            ? L10n.text(key: "settings.permissions.recheck", zhHans: "重新检测", en: "Recheck")
            : L10n.text(key: "settings.permissions.check_and_authorize", zhHans: "检测并授权", en: "Check & Grant Access"))

        configureObservableRow(
            inputMonitoringRow,
            status: inputMonitoringStatus,
            buttonTitle: L10n.text(zhHans: "打开设置", en: "Open Settings")
        )
        configureObservableRow(
            screenRecordingRow,
            status: screenRecordingStatus,
            buttonTitle: L10n.text(zhHans: "打开设置", en: "Open Settings")
        )

        filesAndFoldersRow.setAuthorized(false)
        filesAndFoldersRow.setStatusNote(L10n.format(
            key: "settings.permissions.files_and_folders.note",
            zhHans: "按需权限：只有访问受保护位置后，系统才可能显示 %@；默认使用通常不需要。",
            en: "On-demand permission: %@ usually appears here only after you access a protected location, and most people will not need it.",
            appName
        ))
        filesAndFoldersRow.setButtonTitle(L10n.text(zhHans: "打开设置", en: "Open Settings"))

        fullDiskAccessRow.setAuthorized(false)
        fullDiskAccessRow.setStatusNote(L10n.format(
            key: "settings.permissions.full_disk_access.note",
            zhHans: "按需权限：只有读取受保护目录时才可能需要；未触发前系统列表里通常不会出现 %@。",
            en: "On-demand permission: this is only needed when reading protected folders, so %@ may not appear in the system list until then.",
            appName
        ))
        fullDiskAccessRow.setButtonTitle(L10n.text(zhHans: "打开设置", en: "Open Settings"))

        automationRow.setStatusNote(automationGranted == true ? nil : automationText)
    }

    func requestAccessibilityPermission() {
        activateApp()
        appendDiagnostic(L10n.text(zhHans: "请求辅助功能权限", en: "Request Accessibility permission"))
        permissionManager.requestAccessibilityPermission { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendDiagnostic(
                    "\(L10n.text(zhHans: "辅助功能", en: "Accessibility")) | before=\(result.beforeTrusted ? "trusted" : "untrusted") after=\(result.afterTrusted ? "trusted" : "untrusted") granted=\(result.granted) detail=\(result.detail)"
                )
                self.refreshStatus()
            }
        }
    }

    func requestCalendarPermission() {
        activateApp()
        appendDiagnostic(L10n.text(zhHans: "请求日历权限", en: "Request calendar permission"))
        permissionManager.requestCalendarAccess { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let errorText = result.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.appendDiagnostic(
                    "\(L10n.text(zhHans: "日历", en: "Calendar")) | before=\(PermissionManager.calendarStatusText(result.beforeStatus)) after=\(PermissionManager.calendarStatusText(result.afterStatus)) granted=\(result.granted) detail=\(result.detail)\(errorText?.isEmpty == false ? " error=\(errorText!)" : "")"
                )
                self.refreshStatus()
            }
        }
    }

    func requestAutomationPermission() {
        activateApp()
        appendDiagnostic(L10n.text(zhHans: "请求自动化(Calendar)权限", en: "Request Automation (Calendar) permission"))
        permissionManager.requestCalendarAutomationPermission { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settings.calendarAutomationPermissionGranted = result.granted
                let errorText = result.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                let codeText = result.errorCode.map(String.init) ?? "nil"
                self.appendDiagnostic(
                    "\(L10n.text(zhHans: "自动化(Calendar)", en: "Automation (Calendar)")) | granted=\(result.granted) code=\(codeText) detail=\(result.detail)\(errorText?.isEmpty == false ? " error=\(errorText!)" : "")"
                )
                self.refreshStatus()
            }
        }
    }

    func requestAllNecessaryPermissions() {
        activateApp()
        actionLabel.stringValue = L10n.text(zhHans: "正在请求必要权限...", en: "Requesting required permissions...")
        appendDiagnostic(L10n.text(zhHans: "请求全部必要权限", en: "Request all required permissions"))

        permissionManager.requestAccessibilityPermission { [weak self] accessibilityResult in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendDiagnostic("\(L10n.text(zhHans: "批量授权", en: "Batch authorize")) | \(L10n.text(zhHans: "辅助功能", en: "Accessibility")) granted=\(accessibilityResult.granted) detail=\(accessibilityResult.detail)")
                self.requestCalendarPermissionIfNeeded {
                    self.requestScreenRecordingPermissionIfNeeded {
                        self.requestAutomationPermissionIfNeeded {
                            self.refreshStatus()
                        }
                    }
                }
            }
        }
    }

    func openInputMonitoringSettings() {
        let opened = permissionManager.openInputMonitoringSettings()
        appendDiagnostic("\(L10n.text(zhHans: "打开输入监控设置", en: "Open Input Monitoring settings")) opened=\(opened)")
    }

    func openScreenRecordingSettings() {
        let opened = permissionManager.openScreenRecordingSettings()
        appendDiagnostic("\(L10n.text(zhHans: "打开屏幕录制设置", en: "Open Screen Recording settings")) opened=\(opened)")
    }

    func openFilesAndFoldersSettings() {
        let opened = permissionManager.openFilesAndFoldersSettings()
        appendDiagnostic("\(L10n.text(zhHans: "打开文件与文件夹设置", en: "Open Files & Folders settings")) opened=\(opened)")
    }

    func openFullDiskAccessSettings() {
        let opened = permissionManager.openFullDiskAccessSettings()
        appendDiagnostic("\(L10n.text(zhHans: "打开完全磁盘访问设置", en: "Open Full Disk Access settings")) opened=\(opened)")
    }

    func refreshCalendarAutomationStatusIfNeeded() {
        guard productProfile.requiresAutomationPermission else { return }
        guard settings.calendarAutomationPermissionGranted == nil, !isRefreshingAutomationStatus else {
            return
        }
        isRefreshingAutomationStatus = true
        permissionManager.checkCalendarAutomationPermission { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRefreshingAutomationStatus = false
                if result.granted || result.detail != "calendar_not_running" {
                    self.settings.calendarAutomationPermissionGranted = result.granted
                    self.refreshStatus()
                }
            }
        }
    }

    private func configureObservableRow(
        _ row: SettingsPermissionRowView,
        status: PermissionManager.ObservableAuthorizationStatus,
        buttonTitle: String
    ) {
        row.setButtonTitle(buttonTitle)
        switch status {
        case .granted:
            row.setAuthorized(true)
            row.setStatusNote(nil)
        case .denied, .unknown, .unavailable:
            row.setAuthorized(false)
            row.setStatusNote(PermissionManager.observableAuthorizationStatusText(status))
        }
    }

    private func appendDiagnostic(_ entry: String) {
        diagnosticHistory.append("[\(diagnosticTimestamp())] \(entry)")
        if diagnosticHistory.count > 8 {
            diagnosticHistory = Array(diagnosticHistory.suffix(8))
        }
        let rendered = diagnosticHistory.reversed().joined(separator: "\n")
        diagnosticsLabel.stringValue = rendered.isEmpty
            ? L10n.text(key: "settings.permissions.diagnostics.empty", zhHans: "诊断：暂无", en: "Diagnostics: none yet")
            : rendered
    }

    private func diagnosticTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private func requestCalendarPermissionIfNeeded(completion: @escaping () -> Void) {
        guard productProfile.requiresCalendarPermission else {
            completion()
            return
        }

        permissionManager.requestCalendarAccess { [weak self] calendarResult in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendDiagnostic("\(L10n.text(zhHans: "批量授权", en: "Batch authorize")) | \(L10n.text(zhHans: "日历", en: "Calendar")) granted=\(calendarResult.granted) detail=\(calendarResult.detail)")
                completion()
            }
        }
    }

    private func requestScreenRecordingPermissionIfNeeded(completion: @escaping () -> Void) {
        guard productProfile.requiresScreenRecordingPermission else {
            completion()
            return
        }

        permissionManager.requestScreenRecordingPermission { [weak self] screenResult in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appendDiagnostic("\(L10n.text(zhHans: "批量授权", en: "Batch authorize")) | \(L10n.text(zhHans: "屏幕录制", en: "Screen Recording")) granted=\(screenResult.granted) detail=\(screenResult.detail)")
                completion()
            }
        }
    }

    private func requestAutomationPermissionIfNeeded(completion: @escaping () -> Void) {
        guard productProfile.requiresAutomationPermission else {
            completion()
            return
        }

        permissionManager.requestCalendarAutomationPermission { [weak self] automationResult in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settings.calendarAutomationPermissionGranted = automationResult.granted
                self.appendDiagnostic("\(L10n.text(zhHans: "批量授权", en: "Batch authorize")) | \(L10n.text(zhHans: "自动化(Calendar)", en: "Automation (Calendar)")) granted=\(automationResult.granted) detail=\(automationResult.detail)")
                completion()
            }
        }
    }
}

@MainActor
final class SettingsKnowledgeBaseImportCoordinator {
    private let knowledgeBaseStore: ReplyKnowledgeBaseStore
    private let addButton: NSButton
    private let statusLabel: NSTextField
    private let reloadEntries: (String) -> Void
    private let defaultAddButtonTitle: String

    init(
        knowledgeBaseStore: ReplyKnowledgeBaseStore,
        addButton: NSButton,
        statusLabel: NSTextField,
        reloadEntries: @escaping (String) -> Void
    ) {
        self.knowledgeBaseStore = knowledgeBaseStore
        self.addButton = addButton
        self.statusLabel = statusLabel
        self.reloadEntries = reloadEntries
        self.defaultAddButtonTitle = addButton.title
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ReplyKnowledgeBaseStore.supportedFilenameExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = L10n.text(key: "settings.knowledge_base.import.choose_files", zhHans: "选择要导入到知识库的文件", en: "Choose files to import into the knowledge base")
        panel.prompt = L10n.text(zhHans: "导入", en: "Import")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let urls = panel.urls
        setImportingState(true)
        statusLabel.stringValue = L10n.format(
            key: "settings.knowledge_base.import.parsing",
            zhHans: "正在解析 %d 个文件...",
            en: "Parsing %d files...",
            urls.count
        )

        Task { [weak self] in
            guard let self else { return }
            let result = await self.knowledgeBaseStore.importFiles(urls: urls)
            await MainActor.run {
                self.setImportingState(false)
                self.reloadEntries(self.importStatus(for: result))
            }
        }
    }

    func importURL(_ rawURL: String) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusLabel.stringValue = L10n.text(key: "settings.knowledge_base.import.enter_url", zhHans: "请输入要采集的链接。", en: "Enter a URL to collect.")
            return
        }

        let normalizedString: String
        if trimmed.contains("://") {
            normalizedString = trimmed
        } else {
            normalizedString = "https://\(trimmed)"
        }

        guard let url = URL(string: normalizedString), url.scheme?.hasPrefix("http") == true else {
            statusLabel.stringValue = L10n.text(key: "settings.knowledge_base.import.invalid_url", zhHans: "链接格式无效。", en: "Invalid URL.")
            return
        }

        setImportingState(true)
        statusLabel.stringValue = L10n.text(key: "settings.knowledge_base.import.collecting_url", zhHans: "正在采集链接...", en: "Collecting link...")

        Task { [weak self] in
            guard let self else { return }
            let result = await self.knowledgeBaseStore.collectURL(url)
            await MainActor.run {
                self.setImportingState(false)
                self.reloadEntries(self.importStatus(for: ReplyKnowledgeBaseImportResult(
                    imported: result.inserted + result.updated,
                    failures: result.failures
                )))
            }
        }
    }

    private func setImportingState(_ importing: Bool) {
        addButton.isEnabled = !importing
        addButton.title = importing
            ? L10n.text(key: "settings.knowledge_base.import.importing", zhHans: "导入中…", en: "Importing...")
            : defaultAddButtonTitle
    }

    private func importStatus(for result: ReplyKnowledgeBaseImportResult) -> String {
        let successCount = result.imported.count
        let failureCount = result.failures.count
        let failureText = result.failures.prefix(2).map { "\($0.fileName)：\($0.reason)" }.joined(separator: "；")
        if successCount > 0 && failureCount > 0 {
            return L10n.format(
                key: "settings.knowledge_base.import.status.partial_success",
                zhHans: "已导入 %d 个文件，%d 个失败。%@",
                en: "Imported %d files. %d failed. %@",
                successCount,
                failureCount,
                failureText
            )
        }
        if successCount > 0 {
            return L10n.format(
                key: "settings.knowledge_base.import.status.success",
                zhHans: "已导入 %d 个文件。",
                en: "Imported %d files.",
                successCount
            )
        }
        if failureCount > 0 {
            return failureText.isEmpty
                ? L10n.text(key: "settings.knowledge_base.import.status.failed", zhHans: "导入失败。", en: "Import failed.")
                : L10n.format(
                    key: "settings.knowledge_base.import.status.none_succeeded",
                    zhHans: "没有导入成功。%@",
                    en: "No files were imported. %@",
                    failureText
                )
        }
        return L10n.text(key: "settings.knowledge_base.import.status.no_new_files", zhHans: "没有导入新文件。", en: "No new files were imported.")
    }
}
