import AppKit
import CoreGraphics
import NexShared

#if !NEXHUB_PRODUCT_NEXHUB

struct AskBoxSelection {
    let startPoint: CGPoint
    let endPoint: CGPoint
    let rect: CGRect
}

final class AskBoxSelectionOverlayController {
    private final class OverlayWindow: NSWindow {
        init(frame: CGRect, contentView: NSView) {
            super.init(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            hidesOnDeactivate = false
            level = .statusBar
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            ignoresMouseEvents = true
            self.contentView = contentView
        }
    }

    private final class OverlayView: NSView {
        private(set) var screenFrame: CGRect = .zero
        private(set) var selectionRect: CGRect?
        private var drawSessionID: Int?
        private var hasReportedFirstDrawForSession = false
        var onFirstSelectionDraw: ((Int) -> Void)?

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let context = NSGraphicsContext.current?.cgContext else { return }

            context.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
            context.fill(bounds)

            guard let selectionRect else { return }
            let localRect = CGRect(
                x: selectionRect.minX - screenFrame.minX,
                y: selectionRect.minY - screenFrame.minY,
                width: selectionRect.width,
                height: selectionRect.height
            ).intersection(bounds)
            guard !localRect.isNull, localRect.width > 0, localRect.height > 0 else { return }
            let strokedRect = localRect.integral.insetBy(dx: 0.5, dy: 0.5)

            context.clear(localRect)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
            context.setLineWidth(1.6)
            context.stroke(strokedRect)

            if let drawSessionID, !hasReportedFirstDrawForSession {
                hasReportedFirstDrawForSession = true
                onFirstSelectionDraw?(drawSessionID)
            }
        }

        func configure(screenFrame: CGRect) {
            self.screenFrame = screenFrame
        }

        func update(selectionRect: CGRect?) {
            self.selectionRect = selectionRect
            needsDisplay = true
        }

        func configureDrawSession(_ sessionID: Int?, onFirstSelectionDraw: ((Int) -> Void)?) {
            drawSessionID = sessionID
            hasReportedFirstDrawForSession = false
            self.onFirstSelectionDraw = onFirstSelectionDraw
        }
    }

    private struct ScreenOverlay {
        let screenFrame: CGRect
        let window: OverlayWindow
        let view: OverlayView
    }

    private var overlays: [ScreenOverlay] = []
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var hasWarmedPresentation = false
    private let diagnosticsLogger = DiagnosticsLogger.shared
    private var sessionSequence = 0
    private var activeSessionID: Int?
    private var activeSessionStartedAt: CFAbsoluteTime?
    private var hasLoggedFirstDragForSession = false
    private var hasLoggedFirstDrawForSession = false

    var isActive: Bool {
        startPoint != nil
    }

    func prepare() {
        let prepareStartedAt = CFAbsoluteTimeGetCurrent()
        rebuildOverlaysIfNeeded()
        overlays.forEach { overlay in
            overlay.view.update(selectionRect: nil)
            overlay.window.orderOut(nil)
        }
        warmPresentationIfNeeded()
        diagnosticsLogger.log(
            "ask.entry",
            "overlay prepare screens=\(overlays.count) elapsed_ms=\(Self.elapsedMilliseconds(since: prepareStartedAt)) warmed=\(hasWarmedPresentation)"
        )
    }

    func begin(at point: CGPoint) {
        let beginStartedAt = CFAbsoluteTimeGetCurrent()
        sessionSequence += 1
        let sessionID = sessionSequence
        activeSessionID = sessionID
        activeSessionStartedAt = beginStartedAt
        hasLoggedFirstDragForSession = false
        hasLoggedFirstDrawForSession = false
        startPoint = point
        currentPoint = point

        let rebuildStartedAt = CFAbsoluteTimeGetCurrent()
        rebuildOverlaysIfNeeded()
        let rebuildElapsed = Self.elapsedMilliseconds(since: rebuildStartedAt)

        overlays.forEach { overlay in
            overlay.view.configureDrawSession(sessionID) { [weak self] drawSessionID in
                self?.logFirstDrawIfNeeded(for: drawSessionID)
            }
        }

        let updateStartedAt = CFAbsoluteTimeGetCurrent()
        updateSelectionRect()
        let updateElapsed = Self.elapsedMilliseconds(since: updateStartedAt)

        let orderFrontStartedAt = CFAbsoluteTimeGetCurrent()
        overlays.forEach { $0.window.orderFrontRegardless() }
        let orderFrontElapsed = Self.elapsedMilliseconds(since: orderFrontStartedAt)
        diagnosticsLogger.log(
            "ask.entry",
            "overlay begin session=\(sessionID) screens=\(overlays.count) point=(\(Int(point.x)),\(Int(point.y))) rebuild_ms=\(rebuildElapsed) update_ms=\(updateElapsed) orderFront_ms=\(orderFrontElapsed) total_ms=\(Self.elapsedMilliseconds(since: beginStartedAt))"
        )
    }

    func updateCurrentPoint(_ point: CGPoint) {
        guard isActive else { return }
        let updateStartedAt = CFAbsoluteTimeGetCurrent()
        currentPoint = point
        updateSelectionRect()
        if !hasLoggedFirstDragForSession, let sessionID = activeSessionID {
            hasLoggedFirstDragForSession = true
            diagnosticsLogger.log(
                "ask.entry",
                "overlay first_drag session=\(sessionID) point=(\(Int(point.x)),\(Int(point.y))) elapsed_ms=\(elapsedSinceSessionStart()) update_ms=\(Self.elapsedMilliseconds(since: updateStartedAt))"
            )
        }
    }

    func finish(at point: CGPoint) -> AskBoxSelection? {
        guard isActive else { return nil }
        currentPoint = point
        let selection = selection(start: startPoint, end: currentPoint)
        if let sessionID = activeSessionID {
            diagnosticsLogger.log(
                "ask.entry",
                "overlay finish session=\(sessionID) elapsed_ms=\(elapsedSinceSessionStart()) rect=\(Self.format(rect: selection?.rect))"
            )
        }
        cancel()
        guard let selection,
              selection.rect.width >= 6,
              selection.rect.height >= 6 else { return nil }
        return selection
    }

    func cancel() {
        if let sessionID = activeSessionID {
            diagnosticsLogger.log(
                "ask.entry",
                "overlay cancel session=\(sessionID) elapsed_ms=\(elapsedSinceSessionStart())"
            )
        }
        activeSessionID = nil
        activeSessionStartedAt = nil
        hasLoggedFirstDragForSession = false
        hasLoggedFirstDrawForSession = false
        startPoint = nil
        currentPoint = nil
        overlays.forEach { overlay in
            overlay.view.configureDrawSession(nil, onFirstSelectionDraw: nil)
            overlay.view.update(selectionRect: nil)
            overlay.window.orderOut(nil)
        }
    }

    private func rebuildOverlaysIfNeeded() {
        let screens = NSScreen.screens
        if overlays.count == screens.count,
           zip(overlays.map(\.screenFrame), screens.map(\.frame)).allSatisfy({ $0 == $1 }) {
            return
        }

        overlays.forEach { $0.window.orderOut(nil) }
        overlays.removeAll()
        hasWarmedPresentation = false

        for screen in screens {
            let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.configure(screenFrame: screen.frame)
            let window = OverlayWindow(frame: screen.frame, contentView: view)
            overlays.append(ScreenOverlay(screenFrame: screen.frame, window: window, view: view))
        }
    }

    private func warmPresentationIfNeeded() {
        guard !hasWarmedPresentation else { return }
        hasWarmedPresentation = true
        let warmStartedAt = CFAbsoluteTimeGetCurrent()

        for overlay in overlays {
            let window = overlay.window
            let previousAlpha = window.alphaValue
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.displayIfNeeded()
            overlay.view.displayIfNeeded()
            window.orderOut(nil)
            window.alphaValue = previousAlpha
        }
        diagnosticsLogger.log(
            "ask.entry",
            "overlay warm screens=\(overlays.count) elapsed_ms=\(Self.elapsedMilliseconds(since: warmStartedAt))"
        )
    }

    private func updateSelectionRect() {
        overlays.forEach { $0.view.update(selectionRect: selection(start: startPoint, end: currentPoint)?.rect) }
    }

    private func selection(start: CGPoint?, end: CGPoint?) -> AskBoxSelection? {
        guard let start, let end else { return nil }
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let rect = CGRect(x: minX, y: minY, width: abs(end.x - start.x), height: abs(end.y - start.y)).integral
        return AskBoxSelection(startPoint: start, endPoint: end, rect: rect)
    }

    private func logFirstDrawIfNeeded(for sessionID: Int) {
        guard activeSessionID == sessionID, !hasLoggedFirstDrawForSession else { return }
        hasLoggedFirstDrawForSession = true
        diagnosticsLogger.log(
            "ask.entry",
            "overlay first_draw session=\(sessionID) elapsed_ms=\(elapsedSinceSessionStart())"
        )
    }

    private func elapsedSinceSessionStart() -> Int {
        guard let activeSessionStartedAt else { return 0 }
        return Self.elapsedMilliseconds(since: activeSessionStartedAt)
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Int {
        Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
    }

    private static func format(rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return "(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height)))"
    }
}

#endif
