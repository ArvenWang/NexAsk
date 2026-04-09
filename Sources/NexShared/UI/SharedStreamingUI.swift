import AppKit
import QuartzCore

package enum SharedStreamingTextAnimation {
    static let revealInterval: TimeInterval = 0.08
    static let highlightFadeInterval: TimeInterval = 0.035
    static let highlightAlphaStep: CGFloat = 0.12
    static let initialHighlightedAlpha: CGFloat = 0.76
}

package final class ShimmeringStatusLabel: NSView {
    private static let shimmerPhaseAnchor = CACurrentMediaTime()
    private static let shimmerDuration = DesignTokens.ResultPanel.ShimmeringStatus.duration
    private static let shimmerFromLocations = DesignTokens.ResultPanel.ShimmeringStatus.fromLocations
    private static let shimmerToLocations = DesignTokens.ResultPanel.ShimmeringStatus.toLocations

    private let textLayer = CATextLayer()
    private let highlightLayer = CAGradientLayer()
    private let highlightMask = CATextLayer()
    private let font = DesignTokens.Typography.resultPanelStatus
    private var text: String
    private let isShimmering: Bool

    package init(text: String, isShimmering: Bool, baseColor: NSColor) {
        self.text = text
        self.isShimmering = isShimmering
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        textLayer.string = text
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.foregroundColor = baseColor.cgColor
        textLayer.truncationMode = .end
        textLayer.alignmentMode = .left
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(textLayer)

        if isShimmering {
            highlightLayer.colors = [
                NSColor.white.withAlphaComponent(0.0).cgColor,
                NSColor.white.withAlphaComponent(1.0).cgColor,
                NSColor.white.withAlphaComponent(0.0).cgColor,
            ]
            highlightLayer.locations = DesignTokens.ResultPanel.ShimmeringStatus.highlightLocations
            highlightLayer.startPoint = CGPoint(x: 0, y: 0.5)
            highlightLayer.endPoint = CGPoint(x: 1, y: 0.5)
            highlightLayer.opacity = 1
            highlightLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

            highlightMask.string = text
            highlightMask.font = font
            highlightMask.fontSize = font.pointSize
            highlightMask.foregroundColor = NSColor.white.cgColor
            highlightMask.truncationMode = .end
            highlightMask.alignmentMode = .left
            highlightMask.contentsScale = NSScreen.main?.backingScaleFactor ?? 2

            highlightLayer.mask = highlightMask
            layer?.addSublayer(highlightLayer)
            startShimmerAnimation()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let lineHeight = ceil(font.ascender - font.descender) + 2
        let textFrame = CGRect(x: 0, y: max(0, (bounds.height - lineHeight) / 2), width: bounds.width, height: lineHeight)
        textLayer.frame = textFrame
        highlightLayer.frame = textFrame
        highlightMask.frame = CGRect(origin: .zero, size: textFrame.size)
        CATransaction.commit()
        if isShimmering, highlightLayer.animation(forKey: "text-shimmer") == nil {
            startShimmerAnimation()
        }
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isShimmering {
            startShimmerAnimation()
        }
    }

    package override var intrinsicContentSize: NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let width = (text as NSString).size(withAttributes: attrs).width
        return NSSize(width: ceil(width), height: ceil(font.ascender - font.descender) + 4)
    }

    package func updateText(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        textLayer.string = text
        highlightMask.string = text
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func startShimmerAnimation() {
        highlightLayer.removeAnimation(forKey: "text-shimmer")
        let phase = Self.currentShimmerPhase()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.locations = Self.interpolatedLocations(for: phase)
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = Self.shimmerFromLocations
        animation.toValue = Self.shimmerToLocations
        animation.duration = Self.shimmerDuration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.beginTime = 0
        animation.timeOffset = CFTimeInterval(phase) * Self.shimmerDuration
        animation.isRemovedOnCompletion = false
        highlightLayer.add(animation, forKey: "text-shimmer")
    }

    private static func currentShimmerPhase() -> CGFloat {
        CGFloat(fmod(CACurrentMediaTime() - shimmerPhaseAnchor, shimmerDuration) / shimmerDuration)
    }

    private static func interpolatedLocations(for phase: CGFloat) -> [NSNumber] {
        zip(shimmerFromLocations, shimmerToLocations).map { from, to in
            NSNumber(value: Double(from + ((to - from) * phase)))
        }
    }
}

package final class ResultLoadingLineEffectController {
    private let divider: NSView
    private weak var auraOverlayView: NSView?
    private let dividerFlowLayer = CAGradientLayer()
    private let dividerFlowAuraLayer = CAGradientLayer()
    private let dividerFlowMaskLayer = CAGradientLayer()
    private let dividerFlowContainerLayer = CALayer()
    private let panelAuraContainerLayer = CALayer()

    package init(divider: NSView, auraOverlayView: NSView) {
        self.divider = divider
        self.auraOverlayView = auraOverlayView
    }

    package func configure() {
        guard let dividerLayer = divider.layer,
              let auraOverlayLayer = auraOverlayView?.layer else { return }

        let effect = DesignTokens.Effects.ResultLoadingLine.self
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        dividerLayer.backgroundColor = effect.trackColor.cgColor

        dividerFlowLayer.colors = [
            effect.accentColor.withAlphaComponent(0).cgColor,
            effect.accentColor.withAlphaComponent(0.38).cgColor,
            effect.coreColor.withAlphaComponent(0.98).cgColor,
            effect.accentColor.withAlphaComponent(0.38).cgColor,
            effect.accentColor.withAlphaComponent(0).cgColor,
        ]
        dividerFlowLayer.locations = effect.gradientLocations
        dividerFlowLayer.startPoint = CGPoint(x: 0, y: 0.5)
        dividerFlowLayer.endPoint = CGPoint(x: 1, y: 0.5)
        dividerFlowLayer.opacity = 0
        dividerFlowLayer.shadowColor = effect.accentColor.cgColor
        dividerFlowLayer.shadowOpacity = effect.shadowOpacity
        dividerFlowLayer.shadowRadius = effect.shadowRadius
        dividerFlowLayer.shadowOffset = .zero

        dividerFlowAuraLayer.type = .radial
        dividerFlowAuraLayer.colors = [
            effect.auraCoreColor.withAlphaComponent(0.95).cgColor,
            effect.auraMidColor.withAlphaComponent(0.48).cgColor,
            effect.accentColor.withAlphaComponent(0.16).cgColor,
            effect.accentColor.withAlphaComponent(0.04).cgColor,
            effect.accentColor.withAlphaComponent(0).cgColor,
        ]
        dividerFlowAuraLayer.locations = effect.auraGradientLocations
        dividerFlowAuraLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        dividerFlowAuraLayer.endPoint = CGPoint(x: 1, y: 1)
        dividerFlowAuraLayer.opacity = 0
        dividerFlowAuraLayer.shadowColor = effect.auraMidColor.cgColor
        dividerFlowAuraLayer.shadowOpacity = effect.auraShadowOpacity
        dividerFlowAuraLayer.shadowRadius = effect.auraShadowRadius
        dividerFlowAuraLayer.shadowOffset = .zero

        panelAuraContainerLayer.masksToBounds = false
        dividerFlowContainerLayer.masksToBounds = true
        dividerFlowMaskLayer.startPoint = CGPoint(x: 0, y: 0.5)
        dividerFlowMaskLayer.endPoint = CGPoint(x: 1, y: 0.5)
        dividerFlowMaskLayer.colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.38).cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0.38).cgColor,
            NSColor.black.withAlphaComponent(0).cgColor,
        ]

        if panelAuraContainerLayer.superlayer == nil {
            auraOverlayLayer.addSublayer(panelAuraContainerLayer)
        }
        if dividerFlowAuraLayer.superlayer == nil {
            panelAuraContainerLayer.addSublayer(dividerFlowAuraLayer)
        }
        if dividerFlowContainerLayer.superlayer == nil {
            dividerLayer.addSublayer(dividerFlowContainerLayer)
        }
        dividerFlowContainerLayer.mask = dividerFlowMaskLayer
        if dividerFlowLayer.superlayer == nil {
            dividerFlowContainerLayer.addSublayer(dividerFlowLayer)
        }
    }

    package func start() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dividerFlowAuraLayer.removeAllAnimations()
        dividerFlowLayer.removeAllAnimations()
        dividerFlowAuraLayer.opacity = 0
        dividerFlowLayer.opacity = 0
        CATransaction.commit()
    }

    package func stop(immediately: Bool = false) {
        dividerFlowAuraLayer.removeAllAnimations()
        dividerFlowLayer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dividerFlowAuraLayer.opacity = 0
        dividerFlowLayer.opacity = 0
        CATransaction.commit()
    }
}
