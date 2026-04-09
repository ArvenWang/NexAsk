import AppKit

extension SettingsWindowController: SettingsTabStatePresenting {
    func refreshSettingsState(for tab: SettingsShellTab) {
        switch tab {
        case .skills:
            rebuildSkillCatalogViews()
            if skillDetailPanel.isHidden == false {
                updateSkillDetailOverlay()
            }
        case .automation:
            reloadAutomationSettingsPage()
        case .ai:
            aiConfigurationCoordinator.handleGatewayRuntimeStatusChanged(aiTabCoordinator.runtimeSnapshot())
        case .membership:
            refreshCommerceUI()
        case .general, .knowledgeBase, .shortcuts, .privacy, .stats:
            break
        }
    }
}

extension SettingsWindowController {
    func refreshLearningDiagnostics() {
        let summary = usageLearningStore.summary()
        let builder = SettingsLearningDiagnosticsBuilder(
            appLanguage: settings.appLanguage,
            resolveSkillTitle: { [weak self] in self?.actionRegistry.definition(forSkillID: $0)?.title },
            resolveBundleName: { [weak self] in
                self?.displayName(forBundleID: $0) ?? L10n.text(key: "settings.learning.unknown_app", zhHans: "未知应用", en: "Unknown App")
            },
            resolveCategoryName: { [weak self] in self?.friendlyCategoryName($0) ?? $0 }
        )

        statisticsMetricStripView.update(items: builder.metricItems(from: summary))
        statisticsSkillChartView.update(items: builder.skillBarItems(from: summary))
        statisticsAppChartView.update(items: builder.appBarItems(from: summary))
        statisticsCategoryChartView.update(items: builder.categoryBarItems(from: summary))
        statisticsTrendSectionView.update(points: builder.trendPoints(from: summary))
        statisticsRouteSnapshotView.update(model: statisticsRouteSnapshotModel())
        refreshScrollableTabLayout(
            scrollView: learningScrollView,
            hostView: learningContentHost,
            contentView: learningContentStack
        )
    }

    func displayName(forBundleID bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else {
            return L10n.text(key: "settings.learning.unknown_app", zhHans: "未知应用", en: "Unknown App")
        }
        let known = RunningApplicationCatalog.currentApplicationsByBundleID()
        return known[bundleID]?.displayName
            ?? RunningApplicationCatalog.fallbackDisplayName(for: bundleID)
            ?? bundleID
    }

    func friendlyConfidenceText(_ value: Double) -> String {
        switch value {
        case 0.82...:
            return L10n.format(
                key: "settings.learning.confidence.very_confident",
                zhHans: "很确定（%@）",
                en: "High confidence (%@)",
                String(format: "%.2f", value)
            )
        case 0.62...:
            return L10n.format(
                key: "settings.learning.confidence.fairly_confident",
                zhHans: "比较确定（%@）",
                en: "Good confidence (%@)",
                String(format: "%.2f", value)
            )
        default:
            return L10n.format(
                key: "settings.learning.confidence.still_learning",
                zhHans: "还在学习（%@）",
                en: "Still learning (%@)",
                String(format: "%.2f", value)
            )
        }
    }

    func friendlyRecommendationStyleText(_ style: SkillRecommendationStyle) -> String {
        switch style {
        case .focused:
            return L10n.text(key: "settings.learning.style.focused", zhHans: "强推荐", en: "Recommended")
        case .cautious:
            return L10n.text(key: "settings.learning.style.cautious", zhHans: "谨慎推荐", en: "Recommended with caution")
        case .exploratory:
            return L10n.text(key: "settings.learning.style.exploratory", zhHans: "探索式推荐", en: "Exploratory")
        }
    }

    func friendlyCategoryName(_ rawValue: String) -> String {
        switch rawValue {
        case "chat_message": return L10n.text(key: "settings.learning.category.chat_message", zhHans: "沟通消息", en: "Conversation")
        case "feedback_request": return L10n.text(key: "settings.learning.category.feedback_request", zhHans: "需要回复或反馈的内容", en: "Feedback or reply request")
        case "foreign_text": return L10n.text(key: "settings.learning.category.foreign_text", zhHans: "短外语内容", en: "Short text in another language")
        case "long_foreign_text": return L10n.text(key: "settings.learning.category.long_foreign_text", zhHans: "长外语内容", en: "Long text in another language")
        case "mixed_language": return L10n.text(key: "settings.learning.category.mixed_language", zhHans: "中外文混合内容", en: "Mixed-language text")
        case "documentation_query": return L10n.text(key: "settings.learning.category.documentation_query", zhHans: "文档或接入查询", en: "Docs or integration question")
        case "news_or_announcement": return L10n.text(key: "settings.learning.category.news_or_announcement", zhHans: "发布或更新信息", en: "News or announcement")
        case "product_or_model_mention": return L10n.text(key: "settings.learning.category.product_or_model_mention", zhHans: "产品、模型或入口信息", en: "Product, model, or feature mention")
        case "technical_paragraph": return L10n.text(key: "settings.learning.category.technical_paragraph", zhHans: "技术说明内容", en: "Technical text")
        case "unclear_term": return L10n.text(key: "settings.learning.category.unclear_term", zhHans: "待解释的词或短语", en: "Term or phrase")
        case "general_text": return L10n.text(key: "settings.learning.category.general_text", zhHans: "通用文本", en: "General text")
        default: return rawValue
        }
    }

    private func statisticsRouteSnapshotModel() -> SettingsStatisticsRouteSnapshotModel? {
        guard let snapshot = routeDiagnosticsStore.currentSnapshot() else { return nil }
        return settingsLearningSnapshotFormatter.makeRouteSnapshotModel(from: snapshot)
    }
}
