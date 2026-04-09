import Foundation

package final class AskAutomationStore {
    package static let shared = AskAutomationStore()

    private struct JobsPayload: Codable {
        let version: Int
        let jobs: [AskAutomationJob]
    }

    private struct InboxPayload: Codable {
        let version: Int
        let items: [AskInboxItem]
    }

    private let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let queue = DispatchQueue(label: "com.nexask.ask-automation-store", qos: .utility)
    private let encoder = JSONEncoder()
    private let lineEncoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let rootDirectoryURLOverride: URL?

    private var draftCache: [String: AskAutomationDraft] = [:]

    package init(
        fileManager: FileManager = .default,
        notificationCenter: NotificationCenter = .default,
        rootDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.notificationCenter = notificationCenter
        self.rootDirectoryURLOverride = rootDirectoryURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        lineEncoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        ensureDirectories()
    }

    package func listJobs() -> [AskAutomationJob] {
        queue.sync {
            loadJobs().sorted {
                let lhs = $0.nextRunAt ?? .distantFuture
                let rhs = $1.nextRunAt ?? .distantFuture
                if lhs == rhs {
                    return $0.updatedAt > $1.updatedAt
                }
                return lhs < rhs
            }
        }
    }

    package func job(id: String) -> AskAutomationJob? {
        queue.sync {
            loadJobs().first { $0.id == id }
        }
    }

    package func saveDraft(_ draft: AskAutomationDraft) {
        queue.sync {
            draftCache[draft.id] = draft
        }
    }

    package func draft(id: String) -> AskAutomationDraft? {
        queue.sync {
            draftCache[id]
        }
    }

    @discardableResult
    package func createJob(from draft: AskAutomationDraft, now: Date = Date()) -> AskAutomationJob {
        queue.sync {
            draftCache[draft.id] = draft
            var jobs = loadJobs()
            let job = AskAutomationJob.make(from: draft, now: now)
            jobs.append(job)
            persistJobs(jobs)
            draftCache.removeValue(forKey: draft.id)
            post(AskAutomationNotificationNames.jobsDidChange)
            return job
        }
    }

    @discardableResult
    package func upsert(job: AskAutomationJob) -> AskAutomationJob {
        queue.sync {
            var jobs = loadJobs()
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index] = job
            } else {
                jobs.append(job)
            }
            persistJobs(jobs)
            post(AskAutomationNotificationNames.jobsDidChange)
            return job
        }
    }

    @discardableResult
    package func setJobEnabled(_ jobID: String, enabled: Bool, now: Date = Date()) -> AskAutomationJob? {
        queue.sync {
            var jobs = loadJobs()
            guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return nil }
            jobs[index].enabled = enabled
            jobs[index].updatedAt = now
            jobs[index].refreshNextRun(after: now)
            persistJobs(jobs)
            post(AskAutomationNotificationNames.jobsDidChange)
            return jobs[index]
        }
    }

    @discardableResult
    package func deleteJob(id: String) -> Bool {
        queue.sync {
            var jobs = loadJobs()
            let originalCount = jobs.count
            jobs.removeAll { $0.id == id }
            persistJobs(jobs)
            if jobs.count != originalCount {
                post(AskAutomationNotificationNames.jobsDidChange)
                return true
            }
            return false
        }
    }

    @discardableResult
    package func updateJobAfterRun(
        jobID: String,
        status: AskAutomationRunStatus,
        finishedAt: Date,
        now: Date = Date()
    ) -> AskAutomationJob? {
        queue.sync {
            var jobs = loadJobs()
            guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return nil }
            jobs[index].lastRunAt = finishedAt
            jobs[index].lastRunStatus = status
            jobs[index].updatedAt = now
            jobs[index].refreshNextRun(after: now)
            if jobs[index].trigger.kind == .onceAt {
                jobs[index].enabled = false
                jobs[index].nextRunAt = nil
            }
            persistJobs(jobs)
            post(AskAutomationNotificationNames.jobsDidChange)
            return jobs[index]
        }
    }

    package func listRuns(jobID: String? = nil, limit: Int = 40) -> [AskAutomationRunRecord] {
        queue.sync {
            let collapsed = collapseRuns(loadRunLines())
            let filtered = collapsed.filter { record in
                guard let jobID else { return true }
                return record.jobID == jobID
            }
            return Array(filtered.sorted(by: sortRuns).prefix(limit))
        }
    }

    package func recordRun(_ run: AskAutomationRunRecord) {
        queue.sync {
            appendRun(run)
            post(AskAutomationNotificationNames.runsDidChange)
        }
    }

    package func listInboxItems(limit: Int = 40) -> [AskInboxItem] {
        queue.sync {
            Array(loadInboxItems().sorted { $0.createdAt > $1.createdAt }.prefix(limit))
        }
    }

    package func saveInboxItem(_ item: AskInboxItem) {
        queue.sync {
            var items = loadInboxItems()
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.append(item)
            }
            persistInbox(items)
            post(AskAutomationNotificationNames.inboxDidChange)
        }
    }

    @discardableResult
    package func markInboxItemRead(_ id: String) -> AskInboxItem? {
        queue.sync {
            var items = loadInboxItems()
            guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
            items[index].isRead = true
            persistInbox(items)
            post(AskAutomationNotificationNames.inboxDidChange)
            return items[index]
        }
    }

    private var rootDirectoryURL: URL {
        if let rootDirectoryURLOverride {
            return rootDirectoryURLOverride
        }
        return AskKernelPersistencePaths.askRoot(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("Automation", isDirectory: true)
    }

    private var jobsFileURL: URL {
        rootDirectoryURL.appendingPathComponent("jobs.json")
    }

    private var inboxFileURL: URL {
        rootDirectoryURL.appendingPathComponent("inbox.json")
    }

    private var runsFileURL: URL {
        rootDirectoryURL.appendingPathComponent("runs.jsonl")
    }

    private func ensureDirectories() {
        try? fileManager.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: runsFileURL.path) {
            fileManager.createFile(atPath: runsFileURL.path, contents: Data())
        }
    }

    private func loadJobs() -> [AskAutomationJob] {
        guard let data = try? Data(contentsOf: jobsFileURL),
              let payload = try? decoder.decode(JobsPayload.self, from: data) else {
            return []
        }
        return payload.jobs
    }

    private func persistJobs(_ jobs: [AskAutomationJob]) {
        let payload = JobsPayload(version: 1, jobs: jobs)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: jobsFileURL, options: .atomic)
    }

    private func loadInboxItems() -> [AskInboxItem] {
        guard let data = try? Data(contentsOf: inboxFileURL),
              let payload = try? decoder.decode(InboxPayload.self, from: data) else {
            return []
        }
        return payload.items
    }

    private func persistInbox(_ items: [AskInboxItem]) {
        let payload = InboxPayload(version: 1, items: items)
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: inboxFileURL, options: .atomic)
    }

    private func loadRunLines() -> [AskAutomationRunRecord] {
        guard let data = try? Data(contentsOf: runsFileURL),
              let string = String(data: data, encoding: .utf8) else {
            return []
        }
        return string
            .split(separator: "\n")
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(AskAutomationRunRecord.self, from: data)
            }
    }

    private func appendRun(_ run: AskAutomationRunRecord) {
        ensureDirectories()
        guard let data = try? lineEncoder.encode(run) else { return }
        guard let handle = try? FileHandle(forWritingTo: runsFileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            return
        }
    }

    private func collapseRuns(_ runs: [AskAutomationRunRecord]) -> [AskAutomationRunRecord] {
        var latestByRunID: [String: AskAutomationRunRecord] = [:]
        for run in runs {
            let existing = latestByRunID[run.runID]
            if existing == nil || sortRuns(lhs: run, rhs: existing!) {
                latestByRunID[run.runID] = run
            }
        }
        return Array(latestByRunID.values)
    }

    private func sortRuns(lhs: AskAutomationRunRecord, rhs: AskAutomationRunRecord) -> Bool {
        let lhsDate = lhs.finishedAt ?? lhs.startedAt
        let rhsDate = rhs.finishedAt ?? rhs.startedAt
        if lhsDate == rhsDate {
            return lhs.runID > rhs.runID
        }
        return lhsDate > rhsDate
    }

    private func post(_ name: Notification.Name) {
        DispatchQueue.main.async {
            self.notificationCenter.post(name: name, object: nil)
        }
    }
}
