import Foundation
import NexShared

#if !NEXHUB_PRODUCT_NEXHUB

final class AskAutomationScheduler: @unchecked Sendable {
    static let shared = AskAutomationScheduler()

    private let automationStore: AskAutomationStore
    private let runner: AskAutomationRunner
    private let diagnosticsLogger: DiagnosticsLogger
    private let notificationCenter: NotificationCenter
    private let queue = DispatchQueue(label: "com.nexhub.ask-automation-scheduler")

    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private var isStarted = false
    private var activeJobIDs: Set<String> = []

    init(
        automationStore: AskAutomationStore = .shared,
        runner: AskAutomationRunner = .shared,
        diagnosticsLogger: DiagnosticsLogger = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.automationStore = automationStore
        self.runner = runner
        self.diagnosticsLogger = diagnosticsLogger
        self.notificationCenter = notificationCenter
    }

    func start() {
        queue.async {
            guard !self.isStarted else { return }
            self.isStarted = true
            self.observeChangesIfNeeded()
            self.scheduleNextWake()
            Task {
                await self.runDueJobsNow()
            }
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.isStarted = false
            if let observer = self.observer {
                self.notificationCenter.removeObserver(observer)
                self.observer = nil
            }
        }
    }

    func runNow(jobID: String) {
        Task {
            await runJobIfPossible(jobID: jobID)
            queue.async {
                self.scheduleNextWake()
            }
        }
    }

    func runDueJobsNow(referenceDate: Date = Date()) async {
        let jobs = automationStore.listJobs().filter { job in
            job.enabled && (job.nextRunAt ?? .distantFuture) <= referenceDate
        }
        for job in jobs {
            await runJobIfPossible(jobID: job.id)
        }
        queue.async {
            self.scheduleNextWake()
        }
    }

    private func runJobIfPossible(jobID: String) async {
        let shouldRun = queue.sync { () -> Bool in
            guard !activeJobIDs.contains(jobID) else { return false }
            activeJobIDs.insert(jobID)
            return true
        }
        guard shouldRun else { return }
        defer {
            queue.async {
                self.activeJobIDs.remove(jobID)
            }
        }

        guard let job = automationStore.job(id: jobID), job.enabled else { return }
        diagnosticsLogger.log("ask.automation", "scheduler_run job=\(job.id) next=\(job.nextRunAt?.description ?? "nil")")
        _ = await runner.run(job: job)
    }

    private func observeChangesIfNeeded() {
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: .askAutomationJobsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.queue.async {
                self?.scheduleNextWake()
            }
        }
    }

    private func scheduleNextWake() {
        timer?.cancel()
        timer = nil

        guard isStarted else { return }
        let jobs = automationStore.listJobs().filter(\.enabled)
        guard let nextDate = jobs.compactMap(\.nextRunAt).min() else {
            diagnosticsLogger.log("ask.automation", "scheduler_idle")
            return
        }

        let delay = max(1, nextDate.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.runDueJobsNow()
            }
        }
        timer.resume()
        self.timer = timer
        diagnosticsLogger.log("ask.automation", "scheduler_next delay_seconds=\(Int(delay.rounded()))")
    }
}

#endif
