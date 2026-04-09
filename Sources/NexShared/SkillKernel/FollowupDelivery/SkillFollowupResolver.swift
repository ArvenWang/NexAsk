import Foundation

enum SkillFollowupResolver {
    static let defaultMaxDepth = 1

    static func resolve(
        skillID: String,
        envelopeFollowups: [SkillFollowupContract]?,
        context: SkillExecutionContext? = nil,
        metadata: [String: String]? = nil
    ) -> [SkillFollowupContract] {
        let currentDepth = context?.followupDepth ?? Int(metadata?["followup_depth"] ?? "") ?? 0
        guard currentDepth >= 0 else { return [] }

        let resolved = (envelopeFollowups?.isEmpty == false)
            ? envelopeFollowups ?? []
            : defaultFollowups(for: skillID, currentDepth: currentDepth)

        return resolved.compactMap { followup in
            let maxDepth = max(0, followup.maxDepth ?? defaultMaxDepth)
            guard currentDepth < maxDepth else { return nil }
            guard followup.skillID != skillID else { return nil }
            return SkillFollowupContract(
                skillID: followup.skillID,
                label: followup.label,
                inputSource: followup.inputSource ?? .currentResult,
                maxDepth: maxDepth,
                sourceSkillID: followup.sourceSkillID ?? metadata?["followup_source_skill_id"] ?? skillID
            )
        }
    }

    private static func defaultFollowups(for skillID: String, currentDepth: Int) -> [SkillFollowupContract] {
        guard currentDepth == 0 else { return [] }

        switch skillID {
        case "translate":
            return [
                SkillFollowupContract(
                    skillID: "explain",
                    label: L10n.text(zhHans: "解释", en: "Explain"),
                    inputSource: .currentResult,
                    maxDepth: defaultMaxDepth,
                    sourceSkillID: "translate"
                )
            ]
        case "screenshot_ocr":
            return [
                SkillFollowupContract(
                    skillID: "translate",
                    label: L10n.text(zhHans: "翻译", en: "Translate"),
                    inputSource: .currentResult,
                    maxDepth: defaultMaxDepth,
                    sourceSkillID: "screenshot_ocr"
                ),
                SkillFollowupContract(
                    skillID: "explain",
                    label: L10n.text(zhHans: "解释", en: "Explain"),
                    inputSource: .currentResult,
                    maxDepth: defaultMaxDepth,
                    sourceSkillID: "screenshot_ocr"
                )
            ]
        default:
            return []
        }
    }
}
