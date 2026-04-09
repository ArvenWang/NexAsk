import AppKit

protocol FloatingToolbarControllerDelegate: AnyObject {
    func floatingToolbar(_ controller: FloatingToolbarController, didTapSkill skillID: String)
    func floatingToolbar(_ controller: FloatingToolbarController, didTapMoreWith secondarySkillIDs: [String])
    func floatingToolbarDidTapScreenshotLongCapture(_ controller: FloatingToolbarController)
    func floatingToolbarDidTapScreenshotFinishScrolling(_ controller: FloatingToolbarController)
    func floatingToolbarDidTapScreenshotCancelScrolling(_ controller: FloatingToolbarController)
    func floatingToolbarDidTapScreenshotCancelSession(_ controller: FloatingToolbarController)
    func floatingToolbarDidTapScreenshotConfirm(_ controller: FloatingToolbarController)
    func floatingToolbar(_ controller: FloatingToolbarController, didTapScreenshotTool tool: ScreenshotEditingTool)
    func floatingToolbar(_ controller: FloatingToolbarController, didTapScreenshotStrokeSize size: ScreenshotStrokeSize)
    func floatingToolbar(_ controller: FloatingToolbarController, didTapScreenshotColor color: ScreenshotAnnotationColor)
}

final class FloatingToolbarController {
    private enum PresentationMode {
        case compact
        case expanded
    }

    private static let maxPrimarySkillCount = 3
    private static let strokeDotCanvas: CGFloat = 20
    private static let colorDotCanvas: CGFloat = 20

    weak var delegate: FloatingToolbarControllerDelegate?
    private let actionRegistry = ActionRegistry.shared

    private let panel: NSPanel
    private let hostView = NSView(frame: .zero)
    private let rootView = PanelSurfaceView(style: .toolbar)
    private let rowStack = NSStackView()

    private let countView = RollingCountView()
    private let screenshotDimensionView = ScreenshotDimensionView()
    private let screenshotLongCaptureButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotScrollFinishButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotScrollCancelButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotBrushButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotRectangleButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotTextButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotArrowButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotStrokeDrawerButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotColorDrawerButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotSmallSizeButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotMediumSizeButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotLargeSizeButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotRedColorButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotYellowColorButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotGreenColorButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotBlueColorButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotCancelSessionButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let screenshotConfirmButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let actionSeparator = NSView()
    private let moreButton = HoverToolbarButton(title: "", target: nil, action: nil)
    private let skillButtons = (0..<FloatingToolbarController.maxPrimarySkillCount).map { _ in
        HoverToolbarButton(title: "", target: nil, action: nil)
    }

    private(set) var isPresentingMenu = false
    private var skillWidthConstraints: [NSLayoutConstraint] = []
    private var presentationMode: PresentationMode = .expanded
    private var pendingRevealWorkItem: DispatchWorkItem?
    private var compactCountVisible = true
    private var slotLayout = ToolbarSlotLayoutState.empty
    private var loadingStatusText: String?
    private var selectedScreenshotTool: ScreenshotEditingTool = .none
    private var selectedScreenshotStrokeSize: ScreenshotStrokeSize = .small
    private var selectedScreenshotColor: ScreenshotAnnotationColor = .red
    private var screenshotToolbarMode: ScreenshotToolbarMode = .editing
    private let strokeDrawerController = ToolbarDrawerController()
    private let colorDrawerController = ToolbarDrawerController()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 336, height: DesignTokens.Toolbar.height),
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
        panel.isMovableByWindowBackground = true
        panel.contentView = hostView

        configureContentView()
        let initialPrimary = actionRegistry.defaultPrimarySkillIDs(settings: .shared, maxCount: Self.maxPrimarySkillCount)
        let initialSecondary = actionRegistry.defaultSecondarySkillIDs(settings: .shared, excluding: initialPrimary)
        updateSlotLayout(
            ToolbarSlotLayoutState(
                recognitionSlot: .textCount(),
                skillSlots: Array(initialPrimary.prefix(Self.maxPrimarySkillCount)).enumerated().map { index, skillID in
                    SkillSlotState(slotIndex: index, skillID: skillID)
                },
                moreSlot: MoreSlotState(skillIDs: initialSecondary)
            )
        )
        applyPresentationMode(.expanded, at: nil, animated: false, preserveCompactAnchor: false)
    }

    var frame: NSRect { panel.frame }
    var isVisible: Bool { panel.isVisible }
    var isCompactPresentation: Bool { presentationMode == .compact }
    var isShowingLoadingState: Bool { currentLoadingText != nil }
    private var primarySkillIDs: [String] { slotLayout.skillSlots.map(\.skillID) }
    private var secondarySkillIDs: [String] { slotLayout.moreSlot.skillIDs }
    private var currentLoadingText: String? { loadingStatusText }
    private var isScreenshotContext: Bool { slotLayout.recognitionSlot.kind == .screenshotSize }

    func contains(screenPoint: CGPoint) -> Bool {
        (panel.isVisible && panel.frame.contains(screenPoint))
            || strokeDrawerController.contains(screenPoint: screenPoint)
            || colorDrawerController.contains(screenPoint: screenPoint)
    }

    func setWindowLevel(_ level: NSWindow.Level) {
        panel.level = level
        strokeDrawerController.setWindowLevel(level)
        colorDrawerController.setWindowLevel(level)
    }

    func show(at point: CGPoint) {
        cancelPendingReveal()
        let shouldAnimateExpansion = panel.isVisible && presentationMode == .compact
        applyPresentationMode(
            .expanded,
            at: point,
            animated: shouldAnimateExpansion,
            preserveCompactAnchor: shouldAnimateExpansion
        )
        panel.orderFrontRegardless()
    }

    func showExpanded(atOrigin origin: CGPoint) {
        cancelPendingReveal()
        applyPresentationMode(.expanded, at: nil, animated: false, preserveCompactAnchor: false)
        var frame = panel.frame
        frame.origin = origin
        frame.size = panelSize(for: .expanded)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func expandedPanelSize() -> NSSize {
        panelSize(for: .expanded)
    }

    func reveal(at point: CGPoint) {
        reveal(at: point, compactHoldDelay: 0.05)
    }

    func revealImmediately(at point: CGPoint) {
        reveal(at: point, compactHoldDelay: 0)
    }

    private func reveal(at point: CGPoint, compactHoldDelay: TimeInterval) {
        cancelPendingReveal()
        compactCountVisible = false
        applyPresentationMode(.compact, at: point, animated: false, preserveCompactAnchor: false)
        panel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRevealWorkItem = nil
            self.applyPresentationMode(.expanded, at: point, animated: true, preserveCompactAnchor: true)
        }
        pendingRevealWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + compactHoldDelay, execute: workItem)
    }

    func showCompact(at point: CGPoint) {
        cancelPendingReveal()
        compactCountVisible = true
        applyPresentationMode(.compact, at: point, animated: false, preserveCompactAnchor: false)
        panel.orderFrontRegardless()
    }

    func move(to point: CGPoint) {
        guard panel.isVisible else { return }
        hideScreenshotDrawers()
        let newOrigin = origin(for: point, size: panel.frame.size)
        if panel.frame.origin == newOrigin { return }
        panel.setFrameOrigin(newOrigin)
    }

    func hide() {
        cancelPendingReveal()
        hideScreenshotDrawers()
        panel.orderOut(nil)
    }

    func restoreLoadingPresentationIfNeeded() {
        guard currentLoadingText != nil, !panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    func updateSlotLayout(_ layout: ToolbarSlotLayoutState) {
        let previousSlot = slotLayout.recognitionSlot
        let previousStatus = currentLoadingText
        var nextLayout = layout
        if previousStatus != nil {
            nextLayout.recognitionSlot.statusText = previousStatus
        }
        slotLayout = nextLayout
        hideScreenshotDrawers()
        applySkillSlots()
        applyRecognitionSlot(animated: shouldAnimateRecognitionSlotChange(from: previousSlot, to: nextLayout.recognitionSlot))
        refreshPillWidthConstraints()
        resizePanel(at: nil, animated: false)
    }

    func updateRecognitionSlot(_ slot: RecognitionSlotState) {
        let previousSlot = slotLayout.recognitionSlot
        let previousStatus = currentLoadingText
        var nextSlot = slot
        if previousStatus != nil {
            nextSlot.statusText = previousStatus
        }
        slotLayout.recognitionSlot = nextSlot
        hideScreenshotDrawers()
        applyRecognitionSlot(animated: shouldAnimateRecognitionSlotChange(from: previousSlot, to: nextSlot))
        resizePanel(at: nil, animated: false)
    }

    func setLoadingState(_ text: String?) {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != currentLoadingText else { return }
        loadingStatusText = normalized
        slotLayout.recognitionSlot.statusText = normalized

        let isLoading = normalized != nil
        skillButtons.forEach { $0.isEnabled = !isLoading }
        moreButton.isEnabled = !isLoading
        applyRecognitionSlot(animated: false)
        resizePanel(at: nil, animated: false)
    }

    func setScreenshotEditingState(
        tool: ScreenshotEditingTool,
        strokeSize: ScreenshotStrokeSize,
        color: ScreenshotAnnotationColor
    ) {
        let changed = selectedScreenshotTool != tool
            || selectedScreenshotStrokeSize != strokeSize
            || selectedScreenshotColor != color
        guard changed else { return }
        selectedScreenshotTool = tool
        selectedScreenshotStrokeSize = strokeSize
        selectedScreenshotColor = color
        refreshScreenshotControls()
    }

    func setScreenshotToolbarMode(_ mode: ScreenshotToolbarMode) {
        guard screenshotToolbarMode != mode else { return }
        screenshotToolbarMode = mode
        hideScreenshotDrawers()
        refreshScreenshotControls()
        if presentationMode == .expanded {
            resizePanel(at: nil, animated: false, preserveCompactAnchor: true)
        }
    }

    func present(menu: NSMenu) {
        guard let contentView = panel.contentView else { return }
        hideScreenshotDrawers()
        isPresentingMenu = true
        menu.popUp(positioning: nil, at: NSPoint(x: panel.frame.width - 20, y: 10), in: contentView)
        isPresentingMenu = false
    }

    private func configureContentView() {
        guard let contentView = panel.contentView else { return }

        rootView.frame = contentView.bounds
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.refreshAppearance()

        countView.setContentHuggingPriority(.required, for: .horizontal)
        countView.setContentCompressionResistancePriority(.required, for: .horizontal)
        countView.setEmphasized(false)
        screenshotDimensionView.setContentHuggingPriority(.required, for: .horizontal)
        screenshotDimensionView.setContentCompressionResistancePriority(.required, for: .horizontal)
        screenshotDimensionView.setEmphasized(false)
        applyRecognitionSlot(animated: false)

        configureSeparator(actionSeparator)
        configureScreenshotToolbarButton(
            screenshotLongCaptureButton,
            title: L10n.text(zhHans: "长截屏", en: "Long Capture"),
            symbolName: "arrow.up.and.down.circle",
            iconOnly: true
        )
        configureScreenshotToolbarButton(
            screenshotScrollFinishButton,
            title: L10n.text(zhHans: "确定", en: "Confirm"),
            symbolName: "checkmark",
            iconOnly: true
        )
        configureScreenshotToolbarButton(
            screenshotScrollCancelButton,
            title: L10n.text(zhHans: "取消", en: "Cancel"),
            symbolName: "xmark",
            iconOnly: true
        )
        configureScreenshotToolbarButton(
            screenshotBrushButton,
            title: L10n.text(zhHans: "画笔", en: "Brush"),
            symbolName: "pencil",
            iconOnly: true
        )
        configureScreenshotToolbarButton(
            screenshotRectangleButton,
            title: L10n.text(zhHans: "矩形", en: "Rectangle"),
            symbolName: "rectangle",
            iconOnly: true
        )
        configureScreenshotToolbarButton(
            screenshotTextButton,
            title: L10n.text(zhHans: "文字", en: "Text"),
            symbolName: "character.textbox",
            iconOnly: true
        )
        configureScreenshotToolbarButton(
            screenshotArrowButton,
            title: L10n.text(zhHans: "箭头", en: "Arrow"),
            symbolName: "arrow.up.right",
            iconOnly: true
        )
        configureScreenshotToolbarButton(
            screenshotStrokeDrawerButton,
            title: L10n.text(zhHans: "画笔粗细", en: "Stroke Size"),
            symbolName: "circle.fill",
            iconOnly: true
        )
        configureScreenshotToolbarButton(
            screenshotColorDrawerButton,
            title: L10n.text(zhHans: "画笔颜色", en: "Color"),
            symbolName: "circle.fill",
            iconOnly: true
        )
        configureScreenshotSizeButton(screenshotSmallSizeButton, size: .small)
        configureScreenshotSizeButton(screenshotMediumSizeButton, size: .medium)
        configureScreenshotSizeButton(screenshotLargeSizeButton, size: .large)
        configureScreenshotColorButton(screenshotRedColorButton, color: .red)
        configureScreenshotColorButton(screenshotYellowColorButton, color: .yellow)
        configureScreenshotColorButton(screenshotGreenColorButton, color: .green)
        configureScreenshotColorButton(screenshotBlueColorButton, color: .blue)
        configureScreenshotToolbarButton(
            screenshotCancelSessionButton,
            title: L10n.text(zhHans: "取消截图", en: "Cancel Capture"),
            symbolName: "xmark.circle.fill",
            iconOnly: true
        )
        screenshotCancelSessionButton.contentTintColor = DesignTokens.Toolbar.ScreenshotControl.cancelTint
        configureScreenshotToolbarButton(
            screenshotConfirmButton,
            title: L10n.text(zhHans: "确认截图", en: "Confirm Capture"),
            symbolName: "checkmark.circle.fill",
            iconOnly: true
        )
        screenshotConfirmButton.contentTintColor = DesignTokens.Toolbar.ScreenshotControl.confirmTint
        skillButtons.forEach {
            configureToolbarButton($0)
            $0.target = self
            $0.action = #selector(handleSkillButton(_:))
        }

        moreButton.isBordered = false
        moreButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L10n.text(zhHans: "更多", en: "More"))
        moreButton.contentTintColor = DesignTokens.Color.iconPrimary
        moreButton.imageScaling = .scaleProportionallyDown

        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = DesignTokens.Toolbar.itemSpacing
        rowStack.setContentHuggingPriority(.required, for: .horizontal)
        rowStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        rowStack.addArrangedSubview(countView)
        rowStack.addArrangedSubview(screenshotDimensionView)
        rowStack.addArrangedSubview(actionSeparator)
        rowStack.addArrangedSubview(screenshotLongCaptureButton)
        rowStack.addArrangedSubview(screenshotScrollFinishButton)
        rowStack.addArrangedSubview(screenshotScrollCancelButton)
        rowStack.addArrangedSubview(screenshotBrushButton)
        rowStack.addArrangedSubview(screenshotRectangleButton)
        rowStack.addArrangedSubview(screenshotTextButton)
        rowStack.addArrangedSubview(screenshotArrowButton)
        rowStack.addArrangedSubview(screenshotStrokeDrawerButton)
        rowStack.addArrangedSubview(screenshotColorDrawerButton)
        skillButtons.forEach { rowStack.addArrangedSubview($0) }
        rowStack.addArrangedSubview(moreButton)
        rowStack.addArrangedSubview(screenshotCancelSessionButton)
        rowStack.addArrangedSubview(screenshotConfirmButton)

        contentView.addSubview(rootView)
        rootView.addSubview(rowStack)

        var constraints: [NSLayoutConstraint] = [
            rootView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            rowStack.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            rowStack.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: DesignTokens.Toolbar.contentInsetLeading),
            rowStack.trailingAnchor.constraint(lessThanOrEqualTo: rootView.trailingAnchor, constant: -DesignTokens.Toolbar.contentInsetTrailing),
            rowStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: DesignTokens.Spacing.sm),
            rowStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -DesignTokens.Spacing.sm),

            moreButton.widthAnchor.constraint(equalToConstant: DesignTokens.Toolbar.chevronButtonSize),
            moreButton.heightAnchor.constraint(equalToConstant: DesignTokens.Toolbar.chevronButtonSize)
        ]

        for button in skillButtons {
            constraints.append(button.heightAnchor.constraint(equalToConstant: DesignTokens.Toolbar.controlHeight))
            let width = button.widthAnchor.constraint(equalToConstant: button.preferredPillWidth())
            width.isActive = true
            skillWidthConstraints.append(width)
        }
        NSLayoutConstraint.activate(constraints)

        moreButton.target = self
        moreButton.action = #selector(handleMore)
        screenshotLongCaptureButton.target = self
        screenshotLongCaptureButton.action = #selector(handleScreenshotLongCapture)
        screenshotScrollFinishButton.target = self
        screenshotScrollFinishButton.action = #selector(handleScreenshotScrollFinish)
        screenshotScrollCancelButton.target = self
        screenshotScrollCancelButton.action = #selector(handleScreenshotScrollCancel)
        screenshotBrushButton.target = self
        screenshotBrushButton.action = #selector(handleScreenshotBrushTool)
        screenshotRectangleButton.target = self
        screenshotRectangleButton.action = #selector(handleScreenshotRectangleTool)
        screenshotTextButton.target = self
        screenshotTextButton.action = #selector(handleScreenshotTextTool)
        screenshotArrowButton.target = self
        screenshotArrowButton.action = #selector(handleScreenshotArrowTool)
        screenshotStrokeDrawerButton.target = self
        screenshotStrokeDrawerButton.action = #selector(handleScreenshotStrokeDrawer)
        screenshotColorDrawerButton.target = self
        screenshotColorDrawerButton.action = #selector(handleScreenshotColorDrawer)
        screenshotSmallSizeButton.target = self
        screenshotSmallSizeButton.action = #selector(handleScreenshotSmallSize)
        screenshotMediumSizeButton.target = self
        screenshotMediumSizeButton.action = #selector(handleScreenshotMediumSize)
        screenshotLargeSizeButton.target = self
        screenshotLargeSizeButton.action = #selector(handleScreenshotLargeSize)
        screenshotRedColorButton.target = self
        screenshotRedColorButton.action = #selector(handleScreenshotRedColor)
        screenshotYellowColorButton.target = self
        screenshotYellowColorButton.action = #selector(handleScreenshotYellowColor)
        screenshotGreenColorButton.target = self
        screenshotGreenColorButton.action = #selector(handleScreenshotGreenColor)
        screenshotBlueColorButton.target = self
        screenshotBlueColorButton.action = #selector(handleScreenshotBlueColor)
        screenshotCancelSessionButton.target = self
        screenshotCancelSessionButton.action = #selector(handleScreenshotCancelSession)
        screenshotConfirmButton.target = self
        screenshotConfirmButton.action = #selector(handleScreenshotConfirm)
        strokeDrawerController.setButtons([
            screenshotLargeSizeButton,
            screenshotMediumSizeButton,
            screenshotSmallSizeButton
        ])
        colorDrawerController.setButtons([
            screenshotBlueColorButton,
            screenshotGreenColorButton,
            screenshotYellowColorButton,
            screenshotRedColorButton
        ])
        refreshScreenshotControls()
    }

    private func configureToolbarButton(_ button: NSButton) {
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.font = DesignTokens.Toolbar.font
        button.contentTintColor = DesignTokens.Color.iconPrimary
        button.setButtonType(.momentaryPushIn)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.isHidden = true
    }

    private func configureScreenshotToolbarButton(
        _ button: HoverToolbarButton,
        title: String,
        symbolName: String,
        iconOnly: Bool = false
    ) {
        configureToolbarButton(button)
        button.title = iconOnly ? "" : title
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = iconOnly ? .imageOnly : .imageLeading
        button.toolTip = title
    }

    private func configureScreenshotSizeButton(_ button: HoverToolbarButton, size: ScreenshotStrokeSize) {
        configureToolbarButton(button)
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = strokeSizeImage(for: size)
        button.imageScaling = .scaleNone
        button.toolTip = L10n.format(zhHans: "画笔尺寸%@", en: "Stroke size %@", size.displayName)
    }

    private func configureScreenshotColorButton(_ button: HoverToolbarButton, color: ScreenshotAnnotationColor) {
        configureToolbarButton(button)
        button.image = colorDotImage(color: color.nsColor)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = color.displayName
    }

    private func configureSkillButton(_ button: HoverToolbarButton, skillID: String?) {
        guard let skillID, let definition = actionRegistry.definition(forSkillID: skillID) else {
            button.identifier = nil
            button.title = ""
            button.image = nil
            button.toolTip = nil
            button.isHidden = true
            return
        }
        button.identifier = NSUserInterfaceItemIdentifier(skillID)
        button.title = isScreenshotContext ? "" : definition.toolbarTitle
        button.image = NSImage(systemSymbolName: definition.symbolName, accessibilityDescription: nil)
        button.imagePosition = isScreenshotContext ? .imageOnly : .imageLeading
        button.toolTip = definition.title
        button.isHidden = false
    }

    private func applyRecognitionSlot(animated: Bool) {
        let isScreenshotSlot = slotLayout.recognitionSlot.kind == .screenshotSize
        countView.isHidden = isScreenshotSlot
        screenshotDimensionView.isHidden = !isScreenshotSlot

        switch slotLayout.recognitionSlot.kind {
        case .textCount, .fileCount:
            countView.setRecognitionKind(slotLayout.recognitionSlot.kind)
            countView.setStatusText(slotLayout.recognitionSlot.statusText)
            guard slotLayout.recognitionSlot.statusText == nil else { return }
            countView.setCount(slotLayout.recognitionSlot.count, animated: animated)

        case .screenshotSize:
            screenshotDimensionView.setStatusText(slotLayout.recognitionSlot.statusText)
            guard slotLayout.recognitionSlot.statusText == nil else { return }
            screenshotDimensionView.setDimensions(
                slotLayout.recognitionSlot.dimensions ?? ScreenshotDimensionValue(width: 0, height: 0),
                animated: animated
            )
        }
    }

    private func shouldAnimateRecognitionSlotChange(
        from previousSlot: RecognitionSlotState,
        to nextSlot: RecognitionSlotState
    ) -> Bool {
        guard nextSlot.statusText == nil, previousSlot.statusText == nil else { return false }
        guard previousSlot.kind == nextSlot.kind else { return false }

        switch nextSlot.kind {
        case .textCount, .fileCount:
            return nextSlot.count != previousSlot.count
        case .screenshotSize:
            return nextSlot.dimensions != previousSlot.dimensions
        }
    }

    private func applySkillSlots() {
        for (index, button) in skillButtons.enumerated() {
            let skillID = slotLayout.skillSlots.first(where: { $0.slotIndex == index })?.skillID
            configureSkillButton(button, skillID: skillID)
        }
        refreshScreenshotControls()
    }

    private func configureSeparator(_ line: NSView) {
        line.wantsLayer = true
        line.layer?.backgroundColor = DesignTokens.Color.border.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 14).isActive = true
    }

    private func applyPresentationMode(
        _ mode: PresentationMode,
        at point: CGPoint?,
        animated: Bool,
        preserveCompactAnchor: Bool
    ) {
        presentationMode = mode
        hideScreenshotDrawers()
        refreshPillWidthConstraints()

        switch mode {
        case .compact:
            actionSeparator.isHidden = true
            screenshotButtons.forEach { $0.isHidden = true }
            skillButtons.forEach { $0.isHidden = true }
            moreButton.isHidden = true
            countView.setEmphasized(true)
            screenshotDimensionView.setEmphasized(true)
            countView.alphaValue = compactCountVisible ? 1 : 0
            screenshotDimensionView.alphaValue = compactCountVisible ? 1 : 0
            rootView.layer?.cornerRadius = DesignTokens.Radius.md
            resizePanel(at: point, animated: false)

        case .expanded:
            let visibleButtons = skillButtons.filter { button in
                guard let skillID = button.identifier?.rawValue else { return false }
                return primarySkillIDs.contains(skillID)
            }
            let hiddenViews: [NSView] = [actionSeparator] + screenshotButtons + visibleButtons + [moreButton]
            applyScreenshotVisibility()
            actionSeparator.isHidden = (isScreenshotContext && screenshotToolbarMode.isScrollFocused) || (!isScreenshotContext && primarySkillIDs.isEmpty)
            for button in skillButtons {
                guard let skillID = button.identifier?.rawValue else {
                    button.isHidden = true
                    continue
                }
                button.isHidden = !primarySkillIDs.contains(skillID) || (isScreenshotContext && screenshotToolbarMode.isScrollFocused)
            }
            moreButton.isHidden = isScreenshotContext && screenshotToolbarMode.isScrollFocused
            countView.setEmphasized(false)
            screenshotDimensionView.setEmphasized(false)
            rootView.layer?.cornerRadius = DesignTokens.Radius.md

            if animated {
                let countStartsHidden = !compactCountVisible
                compactCountVisible = true
                hiddenViews.forEach { view in
                    guard !view.isHidden else { return }
                    view.alphaValue = 0
                }
                if countStartsHidden {
                    countView.alphaValue = 0
                    screenshotDimensionView.alphaValue = 0
                }
                // Visual tuning for this sweep is centralized in DesignTokens.Effects.ToolbarSweep.
                rootView.playToolbarSweepGlow(travelWidth: panelSize(for: .expanded).width)
                resizePanel(at: point, animated: true, preserveCompactAnchor: preserveCompactAnchor)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = DesignTokens.Motion.medium
                    if countStartsHidden {
                        countView.animator().alphaValue = 1
                        screenshotDimensionView.animator().alphaValue = 1
                    }
                    hiddenViews.forEach { view in
                        guard !view.isHidden else { return }
                        view.animator().alphaValue = 1
                    }
                }
            } else {
                compactCountVisible = true
                countView.alphaValue = 1
                screenshotDimensionView.alphaValue = 1
                hiddenViews.forEach { $0.alphaValue = 1 }
                resizePanel(at: point, animated: false, preserveCompactAnchor: preserveCompactAnchor)
            }
        }
    }

    private func refreshPillWidthConstraints() {
        for (index, constraint) in skillWidthConstraints.enumerated() {
            guard index < skillButtons.count else { continue }
            constraint.constant = skillButtons[index].preferredPillWidth()
        }
    }

    private func resizePanel(at point: CGPoint?, animated: Bool, preserveCompactAnchor: Bool = false) {
        hideScreenshotDrawers()
        var frame = panel.frame
        let size = panelSize(for: presentationMode)
        let targetOrigin: NSPoint
        if preserveCompactAnchor, panel.isVisible {
            targetOrigin = anchoredOrigin(from: panel.frame, targetSize: size)
        } else if point == nil, panel.isVisible {
            targetOrigin = anchoredOrigin(from: panel.frame, targetSize: size)
        } else {
            let anchorPoint = point ?? CGPoint(x: frame.midX, y: frame.minY)
            targetOrigin = origin(for: anchorPoint, size: size)
        }
        frame.origin = targetOrigin
        frame.size = size

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DesignTokens.Motion.medium
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func panelSize(for mode: PresentationMode) -> NSSize {
        let visibleSubviews = rowStack.arrangedSubviews.filter { !$0.isHidden }
        let itemsWidth = visibleSubviews.reduce(CGFloat.zero) { partial, view in
            partial + view.fittingSize.width
        }
        let gapCount = max(0, visibleSubviews.count - 1)

        switch mode {
        case .compact:
            let width = itemsWidth
                + CGFloat(gapCount) * DesignTokens.Toolbar.itemSpacing
                + DesignTokens.Toolbar.compactInsetX * 2
            return NSSize(
                width: max(DesignTokens.Toolbar.compactMinWidth, width),
                height: DesignTokens.Toolbar.compactHeight
            )

        case .expanded:
            let width = itemsWidth
                + CGFloat(gapCount) * DesignTokens.Toolbar.itemSpacing
                + DesignTokens.Toolbar.contentInsetLeading
                + DesignTokens.Toolbar.contentInsetTrailing
            return NSSize(
                width: clamp(width, min: DesignTokens.Toolbar.minWidth, max: DesignTokens.Toolbar.maxWidth),
                height: DesignTokens.Toolbar.height
            )
        }
    }

    private func origin(for point: CGPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let x = clamp(
            point.x - size.width / 2,
            min: visibleFrame.minX + DesignTokens.Spacing.sm,
            max: visibleFrame.maxX - size.width - DesignTokens.Spacing.sm
        )
        var y = point.y + 12
        if y + size.height > visibleFrame.maxY {
            y = point.y - size.height - 12
        }
        if y < visibleFrame.minY + DesignTokens.Spacing.sm {
            y = visibleFrame.minY + DesignTokens.Spacing.sm
        }
        return NSPoint(x: x, y: y)
    }

    private func anchoredOrigin(from currentFrame: NSRect, targetSize: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(currentFrame) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = clamp(
            currentFrame.midX - targetSize.width / 2,
            min: visibleFrame.minX + DesignTokens.Spacing.sm,
            max: visibleFrame.maxX - targetSize.width - DesignTokens.Spacing.sm
        )
        let y = clamp(
            currentFrame.minY,
            min: visibleFrame.minY + DesignTokens.Spacing.sm,
            max: visibleFrame.maxY - targetSize.height - DesignTokens.Spacing.sm
        )
        return NSPoint(x: x, y: y)
    }

    private func cancelPendingReveal() {
        pendingRevealWorkItem?.cancel()
        pendingRevealWorkItem = nil
    }

    @objc private func handleSkillButton(_ sender: NSButton) {
        hideScreenshotDrawers()
        guard let skillID = sender.identifier?.rawValue else { return }
        delegate?.floatingToolbar(self, didTapSkill: skillID)
    }

    @objc private func handleMore() {
        hideScreenshotDrawers()
        delegate?.floatingToolbar(self, didTapMoreWith: secondarySkillIDs)
    }

    @objc private func handleScreenshotLongCapture() {
        hideScreenshotDrawers()
        delegate?.floatingToolbarDidTapScreenshotLongCapture(self)
    }

    @objc private func handleScreenshotScrollFinish() {
        hideScreenshotDrawers()
        delegate?.floatingToolbarDidTapScreenshotFinishScrolling(self)
    }

    @objc private func handleScreenshotScrollCancel() {
        hideScreenshotDrawers()
        delegate?.floatingToolbarDidTapScreenshotCancelScrolling(self)
    }

    @objc private func handleScreenshotBrushTool() {
        hideScreenshotDrawers()
        delegate?.floatingToolbar(self, didTapScreenshotTool: .brush)
    }

    @objc private func handleScreenshotArrowTool() {
        hideScreenshotDrawers()
        delegate?.floatingToolbar(self, didTapScreenshotTool: .arrow)
    }

    @objc private func handleScreenshotRectangleTool() {
        hideScreenshotDrawers()
        delegate?.floatingToolbar(self, didTapScreenshotTool: .rectangle)
    }

    @objc private func handleScreenshotTextTool() {
        hideScreenshotDrawers()
        delegate?.floatingToolbar(self, didTapScreenshotTool: .text)
    }

    @objc private func handleScreenshotStrokeDrawer() {
        toggleStrokeDrawer()
    }

    @objc private func handleScreenshotColorDrawer() {
        toggleColorDrawer()
    }

    @objc private func handleScreenshotSmallSize() {
        hideScreenshotDrawers()
        delegate?.floatingToolbar(self, didTapScreenshotStrokeSize: .small)
    }

    @objc private func handleScreenshotMediumSize() {
        hideScreenshotDrawers()
        delegate?.floatingToolbar(self, didTapScreenshotStrokeSize: .medium)
    }

    @objc private func handleScreenshotLargeSize() {
        hideScreenshotDrawers()
        delegate?.floatingToolbar(self, didTapScreenshotStrokeSize: .large)
    }

    @objc private func handleScreenshotRedColor() {
        hideScreenshotDrawers()
        delegate?.floatingToolbar(self, didTapScreenshotColor: .red)
    }

    @objc private func handleScreenshotYellowColor() {
        hideScreenshotDrawers()
        delegate?.floatingToolbar(self, didTapScreenshotColor: .yellow)
    }

    @objc private func handleScreenshotGreenColor() {
        hideScreenshotDrawers()
        delegate?.floatingToolbar(self, didTapScreenshotColor: .green)
    }

    @objc private func handleScreenshotBlueColor() {
        hideScreenshotDrawers()
        delegate?.floatingToolbar(self, didTapScreenshotColor: .blue)
    }

    @objc private func handleScreenshotCancelSession() {
        hideScreenshotDrawers()
        delegate?.floatingToolbarDidTapScreenshotCancelSession(self)
    }

    @objc private func handleScreenshotConfirm() {
        hideScreenshotDrawers()
        delegate?.floatingToolbarDidTapScreenshotConfirm(self)
    }

    private var screenshotButtons: [HoverToolbarButton] {
        [
            screenshotLongCaptureButton,
            screenshotScrollFinishButton,
            screenshotScrollCancelButton,
            screenshotBrushButton,
            screenshotRectangleButton,
            screenshotTextButton,
            screenshotArrowButton,
            screenshotStrokeDrawerButton,
            screenshotColorDrawerButton,
            screenshotCancelSessionButton,
            screenshotConfirmButton
        ]
    }

    private func refreshScreenshotControls() {
        applyScreenshotVisibility()
        screenshotLongCaptureButton.isActiveState = false
        screenshotScrollFinishButton.isActiveState = false
        screenshotScrollCancelButton.isActiveState = false
        screenshotBrushButton.isActiveState = isScreenshotContext && screenshotToolbarMode == .editing && selectedScreenshotTool == .brush
        screenshotRectangleButton.isActiveState = isScreenshotContext && screenshotToolbarMode == .editing && selectedScreenshotTool == .rectangle
        screenshotTextButton.isActiveState = isScreenshotContext && screenshotToolbarMode == .editing && selectedScreenshotTool == .text
        screenshotArrowButton.isActiveState = isScreenshotContext && screenshotToolbarMode == .editing && selectedScreenshotTool == .arrow
        screenshotCancelSessionButton.isActiveState = false
        screenshotConfirmButton.isActiveState = false
        screenshotStrokeDrawerButton.isActiveState = isScreenshotContext
            && screenshotToolbarMode == .editing
            && strokeDrawerController.isVisible
        screenshotSmallSizeButton.isActiveState = isScreenshotContext && screenshotToolbarMode == .editing && selectedScreenshotStrokeSize == .small
        screenshotMediumSizeButton.isActiveState = isScreenshotContext && screenshotToolbarMode == .editing && selectedScreenshotStrokeSize == .medium
        screenshotLargeSizeButton.isActiveState = isScreenshotContext && screenshotToolbarMode == .editing && selectedScreenshotStrokeSize == .large
        screenshotColorDrawerButton.isActiveState = isScreenshotContext
            && screenshotToolbarMode == .editing
            && colorDrawerController.isVisible
        screenshotRedColorButton.isActiveState = isScreenshotContext && screenshotToolbarMode == .editing && selectedScreenshotColor == .red
        screenshotYellowColorButton.isActiveState = isScreenshotContext && screenshotToolbarMode == .editing && selectedScreenshotColor == .yellow
        screenshotGreenColorButton.isActiveState = isScreenshotContext && screenshotToolbarMode == .editing && selectedScreenshotColor == .green
        screenshotBlueColorButton.isActiveState = isScreenshotContext && screenshotToolbarMode == .editing && selectedScreenshotColor == .blue
        screenshotStrokeDrawerButton.image = strokeSizeImage(for: selectedScreenshotStrokeSize)
        screenshotStrokeDrawerButton.imageScaling = .scaleNone
        screenshotStrokeDrawerButton.contentTintColor = DesignTokens.Color.iconPrimary
        screenshotColorDrawerButton.image = colorDotImage(color: selectedScreenshotColor.nsColor)
        screenshotColorDrawerButton.imageScaling = .scaleNone
        screenshotColorDrawerButton.contentTintColor = nil
        screenshotCancelSessionButton.contentTintColor = DesignTokens.Toolbar.ScreenshotControl.cancelTint
        screenshotConfirmButton.contentTintColor = DesignTokens.Toolbar.ScreenshotControl.confirmTint
    }

    private func applyScreenshotVisibility() {
        guard isScreenshotContext else {
            hideScreenshotDrawers()
            screenshotButtons.forEach { $0.isHidden = true }
            return
        }

        screenshotLongCaptureButton.isHidden = screenshotToolbarMode != .editing
        screenshotScrollFinishButton.isHidden = screenshotToolbarMode != .scrollCapturing
        screenshotScrollCancelButton.isHidden = screenshotToolbarMode != .scrollCapturing

        let showEditingTools = screenshotToolbarMode == .editing
        screenshotBrushButton.isHidden = !showEditingTools
        screenshotRectangleButton.isHidden = !showEditingTools
        screenshotTextButton.isHidden = !showEditingTools
        screenshotArrowButton.isHidden = !showEditingTools
        screenshotStrokeDrawerButton.isHidden = !showEditingTools
        screenshotColorDrawerButton.isHidden = !showEditingTools
        screenshotCancelSessionButton.isHidden = !showEditingTools
        screenshotConfirmButton.isHidden = !showEditingTools
        if !showEditingTools {
            hideScreenshotDrawers()
        }
    }

    private func toggleStrokeDrawer() {
        guard isScreenshotContext, screenshotToolbarMode == .editing else { return }
        colorDrawerController.hide()
        _ = strokeDrawerController.toggle(anchoredTo: screenshotStrokeDrawerButton)
        refreshScreenshotControls()
    }

    private func toggleColorDrawer() {
        guard isScreenshotContext, screenshotToolbarMode == .editing else { return }
        strokeDrawerController.hide()
        _ = colorDrawerController.toggle(anchoredTo: screenshotColorDrawerButton)
        refreshScreenshotControls()
    }

    private func hideScreenshotDrawers() {
        strokeDrawerController.hide()
        colorDrawerController.hide()
    }

    private func strokeSizeImage(for size: ScreenshotStrokeSize) -> NSImage? {
        let diameter: CGFloat
        switch size {
        case .small:
            diameter = 6
        case .medium:
            diameter = 10
        case .large:
            diameter = 14
        }
        return dotImage(
            color: DesignTokens.Color.iconPrimary,
            diameter: diameter,
            canvas: Self.strokeDotCanvas
        )
    }

    private func dotImage(color: NSColor, diameter: CGFloat, canvas: CGFloat = 18) -> NSImage? {
        let size = NSSize(width: canvas, height: canvas)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        color.setFill()
        let rect = NSRect(
            x: (canvas - diameter) / 2,
            y: (canvas - diameter) / 2,
            width: diameter,
            height: diameter
        )
        NSBezierPath(ovalIn: rect).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func colorDotImage(color: NSColor) -> NSImage? {
        dotImage(color: color, diameter: 14, canvas: Self.colorDotCanvas)
    }
}

private final class HoverToolbarButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    var isActiveState = false {
        didSet { updateHoverVisual(animated: true) }
    }
    private var hovering = false {
        didSet { updateHoverVisual(animated: true) }
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(
            width: base.width,
            height: max(base.height, DesignTokens.Toolbar.controlHeight)
        )
    }

    func preferredPillWidth() -> CGFloat {
        let titleText = title
        let fontToUse = font ?? DesignTokens.Toolbar.font
        let titleWidth = titleText.isEmpty
            ? 0
            : ceil((titleText as NSString).size(withAttributes: [.font: fontToUse]).width)

        let imageWidth = image.map { ceil($0.size.width) } ?? 0
        let gap: CGFloat = (imageWidth > 0 && titleWidth > 0) ? 6 : 0
        let horizontalPadding = DesignTokens.Toolbar.hoverHorizontalPadding * 2
        let total = titleWidth + imageWidth + gap + horizontalPadding
        return max(total, DesignTokens.Toolbar.controlHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupStyle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupStyle()
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                hovering = false
            }
            updateHoverVisual(animated: false)
        }
    }

    private func setupStyle() {
        cell = PaddedButtonCell(horizontalPadding: DesignTokens.Toolbar.hoverHorizontalPadding)
        wantsLayer = true
        isBordered = false
        layer?.cornerRadius = DesignTokens.Radius.sm
        layer?.masksToBounds = true
        updateHoverVisual(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard isEnabled else { return }
        hovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
        NSCursor.arrow.set()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateHoverVisual(animated: Bool) {
        let apply = {
            self.alphaValue = self.isEnabled ? 1 : 0.55
            self.layer?.borderWidth = 0
            self.layer?.borderColor = NSColor.clear.cgColor
            if self.isEnabled && (self.hovering || self.isActiveState) {
                self.layer?.backgroundColor = DesignTokens.Color.hoverFill.cgColor
            } else {
                self.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
        guard animated else {
            apply()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.Motion.fast
            self.animator().alphaValue = self.isEnabled ? 1 : 0.55
            apply()
        }
    }
}

private final class ToolbarDrawerController {
    private let panel: NSPanel
    private let hostView = NSView(frame: .zero)
    private let rootView = PanelSurfaceView(style: .panel)
    private let stackView = NSStackView()
    private let contentInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 44, height: 44),
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
        panel.ignoresMouseEvents = false
        panel.contentView = hostView

        rootView.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(rootView)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = DesignTokens.Toolbar.drawerStackSpacing
        rootView.addSubview(stackView)

        NSLayoutConstraint.activate([
            rootView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            rootView.topAnchor.constraint(equalTo: hostView.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: contentInset.left),
            stackView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -contentInset.right),
            stackView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: contentInset.top),
            stackView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -contentInset.bottom),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    func setWindowLevel(_ level: NSWindow.Level) {
        panel.level = level
    }

    func contains(screenPoint: CGPoint) -> Bool {
        panel.isVisible && panel.frame.contains(screenPoint)
    }

    func setButtons(_ buttons: [HoverToolbarButton]) {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        buttons.forEach { button in
            button.isHidden = false
            stackView.addArrangedSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: DesignTokens.Toolbar.controlHeight).isActive = true
            button.heightAnchor.constraint(equalToConstant: DesignTokens.Toolbar.controlHeight).isActive = true
        }
        hostView.layoutSubtreeIfNeeded()
    }

    @discardableResult
    func toggle(anchoredTo anchorView: NSView) -> Bool {
        if panel.isVisible {
            hide()
            return false
        }
        show(anchoredTo: anchorView)
        return true
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func show(anchoredTo anchorView: NSView) {
        guard let window = anchorView.window else { return }
        hostView.layoutSubtreeIfNeeded()
        stackView.layoutSubtreeIfNeeded()

        let stackSize = stackView.fittingSize
        let contentSize = NSSize(
            width: max(DesignTokens.Toolbar.controlHeight + contentInset.left + contentInset.right, stackSize.width + contentInset.left + contentInset.right),
            height: stackSize.height + contentInset.top + contentInset.bottom
        )
        panel.setContentSize(contentSize)

        let anchorRectInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorRectOnScreen = window.convertToScreen(anchorRectInWindow)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorRectOnScreen) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? anchorRectOnScreen.insetBy(dx: -160, dy: -160)

        var origin = CGPoint(
            x: anchorRectOnScreen.maxX - contentSize.width,
            y: anchorRectOnScreen.maxY + 8
        )
        origin.x = clamp(
            origin.x,
            min: visibleFrame.minX + DesignTokens.Spacing.sm,
            max: visibleFrame.maxX - contentSize.width - DesignTokens.Spacing.sm
        )
        origin.y = clamp(
            origin.y,
            min: visibleFrame.minY + DesignTokens.Spacing.sm,
            max: visibleFrame.maxY - contentSize.height - DesignTokens.Spacing.sm
        )

        panel.setFrame(NSRect(origin: origin, size: panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size), display: true)
        panel.orderFrontRegardless()
    }
}

private final class PaddedButtonCell: NSButtonCell {
    private let horizontalPadding: CGFloat

    init(horizontalPadding: CGFloat) {
        self.horizontalPadding = horizontalPadding
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        self.horizontalPadding = DesignTokens.Toolbar.hoverHorizontalPadding
        super.init(coder: coder)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect).insetBy(dx: horizontalPadding, dy: 0)
    }
}

private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    Swift.max(minValue, Swift.min(maxValue, value))
}
