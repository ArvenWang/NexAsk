import AppKit

struct ResultFooterActionContext {
    let definition: SkillDefinition?
    let currentSourceText: String?
    let currentSourceBundleID: String?
    let currentReplacementTarget: ReplacementTargetSnapshot?
    let currentSourceInteractionContext: SourceInteractionContext
    let latestReplaceText: String?
    let latestWritebackText: String?
    let latestSourceURL: URL?
    let currentResultMetadata: [String: String]
    let resolvedFooterSourceText: String?
}

final class ResultFailureAlertPresenter {
    private let diagnosticsLogger: DiagnosticsLogger

    init(diagnosticsLogger: DiagnosticsLogger = .shared) {
        self.diagnosticsLogger = diagnosticsLogger
    }

    func showWritebackFallbackAlert(sourceBundleID: String?, reason: String, diagnostics: String) {
        let appName = sourceBundleID.flatMap { RunningApplicationCatalog.fallbackDisplayName(for: $0) }
            ?? L10n.text(zhHans: "当前应用", en: "the current app")
        diagnosticsLogger.log("result.writeback", "reason=\(reason)\n\(diagnostics)")
        let logPath = diagnosticsLogger.logFileDisplayPath
        let alert = NSAlert()
        alert.messageText = L10n.text(zhHans: "未写回到输入框", en: "Couldn't write back to the input field")
        let compactDiagnostics = diagnostics.isEmpty ? L10n.text(zhHans: "无", en: "None") : diagnostics
        alert.informativeText = L10n.format(
            zhHans: "这次没能直接写回到%@的输入框。通常是因为当前输入区已经失焦，或者该应用没有把真实输入层暴露给系统。\n\n现在最直接的恢复方式是：回到%@，按 Command+V 粘贴。结果已经替你复制到剪贴板了。\n\n诊断：\n%@\n\n完整日志：%@",
            en: "NexHub couldn't write directly back into %@. This usually happens because the input lost focus or the app doesn't expose a stable system-editable text field.\n\nThe fastest recovery is to go back to %@ and press Command+V. NexHub has already copied the result to your clipboard.\n\nDiagnostics:\n%@\n\nFull log: %@",
            appName,
            appName,
            compactDiagnostics,
            logPath
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.text(zhHans: "确定", en: "OK"))
        alert.runModal()
    }

    func showReplaceFailureAlert(sourceBundleID: String?, reason: String, diagnostics: String) {
        let appName = sourceBundleID.flatMap { RunningApplicationCatalog.fallbackDisplayName(for: $0) }
            ?? L10n.text(zhHans: "原应用", en: "the source app")
        diagnosticsLogger.log("result.replace", "reason=\(reason)\n\(diagnostics)")
        let logPath = diagnosticsLogger.logFileDisplayPath
        let alert = NSAlert()
        alert.messageText = L10n.text(zhHans: "未替换原文", en: "Couldn't replace the original text")
        let compactDiagnostics = diagnostics.isEmpty ? L10n.text(zhHans: "无", en: "None") : diagnostics
        alert.informativeText = L10n.format(
            zhHans: "这次没有直接替换掉原文。大多数情况下，是因为原输入框已经失焦，或者这段内容所在的位置并不是一个稳定可替换的输入区。\n\n来源应用：%@\n\n如果你只是想把结果带回去，优先改用“写回输入框”会更稳；如果当前场景没有写回，也可以回到原应用手动粘贴。\n\n诊断：\n%@\n\n完整日志：%@",
            en: "NexHub couldn't replace the original text in %@. This usually means the field lost focus or the app doesn't expose a stable editable field.\n\nIf you just need to send the result back, Write Back is usually the more reliable option. If it isn't available here, go back to the source app and paste manually.\n\nDiagnostics:\n%@\n\nFull log: %@",
            appName,
            compactDiagnostics,
            logPath
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.text(zhHans: "确定", en: "OK"))
        alert.runModal()
    }
}

final class ResultFooterActionCoordinator {
    private let diagnosticsLogger: DiagnosticsLogger
    private let alertPresenter: ResultFailureAlertPresenter
    private let contextProvider: () -> ResultFooterActionContext
    private let actionPolicyDecisionProvider: (ResultFooterActionKind) -> ResultActionPolicyDecision
    private let copyHandler: () -> Void
    private let hideHandler: (Bool) -> Void
    private let refocusSourceApplication: (String?) -> Void
    private let onRegenerateRequested: (String, String) -> Void
    private let onSkillShortcutRequested: (String, String, Int, String?) -> Void

    init(
        diagnosticsLogger: DiagnosticsLogger = .shared,
        alertPresenter: ResultFailureAlertPresenter,
        contextProvider: @escaping () -> ResultFooterActionContext,
        actionPolicyDecisionProvider: @escaping (ResultFooterActionKind) -> ResultActionPolicyDecision,
        copyHandler: @escaping () -> Void,
        hideHandler: @escaping (Bool) -> Void,
        refocusSourceApplication: @escaping (String?) -> Void,
        onRegenerateRequested: @escaping (String, String) -> Void,
        onSkillShortcutRequested: @escaping (String, String, Int, String?) -> Void
    ) {
        self.diagnosticsLogger = diagnosticsLogger
        self.alertPresenter = alertPresenter
        self.contextProvider = contextProvider
        self.actionPolicyDecisionProvider = actionPolicyDecisionProvider
        self.copyHandler = copyHandler
        self.hideHandler = hideHandler
        self.refocusSourceApplication = refocusSourceApplication
        self.onRegenerateRequested = onRegenerateRequested
        self.onSkillShortcutRequested = onSkillShortcutRequested
    }

    func performFooterAction(
        _ kind: ResultFooterActionKind,
        followupSkillID: String? = nil,
        followupInputSource: SkillFollowupInputSource? = nil,
        followupMaxDepth: Int? = nil,
        followupSourceSkillID: String? = nil
    ) {
        let context = contextProvider()
        let decision = actionPolicyDecisionProvider(kind)
        diagnosticsLogger.log(
            "result.action_policy",
            decision.diagnosticsPayload(skillID: context.definition?.skillID, sourceBundleID: context.currentSourceBundleID)
        )

        switch kind {
        case .regenerate:
            guard let definition = context.definition,
                  let sourceText = context.currentSourceText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sourceText.isEmpty else {
                return
            }
            onRegenerateRequested(definition.skillID, sourceText)
        case .copy:
            copyHandler()
        case .translate:
            guard let request = followupInvocationRequest(
                context: context,
                skillID: "translate",
                inputSource: followupInputSource,
                maxDepth: followupMaxDepth,
                sourceSkillID: followupSourceSkillID
            ) else { return }
            onSkillShortcutRequested(request.skillID, request.sourceText, request.followupDepth, request.followupSourceSkillID)
        case .explain:
            guard let request = followupInvocationRequest(
                context: context,
                skillID: "explain",
                inputSource: followupInputSource,
                maxDepth: followupMaxDepth,
                sourceSkillID: followupSourceSkillID
            ) else { return }
            onSkillShortcutRequested(request.skillID, request.sourceText, request.followupDepth, request.followupSourceSkillID)
        case .followup:
            guard let followupSkillID,
                  let request = followupInvocationRequest(
                    context: context,
                    skillID: followupSkillID,
                    inputSource: followupInputSource,
                    maxDepth: followupMaxDepth,
                    sourceSkillID: followupSourceSkillID
                  ) else { return }
            onSkillShortcutRequested(request.skillID, request.sourceText, request.followupDepth, request.followupSourceSkillID)
        case .replace:
            guard let replacement = context.latestReplaceText else { return }
            let sourceBundleID = context.currentSourceBundleID
            hideHandler(true)
            SelectionAccess.replaceSelectedText(
                with: replacement,
                sourceBundleID: sourceBundleID,
                replacementTarget: context.currentReplacementTarget,
                selectedText: context.currentSourceText
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let diagnostics):
                        self.diagnosticsLogger.log("result.replace", diagnostics)
                        self.refocusSourceApplication(sourceBundleID)
                    case .failure(let reason, let diagnostics):
                        self.alertPresenter.showReplaceFailureAlert(sourceBundleID: sourceBundleID, reason: reason, diagnostics: diagnostics)
                    }
                }
            }
        case .writeInput:
            guard let replacement = context.latestWritebackText else { return }
            let sourceBundleID = context.currentSourceBundleID
            hideHandler(true)
            SelectionAccess.writeTextToInput(
                replacement,
                sourceBundleID: sourceBundleID,
                sourceInteractionContext: context.currentSourceInteractionContext
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(_, let diagnostics):
                        self.diagnosticsLogger.log("result.writeback", diagnostics)
                        self.refocusSourceApplication(sourceBundleID)
                    case .copiedToPasteboard(let reason, let diagnostics):
                        self.alertPresenter.showWritebackFallbackAlert(sourceBundleID: sourceBundleID, reason: reason, diagnostics: diagnostics)
                    case .failure(let reason, let diagnostics):
                        self.alertPresenter.showWritebackFallbackAlert(sourceBundleID: sourceBundleID, reason: reason, diagnostics: diagnostics)
                    }
                }
            }
        case .openPrimary:
            if let url = context.latestSourceURL {
                NSWorkspace.shared.open(url)
            }
        case .capabilityAction:
            return
        }
    }

    private func followupInvocationRequest(
        context: ResultFooterActionContext,
        skillID: String,
        inputSource: SkillFollowupInputSource?,
        maxDepth: Int?,
        sourceSkillID: String?
    ) -> (skillID: String, sourceText: String, followupDepth: Int, followupSourceSkillID: String?)? {
        let sourceText: String?
        switch inputSource ?? .currentResult {
        case .currentResult:
            sourceText = context.resolvedFooterSourceText
        case .originalSelection:
            let trimmedOriginal = context.currentSourceText?.trimmingCharacters(in: .whitespacesAndNewlines)
            sourceText = (trimmedOriginal?.isEmpty == false) ? trimmedOriginal : nil
        }

        guard let sourceText, !sourceText.isEmpty else { return nil }
        let currentDepth = Int(context.currentResultMetadata["followup_depth"] ?? "") ?? 0
        let resolvedMaxDepth = maxDepth ?? Int(context.currentResultMetadata["followup_max_depth"] ?? "") ?? SkillFollowupResolver.defaultMaxDepth
        guard currentDepth < resolvedMaxDepth else { return nil }
        let resolvedSourceSkillID = sourceSkillID
            ?? context.currentResultMetadata["followup_source_skill_id"]
            ?? context.definition?.skillID
        return (
            skillID: skillID,
            sourceText: sourceText,
            followupDepth: currentDepth + 1,
            followupSourceSkillID: resolvedSourceSkillID
        )
    }
}
