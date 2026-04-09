import AppKit

final class InlineActionPromptController {
    private let panel: NSPanel
    private let hostView = NSView(frame: .zero)
    private let surfaceView = PanelSurfaceView(style: .toolbar)
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let contentStack = NSStackView()

    private var actionHandler: (() -> Void)?
    private var autoHideWorkItem: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: DesignTokens.InlinePrompt.initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentView = hostView

        configureContentView()
    }

    var isVisible: Bool { panel.isVisible }

    func contains(screenPoint: CGPoint) -> Bool {
        panel.isVisible && panel.frame.contains(screenPoint)
    }

    func show(
        message: String,
        actionTitle: String? = nil,
        near anchor: NSRect,
        onAction: (() -> Void)? = nil,
        autoHideAfter: TimeInterval? = nil
    ) {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        actionHandler = onAction
        messageLabel.stringValue = message
        applyActionButtonTitle(actionTitle)

        let frame = resolvedFrame(near: anchor)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        if let autoHideAfter {
            let workItem = DispatchWorkItem { [weak self] in
                self?.hide()
            }
            autoHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHideAfter, execute: workItem)
        }
    }

    func hide() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
        actionHandler = nil
        panel.orderOut(nil)
    }

    private func configureContentView() {
        guard let contentView = panel.contentView else { return }

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.refreshAppearance()

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: "warning")
        iconView.contentTintColor = DesignTokens.InlinePrompt.warningColor
        iconView.symbolConfiguration = .init(pointSize: DesignTokens.InlinePrompt.iconPointSize, weight: .semibold)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.widthAnchor.constraint(equalToConstant: DesignTokens.InlinePrompt.iconDimension).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: DesignTokens.InlinePrompt.iconDimension).isActive = true

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = DesignTokens.Typography.inlinePromptMessage
        messageLabel.textColor = DesignTokens.Color.textSecondary
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = DesignTokens.InlinePrompt.maxMessageLines
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.isBordered = false
        actionButton.font = DesignTokens.Typography.inlinePromptAction
        actionButton.setButtonType(.momentaryPushIn)
        actionButton.bezelStyle = .regularSquare
        actionButton.target = self
        actionButton.action = #selector(handleAction)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = DesignTokens.InlinePrompt.stackSpacing
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(messageLabel)
        contentStack.addArrangedSubview(actionButton)

        contentView.addSubview(surfaceView)
        surfaceView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: contentView.topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: DesignTokens.InlinePrompt.contentHorizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor, constant: -DesignTokens.InlinePrompt.contentHorizontalInset),
            contentStack.topAnchor.constraint(equalTo: surfaceView.topAnchor, constant: DesignTokens.InlinePrompt.contentVerticalInset),
            contentStack.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor, constant: -DesignTokens.InlinePrompt.contentVerticalInset),
        ])
    }

    private func resolvedFrame(near anchor: NSRect) -> NSRect {
        let size = preferredSize()
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let x = inlinePromptClamp(
            anchor.midX - size.width / 2,
            min: visibleFrame.minX + DesignTokens.InlinePrompt.viewportInset,
            max: visibleFrame.maxX - size.width - DesignTokens.InlinePrompt.viewportInset
        )
        var y = anchor.minY - size.height - DesignTokens.InlinePrompt.anchorGap
        if y < visibleFrame.minY + DesignTokens.InlinePrompt.viewportInset {
            y = anchor.maxY + DesignTokens.InlinePrompt.anchorGap
        }
        y = inlinePromptClamp(
            y,
            min: visibleFrame.minY + DesignTokens.InlinePrompt.viewportInset,
            max: visibleFrame.maxY - size.height - DesignTokens.InlinePrompt.viewportInset
        )

        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func preferredSize() -> NSSize {
        hostView.layoutSubtreeIfNeeded()
        let fitting = contentStack.fittingSize
        let width = inlinePromptClamp(
            fitting.width + DesignTokens.InlinePrompt.widthPadding,
            min: DesignTokens.InlinePrompt.minWidth,
            max: DesignTokens.InlinePrompt.maxWidth
        )
        let height = max(DesignTokens.InlinePrompt.minHeight, fitting.height + DesignTokens.InlinePrompt.heightPadding)
        return NSSize(width: width, height: height)
    }

    private func applyActionButtonTitle(_ title: String?) {
        let normalized = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            actionButton.attributedTitle = NSAttributedString(string: "")
            actionButton.isHidden = true
            return
        }

        actionButton.isHidden = false
        actionButton.attributedTitle = NSAttributedString(
            string: normalized,
            attributes: [
                .font: DesignTokens.Typography.inlinePromptAction,
                .foregroundColor: DesignTokens.InlinePrompt.actionColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        )
    }

    @objc private func handleAction() {
        guard !actionButton.isHidden else { return }
        let action = actionHandler
        hide()
        action?()
    }
}

private func inlinePromptClamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    Swift.max(minValue, Swift.min(maxValue, value))
}
