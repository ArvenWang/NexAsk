import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskAutomationStoreTests: XCTestCase {
    func testCreateJobPersistsAndComputesNextRun() throws {
        let root = makeRoot()
        let notificationCenter = NotificationCenter()
        let store = AskAutomationStore(
            fileManager: .default,
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )
        let parser = AskAutomationDraftParser()
        let now = referenceDate()
        let draft = parser.parse("每天 9 点检查官网更新", now: now)

        let job = store.createJob(from: try XCTUnwrap(draft), now: now)
        let reloadedStore = AskAutomationStore(
            fileManager: .default,
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )
        let jobs = reloadedStore.listJobs()

        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.id, job.id)
        XCTAssertEqual(jobs.first?.trigger.kind, .dailyAt)
        XCTAssertNotNil(jobs.first?.nextRunAt)
    }

    func testRunAndInboxPersistenceSurviveReload() {
        let root = makeRoot()
        let notificationCenter = NotificationCenter()
        let store = AskAutomationStore(
            fileManager: .default,
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )

        let run = AskAutomationRunRecord(
            id: UUID().uuidString.lowercased(),
            jobID: "job-1",
            runID: "run-1",
            startedAt: referenceDate(),
            finishedAt: referenceDate().addingTimeInterval(30),
            status: .completed,
            summary: "checked updates",
            toolSteps: ["search_web", "collect_url"],
            artifacts: [AskAutomationArtifact(kind: "url", title: "OpenAI", value: "https://openai.com")],
            error: nil,
            inboxItemID: "inbox-1",
            sessionID: nil,
            kernelInvocationID: nil,
            kernelTaskID: nil,
            kernelMode: nil,
            kernelProfileID: nil,
            workspaceRoot: nil,
            pendingApprovalActionID: nil,
            agentState: nil
        )
        let item = AskInboxItem(
            id: "inbox-1",
            kind: "automation_result",
            title: "官网更新检查",
            summary: "发现了新的更新",
            createdAt: referenceDate(),
            sourceJobID: "job-1",
            sourceRunID: "run-1",
            sourceTaskID: nil,
            sourceTaskStatus: nil,
            assistantDeliveryChannel: nil,
            activeTaskID: nil,
            activeTaskResumeToken: nil,
            workspaceRoot: nil,
            actions: [AskInboxAction(label: "查看", value: "open")],
            isRead: false
        )

        store.recordRun(run)
        store.saveInboxItem(item)

        let reloadedStore = AskAutomationStore(
            fileManager: .default,
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )

        XCTAssertEqual(reloadedStore.listRuns(jobID: "job-1", limit: 5).first?.summary, "checked updates")
        XCTAssertEqual(reloadedStore.listInboxItems(limit: 5).first?.id, "inbox-1")
    }

    private func makeRoot(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create automation store root: \(error)", file: file, line: line)
        }
        return root
    }

    private func referenceDate() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .current
        return calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 11, minute: 30)) ?? Date()
    }
}
