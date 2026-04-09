import AppKit
import NexShared
import QuartzCore

#if !NEXHUB_PRODUCT_NEXHUB

enum AskWindowGeometry {
    static let minimumSize = NSSize(width: 280, height: 200)
    static let maximumComfortableWidth: CGFloat = 760
    static let screenInset: CGFloat = 8
    static let entranceSeedEdge: CGFloat = 12

    private enum HorizontalAnchor {
        case minX
        case maxX
    }

    private enum VerticalAnchor {
        case minY
        case maxY
    }

    static func resolvedFrame(for desiredRect: CGRect, screens: [NSScreen]) -> NSRect {
        resolvedFrame(for: desiredRect, screens: screens, startPoint: nil, endPoint: nil)
    }

    static func resolvedFrame(
        for desiredRect: CGRect,
        screens: [NSScreen],
        startPoint: CGPoint?,
        endPoint: CGPoint?
    ) -> NSRect {
        let fallbackVisible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = bestVisibleFrame(for: desiredRect, screens: screens) ?? fallbackVisible
        return resolvedFrame(
            for: desiredRect,
            visibleFrame: visibleFrame,
            startPoint: startPoint,
            endPoint: endPoint
        )
    }

    static func resolvedFrame(for desiredRect: CGRect, visibleFrame: CGRect) -> NSRect {
        resolvedFrame(for: desiredRect, visibleFrame: visibleFrame, startPoint: nil, endPoint: nil)
    }

    static func resolvedFrame(
        for desiredRect: CGRect,
        visibleFrame: CGRect,
        startPoint: CGPoint?,
        endPoint: CGPoint?
    ) -> NSRect {
        let availableWidth = max(240, visibleFrame.width - screenInset * 2)
        let availableHeight = max(180, visibleFrame.height - screenInset * 2)
        let maximumWidth = min(availableWidth, comfortableMaximumWidth(for: visibleFrame))

        let width = min(max(desiredRect.width, minimumSize.width), maximumWidth)
        let height = min(max(desiredRect.height, minimumSize.height), availableHeight)
        let horizontalAnchor = horizontalAnchor(startPoint: startPoint, endPoint: endPoint)
        let verticalAnchor = verticalAnchor(startPoint: startPoint, endPoint: endPoint)
        let anchoredOriginX = horizontalAnchor == .minX
            ? desiredRect.minX
            : desiredRect.maxX - width
        let anchoredOriginY = verticalAnchor == .minY
            ? desiredRect.minY
            : desiredRect.maxY - height
        let originX = clamp(
            anchoredOriginX,
            min: visibleFrame.minX + screenInset,
            max: visibleFrame.maxX - width - screenInset
        )
        let originY = clamp(
            anchoredOriginY,
            min: visibleFrame.minY + screenInset,
            max: visibleFrame.maxY - height - screenInset
        )

        return NSRect(x: originX, y: originY, width: width, height: height).integral
    }

    static func resizeBounds(for visibleFrame: CGRect) -> (min: NSSize, max: NSSize) {
        let availableWidth = max(minimumSize.width, visibleFrame.width - screenInset * 2)
        let availableHeight = max(minimumSize.height, visibleFrame.height - screenInset * 2)
        return (
            minimumSize,
            NSSize(
                width: min(availableWidth, comfortableMaximumWidth(for: visibleFrame)),
                height: availableHeight
            )
        )
    }

    static func comfortableMaximumWidth(for visibleFrame: CGRect) -> CGFloat {
        min(maximumComfortableWidth, max(minimumSize.width, visibleFrame.width - screenInset * 2))
    }

    static func entranceSeedFrame(
        startPoint: CGPoint,
        endPoint: CGPoint
    ) -> NSRect {
        let seedWidth = entranceSeedEdge
        let seedHeight = entranceSeedEdge
        let originX = startPoint.x <= endPoint.x ? startPoint.x : startPoint.x - seedWidth
        let originY = startPoint.y <= endPoint.y ? startPoint.y : startPoint.y - seedHeight
        return NSRect(x: originX, y: originY, width: seedWidth, height: seedHeight).integral
    }

    static func entranceAnimationFrames(
        selectionFrame: CGRect,
        resolvedFrame: CGRect,
        startPoint: CGPoint?,
        endPoint: CGPoint?
    ) -> [NSRect] {
        let integralSelection = selectionFrame.integral
        let seedFrame: NSRect
        if let startPoint, let endPoint {
            seedFrame = entranceSeedFrame(startPoint: startPoint, endPoint: endPoint)
        } else {
            seedFrame = integralSelection
        }

        var frames: [NSRect] = [seedFrame]
        let integralResolved = resolvedFrame.integral
        if integralResolved != frames.last {
            frames.append(integralResolved)
        }
        return frames
    }

    private static func bestVisibleFrame(for rect: CGRect, screens: [NSScreen]) -> NSRect? {
        let ranked = screens
            .map { screen -> (area: CGFloat, visibleFrame: NSRect) in
                let intersection = screen.frame.intersection(rect)
                let area = max(0, intersection.width * intersection.height)
                return (area, screen.visibleFrame)
            }
            .sorted { lhs, rhs in lhs.area > rhs.area }
        return ranked.first(where: { $0.area > 0 })?.visibleFrame ?? screens.first?.visibleFrame
    }

    private static func horizontalAnchor(startPoint: CGPoint?, endPoint: CGPoint?) -> HorizontalAnchor {
        guard let startPoint, let endPoint else { return .minX }
        return startPoint.x <= endPoint.x ? .minX : .maxX
    }

    private static func verticalAnchor(startPoint: CGPoint?, endPoint: CGPoint?) -> VerticalAnchor {
        guard let startPoint, let endPoint else { return .maxY }
        return startPoint.y <= endPoint.y ? .minY : .maxY
    }

    private static func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }
}

private extension Character {
    var isSentenceBoundary: Bool {
        [".", "!", "?", ",", ";", ":", "。", "！", "？", "，", "；", "："].contains(self)
    }

    var isWhitespaceLike: Bool {
        unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }

    var isLikelyCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }
}

final class AskConversationWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private struct KernelScopeSummary {
        let mode: AskExecutionMode
        let profileID: String
        let workspace: String?
        let page: String?
        let pageTitle: String?
        let selectionPreview: String?
        let planModeActive: Bool
        let editScopeLimited: Bool
        let planModeSummary: String?
        let workspacePermissionProfile: AskWorkspacePermissionProfile
        let workspaceWriteGranted: Bool
        let workspaceShellGranted: Bool
        let workspaceGitWriteGranted: Bool
        let workspaceNetworkAccessGranted: Bool
        let activeTaskTitle: String?
        let capabilityCount: Int
    }

    private struct SmokeStateSnapshot: Encodable {
        let timestamp: TimeInterval
        let isVisible: Bool
        let isStreaming: Bool
        let sessionID: String
        let composerText: String
        let stateMessageCount: Int
        let assistantMessageCount: Int
        let userMessageCount: Int
        let isUsingPersistentAskSessionShell: Bool
        let persistentAskInvocationCount: Int
        let isShowingProactivePopup: Bool
        let proactiveHintText: String?
        let didObserveRuntimeCodePreview: Bool
        let maxObservedRuntimeCodePreviewHeight: CGFloat
        let hasSupplementaryChrome: Bool
        let scopeBarHidden: Bool
        let sessionModeHidden: Bool
        let taskContinuityHidden: Bool
        let hasPendingApproval: Bool
        let pendingApprovalTitle: String?
        let pendingApprovalDetail: String?
        let pendingApprovalConfirmEnabled: Bool
        let pendingApprovalCancelEnabled: Bool
        let latestRuntimeStepTitle: String?
        let latestRuntimeStepState: String?
        let latestRuntimeStepDetail: String?
        let latestRuntimeCodePreviewHeight: CGFloat
        let latestRuntimeCodePreviewSample: String?
        let latestVisibleCodePreviewStepTitle: String?
        let latestVisibleCodePreviewHeight: CGFloat
        let latestVisibleCodePreviewSample: String?
        let transcriptContainsKernelPreparedTask: Bool
        let activeTaskID: String?
        let activeTaskResumeToken: String?
        let activeTaskWorkspaceRoot: String?
        let latestPlaygroundArtifactEntryFile: String?
        let interactiveTaskScopeGranted: Bool
    }

    private enum Layout {
        static let contentInset = DesignTokens.ConversationPanel.contentInsetX
        static let closeButtonSize: CGFloat = 28
        static let composerHorizontalInset: CGFloat = 14
        static let composerVerticalInset: CGFloat = 10
        static let composerButtonSpacing: CGFloat = 10
        static let composerCompactButtonSpacing: CGFloat = 12
        static let composerCompactHorizontalTextInset: CGFloat = 4
        static let composerCompactTrailingClipPadding: CGFloat = 8
        static let composerMinimumHeight: CGFloat = 42
        static let composerCompactWidthThreshold: CGFloat = 400
        static let composerExpandedVisibleLineCount: CGFloat = 2
        static let scopeCardCornerRadius = DesignTokens.ConversationPanel.stripCornerRadius
        static let scopeCardInset: CGFloat = 12
        static let draftCardCornerRadius: CGFloat = 14
        static let draftCardInset: CGFloat = 12
        static let pendingApprovalInlineInset: CGFloat = 12
        static let pendingApprovalInlineMinimumHeight: CGFloat = 40
        static let pendingApprovalInlineButtonWidth: CGFloat = 64
        static let compactCardStackSpacing: CGFloat = 3
        static let compactCardMaxMetaLines = 1
        static let compactCardMaxDetailLines = 1
        static let emptyStateMaxWidth: CGFloat = 300
        static let supplementaryChromeSpacing = DesignTokens.ConversationPanel.chromeSpacing
        static let transcriptStageInset = DesignTokens.ConversationPanel.transcriptStageInset
        static let streamingUpdateFrameInterval: TimeInterval = 1.0 / 60.0
        static let entranceSelectionDuration: TimeInterval = 0.38
        static let entranceExpansionDuration: TimeInterval = 0.28
        static let entranceDirectDuration: TimeInterval = 0.40
        static let entranceInitialAlpha: Float = 0.78
        static let entranceFlowSecondaryDelay: TimeInterval = 0.08
        static let entranceFlowLineThickness: CGFloat = 1.8
        static let entranceFlowPrimarySegmentLength: CGFloat = 0.22
        static let entranceFlowSecondarySegmentLength: CGFloat = 0.15
        static let entranceFlowPrimaryOpacity: Float = 0.68
        static let entranceFlowSecondaryOpacity: Float = 0.42
        static let entranceFlowFadeKeyTimes: [NSNumber] = [0, 0.14, 0.68, 1]
        static let streamingFollowSlackBase: CGFloat = 12
        static let streamingFollowSlackMinimum: CGFloat = 72
        static let streamingFollowSlackMaximum: CGFloat = 160
        static let streamingFollowSlackViewportFraction: CGFloat = 0.18
    }

    private enum EntranceBorderCorner: Int {
        case topLeft
        case topRight
        case bottomRight
        case bottomLeft
    }

    private final class AskPanel: NSPanel {
        var onEscapePressed: (() -> Void)?
        var keyEquivalentHandler: ((NSEvent) -> Bool)?
        var primaryMouseDownHandler: ((NSEvent) -> Bool)?
        var leftMouseDownObserver: ((NSEvent) -> Void)?

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }

        override func cancelOperation(_ sender: Any?) {
            onEscapePressed?()
        }

        override func sendEvent(_ event: NSEvent) {
            if event.type == .leftMouseDown {
                leftMouseDownObserver?(event)
                if primaryMouseDownHandler?(event) == true {
                    return
                }
            }
            super.sendEvent(event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if keyEquivalentHandler?(event) == true {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    private final class ComposerTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var onFocusChanged: ((Bool) -> Void)?
        var suppressAutoScrollToSelection = false

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
                onSubmit?()
                return
            }
            super.keyDown(with: event)
        }

        override func becomeFirstResponder() -> Bool {
            let didBecome = super.becomeFirstResponder()
            if didBecome {
                onFocusChanged?(true)
            }
            return didBecome
        }

        override func resignFirstResponder() -> Bool {
            let didResign = super.resignFirstResponder()
            if didResign {
                onFocusChanged?(false)
            }
            return didResign
        }

        override func mouseDown(with event: NSEvent) {
            onFocusChanged?(true)
            super.mouseDown(with: event)
        }

        override func scrollRangeToVisible(_ range: NSRange) {
            guard suppressAutoScrollToSelection else {
                super.scrollRangeToVisible(range)
                return
            }
            needsDisplay = true
        }
    }

    private final class InteractiveTranscriptTextView: NSTextView {
        private var trackingAreaRef: NSTrackingArea?
        private var baseAttributedContent = NSMutableAttributedString()
        private var hoveredLinkRange: NSRange?
        private var appliedHoveredLinkRange: NSRange?
        private var highlightedSuffixLength = 0
        private var highlightedAlpha: CGFloat = 1
        private var appliedHighlightRange: NSRange?
        private var preparedLayoutWidth: CGFloat = 0

        override var intrinsicContentSize: NSSize {
            guard let layoutManager, let textContainer else {
                return NSSize(width: NSView.noIntrinsicMetric, height: 0)
            }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let height = ceil(usedRect.height + (textContainerInset.height * 2))
            return NSSize(width: NSView.noIntrinsicMetric, height: max(1, height))
        }

        override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
            super.init(frame: frameRect, textContainer: container)
            configureAppearance()
        }

        convenience init() {
            let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            let layoutManager = NSLayoutManager()
            let textStorage = NSTextStorage()
            layoutManager.addTextContainer(textContainer)
            textStorage.addLayoutManager(layoutManager)
            self.init(frame: .zero, textContainer: textContainer)
        }

        private func configureAppearance() {
            translatesAutoresizingMaskIntoConstraints = false
            drawsBackground = false
            isEditable = false
            isSelectable = true
            isAutomaticQuoteSubstitutionEnabled = false
            isAutomaticDashSubstitutionEnabled = false
            isAutomaticTextReplacementEnabled = false
            isAutomaticSpellingCorrectionEnabled = false
            isContinuousSpellCheckingEnabled = false
            isGrammarCheckingEnabled = false
            isAutomaticLinkDetectionEnabled = false
            isAutomaticDataDetectionEnabled = false
            isAutomaticTextCompletionEnabled = false
            enabledTextCheckingTypes = 0
            isRichText = true
            importsGraphics = false
            usesFindBar = false
            isVerticallyResizable = true
            isHorizontallyResizable = false
            textContainerInset = .zero
            textContainer?.lineFragmentPadding = 0
            textContainer?.widthTracksTextView = true
            textContainer?.heightTracksTextView = false
            textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            backgroundColor = .clear
            insertionPointColor = .clear
            linkTextAttributes = [
                .foregroundColor: DesignTokens.Color.linkBlue
            ]
            setContentCompressionResistancePriority(.required, for: .vertical)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.required, for: .vertical)
            setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func setAttributedContent(_ content: NSAttributedString, invalidateLayout: Bool = true) {
            baseAttributedContent = NSMutableAttributedString(attributedString: content)
            textStorage?.setAttributedString(baseAttributedContent)
            clampTemporaryStateToContentLength()
            refreshTemporaryAttributes()
            needsDisplay = true
            if invalidateLayout {
                invalidateIntrinsicContentSize()
            }
        }

        func appendAttributedContent(_ content: NSAttributedString, invalidateLayout: Bool = true) {
            guard content.length > 0 else { return }
            baseAttributedContent.append(content)
            textStorage?.append(content)
            clampTemporaryStateToContentLength()
            refreshTemporaryAttributes()
            needsDisplay = true
            if invalidateLayout {
                invalidateIntrinsicContentSize()
            }
        }

        func measuredContentHeight() -> CGFloat {
            guard let layoutManager, let textContainer else { return 0 }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            return ceil(usedRect.height + (textContainerInset.height * 2))
        }

        func primeLayoutWidth(_ width: CGFloat) {
            let normalizedWidth = max(1, floor(width))
            guard abs(normalizedWidth - preparedLayoutWidth) > 0.5 else { return }
            preparedLayoutWidth = normalizedWidth
            textContainer?.containerSize = NSSize(
                width: normalizedWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
            invalidateIntrinsicContentSize()
        }

        func setHighlightedSuffix(length: Int, alpha: CGFloat) {
            let normalizedLength = min(max(0, length), baseAttributedContent.length)
            guard normalizedLength != highlightedSuffixLength || abs(alpha - highlightedAlpha) > 0.001 else { return }
            highlightedSuffixLength = normalizedLength
            highlightedAlpha = alpha
            refreshTemporaryAttributes()
        }

        var currentHighlightState: (length: Int, alpha: CGFloat) {
            (highlightedSuffixLength, highlightedAlpha)
        }

        func setStreamingInteractionEnabled(_ isStreaming: Bool) {
            // Keep interaction mode stable while streaming. Toggling NSTextView selection
            // state mid-stream can trigger AppKit selection assertions once layout updates
            // race with pending range bookkeeping.
            _ = isStreaming
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            primeLayoutWidth(newSize.width)
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            updateHoverState(with: event)
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            updateHoverState(with: event)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            setHoveredLinkRange(nil)
            NSCursor.arrow.set()
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let linkInfo = linkInfo(at: point) {
                openResolvedLink(linkInfo.url)
                return
            }
            super.mouseUp(with: event)
        }

        override func clicked(onLink link: Any, at charIndex: Int) {
            guard let url = resolvedURL(from: link) else {
                super.clicked(onLink: link, at: charIndex)
                return
            }
            openResolvedLink(url)
        }

        private func updateHoverState(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let linkInfo = linkInfo(at: point)
            setHoveredLinkRange(linkInfo?.range)
            if linkInfo == nil {
                NSCursor.arrow.set()
            } else {
                NSCursor.pointingHand.set()
            }
        }

        private func setHoveredLinkRange(_ range: NSRange?) {
            let current = hoveredLinkRange ?? NSRange(location: NSNotFound, length: 0)
            let next = range ?? NSRange(location: NSNotFound, length: 0)
            guard !NSEqualRanges(current, next) else { return }
            hoveredLinkRange = range
            refreshTemporaryAttributes()
        }

        private func refreshTemporaryAttributes() {
            guard let layoutManager else { return }
            let contentLength = baseAttributedContent.length
            if let removalRange = clampedTemporaryRange(appliedHoveredLinkRange, contentLength: contentLength) {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: removalRange)
            }
            if let removalRange = clampedTemporaryRange(appliedHighlightRange, contentLength: contentLength) {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: removalRange)
            }
            appliedHoveredLinkRange = nil
            appliedHighlightRange = nil

            if let highlightRange = clampedHighlightRange(contentLength: contentLength) {
                applyStreamingRevealAlpha(
                    to: highlightRange,
                    alpha: highlightedAlpha,
                    layoutManager: layoutManager
                )
                appliedHighlightRange = highlightRange
            }

            if let hoveredLinkRange = clampedTemporaryRange(hoveredLinkRange, contentLength: contentLength) {
                layoutManager.addTemporaryAttributes(
                    [.foregroundColor: hoverLinkColor()],
                    forCharacterRange: hoveredLinkRange
                )
                appliedHoveredLinkRange = hoveredLinkRange
            }
        }

        private func clampTemporaryStateToContentLength() {
            let contentLength = baseAttributedContent.length
            highlightedSuffixLength = min(max(0, highlightedSuffixLength), contentLength)
            hoveredLinkRange = clampedTemporaryRange(hoveredLinkRange, contentLength: contentLength)
            appliedHoveredLinkRange = clampedTemporaryRange(appliedHoveredLinkRange, contentLength: contentLength)
            appliedHighlightRange = clampedHighlightRange(contentLength: contentLength)
        }

        private func clampedHighlightRange(contentLength: Int) -> NSRange? {
            let clampedLength = min(max(0, highlightedSuffixLength), contentLength)
            guard clampedLength > 0 else { return nil }
            return NSRange(location: max(0, contentLength - clampedLength), length: clampedLength)
        }

        private func clampedTemporaryRange(_ range: NSRange?, contentLength: Int) -> NSRange? {
            guard let range,
                  range.location != NSNotFound,
                  contentLength > 0,
                  range.location < contentLength else {
                return nil
            }
            let clampedLength = min(range.length, contentLength - range.location)
            guard clampedLength > 0 else { return nil }
            return NSRange(location: range.location, length: clampedLength)
        }

        private func linkInfo(at point: NSPoint) -> (url: URL, range: NSRange)? {
            guard let layoutManager, let textContainer, let textStorage else { return nil }
            let containerPoint = NSPoint(
                x: point.x - textContainerInset.width,
                y: point.y - textContainerInset.height
            )
            guard containerPoint.x >= 0, containerPoint.y >= 0 else { return nil }

            let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
            guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            guard glyphRect.contains(containerPoint) else { return nil }

            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            guard characterIndex < textStorage.length else { return nil }

            var effectiveRange = NSRange(location: 0, length: 0)
            let value = textStorage.attribute(.link, at: characterIndex, effectiveRange: &effectiveRange)
            guard let url = resolvedURL(from: value) else { return nil }
            return (url, effectiveRange)
        }

        private func resolvedURL(from value: Any?) -> URL? {
            if let url = value as? URL {
                return url.isFileURL ? url.standardizedFileURL : url
            }
            if let string = value as? String {
                if string.hasPrefix("/") || string.hasPrefix("~") {
                    return URL(fileURLWithPath: (string as NSString).expandingTildeInPath).standardizedFileURL
                }
                if string.hasPrefix("file://") {
                    if let url = URL(string: string) {
                        return url.isFileURL ? url.standardizedFileURL : url
                    }
                    return nil
                }
                return URL(string: string)
            }
            return nil
        }

        private func openResolvedLink(_ url: URL) {
            let resolved = url.isFileURL ? url.standardizedFileURL : url
            if resolved.isFileURL, resolved.hasDirectoryPath {
                NSWorkspace.shared.open(resolved)
            } else if resolved.isFileURL {
                NSWorkspace.shared.activateFileViewerSelecting([resolved])
            } else {
                NSWorkspace.shared.open(resolved)
            }
        }

        private func hoverLinkColor() -> NSColor {
            DesignTokens.Color.linkBlue.blended(withFraction: 0.12, of: .white) ?? DesignTokens.Color.linkBlue
        }

        private func applyStreamingRevealAlpha(
            to range: NSRange,
            alpha: CGFloat,
            layoutManager: NSLayoutManager
        ) {
            let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: baseAttributedContent.length))
            guard safeRange.length > 0 else { return }
            let clampedAlpha = max(0.7, min(alpha, 1))
            baseAttributedContent.enumerateAttribute(.foregroundColor, in: safeRange, options: []) { value, effectiveRange, _ in
                let baseColor = (value as? NSColor) ?? DesignTokens.Color.textPrimary
                layoutManager.addTemporaryAttributes(
                    [.foregroundColor: baseColor.withAlphaComponent(baseColor.alphaComponent * clampedAlpha)],
                    forCharacterRange: effectiveRange
                )
            }
        }
    }

    private final class PlaceholderTextField: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    private final class HoverResponsiveView: NSView {
        var onHoverChanged: ((Bool) -> Void)?

        private var trackingAreaRef: NSTrackingArea?
        private var isHovering = false {
            didSet {
                guard isHovering != oldValue else { return }
                onHoverChanged?(isHovering)
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
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
            isHovering = true
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            isHovering = false
        }
    }

    private final class HoverButton: NSButton {
        var onHoverChanged: ((Bool) -> Void)?
        var onPrimaryMouseDown: ((NSEvent) -> Bool)?
        var onMouseDown: ((NSEvent) -> Void)?
        var hoverScale: CGFloat = 1
        var currentHoverState: Bool { isHovering }

        private var trackingAreaRef: NSTrackingArea?
        private var isHovering = false {
            didSet {
                guard isHovering != oldValue else { return }
                onHoverChanged?(isHovering)
            }
        }

        override var isEnabled: Bool {
            didSet {
                guard isEnabled != oldValue else { return }
                if !isEnabled {
                    isHovering = false
                }
                onHoverChanged?(isHovering)
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            onMouseDown?(event)
            if onPrimaryMouseDown?(event) == true {
                return
            }
            super.mouseDown(with: event)
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
            isHovering = true
            NSCursor.pointingHand.set()
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            isHovering = false
            NSCursor.arrow.set()
        }
    }

    private final class AskFlippedClipView: NSClipView {
        override var isFlipped: Bool { true }
    }

    private final class AskFlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class CitationButton: NSButton {
        let card: SkillResultCard

        init(card: SkillResultCard, index: Int) {
            self.card = card
            super.init(frame: .zero)
            let label = "\(index + 1). \(card.title)"
            title = label
            isBordered = false
            bezelStyle = .regularSquare
            focusRingType = .none
            font = NSFont.systemFont(ofSize: 11, weight: .medium)
            contentTintColor = DesignTokens.Color.textPrimary
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.borderWidth = 1
            layer?.borderColor = DesignTokens.Color.controlBorder.cgColor
            layer?.backgroundColor = DesignTokens.Color.controlFill.cgColor
            lineBreakMode = .byTruncatingTail
            setButtonType(.momentaryPushIn)
            setContentHuggingPriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .horizontal)
            attributedTitle = NSAttributedString(
                string: label,
                attributes: [
                    .font: font ?? NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: DesignTokens.Color.textPrimary
                ]
            )
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private final class AssistantActionCardView: NSView {
        var onAction: (() -> Void)?
        private let isPrimary: Bool
        private var trackingAreaRef: NSTrackingArea?
        private var hover = false

        init(card: SkillResultCard, isPrimary: Bool) {
            self.isPrimary = isPrimary
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = DesignTokens.ResultPanel.ActionCard.cornerRadius
            translatesAutoresizingMaskIntoConstraints = false
            updateAppearance(animated: false)
            let hasAction = card.action != nil

            let titleLabel = NSTextField(labelWithString: card.title)
            titleLabel.font = DesignTokens.Typography.resultPanelCardTitle
            titleLabel.textColor = DesignTokens.Color.textPrimary
            titleLabel.lineBreakMode = .byTruncatingTail

            let subtitleLabel = NSTextField(wrappingLabelWithString: card.subtitle ?? "")
            subtitleLabel.font = DesignTokens.Typography.resultPanelCardDescription
            subtitleLabel.textColor = DesignTokens.Color.textSecondary
            subtitleLabel.maximumNumberOfLines = 2
            subtitleLabel.isHidden = card.subtitle?.isEmpty ?? true

            let badgesLabel = NSTextField(labelWithString: (card.badges ?? []).joined(separator: " · "))
            badgesLabel.font = DesignTokens.Typography.resultPanelCardDescription
            badgesLabel.textColor = DesignTokens.ResultPanel.ActionCard.descriptionColor
            badgesLabel.isHidden = card.badges?.isEmpty ?? true

            let descriptionLabel = NSTextField(wrappingLabelWithString: card.description ?? "")
            descriptionLabel.font = DesignTokens.Typography.resultPanelCardDescription
            descriptionLabel.textColor = DesignTokens.ResultPanel.ActionCard.descriptionColor
            descriptionLabel.maximumNumberOfLines = 3
            descriptionLabel.isHidden = card.description?.isEmpty ?? true

            let actionArrow = NSImageView(
                image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "action") ?? NSImage()
            )
            actionArrow.contentTintColor = DesignTokens.ResultPanel.ActionCard.actionTint
            actionArrow.symbolConfiguration = .init(
                pointSize: DesignTokens.ResultPanel.ActionCard.arrowPointSize,
                weight: .semibold
            )
            actionArrow.translatesAutoresizingMaskIntoConstraints = false
            actionArrow.widthAnchor.constraint(equalToConstant: DesignTokens.ResultPanel.ActionCard.arrowDimension).isActive = true
            actionArrow.heightAnchor.constraint(equalToConstant: DesignTokens.ResultPanel.ActionCard.arrowDimension).isActive = true
            actionArrow.isHidden = !hasAction

            let titleRow = NSStackView(views: [titleLabel, NSView(), actionArrow])
            titleRow.orientation = .horizontal
            titleRow.alignment = .centerY
            titleRow.spacing = DesignTokens.ResultPanel.ActionCard.titleRowSpacing

            var arranged: [NSView] = [titleRow]
            if !(card.subtitle?.isEmpty ?? true) {
                arranged.append(subtitleLabel)
            }
            if !(card.badges?.isEmpty ?? true) {
                arranged.append(badgesLabel)
            }
            if !(card.description?.isEmpty ?? true) {
                arranged.append(descriptionLabel)
            }

            let stack = NSStackView(views: arranged)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = DesignTokens.ResultPanel.ActionCard.verticalSpacing
            stack.translatesAutoresizingMaskIntoConstraints = false

            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.ResultPanel.ActionCard.contentInset),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.ResultPanel.ActionCard.contentInset),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.ResultPanel.ActionCard.contentInset),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.ResultPanel.ActionCard.contentInset),
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingAreaRef = area
            window?.invalidateCursorRects(for: self)
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard onAction != nil else { return }
            addCursorRect(bounds, cursor: .pointingHand)
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            guard onAction != nil else { return }
            hover = true
            updateAppearance(animated: true)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            guard onAction != nil else { return }
            hover = false
            updateAppearance(animated: true)
        }

        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            guard !bounds.isEmpty else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return }
            onAction?()
        }

        private func updateAppearance(animated: Bool) {
            let palette: DesignTokens.Semantic.SurfacePair
            if isPrimary {
                palette = hover
                    ? DesignTokens.Semantic.ResultPanel.ActionCard.primaryHover
                    : DesignTokens.Semantic.ResultPanel.ActionCard.primaryRest
            } else {
                palette = hover
                    ? DesignTokens.Semantic.ResultPanel.ActionCard.secondaryHover
                    : DesignTokens.Semantic.ResultPanel.ActionCard.secondaryRest
            }

            let apply = {
                self.layer?.backgroundColor = palette.fill.cgColor
                self.layer?.borderWidth = DesignTokens.ResultPanel.ActionCard.borderWidth
                self.layer?.borderColor = palette.border.cgColor
            }

            guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                apply()
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = DesignTokens.ResultPanel.ActionCard.hoverAnimationDuration
                self.animator().alphaValue = 1
                apply()
            }
        }
    }

    private enum AskMarkdownRenderer {
        private enum Block {
            case heading(level: Int, text: String)
            case paragraph(String)
            case bullet(String)
            case quote(String)
            case code(String)
        }

        static func attributedText(
            for text: String,
            role: AskMessageRole,
            highlightedSuffixLength: Int = 0,
            highlightedAlpha: CGFloat = 1
        ) -> NSAttributedString {
            switch role {
            case .assistant:
                return ResultMarkdownRenderer.assistantAttributedText(
                    text: text,
                    highlightedSuffixLength: highlightedSuffixLength,
                    highlightedAlpha: highlightedAlpha
                )
            default:
                return NSAttributedString(
                    string: text,
                    attributes: bodyAttributes()
                )
            }
        }

        static func streamingAssistantAttributedText(
            _ text: String,
            highlightedSuffixLength: Int = 0,
            highlightedAlpha: CGFloat = 1
        ) -> NSAttributedString {
            let output = NSMutableAttributedString(
                string: text,
                attributes: bodyAttributes()
            )
            if highlightedSuffixLength > 0 {
                let suffixLength = min(max(0, highlightedSuffixLength), output.length)
                if suffixLength > 0 {
                    let suffixRange = NSRange(location: output.length - suffixLength, length: suffixLength)
                    output.addAttribute(
                        .foregroundColor,
                        value: DesignTokens.Color.textPrimary.withAlphaComponent(highlightedAlpha),
                        range: suffixRange
                    )
                }
            }
            return output
        }

        static func prefersStructuredStreamingRendering(for text: String) -> Bool {
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            if containsMarkdownSyntax(normalized) {
                return true
            }
            let linkLikeMarkers = [
                "/Users/",
                "http://",
                "https://",
                "~/",
                "Desktop/",
                "Downloads/",
                "Documents/"
            ]
            return linkLikeMarkers.contains { normalized.contains($0) }
        }

        static func displayStringForAssistantText(_ text: String) -> String {
            attributedText(for: text, role: .assistant).string
        }

        private static func assistantAttributedText(
            text: String,
            highlightedSuffixLength: Int,
            highlightedAlpha: CGFloat
        ) -> NSAttributedString {
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            let blocks = markdownBlocks(from: normalized)
            let output = NSMutableAttributedString()

            for (index, block) in blocks.enumerated() {
                if index > 0 {
                    output.append(NSAttributedString(string: "\n"))
                }
                switch block {
                case .heading(let level, let content):
                    output.append(inlineAttributedText(content, attributes: headingAttributes(level: level)))
                case .paragraph(let content):
                    output.append(inlineAttributedText(content, attributes: bodyAttributes()))
                case .bullet(let content):
                    let paragraphStyle = bulletParagraphStyle()
                    let bulletPrefix = NSAttributedString(
                        string: "• ",
                        attributes: [
                            .font: DesignTokens.Typography.resultPanelBody,
                            .foregroundColor: DesignTokens.Color.textPrimary,
                            .paragraphStyle: paragraphStyle
                        ]
                    )
                    let body = inlineAttributedText(
                        content,
                        attributes: [
                            .font: DesignTokens.Typography.resultPanelBody,
                            .foregroundColor: DesignTokens.Color.textPrimary,
                            .paragraphStyle: paragraphStyle
                        ]
                    )
                    let line = NSMutableAttributedString(attributedString: bulletPrefix)
                    line.append(body)
                    output.append(line)
                case .quote(let content):
                    output.append(inlineAttributedText(content, attributes: quoteAttributes()))
                case .code(let content):
                    output.append(NSAttributedString(string: content, attributes: codeBlockAttributes()))
                }
            }

            if highlightedSuffixLength > 0 && !containsMarkdownSyntax(normalized) {
                let suffixLength = min(max(0, highlightedSuffixLength), output.length)
                if suffixLength > 0 {
                    let suffixRange = NSRange(location: output.length - suffixLength, length: suffixLength)
                    output.addAttribute(
                        .foregroundColor,
                        value: DesignTokens.Color.textPrimary.withAlphaComponent(highlightedAlpha),
                        range: suffixRange
                    )
                }
            }

            return output
        }

        private static func markdownBlocks(from text: String) -> [Block] {
            let lines = text.components(separatedBy: .newlines)
            var blocks: [Block] = []
            var index = 0

            func trimmed(_ value: String) -> String {
                value.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            while index < lines.count {
                let currentLine = lines[index]
                let current = trimmed(currentLine)
                if current.isEmpty {
                    index += 1
                    continue
                }

                if current.hasPrefix("```") {
                    index += 1
                    var codeLines: [String] = []
                    while index < lines.count {
                        let line = lines[index]
                        if trimmed(line).hasPrefix("```") {
                            index += 1
                            break
                        }
                        codeLines.append(line)
                        index += 1
                    }
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    continue
                }

                if let headingMatch = current.range(of: #"^(#{1,3})\s+(.+)$"#, options: .regularExpression) {
                    let line = String(current[headingMatch])
                    let hashes = line.prefix { $0 == "#" }.count
                    let content = trimmed(String(line.dropFirst(hashes)))
                    blocks.append(.heading(level: hashes, text: content))
                    index += 1
                    continue
                }

                if let bulletMatch = current.range(of: #"^(?:[-*•]|\d+[.)])\s+(.+)$"#, options: .regularExpression) {
                    let line = String(current[bulletMatch])
                    let content = line.replacingOccurrences(
                        of: #"^(?:[-*•]|\d+[.)])\s+"#,
                        with: "",
                        options: .regularExpression
                    )
                    blocks.append(.bullet(content))
                    index += 1
                    continue
                }

                if current.hasPrefix(">") {
                    let content = trimmed(current.replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression))
                    blocks.append(.quote(content))
                    index += 1
                    continue
                }

                var paragraphLines = [current]
                index += 1
                while index < lines.count {
                    let next = trimmed(lines[index])
                    if next.isEmpty || next.hasPrefix("```") {
                        break
                    }
                    if next.range(of: #"^(#{1,3})\s+.+$"#, options: .regularExpression) != nil ||
                        next.range(of: #"^(?:[-*•]|\d+[.)])\s+.+$"#, options: .regularExpression) != nil ||
                        next.hasPrefix(">") {
                        break
                    }
                    paragraphLines.append(next)
                    index += 1
                }
                blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            }

            return blocks.isEmpty ? [.paragraph(text)] : blocks
        }

        private static func inlineAttributedText(
            _ text: String,
            attributes: [NSAttributedString.Key: Any]
        ) -> NSAttributedString {
            let output = NSMutableAttributedString()
            var cursor = text.startIndex

            func appendPlain(_ string: String) {
                guard !string.isEmpty else { return }
                output.append(NSAttributedString(string: string, attributes: attributes))
            }

            while cursor < text.endIndex {
                let remaining = text[cursor...]

                if remaining.hasPrefix("**"),
                   let boldStart = text.index(cursor, offsetBy: 2, limitedBy: text.endIndex),
                   let boldRange = text[boldStart...].range(of: "**") {
                    let content = String(text[boldStart..<boldRange.lowerBound])
                    let merged = emphasisAttributes(base: attributes)
                    output.append(NSAttributedString(string: content, attributes: merged))
                    cursor = boldRange.upperBound
                    continue
                }

                if remaining.hasPrefix("`"),
                   let codeStart = text.index(cursor, offsetBy: 1, limitedBy: text.endIndex),
                   let codeRange = text[codeStart...].range(of: "`") {
                    let content = String(text[codeStart..<codeRange.lowerBound])
                    if let localURL = resolvedLocalFileURL(for: content) {
                        output.append(NSAttributedString(string: content, attributes: linkAttributes(base: attributes, url: localURL)))
                    } else {
                        output.append(NSAttributedString(string: content, attributes: inlineCodeAttributes(base: attributes)))
                    }
                    cursor = codeRange.upperBound
                    continue
                }

                if remaining.hasPrefix("["),
                   let closeBracket = remaining.range(of: "]("),
                   let urlEnd = remaining[closeBracket.upperBound...].firstIndex(of: ")") {
                    let labelStart = remaining.index(after: remaining.startIndex)
                    let label = String(remaining[labelStart..<closeBracket.lowerBound])
                    let urlText = String(remaining[closeBracket.upperBound..<urlEnd])
                    if let url = URL(string: urlText), !label.isEmpty {
                        output.append(
                            NSAttributedString(
                                string: label,
                                attributes: mergedAttributes(
                                    base: attributes,
                                    extras: linkAttributes(base: attributes, url: url)
                                )
                            )
                        )
                        cursor = text.index(after: urlEnd)
                        continue
                    }
                }

                appendPlain(String(text[cursor]))
                cursor = text.index(after: cursor)
            }

            return output
        }

        private static func mergedAttributes(
            base: [NSAttributedString.Key: Any],
            extras: [NSAttributedString.Key: Any]
        ) -> [NSAttributedString.Key: Any] {
            base.merging(extras) { _, new in new }
        }

        private static func emphasisAttributes(
            base: [NSAttributedString.Key: Any]
        ) -> [NSAttributedString.Key: Any] {
            mergedAttributes(
                base: base,
                extras: [
                    .font: NSFont.systemFont(ofSize: DesignTokens.Typography.resultPanelBody.pointSize, weight: .bold),
                    .foregroundColor: DesignTokens.Color.textPrimary.withAlphaComponent(0.98)
                ]
            )
        }

        private static func containsMarkdownSyntax(_ text: String) -> Bool {
            let candidates = ["```", "**", "`", "# ", "- ", "* ", "[", "> "]
            return candidates.contains { text.contains($0) }
        }

        private static func bodyAttributes() -> [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            style.lineSpacing = 4
            style.paragraphSpacing = 12
            return [
                .font: DesignTokens.Typography.resultPanelBody,
                .foregroundColor: DesignTokens.Color.textPrimary,
                .paragraphStyle: style
            ]
        }

        private static func headingAttributes(level: Int) -> [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            style.lineSpacing = 3
            style.paragraphSpacing = 10
            let fontSize: CGFloat = switch level {
            case 1: 17
            case 2: 15
            default: 14
            }
            return [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: DesignTokens.Color.textPrimary,
                .paragraphStyle: style
            ]
        }

        private static func quoteAttributes() -> [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            style.lineSpacing = 4
            style.paragraphSpacing = 12
            style.headIndent = 10
            style.firstLineHeadIndent = 10
            return [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: DesignTokens.Color.textSecondary,
                .paragraphStyle: style
            ]
        }

        private static func codeBlockAttributes() -> [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            style.lineSpacing = 3
            style.paragraphSpacing = 12
            style.headIndent = 10
            style.firstLineHeadIndent = 10
            return [
                .font: DesignTokens.Typography.resultPanelDetailMono,
                .foregroundColor: DesignTokens.Color.textPrimary,
                .backgroundColor: DesignTokens.Color.controlFill.withAlphaComponent(0.55),
                .paragraphStyle: style
            ]
        }

        private static func inlineCodeAttributes(base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            mergedAttributes(
                base: base,
                extras: [
                    .font: DesignTokens.Typography.resultPanelDetailMono,
                    .backgroundColor: DesignTokens.Color.controlFill.withAlphaComponent(0.55)
                ]
            )
        }

        private static func linkAttributes(
            base: [NSAttributedString.Key: Any],
            url: URL
        ) -> [NSAttributedString.Key: Any] {
            mergedAttributes(
                base: base,
                extras: [
                    .foregroundColor: DesignTokens.Color.linkBlue,
                    .link: url
                ]
            )
        }

        private static func resolvedLocalFileURL(for rawValue: String) -> URL? {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let expanded = (trimmed as NSString).expandingTildeInPath
            let fileManager = FileManager.default

            if expanded.hasPrefix("/") || trimmed.hasPrefix("~") {
                let explicitURL = URL(fileURLWithPath: expanded).standardizedFileURL
                return fileManager.fileExists(atPath: explicitURL.path) ? explicitURL : nil
            }

            let home = fileManager.homeDirectoryForCurrentUser
            let candidateRoots = [
                home.appendingPathComponent("Desktop", isDirectory: true),
                home.appendingPathComponent("Downloads", isDirectory: true),
                home.appendingPathComponent("Documents", isDirectory: true)
            ]

            var matches: [URL] = []
            for root in candidateRoots {
                let candidate = root.appendingPathComponent(trimmed)
                if fileManager.fileExists(atPath: candidate.path) {
                    matches.append(candidate.standardizedFileURL)
                }
            }

            guard !matches.isEmpty else { return nil }
            return matches.sorted(by: preferredLocalURLOrder).first
        }

        private static func preferredLocalURLOrder(lhs: URL, rhs: URL) -> Bool {
            let fileManager = FileManager.default
            var lhsIsDirectory: ObjCBool = false
            var rhsIsDirectory: ObjCBool = false
            let lhsExists = fileManager.fileExists(atPath: lhs.path, isDirectory: &lhsIsDirectory)
            let rhsExists = fileManager.fileExists(atPath: rhs.path, isDirectory: &rhsIsDirectory)
            if lhsExists, rhsExists, lhsIsDirectory.boolValue != rhsIsDirectory.boolValue {
                return lhsIsDirectory.boolValue && !rhsIsDirectory.boolValue
            }
            return lhs.path < rhs.path
        }

        private static func bulletParagraphStyle() -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            style.lineSpacing = 4
            style.paragraphSpacing = 10
            style.headIndent = 18
            return style
        }
    }

    private final class CitationPopoverViewController: NSViewController {
        private let card: SkillResultCard
        private let actionHandler: (SkillResultCard) -> Void

        init(card: SkillResultCard, actionHandler: @escaping (SkillResultCard) -> Void) {
            self.card = card
            self.actionHandler = actionHandler
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let root = NSView()
            root.translatesAutoresizingMaskIntoConstraints = false
            root.wantsLayer = true
            root.layer?.cornerRadius = 12
            root.layer?.backgroundColor = DesignTokens.Color.surfacePanel.cgColor

            let titleLabel = NSTextField(wrappingLabelWithString: card.title)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            titleLabel.textColor = DesignTokens.Color.textPrimary
            titleLabel.maximumNumberOfLines = 0

            let subtitleText = [card.subtitle, card.description]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let subtitleLabel = NSTextField(wrappingLabelWithString: subtitleText)
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            subtitleLabel.textColor = DesignTokens.Color.textSecondary
            subtitleLabel.maximumNumberOfLines = 0
            subtitleLabel.isHidden = subtitleText.isEmpty

            root.addSubview(titleLabel)
            root.addSubview(subtitleLabel)

            var constraints = [
                titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
                titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            ]

            if subtitleText.isEmpty {
                constraints.append(titleLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12))
            } else {
                constraints.append(contentsOf: [
                    subtitleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                    subtitleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
                    subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
                ])
            }

            if let action = card.action {
                let actionButton = NSButton(title: action.label, target: self, action: #selector(handleAction))
                actionButton.translatesAutoresizingMaskIntoConstraints = false
                actionButton.bezelStyle = .rounded
                root.addSubview(actionButton)
                if subtitleText.isEmpty {
                    constraints.removeLast()
                    constraints.append(actionButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10))
                } else {
                    constraints.append(actionButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10))
                }
                constraints.append(contentsOf: [
                    actionButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                    actionButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
                ])
            } else if !subtitleText.isEmpty {
                constraints.append(subtitleLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12))
            }

            NSLayoutConstraint.activate(constraints)
            preferredContentSize = NSSize(width: 260, height: (card.action == nil && subtitleText.isEmpty) ? 52 : 110)
            view = root
        }

        @objc private func handleAction() {
            actionHandler(card)
        }
    }

    private final class TranscriptRowView: NSView {
        private final class BubbleContainerView: NSView {
            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                translatesAutoresizingMaskIntoConstraints = false
                wantsLayer = true
                layer?.cornerRadius = 12
                layer?.masksToBounds = true
                layer?.backgroundColor = DesignTokens.ConversationPanel.Surface.userBubbleFill.cgColor
                layer?.borderWidth = 1
                layer?.borderColor = DesignTokens.ConversationPanel.Surface.userBubbleBorder.cgColor
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }
        }

        private class AssistantBlockView: NSView {
            let blockID: Int

            init(blockID: Int) {
                self.blockID = blockID
                super.init(frame: .zero)
                translatesAutoresizingMaskIntoConstraints = false
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            func prepareLayoutWidth(_ width: CGFloat) {
                _ = width
            }

            func setHighlightedSuffix(length: Int, alpha: CGFloat) {
                _ = length
                _ = alpha
            }
        }

        private final class AssistantTextBlockView: AssistantBlockView {
            private let textView = InteractiveTranscriptTextView()
            private var currentKind: AskRenderableBlockKind?
            private var currentText = ""
            private var isStreaming = false

            init(blockID: Int, interactiveLinks: Bool) {
                super.init(blockID: blockID)
                textView.isSelectable = interactiveLinks
                addSubview(textView)
                NSLayoutConstraint.activate([
                    textView.leadingAnchor.constraint(equalTo: leadingAnchor),
                    textView.trailingAnchor.constraint(equalTo: trailingAnchor),
                    textView.topAnchor.constraint(equalTo: topAnchor),
                    textView.bottomAnchor.constraint(equalTo: bottomAnchor)
                ])
            }

            override func prepareLayoutWidth(_ width: CGFloat) {
                textView.primeLayoutWidth(width)
            }

            @discardableResult
            func renderStatic(
                kind: AskRenderableBlockKind,
                text: String,
                localLinkResolutionMode: ResultMarkdownRenderer.LocalLinkResolutionMode = .synchronousFull
            ) -> Bool {
                let previousHeight = textView.measuredContentHeight()
                textView.setAttributedContent(
                    Self.attributedText(
                        for: kind,
                        text: text,
                        localLinkResolutionMode: localLinkResolutionMode
                    )
                )
                textView.setHighlightedSuffix(length: 0, alpha: 1)
                currentKind = kind
                currentText = text
                isStreaming = false
                let updatedHeight = textView.measuredContentHeight()
                return abs(updatedHeight - previousHeight) > 0.5
            }

            @discardableResult
            func renderStreaming(
                kind: AskRenderableBlockKind,
                text: String,
                highlightedSuffixLength: Int,
                highlightedAlpha: CGFloat
            ) -> Bool {
                let previousHeight = textView.measuredContentHeight()
                if shouldRenderStreamingBlockAsFormatted(kind: kind, text: text) {
                    textView.setAttributedContent(
                        Self.attributedText(
                            for: kind,
                            text: text,
                            localLinkResolutionMode: .cachedOnly
                        ),
                        invalidateLayout: false
                    )
                } else if canAppendStreamingText(kind: kind, text: text) {
                    let delta = String(text.dropFirst(currentText.count))
                    if !delta.isEmpty {
                        textView.appendAttributedContent(
                            Self.streamingDeltaAttributedText(for: kind, delta: delta),
                            invalidateLayout: false
                        )
                    }
                } else {
                    textView.setAttributedContent(
                        Self.streamingAttributedText(for: kind, text: text),
                        invalidateLayout: false
                    )
                }

                currentKind = kind
                currentText = text
                isStreaming = true
                textView.setHighlightedSuffix(length: highlightedSuffixLength, alpha: highlightedAlpha)
                let updatedHeight = textView.measuredContentHeight()
                if abs(updatedHeight - previousHeight) > 0.5 {
                    textView.invalidateIntrinsicContentSize()
                }
                return abs(updatedHeight - previousHeight) > 0.5
            }

            override func setHighlightedSuffix(length: Int, alpha: CGFloat) {
                textView.setHighlightedSuffix(length: length, alpha: alpha)
            }

            var currentHighlightState: (length: Int, alpha: CGFloat) {
                textView.currentHighlightState
            }

            private func shouldRenderStreamingBlockAsFormatted(
                kind: AskRenderableBlockKind,
                text: String
            ) -> Bool {
                switch kind {
                case .unorderedList, .orderedList, .quote:
                    return true
                case .paragraph:
                    return AskMarkdownRenderer.prefersStructuredStreamingRendering(for: text)
                case .codeBlock:
                    return false
                }
            }

            private func canAppendStreamingText(
                kind: AskRenderableBlockKind,
                text: String
            ) -> Bool {
                guard isStreaming,
                      currentKind == kind,
                      !currentText.isEmpty,
                      text.hasPrefix(currentText) else {
                    return false
                }
                return true
            }

            private static func attributedText(
                for kind: AskRenderableBlockKind,
                text: String,
                localLinkResolutionMode: ResultMarkdownRenderer.LocalLinkResolutionMode
            ) -> NSAttributedString {
                let markdownText: String
                switch kind {
                case .paragraph:
                    markdownText = text
                case .unorderedList, .orderedList, .quote:
                    markdownText = text
                case .codeBlock:
                    markdownText = text
                }
                return ResultMarkdownRenderer.assistantAttributedText(
                    text: markdownText,
                    localLinkResolutionMode: localLinkResolutionMode
                )
            }

            private static func streamingAttributedText(
                for kind: AskRenderableBlockKind,
                text: String
            ) -> NSAttributedString {
                let output = NSMutableAttributedString()
                switch kind {
                case .paragraph:
                    output.append(NSAttributedString(string: text, attributes: streamingParagraphAttributes()))
                case .unorderedList, .orderedList:
                    output.append(NSAttributedString(string: text, attributes: streamingListBodyAttributes()))
                case .quote:
                    output.append(NSAttributedString(string: text, attributes: streamingQuoteAttributes()))
                case .codeBlock:
                    output.append(NSAttributedString(string: text, attributes: streamingParagraphAttributes()))
                }
                return output
            }

            private static func streamingDeltaAttributedText(
                for kind: AskRenderableBlockKind,
                delta: String
            ) -> NSAttributedString {
                let attributes: [NSAttributedString.Key: Any]
                switch kind {
                case .paragraph:
                    attributes = streamingParagraphAttributes()
                case .unorderedList, .orderedList:
                    attributes = streamingListBodyAttributes()
                case .quote:
                    attributes = streamingQuoteAttributes()
                case .codeBlock:
                    attributes = streamingParagraphAttributes()
                }
                return NSAttributedString(string: delta, attributes: attributes)
            }

            private static func streamingParagraphAttributes() -> [NSAttributedString.Key: Any] {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                style.lineSpacing = 4
                style.paragraphSpacing = 12
                return [
                    .font: DesignTokens.ConversationPanel.Typography.body,
                    .foregroundColor: DesignTokens.ConversationPanel.Text.title,
                    .paragraphStyle: style
                ]
            }

            private static func streamingListPrefixAttributes() -> [NSAttributedString.Key: Any] {
                return [
                    .font: DesignTokens.ConversationPanel.Typography.body,
                    .foregroundColor: DesignTokens.ConversationPanel.Text.title,
                    .paragraphStyle: streamingListParagraphStyle()
                ]
            }

            private static func streamingListBodyAttributes() -> [NSAttributedString.Key: Any] {
                return [
                    .font: DesignTokens.ConversationPanel.Typography.body,
                    .foregroundColor: DesignTokens.ConversationPanel.Text.title,
                    .paragraphStyle: streamingListParagraphStyle()
                ]
            }

            private static func streamingQuoteAttributes() -> [NSAttributedString.Key: Any] {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                style.lineSpacing = 4
                style.paragraphSpacing = 12
                return [
                    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: DesignTokens.ConversationPanel.Text.meta,
                    .paragraphStyle: style
                ]
            }

            private static func streamingListParagraphStyle() -> NSMutableParagraphStyle {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                style.lineSpacing = 4
                style.paragraphSpacing = 10
                style.headIndent = 18
                return style
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }
        }

        private final class AssistantCodeBlockView: AssistantBlockView {
            private let codeTextView = InteractiveTranscriptTextView()
            private let headerLabel = NSTextField(labelWithString: "")
            private let headerDivider = NSView()
            private var currentCode = ""
            private var currentLanguage: String?
            private var isStreaming = false

            init(blockID: Int, code: String, language: String?, interactiveSelection: Bool) {
                super.init(blockID: blockID)
                wantsLayer = true
                layer?.cornerRadius = 14
                layer?.borderWidth = 1
                layer?.borderColor = DesignTokens.ConversationPanel.Surface.codeBorder.cgColor
                layer?.backgroundColor = DesignTokens.ConversationPanel.Surface.codeFill.cgColor

                headerLabel.translatesAutoresizingMaskIntoConstraints = false
                headerLabel.font = DesignTokens.ConversationPanel.Typography.inlineMono
                headerLabel.textColor = DesignTokens.ConversationPanel.Text.codeHeader
                headerDivider.translatesAutoresizingMaskIntoConstraints = false
                headerDivider.wantsLayer = true
                headerDivider.layer?.backgroundColor = DesignTokens.ConversationPanel.Surface.codeDivider.cgColor
                codeTextView.isSelectable = interactiveSelection

                let insetView = NSView()
                insetView.translatesAutoresizingMaskIntoConstraints = false
                addSubview(headerLabel)
                addSubview(headerDivider)
                addSubview(insetView)
                insetView.addSubview(codeTextView)

                NSLayoutConstraint.activate([
                    headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                    headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
                    headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),

                    headerDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
                    headerDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
                    headerDivider.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
                    headerDivider.heightAnchor.constraint(equalToConstant: 1),

                    insetView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                    insetView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                    insetView.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 10),
                    insetView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

                    codeTextView.leadingAnchor.constraint(equalTo: insetView.leadingAnchor),
                    codeTextView.trailingAnchor.constraint(equalTo: insetView.trailingAnchor),
                    codeTextView.topAnchor.constraint(equalTo: insetView.topAnchor),
                    codeTextView.bottomAnchor.constraint(equalTo: insetView.bottomAnchor)
                ])

                renderStatic(code: code, language: language)
            }

            convenience init(code: String, language: String?) {
                self.init(blockID: -1, code: code, language: language, interactiveSelection: true)
            }

            override func prepareLayoutWidth(_ width: CGFloat) {
                codeTextView.primeLayoutWidth(max(1, width - 24))
            }

            @discardableResult
            func renderStatic(
                code: String,
                language: String?
            ) -> Bool {
                let previousHeight = codeTextView.measuredContentHeight()
                currentCode = code
                currentLanguage = language
                isStreaming = false
                headerLabel.stringValue = (language?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? language!.uppercased()
                    : "CODE")

                codeTextView.setAttributedContent(
                    NSAttributedString(string: code, attributes: Self.codeAttributes())
                )
                codeTextView.setHighlightedSuffix(length: 0, alpha: 1)
                let updatedHeight = codeTextView.measuredContentHeight()
                return abs(updatedHeight - previousHeight) > 0.5
            }

            @discardableResult
            func renderStreaming(
                code: String,
                language: String?,
                highlightedSuffixLength: Int,
                highlightedAlpha: CGFloat
            ) -> Bool {
                let previousHeight = codeTextView.measuredContentHeight()
                headerLabel.stringValue = (language?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? language!.uppercased()
                    : "CODE")

                if isStreaming,
                   currentLanguage == language,
                   !currentCode.isEmpty,
                   code.hasPrefix(currentCode) {
                    let delta = String(code.dropFirst(currentCode.count))
                    if !delta.isEmpty {
                        codeTextView.appendAttributedContent(
                            NSAttributedString(string: delta, attributes: Self.codeAttributes()),
                            invalidateLayout: false
                        )
                    }
                } else {
                    codeTextView.setAttributedContent(
                        NSAttributedString(string: code, attributes: Self.codeAttributes()),
                        invalidateLayout: false
                    )
                }

                currentCode = code
                currentLanguage = language
                isStreaming = true
                codeTextView.setHighlightedSuffix(length: highlightedSuffixLength, alpha: highlightedAlpha)
                let updatedHeight = codeTextView.measuredContentHeight()
                if abs(updatedHeight - previousHeight) > 0.5 {
                    codeTextView.invalidateIntrinsicContentSize()
                }
                return abs(updatedHeight - previousHeight) > 0.5
            }

            func update(
                code: String,
                language: String?,
                highlightedSuffixLength: Int,
                highlightedAlpha: CGFloat
            ) {
                renderStatic(code: code, language: language)
                codeTextView.setHighlightedSuffix(length: highlightedSuffixLength, alpha: highlightedAlpha)
            }

            override func setHighlightedSuffix(length: Int, alpha: CGFloat) {
                codeTextView.setHighlightedSuffix(length: length, alpha: alpha)
            }

            var displayedContentLength: Int {
                (currentCode as NSString).length
            }

            var currentHighlightState: (length: Int, alpha: CGFloat) {
                codeTextView.currentHighlightState
            }

            private static func codeAttributes() -> [NSAttributedString.Key: Any] {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byWordWrapping
                style.lineSpacing = 3
                style.paragraphSpacing = 6
                return [
                    .font: DesignTokens.ConversationPanel.Typography.inlineMono,
                    .foregroundColor: DesignTokens.ConversationPanel.Text.title,
                    .paragraphStyle: style
                ]
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }
        }

        private final class AssistantMessageBlockContainerView: NSView {
            private let stackView = NSStackView()
            private var blockViewsByID: [Int: AssistantBlockView] = [:]
            private var widthConstraintsByBlockID: [Int: NSLayoutConstraint] = [:]
            private var orderedBlockIDs: [Int] = []
            private var assembler = AskTranscriptStreamAssembler()
            private var cachedStableBlockWidth: CGFloat = 0

            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                translatesAutoresizingMaskIntoConstraints = false

                stackView.translatesAutoresizingMaskIntoConstraints = false
                stackView.orientation = .vertical
                stackView.alignment = .leading
                stackView.spacing = 10

                addSubview(stackView)
                NSLayoutConstraint.activate([
                    stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
                    stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
                    stackView.topAnchor.constraint(equalTo: topAnchor),
                    stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
                ])
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            var renderedFullTextLength: Int {
                assembler.state.fullText.count
            }

            func renderMessage(
                _ text: String,
                finalizeFormatting: Bool,
                localLinkResolutionMode: ResultMarkdownRenderer.LocalLinkResolutionMode
            ) {
                let patch = assembler.replaceAll(
                    with: text,
                    highlightedSuffixLength: 0,
                    finalize: finalizeFormatting
                )
                apply(
                    patch,
                    highlightedAlpha: 1,
                    localLinkResolutionMode: localLinkResolutionMode
                )
            }

            func renderStaticMessage(_ text: String) {
                renderMessage(
                    text,
                    finalizeFormatting: true,
                    localLinkResolutionMode: .synchronousFull
                )
            }

            @discardableResult
            func applyStreamingUpdate(
                fullText: String,
                appendedChunk: String,
                highlightedSuffixLength: Int,
                highlightedAlpha: CGFloat,
                finalizeFormatting: Bool
            ) -> Bool {
                let patch = assembler.apply(
                    appendedChunk: appendedChunk,
                    fullText: fullText,
                    highlightedSuffixLength: highlightedSuffixLength,
                    finalize: finalizeFormatting
                )
                return apply(
                    patch,
                    highlightedAlpha: highlightedAlpha,
                    localLinkResolutionMode: finalizeFormatting ? .cachedOnly : .cachedOnly
                )
            }

            @discardableResult
            private func apply(
                _ patch: AskRenderPatch,
                highlightedAlpha: CGFloat,
                localLinkResolutionMode: ResultMarkdownRenderer.LocalLinkResolutionMode
            ) -> Bool {
                if patch.reset {
                    rebuild(with: patch.state, localLinkResolutionMode: localLinkResolutionMode)
                    return true
                }

                var needsViewportRefresh = false
                for block in patch.appendedBlocks {
                    needsViewportRefresh = upsertBlock(
                        block,
                        highlightedSuffixLength: 0,
                        localLinkResolutionMode: localLinkResolutionMode
                    ) || needsViewportRefresh
                }
                needsViewportRefresh = updateTail(patch.state.tailBlock, highlightedAlpha: highlightedAlpha) || needsViewportRefresh
                needsViewportRefresh = synchronizeOrder(with: patch.state) || needsViewportRefresh
                return needsViewportRefresh
            }

            private func rebuild(
                with state: AskAssistantRenderState,
                localLinkResolutionMode: ResultMarkdownRenderer.LocalLinkResolutionMode
            ) {
                blockViewsByID.removeAll(keepingCapacity: true)
                widthConstraintsByBlockID.values.forEach { $0.isActive = false }
                widthConstraintsByBlockID.removeAll(keepingCapacity: true)
                orderedBlockIDs.removeAll(keepingCapacity: true)
                stackView.arrangedSubviews.forEach {
                    stackView.removeArrangedSubview($0)
                    $0.removeFromSuperview()
                }

                for block in state.committedBlocks {
                    upsertBlock(
                        block,
                        highlightedSuffixLength: 0,
                        localLinkResolutionMode: localLinkResolutionMode
                    )
                }
                updateTail(state.tailBlock, highlightedAlpha: 1)
                synchronizeOrder(with: state)
            }

            @discardableResult
            private func upsertBlock(
                _ block: AskRenderableBlock,
                highlightedSuffixLength: Int,
                localLinkResolutionMode: ResultMarkdownRenderer.LocalLinkResolutionMode
            ) -> Bool {
                let view = ensureView(
                    blockID: block.id,
                    kind: block.kind,
                    text: block.text,
                    isStreamingTail: false
                )
                let heightChanged = update(
                    view: view,
                    kind: block.kind,
                    text: block.text,
                    highlightedSuffixLength: highlightedSuffixLength,
                    highlightedAlpha: 1,
                    isStreamingTail: false,
                    localLinkResolutionMode: localLinkResolutionMode
                )
                return heightChanged
            }

            @discardableResult
            private func updateTail(
                _ tailBlock: AskMutableTailBlock?,
                highlightedAlpha: CGFloat
            ) -> Bool {
                guard let tailBlock else {
                    return false
                }

                let view = ensureView(
                    blockID: tailBlock.id,
                    kind: tailBlock.kind,
                    text: tailBlock.text,
                    isStreamingTail: true
                )
                let heightChanged = update(
                    view: view,
                    kind: tailBlock.kind,
                    text: tailBlock.text,
                    highlightedSuffixLength: tailBlock.highlightedSuffixLength,
                    highlightedAlpha: highlightedAlpha,
                    isStreamingTail: true
                )
                return heightChanged
            }

            func setStreamingHighlight(length: Int, alpha: CGFloat) {
                guard let tailBlock = assembler.state.tailBlock,
                      let view = blockViewsByID[tailBlock.id] else {
                    return
                }
                view.setHighlightedSuffix(length: length, alpha: alpha)
            }

            var currentStreamingHighlightState: (length: Int, alpha: CGFloat) {
                guard let tailBlock = assembler.state.tailBlock,
                      let view = blockViewsByID[tailBlock.id] else {
                    return (0, 1)
                }

                switch view {
                case let textView as AssistantTextBlockView:
                    return textView.currentHighlightState
                case let codeView as AssistantCodeBlockView:
                    return codeView.currentHighlightState
                default:
                    return (0, 1)
                }
            }

            @discardableResult
            private func synchronizeOrder(with state: AskAssistantRenderState) -> Bool {
                let desiredIDs = state.committedBlocks.map(\.id) + [state.tailBlock?.id].compactMap { $0 }
                guard desiredIDs != orderedBlockIDs else { return false }
                orderedBlockIDs = desiredIDs

                let desiredViews = desiredIDs.compactMap { blockViewsByID[$0] }
                let currentViews = stackView.arrangedSubviews.compactMap { $0 as? AssistantBlockView }
                for (index, view) in desiredViews.enumerated() {
                    if index < currentViews.count, currentViews[index] === view {
                        continue
                    }
                    if stackView.arrangedSubviews.contains(view) {
                        stackView.removeArrangedSubview(view)
                    }
                    attach(view, at: index)
                }

                let desiredIDSet = Set(desiredIDs)
                for view in currentViews where !desiredIDSet.contains(view.blockID) {
                    stackView.removeArrangedSubview(view)
                    view.removeFromSuperview()
                    blockViewsByID.removeValue(forKey: view.blockID)
                    widthConstraintsByBlockID[view.blockID]?.isActive = false
                    widthConstraintsByBlockID.removeValue(forKey: view.blockID)
                }
                return true
            }

            private func makeView(for block: AskRenderableBlock, isStreamingTail: Bool) -> AssistantBlockView {
                let view: AssistantBlockView
                switch block.kind {
                case .codeBlock(let language):
                    view = AssistantCodeBlockView(
                        blockID: block.id,
                        code: block.text,
                        language: language,
                        interactiveSelection: true
                    )
                default:
                    view = AssistantTextBlockView(
                        blockID: block.id,
                        interactiveLinks: true
                    )
                }
                return view
            }

            private func ensureView(
                blockID: Int,
                kind: AskRenderableBlockKind,
                text: String,
                isStreamingTail: Bool
            ) -> AssistantBlockView {
                if let existing = blockViewsByID[blockID],
                   isCompatible(existing, with: kind, isStreamingTail: isStreamingTail) {
                    return existing
                }

                let replacement = makeView(
                    for: AskRenderableBlock(id: blockID, kind: kind, text: text),
                    isStreamingTail: isStreamingTail
                )
                if let existing = blockViewsByID[blockID] {
                    replace(existing, with: replacement)
                }
                blockViewsByID[blockID] = replacement
                return replacement
            }

            private func isCompatible(
                _ view: AssistantBlockView,
                with kind: AskRenderableBlockKind,
                isStreamingTail: Bool
            ) -> Bool {
                _ = isStreamingTail
                switch kind {
                case .codeBlock:
                    return view is AssistantCodeBlockView
                default:
                    return view is AssistantTextBlockView
                }
            }

            private func replace(_ existing: AssistantBlockView, with replacement: AssistantBlockView) {
                let existingIndex = stackView.arrangedSubviews.firstIndex(of: existing)
                if stackView.arrangedSubviews.contains(existing) {
                    stackView.removeArrangedSubview(existing)
                }
                existing.removeFromSuperview()
                widthConstraintsByBlockID[existing.blockID]?.isActive = false
                widthConstraintsByBlockID.removeValue(forKey: existing.blockID)
                if let existingIndex {
                    attach(replacement, at: existingIndex)
                }
            }

            private func attach(_ view: AssistantBlockView, at index: Int) {
                if stackView.arrangedSubviews.contains(view) {
                    if stackView.arrangedSubviews.firstIndex(of: view) != index {
                        stackView.removeArrangedSubview(view)
                        stackView.insertArrangedSubview(view, at: index)
                    }
                } else {
                    stackView.insertArrangedSubview(view, at: index)
                }

                if widthConstraintsByBlockID[view.blockID] == nil {
                    let constraint = view.widthAnchor.constraint(equalTo: stackView.widthAnchor)
                    constraint.isActive = true
                    widthConstraintsByBlockID[view.blockID] = constraint
                }

                stabilizeLayoutWidth(for: view)
            }

            @discardableResult
            private func update(
                view: AssistantBlockView,
                kind: AskRenderableBlockKind,
                text: String,
                highlightedSuffixLength: Int,
                highlightedAlpha: CGFloat,
                isStreamingTail: Bool,
                localLinkResolutionMode: ResultMarkdownRenderer.LocalLinkResolutionMode = .cachedOnly
            ) -> Bool {
                stabilizeLayoutWidth(for: view)
                switch kind {
                case .codeBlock(let language):
                    guard let codeView = view as? AssistantCodeBlockView else { return false }
                    if isStreamingTail {
                        let heightChanged = codeView.renderStreaming(
                            code: text,
                            language: language,
                            highlightedSuffixLength: highlightedSuffixLength,
                            highlightedAlpha: highlightedAlpha
                        )
                        return heightChanged
                    } else {
                        return codeView.renderStatic(code: text, language: language)
                    }
                default:
                    guard let textView = view as? AssistantTextBlockView else { return false }
                    if isStreamingTail {
                        return textView.renderStreaming(
                            kind: kind,
                            text: text,
                            highlightedSuffixLength: highlightedSuffixLength,
                            highlightedAlpha: highlightedAlpha
                        )
                    } else {
                        return textView.renderStatic(
                            kind: kind,
                            text: text,
                            localLinkResolutionMode: localLinkResolutionMode
                        )
                    }
                }
            }

            private func stabilizeLayoutWidth(for view: AssistantBlockView) {
                let width = resolvedBlockWidth()
                if width > 1 {
                    let normalized = floor(width)
                    cachedStableBlockWidth = normalized
                    view.prepareLayoutWidth(normalized)
                    return
                }
                guard cachedStableBlockWidth > 1 else { return }
                view.prepareLayoutWidth(cachedStableBlockWidth)
            }

            private func resolvedBlockWidth() -> CGFloat {
                let candidates: [CGFloat] = [
                    stackView.fittingSize.width,
                    stackView.bounds.width,
                    stackView.frame.width,
                    bounds.width,
                    frame.width,
                    superview?.bounds.width ?? 0
                ]
                return candidates.max() ?? 0
            }
        }

        private enum AssistantSegment: Equatable {
            case richText(String)
            case code(language: String?, content: String)
        }

        private let bodyLabel = InteractiveTranscriptTextView()
        private let assistantBlockContainer = AssistantMessageBlockContainerView()
        private let assistantContentStack = NSStackView()
        private let assistantMessageStack = NSStackView()
        private let actionCardStack = NSStackView()
        private let userLabel = NSTextField(wrappingLabelWithString: "")
        private let citationStack = NSStackView()
        private let role: AskMessageRole
        private let userBubbleContainer = BubbleContainerView()
        private var bodyBottomConstraint: NSLayoutConstraint?
        private var citationBottomConstraint: NSLayoutConstraint?
        private var renderedAssistantContent = ""
        private var renderedAssistantSegments: [AssistantSegment] = []
        var onCitationTapped: ((SkillResultCard, NSView) -> Void)?
        var onActionCardTapped: ((SkillResultCard) -> Void)?

        init(message: AskMessage, citations: [SkillResultCard]) {
            self.role = message.role
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            citationStack.translatesAutoresizingMaskIntoConstraints = false
            citationStack.orientation = .horizontal
            citationStack.alignment = .leading
            citationStack.spacing = 6
            citationStack.isHidden = true
            assistantContentStack.translatesAutoresizingMaskIntoConstraints = false
            assistantContentStack.orientation = .vertical
            assistantContentStack.alignment = .leading
            assistantContentStack.spacing = 10
            assistantMessageStack.translatesAutoresizingMaskIntoConstraints = false
            assistantMessageStack.orientation = .vertical
            assistantMessageStack.alignment = .leading
            assistantMessageStack.spacing = 10
            actionCardStack.translatesAutoresizingMaskIntoConstraints = false
            actionCardStack.orientation = .vertical
            actionCardStack.alignment = .leading
            actionCardStack.spacing = 8
            actionCardStack.isHidden = true
            userLabel.translatesAutoresizingMaskIntoConstraints = false
            userLabel.font = DesignTokens.ConversationPanel.Typography.body
            userLabel.textColor = DesignTokens.ConversationPanel.Text.title
            userLabel.maximumNumberOfLines = 0
            userLabel.lineBreakMode = .byWordWrapping
            userLabel.isSelectable = true
            userLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            userLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            if message.role == .user {
                userBubbleContainer.addSubview(userLabel)
                addSubview(userBubbleContainer)

                NSLayoutConstraint.activate([
                    userBubbleContainer.topAnchor.constraint(equalTo: topAnchor),
                    userBubbleContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
                    userBubbleContainer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 48),
                    userLabel.leadingAnchor.constraint(equalTo: userBubbleContainer.leadingAnchor, constant: 14),
                    userLabel.trailingAnchor.constraint(equalTo: userBubbleContainer.trailingAnchor, constant: -14),
                    userLabel.topAnchor.constraint(equalTo: userBubbleContainer.topAnchor, constant: 10),
                    userLabel.bottomAnchor.constraint(equalTo: userBubbleContainer.bottomAnchor, constant: -10),
                    userBubbleContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
                    userBubbleContainer.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.78)
                ])
            } else if message.role != .assistant {
                addSubview(bodyLabel)
                let roleLabel = NSTextField(labelWithString: Self.roleTitle(for: message.role))
                roleLabel.font = DesignTokens.Typography.resultPanelRole
                roleLabel.textColor = Self.roleColor(for: message.role)
                roleLabel.isSelectable = false
                roleLabel.translatesAutoresizingMaskIntoConstraints = false
                addSubview(roleLabel)

                NSLayoutConstraint.activate([
                    roleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                    roleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                    roleLabel.topAnchor.constraint(equalTo: topAnchor),

                    bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                    bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
                    bodyLabel.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: DesignTokens.ResultPanel.messageRoleSpacing),
                ])
                bodyBottomConstraint = bodyLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
                bodyBottomConstraint?.isActive = true
            } else {
                assistantMessageStack.addArrangedSubview(assistantBlockContainer)
                assistantContentStack.addArrangedSubview(assistantMessageStack)
                assistantContentStack.addArrangedSubview(actionCardStack)
                addSubview(assistantContentStack)
                addSubview(citationStack)
                NSLayoutConstraint.activate([
                    assistantContentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
                    assistantContentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
                    assistantContentStack.topAnchor.constraint(equalTo: topAnchor),
                    citationStack.leadingAnchor.constraint(equalTo: leadingAnchor),
                    citationStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                    citationStack.topAnchor.constraint(equalTo: assistantContentStack.bottomAnchor, constant: 8)
                ])
                assistantMessageStack.widthAnchor.constraint(equalTo: assistantContentStack.widthAnchor).isActive = true
                assistantBlockContainer.widthAnchor.constraint(equalTo: assistantMessageStack.widthAnchor).isActive = true
                actionCardStack.widthAnchor.constraint(equalTo: assistantContentStack.widthAnchor).isActive = true
                bodyBottomConstraint = assistantContentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
                citationBottomConstraint = citationStack.bottomAnchor.constraint(equalTo: bottomAnchor)
                bodyBottomConstraint?.isActive = true
            }

            update(message: message, citations: citations)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        var renderedAssistantFullTextLength: Int {
            guard role == .assistant else { return 0 }
            return assistantBlockContainer.renderedFullTextLength
        }

        func update(
            message: AskMessage,
            citations: [SkillResultCard] = [],
            highlightedSuffixLength: Int = 0,
            highlightedAlpha: CGFloat = 1
        ) {
            if role == .user {
                userLabel.stringValue = message.content
            } else {
            if role == .assistant {
                renderedAssistantContent = message.content
                renderedAssistantSegments.removeAll(keepingCapacity: false)
                assistantBlockContainer.renderMessage(
                    message.content,
                    finalizeFormatting: true,
                    localLinkResolutionMode: .synchronousFull
                )
                } else {
                    bodyLabel.setAttributedContent(AskMarkdownRenderer.attributedText(
                        for: message.content,
                        role: role,
                        highlightedSuffixLength: highlightedSuffixLength,
                        highlightedAlpha: highlightedAlpha
                    ))
                    bodyLabel.setHighlightedSuffix(length: highlightedSuffixLength, alpha: highlightedAlpha)
                }
            }

            if role == .assistant {
                renderAssistantCards(citations)
            }
        }

        @discardableResult
        func updateStreamingAssistant(
            fullText: String,
            appendedChunk: String,
            citations: [SkillResultCard],
            highlightedSuffixLength: Int,
            highlightedAlpha: CGFloat,
            finalizeFormatting: Bool
        ) -> Bool {
            guard role == .assistant else {
                update(
                    message: AskMessage(role: role, content: fullText),
                    citations: citations,
                    highlightedSuffixLength: highlightedSuffixLength,
                    highlightedAlpha: highlightedAlpha
                )
                return true
            }

            let previousRenderedAssistantContent = renderedAssistantContent
            let shouldRebuildStreamingBuffer = previousRenderedAssistantContent.isEmpty
                || !fullText.hasPrefix(previousRenderedAssistantContent)
            renderedAssistantContent = fullText
            if shouldRebuildStreamingBuffer {
                if !previousRenderedAssistantContent.isEmpty {
                    DiagnosticsLogger.shared.log(
                        "ask.render",
                        "assistant_row_reset full_chars=\(fullText.count) appended_chars=\(appendedChunk.count) finalize=\(finalizeFormatting)"
                    )
                }
                assistantBlockContainer.renderMessage(
                    fullText,
                    finalizeFormatting: finalizeFormatting,
                    localLinkResolutionMode: finalizeFormatting ? .cachedOnly : .cachedOnly
                )
                assistantBlockContainer.setStreamingHighlight(length: highlightedSuffixLength, alpha: highlightedAlpha)
                renderAssistantCards(citations)
                return true
            } else {
                let viewportNeedsRefresh = assistantBlockContainer.applyStreamingUpdate(
                    fullText: fullText,
                    appendedChunk: appendedChunk,
                    highlightedSuffixLength: highlightedSuffixLength,
                    highlightedAlpha: highlightedAlpha,
                    finalizeFormatting: finalizeFormatting
                )
                renderAssistantCards(citations)
                return viewportNeedsRefresh
            }
        }

        func updateStreamingHighlight(length: Int, alpha: CGFloat) {
            guard role == .assistant else { return }
            assistantBlockContainer.setStreamingHighlight(length: length, alpha: alpha)
        }

        var currentStreamingHighlightState: (length: Int, alpha: CGFloat) {
            guard role == .assistant else { return (0, 1) }
            return assistantBlockContainer.currentStreamingHighlightState
        }

        private func renderAssistantContent(
            text: String,
            highlightedSuffixLength: Int,
            highlightedAlpha: CGFloat,
            finalizeFormatting: Bool
        ) {
            let segments = assistantSegments(from: text)
            let hasCodeBlock = segments.contains { segment in
                if case .code = segment { return true }
                return false
            }

            if !hasCodeBlock {
                renderedAssistantSegments.removeAll(keepingCapacity: false)
                ensureAssistantStreamingView()
                let useStructuredStreamingRender = finalizeFormatting
                    || AskMarkdownRenderer.prefersStructuredStreamingRendering(for: text)
                let attributed = useStructuredStreamingRender
                    ? AskMarkdownRenderer.attributedText(
                        for: text,
                        role: .assistant,
                        highlightedSuffixLength: highlightedSuffixLength,
                        highlightedAlpha: highlightedAlpha
                    )
                    : AskMarkdownRenderer.streamingAssistantAttributedText(
                        text,
                        highlightedSuffixLength: highlightedSuffixLength,
                        highlightedAlpha: highlightedAlpha
                    )
                bodyLabel.setAttributedContent(attributed)
                bodyLabel.setHighlightedSuffix(length: highlightedSuffixLength, alpha: highlightedAlpha)
                return
            }

            renderSegmentedAssistantContent(
                segments: segments,
                highlightedSuffixLength: highlightedSuffixLength,
                highlightedAlpha: highlightedAlpha,
                finalizeFormatting: finalizeFormatting
            )
        }

        private func renderSegmentedAssistantContent(
            segments: [AssistantSegment],
            highlightedSuffixLength: Int,
            highlightedAlpha: CGFloat,
            finalizeFormatting: Bool
        ) {
            let sanitizedSegments = segments.compactMap { sanitizedSegment($0) }
            guard !sanitizedSegments.isEmpty else {
                renderedAssistantSegments.removeAll(keepingCapacity: false)
                ensureAssistantStreamingView()
                bodyLabel.setAttributedContent(NSAttributedString(string: ""))
                bodyLabel.setHighlightedSuffix(length: 0, alpha: 1)
                return
            }

            guard assistantMessageStack.arrangedSubviews.count == renderedAssistantSegments.count else {
                rebuildAssistantSegmentViews(
                    sanitizedSegments,
                    highlightedSuffixLength: highlightedSuffixLength,
                    highlightedAlpha: highlightedAlpha,
                    finalizeFormatting: finalizeFormatting
                )
                return
            }

            if sanitizedSegments == renderedAssistantSegments {
                applyHighlightToAssistantSegments(
                    highlightedSuffixLength: highlightedSuffixLength,
                    highlightedAlpha: highlightedAlpha
                )
                return
            }

            let oldSegments = renderedAssistantSegments
            let diffIndex = firstDifferingAssistantSegmentIndex(oldSegments, sanitizedSegments) ?? min(oldSegments.count, sanitizedSegments.count)
            let canIncrementallyUpdateTail =
                diffIndex < oldSegments.count &&
                diffIndex < sanitizedSegments.count &&
                assistantSegmentsShareKindAndPrefix(oldSegments[diffIndex], sanitizedSegments[diffIndex]) &&
                sanitizedSegments.count >= oldSegments.count &&
                oldSegments.dropFirst(diffIndex + 1).elementsEqual(sanitizedSegments.dropFirst(diffIndex + 1).prefix(oldSegments.count - diffIndex - 1))

            if canIncrementallyUpdateTail {
                updateAssistantSegmentView(
                    assistantMessageStack.arrangedSubviews[diffIndex],
                    with: sanitizedSegments[diffIndex],
                    isLastSegment: diffIndex == sanitizedSegments.count - 1,
                    highlightedSuffixLength: diffIndex == sanitizedSegments.count - 1 ? highlightedSuffixLength : 0,
                    highlightedAlpha: diffIndex == sanitizedSegments.count - 1 ? highlightedAlpha : 1,
                    finalizeFormatting: finalizeFormatting
                )
                if sanitizedSegments.count > oldSegments.count {
                    for segmentIndex in oldSegments.count..<sanitizedSegments.count {
                        appendAssistantSegmentView(
                            sanitizedSegments[segmentIndex],
                            isLastSegment: segmentIndex == sanitizedSegments.count - 1,
                            highlightedSuffixLength: segmentIndex == sanitizedSegments.count - 1 ? highlightedSuffixLength : 0,
                            highlightedAlpha: segmentIndex == sanitizedSegments.count - 1 ? highlightedAlpha : 1,
                            finalizeFormatting: finalizeFormatting
                        )
                    }
                }
                renderedAssistantSegments = sanitizedSegments
                applyHighlightToAssistantSegments(
                    highlightedSuffixLength: highlightedSuffixLength,
                    highlightedAlpha: highlightedAlpha
                )
                return
            }

            while assistantMessageStack.arrangedSubviews.count > diffIndex {
                guard let last = assistantMessageStack.arrangedSubviews.last else { break }
                assistantMessageStack.removeArrangedSubview(last)
                last.removeFromSuperview()
            }
            for segmentIndex in diffIndex..<sanitizedSegments.count {
                appendAssistantSegmentView(
                    sanitizedSegments[segmentIndex],
                    isLastSegment: segmentIndex == sanitizedSegments.count - 1,
                    highlightedSuffixLength: segmentIndex == sanitizedSegments.count - 1 ? highlightedSuffixLength : 0,
                    highlightedAlpha: segmentIndex == sanitizedSegments.count - 1 ? highlightedAlpha : 1,
                    finalizeFormatting: finalizeFormatting
                )
            }
            renderedAssistantSegments = sanitizedSegments
            applyHighlightToAssistantSegments(
                highlightedSuffixLength: highlightedSuffixLength,
                highlightedAlpha: highlightedAlpha
            )
        }

        private func rebuildAssistantSegmentViews(
            _ segments: [AssistantSegment],
            highlightedSuffixLength: Int,
            highlightedAlpha: CGFloat,
            finalizeFormatting: Bool
        ) {
            assistantMessageStack.arrangedSubviews.forEach {
                assistantMessageStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }

            for (index, segment) in segments.enumerated() {
                appendAssistantSegmentView(
                    segment,
                    isLastSegment: index == segments.count - 1,
                    highlightedSuffixLength: index == segments.count - 1 ? highlightedSuffixLength : 0,
                    highlightedAlpha: index == segments.count - 1 ? highlightedAlpha : 1,
                    finalizeFormatting: finalizeFormatting
                )
            }
            renderedAssistantSegments = segments
        }

        private func appendAssistantSegmentView(
            _ segment: AssistantSegment,
            isLastSegment: Bool,
            highlightedSuffixLength: Int,
            highlightedAlpha: CGFloat,
            finalizeFormatting: Bool
        ) {
            let view: NSView
            switch segment {
            case .richText:
                let textView = InteractiveTranscriptTextView()
                updateAssistantSegmentView(
                    textView,
                    with: segment,
                    isLastSegment: isLastSegment,
                    highlightedSuffixLength: highlightedSuffixLength,
                    highlightedAlpha: highlightedAlpha,
                    finalizeFormatting: finalizeFormatting
                )
                view = textView
            case .code:
                let codeView = AssistantCodeBlockView(code: "", language: nil)
                updateAssistantSegmentView(
                    codeView,
                    with: segment,
                    isLastSegment: isLastSegment,
                    highlightedSuffixLength: highlightedSuffixLength,
                    highlightedAlpha: highlightedAlpha,
                    finalizeFormatting: finalizeFormatting
                )
                view = codeView
            }
            assistantMessageStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: assistantMessageStack.widthAnchor).isActive = true
        }

        private func updateAssistantSegmentView(
            _ view: NSView,
            with segment: AssistantSegment,
            isLastSegment: Bool,
            highlightedSuffixLength: Int,
            highlightedAlpha: CGFloat,
            finalizeFormatting: Bool
        ) {
            switch segment {
            case .richText(let richText):
                guard let textView = view as? InteractiveTranscriptTextView else { return }
                let useStructuredStreamingRender = finalizeFormatting
                    || AskMarkdownRenderer.prefersStructuredStreamingRendering(for: richText)
                let attributed = useStructuredStreamingRender
                    ? AskMarkdownRenderer.attributedText(
                        for: richText,
                        role: .assistant,
                        highlightedSuffixLength: isLastSegment ? highlightedSuffixLength : 0,
                        highlightedAlpha: isLastSegment ? highlightedAlpha : 1
                    )
                    : AskMarkdownRenderer.streamingAssistantAttributedText(
                        richText,
                        highlightedSuffixLength: isLastSegment ? highlightedSuffixLength : 0,
                        highlightedAlpha: isLastSegment ? highlightedAlpha : 1
                    )
                textView.setAttributedContent(attributed)
                textView.setHighlightedSuffix(length: isLastSegment ? highlightedSuffixLength : 0, alpha: isLastSegment ? highlightedAlpha : 1)
            case .code(let language, let code):
                guard let codeView = view as? AssistantCodeBlockView else { return }
                codeView.update(
                    code: code,
                    language: language,
                    highlightedSuffixLength: isLastSegment ? highlightedSuffixLength : 0,
                    highlightedAlpha: isLastSegment ? highlightedAlpha : 1
                )
            }
        }

        private func applyHighlightToAssistantSegments(
            highlightedSuffixLength: Int,
            highlightedAlpha: CGFloat
        ) {
            for (index, view) in assistantMessageStack.arrangedSubviews.enumerated() {
                let isLastSegment = index == assistantMessageStack.arrangedSubviews.count - 1
                let length = isLastSegment ? highlightedSuffixLength : 0
                if let textView = view as? InteractiveTranscriptTextView {
                    textView.setHighlightedSuffix(length: length, alpha: isLastSegment ? highlightedAlpha : 1)
                } else if let codeView = view as? AssistantCodeBlockView {
                    let codeLength = min(length, codeView.displayedContentLength)
                    codeView.setHighlightedSuffix(length: codeLength, alpha: isLastSegment ? highlightedAlpha : 1)
                }
            }
        }

        private func sanitizedSegment(_ segment: AssistantSegment) -> AssistantSegment? {
            switch segment {
            case .richText(let richText):
                let trimmed = richText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return .richText(trimmed)
            case .code(let language, let code):
                let trimmed = code.trimmingCharacters(in: .newlines)
                guard !trimmed.isEmpty else { return nil }
                return .code(language: language, content: trimmed)
            }
        }

        private func firstDifferingAssistantSegmentIndex(
            _ oldSegments: [AssistantSegment],
            _ newSegments: [AssistantSegment]
        ) -> Int? {
            let sharedCount = min(oldSegments.count, newSegments.count)
            for index in 0..<sharedCount where oldSegments[index] != newSegments[index] {
                return index
            }
            if oldSegments.count != newSegments.count {
                return sharedCount
            }
            return nil
        }

        private func assistantSegmentsShareKindAndPrefix(_ lhs: AssistantSegment, _ rhs: AssistantSegment) -> Bool {
            switch (lhs, rhs) {
            case let (.richText(old), .richText(new)):
                return new.hasPrefix(old)
            case let (.code(oldLanguage, old), .code(newLanguage, new)):
                return oldLanguage == newLanguage && new.hasPrefix(old)
            default:
                return false
            }
        }

        private func ensureAssistantStreamingView() {
            if assistantMessageStack.arrangedSubviews.count == 1,
               assistantMessageStack.arrangedSubviews.first === bodyLabel {
                return
            }
            assistantMessageStack.arrangedSubviews.forEach {
                assistantMessageStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            renderedAssistantSegments.removeAll(keepingCapacity: false)
            assistantMessageStack.addArrangedSubview(bodyLabel)
        }

        private func assistantSegments(from text: String) -> [AssistantSegment] {
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            let lines = normalized.components(separatedBy: .newlines)
            var segments: [AssistantSegment] = []
            var textBuffer: [String] = []
            var codeBuffer: [String] = []
            var codeFenceLanguage: String?
            var inCodeBlock = false

            func flushText() {
                guard !textBuffer.isEmpty else { return }
                segments.append(.richText(textBuffer.joined(separator: "\n")))
                textBuffer.removeAll(keepingCapacity: true)
            }

            func flushCode() {
                guard !codeBuffer.isEmpty else { return }
                segments.append(.code(language: codeFenceLanguage, content: codeBuffer.joined(separator: "\n")))
                codeBuffer.removeAll(keepingCapacity: true)
            }

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("```") {
                    if inCodeBlock {
                        flushCode()
                        codeFenceLanguage = nil
                    } else {
                        flushText()
                        let languageHint = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                        codeFenceLanguage = languageHint.isEmpty ? nil : languageHint
                    }
                    inCodeBlock.toggle()
                    continue
                }

                if inCodeBlock {
                    codeBuffer.append(line)
                } else {
                    textBuffer.append(line)
                }
            }

            if inCodeBlock {
                textBuffer.append("```")
                textBuffer.append(contentsOf: codeBuffer)
            } else {
                flushCode()
            }
            flushText()
            return segments
        }

        private static func roleTitle(for role: AskMessageRole) -> String {
            switch role {
            case .system:
                return L10n.text(zhHans: "系统", en: "System")
            case .user:
                return L10n.text(zhHans: "你", en: "You")
            case .assistant:
                return L10n.text(zhHans: "AI", en: "AI")
            case .info:
                return L10n.text(zhHans: "状态", en: "Status")
            }
        }

        private static func roleColor(for role: AskMessageRole) -> NSColor {
            switch role {
            case .system:
                return DesignTokens.Semantic.ResultPanel.Role.systemText
            case .info:
                return DesignTokens.Color.linkBlue
            case .user:
                return DesignTokens.Semantic.ResultPanel.Role.userText
            case .assistant:
                return DesignTokens.Semantic.ResultPanel.Role.assistantText
            }
        }

        private func renderAssistantCards(_ cards: [SkillResultCard]) {
            let actionCards = Array(cards.filter { $0.action != nil }.prefix(2))
            let citationCards = Array(cards.filter { $0.action == nil }.prefix(3))
            renderActionCards(actionCards)
            renderCitationButtons(citationCards)
        }

        private func renderActionCards(_ cards: [SkillResultCard]) {
            actionCardStack.arrangedSubviews.forEach {
                actionCardStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            guard !cards.isEmpty else {
                actionCardStack.isHidden = true
                return
            }

            for (index, card) in cards.enumerated() {
                let cardView = AssistantActionCardView(card: card, isPrimary: index == 0)
                cardView.onAction = { [weak self] in
                    self?.onActionCardTapped?(card)
                }
                actionCardStack.addArrangedSubview(cardView)
                cardView.widthAnchor.constraint(equalTo: actionCardStack.widthAnchor).isActive = true
            }
            actionCardStack.isHidden = false
        }

        private func renderCitationButtons(_ citations: [SkillResultCard]) {
            citationStack.arrangedSubviews.forEach {
                citationStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            let visibleCitations = citations.prefix(3)
            guard !visibleCitations.isEmpty else {
                citationStack.isHidden = true
                citationBottomConstraint?.isActive = false
                bodyBottomConstraint?.isActive = true
                return
            }

            for (index, card) in visibleCitations.enumerated() {
                let button = CitationButton(card: card, index: index)
                button.target = self
                button.action = #selector(handleCitationButton(_:))
                citationStack.addArrangedSubview(button)
            }
            citationStack.isHidden = false
            bodyBottomConstraint?.isActive = false
            citationBottomConstraint?.isActive = true
        }

        @objc private func handleCitationButton(_ sender: CitationButton) {
            onCitationTapped?(sender.card, sender)
        }
    }

    private final class TranscriptRuntimeStepRowView: NSView {
        private static let codePreviewVisibleLineCount: CGFloat = 2
        private static let codePreviewHorizontalInset: CGFloat = 12
        private static let codePreviewVerticalInset: CGFloat = 10
        private static let codePreviewLineSpacing: CGFloat = 3

        private var titleLabel: ShimmeringStatusLabel
        private let surfaceView = NSView()
        private let titleRow = NSStackView()
        private let bodyStack = NSStackView()
        private let detailLabel = NSTextField(wrappingLabelWithString: "")
        private let codePreviewContainer = NSView()
        private let codeHeaderLabel = NSTextField(labelWithString: "")
        private let codeHeaderDivider = NSView()
        private let codeScrollView = NSScrollView()
        private let codeTextView = NSTextView(frame: .zero)
        private var codeHeightConstraint: NSLayoutConstraint?

        init(step: AskRuntimeStepEvent) {
            self.titleLabel = ShimmeringStatusLabel(
                text: step.title,
                isShimmering: step.state == .running || step.state == .waiting,
                baseColor: Self.titleColor(for: step.state)
            )
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            buildUI()
            update(step: step)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            guard codePreviewContainer.isHidden == false else { return }
            updateCodePreviewLayout(scrollToBottom: false)
        }

        func update(step: AskRuntimeStepEvent) {
            let refreshedTitle = ShimmeringStatusLabel(
                text: step.title,
                isShimmering: step.state == .running || step.state == .waiting,
                baseColor: Self.titleColor(for: step.state)
            )
            refreshedTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            refreshedTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
            titleLabel.removeFromSuperview()
            titleRow.insertArrangedSubview(refreshedTitle, at: 0)
            self.titleLabel = refreshedTitle
            detailLabel.stringValue = step.detail ?? ""
            detailLabel.isHidden = detailLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            updateCodeBlock(step.codeBlock)
        }

        var testingCodePreviewText: String? {
            codePreviewContainer.isHidden ? nil : codeTextView.string
        }

        var testingCodePreviewHeight: CGFloat {
            codePreviewContainer.isHidden ? 0 : (codeHeightConstraint?.constant ?? 0)
        }

        private func buildUI() {
            surfaceView.translatesAutoresizingMaskIntoConstraints = false
            surfaceView.wantsLayer = true
            surfaceView.layer?.cornerRadius = 0
            surfaceView.layer?.borderWidth = 0
            surfaceView.layer?.borderColor = NSColor.clear.cgColor
            surfaceView.layer?.backgroundColor = NSColor.clear.cgColor

            titleRow.orientation = .horizontal
            titleRow.alignment = .centerY
            titleRow.spacing = DesignTokens.ResultPanel.ToolStatus.titleSpacing
            titleRow.translatesAutoresizingMaskIntoConstraints = false
            titleRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
            titleRow.addArrangedSubview(titleLabel)
            titleRow.addArrangedSubview(NSView())

            bodyStack.orientation = .vertical
            bodyStack.alignment = .leading
            bodyStack.spacing = 6
            bodyStack.translatesAutoresizingMaskIntoConstraints = false
            bodyStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            bodyStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
            bodyStack.addArrangedSubview(titleRow)

            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            detailLabel.font = DesignTokens.ConversationPanel.Typography.stripDetail
            detailLabel.textColor = DesignTokens.ConversationPanel.Text.detail
            detailLabel.maximumNumberOfLines = 0
            detailLabel.lineBreakMode = .byWordWrapping
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            detailLabel.isHidden = true
            bodyStack.addArrangedSubview(detailLabel)

            configureCodePreviewUI()
            bodyStack.addArrangedSubview(codePreviewContainer)

            addSubview(surfaceView)
            surfaceView.addSubview(bodyStack)
            NSLayoutConstraint.activate([
                surfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
                surfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
                surfaceView.topAnchor.constraint(equalTo: topAnchor),
                surfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
                bodyStack.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
                bodyStack.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
                bodyStack.topAnchor.constraint(equalTo: surfaceView.topAnchor),
                bodyStack.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor),
                codePreviewContainer.widthAnchor.constraint(equalTo: bodyStack.widthAnchor)
            ])
        }

        private func configureCodePreviewUI() {
            codePreviewContainer.translatesAutoresizingMaskIntoConstraints = false
            codePreviewContainer.wantsLayer = true
            codePreviewContainer.layer?.cornerRadius = 14
            codePreviewContainer.layer?.borderWidth = 1
            codePreviewContainer.layer?.borderColor = DesignTokens.ConversationPanel.Surface.codeBorder.cgColor
            codePreviewContainer.layer?.backgroundColor = DesignTokens.ConversationPanel.Surface.codeFill.cgColor
            codePreviewContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            codePreviewContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            codePreviewContainer.isHidden = true

            codeHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
            codeHeaderLabel.font = DesignTokens.ConversationPanel.Typography.inlineMono
            codeHeaderLabel.textColor = DesignTokens.ConversationPanel.Text.codeHeader
            codeHeaderLabel.lineBreakMode = .byTruncatingTail
            codeHeaderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            codeHeaderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

            codeHeaderDivider.translatesAutoresizingMaskIntoConstraints = false
            codeHeaderDivider.wantsLayer = true
            codeHeaderDivider.layer?.backgroundColor = DesignTokens.ConversationPanel.Surface.codeDivider.cgColor

            codeScrollView.translatesAutoresizingMaskIntoConstraints = false
            codeScrollView.borderType = .noBorder
            codeScrollView.drawsBackground = false
            codeScrollView.hasVerticalScroller = false
            codeScrollView.hasHorizontalScroller = false
            codeScrollView.autohidesScrollers = false
            codeScrollView.scrollerStyle = .overlay
            codeScrollView.verticalScrollElasticity = .none
            codeScrollView.scrollerKnobStyle = .light
            codeScrollView.contentView.postsBoundsChangedNotifications = false
            codeScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            codeScrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let clipView = NSClipView()
            clipView.drawsBackground = false
            codeScrollView.contentView = clipView

            codeTextView.autoresizingMask = [.width]
            codeTextView.isEditable = false
            codeTextView.isSelectable = true
            codeTextView.drawsBackground = false
            codeTextView.textColor = DesignTokens.ConversationPanel.Text.title
            codeTextView.font = DesignTokens.ConversationPanel.Typography.inlineMono
            codeTextView.textContainerInset = .zero
            codeTextView.isVerticallyResizable = true
            codeTextView.isHorizontallyResizable = false
            codeTextView.minSize = NSSize(width: 0, height: 0)
            codeTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            codeTextView.textContainer?.lineFragmentPadding = 0
            codeTextView.textContainer?.widthTracksTextView = true
            codeTextView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            codeTextView.textContainer?.lineBreakMode = .byWordWrapping
            codeScrollView.documentView = codeTextView

            codePreviewContainer.addSubview(codeHeaderLabel)
            codePreviewContainer.addSubview(codeHeaderDivider)
            codePreviewContainer.addSubview(codeScrollView)

            NSLayoutConstraint.activate([
                codeHeaderLabel.leadingAnchor.constraint(equalTo: codePreviewContainer.leadingAnchor, constant: Self.codePreviewHorizontalInset),
                codeHeaderLabel.trailingAnchor.constraint(lessThanOrEqualTo: codePreviewContainer.trailingAnchor, constant: -Self.codePreviewHorizontalInset),
                codeHeaderLabel.topAnchor.constraint(equalTo: codePreviewContainer.topAnchor, constant: Self.codePreviewVerticalInset),

                codeHeaderDivider.leadingAnchor.constraint(equalTo: codePreviewContainer.leadingAnchor),
                codeHeaderDivider.trailingAnchor.constraint(equalTo: codePreviewContainer.trailingAnchor),
                codeHeaderDivider.topAnchor.constraint(equalTo: codeHeaderLabel.bottomAnchor, constant: 8),
                codeHeaderDivider.heightAnchor.constraint(equalToConstant: 1),

                codeScrollView.leadingAnchor.constraint(equalTo: codePreviewContainer.leadingAnchor, constant: Self.codePreviewHorizontalInset),
                codeScrollView.trailingAnchor.constraint(equalTo: codePreviewContainer.trailingAnchor, constant: -Self.codePreviewHorizontalInset),
                codeScrollView.topAnchor.constraint(equalTo: codeHeaderDivider.bottomAnchor, constant: Self.codePreviewVerticalInset),
                codeScrollView.bottomAnchor.constraint(equalTo: codePreviewContainer.bottomAnchor, constant: -Self.codePreviewVerticalInset)
            ])

            codeHeightConstraint = codeScrollView.heightAnchor.constraint(equalToConstant: preferredCodePreviewHeight())
            codeHeightConstraint?.isActive = true
        }

        private func updateCodeBlock(_ codeBlock: AskRuntimeCodeBlockPreview?) {
            guard let codeBlock,
                  !codeBlock.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                codeTextView.textStorage?.setAttributedString(NSAttributedString())
                codePreviewContainer.isHidden = true
                return
            }

            codeHeaderLabel.stringValue = normalizedCodeLanguageHint(codeBlock.languageHint)
            codeTextView.textStorage?.setAttributedString(
                NSAttributedString(string: codeBlock.content, attributes: Self.codeAttributes())
            )
            codePreviewContainer.isHidden = false
            updateCodePreviewLayout(scrollToBottom: codeBlock.isStreaming)
        }

        private func updateCodePreviewLayout(scrollToBottom: Bool) {
            guard let textContainer = codeTextView.textContainer,
                  let layoutManager = codeTextView.layoutManager else {
                return
            }

            codeHeightConstraint?.constant = preferredCodePreviewHeight()
            codePreviewContainer.layoutSubtreeIfNeeded()

            let targetWidth = max(140, codeScrollView.contentSize.width)
            codeTextView.frame = NSRect(x: 0, y: 0, width: targetWidth, height: codeTextView.frame.height)
            textContainer.containerSize = NSSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let contentHeight = ceil(max(usedHeight, preferredCodePreviewHeight()))
            if abs(codeTextView.frame.height - contentHeight) > 0.5
                || abs(codeTextView.frame.width - targetWidth) > 0.5 {
                codeTextView.frame = NSRect(x: 0, y: 0, width: targetWidth, height: contentHeight)
            }

            if scrollToBottom {
                scrollCodePreviewToBottom()
            }
        }

        private func preferredCodePreviewHeight() -> CGFloat {
            let fontLineHeight = codeTextView.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 13
            let visibleContentHeight = ceil(
                (fontLineHeight * Self.codePreviewVisibleLineCount)
                + (Self.codePreviewLineSpacing * max(0, Self.codePreviewVisibleLineCount - 1))
            )
            return max(36, visibleContentHeight)
        }

        private func scrollCodePreviewToBottom() {
            let clipView = codeScrollView.contentView
            let maxOffset = max(0, codeTextView.frame.height - clipView.bounds.height)
            clipView.scroll(to: NSPoint(x: 0, y: maxOffset))
            codeScrollView.reflectScrolledClipView(clipView)
        }

        private func normalizedCodeLanguageHint(_ languageHint: String?) -> String {
            let normalized = languageHint?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard let normalized, !normalized.isEmpty else {
                return "CODE"
            }
            return normalized.uppercased()
        }

        private static func codeAttributes() -> [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            style.lineSpacing = Self.codePreviewLineSpacing
            style.paragraphSpacing = 6
            return [
                .font: DesignTokens.ConversationPanel.Typography.inlineMono,
                .foregroundColor: DesignTokens.ConversationPanel.Text.title,
                .paragraphStyle: style
            ]
        }

        private static func titleColor(for state: AskRuntimeStepState) -> NSColor {
            switch state {
            case .failed:
                return DesignTokens.Semantic.ResultPanel.Role.systemText
            case .blocked:
                return DesignTokens.Color.accentOrange
            case .saved:
                return DesignTokens.Settings.Status.success
            case .completed:
                return DesignTokens.Color.textSecondary.withAlphaComponent(0.92)
            case .running, .waiting:
                return DesignTokens.Color.textTertiary.withAlphaComponent(0.68)
            }
        }
    }

    private final class ToolStatusBadgeView: NSView {
        private let title: String
        private let labelFont = DesignTokens.Typography.resultPanelBadge

        init(title: String) {
            self.title = title
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.cornerRadius = DesignTokens.ResultPanel.Badge.cornerRadius
            layer?.backgroundColor = DesignTokens.Semantic.ResultPanel.ToolBadge.appearance.fill.cgColor
            layer?.borderWidth = DesignTokens.ResultPanel.Badge.borderWidth
            layer?.borderColor = DesignTokens.Semantic.ResultPanel.ToolBadge.appearance.border.cgColor

            let label = NSTextField(labelWithString: title)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = labelFont
            label.textColor = DesignTokens.Semantic.ResultPanel.ToolBadge.appearance.text
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)

            addSubview(label)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: DesignTokens.ResultPanel.Badge.height),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.ResultPanel.Badge.horizontalPadding),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.ResultPanel.Badge.horizontalPadding),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private final class ToolStatusBadgeOffsetView: NSView {
        init(contentView: NSView) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
                contentView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private final class TranscriptLoadingRowView: NSView {
        private let shimmerLabel: ShimmeringStatusLabel

        init(text: String) {
            self.shimmerLabel = ShimmeringStatusLabel(
                text: text,
                isShimmering: true,
                baseColor: DesignTokens.Color.textTertiary.withAlphaComponent(0.68)
            )
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            shimmerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            shimmerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let row = NSStackView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = DesignTokens.ResultPanel.ToolStatus.titleSpacing
            row.addArrangedSubview(shimmerLabel)
            row.addArrangedSubview(NSView())
            addSubview(row)

            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.topAnchor.constraint(equalTo: topAnchor),
                row.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(text: String) {
            shimmerLabel.updateText(text)
        }
    }

    private struct TranscriptMessageEntry: Equatable {
        let id: String
        var message: AskMessage
    }

    private enum TranscriptEntry: Equatable {
        case message(TranscriptMessageEntry)
        case runtimeStep(AskRuntimeStepEvent)

        var id: String {
            switch self {
            case .message(let entry):
                return entry.id
            case .runtimeStep(let event):
                return event.id
            }
        }
    }

    private let diagnosticsLogger: DiagnosticsLogger
    private let askSessionService: AskSessionService
    private let askSessionKernelBridge = AskSessionKernelBridge()
    private let browserPageCaptureProvider: BrowserPageCaptureProviding
    private let permissionManager: PermissionManager
    private let automationDraftParser: AskAutomationDraftParser
    private let automationStore: AskAutomationStore
    private let assistantFollowUpSessionStore: AskAssistantFollowUpSessionStore
    private let persistentAskSessionCoordinator: AskPersistentSessionCoordinator

    private let panel: AskPanel
    private let hostView = NSView(frame: .zero)
    private let panelSurfaceView = PanelSurfaceView(style: .panel)
    private let contentStack = NSStackView()
    private let supplementaryChromeStack = NSStackView()
    private let headerDragRegionView = NSView()
    private let transcriptStageContainer = NSView()
    private let transcriptScrollView = NSScrollView()
    private let transcriptScrollIndicator = OverlayScrollIndicatorView()
    private let transcriptContentView = AskFlippedDocumentView(frame: .zero)
    private let transcriptStack = NSStackView()
    private let transcriptStreamingSlackSpacer = NSView()
    private let transcriptEmptyStateLabel = PlaceholderTextField(
        labelWithString: L10n.text(
            zhHans: "输入问题，开始提问",
            en: "Type a question to start"
        )
    )
    private let titleLabel = NSTextField(labelWithString: L10n.text(zhHans: "Ask AI", en: "Ask AI"))
    private let closeButton = HoverButton(title: "", target: nil, action: nil)
    private let proactiveHintContainer = NSView()
    private let proactiveHintLabel = NSTextField(labelWithString: "")
    private let scopeBarContainer = NSView()
    private let scopeBarStack = NSStackView()
    private let scopeSourceLabel = NSTextField(labelWithString: "")
    private let scopePermissionsLabel = NSTextField(wrappingLabelWithString: "")
    private let scopeStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let sessionModeContainer = NSView()
    private let sessionModeEyebrowLabel = NSTextField(labelWithString: L10n.text(zhHans: "会话模式", en: "Session mode"))
    private let sessionModeTitleLabel = NSTextField(labelWithString: "")
    private let sessionModeMetaLabel = NSTextField(wrappingLabelWithString: "")
    private let sessionModeDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let pendingApprovalContainer = NSView()
    private let pendingApprovalTitleLabel = NSTextField(labelWithString: "")
    private let pendingApprovalDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let pendingApprovalPreviewStack = NSStackView()
    private let pendingApprovalConfirmButton = HoverButton(title: L10n.text(zhHans: "确认", en: "Confirm"), target: nil, action: nil)
    private let pendingApprovalCancelButton = HoverButton(title: L10n.text(zhHans: "取消", en: "Cancel"), target: nil, action: nil)
    private let taskContinuityContainer = NSView()
    private let taskContinuityEyebrowLabel = NSTextField(labelWithString: L10n.text(zhHans: "任务连续性", en: "Task continuity"))
    private let taskContinuityTitleLabel = NSTextField(labelWithString: "")
    private let taskContinuityMetaLabel = NSTextField(wrappingLabelWithString: "")
    private let taskContinuityDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let divider = NSView()
    private let cronDraftContainer = NSView()
    private let cronDraftTitleLabel = NSTextField(labelWithString: "")
    private let cronDraftScheduleLabel = NSTextField(wrappingLabelWithString: "")
    private let cronDraftSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let cronDraftDeliveryLabel = NSTextField(wrappingLabelWithString: "")
    private let cronDraftRiskLabel = NSTextField(wrappingLabelWithString: "")
    private let composerContainer = HoverResponsiveView()
    private let composerTextClipView = NSView()
    private let composerPlaceholder = PlaceholderTextField(labelWithString: L10n.text(zhHans: "输入问题，Enter 发送，Shift+Enter 换行", en: "Ask anything. Enter to send, Shift+Enter for a new line"))
    private let composerTextView = ComposerTextView()
    private let composerButtonStack = NSStackView()
    private let saveAutomationButton = HoverButton(title: L10n.text(zhHans: "保存为定时任务", en: "Save as cron"), target: nil, action: nil)
    private let sendButton = HoverButton(title: L10n.text(zhHans: "发送", en: "Send"), target: nil, action: nil)
    private let cronContinueButton = HoverButton(title: L10n.text(zhHans: "继续发送", en: "Send instead"), target: nil, action: nil)
    private let cronSaveButton = HoverButton(title: L10n.text(zhHans: "保存任务", en: "Save job"), target: nil, action: nil)
    private let cronDismissButton = HoverButton(title: L10n.text(zhHans: "稍后再说", en: "Not now"), target: nil, action: nil)
    private let entranceFlowOverlayView = NSView()

    private var transcriptHeightConstraint: NSLayoutConstraint?
    private var composerTextHeightConstraint: NSLayoutConstraint?
    private var composerButtonStackLeadingConstraint: NSLayoutConstraint?
    private var composerTextWidthConstraint: NSLayoutConstraint?
    private var transcriptEntries: [TranscriptEntry] = []
    private var transcriptMessageRowViewsByEntryID: [String: TranscriptRowView] = [:]
    private var transcriptRuntimeStepRowViewsByEntryID: [String: TranscriptRuntimeStepRowView] = [:]
    private var state = AskSessionState.make(sourceBundleID: nil, sourceAppName: nil)
    private var streamingAssistantIndex: Int?
    private var streamingAssistantEntryID: String?
    private var streamingTargetText = ""
    private var latestResponseMetadata: [String: String] = [:]
    private var latestKernelScopeSummary: KernelScopeSummary?
    private var sessionKernelMetadata: [String: String] = [:]
    private var wantsScopeChrome = false
    private var wantsSessionChrome = false
    private var wantsTaskChrome = false
    private var sessionContextCaptureTask: Task<Void, Never>?
    private var pendingAutomationDraft: AskAutomationDraft?
    private var pendingAutomationPrompt: String?
    private var currentTask: Task<Void, Never>?
    private var syntheticStreamingWorkItems: [DispatchWorkItem] = []
    private var smokeViewportTraceFileURL: URL?
    private var smokeViewportTraceSequence = 0
    private var smokeStateSnapshotFileURL: URL?
    private var pendingSmokeStateSnapshotWriteWorkItem: DispatchWorkItem?
    private var composerHasFocus = false
    private var composerIsHovered = false
    private var didPromoteActivationPolicyForVisibility = false
    private var isRunningEntranceAnimation = false
    private var isAdjustingPanelComfortBounds = false
    private var pendingComposerFocusRetryWorkItem: DispatchWorkItem?
    private var sendButtonGlobalFallbackMonitor: Any?
    private var entranceRevealWorkItem: DispatchWorkItem?
    private var entrancePresentationID = UUID()
    private var messageCitationsByEntryID: [String: [SkillResultCard]] = [:]
    private var pendingApprovalActionID: String?
    private var pendingApprovalSummaryText: String?
    private var pendingApprovalMessageText: String?
    private var pendingApprovalPreviewCards: [SkillResultCard] = []
    private var pendingApprovalCardSuppressed = false
    private var activeAssistantFollowUpPersistenceKey: String?
    private var isUsingPersistentAskSessionShell = false
    private var persistentAskInvocationRecords: [AskPersistentInvocationRecord] = []
    private var deferredPersistentAskSnapshot: AskPersistentSessionSnapshot?
    private var activeProactiveHintText: String?
    private var activeProactiveOpportunityID: String?
    private var currentProactivePresentationMode: AskProactivePresentationMode?
    private var loadingStatusRowView: TranscriptLoadingRowView?
    private var currentLoadingStatusText: String?
    private var activeRuntimeStepEntryID: String?
    private var didObserveRuntimeCodePreview = false
    private var maxObservedRuntimeCodePreviewHeight: CGFloat = 0
    private var currentTurnSubmittedAt: Date?
    private var currentTurnReceivedDelta = false
    private var currentTurnRowUpdateCount = 0
    private var currentTurnMaxRenderedChunkLength = 0

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingComposerFocusRetryWorkItem?.cancel()
        pendingSmokeStateSnapshotWriteWorkItem?.cancel()
        sessionContextCaptureTask?.cancel()
        if let sendButtonGlobalFallbackMonitor {
            NSEvent.removeMonitor(sendButtonGlobalFallbackMonitor)
        }
        streamingHighlightFadeTimer?.invalidate()
    }
    private var streamingHighlightEntryID: String?
    private var streamingHighlightSuffixLength = 0
    private var streamingHighlightAlpha: CGFloat = 1
    private var streamingHighlightFadeTimer: Timer?
    private var streamingHighlightFadeStartedAt: CFTimeInterval?
    private var pendingTranscriptViewportRefreshWorkItem: DispatchWorkItem?
    private var pendingTranscriptViewportShouldScrollToBottom = false
    private var pendingTranscriptViewportAnchorEntryID: String?
    private var pendingTranscriptViewportAnchorVisibleMinY: CGFloat?
    private var lastTranscriptContentFrameSize = NSSize.zero
    private var lastTranscriptTargetOffset: CGFloat = -1
    private var transcriptStreamingSlackHeightConstraint: NSLayoutConstraint?
    private var currentTranscriptStreamingSlackHeight = Layout.streamingFollowSlackBase
    private var lastTranscriptVisibleContentHeight: CGFloat = 0
    private var transcriptScrollAnimationWorkItem: DispatchWorkItem?
    private var transcriptScrollAnimationTargetOffset: CGFloat?
    private var citationPopover: NSPopover?
    private let entranceFlowContainerLayer = CALayer()
    private let entranceFlowPrimaryLayer = CAShapeLayer()
    private let entranceFlowSecondaryLayer = CAShapeLayer()
    private let entranceFlowPrimaryAuraLayer = CAGradientLayer()
    private let entranceFlowSecondaryAuraLayer = CAGradientLayer()
    private lazy var loadingLineEffectController = ResultLoadingLineEffectController(
        divider: divider,
        auraOverlayView: panelSurfaceView
    )

    private lazy var resultCardActionCoordinator = ResultCardActionCoordinator(
        diagnosticsLogger: diagnosticsLogger,
        contextProvider: { [weak self] in
            ResultCardActionContext(
                currentSkillID: nil,
                currentSourceBundleID: self?.state.sourceBundleID
            )
        },
        hideHandler: { _ in }
    )

    var onVisibilityChanged: ((Bool) -> Void)?

    private static let supportedBrowserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac"
    ]

    init(
        askSessionService: AskSessionService = AskSessionService(),
        diagnosticsLogger: DiagnosticsLogger = .shared,
        permissionManager: PermissionManager = PermissionManager(),
        automationDraftParser: AskAutomationDraftParser = .shared,
        automationStore: AskAutomationStore = .shared,
        assistantFollowUpSessionStore: AskAssistantFollowUpSessionStore = .shared,
        persistentAskSessionCoordinator: AskPersistentSessionCoordinator? = nil,
        browserPageCaptureProvider: BrowserPageCaptureProviding = BrowserPageCaptureService()
    ) {
        self.askSessionService = askSessionService
        self.diagnosticsLogger = diagnosticsLogger
        self.browserPageCaptureProvider = browserPageCaptureProvider
        self.permissionManager = permissionManager
        self.automationDraftParser = automationDraftParser
        self.automationStore = automationStore
        self.assistantFollowUpSessionStore = assistantFollowUpSessionStore
        self.persistentAskSessionCoordinator = persistentAskSessionCoordinator ?? AskPersistentSessionCoordinator(
            store: .shared,
            legacyAssistantFollowUpSessionStore: assistantFollowUpSessionStore
        )
        self.panel = AskPanel(
            contentRect: NSRect(x: 0, y: 0, width: AskWindowGeometry.minimumSize.width, height: AskWindowGeometry.minimumSize.height),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.minSize = AskWindowGeometry.minimumSize
        panel.contentView = hostView
        panel.delegate = self
        panel.onEscapePressed = { [weak self] in
            self?.hide()
        }
        panel.leftMouseDownObserver = { [weak self] event in
            self?.logPanelMouseDiagnostics(stage: "panel_send_event", event: event)
        }
        panel.primaryMouseDownHandler = { [weak self] event in
            self?.handlePanelPrimaryMouseDown(event) ?? false
        }
        panel.keyEquivalentHandler = { [weak self] event in
            self?.handlePanelKeyEquivalent(event) ?? false
        }

        configureUI()
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var currentPersistentAskSessionID: String? {
        isUsingPersistentAskSessionShell ? state.sessionID : nil
    }

    var isStreamingForPresence: Bool {
        state.isStreaming
    }

    var hasPendingApprovalForPresence: Bool {
        pendingApprovalActionID != nil
    }

    var isShowingProactivePopup: Bool {
        panel.isVisible && currentProactivePresentationMode != nil
    }

    func contains(screenPoint: CGPoint) -> Bool {
        panel.isVisible && panel.frame.contains(screenPoint)
    }

    private enum SessionShellKind {
        case transient
        case persistentAsk
    }

    private func beginSessionShell(
        frame desiredFrame: CGRect,
        transitionStartPoint: CGPoint?,
        transitionEndPoint: CGPoint?,
        sourceBundleID: String?,
        sourceAppName: String?,
        initialKernelMetadata: [String: String] = [:],
        sessionOrigin: AskSessionOrigin = .user,
        invocationSurface: AskInvocationSurface = .askWindow,
        requestedMode: AskExecutionMode? = nil,
        captureLiveSelection: Bool = false,
        sessionID: String? = nil,
        shellKind: SessionShellKind
    ) {
        persistActiveSessionIfNeeded()
        cancelCurrentRequest()
        state = AskSessionState.make(
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            sessionOrigin: sessionOrigin,
            invocationSurface: invocationSurface,
            requestedMode: requestedMode,
            sessionID: sessionID
        )
        isUsingPersistentAskSessionShell = shellKind == .persistentAsk
        persistentAskInvocationRecords = []
        deferredPersistentAskSnapshot = nil
        didObserveRuntimeCodePreview = false
        maxObservedRuntimeCodePreviewHeight = 0
        activeAssistantFollowUpPersistenceKey = shellKind == .transient && sessionOrigin == .assistantFollowUp
            ? AskAssistantFollowUpActivation.persistenceKey(from: initialKernelMetadata)
            : nil
        sessionKernelMetadata = makeSessionKernelMetadata(
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            initialKernelMetadata: initialKernelMetadata,
            captureCurrentSelection: captureLiveSelection
        )
        transcriptEntries.removeAll()
        transcriptMessageRowViewsByEntryID.removeAll()
        transcriptRuntimeStepRowViewsByEntryID.removeAll()
        messageCitationsByEntryID.removeAll()
        clearPendingApprovalState()
        hideLoadingStatus(immediately: true)
        citationPopover?.performClose(nil)
        streamingAssistantIndex = nil
        streamingAssistantEntryID = nil
        activeRuntimeStepEntryID = nil
        streamingTargetText = ""
        currentTurnSubmittedAt = nil
        currentTurnReceivedDelta = false
        resetStreamingHighlight()
        resetPendingStreamingAssistantRowUpdate()
        resetPendingTranscriptViewportRefresh()
        resetTranscriptStreamingSlack()
        composerHasFocus = false
        latestResponseMetadata = [:]
        latestKernelScopeSummary = nil
        wantsScopeChrome = false
        wantsSessionChrome = false
        wantsTaskChrome = false
        activeProactiveHintText = nil
        activeProactiveOpportunityID = nil
        currentProactivePresentationMode = nil
        pendingAutomationDraft = nil
        pendingAutomationPrompt = nil
        composerTextView.string = ""
        cronDraftContainer.isHidden = true
        scopeBarContainer.isHidden = true
        sessionModeContainer.isHidden = true
        pendingApprovalContainer.isHidden = true
        taskContinuityContainer.isHidden = true
        updateComposerPlaceholder()
        updateProactiveHintPresentation()
        updateScopeBar()
        updateComposerActionButtonsState(animated: false)
        updateEmptyStateVisibility()
        renderTranscript()
        updateComposerMetrics()

        let resolvedFrame = AskWindowGeometry.resolvedFrame(
            for: desiredFrame,
            screens: NSScreen.screens,
            startPoint: transitionStartPoint,
            endPoint: transitionEndPoint
        )
        presentPanelForNewSession(
            selectionFrame: desiredFrame,
            transitionStartPoint: transitionStartPoint,
            transitionEndPoint: transitionEndPoint,
            targetFrame: resolvedFrame
        ) { [weak self] in
            guard let self else { return }
            self.onVisibilityChanged?(true)
            self.diagnosticsLogger.log(
                "ask.session",
                "begin session=\(self.state.sessionID) bundle=\(sourceBundleID ?? "unknown") frame=(\(Int(resolvedFrame.minX)),\(Int(resolvedFrame.minY)),\(Int(resolvedFrame.width)),\(Int(resolvedFrame.height)))"
            )
        }
        ensureSendButtonGlobalFallbackMonitor()
    }

    func beginNewSession(
        frame desiredFrame: CGRect,
        transitionStartPoint: CGPoint?,
        transitionEndPoint: CGPoint?,
        sourceBundleID: String?,
        sourceAppName: String?,
        initialKernelMetadata: [String: String] = [:],
        sessionOrigin: AskSessionOrigin = .user,
        invocationSurface: AskInvocationSurface = .askWindow,
        requestedMode: AskExecutionMode? = nil,
        captureLiveSelection: Bool = false,
        sessionID: String? = nil
    ) {
        beginSessionShell(
            frame: desiredFrame,
            transitionStartPoint: transitionStartPoint,
            transitionEndPoint: transitionEndPoint,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            initialKernelMetadata: initialKernelMetadata,
            sessionOrigin: sessionOrigin,
            invocationSurface: invocationSurface,
            requestedMode: requestedMode,
            captureLiveSelection: captureLiveSelection,
            sessionID: sessionID,
            shellKind: .transient
        )
    }

    func beginPersistentAskSession(
        frame desiredFrame: CGRect,
        transitionStartPoint: CGPoint?,
        transitionEndPoint: CGPoint?,
        sourceBundleID: String?,
        sourceAppName: String?,
        initialKernelMetadata: [String: String] = [:],
        sessionOrigin: AskSessionOrigin = .user,
        invocationSurface: AskInvocationSurface = .askWindow,
        requestedMode: AskExecutionMode? = nil,
        captureLiveSelection: Bool = false,
        compatibilityPersistenceKey: String? = nil,
        suggestedPrompt: String? = nil
    ) {
        let entry = AskPersistentSessionEntry(
            sessionOrigin: sessionOrigin,
            invocationSurface: invocationSurface,
            requestedMode: requestedMode,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            compatibilityPersistenceKey: compatibilityPersistenceKey,
            activeTaskID: currentPersistentLineageValue(
                in: initialKernelMetadata,
                primaryKey: "active_task_id",
                fallbackKeys: ["assistant_delivery_active_task_id"]
            ),
            activeTaskResumeToken: currentPersistentLineageValue(
                in: initialKernelMetadata,
                primaryKey: "active_task_resume_token",
                fallbackKeys: ["resume_token", "task_resume_token"]
            ),
            isProactive: false,
            proactiveReason: nil,
            presentationMode: nil
        )

        if panel.isVisible, isUsingPersistentAskSessionShell {
            attachPersistentAskInvocationToCurrentSession(
                entry: entry,
                initialKernelMetadata: initialKernelMetadata,
                captureLiveSelection: captureLiveSelection,
                suggestedPrompt: suggestedPrompt
            )
            focusComposer()
            return
        }

        let existingPersistentSnapshot = persistentAskSessionCoordinator.currentSnapshot()
        switch persistentAskSessionCoordinator.bootstrap(for: entry) {
        case .fresh:
            beginSessionShell(
                frame: desiredFrame,
                transitionStartPoint: transitionStartPoint,
                transitionEndPoint: transitionEndPoint,
                sourceBundleID: sourceBundleID,
                sourceAppName: sourceAppName,
                initialKernelMetadata: initialKernelMetadata,
                sessionOrigin: sessionOrigin,
                invocationSurface: invocationSurface,
                requestedMode: requestedMode,
                captureLiveSelection: captureLiveSelection,
                sessionID: nil,
                shellKind: .persistentAsk
            )
            deferredPersistentAskSnapshot = existingPersistentSnapshot
            attachPersistentAskInvocationToCurrentSession(
                entry: entry,
                initialKernelMetadata: initialKernelMetadata,
                captureLiveSelection: captureLiveSelection,
                suggestedPrompt: suggestedPrompt
            )

        case .restoreMain(let snapshot):
            deferredPersistentAskSnapshot = nil
            beginSessionShell(
                frame: preferredPersistentAskFrame(desiredFrame, fallback: snapshot.frame?.rect),
                transitionStartPoint: transitionStartPoint,
                transitionEndPoint: transitionEndPoint,
                sourceBundleID: snapshot.sourceBundleID ?? sourceBundleID,
                sourceAppName: snapshot.sourceAppName ?? sourceAppName,
                initialKernelMetadata: snapshot.kernelMetadata,
                sessionOrigin: snapshot.sessionOrigin,
                invocationSurface: snapshot.invocationSurface,
                requestedMode: snapshot.requestedMode,
                captureLiveSelection: false,
                sessionID: snapshot.sessionID,
                shellKind: .persistentAsk
            )
            restorePersistentAskSessionSnapshot(snapshot)
            attachPersistentAskInvocationToCurrentSession(
                entry: entry,
                initialKernelMetadata: initialKernelMetadata,
                captureLiveSelection: captureLiveSelection,
                suggestedPrompt: suggestedPrompt
            )
            refreshKernelResultSummaryIfNeeded(sessionID: state.sessionID)

        case .restoreLegacy(let snapshot):
            deferredPersistentAskSnapshot = nil
            beginSessionShell(
                frame: preferredPersistentAskFrame(desiredFrame, fallback: snapshot.frame?.rect),
                transitionStartPoint: transitionStartPoint,
                transitionEndPoint: transitionEndPoint,
                sourceBundleID: snapshot.sourceBundleID ?? sourceBundleID,
                sourceAppName: snapshot.sourceAppName ?? sourceAppName,
                initialKernelMetadata: snapshot.kernelMetadata,
                sessionOrigin: snapshot.sessionOrigin,
                invocationSurface: snapshot.invocationSurface,
                requestedMode: snapshot.requestedMode,
                captureLiveSelection: false,
                sessionID: snapshot.sessionID,
                shellKind: .persistentAsk
            )
            restoreLegacyAssistantFollowUpSessionSnapshot(snapshot)
            attachPersistentAskInvocationToCurrentSession(
                entry: entry,
                initialKernelMetadata: initialKernelMetadata,
                captureLiveSelection: captureLiveSelection,
                suggestedPrompt: suggestedPrompt
            )
            refreshKernelResultSummaryIfNeeded(sessionID: state.sessionID)
        }

        persistPersistentAskSessionIfNeeded()
    }

    func presentProactiveAskContact(
        _ opportunity: AskProactiveOpportunity,
        targetFrame: CGRect,
        fallbackFrame: CGRect? = nil
    ) {
        let resolvedFrame = preferredPersistentAskFrame(targetFrame, fallback: fallbackFrame)
        let entry = AskPersistentSessionEntry(
            sessionOrigin: opportunity.sessionOrigin,
            invocationSurface: opportunity.invocationSurface,
            requestedMode: opportunity.requestedMode,
            sourceBundleID: opportunity.sourceBundleID,
            sourceAppName: opportunity.sourceAppName,
            compatibilityPersistenceKey: opportunity.compatibilityPersistenceKey,
            activeTaskID: currentPersistentLineageValue(
                in: opportunity.metadata,
                primaryKey: "active_task_id",
                fallbackKeys: ["assistant_delivery_active_task_id"]
            ),
            activeTaskResumeToken: currentPersistentLineageValue(
                in: opportunity.metadata,
                primaryKey: "active_task_resume_token",
                fallbackKeys: ["resume_token", "task_resume_token"]
            ),
            isProactive: true,
            proactiveReason: opportunity.reason,
            presentationMode: targetFrame.width > 0 && targetFrame.height > 0 ? .statusItemPopup : .fallbackPopup
        )

        activeProactiveHintText = opportunity.hintText
        activeProactiveOpportunityID = opportunity.id
        currentProactivePresentationMode = entry.presentationMode

        if panel.isVisible, isUsingPersistentAskSessionShell {
            attachPersistentAskInvocationToCurrentSession(
                entry: entry,
                initialKernelMetadata: opportunity.metadata,
                captureLiveSelection: false,
                suggestedPrompt: opportunity.suggestedPrompt
            )
            panel.makeKeyAndOrderFront(nil)
            panel.setFrame(resolvedFrame, display: true)
            updateProactiveHintPresentation()
            focusComposer()
            return
        }

        beginPersistentAskSession(
            frame: resolvedFrame,
            transitionStartPoint: nil,
            transitionEndPoint: nil,
            sourceBundleID: opportunity.sourceBundleID,
            sourceAppName: opportunity.sourceAppName,
            initialKernelMetadata: opportunity.metadata,
            sessionOrigin: opportunity.sessionOrigin,
            invocationSurface: opportunity.invocationSurface,
            requestedMode: opportunity.requestedMode,
            captureLiveSelection: false,
            compatibilityPersistenceKey: opportunity.compatibilityPersistenceKey,
            suggestedPrompt: opportunity.suggestedPrompt
        )
        activeProactiveHintText = opportunity.hintText
        activeProactiveOpportunityID = opportunity.id
        currentProactivePresentationMode = entry.presentationMode
        updateProactiveHintPresentation()
        panel.setFrame(resolvedFrame, display: true)
        panel.makeKeyAndOrderFront(nil)
        focusComposer()
    }

    func attachProactiveOpportunity(_ opportunity: AskProactiveOpportunity) {
        let entry = AskPersistentSessionEntry(
            sessionOrigin: opportunity.sessionOrigin,
            invocationSurface: opportunity.invocationSurface,
            requestedMode: opportunity.requestedMode,
            sourceBundleID: opportunity.sourceBundleID,
            sourceAppName: opportunity.sourceAppName,
            compatibilityPersistenceKey: opportunity.compatibilityPersistenceKey,
            activeTaskID: currentPersistentLineageValue(
                in: opportunity.metadata,
                primaryKey: "active_task_id",
                fallbackKeys: ["assistant_delivery_active_task_id"]
            ),
            activeTaskResumeToken: currentPersistentLineageValue(
                in: opportunity.metadata,
                primaryKey: "active_task_resume_token",
                fallbackKeys: ["resume_token", "task_resume_token"]
            ),
            isProactive: true,
            proactiveReason: opportunity.reason,
            presentationMode: .interactive
        )
        activeProactiveHintText = opportunity.hintText
        activeProactiveOpportunityID = opportunity.id
        currentProactivePresentationMode = .interactive
        attachPersistentAskInvocationToCurrentSession(
            entry: entry,
            initialKernelMetadata: opportunity.metadata,
            captureLiveSelection: false,
            suggestedPrompt: opportunity.suggestedPrompt
        )
        updateProactiveHintPresentation()
    }

    func attachPersistentAskInvocation(
        sourceBundleID: String?,
        sourceAppName: String?,
        initialKernelMetadata: [String: String] = [:],
        sessionOrigin: AskSessionOrigin = .user,
        invocationSurface: AskInvocationSurface = .askWindow,
        requestedMode: AskExecutionMode? = nil,
        captureLiveSelection: Bool = false,
        compatibilityPersistenceKey: String? = nil,
        suggestedPrompt: String? = nil
    ) {
        guard panel.isVisible, isUsingPersistentAskSessionShell else {
            beginPersistentAskSession(
                frame: panel.frame,
                transitionStartPoint: nil,
                transitionEndPoint: nil,
                sourceBundleID: sourceBundleID,
                sourceAppName: sourceAppName,
                initialKernelMetadata: initialKernelMetadata,
                sessionOrigin: sessionOrigin,
                invocationSurface: invocationSurface,
                requestedMode: requestedMode,
                captureLiveSelection: captureLiveSelection,
                compatibilityPersistenceKey: compatibilityPersistenceKey,
                suggestedPrompt: suggestedPrompt
            )
            return
        }

        let entry = AskPersistentSessionEntry(
            sessionOrigin: sessionOrigin,
            invocationSurface: invocationSurface,
            requestedMode: requestedMode,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            compatibilityPersistenceKey: compatibilityPersistenceKey,
            activeTaskID: currentPersistentLineageValue(
                in: initialKernelMetadata,
                primaryKey: "active_task_id",
                fallbackKeys: ["assistant_delivery_active_task_id"]
            ),
            activeTaskResumeToken: currentPersistentLineageValue(
                in: initialKernelMetadata,
                primaryKey: "active_task_resume_token",
                fallbackKeys: ["resume_token", "task_resume_token"]
            ),
            isProactive: false,
            proactiveReason: nil,
            presentationMode: nil
        )
        attachPersistentAskInvocationToCurrentSession(
            entry: entry,
            initialKernelMetadata: initialKernelMetadata,
            captureLiveSelection: captureLiveSelection,
            suggestedPrompt: suggestedPrompt
        )
        focusComposer()
    }

    func hide() {
        persistActiveSessionIfNeeded()
        cancelCurrentRequest()
        guard panel.isVisible else { return }
        entrancePresentationID = UUID()
        entranceRevealWorkItem?.cancel()
        entranceRevealWorkItem = nil
        pendingComposerFocusRetryWorkItem?.cancel()
        pendingComposerFocusRetryWorkItem = nil
        isRunningEntranceAnimation = false
        composerHasFocus = false
        transcriptEntries.removeAll()
        transcriptMessageRowViewsByEntryID.removeAll()
        transcriptRuntimeStepRowViewsByEntryID.removeAll()
        messageCitationsByEntryID.removeAll()
        hideLoadingStatus(immediately: true)
        citationPopover?.performClose(nil)
        stopEntranceFlowAnimation()
        pendingAutomationDraft = nil
        pendingAutomationPrompt = nil
        latestResponseMetadata = [:]
        latestKernelScopeSummary = nil
        sessionKernelMetadata = [:]
        wantsScopeChrome = false
        wantsSessionChrome = false
        wantsTaskChrome = false
        activeProactiveHintText = nil
        activeProactiveOpportunityID = nil
        currentProactivePresentationMode = nil
        cronDraftContainer.isHidden = true
        scopeBarContainer.isHidden = true
        sessionModeContainer.isHidden = true
        clearPendingApprovalState()
        taskContinuityContainer.isHidden = true
        updateComposerPlaceholder()
        updateEmptyStateVisibility()
        updateProactiveHintPresentation()
        updateScopeBar()
        updateComposerActionButtonsState(animated: false)
        updateComposerContainerAppearance(animated: false)
        removeSendButtonGlobalFallbackMonitor()
        panel.orderOut(nil)
        isUsingPersistentAskSessionShell = false
        persistentAskInvocationRecords = []
        deferredPersistentAskSnapshot = nil
        didObserveRuntimeCodePreview = false
        maxObservedRuntimeCodePreviewHeight = 0
        activeAssistantFollowUpPersistenceKey = nil
        restoreActivationPolicyIfNeeded()
        onVisibilityChanged?(false)
        scheduleSmokeStateSnapshotWrite(immediately: true)
    }

    func cancelCurrentRequest() {
        currentTask?.cancel()
        currentTask = nil
        sessionContextCaptureTask?.cancel()
        sessionContextCaptureTask = nil
        cancelSyntheticStreamingWorkItems()
        entranceRevealWorkItem?.cancel()
        entranceRevealWorkItem = nil
        pendingComposerFocusRetryWorkItem?.cancel()
        pendingComposerFocusRetryWorkItem = nil
        state.isStreaming = false
        latestKernelScopeSummary = nil
        wantsScopeChrome = false
        wantsSessionChrome = false
        wantsTaskChrome = false
        streamingAssistantIndex = nil
        streamingAssistantEntryID = nil
        activeRuntimeStepEntryID = nil
        streamingTargetText = ""
        currentTurnSubmittedAt = nil
        currentTurnReceivedDelta = false
        resetStreamingHighlight()
        resetPendingStreamingAssistantRowUpdate()
        resetPendingTranscriptViewportRefresh()
        resetTranscriptStreamingSlack()
        hideLoadingStatus(immediately: true)
        sessionKernelMetadata = [:]
        didObserveRuntimeCodePreview = false
        maxObservedRuntimeCodePreviewHeight = 0
        updateComposerActionButtonsState(animated: true)
        citationPopover?.performClose(nil)
        scopeBarContainer.isHidden = true
        sessionModeContainer.isHidden = true
        clearPendingApprovalState()
        taskContinuityContainer.isHidden = true
        removeTranscriptEntry(withID: taskContinuityRuntimeStepID)
        updateScopeBar()
        updateEmptyStateVisibility()
        finalizeSmokeViewportTrace(reason: "cancel")
        scheduleSmokeStateSnapshotWrite(immediately: true)
    }

    func submitCurrentPrompt() {
        if commitComposerMarkedTextIfNeeded() {
            DispatchQueue.main.async { [weak self] in
                self?.submitCurrentPrompt()
            }
            return
        }

        let prompt = trimmedComposerText()
        guard !prompt.isEmpty else { return }
        submitPrompt(prompt)
    }

    private func submitPrompt(_ prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !state.isStreaming else { return }
        startStreamingTurn(with: trimmedPrompt)
        let bypassKernelPreparation = shouldBypassKernelPreparation(for: trimmedPrompt)

        let baseRequest = AskSessionRequest(
            messages: state.messages,
            metadata: AskSessionMetadata(
                sessionID: state.sessionID,
                sourceBundleID: state.sourceBundleID,
                sourceAppName: state.sourceAppName,
                frame: panel.frame,
                sessionOrigin: state.sessionOrigin,
                invocationSurface: state.invocationSurface,
                requestedMode: state.requestedMode,
                kernelMetadata: sessionKernelMetadata
            ),
            uiLanguage: AppSettings.shared.appLanguage.languageCode,
            responseLanguage: resolvedResponseLanguage()
        )

        diagnosticsLogger.log("ask.session", "submit session=\(state.sessionID) turns=\(state.messages.count) promptLength=\(trimmedPrompt.count)")
        ResultMarkdownRenderer.prewarmDefaultLocalReferenceIndexes()
        currentTask = Task { [weak self] in
            guard let self else { return }
            let preparedRequest: AskSessionRequest
            if bypassKernelPreparation {
                preparedRequest = baseRequest
            } else {
                let prepared = await self.askSessionKernelBridge.prepare(request: baseRequest)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self.appendKernelPreparationStep(prepared.preparedTask)
                }
                preparedRequest = prepared.request
            }

            let streamTask = self.askSessionService.streamReply(
                request: preparedRequest,
                onEvent: { [weak self] event in
                    self?.handleStreamEvent(event)
                },
                onComplete: { [weak self] result in
                    self?.handleCompletion(result)
                }
            )

            await withTaskCancellationHandler(
                operation: {
                    await streamTask.value
                },
                onCancel: {
                    streamTask.cancel()
                }
            )
        }
    }

    private func shouldBypassKernelPreparation(for prompt: String) -> Bool {
        guard pendingApprovalActionID != nil else { return false }
        return pendingApprovalDecision(for: prompt) != nil
    }

    private func pendingApprovalDecision(for prompt: String) -> AskApprovalDecision? {
        let normalized = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "确认", "确认执行", "confirm", "approve":
            return .approve
        case "取消", "cancel", "deny":
            return .cancel
        default:
            return nil
        }
    }

    func beginAssistantFollowUpSession(
        activation: AskAssistantFollowUpActivation,
        frame desiredFrame: CGRect,
        transitionStartPoint: CGPoint? = nil,
        transitionEndPoint: CGPoint? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        prefillSuggestedPrompt: Bool = true
    ) {
        beginPersistentAskSession(
            frame: desiredFrame,
            transitionStartPoint: transitionStartPoint,
            transitionEndPoint: transitionEndPoint,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            initialKernelMetadata: activation.initialKernelMetadata,
            sessionOrigin: activation.sessionOrigin,
            invocationSurface: activation.invocationSurface,
            requestedMode: activation.requestedMode,
            captureLiveSelection: false,
            compatibilityPersistenceKey: activation.persistenceKey,
            suggestedPrompt: prefillSuggestedPrompt ? activation.suggestedPrompt(responseLanguage: resolvedResponseLanguage()) : nil
        )
    }

    private func persistActiveSessionIfNeeded() {
        if isUsingPersistentAskSessionShell {
            persistPersistentAskSessionIfNeeded()
        } else {
            persistAssistantFollowUpSessionIfNeeded()
        }
    }

    private func preferredPersistentAskFrame(_ desiredFrame: CGRect, fallback: CGRect?) -> CGRect {
        if desiredFrame.width > 0, desiredFrame.height > 0 {
            return desiredFrame
        }
        return fallback ?? desiredFrame
    }

    private func currentPersistentLineageValue(
        in metadata: [String: String],
        primaryKey: String,
        fallbackKeys: [String] = []
    ) -> String? {
        let keys = [primaryKey] + fallbackKeys
        for key in keys {
            guard let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    private func currentPersistentAskHasPersistableContent() -> Bool {
        !state.messages.isEmpty
            || currentAssistantFollowUpApprovalSnapshot() != nil
            || !(trimmedComposerText().isEmpty)
            || !(sessionKernelMetadata["active_task_resume_token"] ?? "").isEmpty
            || !(sessionKernelMetadata["active_task_id"] ?? "").isEmpty
    }

    private func attachPersistentAskInvocationToCurrentSession(
        entry: AskPersistentSessionEntry,
        initialKernelMetadata: [String: String],
        captureLiveSelection: Bool,
        suggestedPrompt: String?
    ) {
        guard isUsingPersistentAskSessionShell else { return }

        var updatedState = AskSessionState.make(
            sourceBundleID: entry.sourceBundleID ?? state.sourceBundleID,
            sourceAppName: entry.sourceAppName ?? state.sourceAppName,
            sessionOrigin: entry.sessionOrigin,
            invocationSurface: entry.invocationSurface,
            requestedMode: entry.requestedMode ?? state.requestedMode,
            sessionID: state.sessionID
        )
        updatedState.messages = state.messages
        updatedState.isStreaming = state.isStreaming
        state = updatedState

        var mergedMetadata = sessionKernelMetadata
        for key in [
            "source_bundle_id",
            "source_app_name",
            "current_page_url",
            "current_page_title",
            "current_page_text_preview",
            "selection_preview"
        ] {
            if let value = initialKernelMetadata[key], !value.isEmpty {
                mergedMetadata[key] = value
            }
        }
        for key in [
            "active_task_id",
            "active_task_title",
            "active_task_status",
            "active_task_resume_token",
            "active_task_workspace_root",
            "interactive_task_scope_root",
            "workspace_root",
            "assistant_delivery_source_task_id",
            "assistant_delivery_source_run_id",
            "assistant_delivery_source_job_id",
            "latest_assistant_delivery_channel"
        ] {
            if let value = initialKernelMetadata[key], !value.isEmpty {
                mergedMetadata[key] = value
            }
        }
        sessionKernelMetadata = makeSessionKernelMetadata(
            sourceBundleID: entry.sourceBundleID ?? state.sourceBundleID,
            sourceAppName: entry.sourceAppName ?? state.sourceAppName,
            initialKernelMetadata: mergedMetadata,
            captureCurrentSelection: captureLiveSelection
        )

        let invocationRecord = AskPersistentInvocationRecord(
            id: UUID().uuidString.lowercased(),
            recordedAt: Date(),
            sessionOrigin: entry.sessionOrigin,
            invocationSurface: entry.invocationSurface,
            sourceBundleID: entry.sourceBundleID,
            sourceAppName: entry.sourceAppName,
            requestedMode: entry.requestedMode,
            assistantDeliveryChannel: sessionKernelMetadata["latest_assistant_delivery_channel"],
            sourceTaskID: sessionKernelMetadata["assistant_delivery_source_task_id"],
            sourceRunID: sessionKernelMetadata["assistant_delivery_source_run_id"],
            sourceJobID: sessionKernelMetadata["assistant_delivery_source_job_id"],
            activeTaskID: sessionKernelMetadata["active_task_id"],
            activeTaskResumeToken: sessionKernelMetadata["active_task_resume_token"],
            workspaceRoot: sessionKernelMetadata["interactive_task_scope_root"]
                ?? sessionKernelMetadata["active_task_workspace_root"]
                ?? sessionKernelMetadata["workspace_root"],
            isProactive: entry.isProactive,
            proactiveReason: entry.proactiveReason,
            presentationMode: entry.presentationMode
        )
        persistentAskInvocationRecords.append(invocationRecord)
        if persistentAskInvocationRecords.count > 24 {
            persistentAskInvocationRecords = Array(persistentAskInvocationRecords.suffix(24))
        }

        if let suggestedPrompt {
            let trimmedSuggestedPrompt = suggestedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSuggestedPrompt.isEmpty,
               trimmedComposerText().isEmpty,
               !state.isStreaming {
                composerTextView.string = trimmedSuggestedPrompt
                updateComposerMetrics()
                updateComposerPlaceholder()
            }
        }

        updateComposerActionButtonsState(animated: false)
        updateEmptyStateVisibility()
        updateProactiveHintPresentation()
        updateScopeBar()
        if !state.isStreaming {
            persistPersistentAskSessionIfNeeded()
        }
        scheduleSmokeStateSnapshotWrite()
    }

    private func currentAssistantFollowUpPersistenceKey() -> String? {
        guard state.sessionOrigin == .assistantFollowUp else { return nil }
        return activeAssistantFollowUpPersistenceKey
            ?? AskAssistantFollowUpActivation.persistenceKey(from: sessionKernelMetadata)
    }

    private func currentAssistantFollowUpMessageCardSnapshots() -> [AskAssistantFollowUpMessageCardsSnapshot] {
        let messageEntryIDs = transcriptEntries.compactMap { entry -> String? in
            guard case .message(let messageEntry) = entry else { return nil }
            return messageEntry.id
        }
        return state.messages.enumerated().compactMap { index, _ in
            guard messageEntryIDs.indices.contains(index),
                  let cards = messageCitationsByEntryID[messageEntryIDs[index]],
                  !cards.isEmpty else {
                return nil
            }
            return AskAssistantFollowUpMessageCardsSnapshot(messageIndex: index, cards: cards)
        }
    }

    private func currentAssistantFollowUpApprovalSnapshot() -> AskAssistantFollowUpApprovalSnapshot? {
        guard let actionID = pendingApprovalActionID else { return nil }
        return AskAssistantFollowUpApprovalSnapshot(
            actionID: actionID,
            summaryText: pendingApprovalSummaryText,
            messageText: pendingApprovalMessageText,
            previewCards: pendingApprovalPreviewCards
        )
    }

    private func persistAssistantFollowUpSessionIfNeeded() {
        guard !isUsingPersistentAskSessionShell else { return }
        guard let persistenceKey = currentAssistantFollowUpPersistenceKey() else { return }
        guard !state.isStreaming else { return }

        let composerDraft = trimmedComposerText().isEmpty ? nil : composerTextView.string
        let hasPersistentContent =
            !state.messages.isEmpty
            || currentAssistantFollowUpApprovalSnapshot() != nil
            || composerDraft != nil
            || !(sessionKernelMetadata["active_task_resume_token"] ?? "").isEmpty
            || !(sessionKernelMetadata["active_task_id"] ?? "").isEmpty

        guard hasPersistentContent else {
            assistantFollowUpSessionStore.removeSnapshot(for: persistenceKey)
            return
        }

        let frameSnapshot: AskAssistantFollowUpWindowFrameSnapshot? = {
            let frame = panel.frame
            guard frame.width > 0, frame.height > 0 else { return nil }
            return AskAssistantFollowUpWindowFrameSnapshot(rect: frame)
        }()

        let snapshot = AskAssistantFollowUpSessionSnapshot(
            persistenceKey: persistenceKey,
            savedAt: Date(),
            sessionID: state.sessionID,
            sourceBundleID: state.sourceBundleID,
            sourceAppName: state.sourceAppName,
            sessionOrigin: state.sessionOrigin,
            invocationSurface: state.invocationSurface,
            requestedMode: state.requestedMode,
            frame: frameSnapshot,
            kernelMetadata: sessionKernelMetadata,
            latestResponseMetadata: latestResponseMetadata,
            messages: state.messages,
            messageCards: currentAssistantFollowUpMessageCardSnapshots(),
            pendingApproval: currentAssistantFollowUpApprovalSnapshot(),
            composerDraft: composerDraft
        )
        assistantFollowUpSessionStore.save(snapshot)
    }

    private func persistPersistentAskSessionIfNeeded() {
        guard isUsingPersistentAskSessionShell else { return }
        guard !state.isStreaming else { return }

        let composerDraft = trimmedComposerText().isEmpty ? nil : composerTextView.string
        let hasPersistentContent = currentPersistentAskHasPersistableContent()

        guard hasPersistentContent else {
            if deferredPersistentAskSnapshot != nil {
                return
            }
            persistentAskSessionCoordinator.clearPersistedSession()
            return
        }

        let frameSnapshot: AskAssistantFollowUpWindowFrameSnapshot? = {
            let frame = panel.frame
            guard frame.width > 0, frame.height > 0 else { return nil }
            return AskAssistantFollowUpWindowFrameSnapshot(rect: frame)
        }()

        let snapshot = AskPersistentSessionSnapshot(
            persistenceKey: AskPersistentSessionCoordinator.primarySessionKey,
            savedAt: Date(),
            sessionID: state.sessionID,
            sourceBundleID: state.sourceBundleID,
            sourceAppName: state.sourceAppName,
            sessionOrigin: state.sessionOrigin,
            invocationSurface: state.invocationSurface,
            requestedMode: state.requestedMode,
            frame: frameSnapshot,
            kernelMetadata: sessionKernelMetadata,
            latestResponseMetadata: latestResponseMetadata,
            messages: state.messages,
            messageCards: currentAssistantFollowUpMessageCardSnapshots(),
            pendingApproval: currentAssistantFollowUpApprovalSnapshot(),
            composerDraft: composerDraft,
            invocations: persistentAskInvocationRecords
        )
        deferredPersistentAskSnapshot = nil
        persistentAskSessionCoordinator.persist(snapshot)
    }

    private func restorePersistentAskSessionSnapshot(_ snapshot: AskPersistentSessionSnapshot) {
        isUsingPersistentAskSessionShell = true
        persistentAskInvocationRecords = snapshot.invocations
        deferredPersistentAskSnapshot = nil
        activeProactiveHintText = nil
        activeProactiveOpportunityID = nil
        currentProactivePresentationMode = nil
        var restoredState = AskSessionState.make(
            sourceBundleID: snapshot.sourceBundleID,
            sourceAppName: snapshot.sourceAppName,
            sessionOrigin: snapshot.sessionOrigin,
            invocationSurface: snapshot.invocationSurface,
            requestedMode: snapshot.requestedMode,
            sessionID: snapshot.sessionID
        )
        restoredState.messages = snapshot.messages
        restoredState.isStreaming = false
        state = restoredState
        latestResponseMetadata = snapshot.latestResponseMetadata
        sessionKernelMetadata = makeSessionKernelMetadata(
            sourceBundleID: snapshot.sourceBundleID,
            sourceAppName: snapshot.sourceAppName,
            initialKernelMetadata: snapshot.kernelMetadata,
            captureCurrentSelection: false
        )
        latestKernelScopeSummary = nil
        streamingAssistantIndex = nil
        streamingAssistantEntryID = nil
        activeRuntimeStepEntryID = nil
        streamingTargetText = ""
        currentTurnSubmittedAt = nil
        currentTurnReceivedDelta = false
        currentTurnRowUpdateCount = 0
        currentTurnMaxRenderedChunkLength = 0
        resetStreamingHighlight()
        resetPendingStreamingAssistantRowUpdate()
        resetPendingTranscriptViewportRefresh()
        resetTranscriptStreamingSlack()
        hideLoadingStatus(immediately: true)
        rebuildTranscriptFromSnapshot(messages: snapshot.messages, messageCards: snapshot.messageCards)

        if let pendingApproval = snapshot.pendingApproval {
            pendingApprovalActionID = pendingApproval.actionID
            pendingApprovalSummaryText = pendingApproval.summaryText
            pendingApprovalMessageText = pendingApproval.messageText
            pendingApprovalPreviewCards = pendingApproval.previewCards
        } else {
            clearPendingApprovalState()
        }

        composerTextView.string = snapshot.composerDraft ?? ""
        updateComposerPlaceholder()
        updateProactiveHintPresentation()
        updateComposerMetrics()
        updateComposerActionButtonsState(animated: false)
        updatePendingApprovalCard()
        updateEmptyStateVisibility()
        refreshTaskContinuityStep()
        updateScopeBar()
        if !state.messages.isEmpty {
            scrollTranscriptToBottom()
        }
        scheduleSmokeStateSnapshotWrite()
    }

    private func restoreLegacyAssistantFollowUpSessionSnapshot(_ snapshot: AskAssistantFollowUpSessionSnapshot) {
        activeProactiveHintText = nil
        activeProactiveOpportunityID = nil
        currentProactivePresentationMode = nil
        var restoredState = AskSessionState.make(
            sourceBundleID: snapshot.sourceBundleID,
            sourceAppName: snapshot.sourceAppName,
            sessionOrigin: snapshot.sessionOrigin,
            invocationSurface: snapshot.invocationSurface,
            requestedMode: snapshot.requestedMode,
            sessionID: snapshot.sessionID
        )
        restoredState.messages = snapshot.messages
        restoredState.isStreaming = false
        state = restoredState
        activeAssistantFollowUpPersistenceKey = snapshot.persistenceKey
        latestResponseMetadata = snapshot.latestResponseMetadata
        sessionKernelMetadata = makeSessionKernelMetadata(
            sourceBundleID: snapshot.sourceBundleID,
            sourceAppName: snapshot.sourceAppName,
            initialKernelMetadata: snapshot.kernelMetadata,
            captureCurrentSelection: false
        )
        latestKernelScopeSummary = nil
        streamingAssistantIndex = nil
        streamingAssistantEntryID = nil
        activeRuntimeStepEntryID = nil
        streamingTargetText = ""
        currentTurnSubmittedAt = nil
        currentTurnReceivedDelta = false
        currentTurnRowUpdateCount = 0
        currentTurnMaxRenderedChunkLength = 0
        resetStreamingHighlight()
        resetPendingStreamingAssistantRowUpdate()
        resetPendingTranscriptViewportRefresh()
        resetTranscriptStreamingSlack()
        hideLoadingStatus(immediately: true)
        rebuildTranscriptFromSnapshot(messages: snapshot.messages, messageCards: snapshot.messageCards)

        if let pendingApproval = snapshot.pendingApproval {
            pendingApprovalActionID = pendingApproval.actionID
            pendingApprovalSummaryText = pendingApproval.summaryText
            pendingApprovalMessageText = pendingApproval.messageText
            pendingApprovalPreviewCards = pendingApproval.previewCards
        } else {
            clearPendingApprovalState()
        }

        composerTextView.string = snapshot.composerDraft ?? ""
        updateComposerPlaceholder()
        updateProactiveHintPresentation()
        updateComposerMetrics()
        updateComposerActionButtonsState(animated: false)
        updatePendingApprovalCard()
        updateEmptyStateVisibility()
        refreshTaskContinuityStep()
        updateScopeBar()
        if !state.messages.isEmpty {
            scrollTranscriptToBottom()
        }
        scheduleSmokeStateSnapshotWrite()
    }

    private func rebuildTranscriptFromSnapshot(
        messages: [AskMessage],
        messageCards: [AskAssistantFollowUpMessageCardsSnapshot]
    ) {
        transcriptEntries.removeAll()
        transcriptMessageRowViewsByEntryID.removeAll()
        transcriptRuntimeStepRowViewsByEntryID.removeAll()
        messageCitationsByEntryID.removeAll()

        let cardsByMessageIndex = Dictionary(uniqueKeysWithValues: messageCards.map { ($0.messageIndex, $0.cards) })
        for (index, message) in messages.enumerated() {
            let entryID = UUID().uuidString.lowercased()
            transcriptEntries.append(.message(TranscriptMessageEntry(id: entryID, message: message)))
            if let cards = cardsByMessageIndex[index], !cards.isEmpty {
                messageCitationsByEntryID[entryID] = cards
            }
        }
        renderTranscript()
    }

    private func startStreamingTurn(with prompt: String) {
        let userMessage = AskMessage(role: .user, content: prompt)
        state.messages.append(userMessage)
        appendTranscriptMessageEntry(userMessage)
        state.isStreaming = true
        activeProactiveHintText = nil
        activeProactiveOpportunityID = nil
        currentProactivePresentationMode = nil
        composerTextView.string = ""
        updateComposerPlaceholder()
        updateProactiveHintPresentation()
        updateComposerMetrics()
        updateComposerActionButtonsState(animated: true)
        streamingTargetText = ""
        streamingAssistantIndex = nil
        streamingAssistantEntryID = nil
        activeRuntimeStepEntryID = nil
        hideLoadingStatus(immediately: true)
        currentTurnSubmittedAt = Date()
        currentTurnReceivedDelta = false
        currentTurnRowUpdateCount = 0
        currentTurnMaxRenderedChunkLength = 0
        resetStreamingHighlight()
        resetPendingTranscriptViewportRefresh()
        prepareTranscriptStreamingSlackIfNeeded()
        scrollTranscriptToBottom()
        showLoadingStatus(
            status: "thinking",
            detail: L10n.text(
                languageCode: resolvedResponseLanguage(),
                zhHans: "正在思考…",
                en: "Thinking…"
            )
        )
        appendSmokeViewportTrace(reason: "stream_start")
        updateScopeBar()
    }

    func runSmokePrompt(_ prompt: String, traceFilePath: String? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        configureSmokeViewportTrace(filePath: traceFilePath)
        prepareSmokePrompt(trimmed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.submitCurrentPrompt()
        }
    }

    func prepareSmokePrompt(_ prompt: String, traceFilePath: String? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        configureSmokeViewportTrace(filePath: traceFilePath)
        prepareSmokePrompt(trimmed)
    }

    private func prepareSmokePrompt(_ prompt: String) {
        composerTextView.string = prompt
        updateComposerPlaceholder()
        updateEmptyStateVisibility()
        updateComposerMetrics()
        updateComposerActionButtonsState(animated: false)
        scheduleSmokeStateSnapshotWrite()
    }

    func configureSmokeStateSnapshot(filePath: String?) {
        guard let trimmedPath = filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedPath.isEmpty else {
            pendingSmokeStateSnapshotWriteWorkItem?.cancel()
            pendingSmokeStateSnapshotWriteWorkItem = nil
            smokeStateSnapshotFileURL = nil
            return
        }

        let fileURL = URL(fileURLWithPath: trimmedPath)
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            smokeStateSnapshotFileURL = fileURL
            scheduleSmokeStateSnapshotWrite(immediately: true)
        } catch {
            diagnosticsLogger.log(
                "ask.smoke",
                "failed to create state snapshot directory path=\(trimmedPath) error=\(error.localizedDescription)"
            )
            smokeStateSnapshotFileURL = nil
        }
    }

    func configureSmokeViewportTrace(filePath: String?) {
        finalizeSmokeViewportTrace(reason: "trace_reset")
        guard let trimmedPath = filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedPath.isEmpty else {
            return
        }

        let fileURL = URL(fileURLWithPath: trimmedPath)
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            try Data().write(to: fileURL, options: .atomic)
            smokeViewportTraceFileURL = fileURL
            smokeViewportTraceSequence = 0
            appendSmokeViewportTrace(reason: "trace_enabled")
        } catch {
            diagnosticsLogger.log(
                "ask.smoke",
                "failed to create viewport trace file path=\(trimmedPath) error=\(error.localizedDescription)"
            )
            smokeViewportTraceFileURL = nil
            smokeViewportTraceSequence = 0
        }
    }

    private func scheduleSmokeStateSnapshotWrite(immediately: Bool = false) {
        guard smokeStateSnapshotFileURL != nil else { return }
        pendingSmokeStateSnapshotWriteWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let fileURL = self.smokeStateSnapshotFileURL else { return }
            self.pendingSmokeStateSnapshotWriteWorkItem = nil
            self.writeSmokeStateSnapshot(to: fileURL)
        }
        pendingSmokeStateSnapshotWriteWorkItem = workItem

        if immediately {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Layout.streamingUpdateFrameInterval,
                execute: workItem
            )
        }
    }

    func runSyntheticSmokeReply(
        prompt: String,
        response: String,
        chunkSize: Int = 8,
        chunkInterval: TimeInterval = 1.0 / 60.0,
        traceFilePath: String? = nil
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedResponse = response
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !normalizedResponse.isEmpty else { return }

        cancelCurrentRequest()
        configureSmokeViewportTrace(filePath: traceFilePath)
        startStreamingTurn(with: trimmedPrompt)

        let chunks = syntheticResponseChunks(
            from: normalizedResponse,
            chunkSize: max(1, chunkSize)
        )
        var fullText = ""
        syntheticStreamingWorkItems.removeAll(keepingCapacity: true)

        for (index, chunk) in chunks.enumerated() {
            fullText += chunk
            let expectedFullText = fullText
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.handleStreamEvent(.delta(chunk, fullText: expectedFullText))
            }
            syntheticStreamingWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (chunkInterval * Double(index + 1)),
                execute: workItem
            )
        }

        let completionItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.syntheticStreamingWorkItems.removeAll(keepingCapacity: true)
            self.handleCompletion(
                .success(
                    AskSessionResponse(
                        message: normalizedResponse,
                        cards: [],
                        metadata: ["source": "synthetic_smoke"]
                    )
                )
            )
        }
        syntheticStreamingWorkItems.append(completionItem)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (chunkInterval * Double(chunks.count + 1)),
            execute: completionItem
        )
    }

    func windowWillClose(_ notification: Notification) {
        cancelCurrentRequest()
        removeSendButtonGlobalFallbackMonitor()
        restoreActivationPolicyIfNeeded()
        onVisibilityChanged?(false)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel else { return frameSize }
        return clampedPanelSize(for: frameSize)
    }

    func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        guard !isRunningEntranceAnimation else { return }
        restorePanelResizeBounds()
        enforcePanelComfortBoundsIfNeeded()
        updateTranscriptDocumentFrame()
        updateComposerMetrics()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !isRunningEntranceAnimation else { return }
        diagnosticsLogger.log("ask.click", diagnosticSessionState(prefix: "window_did_become_key"))
        finalizeSmokeViewportTrace(reason: "completion")
    }

    func windowDidResignKey(_ notification: Notification) {
        diagnosticsLogger.log("ask.click", diagnosticSessionState(prefix: "window_did_resign_key"))
        composerHasFocus = false
        updateComposerPlaceholder()
        updateComposerContainerAppearance(animated: true)
    }

    func textDidBeginEditing(_ notification: Notification) {
        ensureInteractiveActivationAfterComposerInput()
        diagnosticsLogger.log("ask.click", diagnosticSessionState(prefix: "composer_begin_edit"))
        composerHasFocus = true
        updateComposerPlaceholder()
        updateComposerContainerAppearance(animated: true)
    }

    func textDidEndEditing(_ notification: Notification) {
        diagnosticsLogger.log("ask.click", diagnosticSessionState(prefix: "composer_end_edit"))
        composerHasFocus = false
        updateComposerPlaceholder()
        updateComposerContainerAppearance(animated: true)
    }

    func textDidChange(_ notification: Notification) {
        ensureInteractiveActivationAfterComposerInput()
        diagnosticsLogger.log(
            "ask.click",
            diagnosticSessionState(prefix: "composer_change chars=\(composerTextView.string.count)")
        )
        updateComposerPlaceholder()
        updateEmptyStateVisibility()
        updateComposerMetrics()
        updateComposerActionButtonsState(animated: true)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard notification.object as? NSTextView === composerTextView else { return }
        updateComposerMetrics()
    }

    @objc private func handleCloseButton() {
        hide()
    }

    @objc private func handleSendButton() {
        diagnosticsLogger.log("ask.click", diagnosticSessionState(prefix: "send_button_action"))
        submitCurrentPrompt()
    }

    @objc private func handleSaveAutomationButton() {
        guard !state.isStreaming else { return }
        if pendingAutomationDraft != nil {
            savePendingAutomationDraft()
            return
        }

        guard let sourceText = automationSourceTextForComposerAction() else {
            appendLocalRuntimeStep(
                title: L10n.text(zhHans: "没有可保存的任务描述", en: "Nothing to save as an automation"),
                detail: L10n.text(zhHans: "先输入一条自然语言规则，或在完成一次 Ask 后再试。", en: "Enter a natural-language schedule first, or try again after an Ask turn."),
                state: .blocked
            )
            return
        }

        guard let draft = automationDraftParser.parse(
            sourceText,
            workspaceRoot: sessionKernelMetadata["workspace_root"]
        ) else {
            appendLocalRuntimeStep(
                title: L10n.text(zhHans: "没能解析这条定时规则", en: "Couldn't parse this automation rule"),
                detail: L10n.text(zhHans: "试试包含像“每天 9 点”“每周一 10 点”这样的时间表达。", en: "Try including time language like “every day at 9” or “every Monday at 10”."),
                state: .blocked
            )
            return
        }

        presentAutomationDraft(draft, prompt: sourceText)
    }

    @objc private func handleContinueAutomationDraft() {
        guard let prompt = pendingAutomationPrompt ?? automationSourceTextForComposerAction() else { return }
        submitPrompt(prompt)
    }

    @objc private func handleSaveAutomationDraft() {
        savePendingAutomationDraft()
    }

    @objc private func handleDismissAutomationDraft() {
        dismissAutomationDraft(clearComposer: false)
    }

    private func handlePanelPrimaryMouseDown(_ event: NSEvent) -> Bool {
        guard shouldBeginWindowDrag(at: event.locationInWindow) else {
            return false
        }
        panel.performDrag(with: event)
        return true
    }

    private func shouldBeginWindowDrag(at windowPoint: NSPoint) -> Bool {
        guard panel.isVisible else { return false }

        let pointInHeader = headerDragRegionView.convert(windowPoint, from: nil)
        guard headerDragRegionView.bounds.contains(pointInHeader) else {
            return false
        }

        let pointInCloseButton = closeButton.convert(windowPoint, from: nil)
        if closeButton.bounds.contains(pointInCloseButton) {
            return false
        }

        let pointInHostView = hostView.convert(windowPoint, from: nil)
        guard let hitView = hostView.hitTest(pointInHostView) else {
            return true
        }
        if hitView === closeButton || hitView.isDescendant(of: closeButton) {
            return false
        }
        return hitView === headerDragRegionView || hitView.isDescendant(of: headerDragRegionView)
    }

    private func handleSendButtonPrimaryMouseDown(_ event: NSEvent) -> Bool {
        guard panel.isVisible,
              hasPendingComposerSubmission,
              !state.isStreaming else {
            return false
        }

        let pointInButton = sendButton.convert(event.locationInWindow, from: nil)
        guard sendButton.bounds.contains(pointInButton) else {
            return false
        }

        diagnosticsLogger.log("ask.click", diagnosticSessionState(prefix: "send_button_primary_submit"))
        submitCurrentPrompt()
        return true
    }

    private func handleStreamEvent(_ event: AskSessionStreamEvent) {
        switch event {
        case .status(let status, let detail):
            updateActiveRuntimeStepDetail(with: detail)
            if activeRuntimeStepEntryID == nil {
                showLoadingStatus(status: status, detail: detail)
            }
        case .runtimeStep(let step):
            diagnosticsLogger.log(
                "ask.ui",
                "session=\(state.sessionID) runtime_step kind=\(step.kind.rawValue) state=\(step.state.rawValue) title=\(step.title)"
            )
            hideLoadingStatus()
            upsertRuntimeStep(step)
        case .assistantPreamble(let text):
            diagnosticsLogger.log(
                "ask.ui",
                "session=\(state.sessionID) preamble chars=\(text.count) elapsed_ms=\(elapsedSinceCurrentTurnSubmission())"
            )
            hideLoadingStatus()
            appendAssistantPreamble(text)
        case .delta(let delta, let fullText):
            if !currentTurnReceivedDelta {
                currentTurnReceivedDelta = true
                diagnosticsLogger.log(
                    "ask.ui",
                    "session=\(state.sessionID) first_delta delta_chars=\(delta.count) full_chars=\(fullText.count) elapsed_ms=\(elapsedSinceCurrentTurnSubmission())"
                )
            }
            hideLoadingStatus()
            appendAssistantDelta(delta: delta, fullText: fullText)
        case .done(let response):
            diagnosticsLogger.log(
                "ask.ui",
                "session=\(state.sessionID) done chars=\(response.message.count) had_delta=\(currentTurnReceivedDelta) elapsed_ms=\(elapsedSinceCurrentTurnSubmission())"
            )
            hideLoadingStatus()
        case .failed(let message, let detail):
            diagnosticsLogger.log(
                "ask.ui",
                "session=\(state.sessionID) failed had_delta=\(currentTurnReceivedDelta) elapsed_ms=\(elapsedSinceCurrentTurnSubmission()) message=\((detail ?? message).trimmingCharacters(in: .whitespacesAndNewlines))"
            )
            if let activeRuntimeStepEntryID {
                upsertRuntimeStep(
                    AskRuntimeStepEvent(
                        id: activeRuntimeStepEntryID,
                        kind: .executionResult,
                        title: L10n.text(zhHans: "这一步执行失败", en: "Step failed"),
                        detail: detail ?? message,
                        state: .failed
                    )
                )
            } else {
                showLoadingStatus(status: "failed", detail: detail ?? message)
            }
        }
    }

    private func handleCompletion(_ result: Result<AskSessionResponse, Error>) {
        currentTask = nil
        state.isStreaming = false
        flushPendingStreamingAssistantRowUpdateIfNeeded()
        flushPendingTranscriptViewportRefreshIfNeeded()
        hideLoadingStatus()
        updateComposerActionButtonsState(animated: true)
        var shouldRefocusComposerAfterCompletion = true
        switch result {
        case .success(let response):
            syncPendingApprovalState(from: response)
            applyResponseMetadata(response.metadata)
            refreshKernelResultSummaryIfNeeded(sessionID: state.sessionID)
            shouldRefocusComposerAfterCompletion = shouldRefocusComposer(after: response)
            let authoritativeText = authoritativeAssistantContent(finalMessage: response.message)
            diagnosticsLogger.log(
                "ask.ui",
                "session=\(state.sessionID) completion final_chars=\(authoritativeText.count) row_updates=\(currentTurnRowUpdateCount) max_row_chunk=\(currentTurnMaxRenderedChunkLength)"
            )
            if shouldSuppressAssistantTranscript(for: response) {
                discardStreamingAssistantMessageIfNeeded()
            } else {
                if let index = streamingAssistantIndex,
                   state.messages.indices.contains(index) {
                    state.messages[index] = AskMessage(role: .assistant, content: authoritativeText)
                }
                streamingTargetText = authoritativeText
                if let entryID = streamingAssistantEntryID,
                   let row = transcriptMessageRowViewsByEntryID[entryID] {
                    row.updateStreamingAssistant(
                        fullText: authoritativeText,
                        appendedChunk: "",
                        citations: messageCitationsByEntryID[entryID] ?? response.cards,
                        highlightedSuffixLength: 0,
                        highlightedAlpha: 1,
                        finalizeFormatting: true
                    )
                    diagnosticsLogger.log(
                        "ask.render",
                        "session=\(state.sessionID) finalize entry=\(entryID) authoritative_chars=\(authoritativeText.count) rendered_chars=\(row.renderedAssistantFullTextLength)"
                    )
                    scheduleTranscriptViewportRefresh(scrollToBottom: true)
                    settleTranscriptViewport(scrollToBottom: true)
                }
            }
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            pendingApprovalCardSuppressed = false
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            finalizeAssistantMessage(
                AskSessionResponse(
                    message: message.isEmpty ? L10n.text(zhHans: "Ask 会话失败。", en: "The Ask session failed.") : message,
                    cards: [],
                    metadata: [:]
                )
            )
        }
        currentTurnSubmittedAt = nil
        currentTurnReceivedDelta = false
        currentTurnRowUpdateCount = 0
        currentTurnMaxRenderedChunkLength = 0
        resetStreamingHighlight()
        resetTranscriptStreamingSlack()
        updatePendingApprovalCard()
        updateScopeBar()
        persistActiveSessionIfNeeded()
        if shouldRefocusComposerAfterCompletion {
            focusComposer()
        }
    }

    private func shouldSuppressAssistantTranscript(for response: AskSessionResponse) -> Bool {
        response.metadata["agent_state"] == "waiting_approval"
            && !(response.metadata["pending_approval_action_id"] ?? "").isEmpty
    }

    private func discardStreamingAssistantMessageIfNeeded() {
        if let index = streamingAssistantIndex,
           state.messages.indices.contains(index),
           state.messages[index].role == .assistant {
            state.messages.remove(at: index)
        }
        if let entryID = streamingAssistantEntryID {
            messageCitationsByEntryID.removeValue(forKey: entryID)
            removeTranscriptEntry(withID: entryID)
        }
        streamingAssistantIndex = nil
        streamingAssistantEntryID = nil
        streamingTargetText = ""
        resetStreamingHighlight()
    }

    private func appendAssistantDelta(delta: String, fullText: String) {
        let normalizedDelta = delta.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalizedDelta.isEmpty else { return }
        let normalizedFullText = fullText.replacingOccurrences(of: "\r\n", with: "\n")

        if let index = streamingAssistantIndex,
           state.messages.indices.contains(index) {
            let current = state.messages[index].content
            let expectedTarget = normalizedFullText.isEmpty ? current + normalizedDelta : normalizedFullText
            if !expectedTarget.hasPrefix(current) {
                prepareForNewStreamedAssistantMessage()
            }
        }

        let entryID = ensureStreamingAssistantEntry()
        if transcriptMessageRowViewsByEntryID[entryID] == nil {
            renderTranscript()
        }
        guard let index = streamingAssistantIndex, state.messages.indices.contains(index) else { return }

        let currentContent = state.messages[index].content
        let targetText = normalizedFullText.isEmpty ? currentContent + normalizedDelta : normalizedFullText
        let appendedText: String
        if targetText.hasPrefix(currentContent) {
            appendedText = String(targetText.dropFirst(currentContent.count))
        } else {
            appendedText = normalizedDelta
        }

        guard !appendedText.isEmpty else { return }
        let highlightLength = renderedAssistantHighlightLength(
            from: currentContent,
            to: targetText,
            fallbackRawDelta: appendedText
        )
        streamingTargetText = targetText
        state.messages[index] = AskMessage(role: .assistant, content: targetText)
        beginStreamingHighlight(entryID: entryID, suffixLength: highlightLength)
        updateStreamingAssistantRow(
            entryID: entryID,
            appendedChunk: appendedText,
            finalizeFormatting: false
        )
    }

    private func completeAssistantMessage(_ response: AskSessionResponse) {
        flushPendingStreamingAssistantRowUpdateIfNeeded()
        let trimmed = response.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let previousTargetText = streamingTargetText
        let authoritativeText = authoritativeAssistantContent(finalMessage: trimmed)
        if let index = streamingAssistantIndex,
           state.messages.indices.contains(index) {
            state.messages[index] = AskMessage(role: .assistant, content: authoritativeText)
        }
        streamingTargetText = authoritativeText

        if let entryID = streamingAssistantEntryID,
           normalizedStreamingText(previousTargetText) == normalizedStreamingText(authoritativeText) {
            messageCitationsByEntryID[entryID] = response.cards
            if let row = transcriptMessageRowViewsByEntryID[entryID] {
                row.updateStreamingAssistant(
                    fullText: authoritativeText,
                    appendedChunk: "",
                    citations: response.cards,
                    highlightedSuffixLength: 0,
                    highlightedAlpha: 1,
                    finalizeFormatting: true
                )
                scheduleTranscriptViewportRefresh(scrollToBottom: true)
                settleTranscriptViewport(scrollToBottom: true)
            }
            streamingAssistantIndex = nil
            streamingAssistantEntryID = nil
            streamingTargetText = ""
            resetStreamingHighlight()
            return
        }

        let lastAssistantEntryID = transcriptEntries.reversed().compactMap { entry -> String? in
            guard case .message(let messageEntry) = entry, messageEntry.message.role == .assistant else {
                return nil
            }
            return messageEntry.id
        }.first
        let lastCitations = lastAssistantEntryID.flatMap { messageCitationsByEntryID[$0] } ?? []
        if state.messages.last?.role != .assistant ||
            state.messages.last?.content != response.message ||
            lastCitations != response.cards {
            finalizeAssistantMessage(response)
        }
    }

    private func finalizeAssistantMessage(_ response: AskSessionResponse) {
        flushPendingStreamingAssistantRowUpdateIfNeeded()
        let trimmed = response.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        prepareForNewStreamedAssistantMessage()
        streamingTargetText = trimmed
        let entryID = ensureStreamingAssistantEntry()
        guard let index = streamingAssistantIndex, state.messages.indices.contains(index) else { return }
        state.messages[index] = AskMessage(role: .assistant, content: trimmed)
        messageCitationsByEntryID[entryID] = response.cards
        updateStreamingAssistantRow(entryID: entryID, appendedChunk: trimmed, finalizeFormatting: true)
        streamingAssistantIndex = nil
        streamingAssistantEntryID = nil
        streamingTargetText = ""
        resetStreamingHighlight()
        if transcriptMessageRowViewsByEntryID[entryID] == nil {
            renderTranscript()
        }
    }

    private func appendAssistantPreamble(_ text: String) {
        flushPendingStreamingAssistantRowUpdateIfNeeded()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        prepareForNewStreamedAssistantMessage()
        streamingTargetText = trimmed
        let entryID = ensureStreamingAssistantEntry()
        guard let index = streamingAssistantIndex, state.messages.indices.contains(index) else { return }
        state.messages[index] = AskMessage(role: .assistant, content: trimmed)
        updateStreamingAssistantRow(entryID: entryID, appendedChunk: trimmed, finalizeFormatting: true)
        if transcriptMessageRowViewsByEntryID[entryID] == nil {
            renderTranscript()
        }
    }

    private func prepareForNewStreamedAssistantMessage() {
        flushPendingStreamingAssistantRowUpdateIfNeeded()
        guard let index = streamingAssistantIndex,
              state.messages.indices.contains(index),
              let entryID = streamingAssistantEntryID else {
            return
        }

        if !streamingTargetText.isEmpty {
            state.messages[index] = AskMessage(role: .assistant, content: streamingTargetText)
            if let transcriptIndex = transcriptEntries.firstIndex(where: { $0.id == entryID }) {
                transcriptEntries[transcriptIndex] = .message(
                    TranscriptMessageEntry(id: entryID, message: state.messages[index])
                )
            }
            transcriptMessageRowViewsByEntryID[entryID]?.updateStreamingAssistant(
                fullText: streamingTargetText,
                appendedChunk: "",
                citations: messageCitationsByEntryID[entryID] ?? [],
                highlightedSuffixLength: 0,
                highlightedAlpha: 1,
                finalizeFormatting: true
            )
        }

        streamingAssistantIndex = nil
        streamingAssistantEntryID = nil
        streamingTargetText = ""
        resetStreamingHighlight()
    }

    @discardableResult
    private func ensureStreamingAssistantEntry() -> String {
        if let index = streamingAssistantIndex,
           state.messages.indices.contains(index),
           let entryID = streamingAssistantEntryID {
            return entryID
        }

        state.messages.append(AskMessage(role: .assistant, content: ""))
        streamingAssistantIndex = state.messages.count - 1
        let entryID = appendTranscriptMessageEntry(AskMessage(role: .assistant, content: ""))
        streamingAssistantEntryID = entryID
        return entryID
    }

    private func configureUI() {
        guard let contentView = panel.contentView else { return }
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor

        panelSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        panelSurfaceView.wantsLayer = true
        panelSurfaceView.tintOpacityOverride = DesignTokens.ConversationPanel.panelTintOpacity
        panelSurfaceView.refreshAppearance()
        panelSurfaceView.ambientEffectStyle = .conversationPanel

        entranceFlowOverlayView.translatesAutoresizingMaskIntoConstraints = false
        entranceFlowOverlayView.wantsLayer = true
        entranceFlowOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        configureEntranceFlowLayers()

        titleLabel.font = DesignTokens.ConversationPanel.Typography.title
        titleLabel.textColor = DesignTokens.ConversationPanel.Text.title
        titleLabel.isSelectable = false

        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "close")
        closeButton.contentTintColor = DesignTokens.Color.textSecondary
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(handleCloseButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.wantsLayer = true
        closeButton.hoverScale = 1
        closeButton.widthAnchor.constraint(equalToConstant: Layout.closeButtonSize).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: Layout.closeButtonSize).isActive = true
        closeButton.onHoverChanged = { [weak self] _ in
            self?.updateCloseButtonAppearance(animated: true)
        }

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = DesignTokens.Color.divider.withAlphaComponent(0.8).cgColor
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        loadingLineEffectController.configure()

        let header = NSStackView(views: [titleLabel, NSView(), closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        headerDragRegionView.translatesAutoresizingMaskIntoConstraints = false
        headerDragRegionView.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerDragRegionView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerDragRegionView.trailingAnchor),
            header.topAnchor.constraint(equalTo: headerDragRegionView.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerDragRegionView.bottomAnchor),
            headerDragRegionView.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.closeButtonSize)
        ])

        proactiveHintContainer.translatesAutoresizingMaskIntoConstraints = false
        proactiveHintContainer.isHidden = true

        proactiveHintLabel.translatesAutoresizingMaskIntoConstraints = false
        proactiveHintLabel.font = DesignTokens.ConversationPanel.Typography.stripMeta
        proactiveHintLabel.textColor = DesignTokens.ConversationPanel.Text.meta
        proactiveHintLabel.maximumNumberOfLines = 1
        proactiveHintLabel.lineBreakMode = .byTruncatingTail

        proactiveHintContainer.addSubview(proactiveHintLabel)
        NSLayoutConstraint.activate([
            proactiveHintLabel.leadingAnchor.constraint(equalTo: proactiveHintContainer.leadingAnchor),
            proactiveHintLabel.trailingAnchor.constraint(equalTo: proactiveHintContainer.trailingAnchor),
            proactiveHintLabel.topAnchor.constraint(equalTo: proactiveHintContainer.topAnchor),
            proactiveHintLabel.bottomAnchor.constraint(equalTo: proactiveHintContainer.bottomAnchor)
        ])

        scopeBarContainer.translatesAutoresizingMaskIntoConstraints = false
        configureChromeSurface(
            scopeBarContainer,
            fill: DesignTokens.ConversationPanel.Surface.contextFill,
            border: DesignTokens.ConversationPanel.Surface.contextBorder
        )

        scopeBarStack.orientation = .vertical
        scopeBarStack.alignment = .leading
        scopeBarStack.spacing = Layout.compactCardStackSpacing
        scopeBarStack.translatesAutoresizingMaskIntoConstraints = false

        [scopeSourceLabel, scopePermissionsLabel, scopeStatusLabel].forEach { label in
            label.translatesAutoresizingMaskIntoConstraints = false
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        scopeSourceLabel.font = DesignTokens.ConversationPanel.Typography.stripTitle
        scopeSourceLabel.textColor = DesignTokens.ConversationPanel.Text.title
        scopePermissionsLabel.font = DesignTokens.ConversationPanel.Typography.stripMeta
        scopePermissionsLabel.textColor = DesignTokens.ConversationPanel.Text.meta
        scopeStatusLabel.font = DesignTokens.ConversationPanel.Typography.stripDetail
        scopeStatusLabel.textColor = DesignTokens.ConversationPanel.Text.detail

        [scopeSourceLabel, scopePermissionsLabel, scopeStatusLabel].forEach {
            scopeBarStack.addArrangedSubview($0)
        }
        scopeBarContainer.addSubview(scopeBarStack)
        NSLayoutConstraint.activate([
            scopeBarStack.leadingAnchor.constraint(equalTo: scopeBarContainer.leadingAnchor, constant: Layout.scopeCardInset),
            scopeBarStack.trailingAnchor.constraint(equalTo: scopeBarContainer.trailingAnchor, constant: -Layout.scopeCardInset),
            scopeBarStack.topAnchor.constraint(equalTo: scopeBarContainer.topAnchor, constant: Layout.scopeCardInset),
            scopeBarStack.bottomAnchor.constraint(equalTo: scopeBarContainer.bottomAnchor, constant: -Layout.scopeCardInset)
        ])

        sessionModeContainer.translatesAutoresizingMaskIntoConstraints = false
        configureChromeSurface(
            sessionModeContainer,
            fill: DesignTokens.ConversationPanel.Surface.sessionFill,
            border: DesignTokens.ConversationPanel.Surface.sessionBorder
        )
        sessionModeContainer.isHidden = true

        [sessionModeEyebrowLabel, sessionModeTitleLabel, sessionModeMetaLabel, sessionModeDetailLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.lineBreakMode = .byTruncatingTail
        }
        sessionModeEyebrowLabel.font = DesignTokens.ConversationPanel.Typography.stripEyebrow
        sessionModeEyebrowLabel.textColor = DesignTokens.ConversationPanel.Text.eyebrow
        sessionModeTitleLabel.font = DesignTokens.ConversationPanel.Typography.stripTitle
        sessionModeTitleLabel.textColor = DesignTokens.ConversationPanel.Text.title
        sessionModeTitleLabel.maximumNumberOfLines = 1
        sessionModeMetaLabel.font = DesignTokens.ConversationPanel.Typography.stripMeta
        sessionModeMetaLabel.textColor = DesignTokens.ConversationPanel.Text.meta
        sessionModeMetaLabel.maximumNumberOfLines = Layout.compactCardMaxMetaLines
        sessionModeDetailLabel.font = DesignTokens.ConversationPanel.Typography.stripDetail
        sessionModeDetailLabel.textColor = DesignTokens.ConversationPanel.Text.detail
        sessionModeDetailLabel.maximumNumberOfLines = Layout.compactCardMaxDetailLines

        let sessionModeStack = NSStackView(views: [
            sessionModeEyebrowLabel,
            sessionModeTitleLabel,
            sessionModeMetaLabel,
            sessionModeDetailLabel
        ])
        sessionModeStack.translatesAutoresizingMaskIntoConstraints = false
        sessionModeStack.orientation = .vertical
        sessionModeStack.alignment = .leading
        sessionModeStack.spacing = Layout.compactCardStackSpacing

        sessionModeContainer.addSubview(sessionModeStack)
        NSLayoutConstraint.activate([
            sessionModeStack.leadingAnchor.constraint(equalTo: sessionModeContainer.leadingAnchor, constant: Layout.scopeCardInset),
            sessionModeStack.trailingAnchor.constraint(equalTo: sessionModeContainer.trailingAnchor, constant: -Layout.scopeCardInset),
            sessionModeStack.topAnchor.constraint(equalTo: sessionModeContainer.topAnchor, constant: Layout.scopeCardInset),
            sessionModeStack.bottomAnchor.constraint(equalTo: sessionModeContainer.bottomAnchor, constant: -Layout.scopeCardInset)
        ])

        pendingApprovalContainer.translatesAutoresizingMaskIntoConstraints = false
        configureChromeSurface(
            pendingApprovalContainer,
            fill: DesignTokens.ConversationPanel.Surface.approvalFill,
            border: DesignTokens.ConversationPanel.Surface.approvalBorder
        )
        pendingApprovalContainer.isHidden = true
        pendingApprovalContainer.setAccessibilityIdentifier(AppBrand.accessibilityIdentifier("ask.pending_approval"))
        pendingApprovalContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.pendingApprovalInlineMinimumHeight).isActive = true

        pendingApprovalTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        pendingApprovalTitleLabel.font = DesignTokens.ConversationPanel.Typography.stripTitle
        pendingApprovalTitleLabel.textColor = DesignTokens.ConversationPanel.Text.title
        pendingApprovalTitleLabel.lineBreakMode = .byTruncatingTail
        pendingApprovalTitleLabel.maximumNumberOfLines = 1
        pendingApprovalTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pendingApprovalTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pendingApprovalDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        pendingApprovalDetailLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        pendingApprovalDetailLabel.textColor = DesignTokens.Color.textSecondary
        pendingApprovalDetailLabel.lineBreakMode = .byWordWrapping
        pendingApprovalDetailLabel.maximumNumberOfLines = Layout.compactCardMaxDetailLines
        pendingApprovalDetailLabel.isHidden = true

        pendingApprovalPreviewStack.translatesAutoresizingMaskIntoConstraints = false
        pendingApprovalPreviewStack.orientation = .vertical
        pendingApprovalPreviewStack.alignment = .leading
        pendingApprovalPreviewStack.spacing = 6
        pendingApprovalPreviewStack.isHidden = true

        [pendingApprovalConfirmButton, pendingApprovalCancelButton].forEach { button in
            button.isBordered = false
            button.focusRingType = .none
            button.font = DesignTokens.ConversationPanel.Typography.button
            button.translatesAutoresizingMaskIntoConstraints = false
            button.hoverScale = 1
            button.wantsLayer = true
            button.layer?.cornerRadius = DesignTokens.ConversationPanel.buttonCornerRadius
            button.layer?.masksToBounds = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.pendingApprovalInlineButtonWidth).isActive = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        pendingApprovalConfirmButton.target = self
        pendingApprovalConfirmButton.action = #selector(handleApprovePendingApproval)
        pendingApprovalConfirmButton.setAccessibilityIdentifier(AppBrand.accessibilityIdentifier("ask.pending_approval.confirm"))
        pendingApprovalConfirmButton.onHoverChanged = { [weak self] _ in
            self?.updatePendingApprovalButtonAppearance(animated: true)
        }
        pendingApprovalCancelButton.target = self
        pendingApprovalCancelButton.action = #selector(handleCancelPendingApproval)
        pendingApprovalCancelButton.setAccessibilityIdentifier(AppBrand.accessibilityIdentifier("ask.pending_approval.cancel"))
        pendingApprovalCancelButton.onHoverChanged = { [weak self] _ in
            self?.updatePendingApprovalButtonAppearance(animated: true)
        }

        let pendingApprovalInlineRow = NSStackView(views: [pendingApprovalTitleLabel, NSView(), pendingApprovalConfirmButton, pendingApprovalCancelButton])
        pendingApprovalInlineRow.orientation = .horizontal
        pendingApprovalInlineRow.alignment = .centerY
        pendingApprovalInlineRow.spacing = 8
        pendingApprovalInlineRow.translatesAutoresizingMaskIntoConstraints = false

        pendingApprovalContainer.addSubview(pendingApprovalInlineRow)
        NSLayoutConstraint.activate([
            pendingApprovalInlineRow.leadingAnchor.constraint(equalTo: pendingApprovalContainer.leadingAnchor, constant: Layout.pendingApprovalInlineInset),
            pendingApprovalInlineRow.trailingAnchor.constraint(equalTo: pendingApprovalContainer.trailingAnchor, constant: -Layout.pendingApprovalInlineInset),
            pendingApprovalInlineRow.topAnchor.constraint(equalTo: pendingApprovalContainer.topAnchor, constant: Layout.pendingApprovalInlineInset),
            pendingApprovalInlineRow.bottomAnchor.constraint(equalTo: pendingApprovalContainer.bottomAnchor, constant: -Layout.pendingApprovalInlineInset)
        ])

        taskContinuityContainer.translatesAutoresizingMaskIntoConstraints = false
        configureChromeSurface(
            taskContinuityContainer,
            fill: DesignTokens.ConversationPanel.Surface.taskFill,
            border: DesignTokens.ConversationPanel.Surface.taskBorder
        )
        taskContinuityContainer.isHidden = true

        [taskContinuityEyebrowLabel, taskContinuityTitleLabel, taskContinuityMetaLabel, taskContinuityDetailLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.lineBreakMode = .byTruncatingTail
        }
        taskContinuityEyebrowLabel.font = DesignTokens.ConversationPanel.Typography.stripEyebrow
        taskContinuityEyebrowLabel.textColor = DesignTokens.ConversationPanel.Text.eyebrow
        taskContinuityTitleLabel.font = DesignTokens.ConversationPanel.Typography.stripTitle
        taskContinuityTitleLabel.textColor = DesignTokens.ConversationPanel.Text.title
        taskContinuityTitleLabel.maximumNumberOfLines = 1
        taskContinuityMetaLabel.font = DesignTokens.ConversationPanel.Typography.stripMeta
        taskContinuityMetaLabel.textColor = DesignTokens.ConversationPanel.Text.meta
        taskContinuityMetaLabel.maximumNumberOfLines = Layout.compactCardMaxMetaLines
        taskContinuityDetailLabel.font = DesignTokens.ConversationPanel.Typography.stripDetail
        taskContinuityDetailLabel.textColor = DesignTokens.ConversationPanel.Text.detail
        taskContinuityDetailLabel.maximumNumberOfLines = Layout.compactCardMaxDetailLines

        let taskContinuityStack = NSStackView(views: [
            taskContinuityEyebrowLabel,
            taskContinuityTitleLabel,
            taskContinuityMetaLabel,
            taskContinuityDetailLabel
        ])
        taskContinuityStack.translatesAutoresizingMaskIntoConstraints = false
        taskContinuityStack.orientation = .vertical
        taskContinuityStack.alignment = .leading
        taskContinuityStack.spacing = Layout.compactCardStackSpacing

        taskContinuityContainer.addSubview(taskContinuityStack)
        NSLayoutConstraint.activate([
            taskContinuityStack.leadingAnchor.constraint(equalTo: taskContinuityContainer.leadingAnchor, constant: Layout.scopeCardInset),
            taskContinuityStack.trailingAnchor.constraint(equalTo: taskContinuityContainer.trailingAnchor, constant: -Layout.scopeCardInset),
            taskContinuityStack.topAnchor.constraint(equalTo: taskContinuityContainer.topAnchor, constant: Layout.scopeCardInset),
            taskContinuityStack.bottomAnchor.constraint(equalTo: taskContinuityContainer.bottomAnchor, constant: -Layout.scopeCardInset)
        ])

        transcriptStageContainer.translatesAutoresizingMaskIntoConstraints = false
        transcriptStageContainer.wantsLayer = true
        transcriptStageContainer.layer?.cornerRadius = 0
        transcriptStageContainer.layer?.borderWidth = 0
        transcriptStageContainer.layer?.borderColor = NSColor.clear.cgColor
        transcriptStageContainer.layer?.backgroundColor = NSColor.clear.cgColor

        transcriptScrollView.translatesAutoresizingMaskIntoConstraints = false
        transcriptScrollView.hasVerticalScroller = false
        transcriptScrollView.drawsBackground = false
        transcriptScrollView.backgroundColor = .clear
        transcriptScrollView.wantsLayer = true
        transcriptScrollView.layer?.backgroundColor = NSColor.clear.cgColor
        transcriptScrollView.borderType = .noBorder
        transcriptScrollView.scrollerStyle = .overlay
        transcriptScrollView.contentView = AskFlippedClipView()
        transcriptScrollView.contentView.postsBoundsChangedNotifications = true
        if let clip = transcriptScrollView.contentView as? AskFlippedClipView {
            clip.drawsBackground = false
            clip.backgroundColor = .clear
            clip.wantsLayer = true
            clip.layer?.backgroundColor = NSColor.clear.cgColor
        }
        transcriptScrollIndicator.onScrollRequested = { [weak self] targetOffset in
            self?.scrollTranscript(to: targetOffset)
        }

        transcriptContentView.translatesAutoresizingMaskIntoConstraints = true
        transcriptContentView.wantsLayer = true
        transcriptContentView.layer?.backgroundColor = NSColor.clear.cgColor

        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .leading
        transcriptStack.spacing = DesignTokens.ConversationPanel.transcriptRowSpacing
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false
        transcriptStreamingSlackSpacer.translatesAutoresizingMaskIntoConstraints = false
        transcriptStreamingSlackSpacer.wantsLayer = true
        transcriptStreamingSlackSpacer.layer?.backgroundColor = NSColor.clear.cgColor
        transcriptStreamingSlackHeightConstraint = transcriptStreamingSlackSpacer.heightAnchor.constraint(
            equalToConstant: Layout.streamingFollowSlackBase
        )
        transcriptStreamingSlackHeightConstraint?.isActive = true

        transcriptContentView.addSubview(transcriptStack)
        NSLayoutConstraint.activate([
            transcriptStack.leadingAnchor.constraint(equalTo: transcriptContentView.leadingAnchor),
            transcriptStack.trailingAnchor.constraint(equalTo: transcriptContentView.trailingAnchor),
            transcriptStack.topAnchor.constraint(equalTo: transcriptContentView.topAnchor)
        ])
        ensureTranscriptStreamingSlackSpacerAttached()
        transcriptScrollView.documentView = transcriptContentView

        transcriptEmptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        transcriptEmptyStateLabel.font = DesignTokens.ConversationPanel.Typography.body
        transcriptEmptyStateLabel.textColor = DesignTokens.ConversationPanel.Text.muted
        transcriptEmptyStateLabel.alignment = .center
        transcriptEmptyStateLabel.maximumNumberOfLines = 1
        transcriptEmptyStateLabel.lineBreakMode = .byTruncatingTail
        transcriptEmptyStateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        transcriptEmptyStateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        cronDraftContainer.translatesAutoresizingMaskIntoConstraints = false
        cronDraftContainer.wantsLayer = true
        cronDraftContainer.layer?.cornerRadius = Layout.draftCardCornerRadius
        cronDraftContainer.layer?.borderWidth = 1
        cronDraftContainer.layer?.borderColor = DesignTokens.Color.accentOrange.withAlphaComponent(0.28).cgColor
        cronDraftContainer.layer?.backgroundColor = DesignTokens.Color.controlFill.withAlphaComponent(0.4).cgColor
        cronDraftContainer.isHidden = true

        cronDraftTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        cronDraftTitleLabel.textColor = DesignTokens.Color.textPrimary
        [cronDraftScheduleLabel, cronDraftSummaryLabel, cronDraftDeliveryLabel, cronDraftRiskLabel].forEach { label in
            label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            label.textColor = DesignTokens.Color.textSecondary
            label.maximumNumberOfLines = 0
        }
        cronDraftRiskLabel.textColor = DesignTokens.Color.accentOrange

        composerContainer.translatesAutoresizingMaskIntoConstraints = false
        composerContainer.wantsLayer = true
        composerContainer.layer?.cornerRadius = DesignTokens.ConversationPanel.composerCornerRadius
        composerContainer.layer?.borderWidth = 1
        composerContainer.layer?.borderColor = DesignTokens.ConversationPanel.Surface.composerBorder.cgColor
        composerContainer.layer?.backgroundColor = DesignTokens.ConversationPanel.Surface.composerFill.cgColor
        composerContainer.onHoverChanged = { [weak self] isHovered in
            self?.composerIsHovered = isHovered
            self?.updateComposerContainerAppearance(animated: true)
        }

        composerPlaceholder.font = DesignTokens.ConversationPanel.Typography.body
        composerPlaceholder.textColor = DesignTokens.Color.inputPlaceholder
        composerPlaceholder.maximumNumberOfLines = 2
        composerPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        composerPlaceholder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        composerPlaceholder.setContentHuggingPriority(.defaultLow, for: .horizontal)

        composerTextClipView.translatesAutoresizingMaskIntoConstraints = false
        composerTextClipView.wantsLayer = true
        composerTextClipView.layer?.masksToBounds = true
        composerTextClipView.layer?.backgroundColor = NSColor.clear.cgColor
        composerTextClipView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        composerTextClipView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        composerTextView.translatesAutoresizingMaskIntoConstraints = false
        composerTextView.delegate = self
        composerTextView.font = DesignTokens.ConversationPanel.Typography.body
        composerTextView.textColor = DesignTokens.Color.inputText
        composerTextView.insertionPointColor = DesignTokens.Color.inputText
        composerTextView.drawsBackground = false
        composerTextView.isRichText = false
        composerTextView.importsGraphics = false
        composerTextView.usesFindBar = false
        composerTextView.allowsUndo = true
        composerTextView.isVerticallyResizable = true
        composerTextView.isHorizontallyResizable = false
        composerTextView.minSize = NSSize(width: 0, height: 24)
        composerTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composerTextView.textContainer?.lineFragmentPadding = 0
        composerTextView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composerTextView.textContainerInset = NSSize(width: 0, height: 4)
        composerTextView.textContainer?.widthTracksTextView = true
        composerTextView.textContainer?.lineBreakMode = .byWordWrapping
        composerTextView.setAccessibilityIdentifier(AppBrand.accessibilityIdentifier("ask.composer"))
        composerTextView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        composerTextView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        composerTextView.onSubmit = { [weak self] in
            self?.submitCurrentPrompt()
        }
        composerTextView.onFocusChanged = { [weak self] isFocused in
            self?.composerHasFocus = isFocused
            self?.updateComposerPlaceholder()
            self?.updateComposerContainerAppearance(animated: true)
        }

        composerButtonStack.orientation = .horizontal
        composerButtonStack.alignment = .centerY
        composerButtonStack.spacing = 8
        composerButtonStack.translatesAutoresizingMaskIntoConstraints = false
        composerButtonStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        composerButtonStack.setContentHuggingPriority(.required, for: .horizontal)

        saveAutomationButton.target = self
        saveAutomationButton.action = #selector(handleSaveAutomationButton)
        saveAutomationButton.isBordered = false
        saveAutomationButton.focusRingType = .none
        saveAutomationButton.font = DesignTokens.ConversationPanel.Typography.button
        saveAutomationButton.contentTintColor = DesignTokens.Color.textSecondary
        saveAutomationButton.translatesAutoresizingMaskIntoConstraints = false
        saveAutomationButton.hoverScale = 1
        saveAutomationButton.setAccessibilityIdentifier(AppBrand.accessibilityIdentifier("ask.save_automation"))
        saveAutomationButton.wantsLayer = true
        saveAutomationButton.layer?.cornerRadius = DesignTokens.ConversationPanel.buttonCornerRadius
        saveAutomationButton.layer?.masksToBounds = true
        saveAutomationButton.layer?.borderWidth = 1
        saveAutomationButton.layer?.borderColor = DesignTokens.ConversationPanel.Button.secondaryBorder.cgColor
        saveAutomationButton.onHoverChanged = { [weak self] _ in
            self?.updateSaveAutomationButtonAppearance(animated: true)
        }

        sendButton.target = self
        sendButton.action = #selector(handleSendButton)
        sendButton.isBordered = false
        sendButton.focusRingType = .none
        sendButton.font = DesignTokens.ConversationPanel.Typography.button
        sendButton.contentTintColor = DesignTokens.Color.textSecondary
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.hoverScale = 1
        sendButton.setAccessibilityIdentifier(AppBrand.accessibilityIdentifier("ask.send"))
        sendButton.wantsLayer = true
        sendButton.layer?.cornerRadius = DesignTokens.ConversationPanel.buttonCornerRadius
        sendButton.layer?.masksToBounds = true
        sendButton.layer?.backgroundColor = DesignTokens.ConversationPanel.Button.sendFill.cgColor
        sendButton.layer?.borderWidth = 1
        sendButton.layer?.borderColor = DesignTokens.ConversationPanel.Button.sendBorder.cgColor
        sendButton.onHoverChanged = { [weak self] _ in
            self?.updateSendButtonAppearance(animated: true)
        }
        sendButton.onMouseDown = { [weak self] event in
            self?.logPanelMouseDiagnostics(stage: "send_button_mouse_down", event: event)
        }
        sendButton.onPrimaryMouseDown = { [weak self] event in
            guard let self else { return false }
            return self.handleSendButtonPrimaryMouseDown(event)
        }

        [cronContinueButton, cronSaveButton, cronDismissButton].forEach { button in
            button.isBordered = false
            button.focusRingType = .none
            button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 10
            button.layer?.masksToBounds = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        cronContinueButton.target = self
        cronContinueButton.action = #selector(handleContinueAutomationDraft)
        cronSaveButton.target = self
        cronSaveButton.action = #selector(handleSaveAutomationDraft)
        cronDismissButton.target = self
        cronDismissButton.action = #selector(handleDismissAutomationDraft)

        composerButtonStack.addArrangedSubview(sendButton)
        composerContainer.addSubview(composerTextClipView)
        composerTextClipView.addSubview(composerTextView)
        composerTextClipView.addSubview(composerPlaceholder)
        composerContainer.addSubview(composerButtonStack)

        composerButtonStackLeadingConstraint = composerButtonStack.leadingAnchor.constraint(
            equalTo: composerTextClipView.trailingAnchor,
            constant: Layout.composerButtonSpacing
        )
        composerTextWidthConstraint = composerTextView.widthAnchor.constraint(equalTo: composerTextClipView.widthAnchor)

        NSLayoutConstraint.activate([
            composerTextClipView.leadingAnchor.constraint(equalTo: composerContainer.leadingAnchor, constant: Layout.composerHorizontalInset),
            composerTextClipView.topAnchor.constraint(equalTo: composerContainer.topAnchor, constant: Layout.composerVerticalInset),
            composerTextClipView.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor, constant: -Layout.composerVerticalInset),

            composerTextView.leadingAnchor.constraint(equalTo: composerTextClipView.leadingAnchor),
            composerTextView.topAnchor.constraint(equalTo: composerTextClipView.topAnchor),
            composerTextView.bottomAnchor.constraint(equalTo: composerTextClipView.bottomAnchor),
            composerTextWidthConstraint!,

            composerPlaceholder.leadingAnchor.constraint(equalTo: composerTextView.leadingAnchor, constant: 2),
            composerPlaceholder.trailingAnchor.constraint(lessThanOrEqualTo: composerTextClipView.trailingAnchor),
            composerPlaceholder.topAnchor.constraint(equalTo: composerTextClipView.topAnchor, constant: 3),

            composerButtonStackLeadingConstraint!,
            composerButtonStack.trailingAnchor.constraint(equalTo: composerContainer.trailingAnchor, constant: -Layout.composerHorizontalInset),
            composerButtonStack.topAnchor.constraint(greaterThanOrEqualTo: composerContainer.topAnchor, constant: Layout.composerVerticalInset),
            composerButtonStack.bottomAnchor.constraint(equalTo: composerContainer.bottomAnchor, constant: -Layout.composerVerticalInset),

            composerContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.composerMinimumHeight)
        ])
        sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        sendButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        composerTextHeightConstraint = composerTextView.heightAnchor.constraint(equalToConstant: 28)
        composerTextHeightConstraint?.isActive = true

        let cronDraftContentStack = NSStackView(views: [
            cronDraftTitleLabel,
            cronDraftScheduleLabel,
            cronDraftSummaryLabel,
            cronDraftDeliveryLabel,
            cronDraftRiskLabel
        ])
        cronDraftContentStack.orientation = .vertical
        cronDraftContentStack.alignment = .leading
        cronDraftContentStack.spacing = 6
        cronDraftContentStack.translatesAutoresizingMaskIntoConstraints = false

        let cronDraftButtonRow = NSStackView(views: [cronContinueButton, cronSaveButton, cronDismissButton, NSView()])
        cronDraftButtonRow.orientation = .horizontal
        cronDraftButtonRow.alignment = .centerY
        cronDraftButtonRow.spacing = 8
        cronDraftButtonRow.translatesAutoresizingMaskIntoConstraints = false

        cronDraftContainer.addSubview(cronDraftContentStack)
        cronDraftContainer.addSubview(cronDraftButtonRow)
        NSLayoutConstraint.activate([
            cronDraftContentStack.leadingAnchor.constraint(equalTo: cronDraftContainer.leadingAnchor, constant: Layout.draftCardInset),
            cronDraftContentStack.trailingAnchor.constraint(equalTo: cronDraftContainer.trailingAnchor, constant: -Layout.draftCardInset),
            cronDraftContentStack.topAnchor.constraint(equalTo: cronDraftContainer.topAnchor, constant: Layout.draftCardInset),

            cronDraftButtonRow.leadingAnchor.constraint(equalTo: cronDraftContainer.leadingAnchor, constant: Layout.draftCardInset),
            cronDraftButtonRow.trailingAnchor.constraint(equalTo: cronDraftContainer.trailingAnchor, constant: -Layout.draftCardInset),
            cronDraftButtonRow.topAnchor.constraint(equalTo: cronDraftContentStack.bottomAnchor, constant: 12),
            cronDraftButtonRow.bottomAnchor.constraint(equalTo: cronDraftContainer.bottomAnchor, constant: -Layout.draftCardInset)
        ])

        supplementaryChromeStack.translatesAutoresizingMaskIntoConstraints = false
        supplementaryChromeStack.orientation = .vertical
        supplementaryChromeStack.alignment = .leading
        supplementaryChromeStack.spacing = Layout.supplementaryChromeSpacing
        supplementaryChromeStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        supplementaryChromeStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        supplementaryChromeStack.addArrangedSubview(scopeBarContainer)
        supplementaryChromeStack.addArrangedSubview(sessionModeContainer)
        supplementaryChromeStack.addArrangedSubview(taskContinuityContainer)
        supplementaryChromeStack.isHidden = true

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentStack.addArrangedSubview(headerDragRegionView)
        contentStack.addArrangedSubview(divider)
        contentStack.addArrangedSubview(proactiveHintContainer)
        contentStack.addArrangedSubview(supplementaryChromeStack)
        contentStack.addArrangedSubview(transcriptStageContainer)
        contentStack.addArrangedSubview(pendingApprovalContainer)
        contentStack.addArrangedSubview(composerContainer)

        contentView.addSubview(panelSurfaceView)
        panelSurfaceView.addSubview(entranceFlowOverlayView)
        panelSurfaceView.addSubview(contentStack)
        transcriptStageContainer.addSubview(transcriptScrollView)
        transcriptStageContainer.addSubview(transcriptScrollIndicator)
        transcriptStageContainer.addSubview(transcriptEmptyStateLabel)

        [
            headerDragRegionView,
            divider,
            proactiveHintContainer,
            supplementaryChromeStack,
            pendingApprovalContainer,
            transcriptStageContainer,
            composerContainer
        ].forEach { view in
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        [
            scopeBarContainer,
            sessionModeContainer,
            taskContinuityContainer
        ].forEach { view in
            view.widthAnchor.constraint(equalTo: supplementaryChromeStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            panelSurfaceView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            panelSurfaceView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            panelSurfaceView.topAnchor.constraint(equalTo: contentView.topAnchor),
            panelSurfaceView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            entranceFlowOverlayView.leadingAnchor.constraint(equalTo: panelSurfaceView.leadingAnchor),
            entranceFlowOverlayView.trailingAnchor.constraint(equalTo: panelSurfaceView.trailingAnchor),
            entranceFlowOverlayView.topAnchor.constraint(equalTo: panelSurfaceView.topAnchor),
            entranceFlowOverlayView.bottomAnchor.constraint(equalTo: panelSurfaceView.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: panelSurfaceView.leadingAnchor, constant: Layout.contentInset),
            contentStack.trailingAnchor.constraint(equalTo: panelSurfaceView.trailingAnchor, constant: -Layout.contentInset),
            contentStack.topAnchor.constraint(equalTo: panelSurfaceView.topAnchor, constant: Layout.contentInset),
            contentStack.bottomAnchor.constraint(equalTo: panelSurfaceView.bottomAnchor, constant: -Layout.contentInset),

            transcriptScrollView.leadingAnchor.constraint(equalTo: transcriptStageContainer.leadingAnchor, constant: Layout.transcriptStageInset),
            transcriptScrollView.trailingAnchor.constraint(equalTo: transcriptStageContainer.trailingAnchor, constant: -Layout.transcriptStageInset),
            transcriptScrollView.topAnchor.constraint(equalTo: transcriptStageContainer.topAnchor, constant: Layout.transcriptStageInset),
            transcriptScrollView.bottomAnchor.constraint(equalTo: transcriptStageContainer.bottomAnchor, constant: -Layout.transcriptStageInset),

            transcriptScrollIndicator.trailingAnchor.constraint(equalTo: transcriptScrollView.trailingAnchor, constant: -DesignTokens.ScrollIndicator.trailingInset),
            transcriptScrollIndicator.topAnchor.constraint(equalTo: transcriptScrollView.topAnchor, constant: DesignTokens.ScrollIndicator.verticalInset),
            transcriptScrollIndicator.bottomAnchor.constraint(equalTo: transcriptScrollView.bottomAnchor, constant: -DesignTokens.ScrollIndicator.verticalInset),
            transcriptScrollIndicator.widthAnchor.constraint(equalToConstant: DesignTokens.ScrollIndicator.width)
        ])

        NSLayoutConstraint.activate([
            transcriptEmptyStateLabel.centerXAnchor.constraint(equalTo: transcriptStageContainer.centerXAnchor),
            transcriptEmptyStateLabel.centerYAnchor.constraint(equalTo: transcriptStageContainer.centerYAnchor),
            transcriptEmptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: transcriptStageContainer.leadingAnchor, constant: 24),
            transcriptEmptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: transcriptStageContainer.trailingAnchor, constant: -24),
            transcriptEmptyStateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.emptyStateMaxWidth)
        ])

        transcriptHeightConstraint = transcriptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72)
        transcriptHeightConstraint?.isActive = true
        panel.initialFirstResponder = composerTextView
        renderTranscript()
        updateComposerPlaceholder()
        updateProactiveHintPresentation()
        updateEmptyStateVisibility()
        hideLoadingStatus(immediately: true)
        updateComposerContainerAppearance(animated: false)
        updateCloseButtonAppearance(animated: false)
        updateComposerActionButtonsState(animated: false)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTranscriptScrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: transcriptScrollView.contentView
        )
    }

    private func configureChromeSurface(_ view: NSView, fill: NSColor, border: NSColor) {
        view.wantsLayer = true
        view.layer?.cornerRadius = Layout.scopeCardCornerRadius
        view.layer?.borderWidth = DesignTokens.ConversationPanel.stripBorderWidth
        view.layer?.borderColor = border.cgColor
        view.layer?.backgroundColor = fill.cgColor
    }

    private func updateProactiveHintPresentation() {
        let hint = activeProactiveHintText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let hint, !hint.isEmpty {
            proactiveHintLabel.stringValue = hint.replacingOccurrences(of: "\n", with: " ")
            proactiveHintContainer.isHidden = false
        } else {
            proactiveHintLabel.stringValue = ""
            proactiveHintContainer.isHidden = true
        }
    }

    private func hasResumeSessionContext(_ sessionState: AskAgentSessionState) -> Bool {
        let hasResumeToken = trimmedKernelPreview(sessionState.activeTaskResumeToken, maxLength: 44) != nil
        let hasTaskID = trimmedKernelPreview(sessionState.activeTaskID, maxLength: 24) != nil
        return hasResumeToken || hasTaskID || state.sessionOrigin == .assistantFollowUp
    }

    private func hasTranscriptActivityForMinimalChrome() -> Bool {
        state.isStreaming
            || !transcriptEntries.isEmpty
            || !state.messages.isEmpty
            || currentLoadingStatusText != nil
    }

    private func shouldPreferMinimalInteractiveChrome(_ sessionState: AskAgentSessionState) -> Bool {
        guard state.sessionOrigin == .user,
              resolvedExecutionMode() == .interactive,
              !hasResumeSessionContext(sessionState) else {
            return false
        }

        return automationSessionStateDetails(languageCode: resolvedResponseLanguage()).isEmpty
    }

    private func updateSupplementaryChromeStackVisibility(sessionState: AskAgentSessionState? = nil) {
        _ = sessionState
        wantsScopeChrome = false
        wantsSessionChrome = false
        wantsTaskChrome = false
        scopeBarContainer.isHidden = true
        sessionModeContainer.isHidden = true
        taskContinuityContainer.isHidden = true
        supplementaryChromeStack.isHidden = true
    }

    private func renderTranscript() {
        transcriptMessageRowViewsByEntryID.removeAll(keepingCapacity: true)
        transcriptRuntimeStepRowViewsByEntryID.removeAll(keepingCapacity: true)
        transcriptStack.arrangedSubviews.forEach {
            transcriptStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for entry in transcriptEntries {
            switch entry {
            case .message(let messageEntry):
                appendTranscriptRow(messageEntry.message, entryID: messageEntry.id, citations: messageCitationsByEntryID[messageEntry.id] ?? [])
            case .runtimeStep(let step):
                appendRuntimeStepRow(step, entryID: step.id)
            }
        }
        if let currentLoadingStatusText {
            appendLoadingStatusRow(text: currentLoadingStatusText)
        }
        ensureTranscriptStreamingSlackSpacerAttached()
        updateEmptyStateVisibility()
        updateTranscriptDocumentFrame()
        scheduleSmokeStateSnapshotWrite()
    }

    private func removeTranscriptEntry(withID entryID: String) {
        guard let index = transcriptEntries.firstIndex(where: { $0.id == entryID }) else { return }
        transcriptEntries.remove(at: index)
        if let row = transcriptMessageRowViewsByEntryID.removeValue(forKey: entryID),
           transcriptStack.arrangedSubviews.contains(row) {
            transcriptStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        if let row = transcriptRuntimeStepRowViewsByEntryID.removeValue(forKey: entryID),
           transcriptStack.arrangedSubviews.contains(row) {
            transcriptStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        if activeRuntimeStepEntryID == entryID {
            activeRuntimeStepEntryID = nil
        }
        updateEmptyStateVisibility()
        updateTranscriptDocumentFrame()
        scheduleTranscriptViewportRefresh(scrollToBottom: true)
        scheduleSmokeStateSnapshotWrite()
    }

    private func formattedLoadingStatus(status: String, detail: String?) -> String {
        let detailText = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !detailText.isEmpty {
            return detailText
        }
        switch status {
        case "thinking":
            return L10n.text(zhHans: "正在思考中", en: "Thinking")
        case "failed":
            return L10n.text(zhHans: "执行失败", en: "Failed")
        default:
            return L10n.text(zhHans: "处理中", en: "Working")
        }
    }

    private func showLoadingStatus(status: String, detail: String?) {
        let content = formattedLoadingStatus(status: status, detail: detail)
        guard !content.isEmpty else { return }
        guard currentLoadingStatusText != content || loadingStatusRowView == nil else { return }

        currentLoadingStatusText = content
        appendLoadingStatusRow(text: content)
        loadingLineEffectController.start()
        updateEmptyStateVisibility()
        updateTranscriptDocumentFrame()
        scheduleTranscriptViewportRefresh(scrollToBottom: true)
        appendSmokeViewportTrace(reason: "loading_show")
        scheduleSmokeStateSnapshotWrite()
    }

    private func hideLoadingStatus(immediately: Bool = false) {
        currentLoadingStatusText = nil
        if let loadingStatusRowView,
           transcriptStack.arrangedSubviews.contains(loadingStatusRowView) {
            transcriptStack.removeArrangedSubview(loadingStatusRowView)
            loadingStatusRowView.removeFromSuperview()
        }
        loadingLineEffectController.stop(immediately: immediately)
        updateEmptyStateVisibility()
        updateTranscriptDocumentFrame()
        appendSmokeViewportTrace(reason: immediately ? "loading_hide_immediate" : "loading_hide")
        scheduleSmokeStateSnapshotWrite()
    }

    private func appendLoadingStatusRow(text: String) {
        if let loadingStatusRowView {
            loadingStatusRowView.update(text: text)
            if !transcriptStack.arrangedSubviews.contains(loadingStatusRowView) {
                insertTranscriptArrangedSubviewBeforeSlack(loadingStatusRowView)
            }
            return
        }

        let row = TranscriptLoadingRowView(text: text)
        loadingStatusRowView = row
        insertTranscriptArrangedSubviewBeforeSlack(row)
    }

    @discardableResult
    private func appendTranscriptMessageEntry(_ message: AskMessage) -> String {
        let id = UUID().uuidString.lowercased()
        transcriptEntries.append(.message(TranscriptMessageEntry(id: id, message: message)))
        appendTranscriptRow(message, entryID: id, citations: messageCitationsByEntryID[id] ?? [])
        updateEmptyStateVisibility()
        updateTranscriptDocumentFrame()
        scheduleSmokeStateSnapshotWrite()
        return id
    }

    private var activeRuntimeStepDisplayID: String {
        "ask-active-runtime-step-\(state.sessionID)"
    }

    private func shouldCollapseRuntimeStepIntoSingleStatus(_ step: AskRuntimeStepEvent) -> Bool {
        guard step.kind != .awaitingApproval,
              step.state != .failed else {
            return false
        }
        return true
    }

    private func compactRuntimeStepDetail(_ step: AskRuntimeStepEvent) -> String? {
        switch step.state {
        case .failed, .blocked:
            return trimmedKernelPreview(step.detail, maxLength: 220)
        case .running, .waiting, .completed, .saved:
            return nil
        }
    }

    private func normalizedRuntimeStepForDisplay(_ step: AskRuntimeStepEvent) -> AskRuntimeStepEvent {
        AskRuntimeStepEvent(
            id: shouldCollapseRuntimeStepIntoSingleStatus(step) ? activeRuntimeStepDisplayID : step.id,
            kind: step.kind,
            title: step.title,
            detail: compactRuntimeStepDetail(step),
            state: step.state,
            codeBlock: step.codeBlock
        )
    }

    private func mergedRuntimeStepForDisplay(
        _ step: AskRuntimeStepEvent,
        existingStep: AskRuntimeStepEvent?
    ) -> AskRuntimeStepEvent {
        let preservedCodeBlock: AskRuntimeCodeBlockPreview?
        if let codeBlock = step.codeBlock {
            preservedCodeBlock = codeBlock
        } else if let existingStep,
                  step.state == .running || step.state == .waiting {
            preservedCodeBlock = existingStep.codeBlock
        } else {
            preservedCodeBlock = nil
        }

        return AskRuntimeStepEvent(
            id: step.id,
            kind: step.kind,
            title: step.title,
            detail: step.detail,
            state: step.state,
            codeBlock: preservedCodeBlock
        )
    }

    private func upsertRuntimeStep(_ step: AskRuntimeStepEvent) {
        if step.kind == .awaitingApproval {
            if step.state == .waiting {
                removeTranscriptEntry(withID: activeRuntimeStepDisplayID)
            }
            switch step.state {
            case .waiting:
                pendingApprovalSummaryText = compactRuntimeStepDetail(step)
                    ?? trimmedKernelPreview(step.title, maxLength: 160)
            case .completed, .blocked, .saved, .failed, .running:
                if pendingApprovalActionID == nil {
                    pendingApprovalSummaryText = nil
                }
            }
            updatePendingApprovalCard()
            return
        }

        let renderedStep = normalizedRuntimeStepForDisplay(step)
        if let index = transcriptEntries.firstIndex(where: { entry in
            if case .runtimeStep(let existing) = entry {
                return existing.id == renderedStep.id
            }
            return false
        }) {
            let existingStep: AskRuntimeStepEvent?
            if case .runtimeStep(let step) = transcriptEntries[index] {
                existingStep = step
            } else {
                existingStep = nil
            }
            let mergedStep = mergedRuntimeStepForDisplay(renderedStep, existingStep: existingStep)
            transcriptEntries[index] = .runtimeStep(mergedStep)
            if let row = transcriptRuntimeStepRowViewsByEntryID[renderedStep.id] {
                row.update(step: mergedStep)
                moveTranscriptEntryToBottomIfNeeded(withID: mergedStep.id)
            } else {
                renderTranscript()
            }
        } else {
            transcriptEntries.append(.runtimeStep(renderedStep))
            appendRuntimeStepRow(renderedStep, entryID: renderedStep.id)
            updateEmptyStateVisibility()
        }

        if renderedStep.codeBlock != nil {
            didObserveRuntimeCodePreview = true
            if let row = transcriptRuntimeStepRowViewsByEntryID[renderedStep.id] {
                maxObservedRuntimeCodePreviewHeight = max(
                    maxObservedRuntimeCodePreviewHeight,
                    row.testingCodePreviewHeight
                )
            }
        }

        switch renderedStep.state {
        case .running, .waiting:
            activeRuntimeStepEntryID = renderedStep.id
            loadingLineEffectController.start()
        case .completed, .blocked, .saved, .failed:
            if activeRuntimeStepEntryID == renderedStep.id {
                activeRuntimeStepEntryID = nil
            }
            if !transcriptEntries.contains(where: {
                if case .runtimeStep(let existing) = $0 {
                    return existing.id != renderedStep.id && (existing.state == .running || existing.state == .waiting)
                }
                return false
            }) {
                loadingLineEffectController.stop()
            }
        }

        scheduleTranscriptViewportRefresh(scrollToBottom: true)
        scheduleSmokeStateSnapshotWrite()
    }

    private func updateActiveRuntimeStepDetail(with detail: String?) {
        guard let activeRuntimeStepEntryID,
              activeRuntimeStepEntryID != activeRuntimeStepDisplayID,
              let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty,
              let index = transcriptEntries.firstIndex(where: { $0.id == activeRuntimeStepEntryID }),
              case .runtimeStep(let step) = transcriptEntries[index] else {
            return
        }

        let updated = AskRuntimeStepEvent(
            id: step.id,
            kind: step.kind,
            title: step.title,
            detail: detail,
            state: step.state,
            codeBlock: step.codeBlock
        )
        transcriptEntries[index] = .runtimeStep(updated)
        transcriptRuntimeStepRowViewsByEntryID[step.id]?.update(step: updated)
        moveTranscriptEntryToBottomIfNeeded(withID: step.id)
        scheduleTranscriptViewportRefresh(scrollToBottom: true)
        scheduleSmokeStateSnapshotWrite()
    }

    private func clearPendingApprovalState() {
        pendingApprovalActionID = nil
        pendingApprovalSummaryText = nil
        pendingApprovalMessageText = nil
        pendingApprovalPreviewCards = []
        pendingApprovalCardSuppressed = false
        pendingApprovalTitleLabel.stringValue = ""
        pendingApprovalDetailLabel.stringValue = ""
        pendingApprovalDetailLabel.isHidden = true
        pendingApprovalPreviewStack.arrangedSubviews.forEach {
            pendingApprovalPreviewStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        pendingApprovalPreviewStack.isHidden = true
        pendingApprovalContainer.isHidden = true
        pendingApprovalConfirmButton.isEnabled = false
        pendingApprovalCancelButton.isEnabled = false
        updatePendingApprovalButtonAppearance(animated: false)
        updateSupplementaryChromeStackVisibility()
        scheduleSmokeStateSnapshotWrite()
    }

    private func syncPendingApprovalState(from response: AskSessionResponse) {
        let actionID = [
            response.metadata["pending_approval_action_id"],
            response.metadata["active_action_id"]
        ]
        .compactMap { value in
            trimmedKernelPreview(value, maxLength: 160)
        }
        .first

        guard let actionID else {
            clearPendingApprovalState()
            return
        }

        let isNewApproval = pendingApprovalActionID != actionID
        pendingApprovalActionID = actionID
        pendingApprovalCardSuppressed = false
        if isNewApproval {
            pendingApprovalSummaryText = nil
        }
        pendingApprovalMessageText = trimmedKernelPreview(response.message, maxLength: 320)
        pendingApprovalPreviewCards = response.cards
        if pendingApprovalSummaryText == nil {
            pendingApprovalSummaryText = trimmedKernelPreview(response.message, maxLength: 140)
        }
    }

    private func pendingApprovalInlineTitle() -> String? {
        L10n.text(
            languageCode: resolvedResponseLanguage(),
            zhHans: "确认后继续当前任务",
            en: "Confirm to continue this task"
        )
    }

    private func updatePendingApprovalCard() {
        guard pendingApprovalActionID != nil, !pendingApprovalCardSuppressed else {
            pendingApprovalContainer.isHidden = true
            pendingApprovalConfirmButton.isEnabled = false
            pendingApprovalCancelButton.isEnabled = false
            updatePendingApprovalButtonAppearance(animated: false)
            updateSupplementaryChromeStackVisibility()
            return
        }

        let title = pendingApprovalInlineTitle() ?? L10n.text(
            languageCode: resolvedResponseLanguage(),
            zhHans: "等待你的确认",
            en: "Waiting for your confirmation"
        )

        pendingApprovalTitleLabel.stringValue = title
        pendingApprovalDetailLabel.stringValue = ""
        pendingApprovalDetailLabel.isHidden = true

        pendingApprovalPreviewStack.arrangedSubviews.forEach {
            pendingApprovalPreviewStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        pendingApprovalPreviewStack.isHidden = true

        let buttonsEnabled = !state.isStreaming
        pendingApprovalConfirmButton.isEnabled = buttonsEnabled
        pendingApprovalCancelButton.isEnabled = buttonsEnabled
        pendingApprovalContainer.isHidden = false
        updatePendingApprovalButtonAppearance(animated: true)
        updateSupplementaryChromeStackVisibility()
        scheduleSmokeStateSnapshotWrite()
    }

    private func updatePendingApprovalButtonAppearance(animated: Bool) {
        let buttonConfigs: [(button: HoverButton, isPrimary: Bool)] = [
            (pendingApprovalConfirmButton, true),
            (pendingApprovalCancelButton, false)
        ]

        for config in buttonConfigs {
            let button = config.button
            let isHovered = button.currentHoverState && button.isEnabled
            let backgroundColor: NSColor
            let borderColor: NSColor
            let tintColor: NSColor
            let alphaValue: CGFloat

            if button.isEnabled {
                if config.isPrimary {
                    backgroundColor = isHovered
                        ? DesignTokens.ConversationPanel.Button.sendFillHover
                        : DesignTokens.ConversationPanel.Button.sendFill
                    borderColor = isHovered
                        ? DesignTokens.ConversationPanel.Button.sendBorderHover
                        : DesignTokens.ConversationPanel.Button.sendBorder
                    tintColor = DesignTokens.ConversationPanel.Button.sendText
                } else {
                    backgroundColor = isHovered
                        ? DesignTokens.ConversationPanel.Button.secondaryFillHover
                        : DesignTokens.ConversationPanel.Button.secondaryFill
                    borderColor = isHovered ? DesignTokens.ConversationPanel.Button.secondaryBorderHover : DesignTokens.ConversationPanel.Button.secondaryBorder
                    tintColor = isHovered ? DesignTokens.ConversationPanel.Button.secondaryTextHover : DesignTokens.ConversationPanel.Button.secondaryText
                }
                alphaValue = 1
            } else {
                backgroundColor = DesignTokens.ConversationPanel.Button.disabledFill
                borderColor = DesignTokens.ConversationPanel.Button.disabledBorder
                tintColor = DesignTokens.ConversationPanel.Button.disabledText
                alphaValue = 0.88
            }

            applyLayerAppearance(animated: animated, on: button.layer) {
                button.layer?.backgroundColor = backgroundColor.cgColor
                button.layer?.borderWidth = 1
                button.layer?.borderColor = borderColor.cgColor
                button.alphaValue = alphaValue
            }
            button.contentTintColor = tintColor
        }
    }

    @objc
    private func handleApprovePendingApproval() {
        submitPendingApprovalDecision(approved: true)
    }

    @objc
    private func handleCancelPendingApproval() {
        submitPendingApprovalDecision(approved: false)
    }

    private func submitPendingApprovalDecision(approved: Bool) {
        guard pendingApprovalActionID != nil, !state.isStreaming else { return }
        pendingApprovalCardSuppressed = true
        updatePendingApprovalCard()
        submitPrompt(pendingApprovalDecisionPrompt(approved: approved))
    }

    private func pendingApprovalDecisionPrompt(approved: Bool) -> String {
        L10n.text(
            languageCode: resolvedResponseLanguage(),
            zhHans: approved ? "确认" : "取消",
            en: approved ? "confirm" : "cancel"
        )
    }

    private func handlePanelKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }

        guard let textView = panel.firstResponder as? NSTextView else {
            return false
        }

        switch key {
        case "a":
            textView.selectAll(nil)
            return true
        case "c":
            textView.copy(nil)
            return true
        case "x":
            textView.cut(nil)
            return true
        case "v":
            textView.paste(nil)
            return true
        case "z":
            if flags.contains(.shift) {
                textView.undoManager?.redo()
            } else {
                textView.undoManager?.undo()
            }
            return true
        default:
            return false
        }
    }

    private func appendTranscriptRow(_ message: AskMessage, entryID: String, citations: [SkillResultCard]) {
        let row = TranscriptRowView(message: message, citations: citations)
        row.onCitationTapped = { [weak self] card, anchorView in
            self?.presentCitationPopover(for: card, relativeTo: anchorView)
        }
        row.onActionCardTapped = { [weak self] card in
            self?.resultCardActionCoordinator.performAction(for: card)
        }
        transcriptMessageRowViewsByEntryID[entryID] = row
        insertTranscriptArrangedSubviewBeforeSlack(row)
        row.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true
    }

    private func appendRuntimeStepRow(_ step: AskRuntimeStepEvent, entryID: String) {
        let row = TranscriptRuntimeStepRowView(step: step)
        transcriptRuntimeStepRowViewsByEntryID[entryID] = row
        insertTranscriptArrangedSubviewBeforeSlack(row)
        row.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true
    }

    private func moveTranscriptEntryToBottomIfNeeded(withID entryID: String) {
        if let index = transcriptEntries.firstIndex(where: { $0.id == entryID }),
           index < transcriptEntries.count - 1 {
            let entry = transcriptEntries.remove(at: index)
            transcriptEntries.append(entry)
        }

        guard let row = transcriptRuntimeStepRowViewsByEntryID[entryID],
              transcriptStack.arrangedSubviews.contains(row) else {
            return
        }

        transcriptStack.removeArrangedSubview(row)
        insertTranscriptArrangedSubviewBeforeSlack(row)
    }

    private func ensureTranscriptStreamingSlackSpacerAttached() {
        guard !transcriptStack.arrangedSubviews.contains(transcriptStreamingSlackSpacer) else { return }
        transcriptStack.addArrangedSubview(transcriptStreamingSlackSpacer)
    }

    private func insertTranscriptArrangedSubviewBeforeSlack(_ view: NSView) {
        ensureTranscriptStreamingSlackSpacerAttached()
        let insertionIndex = max(transcriptStack.arrangedSubviews.count - 1, 0)
        transcriptStack.insertArrangedSubview(view, at: insertionIndex)
    }

    private func desiredTranscriptStreamingSlackHeight() -> CGFloat {
        let clipHeight = transcriptScrollView.contentView.bounds.height
        let dynamic = floor(clipHeight * Layout.streamingFollowSlackViewportFraction)
        return max(
            Layout.streamingFollowSlackMinimum,
            min(Layout.streamingFollowSlackMaximum, dynamic)
        )
    }

    private func setTranscriptStreamingSlackHeight(_ height: CGFloat) {
        let normalized = max(Layout.streamingFollowSlackBase, floor(height))
        guard abs(normalized - currentTranscriptStreamingSlackHeight) > 0.5 else { return }
        currentTranscriptStreamingSlackHeight = normalized
        transcriptStreamingSlackHeightConstraint?.constant = normalized
        transcriptStack.invalidateIntrinsicContentSize()
        transcriptContentView.needsLayout = true
    }

    private func prepareTranscriptStreamingSlackIfNeeded() {
        guard state.isStreaming else { return }
        let desired = desiredTranscriptStreamingSlackHeight()
        if currentTranscriptStreamingSlackHeight < desired {
            setTranscriptStreamingSlackHeight(desired)
        }
    }

    private func resetTranscriptStreamingSlack() {
        setTranscriptStreamingSlackHeight(Layout.streamingFollowSlackBase)
        lastTranscriptVisibleContentHeight = 0
    }

    private func scheduleStreamingAssistantRowUpdate(entryID: String, appendedChunk: String, finalizeFormatting: Bool) {
        updateStreamingAssistantRow(
            entryID: entryID,
            appendedChunk: appendedChunk,
            finalizeFormatting: finalizeFormatting
        )
    }

    private func flushPendingStreamingAssistantRowUpdateIfNeeded() {
        return
    }

    private func resetPendingStreamingAssistantRowUpdate() {
        return
    }

    private func updateStreamingAssistantRow(entryID: String, appendedChunk: String, finalizeFormatting: Bool) {
        if !appendedChunk.isEmpty {
            currentTurnRowUpdateCount += 1
            currentTurnMaxRenderedChunkLength = max(currentTurnMaxRenderedChunkLength, appendedChunk.count)
        }
        guard let index = streamingAssistantIndex, state.messages.indices.contains(index) else { return }
        let message = state.messages[index]
        let citations = messageCitationsByEntryID[entryID] ?? []
        let highlightLength = (streamingHighlightEntryID == entryID && !finalizeFormatting) ? streamingHighlightSuffixLength : 0
        let highlightAlpha = (streamingHighlightEntryID == entryID && !finalizeFormatting) ? streamingHighlightAlpha : 1
        let isHighlightOnlyRefresh = appendedChunk.isEmpty && !finalizeFormatting
        if let transcriptIndex = transcriptEntries.firstIndex(where: { $0.id == entryID }) {
            transcriptEntries[transcriptIndex] = .message(
                TranscriptMessageEntry(id: entryID, message: message)
            )
        }
        if let row = transcriptMessageRowViewsByEntryID[entryID] {
            if isHighlightOnlyRefresh {
                row.updateStreamingHighlight(length: highlightLength, alpha: highlightAlpha)
                return
            }
            let viewportNeedsRefresh = row.updateStreamingAssistant(
                fullText: message.content,
                appendedChunk: appendedChunk,
                citations: citations,
                highlightedSuffixLength: highlightLength,
                highlightedAlpha: highlightAlpha,
                finalizeFormatting: finalizeFormatting
            )
            if viewportNeedsRefresh || finalizeFormatting {
                scheduleTranscriptViewportRefresh(scrollToBottom: finalizeFormatting)
            }
        } else {
            renderTranscript()
            if !isHighlightOnlyRefresh {
                scheduleTranscriptViewportRefresh(scrollToBottom: finalizeFormatting)
            }
        }
    }

    private func beginStreamingHighlight(entryID: String, suffixLength: Int) {
        guard suffixLength > 0 else {
            resetStreamingHighlight()
            return
        }

        resetStreamingHighlight()
        streamingHighlightEntryID = entryID
        streamingHighlightSuffixLength = suffixLength
        streamingHighlightAlpha = 0.28
        streamingHighlightFadeStartedAt = CACurrentMediaTime()

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.streamingHighlightEntryID == entryID else {
                timer.invalidate()
                return
            }
            self.refreshStreamingHighlightAnimationState()
            if self.streamingHighlightEntryID == nil {
                timer.invalidate()
                self.streamingHighlightFadeTimer = nil
            }
        }
        streamingHighlightFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshStreamingHighlightAnimationState(now: CFTimeInterval = CACurrentMediaTime()) {
        guard let entryID = streamingHighlightEntryID,
              let startedAt = streamingHighlightFadeStartedAt else {
            return
        }

        let progress = min(max((now - startedAt) / 0.18, 0), 1)
        streamingHighlightAlpha = 0.28 + ((1 - 0.28) * progress)

        if progress >= 1 {
            streamingHighlightEntryID = nil
            streamingHighlightSuffixLength = 0
            streamingHighlightAlpha = 1
            streamingHighlightFadeStartedAt = nil
            transcriptMessageRowViewsByEntryID[entryID]?.updateStreamingHighlight(length: 0, alpha: 1)
            streamingHighlightFadeTimer?.invalidate()
            streamingHighlightFadeTimer = nil
        } else {
            transcriptMessageRowViewsByEntryID[entryID]?.updateStreamingHighlight(
                length: streamingHighlightSuffixLength,
                alpha: streamingHighlightAlpha
            )
        }
    }

    private func renderedAssistantHighlightLength(
        from previousText: String,
        to nextText: String,
        fallbackRawDelta: String
    ) -> Int {
        let fallbackLength = (fallbackRawDelta as NSString).length
        guard AskMarkdownRenderer.prefersStructuredStreamingRendering(for: previousText)
            || AskMarkdownRenderer.prefersStructuredStreamingRendering(for: nextText)
            || nextText.contains("```") else {
            return fallbackLength
        }

        let previousDisplay = AskMarkdownRenderer.displayStringForAssistantText(previousText)
        let nextDisplay = AskMarkdownRenderer.displayStringForAssistantText(nextText)
        guard nextDisplay.hasPrefix(previousDisplay) else {
            return fallbackLength
        }

        let appendedDisplay = String(nextDisplay.dropFirst(previousDisplay.count))
        let displayedLength = (appendedDisplay as NSString).length
        return displayedLength > 0 ? displayedLength : fallbackLength
    }

    private func resetStreamingHighlight() {
        let previousEntryID = streamingHighlightEntryID
        streamingHighlightFadeTimer?.invalidate()
        streamingHighlightFadeTimer = nil
        streamingHighlightFadeStartedAt = nil
        streamingHighlightEntryID = nil
        streamingHighlightSuffixLength = 0
        streamingHighlightAlpha = 1
        previousEntryID.flatMap { transcriptMessageRowViewsByEntryID[$0] }?.updateStreamingHighlight(length: 0, alpha: 1)
    }

    private func rowCurrentText(for entryID: String) -> String {
        guard let index = transcriptEntries.firstIndex(where: { $0.id == entryID }),
              case .message(let entry) = transcriptEntries[index] else {
            return ""
        }
        return entry.message.content
    }

    private func authoritativeAssistantContent(finalMessage: String) -> String {
        let normalizedFinal = normalizedStreamingText(finalMessage)
        if let index = streamingAssistantIndex,
           state.messages.indices.contains(index) {
            let content = state.messages[index].content
            let normalizedCurrent = normalizedStreamingText(content)
            if normalizedCurrent.isEmpty {
                return finalMessage
            }
            if normalizedCurrent == normalizedFinal {
                return content
            }
            if normalizedFinal.hasPrefix(normalizedCurrent) || normalizedFinal.count > normalizedCurrent.count {
                return finalMessage
            }
            return content
        }
        return finalMessage
    }

    private func normalizedStreamingText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func elapsedSinceCurrentTurnSubmission() -> Int {
        guard let currentTurnSubmittedAt else { return -1 }
        return Int(Date().timeIntervalSince(currentTurnSubmittedAt) * 1000)
    }

    private func scheduleTranscriptViewportRefresh(scrollToBottom: Bool) {
        if !scrollToBottom {
            capturePendingTranscriptViewportAnchorIfNeeded()
            cancelTranscriptScrollAnimation()
            lastTranscriptTargetOffset = -1
        } else {
            clearPendingTranscriptViewportAnchor()
        }
        pendingTranscriptViewportShouldScrollToBottom = scrollToBottom
        guard pendingTranscriptViewportRefreshWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let shouldScroll = self.pendingTranscriptViewportShouldScrollToBottom
            self.pendingTranscriptViewportShouldScrollToBottom = false
            self.pendingTranscriptViewportRefreshWorkItem = nil
            self.refreshTranscriptViewport(scrollToBottom: shouldScroll)
        }
        pendingTranscriptViewportRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Layout.streamingUpdateFrameInterval,
            execute: workItem
        )
    }

    private func resetPendingTranscriptViewportRefresh() {
        pendingTranscriptViewportRefreshWorkItem?.cancel()
        pendingTranscriptViewportRefreshWorkItem = nil
        pendingTranscriptViewportShouldScrollToBottom = false
        clearPendingTranscriptViewportAnchor()
        lastTranscriptContentFrameSize = .zero
        lastTranscriptTargetOffset = -1
        cancelTranscriptScrollAnimation()
    }

    private func flushPendingTranscriptViewportRefreshIfNeeded() {
        guard pendingTranscriptViewportRefreshWorkItem != nil else { return }
        pendingTranscriptViewportRefreshWorkItem?.cancel()
        pendingTranscriptViewportRefreshWorkItem = nil
        let shouldScroll = pendingTranscriptViewportShouldScrollToBottom
        pendingTranscriptViewportShouldScrollToBottom = false
        refreshTranscriptViewport(scrollToBottom: shouldScroll)
    }

    private func settleTranscriptViewport(scrollToBottom: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshTranscriptViewport(scrollToBottom: scrollToBottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.streamingUpdateFrameInterval) { [weak self] in
            self?.refreshTranscriptViewport(scrollToBottom: scrollToBottom)
        }
    }

    @objc private func handleTranscriptScrollBoundsChanged(_ notification: Notification) {
        updateTranscriptScrollIndicator(showTemporarily: !state.isStreaming)
    }

    private func updateTranscriptScrollIndicator(showTemporarily: Bool) {
        guard !state.isStreaming else {
            transcriptScrollIndicator.isHidden = true
            return
        }
        let visibleHeight = transcriptScrollView.contentView.bounds.height
        let contentHeight = transcriptContentView.frame.height
        let offsetY = transcriptScrollView.contentView.bounds.origin.y
        transcriptScrollIndicator.update(
            contentHeight: contentHeight,
            visibleHeight: visibleHeight,
            offsetY: offsetY,
            showTemporarily: showTemporarily
        )
    }

        private func scrollTranscript(to targetOffset: CGFloat) {
            let clipView = transcriptScrollView.contentView
            let maxOffset = max(transcriptContentView.frame.height - clipView.bounds.height, 0)
            let clampedOffset = max(0, min(targetOffset, maxOffset))
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: clampedOffset))
            transcriptScrollView.reflectScrolledClipView(clipView)
        updateTranscriptScrollIndicator(showTemporarily: !state.isStreaming)
        appendSmokeViewportTrace(reason: "scroll")
    }

    private func refreshTranscriptViewport(scrollToBottom: Bool) {
        transcriptContentView.layoutSubtreeIfNeeded()
        enforcePanelComfortBoundsIfNeeded()
        let width = max(floor(transcriptScrollView.contentView.bounds.width), 1)
        if state.isStreaming {
            prepareTranscriptStreamingSlackIfNeeded()
        }

        var stackHeight = max(ceil(transcriptStack.fittingSize.height), 1)
        let visibleContentHeight = max(stackHeight - currentTranscriptStreamingSlackHeight, 1)
        if state.isStreaming {
            let contentGrowth = visibleContentHeight - lastTranscriptVisibleContentHeight
            if contentGrowth > 0.5 && currentTranscriptStreamingSlackHeight > Layout.streamingFollowSlackBase {
                let nextSlack = max(
                    Layout.streamingFollowSlackBase,
                    currentTranscriptStreamingSlackHeight - contentGrowth
                )
                if abs(nextSlack - currentTranscriptStreamingSlackHeight) > 0.5 {
                    setTranscriptStreamingSlackHeight(nextSlack)
                    transcriptContentView.layoutSubtreeIfNeeded()
                    stackHeight = max(ceil(transcriptStack.fittingSize.height), 1)
                }
            }
        }
        lastTranscriptVisibleContentHeight = max(stackHeight - currentTranscriptStreamingSlackHeight, 1)
        let height = stackHeight
        let nextSize = NSSize(width: width, height: height)
        if abs(nextSize.width - lastTranscriptContentFrameSize.width) > 0.5
            || abs(nextSize.height - lastTranscriptContentFrameSize.height) > 0.5 {
            transcriptContentView.frame = NSRect(origin: .zero, size: nextSize)
            lastTranscriptContentFrameSize = nextSize
        }
        enforcePanelComfortBoundsIfNeeded()
        updateTranscriptScrollIndicator(showTemporarily: false)
        guard scrollToBottom else {
            preservePendingTranscriptViewportAnchorIfPossible()
            cancelTranscriptScrollAnimation()
            lastTranscriptTargetOffset = -1
            clearPendingTranscriptViewportAnchor()
            appendSmokeViewportTrace(reason: "viewport_refresh", scrollToBottom: false)
            return
        }
        clearPendingTranscriptViewportAnchor()
        let clipView = transcriptScrollView.contentView
        let scrollableContentHeight = state.isStreaming
            ? max(0, transcriptContentView.frame.height - currentTranscriptStreamingSlackHeight)
            : transcriptContentView.frame.height
        let maxY = max(0, scrollableContentHeight - clipView.bounds.height)
        let targetY = transcriptContentView.isFlipped ? floor(maxY) : 0
        if abs(targetY - lastTranscriptTargetOffset) > 0.5 {
            lastTranscriptTargetOffset = targetY
            if state.isStreaming {
                scrollTranscript(to: targetY)
            } else {
                animateTranscriptScroll(to: targetY)
            }
        }
        appendSmokeViewportTrace(reason: "viewport_refresh", scrollToBottom: true)
    }

    private func animateTranscriptScroll(to targetOffset: CGFloat) {
        transcriptScrollAnimationTargetOffset = targetOffset
        guard transcriptScrollAnimationWorkItem == nil else { return }
        scheduleTranscriptScrollAnimationStep()
    }

    private func scheduleTranscriptScrollAnimationStep() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.transcriptScrollAnimationWorkItem = nil
            guard let targetOffset = self.transcriptScrollAnimationTargetOffset else { return }

            let currentOffset = self.transcriptScrollView.contentView.bounds.origin.y
            let delta = targetOffset - currentOffset
            if abs(delta) <= 0.5 {
                self.scrollTranscript(to: targetOffset)
                self.transcriptScrollAnimationTargetOffset = nil
                return
            }

            let direction: CGFloat = delta >= 0 ? 1 : -1
            let easedStep = max(3, min(22, abs(delta) * 0.26)) * direction
            self.scrollTranscript(to: currentOffset + easedStep)
            self.scheduleTranscriptScrollAnimationStep()
        }
        transcriptScrollAnimationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Layout.streamingUpdateFrameInterval,
            execute: workItem
        )
    }

    private func cancelTranscriptScrollAnimation() {
        transcriptScrollAnimationWorkItem?.cancel()
        transcriptScrollAnimationWorkItem = nil
        transcriptScrollAnimationTargetOffset = nil
        appendSmokeViewportTrace(reason: "scroll_animation_cancel")
    }

    private func updateTranscriptDocumentFrame() {
        refreshTranscriptViewport(scrollToBottom: false)
    }

    private func scrollTranscriptToBottom() {
        refreshTranscriptViewport(scrollToBottom: true)
    }

    private func cancelSyntheticStreamingWorkItems() {
        syntheticStreamingWorkItems.forEach { $0.cancel() }
        syntheticStreamingWorkItems.removeAll(keepingCapacity: false)
    }

    private func capturePendingTranscriptViewportAnchorIfNeeded() {
        guard pendingTranscriptViewportAnchorEntryID == nil,
              let entryID = tracedAssistantEntryID(),
              let row = transcriptMessageRowViewsByEntryID[entryID] else {
            return
        }
        let clipView = transcriptScrollView.contentView
        let rowRect = row.convert(row.bounds, to: transcriptContentView)
        pendingTranscriptViewportAnchorEntryID = entryID
        pendingTranscriptViewportAnchorVisibleMinY = rowRect.minY - clipView.bounds.origin.y
    }

    private func preservePendingTranscriptViewportAnchorIfPossible() {
        guard let entryID = pendingTranscriptViewportAnchorEntryID,
              let targetVisibleMinY = pendingTranscriptViewportAnchorVisibleMinY,
              let row = transcriptMessageRowViewsByEntryID[entryID] else {
            return
        }
        let clipView = transcriptScrollView.contentView
        let rowRect = row.convert(row.bounds, to: transcriptContentView)
        var desiredOffset = rowRect.minY - targetVisibleMinY
        let visibleHeight = clipView.bounds.height
        let followBottomLimit = max(0, visibleHeight - Layout.streamingFollowSlackBase)
        let anchoredBottomVisibleY = rowRect.maxY - desiredOffset
        if anchoredBottomVisibleY > followBottomLimit {
            desiredOffset += anchoredBottomVisibleY - followBottomLimit
        }
        scrollTranscript(to: desiredOffset)
    }

    private func clearPendingTranscriptViewportAnchor() {
        pendingTranscriptViewportAnchorEntryID = nil
        pendingTranscriptViewportAnchorVisibleMinY = nil
    }

    private func appendSmokeViewportTrace(reason: String, scrollToBottom: Bool? = nil) {
        guard let fileURL = smokeViewportTraceFileURL else { return }

        struct SmokeViewportTraceRecord: Encodable {
            let sequence: Int
            let timestamp: TimeInterval
            let reason: String
            let scrollToBottom: Bool?
            let scrollOffsetY: CGFloat
            let contentHeight: CGFloat
            let visibleHeight: CGFloat
            let streamingSlackHeight: CGFloat
            let assistantRowVisibleMinY: CGFloat?
            let assistantRowHeight: CGFloat?
            let loadingStatusVisibleMinY: CGFloat?
            let pendingScrollToBottom: Bool
            let lastTargetOffset: CGFloat
            let scrollAnimationTargetOffset: CGFloat?
            let isStreaming: Bool
            let loadingStatusText: String?
        }

        let clipView = transcriptScrollView.contentView
        let assistantRect = tracedAssistantRowRect()
        let loadingRect = loadingStatusRowRect().map {
            CGRect(
                x: $0.origin.x,
                y: $0.origin.y - clipView.bounds.origin.y,
                width: $0.width,
                height: $0.height
            )
        }
        let record = SmokeViewportTraceRecord(
            sequence: smokeViewportTraceSequence,
            timestamp: Date().timeIntervalSince1970,
            reason: reason,
            scrollToBottom: scrollToBottom,
            scrollOffsetY: clipView.bounds.origin.y,
            contentHeight: transcriptContentView.frame.height,
            visibleHeight: clipView.bounds.height,
            streamingSlackHeight: currentTranscriptStreamingSlackHeight,
            assistantRowVisibleMinY: assistantRect.map { $0.minY - clipView.bounds.origin.y },
            assistantRowHeight: assistantRect?.height,
            loadingStatusVisibleMinY: loadingRect?.minY,
            pendingScrollToBottom: pendingTranscriptViewportShouldScrollToBottom,
            lastTargetOffset: lastTranscriptTargetOffset,
            scrollAnimationTargetOffset: transcriptScrollAnimationTargetOffset,
            isStreaming: state.isStreaming,
            loadingStatusText: currentLoadingStatusText
        )
        smokeViewportTraceSequence += 1

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(record)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            diagnosticsLogger.log(
                "ask.smoke",
                "failed to append viewport trace path=\(fileURL.path) error=\(error.localizedDescription)"
            )
        }
    }

    private func tracedAssistantEntryID() -> String? {
        streamingAssistantEntryID ?? transcriptEntries.reversed().compactMap { entry -> String? in
            guard case .message(let messageEntry) = entry,
                  messageEntry.message.role == .assistant else {
                return nil
            }
            return messageEntry.id
        }.first
    }

    private func tracedAssistantRowRect() -> CGRect? {
        let entryID = tracedAssistantEntryID()
        guard let entryID,
              let row = transcriptMessageRowViewsByEntryID[entryID] else {
            return nil
        }
        return row.convert(row.bounds, to: transcriptContentView)
    }

    private func loadingStatusRowRect() -> CGRect? {
        guard let loadingStatusRowView,
              transcriptStack.arrangedSubviews.contains(loadingStatusRowView) else {
            return nil
        }
        return loadingStatusRowView.convert(loadingStatusRowView.bounds, to: transcriptContentView)
    }

    private func lastUserRowRect() -> CGRect? {
        let entryID = transcriptEntries.reversed().compactMap { entry -> String? in
            guard case .message(let messageEntry) = entry,
                  messageEntry.message.role == .user else {
                return nil
            }
            return messageEntry.id
        }.first
        guard let entryID,
              let row = transcriptMessageRowViewsByEntryID[entryID] else {
            return nil
        }
        return row.convert(row.bounds, to: transcriptContentView)
    }

    private func finalizeSmokeViewportTrace(reason: String) {
        guard smokeViewportTraceFileURL != nil else { return }
        appendSmokeViewportTrace(reason: reason)
        smokeViewportTraceFileURL = nil
        smokeViewportTraceSequence = 0
    }

    private func syntheticResponseChunks(from text: String, chunkSize: Int) -> [String] {
        guard chunkSize > 0 else { return [text] }

        var chunks: [String] = []
        var buffer = ""
        buffer.reserveCapacity(chunkSize)

        for character in text {
            buffer.append(character)
            if buffer.count >= chunkSize {
                chunks.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            chunks.append(buffer)
        }
        return chunks
    }

#if DEBUG
    struct TestingTranscriptViewportSnapshot {
        let scrollOffsetY: CGFloat
        let contentHeight: CGFloat
        let visibleHeight: CGFloat
        let streamingSlackHeight: CGFloat
        let assistantRowHeight: CGFloat
        let assistantRowVisibleMinY: CGFloat
        let loadingStatusVisibleMinY: CGFloat
        let lastUserRowVisibleMaxY: CGFloat
    }

    struct TestingComposerMetricsSnapshot {
        let panelWidth: CGFloat
        let textHeight: CGFloat
        let containerHeight: CGFloat
        let isCompactLayout: Bool
        let textViewportWidth: CGFloat
        let textContentWidth: CGFloat
        let textScrollOffsetX: CGFloat
        let textRightGap: CGFloat
        let sendButtonBottomGap: CGFloat
    }

    struct TestingPendingApprovalLayoutSnapshot {
        let isVisible: Bool
        let title: String
        let detailHidden: Bool
        let previewHidden: Bool
        let appearsAboveComposer: Bool
        let confirmButtonWidth: CGFloat
        let cancelButtonWidth: CGFloat
    }

    struct TestingTaskContinuitySnapshot {
        let isVisible: Bool
        let title: String
        let meta: String
        let detail: String
    }

    struct TestingScopeSurfaceSnapshot {
        let isVisible: Bool
        let source: String
        let permissions: String
        let status: String
    }

    struct TestingSessionModeSnapshot {
        let isVisible: Bool
        let title: String
        let meta: String
        let detail: String
    }

    struct TestingVisualStyleSnapshot {
        let usesAskAmbient: Bool
        let supplementaryChromeVisible: Bool
        let transcriptStageCornerRadius: CGFloat
        let composerCornerRadius: CGFloat
        let sendButtonWidth: CGFloat
        let scrollIndicatorHidden: Bool
    }

    func testingStartStreamingTurn(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancelCurrentRequest()
        startStreamingTurn(with: trimmed)
        flushPendingStreamingAssistantRowUpdateIfNeeded()
        flushPendingTranscriptViewportRefreshIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    func testingApplyAssistantDelta(delta: String, fullText: String) {
        handleStreamEvent(.delta(delta, fullText: fullText))
        flushPendingStreamingAssistantRowUpdateIfNeeded()
        flushPendingTranscriptViewportRefreshIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    func testingApplyRuntimeStep(_ step: AskRuntimeStepEvent) {
        handleStreamEvent(.runtimeStep(step))
        flushPendingStreamingAssistantRowUpdateIfNeeded()
        flushPendingTranscriptViewportRefreshIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    func testingFinishAssistantResponse(_ fullText: String) {
        handleCompletion(.success(AskSessionResponse(message: fullText, cards: [], metadata: ["source": "synthetic"])))
        flushPendingStreamingAssistantRowUpdateIfNeeded()
        flushPendingTranscriptViewportRefreshIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    func testingCompleteResponse(_ response: AskSessionResponse) {
        handleCompletion(.success(response))
        flushPendingStreamingAssistantRowUpdateIfNeeded()
        flushPendingTranscriptViewportRefreshIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    func testingTranscriptViewportSnapshot() -> TestingTranscriptViewportSnapshot {
        flushPendingStreamingAssistantRowUpdateIfNeeded()
        flushPendingTranscriptViewportRefreshIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()

        let clipView = transcriptScrollView.contentView
        let assistantRowRect: CGRect
        if let entryID = streamingAssistantEntryID,
           let row = transcriptMessageRowViewsByEntryID[entryID] {
            assistantRowRect = row.convert(row.bounds, to: transcriptContentView)
        } else {
            assistantRowRect = .zero
        }
        let loadingRect = loadingStatusRowRect() ?? .zero
        let userRect = lastUserRowRect() ?? .zero

        return TestingTranscriptViewportSnapshot(
            scrollOffsetY: clipView.bounds.origin.y,
            contentHeight: transcriptContentView.frame.height,
            visibleHeight: clipView.bounds.height,
            streamingSlackHeight: currentTranscriptStreamingSlackHeight,
            assistantRowHeight: assistantRowRect.height,
            assistantRowVisibleMinY: assistantRowRect.minY - clipView.bounds.origin.y,
            loadingStatusVisibleMinY: loadingRect.minY - clipView.bounds.origin.y,
            lastUserRowVisibleMaxY: userRect.maxY - clipView.bounds.origin.y
        )
    }

    func testingScheduleTranscriptViewportRefresh(scrollToBottom: Bool) {
        scheduleTranscriptViewportRefresh(scrollToBottom: scrollToBottom)
    }

    func testingPendingTranscriptViewportShouldScrollToBottom() -> Bool {
        pendingTranscriptViewportShouldScrollToBottom
    }

    func testingStreamingHighlightState() -> (entryID: String?, suffixLength: Int, alpha: CGFloat) {
        (
            streamingHighlightEntryID,
            streamingHighlightSuffixLength,
            streamingHighlightAlpha
        )
    }

    func testingRenderedStreamingHighlightState() -> (suffixLength: Int, alpha: CGFloat) {
        refreshStreamingHighlightAnimationState()
        guard let entryID = streamingAssistantEntryID,
              let row = transcriptMessageRowViewsByEntryID[entryID] else {
            return (0, 1)
        }
        let state = row.currentStreamingHighlightState
        return (state.length, state.alpha)
    }

    func testingLatestRuntimeStepCodePreview() -> (text: String?, height: CGFloat) {
        guard let runtimeStepEntry = transcriptEntries.reversed().first(where: {
            if case .runtimeStep = $0 { return true }
            return false
        }),
        case .runtimeStep(let step) = runtimeStepEntry,
        let row = transcriptRuntimeStepRowViewsByEntryID[step.id] else {
            return (nil, 0)
        }
        return (row.testingCodePreviewText, row.testingCodePreviewHeight)
    }

    func testingLatestVisibleRuntimeStepCodePreview() -> (title: String?, text: String?, height: CGFloat) {
        guard let runtimeStepEntry = transcriptEntries.reversed().first(where: { entry in
            guard case .runtimeStep(let step) = entry,
                  let row = transcriptRuntimeStepRowViewsByEntryID[step.id] else {
                return false
            }
            return row.testingCodePreviewHeight > 0
        }),
        case .runtimeStep(let step) = runtimeStepEntry,
        let row = transcriptRuntimeStepRowViewsByEntryID[step.id] else {
            return (nil, nil, 0)
        }
        return (step.title, row.testingCodePreviewText, row.testingCodePreviewHeight)
    }

    func testingResizePanel(to size: CGSize) {
        restorePanelResizeBounds()
        let newFrame = NSRect(origin: panel.frame.origin, size: size)
        panel.setFrame(newFrame, display: true)
        enforcePanelComfortBoundsIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        updateComposerMetrics()
        panel.displayIfNeeded()
    }

    func testingComposerMetricsSnapshot() -> TestingComposerMetricsSnapshot {
        hostView.layoutSubtreeIfNeeded()
        updateComposerMetrics()
        panel.displayIfNeeded()

        let sendOrigin = sendButton.convert(NSPoint.zero, to: composerContainer)
        let sendFrame = CGRect(origin: sendOrigin, size: sendButton.bounds.size)
        let textViewportFrame = composerTextClipView.convert(composerTextClipView.bounds, to: composerContainer)
        let textInset = composerTextView.textContainerInset.width * 2
        let textViewportWidth = max(0, composerTextClipView.bounds.width - textInset)
        let textContentWidth = max(0, composerTextView.frame.width - textInset)
        return TestingComposerMetricsSnapshot(
            panelWidth: panel.frame.width,
            textHeight: composerTextHeightConstraint?.constant ?? 0,
            containerHeight: composerContainer.bounds.height,
            isCompactLayout: usesCompactComposerLayout,
            textViewportWidth: textViewportWidth,
            textContentWidth: textContentWidth,
            textScrollOffsetX: composerTextClipView.bounds.origin.x,
            textRightGap: sendFrame.minX - textViewportFrame.maxX,
            sendButtonBottomGap: composerContainer.bounds.maxY - sendFrame.maxY
        )
    }

    func testingPendingApprovalLayoutSnapshot() -> TestingPendingApprovalLayoutSnapshot {
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let approvalFrame = pendingApprovalContainer.convert(pendingApprovalContainer.bounds, to: panelSurfaceView)
        let composerFrame = composerContainer.convert(composerContainer.bounds, to: panelSurfaceView)
        let appearsAboveComposer: Bool
        if panelSurfaceView.isFlipped {
            appearsAboveComposer = approvalFrame.maxY <= composerFrame.minY + 1
        } else {
            appearsAboveComposer = approvalFrame.minY >= composerFrame.maxY - 1
        }
        return TestingPendingApprovalLayoutSnapshot(
            isVisible: pendingApprovalContainer.isHidden == false,
            title: pendingApprovalTitleLabel.stringValue,
            detailHidden: pendingApprovalDetailLabel.isHidden,
            previewHidden: pendingApprovalPreviewStack.isHidden,
            appearsAboveComposer: appearsAboveComposer,
            confirmButtonWidth: pendingApprovalConfirmButton.bounds.width,
            cancelButtonWidth: pendingApprovalCancelButton.bounds.width
        )
    }

    func testingTaskContinuitySnapshot() -> TestingTaskContinuitySnapshot {
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        return TestingTaskContinuitySnapshot(
            isVisible: taskContinuityContainer.isHidden == false,
            title: taskContinuityTitleLabel.stringValue,
            meta: taskContinuityMetaLabel.stringValue,
            detail: taskContinuityDetailLabel.stringValue
        )
    }

    func testingScopeSurfaceSnapshot() -> TestingScopeSurfaceSnapshot {
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        return TestingScopeSurfaceSnapshot(
            isVisible: scopeBarContainer.isHidden == false,
            source: scopeSourceLabel.stringValue,
            permissions: scopePermissionsLabel.stringValue,
            status: scopeStatusLabel.stringValue
        )
    }

    func testingSessionModeSnapshot() -> TestingSessionModeSnapshot {
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        return TestingSessionModeSnapshot(
            isVisible: sessionModeContainer.isHidden == false,
            title: sessionModeTitleLabel.stringValue,
            meta: sessionModeMetaLabel.stringValue,
            detail: sessionModeDetailLabel.stringValue
        )
    }

    func testingVisualStyleSnapshot() -> TestingVisualStyleSnapshot {
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        return TestingVisualStyleSnapshot(
            usesAskAmbient: panelSurfaceView.ambientEffectStyle == .conversationPanel,
            supplementaryChromeVisible: supplementaryChromeStack.isHidden == false,
            transcriptStageCornerRadius: transcriptStageContainer.layer?.cornerRadius ?? 0,
            composerCornerRadius: composerContainer.layer?.cornerRadius ?? 0,
            sendButtonWidth: sendButton.bounds.width,
            scrollIndicatorHidden: transcriptScrollIndicator.isHidden
        )
    }

    func testingSendButtonAcceptsFirstMouse() -> Bool {
        sendButton.acceptsFirstMouse(for: nil)
    }

    func testingSetComposerText(_ text: String) {
        composerTextView.string = text
        composerTextView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        updateComposerPlaceholder()
        updateEmptyStateVisibility()
        updateComposerMetrics()
        updateComposerActionButtonsState(animated: false)
    }

    func testingSetPendingApprovalState(
        actionID: String,
        summary: String,
        message: String? = nil,
        cards: [SkillResultCard] = []
    ) {
        pendingApprovalActionID = actionID
        pendingApprovalSummaryText = summary
        pendingApprovalMessageText = message
        pendingApprovalPreviewCards = cards
        updatePendingApprovalCard()
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    func testingShouldBypassKernelPreparation(prompt: String) -> Bool {
        shouldBypassKernelPreparation(for: prompt)
    }

    func testingShouldRefocusComposer(responseMetadata: [String: String]) -> Bool {
        shouldRefocusComposer(
            after: AskSessionResponse(
                message: "",
                cards: [],
                metadata: responseMetadata
            )
        )
    }

    func testingRuntimeStepTitles() -> [String] {
        transcriptEntries.compactMap { entry in
            guard case .runtimeStep(let step) = entry else { return nil }
            return step.title
        }
    }

    func testingAssistantMessageContents() -> [String] {
        transcriptEntries.compactMap { entry in
            guard case .message(let messageEntry) = entry,
                  messageEntry.message.role == .assistant else {
                return nil
            }
            return messageEntry.message.content
        }
    }

    func testingStateMessageContents() -> [String] {
        state.messages.map(\.content)
    }

    func testingComposerText() -> String {
        composerTextView.string
    }

    func testingCurrentSessionID() -> String {
        state.sessionID
    }

    func testingKernelMetadataValue(for key: String) -> String? {
        sessionKernelMetadata[key]
    }

    func testingPersistentAskInvocationCount() -> Int {
        persistentAskInvocationRecords.count
    }

    func testingIsUsingPersistentAskSessionShell() -> Bool {
        isUsingPersistentAskSessionShell
    }

    func testingCurrentProactiveHintText() -> String? {
        let trimmed = proactiveHintLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func testingIsShowingProactivePopup() -> Bool {
        isShowingProactivePopup
    }

    func testingSetSendButtonEnabled(_ isEnabled: Bool) {
        sendButton.isEnabled = isEnabled
    }

    func testingHasSupplementarySessionChrome() -> Bool {
        scopeBarContainer.isHidden == false
            || sessionModeContainer.isHidden == false
            || taskContinuityContainer.isHidden == false
    }

    func testingHasSaveAutomationButton() -> Bool {
        composerButtonStack.arrangedSubviews.contains(where: { $0 === saveAutomationButton })
    }

    func testingIsAutomationDraftVisible() -> Bool {
        pendingAutomationDraft != nil && cronDraftContainer.isHidden == false
    }

    func testingPendingAutomationDraftTitle() -> String? {
        pendingAutomationDraft?.title
    }

    func testingSavePendingAutomationDraft() {
        savePendingAutomationDraft()
    }

    func testingRoutePanelMouseDownToSendButton() {
        let buttonCenter = CGPoint(x: sendButton.bounds.midX, y: sendButton.bounds.midY)
        let pointInWindow = sendButton.convert(buttonCenter, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return
        }

        panel.sendEvent(event)
    }

    func testingClickSendButtonWhileComposerIsFocused() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(composerTextView)
        composerHasFocus = true
        updateComposerPlaceholder()
        updateComposerContainerAppearance(animated: false)

        let buttonCenter = CGPoint(x: sendButton.bounds.midX, y: sendButton.bounds.midY)
        let pointInWindow = sendButton.convert(buttonCenter, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return
        }

        panel.sendEvent(event)
        guard let mouseUpEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ) else {
            return
        }

        panel.sendEvent(mouseUpEvent)
    }

    func testingRouteSendButtonMouseDownWhileComposerIsFocused() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(composerTextView)
        composerHasFocus = true
        updateComposerPlaceholder()
        updateComposerContainerAppearance(animated: false)

        let buttonCenter = CGPoint(x: sendButton.bounds.midX, y: sendButton.bounds.midY)
        let pointInWindow = sendButton.convert(buttonCenter, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return
        }

        panel.sendEvent(event)
    }

    func testingCanStartWindowDragFromHeader() -> Bool {
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let pointInHeader = NSPoint(x: max(18, headerDragRegionView.bounds.minX + 18), y: headerDragRegionView.bounds.midY)
        let pointInWindow = headerDragRegionView.convert(pointInHeader, to: nil)
        return shouldBeginWindowDrag(at: pointInWindow)
    }

    func testingCanStartWindowDragFromCloseButton() -> Bool {
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let pointInButton = NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY)
        let pointInWindow = closeButton.convert(pointInButton, to: nil)
        return shouldBeginWindowDrag(at: pointInWindow)
    }

    func testingCanStartWindowDragFromComposer() -> Bool {
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        let pointInComposer = NSPoint(x: composerContainer.bounds.midX, y: composerContainer.bounds.midY)
        let pointInWindow = composerContainer.convert(pointInComposer, to: nil)
        return shouldBeginWindowDrag(at: pointInWindow)
    }

    func testingIsStreaming() -> Bool {
        state.isStreaming
    }

    func testingCommitComposerMarkedText(_ text: String) -> String {
        composerTextView.setMarkedText(
            text,
            selectedRange: NSRange(location: text.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        _ = commitComposerMarkedTextIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        return composerTextView.string
    }
#endif

    func writeSmokeStateSnapshot(to fileURL: URL) {
        flushPendingStreamingAssistantRowUpdateIfNeeded()
        flushPendingTranscriptViewportRefreshIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()

        let latestRuntimeEntry = transcriptEntries.reversed().compactMap { entry -> (AskRuntimeStepEvent, TranscriptRuntimeStepRowView?)? in
            guard case .runtimeStep(let step) = entry else { return nil }
            return (step, transcriptRuntimeStepRowViewsByEntryID[step.id])
        }.first
        let latestRuntimeStep = latestRuntimeEntry?.0
        let latestRuntimeRow = latestRuntimeEntry?.1
        let latestRuntimePreviewText = latestRuntimeRow?.testingCodePreviewText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let latestVisibleCodePreviewEntry = transcriptEntries.reversed().compactMap { entry -> (AskRuntimeStepEvent, TranscriptRuntimeStepRowView)? in
            guard case .runtimeStep(let step) = entry,
                  let row = transcriptRuntimeStepRowViewsByEntryID[step.id],
                  row.testingCodePreviewHeight > 0 else {
                return nil
            }
            return (step, row)
        }.first
        let latestVisibleCodePreviewStep = latestVisibleCodePreviewEntry?.0
        let latestVisibleCodePreviewRow = latestVisibleCodePreviewEntry?.1
        let latestVisibleCodePreviewText = latestVisibleCodePreviewRow?.testingCodePreviewText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let proactiveHintText = proactiveHintLabel.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcriptContainsKernelPreparedTask = transcriptEntries.contains { entry in
            switch entry {
            case .runtimeStep(let step):
                if step.title.localizedCaseInsensitiveContains("Kernel prepared task") {
                    return true
                }
                if let detail = step.detail, detail.localizedCaseInsensitiveContains("Kernel prepared task") {
                    return true
                }
                return false
            case .message(let messageEntry):
                return messageEntry.message.content.localizedCaseInsensitiveContains("Kernel prepared task")
            }
        }

        let snapshot = SmokeStateSnapshot(
            timestamp: Date().timeIntervalSince1970,
            isVisible: isVisible,
            isStreaming: state.isStreaming,
            sessionID: state.sessionID,
            composerText: composerTextView.string,
            stateMessageCount: state.messages.count,
            assistantMessageCount: state.messages.filter { $0.role == .assistant }.count,
            userMessageCount: state.messages.filter { $0.role == .user }.count,
            isUsingPersistentAskSessionShell: isUsingPersistentAskSessionShell,
            persistentAskInvocationCount: persistentAskInvocationRecords.count,
            isShowingProactivePopup: isShowingProactivePopup,
            proactiveHintText: proactiveHintText.isEmpty ? nil : proactiveHintText,
            didObserveRuntimeCodePreview: didObserveRuntimeCodePreview,
            maxObservedRuntimeCodePreviewHeight: maxObservedRuntimeCodePreviewHeight,
            hasSupplementaryChrome: scopeBarContainer.isHidden == false
                || sessionModeContainer.isHidden == false
                || taskContinuityContainer.isHidden == false,
            scopeBarHidden: scopeBarContainer.isHidden,
            sessionModeHidden: sessionModeContainer.isHidden,
            taskContinuityHidden: taskContinuityContainer.isHidden,
            hasPendingApproval: pendingApprovalContainer.isHidden == false,
            pendingApprovalTitle: pendingApprovalTitleLabel.stringValue.isEmpty ? nil : pendingApprovalTitleLabel.stringValue,
            pendingApprovalDetail: pendingApprovalDetailLabel.isHidden || pendingApprovalDetailLabel.stringValue.isEmpty ? nil : pendingApprovalDetailLabel.stringValue,
            pendingApprovalConfirmEnabled: pendingApprovalConfirmButton.isEnabled,
            pendingApprovalCancelEnabled: pendingApprovalCancelButton.isEnabled,
            latestRuntimeStepTitle: latestRuntimeStep?.title,
            latestRuntimeStepState: latestRuntimeStep?.state.rawValue,
            latestRuntimeStepDetail: latestRuntimeStep?.detail,
            latestRuntimeCodePreviewHeight: latestRuntimeRow?.testingCodePreviewHeight ?? 0,
            latestRuntimeCodePreviewSample: latestRuntimePreviewText.map { String($0.prefix(400)) },
            latestVisibleCodePreviewStepTitle: latestVisibleCodePreviewStep?.title,
            latestVisibleCodePreviewHeight: latestVisibleCodePreviewRow?.testingCodePreviewHeight ?? 0,
            latestVisibleCodePreviewSample: latestVisibleCodePreviewText.map { String($0.prefix(400)) },
            transcriptContainsKernelPreparedTask: transcriptContainsKernelPreparedTask,
            activeTaskID: sessionKernelMetadata["active_task_id"],
            activeTaskResumeToken: sessionKernelMetadata["active_task_resume_token"],
            activeTaskWorkspaceRoot: AskWorkspaceRootSupport.normalizedWorkspaceRoot(
                sessionKernelMetadata["active_task_workspace_root"]
            ) ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(sessionKernelMetadata["workspace_root"]),
            latestPlaygroundArtifactEntryFile: sessionKernelMetadata["playground_artifact_entry_file"],
            interactiveTaskScopeGranted: boolKernelMetadataValue("interactive_task_scope_granted", in: sessionKernelMetadata) ?? false
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: Data.WritingOptions.atomic)
        } catch {
            diagnosticsLogger.log(
                "ask.smoke",
                "failed to write state snapshot path=\(fileURL.path) error=\(error.localizedDescription)"
            )
        }
    }

    // MARK: - Ask Entrance Sweep
    // The Ask window entrance keeps all motion-specific wiring in one place so we can
    // disable or retune it quickly. The structure mirrors the floating toolbar:
    // 1) a crisp border segment that travels directly on the panel outline
    // 2) a brighter orb / aura that rides with that segment
    // 3) two mirrored passes that chase each other from the selection start toward the end
    private var entranceFlowAccentColor: NSColor {
        NSColor(calibratedRed: 1, green: 78.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
    }

    private var entranceFlowCoreColor: NSColor {
        NSColor(calibratedRed: 1, green: 96.0 / 255.0, blue: 56.0 / 255.0, alpha: 1)
    }

    private var entranceFlowAuraCoreColor: NSColor {
        NSColor(calibratedRed: 1, green: 70.0 / 255.0, blue: 36.0 / 255.0, alpha: 1)
    }

    private var entranceFlowAuraMidColor: NSColor {
        NSColor(calibratedRed: 1, green: 52.0 / 255.0, blue: 24.0 / 255.0, alpha: 1)
    }

    private func configureEntranceFlowLayers() {
        guard let hostLayer = entranceFlowOverlayView.layer else { return }
        let effect = DesignTokens.Effects.ResultLoadingLine.self

        hostLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        hostLayer.masksToBounds = false
        hostLayer.backgroundColor = NSColor.clear.cgColor

        entranceFlowContainerLayer.masksToBounds = false
        entranceFlowContainerLayer.compositingFilter = "screenBlendMode"

        configureEntranceSweepLineLayer(
            entranceFlowPrimaryLayer,
            opacity: Layout.entranceFlowPrimaryOpacity,
            shadowOpacity: effect.shadowOpacity
        )
        configureEntranceSweepLineLayer(
            entranceFlowSecondaryLayer,
            opacity: Layout.entranceFlowSecondaryOpacity,
            shadowOpacity: effect.shadowOpacity * 0.72
        )
        configureEntranceSweepAuraLayer(
            entranceFlowPrimaryAuraLayer,
            opacity: effect.auraOpacity * 1.95,
            shadowOpacity: effect.auraShadowOpacity * 1.75
        )
        configureEntranceSweepAuraLayer(
            entranceFlowSecondaryAuraLayer,
            opacity: effect.auraOpacity * 1.5,
            shadowOpacity: effect.auraShadowOpacity * 1.25
        )

        hostLayer.addSublayer(entranceFlowContainerLayer)
        hostLayer.addSublayer(entranceFlowPrimaryAuraLayer)
        hostLayer.addSublayer(entranceFlowSecondaryAuraLayer)
        entranceFlowContainerLayer.addSublayer(entranceFlowPrimaryLayer)
        entranceFlowContainerLayer.addSublayer(entranceFlowSecondaryLayer)
    }

    private func configureEntranceSweepLineLayer(
        _ layer: CAShapeLayer,
        opacity: Float,
        shadowOpacity: Float
    ) {
        let effect = DesignTokens.Effects.ResultLoadingLine.self
        layer.fillColor = NSColor.clear.cgColor
        layer.strokeColor = entranceFlowCoreColor.cgColor
        layer.lineWidth = Layout.entranceFlowLineThickness
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.opacity = opacity
        layer.shadowColor = entranceFlowAuraCoreColor.withAlphaComponent(0.96).cgColor
        layer.shadowOpacity = min(1, shadowOpacity * 1.45)
        layer.shadowRadius = effect.shadowRadius + 3
        layer.shadowOffset = .zero
        layer.compositingFilter = "screenBlendMode"
    }

    private func configureEntranceSweepAuraLayer(
        _ layer: CAGradientLayer,
        opacity: Float,
        shadowOpacity: Float
    ) {
        let effect = DesignTokens.Effects.ResultLoadingLine.self
        layer.type = .radial
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        layer.colors = [
            entranceFlowAuraCoreColor.withAlphaComponent(1).cgColor,
            entranceFlowAuraMidColor.withAlphaComponent(0.78).cgColor,
            entranceFlowAccentColor.withAlphaComponent(0.24).cgColor,
            entranceFlowAccentColor.withAlphaComponent(0).cgColor
        ]
        layer.locations = [0, 0.16, 0.58, 1]
        layer.opacity = opacity
        layer.shadowColor = entranceFlowAuraCoreColor.cgColor
        layer.shadowOpacity = min(1, shadowOpacity * 1.5)
        layer.shadowRadius = effect.auraShadowRadius * 1.08
        layer.shadowOffset = .zero
        layer.compositingFilter = "screenBlendMode"
    }

    private func updateEmptyStateVisibility() {
        let shouldShow = state.messages.isEmpty
            && trimmedComposerText().isEmpty
            && !state.isStreaming
            && pendingAutomationDraft == nil
            && !isRunningEntranceAnimation
        transcriptEmptyStateLabel.isHidden = !shouldShow
        if !shouldShow {
            transcriptEmptyStateLabel.alphaValue = 0
        }
        scheduleSmokeStateSnapshotWrite()
    }

    private func prepareContentForEntrance() {
        entranceRevealWorkItem?.cancel()
        contentStack.alphaValue = 0
        contentStack.isHidden = true
        transcriptEmptyStateLabel.alphaValue = 0
        transcriptEmptyStateLabel.isHidden = true
    }

    private func revealContentAfterEntrance(
        presentationID: UUID,
        targetFrame: NSRect,
        completion: @escaping () -> Void
    ) {
        guard entrancePresentationID == presentationID else { return }

        contentStack.isHidden = false
        contentStack.alphaValue = 0
        completion()
        diagnosticsLogger.log(
            "ask.animation",
            "complete frame=(\(Int(targetFrame.minX)),\(Int(targetFrame.minY)),\(Int(targetFrame.width)),\(Int(targetFrame.height)))"
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            self.contentStack.animator().alphaValue = 1
        }

        let revealWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.entrancePresentationID == presentationID else { return }
            guard self.state.messages.isEmpty, self.trimmedComposerText().isEmpty, !self.state.isStreaming else {
                self.updateEmptyStateVisibility()
                return
            }

            self.transcriptEmptyStateLabel.isHidden = false
            self.transcriptEmptyStateLabel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                self.transcriptEmptyStateLabel.animator().alphaValue = 1
            }
        }

        entranceRevealWorkItem?.cancel()
        entranceRevealWorkItem = revealWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: revealWorkItem)
        focusComposerForNewSession()
    }

    private func startEntranceFlowAnimation(
        selectionFrame: CGRect,
        transitionStartPoint: CGPoint?,
        transitionEndPoint: CGPoint?,
        targetFrame: NSRect,
        duration: TimeInterval
    ) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        guard let hostLayer = entranceFlowOverlayView.layer else { return }

        entranceFlowOverlayView.layoutSubtreeIfNeeded()
        let bounds = entranceFlowOverlayView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let fallbackStart = CGPoint(x: selectionFrame.minX, y: selectionFrame.minY)
        let fallbackEnd = CGPoint(x: selectionFrame.maxX, y: selectionFrame.maxY)
        let startScreenPoint = transitionStartPoint ?? fallbackStart
        let endScreenPoint = transitionEndPoint ?? fallbackEnd

        func localPoint(for screenPoint: CGPoint) -> CGPoint {
            CGPoint(
                x: Swift.max(0, Swift.min(bounds.width, screenPoint.x - targetFrame.minX)),
                y: Swift.max(0, Swift.min(bounds.height, screenPoint.y - targetFrame.minY))
            )
        }

        var startPoint = localPoint(for: startScreenPoint)
        var endPoint = localPoint(for: endScreenPoint)
        var delta = CGPoint(x: endPoint.x - startPoint.x, y: endPoint.y - startPoint.y)
        var length = hypot(delta.x, delta.y)
        if length < 8 {
            startPoint = CGPoint(x: bounds.width * 0.18, y: bounds.height * 0.18)
            endPoint = CGPoint(x: bounds.width * 0.82, y: bounds.height * 0.82)
            delta = CGPoint(x: endPoint.x - startPoint.x, y: endPoint.y - startPoint.y)
            length = hypot(delta.x, delta.y)
        }

        let startCorner = closestEntranceCorner(to: startPoint, delta: delta, in: bounds)
        let endCorner = closestEntranceCorner(to: endPoint, delta: CGPoint(x: -delta.x, y: -delta.y), in: bounds)
        let resolvedEndCorner = startCorner == endCorner
            ? oppositeCorner(for: startCorner)
            : endCorner

        let branchPaths = entranceBorderPaths(
            in: bounds,
            startCorner: startCorner,
            endCorner: resolvedEndCorner,
            cornerRadius: panelSurfaceView.layer?.cornerRadius ?? 0
        )
        let beginTime = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.frame = bounds
        entranceFlowContainerLayer.frame = bounds
        CATransaction.commit()

        animateEntranceFlow(
            lineLayer: entranceFlowPrimaryLayer,
            auraLayer: entranceFlowPrimaryAuraLayer,
            path: branchPaths.clockwise,
            duration: duration * 0.96,
            beginTime: beginTime,
            segmentLength: Layout.entranceFlowPrimarySegmentLength,
            lineOpacity: Layout.entranceFlowPrimaryOpacity,
            auraOpacity: DesignTokens.Effects.ResultLoadingLine.auraOpacity
        )
        animateEntranceFlow(
            lineLayer: entranceFlowSecondaryLayer,
            auraLayer: entranceFlowSecondaryAuraLayer,
            path: branchPaths.counterClockwise,
            duration: duration * 0.92,
            beginTime: beginTime + Layout.entranceFlowSecondaryDelay,
            segmentLength: Layout.entranceFlowSecondarySegmentLength,
            lineOpacity: Layout.entranceFlowSecondaryOpacity,
            auraOpacity: DesignTokens.Effects.ResultLoadingLine.auraOpacity * 0.72
        )
    }

    private func animateEntranceFlow(
        lineLayer: CAShapeLayer,
        auraLayer: CAGradientLayer,
        path: CGPath,
        duration: TimeInterval,
        beginTime: CFTimeInterval,
        segmentLength: CGFloat,
        lineOpacity: Float,
        auraOpacity: Float
    ) {
        let sweepExtent = max(
            88,
            min(
                184,
                (entranceFlowOverlayView.bounds.width + entranceFlowOverlayView.bounds.height)
                    * max(0.08, min(segmentLength, 0.26))
            )
        )
        let auraDiameter = max(120, min(188, sweepExtent * 1.14))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineLayer.removeAllAnimations()
        auraLayer.removeAllAnimations()
        lineLayer.path = path
        lineLayer.opacity = 0
        auraLayer.bounds = CGRect(x: 0, y: 0, width: auraDiameter, height: auraDiameter)
        auraLayer.opacity = 0
        CATransaction.commit()

        let strokeEnd = CAKeyframeAnimation(keyPath: "strokeEnd")
        strokeEnd.values = [0, segmentLength, 1]
        strokeEnd.keyTimes = [0, 0.24, 1]

        let strokeStart = CAKeyframeAnimation(keyPath: "strokeStart")
        strokeStart.values = [0, 0, max(0, 1 - segmentLength)]
        strokeStart.keyTimes = [0, 0.34, 1]

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, lineOpacity, lineOpacity * 0.64, 0]
        opacity.keyTimes = Layout.entranceFlowFadeKeyTimes

        let auraFade = CAKeyframeAnimation(keyPath: "opacity")
        auraFade.values = [0, auraOpacity, auraOpacity * 0.6, 0]
        auraFade.keyTimes = Layout.entranceFlowFadeKeyTimes

        let auraMove = CAKeyframeAnimation(keyPath: "position")
        auraMove.path = path
        auraMove.calculationMode = .paced

        let auraScale = CAKeyframeAnimation(keyPath: "transform")
        auraScale.values = [
            NSValue(caTransform3D: CATransform3DMakeScale(0.76, 0.76, 1)),
            NSValue(caTransform3D: CATransform3DMakeScale(1.02, 1.02, 1)),
            NSValue(caTransform3D: CATransform3DMakeScale(0.92, 0.92, 1)),
            NSValue(caTransform3D: CATransform3DMakeScale(0.84, 0.84, 1))
        ]
        auraScale.keyTimes = [0, 0.16, 0.64, 1]

        let timing = CAMediaTimingFunction(name: .linear)

        let group = CAAnimationGroup()
        group.animations = [strokeStart, strokeEnd, opacity]
        group.beginTime = beginTime
        group.duration = duration
        group.timingFunction = timing
        group.isRemovedOnCompletion = true

        let auraGroup = CAAnimationGroup()
        auraGroup.animations = [auraMove, auraFade, auraScale]
        auraGroup.beginTime = beginTime
        auraGroup.duration = duration
        auraGroup.timingFunction = timing
        auraGroup.isRemovedOnCompletion = true

        lineLayer.add(group, forKey: "ask.entrance.flow.line")
        auraLayer.add(auraGroup, forKey: "ask.entrance.flow.aura")
    }

    private func stopEntranceFlowAnimation() {
        entranceFlowContainerLayer.removeAllAnimations()
        [entranceFlowPrimaryLayer, entranceFlowSecondaryLayer, entranceFlowPrimaryAuraLayer, entranceFlowSecondaryAuraLayer]
            .forEach { layer in
                layer.removeAllAnimations()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = 0
                CATransaction.commit()
            }
    }

    private func closestEntranceCorner(
        to point: CGPoint,
        delta: CGPoint,
        in rect: CGRect
    ) -> EntranceBorderCorner {
        let corners: [(EntranceBorderCorner, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY))
        ]
        if let match = corners.min(by: { lhs, rhs in
            hypot(lhs.1.x - point.x, lhs.1.y - point.y) < hypot(rhs.1.x - point.x, rhs.1.y - point.y)
        }) {
            return match.0
        }
        if delta.x >= 0, delta.y >= 0 { return .bottomLeft }
        if delta.x >= 0, delta.y < 0 { return .topLeft }
        if delta.x < 0, delta.y >= 0 { return .bottomRight }
        return .topRight
    }

    private func oppositeCorner(for corner: EntranceBorderCorner) -> EntranceBorderCorner {
        switch corner {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomRight: return .topLeft
        case .bottomLeft: return .topRight
        }
    }

    private func entranceBorderPaths(
        in rect: CGRect,
        startCorner: EntranceBorderCorner,
        endCorner: EntranceBorderCorner,
        cornerRadius: CGFloat
    ) -> (clockwise: CGPath, counterClockwise: CGPath) {
        let geometry = entranceBorderStrokeGeometry(in: rect, cornerRadius: cornerRadius)
        let clockwise = entranceCornerSequence(
            from: startCorner,
            to: endCorner,
            clockwise: true
        )
        let counterClockwise = entranceCornerSequence(
            from: startCorner,
            to: endCorner,
            clockwise: false
        )
        return (
            entranceBorderPath(in: geometry.rect, corners: clockwise, cornerRadius: geometry.radius),
            entranceBorderPath(in: geometry.rect, corners: counterClockwise, cornerRadius: geometry.radius)
        )
    }

    private func entranceBorderStrokeGeometry(
        in rect: CGRect,
        cornerRadius: CGFloat
    ) -> (rect: CGRect, radius: CGFloat) {
        let inset = Layout.entranceFlowLineThickness / 2
        let strokeRect = rect.insetBy(dx: inset, dy: inset)
        let radius = min(
            max(0, cornerRadius - inset),
            min(strokeRect.width, strokeRect.height) / 2
        )
        return (strokeRect, radius)
    }

    private func entranceCornerSequence(
        from start: EntranceBorderCorner,
        to end: EntranceBorderCorner,
        clockwise: Bool
    ) -> [EntranceBorderCorner] {
        let ordered: [EntranceBorderCorner] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        var index = start.rawValue
        var sequence: [EntranceBorderCorner] = [ordered[index]]
        while index != end.rawValue {
            index = clockwise
                ? (index + 1) % ordered.count
                : (index - 1 + ordered.count) % ordered.count
            sequence.append(ordered[index])
        }
        return sequence
    }

    private func entranceBorderPath(
        in rect: CGRect,
        corners: [EntranceBorderCorner],
        cornerRadius: CGFloat
    ) -> CGPath {
        let points: [EntranceBorderCorner: CGPoint] = [
            .topLeft: CGPoint(x: rect.minX, y: rect.maxY),
            .topRight: CGPoint(x: rect.maxX, y: rect.maxY),
            .bottomRight: CGPoint(x: rect.maxX, y: rect.minY),
            .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
        ]

        let path = CGMutablePath()
        guard let first = corners.first, let firstPoint = points[first] else { return path }
        path.move(to: firstPoint)

        guard corners.count > 1 else { return path }
        if corners.count == 2, let lastPoint = points[corners[1]] {
            path.addLine(to: lastPoint)
            return path
        }

        for index in 1..<(corners.count - 1) {
            guard let tangent1 = points[corners[index]],
                  let tangent2 = points[corners[index + 1]] else { continue }
            path.addArc(tangent1End: tangent1, tangent2End: tangent2, radius: cornerRadius)
        }

        if let lastPoint = points[corners.last ?? first] {
            path.addLine(to: lastPoint)
        }
        return path
    }

    private func presentCitationPopover(for card: SkillResultCard, relativeTo anchorView: NSView) {
        citationPopover?.performClose(nil)

        let controller = CitationPopoverViewController(card: card) { [weak self] selectedCard in
            self?.resultCardActionCoordinator.performAction(for: selectedCard)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        citationPopover = popover
    }

    private func automationDraftIfNeeded(for prompt: String) -> AskAutomationDraft? {
        guard automationDraftParser.detectsAutomationIntent(in: prompt) else {
            return nil
        }
        return automationDraftParser.parse(
            prompt,
            workspaceRoot: sessionKernelMetadata["workspace_root"]
        )
    }

    private func automationSourceTextForComposerAction() -> String? {
        let prompt = trimmedComposerText()
        if !prompt.isEmpty {
            return prompt
        }
        return state.messages.reversed().first(where: { $0.role == .user })?.content
    }

    private func presentAutomationDraft(_ draft: AskAutomationDraft, prompt: String) {
        automationStore.saveDraft(draft)
        pendingAutomationDraft = draft
        pendingAutomationPrompt = prompt
        latestResponseMetadata["pending_automation_draft_id"] = draft.id
        latestResponseMetadata["saved_automation_job_id"] = ""

        cronDraftTitleLabel.stringValue = L10n.format(
            zhHans: "定时任务草稿：%@",
            en: "Automation draft: %@",
            draft.title
        )
        cronDraftScheduleLabel.stringValue = L10n.format(
            zhHans: "什么时候跑：%@",
            en: "When it runs: %@",
            draft.trigger.scheduleSummary
        )
        cronDraftSummaryLabel.stringValue = L10n.format(
            zhHans: "会做什么：%@\n可能会调用：%@",
            en: "What it will do: %@\nPossible capabilities: %@",
            draft.normalizedTaskPrompt,
            formattedToolDomains(draft.keyToolDomains)
        )
        if let workspaceRoot = draft.workspaceRoot, !workspaceRoot.isEmpty {
            cronDraftSummaryLabel.stringValue += "\n" + L10n.format(
                zhHans: "工作区：%@",
                en: "Workspace: %@",
                URL(fileURLWithPath: workspaceRoot).lastPathComponent
            )
        }
        cronDraftDeliveryLabel.stringValue = L10n.text(
            zhHans: "结果会回到哪里：Inbox + 系统通知",
            en: "Results go to: Inbox + system notification"
        )
        cronDraftRiskLabel.stringValue = L10n.format(
            zhHans: "不会自动做什么：%@",
            en: "What it will not do automatically: %@",
            draft.riskSummary
        )
        cronDraftContainer.isHidden = false
        applyDraftActionButtonStyles(animated: true)
        updateScopeBar()
        updateEmptyStateVisibility()
        updateComposerActionButtonsState(animated: true)
        updateComposerMetrics()
    }

    private func dismissAutomationDraft(clearComposer: Bool = false) {
        pendingAutomationDraft = nil
        pendingAutomationPrompt = nil
        latestResponseMetadata["pending_automation_draft_id"] = ""
        cronDraftContainer.isHidden = true
        if clearComposer {
            composerTextView.string = ""
            updateComposerPlaceholder()
            updateComposerMetrics()
        }
        updateScopeBar()
        updateEmptyStateVisibility()
        updateComposerActionButtonsState(animated: true)
    }

    private func savePendingAutomationDraft() {
        guard let draft = pendingAutomationDraft else { return }
        let createdJob = automationStore.createJob(from: draft)
        latestResponseMetadata["saved_automation_job_id"] = createdJob.id
        latestResponseMetadata["pending_automation_draft_id"] = ""
        dismissAutomationDraft(clearComposer: !trimmedComposerText().isEmpty)
        appendLocalRuntimeStep(
            title: L10n.text(zhHans: "已保存为定时任务", en: "Saved as an automation"),
            detail: L10n.format(
                zhHans: "首次执行：%@\n结果回传：Inbox + 系统通知\n你可以在设置 > Automation 中查看、暂停或立即运行。",
                en: "First run: %@\nDelivery: Inbox + system notification\nOpen Settings > Automation to review, pause, or run it now.",
                createdJob.nextRunAt.map(formattedAutomationDate) ?? L10n.text(zhHans: "待计算", en: "Pending")
            ),
            state: .saved
        )
        updateScopeBar()
    }

    private func applyResponseMetadata(_ metadata: [String: String]) {
        latestResponseMetadata = metadata
        for key in [
            "workspace_root",
            "current_page_url",
            "current_page_title",
            "selection_preview",
            "plan_mode_active",
            "plan_mode_summary",
            "edit_scope_limited",
            "workspace_permission_profile",
            "workspace_patch_granted",
            "workspace_write_granted",
            "workspace_shell_granted",
            "workspace_git_write_granted",
            "workspace_network_access_granted",
            "interactive_task_scope_granted",
            "interactive_task_scope_root",
            "active_task_id",
            "active_task_title",
            "active_task_objective",
            "active_task_status",
            "active_task_resume_token",
            "active_task_workspace_root",
            "active_task_todo_count",
            "active_task_todo_completed_count",
            "active_task_todo_in_progress_count",
            "active_task_todo_open_count",
            "active_task_progress_summary",
            "active_task_todo_summary",
            "kernel_child_task_count",
            "kernel_open_child_task_count",
            "kernel_waiting_task_count",
            "latest_kernel_task_status",
            "latest_kernel_child_task_status",
            "latest_kernel_child_task_title"
        ] {
            guard let value = metadata[key], !value.isEmpty else { continue }
            sessionKernelMetadata[key] = value
        }
        sessionKernelMetadata = AskWorkspaceRootSupport.sanitizedKernelMetadata(sessionKernelMetadata)
        refreshTaskContinuityStep()
        updateScopeBar()
        persistActiveSessionIfNeeded()
        scheduleSmokeStateSnapshotWrite()
    }

    private func appendLocalRuntimeStep(title: String, detail: String?, state: AskRuntimeStepState) {
        upsertRuntimeStep(
            AskRuntimeStepEvent(
                id: UUID().uuidString.lowercased(),
                kind: .executionResult,
                title: title,
                detail: detail,
                state: state
            )
        )
    }

    private func appendKernelPreparationStep(_ preparedTask: AskPreparedTask) {
        sessionKernelMetadata.merge(preparedTask.context.metadata, uniquingKeysWith: { _, new in new })
        latestKernelScopeSummary = KernelScopeSummary(
            mode: preparedTask.task.mode,
            profileID: preparedTask.profile.id,
            workspace: preparedTask.context.workspaceRootPath,
            page: preparedTask.context.currentPageURL,
            pageTitle: preparedTask.context.currentPageTitle,
            selectionPreview: preparedTask.context.selectedTextPreview,
            planModeActive: boolKernelMetadataValue("plan_mode_active", in: preparedTask.context.metadata) ?? false,
            editScopeLimited: boolKernelMetadataValue("edit_scope_limited", in: preparedTask.context.metadata) ?? false,
            planModeSummary: preparedTask.context.metadata["plan_mode_summary"],
            workspacePermissionProfile: AskWorkspacePermissionProfile.from(metadata: preparedTask.context.metadata),
            workspaceWriteGranted: boolKernelMetadataValue("workspace_write_granted", in: preparedTask.context.metadata) ?? false,
            workspaceShellGranted: boolKernelMetadataValue("workspace_shell_granted", in: preparedTask.context.metadata) ?? false,
            workspaceGitWriteGranted: boolKernelMetadataValue("workspace_git_write_granted", in: preparedTask.context.metadata) ?? false,
            workspaceNetworkAccessGranted: boolKernelMetadataValue("workspace_network_access_granted", in: preparedTask.context.metadata) ?? false,
            activeTaskTitle: preparedTask.context.metadata["active_task_title"].flatMap { trimmedKernelPreview($0, maxLength: 40) },
            capabilityCount: preparedTask.capabilities.count
        )
        refreshTaskContinuityStep()
        updateScopeBar()
    }

    private func refreshKernelResultSummaryIfNeeded(sessionID: String) {
        Task { [weak self] in
            guard let self,
                  let summary = await self.askSessionKernelBridge.resultSummary(sessionID: sessionID) else {
                return
            }

            let metadata: [String: String] = {
                var metadata: [String: String] = [
                    "kernel_result_count": String(summary.totalCount),
                    "kernel_result_success_count": String(summary.succeededCount),
                    "kernel_result_failure_count": String(summary.failureCount),
                    "kernel_result_waiting_count": String(summary.waitingApprovalCount),
                    "kernel_task_count": String(summary.taskCount),
                    "kernel_child_task_count": String(summary.childTaskCount),
                    "kernel_open_child_task_count": String(summary.openChildTaskCount),
                    "kernel_waiting_task_count": String(summary.waitingTaskCount),
                    "latest_kernel_capability_id": summary.latestCapabilityID ?? "",
                    "latest_kernel_result_status": summary.latestStatus?.rawValue ?? "",
                    "latest_kernel_task_status": summary.latestTaskStatus?.rawValue ?? "",
                    "latest_kernel_task_title": self.trimmedKernelPreview(summary.latestTaskTitle, maxLength: 120) ?? "",
                    "latest_kernel_child_task_status": summary.latestChildTaskStatus?.rawValue ?? "",
                    "latest_kernel_child_task_title": self.trimmedKernelPreview(summary.latestChildTaskTitle, maxLength: 120) ?? ""
                ]
                if let latestSummary = self.trimmedKernelPreview(summary.latestSummary, maxLength: 220) {
                    metadata["latest_kernel_result_summary"] = latestSummary
                }
                if let latestAssistantBriefTitle = self.trimmedKernelPreview(summary.latestAssistantBriefTitle, maxLength: 160) {
                    metadata["latest_assistant_brief_title"] = latestAssistantBriefTitle
                }
                if let latestAssistantBriefKind = summary.latestAssistantBriefKind {
                    metadata["latest_assistant_brief_kind"] = latestAssistantBriefKind
                }
                if let latestAssistantDeliveryChannel = summary.latestAssistantDeliveryChannel {
                    metadata["latest_assistant_delivery_channel"] = latestAssistantDeliveryChannel
                }
                return metadata
            }()

            await MainActor.run {
                guard self.state.sessionID == sessionID else { return }
                self.latestResponseMetadata.merge(metadata, uniquingKeysWith: { _, new in new })
                self.sessionKernelMetadata.merge(metadata, uniquingKeysWith: { _, new in new })
                self.removeTranscriptEntry(withID: "kernel-result-summary-\(sessionID)")
                self.refreshTaskContinuityStep()
                self.updateScopeBar()
                self.persistActiveSessionIfNeeded()
            }
        }
    }

    private func refreshTaskContinuityStep() {
        updateTaskContinuityCard()
    }

    private func updateTaskContinuityCard() {
        wantsTaskChrome = false
        taskContinuityContainer.isHidden = true
        removeTranscriptEntry(withID: taskContinuityRuntimeStepID)
        taskContinuityTitleLabel.stringValue = ""
        taskContinuityMetaLabel.stringValue = ""
        taskContinuityMetaLabel.isHidden = true
        taskContinuityDetailLabel.stringValue = ""
        taskContinuityDetailLabel.isHidden = true
    }

    private var taskContinuityRuntimeStepID: String {
        "kernel-task-continuity-\(state.sessionID)"
    }

    private func updateSessionModeCard() {
        wantsSessionChrome = false
        sessionModeContainer.isHidden = true
        sessionModeTitleLabel.stringValue = ""
        sessionModeMetaLabel.stringValue = ""
        sessionModeMetaLabel.isHidden = true
        sessionModeDetailLabel.stringValue = ""
        sessionModeDetailLabel.isHidden = true

        let languageCode = resolvedResponseLanguage()
        let sessionState = taskContinuitySessionState()
        let activeTaskTitle = sessionState.activeTaskTitle.flatMap { trimmedKernelPreview($0, maxLength: 40) }
        let activeTaskResumeToken = sessionState.activeTaskResumeToken.flatMap { trimmedKernelPreview($0, maxLength: 44) }
        let activeTaskID = sessionState.activeTaskID.flatMap { trimmedKernelPreview($0, maxLength: 24) }
        let activeTaskStatus = sessionState.activeTaskStatus
        let workspaceRoot =
            sessionState.activeTaskWorkspaceRoot
            ?? sessionKernelMetadata["interactive_task_scope_root"]
            ?? sessionKernelMetadata["workspace_root"]
        let workspaceLabel = workspaceRoot.flatMap { compactWorkspaceLabel(for: $0, maxLength: 32) }
        let hasResumeContext = hasResumeSessionContext(sessionState)
        let automationStateEntries = automationSessionStateDetails(languageCode: languageCode)
        let shouldShow =
            state.sessionOrigin != .user
            || hasResumeContext
            || !automationStateEntries.isEmpty
            || resolvedExecutionMode() == .automate

        guard shouldShow else { return }

        wantsSessionChrome = true
        let executionMode = resolvedExecutionMode()
        sessionModeContainer.isHidden = false
        sessionModeTitleLabel.stringValue = localizedSessionModeTitle(
            executionMode: executionMode,
            sessionOrigin: state.sessionOrigin,
            hasResumeContext: hasResumeContext,
            languageCode: languageCode
        )

        var metaParts = [
            localizedSessionOriginLabel(state.sessionOrigin, languageCode: languageCode),
            localizedInvocationSurfaceLabel(state.invocationSurface, languageCode: languageCode)
        ]
        if let activeTaskStatus {
            metaParts.append(localizedTaskStatusSummary(activeTaskStatus, languageCode: languageCode))
        }
        if let grantScope = workspaceExecutionGrantScopeSummary(
            workspacePermissionProfile: sessionState.workspacePermissionProfile,
            workspaceWriteGranted: sessionState.workspaceWriteGranted,
            workspaceShellGranted: sessionState.workspaceShellGranted,
            workspaceGitWriteGranted: sessionState.workspaceGitWriteGranted,
            workspaceNetworkAccessGranted: sessionState.workspaceNetworkAccessGranted
        ) {
            metaParts.append(grantScope)
        }
        sessionModeMetaLabel.stringValue = metaParts.joined(separator: " · ")
        sessionModeMetaLabel.isHidden = sessionModeMetaLabel.stringValue.isEmpty

        var detailParts: [String] = []
        if let activeTaskTitle {
            detailParts.append(
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "当前任务 %@",
                    en: "Active task %@",
                    activeTaskTitle
                )
            )
        }
        if let activeTaskResumeToken {
            detailParts.append(
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "恢复 %@",
                    en: "Resume %@",
                    activeTaskResumeToken
                )
            )
        } else if let activeTaskID {
            detailParts.append(
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "任务 ID %@",
                    en: "Task ID %@",
                    activeTaskID
                )
            )
        }
        if let workspaceLabel {
            detailParts.append(
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "工作区 %@",
                    en: "Workspace %@",
                    workspaceLabel
                )
            )
        }
        if let deliveryChannel = trimmedKernelPreview(sessionKernelMetadata["latest_assistant_delivery_channel"], maxLength: 24) {
            detailParts.append(
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "回传 %@",
                    en: "Delivery %@",
                    localizedAssistantDeliveryChannelLabel(deliveryChannel, languageCode: languageCode)
                )
            )
        }
        if let progressSummary = sessionState.activeTaskProgressSummary.flatMap({ trimmedKernelPreview($0, maxLength: 72) }) {
            detailParts.append(progressSummary)
        }
        detailParts.append(contentsOf: automationStateEntries)
        sessionModeDetailLabel.stringValue = detailParts.joined(separator: " · ")
        sessionModeDetailLabel.isHidden = detailParts.isEmpty
    }

    private func updateScopeBar() {
        wantsScopeChrome = false
        scopeBarContainer.isHidden = true
        scopeSourceLabel.stringValue = ""
        scopePermissionsLabel.stringValue = ""
        scopeStatusLabel.stringValue = ""
        scopePermissionsLabel.isHidden = true
        scopeStatusLabel.isHidden = true

        let languageCode = resolvedResponseLanguage()
        let sessionState = taskContinuitySessionState()
        let workspaceRoot =
            latestKernelScopeSummary?.workspace
            ?? sessionKernelMetadata["interactive_task_scope_root"]
            ?? sessionState.activeTaskWorkspaceRoot
            ?? sessionKernelMetadata["workspace_root"]
        let currentPageURL = latestKernelScopeSummary?.page ?? sessionKernelMetadata["current_page_url"]
        let currentPageTitle = latestKernelScopeSummary?.pageTitle ?? sessionKernelMetadata["current_page_title"]
        let selectionPreview = latestKernelScopeSummary?.selectionPreview ?? sessionKernelMetadata["selection_preview"]
        let activeTaskTitle =
            latestKernelScopeSummary?.activeTaskTitle
            ?? sessionState.activeTaskTitle.flatMap { trimmedKernelPreview($0, maxLength: 40) }
        let planModeActive = latestKernelScopeSummary?.planModeActive ?? sessionState.planModeActive
        let editScopeLimited = latestKernelScopeSummary?.editScopeLimited ?? sessionState.editScopeLimited
        let capabilityCount = latestKernelScopeSummary?.capabilityCount ?? 0
        let interactiveTaskScopeGranted = boolKernelMetadataValue("interactive_task_scope_granted", in: sessionKernelMetadata) ?? false
        let interactiveTaskScopeRoot = sessionKernelMetadata["interactive_task_scope_root"]
        let hasExplicitScopeContext =
            currentPageURL != nil
            || currentPageTitle != nil
            || workspaceRoot != nil
            || trimmedKernelPreview(selectionPreview, maxLength: 36) != nil
            || activeTaskTitle != nil
            || planModeActive
            || editScopeLimited
            || interactiveTaskScopeGranted
            || capabilityCount > 0
            || state.invocationSurface != .askWindow

        var sourceParts: [String] = []
        if hasExplicitScopeContext,
           let sourceAppName = trimmedKernelPreview(state.sourceAppName, maxLength: 24) {
            sourceParts.append(
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "来自 %@",
                    en: "From %@",
                    sourceAppName
                )
            )
        }
        if state.invocationSurface != .askWindow {
            sourceParts.append(localizedInvocationSurfaceLabel(state.invocationSurface, languageCode: languageCode))
        }
        if let pageSummary = pageScopeSummary(title: currentPageTitle, url: currentPageURL) {
            sourceParts.append(pageSummary)
        }
        if let workspaceSummary = workspaceScopeSummary(root: workspaceRoot, languageCode: languageCode) {
            sourceParts.append(workspaceSummary)
        }

        let permissionsSummary = scopePermissionsSummary(
            modeLabel: localizedExecutionModeLabel(resolvedExecutionMode(), languageCode: languageCode),
            profileID: latestKernelScopeSummary?.profileID ?? "",
            capabilityCount: capabilityCount,
            planModeActive: planModeActive,
            editScopeLimited: editScopeLimited,
            workspacePermissionProfile: latestKernelScopeSummary?.workspacePermissionProfile ?? sessionState.workspacePermissionProfile,
            workspaceWriteGranted: latestKernelScopeSummary?.workspaceWriteGranted ?? sessionState.workspaceWriteGranted,
            workspaceShellGranted: latestKernelScopeSummary?.workspaceShellGranted ?? sessionState.workspaceShellGranted,
            workspaceGitWriteGranted: latestKernelScopeSummary?.workspaceGitWriteGranted ?? sessionState.workspaceGitWriteGranted,
            workspaceNetworkAccessGranted: latestKernelScopeSummary?.workspaceNetworkAccessGranted ?? sessionState.workspaceNetworkAccessGranted
        )

        var statusParts: [String] = []
        if let activeTaskSummary = activeTaskScopeSummary(title: activeTaskTitle) {
            statusParts.append(activeTaskSummary)
        }
        if let planScopeSummary = planModeScopeSummary(
            active: planModeActive,
            summary: latestKernelScopeSummary?.planModeSummary ?? sessionKernelMetadata["plan_mode_summary"]
        ) {
            statusParts.append(planScopeSummary)
        }
        if let taskScopeSummary = interactiveTaskGrantSummary(
            granted: interactiveTaskScopeGranted,
            root: interactiveTaskScopeRoot,
            languageCode: languageCode
        ) {
            statusParts.append(taskScopeSummary)
        }
        if let selectionPreview = trimmedKernelPreview(selectionPreview, maxLength: 36) {
            statusParts.append(
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "选区 %@",
                    en: "Selection %@",
                    selectionPreview
                )
            )
        }

        scopeSourceLabel.stringValue = sourceParts.joined(separator: " · ")
        scopePermissionsLabel.stringValue = permissionsSummary
        scopePermissionsLabel.isHidden = permissionsSummary.isEmpty
        scopeStatusLabel.stringValue = statusParts.joined(separator: " · ")
        scopeStatusLabel.isHidden = scopeStatusLabel.stringValue.isEmpty
        let hasVisibleScopeSummary =
            !scopeSourceLabel.stringValue.isEmpty
            || !scopePermissionsLabel.stringValue.isEmpty
            || !scopeStatusLabel.stringValue.isEmpty
        wantsScopeChrome = hasVisibleScopeSummary
        scopeBarContainer.isHidden = !wantsScopeChrome

        updateSessionModeCard()
        updateTaskContinuityCard()
        updateSupplementaryChromeStackVisibility(sessionState: sessionState)
    }

    private func taskContinuitySessionState() -> AskAgentSessionState {
        var snapshot = AskAgentSessionState.make(sessionID: state.sessionID, maxToolCalls: 0)
        snapshot.kernelMetadata = sessionKernelMetadata
        return snapshot
    }

    private func resolvedExecutionMode() -> AskExecutionMode {
        latestKernelScopeSummary?.mode
            ?? state.requestedMode
            ?? (state.sessionOrigin == .automation ? .automate : .interactive)
    }

    private func localizedExecutionModeLabel(_ mode: AskExecutionMode, languageCode: String) -> String {
        switch mode {
        case .interactive:
            return L10n.text(languageCode: languageCode, zhHans: "交互模式", en: "Interactive")
        case .automate:
            return L10n.text(languageCode: languageCode, zhHans: "自动模式", en: "Automated")
        }
    }

    private func localizedSessionOriginLabel(_ origin: AskSessionOrigin, languageCode: String) -> String {
        switch origin {
        case .user:
            return L10n.text(languageCode: languageCode, zhHans: "用户发起", en: "User initiated")
        case .automation:
            return L10n.text(languageCode: languageCode, zhHans: "自动任务", en: "Automation")
        case .assistantFollowUp:
            return L10n.text(languageCode: languageCode, zhHans: "助手后续", en: "Assistant follow-up")
        }
    }

    private func localizedInvocationSurfaceLabel(_ surface: AskInvocationSurface, languageCode: String) -> String {
        switch surface {
        case .askBox:
            return L10n.text(languageCode: languageCode, zhHans: "画框 ASK", en: "Ask box")
        case .globalHotkey:
            return L10n.text(languageCode: languageCode, zhHans: "全局热键", en: "Global hotkey")
        case .askWindow:
            return L10n.text(languageCode: languageCode, zhHans: "Ask 窗口", en: "Ask window")
        case .automation:
            return L10n.text(languageCode: languageCode, zhHans: "自动任务", en: "Automation")
        case .inbox:
            return L10n.text(languageCode: languageCode, zhHans: "Inbox", en: "Inbox")
        case .menuBar:
            return L10n.text(languageCode: languageCode, zhHans: "菜单栏", en: "Menu bar")
        case .proactivePopup:
            return L10n.text(languageCode: languageCode, zhHans: "ASK 主动联系", en: "ASK proactive popup")
        case .cli:
            return L10n.text(languageCode: languageCode, zhHans: "命令行", en: "CLI")
        case .ide:
            return L10n.text(languageCode: languageCode, zhHans: "IDE", en: "IDE")
        case .api:
            return L10n.text(languageCode: languageCode, zhHans: "API", en: "API")
        case .notification:
            return L10n.text(languageCode: languageCode, zhHans: "通知", en: "Notification")
        case .remoteChannel:
            return L10n.text(languageCode: languageCode, zhHans: "远程通道", en: "Remote channel")
        }
    }

    private func localizedSessionModeTitle(
        executionMode: AskExecutionMode,
        sessionOrigin: AskSessionOrigin,
        hasResumeContext: Bool,
        languageCode: String
    ) -> String {
        switch (sessionOrigin, hasResumeContext) {
        case (.automation, _):
            return L10n.text(languageCode: languageCode, zhHans: "自动任务会话", en: "Automation session")
        case (.assistantFollowUp, true):
            return L10n.text(languageCode: languageCode, zhHans: "助手后续恢复", en: "Assistant follow-up resume")
        case (.assistantFollowUp, false):
            return L10n.text(languageCode: languageCode, zhHans: "助手后续会话", en: "Assistant follow-up")
        case (.user, true):
            return L10n.text(languageCode: languageCode, zhHans: "已恢复的交互会话", en: "Resumed interactive session")
        case (.user, false):
            return localizedExecutionModeLabel(executionMode, languageCode: languageCode)
        }
    }

    private func localizedAssistantDeliveryChannelLabel(_ rawValue: String, languageCode: String) -> String {
        switch rawValue.lowercased() {
        case "inbox":
            return L10n.text(languageCode: languageCode, zhHans: "Inbox", en: "Inbox")
        case "notification":
            return L10n.text(languageCode: languageCode, zhHans: "通知", en: "Notification")
        default:
            return rawValue
        }
    }

    private func compactWorkspaceLabel(for root: String, maxLength: Int) -> String {
        let normalized = root.trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf = URL(fileURLWithPath: normalized).lastPathComponent
        if let leafPreview = trimmedKernelPreview(leaf, maxLength: maxLength), !leafPreview.isEmpty {
            return leafPreview
        }
        return trimmedKernelPreview(normalized, maxLength: maxLength) ?? normalized
    }

    private func workspaceScopeSummary(root: String?, languageCode: String) -> String? {
        guard let root,
              !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return L10n.format(
            languageCode: languageCode,
            zhHans: "工作区 %@",
            en: "Workspace %@",
            compactWorkspaceLabel(for: root, maxLength: 28)
        )
    }

    private func interactiveTaskGrantSummary(
        granted: Bool,
        root: String?,
        languageCode: String
    ) -> String? {
        guard granted else { return nil }
        if let root {
            return L10n.format(
                languageCode: languageCode,
                zhHans: "任务作用域 %@",
                en: "Task scope %@",
                compactWorkspaceLabel(for: root, maxLength: 28)
            )
        }
        return L10n.text(languageCode: languageCode, zhHans: "任务级授权", en: "Task-scoped grant")
    }

    private func automationSessionStateDetails(languageCode: String) -> [String] {
        var parts: [String] = []

        let pendingDraft: AskAutomationDraft? = {
            if let pendingAutomationDraft {
                return pendingAutomationDraft
            }
            guard let draftID = latestResponseMetadata["pending_automation_draft_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !draftID.isEmpty else {
                return nil
            }
            return automationStore.draft(id: draftID)
        }()
        if let pendingDraft {
            parts.append(
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "草稿 %@ · %@",
                    en: "Draft %@ · %@",
                    pendingDraft.title,
                    pendingDraft.trigger.scheduleSummary
                )
            )
        }

        if let jobID = latestResponseMetadata["saved_automation_job_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !jobID.isEmpty,
           let job = automationStore.job(id: jobID) {
            parts.append(
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "定时任务 %@ · 下次 %@",
                    en: "Automation %@ · next %@",
                    job.title,
                    job.nextRunAt.map(formattedAutomationDate)
                        ?? L10n.text(languageCode: languageCode, zhHans: "待计算", en: "pending")
                )
            )
        }

        if let inboxItemID = latestResponseMetadata["inbox_item_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !inboxItemID.isEmpty {
            let inboxItem = automationStore.listInboxItems(limit: 80).first(where: { $0.id == inboxItemID })
            let inboxLabel =
                inboxItem.map { trimmedKernelPreview($0.title, maxLength: 40) ?? $0.title }
                ?? trimmedKernelPreview(inboxItemID, maxLength: 24)
                ?? inboxItemID
            parts.append(
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "Inbox %@",
                    en: "Inbox %@",
                    inboxLabel
                )
            )
        }

        return parts
    }

    private func makeSessionKernelMetadata(
        sourceBundleID: String?,
        sourceAppName: String?,
        initialKernelMetadata: [String: String],
        captureCurrentSelection: Bool
    ) -> [String: String] {
        var metadata = AskWorkspaceRootSupport.sanitizedKernelMetadata(initialKernelMetadata)
        if let sourceBundleID, !sourceBundleID.isEmpty {
            metadata["source_bundle_id"] = sourceBundleID
        }
        if let sourceAppName, !sourceAppName.isEmpty {
            metadata["source_app_name"] = sourceAppName
        }
        _ = captureCurrentSelection

        return metadata
    }

    private func startSessionContextCaptureIfNeeded(sourceBundleID: String?, sessionID: String) {
        _ = sourceBundleID
        _ = sessionID
        sessionContextCaptureTask?.cancel()
        sessionContextCaptureTask = nil
    }

    private func pageScopeSummary(title: String?, url: String?) -> String? {
        if let title = trimmedKernelPreview(title, maxLength: 28), !title.isEmpty {
            if let url,
               let host = URL(string: url)?.host,
               !host.isEmpty {
                return L10n.format(zhHans: "页面 %@ (%@)", en: "Page %@ (%@)", title, host)
            }
            return L10n.format(zhHans: "页面 %@", en: "Page %@", title)
        }

        if let url = trimmedKernelPreview(url, maxLength: 48), !url.isEmpty {
            return L10n.format(zhHans: "页面 %@", en: "Page %@", url)
        }

        return nil
    }

    private func planModeScopeSummary(active: Bool, summary: String?) -> String? {
        if let summary = trimmedKernelPreview(summary, maxLength: 36), !summary.isEmpty {
            return L10n.format(zhHans: "规划 %@", en: "Plan %@", summary)
        }
        guard active else { return nil }
        return L10n.text(zhHans: "只读规划", en: "Read-only plan")
    }

    private func activeTaskScopeSummary(title: String?) -> String? {
        guard let title = trimmedKernelPreview(title, maxLength: 28), !title.isEmpty else {
            return nil
        }
        return L10n.format(zhHans: "任务 %@", en: "Task %@", title)
    }

    private func scopePermissionsSummary(
        modeLabel: String,
        profileID: String,
        capabilityCount: Int,
        planModeActive: Bool,
        editScopeLimited: Bool,
        workspacePermissionProfile: AskWorkspacePermissionProfile,
        workspaceWriteGranted: Bool,
        workspaceShellGranted: Bool,
        workspaceGitWriteGranted: Bool,
        workspaceNetworkAccessGranted: Bool
    ) -> String {
        _ = modeLabel
        _ = profileID
        var parts: [String] = []
        if capabilityCount > 0 {
            parts.append(L10n.format(zhHans: "当前能力 %d", en: "Capabilities %d", capabilityCount))
        }
        if planModeActive {
            parts.append(L10n.text(zhHans: "规划模式", en: "Plan mode"))
        }
        if editScopeLimited {
            parts.append(L10n.text(zhHans: "只读", en: "Read-only"))
        }
        if workspacePermissionProfile != .manualApproval {
            let budget = AskWorkspaceExecutionBudget(
                permissionProfile: workspacePermissionProfile,
                grantsGitWriteActions: workspaceGitWriteGranted,
                grantsNetworkAccess: workspaceNetworkAccessGranted
            )
            parts.append(
                L10n.format(
                    zhHans: "权限 %@",
                    en: "Permissions %@",
                    budget.localizedCompactLabel(responseLanguage: resolvedResponseLanguage())
                )
            )
        } else if workspaceWriteGranted {
            parts.append(L10n.text(zhHans: "已授权写入", en: "Writes granted"))
        } else if workspaceShellGranted {
            parts.append(L10n.text(zhHans: "已授权 shell", en: "Shell granted"))
        }
        if workspaceGitWriteGranted {
            parts.append(L10n.text(zhHans: "git 已授权", en: "Git granted"))
        }
        if workspaceNetworkAccessGranted {
            parts.append(L10n.text(zhHans: "网络已授权", en: "Network granted"))
        }
        return parts.joined(separator: " · ")
    }

    private func workspaceExecutionGrantScopeSummary(
        workspacePermissionProfile: AskWorkspacePermissionProfile,
        workspaceWriteGranted: Bool,
        workspaceShellGranted: Bool,
        workspaceGitWriteGranted: Bool,
        workspaceNetworkAccessGranted: Bool
    ) -> String? {
        if workspacePermissionProfile != .manualApproval {
            let budget = AskWorkspaceExecutionBudget(
                permissionProfile: workspacePermissionProfile,
                grantsGitWriteActions: workspaceGitWriteGranted,
                grantsNetworkAccess: workspaceNetworkAccessGranted
            )
            return L10n.format(
                zhHans: "授权 %@",
                en: "Granted %@",
                budget.localizedCompactLabel(responseLanguage: resolvedResponseLanguage())
            )
        }
        var parts: [String] = []
        if workspaceWriteGranted {
            parts.append(L10n.text(zhHans: "写入", en: "writes"))
        }
        if workspaceShellGranted {
            parts.append(L10n.text(zhHans: "shell", en: "shell"))
        }
        if workspaceGitWriteGranted {
            parts.append(L10n.text(zhHans: "git", en: "git"))
        }
        if workspaceNetworkAccessGranted {
            parts.append(L10n.text(zhHans: "网络", en: "net"))
        }
        guard !parts.isEmpty else { return nil }
        return L10n.format(
            zhHans: "授权 %@",
            en: "Granted %@",
            parts.joined(separator: " + ")
        )
    }

    private func localizedTaskStatusSummary(_ status: AskTaskStatus, languageCode: String) -> String {
        switch status {
        case .queued:
            return L10n.text(languageCode: languageCode, zhHans: "已排队", en: "Queued")
        case .planning:
            return L10n.text(languageCode: languageCode, zhHans: "规划中", en: "Planning")
        case .running:
            return L10n.text(languageCode: languageCode, zhHans: "执行中", en: "Running")
        case .waitingApproval:
            return L10n.text(languageCode: languageCode, zhHans: "等待确认", en: "Waiting approval")
        case .blocked:
            return L10n.text(languageCode: languageCode, zhHans: "受阻", en: "Blocked")
        case .completed:
            return L10n.text(languageCode: languageCode, zhHans: "已完成", en: "Completed")
        case .failed:
            return L10n.text(languageCode: languageCode, zhHans: "失败", en: "Failed")
        case .cancelled:
            return L10n.text(languageCode: languageCode, zhHans: "已取消", en: "Cancelled")
        }
    }

    private func boolKernelMetadataValue(_ key: String, in metadata: [String: String]) -> Bool? {
        guard let rawValue = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue == "true"
    }

    private func trimmedKernelPreview(_ text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maxLength))
    }

    private func shortPermissionSummary(title: String, level: PermissionManager.ReadinessLevel) -> String {
        let suffix: String
        switch level {
        case .ready:
            suffix = L10n.text(zhHans: "就绪", en: "ready")
        case .needsAction:
            suffix = L10n.text(zhHans: "待授权", en: "needs setup")
        case .optional:
            suffix = L10n.text(zhHans: "按需", en: "optional")
        }
        return "\(title) \(suffix)"
    }

    private func formattedToolDomains(_ domains: [String]) -> String {
        let labels = domains.map { domain in
            switch domain {
            case "web":
                return L10n.text(zhHans: "网页", en: "Web")
            case "knowledge":
                return L10n.text(zhHans: "知识库", en: "Knowledge")
            case "writeback":
                return L10n.text(zhHans: "写回", en: "Writeback")
            case "calendar":
                return L10n.text(zhHans: "日历", en: "Calendar")
            case "files":
                return L10n.text(zhHans: "文件", en: "Files")
            case "automation":
                return L10n.text(zhHans: "定时任务", en: "Automation")
            default:
                return domain
            }
        }
        return labels.joined(separator: " · ")
    }

    private func formattedAutomationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppSettings.shared.appLanguage.localeIdentifier)
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("M d HH:mm")
        return formatter.string(from: date)
    }

    private func trimmedComposerText() -> String {
        composerTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasPendingComposerSubmission: Bool {
        !trimmedComposerText().isEmpty || composerTextView.hasMarkedText()
    }

    private var shouldAutoDismissOnOutsideInteraction: Bool { false }

    private func updateComposerPlaceholder() {
        let firstResponderIsComposer = (panel.firstResponder as? NSTextView) === composerTextView
        composerPlaceholder.isHidden = composerHasFocus || firstResponderIsComposer || !composerTextView.string.isEmpty
    }

    private var usesCompactComposerLayout: Bool {
        panel.frame.width <= Layout.composerCompactWidthThreshold
    }

    private func composerLineHeight() -> CGFloat {
        let font = composerTextView.font ?? DesignTokens.Typography.resultPanelBody
        return ceil(font.ascender - font.descender + font.leading)
    }

    private func applyComposerLayoutMode(textWidth: CGFloat) {
        guard let textContainer = composerTextView.textContainer else { return }
        let compactLayout = usesCompactComposerLayout
        let textInsetWidth = compactLayout ? Layout.composerCompactHorizontalTextInset : 0
        composerPlaceholder.maximumNumberOfLines = compactLayout ? 1 : Int(Layout.composerExpandedVisibleLineCount)
        composerPlaceholder.lineBreakMode = compactLayout ? .byClipping : .byWordWrapping
        composerTextView.suppressAutoScrollToSelection = compactLayout
        composerTextView.isVerticallyResizable = !compactLayout
        composerTextView.isHorizontallyResizable = compactLayout
        composerTextView.textContainerInset = NSSize(width: textInsetWidth, height: 4)
        textContainer.maximumNumberOfLines = compactLayout ? 1 : 0
        textContainer.lineBreakMode = compactLayout ? .byClipping : .byWordWrapping
        textContainer.widthTracksTextView = !compactLayout
        textContainer.containerSize = NSSize(
            width: compactLayout ? CGFloat.greatestFiniteMagnitude : textWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        composerButtonStackLeadingConstraint?.constant = compactLayout
            ? Layout.composerCompactButtonSpacing
            : Layout.composerButtonSpacing
    }

    private func updateComposerMetrics() {
        guard let textContainer = composerTextView.textContainer,
              let layoutManager = composerTextView.layoutManager else { return }

        let actionWidth = max(composerButtonStack.fittingSize.width, max(sendButton.fittingSize.width, 52))
        let buttonSpacing = usesCompactComposerLayout
            ? Layout.composerCompactButtonSpacing
            : Layout.composerButtonSpacing
        let textWidth = max(
            120,
            composerContainer.bounds.width
                - Layout.composerHorizontalInset * 2
                - buttonSpacing
                - actionWidth
        )
        applyComposerLayoutMode(textWidth: textWidth)
        composerTextWidthConstraint?.constant = 0
        composerContainer.layoutSubtreeIfNeeded()
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let usedWidth = layoutManager.usedRect(for: textContainer).width
        let contentWidth = ceil(usedWidth + composerTextView.textContainerInset.width * 2)
        if usesCompactComposerLayout {
            composerTextWidthConstraint?.constant = max(0, contentWidth - composerTextClipView.bounds.width)
        } else {
            composerTextWidthConstraint?.constant = 0
        }
        let minimumHeight = ceil(composerLineHeight() + composerTextView.textContainerInset.height * 2)
        let maxVisibleLineCount = usesCompactComposerLayout ? 1 : Layout.composerExpandedVisibleLineCount
        let maxVisibleHeight = ceil(
            (composerLineHeight() * maxVisibleLineCount)
            + (composerTextView.textContainerInset.height * 2)
        )
        let desiredHeight = ceil(usedHeight + composerTextView.textContainerInset.height * 2)
        composerTextHeightConstraint?.constant = min(maxVisibleHeight, max(minimumHeight, desiredHeight))
        composerContainer.layoutSubtreeIfNeeded()
        updateComposerHorizontalOffset(contentWidth: max(contentWidth, composerTextClipView.bounds.width))
    }

    private func updateComposerHorizontalOffset(contentWidth: CGFloat) {
        guard usesCompactComposerLayout else {
            composerTextClipView.bounds.origin.x = 0
            return
        }

        let viewportWidth = composerTextClipView.bounds.width
        guard contentWidth > viewportWidth + 0.5 else {
            composerTextClipView.bounds.origin.x = 0
            return
        }

        let maximumOffset = max(0, contentWidth - viewportWidth)
        let desiredOffset = min(maximumOffset, max(0, composerCaretMaxX() - viewportWidth + Layout.composerCompactTrailingClipPadding))
        if abs(composerTextClipView.bounds.origin.x - desiredOffset) > 0.5 {
            composerTextClipView.bounds.origin.x = desiredOffset
        }
    }

    private func composerCaretMaxX() -> CGFloat {
        guard let layoutManager = composerTextView.layoutManager,
              let textContainer = composerTextView.textContainer else {
            return composerTextView.frame.width
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return 0 }

        let characterCount = (composerTextView.string as NSString).length
        let selectionLocation = min(max(0, composerTextView.selectedRange().location), characterCount)
        let clampedCharacterIndex = min(max(0, selectionLocation), max(0, characterCount - 1))
        let glyphIndex = min(max(0, layoutManager.glyphIndexForCharacter(at: clampedCharacterIndex)), max(0, glyphCount - 1))
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        return glyphRect.maxX + composerTextView.textContainerInset.width
    }

    private func updateComposerContainerAppearance(animated: Bool) {
        let backgroundColor: NSColor
        let borderColor: NSColor

        if composerHasFocus {
            backgroundColor = DesignTokens.ConversationPanel.Surface.composerFocusFill
            borderColor = DesignTokens.ConversationPanel.Surface.composerFocusBorder
        } else if composerIsHovered {
            backgroundColor = DesignTokens.ConversationPanel.Surface.composerHoverFill
            borderColor = DesignTokens.ConversationPanel.Surface.composerHoverBorder
        } else {
            backgroundColor = DesignTokens.ConversationPanel.Surface.composerFill
            borderColor = DesignTokens.ConversationPanel.Surface.composerBorder
        }

        applyLayerAppearance(animated: animated, on: composerContainer.layer) {
            composerContainer.layer?.backgroundColor = backgroundColor.cgColor
            composerContainer.layer?.borderColor = borderColor.cgColor
            composerContainer.layer?.shadowOpacity = 0
        }
    }

    private func updateCloseButtonAppearance(animated: Bool) {
        let shouldHighlight = closeButton.isEnabled && closeButton.currentHoverState
        applyLayerAppearance(animated: animated, on: closeButton.layer) {
            closeButton.layer?.backgroundColor = (shouldHighlight
                ? DesignTokens.ConversationPanel.Button.secondaryFillHover
                : NSColor.clear
            ).cgColor
            closeButton.layer?.borderWidth = shouldHighlight ? 1 : 0
            closeButton.layer?.borderColor = (shouldHighlight
                ? DesignTokens.ConversationPanel.Button.secondaryBorderHover
                : NSColor.clear
            ).cgColor
            closeButton.layer?.cornerRadius = Layout.closeButtonSize / 2
            closeButton.layer?.masksToBounds = true
        }
        closeButton.contentTintColor = shouldHighlight
            ? DesignTokens.ConversationPanel.Button.secondaryTextHover
            : DesignTokens.ConversationPanel.Button.secondaryText
    }

    private func updateSendButtonAppearance(animated: Bool) {
        let isHovered = sendButton.currentHoverState && sendButton.isEnabled
        let isEnabled = sendButton.isEnabled
        let backgroundColor: NSColor
        let borderColor: NSColor
        let borderWidth: CGFloat
        let tintColor: NSColor
        let alphaValue: CGFloat

        if isEnabled {
            backgroundColor = isHovered ? DesignTokens.ConversationPanel.Button.sendFillHover : DesignTokens.ConversationPanel.Button.sendFill
            borderColor = isHovered ? DesignTokens.ConversationPanel.Button.sendBorderHover : DesignTokens.ConversationPanel.Button.sendBorder
            borderWidth = 1
            tintColor = DesignTokens.ConversationPanel.Button.sendText
            alphaValue = 1
        } else {
            backgroundColor = DesignTokens.ConversationPanel.Button.disabledFill
            borderColor = DesignTokens.ConversationPanel.Button.disabledBorder
            borderWidth = 1
            tintColor = DesignTokens.ConversationPanel.Button.disabledText
            alphaValue = 0.88
        }

        applyLayerAppearance(animated: animated, on: sendButton.layer) {
            sendButton.layer?.backgroundColor = backgroundColor.cgColor
            sendButton.layer?.borderWidth = borderWidth
            sendButton.layer?.borderColor = borderColor.cgColor
            sendButton.alphaValue = alphaValue
        }
        sendButton.contentTintColor = tintColor
    }

    private func updateSaveAutomationButtonAppearance(animated: Bool) {
        let isHovered = saveAutomationButton.currentHoverState && saveAutomationButton.isEnabled
        let isEnabled = saveAutomationButton.isEnabled
        let backgroundColor: NSColor
        let borderColor: NSColor
        let tintColor: NSColor
        let alphaValue: CGFloat

        if isEnabled {
            backgroundColor = isHovered
                ? DesignTokens.ConversationPanel.Button.secondaryFillHover
                : DesignTokens.ConversationPanel.Button.secondaryFill
            borderColor = isHovered ? DesignTokens.ConversationPanel.Button.secondaryBorderHover : DesignTokens.ConversationPanel.Button.secondaryBorder
            tintColor = isHovered ? DesignTokens.ConversationPanel.Button.secondaryTextHover : DesignTokens.ConversationPanel.Button.secondaryText
            alphaValue = 1
        } else {
            backgroundColor = DesignTokens.ConversationPanel.Button.disabledFill
            borderColor = DesignTokens.ConversationPanel.Button.disabledBorder
            tintColor = DesignTokens.ConversationPanel.Button.disabledText
            alphaValue = 0.88
        }

        applyLayerAppearance(animated: animated, on: saveAutomationButton.layer) {
            saveAutomationButton.layer?.backgroundColor = backgroundColor.cgColor
            saveAutomationButton.layer?.borderWidth = 1
            saveAutomationButton.layer?.borderColor = borderColor.cgColor
            saveAutomationButton.alphaValue = alphaValue
        }
        saveAutomationButton.contentTintColor = tintColor
    }

    private func applyDraftActionButtonStyles(animated: Bool) {
        let buttons: [(HoverButton, Bool)] = [
            (cronContinueButton, false),
            (cronSaveButton, true),
            (cronDismissButton, false)
        ]
        for (button, isPrimary) in buttons {
            applyLayerAppearance(animated: animated, on: button.layer) {
                button.layer?.backgroundColor = (isPrimary
                    ? DesignTokens.ConversationPanel.Button.sendFill
                    : DesignTokens.ConversationPanel.Button.secondaryFill
                ).cgColor
                button.layer?.borderWidth = 1
                button.layer?.borderColor = (isPrimary
                    ? DesignTokens.ConversationPanel.Button.sendBorder
                    : DesignTokens.ConversationPanel.Button.secondaryBorder
                ).cgColor
            }
            button.contentTintColor = isPrimary ? DesignTokens.ConversationPanel.Button.sendText : DesignTokens.ConversationPanel.Button.secondaryText
        }
    }

    private func updateComposerActionButtonsState(animated: Bool) {
        sendButton.isEnabled = !trimmedComposerText().isEmpty && !state.isStreaming
        updateSendButtonAppearance(animated: animated)
        updatePendingApprovalCard()
    }

    private func applyLayerAppearance(animated: Bool, on layer: CALayer?, updates: () -> Void) {
        guard layer != nil else {
            updates()
            return
        }
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updates()
            CATransaction.commit()
            return
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0))
        updates()
        CATransaction.commit()
    }

    private func resolvedResponseLanguage() -> String {
        AppSettings.shared.appLanguage.languageCode
    }

    private func ensureInteractiveActivationAfterComposerInput() {
        guard panel.isVisible else { return }
        guard !NSApp.isActive || !panel.isKeyWindow || NSApp.activationPolicy() != .regular else {
            return
        }
        diagnosticsLogger.log("ask.click", diagnosticSessionState(prefix: "ensure_interactive_activation"))
        prepareApplicationForInteractiveAskSession()
        panel.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    private func commitComposerMarkedTextIfNeeded() -> Bool {
        guard composerTextView.hasMarkedText() else { return false }
        composerTextView.unmarkText()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateComposerPlaceholder()
            self.updateEmptyStateVisibility()
            self.updateComposerMetrics()
            self.updateComposerActionButtonsState(animated: true)
        }
        return true
    }

    private func focusComposer() {
        guard panel.isVisible else { return }
        prepareApplicationForInteractiveAskSession()
        panel.orderFrontRegardless()
        panel.makeMain()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(composerTextView)
        panel.contentView?.window?.makeFirstResponder(composerTextView)
        composerHasFocus = true
        updateComposerPlaceholder()
        updateComposerContainerAppearance(animated: true)
    }

    private func focusComposerForNewSession() {
        pendingComposerFocusRetryWorkItem?.cancel()
        focusComposer()
        DispatchQueue.main.async { [weak self] in
            self?.focusComposer()
        }
        scheduleComposerFocusRetryIfNeeded(presentationID: entrancePresentationID, attempt: 0)
    }

    private func scheduleComposerFocusRetryIfNeeded(presentationID: UUID, attempt: Int) {
        guard panel.isVisible,
              entrancePresentationID == presentationID,
              attempt < 8 else {
            pendingComposerFocusRetryWorkItem = nil
            return
        }

        let isComposerFirstResponder = (panel.firstResponder as? NSTextView) === composerTextView
        if panel.isKeyWindow && isComposerFirstResponder {
            pendingComposerFocusRetryWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.panel.isVisible, self.entrancePresentationID == presentationID else { return }
            self.focusComposer()
            self.scheduleComposerFocusRetryIfNeeded(
                presentationID: presentationID,
                attempt: attempt + 1
            )
        }
        pendingComposerFocusRetryWorkItem?.cancel()
        pendingComposerFocusRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func shouldRefocusComposer(after response: AskSessionResponse) -> Bool {
        let nonRefocusingOperatorActions: Set<String> = ["open_path", "open_url", "reveal_path"]
        let nonRefocusingToolNames: Set<String> = ["open_path", "open_url", "reveal_path"]
        let nonRefocusingCapabilityIDs: Set<String> = [
            "browser.open_url",
            "desktop.reveal_in_finder"
        ]

        switch response.metadata["operator_action"] {
        case let action? where nonRefocusingOperatorActions.contains(action):
            return false
        case _ where nonRefocusingToolNames.contains(response.metadata["latest_tool_name"] ?? ""):
            return false
        case _ where nonRefocusingCapabilityIDs.contains(response.metadata["latest_kernel_capability_id"] ?? ""):
            return false
        default:
            return true
        }
    }

    private func prepareApplicationForInteractiveAskSession() {
        diagnosticsLogger.log("ask.click", diagnosticSessionState(prefix: "prepare_interactive_session_before"))
        if NSApp.activationPolicy() != .regular {
            didPromoteActivationPolicyForVisibility = NSApp.setActivationPolicy(.regular)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApplication.shared.activate(ignoringOtherApps: true)
        if panel.isVisible {
            panel.orderFrontRegardless()
            panel.makeMain()
        }
        diagnosticsLogger.log("ask.click", diagnosticSessionState(prefix: "prepare_interactive_session_after"))
    }

    private func restoreActivationPolicyIfNeeded() {
        guard didPromoteActivationPolicyForVisibility else { return }
        didPromoteActivationPolicyForVisibility = false
        _ = NSApp.setActivationPolicy(.accessory)
    }

    private func ensureSendButtonGlobalFallbackMonitor() {
        guard sendButtonGlobalFallbackMonitor == nil else { return }
        sendButtonGlobalFallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleGlobalSendButtonFallbackMouseDown(event)
        }
    }

    private func removeSendButtonGlobalFallbackMonitor() {
        guard let sendButtonGlobalFallbackMonitor else { return }
        NSEvent.removeMonitor(sendButtonGlobalFallbackMonitor)
        self.sendButtonGlobalFallbackMonitor = nil
    }

    private func handleGlobalSendButtonFallbackMouseDown(_ event: NSEvent) {
        guard panel.isVisible,
              hasPendingComposerSubmission,
              !state.isStreaming,
              (!NSApp.isActive || !panel.isKeyWindow) else {
            return
        }

        let buttonRectInWindow = sendButton.convert(sendButton.bounds, to: nil)
        let buttonRectOnScreen = panel.convertToScreen(buttonRectInWindow)
        guard buttonRectOnScreen.contains(event.locationInWindow) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.diagnosticsLogger.log("ask.click", self?.diagnosticSessionState(prefix: "global_send_fallback_submit") ?? "global_send_fallback_submit")
            self?.submitCurrentPrompt()
        }
    }

    private func diagnosticSessionState(prefix: String) -> String {
        "\(prefix) session=\(state.sessionID) active=\(NSApp.isActive) key=\(panel.isKeyWindow) main=\(panel.isMainWindow) visible=\(panel.isVisible) policy=\(diagnosticActivationPolicy()) first_responder=\(diagnosticFirstResponderDescription()) send_enabled=\(sendButton.isEnabled) streaming=\(state.isStreaming) auto_dismiss=\(shouldAutoDismissOnOutsideInteraction) composer_chars=\(composerTextView.string.count)"
    }

    private func logPanelMouseDiagnostics(stage: String, event: NSEvent) {
        let pointInWindow = event.locationInWindow
        let pointInHostView = hostView.convert(pointInWindow, from: nil)
        let hitView = hostView.hitTest(pointInHostView)
        let pointInButton = sendButton.convert(pointInWindow, from: nil)
        diagnosticsLogger.log(
            "ask.click",
            "\(diagnosticSessionState(prefix: stage)) point_window=(\(Int(pointInWindow.x)),\(Int(pointInWindow.y))) hit_send=\(sendButton.bounds.contains(pointInButton)) hit_view=\(diagnosticViewDescription(hitView))"
        )
    }

    private func diagnosticActivationPolicy() -> String {
        switch NSApp.activationPolicy() {
        case .regular:
            return "regular"
        case .accessory:
            return "accessory"
        case .prohibited:
            return "prohibited"
        @unknown default:
            return "unknown"
        }
    }

    private func diagnosticFirstResponderDescription() -> String {
        guard let responder = panel.firstResponder else { return "nil" }
        if responder === composerTextView {
            return "ComposerTextView"
        }
        if let view = responder as? NSView {
            return diagnosticViewDescription(view)
        }
        return String(describing: type(of: responder))
    }

    private func diagnosticViewDescription(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        let typeName = String(describing: type(of: view))
        let identifier = view.accessibilityIdentifier()
        return identifier.isEmpty ? typeName : "\(typeName)#\(identifier)"
    }

    private func presentPanelForNewSession(
        selectionFrame: CGRect,
        transitionStartPoint: CGPoint?,
        transitionEndPoint: CGPoint?,
        targetFrame: NSRect,
        completion: @escaping () -> Void
    ) {
        entrancePresentationID = UUID()
        let presentationID = entrancePresentationID
        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && selectionFrame.width > 0
            && selectionFrame.height > 0

        prepareApplicationForInteractiveAskSession()
        restorePanelResizeBounds()
        panel.setFrame(targetFrame, display: false)

        guard shouldAnimate else {
            isRunningEntranceAnimation = false
            panel.alphaValue = 1
            contentStack.alphaValue = 1
            contentStack.isHidden = false
            transcriptEmptyStateLabel.alphaValue = 1
            stopEntranceFlowAnimation()
            panel.makeKeyAndOrderFront(nil)
            prepareApplicationForInteractiveAskSession()
            updateEmptyStateVisibility()
            completion()
            focusComposerForNewSession()
            return
        }

        let animationFrames = AskWindowGeometry.entranceAnimationFrames(
            selectionFrame: selectionFrame,
            resolvedFrame: targetFrame,
            startPoint: transitionStartPoint,
            endPoint: transitionEndPoint
        )
        let anchorPoint = entranceAnchorPoint(
            startPoint: transitionStartPoint,
            endPoint: transitionEndPoint
        )
        diagnosticsLogger.log(
            "ask.animation",
            "start frames=\(animationFrames.count) selection=(\(Int(selectionFrame.minX)),\(Int(selectionFrame.minY)),\(Int(selectionFrame.width)),\(Int(selectionFrame.height))) target=(\(Int(targetFrame.minX)),\(Int(targetFrame.minY)),\(Int(targetFrame.width)),\(Int(targetFrame.height)))"
        )

        guard let surfaceLayer = panelSurfaceView.layer else {
            isRunningEntranceAnimation = false
            panel.alphaValue = 1
            contentStack.alphaValue = 1
            contentStack.isHidden = false
            transcriptEmptyStateLabel.alphaValue = 1
            updateEmptyStateVisibility()
            panel.makeKeyAndOrderFront(nil)
            prepareApplicationForInteractiveAskSession()
            completion()
            focusComposerForNewSession()
            return
        }

        isRunningEntranceAnimation = true
        panel.hasShadow = false
        panel.alphaValue = 1
        prepareContentForEntrance()
        panel.displayIfNeeded()
        hostView.layoutSubtreeIfNeeded()
        panelSurfaceView.layoutSubtreeIfNeeded()

        let presentationTransforms = animationFrames.map {
            entranceTransform(for: $0, targetFrame: targetFrame)
        }
        let animationDuration = totalEntranceDuration(for: animationFrames.count)
        stopEntranceFlowAnimation()
        startEntranceFlowAnimation(
            selectionFrame: selectionFrame,
            transitionStartPoint: transitionStartPoint,
            transitionEndPoint: transitionEndPoint,
            targetFrame: targetFrame,
            duration: animationDuration
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.removeAnimation(forKey: "ask.entrance.transform")
        surfaceLayer.removeAnimation(forKey: "ask.entrance.opacity")
        applyAnchorPoint(anchorPoint, to: surfaceLayer)
        surfaceLayer.transform = presentationTransforms.first ?? CATransform3DIdentity
        surfaceLayer.opacity = Layout.entranceInitialAlpha
        CATransaction.commit()

        panel.makeKeyAndOrderFront(nil)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            guard self.entrancePresentationID == presentationID else { return }
            self.isRunningEntranceAnimation = false
            self.panel.hasShadow = true
            self.panel.alphaValue = 1
            self.stopEntranceFlowAnimation()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.applyAnchorPoint(CGPoint(x: 0.5, y: 0.5), to: surfaceLayer)
            surfaceLayer.transform = CATransform3DIdentity
            surfaceLayer.opacity = 1
            CATransaction.commit()
            self.prepareApplicationForInteractiveAskSession()
            self.revealContentAfterEntrance(
                presentationID: presentationID,
                targetFrame: targetFrame,
                completion: completion
            )
        }

        let transformAnimation = CAKeyframeAnimation(keyPath: "transform")
        transformAnimation.values = presentationTransforms.map { NSValue(caTransform3D: $0) }
        transformAnimation.keyTimes = entranceKeyTimes(for: animationFrames.count)
        transformAnimation.timingFunctions = entranceTimingFunctions(for: animationFrames.count)
        transformAnimation.duration = animationDuration
        transformAnimation.fillMode = .forwards
        transformAnimation.isRemovedOnCompletion = false

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = Layout.entranceInitialAlpha
        opacityAnimation.toValue = 1
        opacityAnimation.duration = animationDuration
        opacityAnimation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
        opacityAnimation.fillMode = .forwards
        opacityAnimation.isRemovedOnCompletion = false

        surfaceLayer.add(transformAnimation, forKey: "ask.entrance.transform")
        surfaceLayer.add(opacityAnimation, forKey: "ask.entrance.opacity")
        CATransaction.commit()
    }

    private func restorePanelResizeBounds() {
        let bounds = panelResizeBounds()
        panel.minSize = bounds.min
        panel.maxSize = bounds.max
    }

    private func panelResizeBounds() -> (min: NSSize, max: NSSize) {
        AskWindowGeometry.resizeBounds(for: currentVisibleFrame())
    }

    private func currentVisibleFrame() -> CGRect {
        panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func clampedPanelSize(for requestedSize: NSSize) -> NSSize {
        let bounds = panelResizeBounds()
        return NSSize(
            width: min(max(requestedSize.width, bounds.min.width), bounds.max.width),
            height: min(max(requestedSize.height, bounds.min.height), bounds.max.height)
        )
    }

    private func enforcePanelComfortBoundsIfNeeded() {
        guard !isAdjustingPanelComfortBounds else { return }
        let clampedSize = clampedPanelSize(for: panel.frame.size)
        guard abs(clampedSize.width - panel.frame.width) > 0.5
                || abs(clampedSize.height - panel.frame.height) > 0.5 else {
            return
        }

        isAdjustingPanelComfortBounds = true
        defer { isAdjustingPanelComfortBounds = false }

        var frame = panel.frame
        frame.size = clampedSize
        panel.setFrame(frame, display: true, animate: false)
    }

    private func totalEntranceDuration(for animationFrameCount: Int) -> TimeInterval {
        switch animationFrameCount {
        case 0, 1:
            return 0
        case 2:
            return Layout.entranceDirectDuration
        default:
            return Layout.entranceSelectionDuration + Layout.entranceExpansionDuration
        }
    }

    private func entranceTransform(for absoluteFrame: CGRect, targetFrame: CGRect) -> CATransform3D {
        let scaleX = max(absoluteFrame.width, 1) / max(targetFrame.width, 1)
        let scaleY = max(absoluteFrame.height, 1) / max(targetFrame.height, 1)
        return CATransform3DMakeScale(scaleX, scaleY, 1)
    }

    private func entranceKeyTimes(for animationFrameCount: Int) -> [NSNumber] {
        if animationFrameCount <= 2 {
            return [0, 1]
        }
        let totalDuration = totalEntranceDuration(for: animationFrameCount)
        let firstStageRatio = Layout.entranceSelectionDuration / totalDuration
        return [0, NSNumber(value: firstStageRatio), 1]
    }

    private func entranceTimingFunctions(for animationFrameCount: Int) -> [CAMediaTimingFunction] {
        let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
        if animationFrameCount <= 2 {
            return [easeOut]
        }
        return [easeOut, easeOut]
    }

    private func entranceAnchorPoint(startPoint: CGPoint?, endPoint: CGPoint?) -> CGPoint {
        let horizontal: CGFloat
        if let startPoint, let endPoint, startPoint.x > endPoint.x {
            horizontal = 1
        } else {
            horizontal = 0
        }

        let vertical: CGFloat
        if let startPoint, let endPoint, startPoint.y > endPoint.y {
            vertical = 1
        } else {
            vertical = 0
        }

        return CGPoint(x: horizontal, y: vertical)
    }

    private func applyAnchorPoint(_ anchorPoint: CGPoint, to layer: CALayer) {
        let bounds = layer.bounds
        let newPosition = CGPoint(
            x: bounds.width * anchorPoint.x,
            y: bounds.height * anchorPoint.y
        )
        layer.anchorPoint = anchorPoint
        layer.position = newPosition
    }
}

#endif
