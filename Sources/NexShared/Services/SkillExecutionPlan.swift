import Foundation

enum SkillRecommendationStyle: String {
    case focused
    case cautious
    case exploratory
}

struct SkillRecommendationGuidance {
    let topSkillID: String?
    let style: SkillRecommendationStyle
    let scoreGap: Double
    let reason: String
}

struct SkillExecutionPlan {
    let activationContext: ActivationContext
    let sourceInteractionContext: SourceInteractionContext
    let selectionPreview: String
    let contentCategory: String
    let confidence: Double
    let primarySkillIDs: [String]
    let secondarySkillIDs: [String]
    let rankedIntents: [SkillIntentScore]
    let timestamp: Date

    var selectionType: String {
        activationContext.contentType.rawValue
    }

    var bundleID: String? {
        sourceInteractionContext.bundleID
    }

    func recommendationGuidance(actionRegistry: ActionRegistry) -> SkillRecommendationGuidance {
        guard let topIntent = rankedIntents.first else {
            return SkillRecommendationGuidance(
                topSkillID: nil,
                style: .exploratory,
                scoreGap: 0,
                reason: L10n.text(zhHans: "当前没有形成稳定候选，先保持探索式推荐更稳妥。", en: "There is no stable leading candidate yet, so keeping an exploratory recommendation is safer.")
            )
        }

        let runnerUpScore = rankedIntents.dropFirst().first?.score ?? 0
        let scoreGap = max(0, topIntent.score - runnerUpScore)

        guard let topDefinition = actionRegistry.definition(forSkillID: topIntent.skillID) else {
            return SkillRecommendationGuidance(
                topSkillID: topIntent.skillID,
                style: .exploratory,
                scoreGap: scoreGap,
                reason: L10n.text(zhHans: "当前缺少技能定义信息，先按探索式推荐处理。", en: "Skill definition data is incomplete, so NexHub is using an exploratory recommendation for now.")
            )
        }

        let impactLevel = ActionImpactPolicy.impactLevel(for: topDefinition)
        let hasStrongLead = topIntent.score >= 0.72 && scoreGap >= 0.12
        let hasWeakLead = topIntent.score < 0.48 || scoreGap < 0.06

        if hasWeakLead {
            return SkillRecommendationGuidance(
                topSkillID: topDefinition.skillID,
                style: .exploratory,
                scoreGap: scoreGap,
                reason: L10n.text(zhHans: "这次内容判断还没有和其他候选明显拉开差距，更适合保留多个候选让用户选择。", en: "This result is not clearly ahead of the other candidates yet, so keeping multiple options is more appropriate.")
            )
        }

        if impactLevel != .passive || topDefinition.executionLocality == .cloudOnly {
            return SkillRecommendationGuidance(
                topSkillID: topDefinition.skillID,
                style: .cautious,
                scoreGap: scoreGap,
                reason: L10n.text(zhHans: "头部技能已经较明确，但它涉及写回、创建或云端调用这类更高影响动作，适合谨慎推荐。", en: "The leading skill is fairly clear, but it involves writeback, creation, or cloud execution, so a cautious recommendation is more appropriate.")
            )
        }

        if hasStrongLead {
            return SkillRecommendationGuidance(
                topSkillID: topDefinition.skillID,
                style: .focused,
                scoreGap: scoreGap,
                reason: L10n.text(zhHans: "头部技能与其他候选已明显拉开，可将它作为这次的强推荐入口。", en: "The leading skill is clearly ahead of the others, so it can be presented as the strong recommendation.")
            )
        }

        return SkillRecommendationGuidance(
            topSkillID: topDefinition.skillID,
            style: .cautious,
            scoreGap: scoreGap,
            reason: L10n.text(zhHans: "系统已经形成主推荐，但仍保留谨慎推荐更适合当前阶段。", en: "NexHub has formed a primary recommendation, but a cautious presentation is still more appropriate at this stage.")
        )
    }

    func makeRouteDiagnosticsSnapshot(actionRegistry: ActionRegistry) -> RouteDiagnosticsSnapshot {
        let guidance = recommendationGuidance(actionRegistry: actionRegistry)
        return RouteDiagnosticsSnapshot(
            selectionPreview: selectionPreview,
            bundleID: bundleID,
            sourceInteractionContext: sourceInteractionContext,
            contentCategory: contentCategory,
            confidence: confidence,
            recommendationStyle: guidance.style,
            recommendationReason: guidance.reason,
            primarySkillIDs: primarySkillIDs,
            secondarySkillIDs: secondarySkillIDs,
            diagnostics: rankedIntents.compactMap { intent in
                guard let definition = actionRegistry.definition(forSkillID: intent.skillID) else { return nil }
                return RouteSkillDiagnostic(
                    skillID: intent.skillID,
                    title: definition.title,
                    ruleScore: intent.ruleScore,
                    usageScore: intent.usageScore,
                    finalScore: intent.score,
                    reason: intent.reason
                )
            },
            timestamp: timestamp
        )
    }
}
