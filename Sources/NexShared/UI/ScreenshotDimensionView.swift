import AppKit

final class ScreenshotDimensionView: NSView {
    private let widthDigitsStack = NSStackView()
    private let heightDigitsStack = NSStackView()
    private let timesLabel = NSTextField(labelWithString: "×")
    private let pxLabel = NSTextField(labelWithString: "px")
    private let statusLabel = NSTextField(labelWithString: "")
    private let contentStack = NSStackView()

    private var widthDigitViews: [RollingDigitColumnView] = []
    private var heightDigitViews: [RollingDigitColumnView] = []
    private var currentDimensions = ScreenshotDimensionValue(width: 0, height: 0)
    private var statusText: String?
    private var emphasized = false

    override var intrinsicContentSize: NSSize {
        (statusLabel.isHidden ? contentStack : statusLabel).fittingSize
    }

    override var fittingSize: NSSize {
        intrinsicContentSize
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
        setDimensions(ScreenshotDimensionValue(width: 0, height: 0), animated: false)
        setEmphasized(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
        setDimensions(ScreenshotDimensionValue(width: 0, height: 0), animated: false)
        setEmphasized(false)
    }

    func setDimensions(_ dimensions: ScreenshotDimensionValue, animated: Bool) {
        let previousDimensions = currentDimensions
        currentDimensions = ScreenshotDimensionValue(
            width: max(0, dimensions.width),
            height: max(0, dimensions.height)
        )
        guard statusText == nil else { return }

        updateDigitViews(
            in: widthDigitsStack,
            digitViews: &widthDigitViews,
            previousValue: previousDimensions.width,
            nextValue: currentDimensions.width,
            animated: animated
        )
        updateDigitViews(
            in: heightDigitsStack,
            digitViews: &heightDigitViews,
            previousValue: previousDimensions.height,
            nextValue: currentDimensions.height,
            animated: animated
        )
        invalidateIntrinsicContentSize()
    }

    func setStatusText(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = trimmed.isEmpty ? nil : trimmed
        guard normalized != statusText else { return }
        statusText = normalized
        if let statusText {
            statusLabel.stringValue = statusText
            statusLabel.isHidden = false
        } else {
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
            setDimensions(currentDimensions, animated: false)
        }
        updateContentVisibility()
        invalidateIntrinsicContentSize()
    }

    func setEmphasized(_ emphasized: Bool) {
        self.emphasized = emphasized
        let color = emphasized ? DesignTokens.Color.textPrimary : DesignTokens.Color.textSecondary
        timesLabel.textColor = color
        pxLabel.textColor = color
        statusLabel.textColor = color
        widthDigitViews.forEach { $0.setTextColor(color) }
        heightDigitViews.forEach { $0.setTextColor(color) }
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        configureDigitsStack(widthDigitsStack)
        configureDigitsStack(heightDigitsStack)
        configureStaticLabel(timesLabel)
        configureStaticLabel(pxLabel)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = DesignTokens.Screenshot.Dimension.contentSpacing
        contentStack.edgeInsets = NSEdgeInsets()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentHuggingPriority(.required, for: .horizontal)
        contentStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentStack.addArrangedSubview(widthDigitsStack)
        contentStack.addArrangedSubview(timesLabel)
        contentStack.addArrangedSubview(heightDigitsStack)
        contentStack.addArrangedSubview(pxLabel)

        statusLabel.font = DesignTokens.Typography.screenshotDimension
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(contentStack)
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: topAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            trailingAnchor.constraint(greaterThanOrEqualTo: contentStack.trailingAnchor),
            trailingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor)
        ])
    }

    private func configureDigitsStack(_ stack: NSStackView) {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DesignTokens.Screenshot.Dimension.digitSpacing
        stack.edgeInsets = NSEdgeInsets()
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureStaticLabel(_ label: NSTextField) {
        label.font = DesignTokens.Typography.screenshotDimension
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func updateContentVisibility() {
        let isShowingStatus = statusText != nil
        statusLabel.isHidden = !isShowingStatus
        contentStack.isHidden = isShowingStatus
    }

    private func rebuildDigitViews(
        in stack: NSStackView,
        digitViews: inout [RollingDigitColumnView],
        digits: [Character]
    ) {
        digitViews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        digitViews.removeAll()

        for digit in digits {
            let value = Int(String(digit)) ?? 0
            let view = RollingDigitColumnView(digit: value)
            view.setTextColor(emphasized ? DesignTokens.Color.textPrimary : DesignTokens.Color.textSecondary)
            stack.addArrangedSubview(view)
            digitViews.append(view)
        }
    }

    private func updateDigitViews(
        in stack: NSStackView,
        digitViews: inout [RollingDigitColumnView],
        previousValue: Int,
        nextValue: Int,
        animated: Bool
    ) {
        let nextDigits = Array(String(max(0, nextValue)))
        let isDecreasing = nextValue < previousValue
        let canAnimate = animated
            && digitViews.count == nextDigits.count
            && String(max(0, previousValue)).count == nextDigits.count
            && !isDecreasing

        if !canAnimate {
            rebuildDigitViews(in: stack, digitViews: &digitViews, digits: nextDigits)
            return
        }

        for (index, digit) in nextDigits.enumerated() {
            digitViews[index].setDigit(Int(String(digit)) ?? 0, animated: true)
        }
    }
}
