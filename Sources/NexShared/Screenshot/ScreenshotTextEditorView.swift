import AppKit

final class ScreenshotTextEditorTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "a":
            selectAll(nil)
            return true
        case "c":
            copy(nil)
            return true
        case "v":
            paste(nil)
            return true
        case "x":
            cut(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if event.keyCode == 36 && !flags.contains(.shift) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }
}

final class ScreenshotTextEditorView: NSView, NSTextViewDelegate {
    var onCommit: ((String, CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let horizontalPadding = DesignTokens.Screenshot.Editor.horizontalPadding
    private let verticalPadding = DesignTokens.Screenshot.Editor.verticalPadding
    private let minimumWidth = DesignTokens.Screenshot.Editor.minWidth
    private let maximumWidth = DesignTokens.Screenshot.Editor.maxWidth
    private let minimumHeight = DesignTokens.Screenshot.Editor.minHeight
    private let contentMargin = DesignTokens.Screenshot.Editor.contentMargin
    private var selectionRect: CGRect = .zero
    private var preferredOrigin: CGPoint = .zero
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()
    let textView: ScreenshotTextEditorTextView

    var isEditing: Bool { !isHidden }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textView = ScreenshotTextEditorTextView(frame: .zero, textContainer: textContainer)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Screenshot.Editor.cornerRadius
        layer?.backgroundColor = DesignTokens.Screenshot.Editor.surface.cgColor
        layer?.borderWidth = DesignTokens.Screenshot.Editor.borderWidth
        layer?.borderColor = DesignTokens.Screenshot.Editor.border.cgColor

        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        textContainer.containerSize = CGSize(width: minimumWidth, height: .greatestFiniteMagnitude)

        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textColor = DesignTokens.Screenshot.Editor.defaultTextColor
        textView.font = DesignTokens.Typography.screenshotTextEditorDefault
        textView.insertionPointColor = DesignTokens.Screenshot.Editor.insertionPoint
        textView.delegate = self
        textView.onCommit = { [weak self] in self?.commitEditing() }
        textView.onCancel = { [weak self] in self?.cancelEditing() }

        addSubview(textView)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func beginEditing(
        at point: CGPoint,
        selectionRect: CGRect,
        fontSize: CGFloat,
        color: NSColor,
        initialText: String,
        preferredRect: CGRect? = nil,
        in hostView: NSView
    ) {
        self.selectionRect = selectionRect
        isHidden = false
        if superview == nil {
            hostView.addSubview(self)
        }
        updateStyle(fontSize: fontSize, color: color)
        textView.string = initialText

        let initialHeight = max(minimumHeight, fontSize + (verticalPadding * 2) + DesignTokens.Screenshot.Editor.initialHeightExtra)
        if let preferredRect {
            preferredOrigin = CGPoint(
                x: preferredRect.minX - horizontalPadding,
                y: preferredRect.minY - verticalPadding
            )
            frame = CGRect(origin: preferredRect.origin, size: preferredRect.size)
                .insetBy(dx: -horizontalPadding, dy: -verticalPadding)
                .integral
        } else {
            var originX = min(max(point.x, selectionRect.minX + contentMargin), selectionRect.maxX - minimumWidth - contentMargin)
            if originX.isNaN || originX.isInfinite {
                originX = selectionRect.minX + contentMargin
            }
            let centeredY = point.y - (initialHeight / 2)
            let originY = min(max(centeredY, selectionRect.minY + contentMargin), selectionRect.maxY - initialHeight - contentMargin)
            preferredOrigin = CGPoint(x: originX, y: originY)
            frame = CGRect(x: originX, y: originY, width: minimumWidth, height: initialHeight).integral
        }
        textContainer.containerSize = CGSize(
            width: max(DesignTokens.Screenshot.Editor.minTextContainerWidth, frame.width - (horizontalPadding * 2)),
            height: .greatestFiniteMagnitude
        )
        textContainer.widthTracksTextView = true
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        layoutTextEditorIfNeeded()
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(textView)
    }

    func updateStyle(fontSize: CGFloat, color: NSColor) {
        textView.font = DesignTokens.Screenshot.Annotation.textFont(ofSize: fontSize)
        textView.textColor = color
        layoutTextEditorIfNeeded()
        needsDisplay = true
    }

    func commitEditing() {
        guard isEditing else { return }
        let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let annotationRect = textAnnotationRect()
        isHidden = true
        if !trimmed.isEmpty {
            onCommit?(trimmed, annotationRect)
        } else {
            onCancel?()
        }
    }

    func cancelEditing() {
        guard isEditing else { return }
        isHidden = true
        textView.string = ""
        onCancel?()
    }

    func contains(localPoint: CGPoint) -> Bool {
        isEditing && frame.contains(localPoint)
    }

    func textDidChange(_ notification: Notification) {
        layoutTextEditorIfNeeded()
    }

    override func layout() {
        super.layout()
        let textFrame = bounds.insetBy(dx: horizontalPadding, dy: verticalPadding)
        textView.frame = CGRect(
            x: textFrame.minX,
            y: textFrame.minY,
            width: max(1, textFrame.width),
            height: max(1, textFrame.height)
        ).integral
    }

    private func layoutTextEditorIfNeeded() {
        guard isEditing else { return }
        let maxWidth = max(minimumWidth, min(maximumWidth, selectionRect.width - (contentMargin * 2)))
        let availableRightWidth = max(minimumWidth, selectionRect.maxX - preferredOrigin.x - contentMargin)
        let effectiveMaxWidth = min(maxWidth, availableRightWidth)
        let measuredTextWidth = measuredContentWidth()
        let targetWidth = min(max(minimumWidth, measuredTextWidth + (horizontalPadding * 2)), effectiveMaxWidth)
        textContainer.containerSize = CGSize(
            width: max(DesignTokens.Screenshot.Editor.minTextContainerWidth, targetWidth - (horizontalPadding * 2)),
            height: .greatestFiniteMagnitude
        )
        textView.layoutManager?.ensureLayout(for: textContainer)
        let usedRect = textView.layoutManager?.usedRect(for: textContainer) ?? .zero
        let desiredHeight = max(
            minimumHeight,
            ceil(usedRect.height) + (verticalPadding * 2) + DesignTokens.Screenshot.Editor.usedRectHeightPadding
        )
        let maxHeight = max(minimumHeight, selectionRect.maxY - preferredOrigin.y - contentMargin)
        let nextHeight = min(desiredHeight, maxHeight)
        var originX = preferredOrigin.x
        var originY = preferredOrigin.y
        if originX + targetWidth > selectionRect.maxX - contentMargin {
            originX = max(selectionRect.minX + contentMargin, selectionRect.maxX - targetWidth - contentMargin)
        }
        if originY + nextHeight > selectionRect.maxY - contentMargin {
            originY = max(selectionRect.minY + contentMargin, selectionRect.maxY - nextHeight - contentMargin)
        }
        let nextFrame = CGRect(x: originX, y: originY, width: targetWidth, height: nextHeight).integral
        guard abs(frame.width - nextFrame.width) > 0.5
            || abs(frame.height - nextFrame.height) > 0.5
            || abs(frame.minX - nextFrame.minX) > 0.5
            || abs(frame.minY - nextFrame.minY) > 0.5 else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }
        frame = nextFrame
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func measuredContentWidth() -> CGFloat {
        let text = textView.string
        guard !text.isEmpty else { return 32 }
        let font = textView.font ?? DesignTokens.Typography.screenshotTextEditorDefault
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let lines = text.components(separatedBy: .newlines)
        let widestLine = lines.max { lhs, rhs in
            (lhs as NSString).size(withAttributes: attributes).width < (rhs as NSString).size(withAttributes: attributes).width
        } ?? text
        return ceil((widestLine as NSString).size(withAttributes: attributes).width) + DesignTokens.Screenshot.Editor.measuredWidthPadding
    }

    private func textAnnotationRect() -> CGRect {
        CGRect(
            x: frame.minX + horizontalPadding,
            y: frame.minY + verticalPadding,
            width: max(1, frame.width - (horizontalPadding * 2)),
            height: max(1, frame.height - (verticalPadding * 2))
        ).integral
    }
}
