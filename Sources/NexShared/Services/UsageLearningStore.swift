import Foundation

enum ToolbarSkillSource: String, Codable {
    case primary
    case more
}

struct UsageLearningAdjustment {
    let scoreDelta: Double
    let reason: String?
}

struct UsageLearningTopSkillSummary {
    let skillID: String
    let actions: Int
    let impressions: Int
}

struct UsageLearningAffinitySummary {
    let contextKey: String
    let skillID: String
    let actions: Int
    let impressions: Int
}

struct UsageLearningDailyActivity {
    let date: Date
    let actions: Int
}

struct UsageLearningSummary {
    let totalRecentActions: Int
    let topGlobalSkills: [UsageLearningTopSkillSummary]
    let topBundleAffinities: [UsageLearningAffinitySummary]
    let topCategoryAffinities: [UsageLearningAffinitySummary]
    let recentDailyActivities: [UsageLearningDailyActivity]
}

private struct UsageCounter: Codable {
    var impressions: Int = 0
    var primaryActions: Int = 0
    var moreActions: Int = 0
    var dismissals: Int = 0
    var lastActionTimestamp: TimeInterval?

    var totalActions: Int { primaryActions + moreActions }
}

private struct RecentUsageAction: Codable {
    let skillID: String
    let selectionType: String
    let bundleID: String?
    let contentCategory: String
    let source: ToolbarSkillSource
    let timestamp: TimeInterval
}

private struct UsageLearningSnapshot: Codable {
    var global: [String: UsageCounter] = [:]
    var bySelectionType: [String: [String: UsageCounter]] = [:]
    var byBundleID: [String: [String: UsageCounter]] = [:]
    var byContentCategory: [String: [String: UsageCounter]] = [:]
    var recentActions: [RecentUsageAction] = []
    var totalRecordedActions: Int = 0
    var dailyActionBuckets: [String: Int] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        global = try container.decodeIfPresent([String: UsageCounter].self, forKey: .global) ?? [:]
        bySelectionType = try container.decodeIfPresent([String: [String: UsageCounter]].self, forKey: .bySelectionType) ?? [:]
        byBundleID = try container.decodeIfPresent([String: [String: UsageCounter]].self, forKey: .byBundleID) ?? [:]
        byContentCategory = try container.decodeIfPresent([String: [String: UsageCounter]].self, forKey: .byContentCategory) ?? [:]
        recentActions = try container.decodeIfPresent([RecentUsageAction].self, forKey: .recentActions) ?? []
        totalRecordedActions = try container.decodeIfPresent(Int.self, forKey: .totalRecordedActions) ?? 0
        dailyActionBuckets = try container.decodeIfPresent([String: Int].self, forKey: .dailyActionBuckets) ?? [:]
    }
}

final class UsageLearningStore {
    static let shared = UsageLearningStore()

    private let queue = DispatchQueue(label: "com.nexhub.usage-learning", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileURL: URL
    private var snapshot: UsageLearningSnapshot

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let fileURL {
            self.fileURL = fileURL
            try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let directoryURL = baseURL.appendingPathComponent(AppBrand.supportDirectoryName, isDirectory: true)
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let preferredFileURL = directoryURL.appendingPathComponent("usage_learning.json")
            Self.migrateLegacyUsageStoreIfNeeded(
                baseURL: baseURL,
                destinationURL: preferredFileURL,
                fileManager: fileManager
            )
            self.fileURL = preferredFileURL
        }

        if let data = try? Data(contentsOf: self.fileURL),
           let loaded = try? decoder.decode(UsageLearningSnapshot.self, from: data) {
            snapshot = loaded
        } else {
            snapshot = UsageLearningSnapshot()
        }
    }

    func recordImpression(
        skillIDs: [String],
        moreSkillIDs: [String],
        selectionType: String,
        bundleID: String?,
        contentCategory: String
    ) {
        let visibleSkillIDs = Array(Set(skillIDs + moreSkillIDs))
        guard !visibleSkillIDs.isEmpty else { return }

        queue.async {
            for skillID in visibleSkillIDs {
                self.incrementCounter(skillID: skillID, selectionType: selectionType, bundleID: bundleID, contentCategory: contentCategory) {
                    $0.impressions += 1
                }
            }
            self.persistSnapshot()
        }
    }

    func recordAction(
        skillID: String,
        source: ToolbarSkillSource,
        selectionType: String,
        bundleID: String?,
        contentCategory: String
    ) {
        queue.async {
            let now = Date()
            self.incrementCounter(skillID: skillID, selectionType: selectionType, bundleID: bundleID, contentCategory: contentCategory) {
                switch source {
                case .primary:
                    $0.primaryActions += 1
                case .more:
                    $0.moreActions += 1
                }
                $0.lastActionTimestamp = now.timeIntervalSince1970
            }

            self.snapshot.recentActions.append(
                RecentUsageAction(
                    skillID: skillID,
                    selectionType: selectionType,
                    bundleID: bundleID,
                    contentCategory: contentCategory,
                    source: source,
                    timestamp: now.timeIntervalSince1970
                )
            )
            if self.snapshot.recentActions.count > 200 {
                self.snapshot.recentActions.removeFirst(self.snapshot.recentActions.count - 200)
            }
            self.snapshot.totalRecordedActions += 1
            let dayKey = self.dayBucketKey(for: now)
            self.snapshot.dailyActionBuckets[dayKey, default: 0] += 1
            self.persistSnapshot()
        }
    }

    func recordDismissedExposure(
        skillIDs: [String],
        moreSkillIDs: [String],
        selectionType: String,
        bundleID: String?,
        contentCategory: String
    ) {
        let visibleSkillIDs = Array(Set(skillIDs + moreSkillIDs))
        guard !visibleSkillIDs.isEmpty else { return }

        queue.async {
            for skillID in visibleSkillIDs {
                self.incrementCounter(skillID: skillID, selectionType: selectionType, bundleID: bundleID, contentCategory: contentCategory) {
                    $0.dismissals += 1
                }
            }
            self.persistSnapshot()
        }
    }

    func adjustments(
        for skillIDs: [String],
        selectionType: String,
        bundleID: String?,
        contentCategory: String
    ) -> [String: UsageLearningAdjustment] {
        queue.sync {
            let bundleKey = normalizedBundleKey(bundleID)
            return Dictionary(uniqueKeysWithValues: skillIDs.map { skillID in
                let global = snapshot.global[skillID]
                let typeStats = snapshot.bySelectionType[selectionType]?[skillID]
                let bundleStats = snapshot.byBundleID[bundleKey]?[skillID]
                let categoryStats = snapshot.byContentCategory[contentCategory]?[skillID]

                let globalBoost = smoothedCTR(global, prior: 0.18) * 0.03
                let typeBoost = smoothedCTR(typeStats, prior: 0.12) * 0.05
                let bundleBoost = smoothedCTR(bundleStats, prior: 0.08) * 0.06
                let categoryBoost = smoothedCTR(categoryStats, prior: 0.1) * 0.08
                let recencyBoost = recentBonus(
                    skillID: skillID,
                    selectionType: selectionType,
                    bundleID: bundleID,
                    contentCategory: contentCategory
                )
                let dismissPenalty = dismissalPenalty(
                    global: global,
                    typeStats: typeStats,
                    bundleStats: bundleStats,
                    categoryStats: categoryStats
                )
                let total = max(-0.06, min(0.14, globalBoost + typeBoost + bundleBoost + categoryBoost + recencyBoost - dismissPenalty))

                let reasons = [
                    bundleBoost >= 0.035 ? L10n.text(zhHans: "当前 App 中更常被使用", en: "Used more often in this app") : nil,
                    categoryBoost >= 0.03 ? L10n.text(zhHans: "在相似内容类型下更常被选择", en: "Chosen more often for similar content") : nil,
                    typeBoost >= 0.02 ? L10n.text(zhHans: "在该选择类型下有使用偏好", en: "Preferred for this selection type") : nil,
                    recencyBoost >= 0.025 ? L10n.text(zhHans: "最近刚用过这个技能", en: "This skill was used recently") : nil
                ].compactMap { $0 }

                return (
                    skillID,
                    UsageLearningAdjustment(
                        scoreDelta: total,
                        reason: reasons.isEmpty ? nil : reasons.joined(separator: "，")
                    )
                )
            })
        }
    }

    func summary() -> UsageLearningSummary {
        queue.sync {
            let totalRecordedActions = restoredTotalRecordedActions()
            let topGlobalSkills = snapshot.global
                .map { key, counter in
                    UsageLearningTopSkillSummary(
                        skillID: key,
                        actions: counter.totalActions,
                        impressions: counter.impressions
                    )
                }
                .filter { $0.actions > 0 || $0.impressions > 0 }
                .sorted {
                    if $0.actions != $1.actions { return $0.actions > $1.actions }
                    return $0.impressions > $1.impressions
                }
                .prefix(5)
                .map { $0 }

            let topBundleAffinities = topAffinities(in: snapshot.byBundleID)
            let topCategoryAffinities = topAffinities(in: snapshot.byContentCategory)
            let recentDailyActivities = recentDailyActivity(windowDays: 7)

            return UsageLearningSummary(
                totalRecentActions: totalRecordedActions,
                topGlobalSkills: topGlobalSkills,
                topBundleAffinities: topBundleAffinities,
                topCategoryAffinities: topCategoryAffinities,
                recentDailyActivities: recentDailyActivities
            )
        }
    }

    private func incrementCounter(
        skillID: String,
        selectionType: String,
        bundleID: String?,
        contentCategory: String,
        update: (inout UsageCounter) -> Void
    ) {
        mutateCounter(in: &snapshot.global, skillID: skillID, update: update)
        mutateNestedCounter(in: &snapshot.bySelectionType, key: selectionType, skillID: skillID, update: update)
        mutateNestedCounter(in: &snapshot.byBundleID, key: normalizedBundleKey(bundleID), skillID: skillID, update: update)
        mutateNestedCounter(in: &snapshot.byContentCategory, key: contentCategory, skillID: skillID, update: update)
    }

    private func mutateCounter(
        in storage: inout [String: UsageCounter],
        skillID: String,
        update: (inout UsageCounter) -> Void
    ) {
        var counter = storage[skillID] ?? UsageCounter()
        update(&counter)
        storage[skillID] = counter
    }

    private func mutateNestedCounter(
        in storage: inout [String: [String: UsageCounter]],
        key: String,
        skillID: String,
        update: (inout UsageCounter) -> Void
    ) {
        var nested = storage[key] ?? [:]
        mutateCounter(in: &nested, skillID: skillID, update: update)
        storage[key] = nested
    }

    private func smoothedCTR(_ counter: UsageCounter?, prior: Double) -> Double {
        guard let counter else { return 0 }
        let impressions = Double(max(counter.impressions, 0))
        let weightedActions = Double(counter.primaryActions) + Double(counter.moreActions) * 0.6
        let weightedDismissals = Double(counter.dismissals) * 0.18
        return (weightedActions + prior) / (impressions + 1.6 + weightedDismissals)
    }

    private func recentBonus(
        skillID: String,
        selectionType: String,
        bundleID: String?,
        contentCategory: String
    ) -> Double {
        let now = Date().timeIntervalSince1970
        let recentActions = snapshot.recentActions.suffix(40)
        var total: Double = 0

        for action in recentActions.reversed() {
            guard action.skillID == skillID else { continue }
            let age = now - action.timestamp
            guard age <= 14 * 24 * 60 * 60 else { continue }

            if action.selectionType == selectionType && action.bundleID == bundleID && action.contentCategory == contentCategory {
                total += 0.028
            } else if action.selectionType == selectionType && action.contentCategory == contentCategory {
                total += 0.018
            } else if action.selectionType == selectionType {
                total += 0.01
            }
        }

        return min(total, 0.08)
    }

    private func dismissalPenalty(
        global: UsageCounter?,
        typeStats: UsageCounter?,
        bundleStats: UsageCounter?,
        categoryStats: UsageCounter?
    ) -> Double {
        let counters = [global, typeStats, bundleStats, categoryStats]
        let penalty = counters.reduce(Double.zero) { partial, counter in
            guard let counter, counter.dismissals > counter.totalActions else { return partial }
            let gap = Double(counter.dismissals - counter.totalActions)
            return partial + min(gap * 0.004, 0.015)
        }
        return min(penalty, 0.035)
    }

    private func topAffinities(in storage: [String: [String: UsageCounter]]) -> [UsageLearningAffinitySummary] {
        storage.flatMap { contextKey, skills in
            skills.compactMap { skillID, counter in
                guard counter.totalActions > 0 else { return nil }
                return UsageLearningAffinitySummary(
                    contextKey: contextKey,
                    skillID: skillID,
                    actions: counter.totalActions,
                    impressions: counter.impressions
                )
            }
        }
        .sorted {
            if $0.actions != $1.actions { return $0.actions > $1.actions }
            return $0.impressions > $1.impressions
        }
        .prefix(5)
        .map { $0 }
    }

    private func recentDailyActivity(windowDays: Int) -> [UsageLearningDailyActivity] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let buckets = restoredDailyActionBuckets(windowDays: windowDays)

        return (0..<windowDays).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let actions = buckets[dayBucketKey(for: date)] ?? 0
            return UsageLearningDailyActivity(date: date, actions: actions)
        }
    }

    private func restoredTotalRecordedActions() -> Int {
        let aggregateTotal = snapshot.global.values.reduce(0) { $0 + $1.totalActions }
        return max(snapshot.totalRecordedActions, aggregateTotal)
    }

    private func restoredDailyActionBuckets(windowDays: Int) -> [String: Int] {
        var buckets = snapshot.dailyActionBuckets
        let reconstructedBuckets = reconstructedDailyBucketsFromRecentActions()
        for (key, value) in reconstructedBuckets {
            buckets[key] = max(buckets[key] ?? 0, value)
        }

        let knownTotal = buckets.values.reduce(0, +)
        let estimatedRecentTotal = estimatedRecentActions(windowDays: windowDays)
        let missing = max(0, estimatedRecentTotal - knownTotal)
        if missing > 0 {
            let anchorDate = recentOverflowAnchorDate(windowDays: windowDays) ?? Date()
            let anchorKey = dayBucketKey(for: anchorDate)
            buckets[anchorKey, default: 0] += missing
        }

        return buckets
    }

    private func reconstructedDailyBucketsFromRecentActions() -> [String: Int] {
        var buckets: [String: Int] = [:]
        for action in snapshot.recentActions {
            let date = Date(timeIntervalSince1970: action.timestamp)
            let key = dayBucketKey(for: date)
            buckets[key, default: 0] += 1
        }
        return buckets
    }

    private func estimatedRecentActions(windowDays: Int) -> Int {
        let recentActionCount = snapshot.recentActions.count
        let aggregateTotal = restoredTotalRecordedActions()
        guard recentActionCount > 0 else { return min(aggregateTotal, snapshot.dailyActionBuckets.values.reduce(0, +)) }

        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -(windowDays - 1), to: calendar.startOfDay(for: Date())) ?? Date.distantPast
        let oldestRecentActionDate = snapshot.recentActions
            .map { Date(timeIntervalSince1970: $0.timestamp) }
            .min()

        guard let oldestRecentActionDate, oldestRecentActionDate >= cutoff else {
            return max(snapshot.dailyActionBuckets.values.reduce(0, +), recentActionCount)
        }

        if snapshot.totalRecordedActions > 0 && snapshot.totalRecordedActions < aggregateTotal {
            return max(snapshot.dailyActionBuckets.values.reduce(0, +), recentActionCount)
        }

        return aggregateTotal
    }

    private func recentOverflowAnchorDate(windowDays: Int) -> Date? {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -(windowDays - 1), to: calendar.startOfDay(for: Date())) ?? Date.distantPast
        return snapshot.recentActions
            .map { Date(timeIntervalSince1970: $0.timestamp) }
            .filter { $0 >= cutoff }
            .min()
    }

    private static func migrateLegacyUsageStoreIfNeeded(
        baseURL: URL,
        destinationURL: URL,
        fileManager: FileManager
    ) {
        guard !fileManager.fileExists(atPath: destinationURL.path) else { return }

        for legacyDirectoryName in AppBrand.legacySupportDirectoryNames {
            let legacyURL = baseURL
                .appendingPathComponent(legacyDirectoryName, isDirectory: true)
                .appendingPathComponent("usage_learning.json", isDirectory: false)
            guard fileManager.fileExists(atPath: legacyURL.path) else { continue }
            try? fileManager.copyItem(at: legacyURL, to: destinationURL)
            return
        }
    }

    private func dayBucketKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func normalizedBundleKey(_ bundleID: String?) -> String {
        let trimmed = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private func persistSnapshot() {
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
