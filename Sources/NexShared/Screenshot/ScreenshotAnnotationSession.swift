import AppKit
import Foundation

final class ScreenshotAnnotationSession {
    private typealias StateSnapshot = ScreenshotAnnotationEngine.StateSnapshot

    private let engine = ScreenshotAnnotationEngine()
    private let ellipsePromotionDelay: TimeInterval
    private var brushEllipsePromotionWorkItem: DispatchWorkItem?
    private var undoStack: [StateSnapshot] = []
    private var redoStack: [StateSnapshot] = []
    private var pendingUndoBaseline: StateSnapshot?

    init(ellipsePromotionDelay: TimeInterval = 0.3) {
        self.ellipsePromotionDelay = ellipsePromotionDelay
    }

    var selectedTool: ScreenshotEditingTool { engine.selectedTool }
    var selectedStrokeSize: ScreenshotStrokeSize { engine.selectedStrokeSize }
    var selectedColor: ScreenshotAnnotationColor { engine.selectedColor }
    var annotations: [ScreenshotOverlayAnnotation] { engine.annotations }
    var hasInFlightInteraction: Bool { engine.hasInFlightInteraction }
    var selectedTextAnnotationRect: CGRect? { engine.selectedTextAnnotationRect }
    var selectedTextAnnotation: ScreenshotTextAnnotation? { engine.selectedTextAnnotation }

    func reset() {
        cancelBrushEllipsePromotion()
        engine.reset()
        undoStack.removeAll()
        redoStack.removeAll()
        pendingUndoBaseline = nil
    }

    func clearAnnotationsPreservingStyle() {
        cancelBrushEllipsePromotion()
        engine.clearAnnotationsPreservingStyle()
        undoStack.removeAll()
        redoStack.removeAll()
        pendingUndoBaseline = nil
    }

    func setSelectedTool(_ tool: ScreenshotEditingTool) {
        engine.setSelectedTool(tool)
        cancelBrushEllipsePromotion()
        discardUndoGrouping()
    }

    func setSelectedStrokeSize(_ size: ScreenshotStrokeSize) {
        engine.setSelectedStrokeSize(size)
    }

    func setSelectedColor(_ color: ScreenshotAnnotationColor) {
        engine.setSelectedColor(color)
    }

    @discardableResult
    func beginInteraction(at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        let began = engine.beginInteraction(at: point, modifiers: modifiers)
        if began {
            beginUndoGroupingIfNeeded()
        }
        return began
    }

    @discardableResult
    func updateInteraction(at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        return engine.updateInteraction(at: point, modifiers: modifiers)
    }

    @discardableResult
    func finishInteraction() -> Bool {
        defer { cancelBrushEllipsePromotion() }
        let finished = engine.finishInteraction()
        if finished {
            commitUndoGroupingIfChanged()
        } else {
            discardUndoGrouping()
        }
        return finished
    }

    func cancelInFlightInteraction() {
        cancelBrushEllipsePromotion()
        engine.cancelInFlightInteraction()
        discardUndoGrouping()
    }

    func appendTextAnnotation(text: String, in rect: CGRect) {
        _ = performUndoableMutation {
            let before = engine.makeStateSnapshot()
            engine.appendTextAnnotation(text: text, in: rect)
            return engine.makeStateSnapshot() != before
        }
    }

    func clearTextSelection() {
        engine.clearTextSelection()
    }

    @discardableResult
    func selectTextAnnotation(at point: CGPoint) -> Bool {
        return engine.selectTextAnnotation(at: point)
    }

    @discardableResult
    func moveSelectedTextAnnotation(by delta: CGPoint, constrainedTo bounds: CGRect) -> Bool {
        beginUndoGroupingIfNeeded()
        return engine.moveSelectedTextAnnotation(by: delta, constrainedTo: bounds)
    }

    @discardableResult
    func deleteSelectedTextAnnotation() -> Bool {
        return performUndoableMutation {
            engine.deleteSelectedTextAnnotation()
        }
    }

    @discardableResult
    func updateSelectedTextAnnotation(text: String, rect: CGRect) -> Bool {
        return performUndoableMutation {
            engine.updateSelectedTextAnnotation(text: text, rect: rect)
        }
    }

    func drawCurrentAnnotations(hidingSelectedTextAnnotation: Bool) {
        engine.drawCurrentAnnotations(hidingSelectedTextAnnotation: hidingSelectedTextAnnotation)
    }

    func scheduleBrushEllipsePromotionIfNeeded(onPromoted: @escaping () -> Void) {
        cancelBrushEllipsePromotion()
        guard selectedTool == .brush else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.engine.promoteBrushInteractionToEllipseIfNeeded() {
                onPromoted()
            }
        }
        brushEllipsePromotionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ellipsePromotionDelay, execute: workItem)
    }

    func cancelBrushEllipsePromotion() {
        brushEllipsePromotionWorkItem?.cancel()
        brushEllipsePromotionWorkItem = nil
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func beginUndoGroupingIfNeeded() {
        guard pendingUndoBaseline == nil else { return }
        pendingUndoBaseline = engine.makeStateSnapshot()
    }

    func commitUndoGroupingIfChanged() {
        guard let baseline = pendingUndoBaseline else { return }
        pendingUndoBaseline = nil
        let current = engine.makeStateSnapshot()
        guard current != baseline else { return }
        undoStack.append(baseline)
        redoStack.removeAll()
    }

    func discardUndoGrouping() {
        pendingUndoBaseline = nil
    }

    @discardableResult
    func undo() -> Bool {
        cancelBrushEllipsePromotion()
        discardUndoGrouping()
        guard let snapshot = undoStack.popLast() else { return false }
        redoStack.append(engine.makeStateSnapshot())
        engine.restore(from: snapshot)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        cancelBrushEllipsePromotion()
        discardUndoGrouping()
        guard let snapshot = redoStack.popLast() else { return false }
        undoStack.append(engine.makeStateSnapshot())
        engine.restore(from: snapshot)
        return true
    }

    @discardableResult
    private func performUndoableMutation(_ mutation: () -> Bool) -> Bool {
        let baseline = engine.makeStateSnapshot()
        let mutated = mutation()
        guard mutated else { return false }
        let current = engine.makeStateSnapshot()
        guard current != baseline else { return false }
        undoStack.append(baseline)
        redoStack.removeAll()
        pendingUndoBaseline = nil
        return true
    }
}
