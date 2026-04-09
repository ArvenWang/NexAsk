import AppKit

final class AppInputEventCoordinator {
    private struct FinderSelectionState {
        var gestureID: Int = 0
        var pendingCommandCapture = false
        var lastPreviewCount: Int = 1
        var lowCountStreak: Int = 0
        var baselineCount: Int = 0
        var latestObservedCount: Int?
        var lastLoggedProbeSignature: String?
        var primarySelectionContainer: AXUIElement?
        var previewCountRequestInFlight = false
        var lastPreviewRefreshAt: Date = .distantPast
    }

    private let settings: AppSettings
    private let textSelectionCaptureService: TextSelectionCaptureService
    private let toolbarController: FloatingToolbarController
    private let resultController: ResultPanelController
    private let inlinePromptController: InlineActionPromptController
    private let screenshotSelectionController: ScreenshotSelectionOverlayController
    private let diagnosticsLogger: DiagnosticsLogger
    private let finderSelectionService: FinderSelectionService
    private let globalInputRouter: GlobalInputRouter
    private let isFinderFrontmost: () -> Bool
    private let isScreenshotSelectionActive: () -> Bool
    private let isConversationSelectionActive: () -> Bool
    private let dismissConversationSelection: () -> Void
    private let isProductConversationVisible: () -> Bool
    private let dismissProductConversation: () -> Void
    private let cancelScreenshotCaptureFlow: () -> Void
    private let dismissLockedScreenshotSession: (Bool) -> Void
    private let dismissTransientWindows: (Bool) -> Void
    private let clearFileSelectionContext: () -> Void
    private let handleNewFileSnapshot: (FileSelectionSnapshot) -> Void
    private let cancelToolbarPresentation: () -> Void

    private let fileSelectionCaptureDelay: TimeInterval
    private let finderCommandSelectionCaptureDelay: TimeInterval
    private let multiClickSelectionCaptureDelay: TimeInterval
    private let finderPreviewHideDebounceSamples: Int

    private var globalMouseMonitor: Any?
    private var globalMouseDragMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localEventMonitor: Any?

    private var lastGlobalMouseDownPoint: CGPoint?
    private var lastGlobalMouseDownClickCount: Int = 0
    private var lastGlobalModifierFlags: NSEvent.ModifierFlags = []
    private var mouseSelectionActive = false
    private var mouseDidDragInCurrentGesture = false
    private var pendingClickSelectionExpansion = false
    private var pendingMouseSelectionCaptureWorkItem: DispatchWorkItem?
    private var pendingFileSelectionCaptureWorkItem: DispatchWorkItem?
    private var finderState = FinderSelectionState()
    init(
        settings: AppSettings,
        textSelectionCaptureService: TextSelectionCaptureService,
        toolbarController: FloatingToolbarController,
        resultController: ResultPanelController,
        inlinePromptController: InlineActionPromptController,
        screenshotSelectionController: ScreenshotSelectionOverlayController,
        diagnosticsLogger: DiagnosticsLogger,
        finderSelectionService: FinderSelectionService = FinderSelectionService(),
        globalInputRouter: GlobalInputRouter = GlobalInputRouter(),
        fileSelectionCaptureDelay: TimeInterval = 0.02,
        finderCommandSelectionCaptureDelay: TimeInterval = 0.03,
        multiClickSelectionCaptureDelay: TimeInterval = 0.1,
        finderPreviewHideDebounceSamples: Int = 3,
        isFinderFrontmost: @escaping () -> Bool,
        isScreenshotSelectionActive: @escaping () -> Bool,
        isConversationSelectionActive: @escaping () -> Bool,
        dismissConversationSelection: @escaping () -> Void,
        isProductConversationVisible: @escaping () -> Bool,
        dismissProductConversation: @escaping () -> Void,
        cancelScreenshotCaptureFlow: @escaping () -> Void,
        dismissLockedScreenshotSession: @escaping (Bool) -> Void,
        dismissTransientWindows: @escaping (Bool) -> Void,
        clearFileSelectionContext: @escaping () -> Void,
        handleNewFileSnapshot: @escaping (FileSelectionSnapshot) -> Void,
        cancelToolbarPresentation: @escaping () -> Void
    ) {
        self.settings = settings
        self.textSelectionCaptureService = textSelectionCaptureService
        self.toolbarController = toolbarController
        self.resultController = resultController
        self.inlinePromptController = inlinePromptController
        self.screenshotSelectionController = screenshotSelectionController
        self.diagnosticsLogger = diagnosticsLogger
        self.finderSelectionService = finderSelectionService
        self.globalInputRouter = globalInputRouter
        self.fileSelectionCaptureDelay = fileSelectionCaptureDelay
        self.finderCommandSelectionCaptureDelay = finderCommandSelectionCaptureDelay
        self.multiClickSelectionCaptureDelay = multiClickSelectionCaptureDelay
        self.finderPreviewHideDebounceSamples = finderPreviewHideDebounceSamples
        self.isFinderFrontmost = isFinderFrontmost
        self.isScreenshotSelectionActive = isScreenshotSelectionActive
        self.isConversationSelectionActive = isConversationSelectionActive
        self.dismissConversationSelection = dismissConversationSelection
        self.isProductConversationVisible = isProductConversationVisible
        self.dismissProductConversation = dismissProductConversation
        self.cancelScreenshotCaptureFlow = cancelScreenshotCaptureFlow
        self.dismissLockedScreenshotSession = dismissLockedScreenshotSession
        self.dismissTransientWindows = dismissTransientWindows
        self.clearFileSelectionContext = clearFileSelectionContext
        self.handleNewFileSnapshot = handleNewFileSnapshot
        self.cancelToolbarPresentation = cancelToolbarPresentation
        self.finderSelectionService.onSelectionCountChanged = { [weak self] count in
            Task { @MainActor [weak self] in
                self?.handleFinderSelectionObserverCountChanged(count)
            }
        }
    }

    var currentTextGestureState: TextSelectionGestureState {
        TextSelectionGestureState(
            mouseSelectionActive: mouseSelectionActive,
            mouseDidDragInCurrentGesture: mouseDidDragInCurrentGesture,
            pendingClickSelectionExpansion: pendingClickSelectionExpansion
        )
    }

    func consumePendingClickSelectionExpansion() {
        pendingClickSelectionExpansion = false
    }

    func start() {
        finderSelectionService.start()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseDown(event)
            }
        }
        globalMouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMouseDragged()
            }
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseUp(event)
            }
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleGlobalKey(event)
            }
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleModifierFlagsChanged(event)
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .flagsChanged]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleLocalEvent(event)
            }
            return event
        }
    }

    func stop() {
        cancelPendingCaptures()
        finderSelectionService.stop()
        removeMonitor(&globalMouseMonitor)
        removeMonitor(&globalMouseDragMonitor)
        removeMonitor(&globalMouseUpMonitor)
        removeMonitor(&globalKeyMonitor)
        removeMonitor(&globalFlagsMonitor)
        removeMonitor(&localEventMonitor)
    }

    func handleSelectionCleared() {
        cancelPendingCaptures()
        pendingClickSelectionExpansion = false
    }

    private func handleGlobalMouseDown(_ event: NSEvent) {
        guard !isScreenshotSelectionActive(), !isConversationSelectionActive() else { return }
        if event.type == .leftMouseDown {
            finderState.gestureID &+= 1
            lastGlobalMouseDownPoint = NSEvent.mouseLocation
            lastGlobalMouseDownClickCount = event.clickCount
            mouseSelectionActive = true
            mouseDidDragInCurrentGesture = false
            finderState.lastPreviewCount = 1
            finderState.lowCountStreak = 0
            finderState.latestObservedCount = nil
            finderState.lastLoggedProbeSignature = nil
            finderState.previewCountRequestInFlight = false
            finderState.lastPreviewRefreshAt = .distantPast
            finderState.primarySelectionContainer = isFinderFrontmost()
                ? finderSelectionService.primarySelectionContainer()
                : nil
            finderState.baselineCount = isFinderFrontmost()
                ? (finderSelectionService.selectedItemCount(onPrimaryContainer: finderState.primarySelectionContainer)
                    ?? finderSelectionService.liveSelectedItemCount()
                    ?? 0)
                : 0
            if isFinderFrontmost(), settings.fileSelectionEnabled {
                requestFinderPreviewCountIfNeeded(force: true)
            } else {
                finderState.primarySelectionContainer = nil
            }
            if isFinderFrontmost() {
                diagnosticsLogger.log(
                    "finder.fileSelection",
                    "mouseDown gesture=\(finderState.gestureID) baseline=\(finderState.baselineCount) clickCount=\(event.clickCount)"
                )
            }
        }
        handleOutsideClick(screenPoint: NSEvent.mouseLocation)
    }

    private func handleGlobalMouseUp(_ event: NSEvent) {
        guard !isScreenshotSelectionActive(), !isConversationSelectionActive() else { return }
        let upPoint = NSEvent.mouseLocation
        let downPoint = lastGlobalMouseDownPoint ?? upPoint
        let dx = upPoint.x - downPoint.x
        let dy = upPoint.y - downPoint.y
        let distance = sqrt(dx * dx + dy * dy)
        let clickCount = max(event.clickCount, lastGlobalMouseDownClickCount)
        let strongIntent = distance >= 4 || clickCount >= 2 || mouseDidDragInCurrentGesture
        let isMultiClickSelection = clickCount >= 2 && !mouseDidDragInCurrentGesture
        pendingClickSelectionExpansion = isMultiClickSelection

        if isFinderFrontmost() {
            handleFinderMouseUp(event: event)
            resetMouseGestureState(preserveFinderPreviewState: pendingFileSelectionCaptureWorkItem != nil || finderState.pendingCommandCapture)
            return
        }

        guard settings.textSelectionEnabled else {
            resetMouseGestureState()
            return
        }
        if strongIntent {
            if isMultiClickSelection {
                pendingMouseSelectionCaptureWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.pendingMouseSelectionCaptureWorkItem = nil
                        self.textSelectionCaptureService.captureFromMouseSelectionIntent(strong: true)
                    }
                }
                pendingMouseSelectionCaptureWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + multiClickSelectionCaptureDelay, execute: workItem)
            } else {
                pendingMouseSelectionCaptureWorkItem?.cancel()
                pendingMouseSelectionCaptureWorkItem = nil
                textSelectionCaptureService.captureFromMouseSelectionIntent(strong: true)
            }
        }
        resetMouseGestureState()
    }

    private func handleFinderMouseUp(event: NSEvent) {
        guard settings.fileSelectionEnabled else {
            clearFileSelectionContext()
            return
        }
        let modifierFlags = event.modifierFlags
        let decision = globalInputRouter.finderMouseUpDecision(
            mouseDidDragInCurrentGesture: mouseDidDragInCurrentGesture,
            modifierFlags: modifierFlags
        )

        if decision.waitsForCommandRelease {
            diagnosticsLogger.log(
                "finder.fileSelection",
                "mouseUp gesture=\(finderState.gestureID) waitForCommandRelease baseline=\(finderState.baselineCount) dragged=\(mouseDidDragInCurrentGesture)"
            )
            finderState.pendingCommandCapture = true
        } else if decision.shouldScheduleCapture {
            diagnosticsLogger.log(
                "finder.fileSelection",
                "mouseUp gesture=\(finderState.gestureID) scheduleCapture baseline=\(finderState.baselineCount) dragged=\(mouseDidDragInCurrentGesture) modifiers=\(modifierFlags.rawValue)"
            )
            scheduleFileSelectionCapture(
                after: fileSelectionCaptureDelay,
                baselineCount: finderState.baselineCount,
                gestureID: finderState.gestureID
            )
        } else {
            clearFileSelectionContext()
        }
    }

    private func handleLocalEvent(_ event: NSEvent) {
        if isConversationSelectionActive() {
            if event.type == .keyDown, event.keyCode == 53 {
                dismissConversationSelection()
            }
            return
        }
        if isScreenshotSelectionActive() {
            if event.type == .keyDown, event.keyCode == 53 {
                cancelScreenshotCaptureFlow()
            }
            return
        }
        if event.type == .keyDown {
            handleGlobalKey(event)
            return
        }
        if event.type == .flagsChanged {
            handleModifierFlagsChanged(event)
            return
        }
        if event.type == .leftMouseDragged {
            handleMouseDragged()
            return
        }

        let point: CGPoint
        if let win = event.window {
            point = win.convertPoint(toScreen: event.locationInWindow)
        } else {
            point = NSEvent.mouseLocation
        }
        handleOutsideClick(screenPoint: point)
    }

    private func handleGlobalKey(_ event: NSEvent) {
        if isConversationSelectionActive() {
            if event.keyCode == 53 {
                dismissConversationSelection()
            }
            return
        }
        if event.keyCode == 53, isProductConversationVisible() {
            dismissProductConversation()
            return
        }
        if isScreenshotSelectionActive() {
            if event.keyCode == 53 {
                cancelScreenshotCaptureFlow()
            }
            return
        }
        if event.keyCode == 53, screenshotSelectionController.hasLockedSelection {
            cancelScreenshotCaptureFlow()
            return
        }
        if event.keyCode == 53 {
            dismissTransientWindows(true)
            return
        }

        if inlinePromptController.isVisible {
            inlinePromptController.hide()
            return
        }

        if toolbarController.isVisible {
            toolbarController.hide()
            cancelToolbarPresentation()
            return
        }

        if isFinderFrontmost() {
            guard settings.fileSelectionEnabled else { return }
        } else {
            guard settings.textSelectionEnabled else { return }
        }
        if isSelectionKeyboardIntent(event) {
            if isFinderFrontmost() {
                scheduleFileSelectionCapture(after: fileSelectionCaptureDelay)
                return
            }
            textSelectionCaptureService.captureFromKeyboardSelectionIntent()
        }
    }

    private func handleModifierFlagsChanged(_ event: NSEvent) {
        guard !isScreenshotSelectionActive(), !isConversationSelectionActive() else { return }
        let relevantFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let didReleaseCommand = lastGlobalModifierFlags.contains(.command) && !relevantFlags.contains(.command)
        lastGlobalModifierFlags = relevantFlags

        guard finderState.pendingCommandCapture, didReleaseCommand else { return }
        finderState.pendingCommandCapture = false
        guard settings.fileSelectionEnabled, isFinderFrontmost() else {
            clearFileSelectionContext()
            return
        }
        diagnosticsLogger.log("finder.fileSelection", "commandReleased gesture=\(finderState.gestureID) scheduleCapture baseline=\(finderState.baselineCount)")
        scheduleFileSelectionCapture(after: finderCommandSelectionCaptureDelay, gestureID: finderState.gestureID)
    }

    private func handleOutsideClick(screenPoint: CGPoint) {
        guard !isConversationSelectionActive() else { return }
        guard settings.dismissOnOutsideClick else { return }
        if toolbarController.isPresentingMenu { return }
        let preserveCollectStreamingPresentation = resultController.isPersistentStreamingPresentation
        let preserveToolbarLoading = toolbarController.isShowingLoadingState

        if screenshotSelectionController.hasLockedSelection,
           !toolbarController.contains(screenPoint: screenPoint),
           !resultController.contains(screenPoint: screenPoint),
           !inlinePromptController.contains(screenPoint: screenPoint) {
            cancelScreenshotCaptureFlow()
            return
        }

        if resultController.isVisible,
           !resultController.contains(screenPoint: screenPoint),
           !preserveCollectStreamingPresentation {
            resultController.hide()
        }

        if inlinePromptController.isVisible && !inlinePromptController.contains(screenPoint: screenPoint) {
            inlinePromptController.hide()
        }

        if toolbarController.isVisible,
           !toolbarController.contains(screenPoint: screenPoint),
           !resultController.contains(screenPoint: screenPoint),
           !inlinePromptController.contains(screenPoint: screenPoint),
           !preserveToolbarLoading {
            toolbarController.hide()
        }
    }

    private func handleMouseDragged() {
        guard !isScreenshotSelectionActive(), !isConversationSelectionActive() else { return }
        let entryEnabled = isFinderFrontmost() ? settings.fileSelectionEnabled : settings.textSelectionEnabled
        guard entryEnabled, mouseSelectionActive else { return }
        let point = NSEvent.mouseLocation
        if let down = lastGlobalMouseDownPoint {
            let dx = point.x - down.x
            let dy = point.y - down.y
            if !mouseDidDragInCurrentGesture, (dx * dx + dy * dy) >= 9 {
                mouseDidDragInCurrentGesture = true
            }
        }
        guard mouseDidDragInCurrentGesture else { return }
        if isFinderFrontmost() {
            updateFinderDragPreview(at: point)
            requestFinderPreviewCountIfNeeded()
            return
        }
        textSelectionCaptureService.captureFromMouseDragIntent()
        if toolbarController.isCompactPresentation {
            toolbarController.move(to: point)
        }
    }

    private func updateFinderDragPreview(at point: CGPoint) {
        let liveCount = finderState.latestObservedCount
        applyFinderDragPreviewCount(liveCount, gestureID: finderState.gestureID, point: point)
        if toolbarController.isCompactPresentation {
            toolbarController.move(to: point)
        }
    }

    private func applyFinderDragPreviewCount(_ liveCount: Int?, gestureID: Int, point: CGPoint) {
        let isPendingFinderCapture = pendingFileSelectionCaptureWorkItem != nil || finderState.pendingCommandCapture
        guard (mouseSelectionActive && mouseDidDragInCurrentGesture) || isPendingFinderCapture,
              isFinderFrontmost(),
              finderState.gestureID == gestureID else { return }
        let resolution = Self.resolveFinderDragPreview(
            liveCount: liveCount,
            lastPreviewCount: finderState.lastPreviewCount,
            lowCountStreak: finderState.lowCountStreak,
            hideDebounceSamples: finderPreviewHideDebounceSamples,
            toolbarIsVisible: toolbarController.isVisible,
            toolbarIsCompactPresentation: toolbarController.isCompactPresentation
        )
        finderState.lastPreviewCount = resolution.nextPreviewCount
        finderState.lowCountStreak = resolution.nextLowCountStreak

        if resolution.shouldUpdatePreviewCount {
            diagnosticsLogger.log(
                "finder.fileSelection",
                "drag gesture=\(gestureID) showPreview count=\(resolution.nextPreviewCount) baseline=\(finderState.baselineCount)"
            )
            toolbarController.updateRecognitionSlot(.fileCount(count: resolution.nextPreviewCount))
        }

        if resolution.shouldShowCompact {
            toolbarController.showCompact(at: point)
        }
        if resolution.shouldHideCompact {
            diagnosticsLogger.log(
                "finder.fileSelection",
                "drag gesture=\(gestureID) hidePreview baseline=\(finderState.baselineCount)"
            )
            toolbarController.hide()
        }
    }

    private func isSelectionKeyboardIntent(_ event: NSEvent) -> Bool {
        globalInputRouter.isSelectionKeyboardIntent(event)
    }

    private func scheduleFileSelectionCapture(
        after delay: TimeInterval,
        baselineCount: Int? = nil,
        gestureID: Int? = nil
    ) {
        pendingFileSelectionCaptureWorkItem?.cancel()
        let capturedBaseline = baselineCount
        let capturedGestureID = gestureID ?? finderState.gestureID
        diagnosticsLogger.log(
            "finder.fileSelection",
            "scheduleCapture gesture=\(capturedGestureID) delay=\(delay) baseline=\(capturedBaseline ?? finderState.baselineCount)"
        )
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingFileSelectionCaptureWorkItem = nil
                guard self.finderState.gestureID == capturedGestureID || !self.mouseSelectionActive else {
                    self.diagnosticsLogger.log("finder.fileSelection", "capture abort gesture=\(capturedGestureID) reason=staleGestureBeforeFirstRead current=\(self.finderState.gestureID)")
                    return
                }
                let selectedCount = self.finderState.lastPreviewCount > 1
                    ? self.finderState.lastPreviewCount
                    : (self.finderSelectionService.selectedItemCount(onPrimaryContainer: self.finderState.primarySelectionContainer) ?? 0)
                self.diagnosticsLogger.log(
                    "finder.fileSelection",
                    "capture gesture=\(capturedGestureID) firstRead selectedCount=\(selectedCount) baseline=\(capturedBaseline ?? self.finderState.baselineCount)"
                )
                let previewPoint = NSEvent.mouseLocation
                if selectedCount > 1 {
                    self.finderState.lastPreviewCount = selectedCount
                    self.finderState.lowCountStreak = 0
                    self.toolbarController.updateRecognitionSlot(.fileCount(count: selectedCount))
                    if !self.toolbarController.isVisible || !self.toolbarController.isCompactPresentation {
                        self.toolbarController.showCompact(at: previewPoint)
                    }
                }
                self.finderSelectionService.captureSelectionBySyntheticCopy { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.finderState.gestureID == capturedGestureID || !self.mouseSelectionActive else {
                            self.diagnosticsLogger.log("finder.fileSelection", "capture abort gesture=\(capturedGestureID) reason=staleGestureAfterSyntheticCopy current=\(self.finderState.gestureID) resultCount=\(snapshot?.fileURLs.count ?? 0)")
                            return
                        }
                        self.diagnosticsLogger.log(
                            "finder.fileSelection",
                            "capture gesture=\(capturedGestureID) syntheticCopy resultCount=\(snapshot?.fileURLs.count ?? 0)"
                        )
                        if let snapshot, snapshot.fileURLs.count > 1 {
                            self.handleNewFileSnapshot(snapshot)
                        } else {
                            self.clearFileSelectionContext()
                        }
                    }
                }
            }
        }
        pendingFileSelectionCaptureWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelPendingCaptures() {
        pendingMouseSelectionCaptureWorkItem?.cancel()
        pendingMouseSelectionCaptureWorkItem = nil
        pendingFileSelectionCaptureWorkItem?.cancel()
        pendingFileSelectionCaptureWorkItem = nil
        finderState.pendingCommandCapture = false
        finderState.previewCountRequestInFlight = false
    }

    private func resetMouseGestureState(preserveFinderPreviewState: Bool = false) {
        lastGlobalMouseDownPoint = nil
        lastGlobalMouseDownClickCount = 0
        mouseSelectionActive = false
        mouseDidDragInCurrentGesture = false
        if !preserveFinderPreviewState {
            resetFinderPreviewState()
        }
    }

    private func resetFinderPreviewState() {
        finderState.lastPreviewCount = 1
        finderState.lowCountStreak = 0
        finderState.baselineCount = 0
        finderState.latestObservedCount = nil
        finderState.lastLoggedProbeSignature = nil
        finderState.primarySelectionContainer = nil
        finderState.previewCountRequestInFlight = false
        finderState.lastPreviewRefreshAt = .distantPast
    }

    private func logFinderPreviewProbe(source: String, liveCount: Int?, gestureID: Int, dragged: Bool) {
        let signature = "\(gestureID):\(source):\(liveCount.map(String.init) ?? "nil"):\(dragged)"
        guard finderState.lastLoggedProbeSignature != signature else { return }
        finderState.lastLoggedProbeSignature = signature
        diagnosticsLogger.log(
            "finder.fileSelection",
            "\(source) gesture=\(gestureID) liveCount=\(String(describing: liveCount)) baseline=\(finderState.baselineCount) dragged=\(dragged)"
        )
    }

    private func removeMonitor(_ monitor: inout Any?) {
        if let currentMonitor = monitor {
            NSEvent.removeMonitor(currentMonitor)
            monitor = nil
        }
    }

    private func requestFinderPreviewCountIfNeeded(force: Bool = false) {
        guard settings.fileSelectionEnabled,
              isFinderFrontmost(),
              mouseSelectionActive else { return }

        let now = Date()
        if !force,
           now.timeIntervalSince(finderState.lastPreviewRefreshAt) < 0.02 {
            return
        }
        guard !finderState.previewCountRequestInFlight else { return }
        finderState.previewCountRequestInFlight = true
        finderState.lastPreviewRefreshAt = now

        let gestureID = finderState.gestureID
        let preferredContainer = finderState.primarySelectionContainer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // During marquee selection Finder's active content pane is usually stable for the
            // lifetime of the gesture, so prefer the cached container to avoid repeatedly
            // rescanning the AX tree on every drag sample.
            let resolvedContainer = preferredContainer ?? self.finderSelectionService.primarySelectionContainer()
            let liveCount = self.finderSelectionService.selectionCount(forObserverElement: resolvedContainer)
                ?? self.finderSelectionService.selectedItemCount(onPrimaryContainer: resolvedContainer)
            Task { @MainActor [weak self] in
                self?.handleFinderPreviewCountResolved(
                    liveCount,
                    container: resolvedContainer,
                    gestureID: gestureID
                )
            }
        }
    }

    private func handleFinderPreviewCountResolved(
        _ liveCount: Int?,
        container: AXUIElement?,
        gestureID: Int
    ) {
        guard finderState.gestureID == gestureID else { return }
        finderState.previewCountRequestInFlight = false
        if let container {
            finderState.primarySelectionContainer = container
        }
        guard settings.fileSelectionEnabled,
              isFinderFrontmost(),
              mouseSelectionActive || pendingFileSelectionCaptureWorkItem != nil || finderState.pendingCommandCapture else { return }

        finderState.latestObservedCount = liveCount
        logFinderPreviewProbe(
            source: "directCount",
            liveCount: liveCount,
            gestureID: gestureID,
            dragged: mouseDidDragInCurrentGesture
        )

        if let liveCount, liveCount > 1 {
            mouseDidDragInCurrentGesture = true
        }

        guard mouseDidDragInCurrentGesture || pendingFileSelectionCaptureWorkItem != nil || finderState.pendingCommandCapture else {
            return
        }

        let point = NSEvent.mouseLocation
        applyFinderDragPreviewCount(liveCount, gestureID: gestureID, point: point)
        if toolbarController.isCompactPresentation {
            toolbarController.move(to: point)
        }
    }

    private func handleFinderSelectionObserverCountChanged(_ count: Int?) {
        guard settings.fileSelectionEnabled,
              isFinderFrontmost() else { return }
        finderState.latestObservedCount = count
        guard mouseSelectionActive || pendingFileSelectionCaptureWorkItem != nil || finderState.pendingCommandCapture else {
            return
        }

        logFinderPreviewProbe(
            source: "observerCount",
            liveCount: count,
            gestureID: finderState.gestureID,
            dragged: mouseDidDragInCurrentGesture
        )

        if let count, count > 1 {
            mouseDidDragInCurrentGesture = true
        }

        let point = NSEvent.mouseLocation
        applyFinderDragPreviewCount(count, gestureID: finderState.gestureID, point: point)
        if toolbarController.isCompactPresentation {
            toolbarController.move(to: point)
        }
    }

    static func resolveFinderDragPreview(
        liveCount: Int?,
        lastPreviewCount: Int,
        lowCountStreak: Int,
        hideDebounceSamples: Int,
        toolbarIsVisible: Bool,
        toolbarIsCompactPresentation: Bool
    ) -> FinderDragPreviewResolution {
        FinderPreviewStateMachine.resolve(
            liveCount: liveCount,
            lastPreviewCount: lastPreviewCount,
            lowCountStreak: lowCountStreak,
            hideDebounceSamples: hideDebounceSamples,
            toolbarIsVisible: toolbarIsVisible,
            toolbarIsCompactPresentation: toolbarIsCompactPresentation
        )
    }
}
