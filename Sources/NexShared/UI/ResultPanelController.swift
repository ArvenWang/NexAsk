import AppKit
import QuartzCore

final class ResultPanelController: NSObject, NSWindowDelegate {
    private typealias DisplayKind = ResultPanelDisplayKind
    private enum LoadingEffectAnimationKey {
        static let lineMove = "resultLoadingLineMove"
        static let lineFade = "resultLoadingLineFade"
        static let auraMove = "resultLoadingLineAuraMove"
        static let auraFade = "resultLoadingLineAuraFade"
    }

    enum MessageRole {
        case user
        case assistant
        case tool
        case info
    }

    private struct ChatMessage {
        var role: MessageRole
        var text: String
        var toolKey: String? = nil
        var toolDetails: [String] = []
        var toolLabel: String? = nil
        var toolAnimatedDetail: String? = nil
    }

    private struct PendingToolStatus {
        let key: String
        let title: String
        let detail: String?
        let label: String?
    }

    private enum ConversationUpdate {
        case finalizeAssistant(String)
        case finalizeAssistantWithActionCards(String, cards: [SkillResultCard])
        case trace(summary: String?, pendingEntities: [TraceEntity])
        case info(String)
    }

    private struct PanelChromePresentation {
        let kind: DisplayKind
        let title: String
    }

    private struct FooterActionDescriptor {
        let kind: ResultFooterActionKind
        let title: String
        let systemImageName: String
        let accessibilityDescription: String
        let followupSkillID: String?
        let followupInputSource: SkillFollowupInputSource?
        let followupMaxDepth: Int?
        let followupSourceSkillID: String?
    }

    private struct StreamingSessionPresentation {
        let chrome: PanelChromePresentation
        let queuesThinkingStatus: Bool
    }

    private struct StreamingTextPresentation {
        let delta: String
        let fullText: String?
    }

    private struct StreamingUpdatePresentation {
        let toolStatus: PendingToolStatus?
        let pendingTraceEntities: [TraceEntity]?
        let pendingActionCards: [SkillResultCard]?
        let latestTextToCopy: String?
        let latestReplaceText: String?
        let latestSourceURL: URL?
        let flushPendingToolStatusesBeforeAssistant: Bool
        let clearsPendingToolStatusesBeforeAssistant: Bool
        let cancelsToolStatusPumpBeforeAssistant: Bool
        let removesToolMessagesBeforeAssistant: Bool
        let assistantText: StreamingTextPresentation?
    }

    private struct CompletedResultPresentation {
        let chrome: PanelChromePresentation
        let footerActions: [FooterActionDescriptor]
        let conversationUpdate: ConversationUpdate
        let latestTextToCopy: String
        let latestReplaceText: String?
        let latestWritebackText: String?
        let latestSourceURL: URL?
        let latestTraceEntities: [TraceEntity]
        let pendingTraceEntities: [TraceEntity]
        let pendingActionCards: [SkillResultCard]
        let shouldQueueFooterReveal: Bool
        let shouldScheduleTraceCardFallbackReveal: Bool
        let shouldPublishPendingTraceEntitiesImmediately: Bool
        let shouldPublishActionCardsImmediately: Bool
        let clearsStreamingScratchState: Bool
        let clearsTraceRevealState: Bool
    }

    private struct DeferredMorphResultUpdate {
        let skillID: String
        let presentation: CompletedResultPresentation
        let showStartedAt: CFAbsoluteTime
    }

    private let settings: AppSettings
    private let diagnosticsLogger = DiagnosticsLogger.shared
    private let resultSessionStore = ResultSessionStore()

    private let panel: ChatPanel
    private let hostView = NSView(frame: .zero)
    private let panelSurfaceView = PanelSurfaceView(style: .panel)

    private let titleLabel = NSTextField(labelWithString: "")
    private let pinButton = NSButton(title: "", target: nil, action: nil)
    private let divider = NSView()
    private let panelAuraOverlayView = NSView()
    private let dividerFlowContainerLayer = CALayer()
    private let dividerFlowMaskLayer = CAGradientLayer()
    private let panelAuraContainerLayer = CALayer()
    private let dividerFlowAuraLayer = CAGradientLayer()
    private let dividerFlowLayer = CAGradientLayer()

    private let transcriptScrollView = NSScrollView()
    private let transcriptScrollIndicator = OverlayScrollIndicatorView()
    private let transcriptContentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let transcriptStack = NSStackView()
    private let contentStack = NSStackView()

    private let footerContainer = NSStackView()
    private let footerButtonsStack = NSStackView()

    private var transcriptHeightConstraint: NSLayoutConstraint?
    private var footerMinHeightConstraint: NSLayoutConstraint?
    private(set) var isPinned = false

    private var latestTextToCopy = ""
    private var latestReplaceText: String?
    private var latestWritebackText: String?
    private var latestSourceURL: URL?
    private var currentResultSkillID: String?
    private var currentResultMetadata: [String: String] = [:]
    private var currentSourceText: String?
    private var currentSourceBundleID: String?
    private var currentSourceInteractionContext = SourceInteractionContext.empty
    private var currentReplacementTarget: ReplacementTargetSnapshot?
    private var currentDefinition: SkillDefinition?
    private var currentFooterActions: [FooterActionDescriptor] = []
    private var streamingKind: DisplayKind = .info
    private var currentDisplayKind: DisplayKind = .info
    private var isStreamingMode = false
    private var streamingAssistantIndex: Int?

    private var messages: [ChatMessage] = []
    private var activeToolStatusKey: String?
    private var latestTraceEntities: [TraceEntity] = []
    private var pendingTraceEntities: [TraceEntity] = []
    private var latestActionCards: [SkillResultCard] = []
    private var pendingActionCards: [SkillResultCard] = []
    private var renderedActionCardCount = 0
    private var pendingActionCardEntranceIndex: Int?
    private var actionCardRevealSequence = 0
    private var pendingToolStatuses: [PendingToolStatus] = []
    private var toolStatusPumpWorkItem: DispatchWorkItem?
    private var lastToolStatusRenderAt: Date?
    private var streamingRevealTimer: Timer?
    private var streamingChunkFadeTimer: Timer?
    private var streamingTargetText = ""
    private var pendingStreamingChunks: [String] = []
    private var renderedTraceCardCount = 0
    private var pendingTraceCardEntranceIndex: Int?
    private var traceCardRevealSequence = 0
    private var streamingHighlightedSuffixLength = 0
    private var streamingHighlightedAlpha: CGFloat = 1
    private var pendingTranslationFooterReveal = false
    private var pendingEntranceAnimation = false
    private var defersTranscriptRendering = false
    private var pendingDeferredTranscriptRender = false
    private var pendingMorphTargetFrame: NSRect?
    private var panelFrameAnimationTimer: Timer?
    private var deferredMorphResultUpdate: DeferredMorphResultUpdate?
    private weak var latestSelectableMessageRow: ChatMessageRowView?
    private weak var streamingAssistantMessageRow: ChatMessageRowView?
    private let transcriptRenderer = ResultTranscriptRenderer()

    var onStreamingDismissed: (() -> Void)?
    var onRegenerateRequested: ((String, String) -> Void)?
    var onSkillShortcutRequested: ((String, String, Int, String?) -> Void)?
    var isTransitioning: Bool { pendingEntranceAnimation }
    private lazy var cardActionCoordinator = ResultCardActionCoordinator(
        diagnosticsLogger: diagnosticsLogger,
        contextProvider: { [weak self] in
            ResultCardActionContext(
                currentSkillID: self?.currentDefinition?.skillID,
                currentSourceBundleID: self?.currentSourceBundleID
            )
        },
        hideHandler: { [weak self] force in
            self?.hide(force: force)
        }
    )
    private lazy var failureAlertPresenter = ResultFailureAlertPresenter(diagnosticsLogger: diagnosticsLogger)
    private lazy var footerActionCoordinator = ResultFooterActionCoordinator(
        diagnosticsLogger: diagnosticsLogger,
        alertPresenter: failureAlertPresenter,
        contextProvider: { [weak self] in
            guard let self else {
                return ResultFooterActionContext(
                    definition: nil,
                    currentSourceText: nil,
                    currentSourceBundleID: nil,
                    currentReplacementTarget: nil,
                    currentSourceInteractionContext: .empty,
                    latestReplaceText: nil,
                    latestWritebackText: nil,
                    latestSourceURL: nil,
                    currentResultMetadata: [:],
                    resolvedFooterSourceText: nil
                )
            }
            return self.resultSessionStore.footerActionContext(
                resolvedFooterSourceText: self.resolvedFooterSourceText()
            )
        },
        actionPolicyDecisionProvider: { [weak self] kind in
            self?.footerActionPolicyDecision(for: kind) ?? ResultActionPolicyDecision(
                semantic: .copy,
                impactLevel: .passive,
                disposition: .executeImmediately,
                reason: "controller_unavailable"
            )
        },
        copyHandler: { [weak self] in
            self?.handleCopyAction()
        },
        hideHandler: { [weak self] force in
            self?.hide(force: force)
        },
        refocusSourceApplication: { [weak self] bundleID in
            self?.refocusSourceApplication(bundleID: bundleID)
        },
        onRegenerateRequested: { [weak self] skillID, sourceText in
            self?.onRegenerateRequested?(skillID, sourceText)
        },
        onSkillShortcutRequested: { [weak self] skillID, sourceText, followupDepth, followupSourceSkillID in
            self?.onSkillShortcutRequested?(skillID, sourceText, followupDepth, followupSourceSkillID)
        }
    )

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func resultTitle(for definition: SkillDefinition?) -> String {
        definition?.title ?? L10n.text(zhHans: "结果", en: "Result")
    }

    init(settings: AppSettings = .shared) {
        self.settings = settings

        panel = ChatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 300),
            styleMask: [.borderless, .resizable],
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

        super.init()
        panel.delegate = self
        panel.keyEquivalentHandler = { [weak self] event in
            self?.handlePanelKeyEquivalent(event) ?? false
        }
        configureContentView()
    }

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    var isPersistentStreamingPresentation: Bool {
        isStreamingMode && currentDefinition?.skillID == "collect"
    }

    func contains(screenPoint: CGPoint) -> Bool {
        panel.isVisible && panel.frame.contains(screenPoint)
    }

    func hide(force: Bool = false) {
        if isPersistentStreamingPresentation && !force { return }
        if isPinned && !force { return }
        let shouldCancelStreaming = panel.isVisible && isStreamingMode
        panelFrameAnimationTimer?.invalidate()
        panelFrameAnimationTimer = nil
        defersTranscriptRendering = false
        pendingDeferredTranscriptRender = false
        pendingMorphTargetFrame = nil
        deferredMorphResultUpdate = nil
        isStreamingMode = false
        activeToolStatusKey = nil
        pendingTraceEntities.removeAll()
        pendingActionCards.removeAll()
        pendingToolStatuses.removeAll()
        toolStatusPumpWorkItem?.cancel()
        toolStatusPumpWorkItem = nil
        lastToolStatusRenderAt = nil
        streamingRevealTimer?.invalidate()
        streamingRevealTimer = nil
        streamingChunkFadeTimer?.invalidate()
        streamingChunkFadeTimer = nil
        streamingTargetText = ""
        pendingStreamingChunks.removeAll()
        renderedTraceCardCount = 0
        pendingTraceCardEntranceIndex = nil
        traceCardRevealSequence += 1
        renderedActionCardCount = 0
        pendingActionCardEntranceIndex = nil
        actionCardRevealSequence += 1
        deferredMorphResultUpdate = nil
        streamingHighlightedSuffixLength = 0
        streamingHighlightedAlpha = 1
        pendingTranslationFooterReveal = false
        resultSessionStore.clear()
        stopLoadingLineFlow(immediately: true)
        panel.orderOut(nil)
        panelSurfaceView.alphaValue = 1
        panelSurfaceView.showsBlur = true
        panel.hasShadow = true
        if shouldCancelStreaming {
            onStreamingDismissed?()
        }
    }

    func restorePersistentStreamingPresentationIfNeeded() {
        guard isPersistentStreamingPresentation, !panel.isVisible else { return }
        presentPanel(
            kind: streamingKind,
            near: panel.frame,
            preservePosition: true,
            transitionSourceFrame: nil
        )
        startLoadingLineFlow()
    }

    func showStreaming(
        definition: SkillDefinition,
        sourceText: String,
        targetLanguage: String,
        sourceBundleID: String?,
        sourceInteractionContext: SourceInteractionContext?,
        replacementTarget: ReplacementTargetSnapshot?,
        near rect: NSRect,
        keepConversation: Bool = false,
        preservePosition: Bool = false,
        transitionSourceFrame: NSRect? = nil
    ) {
        diagnosticsLogger.log("result.lifecycle", "showStreaming skill=\(definition.skillID) keepConversation=\(keepConversation)")
        if definition.skillID == "collect" {
            diagnosticsLogger.log(
                "result.render",
                "skill=collect stage=showStreaming sourceTextLength=\(sourceText.count) keepConversation=\(keepConversation)"
            )
        }
        diagnosticsLogger.log(
            "result.transition",
            "showStreaming skill=\(definition.skillID) near=\(formatted(rect)) preserve=\(preservePosition) transitionSource=\(formatted(transitionSourceFrame)) panelVisible=\(panel.isVisible) panelFrame=\(formatted(panel.frame))"
        )
        currentDefinition = definition
        currentSourceText = sourceText
        isStreamingMode = true
        streamingAssistantIndex = nil
        latestTextToCopy = ""
        latestReplaceText = nil
        latestWritebackText = nil
        latestSourceURL = nil
        activeToolStatusKey = nil
        latestTraceEntities = []
        pendingTraceEntities = []
        latestActionCards = []
        pendingActionCards = []
        pendingToolStatuses.removeAll()
        toolStatusPumpWorkItem?.cancel()
        toolStatusPumpWorkItem = nil
        lastToolStatusRenderAt = nil
        streamingRevealTimer?.invalidate()
        streamingRevealTimer = nil
        streamingChunkFadeTimer?.invalidate()
        streamingChunkFadeTimer = nil
        streamingTargetText = ""
        pendingStreamingChunks.removeAll()
        renderedTraceCardCount = 0
        pendingTraceCardEntranceIndex = nil
        traceCardRevealSequence += 1
        renderedActionCardCount = 0
        pendingActionCardEntranceIndex = nil
        actionCardRevealSequence += 1
        streamingHighlightedSuffixLength = 0
        streamingHighlightedAlpha = 1
        pendingTranslationFooterReveal = false
        if let sourceBundleID {
            currentSourceBundleID = sourceBundleID
        } else if let interactionContext = sourceInteractionContext,
                  let interactionBundleID = interactionContext.bundleID {
            currentSourceBundleID = interactionBundleID
        } else if !keepConversation {
            currentSourceBundleID = nil
        }
        if let sourceInteractionContext {
            currentSourceInteractionContext = sourceInteractionContext
        } else if !keepConversation {
            currentSourceInteractionContext = SourceInteractionContext.empty
        }
        if let replacementTarget {
            currentReplacementTarget = replacementTarget
        } else if !keepConversation {
            currentReplacementTarget = nil
        }
        resultSessionStore.beginStreaming(
            definition: definition,
            sourceText: sourceText,
            sourceBundleID: currentSourceBundleID,
            sourceInteractionContext: currentSourceInteractionContext,
            replacementTarget: currentReplacementTarget,
            keepConversation: keepConversation
        )

        let presentation = streamingSessionPresentation(for: definition)
        streamingKind = presentation.chrome.kind
        applyChromePresentation(presentation.chrome)
        applyFooterActions([], reserveSpace: definition.supportsFooter && definition.skillID == "schedule")

        if !keepConversation {
            defersTranscriptRendering = false
            pendingDeferredTranscriptRender = false
            resetConversation()
        }

        if presentation.queuesThinkingStatus {
            enqueueToolStatus(
                statusKey: "thinking",
                title: localizedStatusText("thinking"),
                detail: nil,
                label: nil
            )
        } else if shouldShowLoadingInResultWindow(for: definition) {
            enqueueToolStatus(
                statusKey: "loading",
                title: localizedStatusText("loading"),
                detail: localizedStatusDetail("loading"),
                label: nil
            )
        }
        presentPanel(
            kind: streamingKind,
            near: rect,
            preservePosition: preservePosition || (keepConversation && panel.isVisible),
            transitionSourceFrame: transitionSourceFrame
        )
        if shouldShowLoadingInResultWindow(for: definition) {
            startLoadingLineFlow()
        } else {
            stopLoadingLineFlow(immediately: true)
        }
        _ = targetLanguage
    }

    func updateStreaming(event: SkillRuntimeEvent) {
        guard isStreamingMode else { return }

        switch event.type {
        case .done:
            guard let result = event.result else { return }
            show(resultEnvelope: result, definition: currentDefinition, near: panel.frame, preservePosition: true)
            return

        case .error:
            guard let message = event.message else { return }
            show(
                resultEnvelope: ResultSchemaAdapter.resultEnvelope(for: .info(message), definition: currentDefinition),
                definition: currentDefinition,
                near: panel.frame,
                preservePosition: true
            )
            return

        case .status, .delta, .supplement:
            let presentation = streamingUpdatePresentation(for: event)
            applyStreamingUpdate(presentation)
        }
    }

    func show(
        resultEnvelope: SkillResultEnvelope,
        definition: SkillDefinition? = nil,
        near rect: NSRect,
        preservePosition: Bool = false
    ) {
        let showStartedAt = CFAbsoluteTimeGetCurrent()
        diagnosticsLogger.log("result.lifecycle", "show envelope skill=\(resultEnvelope.skillID) preservePosition=\(preservePosition)")
        diagnosticsLogger.log(
            "result.transition",
            "showResult skill=\(resultEnvelope.skillID) near=\(formatted(rect)) preserve=\(preservePosition) panelVisible=\(panel.isVisible) panelFrameBefore=\(formatted(panel.frame)) pendingEntrance=\(pendingEntranceAnimation)"
        )
        if let definition {
            currentDefinition = definition
        }
        currentResultSkillID = resultEnvelope.skillID
        currentResultMetadata = resultEnvelope.metadata ?? [:]
        isStreamingMode = false
        stopLoadingLineFlow()
        activeToolStatusKey = nil
        pendingTranslationFooterReveal = false
        let presentation = completedPresentation(for: resultEnvelope)
        let kind = presentation.chrome.kind

        currentDisplayKind = presentation.chrome.kind
        if resultEnvelope.skillID == "info" {
            currentDefinition = nil
        }

        removeToolMessages()
        applyChromePresentation(presentation.chrome)
        if shouldDeferCompletedResultUpdate(skillID: resultEnvelope.skillID) {
            deferredMorphResultUpdate = DeferredMorphResultUpdate(
                skillID: resultEnvelope.skillID,
                presentation: presentation,
                showStartedAt: showStartedAt
            )
            diagnosticsLogger.log(
                "result.transition",
                "deferCompletedResultUpdate skill=\(resultEnvelope.skillID) reason=text_collect_during_morph"
            )
        } else {
            applyCompletedResultPresentation(
                presentation,
                skillID: resultEnvelope.skillID,
                showStartedAt: showStartedAt
            )
        }
        if pendingEntranceAnimation {
            diagnosticsLogger.log(
                "result.transition",
                "deferResultFrame skill=\(resultEnvelope.skillID) keepPendingMorphTarget=\(formatted(pendingMorphTargetFrame)) near=\(formatted(rect))"
            )
        } else {
            resizePanel(kind: kind, near: rect, preservePosition: preservePosition)
            presentInteractivePanel()
        }
    }

    private func shouldDeferCompletedResultUpdate(skillID: String) -> Bool {
        false
    }

    private func applyCompletedResultPresentation(
        _ presentation: CompletedResultPresentation,
        skillID: String,
        showStartedAt: CFAbsoluteTime
    ) {
        if skillID == "collect" {
            logCollectStageDuration(skillID: skillID, stage: "completedPresentation.chrome", startedAt: showStartedAt)
        }
        applyConversationUpdate(presentation.conversationUpdate)
        if skillID == "collect" {
            diagnosticsLogger.log(
                "result.render",
                "skill=collect stage=conversationPrepared messages=\(messages.count) textLength=\(totalTranscriptTextLength()) actionCards=\(presentation.pendingActionCards.count) sourceTextLength=\(currentSourceText?.count ?? 0)"
            )
            logCollectStageDuration(skillID: skillID, stage: "applyConversationUpdate", startedAt: showStartedAt)
        }

        latestTextToCopy = presentation.latestTextToCopy
        latestReplaceText = presentation.latestReplaceText
        latestWritebackText = presentation.latestWritebackText
        latestSourceURL = presentation.latestSourceURL
        latestTraceEntities = presentation.latestTraceEntities
        pendingTraceEntities = presentation.pendingTraceEntities
        pendingActionCards = presentation.pendingActionCards
        resultSessionStore.complete(
            definition: currentDefinition,
            metadata: currentResultMetadata,
            footerModel: ResultFooterModel(
                resultActions: footerActions(from: presentation.footerActions.filter { [.regenerate, .copy, .replace, .writeInput, .openPrimary].contains($0.kind) }),
                skillFollowups: footerActions(from: presentation.footerActions.filter { [.translate, .explain, .followup].contains($0.kind) }),
                capabilityActions: footerActions(from: presentation.footerActions.filter { $0.kind == .capabilityAction })
            ),
            latestTextToCopy: presentation.latestTextToCopy,
            latestReplaceText: presentation.latestReplaceText,
            latestWritebackText: presentation.latestWritebackText,
            latestSourceURL: presentation.latestSourceURL
        )

        if presentation.clearsTraceRevealState {
            clearTraceRevealState()
            pendingTraceEntities = presentation.pendingTraceEntities
        }

        if presentation.clearsStreamingScratchState {
            clearStreamingScratchState()
        }

        applyFooterActions(
            presentation.footerActions,
            reserveSpace: skillID == "schedule"
                && resolvedDefinition(for: skillID)?.supportsFooter == true
        )

        if presentation.shouldQueueFooterReveal {
            pendingTranslationFooterReveal = true
            setFooterVisible(false)
            revealFooterIfReady()
        }

        if presentation.shouldScheduleTraceCardFallbackReveal {
            scheduleTraceCardFallbackReveal()
        } else if presentation.shouldPublishPendingTraceEntitiesImmediately {
            publishPendingTraceEntitiesIfNeeded()
        }

        if presentation.shouldPublishActionCardsImmediately {
            publishPendingActionCardsIfNeeded()
        }

        let renderStartedAt = CFAbsoluteTimeGetCurrent()
        renderTranscript()
        if skillID == "collect" {
            diagnosticsLogger.log(
                "result.render",
                "skill=collect stage=showResult.renderTranscript duration_ms=\(Self.millisecondsSince(renderStartedAt)) rows=\(transcriptStack.arrangedSubviews.count) textLength=\(totalTranscriptTextLength()) actionCards=\(latestActionCards.count)"
            )
            diagnosticsLogger.log(
                "result.render",
                "skill=collect stage=showResult.total duration_ms=\(Self.millisecondsSince(showStartedAt))"
            )
        }
    }

    private func configureContentView() {
        guard let contentView = panel.contentView else { return }

        panelSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        panelSurfaceView.refreshAppearance()
        panelAuraOverlayView.translatesAutoresizingMaskIntoConstraints = false
        panelAuraOverlayView.wantsLayer = true
        panelAuraOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        panelAuraOverlayView.layer?.masksToBounds = false

        titleLabel.font = DesignTokens.Typography.resultPanelTitle
        titleLabel.textColor = DesignTokens.Color.textPrimary
        titleLabel.isSelectable = true
        titleLabel.allowsEditingTextAttributes = true

        pinButton.isBordered = false
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "pin")
        pinButton.contentTintColor = DesignTokens.Color.iconPrimary
        pinButton.target = self
        pinButton.action = #selector(handleTogglePin)

        let header = NSStackView(views: [titleLabel, NSView(), pinButton])
        header.orientation = .horizontal
        header.alignment = .centerY

        configureLoadingDivider()

        transcriptScrollView.translatesAutoresizingMaskIntoConstraints = false
        transcriptScrollView.hasVerticalScroller = false
        transcriptScrollView.drawsBackground = false
        transcriptScrollView.backgroundColor = .clear
        transcriptScrollView.wantsLayer = true
        transcriptScrollView.layer?.backgroundColor = NSColor.clear.cgColor
        transcriptScrollView.borderType = .noBorder
        transcriptScrollView.scrollerStyle = .overlay
        transcriptScrollView.contentView = FlippedClipView()
        transcriptScrollView.contentView.postsBoundsChangedNotifications = true
        if let clip = transcriptScrollView.contentView as? FlippedClipView {
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
        transcriptStack.spacing = DesignTokens.ResultPanel.transcriptRowSpacing
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false

        transcriptContentView.addSubview(transcriptStack)
        NSLayoutConstraint.activate([
            transcriptStack.leadingAnchor.constraint(equalTo: transcriptContentView.leadingAnchor),
            transcriptStack.trailingAnchor.constraint(equalTo: transcriptContentView.trailingAnchor),
            transcriptStack.topAnchor.constraint(equalTo: transcriptContentView.topAnchor),
            transcriptStack.bottomAnchor.constraint(equalTo: transcriptContentView.bottomAnchor),
        ])

        transcriptScrollView.documentView = transcriptContentView

        footerContainer.orientation = .horizontal
        footerContainer.alignment = .centerY
        footerContainer.spacing = DesignTokens.Spacing.sm
        footerContainer.translatesAutoresizingMaskIntoConstraints = false
        footerButtonsStack.orientation = .horizontal
        footerButtonsStack.alignment = .centerY
        footerButtonsStack.spacing = DesignTokens.Spacing.sm
        footerButtonsStack.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.addArrangedSubview(footerButtonsStack)
        footerContainer.addArrangedSubview(NSView())
        footerMinHeightConstraint = footerContainer.heightAnchor.constraint(
            greaterThanOrEqualToConstant: DesignTokens.ResultPanel.Footer.containerMinHeight
        )
        footerMinHeightConstraint?.isActive = true

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.spacing = DesignTokens.ResultPanel.stackSpacing
        contentStack.wantsLayer = true
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(divider)
        contentStack.addArrangedSubview(transcriptScrollView)
        contentStack.addArrangedSubview(footerContainer)

        contentView.addSubview(panelSurfaceView)
        panelSurfaceView.addSubview(panelAuraOverlayView)
        panelSurfaceView.addSubview(contentStack)
        panelSurfaceView.addSubview(transcriptScrollIndicator)

        NSLayoutConstraint.activate([
            panelSurfaceView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            panelSurfaceView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            panelSurfaceView.topAnchor.constraint(equalTo: contentView.topAnchor),
            panelSurfaceView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            panelAuraOverlayView.leadingAnchor.constraint(equalTo: panelSurfaceView.leadingAnchor),
            panelAuraOverlayView.trailingAnchor.constraint(equalTo: panelSurfaceView.trailingAnchor),
            panelAuraOverlayView.topAnchor.constraint(equalTo: panelSurfaceView.topAnchor),
            panelAuraOverlayView.bottomAnchor.constraint(equalTo: panelSurfaceView.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: panelSurfaceView.leadingAnchor, constant: DesignTokens.ResultPanel.contentInsetX),
            contentStack.trailingAnchor.constraint(equalTo: panelSurfaceView.trailingAnchor, constant: -DesignTokens.ResultPanel.contentInsetX),
            contentStack.topAnchor.constraint(equalTo: panelSurfaceView.topAnchor, constant: DesignTokens.ResultPanel.contentInsetY),
            contentStack.bottomAnchor.constraint(equalTo: panelSurfaceView.bottomAnchor, constant: -DesignTokens.ResultPanel.contentInsetY),

            transcriptScrollIndicator.trailingAnchor.constraint(equalTo: transcriptScrollView.trailingAnchor, constant: -DesignTokens.ScrollIndicator.trailingInset),
            transcriptScrollIndicator.topAnchor.constraint(equalTo: transcriptScrollView.topAnchor, constant: DesignTokens.ScrollIndicator.verticalInset),
            transcriptScrollIndicator.bottomAnchor.constraint(equalTo: transcriptScrollView.bottomAnchor, constant: -DesignTokens.ScrollIndicator.verticalInset),
            transcriptScrollIndicator.widthAnchor.constraint(equalToConstant: DesignTokens.ScrollIndicator.width),
        ])

        transcriptHeightConstraint = transcriptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        transcriptHeightConstraint?.isActive = true

        titleLabel.stringValue = L10n.text(zhHans: "结果", en: "Result")
        setFooterVisible(false)
        renderTranscript()
        updateTranscriptDocumentFrame()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTranscriptScrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: transcriptScrollView.contentView
        )
    }

    private func setFooterVisible(_ visible: Bool) {
        footerContainer.isHidden = !visible
        diagnosticsLogger.log("result.footer", "visible=\(visible) kind=\(String(describing: currentDisplayKind))")
    }

    // MARK: - Loading Effects

    private func configureLoadingDivider() {
        // All loading-line tuning is centralized in DesignTokens.Effects.ResultLoadingLine.
        let effect = DesignTokens.Effects.ResultLoadingLine.self

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = effect.trackColor.cgColor
        divider.heightAnchor.constraint(equalToConstant: effect.lineThickness).isActive = true

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
        dividerFlowLayer.opacity = effect.glowOpacity
        dividerFlowLayer.shadowColor = effect.accentColor.cgColor
        dividerFlowLayer.shadowOpacity = effect.shadowOpacity
        dividerFlowLayer.shadowRadius = effect.shadowRadius
        dividerFlowLayer.shadowOffset = .zero
        dividerFlowLayer.opacity = 0

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
        panelAuraContainerLayer.compositingFilter = nil

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
        panelAuraOverlayView.layer?.addSublayer(panelAuraContainerLayer)
        panelAuraContainerLayer.addSublayer(dividerFlowAuraLayer)
        divider.layer?.addSublayer(dividerFlowContainerLayer)
        dividerFlowContainerLayer.mask = dividerFlowMaskLayer
        dividerFlowContainerLayer.addSublayer(dividerFlowLayer)
    }

    private func startLoadingLineFlow() {
        guard DesignTokens.Effects.ResultLoadingLine.isEnabled else { return }
        guard let hostLayer = divider.layer else { return }

        panel.contentView?.layoutSubtreeIfNeeded()
        divider.superview?.layoutSubtreeIfNeeded()

        let effect = DesignTokens.Effects.ResultLoadingLine.self
        let availableWidth = max(divider.bounds.width, 120)
        let startMidX = -effect.glowWidth
        let endMidX = availableWidth + effect.glowWidth * 1.25
        let dividerRectInPanel = panelAuraOverlayView.convert(divider.bounds, from: divider)
        let auraWidth = effect.glowWidth * effect.auraWidthMultiplier

        hostLayer.masksToBounds = false
        dividerFlowContainerLayer.frame = CGRect(
            x: 0,
            y: -(effect.shadowRadius - effect.lineThickness) / 2,
            width: divider.bounds.width,
            height: effect.shadowRadius + effect.lineThickness
        )
        panelAuraContainerLayer.frame = panelAuraOverlayView.bounds
        let fadeFraction = min(max(effect.edgeFadeWidth / max(divider.bounds.width, 1), 0.01), 0.45)
        dividerFlowMaskLayer.frame = dividerFlowContainerLayer.bounds
        dividerFlowMaskLayer.locations = [
            0,
            NSNumber(value: Double(fadeFraction * 0.46)),
            NSNumber(value: Double(fadeFraction)),
            NSNumber(value: Double(1 - fadeFraction)),
            NSNumber(value: Double(1 - fadeFraction * 0.46)),
            1,
        ]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dividerFlowAuraLayer.removeAllAnimations()
        dividerFlowLayer.removeAllAnimations()
        dividerFlowAuraLayer.frame = CGRect(
            x: dividerRectInPanel.minX + startMidX - auraWidth / 2,
            y: dividerRectInPanel.midY - effect.auraHeight / 2 + effect.auraVerticalOffset,
            width: auraWidth,
            height: effect.auraHeight
        )
        dividerFlowAuraLayer.opacity = 0
        dividerFlowLayer.frame = CGRect(
            x: startMidX - effect.glowWidth / 2,
            y: (dividerFlowContainerLayer.bounds.height - effect.lineThickness) / 2,
            width: effect.glowWidth,
            height: effect.lineThickness
        )
        dividerFlowLayer.opacity = 0
        CATransaction.commit()

        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = startMidX
        move.toValue = endMidX

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, effect.glowOpacity, effect.glowOpacity, 0]
        opacity.keyTimes = [0, 0.12, 0.97, 1]

        let auraMove = CABasicAnimation(keyPath: "position.x")
        auraMove.fromValue = dividerRectInPanel.minX + startMidX
        auraMove.toValue = dividerRectInPanel.minX + endMidX

        let auraOpacity = CAKeyframeAnimation(keyPath: "opacity")
        auraOpacity.values = [0, effect.auraOpacity, effect.auraOpacity, 0]
        auraOpacity.keyTimes = [0, 0.12, 0.97, 1]

        let group = CAAnimationGroup()
        group.animations = [move, opacity]
        group.duration = effect.animationDuration
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        group.isRemovedOnCompletion = false

        let auraGroup = CAAnimationGroup()
        auraGroup.animations = [auraMove, auraOpacity]
        auraGroup.duration = effect.animationDuration
        auraGroup.repeatCount = .infinity
        auraGroup.timingFunction = CAMediaTimingFunction(name: .linear)
        auraGroup.isRemovedOnCompletion = false

        dividerFlowAuraLayer.add(auraGroup, forKey: LoadingEffectAnimationKey.auraMove)
        dividerFlowLayer.add(group, forKey: LoadingEffectAnimationKey.lineMove)
    }

    private func stopLoadingLineFlow(immediately: Bool = false) {
        let currentAuraPresentation = dividerFlowAuraLayer.presentation()
        let currentAuraOpacity = currentAuraPresentation?.opacity ?? dividerFlowAuraLayer.opacity
        let currentAuraPosition = currentAuraPresentation?.position ?? dividerFlowAuraLayer.position
        dividerFlowAuraLayer.removeAnimation(forKey: LoadingEffectAnimationKey.auraMove)
        dividerFlowAuraLayer.removeAnimation(forKey: LoadingEffectAnimationKey.auraFade)
        let currentPresentation = dividerFlowLayer.presentation()
        let currentOpacity = currentPresentation?.opacity ?? dividerFlowLayer.opacity
        let currentPosition = currentPresentation?.position ?? dividerFlowLayer.position
        dividerFlowLayer.removeAnimation(forKey: LoadingEffectAnimationKey.lineMove)
        dividerFlowLayer.removeAnimation(forKey: LoadingEffectAnimationKey.lineFade)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dividerFlowAuraLayer.position = currentAuraPosition
        dividerFlowAuraLayer.opacity = currentAuraOpacity
        dividerFlowLayer.position = currentPosition
        dividerFlowLayer.opacity = currentOpacity
        CATransaction.commit()

        guard !immediately else {
            dividerFlowAuraLayer.opacity = 0
            dividerFlowLayer.opacity = 0
            return
        }

        let effect = DesignTokens.Effects.ResultLoadingLine.self

        let auraFade = CABasicAnimation(keyPath: "opacity")
        auraFade.fromValue = currentAuraOpacity
        auraFade.toValue = 0
        auraFade.duration = effect.fadeDuration
        auraFade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = currentOpacity
        fade.toValue = 0
        fade.duration = effect.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let auraGroup = CAAnimationGroup()
        auraGroup.animations = [auraFade]
        auraGroup.duration = effect.fadeDuration
        auraGroup.isRemovedOnCompletion = true

        let group = CAAnimationGroup()
        group.animations = [fade]
        group.duration = effect.fadeDuration
        group.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dividerFlowAuraLayer.opacity = 0
        dividerFlowLayer.opacity = 0
        CATransaction.commit()

        dividerFlowAuraLayer.add(auraGroup, forKey: LoadingEffectAnimationKey.auraFade)
        dividerFlowLayer.add(group, forKey: LoadingEffectAnimationKey.lineFade)
    }

    private func resetConversation() {
        messages.removeAll()
        activeToolStatusKey = nil
        latestTraceEntities = []
        pendingTraceEntities = []
        latestActionCards = []
        pendingActionCards = []
        pendingToolStatuses.removeAll()
        toolStatusPumpWorkItem?.cancel()
        toolStatusPumpWorkItem = nil
        lastToolStatusRenderAt = nil
        streamingRevealTimer?.invalidate()
        streamingRevealTimer = nil
        streamingChunkFadeTimer?.invalidate()
        streamingChunkFadeTimer = nil
        streamingTargetText = ""
        pendingStreamingChunks.removeAll()
        streamingAssistantIndex = nil
        renderedTraceCardCount = 0
        pendingTraceCardEntranceIndex = nil
        traceCardRevealSequence += 1
        renderedActionCardCount = 0
        pendingActionCardEntranceIndex = nil
        actionCardRevealSequence += 1
        streamingHighlightedSuffixLength = 0
        streamingHighlightedAlpha = 1
        pendingTranslationFooterReveal = false
        renderTranscript()
        if currentDisplayKind == .trace {
            scrollTranscriptToBottom()
        } else {
            scrollTranscriptToTop()
        }
    }

    private func makeFooterButton(for descriptor: FooterActionDescriptor) -> NSButton {
        let button = FooterActionButton(title: descriptor.title, target: self, action: #selector(handleFooterButtonClick(_:)))
        button.contentTintColor = DesignTokens.Color.iconPrimary
        button.font = DesignTokens.Typography.resultPanelFooterButton
        button.imagePosition = NSControl.ImagePosition.imageLeading
        button.image = NSImage(
            systemSymbolName: descriptor.systemImageName,
            accessibilityDescription: descriptor.accessibilityDescription
        )
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.identifier = NSUserInterfaceItemIdentifier(descriptor.kind.rawValue)
        button.followupSkillID = descriptor.followupSkillID
        button.followupInputSource = descriptor.followupInputSource
        button.followupMaxDepth = descriptor.followupMaxDepth
        button.followupSourceSkillID = descriptor.followupSourceSkillID
        return button
    }

    private func applyFooterActions(_ actions: [FooterActionDescriptor], reserveSpace: Bool = false) {
        currentFooterActions = actions
        clearArrangedSubviews(of: footerButtonsStack)
        for descriptor in actions {
            footerButtonsStack.addArrangedSubview(makeFooterButton(for: descriptor))
        }
        setFooterVisible(!actions.isEmpty || reserveSpace)
    }

    private func applyChromePresentation(_ presentation: PanelChromePresentation) {
        currentDisplayKind = presentation.kind
        titleLabel.stringValue = presentation.title
    }

    private func applyConversationUpdate(_ update: ConversationUpdate) {
        switch update {
        case .finalizeAssistant(let text):
            finalizeStreamingAssistantMessage(text)

        case .finalizeAssistantWithActionCards(let text, let cards):
            finalizeStreamingAssistantMessage(text)
            self.pendingActionCards = cards

        case .trace(let summary, let pendingEntities):
            let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedSummary.isEmpty {
                finalizeStreamingAssistantMessage(trimmedSummary)
            } else {
                messages.removeAll { $0.role == .assistant }
                streamingAssistantIndex = nil
                pendingStreamingChunks.removeAll()
                streamingTargetText = ""
                streamingRevealTimer?.invalidate()
                streamingRevealTimer = nil
            }

            self.pendingTraceEntities = pendingEntities

        case .info(let message):
            appendMessage(role: .info, text: message)
            streamingAssistantIndex = nil
        }
    }

    private func clearStreamingScratchState() {
        streamingRevealTimer?.invalidate()
        streamingRevealTimer = nil
        streamingChunkFadeTimer?.invalidate()
        streamingChunkFadeTimer = nil
        pendingStreamingChunks.removeAll()
        pendingTraceCardEntranceIndex = nil
        traceCardRevealSequence += 1
        streamingHighlightedSuffixLength = 0
        streamingHighlightedAlpha = 1
    }

    private func clearTraceRevealState() {
        latestTraceEntities = []
        pendingTraceEntities = []
        pendingTraceCardEntranceIndex = nil
        pendingToolStatuses.removeAll()
        toolStatusPumpWorkItem?.cancel()
        toolStatusPumpWorkItem = nil
        lastToolStatusRenderAt = nil
    }

    private func streamingSessionPresentation(for definition: SkillDefinition) -> StreamingSessionPresentation {
        let title = resultTitle(for: definition)

        switch definition.skillID {
        case "translate":
            return StreamingSessionPresentation(
                chrome: PanelChromePresentation(
                    kind: .translate,
                    title: title
                ),
                queuesThinkingStatus: true
            )

        case "trace":
            return StreamingSessionPresentation(
                chrome: PanelChromePresentation(
                    kind: .trace,
                    title: title
                ),
                queuesThinkingStatus: false
            )

        case "explain":
            return StreamingSessionPresentation(
                chrome: PanelChromePresentation(
                    kind: .explain,
                    title: title
                ),
                queuesThinkingStatus: true
            )

        case "reply":
            return StreamingSessionPresentation(
                chrome: PanelChromePresentation(
                    kind: .reply,
                    title: title
                ),
                queuesThinkingStatus: true
            )

        case "schedule":
            return StreamingSessionPresentation(
                chrome: PanelChromePresentation(
                    kind: .schedule,
                    title: title
                ),
                queuesThinkingStatus: true
            )

        case "compress":
            return StreamingSessionPresentation(
                chrome: PanelChromePresentation(
                    kind: .info,
                    title: title
                ),
                queuesThinkingStatus: true
            )

        default:
            return StreamingSessionPresentation(
                chrome: PanelChromePresentation(
                    kind: .info,
                    title: title
                ),
                queuesThinkingStatus: false
            )
        }
    }

    private func streamingUpdatePresentation(
        for event: SkillRuntimeEvent
    ) -> StreamingUpdatePresentation {
        let toolStatus: PendingToolStatus?
        let shouldRenderToolStatus = (
            streamingKind == .trace
            || streamingKind == .schedule
            || (currentDefinition?.skillID == "compress")
            || (currentDefinition?.skillID == "collect")
        )
        if let status = event.status, !status.isEmpty, shouldRenderToolStatus, event.type == .status {
            toolStatus = PendingToolStatus(
                key: status,
                title: localizedStatusText(status),
                detail: event.detail,
                label: toolLabel(for: status)
            )
        } else {
            toolStatus = nil
        }

        let validEntities: [TraceEntity]?
        let validActionCards: [SkillResultCard]?
        if event.type == .supplement {
            if streamingKind == .trace {
                let filtered = traceEntities(from: event.cards)
                    .filter { !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                validEntities = filtered.isEmpty ? nil : filtered
                validActionCards = nil
            } else {
                // Generic action cards for any non-trace skill (e.g. schedule with calendar cards)
                let cards: [SkillResultCard]
                if currentDefinition?.resultType == .summaryWithCards {
                    cards = event.cards ?? []
                } else {
                    cards = (event.cards ?? []).filter { $0.action != nil }
                }
                validActionCards = cards.isEmpty ? nil : cards
                validEntities = nil
            }
        } else {
            validEntities = nil
            validActionCards = nil
        }

        let normalizedFullText = event.fullText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let latestTextToCopy = (normalizedFullText?.isEmpty == false) ? event.fullText : nil
        let latestReplaceText = (normalizedFullText?.isEmpty == false && streamingKind == .translate) ? event.fullText : nil

        let assistantText: StreamingTextPresentation?
        if event.type == .delta, let partialDelta = event.delta, !partialDelta.isEmpty {
            let resolvedFullText = (normalizedFullText?.isEmpty == false) ? event.fullText : nil
            assistantText = StreamingTextPresentation(delta: partialDelta, fullText: resolvedFullText)
        } else {
            assistantText = nil
        }

        let dismissLoadingStatusBeforeAssistant = assistantText != nil
            && shouldHideStatusOnFirstDelta(for: currentDefinition)
            && shouldShowLoadingInResultWindow(for: currentDefinition)
        let shouldDismissToolStatusesBeforeAssistant = (shouldRenderToolStatus || dismissLoadingStatusBeforeAssistant)
            && assistantText != nil

        return StreamingUpdatePresentation(
            toolStatus: toolStatus,
            pendingTraceEntities: validEntities,
            pendingActionCards: validActionCards,
            latestTextToCopy: latestTextToCopy,
            latestReplaceText: latestReplaceText,
            latestSourceURL: primaryURL(from: event.cards) ?? validEntities.flatMap { URL(string: $0.first?.url ?? "") },
            flushPendingToolStatusesBeforeAssistant: shouldDismissToolStatusesBeforeAssistant,
            clearsPendingToolStatusesBeforeAssistant: shouldDismissToolStatusesBeforeAssistant,
            cancelsToolStatusPumpBeforeAssistant: shouldDismissToolStatusesBeforeAssistant,
            removesToolMessagesBeforeAssistant: shouldDismissToolStatusesBeforeAssistant,
            assistantText: assistantText
        )
    }

    private func applyStreamingUpdate(_ presentation: StreamingUpdatePresentation) {
        if let toolStatus = presentation.toolStatus {
            enqueueToolStatus(
                statusKey: toolStatus.key,
                title: toolStatus.title,
                detail: toolStatus.detail,
                label: toolStatus.label
            )
        }

        if let pendingTraceEntities = presentation.pendingTraceEntities {
            self.pendingTraceEntities = pendingTraceEntities
        }

        if let pendingActionCards = presentation.pendingActionCards {
            self.pendingActionCards = pendingActionCards
        }

        if let latestSourceURL = presentation.latestSourceURL {
            self.latestSourceURL = latestSourceURL
        }

        if let latestTextToCopy = presentation.latestTextToCopy {
            self.latestTextToCopy = latestTextToCopy
        }

        if let latestReplaceText = presentation.latestReplaceText {
            self.latestReplaceText = latestReplaceText
        }

        guard let assistantText = presentation.assistantText else { return }

        if presentation.flushPendingToolStatusesBeforeAssistant {
            flushPendingToolStatuses()
        }

        if presentation.clearsPendingToolStatusesBeforeAssistant {
            pendingToolStatuses.removeAll()
        }

        if presentation.cancelsToolStatusPumpBeforeAssistant {
            toolStatusPumpWorkItem?.cancel()
            toolStatusPumpWorkItem = nil
        }

        if presentation.removesToolMessagesBeforeAssistant {
            removeToolMessages()
        }

        appendStreamingChunk(assistantText.delta, fullText: assistantText.fullText)
    }

    private func completedPresentation(for resultEnvelope: SkillResultEnvelope) -> CompletedResultPresentation {
        let displayText = resolvedPrimaryText(from: resultEnvelope)
        let trimmedDisplayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingEntities = resultEnvelope.skillID == "trace" ? traceEntities(from: resultEnvelope.cards) : []
        let resolvedActions = ResultActionResolver.resolve(
            resultEnvelope: resultEnvelope,
            currentDefinition: currentDefinition,
            actionRegistry: ActionRegistry.shared,
            settings: settings,
            sourceInteractionContext: currentSourceInteractionContext,
            currentSourceText: currentSourceText,
            latestSourceURL: latestSourceURL,
            resolvedPrimaryText: displayText
        )

        // Extract action cards for non-trace skills (e.g. calendar cards from reply)
        let actionCards: [SkillResultCard]
        if resultEnvelope.skillID != "trace" {
            if resultEnvelope.resultType == .summaryWithCards {
                actionCards = resultEnvelope.cards ?? []
            } else {
                actionCards = (resultEnvelope.cards ?? []).filter { $0.action != nil }
            }
        } else {
            actionCards = []
        }

        let conversationUpdate: ConversationUpdate
        switch resultEnvelope.skillID {
        case "trace":
            conversationUpdate = .trace(
                summary: trimmedDisplayText.isEmpty ? nil : displayText,
                pendingEntities: pendingEntities
            )
        case "info":
            conversationUpdate = .info(displayText)
        default:
            if !actionCards.isEmpty {
                conversationUpdate = .finalizeAssistantWithActionCards(displayText, cards: actionCards)
            } else {
                conversationUpdate = .finalizeAssistant(displayText)
            }
        }

        return CompletedResultPresentation(
            chrome: chromePresentation(for: resultEnvelope),
            footerActions: resolvedActions.footerActions.map {
                FooterActionDescriptor(
                    kind: $0.kind,
                    title: $0.title,
                    systemImageName: $0.systemImageName,
                    accessibilityDescription: $0.accessibilityDescription,
                    followupSkillID: $0.followupSkillID,
                    followupInputSource: $0.followupInputSource,
                    followupMaxDepth: $0.followupMaxDepth,
                    followupSourceSkillID: $0.followupSourceSkillID
                )
            },
            conversationUpdate: conversationUpdate,
            latestTextToCopy: resolvedActions.copyPayload,
            latestReplaceText: resolvedActions.replacePayload,
            latestWritebackText: resolvedActions.writebackPayload,
            latestSourceURL: resolvedActions.primaryURL,
            latestTraceEntities: [],
            pendingTraceEntities: pendingEntities,
            pendingActionCards: actionCards,
            shouldQueueFooterReveal: shouldQueueFooterReveal(for: resultEnvelope),
            shouldScheduleTraceCardFallbackReveal: resultEnvelope.skillID == "trace" && !trimmedDisplayText.isEmpty && !pendingEntities.isEmpty,
            shouldPublishPendingTraceEntitiesImmediately: resultEnvelope.skillID == "trace" && trimmedDisplayText.isEmpty && !pendingEntities.isEmpty,
            shouldPublishActionCardsImmediately: !actionCards.isEmpty && !isStreamingMode,
            clearsStreamingScratchState: resultEnvelope.skillID == "info",
            clearsTraceRevealState: true
        )
    }

    private func footerActions(from descriptors: [FooterActionDescriptor]) -> [ResultFooterAction] {
        descriptors.map {
            ResultFooterAction(
                kind: $0.kind,
                title: $0.title,
                systemImageName: $0.systemImageName,
                accessibilityDescription: $0.accessibilityDescription,
                followupSkillID: $0.followupSkillID,
                followupInputSource: $0.followupInputSource,
                followupMaxDepth: $0.followupMaxDepth,
                followupSourceSkillID: $0.followupSourceSkillID,
                capabilityActionID: nil
            )
        }
    }

    private func chromePresentation(for resultEnvelope: SkillResultEnvelope) -> PanelChromePresentation {
        let title: String
        if resultEnvelope.skillID == "info" {
            title = L10n.text(zhHans: "提示", en: "Notice")
        } else if let definition = currentDefinition, definition.skillID == resultEnvelope.skillID {
            title = resultTitle(for: definition)
        } else {
            title = defaultResultTitle(for: resultEnvelope.skillID)
        }

        return PanelChromePresentation(
            kind: displayKind(for: resultEnvelope.skillID),
            title: title
        )
    }

    private func supportsWritebackForCurrentSource() -> Bool {
        currentSourceInteractionContext.supportsMessageWriteback
    }

    private func resolvedDefinition(for skillID: String) -> SkillDefinition? {
        if let definition = currentDefinition, definition.skillID == skillID {
            return definition
        }
        return ActionRegistry.shared.definition(forSkillID: skillID)
    }

    private func shouldQueueFooterReveal(for resultEnvelope: SkillResultEnvelope) -> Bool {
        if let definition = currentDefinition, definition.skillID == resultEnvelope.skillID {
            if displayKind(for: resultEnvelope.skillID) == .info {
                return false
            }
            return definition.manifest.lifecycle.revealFooterAfterCompletion ?? false
        }
        // Fallback: check the registry for any skill's lifecycle declaration
        if let definition = ActionRegistry.shared.definition(forSkillID: resultEnvelope.skillID) {
            if displayKind(for: resultEnvelope.skillID) == .info {
                return false
            }
            return definition.manifest.lifecycle.revealFooterAfterCompletion ?? false
        }
        return false
    }

    private func shouldShowLoadingInResultWindow(for definition: SkillDefinition?) -> Bool {
        definition?.manifest.lifecycle.showLoadingInResultWindow ?? true
    }

    private func shouldHideStatusOnFirstDelta(for definition: SkillDefinition?) -> Bool {
        definition?.manifest.lifecycle.hideStatusOnFirstDelta ?? true
    }

    private func resolvedPrimaryText(from resultEnvelope: SkillResultEnvelope) -> String {
        if let body = resultEnvelope.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        return resultEnvelope.summary ?? ""
    }

    private func displayKind(for skillID: String) -> DisplayKind {
        switch skillID {
        case "translate":
            return .translate
        case "trace":
            return .trace
        case "explain":
            return .explain
        case "reply":
            return .reply
        case "schedule":
            return .schedule
        case "compress":
            return .info
        case "screenshot_ocr":
            return .info
        default:
            return .info
        }
    }

    private func defaultResultTitle(for skillID: String) -> String {
        switch skillID {
        case "translate":
            return L10n.text(zhHans: "翻译结果", en: "Translation")
        case "trace":
            return L10n.text(zhHans: "溯源结果", en: "Source Result")
        case "explain":
            return L10n.text(zhHans: "解释结果", en: "Explanation")
        case "reply":
            return L10n.text(zhHans: "高情商回复", en: "Reply Draft")
        case "schedule":
            return L10n.text(zhHans: "日程提醒", en: "Schedule Reminder")
        case "compress":
            return L10n.text(zhHans: "文件压缩", en: "Compression Result")
        case "screenshot_ocr":
            return L10n.text(zhHans: "OCR 结果", en: "OCR Result")
        default:
            return L10n.text(zhHans: "提示", en: "Notice")
        }
    }

    private func primaryURL(from cards: [SkillResultCard]?) -> URL? {
        cards?.compactMap { card in
            guard card.action?.type == .openURL, let value = card.action?.value else { return nil }
            return URL(string: value)
        }.first
    }

    private func traceEntities(from cards: [SkillResultCard]?) -> [TraceEntity] {
        (cards ?? []).compactMap { card in
            let url = card.action?.value ?? card.subtitle ?? ""
            guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TraceEntity(
                name: card.title,
                entityType: card.kind,
                title: card.title,
                url: url,
                snippet: card.description ?? "",
                whyThis: nil,
                isOfficial: card.isOfficial
            )
        }
    }

    private func actionCardSectionTitle(for cards: [SkillResultCard]) -> String {
        guard let firstKind = cards.first?.kind else { return L10n.text(zhHans: "快捷操作", en: "Quick Actions") }
        switch firstKind {
        case "calendar_event":
            return L10n.text(zhHans: "📅 创建日历提醒", en: "📅 Create Calendar Event")
        case "reminder":
            return L10n.text(zhHans: "⏰ 创建提醒事项", en: "⏰ Create Reminder")
        case "knowledge_base_source":
            return L10n.text(zhHans: "引用来源", en: "Sources")
        default:
            return L10n.text(zhHans: "快捷操作", en: "Quick Actions")
        }
    }

    private func appendMessage(role: MessageRole, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: role, text: trimmed, toolKey: nil, toolDetails: [], toolLabel: nil, toolAnimatedDetail: nil))
        renderTranscript()
    }

    private func removeToolMessages() {
        messages.removeAll { $0.role == .tool }
        activeToolStatusKey = nil
    }

    private func normalizedToolDetails(from detail: String?, statusKey: String? = nil) -> [String] {
        guard let detail else { return [] }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [localizedToolDetail(trimmed, for: statusKey)]
    }

    private func mergedToolDetails(existing: [String], incoming detail: String?, statusKey: String?) -> [String] {
        guard let detail else { return existing }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        let localized = localizedToolDetail(trimmed, for: statusKey)
        if existing.last == localized {
            return existing
        }
        var merged = existing
        merged.append(localized)
        if merged.count > 6 {
            merged.removeFirst(merged.count - 6)
        }
        return merged
    }

    private func appendToolDetail(_ detail: String?, statusKey: String?, to message: inout ChatMessage) {
        guard let detail else { return }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let localized = localizedToolDetail(trimmed, for: statusKey)
        if message.toolDetails.last == localized {
            return
        }
        message.toolDetails.append(localized)
        if message.toolDetails.count > 4 {
            message.toolDetails.removeFirst(message.toolDetails.count - 4)
        }
        message.toolAnimatedDetail = localized
    }

    private func enqueueToolStatus(statusKey: String, title: String, detail: String?, label: String? = nil) {
        if let index = messages.firstIndex(where: { $0.role == .tool }) {
            if messages[index].toolKey == statusKey {
                let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
                let isDuplicate = messages[index].text == title
                    && messages[index].toolLabel == label
                    && (trimmed?.isEmpty != false || messages[index].toolDetails.last == trimmed)
                guard !isDuplicate else { return }
                pendingToolStatuses.append(PendingToolStatus(key: statusKey, title: title, detail: detail, label: label))
                pumpToolStatusesIfNeeded()
                return
            }
            pendingToolStatuses.removeAll()
            toolStatusPumpWorkItem?.cancel()
            toolStatusPumpWorkItem = nil
            messages[index].text = title
            messages[index].toolKey = statusKey
            messages[index].toolDetails = mergedToolDetails(
                existing: messages[index].toolDetails,
                incoming: detail,
                statusKey: statusKey
            )
            messages[index].toolLabel = label
            messages[index].toolAnimatedDetail = messages[index].toolDetails.last
            activeToolStatusKey = statusKey
            renderTranscript()
            return
        }
        appendToolStatusNow(statusKey: statusKey, title: title, detail: detail, label: label)
    }

    private func flushPendingToolStatuses() {
        toolStatusPumpWorkItem?.cancel()
        toolStatusPumpWorkItem = nil
        while let next = pendingToolStatuses.first {
            pendingToolStatuses.removeFirst()
            appendToolStatusNow(statusKey: next.key, title: next.title, detail: next.detail, label: next.label)
        }
    }

    private func pumpToolStatusesIfNeeded() {
        guard toolStatusPumpWorkItem == nil, let next = pendingToolStatuses.first else { return }
        let minInterval: TimeInterval
        if next.key == "semantic_decomposition" {
            minInterval = Double.random(in: 0.34...0.52)
        } else {
            minInterval = 0.18
        }
        let elapsed = lastToolStatusRenderAt.map { Date().timeIntervalSince($0) } ?? minInterval
        let delay = max(0, minInterval - elapsed)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.toolStatusPumpWorkItem = nil
            guard self.pendingToolStatuses.first?.key == next.key else {
                self.pumpToolStatusesIfNeeded()
                return
            }
            self.pendingToolStatuses.removeFirst()
            self.appendToolStatusNow(statusKey: next.key, title: next.title, detail: next.detail, label: next.label)
            self.pumpToolStatusesIfNeeded()
        }
        toolStatusPumpWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func appendToolStatusNow(statusKey: String, title: String, detail: String?, label: String? = nil) {
        if let index = messages.firstIndex(where: { $0.role == .tool }) {
            if messages[index].toolKey == statusKey {
                messages[index].text = title
                messages[index].toolLabel = label
                appendToolDetail(detail, statusKey: statusKey, to: &messages[index])
            } else {
                messages[index].text = title
                messages[index].toolKey = statusKey
                messages[index].toolDetails = mergedToolDetails(
                    existing: messages[index].toolDetails,
                    incoming: detail,
                    statusKey: statusKey
                )
                messages[index].toolLabel = label
                messages[index].toolAnimatedDetail = messages[index].toolDetails.last
            }
        } else {
            messages.append(
                ChatMessage(
                    role: .tool,
                    text: title,
                    toolKey: statusKey,
                    toolDetails: normalizedToolDetails(from: detail, statusKey: statusKey),
                    toolLabel: label,
                    toolAnimatedDetail: normalizedToolDetails(from: detail, statusKey: statusKey).last
                )
            )
        }
        activeToolStatusKey = statusKey
        lastToolStatusRenderAt = Date()
        renderTranscript()
    }

    private func localizedToolDetail(_ detail: String, for statusKey: String?) -> String {
        guard AppSettings.shared.appLanguage == .english else {
            return detail
        }

        switch statusKey {
        case "search_enhancement":
            if detail == "预检查官网域名" {
                return "Checking likely official domains first"
            }
            if let progress = localizedSearchProgressDetail(detail) {
                return progress
            }
            if let candidates = localizedFoundCandidatesDetail(detail) {
                return candidates
            }
            if detail == "暂无命中" {
                return "No hits yet"
            }
        case "candidate_resolution":
            if let narrowed = localizedPrefixedDetail(detail, prefix: "候选已收束到：", suffix: "。", englishPrefix: "Narrowed candidates to: ") {
                return narrowed
            }
            if let kept = localizedKeepExcludeDetail(detail) {
                return kept
            }
            if let locked = localizedPrefixedDetail(detail, prefix: "已锁定 ", suffix: "。", englishPrefix: "Locked ") {
                return locked
            }
        default:
            break
        }

        return detail
    }

    private func localizedSearchProgressDetail(_ detail: String) -> String? {
        guard detail.hasPrefix("搜索 ") else { return nil }
        let value = String(detail.dropFirst("搜索 ".count))
        return "Search \(value)"
    }

    private func localizedFoundCandidatesDetail(_ detail: String) -> String? {
        let prefix = "命中 "
        let marker = " 个候选："
        guard detail.hasPrefix(prefix), let range = detail.range(of: marker) else { return nil }
        let count = detail[detail.index(detail.startIndex, offsetBy: prefix.count)..<range.lowerBound]
        let summary = detail[range.upperBound...]
        return "Found \(count) candidate(s): \(summary)"
    }

    private func localizedKeepExcludeDetail(_ detail: String) -> String? {
        let keepPrefix = "保留 "
        let excludeMarker = "；排除 "
        let suffix = "。"
        guard detail.hasPrefix(keepPrefix),
              let excludeRange = detail.range(of: excludeMarker),
              detail.hasSuffix(suffix) else {
            return nil
        }
        let kept = detail[detail.index(detail.startIndex, offsetBy: keepPrefix.count)..<excludeRange.lowerBound]
        let excluded = detail[excludeRange.upperBound..<detail.index(detail.endIndex, offsetBy: -suffix.count)]
        return "Kept \(kept); excluded \(excluded)."
    }

    private func localizedPrefixedDetail(_ detail: String, prefix: String, suffix: String, englishPrefix: String) -> String? {
        guard detail.hasPrefix(prefix), detail.hasSuffix(suffix) else { return nil }
        let start = detail.index(detail.startIndex, offsetBy: prefix.count)
        let end = detail.index(detail.endIndex, offsetBy: -suffix.count)
        let content = detail[start..<end]
        return "\(englishPrefix)\(content)."
    }

    private func appendStreamingChunk(_ delta: String, fullText: String?) {
        if streamingKind == .translate || streamingKind == .trace || streamingKind == .explain || streamingKind == .reply || streamingKind == .schedule {
            removeToolMessages()
        }
        let insertedAssistantMessage: Bool
        if let index = streamingAssistantIndex, messages.indices.contains(index) {
            _ = index
            insertedAssistantMessage = false
        } else {
            messages.append(ChatMessage(role: .assistant, text: "", toolKey: nil, toolDetails: [], toolLabel: nil, toolAnimatedDetail: nil))
            streamingAssistantIndex = messages.count - 1
            insertedAssistantMessage = true
        }

        let normalizedDelta = delta.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalizedDelta.isEmpty else { return }
        pendingStreamingChunks.append(normalizedDelta)
        if let fullText, !fullText.isEmpty {
            streamingTargetText = fullText
        } else {
            streamingTargetText += normalizedDelta
        }

        startStreamingRevealTimerIfNeeded()
        if insertedAssistantMessage {
            renderTranscript()
        }
    }

    private func revealFooterIfReady() {
        guard pendingTranslationFooterReveal else { return }
        guard isFooterReady() else { return }
        pendingTranslationFooterReveal = false
        setFooterVisible(true)
    }

    private func syncFooterVisibility() {
        guard currentDisplayKind == .translate || currentDisplayKind == .reply else { return }
        guard pendingTranslationFooterReveal else { return }
        if isFooterReady() {
            pendingTranslationFooterReveal = false
            setFooterVisible(true)
        }
    }

    private func isFooterReady() -> Bool {
        guard (currentDisplayKind == .translate || currentDisplayKind == .reply), !isStreamingMode else { return false }
        guard pendingStreamingChunks.isEmpty else { return false }
        guard let index = streamingAssistantIndex, messages.indices.contains(index) else { return false }

        let current = normalizedStreamingText(messages[index].text)
        let target = normalizedStreamingText(streamingTargetText)
        guard !current.isEmpty, !target.isEmpty else { return false }
        return current == target
    }

    private func finalizeStreamingAssistantMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        streamingTargetText = trimmed

        if streamingAssistantIndex == nil {
            messages.append(ChatMessage(role: .assistant, text: "", toolKey: nil, toolDetails: [], toolLabel: nil, toolAnimatedDetail: nil))
            streamingAssistantIndex = messages.count - 1
        }

        latestTextToCopy = trimmed
        if streamingKind == .translate {
            latestReplaceText = trimmed
        }

        if let index = streamingAssistantIndex, messages.indices.contains(index) {
            let revealed = messages[index].text
            let normalizedTarget = normalizedStreamingText(trimmed)
            let normalizedProjected = normalizedStreamingText(revealed + pendingStreamingChunks.joined())
            if normalizedProjected == normalizedTarget {
                startStreamingRevealTimerIfNeeded()
                renderTranscript()
                return
            }

            if trimmed.hasPrefix(revealed) {
                let remaining = String(trimmed.dropFirst(revealed.count))
                pendingStreamingChunks = remaining.isEmpty ? [] : [remaining]
            } else {
                messages[index].text = ""
                pendingStreamingChunks = [trimmed]
            }
        } else {
            pendingStreamingChunks = [trimmed]
        }

        startStreamingRevealTimerIfNeeded()
        renderTranscript()
    }

    private func startStreamingRevealTimerIfNeeded() {
        guard streamingRevealTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: SharedStreamingTextAnimation.revealInterval, repeats: true) { [weak self] timer in
            self?.tickStreamingReveal(timer)
        }
        streamingRevealTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tickStreamingReveal(_ timer: Timer) {
        guard let index = streamingAssistantIndex, messages.indices.contains(index) else {
            timer.invalidate()
            streamingRevealTimer = nil
            return
        }

        if !pendingStreamingChunks.isEmpty {
            let maxChunksThisTick = pendingStreamingChunks.count > 6 ? 2 : 1
            let revealCount = min(maxChunksThisTick, pendingStreamingChunks.count)
            let revealed = pendingStreamingChunks.prefix(revealCount).joined()
            pendingStreamingChunks.removeFirst(revealCount)
            messages[index].text += revealed
            highlightLatestChunk(revealed)
            if !updateStreamingAssistantRowIfPossible() {
                renderTranscript()
            }
        }

        let current = messages[index].text
        let isComplete = normalizedStreamingText(current) == normalizedStreamingText(streamingTargetText)
        guard !isComplete || !pendingStreamingChunks.isEmpty else {
            revealFooterIfReady()
            publishPendingTraceEntitiesIfNeeded()
            publishPendingActionCardsIfNeeded()
            if !isStreamingMode {
                timer.invalidate()
                streamingRevealTimer = nil
            }
            return
        }
    }

    private func flushStreamingReveal() {
        guard let index = streamingAssistantIndex, messages.indices.contains(index) else { return }
        messages[index].text = streamingTargetText
        publishPendingTraceEntitiesIfNeeded()
        publishPendingActionCardsIfNeeded()
        streamingRevealTimer?.invalidate()
        streamingRevealTimer = nil
        pendingStreamingChunks.removeAll()
        streamingChunkFadeTimer?.invalidate()
        streamingChunkFadeTimer = nil
        streamingHighlightedSuffixLength = 0
        streamingHighlightedAlpha = 1
        revealFooterIfReady()
        if !updateStreamingAssistantRowIfPossible() {
            renderTranscript()
        }
    }

    private func normalizedStreamingText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func highlightLatestChunk(_ chunk: String) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        streamingHighlightedSuffixLength = (chunk as NSString).length
        streamingHighlightedAlpha = SharedStreamingTextAnimation.initialHighlightedAlpha
        streamingChunkFadeTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: SharedStreamingTextAnimation.highlightFadeInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.streamingHighlightedAlpha = min(1, self.streamingHighlightedAlpha + SharedStreamingTextAnimation.highlightAlphaStep)
            if !self.updateStreamingAssistantRowIfPossible() {
                self.renderTranscript()
            }
            if self.streamingHighlightedAlpha >= 1 {
                self.streamingHighlightedSuffixLength = 0
                self.streamingChunkFadeTimer?.invalidate()
                self.streamingChunkFadeTimer = nil
                timer.invalidate()
            }
        }
        streamingChunkFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleTraceCardFallbackReveal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            guard self.currentDisplayKind == .trace, !self.isStreamingMode else { return }
            guard self.latestTraceEntities.isEmpty, !self.pendingTraceEntities.isEmpty else { return }
            guard self.pendingStreamingChunks.isEmpty else { return }
            self.publishPendingTraceEntitiesIfNeeded()
        }
    }

    private func publishPendingTraceEntitiesIfNeeded() {
        guard currentDisplayKind == .trace, !isStreamingMode else { return }
        guard !pendingTraceEntities.isEmpty else { return }
        guard isTraceCardRevealReady() else { return }
        latestTraceEntities = pendingTraceEntities
        renderedTraceCardCount = 0
        pendingTraceEntities = []
        diagnosticsLogger.log("trace.card", "publish count=\(latestTraceEntities.count)")
        pendingTraceCardEntranceIndex = nil
        traceCardRevealSequence += 1
        scheduleNextTraceCardReveal(sequence: traceCardRevealSequence, initialDelay: 0.06)
    }

    private func publishPendingActionCardsIfNeeded() {
        guard !isStreamingMode else { return }
        guard !pendingActionCards.isEmpty else { return }
        latestActionCards = pendingActionCards
        renderedActionCardCount = 0
        pendingActionCards = []
        diagnosticsLogger.log("action.card", "skill=\(currentResultSkillID ?? "unknown") publish count=\(latestActionCards.count)")
        pendingActionCardEntranceIndex = nil
        actionCardRevealSequence += 1
        scheduleNextActionCardReveal(sequence: actionCardRevealSequence, initialDelay: 0.06)
    }

    private func scheduleNextActionCardReveal(sequence: Int, initialDelay: TimeInterval = 0.34) {
        let limit = min(latestActionCards.count, 4)
        guard renderedActionCardCount < limit else {
            pendingActionCardEntranceIndex = nil
            diagnosticsLogger.log("action.card", "skill=\(currentResultSkillID ?? "unknown") complete count=\(renderedActionCardCount)")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            guard let self else { return }
            guard self.actionCardRevealSequence == sequence else { return }
            let limit = min(self.latestActionCards.count, 4)
            guard self.renderedActionCardCount < limit else {
                self.pendingActionCardEntranceIndex = nil
                return
            }
            self.pendingActionCardEntranceIndex = self.renderedActionCardCount
            self.renderedActionCardCount += 1
            self.diagnosticsLogger.log("action.card", "skill=\(self.currentResultSkillID ?? "unknown") reveal index=\(self.pendingActionCardEntranceIndex ?? -1)")
            let renderStartedAt = CFAbsoluteTimeGetCurrent()
            self.renderTranscript()
            if self.currentResultSkillID == "collect" {
                self.diagnosticsLogger.log(
                    "result.render",
                    "skill=collect stage=actionCardReveal.renderTranscript duration_ms=\(Self.millisecondsSince(renderStartedAt)) rows=\(self.transcriptStack.arrangedSubviews.count) renderedActionCards=\(self.renderedActionCardCount)"
                )
            }
            self.scheduleNextActionCardReveal(sequence: sequence)
        }
    }

    private func isTraceCardRevealReady() -> Bool {
        guard currentDisplayKind == .trace, !isStreamingMode else { return false }

        let target = normalizedStreamingText(streamingTargetText)
        if target.isEmpty {
            return true
        }

        guard let index = streamingAssistantIndex, messages.indices.contains(index) else { return false }
        let current = normalizedStreamingText(messages[index].text)
        return pendingStreamingChunks.isEmpty && current == target
    }

    private func scheduleNextTraceCardReveal(sequence: Int, initialDelay: TimeInterval = 0.34) {
        let limit = min(latestTraceEntities.count, 4)
        guard renderedTraceCardCount < limit else {
            pendingTraceCardEntranceIndex = nil
            diagnosticsLogger.log("trace.card", "complete count=\(renderedTraceCardCount)")
            setFooterVisible(!latestTraceEntities.isEmpty)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            guard let self else { return }
            guard self.traceCardRevealSequence == sequence else { return }
            let limit = min(self.latestTraceEntities.count, 4)
            guard self.renderedTraceCardCount < limit else {
                self.pendingTraceCardEntranceIndex = nil
                self.setFooterVisible(!self.latestTraceEntities.isEmpty)
                return
            }
            self.pendingTraceCardEntranceIndex = self.renderedTraceCardCount
            self.renderedTraceCardCount += 1
            self.diagnosticsLogger.log("trace.card", "reveal index=\(self.pendingTraceCardEntranceIndex ?? -1)")
            self.renderTranscript()
            self.scheduleNextTraceCardReveal(sequence: sequence)
        }
    }

    private func renderTranscript() {
        guard !defersTranscriptRendering else {
            pendingDeferredTranscriptRender = true
            return
        }

        clearArrangedSubviews(of: transcriptStack)
        latestSelectableMessageRow = nil
        streamingAssistantMessageRow = nil
        let animatingTraceCardIndex = pendingTraceCardEntranceIndex
        pendingTraceCardEntranceIndex = nil
        let animatingActionCardIndex = pendingActionCardEntranceIndex
        pendingActionCardEntranceIndex = nil

        let renderPlan = transcriptRenderer.makePlan(
            from: ResultTranscriptRenderInput(
                messages: messages.map {
                    ResultTranscriptMessage(
                        role: $0.role,
                        text: $0.text,
                        toolKey: $0.toolKey,
                        toolDetails: $0.toolDetails,
                        toolLabel: $0.toolLabel,
                        toolAnimatedDetail: $0.toolAnimatedDetail
                    )
                },
                isStreamingMode: isStreamingMode,
                activeToolStatusKey: activeToolStatusKey,
                streamingAssistantIndex: streamingAssistantIndex,
                streamingHighlightedSuffixLength: streamingHighlightedSuffixLength,
                streamingHighlightedAlpha: streamingHighlightedAlpha,
                latestTraceEntities: latestTraceEntities,
                renderedTraceCardCount: renderedTraceCardCount,
                animatingTraceCardIndex: animatingTraceCardIndex,
                latestActionCards: latestActionCards,
                renderedActionCardCount: renderedActionCardCount,
                animatingActionCardIndex: animatingActionCardIndex,
                currentDisplayKind: currentDisplayKind
            )
        )

        for row in renderPlan.rows {
            switch row {
            case .toolStatus(let status, let label, let details, let highlightedDetail, let isLoading, let isDone, let messageIndex):
                let view = ToolStatusRowView(
                    label: label,
                    status: status,
                    details: details,
                    highlightedDetail: highlightedDetail,
                    isLoading: isLoading,
                    isDone: isDone
                )
                addFullWidthRow(view)
                if messages.indices.contains(messageIndex) {
                    messages[messageIndex].toolAnimatedDetail = nil
                }
            case .chatMessage(let role, let text, let highlightedSuffixLength, let highlightedAlpha, let isSelectable, let messageIndex):
                let view = ChatMessageRowView(
                    role: role,
                    text: text,
                    highlightedSuffixLength: highlightedSuffixLength,
                    highlightedAlpha: highlightedAlpha
                )
                if isSelectable {
                    latestSelectableMessageRow = view
                }
                if messageIndex == streamingAssistantIndex {
                    streamingAssistantMessageRow = view
                }
                addFullWidthRow(view)
            case .sectionHeader(let title):
                addFullWidthRow(SectionHeaderView(title: title))
            case .traceCard(let entity, let isPrimary, let shouldAnimate):
                let card = TraceEntryCardView(entity: entity, isPrimary: isPrimary)
                if let url = URL(string: entity.url), !entity.url.isEmpty {
                    card.onOpen = { NSWorkspace.shared.open(url) }
                }
                addFullWidthRow(card)
                if shouldAnimate {
                    animateTraceCardEntrance(card)
                }
            case .actionCard(let cardData, let isPrimary, let shouldAnimate):
                let cardView = ActionCardView(card: cardData, isPrimary: isPrimary)
                cardView.onAction = { [weak self] in
                    self?.cardActionCoordinator.performAction(for: cardData)
                }
                addFullWidthRow(cardView)
                if shouldAnimate {
                    animateTraceCardEntrance(cardView)
                }
            }
        }

        updateTranscriptDocumentFrame()
        if renderPlan.shouldScrollToBottom {
            scrollTranscriptToBottom()
        } else {
            scrollTranscriptToTop()
        }
        syncFooterVisibility()
        autosizePanelForCurrentContentIfNeeded()
    }

    private func updateStreamingAssistantRowIfPossible() -> Bool {
        guard let index = streamingAssistantIndex,
              messages.indices.contains(index),
              let row = streamingAssistantMessageRow,
              row.superview != nil else {
            return false
        }

        row.update(
            role: messages[index].role,
            text: messages[index].text,
            highlightedSuffixLength: streamingHighlightedSuffixLength,
            highlightedAlpha: streamingHighlightedAlpha
        )
        updateTranscriptDocumentFrame()
        if currentDisplayKind == .trace || !latestActionCards.isEmpty {
            scrollTranscriptToBottom()
        } else {
            scrollTranscriptToTop()
        }
        syncFooterVisibility()
        autosizePanelForCurrentContentIfNeeded()
        return true
    }

    private func updateTranscriptDocumentFrame() {
        transcriptContentView.layoutSubtreeIfNeeded()
        let width = max(transcriptScrollView.contentView.bounds.width, 1)
        let height = max(transcriptStack.fittingSize.height, 1)
        transcriptContentView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        updateTranscriptScrollIndicator(showTemporarily: false)
    }

    private func addFullWidthRow(_ row: NSView) {
        row.translatesAutoresizingMaskIntoConstraints = false
        transcriptStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true
    }

    private func clearArrangedSubviews(of stack: NSStackView) {
        let views = stack.arrangedSubviews
        for view in views {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    @objc private func handleTranscriptScrollBoundsChanged(_ notification: Notification) {
        updateTranscriptScrollIndicator(showTemporarily: true)
    }

    private func updateTranscriptScrollIndicator(showTemporarily: Bool) {
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
        updateTranscriptScrollIndicator(showTemporarily: true)
    }

    private func scrollTranscriptToTop() {
        transcriptScrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        transcriptScrollView.reflectScrolledClipView(transcriptScrollView.contentView)
        updateTranscriptScrollIndicator(showTemporarily: true)
    }

    private func scrollTranscriptToBottom() {
        transcriptContentView.layoutSubtreeIfNeeded()
        let clipView = transcriptScrollView.contentView
        let maxY = max(0, transcriptContentView.frame.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: maxY))
        transcriptScrollView.reflectScrolledClipView(clipView)
        updateTranscriptScrollIndicator(showTemporarily: true)
    }

    private func totalTranscriptTextLength() -> Int {
        messages.reduce(0) { partialResult, message in
            partialResult + message.text.count
        }
    }

    private func logCollectStageDuration(skillID: String, stage: String, startedAt: CFAbsoluteTime) {
        guard skillID == "collect" else { return }
        diagnosticsLogger.log(
            "result.render",
            "skill=collect stage=\(stage) duration_ms=\(Self.millisecondsSince(startedAt))"
        )
    }

    private static func millisecondsSince(_ startedAt: CFAbsoluteTime) -> Int {
        Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())
    }

    private func animateTraceCardEntrance(_ view: NSView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let translationY: CGFloat = 16
        let duration: TimeInterval = 0.20
        let startTransform = CATransform3DMakeTranslation(0, translationY, 0)
        (view as? TraceEntryCardView)?.suppressHoverDuringEntrance(totalDuration: duration)
        view.wantsLayer = true
        view.alphaValue = 0.01
        view.layer?.transform = startTransform
        view.superview?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.layer?.shadowColor = NSColor.black.withAlphaComponent(0.28).cgColor
        view.layer?.shadowRadius = 18
        view.layer?.shadowOffset = CGSize(width: 0, height: 10)
        view.layer?.shadowPath = CGPath(
            roundedRect: view.bounds,
            cornerWidth: DesignTokens.Radius.md,
            cornerHeight: DesignTokens.Radius.md,
            transform: nil
        )
        view.layer?.shadowOpacity = 0
        DispatchQueue.main.async { [weak view] in
            guard let view, view.superview != nil else { return }
            if let layer = view.layer {
                let transformAnimation = CABasicAnimation(keyPath: "transform")
                transformAnimation.fromValue = startTransform
                transformAnimation.toValue = CATransform3DIdentity
                transformAnimation.duration = duration
                transformAnimation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                layer.transform = CATransform3DIdentity
                layer.add(transformAnimation, forKey: "traceEntranceTransform")

                let shadowAnimation = CABasicAnimation(keyPath: "shadowOpacity")
                shadowAnimation.fromValue = 0.18
                shadowAnimation.toValue = 0
                shadowAnimation.duration = duration
                shadowAnimation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                layer.shadowOpacity = 0
                layer.add(shadowAnimation, forKey: "traceEntranceShadow")
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                view.animator().alphaValue = 1
            }
        }
    }

    private func presentPanel(
        kind: DisplayKind,
        near rect: NSRect,
        preservePosition: Bool,
        transitionSourceFrame: NSRect?
    ) {
        let targetFrame = resolvedFrame(
            for: kind,
            near: rect,
            preservePosition: preservePosition,
            transitionSourceFrame: transitionSourceFrame
        )
        pendingEntranceAnimation = false
        let usesMorph = shouldUseMorphTransition(
            preservePosition: preservePosition,
            transitionSourceFrame: transitionSourceFrame
        )
        diagnosticsLogger.log(
            "result.transition",
            "presentPanel skill=\(currentDefinition?.skillID ?? "unknown") kind=\(String(describing: kind)) near=\(formatted(rect)) preserve=\(preservePosition) source=\(formatted(transitionSourceFrame)) target=\(formatted(targetFrame)) usesMorph=\(usesMorph)"
        )

        if usesMorph, let sourceFrame = transitionSourceFrame {
            pendingEntranceAnimation = true
            defersTranscriptRendering = true
            pendingMorphTargetFrame = targetFrame
            panelFrameAnimationTimer?.invalidate()
            panelFrameAnimationTimer = nil
            panel.minSize = NSSize(width: 1, height: 1)
            panel.maxSize = NSSize(width: 4096, height: 4096)
            panel.setFrame(sourceFrame, display: false)
            contentStack.alphaValue = 1
            panel.alphaValue = 1
            panel.hasShadow = true
            panelSurfaceView.alphaValue = 1
            panel.orderFrontRegardless()
            panel.displayIfNeeded()

            let duration: TimeInterval = 0.22
            animatePanelFrame(from: sourceFrame, to: targetFrame, duration: duration) { [weak self] in
                guard let self, self.pendingEntranceAnimation else { return }
                self.completeMorphTransition(to: targetFrame, kind: kind)
            }
            return
        }

        defersTranscriptRendering = false
        pendingDeferredTranscriptRender = false
        contentStack.alphaValue = 1
        panel.alphaValue = 1
        panel.hasShadow = true
        panelSurfaceView.alphaValue = 1
        panel.setFrame(targetFrame, display: true)
        presentInteractivePanel()
        transcriptHeightConstraint?.constant = transcriptMinHeight(for: kind, frameHeight: targetFrame.height)
        updateTranscriptDocumentFrame()
    }

    private func presentInteractivePanel() {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func animatePanelFrame(
        from sourceFrame: NSRect,
        to targetFrame: NSRect,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        panel.setFrame(sourceFrame, display: false)
        let startTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(max(elapsed / duration, 0), 1)
            let easedProgress = easeOutCubic(progress)
            let frame = interpolatedRect(from: sourceFrame, to: targetFrame, progress: easedProgress)
            self.panel.setFrame(frame, display: true)
            self.panel.displayIfNeeded()

            if progress >= 1 {
                timer.invalidate()
                self.panelFrameAnimationTimer = nil
                completion()
            }
        }

        panelFrameAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func shouldUseMorphTransition(
        preservePosition: Bool,
        transitionSourceFrame: NSRect?
    ) -> Bool {
        guard let transitionSourceFrame else { return false }
        guard !preservePosition else { return false }
        guard transitionSourceFrame.width > 0, transitionSourceFrame.height > 0 else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func completeMorphTransition(to targetFrame: NSRect, kind: DisplayKind) {
        defersTranscriptRendering = false
        let shouldRenderTranscript = pendingDeferredTranscriptRender
        pendingDeferredTranscriptRender = false
        let resolvedTargetFrame = pendingMorphTargetFrame ?? targetFrame
        pendingMorphTargetFrame = nil
        diagnosticsLogger.log(
            "result.transition",
            "completeMorph skill=\(currentDefinition?.skillID ?? "unknown") kind=\(String(describing: kind)) target=\(formatted(targetFrame)) resolvedTarget=\(formatted(resolvedTargetFrame)) panelFrameBefore=\(formatted(panel.frame))"
        )

        panelFrameAnimationTimer?.invalidate()
        panelFrameAnimationTimer = nil
        panel.setFrame(resolvedTargetFrame, display: false)
        panel.alphaValue = 1
        contentStack.alphaValue = 1
        transcriptHeightConstraint?.constant = transcriptMinHeight(for: kind, frameHeight: resolvedTargetFrame.height)
        panelSurfaceView.alphaValue = 1
        let bounds = sizeBounds(for: kind)
        panel.minSize = bounds.min
        panel.maxSize = bounds.max
        panel.orderFrontRegardless()

        if shouldRenderTranscript {
            renderTranscript()
        } else {
            updateTranscriptDocumentFrame()
        }

        panel.hasShadow = true
        presentInteractivePanel()
        pendingEntranceAnimation = false
        if let deferredUpdate = deferredMorphResultUpdate {
            deferredMorphResultUpdate = nil
            applyCompletedResultPresentation(
                deferredUpdate.presentation,
                skillID: deferredUpdate.skillID,
                showStartedAt: deferredUpdate.showStartedAt
            )
        }
        transcriptHeightConstraint?.constant = transcriptMinHeight(
            for: currentDisplayKind,
            frameHeight: panel.frame.height
        )
        updateTranscriptDocumentFrame()
        autosizePanelForCurrentContentIfNeeded()
    }

    private func resizePanel(kind: DisplayKind, near rect: NSRect, preservePosition: Bool = false) {
        currentDisplayKind = kind
        let frame = resolvedFrame(
            for: kind,
            near: rect,
            preservePosition: preservePosition,
            transitionSourceFrame: nil
        )
        diagnosticsLogger.log(
            "result.transition",
            "resizePanel skill=\(currentDefinition?.skillID ?? "unknown") kind=\(String(describing: kind)) near=\(formatted(rect)) preserve=\(preservePosition) resolved=\(formatted(frame)) panelFrameBefore=\(formatted(panel.frame))"
        )
        contentStack.alphaValue = 1
        panel.setFrame(frame, display: true)
        transcriptHeightConstraint?.constant = transcriptMinHeight(for: kind, frameHeight: frame.height)
        updateTranscriptDocumentFrame()
    }

    private func resolvedFrame(
        for kind: DisplayKind,
        near rect: NSRect,
        preservePosition: Bool,
        transitionSourceFrame: NSRect?
    ) -> NSRect {
        let width: CGFloat

        switch kind {
        case .translate, .trace, .explain, .reply, .schedule, .info:
            width = 400
        }

        transcriptContentView.layoutSubtreeIfNeeded()
        let bounds = sizeBounds(for: kind)
        let computedHeight: CGFloat
        if usesStablePanelHeight(for: kind), panel.isVisible {
            computedHeight = clamp(panel.frame.height, min: bounds.min.height, max: bounds.max.height)
        } else {
            computedHeight = preferredPanelHeight(for: kind)
        }

        panel.minSize = bounds.min
        panel.maxSize = bounds.max

        var frame = panel.frame
        let targetWidth = preservePosition && panel.isVisible ? panel.frame.width : width
        frame.size = NSSize(
            width: clamp(targetWidth, min: bounds.min.width, max: bounds.max.width),
            height: clamp(computedHeight, min: bounds.min.height, max: bounds.max.height)
        )

        if preservePosition && panel.isVisible {
            let oldFrame = panel.frame
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(oldFrame) }) ?? NSScreen.main
            let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = clamp(oldFrame.minX, min: visibleFrame.minX + 8, max: visibleFrame.maxX - frame.width - 8)
            let anchoredTopY = oldFrame.maxY - frame.height
            let y = clamp(anchoredTopY, min: visibleFrame.minY + 8, max: visibleFrame.maxY - frame.height - 8)
            frame.origin = NSPoint(x: x, y: y)
        } else if let transitionSourceFrame, transitionSourceFrame.width > 0, transitionSourceFrame.height > 0 {
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(transitionSourceFrame) }) ?? NSScreen.main
            let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = clamp(
                transitionSourceFrame.midX - frame.width / 2,
                min: visibleFrame.minX + 8,
                max: visibleFrame.maxX - frame.width - 8
            )
            let alignedTopY = transitionSourceFrame.maxY - frame.height
            let y = clamp(
                alignedTopY,
                min: visibleFrame.minY + 8,
                max: visibleFrame.maxY - frame.height - 8
            )
            frame.origin = NSPoint(x: x, y: y)
        } else {
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main
            let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let x = clamp(rect.midX - frame.width / 2, min: visibleFrame.minX + 8, max: visibleFrame.maxX - frame.width - 8)
            var y = rect.minY - frame.height - 8
            if y < visibleFrame.minY + 8 {
                y = rect.maxY + 8
            }
            y = clamp(y, min: visibleFrame.minY + 8, max: visibleFrame.maxY - frame.height - 8)
            frame.origin = NSPoint(x: x, y: y)
        }

        return frame
    }

    private func sizeBounds(for kind: DisplayKind) -> (min: NSSize, max: NSSize) {
        switch kind {
        case .translate, .trace, .explain, .reply, .schedule, .info:
            return (
                min: NSSize(width: 400, height: 240),
                max: NSSize(width: 960, height: 480)
            )
        }
    }

    private func handleCopyAction() {
        let contentToCopy = selectedPanelText()
            ?? (!latestTextToCopy.isEmpty ? latestTextToCopy : formatConversationForCopy())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contentToCopy, forType: .string)
    }

    private func handleSelectAllAction() -> Bool {
        if let textView = panel.firstResponder as? NSTextView {
            textView.selectAll(nil)
            return true
        }

        if let row = latestSelectableMessageRow {
            row.selectAllText()
            return true
        }

        return false
    }

    private func handlePanelKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }

        switch key {
        case "a":
            return handleSelectAllAction()
        case "c":
            if let textView = panel.firstResponder as? NSTextView,
               textView.selectedRange().length > 0 {
                textView.copy(nil)
            } else {
                handleCopyAction()
            }
            return true
        default:
            return false
        }
    }

    private func selectedPanelText() -> String? {
        guard let textView = panel.firstResponder as? NSTextView else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0,
              let substringRange = Range(range, in: textView.string) else {
            return nil
        }
        let selectedText = String(textView.string[substringRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return selectedText.isEmpty ? nil : selectedText
    }

    private func resolvedFooterSourceText() -> String? {
        let candidate = selectedPanelText()
            ?? latestTextToCopy.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private func formatConversationForCopy() -> String {
        var lines: [String] = []
        for message in messages {
            let prefix: String
            switch message.role {
            case .user: prefix = L10n.text(zhHans: "你", en: "You")
            case .assistant: prefix = AppBrand.displayName
            case .tool: prefix = L10n.text(zhHans: "工具调用", en: "Tool")
            case .info: prefix = L10n.text(zhHans: "系统", en: "System")
            }
            lines.append("[\(prefix)] \(message.text)")
        }
        if !latestTraceEntities.isEmpty {
            lines.append("")
            lines.append(L10n.text(zhHans: "推荐入口：", en: "Recommended sources:"))
            for (index, entity) in latestTraceEntities.enumerated() {
                lines.append("\(index + 1). \(entity.name)\n\(entity.url)")
            }
        }
        return lines.joined(separator: "\n")
    }

    @objc private func handleFooterButtonClick(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let kind = ResultFooterActionKind(rawValue: rawValue) else {
            return
        }
        diagnosticsLogger.log("result.footer", "tap action=\(kind.rawValue) skill=\(currentDefinition?.skillID ?? String(describing: currentDisplayKind))")
        footerActionCoordinator.performFooterAction(
            kind,
            followupSkillID: (sender as? FooterActionButton)?.followupSkillID,
            followupInputSource: (sender as? FooterActionButton)?.followupInputSource,
            followupMaxDepth: (sender as? FooterActionButton)?.followupMaxDepth,
            followupSourceSkillID: (sender as? FooterActionButton)?.followupSourceSkillID
        )
    }

    private func footerActionPolicyDecision(for kind: ResultFooterActionKind) -> ResultActionPolicyDecision {
        ActionImpactPolicy.decision(
            forFooterAction: footerActionSemantic(for: kind),
            definition: currentDefinition,
            supportsWritebackToSource: supportsWritebackForCurrentSource()
        )
    }

    private func footerActionSemantic(for kind: ResultFooterActionKind) -> ResultActionSemantic {
        switch kind {
        case .regenerate:
            return .regenerate
        case .copy:
            return .copy
        case .translate:
            return .translateShortcut
        case .explain:
            return .explainShortcut
        case .followup:
            return .followup
        case .replace:
            return .replaceSelection
        case .writeInput:
            return .writeInput
        case .openPrimary:
            return .openPrimary
        case .capabilityAction:
            return .copy
        }
    }

    private func refocusSourceApplication(bundleID: String?) {
        guard let bundleID,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    @objc private func handleTogglePin() {
        isPinned.toggle()
        panel.level = isPinned ? .statusBar : .floating
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: "pin")
    }

    func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        transcriptHeightConstraint?.constant = transcriptMinHeight(for: currentDisplayKind, frameHeight: panel.frame.height)
        updateTranscriptDocumentFrame()
        if isStreamingMode {
            startLoadingLineFlow()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
    }

    private func transcriptMinHeight(for kind: DisplayKind, frameHeight: CGFloat) -> CGFloat {
        switch kind {
        case .translate, .trace, .explain, .reply, .schedule, .info:
            return max(48, frameHeight - 112)
        }
    }

    private func preferredPanelHeight(for kind: DisplayKind) -> CGFloat {
        let bounds = sizeBounds(for: kind)
        let estimatedContentHeight = max(36, transcriptStack.fittingSize.height)
        let baseChrome: CGFloat = 98
        let stableMinimumHeight: CGFloat
        switch kind {
        case .trace:
            stableMinimumHeight = 320
        case .translate, .explain, .reply, .schedule, .info:
            stableMinimumHeight = bounds.min.height
        }
        return min(max(stableMinimumHeight, estimatedContentHeight + baseChrome), bounds.max.height)
    }

    private func autosizePanelForCurrentContentIfNeeded() {
        guard panel.isVisible else { return }
        guard !pendingEntranceAnimation else { return }
        guard !usesStablePanelHeight(for: currentDisplayKind) else { return }

        let bounds = sizeBounds(for: currentDisplayKind)
        let targetHeight = clamp(preferredPanelHeight(for: currentDisplayKind), min: bounds.min.height, max: bounds.max.height)
        let currentHeight = panel.frame.height
        guard abs(currentHeight - targetHeight) > 1 else { return }

        var frame = panel.frame
        frame.origin.y += currentHeight - targetHeight
        frame.size.height = targetHeight
        frame.size.width = clamp(frame.size.width, min: bounds.min.width, max: bounds.max.width)
        panel.setFrame(frame, display: true)
        transcriptHeightConstraint?.constant = transcriptMinHeight(for: currentDisplayKind, frameHeight: frame.height)
        updateTranscriptDocumentFrame()
    }

    private func usesStablePanelHeight(for kind: DisplayKind) -> Bool {
        if currentDefinition?.skillID == "collect" {
            return true
        }
        switch kind {
        case .trace:
            return true
        case .translate, .explain, .reply, .schedule, .info:
            return false
        }
    }

    private func localizedStatusText(_ status: String) -> String {
        switch status {
        case "loading":
            return L10n.text(zhHans: "正在加载中", en: "Loading")
        case "thinking":
            return L10n.text(zhHans: "正在思考中", en: "Thinking")
        case "connecting":
            return L10n.text(zhHans: "正在连接模型", en: "Connecting to model")
        case "research":
            return L10n.text(zhHans: "正在搜索候选来源", en: "Searching candidate sources")
        case "semantic_decomposition":
            return L10n.text(zhHans: "正在拆解语义", en: "Decomposing intent")
        case "entity_analysis":
            return L10n.text(zhHans: "正在分析目标", en: "Analyzing target")
        case "search_enhancement":
            return L10n.text(zhHans: "正在检索与增强", en: "Searching and enriching")
        case "candidate_resolution":
            return L10n.text(zhHans: "正在判定入口", en: "Resolving best entry")
        case "result_generation":
            return L10n.text(zhHans: "正在整理回答", en: "Composing answer")
        case "model_streaming":
            return L10n.text(zhHans: "模型流式输出中", en: "Streaming model output")
        case "preparing":
            return L10n.text(zhHans: "正在准备处理中", en: "Preparing")
        case "compressing":
            return L10n.text(zhHans: "正在压缩文件", en: "Compressing files")
        case "collect_prepare":
            return L10n.text(zhHans: "正在准备采集", en: "Preparing collection")
        case "collect_pipeline":
            return L10n.text(zhHans: "正在尝试采集通道", en: "Trying capture paths")
        case "collect_finalize":
            return L10n.text(zhHans: "正在写入知识库", en: "Writing to knowledge base")
        case "fallback":
            return L10n.text(zhHans: "使用降级路径", en: "Using fallback path")
        default:
            return status
        }
    }

    private func formatted(_ rect: NSRect?) -> String {
        guard let rect else { return "nil" }
        return String(
            format: "(x:%.1f y:%.1f w:%.1f h:%.1f)",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    private func localizedStatusDetail(_ status: String?) -> String? {
        guard let status else { return nil }
        switch status {
        case "loading":
            return L10n.text(zhHans: "正在准备结果视图并等待处理完成。", en: "Preparing the result view and waiting for processing to finish.")
        case "thinking":
            return nil
        case "connecting":
            return L10n.text(zhHans: "正在连接 AI 服务并准备生成结果。", en: "Connecting to the AI service and preparing the result.")
        case "research":
            return L10n.text(zhHans: "正在搜索公开候选来源，并准备比较最相关的入口。", en: "Searching public candidate sources and preparing to compare the best entry points.")
        case "semantic_decomposition":
            return L10n.text(zhHans: "解析原文结构，识别事件、实体和它们之间的关系。", en: "Parsing the source text structure and identifying entities, events, and their relationships.")
        case "entity_analysis":
            return L10n.text(zhHans: "判断用户最可能想打开的主目标，并区分相关实体。", en: "Determining the most likely primary target to open and separating related entities.")
        case "search_enhancement":
            return L10n.text(zhHans: "基于主目标、属主线索和别名生成搜索计划并收集候选。", en: "Building a search plan from the main target, ownership clues, and aliases, then collecting candidates.")
        case "candidate_resolution":
            return L10n.text(zhHans: "正在比较候选入口，排除新闻页、导航页和无关同名站点。", en: "Comparing candidate entries and filtering out news pages, directory pages, and irrelevant namesakes.")
        case "result_generation":
            return L10n.text(zhHans: "对候选入口做最终判定，并整理成可直接打开的结果。", en: "Making the final source decision and packaging it into something you can open directly.")
        case "model_streaming":
            return L10n.text(zhHans: "模型正在持续输出总结文本。", en: "The model is still streaming the summary.")
        case "preparing":
            return L10n.text(zhHans: "正在读取选中的文件与文件夹，并建立处理计划。", en: "Reading the selected files and folders and preparing the execution plan.")
        case "compressing":
            return L10n.text(zhHans: "正在调用对应工具处理可压缩文件。", en: "Running the appropriate tools on compressible files.")
        case "collect_prepare":
            return L10n.text(zhHans: "开始检查当前链接可以走哪条采集链路。", en: "Checking which capture path is available for the current URL.")
        case "collect_pipeline":
            return L10n.text(zhHans: "按顺序尝试网页采集通道，并保留可读正文。", en: "Trying the URL capture paths in order and retaining readable content.")
        case "collect_finalize":
            return L10n.text(zhHans: "正在生成知识条目、切分内容并写入索引。", en: "Creating the knowledge entry, chunking content, and writing the index.")
        case "fallback":
            return L10n.text(zhHans: "模型链路不可用，已切换到降级检索与规则判定。", en: "The model path is unavailable, so NexHub switched to fallback retrieval and rule-based resolution.")
        default:
            return nil
        }
    }

    private func toolLabel(for status: String) -> String? {
        switch status {
        case "search_enhancement", "candidate_resolution", "result_generation":
            return L10n.text(zhHans: "工具调用", en: "Tool")
        case "collect_prepare", "collect_pipeline", "collect_finalize":
            return L10n.text(zhHans: "采集链路", en: "Capture path")
        default:
            return nil
        }
    }
}

private enum TranscriptTextStyle {
    static let bodyLineHeightMultiple: CGFloat = 1.5
    static let metaLineHeightMultiple: CGFloat = 1.5

    static func attributedString(
        _ text: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        lineHeightMultiple: CGFloat = bodyLineHeightMultiple,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = lineBreakMode
        paragraphStyle.lineSpacing = lineSpacing(for: font, multiple: lineHeightMultiple)
        paragraphStyle.paragraphSpacing = 0
        paragraphStyle.paragraphSpacingBefore = 0
        if #available(macOS 11.0, *) {
            paragraphStyle.lineBreakStrategy = [.pushOut]
        }

        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    static func lineSpacing(for font: NSFont, multiple: CGFloat) -> CGFloat {
        guard multiple > 1 else { return 0 }
        return round(font.pointSize * (multiple - 1))
    }

    static func makeSelectableLabel(
        attributedString: NSAttributedString,
        lineBreakMode: NSLineBreakMode,
        maximumNumberOfLines: Int
    ) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: attributedString)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.allowsEditingTextAttributes = true
        label.isSelectable = true
        label.lineBreakMode = lineBreakMode
        label.maximumNumberOfLines = maximumNumberOfLines
        label.usesSingleLineMode = maximumNumberOfLines == 1
        label.backgroundColor = .clear
        return label
    }
}

private final class ChatMessageRowView: NSView {
    private let bodyLabel: NSTextField

    init(
        role: ResultPanelController.MessageRole,
        text: String,
        highlightedSuffixLength: Int = 0,
        highlightedAlpha: CGFloat = 1
    ) {
        let bodyAttributedText: NSAttributedString
        if role == .assistant {
            bodyAttributedText = Self.makeAssistantAttributedText(
                text: text,
                highlightedSuffixLength: highlightedSuffixLength,
                highlightedAlpha: highlightedAlpha
            )
        } else {
            bodyAttributedText = TranscriptTextStyle.attributedString(
                text,
                font: DesignTokens.Typography.resultPanelBody,
                color: DesignTokens.Color.textPrimary
            )
        }
        let bodyLabel = TranscriptTextStyle.makeSelectableLabel(
            attributedString: bodyAttributedText,
            lineBreakMode: .byWordWrapping,
            maximumNumberOfLines: 0
        )
        self.bodyLabel = bodyLabel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack: NSStackView
        if role == .assistant {
            stack = NSStackView(views: [bodyLabel])
        } else {
            let roleLabel = TranscriptTextStyle.makeSelectableLabel(
                attributedString: TranscriptTextStyle.attributedString(
                    Self.roleTitle(role),
                    font: DesignTokens.Typography.resultPanelRole,
                    color: Self.roleColor(role),
                    alignment: .left,
                    lineHeightMultiple: TranscriptTextStyle.metaLineHeightMultiple,
                    lineBreakMode: .byTruncatingTail
                ),
                lineBreakMode: .byTruncatingTail,
                maximumNumberOfLines: 1
            )
            stack = NSStackView(views: [roleLabel, bodyLabel])
        }
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = NSLayoutConstraint.Attribute.leading
        stack.spacing = DesignTokens.ResultPanel.messageRoleSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func selectAllText() {
        bodyLabel.selectText(nil)
    }

    func update(
        role: ResultPanelController.MessageRole,
        text: String,
        highlightedSuffixLength: Int = 0,
        highlightedAlpha: CGFloat = 1
    ) {
        if role == .assistant {
            bodyLabel.attributedStringValue = Self.makeAssistantAttributedText(
                text: text,
                highlightedSuffixLength: highlightedSuffixLength,
                highlightedAlpha: highlightedAlpha
            )
        } else {
            bodyLabel.attributedStringValue = TranscriptTextStyle.attributedString(
                text,
                font: DesignTokens.Typography.resultPanelBody,
                color: DesignTokens.Color.textPrimary
            )
        }
    }

    private static func roleTitle(_ role: ResultPanelController.MessageRole) -> String {
        switch role {
        case .user: return L10n.text(zhHans: "你", en: "You")
        case .assistant: return AppBrand.displayName
        case .tool: return L10n.text(zhHans: "工具调用", en: "Tool")
        case .info: return L10n.text(zhHans: "系统", en: "System")
        }
    }

    private static func roleColor(_ role: ResultPanelController.MessageRole) -> NSColor {
        switch role {
        case .user:
            return DesignTokens.Semantic.ResultPanel.Role.userText
        case .assistant:
            return DesignTokens.Semantic.ResultPanel.Role.assistantText
        case .tool:
            return DesignTokens.Semantic.ResultPanel.Role.toolText
        case .info:
            return DesignTokens.Semantic.ResultPanel.Role.systemText
        }
    }

    private static func makeAssistantAttributedText(
        text: String,
        highlightedSuffixLength: Int,
        highlightedAlpha: CGFloat
    ) -> NSAttributedString {
        if highlightedSuffixLength > 0 {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            style.lineSpacing = 4
            style.paragraphSpacing = 12
            let output = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: DesignTokens.Typography.resultPanelBody,
                    .foregroundColor: DesignTokens.Color.textPrimary,
                    .paragraphStyle: style
                ]
            )
            let suffixLength = min(max(0, highlightedSuffixLength), output.length)
            if suffixLength > 0 {
                let suffixRange = NSRange(location: output.length - suffixLength, length: suffixLength)
                output.addAttribute(
                    .foregroundColor,
                    value: DesignTokens.Color.textPrimary.withAlphaComponent(highlightedAlpha),
                    range: suffixRange
                )
            }
            return output
        }

        return ResultMarkdownRenderer.assistantAttributedText(
            text: text,
            highlightedSuffixLength: highlightedSuffixLength,
            highlightedAlpha: highlightedAlpha
        )
    }
}

private final class ToolStatusRowView: NSView {
    init(label: String?, status: String, details: [String], highlightedDetail: String?, isLoading: Bool, isDone: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = ShimmeringStatusLabel(
            text: status,
            isShimmering: isLoading,
            baseColor: isDone
                ? DesignTokens.Color.textSecondary.withAlphaComponent(0.92)
                : DesignTokens.Color.textTertiary.withAlphaComponent(0.68)
        )
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = DesignTokens.ResultPanel.ToolStatus.titleSpacing
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addArrangedSubview(statusLabel)

        if let label, !label.isEmpty {
            let badgeHost = ToolStatusBadgeView(title: label)
            badgeHost.setContentHuggingPriority(.required, for: .horizontal)
            badgeHost.setContentCompressionResistancePriority(.required, for: .horizontal)
            let badgeContainer = ToolStatusBadgeOffsetView(contentView: badgeHost)
            badgeContainer.setContentHuggingPriority(.required, for: .horizontal)
            badgeContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(badgeContainer)
        }

        titleRow.addArrangedSubview(NSView())

        let bodyStack = NSStackView()
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = DesignTokens.ResultPanel.ToolStatus.detailSpacing
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.addArrangedSubview(titleRow)

        for detail in details where !detail.isEmpty {
            let detailLabel = TranscriptTextStyle.makeSelectableLabel(
                attributedString: TranscriptTextStyle.attributedString(
                    detail,
                    font: DesignTokens.Typography.resultPanelDetailMono,
                    color: DesignTokens.ResultPanel.ToolStatus.detailTextColor,
                    alignment: .left,
                    lineHeightMultiple: TranscriptTextStyle.metaLineHeightMultiple,
                    lineBreakMode: .byWordWrapping
                ),
                lineBreakMode: .byWordWrapping,
                maximumNumberOfLines: 2
            )
            detailLabel.alphaValue = highlightedDetail == detail ? 0 : 1
            bodyStack.addArrangedSubview(detailLabel)

            if highlightedDetail == detail, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.32
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    detailLabel.animator().alphaValue = 1
                }
            } else {
                detailLabel.alphaValue = 1
            }
        }

        addSubview(bodyStack)
        NSLayoutConstraint.activate([
            bodyStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyStack.topAnchor.constraint(equalTo: topAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont]
        let labelWidth = ceil((title as NSString).size(withAttributes: attributes).width)
        return NSSize(
            width: labelWidth + (DesignTokens.ResultPanel.Badge.horizontalPadding * 2),
            height: DesignTokens.ResultPanel.Badge.height
        )
    }
}

private final class ToolStatusBadgeOffsetView: NSView {
    private let contentView: NSView

    init(contentView: NSView) {
        self.contentView = contentView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -DesignTokens.ResultPanel.Badge.baselineOffset
            ),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class SectionHeaderView: NSView {
    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = TranscriptTextStyle.makeSelectableLabel(
            attributedString: TranscriptTextStyle.attributedString(
                title,
                font: DesignTokens.Typography.resultPanelSectionHeader,
                color: DesignTokens.Color.textSecondary,
                alignment: .left,
                lineHeightMultiple: TranscriptTextStyle.metaLineHeightMultiple,
                lineBreakMode: .byTruncatingTail
            ),
            lineBreakMode: .byTruncatingTail,
            maximumNumberOfLines: 1
        )

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ActionCardView: NSView {
    var onAction: (() -> Void)?
    private let isPrimary: Bool
    private var trackingAreaRef: NSTrackingArea?
    private var hover = false
    private var suppressHoverUntil = Date.distantPast

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

        let actionArrow = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "action") ?? NSImage())
        actionArrow.contentTintColor = DesignTokens.ResultPanel.ActionCard.actionTint
        actionArrow.symbolConfiguration = .init(pointSize: DesignTokens.ResultPanel.ActionCard.arrowPointSize, weight: .semibold)
        actionArrow.translatesAutoresizingMaskIntoConstraints = false
        actionArrow.widthAnchor.constraint(equalToConstant: DesignTokens.ResultPanel.ActionCard.arrowDimension).isActive = true
        actionArrow.heightAnchor.constraint(equalToConstant: DesignTokens.ResultPanel.ActionCard.arrowDimension).isActive = true
        actionArrow.isHidden = !hasAction

        let titleRow = NSStackView(views: [titleLabel, NSView(), actionArrow])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = DesignTokens.ResultPanel.ActionCard.titleRowSpacing

        var stackViews: [NSView] = [titleRow]
        if !(card.subtitle?.isEmpty ?? true) {
            stackViews.append(subtitleLabel)
        }
        if !(card.badges?.isEmpty ?? true) {
            stackViews.append(badgesLabel)
        }
        if !(card.description?.isEmpty ?? true) {
            stackViews.append(descriptionLabel)
        }

        let stack = NSStackView(views: stackViews)
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
        guard Date() >= suppressHoverUntil else { return }
        hover = true
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard Date() >= suppressHoverUntil else { return }
        hover = false
        updateAppearance(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard !bounds.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        guard onAction != nil else { return }
        onAction?()
    }

    func suppressHoverDuringEntrance(totalDuration: TimeInterval) {
        suppressHoverUntil = Date().addingTimeInterval(totalDuration)
        hover = false
        updateAppearance(animated: false)
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

private final class TraceEntryCardView: NSView {
    var onOpen: (() -> Void)?
    private let isPrimary: Bool
    private var trackingAreaRef: NSTrackingArea?
    private var hover = false
    private var suppressHoverUntil = Date.distantPast

    init(entity: TraceEntity, isPrimary: Bool) {
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.ResultPanel.TraceCard.cornerRadius
        translatesAutoresizingMaskIntoConstraints = false
        updateAppearance(animated: false)

        let icon = NSImageView(image: NSImage(systemSymbolName: "globe", accessibilityDescription: "link") ?? NSImage())
        icon.contentTintColor = isPrimary
            ? DesignTokens.Semantic.ResultPanel.TraceCard.primaryIconText
            : DesignTokens.Color.iconPrimary
        icon.symbolConfiguration = .init(pointSize: DesignTokens.ResultPanel.TraceCard.iconPointSize, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: DesignTokens.ResultPanel.TraceCard.iconDimension).isActive = true
        icon.heightAnchor.constraint(equalToConstant: DesignTokens.ResultPanel.TraceCard.iconDimension).isActive = true

        let nameLabel = NSTextField(labelWithString: entity.name)
        nameLabel.font = DesignTokens.Typography.resultPanelCardTitle
        nameLabel.textColor = DesignTokens.Color.textPrimary
        nameLabel.lineBreakMode = .byTruncatingTail

        let urlLabel = NSTextField(labelWithString: entity.url)
        urlLabel.font = DesignTokens.Typography.resultPanelCardURL
        urlLabel.textColor = DesignTokens.Color.textSecondary
        urlLabel.lineBreakMode = .byTruncatingMiddle

        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription: "open") ?? NSImage())
        arrow.contentTintColor = DesignTokens.Color.textSecondary.withAlphaComponent(0.9)
        arrow.symbolConfiguration = .init(pointSize: DesignTokens.ResultPanel.TraceCard.arrowPointSize, weight: .semibold)
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.widthAnchor.constraint(equalToConstant: DesignTokens.ResultPanel.TraceCard.arrowDimension).isActive = true
        arrow.heightAnchor.constraint(equalToConstant: DesignTokens.ResultPanel.TraceCard.arrowDimension).isActive = true
        arrow.isHidden = entity.url.isEmpty

        let badges = NSStackView()
        badges.orientation = .horizontal
        badges.alignment = .centerY
        badges.spacing = DesignTokens.ResultPanel.TraceCard.badgeSpacing
        if isPrimary {
            badges.addArrangedSubview(Self.makeBadge(title: L10n.text(zhHans: "主源头", en: "Primary"), emphasis: true))
        }
        if entity.isOfficial == true {
            badges.addArrangedSubview(Self.makeBadge(title: L10n.text(zhHans: "官方", en: "Official"), emphasis: false))
        }

        let titleMetaRow = NSStackView(views: [nameLabel])
        titleMetaRow.orientation = .horizontal
        titleMetaRow.alignment = .centerY
        titleMetaRow.spacing = DesignTokens.ResultPanel.TraceCard.titleMetaSpacing
        if !badges.arrangedSubviews.isEmpty {
            titleMetaRow.addArrangedSubview(badges)
        }
        titleMetaRow.addArrangedSubview(NSView())

        let titleRow = NSStackView(views: [icon, titleMetaRow, arrow])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = DesignTokens.ResultPanel.TraceCard.titleRowSpacing

        let stack = NSStackView(views: [titleRow, urlLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.ResultPanel.TraceCard.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.ResultPanel.TraceCard.contentInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.ResultPanel.TraceCard.contentInset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.ResultPanel.TraceCard.contentInset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.ResultPanel.TraceCard.contentInset),
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
        guard onOpen != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard Date() >= suppressHoverUntil else { return }
        hover = true
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard Date() >= suppressHoverUntil else { return }
        hover = false
        updateAppearance(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard !bounds.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onOpen?()
    }

    @objc private func handleOpen() {
        onOpen?()
    }

    func suppressHoverDuringEntrance(totalDuration: TimeInterval) {
        suppressHoverUntil = Date().addingTimeInterval(totalDuration)
        hover = false
        updateAppearance(animated: false)
    }

    private func updateAppearance(animated: Bool) {
        let palette: DesignTokens.Semantic.SurfacePair
        if isPrimary {
            palette = hover
                ? DesignTokens.Semantic.ResultPanel.TraceCard.primaryHover
                : DesignTokens.Semantic.ResultPanel.TraceCard.primaryRest
        } else {
            palette = hover
                ? DesignTokens.Semantic.ResultPanel.TraceCard.secondaryHover
                : DesignTokens.Semantic.ResultPanel.TraceCard.secondaryRest
        }

        let apply = {
            self.layer?.backgroundColor = palette.fill.cgColor
            self.layer?.borderWidth = DesignTokens.ResultPanel.TraceCard.borderWidth
            self.layer?.borderColor = palette.border.cgColor
        }

        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            apply()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.ResultPanel.TraceCard.hoverAnimationDuration
            self.animator().alphaValue = 1
            apply()
        }
    }

    private static func makeBadge(title: String, emphasis: Bool) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = DesignTokens.Typography.resultPanelBadge
        let appearance = emphasis
            ? DesignTokens.Semantic.ResultPanel.TraceCard.emphasisBadge
            : DesignTokens.Semantic.ResultPanel.TraceCard.neutralBadge
        label.textColor = appearance.text

        let host = NSView()
        host.wantsLayer = true
        host.layer?.cornerRadius = DesignTokens.ResultPanel.TraceCard.Badge.cornerRadius
        host.layer?.backgroundColor = appearance.fill.cgColor
        host.layer?.borderWidth = DesignTokens.ResultPanel.TraceCard.Badge.borderWidth
        host.layer?.borderColor = appearance.border.cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: DesignTokens.ResultPanel.TraceCard.Badge.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -DesignTokens.ResultPanel.TraceCard.Badge.horizontalPadding),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: DesignTokens.ResultPanel.TraceCard.Badge.verticalPadding),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -DesignTokens.ResultPanel.TraceCard.Badge.verticalPadding),
        ])
        return host
    }
}

private final class FooterActionButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    var followupSkillID: String?
    var followupInputSource: SkillFollowupInputSource?
    var followupMaxDepth: Int?
    var followupSourceSkillID: String?
    private var hovering = false {
        didSet { updateHoverVisual(animated: true) }
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
        cell = FooterPaddedButtonCell(horizontalPadding: DesignTokens.ResultPanel.Footer.horizontalPadding)
        wantsLayer = true
        isBordered = false
        bezelStyle = .recessed
        focusRingType = .none
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryPushIn)
        layer?.cornerRadius = DesignTokens.ResultPanel.Footer.cornerRadius
        layer?.masksToBounds = true
        updateHoverVisual(animated: false)
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(
            width: max(base.width, DesignTokens.ResultPanel.Footer.minHeight),
            height: max(base.height, DesignTokens.ResultPanel.Footer.minHeight)
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
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
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
    }

    private func updateHoverVisual(animated: Bool) {
        let apply = {
            self.alphaValue = self.isEnabled ? 1 : DesignTokens.ResultPanel.Footer.disabledAlpha
            self.layer?.backgroundColor = (self.isEnabled && self.hovering)
                ? DesignTokens.ResultPanel.Footer.hoverFill.cgColor
                : NSColor.clear.cgColor
        }
        guard animated else {
            apply()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.Motion.fast
            self.animator().alphaValue = self.isEnabled ? 1 : DesignTokens.ResultPanel.Footer.disabledAlpha
            apply()
        }
    }
}

private final class FooterPaddedButtonCell: NSButtonCell {
    private let horizontalPadding: CGFloat

    init(horizontalPadding: CGFloat) {
        self.horizontalPadding = horizontalPadding
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        self.horizontalPadding = DesignTokens.ResultPanel.Footer.horizontalPadding
        super.init(coder: coder)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect).insetBy(dx: horizontalPadding, dy: 0)
    }
}

private final class ChatPanel: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
    override var drawsBackground: Bool {
        get { false }
        set { _ = newValue }
    }
}

private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    Swift.max(minValue, Swift.min(maxValue, value))
}

private func easeOutCubic(_ progress: Double) -> Double {
    let clamped = min(max(progress, 0), 1)
    return 1 - pow(1 - clamped, 3)
}

private func interpolatedRect(from source: NSRect, to target: NSRect, progress: Double) -> NSRect {
    let t = CGFloat(progress)
    let origin = NSPoint(
        x: source.origin.x + (target.origin.x - source.origin.x) * t,
        y: source.origin.y + (target.origin.y - source.origin.y) * t
    )
    let size = NSSize(
        width: source.size.width + (target.size.width - source.size.width) * t,
        height: source.size.height + (target.size.height - source.size.height) * t
    )
    return NSRect(origin: origin, size: size)
}
