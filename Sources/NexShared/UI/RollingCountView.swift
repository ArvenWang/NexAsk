import AppKit
import QuartzCore

final class RollingCountView: NSView {
    private let minimumAnimationInterval = DesignTokens.CountView.minimumAnimationInterval
    private let countStack = NSStackView()
    private let prefixLabel = NSTextField(labelWithString: L10n.text(zhHans: "字数", en: "Words"))
    private let digitsStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")

    private var digitViews: [RollingDigitColumnView] = []
    private var currentCount = 0
    private var statusText: String?
    private var emphasized = false
    private var lastAnimatedCountUpdateAt: TimeInterval = 0
    private var recognitionKind: RecognitionSlotKind = .textCount

    override var intrinsicContentSize: NSSize {
        (statusLabel.isHidden ? countStack : statusLabel).fittingSize
    }

    override var fittingSize: NSSize {
        intrinsicContentSize
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
        setCount(0, animated: false)
        setEmphasized(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
        setCount(0, animated: false)
        setEmphasized(false)
    }

    func setCount(_ count: Int, animated: Bool) {
        let previousCount = currentCount
        currentCount = max(0, count)
        guard statusText == nil else { return }

        let nextDigits = Array(String(currentCount))
        let now = CACurrentMediaTime()
        let passesIntervalGate = (now - lastAnimatedCountUpdateAt) >= minimumAnimationInterval
        let isDecreasing = currentCount < previousCount
        let canAnimate = animated && !isDecreasing && digitViews.count == nextDigits.count && passesIntervalGate

        if !canAnimate {
            rebuildDigitViews(with: nextDigits)
            invalidateIntrinsicContentSize()
            return
        }

        lastAnimatedCountUpdateAt = now
        for (index, digit) in nextDigits.enumerated() {
            digitViews[index].setDigit(Int(String(digit)) ?? 0, animated: true)
        }
    }

    func setRecognitionKind(_ kind: RecognitionSlotKind) {
        guard recognitionKind != kind else { return }
        recognitionKind = kind
        prefixLabel.stringValue = kind == .fileCount
            ? L10n.text(zhHans: "文件", en: "Files")
            : L10n.text(zhHans: "字数", en: "Words")
        updateContentVisibility()
        invalidateIntrinsicContentSize()
    }

    func setStatusText(_ text: String?) {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard normalized != statusText else { return }
        statusText = normalized
        if let statusText {
            statusLabel.stringValue = statusText
            statusLabel.isHidden = false
        } else {
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
            setCount(currentCount, animated: false)
        }
        updateContentVisibility()
        invalidateIntrinsicContentSize()
    }

    func setEmphasized(_ emphasized: Bool) {
        self.emphasized = emphasized
        let color = emphasized ? DesignTokens.Color.textPrimary : DesignTokens.Color.textSecondary
        prefixLabel.textColor = color
        statusLabel.textColor = color
        digitViews.forEach { $0.setTextColor(color) }
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        prefixLabel.font = DesignTokens.CountView.labelFont
        prefixLabel.setContentHuggingPriority(.required, for: .horizontal)
        prefixLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        digitsStack.orientation = .horizontal
        digitsStack.alignment = .centerY
        digitsStack.spacing = DesignTokens.CountView.digitSpacing
        digitsStack.edgeInsets = NSEdgeInsets()
        digitsStack.setContentHuggingPriority(.required, for: .horizontal)
        digitsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        countStack.orientation = .horizontal
        countStack.alignment = .centerY
        countStack.spacing = DesignTokens.CountView.contentSpacing
        countStack.edgeInsets = NSEdgeInsets()
        countStack.translatesAutoresizingMaskIntoConstraints = false
        countStack.setContentHuggingPriority(.required, for: .horizontal)
        countStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        countStack.addArrangedSubview(prefixLabel)
        countStack.addArrangedSubview(digitsStack)

        statusLabel.font = DesignTokens.CountView.labelFont
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(countStack)
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            countStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            countStack.topAnchor.constraint(equalTo: topAnchor),
            countStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: topAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            trailingAnchor.constraint(greaterThanOrEqualTo: countStack.trailingAnchor),
            trailingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor)
        ])
    }

    private func updateContentVisibility() {
        let isShowingStatus = statusText != nil
        statusLabel.isHidden = !isShowingStatus
        countStack.isHidden = isShowingStatus
    }

    private func rebuildDigitViews(with digits: [Character]) {
        digitViews.forEach { view in
            digitsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        digitViews.removeAll()

        for digit in digits {
            let value = Int(String(digit)) ?? 0
            let view = RollingDigitColumnView(digit: value)
            view.setTextColor(emphasized ? DesignTokens.Color.textPrimary : DesignTokens.Color.textSecondary)
            digitsStack.addArrangedSubview(view)
            digitViews.append(view)
        }
    }
}

final class RollingDigitColumnView: NSView {
    private let animationDuration = DesignTokens.CountView.digitAnimationDuration
    private let animationLeadIn = DesignTokens.CountView.digitAnimationLeadIn
    private let timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
    private let baselineYOffset = DesignTokens.CountView.digitBaselineYOffset
    private let digitSize: NSSize
    private var textColor = DesignTokens.Color.textSecondary
    private var currentDigit: Int
    private var animatingToDigit: Int?
    private var pendingDigit: Int?
    private var scheduledDigit: Int?
    private var scheduledAnimationWorkItem: DispatchWorkItem?
    private var isAnimatingDigit = false

    private let currentLayer = CATextLayer()
    private let incomingLayer = CATextLayer()
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    override var intrinsicContentSize: NSSize { digitSize }

    private var digitFont: NSFont {
        DesignTokens.CountView.digitFont
    }

    init(digit: Int) {
        currentDigit = digit
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DesignTokens.CountView.digitFont
        ]
        let sample = "8" as NSString
        let width = ceil(sample.size(withAttributes: attributes).width)
        let height = ceil(sample.size(withAttributes: attributes).height) + DesignTokens.CountView.digitHeightPadding
        digitSize = NSSize(width: width, height: height)
        super.init(frame: .zero)
        configureView()
        applyDigit(currentDigit, to: currentLayer)
    }

    required init?(coder: NSCoder) {
        currentDigit = 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DesignTokens.CountView.digitFont
        ]
        let sample = "8" as NSString
        let width = ceil(sample.size(withAttributes: attributes).width)
        let height = ceil(sample.size(withAttributes: attributes).height) + DesignTokens.CountView.digitHeightPadding
        digitSize = NSSize(width: width, height: height)
        super.init(coder: coder)
        configureView()
        applyDigit(currentDigit, to: currentLayer)
    }

    override func layout() {
        super.layout()
        if !isAnimatingDigit {
            currentLayer.frame = digitFrame(offsetY: baselineYOffset)
            incomingLayer.frame = digitFrame(offsetY: bounds.height + baselineYOffset)
            currentLayer.opacity = 1
            incomingLayer.opacity = 1
        }
    }

    func setDigit(_ digit: Int, animated: Bool) {
        if let scheduledDigit, digit == currentDigit {
            cancelScheduledAnimation()
            self.scheduledDigit = nil
            if scheduledDigit == currentDigit {
                return
            }
        }
        if let scheduledDigit, digit == scheduledDigit {
            return
        }
        if isAnimatingDigit, digit == currentDigit {
            cancelInFlightAnimation()
            pendingDigit = nil
            return
        }
        if isAnimatingDigit, digit == animatingToDigit {
            return
        }
        guard digit != currentDigit else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            cancelScheduledAnimation()
            scheduledDigit = nil
            currentDigit = digit
            applyDigit(currentDigit, to: currentLayer)
            return
        }

        if isAnimatingDigit {
            pendingDigit = digit
            return
        }

        scheduleAnimation(to: digit)
    }

    func setTextColor(_ color: NSColor) {
        textColor = color
        applyDigit(currentDigit, to: currentLayer)
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.isOpaque = false
        layer?.isGeometryFlipped = true

        widthConstraint = widthAnchor.constraint(equalToConstant: digitSize.width)
        heightConstraint = heightAnchor.constraint(equalToConstant: digitSize.height)
        widthConstraint?.isActive = true
        heightConstraint?.isActive = true

        configure(textLayer: currentLayer)
        configure(textLayer: incomingLayer)

        layer?.addSublayer(currentLayer)
        layer?.addSublayer(incomingLayer)
    }

    private func configure(textLayer: CATextLayer) {
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .none
        textLayer.isWrapped = false
        textLayer.frame = CGRect(origin: .zero, size: digitSize)
    }

    private func applyDigit(_ digit: Int, to layer: CATextLayer) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(
            string: "\(digit)",
            attributes: [
                .font: digitFont,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]
        )
        layer.string = string
    }

    private func animate(to nextDigit: Int) {
        cancelScheduledAnimation()
        isAnimatingDigit = true
        animatingToDigit = nextDigit
        layoutSubtreeIfNeeded()
        let increasing = nextDigit >= currentDigit
        let offset = bounds.height
        let startOffset: CGFloat = increasing ? offset : -offset
        let endOffset: CGFloat = increasing ? -offset : offset

        applyDigit(nextDigit, to: incomingLayer)
        currentLayer.removeAllAnimations()
        incomingLayer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentLayer.frame = digitFrame(offsetY: baselineYOffset)
        incomingLayer.frame = digitFrame(offsetY: baselineYOffset + startOffset)
        currentLayer.opacity = 1
        incomingLayer.opacity = 1
        CATransaction.commit()

        let outgoingPosition = CABasicAnimation(keyPath: "position.y")
        outgoingPosition.fromValue = currentLayer.position.y
        outgoingPosition.toValue = currentLayer.position.y + endOffset
        outgoingPosition.duration = animationDuration
        outgoingPosition.timingFunction = timingFunction

        let incomingPosition = CABasicAnimation(keyPath: "position.y")
        incomingPosition.fromValue = incomingLayer.position.y
        incomingPosition.toValue = digitFrame(offsetY: baselineYOffset).midY
        incomingPosition.duration = animationDuration
        incomingPosition.timingFunction = timingFunction

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            self.currentDigit = nextDigit
            self.animatingToDigit = nil
            self.applyDigit(self.currentDigit, to: self.currentLayer)
            self.currentLayer.frame = self.digitFrame(offsetY: self.baselineYOffset)
            self.currentLayer.opacity = 1
            self.incomingLayer.frame = self.digitFrame(offsetY: self.bounds.height + self.baselineYOffset)
            self.incomingLayer.opacity = 1
            self.isAnimatingDigit = false
            self.needsLayout = true

            if let pending = self.pendingDigit, pending != self.currentDigit {
                self.pendingDigit = nil
                self.animate(to: pending)
            } else {
                self.pendingDigit = nil
            }
        }
        CATransaction.setAnimationDuration(animationDuration)
        CATransaction.setDisableActions(true)
        currentLayer.frame = digitFrame(offsetY: baselineYOffset + endOffset)
        incomingLayer.frame = digitFrame(offsetY: baselineYOffset)
        currentLayer.add(outgoingPosition, forKey: "outgoing-position")
        incomingLayer.add(incomingPosition, forKey: "incoming-position")
        CATransaction.commit()
    }

    private func digitFrame(offsetY: CGFloat) -> CGRect {
        CGRect(x: 0, y: offsetY, width: bounds.width, height: bounds.height)
    }

    private func scheduleAnimation(to digit: Int) {
        cancelScheduledAnimation()
        scheduledDigit = digit
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduledAnimationWorkItem = nil
            let target = self.scheduledDigit
            self.scheduledDigit = nil
            guard let target, target != self.currentDigit else { return }
            self.animate(to: target)
        }
        scheduledAnimationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + animationLeadIn, execute: workItem)
    }

    private func cancelScheduledAnimation() {
        scheduledAnimationWorkItem?.cancel()
        scheduledAnimationWorkItem = nil
    }

    private func cancelInFlightAnimation() {
        cancelScheduledAnimation()
        currentLayer.removeAllAnimations()
        incomingLayer.removeAllAnimations()
        animatingToDigit = nil
        isAnimatingDigit = false
        currentLayer.opacity = 1
        incomingLayer.opacity = 1
        currentLayer.frame = digitFrame(offsetY: baselineYOffset)
        incomingLayer.frame = digitFrame(offsetY: bounds.height + baselineYOffset)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
