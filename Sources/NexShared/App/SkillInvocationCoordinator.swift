import AppKit
import Foundation

struct SkillInvocationSnapshotState {
    let textSnapshot: SelectionSnapshot?
    let fileSnapshot: FileSelectionSnapshot?
    let imageSnapshot: ImageSelectionSnapshot?
}

protocol SkillInvocationCoordinatorDelegate: AnyObject {
    func skillInvocationSnapshotState(_ coordinator: SkillInvocationCoordinator) -> SkillInvocationSnapshotState
    func skillInvocationSetScreenshotSelectionActive(_ coordinator: SkillInvocationCoordinator, active: Bool)
    func skillInvocationDismissLockedSelection(_ coordinator: SkillInvocationCoordinator)
    func skillInvocationDismissLockedScreenshotSession(_ coordinator: SkillInvocationCoordinator, clearImageSnapshot: Bool)
    func skillInvocationShowTransientPrompt(
        _ coordinator: SkillInvocationCoordinator,
        message: String,
        near anchor: NSRect,
        actionTitle: String?,
        actionHandler: (() -> Void)?,
        autoHideAfter: TimeInterval?
    )
    func skillInvocationShowActionDisabledPrompt(
        _ coordinator: SkillInvocationCoordinator,
        definition: SkillDefinition,
        near anchor: NSRect
    )
    func skillInvocationShowPermissionPrompt(_ coordinator: SkillInvocationCoordinator, near anchor: NSRect)
    func skillInvocationShowMissingAIConfigPrompt(_ coordinator: SkillInvocationCoordinator, near anchor: NSRect)
    func skillInvocationShowGatewayRuntimePrompt(
        _ coordinator: SkillInvocationCoordinator,
        snapshot: GatewayRuntimeSnapshot,
        near anchor: NSRect
    )
    func skillInvocationShowEntitlementPrompt(_ coordinator: SkillInvocationCoordinator, definition: SkillDefinition, near anchor: NSRect)
    func skillInvocationShowRequestFailurePrompt(_ coordinator: SkillInvocationCoordinator, error: Error, near anchor: NSRect)
}

final class SkillInvocationCoordinator {
    weak var delegate: SkillInvocationCoordinatorDelegate?

    private let toolbarController: FloatingToolbarController
    private let resultController: ResultPanelController
    private let actionRegistry: ActionRegistry
    private let skillRunner: SkillRunner
    private let screenshotSkillBridge: ScreenshotSkillBridge
    private let commerceService: CommerceService
    private let settings: AppSettings
    private let permissionManager: PermissionManager
    private let diagnosticsLogger: DiagnosticsLogger

    private(set) var lastExecutedSkillID: String = "trace"
    private var isActionRunning = false
    private var currentActionID: UUID?
    private var currentActionTask: Task<Void, Never>?

    init(
        toolbarController: FloatingToolbarController,
        resultController: ResultPanelController,
        actionRegistry: ActionRegistry = .shared,
        skillRunner: SkillRunner = SkillRunner(),
        screenshotSkillBridge: ScreenshotSkillBridge,
        commerceService: CommerceService = .shared,
        settings: AppSettings = .shared,
        permissionManager: PermissionManager,
        diagnosticsLogger: DiagnosticsLogger = .shared
    ) {
        self.toolbarController = toolbarController
        self.resultController = resultController
        self.actionRegistry = actionRegistry
        self.skillRunner = skillRunner
        self.screenshotSkillBridge = screenshotSkillBridge
        self.commerceService = commerceService
        self.settings = settings
        self.permissionManager = permissionManager
        self.diagnosticsLogger = diagnosticsLogger
    }

    var isBusy: Bool {
        isActionRunning || currentActionTask != nil
    }

    func runSkill(
        _ skillID: String,
        inputOverride: String? = nil,
        anchorOverride: NSRect? = nil,
        keepConversation: Bool = false,
        preserveResultPanelPosition: Bool = false,
        followupDepth: Int = 0,
        followupSourceSkillID: String? = nil
    ) {
        if isBusy {
            cancelCurrentAction(resetToolbar: true)
        }

        let snapshots = delegate?.skillInvocationSnapshotState(self) ?? .init(
            textSnapshot: nil,
            fileSnapshot: nil,
            imageSnapshot: nil
        )
        let anchor = anchorOverride ?? toolbarController.frame

        guard let definition = skillRunner.definition(for: skillID) else {
            delegate?.skillInvocationShowTransientPrompt(
                self,
                message: L10n.format(zhHans: "未识别的 Skill：%@", en: "Unknown skill: %@", skillID),
                near: anchor,
                actionTitle: nil,
                actionHandler: nil,
                autoHideAfter: nil
            )
            return
        }

        if !actionRegistry.isEnabled(skillID, settings: settings) {
            delegate?.skillInvocationShowActionDisabledPrompt(self, definition: definition, near: anchor)
            return
        }

        if !commerceService.canAccess(definition) {
            delegate?.skillInvocationShowEntitlementPrompt(self, definition: definition, near: anchor)
            return
        }

        if let imageSnapshot = snapshots.imageSnapshot,
           screenshotSkillBridge.supports(definition: definition, snapshot: imageSnapshot) {
            runLocalScreenshotSkill(
                definition: definition,
                snapshot: imageSnapshot,
                near: anchor,
                preserveResultPanelPosition: preserveResultPanelPosition
            )
            return
        }

        let fileSnapshot = snapshots.fileSnapshot
        let imageSnapshot = snapshots.imageSnapshot
        let usesFileSelectionContext = fileSnapshot != nil && definition.supportedContexts.contains(.fileSelection)
        let usesImageSelectionContext = imageSnapshot != nil
            && (definition.supportedContexts.contains(.screenshotRegion) || definition.supportedContexts.contains(.imageCapture))

        if usesImageSelectionContext {
            delegate?.skillInvocationSetScreenshotSelectionActive(self, active: false)
            delegate?.skillInvocationDismissLockedSelection(self)
        }

        let overriddenText = inputOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileDisplayText = fileSnapshot?.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageRecognizedText = imageSnapshot?.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageDisplayText = imageSnapshot?.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputText = (overriddenText?.isEmpty == false)
            ? overriddenText
            : (usesFileSelectionContext
                ? fileDisplayText
                : (usesImageSelectionContext
                    ? ((imageRecognizedText?.isEmpty == false) ? imageRecognizedText : imageDisplayText)
                    : (snapshots.textSnapshot?.text ?? SelectionAccess.readPasteboardText())))

        guard let inputText else {
            delegate?.skillInvocationShowTransientPrompt(
                self,
                message: L10n.text(zhHans: "未检测到可用选中文本", en: "No usable selected text detected"),
                near: anchor,
                actionTitle: nil,
                actionHandler: nil,
                autoHideAfter: nil
            )
            return
        }

        if inputOverride == nil, !usesImageSelectionContext, !permissionManager.isAccessibilityTrusted() {
            _ = permissionManager.requestAccessibilityTrust(prompt: true)
            delegate?.skillInvocationShowPermissionPrompt(self, near: anchor)
            return
        }

        let isToolbarTriggeredTransition = !keepConversation && toolbarController.isVisible

        lastExecutedSkillID = skillID
        isActionRunning = true
        diagnosticsLogger.log(
            "action.lifecycle",
            "start skill=\(skillID) keepConversation=\(keepConversation) inputLength=\(inputText.count)"
        )
        if !isToolbarTriggeredTransition {
            toolbarController.setLoadingState(L10n.text(zhHans: "正在处理…", en: "Processing..."))
        }

        let translationDecision = resolvedTranslationDecision(for: skillID, inputText: inputText)
        let responseLanguage = translationDecision?.responseLanguage ?? resolvedResponseLanguage(for: skillID, inputText: inputText)
        let targetLanguage = translationDecision?.targetLanguage ?? resolvedTargetLanguage(for: skillID, inputText: inputText, responseLanguage: responseLanguage)
        let context = SkillExecutionContext(
            skillID: skillID,
            text: inputText,
            targetLanguage: targetLanguage,
            responseLanguage: responseLanguage,
            uiLanguage: settings.appLanguage.languageCode,
            filePaths: usesFileSelectionContext
                ? (fileSnapshot?.fileURLs.map(\.path) ?? [])
                : (usesImageSelectionContext ? [imageSnapshot?.imageURL.path].compactMap { $0 } : []),
            followupDepth: max(0, followupDepth),
            followupSourceSkillID: followupSourceSkillID,
            translationMode: translationDecision?.mode.rawValue
        )

        let initialAnchor = anchor
        let toolbarTransitionFrame = isToolbarTriggeredTransition ? toolbarController.frame : nil
        diagnosticsLogger.log(
            "result.transition",
            "invoke skill=\(skillID) anchor=\(formatRect(initialAnchor)) toolbarTransition=\(formatRect(toolbarTransitionFrame)) keepConversation=\(keepConversation) preserveResultPanelPosition=\(preserveResultPanelPosition)"
        )
        let actionID = UUID()
        currentActionID = actionID
        let requiresGateway = definition.executionLocality != .localOnly
        let sourceInteractionContext: SourceInteractionContext
        if let textSnapshot = snapshots.textSnapshot {
            sourceInteractionContext = TextSelectionArtifact(snapshot: textSnapshot).sourceInteractionContext
        } else if let fileSnapshot = snapshots.fileSnapshot {
            sourceInteractionContext = FileSelectionArtifact(snapshot: fileSnapshot).sourceInteractionContext
        } else if let imageSnapshot = snapshots.imageSnapshot {
            sourceInteractionContext = ImageSelectionArtifact(snapshot: imageSnapshot).sourceInteractionContext
        } else {
            sourceInteractionContext = .empty
        }
        let streamingSourceText = lightweightStreamingSourceText(
            definition: definition,
            inputText: inputText
        )

        resultController.showStreaming(
            definition: definition,
            sourceText: streamingSourceText,
            targetLanguage: targetLanguage,
            sourceBundleID: sourceInteractionContext.bundleID,
            sourceInteractionContext: sourceInteractionContext,
            replacementTarget: snapshots.textSnapshot?.replacementTarget,
            near: initialAnchor,
            keepConversation: keepConversation,
            preservePosition: preserveResultPanelPosition,
            transitionSourceFrame: toolbarTransitionFrame
        )

        if toolbarTransitionFrame != nil {
            toolbarController.hide()
        }

        currentActionTask?.cancel()
        currentActionTask = Task { [weak self] in
            guard let self else { return }
            if requiresGateway {
                let runtimeReady = await GatewayRuntimeManager.shared.ensureReady()
                if !runtimeReady {
                    let snapshot = GatewayRuntimeManager.shared.currentSnapshot()
                    await MainActor.run {
                        guard self.currentActionID == actionID else { return }
                        self.currentActionTask = nil
                        self.currentActionID = nil
                        self.isActionRunning = false
                        self.toolbarController.setLoadingState(nil)
                        self.resultController.hide(force: true)
                        self.delegate?.skillInvocationShowGatewayRuntimePrompt(
                            self,
                            snapshot: snapshot,
                            near: initialAnchor
                        )
                    }
                    return
                }
            }
            let result = await self.skillRunner.runStreamingEnvelope(
                skillID: skillID,
                context: context
            ) { [weak self] event in
                guard let self else { return }
                Task { @MainActor in
                    guard self.isActionRunning, self.currentActionID == actionID else { return }
                    switch event.type {
                    case .status:
                        self.diagnosticsLogger.log("gateway.stream", "status skill=\(skillID) key=\(event.status ?? "") detail=\(event.detail ?? "")")
                    case .delta:
                        self.diagnosticsLogger.log("gateway.stream", "partial skill=\(skillID) deltaLength=\(event.delta?.count ?? 0) fullLength=\(event.fullText?.count ?? 0)")
                    case .supplement:
                        self.diagnosticsLogger.log("trace.card", "skill=\(skillID) supplement count=\(event.cards?.count ?? 0)")
                    case .done:
                        self.diagnosticsLogger.log("gateway.stream", "done skill=\(skillID)")
                    case .error:
                        self.diagnosticsLogger.log("gateway.stream", "error skill=\(skillID) message=\(event.message ?? "")")
                    }
                    self.resultController.updateStreaming(event: event)
                }
            }

            await MainActor.run {
                guard self.currentActionID == actionID else { return }
                self.currentActionTask = nil
                self.currentActionID = nil
                self.isActionRunning = false
                self.toolbarController.setLoadingState(nil)

                switch result {
                case .success(let resultEnvelope):
                    let shouldPreserveResultPosition = self.resultController.isVisible && !self.resultController.isTransitioning
                    self.diagnosticsLogger.log(
                        "action.lifecycle",
                        "complete skill=\(skillID) resultType=\(resultEnvelope.resultType.rawValue)"
                    )
                    self.diagnosticsLogger.log(
                        "result.transition",
                        "showResultFromCoordinator skill=\(skillID) anchor=\(self.formatRect(initialAnchor)) resultPanelVisible=\(self.resultController.isVisible) preserve=\(shouldPreserveResultPosition)"
                    )
                    self.resultController.show(
                        resultEnvelope: resultEnvelope,
                        definition: definition,
                        near: initialAnchor,
                        preservePosition: shouldPreserveResultPosition
                    )
                case .failure(let error):
                    guard !(error is CancellationError) else { return }
                    self.diagnosticsLogger.log("action.lifecycle", "error skill=\(skillID) error=\(error.localizedDescription)")
                    self.delegate?.skillInvocationShowRequestFailurePrompt(self, error: error, near: initialAnchor)
                }
            }
        }
    }

    func cancelCurrentAction(resetToolbar: Bool) {
        diagnosticsLogger.log("action.lifecycle", "cancel resetToolbar=\(resetToolbar)")
        if resetToolbar {
            toolbarController.setLoadingState(nil)
        }
        guard isBusy else { return }
        currentActionTask?.cancel()
        currentActionTask = nil
        currentActionID = nil
        isActionRunning = false
    }

    private func runLocalScreenshotSkill(
        definition: SkillDefinition,
        snapshot: ImageSelectionSnapshot,
        near anchor: NSRect,
        preserveResultPanelPosition: Bool
    ) {
        if isBusy {
            cancelCurrentAction(resetToolbar: true)
        }

        delegate?.skillInvocationSetScreenshotSelectionActive(self, active: false)
        delegate?.skillInvocationDismissLockedScreenshotSession(self, clearImageSnapshot: true)

        let actionID = UUID()
        currentActionID = actionID
        currentActionTask?.cancel()
        isActionRunning = true
        toolbarController.setLoadingState(L10n.text(zhHans: "正在处理…", en: "Processing..."))

        currentActionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.screenshotSkillBridge.execute(definition: definition, snapshot: snapshot)
                await MainActor.run {
                    guard self.currentActionID == actionID else { return }
                    self.currentActionTask = nil
                    self.currentActionID = nil
                    self.isActionRunning = false
                    self.toolbarController.setLoadingState(nil)
                    self.lastExecutedSkillID = definition.skillID

                    switch result {
                    case .resultEnvelope(let envelope):
                        self.resultController.show(
                            resultEnvelope: envelope,
                            definition: definition,
                            near: anchor,
                            preservePosition: preserveResultPanelPosition && self.resultController.isVisible
                        )
                    case .transientMessage(let message, let autoHideAfter):
                        self.delegate?.skillInvocationShowTransientPrompt(
                            self,
                            message: message,
                            near: anchor,
                            actionTitle: nil,
                            actionHandler: nil,
                            autoHideAfter: autoHideAfter
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.currentActionID == actionID else { return }
                    self.currentActionTask = nil
                    self.currentActionID = nil
                    self.isActionRunning = false
                    self.toolbarController.setLoadingState(nil)
                    self.delegate?.skillInvocationShowTransientPrompt(
                        self,
                        message: L10n.format(zhHans: "执行失败：%@", en: "Execution failed: %@", error.localizedDescription),
                        near: anchor,
                        actionTitle: nil,
                        actionHandler: nil,
                        autoHideAfter: 2.0
                    )
                }
            }
        }
    }

    private func formatRect(_ rect: NSRect?) -> String {
        guard let rect else { return "nil" }
        return String(
            format: "(x:%.1f y:%.1f w:%.1f h:%.1f)",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    private func lightweightStreamingSourceText(
        definition: SkillDefinition,
        inputText: String
    ) -> String {
        if definition.skillID == "collect" {
            return ""
        }
        return inputText
    }

    private func resolvedResponseLanguage(for skillID: String, inputText: String) -> String {
        switch skillID {
        case "translate":
            return LanguageRoutingSupport.translationDecision(
                for: inputText,
                uiLanguage: settings.appLanguage.languageCode
            ).responseLanguage
        default:
            return settings.appLanguage.languageCode
        }
    }

    private func resolvedTargetLanguage(for skillID: String, inputText: String, responseLanguage: String) -> String {
        switch skillID {
        case "translate":
            return LanguageRoutingSupport.translationDecision(
                for: inputText,
                uiLanguage: settings.appLanguage.languageCode
            ).targetLanguage
        default:
            return responseLanguage
        }
    }

    private func resolvedTranslationDecision(for skillID: String, inputText: String) -> TranslationRoutingDecision? {
        guard skillID == "translate" else { return nil }
        return LanguageRoutingSupport.translationDecision(
            for: inputText,
            uiLanguage: settings.appLanguage.languageCode
        )
    }
}
