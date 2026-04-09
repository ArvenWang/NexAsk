import AppKit

struct ShortcutConflict {
    let title: String
    let detail: String
}

enum ShortcutSupport {
    static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .shift, .option, .control])
    }

    static func matches(event: NSEvent, shortcut: KeyboardShortcut) -> Bool {
        UInt16(event.keyCode) == shortcut.keyCode
            && normalizedModifiers(event.modifierFlags) == normalizedModifiers(shortcut.modifierFlags)
    }

    static func displayText(for shortcut: KeyboardShortcut) -> String {
        let flags = normalizedModifiers(shortcut.modifierFlags)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyDisplayName(for: shortcut.keyCode))
        return parts.joined()
    }

    static func conflict(for shortcut: KeyboardShortcut) -> ShortcutConflict? {
        let candidates: [(KeyboardShortcut, ShortcutConflict)] = [
            (
                KeyboardShortcut(keyCode: 20, modifierFlags: [.command, .shift]),
                ShortcutConflict(
                    title: L10n.text(zhHans: "系统截图", en: "System Screenshot"),
                    detail: L10n.text(zhHans: "⌘⇧3 通常用于系统全屏截图", en: "⌘⇧3 is usually used for a full-screen macOS screenshot")
                )
            ),
            (
                KeyboardShortcut(keyCode: 21, modifierFlags: [.command, .shift]),
                ShortcutConflict(
                    title: L10n.text(zhHans: "系统截图", en: "System Screenshot"),
                    detail: L10n.text(zhHans: "⌘⇧4 通常用于系统区域截图", en: "⌘⇧4 is usually used for an area screenshot in macOS")
                )
            ),
            (
                KeyboardShortcut(keyCode: 23, modifierFlags: [.command, .shift]),
                ShortcutConflict(
                    title: L10n.text(zhHans: "系统截图", en: "System Screenshot"),
                    detail: L10n.text(zhHans: "⌘⇧5 通常用于系统截图工具", en: "⌘⇧5 is usually used for the macOS screenshot tool")
                )
            )
        ]

        for (candidate, conflict) in candidates {
            if normalizedModifiers(candidate.modifierFlags) == normalizedModifiers(shortcut.modifierFlags)
                && candidate.keyCode == shortcut.keyCode {
                return conflict
            }
        }
        return nil
    }

    static func keyDisplayName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 49: return "Space"
        case 50: return "`"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key\(keyCode)"
        }
    }
}
