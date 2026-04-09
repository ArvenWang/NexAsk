import AppKit

extension NexHubRuntime: SelectionMonitorDelegate {
    func selectionMonitor(_ monitor: SelectionMonitor, didUpdate snapshot: SelectionSnapshot) {
        productExperienceController.handleSelectionSnapshot(snapshot)
        if productExperienceController.isSelectionOverlayActive {
            inputEventCoordinator.consumePendingClickSelectionExpansion()
            return
        }
        if skillInvocationCoordinator.isBusy || resultController.isTransitioning {
            inputEventCoordinator.consumePendingClickSelectionExpansion()
            return
        }
        selectionPresentationCoordinator.handleNewTextSnapshot(
            snapshot,
            gestureState: inputEventCoordinator.currentTextGestureState
        )
        inputEventCoordinator.consumePendingClickSelectionExpansion()
    }

    func selectionMonitorDidClearSelection(_ monitor: SelectionMonitor) {
        inputEventCoordinator.handleSelectionCleared()
        productExperienceController.handleSelectionCleared()
        guard !productExperienceController.isSelectionOverlayActive else { return }
        selectionPresentationCoordinator.handleTextSelectionCleared()
    }
}

extension NexHubRuntime: SkillInvocationCoordinatorDelegate {
    func skillInvocationSnapshotState(_ coordinator: SkillInvocationCoordinator) -> SkillInvocationSnapshotState {
        SkillInvocationSnapshotState(
            textSnapshot: currentSnapshot,
            fileSnapshot: currentFileSnapshot,
            imageSnapshot: currentImageSnapshot
        )
    }

    func skillInvocationSetScreenshotSelectionActive(_ coordinator: SkillInvocationCoordinator, active: Bool) {
        isScreenshotSelectionActive = active
    }

    func skillInvocationDismissLockedSelection(_ coordinator: SkillInvocationCoordinator) {
        screenshotSelectionController.dismissLockedSelection()
    }

    func skillInvocationDismissLockedScreenshotSession(
        _ coordinator: SkillInvocationCoordinator,
        clearImageSnapshot: Bool
    ) {
        dismissLockedScreenshotSession(clearImageSnapshot: clearImageSnapshot)
    }

    func skillInvocationShowTransientPrompt(
        _ coordinator: SkillInvocationCoordinator,
        message: String,
        near anchor: NSRect,
        actionTitle: String?,
        actionHandler: (() -> Void)?,
        autoHideAfter: TimeInterval?
    ) {
        showTransientPrompt(
            message,
            near: anchor,
            actionTitle: actionTitle,
            actionHandler: actionHandler,
            autoHideAfter: autoHideAfter
        )
    }

    func skillInvocationShowActionDisabledPrompt(
        _ coordinator: SkillInvocationCoordinator,
        definition: SkillDefinition,
        near anchor: NSRect
    ) {
        showActionDisabledPrompt(definition: definition, near: anchor)
    }

    func skillInvocationShowPermissionPrompt(_ coordinator: SkillInvocationCoordinator, near anchor: NSRect) {
        showPermissionPrompt(near: anchor)
    }

    func skillInvocationShowMissingAIConfigPrompt(_ coordinator: SkillInvocationCoordinator, near anchor: NSRect) {
        showMissingAIConfigPrompt(near: anchor)
    }

    func skillInvocationShowGatewayRuntimePrompt(
        _ coordinator: SkillInvocationCoordinator,
        snapshot: GatewayRuntimeSnapshot,
        near anchor: NSRect
    ) {
        showGatewayRuntimePrompt(snapshot: snapshot, near: anchor)
    }

    func skillInvocationShowEntitlementPrompt(
        _ coordinator: SkillInvocationCoordinator,
        definition: SkillDefinition,
        near anchor: NSRect
    ) {
        showEntitlementPrompt(definition: definition, near: anchor)
    }

    func skillInvocationShowRequestFailurePrompt(
        _ coordinator: SkillInvocationCoordinator,
        error: Error,
        near anchor: NSRect
    ) {
        showRequestFailurePrompt(error, near: anchor)
    }
}

extension NexHubRuntime: ScreenshotSessionCoordinatorDelegate {
    func screenshotSessionClearImageSelectionContext(_ coordinator: ScreenshotSessionCoordinator) {
        selectionPresentationCoordinator.clearImageSelectionContext()
    }

    func screenshotSessionSetSelectionActive(_ coordinator: ScreenshotSessionCoordinator, active: Bool) {
        isScreenshotSelectionActive = active
    }

    func screenshotSessionShowTransientPrompt(
        _ coordinator: ScreenshotSessionCoordinator,
        message: String,
        near anchor: NSRect,
        autoHideAfter: TimeInterval?
    ) {
        showTransientPrompt(message, near: anchor, autoHideAfter: autoHideAfter)
    }

    func screenshotSessionCopyImageToPasteboard(_ coordinator: ScreenshotSessionCoordinator, image: NSImage) {
        copyImageToPasteboard(image)
    }
}

extension NexHubRuntime: FloatingToolbarControllerDelegate {
    func floatingToolbar(_ controller: FloatingToolbarController, didTapSkill skillID: String) {
        runSkill(skillID)
    }

    func floatingToolbarDidTapScreenshotLongCapture(_ controller: FloatingToolbarController) {
        beginScrollCaptureMode()
    }

    func floatingToolbarDidTapScreenshotFinishScrolling(_ controller: FloatingToolbarController) {
        finishScrollCapture()
    }

    func floatingToolbarDidTapScreenshotCancelScrolling(_ controller: FloatingToolbarController) {
        cancelScrollCaptureMode()
    }

    func floatingToolbarDidTapScreenshotCancelSession(_ controller: FloatingToolbarController) {
        cancelScreenshotCaptureFlow()
    }

    func floatingToolbarDidTapScreenshotConfirm(_ controller: FloatingToolbarController) {
        screenshotSessionCoordinator.confirmLockedSelectionCopy()
    }

    func floatingToolbar(_ controller: FloatingToolbarController, didTapScreenshotTool tool: ScreenshotEditingTool) {
        screenshotSessionCoordinator.setSelectedTool(tool)
    }

    func floatingToolbar(_ controller: FloatingToolbarController, didTapScreenshotStrokeSize size: ScreenshotStrokeSize) {
        screenshotSessionCoordinator.setSelectedStrokeSize(size)
    }

    func floatingToolbar(_ controller: FloatingToolbarController, didTapScreenshotColor color: ScreenshotAnnotationColor) {
        screenshotSessionCoordinator.setSelectedColor(color)
    }

    func floatingToolbar(_ controller: FloatingToolbarController, didTapMoreWith secondarySkillIDs: [String]) {
        let menu = NSMenu()

        for skillID in secondarySkillIDs {
            guard let definition = actionRegistry.definition(forSkillID: skillID) else { continue }
            let item = NSMenuItem(
                title: definition.title,
                action: #selector(handleMoreSkillMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = skillID
            menu.addItem(item)
        }
        if !secondarySkillIDs.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(
            menuActionItem(
                L10n.text(zhHans: "获取更多技能…", en: "Get More Skills…"),
                action: #selector(showSkillCenter)
            )
        )
        menu.addItem(
            menuActionItem(
                L10n.text(zhHans: "设置…", en: "Settings…"),
                action: #selector(showActionManager)
            )
        )

        controller.present(menu: menu)
    }
}
