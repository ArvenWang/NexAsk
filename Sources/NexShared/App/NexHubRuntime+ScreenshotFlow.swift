import AppKit

extension NexHubRuntime {
    func triggerScreenshotCaptureFlow() {
        guard AppProductProfile.current.supportsScreenshotEntry else { return }
        guard settings.screenshotEnabled,
              !isScreenshotSelectionActive,
              !productExperienceController.isSelectionOverlayActive else { return }
        productExperienceController.dismissConversation()
        dismissLockedScreenshotSession(clearImageSnapshot: true)
        dismissTransientWindows(forcePinned: true)

        let sourceBundleID = SelectionAccess.frontmostBundleID()
        isScreenshotSelectionActive = true
        screenshotSessionCoordinator.resetEditorStateForNewSession()
        screenshotSelectionController.start(
            onSelectionLocked: { [weak self] result in
                guard let self else { return }
                let snapshot = self.screenshotSessionCoordinator.makeImageSelectionSnapshot(
                    from: result,
                    sourceBundleID: sourceBundleID
                )
                self.selectionPresentationCoordinator.handleNewImageSnapshot(snapshot)
            },
            onSelectionPreviewChanged: { [weak self] selectionRect, anchorPoint in
                guard let self else { return }
                self.selectionPresentationCoordinator.previewImageSelectionGeometry(
                    selectionRect: selectionRect,
                    anchorPoint: anchorPoint,
                    sourceBundleID: sourceBundleID
                )
            },
            onSelectionUpdated: { [weak self] result in
                guard let self else { return }
                let snapshot = self.screenshotSessionCoordinator.makeImageSelectionSnapshot(
                    from: result,
                    sourceBundleID: sourceBundleID
                )
                self.selectionPresentationCoordinator.handleNewImageSnapshot(snapshot)
            },
            onSelectionCopied: { [weak self] _ in
                guard let self else { return }
                self.isScreenshotSelectionActive = false
                self.dismissLockedScreenshotSession(clearImageSnapshot: true)
            },
            onSessionCancelled: { [weak self] in
                guard let self else { return }
                self.isScreenshotSelectionActive = false
                self.selectionPresentationCoordinator.clearImageSelectionContext()
                self.refreshToolbarSkillLineup(
                    textSnapshot: self.currentSnapshot,
                    fileSnapshot: self.currentFileSnapshot,
                    imageSnapshot: nil
                )
                self.toolbarController.hide()
            }
        )
    }

    func isFinderFrontmost() -> Bool {
        SelectionAccess.frontmostBundleID() == "com.apple.finder"
    }

    func dismissTransientWindows(forcePinned: Bool) {
        selectionPresentationCoordinator.cancelPendingPresentation()
        inputEventCoordinator.handleSelectionCleared()
        skillPresentationCoordinator.finalizeToolbarExposureIfNeeded(recordDismissal: true)
        skillInvocationCoordinator.cancelCurrentAction(resetToolbar: true)
        screenshotSelectionController.dismissLockedSelection()
        toolbarController.hide()
        inlinePromptController.hide()
        resultController.hide(force: forcePinned)
    }

    func dismissLockedScreenshotSession(clearImageSnapshot: Bool) {
        isScreenshotSelectionActive = false
        screenshotSessionCoordinator.dismissLockedSession(clearImageSnapshot: clearImageSnapshot)
    }

    package func prepareForConversationSelectionCapture() {
        dismissLockedScreenshotSession(clearImageSnapshot: true)
        selectionPresentationCoordinator.cancelPendingPresentation()
        skillInvocationCoordinator.cancelCurrentAction(resetToolbar: true)
        selectionPresentationCoordinator.clearFileSelectionContext()
        selectionPresentationCoordinator.clearImageSelectionContext()
        toolbarController.hide()
        inlinePromptController.hide()
        resultController.hide(force: true)
    }

    func cancelScreenshotCaptureFlow() {
        guard isScreenshotSelectionActive || screenshotSelectionController.hasLockedSelection else { return }
        screenshotSelectionController.cancelSession()
    }

    func beginScrollCaptureMode() {
        screenshotSessionCoordinator.beginScrollCaptureMode(currentImageSnapshot: currentImageSnapshot)
    }

    func finishScrollCapture() {
        screenshotSessionCoordinator.finishScrollCapture(currentImageSnapshot: currentImageSnapshot)
    }

    func cancelScrollCaptureMode() {
        screenshotSessionCoordinator.cancelScrollCaptureMode()
    }

    func copyImageToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.writeObjects([image])
    }

    func makePreviewImageSelectionSnapshot(
        selectionRect: CGRect,
        anchorPoint: CGPoint,
        sourceBundleID: String?
    ) -> ImageSelectionSnapshot {
        screenshotSessionCoordinator.makePreviewImageSelectionSnapshot(
            selectionRect: selectionRect,
            anchorPoint: anchorPoint,
            sourceBundleID: sourceBundleID,
            currentSnapshot: currentImageSnapshot
        )
    }
}
