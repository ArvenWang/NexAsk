import AppKit

extension NexHubRuntime {
    func runSkill(
        _ skillID: String,
        inputOverride: String? = nil,
        anchorOverride: NSRect? = nil,
        keepConversation: Bool = false,
        preserveResultPanelPosition: Bool = false,
        followupDepth: Int = 0,
        followupSourceSkillID: String? = nil
    ) {
        inlinePromptController.hide()
        if inputOverride == nil {
            skillPresentationCoordinator.recordSkillInvocationIfNeeded(skillID: skillID)
        }
        skillInvocationCoordinator.runSkill(
            skillID,
            inputOverride: inputOverride,
            anchorOverride: anchorOverride,
            keepConversation: keepConversation,
            preserveResultPanelPosition: preserveResultPanelPosition,
            followupDepth: followupDepth,
            followupSourceSkillID: followupSourceSkillID
        )
    }

    func showTransientPrompt(
        _ message: String,
        near anchor: NSRect,
        actionTitle: String? = nil,
        actionHandler: (() -> Void)? = nil,
        autoHideAfter: TimeInterval? = nil
    ) {
        resultController.hide(force: true)
        inlinePromptController.show(
            message: message,
            actionTitle: actionTitle,
            near: anchor,
            onAction: actionHandler,
            autoHideAfter: autoHideAfter
        )
    }

    func showActionDisabledPrompt(definition: SkillDefinition, near anchor: NSRect) {
        showTransientPrompt(
            L10n.format(zhHans: "%@功能已禁用，前往", en: "%@ is disabled. Open", definition.title),
            near: anchor,
            actionTitle: L10n.text(zhHans: "动作设置", en: "Action Settings")
        ) { [weak self] in
            self?.showActionManager()
        }
    }

    func showPermissionPrompt(near anchor: NSRect) {
        let readiness = permissionManager.firstUseReadinessSnapshot(
            calendarAutomationGranted: settings.calendarAutomationPermissionGranted
        )
        showTransientPrompt(
            readiness.summary,
            near: anchor,
            actionTitle: L10n.text(zhHans: "隐私设置", en: "Privacy Settings")
        ) { [weak self] in
            self?.showPrivacy()
        }
    }

    func showMissingAIConfigPrompt(near anchor: NSRect) {
        showTransientPrompt(
            L10n.text(zhHans: "当前托管 AI 服务暂不可用，请稍后重试。", en: "Managed AI is temporarily unavailable. Please try again later."),
            near: anchor
        )
    }

    func showGatewayRuntimePrompt(snapshot: GatewayRuntimeSnapshot, near anchor: NSRect) {
        let actionTitle: String
        let actionHandler: (() -> Void)?
        switch snapshot.failureReason {
        case .permission:
            actionTitle = L10n.text(zhHans: "隐私设置", en: "Privacy Settings")
            actionHandler = { [weak self] in self?.showPrivacy() }
        default:
            actionTitle = L10n.text(zhHans: "通用设置", en: "General Settings")
            actionHandler = { [weak self] in self?.showSettings() }
        }

        showTransientPrompt(
            snapshot.inlinePromptMessage,
            near: anchor,
            actionTitle: actionTitle,
            actionHandler: actionHandler
        )
    }

    func showEntitlementPrompt(definition: SkillDefinition, near anchor: NSRect) {
        let tierTitle = definition.requiredEntitlementTier?.rawValue.uppercased() ?? "PRO"
        showTransientPrompt(
            L10n.format(zhHans: "%@需要 %@ 权益，前往", en: "%@ requires %@ access. Open", definition.title, tierTitle),
            near: anchor,
            actionTitle: L10n.text(zhHans: "会员中心", en: "Membership")
        ) { [weak self] in
            self?.showMembership()
        }
    }

    func showRequestFailurePrompt(_ error: Error, near anchor: NSRect) {
        let nsError = error as NSError
        let message: String
        let actionTitle: String?
        let actionHandler: (() -> Void)?
        if let actionError = error as? ActionError {
            switch actionError {
            case .network(let detail) where detail == "gateway_not_ready":
                let snapshot = gatewayRuntime.currentSnapshot()
                message = snapshot.inlinePromptMessage
                actionTitle = L10n.text(zhHans: "通用设置", en: "General Settings")
                actionHandler = { [weak self] in self?.showSettings() }
            case .network(let detail) where detail == "Invalid API base URL":
                message = L10n.text(zhHans: "托管 AI 服务地址异常，请联系管理员。", en: "The managed AI service endpoint is invalid. Contact your administrator.")
                actionTitle = nil
                actionHandler = nil
            case .network(let detail) where detail.localizedCaseInsensitiveContains("unknown skill"):
                message = L10n.text(
                    zhHans: "Skill 执行配置异常，请检查内置技能。",
                    en: "Skill execution configuration is invalid. Please check the built-in skills."
                )
                actionTitle = nil
                actionHandler = nil
            case .network(let detail):
                message = detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? L10n.text(zhHans: "请求失败，请稍后重试。", en: "Request failed. Please try again shortly.")
                    : detail
                actionTitle = nil
                actionHandler = nil
            case .invalidResponse:
                message = L10n.text(
                    zhHans: "服务返回异常，请稍后重试。",
                    en: "The service returned an invalid response. Please try again shortly."
                )
                actionTitle = nil
                actionHandler = nil
            }
        } else if nsError.domain == NSURLErrorDomain && nsError.code == URLError.timedOut.rawValue {
            message = L10n.text(zhHans: "请求超时，请稍后重试。", en: "The request timed out. Please try again shortly.")
            actionTitle = nil
            actionHandler = nil
        } else {
            let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            message = description.isEmpty
                ? L10n.text(zhHans: "请求失败，请稍后重试。", en: "Request failed. Please try again shortly.")
                : description
            actionTitle = nil
            actionHandler = nil
        }

        showTransientPrompt(
            message,
            near: anchor,
            actionTitle: actionTitle,
            actionHandler: actionHandler
        )
    }

    func refreshToolbarSkillLineup(snapshot: SelectionSnapshot?) {
        refreshToolbarSkillLineup(textSnapshot: snapshot, fileSnapshot: nil, imageSnapshot: nil)
    }

    func refreshToolbarSkillLineup(
        textSnapshot: SelectionSnapshot?,
        fileSnapshot: FileSelectionSnapshot?,
        imageSnapshot: ImageSelectionSnapshot?
    ) {
        let layout = skillPresentationCoordinator.prepareToolbarLayout(
            textSnapshot: textSnapshot,
            fileSnapshot: fileSnapshot,
            imageSnapshot: imageSnapshot,
            settings: settings
        )
        toolbarController.updateSlotLayout(layout)
    }

    func makeActivationContext(from snapshot: SelectionSnapshot) -> ActivationContext {
        TextSelectionArtifact(snapshot: snapshot).activationContext
    }

    func makeActivationContext(from snapshot: FileSelectionSnapshot) -> ActivationContext {
        FileSelectionArtifact(snapshot: snapshot).activationContext
    }

    func makeActivationContext(from snapshot: ImageSelectionSnapshot) -> ActivationContext {
        ImageSelectionArtifact(snapshot: snapshot).activationContext
    }
}
