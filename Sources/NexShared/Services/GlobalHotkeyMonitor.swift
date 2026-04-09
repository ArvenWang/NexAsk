import AppKit
import CoreGraphics
import Foundation

final class GlobalHotkeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackGlobalMonitor: Any?
    private var onHotkey: (() -> Void)?
    private var shortcut: KeyboardShortcut?
    private var consumeMatch = false

    deinit {
        stop()
    }

    func start(shortcut: KeyboardShortcut, consumeMatch: Bool, onHotkey: @escaping () -> Void) {
        stop()
        self.shortcut = shortcut
        self.consumeMatch = consumeMatch
        self.onHotkey = onHotkey

        let ref = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: (1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handleEvent(type: type, event: event)
            },
            userInfo: ref
        ) else {
            // Fallback path if event tap cannot be created.
            fallbackGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self,
                      let shortcut = self.shortcut,
                      ShortcutSupport.matches(event: event, shortcut: shortcut) else {
                    return
                }
                self.onHotkey?()
            }
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let monitor = fallbackGlobalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        fallbackGlobalMonitor = nil

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        onHotkey = nil
        shortcut = nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, let shortcut else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)).intersection([.command, .shift, .option, .control])

        guard keyCode == shortcut.keyCode,
              modifiers == ShortcutSupport.normalizedModifiers(shortcut.modifierFlags) else {
            return Unmanaged.passUnretained(event)
        }

        if Thread.isMainThread {
            onHotkey?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onHotkey?()
            }
        }

        return consumeMatch ? nil : Unmanaged.passUnretained(event)
    }
}
