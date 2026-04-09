import AppKit
import QuartzCore

package final class PanelSurfaceView: NSView {
    private enum SurfaceEffectAnimationKey {
        static let glow = "toolbarSweepGlow"
        static let wake = "toolbarSweepWake"
        static let borderSweep = "toolbarSweepBorderSweep"
        static let ambientDrift = "ambientDrift"
        static let ambientScale = "ambientScale"
        static let ambientOpacity = "ambientOpacity"
    }

    package enum Style {
        case toolbar
        case panel
    }

    package enum AmbientEffectStyle {
        case none
        case resultPanel
        case conversationPanel
    }

    private struct AmbientBlobConfiguration {
        let size: CGSize
        let color: NSColor
        let relativePosition: CGPoint
        let drift: CGPoint
        let duration: TimeInterval
        let startScale: CGFloat
        let endScale: CGFloat
    }

    private struct AmbientEffectConfiguration {
        let centerGlowAlpha: CGFloat
        let midGlowAlpha: CGFloat
        let edgeGlowAlpha: CGFloat
        let shadowOpacity: Float
        let shadowRadius: CGFloat
        let gradientLocations: [NSNumber]
        let opacityValues: [CGFloat]
        let opacityKeyTimes: [NSNumber]
        let blobs: [AmbientBlobConfiguration]
    }

    private let style: Style
    private let blurView = NSVisualEffectView()
    private let ambientView = NSView()
    private let glowView = NSView()
    private let tintView = NSView()
    private let toolbarSweepLayer = CAGradientLayer()
    private let toolbarWakeLayer = CAGradientLayer()
    private let toolbarBorderSweepContainerLayer = CALayer()
    private let toolbarBorderSweepLayer = CAGradientLayer()
    private let toolbarBorderMaskLayer = CAShapeLayer()
    private let ambientPrimaryLayer = CAGradientLayer()
    private let ambientSecondaryLayer = CAGradientLayer()
    private let ambientTertiaryLayer = CAGradientLayer()
    package var ambientEffectStyle: AmbientEffectStyle = .none {
        didSet {
            guard ambientEffectStyle != oldValue else { return }
            configureAmbientEffectIfNeeded()
            layoutAmbientEffect()
        }
    }
    package var tintOpacityOverride: CGFloat? {
        didSet { refreshAppearance() }
    }
    var showsBorder = true {
        didSet { refreshAppearance() }
    }
    var showsTint = true {
        didSet { refreshAppearance() }
    }
    var showsBlur = true {
        didSet { refreshAppearance() }
    }

    package init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        configureSubviews()
        refreshAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    package override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    package override func layout() {
        super.layout()
        layoutAmbientEffect()
        layoutToolbarSweep()
    }

    package override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    // MARK: - Setup

    private func configureSubviews() {
        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.state = .active
        blurView.blendingMode = .behindWindow
        blurView.wantsLayer = true

        ambientView.translatesAutoresizingMaskIntoConstraints = false
        ambientView.wantsLayer = true
        ambientView.layer?.masksToBounds = false

        glowView.translatesAutoresizingMaskIntoConstraints = false
        glowView.wantsLayer = true
        glowView.layer?.masksToBounds = false

        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true

        addSubview(blurView)
        addSubview(ambientView)
        addSubview(tintView)
        addSubview(glowView)
        configureAmbientEffectIfNeeded()
        configureToolbarSweepIfNeeded()

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            ambientView.leadingAnchor.constraint(equalTo: leadingAnchor),
            ambientView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ambientView.topAnchor.constraint(equalTo: topAnchor),
            ambientView.bottomAnchor.constraint(equalTo: bottomAnchor),

            glowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glowView.topAnchor.constraint(equalTo: topAnchor),
            glowView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Toolbar Sweep

    func playToolbarSweepGlow(travelWidth: CGFloat? = nil) {
        guard style == .toolbar else { return }
        guard DesignTokens.Effects.ToolbarSweep.isEnabled else { return }
        guard let hostLayer = glowView.layer else { return }

        // All toolbar sweep tuning lives in DesignTokens.Effects.ToolbarSweep.
        let effect = DesignTokens.Effects.ToolbarSweep.self

        layoutSubtreeIfNeeded()
        layoutToolbarSweep()

        let diameter = effect.radius * 2
        let width = max(travelWidth ?? bounds.width, bounds.width)
        let startX = -effect.radius - effect.travelOvershoot
        let endX = width + effect.radius + effect.travelOvershoot
        let centerY = sweepCenterY()
        let wakeRadius = effect.radius * effect.secondaryScale
        let wakeDiameter = wakeRadius * 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.masksToBounds = false
        toolbarSweepLayer.removeAllAnimations()
        toolbarWakeLayer.removeAllAnimations()
        toolbarBorderSweepLayer.removeAllAnimations()
        toolbarSweepLayer.position = CGPoint(x: endX, y: centerY)
        toolbarSweepLayer.opacity = 0
        toolbarSweepLayer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        toolbarWakeLayer.position = CGPoint(
            x: endX - effect.radius * 0.6,
            y: centerY + effect.secondaryYOffset
        )
        toolbarWakeLayer.opacity = 0
        toolbarWakeLayer.bounds = CGRect(x: 0, y: 0, width: wakeDiameter, height: wakeDiameter)
        toolbarBorderSweepLayer.opacity = 0
        toolbarBorderSweepLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: effect.borderGlowWidth,
            height: bounds.height + effect.borderShadowRadius * 2
        )
        toolbarBorderSweepLayer.position = CGPoint(
            x: startX,
            y: bounds.midY
        )
        CATransaction.commit()

        let baseBeginTime = CACurrentMediaTime()
        let timing = CAMediaTimingFunction(
            controlPoints: effect.timingControlPoints.0,
            effect.timingControlPoints.1,
            effect.timingControlPoints.2,
            effect.timingControlPoints.3
        )

        let primaryGroup = makeSweepAnimationGroup(
            path: sweepPath(
                fromX: startX,
                toX: endX,
                centerY: centerY,
                wobbleAmplitude: effect.wobbleAmplitude
            ),
            duration: effect.animationDuration,
            beginTime: baseBeginTime,
            timingFunction: timing,
            opacityValues: effect.primaryOpacityValues,
            opacityKeyTimes: effect.primaryOpacityKeyTimes,
            transformValues: [
                CATransform3DMakeScale(1.16, 0.84, 1),
                CATransform3DMakeScale(0.98, 1.02, 1),
                CATransform3DMakeScale(1.08, 0.92, 1),
                CATransform3DMakeScale(0.94, 1.04, 1)
            ],
            transformKeyTimes: effect.primaryTransformKeyTimes
        )

        let wakeGroup = makeSweepAnimationGroup(
            path: sweepPath(
                fromX: startX - effect.radius * 0.42,
                toX: endX - effect.radius * 0.3,
                centerY: centerY + effect.secondaryYOffset,
                wobbleAmplitude: effect.wobbleAmplitude * 0.7
            ),
            duration: effect.animationDuration * 0.94,
            beginTime: baseBeginTime + effect.secondaryDelay,
            timingFunction: timing,
            opacityValues: effect.wakeOpacityValues,
            opacityKeyTimes: effect.wakeOpacityKeyTimes,
            transformValues: [
                CATransform3DMakeScale(1.22, 0.82, 1),
                CATransform3DMakeScale(1.0, 1.0, 1),
                CATransform3DMakeScale(1.1, 0.9, 1),
                CATransform3DMakeScale(0.96, 1.02, 1)
            ],
            transformKeyTimes: effect.wakeTransformKeyTimes
        )

        let borderMove = CABasicAnimation(keyPath: "position.x")
        borderMove.fromValue = startX
        borderMove.toValue = endX

        let borderOpacity = CAKeyframeAnimation(keyPath: "opacity")
        borderOpacity.values = effect.borderOpacityValues
        borderOpacity.keyTimes = effect.borderOpacityKeyTimes

        let borderGroup = CAAnimationGroup()
        borderGroup.animations = [borderMove, borderOpacity]
        borderGroup.duration = effect.animationDuration
        borderGroup.beginTime = baseBeginTime
        borderGroup.timingFunction = timing
        borderGroup.isRemovedOnCompletion = true

        toolbarSweepLayer.add(primaryGroup, forKey: SurfaceEffectAnimationKey.glow)
        toolbarWakeLayer.add(wakeGroup, forKey: SurfaceEffectAnimationKey.wake)
        toolbarBorderSweepLayer.add(borderGroup, forKey: SurfaceEffectAnimationKey.borderSweep)
    }

    // MARK: - Appearance

    package func refreshAppearance() {
        let appearance = appearanceValues(for: style)

        let resolvedRadius = appearance.radius
        let resolvedTintOpacity = tintOpacityOverride ?? appearance.tintOpacityMultiplier

        layer?.cornerRadius = resolvedRadius
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = DesignTokens.Color.border.cgColor
        layer?.borderWidth = showsBorder ? 1 : 0

        blurView.isHidden = !showsBlur
        tintView.isHidden = !showsTint
        ambientView.isHidden = ambientEffectStyle == .none
        blurView.material = appearance.material
        blurView.layer?.cornerRadius = resolvedRadius
        ambientView.layer?.cornerRadius = resolvedRadius
        tintView.layer?.cornerRadius = resolvedRadius
        tintView.layer?.backgroundColor = appearance.backgroundColor
            .withAlphaComponent(appearance.backgroundColor.alphaComponent * resolvedTintOpacity)
            .cgColor
        glowView.layer?.cornerRadius = resolvedRadius
        toolbarBorderMaskLayer.path = insetRoundedRectPath(
            inset: DesignTokens.Effects.ToolbarSweep.borderLineWidth / 2,
            cornerRadius: max(0, resolvedRadius - DesignTokens.Effects.ToolbarSweep.borderLineWidth / 2)
        )
    }

    // MARK: - Ambient Background

    private func configureAmbientEffectIfNeeded() {
        guard let hostLayer = ambientView.layer else { return }

        hostLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        ambientPrimaryLayer.removeAllAnimations()
        ambientSecondaryLayer.removeAllAnimations()
        ambientTertiaryLayer.removeAllAnimations()

        guard let configuration = ambientConfiguration(for: ambientEffectStyle) else {
            ambientView.isHidden = true
            return
        }

        ambientView.isHidden = false
        hostLayer.compositingFilter = "screenBlendMode"
        let layers = [ambientPrimaryLayer, ambientSecondaryLayer, ambientTertiaryLayer]

        for (layer, blob) in zip(layers, configuration.blobs) {
            configureAmbientBlobLayer(layer, configuration: configuration, color: blob.color)
            hostLayer.addSublayer(layer)
        }
    }

    // Toolbar sweep structure stays here, but every visual knob should resolve back to DesignTokens.Effects.ToolbarSweep.
    private func configureToolbarSweepIfNeeded() {
        guard style == .toolbar else { return }
        guard let hostLayer = glowView.layer else { return }
        guard DesignTokens.Effects.ToolbarSweep.isEnabled else {
            glowView.isHidden = true
            return
        }

        let effect = DesignTokens.Effects.ToolbarSweep.self
        hostLayer.compositingFilter = "screenBlendMode"
        configureSweepLayer(
            toolbarSweepLayer,
            effect: effect,
            alphaScale: effect.primaryAlphaScale,
            shadowRadius: effect.primaryShadowRadius,
            shadowOpacity: effect.primaryShadowOpacity
        )
        configureSweepLayer(
            toolbarWakeLayer,
            effect: effect,
            alphaScale: effect.secondaryAlphaScale,
            shadowRadius: effect.secondaryShadowRadius,
            shadowOpacity: effect.secondaryShadowOpacity
        )
        configureToolbarBorderSweepLayer(effect: effect)
        hostLayer.addSublayer(toolbarSweepLayer)
        hostLayer.addSublayer(toolbarWakeLayer)
        hostLayer.addSublayer(toolbarBorderSweepContainerLayer)
    }

    private func layoutToolbarSweep() {
        guard style == .toolbar else { return }
        let effect = DesignTokens.Effects.ToolbarSweep.self

        let diameter = effect.radius * 2
        let wakeDiameter = diameter * effect.secondaryScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        toolbarSweepLayer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        toolbarWakeLayer.bounds = CGRect(x: 0, y: 0, width: wakeDiameter, height: wakeDiameter)
        if toolbarSweepLayer.animation(forKey: SurfaceEffectAnimationKey.glow) == nil {
            toolbarSweepLayer.position = CGPoint(
                x: -effect.radius - effect.travelOvershoot,
                y: sweepCenterY()
            )
        }
        if toolbarWakeLayer.animation(forKey: SurfaceEffectAnimationKey.wake) == nil {
            toolbarWakeLayer.position = CGPoint(
                x: -effect.radius - effect.travelOvershoot,
                y: sweepCenterY() + effect.secondaryYOffset
            )
        }
        toolbarBorderSweepContainerLayer.frame = bounds
        toolbarBorderMaskLayer.frame = bounds
        toolbarBorderMaskLayer.path = insetRoundedRectPath(
            inset: effect.borderLineWidth / 2,
            cornerRadius: max(0, layer?.cornerRadius ?? 0 - effect.borderLineWidth / 2)
        )
        CATransaction.commit()
    }

    private func layoutAmbientEffect() {
        guard let configuration = ambientConfiguration(for: ambientEffectStyle) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layers = [ambientPrimaryLayer, ambientSecondaryLayer, ambientTertiaryLayer]

        for (layer, blob) in zip(layers, configuration.blobs) {
            layer.bounds = CGRect(origin: .zero, size: blob.size)
            if layer.animation(forKey: SurfaceEffectAnimationKey.ambientDrift) == nil {
                layer.position = CGPoint(
                    x: bounds.width * blob.relativePosition.x,
                    y: bounds.height * blob.relativePosition.y
                )
                addAmbientAnimations(
                    to: layer,
                    configuration: configuration,
                    startPosition: layer.position,
                    endPosition: CGPoint(
                        x: layer.position.x + blob.drift.x,
                        y: layer.position.y + blob.drift.y
                    ),
                    duration: blob.duration,
                    startScale: blob.startScale,
                    endScale: blob.endScale
                )
            }
        }
        CATransaction.commit()
    }

    private func ambientConfiguration(for style: AmbientEffectStyle) -> AmbientEffectConfiguration? {
        switch style {
        case .none:
            return nil
        case .resultPanel:
            guard DesignTokens.Effects.ResultAmbient.isEnabled else { return nil }
            let effect = DesignTokens.Effects.ResultAmbient.self
            return AmbientEffectConfiguration(
                centerGlowAlpha: effect.centerGlowAlpha,
                midGlowAlpha: effect.midGlowAlpha,
                edgeGlowAlpha: effect.edgeGlowAlpha,
                shadowOpacity: effect.shadowOpacity,
                shadowRadius: effect.shadowRadius,
                gradientLocations: effect.gradientLocations,
                opacityValues: effect.opacityValues,
                opacityKeyTimes: effect.opacityKeyTimes,
                blobs: [
                    AmbientBlobConfiguration(
                        size: effect.blobSize,
                        color: effect.primaryColor,
                        relativePosition: CGPoint(x: 0.28, y: 0.76),
                        drift: CGPoint(x: effect.driftDistance, y: -effect.verticalDrift),
                        duration: effect.primaryDuration,
                        startScale: 0.96,
                        endScale: 1.08
                    ),
                    AmbientBlobConfiguration(
                        size: effect.secondaryBlobSize,
                        color: effect.secondaryColor,
                        relativePosition: CGPoint(x: 0.76, y: 0.46),
                        drift: CGPoint(x: -effect.driftDistance * 0.84, y: effect.verticalDrift * 0.56),
                        duration: effect.secondaryDuration,
                        startScale: 1.02,
                        endScale: 0.92
                    ),
                    AmbientBlobConfiguration(
                        size: effect.tertiaryBlobSize,
                        color: effect.tertiaryColor,
                        relativePosition: CGPoint(x: 0.54, y: 0.18),
                        drift: CGPoint(x: effect.driftDistance * 0.54, y: effect.verticalDrift * 0.42),
                        duration: effect.tertiaryDuration,
                        startScale: 0.9,
                        endScale: 1.04
                    )
                ]
            )
        case .conversationPanel:
            guard DesignTokens.Effects.ConversationAmbient.isEnabled else { return nil }
            let effect = DesignTokens.Effects.ConversationAmbient.self
            return AmbientEffectConfiguration(
                centerGlowAlpha: effect.centerGlowAlpha,
                midGlowAlpha: effect.midGlowAlpha,
                edgeGlowAlpha: effect.edgeGlowAlpha,
                shadowOpacity: effect.shadowOpacity,
                shadowRadius: effect.shadowRadius,
                gradientLocations: effect.gradientLocations,
                opacityValues: effect.opacityValues,
                opacityKeyTimes: effect.opacityKeyTimes,
                blobs: [
                    AmbientBlobConfiguration(
                        size: effect.blobSize,
                        color: effect.primaryColor,
                        relativePosition: CGPoint(x: 0.22, y: 0.74),
                        drift: CGPoint(x: effect.driftDistance, y: -effect.verticalDrift),
                        duration: effect.primaryDuration,
                        startScale: 0.98,
                        endScale: 1.06
                    ),
                    AmbientBlobConfiguration(
                        size: effect.secondaryBlobSize,
                        color: effect.secondaryColor,
                        relativePosition: CGPoint(x: 0.82, y: 0.58),
                        drift: CGPoint(x: -effect.driftDistance * 0.72, y: effect.verticalDrift * 0.46),
                        duration: effect.secondaryDuration,
                        startScale: 1.0,
                        endScale: 0.94
                    ),
                    AmbientBlobConfiguration(
                        size: effect.tertiaryBlobSize,
                        color: effect.tertiaryColor,
                        relativePosition: CGPoint(x: 0.52, y: 0.12),
                        drift: CGPoint(x: effect.driftDistance * 0.48, y: effect.verticalDrift * 0.34),
                        duration: effect.tertiaryDuration,
                        startScale: 0.92,
                        endScale: 1.02
                    )
                ]
            )
        }
    }

    private func configureSweepLayer(
        _ layer: CAGradientLayer,
        effect: DesignTokens.Effects.ToolbarSweep.Type,
        alphaScale: CGFloat,
        shadowRadius: CGFloat,
        shadowOpacity: Float
    ) {
        layer.type = .radial
        layer.colors = [
            effect.coreColor.withAlphaComponent(0.98 * alphaScale).cgColor,
            effect.accentColor.withAlphaComponent(1.0 * alphaScale).cgColor,
            effect.accentColor.withAlphaComponent(0.62 * alphaScale).cgColor,
            effect.accentColor.withAlphaComponent(0.22 * alphaScale).cgColor,
            effect.accentColor.withAlphaComponent(0).cgColor,
        ]
        layer.locations = effect.gradientLocations
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        layer.opacity = 0
        layer.shadowColor = effect.accentColor.withAlphaComponent(0.8 * alphaScale).cgColor
        layer.shadowRadius = shadowRadius
        layer.shadowOpacity = shadowOpacity
        layer.shadowOffset = .zero
        layer.shouldRasterize = true
        layer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    private func configureToolbarBorderSweepLayer(effect: DesignTokens.Effects.ToolbarSweep.Type) {
        // This layer is masked by the toolbar outline so only a narrow stroke segment appears to travel along the border.
        toolbarBorderSweepContainerLayer.masksToBounds = false
        toolbarBorderSweepContainerLayer.mask = toolbarBorderMaskLayer

        toolbarBorderMaskLayer.fillColor = NSColor.clear.cgColor
        toolbarBorderMaskLayer.strokeColor = NSColor.black.cgColor
        toolbarBorderMaskLayer.lineWidth = effect.borderLineWidth

        toolbarBorderSweepLayer.startPoint = CGPoint(x: 0, y: 0.5)
        toolbarBorderSweepLayer.endPoint = CGPoint(x: 1, y: 0.5)
        toolbarBorderSweepLayer.colors = [
            effect.accentColor.withAlphaComponent(0).cgColor,
            effect.accentColor.withAlphaComponent(effect.borderMidAlpha).cgColor,
            effect.coreColor.withAlphaComponent(effect.borderCoreAlpha).cgColor,
            effect.accentColor.withAlphaComponent(effect.borderMidAlpha).cgColor,
            effect.accentColor.withAlphaComponent(0).cgColor,
        ]
        toolbarBorderSweepLayer.locations = effect.gradientLocations
        toolbarBorderSweepLayer.opacity = 0
        toolbarBorderSweepLayer.shadowColor = effect.accentColor.withAlphaComponent(0.7).cgColor
        toolbarBorderSweepLayer.shadowRadius = effect.borderShadowRadius
        toolbarBorderSweepLayer.shadowOpacity = effect.borderShadowOpacity
        toolbarBorderSweepLayer.shadowOffset = .zero
        toolbarBorderSweepLayer.compositingFilter = "screenBlendMode"
        toolbarBorderSweepContainerLayer.addSublayer(toolbarBorderSweepLayer)
    }

    private func configureAmbientBlobLayer(
        _ layer: CAGradientLayer,
        configuration: AmbientEffectConfiguration,
        color: NSColor
    ) {
        layer.type = .radial
        layer.colors = [
            color.withAlphaComponent(configuration.centerGlowAlpha).cgColor,
            color.withAlphaComponent(configuration.midGlowAlpha).cgColor,
            color.withAlphaComponent(configuration.midGlowAlpha * 0.4).cgColor,
            color.withAlphaComponent(configuration.edgeGlowAlpha).cgColor,
        ]
        layer.locations = configuration.gradientLocations
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        layer.opacity = Float(configuration.opacityValues.first ?? 0.2)
        layer.shadowColor = color.withAlphaComponent(0.34).cgColor
        layer.shadowRadius = configuration.shadowRadius
        layer.shadowOpacity = configuration.shadowOpacity
        layer.shadowOffset = .zero
        layer.shouldRasterize = true
        layer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    private func addAmbientAnimations(
        to layer: CAGradientLayer,
        configuration: AmbientEffectConfiguration,
        startPosition: CGPoint,
        endPosition: CGPoint,
        duration: TimeInterval,
        startScale: CGFloat,
        endScale: CGFloat
    ) {
        let drift = CABasicAnimation(keyPath: "position")
        drift.fromValue = NSValue(point: startPosition)
        drift.toValue = NSValue(point: endPosition)
        drift.duration = duration
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = startScale
        scale.toValue = endScale
        scale.duration = duration * 0.82
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = configuration.opacityValues
        opacity.keyTimes = configuration.opacityKeyTimes
        opacity.duration = duration * 0.88
        opacity.autoreverses = true
        opacity.repeatCount = .infinity
        opacity.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: configuration.opacityValues.count - 1
        )

        layer.add(drift, forKey: SurfaceEffectAnimationKey.ambientDrift)
        layer.add(scale, forKey: SurfaceEffectAnimationKey.ambientScale)
        layer.add(opacity, forKey: SurfaceEffectAnimationKey.ambientOpacity)
    }

    private func makeSweepAnimationGroup(
        path: CGPath,
        duration: TimeInterval,
        beginTime: TimeInterval,
        timingFunction: CAMediaTimingFunction,
        opacityValues: [CGFloat],
        opacityKeyTimes: [NSNumber],
        transformValues: [CATransform3D],
        transformKeyTimes: [NSNumber]
    ) -> CAAnimationGroup {
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.calculationMode = .cubicPaced

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = opacityValues
        opacity.keyTimes = opacityKeyTimes

        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.values = transformValues.map(NSValue.init(caTransform3D:))
        transform.keyTimes = transformKeyTimes

        let group = CAAnimationGroup()
        group.animations = [move, opacity, transform]
        group.duration = duration
        group.beginTime = beginTime
        group.timingFunction = timingFunction
        group.isRemovedOnCompletion = true
        return group
    }

    private func sweepPath(
        fromX startX: CGFloat,
        toX endX: CGFloat,
        centerY: CGFloat,
        wobbleAmplitude: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: startX, y: centerY))
        path.addCurve(
            to: CGPoint(x: endX, y: centerY),
            control1: CGPoint(x: startX + (endX - startX) * 0.24, y: centerY + wobbleAmplitude),
            control2: CGPoint(x: startX + (endX - startX) * 0.54, y: centerY - wobbleAmplitude * 0.9)
        )
        return path
    }

    private func sweepCenterY() -> CGFloat {
        -DesignTokens.Effects.ToolbarSweep.verticalOffsetBelowBounds
    }

    private func insetRoundedRectPath(inset: CGFloat, cornerRadius: CGFloat) -> CGPath {
        let rect = bounds.insetBy(dx: inset, dy: inset)
        return CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }

    private func appearanceValues(for style: Style) -> (
        backgroundColor: NSColor,
        radius: CGFloat,
        material: NSVisualEffectView.Material,
        tintOpacityMultiplier: CGFloat
    ) {
        switch style {
        case .toolbar:
            return (
                backgroundColor: DesignTokens.Color.surfaceToolbar,
                radius: DesignTokens.Radius.md,
                material: .hudWindow,
                tintOpacityMultiplier: 0.68
            )
        case .panel:
            return (
                backgroundColor: DesignTokens.Color.surfacePanel,
                radius: DesignTokens.Radius.lg,
                material: .hudWindow,
                tintOpacityMultiplier: 0.64
            )
        }
    }
}
