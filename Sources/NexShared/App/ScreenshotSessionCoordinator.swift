import AppKit
import Foundation

protocol ScreenshotSessionCoordinatorDelegate: AnyObject {
    func screenshotSessionClearImageSelectionContext(_ coordinator: ScreenshotSessionCoordinator)
    func screenshotSessionSetSelectionActive(_ coordinator: ScreenshotSessionCoordinator, active: Bool)
    func screenshotSessionShowTransientPrompt(
        _ coordinator: ScreenshotSessionCoordinator,
        message: String,
        near anchor: NSRect,
        autoHideAfter: TimeInterval?
    )
    func screenshotSessionCopyImageToPasteboard(_ coordinator: ScreenshotSessionCoordinator, image: NSImage)
}

final class ScreenshotSessionCoordinator {
    weak var delegate: ScreenshotSessionCoordinatorDelegate?

    private let toolbarController: FloatingToolbarController
    private let selectionController: ScreenshotSelectionOverlayController
    private let previewController: ScreenshotScrollPreviewController
    private let scrollCoordinator: ScreenshotScrollCaptureCoordinator
    private let contentAnalyzer: ScreenshotContentAnalyzer

    init(
        toolbarController: FloatingToolbarController,
        selectionController: ScreenshotSelectionOverlayController,
        previewController: ScreenshotScrollPreviewController,
        scrollCoordinator: ScreenshotScrollCaptureCoordinator,
        contentAnalyzer: ScreenshotContentAnalyzer = .shared
    ) {
        self.toolbarController = toolbarController
        self.selectionController = selectionController
        self.previewController = previewController
        self.scrollCoordinator = scrollCoordinator
        self.contentAnalyzer = contentAnalyzer
    }

    func resetEditorStateForNewSession() {
        selectionController.setSelectedTool(.none)
        selectionController.setSelectedStrokeSize(.small)
        selectionController.setSelectedColor(.red)
        toolbarController.setScreenshotEditingState(
            tool: .none,
            strokeSize: .small,
            color: .red
        )
        toolbarController.setScreenshotToolbarMode(.editing)
    }

    func syncEditingStateToToolbar() {
        toolbarController.setScreenshotEditingState(
            tool: selectionController.selectedTool,
            strokeSize: selectionController.selectedStrokeSize,
            color: selectionController.selectedColor
        )
    }

    func makeImageSelectionSnapshot(
        from result: ScreenshotSelectionResult,
        sourceBundleID: String?
    ) -> ImageSelectionSnapshot {
        let pixelWidth = Int(result.selectionRect.width.rounded())
        let pixelHeight = Int(result.selectionRect.height.rounded())
        return ImageSelectionSnapshot(
            imageURL: result.imageURL,
            anchorPoint: result.anchorPoint,
            selectionRect: result.selectionRect,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            sourceBundleID: sourceBundleID,
            contentHints: contentAnalyzer.analyze(
                imageURL: result.imageURL,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        )
    }

    func makePreviewImageSelectionSnapshot(
        selectionRect: CGRect,
        anchorPoint: CGPoint,
        sourceBundleID: String?,
        currentSnapshot: ImageSelectionSnapshot?
    ) -> ImageSelectionSnapshot {
        let imageURL = currentSnapshot?.imageURL
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nexhub-pending.png")
        let preservedBundleID = currentSnapshot?.sourceBundleID ?? sourceBundleID
        return ImageSelectionSnapshot(
            imageURL: imageURL,
            anchorPoint: anchorPoint,
            selectionRect: selectionRect,
            pixelWidth: Int(selectionRect.width.rounded()),
            pixelHeight: Int(selectionRect.height.rounded()),
            sourceBundleID: preservedBundleID,
            contentHints: nil
        )
    }

    func presentToolbar(for snapshot: ImageSelectionSnapshot) {
        let toolbarOrigin = screenshotToolbarOrigin(
            for: snapshot,
            toolbarSize: toolbarController.expandedPanelSize()
        )
        toolbarController.showExpanded(atOrigin: toolbarOrigin)
    }

    func dismissLockedSession(clearImageSnapshot: Bool) {
        scrollCoordinator.cancel()
        previewController.hide()
        selectionController.dismissLockedSelection()
        delegate?.screenshotSessionSetSelectionActive(self, active: false)
        toolbarController.setWindowLevel(.floating)
        toolbarController.setScreenshotToolbarMode(.editing)
        if clearImageSnapshot {
            delegate?.screenshotSessionClearImageSelectionContext(self)
        }
    }

    func confirmLockedSelectionCopy() {
        selectionController.copyLockedSelectionToClipboard()
    }

    func setSelectedTool(_ tool: ScreenshotEditingTool) {
        selectionController.setSelectedTool(tool)
        syncEditingStateToToolbar()
    }

    func setSelectedStrokeSize(_ size: ScreenshotStrokeSize) {
        let restoredTool = preferredDrawingToolAfterStyleChange()
        if selectionController.selectedTool != restoredTool {
            selectionController.setSelectedTool(restoredTool)
        }
        selectionController.setSelectedStrokeSize(size)
        syncEditingStateToToolbar()
    }

    func setSelectedColor(_ color: ScreenshotAnnotationColor) {
        let restoredTool = preferredDrawingToolAfterStyleChange()
        if selectionController.selectedTool != restoredTool {
            selectionController.setSelectedTool(restoredTool)
        }
        selectionController.setSelectedColor(color)
        syncEditingStateToToolbar()
    }

    func handleScrollStateChanged(_ state: ScreenshotScrollCaptureCoordinator.State, currentImageSnapshot: ImageSelectionSnapshot?) {
        switch state {
        case .idle:
            selectionController.setInteractionSuspended(false)
            previewController.hide()
            if selectionController.hasLockedSelection {
                toolbarController.setScreenshotToolbarMode(.editing)
                if let snapshot = currentImageSnapshot {
                    toolbarController.updateRecognitionSlot(
                        .screenshotSize(width: snapshot.pixelWidth, height: snapshot.pixelHeight)
                    )
                    presentToolbar(for: snapshot)
                }
            }
        case .capturing:
            selectionController.setInteractionSuspended(true)
            toolbarController.setScreenshotToolbarMode(.scrollCapturing)
            toolbarController.updateRecognitionSlot(.screenshotSize(statusText: L10n.text(zhHans: "滚动截屏中", en: "Capturing scroll")))
            if let snapshot = currentImageSnapshot {
                presentToolbar(for: snapshot)
                previewController.show(near: snapshot.selectionRect)
            }
        case .finishing:
            selectionController.setInteractionSuspended(false)
            toolbarController.setScreenshotToolbarMode(.scrollFinishing)
            toolbarController.updateRecognitionSlot(.screenshotSize(statusText: L10n.text(zhHans: "正在拼接...", en: "Stitching...")))
            if let snapshot = currentImageSnapshot {
                presentToolbar(for: snapshot)
            }
        }
    }

    func beginScrollCaptureMode(currentImageSnapshot: ImageSelectionSnapshot?) {
        guard selectionController.hasLockedSelection,
              let selectionRect = currentImageSnapshot?.selectionRect else { return }
        scrollCoordinator.startCapture(selectionRect: selectionRect) { [weak self] success in
            guard let self else { return }
            if !success, let snapshot = currentImageSnapshot {
                self.delegate?.screenshotSessionShowTransientPrompt(
                    self,
                    message: L10n.text(zhHans: "长截屏启动失败", en: "Failed to start long capture"),
                    near: self.toolbarController.frame,
                    autoHideAfter: 1.6
                )
                self.toolbarController.setScreenshotToolbarMode(.editing)
                self.toolbarController.updateRecognitionSlot(
                    .screenshotSize(width: snapshot.pixelWidth, height: snapshot.pixelHeight)
                )
            }
        }
    }

    func finishScrollCapture(currentImageSnapshot: ImageSelectionSnapshot?) {
        scrollCoordinator.stopCapture { [weak self] image in
            guard let self else { return }
            guard let image else {
                self.toolbarController.setScreenshotToolbarMode(.editing)
                self.previewController.hide()
                if let snapshot = currentImageSnapshot {
                    self.toolbarController.updateRecognitionSlot(
                        .screenshotSize(width: snapshot.pixelWidth, height: snapshot.pixelHeight)
                    )
                }
                return
            }

            self.delegate?.screenshotSessionCopyImageToPasteboard(self, image: image)
            self.previewController.hide()
            self.dismissLockedSession(clearImageSnapshot: true)
            self.delegate?.screenshotSessionShowTransientPrompt(
                self,
                message: L10n.text(zhHans: "长截屏已复制到剪贴板", en: "Long capture copied to clipboard"),
                near: self.toolbarController.frame,
                autoHideAfter: 1.4
            )
        }
    }

    func cancelScrollCaptureMode() {
        scrollCoordinator.cancel()
        dismissLockedSession(clearImageSnapshot: true)
    }

    private func preferredDrawingToolAfterStyleChange() -> ScreenshotEditingTool {
        switch selectionController.selectedTool {
        case .brush, .rectangle, .arrow, .text:
            return selectionController.selectedTool
        case .none:
            return .brush
        }
    }

    private func screenshotToolbarOrigin(for snapshot: ImageSelectionSnapshot, toolbarSize: NSSize) -> CGPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(snapshot.selectionRect) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? snapshot.selectionRect.insetBy(dx: -120, dy: -120)
        let outsideGap: CGFloat = 10
        let insideGap: CGFloat = 10
        let screenInset = DesignTokens.Spacing.sm
        let clampedMinX = visibleFrame.minX + screenInset
        let clampedMaxX = visibleFrame.maxX - toolbarSize.width - screenInset
        let leadingAlignedX = snapshot.selectionRect.minX
        let trailingAlignedX = snapshot.selectionRect.maxX - toolbarSize.width
        let leftFits = leadingAlignedX >= clampedMinX && leadingAlignedX <= clampedMaxX
        let rightFits = trailingAlignedX >= clampedMinX && trailingAlignedX <= clampedMaxX
        let clampedLeadingX = max(clampedMinX, min(leadingAlignedX, clampedMaxX))
        let clampedTrailingX = max(clampedMinX, min(trailingAlignedX, clampedMaxX))
        let preferredAlignedX: CGFloat
        if snapshot.selectionRect.midX <= visibleFrame.midX {
            preferredAlignedX = leftFits ? leadingAlignedX : (rightFits ? trailingAlignedX : clampedLeadingX)
        } else {
            preferredAlignedX = rightFits ? trailingAlignedX : (leftFits ? leadingAlignedX : clampedTrailingX)
        }

        let availableAbove = visibleFrame.maxY - snapshot.selectionRect.maxY
        let availableBelow = snapshot.selectionRect.minY - visibleFrame.minY
        let prefersAbove = availableAbove >= availableBelow
        let aboveOriginY = snapshot.selectionRect.maxY + outsideGap
        let belowOriginY = snapshot.selectionRect.minY - toolbarSize.height - outsideGap
        let aboveFits = aboveOriginY + toolbarSize.height <= visibleFrame.maxY - screenInset
        let belowFits = belowOriginY >= visibleFrame.minY + screenInset

        let preferredOriginY: CGFloat
        if prefersAbove, aboveFits {
            preferredOriginY = aboveOriginY
        } else if !prefersAbove, belowFits {
            preferredOriginY = belowOriginY
        } else if aboveFits {
            preferredOriginY = aboveOriginY
        } else if belowFits {
            preferredOriginY = belowOriginY
        } else if prefersAbove {
            preferredOriginY = snapshot.selectionRect.maxY - toolbarSize.height - insideGap
        } else {
            preferredOriginY = snapshot.selectionRect.minY + insideGap
        }

        let clampedY = max(
            visibleFrame.minY + screenInset,
            min(preferredOriginY, visibleFrame.maxY - toolbarSize.height - screenInset)
        )
        return CGPoint(x: preferredAlignedX, y: clampedY)
    }
}
