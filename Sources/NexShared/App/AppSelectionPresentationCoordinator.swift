import AppKit

struct TextSelectionGestureState {
    let mouseSelectionActive: Bool
    let mouseDidDragInCurrentGesture: Bool
    let pendingClickSelectionExpansion: Bool
}

final class AppSelectionPresentationCoordinator {
    private let settings: AppSettings
    private let textEntryCoordinator: TextEntryCoordinator
    private let fileEntryCoordinator: FileEntryCoordinator
    private let screenshotEntryCoordinator: ScreenshotEntryCoordinator
    private let toolbarController: FloatingToolbarController
    private let inlinePromptController: InlineActionPromptController
    private let skillInvocationCoordinator: SkillInvocationCoordinator
    private let skillPresentationCoordinator: SkillPresentationCoordinator
    private let screenshotSelectionController: ScreenshotSelectionOverlayController
    private let diagnosticsLogger: DiagnosticsLogger
    private let refreshToolbarSkillLineup: (SelectionSnapshot?, FileSelectionSnapshot?, ImageSelectionSnapshot?) -> Void
    private let makePreviewImageSelectionSnapshot: (CGRect, CGPoint, String?) -> ImageSelectionSnapshot
    private let presentScreenshotToolbar: (ImageSelectionSnapshot) -> Void

    private let clickSelectionPresentationDelay: TimeInterval
    private let dragSelectionPresentationDelay: TimeInterval
    private var pendingToolbarPresentationWorkItem: DispatchWorkItem?

    init(
        settings: AppSettings,
        textEntryCoordinator: TextEntryCoordinator,
        fileEntryCoordinator: FileEntryCoordinator,
        screenshotEntryCoordinator: ScreenshotEntryCoordinator,
        toolbarController: FloatingToolbarController,
        inlinePromptController: InlineActionPromptController,
        skillInvocationCoordinator: SkillInvocationCoordinator,
        skillPresentationCoordinator: SkillPresentationCoordinator,
        screenshotSelectionController: ScreenshotSelectionOverlayController,
        diagnosticsLogger: DiagnosticsLogger,
        clickSelectionPresentationDelay: TimeInterval = 0.2,
        dragSelectionPresentationDelay: TimeInterval = 0.08,
        refreshToolbarSkillLineup: @escaping (SelectionSnapshot?, FileSelectionSnapshot?, ImageSelectionSnapshot?) -> Void,
        makePreviewImageSelectionSnapshot: @escaping (CGRect, CGPoint, String?) -> ImageSelectionSnapshot,
        presentScreenshotToolbar: @escaping (ImageSelectionSnapshot) -> Void
    ) {
        self.settings = settings
        self.textEntryCoordinator = textEntryCoordinator
        self.fileEntryCoordinator = fileEntryCoordinator
        self.screenshotEntryCoordinator = screenshotEntryCoordinator
        self.toolbarController = toolbarController
        self.inlinePromptController = inlinePromptController
        self.skillInvocationCoordinator = skillInvocationCoordinator
        self.skillPresentationCoordinator = skillPresentationCoordinator
        self.screenshotSelectionController = screenshotSelectionController
        self.diagnosticsLogger = diagnosticsLogger
        self.clickSelectionPresentationDelay = clickSelectionPresentationDelay
        self.dragSelectionPresentationDelay = dragSelectionPresentationDelay
        self.refreshToolbarSkillLineup = refreshToolbarSkillLineup
        self.makePreviewImageSelectionSnapshot = makePreviewImageSelectionSnapshot
        self.presentScreenshotToolbar = presentScreenshotToolbar
    }

    var currentTextSnapshot: SelectionSnapshot? {
        textEntryCoordinator.currentSnapshot
    }

    var currentFileSnapshot: FileSelectionSnapshot? {
        fileEntryCoordinator.currentSnapshot
    }

    var currentImageSnapshot: ImageSelectionSnapshot? {
        screenshotEntryCoordinator.currentSnapshot
    }

    func cancelPendingPresentation() {
        pendingToolbarPresentationWorkItem?.cancel()
        pendingToolbarPresentationWorkItem = nil
    }

    func handleTextSelectionCleared() {
        cancelPendingPresentation()
        guard !toolbarController.isPresentingMenu else { return }
        textEntryCoordinator.clear()
        inlinePromptController.hide()
        refreshToolbarSkillLineup(nil, nil, nil)
        guard !toolbarController.isShowingLoadingState else {
            toolbarController.restoreLoadingPresentationIfNeeded()
            return
        }
        toolbarController.hide()
    }

    func handleNewTextSnapshot(_ snapshot: SelectionSnapshot, gestureState: TextSelectionGestureState) {
        let update = textEntryCoordinator.update(with: snapshot)
        fileEntryCoordinator.clear()
        screenshotEntryCoordinator.clear()
        toolbarController.setWindowLevel(.floating)
        inlinePromptController.hide()
        refreshToolbarSkillLineup(snapshot, nil, nil)
        diagnosticsLogger.log(
            "selection.present",
            "same=\(update.isSameSelection) mouseActive=\(gestureState.mouseSelectionActive) dragged=\(gestureState.mouseDidDragInCurrentGesture) length=\(snapshot.text.count)"
        )
        if !skillInvocationCoordinator.isBusy {
            toolbarController.setLoadingState(nil)
        }

        guard settings.textSelectionEnabled else { return }
        let presentationIntent = textEntryCoordinator.makePresentationIntent(
            for: update,
            context: TextPresentationContext(
                mouseSelectionActive: gestureState.mouseSelectionActive,
                mouseDidDragInCurrentGesture: gestureState.mouseDidDragInCurrentGesture,
                pendingClickSelectionExpansion: gestureState.pendingClickSelectionExpansion,
                toolbarIsVisible: toolbarController.isVisible,
                toolbarIsCompactPresentation: toolbarController.isCompactPresentation,
                clickSelectionPresentationDelay: clickSelectionPresentationDelay,
                dragSelectionPresentationDelay: dragSelectionPresentationDelay
            )
        )
        applyToolbarPresentationIntent(presentationIntent)
    }

    func handleNewFileSnapshot(_ snapshot: FileSelectionSnapshot) {
        guard snapshot.fileURLs.count > 1 else {
            clearFileSelectionContext()
            return
        }
        guard settings.fileSelectionEnabled else {
            clearFileSelectionContext()
            return
        }
        textEntryCoordinator.clear()
        let update = fileEntryCoordinator.update(
            with: snapshot,
            toolbarIsVisible: toolbarController.isVisible
        )
        screenshotEntryCoordinator.clear()
        toolbarController.setWindowLevel(.floating)
        inlinePromptController.hide()
        refreshToolbarSkillLineup(nil, snapshot, nil)
        diagnosticsLogger.log(
            "file.present",
            "same=\(update.isSameSelection) count=\(snapshot.fileURLs.count) bundle=\(snapshot.sourceBundleID ?? "unknown")"
        )

        guard settings.fileSelectionEnabled else { return }
        applyToolbarPresentationIntent(update.presentationIntent)
    }

    func handleNewImageSnapshot(_ snapshot: ImageSelectionSnapshot) {
        guard settings.screenshotEnabled else {
            clearImageSelectionContext()
            return
        }
        textEntryCoordinator.clear()
        fileEntryCoordinator.clear()
        let update = screenshotEntryCoordinator.update(
            with: snapshot,
            selectedTool: screenshotSelectionController.selectedTool,
            toolbarIsVisible: toolbarController.isVisible
        )
        toolbarController.setWindowLevel(.popUpMenu)
        let toolbarMode: ScreenshotToolbarMode = screenshotSelectionController.hasLockedSelection ? .editing : .longResult
        toolbarController.setScreenshotToolbarMode(toolbarMode)
        toolbarController.setScreenshotEditingState(
            tool: screenshotSelectionController.selectedTool,
            strokeSize: screenshotSelectionController.selectedStrokeSize,
            color: screenshotSelectionController.selectedColor
        )
        inlinePromptController.hide()
        if update.shouldRefreshToolbarLayout {
            refreshToolbarSkillLineup(nil, nil, snapshot)
        }
        diagnosticsLogger.log(
            "image.present",
            "path=\(snapshot.imageURL.path) bundle=\(snapshot.sourceBundleID ?? "unknown")"
        )

        guard settings.screenshotEnabled else { return }
        if update.shouldRefreshToolbarLayout {
            presentScreenshotToolbar(snapshot)
        }
    }

    func previewImageSelectionGeometry(
        selectionRect: CGRect,
        anchorPoint: CGPoint,
        sourceBundleID: String?
    ) {
        guard settings.screenshotEnabled else { return }
        toolbarController.setScreenshotEditingState(
            tool: screenshotSelectionController.selectedTool,
            strokeSize: screenshotSelectionController.selectedStrokeSize,
            color: screenshotSelectionController.selectedColor
        )
        toolbarController.setScreenshotToolbarMode(.editing)
        let snapshot = makePreviewImageSelectionSnapshot(selectionRect, anchorPoint, sourceBundleID)
        let update = screenshotEntryCoordinator.update(
            with: snapshot,
            selectedTool: screenshotSelectionController.selectedTool,
            toolbarIsVisible: toolbarController.isVisible
        )
        textEntryCoordinator.clear()
        fileEntryCoordinator.clear()
        toolbarController.setWindowLevel(.popUpMenu)
        if update.shouldRefreshToolbarLayout {
            refreshToolbarSkillLineup(nil, nil, snapshot)
        }
        toolbarController.updateRecognitionSlot(
            .screenshotSize(width: snapshot.pixelWidth, height: snapshot.pixelHeight)
        )
        presentScreenshotToolbar(snapshot)
    }

    func clearFileSelectionContext() {
        let hadFileSnapshot = fileEntryCoordinator.clear()
        guard hadFileSnapshot else { return }
        if textEntryCoordinator.currentSnapshot == nil {
            skillPresentationCoordinator.finalizeToolbarExposureIfNeeded(recordDismissal: true)
            skillPresentationCoordinator.clearRouteDiagnostics()
            if toolbarController.isShowingLoadingState {
                toolbarController.restoreLoadingPresentationIfNeeded()
            } else {
                toolbarController.hide()
            }
        }
        refreshToolbarSkillLineup(textEntryCoordinator.currentSnapshot, nil, screenshotEntryCoordinator.currentSnapshot)
    }

    func clearImageSelectionContext() {
        let hadImageSnapshot = screenshotEntryCoordinator.clear()
        guard hadImageSnapshot else { return }
        toolbarController.setWindowLevel(.floating)
        if textEntryCoordinator.currentSnapshot == nil && fileEntryCoordinator.currentSnapshot == nil {
            skillPresentationCoordinator.finalizeToolbarExposureIfNeeded(recordDismissal: true)
            skillPresentationCoordinator.clearRouteDiagnostics()
            if toolbarController.isShowingLoadingState {
                toolbarController.restoreLoadingPresentationIfNeeded()
            } else {
                toolbarController.hide()
            }
        }
        refreshToolbarSkillLineup(
            textEntryCoordinator.currentSnapshot,
            fileEntryCoordinator.currentSnapshot,
            nil
        )
    }

    private func applyToolbarPresentationIntent(_ intent: ToolbarPresentationIntent?) {
        guard let intent else { return }

        let presentation = { [weak self] in
            guard let self else { return }
            switch intent.style {
            case .compact:
                self.toolbarController.showCompact(at: intent.anchorPoint)
            case .reveal:
                self.toolbarController.reveal(at: intent.anchorPoint)
            case .revealImmediately:
                self.toolbarController.revealImmediately(at: intent.anchorPoint)
            case .show:
                self.toolbarController.show(at: intent.anchorPoint)
            }
        }

        cancelPendingPresentation()

        guard let delay = intent.delay else {
            presentation()
            return
        }

        let snapshotText = intent.snapshotTextGuard
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingToolbarPresentationWorkItem = nil
            if let snapshotText, self.textEntryCoordinator.currentSnapshot?.text != snapshotText {
                return
            }
            presentation()
        }
        pendingToolbarPresentationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
