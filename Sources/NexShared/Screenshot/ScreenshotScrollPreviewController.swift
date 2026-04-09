import AppKit
import Foundation

final class ScreenshotScrollPreviewController {
    private enum Layout {
        static let panelWidth = DesignTokens.Screenshot.Preview.panelSize.width
        static let panelHeight = DesignTokens.Screenshot.Preview.panelSize.height
        static let imageHeight = DesignTokens.Screenshot.Preview.imageHeight
        static let outerGap = DesignTokens.Screenshot.Preview.outerGap
        static let innerGap = DesignTokens.Screenshot.Preview.innerGap
        static let edgeInset = DesignTokens.Screenshot.Preview.edgeInset
    }

    private let panel: NSPanel
    private let hostView: NSView
    private let rootView = PanelSurfaceView(style: .panel)
    private let titleLabel = NSTextField(labelWithString: L10n.text(zhHans: "长截屏预览", en: "Long Capture Preview"))
    private let imageContainer = NSView(frame: .zero)
    private let imageView = NSImageView(frame: .zero)
    private let sizeLabel = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: Layout.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        hostView = NSView(frame: NSRect(origin: .zero, size: NSSize(width: Layout.panelWidth, height: Layout.panelHeight)))
        hostView.autoresizingMask = [.width, .height]
        panel.contentView = hostView
        panel.contentMinSize = NSSize(width: Layout.panelWidth, height: Layout.panelHeight)
        panel.contentMaxSize = NSSize(width: Layout.panelWidth, height: Layout.panelHeight)
        panel.minSize = NSSize(width: Layout.panelWidth, height: Layout.panelHeight)
        panel.maxSize = NSSize(width: Layout.panelWidth, height: Layout.panelHeight)
        panel.setContentSize(NSSize(width: Layout.panelWidth, height: Layout.panelHeight))

        rootView.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(rootView)

        titleLabel.font = DesignTokens.Typography.screenshotPreviewTitle
        titleLabel.textColor = DesignTokens.Color.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.wantsLayer = true
        imageContainer.layer?.cornerRadius = DesignTokens.Screenshot.Preview.imageCornerRadius
        imageContainer.layer?.masksToBounds = true
        imageContainer.layer?.backgroundColor = DesignTokens.Screenshot.Preview.imageSurface.cgColor

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        sizeLabel.font = DesignTokens.Typography.screenshotPreviewMeta
        sizeLabel.textColor = DesignTokens.Color.textSecondary
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false

        imageContainer.addSubview(imageView)
        rootView.addSubview(titleLabel)
        rootView.addSubview(imageContainer)
        rootView.addSubview(sizeLabel)

        NSLayoutConstraint.activate([
            rootView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            rootView.topAnchor.constraint(equalTo: hostView.topAnchor),
            rootView.widthAnchor.constraint(equalToConstant: Layout.panelWidth),
            rootView.heightAnchor.constraint(equalToConstant: Layout.panelHeight),

            titleLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: DesignTokens.Screenshot.Preview.horizontalInset),
            titleLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -DesignTokens.Screenshot.Preview.horizontalInset),
            titleLabel.topAnchor.constraint(equalTo: rootView.topAnchor, constant: DesignTokens.Screenshot.Preview.topInset),

            imageContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: DesignTokens.Screenshot.Preview.horizontalInset),
            imageContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -DesignTokens.Screenshot.Preview.horizontalInset),
            imageContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.Screenshot.Preview.sectionSpacing),
            imageContainer.heightAnchor.constraint(equalToConstant: Layout.imageHeight),

            imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),

            sizeLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: DesignTokens.Screenshot.Preview.horizontalInset),
            sizeLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -DesignTokens.Screenshot.Preview.horizontalInset),
            sizeLabel.topAnchor.constraint(equalTo: imageContainer.bottomAnchor, constant: DesignTokens.Screenshot.Preview.sectionSpacing),
            sizeLabel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -DesignTokens.Screenshot.Preview.bottomInset)
        ])
    }

    var isVisible: Bool { panel.isVisible }

    func show(near selectionRect: CGRect) {
        let contentSize = NSSize(width: Layout.panelWidth, height: Layout.panelHeight)
        panel.setContentSize(contentSize)
        hostView.frame = NSRect(origin: .zero, size: contentSize)
        let size = panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        let origin = previewOrigin(near: selectionRect, panelSize: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        DiagnosticsLogger.shared.log(
            "screenshot.scrollPreview",
            "show selectionRect=\(selectionRect.debugDescription) panelFrame=\(panel.frame.debugDescription) contentSize=\(NSStringFromSize(panel.contentView?.frame.size ?? .zero))"
        )
        panel.orderFrontRegardless()
    }

    func update(image: NSImage, near selectionRect: CGRect) {
        imageView.image = image
        sizeLabel.stringValue = "\(Int(image.size.width.rounded())) × \(Int(image.size.height.rounded())) px"
        DiagnosticsLogger.shared.log(
            "screenshot.scrollPreview",
            "update imageSize=\(image.size.debugDescription) selectionRect=\(selectionRect.debugDescription)"
        )
        show(near: selectionRect)
    }

    func hide() {
        panel.orderOut(nil)
        imageView.image = nil
        sizeLabel.stringValue = ""
    }

    private func previewOrigin(near selectionRect: CGRect, panelSize: NSSize) -> CGPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(selectionRect) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? selectionRect.insetBy(dx: -240, dy: -240)

        let canFitOutsideLeft =
            selectionRect.minX - Layout.outerGap - panelSize.width >= visibleFrame.minX + Layout.edgeInset
        let canFitInsideLeft =
            selectionRect.width >= panelSize.width + (Layout.innerGap * 2)

        var origin: CGPoint
        if canFitOutsideLeft {
            origin = CGPoint(
                x: selectionRect.minX - panelSize.width - Layout.outerGap,
                y: selectionRect.minY
            )
        } else if canFitInsideLeft {
            origin = CGPoint(
                x: selectionRect.minX + Layout.innerGap,
                y: selectionRect.minY + Layout.innerGap
            )
        } else {
            origin = CGPoint(
                x: selectionRect.minX + Layout.edgeInset,
                y: selectionRect.minY + Layout.edgeInset
            )
        }

        origin.x = min(
            max(origin.x, visibleFrame.minX + Layout.edgeInset),
            visibleFrame.maxX - panelSize.width - Layout.edgeInset
        )
        origin.y = min(
            max(origin.y, visibleFrame.minY + Layout.edgeInset),
            visibleFrame.maxY - panelSize.height - Layout.edgeInset
        )
        return origin
    }
}
