import AppKit

extension SettingsWindowController {
    @objc func handleRedeemInvite() {
        membershipPresenter.redeemInvite()
    }

    @objc func handleActivateLocalSubscription() {
        membershipPresenter.activateLocalSubscription()
    }

    @objc func handleCancelSubscription() {
        membershipPresenter.cancelSubscription()
    }

    @objc func handleAddKnowledgeBaseFiles() {
        knowledgeBaseImportCoordinator.importFiles()
    }

    @objc func handleToggleKnowledgeBaseManageMode() {
        setKnowledgeBaseManaging(!isKnowledgeBaseManaging)
    }

    @objc func handleToggleSelectAllKnowledgeBaseEntries() {
        let visibleIDs = Set(knowledgeBaseCoordinator.visibleEntries.map(\.id))
        if !visibleIDs.isEmpty, visibleIDs.isSubset(of: selectedKnowledgeBaseEntryIDs) {
            selectedKnowledgeBaseEntryIDs.subtract(visibleIDs)
        } else {
            selectedKnowledgeBaseEntryIDs.formUnion(visibleIDs)
        }
        renderKnowledgeBaseRows()
    }

    @objc func handleDeleteSelectedKnowledgeBaseEntries() {
        let selectedIDs = selectedKnowledgeBaseEntryIDs.intersection(Set(knowledgeBaseCoordinator.visibleEntries.map(\.id)))
        guard !selectedIDs.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = L10n.text(zhHans: "删除选中的知识资料？", en: "Delete the selected knowledge sources?")
        alert.informativeText = L10n.format(
            zhHans: "删除后，这 %d 份资料将不会再参与任何技能的知识库检索。",
            en: "After deletion, these %d sources will no longer participate in knowledge retrieval.",
            selectedIDs.count
        )
        alert.addButton(withTitle: L10n.text(zhHans: "删除", en: "Delete"))
        alert.addButton(withTitle: L10n.text(zhHans: "取消", en: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let deletedCount = selectedIDs.reduce(into: 0) { count, id in
            if knowledgeBaseStore.deleteEntry(id: id) {
                count += 1
            }
        }
        selectedKnowledgeBaseEntryIDs.subtract(selectedIDs)
        if deletedCount > 0 {
            reloadKnowledgeBaseEntries(status: L10n.format(
                zhHans: "已删除 %d 份知识资料。",
                en: "Deleted %d knowledge source(s).",
                deletedCount
            ))
            if knowledgeBaseCoordinator.visibleEntries.isEmpty {
                setKnowledgeBaseManaging(false)
            } else {
                renderKnowledgeBaseRows()
            }
        } else {
            updateKnowledgeBaseStatusMessage(L10n.text(zhHans: "批量删除失败，请稍后重试。", en: "Bulk deletion failed. Please try again shortly."))
        }
    }

    @objc func handleToggleKnowledgeBaseAutoSync() {
        reloadKnowledgeBaseEntries()
    }

    @objc func handleKnowledgeBaseSourceFilterTap(_ sender: NSButton) {
        knowledgeBaseCoordinator.handleSourceFilterTap(tab: KnowledgeBaseSourceTab(rawValue: sender.tag) ?? .all)
        resetKnowledgeBaseScrollPosition()
    }

    @objc func handleKnowledgeBasePreviousPage() {
        knowledgeBaseCoordinator.goToPreviousPage()
        resetKnowledgeBaseScrollPosition()
    }

    @objc func handleKnowledgeBaseNextPage() {
        knowledgeBaseCoordinator.goToNextPage()
        resetKnowledgeBaseScrollPosition()
    }

    @objc func handleBindKnowledgeBaseNotion() {
        handleInlineKnowledgeBaseNotionBinding()
    }

    @objc func handleRecordScreenshotShortcut() {
        screenshotShortcutCoordinator.toggleRecording()
    }

    @objc func handleResetScreenshotShortcut() {
        screenshotShortcutCoordinator.resetToDefault()
    }

    @objc func handleTestScreenshotShortcut() {
        onRequestTriggerScreenshotCapture?()
    }

    @objc func handleRefreshPermissionStatus() {
        permissionCoordinator.refreshStatus(logDiagnostic: true)
    }

    @objc func handleRequestAccessibilityPermission() {
        permissionCoordinator.requestAccessibilityPermission()
    }

    @objc func handleRequestCalendarPermission() {
        permissionCoordinator.requestCalendarPermission()
    }

    @objc func handleRequestAutomationPermission() {
        permissionCoordinator.requestAutomationPermission()
    }

    @objc func handleRequestAllNecessaryPermissions() {
        permissionCoordinator.requestAllNecessaryPermissions()
    }

    @objc func handleOpenInputMonitoringSettings() {
        permissionCoordinator.openInputMonitoringSettings()
    }

    @objc func handleOpenScreenRecordingSettings() {
        permissionCoordinator.openScreenRecordingSettings()
    }

    @objc func handleOpenFilesAndFoldersSettings() {
        permissionCoordinator.openFilesAndFoldersSettings()
    }

    @objc func handleOpenFullDiskAccessSettings() {
        permissionCoordinator.openFullDiskAccessSettings()
    }
}
