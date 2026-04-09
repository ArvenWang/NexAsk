import Foundation

enum ResultFooterActionKind: String {
    case regenerate
    case copy
    case translate
    case explain
    case followup
    case replace
    case writeInput
    case openPrimary
    case capabilityAction = "capability_action"
}

struct ResultFooterAction {
    let kind: ResultFooterActionKind
    let title: String
    let systemImageName: String
    let accessibilityDescription: String
    let followupSkillID: String?
    let followupInputSource: SkillFollowupInputSource?
    let followupMaxDepth: Int?
    let followupSourceSkillID: String?
    let capabilityActionID: String?
}

struct ResultFooterModel {
    let resultActions: [ResultFooterAction]
    let skillFollowups: [ResultFooterAction]
    let capabilityActions: [ResultFooterAction]

    var flattenedActions: [ResultFooterAction] {
        resultActions + skillFollowups + capabilityActions
    }
}

struct ResolvedResultModel {
    let copyPayload: String
    let replacePayload: String?
    let writebackPayload: String?
    let primaryURL: URL?
    let footerModel: ResultFooterModel

    var footerActions: [ResultFooterAction] {
        footerModel.flattenedActions
    }
}

typealias ResolvedResultActions = ResolvedResultModel

enum ResultFooterModelResolver {
    static func resolve(
        resultEnvelope: SkillResultEnvelope,
        currentDefinition: SkillDefinition?,
        actionRegistry: ActionRegistry,
        settings: AppSettings,
        sourceInteractionContext: SourceInteractionContext,
        currentSourceText: String?,
        latestSourceURL: URL?,
        resolvedPrimaryText: String
    ) -> ResolvedResultModel {
        let definition = resolveDefinition(
            skillID: resultEnvelope.skillID,
            currentDefinition: currentDefinition,
            actionRegistry: actionRegistry
        )
        let copyPayload = resolvedCopyPayload(for: resultEnvelope, displayText: resolvedPrimaryText)
        let replacePayload = resolvedReplacePayload(
            for: resultEnvelope,
            definition: definition,
            displayText: resolvedPrimaryText,
            sourceInteractionContext: sourceInteractionContext
        )
        let sourceURL = latestSourceURL ?? primaryURL(from: resultEnvelope)
        let writebackPayload = resolveWritebackPayload(
            for: resultEnvelope,
            definition: definition,
            displayText: resolvedPrimaryText,
            sourceInteractionContext: sourceInteractionContext
        )

        let footerModel = footerModel(
            for: resultEnvelope,
            definition: definition,
            settings: settings,
            hasSourceText: currentSourceText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            copyPayload: copyPayload,
            replacePayload: replacePayload,
            writebackPayload: writebackPayload,
            primaryURL: sourceURL,
            actionRegistry: actionRegistry
        )

        return ResolvedResultModel(
            copyPayload: copyPayload,
            replacePayload: replacePayload,
            writebackPayload: writebackPayload,
            primaryURL: sourceURL,
            footerModel: footerModel
        )
    }

    private static func resolveDefinition(
        skillID: String,
        currentDefinition: SkillDefinition?,
        actionRegistry: ActionRegistry
    ) -> SkillDefinition? {
        if let currentDefinition, currentDefinition.skillID == skillID {
            return currentDefinition
        }
        return actionRegistry.definition(forSkillID: skillID)
    }

    private static func resolvedCopyPayload(for resultEnvelope: SkillResultEnvelope, displayText: String) -> String {
        resultEnvelope.copyPayload ?? displayText
    }

    private static func resolvedReplacePayload(
        for resultEnvelope: SkillResultEnvelope,
        definition: SkillDefinition?,
        displayText: String,
        sourceInteractionContext: SourceInteractionContext
    ) -> String? {
        guard let definition else {
            return resultEnvelope.replacePayload
        }

        if definition.supportsReplace,
           sourceInteractionContext.supportsReplaceSelection {
            let payload = resultEnvelope.replacePayload ?? resultEnvelope.copyPayload ?? displayText
            return payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : payload
        }

        return nil
    }

    private static func resolveWritebackPayload(
        for resultEnvelope: SkillResultEnvelope,
        definition: SkillDefinition?,
        displayText: String,
        sourceInteractionContext: SourceInteractionContext
    ) -> String? {
        ResultDeliveryPolicy.writebackPayload(
            for: resultEnvelope,
            definition: definition,
            displayText: displayText,
            sourceInteractionContext: sourceInteractionContext
        )
    }

    private static func footerModel(
        for resultEnvelope: SkillResultEnvelope,
        definition: SkillDefinition?,
        settings: AppSettings,
        hasSourceText: Bool,
        copyPayload: String,
        replacePayload: String?,
        writebackPayload: String?,
        primaryURL: URL?,
        actionRegistry: ActionRegistry
    ) -> ResultFooterModel {
        guard let definition,
              definition.supportsFooter else {
            return ResultFooterModel(resultActions: [], skillFollowups: [], capabilityActions: [])
        }

        var resultActions: [ResultFooterAction] = []

        if definition.supportsRegenerate,
           shouldShowRegenerate(for: resultEnvelope),
           hasSourceText {
            resultActions.append(
                ResultFooterAction(
                    kind: .regenerate,
                    title: L10n.text(key: "result.action.regenerate", zhHans: "重新生成", en: "Regenerate"),
                    systemImageName: "arrow.clockwise",
                    accessibilityDescription: "regenerate",
                    followupSkillID: nil,
                    followupInputSource: nil,
                    followupMaxDepth: nil,
                    followupSourceSkillID: nil,
                    capabilityActionID: nil
                )
            )
        }

        if !copyPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           definition.supportsCopy {
            resultActions.append(
                ResultFooterAction(
                    kind: .copy,
                    title: L10n.text(key: "result.action.copy", zhHans: "复制", en: "Copy"),
                    systemImageName: "doc.on.doc",
                    accessibilityDescription: "copy",
                    followupSkillID: nil,
                    followupInputSource: nil,
                    followupMaxDepth: nil,
                    followupSourceSkillID: nil,
                    capabilityActionID: nil
                )
            )
        }

        if let replacePayload,
           !replacePayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           definition.supportsReplace {
            resultActions.append(
                ResultFooterAction(
                    kind: .replace,
                    title: L10n.text(key: "result.action.replace", zhHans: "替换原文", en: "Replace Original"),
                    systemImageName: "arrow.left.arrow.right",
                    accessibilityDescription: "replace",
                    followupSkillID: nil,
                    followupInputSource: nil,
                    followupMaxDepth: nil,
                    followupSourceSkillID: nil,
                    capabilityActionID: nil
                )
            )
        }

        if let writebackPayload,
           !writebackPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resultActions.append(
                ResultFooterAction(
                    kind: .writeInput,
                    title: L10n.text(key: "result.action.write_input", zhHans: "写回输入框", en: "Write Back"),
                    systemImageName: "arrow.down.message",
                    accessibilityDescription: "writeback",
                    followupSkillID: nil,
                    followupInputSource: nil,
                    followupMaxDepth: nil,
                    followupSourceSkillID: nil,
                    capabilityActionID: nil
                )
            )
        }

        if definition.supportsOpenPrimary,
           resultEnvelope.primaryAction?.type == .openURL,
           primaryURL != nil {
            resultActions.append(
                ResultFooterAction(
                    kind: .openPrimary,
                    title: resultEnvelope.primaryAction?.label
                        ?? L10n.text(key: "result.action.open_primary", zhHans: "打开来源", en: "Open Link"),
                    systemImageName: "arrow.up.forward",
                    accessibilityDescription: "open-primary",
                    followupSkillID: nil,
                    followupInputSource: nil,
                    followupMaxDepth: nil,
                    followupSourceSkillID: nil,
                    capabilityActionID: nil
                )
            )
        }

        return ResultFooterModel(
            resultActions: resultActions,
            skillFollowups: followupActions(for: resultEnvelope, settings: settings, actionRegistry: actionRegistry),
            capabilityActions: CapabilityActionResolver.resolve(
                resultEnvelope: resultEnvelope,
                definition: definition
            )
        )
    }

    private static func followupActions(
        for resultEnvelope: SkillResultEnvelope,
        settings: AppSettings,
        actionRegistry: ActionRegistry
    ) -> [ResultFooterAction] {
        let followups = resultEnvelope.followups ?? []
        guard !followups.isEmpty else { return [] }

        return followups.compactMap { followup in
            guard let definition = actionRegistry.definition(forSkillID: followup.skillID),
                  actionRegistry.isEnabled(definition.skillID, settings: settings) else {
                return nil
            }

            let kind: ResultFooterActionKind
            switch followup.skillID {
            case "translate":
                kind = .translate
            case "explain":
                kind = .explain
            default:
                kind = .followup
            }

            return ResultFooterAction(
                kind: kind,
                title: followup.label,
                systemImageName: definition.symbolName,
                accessibilityDescription: "followup-\(followup.skillID)",
                followupSkillID: followup.skillID,
                followupInputSource: followup.inputSource,
                followupMaxDepth: followup.maxDepth,
                followupSourceSkillID: followup.sourceSkillID,
                capabilityActionID: nil
            )
        }
    }

    private static func shouldShowRegenerate(for resultEnvelope: SkillResultEnvelope) -> Bool {
        if resultEnvelope.skillID == "schedule" {
            return resultEnvelope.metadata?["used_llm"] == "true"
        }
        return true
    }

    private static func primaryURL(from resultEnvelope: SkillResultEnvelope) -> URL? {
        if resultEnvelope.primaryAction?.type == .openURL,
           let value = resultEnvelope.primaryAction?.value {
            return URL(string: value)
        }

        return resultEnvelope.cards?.compactMap { card in
            guard card.action?.type == .openURL,
                  let value = card.action?.value else {
                return nil
            }
            return URL(string: value)
        }.first
    }
}

typealias ResultActionResolver = ResultFooterModelResolver
