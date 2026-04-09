import Foundation

struct SettingsLearningSnapshotFormatter {
    let resolveSkillTitle: (String) -> String?
    let resolveBundleName: (String?) -> String
    let resolveCategoryName: (String) -> String
    let resolveConfidenceText: (Double) -> String
    let resolveRecommendationStyleText: (SkillRecommendationStyle) -> String

    func makeRouteSnapshotModel(from snapshot: RouteDiagnosticsSnapshot) -> SettingsStatisticsRouteSnapshotModel {
        let recommendedTitles = snapshot.primarySkillIDs.compactMap(resolveSkillTitle)
        let recommendedText = recommendedTitles.isEmpty
            ? L10n.text(zhHans: "暂无", en: "None yet")
            : L10n.joinedList(recommendedTitles)
        let bundleName = resolveBundleName(snapshot.bundleID)
        let categoryName = resolveCategoryName(snapshot.contentCategory)

        return SettingsStatisticsRouteSnapshotModel(
            title: L10n.text(zhHans: "为什么这次会这样推荐", en: "Why This Was Recommended"),
            summary: summaryText(
                recommendedTitles: recommendedTitles,
                bundleName: bundleName,
                categoryName: categoryName,
                recommendationReason: snapshot.recommendationReason
            ),
            rows: [
                (
                    L10n.text(zhHans: "推荐技能", en: "Recommended"),
                    recommendedText
                ),
                (
                    L10n.text(zhHans: "识别内容", en: "Selected content"),
                    previewText(snapshot.selectionPreview)
                ),
                (
                    L10n.text(zhHans: "当前场景", en: "Context"),
                    L10n.format(zhHans: "%@ · %@", en: "%@ · %@", bundleName, categoryName)
                ),
                (
                    L10n.text(zhHans: "推荐方式", en: "Recommendation style"),
                    resolveRecommendationStyleText(snapshot.recommendationStyle)
                ),
                (
                    L10n.text(zhHans: "把握程度", en: "Confidence"),
                    resolveConfidenceText(snapshot.confidence)
                )
            ]
        )
    }

    private func summaryText(
        recommendedTitles: [String],
        bundleName: String,
        categoryName: String,
        recommendationReason: String
    ) -> String {
        let recommendationSentence: String
        if recommendedTitles.isEmpty {
            recommendationSentence = L10n.format(
                zhHans: "这次在 %@ 的 %@ 场景下，NexHub 还没形成明确主推荐。",
                en: "In %@ for %@, NexHub has not formed a clear primary recommendation yet.",
                bundleName,
                categoryName
            )
        } else {
            recommendationSentence = L10n.format(
                zhHans: "这次在 %@ 的 %@ 场景下，NexHub 先推荐 %@。",
                en: "In %@ for %@, NexHub recommends %@ first.",
                bundleName,
                categoryName,
                L10n.joinedList(recommendedTitles)
            )
        }

        let normalizedReason = normalizedSentence(recommendationReason)
        guard !normalizedReason.isEmpty else { return recommendationSentence }
        return "\(recommendationSentence) \(normalizedReason)"
    }

    private func previewText(_ rawText: String) -> String {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return L10n.text(zhHans: "暂无可展示内容", en: "No preview available")
        }

        let limit = 88
        guard normalized.count > limit else { return normalized }
        let index = normalized.index(normalized.startIndex, offsetBy: limit)
        return "\(normalized[..<index])..."
    }

    private func normalizedSentence(_ rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") || trimmed.hasSuffix("。") {
            return trimmed
        }

        return trimmed + L10n.text(zhHans: "。", en: ".")
    }
}
