import Foundation

typealias TextEntryCoordinator = TextActivationCoordinator

final class TextSelectionCaptureService {
    private let selectionMonitor: SelectionMonitor

    init(selectionMonitor: SelectionMonitor) {
        self.selectionMonitor = selectionMonitor
    }

    func captureFromMouseSelectionIntent(strong: Bool) {
        selectionMonitor.captureFromMouseSelectionIntent(strong: strong)
    }

    func captureFromMouseDragIntent() {
        selectionMonitor.captureFromMouseDragIntent()
    }

    func captureFromKeyboardSelectionIntent() {
        selectionMonitor.captureFromKeyboardSelectionIntent()
    }
}
