import AppKit

protocol SettingsInputStylable: AnyObject {
    func applySettingsInputStyle()
}

private final class SettingsInsetTextFieldCell: NSTextFieldCell {
    private let insets = NSEdgeInsets(top: 0, left: DesignTokens.Settings.Input.horizontalInset, bottom: 0, right: DesignTokens.Settings.Input.horizontalInset)

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        adjustedRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        adjustedRect(for: rect)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: adjustedRect(for: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: adjustedRect(for: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    private func adjustedRect(for rect: NSRect) -> NSRect {
        let insetRect = NSRect(
            x: rect.origin.x + insets.left,
            y: rect.origin.y,
            width: max(0, rect.width - insets.left - insets.right),
            height: rect.height
        )
        let textHeight = cellSize(forBounds: insetRect).height
        let centeredY = rect.origin.y + floor((rect.height - textHeight) / 2)
        return NSRect(x: insetRect.origin.x, y: centeredY, width: insetRect.width, height: textHeight)
    }
}

private final class SettingsInsetSecureTextFieldCell: NSSecureTextFieldCell {
    private let horizontalInset = DesignTokens.Settings.Input.horizontalInset

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        adjustedRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        adjustedRect(for: rect)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: adjustedRect(for: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: adjustedRect(for: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    private func adjustedRect(for rect: NSRect) -> NSRect {
        let insetRect = NSRect(
            x: rect.origin.x + horizontalInset,
            y: rect.origin.y,
            width: max(0, rect.width - (horizontalInset * 2)),
            height: rect.height
        )
        let textHeight = cellSize(forBounds: insetRect).height
        let centeredY = rect.origin.y + floor((rect.height - textHeight) / 2)
        return NSRect(x: insetRect.origin.x, y: centeredY, width: insetRect.width, height: textHeight)
    }
}

private protocol PasteFriendlyEditing: NSControl {
    func currentEditor() -> NSText?
}

extension NSTextField: PasteFriendlyEditing {}

private extension PasteFriendlyEditing {
    func handleStandardEditCommand(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }

        switch key {
        case "v":
            currentEditor()?.paste(nil)
            return true
        case "c":
            currentEditor()?.copy(nil)
            return true
        case "x":
            currentEditor()?.cut(nil)
            return true
        case "a":
            currentEditor()?.selectAll(nil)
            return true
        default:
            return false
        }
    }
}

final class PasteFriendlySecureField: NSSecureTextField {
    private var settingsHoverTrackingArea: NSTrackingArea?
    private var isSettingsHovering = false
    private var isSettingsFocused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSettingsInputSupport()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSettingsInputSupport()
    }

    package override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleStandardEditCommand(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    package override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            isSettingsFocused = true
            refreshSettingsAppearance()
        }
        return accepted
    }

    package override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            isSettingsFocused = false
            refreshSettingsAppearance()
        }
        return resigned
    }

    package override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let settingsHoverTrackingArea {
            removeTrackingArea(settingsHoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        settingsHoverTrackingArea = trackingArea
    }

    package override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isSettingsHovering = true
        refreshSettingsAppearance()
    }

    package override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isSettingsHovering = false
        refreshSettingsAppearance()
    }

    private func configureSettingsInputSupport() {
        wantsLayer = true
        if !(cell is SettingsInsetSecureTextFieldCell) {
            let existingCell = cell as? NSSecureTextFieldCell
            let customCell = SettingsInsetSecureTextFieldCell(textCell: stringValue)
            customCell.isEditable = existingCell?.isEditable ?? true
            customCell.isSelectable = existingCell?.isSelectable ?? true
            customCell.isScrollable = existingCell?.isScrollable ?? true
            customCell.lineBreakMode = existingCell?.lineBreakMode ?? .byTruncatingTail
            customCell.usesSingleLineMode = true
            customCell.placeholderString = placeholderString
            cell = customCell
        }
    }

    private func refreshSettingsAppearance() {
        guard wantsLayer else { return }
        layer?.cornerRadius = DesignTokens.Settings.Input.cornerRadius
        layer?.borderWidth = DesignTokens.Settings.Input.borderWidth
        let backgroundColor = isSettingsFocused
            ? DesignTokens.Settings.Input.focusSurface
            : (isSettingsHovering ? DesignTokens.Settings.Input.hoverSurface : DesignTokens.Settings.Input.surface)
        let borderColor = isSettingsFocused
            ? DesignTokens.Settings.Input.focusBorder
            : (isSettingsHovering ? DesignTokens.Settings.Input.hoverBorder : DesignTokens.Settings.Input.border)
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
    }
}

extension PasteFriendlySecureField: SettingsInputStylable {
    func applySettingsInputStyle() {
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        refreshSettingsAppearance()
    }
}

package final class PasteFriendlyTextField: NSTextField {
    private var settingsHoverTrackingArea: NSTrackingArea?
    private var isSettingsHovering = false
    private var isSettingsFocused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSettingsInputSupport()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSettingsInputSupport()
    }

    package override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleStandardEditCommand(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    package override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            isSettingsFocused = true
            refreshSettingsAppearance()
        }
        return accepted
    }

    package override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            isSettingsFocused = false
            refreshSettingsAppearance()
        }
        return resigned
    }

    package override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let settingsHoverTrackingArea {
            removeTrackingArea(settingsHoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        settingsHoverTrackingArea = trackingArea
    }

    package override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isSettingsHovering = true
        refreshSettingsAppearance()
    }

    package override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isSettingsHovering = false
        refreshSettingsAppearance()
    }

    private func configureSettingsInputSupport() {
        wantsLayer = true
        if !(cell is SettingsInsetTextFieldCell) {
            let existingCell = cell as? NSTextFieldCell
            let customCell = SettingsInsetTextFieldCell(textCell: stringValue)
            customCell.isEditable = existingCell?.isEditable ?? true
            customCell.isSelectable = existingCell?.isSelectable ?? true
            customCell.isScrollable = existingCell?.isScrollable ?? true
            customCell.lineBreakMode = existingCell?.lineBreakMode ?? .byTruncatingTail
            customCell.usesSingleLineMode = true
            customCell.placeholderString = placeholderString
            cell = customCell
        }
    }

    private func refreshSettingsAppearance() {
        guard wantsLayer else { return }
        layer?.cornerRadius = DesignTokens.Settings.Input.cornerRadius
        layer?.borderWidth = DesignTokens.Settings.Input.borderWidth
        let backgroundColor = isSettingsFocused
            ? DesignTokens.Settings.Input.focusSurface
            : (isSettingsHovering ? DesignTokens.Settings.Input.hoverSurface : DesignTokens.Settings.Input.surface)
        let borderColor = isSettingsFocused
            ? DesignTokens.Settings.Input.focusBorder
            : (isSettingsHovering ? DesignTokens.Settings.Input.hoverBorder : DesignTokens.Settings.Input.border)
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
    }
}

extension PasteFriendlyTextField: SettingsInputStylable {
    func applySettingsInputStyle() {
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        refreshSettingsAppearance()
    }
}
