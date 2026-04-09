import AppKit

final class SettingsScreenshotShortcutRecorder {
    typealias CaptureHandler = (UInt16, NSEvent.ModifierFlags) -> Void

    private let captureHandler: CaptureHandler
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    init(captureHandler: @escaping CaptureHandler) {
        self.captureHandler = captureHandler
    }

    var isActive: Bool {
        tap != nil
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let ref = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: (1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<SettingsScreenshotShortcutRecorder>.fromOpaque(userInfo).takeUnretainedValue()
                return recorder.handleTapEvent(type: type, event: event)
            },
            userInfo: ref
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tapSource = nil
        if let tap {
            CFMachPortInvalidate(tap)
        }
        tap = nil
    }

    deinit {
        stop()
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        DispatchQueue.main.async { [captureHandler] in
            captureHandler(keyCode, flags)
        }
        return nil
    }
}
