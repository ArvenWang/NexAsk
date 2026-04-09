import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskSystemExecutorTests: XCTestCase {
    func testWriteTodoPersistsChecklistAndMirrorsActiveProgressMetadata() async throws {
        let taskStore = AskInMemoryTaskStore(
            persistToDisk: false,
            rootDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let executor = AskSystemExecutor(taskStore: taskStore)
        let task = makeTask(sessionID: "todo-session", title: "ASK persistent assistant closure")
        await taskStore.save(task)

        let result = await executor.execute(
            request: makeRequest(
                task: task,
                capabilityID: "system.write_todo",
                arguments: [
                    "session_id": "todo-session",
                    "items_json": #"[{"content":"Collapse dual runtime seams","status":"completed"},{"content":"Connect MCP live bridge","status":"in_progress"},{"content":"Stabilize todo memory","status":"pending"}]"#
                ]
            )
        )

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.metadata["task_todo_count"], "3")
        XCTAssertEqual(result.metadata["task_todo_completed_count"], "1")
        XCTAssertEqual(result.metadata["task_todo_in_progress_count"], "1")
        XCTAssertEqual(result.metadata["active_task_todo_count"], "3")
        XCTAssertTrue(result.metadata["task_progress_summary"]?.contains("1/3 completed") == true)
        XCTAssertTrue(result.metadata["task_todo_summary"]?.contains("[x] Collapse dual runtime seams") == true)
        XCTAssertTrue(result.metadata["task_todo_summary"]?.contains("[-] Connect MCP live bridge") == true)

        let storedTaskValue = await taskStore.task(id: task.id)
        let storedTask = try XCTUnwrap(storedTaskValue)
        XCTAssertEqual(storedTask.checklistItems.count, 3)
        XCTAssertEqual(storedTask.checklistItems[0].status, .completed)
        XCTAssertEqual(storedTask.checklistItems[1].status, .inProgress)
        XCTAssertEqual(storedTask.checklistItems[2].status, .pending)
    }

    func testWriteTodoAcceptsEmptyListToClearChecklist() async throws {
        let taskStore = AskInMemoryTaskStore(
            persistToDisk: false,
            rootDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        let executor = AskSystemExecutor(taskStore: taskStore)
        let task = makeTask(sessionID: "todo-clear", title: "Clear checklist").revised(
            checklist: [
                AskTaskChecklistItem(
                    id: "todo-1",
                    title: "Existing item",
                    status: .pending,
                    note: nil,
                    updatedAt: Date()
                )
            ]
        )
        await taskStore.save(task)

        let result = await executor.execute(
            request: makeRequest(
                task: task,
                capabilityID: "system.write_todo",
                arguments: [
                    "session_id": "todo-clear",
                    "items_json": "[]"
                ]
            )
        )

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.metadata["task_todo_count"], "0")
        XCTAssertEqual(result.metadata["active_task_todo_count"], "0")
        XCTAssertEqual(result.metadata["task_progress_summary"], "No checklist items recorded.")

        let storedTaskValue = await taskStore.task(id: task.id)
        let storedTask = try XCTUnwrap(storedTaskValue)
        XCTAssertTrue(storedTask.checklistItems.isEmpty)
    }

    private func makeTask(
        sessionID: String,
        title: String,
        objective: String = "Close the remaining ASK persistent assistant work."
    ) -> AskAgentTask {
        let invocation = AskInvocation(
            id: UUID().uuidString.lowercased(),
            sessionID: sessionID,
            parentTaskID: nil,
            prompt: objective,
            surface: .cli,
            requestedMode: .interactive,
            sourceBundleID: nil,
            sourceAppName: nil,
            createdAt: Date(),
            metadata: [
                "session_id": sessionID,
                "workspace_root": "/tmp/ask-persistent"
            ]
        )
        let context = AskExecutionContext.empty(
            surface: .cli,
            sourceBundleID: nil,
            sourceAppName: nil,
            metadata: invocation.metadata
        )
        return AskAgentTask.make(
            title: title,
            objective: objective,
            mode: .interactive,
            invocation: invocation,
            context: context
        )
    }

    private func makeRequest(
        task: AskAgentTask,
        capabilityID: String,
        arguments: AskInvocationMetadata
    ) -> AskCapabilityExecutionRequest {
        AskCapabilityExecutionRequest(
            task: task,
            capability: AskCapabilityDefinition(
                id: capabilityID,
                domain: .system,
                summary: "test",
                riskClass: .reversible,
                visibilityClass: .silent,
                supportsUnattendedExecution: true,
                supportsPreview: false,
                supportsRollback: false,
                requiredContextKeys: []
            ),
            decision: AskPolicyDecision(
                kind: .allow,
                reason: "test",
                requiresForeground: false,
                profileID: "interactive"
            ),
            arguments: arguments,
            dryRun: false,
            requestedAt: Date()
        )
    }
}
