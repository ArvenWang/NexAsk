import AppKit
import Foundation

extension Notification.Name {
    static let knowledgeBaseAutoSyncDidChange = Notification.Name("nexhub.knowledgeBaseAutoSyncDidChange")
}

enum ReplyKnowledgeBaseNotionSyncMode {
    case incremental
    case full
}

struct ReplyKnowledgeBaseAutoSyncSnapshot {
    let isSyncing: Bool
    let isAutoSyncEnabled: Bool
    let lastSyncAt: Date?
    let nextSyncAt: Date?
    let statusMessage: String?
}

@MainActor
final class ReplyKnowledgeBaseAutoSyncCoordinator {
    static let shared = ReplyKnowledgeBaseAutoSyncCoordinator()

    private let settings: AppSettings
    private let notionSyncService: ReplyKnowledgeBaseNotionSyncService
    private let syncInterval: TimeInterval
    private let initialSyncDelay: TimeInterval

    private var timer: Timer?
    private var syncTask: Task<ReplyKnowledgeBaseNotionSyncSummary, Error>?
    private var observersInstalled = false
    private var statusMessage: String?

    private init(
        settings: AppSettings = .shared,
        notionSyncService: ReplyKnowledgeBaseNotionSyncService = .shared,
        syncInterval: TimeInterval = 15 * 60,
        initialSyncDelay: TimeInterval = 8
    ) {
        self.settings = settings
        self.notionSyncService = notionSyncService
        self.syncInterval = syncInterval
        self.initialSyncDelay = initialSyncDelay
    }

    var snapshot: ReplyKnowledgeBaseAutoSyncSnapshot {
        ReplyKnowledgeBaseAutoSyncSnapshot(
            isSyncing: syncTask != nil,
            isAutoSyncEnabled: canAutoSync,
            lastSyncAt: settings.knowledgeBaseNotionLastSyncAt,
            nextSyncAt: timer?.fireDate,
            statusMessage: statusMessage
        )
    }

    func start() {
        guard !observersInstalled else {
            refreshSchedule(allowImmediateSync: false)
            return
        }

        observersInstalled = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: .appSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        refreshSchedule(allowImmediateSync: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        syncTask?.cancel()
        syncTask = nil

        guard observersInstalled else { return }
        observersInstalled = false
        NotificationCenter.default.removeObserver(self, name: .appSettingsDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    func syncNow(mode: ReplyKnowledgeBaseNotionSyncMode) async throws -> ReplyKnowledgeBaseNotionSyncSummary {
        guard KnowledgeBaseFeatureFlags.notionEnabled else {
            statusMessage = nil
            postDidChange()
            return ReplyKnowledgeBaseNotionSyncSummary(importedCount: 0, updatedCount: 0, skippedCount: 0, failureMessages: [])
        }
        return try await runSync(mode: mode, initiatedAutomatically: false)
    }

    @objc private func handleSettingsChanged() {
        refreshSchedule(allowImmediateSync: true)
    }

    @objc private func handleAppDidBecomeActive() {
        refreshSchedule(allowImmediateSync: true)
    }

    @objc private func handleTimerFired() {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.runSync(mode: .incremental, initiatedAutomatically: true)
        }
    }

    private var canAutoSync: Bool {
        KnowledgeBaseFeatureFlags.notionEnabled &&
        settings.knowledgeBaseNotionAutoSyncEnabled &&
        !settings.notionIntegrationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshSchedule(allowImmediateSync: Bool) {
        timer?.invalidate()
        timer = nil

        guard canAutoSync else {
            if KnowledgeBaseFeatureFlags.notionEnabled,
               settings.notionIntegrationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = L10n.Settings.KnowledgeBase.waitingForToken
            } else {
                statusMessage = nil
            }
            postDidChange()
            return
        }

        let now = Date()
        let lastSyncAt = settings.knowledgeBaseNotionLastSyncAt
        let nextDueAt: Date
        if let lastSyncAt {
            nextDueAt = lastSyncAt.addingTimeInterval(syncInterval)
        } else {
            nextDueAt = now.addingTimeInterval(initialSyncDelay)
        }

        if allowImmediateSync && nextDueAt <= now {
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.runSync(mode: .incremental, initiatedAutomatically: true)
            }
            installTimer(fireAt: now.addingTimeInterval(syncInterval))
            return
        }

        installTimer(fireAt: nextDueAt)
    }

    private func installTimer(fireAt date: Date) {
        let timer = Timer(fireAt: date, interval: syncInterval, target: self, selector: #selector(handleTimerFired), userInfo: nil, repeats: true)
        timer.tolerance = min(60, syncInterval * 0.12)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        postDidChange()
    }

    private func runSync(mode: ReplyKnowledgeBaseNotionSyncMode, initiatedAutomatically: Bool) async throws -> ReplyKnowledgeBaseNotionSyncSummary {
        if let syncTask {
            return try await syncTask.value
        }

        let syncAnchor = Date()
        statusMessage = initiatedAutomatically
            ? L10n.text(zhHans: "正在后台同步 Notion…", en: "Syncing Notion in the background...")
            : L10n.text(zhHans: "正在同步 Notion…", en: "Syncing Notion...")
        postDidChange()

        let task = Task<ReplyKnowledgeBaseNotionSyncSummary, Error> {
            switch mode {
            case .incremental:
                return try await notionSyncService.syncIncrementalPages(since: settings.knowledgeBaseNotionLastSyncAt)
            case .full:
                return try await notionSyncService.syncRecentSharedPages(limit: 24)
            }
        }
        syncTask = task

        do {
            let summary = try await task.value
            syncTask = nil
            settings.knowledgeBaseNotionLastSyncAt = syncAnchor
            statusMessage = statusMessage(for: summary, initiatedAutomatically: initiatedAutomatically)
            refreshSchedule(allowImmediateSync: false)
            return summary
        } catch {
            syncTask = nil
            statusMessage = initiatedAutomatically
                ? L10n.format(zhHans: "Notion 后台同步失败：%@", en: "Background Notion sync failed: %@", error.localizedDescription)
                : error.localizedDescription
            refreshSchedule(allowImmediateSync: false)
            throw error
        }
    }

    private func statusMessage(for summary: ReplyKnowledgeBaseNotionSyncSummary, initiatedAutomatically: Bool) -> String {
        if summary.importedCount == 0 && summary.updatedCount == 0 && summary.skippedCount == 0 && summary.failureMessages.isEmpty {
            return initiatedAutomatically
                ? L10n.text(zhHans: "Notion 后台检查完成，暂时没有可同步的新页面。", en: "Background Notion check finished. No new pages are ready to sync yet.")
                : L10n.text(zhHans: "没有找到可同步的 Notion 页面。请先把页面共享给这个 Integration。", en: "No Notion pages are available to sync. Share the page with this integration first.")
        }

        if summary.importedCount == 0 && summary.updatedCount == 0 && summary.failureMessages.isEmpty {
            return initiatedAutomatically
                ? L10n.text(zhHans: "Notion 后台检查完成，知识库已是最新。", en: "Background Notion check finished. The knowledge base is already up to date.")
                : L10n.text(zhHans: "Notion 同步完成，知识库已是最新。", en: "Notion sync finished. The knowledge base is already up to date.")
        }

        var parts: [String] = [
            initiatedAutomatically
                ? L10n.text(zhHans: "Notion 后台同步完成", en: "Background Notion sync finished")
                : L10n.text(zhHans: "Notion 同步完成", en: "Notion sync finished"),
            L10n.format(zhHans: "新增 %d 个", en: "Imported %d", summary.importedCount),
            L10n.format(zhHans: "更新 %d 个", en: "Updated %d", summary.updatedCount)
        ]
        if summary.skippedCount > 0 {
            parts.append(L10n.format(zhHans: "无变更 %d 个", en: "Unchanged %d", summary.skippedCount))
        }
        if let failurePreview = summary.failureMessages.first, !failurePreview.isEmpty {
            parts.append(failurePreview)
        }
        return parts.joined(separator: "，")
    }

    private func postDidChange() {
        NotificationCenter.default.post(name: .knowledgeBaseAutoSyncDidChange, object: self)
    }
}
