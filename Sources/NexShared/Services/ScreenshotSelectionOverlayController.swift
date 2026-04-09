import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func privateAXUIElementGetWindow(
    _ element: AXUIElement,
    _ outWindowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

enum AXBridge {
    static func element(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func value(from value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXValue.self)
    }
}

struct ScreenshotSelectionResult {
    let imageURL: URL
    let selectionRect: CGRect
    let anchorPoint: CGPoint
}

final class ScreenshotSelectionOverlayController: NSObject {
    private struct ScreenOverlay {
        let screen: NSScreen
        let screenFrame: CGRect
        let window: ScreenshotSelectionWindow
        let selectionView: ScreenshotSelectionView
    }

    private enum SessionPhase {
        case idle
        case selecting
        case locked
    }

    private let window: ScreenshotSelectionWindow
    private let selectionView: ScreenshotSelectionView
    private let exportPipeline: ScreenshotExportPipeline
    private var additionalOverlays: [ScreenOverlay] = []
    private var onSelectionLocked: ((ScreenshotSelectionResult) -> Void)?
    private var onSelectionPreviewChanged: ((CGRect, CGPoint) -> Void)?
    private var onSelectionUpdated: ((ScreenshotSelectionResult) -> Void)?
    private var onSelectionCopied: ((URL) -> Void)?
    private var onSessionCancelled: (() -> Void)?
    private var shouldPassthroughScreenPoint: ((CGPoint) -> Bool)?
    private var localMouseMonitor: Any?
    private var phase: SessionPhase = .idle
    private let captureDelay: TimeInterval = 0.01
    private var frozenScreenImage: NSImage?
    private var exportGeneration: Int = 0
    private var screenUnionFrame: CGRect
    private weak var lockedSelectionView: ScreenshotSelectionView?
    private weak var engagedSelectionView: ScreenshotSelectionView?
    private var sessionOriginApplicationPID: pid_t?

    init(exportPipeline: ScreenshotExportPipeline = ScreenshotFeaturePlatformFactory.current().exportPipeline) {
        let frame = ScreenshotSelectionOverlayController.currentUnionFrame()
        let selectionView = ScreenshotSelectionView(frame: NSRect(origin: .zero, size: frame.size))
        self.selectionView = selectionView
        self.window = ScreenshotSelectionWindow(frame: frame, selectionView: selectionView)
        self.exportPipeline = exportPipeline
        self.screenUnionFrame = frame
        super.init()
        self.selectionView.updateScreenUnionFrame(frame)
        self.window.selectionDelegate = self
    }

    var hasLockedSelection: Bool {
        phase == .locked
    }

    var selectedTool: ScreenshotEditingTool {
        activeSelectionView.selectedTool
    }

    var selectedStrokeSize: ScreenshotStrokeSize {
        activeSelectionView.selectedStrokeSize
    }

    var selectedColor: ScreenshotAnnotationColor {
        activeSelectionView.selectedColor
    }

    func prepare() {
        let screens = NSScreen.screens
        let screenFrames = screens.map(\.frame)
        let unionFrame = screenFrames.reduce(CGRect.null) { partial, frame in
            partial.union(frame)
        }
        guard !unionFrame.isNull, unionFrame.width > 0, unionFrame.height > 0 else { return }
        screenUnionFrame = unionFrame
        rebuildScreenOverlays(for: screens, unionFrame: unionFrame)
        allSelectionViews.forEach { $0.prepareForNewSession() }
    }

    func start(
        onSelectionLocked: @escaping (ScreenshotSelectionResult) -> Void,
        onSelectionPreviewChanged: @escaping (CGRect, CGPoint) -> Void,
        onSelectionUpdated: @escaping (ScreenshotSelectionResult) -> Void,
        onSelectionCopied: @escaping (URL) -> Void,
        onSessionCancelled: @escaping () -> Void
    ) {
        if phase != .idle {
            dismissLockedSelection()
        }
        prepare()
        guard window.frame.width > 0, window.frame.height > 0 else {
            onSessionCancelled()
            return
        }

        self.onSelectionLocked = onSelectionLocked
        self.onSelectionPreviewChanged = onSelectionPreviewChanged
        self.onSelectionUpdated = onSelectionUpdated
        self.onSelectionCopied = onSelectionCopied
        self.onSessionCancelled = onSessionCancelled
        phase = .selecting
        sessionOriginApplicationPID = sessionOriginApplicationPIDForCurrentLaunch()
        lockedSelectionView = nil
        engagedSelectionView = nil
        allWindows.forEach {
            $0.level = .statusBar
            $0.ignoresMouseEvents = false
            $0.orderFrontRegardless()
        }
        allSelectionViews.forEach { $0.beginSession() }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let focusWindow = overlay(for: NSEvent.mouseLocation)?.window ?? window
        focusWindow.makeKey()
        focusWindow.makeFirstResponder(selectionView(for: focusWindow))
        installLocalMouseMonitor()
    }

    func dismissLockedSelection() {
        guard phase != .idle else { return }
        finishSession(notifyCancellation: false)
    }

    func cancelSession() {
        guard phase != .idle else { return }
        finishSession(notifyCancellation: true)
    }

    func setSelectedTool(_ tool: ScreenshotEditingTool) {
        allSelectionViews.forEach { $0.setSelectedTool(tool) }
    }

    func setSelectedStrokeSize(_ size: ScreenshotStrokeSize) {
        allSelectionViews.forEach { $0.setSelectedStrokeSize(size) }
    }

    func setSelectedColor(_ color: ScreenshotAnnotationColor) {
        allSelectionViews.forEach { $0.setSelectedColor(color) }
    }

    func copyLockedSelectionToClipboard() {
        guard phase == .locked,
              let lockedSelectionView else {
            return
        }
        lockedSelectionView.commitPendingTextAnnotationIfNeeded()
        guard let localRect = lockedSelectionView.currentLockedSelectionRect else { return }
        guard let image = exportedSelectionImage(for: localRect, annotations: lockedSelectionView.annotations) else { return }

        copyImageToPasteboard(image)
        if let imageURL = exportPipeline.writePNGImage(image) {
            onSelectionCopied?(imageURL)
        }
        finishSession(notifyCancellation: false)
    }

    func setMouseEventPassthroughHandler(_ handler: ((CGPoint) -> Bool)?) {
        shouldPassthroughScreenPoint = handler
        allSelectionViews.forEach { $0.shouldPassthroughScreenPoint = handler }
    }

    func setInteractionSuspended(_ suspended: Bool) {
        guard phase == .locked else { return }
        allWindows.forEach { $0.ignoresMouseEvents = suspended }
        allSelectionViews.forEach { $0.setInteractionSuspended(suspended) }
        if !suspended {
            guard let lockedSelectionView, let lockedWindow = lockedSelectionView.window else { return }
            lockedWindow.orderFrontRegardless()
            lockedWindow.makeKey()
            lockedWindow.makeFirstResponder(lockedSelectionView)
        }
    }

    private func installLocalMouseMonitor() {
        removeLocalMouseMonitor()
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]
        ) { [weak self] event in
            guard let self, self.phase != .idle else { return event }
            let screenPoint = self.screenPoint(for: event)
            if self.shouldPassthroughScreenPoint?(screenPoint) == true {
                return event
            }
            let targetSelectionView: ScreenshotSelectionView?
            if self.phase == .locked {
                targetSelectionView = self.lockedSelectionView ?? self.overlay(for: screenPoint)?.selectionView ?? self.overlay(for: event)?.selectionView
            } else if event.type == .leftMouseDragged || event.type == .leftMouseUp {
                targetSelectionView = self.engagedSelectionView ?? self.overlay(for: screenPoint)?.selectionView ?? self.overlay(for: event)?.selectionView
            } else {
                targetSelectionView = self.overlay(for: screenPoint)?.selectionView ?? self.overlay(for: event)?.selectionView
            }
            guard let targetSelectionView else {
                return event
            }
            if targetSelectionView.shouldAllowSystemHandling(for: event) {
                return event
            }
            if let eventWindow = event.window,
               let eventSelectionView = self.selectionView(for: eventWindow),
               eventSelectionView !== targetSelectionView,
               event.type == .leftMouseDown {
                return event
            }
            if event.type == .leftMouseDown {
                self.engagedSelectionView = targetSelectionView
            }
            self.handleObservedMouseEvent(event, in: targetSelectionView)
            if event.type == .leftMouseUp {
                self.engagedSelectionView = nil
            }
            return nil
        }
    }

    private func removeLocalMouseMonitor() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        localMouseMonitor = nil
    }

    private func handleObservedMouseEvent(_ event: NSEvent, in selectionView: ScreenshotSelectionView) {
        guard phase != .idle else { return }
        let screenPoint = screenPoint(for: event)
        if shouldPassthroughScreenPoint?(screenPoint) == true {
            return
        }
        selectionView.handleObservedMouseEvent(event)
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        return NSEvent.mouseLocation
    }

    private func finishSession(notifyCancellation: Bool) {
        phase = .idle
        removeLocalMouseMonitor()
        allSelectionViews.forEach { $0.prepareForNewSession() }
        allWindows.forEach {
            $0.ignoresMouseEvents = false
            $0.orderOut(nil)
        }
        lockedSelectionView = nil
        engagedSelectionView = nil
        let cancelledCallback = onSessionCancelled
        onSelectionLocked = nil
        onSelectionPreviewChanged = nil
        onSelectionUpdated = nil
        onSelectionCopied = nil
        onSessionCancelled = nil
        frozenScreenImage = nil
        exportGeneration = 0
        let originApplicationPID = sessionOriginApplicationPID
        sessionOriginApplicationPID = nil
        if notifyCancellation {
            cancelledCallback?()
            restoreSessionOriginApplicationIfNeeded(originApplicationPID)
        }
    }

    private func sessionOriginApplicationPIDForCurrentLaunch() -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return pid
    }

    private func restoreSessionOriginApplicationIfNeeded(_ pid: pid_t?) {
        guard let pid,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else {
            return
        }
        DispatchQueue.main.async {
            _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    private static func currentUnionFrame() -> CGRect {
        NSScreen.screens
            .map(\.frame)
            .reduce(CGRect.null) { partial, frame in
                partial.union(frame)
            }
    }

    private var allWindows: [ScreenshotSelectionWindow] {
        [window] + additionalOverlays.map(\.window)
    }

    private var allSelectionViews: [ScreenshotSelectionView] {
        [selectionView] + additionalOverlays.map(\.selectionView)
    }

    private var activeSelectionView: ScreenshotSelectionView {
        lockedSelectionView ?? selectionView
    }

    private func rebuildScreenOverlays(for screens: [NSScreen], unionFrame: CGRect) {
        let resolvedScreens = screens.isEmpty ? (NSScreen.main.map { [$0] } ?? []) : screens
        guard let primaryScreen = resolvedScreens.first else { return }

        window.setFrame(primaryScreen.frame, display: false)
        selectionView.frame = CGRect(origin: .zero, size: primaryScreen.frame.size)
        selectionView.updateScreenFrames(screen: primaryScreen, unionFrame: unionFrame)
        selectionView.delegate = self
        selectionView.shouldPassthroughScreenPoint = shouldPassthroughScreenPoint
        window.selectionDelegate = self

        additionalOverlays.forEach { $0.window.orderOut(nil) }
        additionalOverlays.removeAll()

        for screen in resolvedScreens.dropFirst() {
            let view = ScreenshotSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.delegate = self
            view.shouldPassthroughScreenPoint = shouldPassthroughScreenPoint
            view.updateScreenFrames(screen: screen, unionFrame: unionFrame)
            let overlayWindow = ScreenshotSelectionWindow(frame: screen.frame, selectionView: view)
            overlayWindow.selectionDelegate = self
            additionalOverlays.append(ScreenOverlay(screen: screen, screenFrame: screen.frame, window: overlayWindow, selectionView: view))
        }
    }

    private func overlay(for event: NSEvent) -> ScreenOverlay? {
        guard let eventWindow = event.window else { return nil }
        if eventWindow === window {
            let screen = selectionView.captureScreen ?? NSScreen.main ?? NSScreen.screens[0]
            return ScreenOverlay(screen: screen, screenFrame: window.frame, window: window, selectionView: selectionView)
        }
        return additionalOverlays.first(where: { $0.window === eventWindow })
    }

    private func overlay(for screenPoint: CGPoint) -> ScreenOverlay? {
        if window.frame.contains(screenPoint) {
            let screen = selectionView.captureScreen ?? NSScreen.main ?? NSScreen.screens[0]
            return ScreenOverlay(screen: screen, screenFrame: window.frame, window: window, selectionView: selectionView)
        }
        return additionalOverlays.first(where: { $0.screenFrame.contains(screenPoint) })
    }

    private func selectionView(for window: NSWindow) -> ScreenshotSelectionView? {
        if window === self.window { return selectionView }
        return additionalOverlays.first(where: { $0.window === window })?.selectionView
    }

}

extension ScreenshotSelectionOverlayController: ScreenshotSelectionViewDelegate {
    func screenshotSelectionDidCancel(_ selectionView: ScreenshotSelectionView) {
        guard phase != .idle else { return }
        finishSession(notifyCancellation: true)
    }

    func screenshotSelectionDidFinish(
        _ selectionView: ScreenshotSelectionView,
        localRect: CGRect,
        screenRect: CGRect,
        anchorPoint: CGPoint,
        ownerPID: pid_t?
    ) {
        guard phase == .selecting else { return }
        captureFrozenScreenAndLock(
            in: selectionView,
            localRect: localRect,
            screenRect: screenRect,
            anchorPoint: anchorPoint,
            ownerPID: ownerPID
        )
    }

    func screenshotSelectionDidUpdateLockedSelection(
        _ selectionView: ScreenshotSelectionView,
        localRect: CGRect,
        screenRect: CGRect,
        anchorPoint: CGPoint
    ) {
        guard phase == .locked else { return }
        exportSelectionFromFrozenScreenAsync(
            localRect: localRect,
            screenRect: screenRect,
            anchorPoint: anchorPoint,
            isInitialLock: false
        )
    }

    func screenshotSelectionDidPreviewLockedSelection(
        _ selectionView: ScreenshotSelectionView,
        localRect: CGRect,
        screenRect: CGRect,
        anchorPoint: CGPoint
    ) {
        guard phase == .locked else { return }
        onSelectionPreviewChanged?(screenRect, anchorPoint)
    }

    func screenshotSelectionDidRequestCopySelection(
        _ selectionView: ScreenshotSelectionView,
        localRect: CGRect,
        screenRect: CGRect
    ) {
        guard phase == .locked else { return }
        copyLockedSelectionToClipboard()
    }

    private func captureFrozenScreenAndLock(
        in selectionView: ScreenshotSelectionView,
        localRect: CGRect,
        screenRect: CGRect,
        anchorPoint: CGPoint,
        ownerPID: pid_t?
    ) {
        let fullScreenRect = selectionView.captureScreenFrame
        performFrozenScreenCapture(screenRect: fullScreenRect, restoreOverlay: true, ownerPID: ownerPID) { [weak self] frozenImage in
            guard let self else { return }
            guard let frozenImage else {
                self.finishSession(notifyCancellation: true)
                return
            }

            frozenImage.size = fullScreenRect.size
            self.frozenScreenImage = frozenImage
            self.lockSelection(
                in: selectionView,
                localRect: localRect,
                screenRect: screenRect,
                anchorPoint: anchorPoint
            )
            self.exportSelectionFromFrozenScreenAsync(
                localRect: localRect,
                screenRect: screenRect,
                anchorPoint: anchorPoint,
                isInitialLock: true
            )
        }
    }

    private func lockSelection(
        in selectionView: ScreenshotSelectionView,
        localRect: CGRect,
        screenRect: CGRect,
        anchorPoint: CGPoint
    ) {
        lockedSelectionView = selectionView
        selectionView.lockSelection(
            localRect,
            anchorPoint: selectionView.localPoint(fromScreenPoint: anchorPoint),
            previewImage: frozenScreenImage
        )
        allWindows
            .filter { $0 !== selectionView.window }
            .forEach { $0.orderOut(nil) }
        phase = .locked
        selectionView.window?.level = .floating
        selectionView.window?.ignoresMouseEvents = false
        selectionView.window?.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        selectionView.window?.makeKey()
        selectionView.window?.makeFirstResponder(selectionView)
        onSelectionPreviewChanged?(screenRect, anchorPoint)
    }

    private func exportSelectionFromFrozenScreenAsync(
        localRect: CGRect,
        screenRect: CGRect,
        anchorPoint: CGPoint,
        isInitialLock: Bool
    ) {
        exportGeneration += 1
        let generation = exportGeneration
        guard let frozenScreenImage else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let annotations = self.lockedSelectionView?.annotations ?? self.selectionView.annotations
            guard let image = self.exportedSelectionImage(
                from: frozenScreenImage,
                for: localRect,
                annotations: annotations
            ),
                  let imageURL = self.exportPipeline.writePNGImage(image) else {
                DispatchQueue.main.async {
                    guard self.exportGeneration == generation else { return }
                    self.finishSession(notifyCancellation: true)
                }
                return
            }

            let result = ScreenshotSelectionResult(
                imageURL: imageURL,
                selectionRect: screenRect,
                anchorPoint: anchorPoint
            )
            DispatchQueue.main.async {
                guard self.exportGeneration == generation else { return }
                self.publishSelectionResult(result, isInitialLock: isInitialLock)
            }
        }
    }

    private func publishSelectionResult(_ result: ScreenshotSelectionResult, isInitialLock: Bool) {
        if isInitialLock {
            onSelectionLocked?(result)
        } else {
            onSelectionUpdated?(result)
        }
    }

    private func copyImageToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.writeObjects([image])
    }

    private func performFrozenScreenCapture(
        screenRect: CGRect,
        restoreOverlay: Bool,
        ownerPID: pid_t?,
        completion: @escaping (NSImage?) -> Void
    ) {
        let shouldRestore = restoreOverlay && phase != .idle
        let previousStates = allWindows.map { ($0, $0.level, $0.ignoresMouseEvents, $0.isVisible) }

        if let ownerPID {
            raiseApplication(ownerPID: ownerPID)
        }

        allWindows.forEach { $0.orderOut(nil) }

        DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay) { [weak self] in
            ScreenCaptureKitRegionCapture.captureImage(in: screenRect) { image in
                DispatchQueue.main.async {
                    guard let self else {
                        completion(image)
                        return
                    }
                    if shouldRestore, self.phase != .idle {
                        previousStates.forEach { window, level, ignoresMouseEvents, wasVisible in
                            window.level = level
                            window.ignoresMouseEvents = ignoresMouseEvents
                            if wasVisible {
                                window.orderFrontRegardless()
                            }
                        }
                    }
                    completion(image)
                }
            }
        }
    }

    private func raiseApplication(ownerPID: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: ownerPID) else { return }
        _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        let appElement = AXUIElementCreateApplication(ownerPID)
        _ = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private func exportedSelectionImage(
        for localRect: CGRect,
        annotations: [ScreenshotOverlayAnnotation]
    ) -> NSImage? {
        guard let frozenScreenImage else { return nil }
        return exportedSelectionImage(from: frozenScreenImage, for: localRect, annotations: annotations)
    }

    private func exportedSelectionImage(
        from frozenScreenImage: NSImage,
        for localRect: CGRect,
        annotations: [ScreenshotOverlayAnnotation]
    ) -> NSImage? {
        exportPipeline.renderSelectionImage(
            ScreenshotExportRequest(
                frozenImage: frozenScreenImage,
                selectionRect: localRect,
                annotations: annotations
            )
        )
    }
}

protocol ScreenshotSelectionViewDelegate: AnyObject {
    func screenshotSelectionDidCancel(_ selectionView: ScreenshotSelectionView)
    func screenshotSelectionDidFinish(_ selectionView: ScreenshotSelectionView, localRect: CGRect, screenRect: CGRect, anchorPoint: CGPoint, ownerPID: pid_t?)
    func screenshotSelectionDidPreviewLockedSelection(_ selectionView: ScreenshotSelectionView, localRect: CGRect, screenRect: CGRect, anchorPoint: CGPoint)
    func screenshotSelectionDidUpdateLockedSelection(_ selectionView: ScreenshotSelectionView, localRect: CGRect, screenRect: CGRect, anchorPoint: CGPoint)
    func screenshotSelectionDidRequestCopySelection(_ selectionView: ScreenshotSelectionView, localRect: CGRect, screenRect: CGRect)
}

final class ScreenshotSelectionWindow: NSWindow {
    weak var selectionDelegate: ScreenshotSelectionViewDelegate? {
        didSet {
            (contentView as? ScreenshotSelectionView)?.delegate = selectionDelegate
        }
    }

    init(frame: CGRect, selectionView: ScreenshotSelectionView) {
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
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ScreenshotSelectionView: NSView {
    private enum RectCorner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private enum LockedInteraction {
        case moving(initialRect: CGRect, dragStartPoint: CGPoint)
        case resizing(handle: ResizeHandle, initialRect: CGRect, dragStartPoint: CGPoint)
        case movingTextAnnotation(lastPoint: CGPoint)
    }

    private enum ResizeHandle {
        case top
        case bottom
        case left
        case right
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private struct HoveredWindowInfo: Equatable {
        let ownerPID: pid_t
        let screenRect: CGRect
        let localRect: CGRect
    }

    private struct HoverResolution {
        let info: HoveredWindowInfo?
        let diagnostics: String
    }

    weak var delegate: ScreenshotSelectionViewDelegate?

    private let previewSurface = PanelSurfaceView(style: .toolbar)
    private let previewDimensionView = ScreenshotDimensionView()
    private let diagnosticsLogger = DiagnosticsLogger.shared

    private var dragStartPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var initialMouseDownPoint: CGPoint?
    private var pendingWindowSelection: HoveredWindowInfo?
    private var hoveredWindow: HoveredWindowInfo?
    private var lockedSelectionRect: CGRect?
    private var lockedPreviewImage: NSImage?
    private var lockedAnchorPoint: CGPoint?
    private var lockedInteraction: LockedInteraction?
    private var lockedInteractionDidMutateRect = false
    private var lockedSelectionState = ScreenshotLockedSelectionState()
    private var isDragging = false
    private var lastDragRawPoint: CGPoint?
    private var lastDragTimestamp: TimeInterval?
    private let lockedSelectionMinimumSize: CGFloat = 16
    private let resizeHandleSize: CGFloat = 10
    private let handleVisualSize: CGFloat = 8
    private let annotationSession = ScreenshotAnnotationSession()
    private var isInteractionSuspended = false
    private var lastHoverDiagnostics: String?
    private let textEditor = ScreenshotTextEditorView()
    private var isEditingExistingTextAnnotation = false
    private weak var currentScreen: NSScreen?
    private var screenFrame: CGRect = .zero
    private var screenUnionFrame: CGRect = .zero
    var shouldPassthroughScreenPoint: ((CGPoint) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    var selectedTool: ScreenshotEditingTool { annotationSession.selectedTool }
    var selectedStrokeSize: ScreenshotStrokeSize { annotationSession.selectedStrokeSize }
    var selectedColor: ScreenshotAnnotationColor { annotationSession.selectedColor }
    var annotations: [ScreenshotOverlayAnnotation] { annotationSession.annotations }
    var currentLockedSelectionRect: CGRect? { lockedSelectionRect }
    var captureScreenFrame: CGRect { effectiveScreenFrame }
    var captureScreen: NSScreen? { currentScreen }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configurePreview()
        configureTextEditor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePreview()
        configureTextEditor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isInteractionSuspended, let lockedSelectionRect {
            NSColor.black.withAlphaComponent(0.42).setFill()
            dirtyRect.fill()
            NSColor.clear.setFill()
            lockedSelectionRect.fill(using: .clear)
        } else if let lockedPreviewImage {
            lockedPreviewImage.draw(
                in: bounds,
                from: previewImageRectForCurrentScreen(),
                operation: .copy,
                fraction: 1
            )

            let overlayPath = NSBezierPath(rect: bounds)
            if let rect = displayRect {
                overlayPath.appendRect(rect)
            }
            overlayPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.42).setFill()
            overlayPath.fill()
        } else {
            NSColor.black.withAlphaComponent(0.42).setFill()
            dirtyRect.fill()

            guard let rect = displayRect else { return }
            NSColor.clear.setFill()
            rect.fill(using: .clear)
        }

        guard let rect = displayRect else { return }

        let strokeColor: NSColor
        if lockedSelectionRect != nil {
            strokeColor = isInteractionSuspended
                ? NSColor.white.withAlphaComponent(0.72)
                : NSColor.white.withAlphaComponent(0.98)
        } else if hoveredWindow != nil && !isDragging {
            strokeColor = NSColor.white.withAlphaComponent(0.82)
        } else {
            strokeColor = NSColor.white.withAlphaComponent(0.95)
        }

        strokeColor.setStroke()

        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.2
        path.stroke()

        if !isInteractionSuspended {
            drawAnnotations()
        }

        if lockedSelectionRect != nil && !isInteractionSuspended {
            drawResizeHandles(for: rect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        handleObservedMouseEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleObservedMouseEvent(event)
    }

    override func mouseUp(with event: NSEvent) {
        handleObservedMouseEvent(event)
    }

    override func mouseMoved(with event: NSEvent) {
        handleObservedMouseEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if textEditor.isEditing {
            if event.keyCode == 53 {
                cancelPendingTextAnnotation()
                return
            }
            super.keyDown(with: event)
            return
        }
        if handleUndoRedoShortcut(with: event) {
            return
        }
        if event.keyCode == 53 {
            delegate?.screenshotSelectionDidCancel(self)
            return
        }
        if selectedTool == .text, (event.keyCode == 51 || event.keyCode == 117) {
            if annotationSession.deleteSelectedTextAnnotation() {
                needsDisplay = true
            }
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
    }

    override func cursorUpdate(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let screenPoint = screenPoint(fromLocalPoint: localPoint)
        if shouldPassthroughScreenPoint?(screenPoint) == true {
            return
        }
        activeCursor(for: localPoint).set()
    }

    func prepareForNewSession() {
        dragStartPoint = nil
        currentPoint = nil
        initialMouseDownPoint = nil
        pendingWindowSelection = nil
        hoveredWindow = nil
        lockedSelectionRect = nil
        lockedPreviewImage = nil
        lockedAnchorPoint = nil
        lockedInteraction = nil
        lockedInteractionDidMutateRect = false
        lockedSelectionState.reset()
        isDragging = false
        lastDragRawPoint = nil
        lastDragTimestamp = nil
        isInteractionSuspended = false
        cancelBrushEllipsePromotion()
        textEditor.cancelEditing()
        isEditingExistingTextAnnotation = false
        annotationSession.reset()
        hidePreview()
        needsDisplay = true
    }

    func beginSession() {
        prepareForNewSession()
        NSCursor.crosshair.set()
        window?.makeFirstResponder(self)
        refreshHoveredWindow(at: localPoint(fromScreenPoint: NSEvent.mouseLocation))
    }

    func lockSelection(_ rect: CGRect, anchorPoint: CGPoint, previewImage: NSImage?) {
        commitPendingTextAnnotationIfNeeded()
        lockedSelectionRect = rect
        lockedPreviewImage = previewImage
        lockedAnchorPoint = anchorPoint
        dragStartPoint = nil
        currentPoint = nil
        initialMouseDownPoint = nil
        pendingWindowSelection = nil
        hoveredWindow = nil
        isDragging = false
        lockedInteraction = nil
        lockedInteractionDidMutateRect = false
        lockedSelectionState.reset()
        cancelBrushEllipsePromotion()
        hidePreview()
        needsDisplay = true
    }

    func setSelectedTool(_ tool: ScreenshotEditingTool) {
        if annotationSession.selectedTool == .text {
            commitPendingTextAnnotationIfNeeded()
        }
        annotationSession.setSelectedTool(tool)
        lockedInteractionDidMutateRect = false
        needsDisplay = true
    }

    func setSelectedStrokeSize(_ size: ScreenshotStrokeSize) {
        annotationSession.setSelectedStrokeSize(size)
        textEditor.updateStyle(fontSize: size.textFontSize, color: annotationSession.selectedColor.nsColor)
        needsDisplay = true
    }

    func setSelectedColor(_ color: ScreenshotAnnotationColor) {
        annotationSession.setSelectedColor(color)
        textEditor.updateStyle(fontSize: annotationSession.selectedStrokeSize.textFontSize, color: color.nsColor)
        needsDisplay = true
    }

    func setInteractionSuspended(_ suspended: Bool) {
        guard isInteractionSuspended != suspended else { return }
        isInteractionSuspended = suspended
        if suspended {
            lockedInteraction = nil
            lockedInteractionDidMutateRect = false
            annotationSession.cancelInFlightInteraction()
        }
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func shouldAllowSystemHandling(for event: NSEvent) -> Bool {
        guard textEditor.isEditing, event.window === window else { return false }
        let point = convert(event.locationInWindow, from: nil)
        return textEditor.contains(localPoint: point)
    }

    func commitPendingTextAnnotationIfNeeded() {
        textEditor.commitEditing()
    }

    func handleObservedMouseEvent(_ event: NSEvent) {
        let point = clampedPoint(currentMousePoint(), inside: bounds)
        let screenPoint = screenPoint(fromLocalPoint: point)
        if shouldPassthroughScreenPoint?(screenPoint) == true {
            return
        }
        activeCursor(for: point).set()
        if lockedSelectionState.isReselecting {
            handleLockedReselectionEvent(event, point: point)
            return
        }
        if lockedSelectionRect != nil {
            handleLockedMouseEvent(event, point: point)
            return
        }

        switch event.type {
        case .mouseMoved:
            refreshHoveredWindow(at: point)

        case .leftMouseDown:
            initialMouseDownPoint = point
            pendingWindowSelection = hoveredWindow
            if pendingWindowSelection == nil {
                beginFreeformSelection(at: point)
            } else {
                if let pendingWindowSelection {
                    raiseWindow(ownerPID: pendingWindowSelection.ownerPID, matching: pendingWindowSelection.screenRect)
                }
                hidePreview()
                needsDisplay = true
            }

        case .leftMouseDragged:
            let shouldBeginFreeform = shouldSwitchWindowClickToFreeform(at: point)
            if shouldBeginFreeform {
                pendingWindowSelection = nil
                beginFreeformSelection(at: initialMouseDownPoint ?? point)
            }
            if isDragging {
                updateFreeformSelection(to: point, timestamp: event.timestamp)
            }

        case .leftMouseUp:
            if let pendingWindowSelection {
                finalizeSelection(
                    withLocalRect: pendingWindowSelection.localRect,
                    localAnchorPoint: CGPoint(x: pendingWindowSelection.localRect.maxX, y: pendingWindowSelection.localRect.maxY),
                    ownerPID: pendingWindowSelection.ownerPID
                )
                return
            }
            if isDragging {
                finishFreeformSelection(at: point, timestamp: event.timestamp)
                return
            }
            delegate?.screenshotSelectionDidCancel(self)

        default:
            break
        }
    }

    func localPoint(fromScreenPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - effectiveScreenFrame.origin.x,
            y: point.y - effectiveScreenFrame.origin.y
        )
    }

    func updateScreenUnionFrame(_ frame: CGRect) {
        screenUnionFrame = frame
    }

    func updateScreenFrames(screen: NSScreen, unionFrame: CGRect) {
        currentScreen = screen
        self.screenFrame = screen.frame
        screenUnionFrame = unionFrame
    }

    private func currentMousePoint() -> CGPoint {
        let screenPoint = NSEvent.mouseLocation
        return localPoint(fromScreenPoint: screenPoint)
    }

    private func configurePreview() {
        wantsLayer = true

        previewSurface.isHidden = true
        previewSurface.translatesAutoresizingMaskIntoConstraints = true
        previewSurface.autoresizingMask = []

        previewDimensionView.setEmphasized(true)
        previewDimensionView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(previewSurface)
        previewSurface.addSubview(previewDimensionView)

        NSLayoutConstraint.activate([
            previewDimensionView.leadingAnchor.constraint(equalTo: previewSurface.leadingAnchor, constant: DesignTokens.Toolbar.compactInsetX),
            previewDimensionView.trailingAnchor.constraint(equalTo: previewSurface.trailingAnchor, constant: -DesignTokens.Toolbar.compactInsetX),
            previewDimensionView.centerYAnchor.constraint(equalTo: previewSurface.centerYAnchor)
        ])
    }

    private func beginFreeformSelection(at point: CGPoint) {
        dragStartPoint = point
        currentPoint = point
        isDragging = true
        lastDragRawPoint = point
        lastDragTimestamp = nil
        hidePreview()
        needsDisplay = true
    }

    private func updateFreeformSelection(to rawPoint: CGPoint, timestamp: TimeInterval) {
        guard let dragStartPoint else { return }
        let adjustedPoint = adjustedDragPoint(rawPoint, from: dragStartPoint, timestamp: timestamp)
        currentPoint = adjustedPoint
        updatePreview(for: currentSelectionRect, cursorPoint: adjustedPoint)
        needsDisplay = true
    }

    private func finishFreeformSelection(at point: CGPoint, timestamp: TimeInterval) {
        guard isDragging else {
            delegate?.screenshotSelectionDidCancel(self)
            return
        }
        isDragging = false
        if let dragStartPoint {
            currentPoint = adjustedDragPoint(point, from: dragStartPoint, timestamp: timestamp)
        } else {
            currentPoint = point
        }

        guard let currentSelectionRect,
              currentSelectionRect.width >= 4,
              currentSelectionRect.height >= 4 else {
            delegate?.screenshotSelectionDidCancel(self)
            return
        }

        finalizeSelection(
            withLocalRect: currentSelectionRect,
            localAnchorPoint: nearestCornerPoint(to: currentPoint ?? point, in: currentSelectionRect),
            ownerPID: nil
        )
    }

    private func finalizeSelection(withLocalRect localRect: CGRect, localAnchorPoint: CGPoint, ownerPID: pid_t?) {
        hidePreview()
        let screenRect = screenRect(fromLocalRect: localRect)
        let anchor = screenPoint(fromLocalPoint: localAnchorPoint)
        delegate?.screenshotSelectionDidFinish(self, localRect: localRect, screenRect: screenRect, anchorPoint: anchor, ownerPID: ownerPID)
    }

    private func handleLockedMouseEvent(_ event: NSEvent, point: CGPoint) {
        guard let lockedSelectionRect else { return }

        switch event.type {
        case .mouseMoved:
            resetCursorRects()
            needsDisplay = true

        case .leftMouseDown:
            if textEditor.isEditing {
                if textEditor.contains(localPoint: point) {
                    return
                }
                commitPendingTextAnnotationIfNeeded()
            }

            if selectedTool == .text {
                guard lockedSelectionRect.contains(point) else {
                    annotationSession.clearTextSelection()
                    beginLockedReselection(at: point)
                    return
                }
                if annotationSession.selectTextAnnotation(at: point) {
                    if event.clickCount >= 2 {
                        beginEditingSelectedTextAnnotation()
                        return
                    }
                    lockedInteraction = .movingTextAnnotation(lastPoint: point)
                    lockedInteractionDidMutateRect = false
                    needsDisplay = true
                    return
                }
                annotationSession.clearTextSelection()
                beginTextAnnotation(at: clampedPoint(point, inside: lockedSelectionRect), in: lockedSelectionRect)
                return
            }

            if event.clickCount >= 2 {
                if lockedSelectionRect.contains(point) {
                    delegate?.screenshotSelectionDidRequestCopySelection(
                        self,
                        localRect: lockedSelectionRect,
                        screenRect: screenRect(fromLocalRect: lockedSelectionRect)
                    )
                } else {
                    delegate?.screenshotSelectionDidCancel(self)
                }
                return
            }

            if selectedTool == .brush || selectedTool == .rectangle || selectedTool == .arrow {
                guard lockedSelectionRect.contains(point) else {
                    beginLockedReselection(at: point)
                    return
                }
                _ = annotationSession.beginInteraction(at: point, modifiers: event.modifierFlags)
                lockedInteractionDidMutateRect = false
                scheduleBrushEllipsePromotionIfNeeded()
                return
            }

            if let handle = resizeHandle(at: point, in: lockedSelectionRect) {
                lockedInteraction = .resizing(handle: handle, initialRect: lockedSelectionRect, dragStartPoint: point)
                lockedInteractionDidMutateRect = false
                return
            }

            if lockedSelectionRect.contains(point) {
                lockedInteraction = .moving(initialRect: lockedSelectionRect, dragStartPoint: point)
                lockedInteractionDidMutateRect = false
                return
            }

            beginLockedReselection(at: point)

        case .leftMouseDragged:
            if annotationSession.hasInFlightInteraction {
                let nextPoint = clampedPoint(point, inside: lockedSelectionRect)
                lockedInteractionDidMutateRect = annotationSession.updateInteraction(
                    at: nextPoint,
                    modifiers: event.modifierFlags
                )
                scheduleBrushEllipsePromotionIfNeeded()
                needsDisplay = true
                return
            }
            guard let lockedInteraction else { return }
            let nextRect: CGRect?
            switch lockedInteraction {
            case let .moving(initialRect, dragStartPoint):
                nextRect = translatedLockedRect(initialRect: initialRect, dragStartPoint: dragStartPoint, currentPoint: point)
            case let .resizing(handle, initialRect, dragStartPoint):
                nextRect = resizedLockedRect(
                    handle: handle,
                    initialRect: initialRect,
                    dragStartPoint: dragStartPoint,
                    currentPoint: point,
                    modifiers: event.modifierFlags
                )
            case let .movingTextAnnotation(lastPoint):
                let delta = CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
                let moved = annotationSession.moveSelectedTextAnnotation(by: delta, constrainedTo: lockedSelectionRect)
                self.lockedInteraction = .movingTextAnnotation(lastPoint: point)
                lockedInteractionDidMutateRect = moved || lockedInteractionDidMutateRect
                if moved {
                    needsDisplay = true
                }
                return
            }

            guard let nextRect, nextRect != lockedSelectionRect else { return }
            self.lockedSelectionRect = nextRect
            let liveAnchorPoint = liveAnchorPoint(for: nextRect, currentPoint: point, interaction: lockedInteraction)
            lockedAnchorPoint = liveAnchorPoint
            delegate?.screenshotSelectionDidPreviewLockedSelection(
                self,
                localRect: nextRect,
                screenRect: screenRect(fromLocalRect: nextRect),
                anchorPoint: screenPoint(fromLocalPoint: liveAnchorPoint)
            )
            lockedInteractionDidMutateRect = true
            needsDisplay = true

        case .leftMouseUp:
            defer {
                lockedInteraction = nil
                lockedInteractionDidMutateRect = false
                cancelBrushEllipsePromotion()
            }
            if case .movingTextAnnotation = lockedInteraction {
                if lockedInteractionDidMutateRect {
                    annotationSession.commitUndoGroupingIfChanged()
                    needsDisplay = true
                } else {
                    annotationSession.discardUndoGrouping()
                }
                return
            }
            if annotationSession.hasInFlightInteraction {
                guard lockedInteractionDidMutateRect, annotationSession.finishInteraction() else { return }
                if let updatedRect = self.lockedSelectionRect {
                    let anchorPoint = nearestCornerPoint(to: point, in: updatedRect)
                    delegate?.screenshotSelectionDidUpdateLockedSelection(
                        self,
                        localRect: updatedRect,
                        screenRect: screenRect(fromLocalRect: updatedRect),
                        anchorPoint: screenPoint(fromLocalPoint: anchorPoint)
                    )
                }
                needsDisplay = true
                return
            }
            guard lockedInteractionDidMutateRect, let updatedRect = self.lockedSelectionRect else { return }
            let anchorPoint = nearestCornerPoint(to: point, in: updatedRect)
            lockedAnchorPoint = anchorPoint
            delegate?.screenshotSelectionDidUpdateLockedSelection(
                self,
                localRect: updatedRect,
                screenRect: screenRect(fromLocalRect: updatedRect),
                anchorPoint: screenPoint(fromLocalPoint: anchorPoint)
            )

        default:
            break
        }
    }

    private func beginLockedReselection(at point: CGPoint) {
        guard lockedSelectionRect != nil else { return }
        clearLockedSelectionArtifactsForReselection()
        lockedSelectionState.beginReselection(from: lockedSelectionRect, anchorPoint: lockedAnchorPoint)
        lockedSelectionRect = nil
        lockedAnchorPoint = nil
        lockedInteraction = nil
        lockedInteractionDidMutateRect = false
        hoveredWindow = nil
        pendingWindowSelection = nil
        initialMouseDownPoint = point
        beginFreeformSelection(at: point)
    }

    private func handleLockedReselectionEvent(_ event: NSEvent, point: CGPoint) {
        switch event.type {
        case .mouseMoved:
            needsDisplay = true

        case .leftMouseDragged:
            if isDragging {
                updateFreeformSelection(to: point, timestamp: event.timestamp)
            }

        case .leftMouseUp:
            finishLockedReselection(at: point, timestamp: event.timestamp)

        default:
            break
        }
    }

    private func finishLockedReselection(at point: CGPoint, timestamp: TimeInterval) {
        defer {
            lockedSelectionState.endReselection()
        }

        guard isDragging else {
            restorePreviousLockedSelectionIfNeeded()
            return
        }

        isDragging = false
        if let dragStartPoint {
            currentPoint = adjustedDragPoint(point, from: dragStartPoint, timestamp: timestamp)
        } else {
            currentPoint = point
        }

        guard let nextRect = currentSelectionRect,
              nextRect.width >= 4,
              nextRect.height >= 4 else {
            restorePreviousLockedSelectionIfNeeded()
            return
        }

        let anchorPoint = nearestCornerPoint(to: currentPoint ?? point, in: nextRect)
        lockedSelectionRect = nextRect
        lockedAnchorPoint = anchorPoint
        dragStartPoint = nil
        currentPoint = nil
        initialMouseDownPoint = nil
        hidePreview()
        delegate?.screenshotSelectionDidUpdateLockedSelection(
            self,
            localRect: nextRect,
            screenRect: screenRect(fromLocalRect: nextRect),
            anchorPoint: screenPoint(fromLocalPoint: anchorPoint)
        )
        needsDisplay = true
    }

    private func restorePreviousLockedSelectionIfNeeded() {
        lockedSelectionRect = lockedSelectionState.restoreRect
        lockedAnchorPoint = lockedSelectionState.restoreAnchorPoint
        dragStartPoint = nil
        currentPoint = nil
        initialMouseDownPoint = nil
        hidePreview()
        needsDisplay = true
    }

    private func clearLockedSelectionArtifactsForReselection() {
        if textEditor.isEditing {
            textEditor.cancelEditing()
        }
        isEditingExistingTextAnnotation = false
        annotationSession.cancelInFlightInteraction()
        annotationSession.discardUndoGrouping()
        annotationSession.clearAnnotationsPreservingStyle()
    }

    private func handleUndoRedoShortcut(with event: NSEvent) -> Bool {
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key == "z" else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let usesUndoModifier = flags.contains(.command) || flags.contains(.control)
        guard usesUndoModifier else { return false }

        let isRedo = flags.contains(.shift)
        let handled = isRedo ? annotationSession.redo() : annotationSession.undo()
        if handled {
            lockedInteraction = nil
            lockedInteractionDidMutateRect = false
            needsDisplay = true
        }
        return handled
    }

    private func updatePreview(for rect: CGRect?, cursorPoint: CGPoint) {
        guard let rect else {
            hidePreview()
            return
        }
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        guard width > 0, height > 0 else {
            hidePreview()
            return
        }

        previewDimensionView.setDimensions(
            ScreenshotDimensionValue(width: width, height: height),
            animated: true
        )
        previewDimensionView.layoutSubtreeIfNeeded()
        previewDimensionView.displayIfNeeded()

        let contentSize = previewDimensionView.fittingSize
        let surfaceSize = NSSize(
            width: ceil(contentSize.width + DesignTokens.Toolbar.compactInsetX * 2),
            height: DesignTokens.Toolbar.compactHeight
        )
        previewSurface.frame = CGRect(
            origin: previewOrigin(near: cursorPoint, size: surfaceSize),
            size: surfaceSize
        )
        previewSurface.isHidden = false
        previewSurface.layoutSubtreeIfNeeded()
        previewSurface.displayIfNeeded()
    }

    private func hidePreview() {
        previewSurface.isHidden = true
    }

    private func drawResizeHandles(for rect: CGRect) {
        let half = handleVisualSize / 2
        for center in handleCenters(for: rect) {
            let handleRect = CGRect(
                x: center.x - half,
                y: center.y - half,
                width: handleVisualSize,
                height: handleVisualSize
            )
            NSColor.white.setFill()
            NSBezierPath(rect: handleRect).fill()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            let outline = NSBezierPath(rect: handleRect.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    private func drawAnnotations() {
        annotationSession.drawCurrentAnnotations(hidingSelectedTextAnnotation: isEditingExistingTextAnnotation)
        drawSelectedTextAnnotationOutline()
    }

    private func configureTextEditor() {
        textEditor.isHidden = true
        textEditor.onCommit = { [weak self] text, rect in
            guard let self else { return }
            if self.isEditingExistingTextAnnotation {
                _ = self.annotationSession.updateSelectedTextAnnotation(text: text, rect: rect)
            } else {
                self.annotationSession.appendTextAnnotation(text: text, in: rect)
            }
            self.isEditingExistingTextAnnotation = false
            self.window?.makeFirstResponder(self)
            self.needsDisplay = true
        }
        textEditor.onCancel = { [weak self] in
            self?.isEditingExistingTextAnnotation = false
            self?.window?.makeFirstResponder(self)
            self?.needsDisplay = true
        }
        addSubview(textEditor)
    }

    private func beginTextAnnotation(at point: CGPoint, in selectionRect: CGRect) {
        isEditingExistingTextAnnotation = false
        textEditor.beginEditing(
            at: point,
            selectionRect: selectionRect,
            fontSize: annotationSession.selectedStrokeSize.textFontSize,
            color: annotationSession.selectedColor.nsColor,
            initialText: "",
            preferredRect: nil,
            in: self
        )
        window?.makeFirstResponder(textEditor.textView)
    }

    private func beginEditingSelectedTextAnnotation() {
        guard let annotation = annotationSession.selectedTextAnnotation,
              let lockedSelectionRect else { return }
        isEditingExistingTextAnnotation = true
        textEditor.beginEditing(
            at: annotation.rect.origin,
            selectionRect: lockedSelectionRect,
            fontSize: annotation.fontSize,
            color: annotation.color.nsColor,
            initialText: annotation.text,
            preferredRect: annotation.rect,
            in: self
        )
        window?.makeFirstResponder(textEditor.textView)
    }

    private func cancelPendingTextAnnotation() {
        textEditor.cancelEditing()
        isEditingExistingTextAnnotation = false
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func handleCenters(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
    }

    private func previewOrigin(near point: CGPoint, size: NSSize) -> CGPoint {
        let inset = DesignTokens.Spacing.sm
        let x = max(inset, min(point.x - size.width / 2, bounds.width - size.width - inset))
        var y = point.y + 12
        if y + size.height > bounds.maxY - inset {
            y = point.y - size.height - 12
        }
        y = max(inset, min(y, bounds.maxY - size.height - inset))
        return CGPoint(x: x, y: y)
    }

    private func shouldSwitchWindowClickToFreeform(at point: CGPoint) -> Bool {
        guard pendingWindowSelection != nil, let initialMouseDownPoint else { return false }
        let dx = point.x - initialMouseDownPoint.x
        let dy = point.y - initialMouseDownPoint.y
        return (dx * dx + dy * dy) >= 16
    }

    private func refreshHoveredWindow(at point: CGPoint) {
        guard !isDragging, lockedSelectionRect == nil else { return }
        let resolution = resolveHoveredWindow(at: point)
        let nextHoveredWindow = resolution.info
        if nextHoveredWindow != hoveredWindow {
            hoveredWindow = nextHoveredWindow
            if resolution.diagnostics != lastHoverDiagnostics {
                diagnosticsLogger.log("screenshot.windowHover", resolution.diagnostics)
                lastHoverDiagnostics = resolution.diagnostics
            }
        }
        if let hoveredWindow {
            updatePreview(for: hoveredWindow.localRect, cursorPoint: point)
        } else {
            hidePreview()
        }
        needsDisplay = true
    }

    private func resolveHoveredWindow(at localPoint: CGPoint) -> HoverResolution {
        let screenPoint = screenPoint(fromLocalPoint: localPoint)
        let overlayWindowID = window.map { CGWindowID($0.windowNumber) }
        let hoveredWindow = topmostWindow(
            containingScreenPoint: screenPoint,
            belowWindowID: overlayWindowID
        ) ?? accessibilityWindow(containingScreenPoint: screenPoint)

        if let hoveredWindow {
            let cocoaRect = hoveredWindow.bounds
            let hitScreen = screenContaining(screenPoint)
            let info = HoveredWindowInfo(
                ownerPID: hoveredWindow.ownerPID,
                screenRect: cocoaRect,
                localRect: cocoaRect.offsetBy(
                    dx: -effectiveScreenFrame.origin.x,
                    dy: -effectiveScreenFrame.origin.y
                )
            )
            let bundleID = NSRunningApplication(processIdentifier: hoveredWindow.ownerPID)?.bundleIdentifier ?? "unknown"
            let diagnostics = [
                "mouse=\(format(point: screenPoint))",
                "source=\(hoveredWindow.source)",
                "pid=\(hoveredWindow.ownerPID)",
                "bundle=\(bundleID)",
                "bounds=\(format(rect: hoveredWindow.bounds))",
                hoveredWindow.rawBounds.map { "raw=\(format(rect: $0))" },
                hoveredWindow.convertedBounds.map { "converted=\(format(rect: $0))" },
                hoveredWindow.windowNumber.map { "windowNumber=\($0)" },
                hoveredWindow.axFrame.map { "axFrame=\(format(rect: $0))" },
                hoveredWindow.resolvedBounds.map { "resolved=\(format(rect: $0))" },
                hitScreen.map { "screen=\(format(rect: $0.frame))" }
            ]
                .compactMap { $0 }
                .joined(separator: " ")
            return HoverResolution(info: info, diagnostics: diagnostics)
        }

        return HoverResolution(
            info: nil,
            diagnostics: "mouse=\(format(point: screenPoint)) source=none"
        )
    }

    private struct WindowHitResult {
        let ownerPID: pid_t
        let bounds: CGRect
        let source: String
        let windowNumber: CGWindowID?
        let axFrame: CGRect?
        let resolvedBounds: CGRect?
        let rawBounds: CGRect?
        let convertedBounds: CGRect?
    }

    private struct AXWindowFrameCandidate {
        let ownerPID: pid_t
        let frame: CGRect
        let windowNumber: CGWindowID?
    }

    private func topmostWindow(
        containingScreenPoint point: CGPoint,
        belowWindowID: CGWindowID?,
        ownerPIDFilter: pid_t? = nil
    ) -> WindowHitResult? {
        let listOption: CGWindowListOption = belowWindowID == nil
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionOnScreenBelowWindow, .excludeDesktopElements]
        let relativeWindow = belowWindowID ?? kCGNullWindowID
        guard let infoList = CGWindowListCopyWindowInfo(listOption, relativeWindow)
                as? [[String: Any]] else {
            return nil
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != currentPID,
                  (ownerPIDFilter == nil || ownerPID == ownerPIDFilter),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  alpha > 0.01,
                  let boundsValue = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsValue) else {
                continue
            }

            let convertedBounds = cocoaRect(fromSystemRect: bounds)
            guard convertedBounds.width >= 80,
                  convertedBounds.height >= 48,
                  convertedBounds.contains(point) else {
                continue
            }

            let windowNumber = (info[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
            let quartzHit = WindowHitResult(
                ownerPID: ownerPID,
                bounds: convertedBounds,
                source: "quartz",
                windowNumber: windowNumber,
                axFrame: nil,
                resolvedBounds: nil,
                rawBounds: bounds,
                convertedBounds: convertedBounds
            )
            return refinedWindowHit(quartzHit, forScreenPoint: point)
        }
        return nil
    }

    private func accessibilityWindow(containingScreenPoint point: CGPoint) -> WindowHitResult? {
        guard let hitElement = accessibilityHitElement(containingScreenPoint: point) else { return nil }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        var ownerPID: pid_t = 0
        AXUIElementGetPid(hitElement, &ownerPID)
        guard ownerPID != currentPID else { return nil }

        if let directWindow = accessibilityOwningWindow(of: hitElement),
           let frame = accessibilityFrame(for: directWindow, near: point) {
            let windowNumber = accessibilityWindowNumber(of: directWindow)
            let resolvedBounds = preferredHoverBounds(
                for: directWindow,
                ownerPID: ownerPID,
                screenPoint: point,
                fallbackFrame: frame
            )
            guard resolvedBounds.width >= 80,
                  resolvedBounds.height >= 48,
                  resolvedBounds.contains(point) else {
                return nil
            }
            return WindowHitResult(
                ownerPID: ownerPID,
                bounds: resolvedBounds,
                source: "ax.windowAttribute",
                windowNumber: windowNumber,
                axFrame: frame,
                resolvedBounds: resolvedBounds,
                rawBounds: nil,
                convertedBounds: frame
            )
        }

        var cursor: AXUIElement? = hitElement
        var depth = 0
        while depth < 12, let element = cursor {
            if accessibilityRole(of: element) == kAXWindowRole as String,
               let frame = accessibilityFrame(for: element, near: point) {
                let windowNumber = accessibilityWindowNumber(of: element)
                let resolvedBounds = preferredHoverBounds(
                    for: element,
                    ownerPID: ownerPID,
                    screenPoint: point,
                    fallbackFrame: frame
                )
                guard resolvedBounds.width >= 80,
                      resolvedBounds.height >= 48,
                      resolvedBounds.contains(point) else {
                    return nil
                }
                return WindowHitResult(
                    ownerPID: ownerPID,
                    bounds: resolvedBounds,
                    source: "ax.parentChain",
                    windowNumber: windowNumber,
                    axFrame: frame,
                    resolvedBounds: resolvedBounds,
                    rawBounds: nil,
                    convertedBounds: frame
                )
            }
            cursor = accessibilityParent(of: element)
            depth += 1
        }

        let candidateWindows = accessibilityWindows(for: ownerPID).compactMap { window -> (WindowHitResult, CGFloat)? in
            guard let frame = accessibilityFrame(for: window, near: point) else {
                return nil
            }
            let windowNumber = accessibilityWindowNumber(of: window)
            let resolvedBounds = preferredHoverBounds(
                for: window,
                ownerPID: ownerPID,
                screenPoint: point,
                fallbackFrame: frame
            )
            guard resolvedBounds.width >= 80,
                  resolvedBounds.height >= 48,
                  resolvedBounds.contains(point) else {
                return nil
            }
            let result = WindowHitResult(
                ownerPID: ownerPID,
                bounds: resolvedBounds,
                source: "ax.windowList",
                windowNumber: windowNumber,
                axFrame: frame,
                resolvedBounds: resolvedBounds,
                rawBounds: nil,
                convertedBounds: frame
            )
            return (result, resolvedBounds.width * resolvedBounds.height)
        }

        if let bestWindow = candidateWindows.min(by: { $0.1 < $1.1 }) {
            return bestWindow.0
        }

        return nil
    }

    private func accessibilityRole(of element: AXUIElement) -> String? {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else {
            return nil
        }
        return role
    }

    private func accessibilityWindowNumber(of element: AXUIElement) -> CGWindowID? {
        var numberValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXWindowNumber" as CFString, &numberValue) == .success,
              let number = numberValue as? NSNumber else {
            var windowID: CGWindowID = 0
            let result = privateAXUIElementGetWindow(element, &windowID)
            guard result == .success, windowID != 0 else {
                return nil
            }
            return windowID
        }
        return CGWindowID(number.uint32Value)
    }

    private func accessibilityOwningWindow(of element: AXUIElement) -> AXUIElement? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
              let window = AXBridge.element(from: windowValue) else {
            return nil
        }
        return window
    }

    private func accessibilityParent(of element: AXUIElement) -> AXUIElement? {
        var parentValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
              let parent = AXBridge.element(from: parentValue) else {
            return nil
        }
        return parent
    }

    private func accessibilityWindows(for ownerPID: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(ownerPID)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windowsValue else {
            return []
        }

        if let windows = windowsValue as? [AXUIElement] {
            return windows
        }

        if let rawWindows = windowsValue as? [AnyObject] {
            return rawWindows.compactMap {
                AXBridge.element(from: $0)
            }
        }

        return []
    }

    private func preferredHoverBounds(
        for window: AXUIElement,
        ownerPID: pid_t,
        screenPoint: CGPoint,
        fallbackFrame: CGRect
    ) -> CGRect {
        if let windowNumber = accessibilityWindowNumber(of: window),
           let exactBounds = boundsForWindowNumber(windowNumber, near: screenPoint),
           exactBounds.contains(screenPoint) {
            return exactBounds
        }

        if let ownerBounds = topmostWindow(
            containingScreenPoint: screenPoint,
            belowWindowID: nil,
            ownerPIDFilter: ownerPID
        )?.bounds,
           ownerBounds.contains(screenPoint) {
            return ownerBounds
        }

        return fallbackFrame
    }

    private func boundsForWindowNumber(_ windowNumber: CGWindowID, near point: CGPoint) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return nil
        }

        for info in infoList {
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  CGWindowID(number.uint32Value) == windowNumber,
                  let boundsValue = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsValue) else {
                continue
            }
            return cocoaRect(fromSystemRect: bounds)
        }

        return nil
    }

    private func accessibilityHitElement(containingScreenPoint point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        let candidatePoints = [systemPoint(fromCocoaPoint: point), point]

        for candidate in candidatePoints {
            var hitElement: AXUIElement?
            let hitResult = AXUIElementCopyElementAtPosition(systemWide, Float(candidate.x), Float(candidate.y), &hitElement)
            if hitResult == .success, let hitElement {
                return hitElement
            }
        }

        return nil
    }

    private func refinedWindowHit(_ quartzHit: WindowHitResult, forScreenPoint point: CGPoint) -> WindowHitResult {
        guard let axCandidate = accessibilityWindowFrame(containingScreenPoint: point, ownerPIDFilter: quartzHit.ownerPID),
              isReasonableAXWindowFrame(axCandidate.frame, forScreenPoint: point) else {
            return quartzHit
        }

        let sameWindowNumber = quartzHit.windowNumber != nil && quartzHit.windowNumber == axCandidate.windowNumber
        let axContainsQuartzCenter = axCandidate.frame.contains(quartzHit.bounds.centerPoint)
        guard sameWindowNumber || axContainsQuartzCenter else {
            return quartzHit
        }

        guard !quartzHit.bounds.roughlyEquals(axCandidate.frame, tolerance: 6) else {
            return WindowHitResult(
                ownerPID: quartzHit.ownerPID,
                bounds: quartzHit.bounds,
                source: quartzHit.source,
                windowNumber: quartzHit.windowNumber ?? axCandidate.windowNumber,
                axFrame: axCandidate.frame,
                resolvedBounds: quartzHit.bounds,
                rawBounds: quartzHit.rawBounds,
                convertedBounds: quartzHit.convertedBounds
            )
        }

        return WindowHitResult(
            ownerPID: quartzHit.ownerPID,
            bounds: axCandidate.frame,
            source: "quartz.axFrame",
            windowNumber: quartzHit.windowNumber ?? axCandidate.windowNumber,
            axFrame: axCandidate.frame,
            resolvedBounds: axCandidate.frame,
            rawBounds: quartzHit.rawBounds,
            convertedBounds: quartzHit.convertedBounds
        )
    }

    private func accessibilityWindowFrame(
        containingScreenPoint point: CGPoint,
        ownerPIDFilter: pid_t? = nil
    ) -> AXWindowFrameCandidate? {
        guard let hitElement = accessibilityHitElement(containingScreenPoint: point) else {
            return nil
        }

        var ownerPID: pid_t = 0
        AXUIElementGetPid(hitElement, &ownerPID)
        guard ownerPID != ProcessInfo.processInfo.processIdentifier,
              ownerPIDFilter == nil || ownerPID == ownerPIDFilter else {
            return nil
        }

        if let directWindow = accessibilityOwningWindow(of: hitElement),
           let frame = accessibilityFrame(for: directWindow, near: point),
           frame.contains(point) {
            return AXWindowFrameCandidate(
                ownerPID: ownerPID,
                frame: frame,
                windowNumber: accessibilityWindowNumber(of: directWindow)
            )
        }

        var cursor: AXUIElement? = hitElement
        var depth = 0
        while depth < 12, let element = cursor {
            if accessibilityRole(of: element) == kAXWindowRole as String,
               let frame = accessibilityFrame(for: element, near: point),
               frame.contains(point) {
                return AXWindowFrameCandidate(
                    ownerPID: ownerPID,
                    frame: frame,
                    windowNumber: accessibilityWindowNumber(of: element)
                )
            }
            cursor = accessibilityParent(of: element)
            depth += 1
        }

        let candidates = accessibilityWindows(for: ownerPID).compactMap { window -> AXWindowFrameCandidate? in
            guard let frame = accessibilityFrame(for: window, near: point),
                  frame.contains(point) else {
                return nil
            }
            return AXWindowFrameCandidate(
                ownerPID: ownerPID,
                frame: frame,
                windowNumber: accessibilityWindowNumber(of: window)
            )
        }

        return candidates.min { $0.frame.area < $1.frame.area }
    }

    private func isReasonableAXWindowFrame(_ frame: CGRect, forScreenPoint point: CGPoint) -> Bool {
        guard frame.width >= 80,
              frame.height >= 48,
              frame.contains(point) else {
            return false
        }

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            return true
        }

        let maxWidth = (screen.frame.width * 1.25) + 80
        let maxHeight = (screen.frame.height * 1.25) + 80
        let maxArea = screen.frame.area * 1.4
        return frame.width <= maxWidth && frame.height <= maxHeight && frame.area <= maxArea
    }

    private func format(point: CGPoint) -> String {
        "(\(Int(point.x)),\(Int(point.y)))"
    }

    private func format(rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height)))"
    }

    private func raiseWindow(ownerPID: pid_t, matching screenRect: CGRect) {
        if let app = NSRunningApplication(processIdentifier: ownerPID) {
            _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }

        let appElement = AXUIElementCreateApplication(ownerPID)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard result == .success, let windows = windowsValue as? [AXUIElement] else { return }

        var fallbackWindow: AXUIElement?
        for window in windows {
            guard let frame = accessibilityFrame(for: window, near: screenRect.centerPoint) else { continue }
            fallbackWindow = fallbackWindow ?? window
            if matches(frame: frame, screenRect: screenRect) {
                focusAndRaise(window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    self.focusAndRaise(window)
                    self.window?.orderFrontRegardless()
                }
                return
            }
        }

        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let focusedWindow = AXBridge.element(from: focusedValue) {
            focusAndRaise(focusedWindow)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.focusAndRaise(focusedWindow)
                self.window?.orderFrontRegardless()
            }
            return
        }

        if let fallbackWindow {
            focusAndRaise(fallbackWindow)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.focusAndRaise(fallbackWindow)
                self.window?.orderFrontRegardless()
            }
        }
    }

    private func focusAndRaise(_ window: AXUIElement) {
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private func accessibilityFrame(for element: AXUIElement, near point: CGPoint) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue else {
            return nil
        }
        guard let positionAXValue = AXBridge.value(from: positionValue),
              let sizeAXValue = AXBridge.value(from: sizeValue) else {
            DiagnosticsLogger.shared.log("screenshot.ax", "invalid_frame_value_type")
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionAXValue) == .cgPoint,
              AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetType(sizeAXValue) == .cgSize,
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        return cocoaRect(fromSystemRect: CGRect(origin: position, size: size))
    }

    private func matches(frame: CGRect, screenRect: CGRect) -> Bool {
        abs(frame.minX - screenRect.minX) <= 2
            && abs(frame.minY - screenRect.minY) <= 2
            && abs(frame.width - screenRect.width) <= 2
            && abs(frame.height - screenRect.height) <= 2
    }

    private func adjustedDragPoint(_ point: CGPoint, from start: CGPoint, timestamp: TimeInterval) -> CGPoint {
        let fastDrag = isFastDrag(point, timestamp: timestamp)

        let rawDX = point.x - start.x
        let rawDY = point.y - start.y
        let snappedDX = weakSnapToTens(rawDX, fastDrag: fastDrag)
        let snappedDY = weakSnapToTens(rawDY, fastDrag: fastDrag)

        return CGPoint(
            x: start.x + snappedDX,
            y: start.y + snappedDY
        )
    }

    private func isFastDrag(_ point: CGPoint, timestamp: TimeInterval) -> Bool {
        defer {
            lastDragRawPoint = point
            lastDragTimestamp = timestamp
        }

        guard let lastDragRawPoint, let lastDragTimestamp else { return false }
        let dt = max(0.001, timestamp - lastDragTimestamp)
        let distance = hypot(point.x - lastDragRawPoint.x, point.y - lastDragRawPoint.y)
        return (distance / CGFloat(dt)) >= 900
    }

    private func weakSnapToTens(_ delta: CGFloat, fastDrag: Bool) -> CGFloat {
        guard fastDrag, abs(delta) >= 18 else { return delta }
        let rounded = (delta / 10).rounded() * 10
        return abs(rounded - delta) <= 5 ? rounded : delta
    }

    private func nearestCornerPoint(to point: CGPoint, in rect: CGRect) -> CGPoint {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        return corners.min { lhs, rhs in
            hypot(lhs.x - point.x, lhs.y - point.y) < hypot(rhs.x - point.x, rhs.y - point.y)
        } ?? CGPoint(x: rect.maxX, y: rect.minY)
    }

    // Quartz window bounds and AX positions use a global top-left origin anchored
    // to the main display, even when the hit point is on another screen.
    private func systemPoint(fromCocoaPoint point: CGPoint) -> CGPoint {
        let screenMaxY = quartzCoordinateReferenceMaxY
        return CGPoint(
            x: point.x,
            y: screenMaxY - point.y
        )
    }

    private func cocoaRect(fromSystemRect rect: CGRect) -> CGRect {
        let screenMaxY = quartzCoordinateReferenceMaxY
        return CGRect(
            x: rect.minX,
            y: screenMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private var quartzCoordinateReferenceMaxY: CGFloat {
        if let mainDisplayScreen = NSScreen.screens.first(where: {
            abs($0.frame.origin.x) <= 1 && abs($0.frame.origin.y) <= 1
        }) {
            return mainDisplayScreen.frame.maxY
        }
        return NSScreen.screens.first?.frame.maxY ?? effectiveScreenUnionFrame.maxY
    }

    private func screenContaining(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func previewImageRectForCurrentScreen() -> CGRect {
        if let lockedPreviewImage,
           abs(lockedPreviewImage.size.width - effectiveScreenFrame.width) <= 1,
           abs(lockedPreviewImage.size.height - effectiveScreenFrame.height) <= 1 {
            return CGRect(origin: .zero, size: lockedPreviewImage.size)
        }
        return effectiveScreenFrame.offsetBy(
            dx: -effectiveScreenUnionFrame.origin.x,
            dy: -effectiveScreenUnionFrame.origin.y
        )
    }

    private var currentSelectionRect: CGRect? {
        guard let start = dragStartPoint, let current = currentPoint else { return nil }
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let width = abs(current.x - start.x)
        let height = abs(current.y - start.y)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private var displayRect: CGRect? {
        lockedSelectionRect ?? currentSelectionRect ?? hoveredWindow?.localRect
    }

    func screenRect(fromLocalRect rect: CGRect) -> CGRect {
        rect.offsetBy(
            dx: effectiveScreenFrame.origin.x,
            dy: effectiveScreenFrame.origin.y
        )
    }

    private func screenPoint(fromLocalPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x + effectiveScreenFrame.origin.x,
            y: point.y + effectiveScreenFrame.origin.y
        )
    }

    private var effectiveScreenFrame: CGRect {
        if screenFrame.isNull || screenFrame.isEmpty {
            return window?.frame ?? .zero
        }
        return screenFrame
    }

    private var effectiveScreenUnionFrame: CGRect {
        if screenUnionFrame.isNull || screenUnionFrame.isEmpty {
            return window?.frame ?? .zero
        }
        return screenUnionFrame
    }

    private func activeCursor(for point: CGPoint) -> NSCursor {
        guard let lockedSelectionRect else { return .crosshair }
        if selectedTool == .text {
            if let selectedRect = annotationSession.selectedTextAnnotationRect,
               selectedRect.insetBy(dx: -10, dy: -8).contains(point) {
                if case .movingTextAnnotation = lockedInteraction {
                    return .closedHand
                }
                return .openHand
            }
            return lockedSelectionRect.contains(point) ? .iBeam : .crosshair
        }
        if selectedTool == .brush || selectedTool == .rectangle || selectedTool == .arrow {
            return .crosshair
        }
        guard let lockedInteraction else {
            if let handle = resizeHandle(at: point, in: lockedSelectionRect) {
                return cursor(for: handle)
            }
            if lockedSelectionRect.contains(point) {
                return .openHand
            }
            return .crosshair
        }

        switch lockedInteraction {
        case .moving:
            return .closedHand
        case .movingTextAnnotation:
            return .closedHand
        case let .resizing(handle, _, _):
            return cursor(for: handle)
        }
    }

    private func drawSelectedTextAnnotationOutline() {
        guard selectedTool == .text,
              !isEditingExistingTextAnnotation,
              let rect = annotationSession.selectedTextAnnotationRect else { return }
        let outlineRect = rect.insetBy(dx: -6, dy: -4)
        let path = NSBezierPath(roundedRect: outlineRect, xRadius: 6, yRadius: 6)
        let dashPattern: [CGFloat] = [5, 4]
        path.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        path.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.88).setStroke()
        path.stroke()
    }

    private func cursor(for handle: ResizeHandle) -> NSCursor {
        switch handle {
        case .left, .right:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .topLeft, .bottomRight:
            return Self.diagonalCursor(descending: true)
        case .topRight, .bottomLeft:
            return Self.diagonalCursor(descending: false)
        }
    }

    private static func diagonalCursor(descending: Bool) -> NSCursor {
        let symbolName = descending
            ? "arrow.up.left.and.arrow.down.right"
            : "arrow.up.right.and.arrow.down.left"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let sized = image.copy() as! NSImage
            sized.size = NSSize(width: 18, height: 18)
            return NSCursor(image: sized, hotSpot: CGPoint(x: 9, y: 9))
        }
        return descending ? .resizeLeftRight : .resizeUpDown
    }

    private func resizeHandle(at point: CGPoint, in rect: CGRect) -> ResizeHandle? {
        let inset = resizeHandleSize
        let left = abs(point.x - rect.minX) <= inset
        let right = abs(point.x - rect.maxX) <= inset
        let bottom = abs(point.y - rect.minY) <= inset
        let top = abs(point.y - rect.maxY) <= inset
        let withinY = point.y >= rect.minY - inset && point.y <= rect.maxY + inset
        let withinX = point.x >= rect.minX - inset && point.x <= rect.maxX + inset

        if left && top { return .topLeft }
        if right && top { return .topRight }
        if left && bottom { return .bottomLeft }
        if right && bottom { return .bottomRight }
        if top && withinX { return .top }
        if bottom && withinX { return .bottom }
        if left && withinY { return .left }
        if right && withinY { return .right }
        return nil
    }

    private func translatedLockedRect(initialRect: CGRect, dragStartPoint: CGPoint, currentPoint: CGPoint) -> CGRect {
        let dx = currentPoint.x - dragStartPoint.x
        let dy = currentPoint.y - dragStartPoint.y
        var rect = initialRect.offsetBy(dx: dx, dy: dy)
        if rect.minX < bounds.minX {
            rect.origin.x = bounds.minX
        }
        if rect.maxX > bounds.maxX {
            rect.origin.x = bounds.maxX - rect.width
        }
        if rect.minY < bounds.minY {
            rect.origin.y = bounds.minY
        }
        if rect.maxY > bounds.maxY {
            rect.origin.y = bounds.maxY - rect.height
        }
        return rect.integral
    }

    private func resizedLockedRect(
        handle: ResizeHandle,
        initialRect: CGRect,
        dragStartPoint: CGPoint,
        currentPoint: CGPoint,
        modifiers: NSEvent.ModifierFlags
    ) -> CGRect? {
        let symmetric = modifiers.contains(.option)
        let proportional = modifiers.contains(.shift)
        let dx = currentPoint.x - dragStartPoint.x
        let dy = currentPoint.y - dragStartPoint.y

        let center = CGPoint(x: initialRect.midX, y: initialRect.midY)
        var minX = initialRect.minX
        var maxX = initialRect.maxX
        var minY = initialRect.minY
        var maxY = initialRect.maxY

        switch handle {
        case .left:
            minX += dx
            if symmetric { maxX -= dx }
        case .right:
            maxX += dx
            if symmetric { minX -= dx }
        case .bottom:
            minY += dy
            if symmetric { maxY -= dy }
        case .top:
            maxY += dy
            if symmetric { minY -= dy }
        case .topLeft:
            minX += dx
            maxY += dy
            if symmetric {
                maxX -= dx
                minY -= dy
            }
        case .topRight:
            maxX += dx
            maxY += dy
            if symmetric {
                minX -= dx
                minY -= dy
            }
        case .bottomLeft:
            minX += dx
            minY += dy
            if symmetric {
                maxX -= dx
                maxY -= dy
            }
        case .bottomRight:
            maxX += dx
            minY += dy
            if symmetric {
                minX -= dx
                maxY -= dy
            }
        }

        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).standardized
        rect.size.width = max(lockedSelectionMinimumSize, rect.width)
        rect.size.height = max(lockedSelectionMinimumSize, rect.height)

        if proportional {
            rect = proportionalRect(for: rect, handle: handle, anchorRect: initialRect, symmetric: symmetric, center: center)
        }

        rect.origin.x = max(bounds.minX, min(rect.origin.x, bounds.maxX - rect.width))
        rect.origin.y = max(bounds.minY, min(rect.origin.y, bounds.maxY - rect.height))
        rect.size.width = min(rect.width, bounds.width)
        rect.size.height = min(rect.height, bounds.height)
        guard rect.width >= lockedSelectionMinimumSize, rect.height >= lockedSelectionMinimumSize else { return nil }
        return rect.integral
    }

    private func proportionalRect(
        for rect: CGRect,
        handle: ResizeHandle,
        anchorRect: CGRect,
        symmetric: Bool,
        center: CGPoint
    ) -> CGRect {
        guard anchorRect.width > 0, anchorRect.height > 0 else { return rect }
        let aspectRatio = anchorRect.width / anchorRect.height
        var width = max(lockedSelectionMinimumSize, rect.width)
        var height = max(lockedSelectionMinimumSize, rect.height)

        if width / height > aspectRatio {
            height = width / aspectRatio
        } else {
            width = height * aspectRatio
        }

        if symmetric {
            return CGRect(
                x: center.x - width / 2,
                y: center.y - height / 2,
                width: width,
                height: height
            ).integral
        }

        var origin = rect.origin
        switch handle {
        case .topLeft:
            origin = CGPoint(x: anchorRect.maxX - width, y: anchorRect.minY)
        case .topRight:
            origin = CGPoint(x: anchorRect.minX, y: anchorRect.minY)
        case .bottomLeft:
            origin = CGPoint(x: anchorRect.maxX - width, y: anchorRect.maxY - height)
        case .bottomRight:
            origin = CGPoint(x: anchorRect.minX, y: anchorRect.maxY - height)
        case .left:
            origin = CGPoint(x: anchorRect.maxX - width, y: rect.midY - height / 2)
        case .right:
            origin = CGPoint(x: anchorRect.minX, y: rect.midY - height / 2)
        case .top:
            origin = CGPoint(x: rect.midX - width / 2, y: anchorRect.minY)
        case .bottom:
            origin = CGPoint(x: rect.midX - width / 2, y: anchorRect.maxY - height)
        }

        return CGRect(origin: origin, size: CGSize(width: width, height: height)).integral
    }

    private func liveAnchorPoint(
        for rect: CGRect,
        currentPoint: CGPoint,
        interaction: LockedInteraction
    ) -> CGPoint {
        switch interaction {
        case let .moving(initialRect, _):
            let reference = lockedAnchorPoint ?? nearestCornerPoint(to: currentPoint, in: initialRect)
            let corner = nearestCornerKind(to: reference, in: initialRect)
            return cornerPoint(for: corner, in: rect)
        case .resizing:
            return nearestCornerPoint(to: currentPoint, in: rect)
        case .movingTextAnnotation:
            return nearestCornerPoint(to: currentPoint, in: rect)
        }
    }

    private func nearestCornerKind(to point: CGPoint, in rect: CGRect) -> RectCorner {
        let candidates: [(RectCorner, CGPoint)] = [
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
        return candidates.min { lhs, rhs in
            hypot(lhs.1.x - point.x, lhs.1.y - point.y) < hypot(rhs.1.x - point.x, rhs.1.y - point.y)
        }?.0 ?? .topRight
    }

    private func cornerPoint(for corner: RectCorner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .topRight:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottomLeft:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .bottomRight:
            return CGPoint(x: rect.maxX, y: rect.minY)
        }
    }

    private func clampedPoint(_ point: CGPoint, inside rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func scheduleBrushEllipsePromotionIfNeeded() {
        annotationSession.scheduleBrushEllipsePromotionIfNeeded { [weak self] in
            guard let self else { return }
            self.lockedInteractionDidMutateRect = true
            self.needsDisplay = true
        }
    }

    private func cancelBrushEllipsePromotion() {
        annotationSession.cancelBrushEllipsePromotion()
    }
}

private extension CGRect {
    var area: CGFloat {
        width * height
    }

    var centerPoint: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func centerDistanceSquared(to point: CGPoint) -> CGFloat {
        let dx = midX - point.x
        let dy = midY - point.y
        return (dx * dx) + (dy * dy)
    }

    func roughlyEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
