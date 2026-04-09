import AppKit

extension NexHubRuntime {
    func setupStatusBar() {
        let productProfile = AppProductProfile.current
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = makeStatusBarImage()
        statusItem.button?.toolTip = AppBrand.displayName
        statusItem.button?.setAccessibilityIdentifier(AppBrand.accessibilityIdentifier("status-item"))
        statusItem.button?.setAccessibilityLabel("\(AppBrand.displayName) Menu Bar")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleStatusItemButtonAction(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menu = NSMenu()
        statusMenu = menu

        if productProfile.supportsTextSelectionEntry {
            let autoItem = NSMenuItem(
                title: L10n.text(zhHans: "启用划词", en: "Enable text selection"),
                action: #selector(toggleAutoToolbar),
                keyEquivalent: ""
            )
            autoItem.target = self
            menu.addItem(autoItem)
            menu.addItem(.separator())
            autoToolbarMenuItem = autoItem
        } else {
            autoToolbarMenuItem = nil
        }
        menu.addItem(makeMenuItem(L10n.text(zhHans: "设置…", en: "Settings…"), action: #selector(showSettings)))
        let updateMenuItem = makeMenuItem(
            L10n.text(zhHans: "检查更新…", en: "Check for Updates…"),
            action: #selector(checkUpdates)
        )
        appUpdateCoordinator.configureMenuItem(
            updateMenuItem,
            fallbackTarget: self,
            fallbackAction: #selector(checkUpdates)
        )
        checkUpdatesMenuItem = updateMenuItem
        menu.addItem(updateMenuItem)
        menu.addItem(.separator())
        menu.addItem(
            makeMenuItem(
                L10n.format(zhHans: "退出 %@", en: "Quit %@", AppBrand.displayName),
                action: #selector(quitApp)
            )
        )

        self.statusItem = statusItem
    }

    @objc private func handleStatusItemButtonAction(_ sender: Any?) {
        guard AppProductProfile.current.statusItemPrimaryAction == .conversation else {
            showStatusItemMenu()
            return
        }
        guard let event = NSApp.currentEvent else {
            _ = productExperienceController.presentPrimaryStatusItemExperience(anchorFrame: statusItemAnchorFrame())
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showStatusItemMenu()
        } else {
            if !productExperienceController.presentPrimaryStatusItemExperience(anchorFrame: statusItemAnchorFrame()) {
                showStatusItemMenu()
            }
        }
    }

    private func showStatusItemMenu() {
        guard let statusItem,
              let button = statusItem.button,
              let menu = statusMenu else { return }
        statusItem.menu = menu
        button.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    package func statusItemAnchorFrame() -> CGRect? {
        guard let button = statusItem?.button,
              let window = button.window else {
            return nil
        }
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(buttonFrameInWindow)
    }

    package func statusItemPopupFrame(anchorFrame: CGRect?) -> CGRect {
        let preferredSize = NSSize(width: 440, height: 340)
        let fallbackVisibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let anchorFrame {
            let visibleFrame = NSScreen.screens.first(where: { $0.frame.intersects(anchorFrame) })?.visibleFrame ?? fallbackVisibleFrame
            let desired = CGRect(
                x: anchorFrame.maxX - preferredSize.width,
                y: anchorFrame.minY - preferredSize.height - 8,
                width: preferredSize.width,
                height: preferredSize.height
            )
            return resolvedStatusItemPopupFrame(for: desired, visibleFrame: visibleFrame)
        }

        let desired = CGRect(
            x: fallbackVisibleFrame.maxX - preferredSize.width - 16,
            y: fallbackVisibleFrame.maxY - preferredSize.height - 24,
            width: preferredSize.width,
            height: preferredSize.height
        )
        return resolvedStatusItemPopupFrame(for: desired, visibleFrame: fallbackVisibleFrame)
    }

    func makeStatusBarImage() -> NSImage? {
        if let path = Bundle.main.path(forResource: "MenuBarIconTemplate", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "sparkles", accessibilityDescription: AppBrand.displayName)
    }

    func makeMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuActionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func refreshUpdateMenuItemBinding() {
        guard let checkUpdatesMenuItem else { return }
        appUpdateCoordinator.configureMenuItem(
            checkUpdatesMenuItem,
            fallbackTarget: self,
            fallbackAction: #selector(checkUpdates)
        )
    }

    func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.text(zhHans: "确定", en: "OK"))
        alert.runModal()
    }

    @objc func toggleAutoToolbar() {
        settings.textSelectionEnabled.toggle()
    }

    @objc func showActionManager() {
        presentSettings(tab: .general)
    }

    @objc func showSettings() {
        showActionManager()
    }

    @objc func showSkillCenter() {
        presentSettings(tab: .skills)
    }

    @objc func showShortcuts() {
        presentSettings(tab: .shortcuts)
    }

    @objc func showAIConfig() {
        presentSettings(tab: .general)
    }

    @objc func showKnowledgeBaseSettings() {
        presentSettings(tab: .knowledgeBase)
    }

    @objc func showMembership() {
        presentSettings(tab: .membership)
    }

    @objc func showPrivacy() {
        inlinePromptController.hide()
        toolbarController.hide()
        settingsWindowShell.show(tab: .privacy)
    }

    func presentSettings(tab: SettingsShellTab) {
        inlinePromptController.hide()
        toolbarController.hide()

        // When invoked from the floating toolbar's popup menu, defer window presentation
        // until the menu tracking loop has fully unwound.
        DispatchQueue.main.async { [weak self] in
            self?.settingsWindowShell.show(tab: tab)
        }
    }

    @objc func checkUpdates() {
        showInfoAlert(
            title: L10n.text(zhHans: "远程更新尚未启用", en: "Remote updates are not enabled"),
            message: appUpdateCoordinator.configurationIssueMessage()
        )
    }

    @objc func showDiagnosticToolbarNow() {
        let snapshot = SelectionSnapshot(
            text: "\(AppBrand.displayName) diagnostic sample text",
            anchorPoint: NSEvent.mouseLocation,
            sourceBundleID: "com.nexhub.diagnostic",
            origin: .clipboardCopy,
            replacementTarget: nil
        )
        selectionPresentationCoordinator.handleNewTextSnapshot(
            snapshot,
            gestureState: inputEventCoordinator.currentTextGestureState
        )
        inputEventCoordinator.consumePendingClickSelectionExpansion()
    }

    @objc func showSelectionReadDiagnostic() {
        if let snapshot = SelectionAccess.readCurrentSelection() {
            let preview = snapshot.text.count > 120 ? String(snapshot.text.prefix(120)) + "..." : snapshot.text
            showInfoAlert(
                title: L10n.text(zhHans: "选区读取成功", en: "Selection read succeeded"),
                message: L10n.format(
                    zhHans: "来源：%@\n长度：%d\n预览：%@\n\n诊断：\n%@",
                    en: "Source: %@\nLength: %d\nPreview: %@\n\nDiagnostics:\n%@",
                    snapshot.sourceBundleID ?? "unknown",
                    snapshot.text.count,
                    preview,
                    SelectionAccess.diagnoseCurrentSelection()
                )
            )
        } else {
            showInfoAlert(
                title: L10n.text(zhHans: "未读取到选区", en: "No selection detected"),
                message: L10n.format(
                    zhHans: "诊断：\n%@",
                    en: "Diagnostics:\n%@",
                    SelectionAccess.diagnoseCurrentSelection()
                )
            )
        }
    }

    @objc func handleDiagnosticScreenshotTrigger() {
        triggerScreenshotCaptureFlow()
    }

    @objc func showPermissionAndSigningDiagnostic() {
        let accessibility = permissionManager.isAccessibilityTrusted()
            ? L10n.text(zhHans: "已授权", en: "Granted")
            : L10n.text(zhHans: "未授权", en: "Not granted")
        let signing = signingStatusSummary()
        let bundlePath = Bundle.main.bundlePath
        showInfoAlert(
            title: L10n.text(zhHans: "权限与签名诊断", en: "Permissions and signing diagnostics"),
            message: L10n.format(
                zhHans: "辅助功能：%@\n版本：%@\n签名：%@\n路径：%@",
                en: "Accessibility: %@\nVersion: %@\nSignature: %@\nPath: %@",
                accessibility,
                buildVersionSummary(),
                signing,
                bundlePath
            )
        )
    }

    func buildVersionSummary() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let gitSHA = info?["NexHubGitSHA"] as? String ?? "unknown"
        return "\(version) (\(build), \(gitSHA))"
    }

    func signingStatusSummary() -> String {
        if let buildInfoSummary = AppBuildInfo.load()?.signingSummary {
            return buildInfoSummary
        }

        let info = Bundle.main.infoDictionary
        let identity = (info?["NexHubSigningIdentity"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let team = (info?["NexHubSigningTeam"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = (info?["NexHubSigningMode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let identity, !identity.isEmpty, let team, !team.isEmpty {
            return "\(identity) / Team \(team)"
        }
        if let identity, !identity.isEmpty {
            return identity
        }
        if let mode, !mode.isEmpty {
            return mode
        }
        return L10n.text(zhHans: "未知", en: "Unknown")
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func handleMoreSkillMenuItem(_ sender: NSMenuItem) {
        guard let skillID = sender.representedObject as? String else { return }
        runSkill(skillID)
    }

    private func resolvedStatusItemPopupFrame(for desired: CGRect, visibleFrame: CGRect) -> CGRect {
        let inset: CGFloat = 12
        let width = max(desired.width, 440)
        let height = max(desired.height, 340)
        let minX = visibleFrame.minX + inset
        let minY = visibleFrame.minY + inset
        let maxX = max(minX, visibleFrame.maxX - width - inset)
        let maxY = max(minY, visibleFrame.maxY - height - inset)
        let originX = min(max(desired.origin.x, minX), maxX)
        let originY = min(max(desired.origin.y, minY), maxY)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}
