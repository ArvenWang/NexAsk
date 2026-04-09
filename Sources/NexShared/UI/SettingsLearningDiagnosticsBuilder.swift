import Foundation

struct SettingsLearningDiagnosticsBuilder {
    let appLanguage: AppLanguage
    let resolveSkillTitle: (String) -> String?
    let resolveBundleName: (String?) -> String
    let resolveCategoryName: (String) -> String

    func metricItems(from summary: UsageLearningSummary) -> [SettingsStatisticsMetricItem] {
        let lastSevenDays = summary.recentDailyActivities.reduce(0) { $0 + $1.actions }
        let topSkillTitle = summary.topGlobalSkills.first.flatMap { resolveSkillTitle($0.skillID) }
            ?? L10n.text(zhHans: "暂无", en: "None yet")
        let topScene = summary.topBundleAffinities.first.map {
            resolveBundleName($0.contextKey == "unknown" ? nil : $0.contextKey)
        } ?? L10n.text(zhHans: "暂无", en: "None yet")

        return [
            SettingsStatisticsMetricItem(
                title: L10n.text(zhHans: "最近触发", en: "Recent uses"),
                value: "\(summary.totalRecentActions)",
                note: L10n.text(zhHans: "累计记录到的有效使用次数", en: "Total recorded successful uses")
            ),
            SettingsStatisticsMetricItem(
                title: L10n.text(zhHans: "近 7 天", en: "Last 7 days"),
                value: "\(lastSevenDays)",
                note: L10n.text(zhHans: "这一周里最活跃的使用情况", en: "Your activity during the last week")
            ),
            SettingsStatisticsMetricItem(
                title: L10n.text(zhHans: "最常点技能", en: "Top skill"),
                value: topSkillTitle,
                note: L10n.text(zhHans: "最近你最常主动选择的技能", en: "The skill you picked most often recently")
            ),
            SettingsStatisticsMetricItem(
                title: L10n.text(zhHans: "常出现 App", en: "Top app"),
                value: topScene,
                note: L10n.text(zhHans: "最近最常触发 NexHub 的应用", en: "The app where NexHub appeared most often")
            )
        ]
    }

    func skillBarItems(from summary: UsageLearningSummary) -> [SettingsStatisticsBarItem] {
        let maxActions = max(summary.topGlobalSkills.map(\.actions).max() ?? 0, 1)
        return summary.topGlobalSkills.map { item in
            let title = resolveSkillTitle(item.skillID) ?? item.skillID
            let rate = selectionRate(actions: item.actions, impressions: item.impressions)
            return SettingsStatisticsBarItem(
                title: title,
                valueText: L10n.format(zhHans: "%d 次 · %@", en: "%d uses · %@", item.actions, rate),
                ratio: CGFloat(item.actions) / CGFloat(maxActions)
            )
        }
    }

    func appBarItems(from summary: UsageLearningSummary) -> [SettingsStatisticsBarItem] {
        let maxActions = max(summary.topBundleAffinities.map(\.actions).max() ?? 0, 1)
        return summary.topBundleAffinities.map { item in
            let appName = resolveBundleName(item.contextKey == "unknown" ? nil : item.contextKey)
            let skillName = resolveSkillTitle(item.skillID) ?? item.skillID
            return SettingsStatisticsBarItem(
                title: appName,
                valueText: L10n.format(zhHans: "%@ · %d 次", en: "%@ · %d uses", skillName, item.actions),
                ratio: CGFloat(item.actions) / CGFloat(maxActions)
            )
        }
    }

    func categoryBarItems(from summary: UsageLearningSummary) -> [SettingsStatisticsBarItem] {
        let maxActions = max(summary.topCategoryAffinities.map(\.actions).max() ?? 0, 1)
        return summary.topCategoryAffinities.map { item in
            let skillName = resolveSkillTitle(item.skillID) ?? item.skillID
            return SettingsStatisticsBarItem(
                title: resolveCategoryName(item.contextKey),
                valueText: L10n.format(zhHans: "%@ · %d 次", en: "%@ · %d uses", skillName, item.actions),
                ratio: CGFloat(item.actions) / CGFloat(maxActions)
            )
        }
    }

    func trendPoints(from summary: UsageLearningSummary) -> [SettingsStatisticsTrendPoint] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage == .english ? "en_US_POSIX" : "zh_CN")
        formatter.dateFormat = "M/d"
        return summary.recentDailyActivities.map { item in
            SettingsStatisticsTrendPoint(label: formatter.string(from: item.date), value: item.actions)
        }
    }

    private func selectionRate(actions: Int, impressions: Int) -> String {
        guard impressions > 0 else { return L10n.text(zhHans: "曝光较少", en: "Low exposure") }
        let percentage = Int(round((Double(actions) / Double(max(impressions, 1))) * 100))
        return L10n.format(zhHans: "选择率 %d%%", en: "Selection rate %d%%", percentage)
    }
}
