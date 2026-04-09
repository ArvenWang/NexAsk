import AppKit
import CoreGraphics
import NexShared

#if !NEXHUB_PRODUCT_NEXHUB

final class AskBoxInputInterceptor {
    private enum CapturePhase {
        case idle
        case armed(startPoint: CGPoint, sessionID: Int, beganAt: CFAbsoluteTime)
        case capturing(startPoint: CGPoint, sessionID: Int, beganAt: CFAbsoluteTime)
    }

    private static let minimumDragDistanceToBeginCapture: CGFloat = 4

    private var passiveEventTap: CFMachPort?
    private var passiveRunLoopSource: CFRunLoopSource?
    private var captureEventTap: CFMachPort?
    private var captureRunLoopSource: CFRunLoopSource?
    private var eventTapRunLoop: CFRunLoop?
    private var eventTapThread: Thread?
    private let diagnosticsLogger: DiagnosticsLogger
    private let isEnabled: () -> Bool
    private let shouldBeginCapture: () -> Bool
    private let onCaptureBegan: (CGPoint) -> Void
    private let onCaptureChanged: (CGPoint) -> Void
    private let onCaptureEnded: (CGPoint) -> Void
    private let onCaptureCancelled: () -> Void
    private let stateLock = NSLock()
    private var phase: CapturePhase = .idle
    private var captureSequence = 0
    private var optionKeyDownAt: CFAbsoluteTime?
    private var firstDragLoggedSessionID: Int?

    init(
        diagnosticsLogger: DiagnosticsLogger = .shared,
        isEnabled: @escaping () -> Bool,
        shouldBeginCapture: @escaping () -> Bool,
        onCaptureBegan: @escaping (CGPoint) -> Void,
        onCaptureChanged: @escaping (CGPoint) -> Void,
        onCaptureEnded: @escaping (CGPoint) -> Void,
        onCaptureCancelled: @escaping () -> Void
    ) {
        self.diagnosticsLogger = diagnosticsLogger
        self.isEnabled = isEnabled
        self.shouldBeginCapture = shouldBeginCapture
        self.onCaptureBegan = onCaptureBegan
        self.onCaptureChanged = onCaptureChanged
        self.onCaptureEnded = onCaptureEnded
        self.onCaptureCancelled = onCaptureCancelled
    }

    deinit {
        stop()
    }

    var isCapturing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if case .capturing = phase { return true }
        return false
    }

    var isMonitoring: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return passiveEventTap != nil
            && captureEventTap != nil
            && eventTapRunLoop != nil
            && eventTapThread != nil
    }

    func start() {
        stop()
        let ref = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let passiveEventMask: CGEventMask =
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let captureEventMask: CGEventMask =
            (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)

        guard let passiveTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: passiveEventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<AskBoxInputInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handlePassiveEvent(type: type, event: event)
            },
            userInfo: ref
        ) else {
            diagnosticsLogger.log("ask.entry", "passive eventTap unavailable")
            return
        }

        guard let captureTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: captureEventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<AskBoxInputInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handleCaptureEvent(type: type, event: event)
            },
            userInfo: ref
        ) else {
            diagnosticsLogger.log("ask.entry", "capture eventTap unavailable")
            CFMachPortInvalidate(passiveTap)
            return
        }

        passiveEventTap = passiveTap
        passiveRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, passiveTap, 0)
        captureEventTap = captureTap
        captureRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, captureTap, 0)
        let readySignal = DispatchSemaphore(value: 0)
        let tapThread = Thread { [weak self] in
            autoreleasepool {
                guard let self else {
                    readySignal.signal()
                    return
                }
                let runLoop = CFRunLoopGetCurrent()
                self.stateLock.lock()
                self.eventTapRunLoop = runLoop
                self.stateLock.unlock()
                if let source = self.passiveRunLoopSource, let tap = self.passiveEventTap {
                    CFRunLoopAddSource(runLoop, source, .commonModes)
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                if let source = self.captureRunLoopSource, let tap = self.captureEventTap {
                    CFRunLoopAddSource(runLoop, source, .commonModes)
                    CGEvent.tapEnable(tap: tap, enable: false)
                }
                readySignal.signal()
                CFRunLoopRun()
            }
        }
        tapThread.name = "com.nexhub.askbox.eventtap"
        eventTapThread = tapThread
        tapThread.start()
        _ = readySignal.wait(timeout: .now() + 1)
    }

    func stop() {
        cancelCapture()
        if let runLoop = eventTapRunLoop {
            let passiveSource = passiveRunLoopSource
            let passiveTap = passiveEventTap
            let captureSource = captureRunLoopSource
            let captureTap = captureEventTap
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                if let passiveSource {
                    CFRunLoopRemoveSource(runLoop, passiveSource, .commonModes)
                }
                if let captureSource {
                    CFRunLoopRemoveSource(runLoop, captureSource, .commonModes)
                }
                if let passiveTap {
                    CFMachPortInvalidate(passiveTap)
                }
                if let captureTap {
                    CFMachPortInvalidate(captureTap)
                }
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        } else {
            if let passiveEventTap {
                CFMachPortInvalidate(passiveEventTap)
            }
            if let captureEventTap {
                CFMachPortInvalidate(captureEventTap)
            }
        }
        eventTapRunLoop = nil
        eventTapThread = nil
        passiveRunLoopSource = nil
        passiveEventTap = nil
        captureRunLoopSource = nil
        captureEventTap = nil
    }

    private func handlePassiveEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            diagnosticsLogger.log("ask.entry", "passive eventTap re-enabled reason=\(type.rawValue)")
            if let tap = passiveEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled() else {
            cancelCaptureIfNeeded(notify: false)
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown:
            guard shouldBeginCapture(),
                  Self.containsOptionModifier(event.flags) else {
                return Unmanaged.passUnretained(event)
            }
            let point = Self.cocoaPoint(fromSystemPoint: event.location)
            let beganAt = CFAbsoluteTimeGetCurrent()
            let sessionID: Int
            let optionHeldDelay: Int
            stateLock.lock()
            captureSequence += 1
            sessionID = captureSequence
            phase = .armed(startPoint: point, sessionID: sessionID, beganAt: beganAt)
            firstDragLoggedSessionID = nil
            optionHeldDelay = optionKeyDownAt.map { Self.elapsedMilliseconds(from: $0, to: beganAt) } ?? -1
            stateLock.unlock()
            diagnosticsLogger.log(
                "ask.entry",
                "raw leftMouseDown session=\(sessionID) x=\(Int(point.x)) y=\(Int(point.y)) optionHeld_ms=\(optionHeldDelay)"
            )
            setCaptureTapEnabled(true)
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            let now = CFAbsoluteTimeGetCurrent()
            let hasOption = Self.containsOptionModifier(event.flags)
            stateLock.lock()
            let wasOptionDown = optionKeyDownAt != nil
            if hasOption, optionKeyDownAt == nil {
                optionKeyDownAt = now
            } else if !hasOption {
                optionKeyDownAt = nil
            }
            let phaseSnapshot = phase
            stateLock.unlock()

            if hasOption, !wasOptionDown {
                diagnosticsLogger.log("ask.entry", "raw optionDown")
            } else if !hasOption, wasOptionDown {
                diagnosticsLogger.log("ask.entry", "raw optionUp")
            }

            switch phaseSnapshot {
            case .capturing(_, let sessionID, let beganAt):
                guard !hasOption else { return Unmanaged.passUnretained(event) }
                diagnosticsLogger.log(
                    "ask.entry",
                    "raw optionReleasedDuringCapture session=\(sessionID) elapsed_ms=\(Self.elapsedMilliseconds(from: beganAt, to: now))"
                )
                cancelCapture()
                return Unmanaged.passUnretained(event)
            case .armed(_, let sessionID, let beganAt):
                guard !hasOption else { return Unmanaged.passUnretained(event) }
                diagnosticsLogger.log(
                    "ask.entry",
                    "raw optionReleasedWhileArmed session=\(sessionID) elapsed_ms=\(Self.elapsedMilliseconds(from: beganAt, to: now))"
                )
                cancelCaptureIfNeeded(notify: false)
                return Unmanaged.passUnretained(event)
            case .idle:
                return Unmanaged.passUnretained(event)
            }
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleCaptureEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            diagnosticsLogger.log("ask.entry", "capture eventTap re-enabled reason=\(type.rawValue)")
            if let tap = captureEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled() else {
            cancelCaptureIfNeeded(notify: false)
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDragged:
            let point = Self.cocoaPoint(fromSystemPoint: event.location)
            stateLock.lock()
            let phaseSnapshot = phase
            let nextPhase: CapturePhase
            let shouldActivateCapture: Bool
            let shouldLogFirstDrag: Bool
            switch phaseSnapshot {
            case .armed(_, let sessionID, _):
                shouldActivateCapture = Self.qualifiesAsCaptureDrag(
                    start: Self.startPoint(from: phaseSnapshot),
                    end: point
                )
                if shouldActivateCapture {
                    nextPhase = .capturing(
                        startPoint: Self.startPoint(from: phaseSnapshot),
                        sessionID: sessionID,
                        beganAt: Self.beganAt(from: phaseSnapshot)
                    )
                    phase = nextPhase
                } else {
                    nextPhase = phaseSnapshot
                }
                shouldLogFirstDrag = shouldActivateCapture && firstDragLoggedSessionID != sessionID
                if shouldLogFirstDrag {
                    firstDragLoggedSessionID = sessionID
                }
            case .capturing(_, let sessionID, _):
                shouldActivateCapture = false
                nextPhase = phaseSnapshot
                shouldLogFirstDrag = firstDragLoggedSessionID != sessionID
                if shouldLogFirstDrag {
                    firstDragLoggedSessionID = sessionID
                }
            case .idle:
                shouldActivateCapture = false
                nextPhase = .idle
                shouldLogFirstDrag = false
            }
            stateLock.unlock()

            switch phaseSnapshot {
            case .armed, .capturing:
                break
            case .idle:
                return Unmanaged.passUnretained(event)
            }

            guard shouldActivateCapture || isCapturing else {
                return Unmanaged.passUnretained(event)
            }
            if shouldActivateCapture,
               case let .capturing(startPoint, sessionID, _) = nextPhase {
                diagnosticsLogger.log(
                    "ask.entry",
                    "capture activated session=\(sessionID) x=\(Int(point.x)) y=\(Int(point.y)) distance=\(Int(Self.dragDistance(from: startPoint, to: point).rounded())) optionHeld_ms=\(optionKeyDownAt.map { Self.elapsedMilliseconds(from: $0, to: CFAbsoluteTimeGetCurrent()) } ?? -1)"
                )
                DispatchQueue.main.async { [onCaptureBegan] in
                    onCaptureBegan(startPoint)
                }
            }
            if shouldLogFirstDrag,
               case let .capturing(_, sessionID, beganAt) = nextPhase {
                diagnosticsLogger.log(
                    "ask.entry",
                    "raw firstMouseDragged session=\(sessionID) x=\(Int(point.x)) y=\(Int(point.y)) elapsed_ms=\(Self.elapsedMilliseconds(from: beganAt, to: CFAbsoluteTimeGetCurrent()))"
                )
            }
            DispatchQueue.main.async { [onCaptureChanged] in
                onCaptureChanged(point)
            }
            return nil
        case .leftMouseUp:
            stateLock.lock()
            let phaseSnapshot = phase
            phase = .idle
            stateLock.unlock()
            setCaptureTapEnabled(false)
            switch phaseSnapshot {
            case .capturing(_, let sessionID, let beganAt):
                let point = Self.cocoaPoint(fromSystemPoint: event.location)
                diagnosticsLogger.log(
                    "ask.entry",
                    "raw leftMouseUp session=\(sessionID) x=\(Int(point.x)) y=\(Int(point.y)) elapsed_ms=\(Self.elapsedMilliseconds(from: beganAt, to: CFAbsoluteTimeGetCurrent()))"
                )
                DispatchQueue.main.async { [onCaptureEnded] in
                    onCaptureEnded(point)
                }
                return nil
            case .armed(_, let sessionID, let beganAt):
                diagnosticsLogger.log(
                    "ask.entry",
                    "raw leftMouseUp passthrough session=\(sessionID) elapsed_ms=\(Self.elapsedMilliseconds(from: beganAt, to: CFAbsoluteTimeGetCurrent()))"
                )
                return Unmanaged.passUnretained(event)
            case .idle:
                return Unmanaged.passUnretained(event)
            }
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func cancelCapture() {
        cancelCaptureIfNeeded(notify: true)
    }

    private func cancelCaptureIfNeeded(notify: Bool) {
        stateLock.lock()
        let phaseSnapshot = phase
        phase = .idle
        stateLock.unlock()
        setCaptureTapEnabled(false)
        switch phaseSnapshot {
        case .capturing(_, let sessionID, let beganAt):
            diagnosticsLogger.log(
                "ask.entry",
                "capture cancelled session=\(sessionID) elapsed_ms=\(Self.elapsedMilliseconds(from: beganAt, to: CFAbsoluteTimeGetCurrent()))"
            )
            if notify {
                DispatchQueue.main.async { [onCaptureCancelled] in
                    onCaptureCancelled()
                }
            }
        case .armed(_, let sessionID, let beganAt):
            diagnosticsLogger.log(
                "ask.entry",
                "capture disarmed session=\(sessionID) elapsed_ms=\(Self.elapsedMilliseconds(from: beganAt, to: CFAbsoluteTimeGetCurrent()))"
            )
        case .idle:
            return
        }
    }

    private static func containsOptionModifier(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate)
    }

    private func setCaptureTapEnabled(_ enabled: Bool) {
        guard let tap = captureEventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
    }

    static func qualifiesAsCaptureDrag(
        start: CGPoint,
        end: CGPoint,
        minimumDistance: CGFloat = AskBoxInputInterceptor.minimumDragDistanceToBeginCapture
    ) -> Bool {
        dragDistance(from: start, to: end) >= minimumDistance
    }

    static func cocoaPoint(fromSystemPoint point: CGPoint, referenceMaxY: CGFloat? = nil) -> CGPoint {
        let resolvedMaxY = referenceMaxY ?? quartzCoordinateReferenceMaxY()
        return CGPoint(x: point.x, y: resolvedMaxY - point.y)
    }

    private static func dragDistance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return sqrt(dx * dx + dy * dy)
    }

    private static func startPoint(from phase: CapturePhase) -> CGPoint {
        switch phase {
        case .idle:
            return .zero
        case .armed(let startPoint, _, _), .capturing(let startPoint, _, _):
            return startPoint
        }
    }

    private static func beganAt(from phase: CapturePhase) -> CFAbsoluteTime {
        switch phase {
        case .idle:
            return 0
        case .armed(_, _, let beganAt), .capturing(_, _, let beganAt):
            return beganAt
        }
    }

    private static func quartzCoordinateReferenceMaxY() -> CGFloat {
        if let mainDisplayScreen = NSScreen.screens.first(where: {
            abs($0.frame.origin.x) <= 1 && abs($0.frame.origin.y) <= 1
        }) {
            return mainDisplayScreen.frame.maxY
        }
        return NSScreen.screens.first?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
    }

    private static func elapsedMilliseconds(from start: CFAbsoluteTime, to end: CFAbsoluteTime) -> Int {
        Int(((end - start) * 1000).rounded())
    }
}

#endif
