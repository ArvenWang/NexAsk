import AppKit
import ApplicationServices
import CoreGraphics
import CoreServices
import EventKit
import IOKit.hidsystem

package final class PermissionManager {
    package enum ObservableAuthorizationStatus {
        case granted
        case denied
        case unknown
        case unavailable(String)
    }

    package enum ReadinessLevel {
        case ready
        case needsAction
        case optional
    }

    package struct CapabilityReadiness {
        let title: String
        let level: ReadinessLevel
        let summary: String
    }

    package struct FirstUseReadinessSnapshot {
        let productProfile: AppProductProfile
        let coreEntry: CapabilityReadiness
        let screenshot: CapabilityReadiness
        let calendar: CapabilityReadiness
        let automation: CapabilityReadiness

        var isCoreEntryReady: Bool {
            coreEntry.level == .ready
        }

        var headline: String {
            if isCoreEntryReady {
                return L10n.text(key: "permission.headline.ready", zhHans: "核心入口已可用", en: "Core access is ready")
            }
            return L10n.format(
                key: "permission.headline.needs_action",
                zhHans: "还差一步才能稳定使用 %@",
                en: "One more step to use %@ reliably",
                AppBrand.displayName
            )
        }

        var summary: String {
            if isCoreEntryReady {
                switch productProfile {
                case .unified:
                    return L10n.text(
                        key: "permission.summary.ready",
                        zhHans: "核心交互已就绪。截图和日历相关权限可以按需要再开启。",
                        en: "Core interaction is ready. You can enable screenshot and calendar access later if you need them."
                    )
                case .nexhub:
                    return L10n.text(
                        zhHans: "核心交互已就绪。截图、兼容抓取和文件相关权限可以按需要再开启。",
                        en: "Core interaction is ready. You can enable screenshot, compatibility capture, and file-related permissions later if you need them."
                    )
                case .nexask:
                    return L10n.text(
                        zhHans: "核心交互已就绪。日历和自动化相关权限可以按需要再开启。",
                        en: "Core interaction is ready. You can enable calendar and automation access later if you need them."
                    )
                }
            }
            return coreEntry.summary
        }

        var actionHint: String {
            if isCoreEntryReady {
                switch productProfile {
                case .unified, .nexhub:
                    return L10n.text(
                        key: "permission.action_hint.ready",
                        zhHans: "建议先试一次主入口，确认浮条或菜单能正常出现；其他权限可以稍后按需开启。",
                        en: "Try the primary entry flow once and make sure the toolbar or menu appears. Other permissions can wait."
                    )
                case .nexask:
                    return L10n.format(
                        zhHans: "建议先打开一次 %@ 主窗口，确认主交互可用；日历和自动化权限可以稍后按需开启。",
                        en: "Open %@ once to verify the main interaction works. Calendar and automation permissions can wait.",
                        AppBrand.displayName
                    )
                }
            }
            switch productProfile {
            case .unified, .nexhub:
                return L10n.format(
                    key: "permission.action_hint.needs_action",
                    zhHans: "先完成辅助功能授权，%@ 才能读取选区并在任意 App 里稳定出现入口。",
                    en: "Grant Accessibility first so %@ can read selections and show its entry points reliably in any app.",
                    AppBrand.displayName
                )
            case .nexask:
                return L10n.format(
                    zhHans: "先完成辅助功能授权，%@ 才能更稳定地读取应用上下文并执行辅助动作。",
                    en: "Grant Accessibility first so %@ can interact with app context more reliably for assisted actions.",
                    AppBrand.displayName
                )
            }
        }
    }

    package struct AccessibilityRequestResult {
        let granted: Bool
        let beforeTrusted: Bool
        let afterTrusted: Bool
        let detail: String
    }

    package struct CalendarRequestResult {
        let granted: Bool
        let beforeStatus: EKAuthorizationStatus
        let afterStatus: EKAuthorizationStatus
        let errorDescription: String?
        let detail: String
    }

    package struct AutomationRequestResult {
        let granted: Bool
        let errorCode: Int?
        let errorDescription: String?
        let detail: String
    }

    struct ScreenRecordingRequestResult {
        let granted: Bool
        let beforeGranted: Bool
        let afterGranted: Bool
        let detail: String
    }

    private let calendarStore = EKEventStore()

    package init() {}

    package func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityTrust(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        _ = openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    @discardableResult
    func openCalendarSettings() -> Bool {
        openPrivacySettings(anchor: "Privacy_Calendars")
    }

    @discardableResult
    func openAutomationSettings() -> Bool {
        openPrivacySettings(anchor: "Privacy_Automation")
    }

    @discardableResult
    func openInputMonitoringSettings() -> Bool {
        openPrivacySettings(anchor: "Privacy_ListenEvent")
    }

    @discardableResult
    func openScreenRecordingSettings() -> Bool {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    @discardableResult
    func openFullDiskAccessSettings() -> Bool {
        openPrivacySettings(anchor: "Privacy_AllFiles")
    }

    @discardableResult
    func openFilesAndFoldersSettings() -> Bool {
        openPrivacySettings(anchor: "Privacy_FilesAndFolders")
    }

    func inputMonitoringAuthorizationStatus() -> ObservableAuthorizationStatus {
        if #available(macOS 10.15, *) {
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted:
                return .granted
            case kIOHIDAccessTypeDenied:
                return .denied
            case kIOHIDAccessTypeUnknown:
                return .unknown
            default:
                return .unknown
            }
        }
        return .unavailable(L10n.text(zhHans: "当前系统不支持状态读取", en: "This macOS version does not expose the permission status"))
    }

    func screenRecordingAuthorizationStatus() -> ObservableAuthorizationStatus {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
        return .unavailable(L10n.text(zhHans: "当前系统不支持状态读取", en: "This macOS version does not expose the permission status"))
    }

    static func observableAuthorizationStatusText(_ status: ObservableAuthorizationStatus) -> String {
        switch status {
        case .granted:
            return L10n.text(key: "permission.observable.granted", zhHans: "已授权", en: "Granted")
        case .denied:
            return L10n.text(key: "permission.observable.denied", zhHans: "未授权", en: "Not Enabled")
        case .unknown:
            return L10n.text(key: "permission.observable.unknown", zhHans: "未检测", en: "Unknown")
        case .unavailable(let reason):
            return reason
        }
    }

    func firstUseReadinessSnapshot(
        calendarAutomationGranted: Bool?,
        productProfile: AppProductProfile = .current
    ) -> FirstUseReadinessSnapshot {
        let accessibilityGranted = isAccessibilityTrusted()
        let calendarStatus = calendarAuthorizationStatus()
        let screenRecordingStatus = screenRecordingAuthorizationStatus()
        let calendarGranted: Bool
        if #available(macOS 14.0, *) {
            calendarGranted = (calendarStatus == .fullAccess || calendarStatus == .writeOnly)
        } else {
            calendarGranted = (calendarStatus == .authorized)
        }

        let coreEntry = CapabilityReadiness(
            title: L10n.text(zhHans: "辅助功能", en: "Accessibility"),
            level: accessibilityGranted ? .ready : .needsAction,
            summary: {
                if accessibilityGranted {
                    switch productProfile {
                    case .unified, .nexhub:
                        return L10n.text(
                            key: "permission.accessibility.summary.ready",
                            zhHans: "辅助功能已授权，文本与应用交互入口可以正常工作。",
                            en: "Accessibility is enabled, so text and app interaction entry points should work normally."
                        )
                    case .nexask:
                        return L10n.format(
                            zhHans: "辅助功能已授权，%@ 读取应用上下文和执行辅助动作会更稳定。",
                            en: "Accessibility is enabled, so %@ can interact with app context more reliably.",
                            AppBrand.displayName
                        )
                    }
                } else {
                    switch productProfile {
                    case .unified, .nexhub:
                        return L10n.format(
                            key: "permission.accessibility.summary.needs_action",
                            zhHans: "还没有辅助功能权限，所以 %@ 当前不能稳定读取选区，也无法可靠显示入口。",
                            en: "Accessibility is off, so %@ can't reliably read selections or show its entry points.",
                            AppBrand.displayName
                        )
                    case .nexask:
                        return L10n.format(
                            zhHans: "还没有辅助功能权限，所以 %@ 当前无法稳定读取应用上下文或执行部分辅助动作。",
                            en: "Accessibility is off, so %@ can't reliably read app context or perform some assisted actions.",
                            AppBrand.displayName
                        )
                    }
                }
            }()
        )

        let screenshotGranted: Bool
        switch screenRecordingStatus {
        case .granted:
            screenshotGranted = true
        default:
            screenshotGranted = false
        }
        let screenshot = CapabilityReadiness(
            title: L10n.text(zhHans: "屏幕录制", en: "Screen Recording"),
            level: screenshotGranted ? .ready : .optional,
            summary: screenshotGranted
                ? L10n.text(key: "permission.screen_recording.summary.ready", zhHans: "截图相关权限已就绪。", en: "Screen capture is ready.")
                : L10n.text(
                    key: "permission.screen_recording.summary.optional",
                    zhHans: "截图相关能力暂时不可用，但不会影响普通划词和回复场景。",
                    en: "Screen capture is unavailable for now, but text selection and reply still work."
                )
        )

        let calendar = CapabilityReadiness(
            title: L10n.text(zhHans: "日历", en: "Calendar"),
            level: calendarGranted ? .ready : .optional,
            summary: calendarGranted
                ? L10n.text(key: "permission.calendar.summary.ready", zhHans: "日历写入权限已可用。", en: "Calendar access is ready.")
                : L10n.text(
                    key: "permission.calendar.summary.optional",
                    zhHans: "日历权限目前还没开启，创建日程时再授权也可以。",
                    en: "Calendar access is off. You can enable it when you create a schedule."
                )
        )

        let automation: CapabilityReadiness
        if let calendarAutomationGranted {
            automation = CapabilityReadiness(
                title: L10n.text(zhHans: "自动化(Calendar)", en: "Automation (Calendar)"),
                level: calendarAutomationGranted ? .ready : .optional,
                summary: calendarAutomationGranted
                    ? L10n.text(
                        key: "permission.automation.summary.ready",
                        zhHans: "Calendar 自动化已确认可用。",
                        en: "Calendar automation is enabled and ready."
                    )
                    : L10n.text(
                        key: "permission.automation.summary.optional",
                        zhHans: "Calendar 自动化还没确认成功，只会影响日程相关动作。",
                        en: "Calendar automation is not confirmed yet. This only affects scheduling actions."
                    )
            )
        } else {
            automation = CapabilityReadiness(
                title: L10n.text(zhHans: "自动化(Calendar)", en: "Automation (Calendar)"),
                level: .optional,
                summary: L10n.text(
                    key: "permission.automation.summary.unchecked",
                    zhHans: "Calendar 自动化还没检测过，只在创建日程时需要。",
                    en: "Calendar automation has not been checked yet. You only need it when creating a schedule."
                )
            )
        }

        return FirstUseReadinessSnapshot(
            productProfile: productProfile,
            coreEntry: coreEntry,
            screenshot: screenshot,
            calendar: calendar,
            automation: automation
        )
    }

    @discardableResult
    private func openPrivacySettings(anchor: String) -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        ]
        for entry in candidates {
            if let url = URL(string: entry), NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }

    private func activateForSystemPrompt() {
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
    }

    func requestAccessibilityWithFallbackOpen() {
        let granted = requestAccessibilityTrust(prompt: true)
        if !granted {
            openAccessibilitySettings()
        }
    }

    func requestScreenRecordingPermission(completion: @escaping (ScreenRecordingRequestResult) -> Void) {
        guard #available(macOS 10.15, *) else {
            completion(
                ScreenRecordingRequestResult(
                    granted: false,
                    beforeGranted: false,
                    afterGranted: false,
                    detail: "unsupported_system"
                )
            )
            return
        }

        let beforeGranted = CGPreflightScreenCaptureAccess()
        if beforeGranted {
            completion(
                ScreenRecordingRequestResult(
                    granted: true,
                    beforeGranted: true,
                    afterGranted: true,
                    detail: "already_granted"
                )
            )
            return
        }

        activateForSystemPrompt()
        let promptTriggered = CGRequestScreenCaptureAccess()

        var remainingChecks = 20
        func poll() {
            let afterGranted = CGPreflightScreenCaptureAccess()
            if afterGranted {
                completion(
                    ScreenRecordingRequestResult(
                        granted: true,
                        beforeGranted: beforeGranted,
                        afterGranted: true,
                        detail: promptTriggered ? "granted_after_prompt" : "granted_after_preflight"
                    )
                )
                return
            }

            remainingChecks -= 1
            if remainingChecks <= 0 {
                let openedSettings = self.openScreenRecordingSettings()
                completion(
                    ScreenRecordingRequestResult(
                        granted: false,
                        beforeGranted: beforeGranted,
                        afterGranted: false,
                        detail: "prompt_timeout_or_denied(settings_opened=\(openedSettings))"
                    )
                )
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                poll()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            poll()
        }
    }

    func requestAccessibilityPermission(completion: @escaping (AccessibilityRequestResult) -> Void) {
        let before = isAccessibilityTrusted()
        if before {
            completion(
                AccessibilityRequestResult(
                    granted: true,
                    beforeTrusted: true,
                    afterTrusted: true,
                    detail: "already_trusted"
                )
            )
            return
        }

        _ = requestAccessibilityTrust(prompt: true)

        // AX prompt is asynchronous and has no callback; poll briefly.
        var remainingChecks = 20
        func poll() {
            let after = self.isAccessibilityTrusted()
            if after {
                completion(
                    AccessibilityRequestResult(
                        granted: true,
                        beforeTrusted: before,
                        afterTrusted: true,
                        detail: "granted_after_prompt"
                    )
                )
                return
            }
            remainingChecks -= 1
            if remainingChecks <= 0 {
                completion(
                    AccessibilityRequestResult(
                        granted: false,
                        beforeTrusted: before,
                        afterTrusted: false,
                        detail: "prompt_timeout_or_denied"
                    )
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                poll()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            poll()
        }
    }

    func calendarAuthorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestCalendarAccess(completion: @escaping (CalendarRequestResult) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.requestCalendarAccess(completion: completion)
            }
            return
        }

        activateForSystemPrompt()
        calendarStore.reset()

        let beforeStatus = calendarAuthorizationStatus()

        if #available(macOS 14.0, *) {
            switch beforeStatus {
            case .fullAccess, .writeOnly:
                completion(
                    CalendarRequestResult(
                        granted: true,
                        beforeStatus: beforeStatus,
                        afterStatus: beforeStatus,
                        errorDescription: nil,
                        detail: "already_authorized"
                    )
                )
            case .notDetermined:
                calendarStore.requestWriteOnlyAccessToEvents { granted, error in
                    DispatchQueue.main.async {
                        let afterStatus = self.calendarAuthorizationStatus()
                        if granted || afterStatus == .writeOnly || afterStatus == .fullAccess {
                            completion(
                                CalendarRequestResult(
                                    granted: true,
                                    beforeStatus: beforeStatus,
                                    afterStatus: afterStatus,
                                    errorDescription: error?.localizedDescription,
                                    detail: "requested_write_only_access(status=\(Self.calendarStatusText(afterStatus)))"
                                )
                            )
                            return
                        }

                        if !granted, afterStatus == .notDetermined {
                            self.calendarStore.requestFullAccessToEvents { fullGranted, fullError in
                                DispatchQueue.main.async {
                                    let fullStatus = self.calendarAuthorizationStatus()
                                    if fullGranted || fullStatus == .fullAccess || fullStatus == .writeOnly {
                                        completion(
                                            CalendarRequestResult(
                                                granted: true,
                                                beforeStatus: beforeStatus,
                                                afterStatus: fullStatus,
                                                errorDescription: fullError?.localizedDescription ?? error?.localizedDescription,
                                                detail: "requested_write_only_then_full_access(status=\(Self.calendarStatusText(fullStatus)))"
                                            )
                                        )
                                        return
                                    }
                                    if fullStatus == .notDetermined {
                                        // Final fallback: legacy API can still surface consent on some systems.
                                        self.calendarStore.requestAccess(to: .event) { legacyGranted, legacyError in
                                            DispatchQueue.main.async {
                                                let fallbackStatus = self.calendarAuthorizationStatus()
                                                let openedSettings = fallbackStatus == .notDetermined ? self.openCalendarSettings() : false
                                                completion(
                                                    CalendarRequestResult(
                                                        granted: legacyGranted,
                                                        beforeStatus: beforeStatus,
                                                        afterStatus: fallbackStatus,
                                                        errorDescription: legacyError?.localizedDescription
                                                            ?? fullError?.localizedDescription
                                                            ?? error?.localizedDescription,
                                                        detail: "requested_write_only_then_full_then_legacy_access(status=\(Self.calendarStatusText(fallbackStatus));settings_opened=\(openedSettings))"
                                                    )
                                                )
                                            }
                                        }
                                    } else {
                                        let openedSettings = self.openCalendarSettingsIfGuidanceNeeded(for: fullStatus)
                                        completion(
                                            CalendarRequestResult(
                                                granted: false,
                                                beforeStatus: beforeStatus,
                                                afterStatus: fullStatus,
                                                errorDescription: fullError?.localizedDescription ?? error?.localizedDescription,
                                                detail: "requested_write_only_then_full_access(status=\(Self.calendarStatusText(fullStatus));settings_opened=\(openedSettings))"
                                            )
                                        )
                                    }
                                }
                            }
                            return
                        }
                        let openedSettings = self.openCalendarSettingsIfGuidanceNeeded(for: afterStatus)
                        completion(
                            CalendarRequestResult(
                                granted: granted,
                                beforeStatus: beforeStatus,
                                afterStatus: afterStatus,
                                errorDescription: error?.localizedDescription,
                                detail: error == nil
                                    ? "requested_write_only_access(status=\(Self.calendarStatusText(afterStatus));settings_opened=\(openedSettings))"
                                    : "request_failed(status=\(Self.calendarStatusText(afterStatus));settings_opened=\(openedSettings))"
                            )
                        )
                    }
                }
            case .denied, .restricted:
                let openedSettings = openCalendarSettingsIfGuidanceNeeded(for: beforeStatus)
                completion(
                    CalendarRequestResult(
                        granted: false,
                        beforeStatus: beforeStatus,
                        afterStatus: beforeStatus,
                        errorDescription: nil,
                        detail: "status_\(Self.calendarStatusText(beforeStatus))(settings_opened=\(openedSettings))"
                    )
                )
            @unknown default:
                completion(
                    CalendarRequestResult(
                        granted: false,
                        beforeStatus: beforeStatus,
                        afterStatus: beforeStatus,
                        errorDescription: "unknown authorization status",
                        detail: "unknown_status"
                    )
                )
            }
        } else {
            switch beforeStatus {
            case .authorized:
                completion(
                    CalendarRequestResult(
                        granted: true,
                        beforeStatus: beforeStatus,
                        afterStatus: beforeStatus,
                        errorDescription: nil,
                        detail: "already_authorized"
                    )
                )
            case .fullAccess, .writeOnly:
                completion(
                    CalendarRequestResult(
                        granted: true,
                        beforeStatus: beforeStatus,
                        afterStatus: beforeStatus,
                        errorDescription: nil,
                        detail: "already_authorized"
                    )
                )
            case .notDetermined:
                calendarStore.requestAccess(to: .event) { granted, error in
                    DispatchQueue.main.async {
                        let afterStatus = self.calendarAuthorizationStatus()
                        let openedSettings = !granted ? self.openCalendarSettingsIfGuidanceNeeded(for: afterStatus) : false
                        completion(
                            CalendarRequestResult(
                                granted: granted,
                                beforeStatus: beforeStatus,
                                afterStatus: afterStatus,
                                errorDescription: error?.localizedDescription,
                                detail: error == nil
                                    ? "requested_access_legacy(status=\(Self.calendarStatusText(afterStatus));settings_opened=\(openedSettings))"
                                    : "request_failed(status=\(Self.calendarStatusText(afterStatus));settings_opened=\(openedSettings))"
                            )
                        )
                    }
                }
            case .denied, .restricted:
                let openedSettings = openCalendarSettingsIfGuidanceNeeded(for: beforeStatus)
                completion(
                    CalendarRequestResult(
                        granted: false,
                        beforeStatus: beforeStatus,
                        afterStatus: beforeStatus,
                        errorDescription: nil,
                        detail: "status_\(Self.calendarStatusText(beforeStatus))(settings_opened=\(openedSettings))"
                    )
                )
            @unknown default:
                completion(
                    CalendarRequestResult(
                        granted: false,
                        beforeStatus: beforeStatus,
                        afterStatus: beforeStatus,
                        errorDescription: "unknown authorization status",
                        detail: "unknown_status"
                    )
                )
            }
        }
    }

    func requestCalendarAutomationPermission(completion: @escaping (AutomationRequestResult) -> Void) {
        requestCalendarAutomationPermission(askUserIfNeeded: true, completion: completion)
    }

    func checkCalendarAutomationPermission(completion: @escaping (AutomationRequestResult) -> Void) {
        requestCalendarAutomationPermission(askUserIfNeeded: false, completion: completion)
    }

    private func requestCalendarAutomationPermission(
        askUserIfNeeded: Bool,
        completion: @escaping (AutomationRequestResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let running = self.ensureApplicationRunning(bundleID: "com.apple.iCal", activate: askUserIfNeeded)
            DispatchQueue.main.async {
                if askUserIfNeeded {
                    self.activateForSystemPrompt()
                }

                if !running {
                    completion(
                        AutomationRequestResult(
                            granted: false,
                            errorCode: Int(OSStatus(procNotFound)),
                            errorDescription: Self.appleEventStatusDescription(OSStatus(procNotFound)),
                            detail: "calendar_not_running"
                        )
                    )
                    return
                }

                let askStatus = self.determineAutomationPermission(
                    targetBundleID: "com.apple.iCal",
                    askUserIfNeeded: askUserIfNeeded
                )
                let finalStatus = self.determineAutomationPermission(
                    targetBundleID: "com.apple.iCal",
                    askUserIfNeeded: false
                )
                let effectiveStatus: OSStatus = finalStatus == noErr ? finalStatus : askStatus
                let granted = (effectiveStatus == noErr)
                let shouldOpenSettings = askUserIfNeeded
                    && (effectiveStatus == OSStatus(errAEEventNotPermitted)
                    || effectiveStatus == OSStatus(errAEEventWouldRequireUserConsent)
                    || effectiveStatus == OSStatus(procNotFound))
                let openedSettings = (!granted && shouldOpenSettings) ? self.openAutomationSettings() : false
                let detail = "aedetermine askUser=\(askUserIfNeeded) ask=\(askStatus) final=\(finalStatus) settings_opened=\(openedSettings)"

                completion(
                    AutomationRequestResult(
                        granted: granted,
                        errorCode: granted ? nil : Int(effectiveStatus),
                        errorDescription: granted ? nil : Self.appleEventStatusDescription(effectiveStatus),
                        detail: detail
                    )
                )
            }
        }
    }

    static func calendarStatusText(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .fullAccess:
            return "fullAccess"
        case .writeOnly:
            return "writeOnly"
        @unknown default:
            return "unknown"
        }
    }

    private func openCalendarSettingsIfGuidanceNeeded(for status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .denied, .restricted, .notDetermined:
            return openCalendarSettings()
        default:
            return false
        }
    }

    private func ensureApplicationRunning(bundleID: String, timeout: TimeInterval = 2.5, activate: Bool = true) -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
            return true
        }
        let calendarURL = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        if activate {
            _ = NSWorkspace.shared.open(calendarURL)
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: calendarURL, configuration: configuration) { _, _ in }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) {
                return true
            }
            usleep(100_000)
        }
        return NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID })
    }

    private func determineAutomationPermission(targetBundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        var targetDesc = AEAddressDesc()
        let bytes = Array(targetBundleID.utf8)
        let createStatus: OSStatus = bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(paramErr) }
            let status = AECreateDesc(
                DescType(typeApplicationBundleID),
                base,
                bytes.count,
                &targetDesc
            )
            return OSStatus(status)
        }
        guard createStatus == noErr else {
            return createStatus
        }
        defer { AEDisposeDesc(&targetDesc) }

        return AEDeterminePermissionToAutomateTarget(
            &targetDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
    }

    private static func appleEventStatusDescription(_ status: OSStatus) -> String {
        switch status {
        case noErr:
            return "noErr"
        case OSStatus(errAEEventNotPermitted):
            return "errAEEventNotPermitted(-1743)"
        case OSStatus(errAEEventWouldRequireUserConsent):
            return "errAEEventWouldRequireUserConsent(-1744)"
        case OSStatus(procNotFound):
            return "procNotFound"
        case OSStatus(paramErr):
            return "paramErr"
        default:
            return "OSStatus(\(status))"
        }
    }
}
