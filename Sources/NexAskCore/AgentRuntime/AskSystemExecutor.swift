import Foundation
import NexShared
import UserNotifications

struct AskSystemExecutor: AskCapabilityExecuting {
    let supportedCapabilityIDs: [AskCapabilityID] = [
        "system.prepare_assistant_brief",
        "system.deliver_notification",
        "system.deliver_inbox_item",
        "system.list_tasks",
        "system.get_task",
        "system.update_task",
        "system.stop_task",
        "system.resume_task",
        "system.write_todo",
        "system.spawn_subtask"
    ]

    private let inboxStore: AskInboxStore
    private let taskStore: any AskTaskStoring

    init(
        inboxStore: AskInboxStore = .shared,
        taskStore: any AskTaskStoring
    ) {
        self.inboxStore = inboxStore
        self.taskStore = taskStore
    }

    func execute(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        switch request.capability.id {
        case "system.prepare_assistant_brief":
            return prepareAssistantBrief(request: request)
        case "system.deliver_notification":
            return await deliverNotification(request: request)
        case "system.deliver_inbox_item":
            return deliverInboxItem(request: request)
        case "system.list_tasks":
            return await listTasks(request: request)
        case "system.get_task":
            return await getTask(request: request)
        case "system.update_task":
            return await updateTask(request: request)
        case "system.stop_task":
            return await stopTask(request: request)
        case "system.resume_task":
            return await resumeTask(request: request)
        case "system.write_todo":
            return await writeTodo(request: request)
        case "system.spawn_subtask":
            return await spawnSubtask(request: request)
        default:
            return .unsupported(summary: "Unsupported system capability: \(request.capability.id)")
        }
    }

    private func prepareAssistantBrief(request: AskCapabilityExecutionRequest) -> AskCapabilityExecutionResult {
        let brief = resolvedAssistantBrief(request: request)
        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Prepared a reusable assistant brief.",
            approvalID: nil,
            artifacts: brief.artifacts(),
            metadata: brief.metadata(channel: .brief)
        )
    }

    private func deliverNotification(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        let brief = resolvedAssistantBrief(request: request)
        let title = brief.title
        let body = brief.body

        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "A notification title or body was missing.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared a local notification preview.",
                approvalID: nil,
                artifacts: brief.artifacts() + [
                    AskCapabilityArtifact(kind: "notification_title", value: title),
                    AskCapabilityArtifact(kind: "notification_body", value: String(body.prefix(180)))
                ],
                metadata: brief.metadata(channel: .notification).merging([
                    "notification_title": title,
                    "notification_body": String(body.prefix(180))
                ], uniquingKeysWith: { _, new in new })
            )
        }

        let center = UNUserNotificationCenter.current()
        let granted = await requestAuthorizationIfNeeded(center: center)
        guard granted else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "Notification permission was not granted.",
                approvalID: nil,
                artifacts: [],
                metadata: brief.metadata(channel: .notification).merging([
                    "notification_title": title
                ], uniquingKeysWith: { _, new in new })
            )
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.count > 180 ? String(body.prefix(180)) + "…" : body
        content.userInfo = AskAssistantFollowUpActivation
            .from(brief: brief, channel: .notification)
            .notificationUserInfo
        let notificationRequest = UNNotificationRequest(
            identifier: UUID().uuidString.lowercased(),
            content: content,
            trigger: nil
        )

        do {
            try await center.add(notificationRequest)
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Delivered a local notification.",
                approvalID: nil,
                artifacts: brief.artifacts() + [
                    AskCapabilityArtifact(kind: "notification_title", value: title),
                    AskCapabilityArtifact(kind: "notification_body", value: content.body)
                ],
                metadata: brief.metadata(channel: .notification).merging([
                    "notification_title": title,
                    "notification_body": content.body
                ], uniquingKeysWith: { _, new in new })
            )
        } catch {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "Failed to deliver the local notification.",
                approvalID: nil,
                artifacts: [],
                metadata: brief.metadata(channel: .notification).merging([
                    "notification_title": title,
                    "error": error.localizedDescription
                ], uniquingKeysWith: { _, new in new })
            )
        }
    }

    private func deliverInboxItem(request: AskCapabilityExecutionRequest) -> AskCapabilityExecutionResult {
        let brief = resolvedAssistantBrief(request: request)
        let title = brief.title
        let summary = brief.summary
        let kind = brief.kind

        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "An inbox title or summary was missing.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let actions = decodedInboxActions(from: request.arguments)
        let followUpActivation = AskAssistantFollowUpActivation.from(brief: brief, channel: .inbox)
        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared an Ask inbox item preview.",
                approvalID: nil,
                artifacts: brief.artifacts() + [
                    AskCapabilityArtifact(kind: "inbox_title", value: title),
                    AskCapabilityArtifact(kind: "inbox_summary", value: String(summary.prefix(180)))
                ],
                metadata: brief.metadata(channel: .inbox).merging([
                    "inbox_title": title,
                    "inbox_summary": String(summary.prefix(180)),
                    "inbox_kind": kind
                ], uniquingKeysWith: { _, new in new })
            )
        }

        let item = AskInboxItem(
            id: UUID().uuidString.lowercased(),
            kind: kind,
            title: title,
            summary: summary,
            createdAt: Date(),
            sourceJobID: followUpActivation.sourceJobID,
            sourceRunID: followUpActivation.sourceRunID,
            sourceTaskID: followUpActivation.sourceTaskID,
            sourceTaskStatus: followUpActivation.sourceTaskStatus,
            assistantDeliveryChannel: followUpActivation.deliveryChannel,
            activeTaskID: followUpActivation.activeTaskID,
            activeTaskResumeToken: followUpActivation.resumeToken,
            workspaceRoot: followUpActivation.workspaceRoot,
            actions: actions,
            isRead: false
        )
        inboxStore.save(item)
        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Delivered an Ask inbox item.",
            approvalID: nil,
            artifacts: brief.artifacts() + [
                AskCapabilityArtifact(kind: "inbox_title", value: title),
                AskCapabilityArtifact(kind: "inbox_summary", value: String(summary.prefix(180)))
            ],
            metadata: brief.metadata(channel: .inbox).merging([
                "saved_inbox_item_id": item.id,
                "inbox_title": title,
                "inbox_kind": kind
            ], uniquingKeysWith: { _, new in new })
        )
    }

    private func spawnSubtask(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        let title = firstNonEmptyValue(
            in: request.arguments,
            keys: ["title", "name", "subtask_title"]
        ) ?? String(request.task.title.prefix(48))
        let objective = firstNonEmptyValue(
            in: request.arguments,
            keys: ["objective", "summary", "spec", "subtask", "task"]
        ) ?? title
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedObjective.isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "A subtask title or objective was missing.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let workspaceRoot = firstNonEmptyValue(
            in: request.arguments,
            keys: ["workspace_root", "project_root"]
        ) ?? request.task.context.workspaceRootPath

        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared a child task outline.",
                approvalID: nil,
                artifacts: [
                    AskCapabilityArtifact(kind: "subtask_title", value: trimmedTitle),
                    AskCapabilityArtifact(kind: "subtask_objective", value: String(trimmedObjective.prefix(180)))
                ],
                metadata: [
                    "subtask_title": trimmedTitle,
                    "subtask_objective": String(trimmedObjective.prefix(180)),
                    "workspace_root": workspaceRoot ?? ""
                ]
            )
        }

        let subtask = AskAgentTask.makeSubtask(
            title: trimmedTitle,
            objective: trimmedObjective,
            parentTask: request.task,
            workspaceRoot: workspaceRoot,
            metadata: [
                "spawned_by_capability": request.capability.id,
                "session_id": request.task.metadata["session_id"] ?? ""
            ]
        )
        await taskStore.save(subtask)
        let resumeToken = taskResumeToken(for: subtask)
        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Recorded a focused child task.",
            approvalID: nil,
            artifacts: [
                AskCapabilityArtifact(kind: "subtask_id", value: subtask.id),
                AskCapabilityArtifact(kind: "subtask_title", value: subtask.title),
                AskCapabilityArtifact(kind: "subtask_resume_token", value: resumeToken)
            ],
            metadata: [
                "subtask_id": subtask.id,
                "subtask_title": subtask.title,
                "subtask_objective": String(subtask.objective.prefix(220)),
                "subtask_status": subtask.status.rawValue,
                "subtask_resume_token": resumeToken,
                "parent_task_id": request.task.id,
                "root_task_id": request.task.lineage.rootTaskID,
                "workspace_root": workspaceRoot ?? ""
            ]
        )
    }

    private func resumeTask(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let sessionID = (firstNonEmptyValue(in: request.arguments, keys: ["session_id"])
            ?? request.task.metadata["session_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !sessionID.isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No coding session context was available for task resume.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let tasks = await taskStore.tasks(for: sessionID)
        guard !tasks.isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No recorded tasks were found for the current coding session.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let requestedTaskID = firstNonEmptyValue(in: request.arguments, keys: ["task_id", "subtask_id"])
        let requestedResumeToken = firstNonEmptyValue(in: request.arguments, keys: ["resume_token", "task_token"])
        let requestedTitle = firstNonEmptyValue(in: request.arguments, keys: ["title", "task_title", "query", "subtask_title"])
        let requestedWorkspaceRoot = firstNonEmptyValue(in: request.arguments, keys: ["workspace_root", "project_root"])

        guard let candidate = resolvedTaskToResume(
            requestedTaskID: requestedTaskID,
            requestedResumeToken: requestedResumeToken,
            requestedTitle: requestedTitle,
            requestedWorkspaceRoot: requestedWorkspaceRoot,
            tasks: tasks
        ) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No matching recorded task could be resumed.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared a task-resume preview.",
                approvalID: nil,
                artifacts: [
                    AskCapabilityArtifact(kind: "active_task_id", value: candidate.id),
                    AskCapabilityArtifact(kind: "active_task_title", value: candidate.title),
                    AskCapabilityArtifact(kind: "active_task_resume_token", value: taskResumeToken(for: candidate))
                ],
                metadata: resumeMetadata(for: candidate, workspaceRootOverride: requestedWorkspaceRoot)
            )
        }

        let effectiveStatus: AskTaskStatus = {
            switch candidate.status {
            case .queued, .planning, .blocked:
                return .running
            case .waitingApproval, .running, .completed, .failed, .cancelled:
                return candidate.status
            }
        }()

        let effectiveTask: AskAgentTask
        if effectiveStatus != candidate.status,
           let updatedTask = await taskStore.mark(
                taskID: candidate.id,
                status: effectiveStatus,
                pendingApprovalID: candidate.pendingApprovalID,
                appendingArtifacts: ["resumed_in_session:\(sessionID)"],
                mergingMetadata: [
                    "last_resumed_session_id": sessionID,
                    "last_resumed_at": ISO8601DateFormatter().string(from: Date())
                ]
           ) {
            effectiveTask = updatedTask
        } else {
            effectiveTask = candidate
        }

        let statusSuffix: String
        switch effectiveTask.status {
        case .waitingApproval:
            statusSuffix = " It is currently waiting for approval."
        case .completed, .failed, .cancelled:
            statusSuffix = " Restored it as historical context from a terminal task."
        case .queued, .planning, .running, .blocked:
            statusSuffix = ""
        }

        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Restored the recorded task context: \(effectiveTask.title)." + statusSuffix,
            approvalID: nil,
            artifacts: [
                AskCapabilityArtifact(kind: "active_task_id", value: effectiveTask.id),
                AskCapabilityArtifact(kind: "active_task_title", value: effectiveTask.title),
                AskCapabilityArtifact(kind: "active_task_resume_token", value: taskResumeToken(for: effectiveTask))
            ],
            metadata: resumeMetadata(for: effectiveTask, workspaceRootOverride: requestedWorkspaceRoot)
        )
    }

    private func writeTodo(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let sessionID = resolvedSessionID(from: request) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No coding session context was available for writing todo items.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let requestedWorkspaceRoot = firstNonEmptyValue(in: request.arguments, keys: ["workspace_root", "project_root"])
        let tasks = await taskStore.tasks(for: sessionID)
        guard !tasks.isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No recorded tasks were found for the current coding session.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        guard let checklist = decodedChecklistItems(from: request.arguments) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "A valid todo item list was required. Pass items with content and optional status.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        guard let candidate = resolvedTaskForChecklist(
            request: request,
            requestedWorkspaceRoot: requestedWorkspaceRoot,
            tasks: tasks
        ) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No matching recorded task could be found for this todo list.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let updatedTask = candidate.revised(
            checklist: checklist,
            appendingArtifacts: ["todo_write:\(checklist.count)"],
            mergingMetadata: todoWriteMetadata(sessionID: sessionID, itemCount: checklist.count)
        )
        let includeActiveMirror = isActiveTask(updatedTask, request: request)

        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared a todo-list update preview for \(updatedTask.title).",
                approvalID: nil,
                artifacts: [
                    AskCapabilityArtifact(kind: "task_id", value: updatedTask.id),
                    AskCapabilityArtifact(kind: "task_title", value: updatedTask.title),
                    AskCapabilityArtifact(kind: "task_resume_token", value: taskResumeToken(for: updatedTask))
                ],
                metadata: taskMetadata(
                    for: updatedTask,
                    includeActiveMirror: includeActiveMirror
                )
            )
        }

        await taskStore.save(updatedTask)
        let summary = checklist.isEmpty
            ? "Cleared the task todo list for \(updatedTask.title)."
            : "Updated the task todo list for \(updatedTask.title). \(updatedTask.todoProgressSummary)"

        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: summary,
            approvalID: nil,
            artifacts: [
                AskCapabilityArtifact(kind: "task_id", value: updatedTask.id),
                AskCapabilityArtifact(kind: "task_title", value: updatedTask.title),
                AskCapabilityArtifact(kind: "task_resume_token", value: taskResumeToken(for: updatedTask)),
                AskCapabilityArtifact(kind: "task_todo_count", value: String(updatedTask.todoCount))
            ],
            metadata: taskMetadata(
                for: updatedTask,
                includeActiveMirror: includeActiveMirror
            )
        )
    }

    private func listTasks(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let sessionID = resolvedSessionID(from: request) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No coding session context was available for listing tasks.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let requestedWorkspaceRoot = firstNonEmptyValue(in: request.arguments, keys: ["workspace_root", "project_root"])
        let includeTerminal = boolValue(in: request.arguments, keys: ["include_terminal", "include_completed", "include_all"]) ?? false
        let limit = min(max(integerValue(in: request.arguments, keys: ["limit", "max_count"]) ?? 8, 1), 24)
        let tasks = preferredWorkspaceScopedTasks(
            await taskStore.tasks(for: sessionID),
            requestedWorkspaceRoot: requestedWorkspaceRoot
        )
        let openTasks = tasks.filter { !isTerminal($0.status) }
        let listedSource = includeTerminal ? tasks : (openTasks.isEmpty ? tasks : openTasks)
        guard !listedSource.isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No recorded tasks were found for the current coding session.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let listedTasks = Array(listedSource.suffix(limit)).reversed()
        let summaryLines = listedTasks.map { taskSummaryLine(for: $0, includeResumeToken: true) }
        let summary = [
            "Listed \(listedTasks.count) recorded task\(listedTasks.count == 1 ? "" : "s").",
            summaryLines.map { "- \($0)" }.joined(separator: "\n")
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: summary,
            approvalID: nil,
            artifacts: listedTasks.flatMap { task in
                [
                    AskCapabilityArtifact(kind: "task_id", value: task.id),
                    AskCapabilityArtifact(kind: "task_title", value: task.title),
                    AskCapabilityArtifact(kind: "task_resume_token", value: taskResumeToken(for: task))
                ]
            },
            metadata: [
                "listed_task_count": String(listedTasks.count),
                "session_task_count": String(tasks.count),
                "open_task_count": String(openTasks.count),
                "waiting_task_count": String(tasks.filter { $0.status == .waitingApproval }.count),
                "listed_task_ids": listedTasks.map(\.id).joined(separator: ","),
                "listed_task_titles": listedTasks.map { String($0.title.prefix(80)) }.joined(separator: " | "),
                "task_list_summary": String(summaryLines.joined(separator: "\n").prefix(1200))
            ]
        )
    }

    private func getTask(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let sessionID = resolvedSessionID(from: request) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No coding session context was available for fetching task details.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let requestedWorkspaceRoot = firstNonEmptyValue(in: request.arguments, keys: ["workspace_root", "project_root"])
        let tasks = await taskStore.tasks(for: sessionID)
        guard !tasks.isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No recorded tasks were found for the current coding session.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let candidate = resolvedTaskToResume(
            requestedTaskID: firstNonEmptyValue(in: request.arguments, keys: ["task_id", "subtask_id"]),
            requestedResumeToken: firstNonEmptyValue(in: request.arguments, keys: ["resume_token", "task_token"]),
            requestedTitle: firstNonEmptyValue(in: request.arguments, keys: ["query", "title", "task_title", "subtask_title"]),
            requestedWorkspaceRoot: requestedWorkspaceRoot,
            tasks: tasks
        )

        guard let candidate else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No matching recorded task could be found.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Loaded task details for \(candidate.title) [\(candidate.status.rawValue)].",
            approvalID: nil,
            artifacts: [
                AskCapabilityArtifact(kind: "task_id", value: candidate.id),
                AskCapabilityArtifact(kind: "task_title", value: candidate.title),
                AskCapabilityArtifact(kind: "task_resume_token", value: taskResumeToken(for: candidate))
            ],
            metadata: taskMetadata(for: candidate)
        )
    }

    private func updateTask(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let sessionID = resolvedSessionID(from: request) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No coding session context was available for updating a task.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let newTitle = firstNonEmptyValue(in: request.arguments, keys: ["new_title"])
        let newObjective = firstNonEmptyValue(in: request.arguments, keys: ["new_objective", "objective"])
        let note = firstNonEmptyValue(in: request.arguments, keys: ["note", "reason", "summary"])
        let newStatus = firstNonEmptyValue(in: request.arguments, keys: ["status", "new_status"]).flatMap { rawValue in
            AskTaskStatus(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard newTitle != nil || newObjective != nil || note != nil || newStatus != nil else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No task changes were provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        if firstNonEmptyValue(in: request.arguments, keys: ["status", "new_status"]) != nil, newStatus == nil {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "The requested task status was invalid.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let requestedWorkspaceRoot = firstNonEmptyValue(in: request.arguments, keys: ["workspace_root", "project_root"])
        let tasks = await taskStore.tasks(for: sessionID)
        guard !tasks.isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No recorded tasks were found for the current coding session.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        guard let candidate = resolvedTaskToResume(
            requestedTaskID: firstNonEmptyValue(in: request.arguments, keys: ["task_id", "subtask_id"]),
            requestedResumeToken: firstNonEmptyValue(in: request.arguments, keys: ["resume_token", "task_token"]),
            requestedTitle: firstNonEmptyValue(in: request.arguments, keys: ["query", "title", "task_title", "subtask_title"]),
            requestedWorkspaceRoot: requestedWorkspaceRoot,
            tasks: tasks
        ) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No matching recorded task could be updated.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let updatedTask = candidate.revised(
            title: newTitle,
            objective: newObjective,
            status: newStatus,
            appendingArtifacts: note.map { ["manual_note:\($0)"] } ?? [],
            mergingMetadata: updateMetadata(
                note: note,
                requestedStatus: newStatus,
                sessionID: sessionID
            )
        )

        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared a task update preview for \(updatedTask.title).",
                approvalID: nil,
                artifacts: [
                    AskCapabilityArtifact(kind: "task_id", value: updatedTask.id),
                    AskCapabilityArtifact(kind: "task_title", value: updatedTask.title),
                    AskCapabilityArtifact(kind: "task_resume_token", value: taskResumeToken(for: updatedTask))
                ],
                metadata: taskMetadata(
                    for: updatedTask,
                    includeActiveMirror: isActiveTask(updatedTask, request: request)
                )
            )
        }

        await taskStore.save(updatedTask)
        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Updated task: \(updatedTask.title) [\(updatedTask.status.rawValue)].",
            approvalID: nil,
            artifacts: [
                AskCapabilityArtifact(kind: "task_id", value: updatedTask.id),
                AskCapabilityArtifact(kind: "task_title", value: updatedTask.title),
                AskCapabilityArtifact(kind: "task_resume_token", value: taskResumeToken(for: updatedTask))
            ],
            metadata: taskMetadata(
                for: updatedTask,
                includeActiveMirror: isActiveTask(updatedTask, request: request)
            )
        )
    }

    private func stopTask(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let sessionID = resolvedSessionID(from: request) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No coding session context was available for stopping a task.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let requestedWorkspaceRoot = firstNonEmptyValue(in: request.arguments, keys: ["workspace_root", "project_root"])
        let tasks = await taskStore.tasks(for: sessionID)
        guard !tasks.isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No recorded tasks were found for the current coding session.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        guard let candidate = resolvedTaskToResume(
            requestedTaskID: firstNonEmptyValue(in: request.arguments, keys: ["task_id", "subtask_id"]),
            requestedResumeToken: firstNonEmptyValue(in: request.arguments, keys: ["resume_token", "task_token"]),
            requestedTitle: firstNonEmptyValue(in: request.arguments, keys: ["query", "title", "task_title", "subtask_title"]),
            requestedWorkspaceRoot: requestedWorkspaceRoot,
            tasks: tasks
        ) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No matching recorded task could be stopped.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let stopReason = firstNonEmptyValue(in: request.arguments, keys: ["reason", "note"])
        let effectiveTask = isTerminal(candidate.status)
            ? candidate
            : candidate.revised(
                status: .cancelled,
                appendingArtifacts: stopReason.map { ["manual_stop:\($0)"] } ?? [],
                mergingMetadata: updateMetadata(
                    note: stopReason,
                    requestedStatus: .cancelled,
                    sessionID: sessionID
                )
            )

        if !isTerminal(candidate.status) && !request.dryRun {
            await taskStore.save(effectiveTask)
        }

        let prefix = isTerminal(candidate.status) ? "Task was already terminal" : "Stopped task"
        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "\(prefix): \(effectiveTask.title) [\(effectiveTask.status.rawValue)].",
            approvalID: nil,
            artifacts: [
                AskCapabilityArtifact(kind: "task_id", value: effectiveTask.id),
                AskCapabilityArtifact(kind: "task_title", value: effectiveTask.title),
                AskCapabilityArtifact(kind: "task_resume_token", value: taskResumeToken(for: effectiveTask))
            ],
            metadata: taskMetadata(
                for: effectiveTask,
                includeActiveMirror: isActiveTask(effectiveTask, request: request)
            )
        )
    }

    private func resumeMetadata(
        for task: AskAgentTask,
        workspaceRootOverride: String?
    ) -> AskInvocationMetadata {
        let resumeToken = taskResumeToken(for: task)
        var metadata: AskInvocationMetadata = [
            "active_task_id": task.id,
            "active_task_title": task.title,
            "active_task_objective": String(task.objective.prefix(220)),
            "active_task_status": task.status.rawValue,
            "active_task_resume_token": resumeToken,
            "active_task_is_child": task.lineage.parentTaskID == nil ? "false" : "true",
            "resumed_task_id": task.id,
            "resumed_task_title": task.title,
            "resumed_task_status": task.status.rawValue
        ]
        if let parentTaskID = task.lineage.parentTaskID {
            metadata["active_task_parent_id"] = parentTaskID
        }
        if let workspaceRoot = workspaceRootOverride ?? task.context.workspaceRootPath ?? task.metadata["workspace_root"],
           !workspaceRoot.isEmpty {
            metadata["workspace_root"] = workspaceRoot
            metadata["active_task_workspace_root"] = workspaceRoot
        }
        if let planSummary = firstNonEmptyValue(in: task.context.metadata, keys: ["plan_mode_summary"]) {
            metadata["active_task_plan_summary"] = String(planSummary.prefix(220))
        }
        metadata.merge(
            checklistMetadata(for: task, prefix: "active_task"),
            uniquingKeysWith: { _, new in new }
        )
        return metadata
    }

    private func resolvedTaskToResume(
        requestedTaskID: String?,
        requestedResumeToken: String?,
        requestedTitle: String?,
        requestedWorkspaceRoot: String?,
        tasks: [AskAgentTask]
    ) -> AskAgentTask? {
        let candidateTasks = preferredWorkspaceScopedTasks(tasks, requestedWorkspaceRoot: requestedWorkspaceRoot)

        if let requestedTaskID,
           let exactTask = candidateTasks.last(where: { $0.id == requestedTaskID }) {
            return exactTask
        }

        if let requestedResumeToken {
            let normalizedToken = normalizedResumeToken(requestedResumeToken)
            if let tokenMatch = candidateTasks.last(where: { normalizedResumeToken(taskResumeToken(for: $0)) == normalizedToken }) {
                return tokenMatch
            }
            if let rawIDMatch = candidateTasks.last(where: { $0.id == normalizedToken }) {
                return rawIDMatch
            }
        }

        if let requestedTitle {
            let normalizedTitle = normalizedTaskSearchText(requestedTitle)
            let exactMatches = candidateTasks.filter { normalizedTaskSearchText($0.title) == normalizedTitle }
            if let exactMatch = preferredResumeCandidate(from: exactMatches) {
                return exactMatch
            }
            let fuzzyMatches = candidateTasks.filter { normalizedTaskSearchText($0.title).contains(normalizedTitle) }
            if let fuzzyMatch = preferredResumeCandidate(from: fuzzyMatches) {
                return fuzzyMatch
            }
        }

        return preferredResumeCandidate(from: candidateTasks)
    }

    private func preferredResumeCandidate(from tasks: [AskAgentTask]) -> AskAgentTask? {
        let openChildTasks = tasks.filter { $0.lineage.parentTaskID != nil && !isTerminal($0.status) }
        if let openChildTask = openChildTasks.last {
            return openChildTask
        }
        let openTasks = tasks.filter { !isTerminal($0.status) }
        if let openTask = openTasks.last {
            return openTask
        }
        let childTasks = tasks.filter { $0.lineage.parentTaskID != nil }
        if let childTask = childTasks.last {
            return childTask
        }
        return tasks.last
    }

    private func taskMetadata(
        for task: AskAgentTask,
        includeActiveMirror: Bool = false
    ) -> AskInvocationMetadata {
        let resumeToken = taskResumeToken(for: task)
        var metadata: AskInvocationMetadata = [
            "task_id": task.id,
            "task_title": task.title,
            "task_objective": String(task.objective.prefix(220)),
            "task_status": task.status.rawValue,
            "task_resume_token": resumeToken,
            "task_is_child": task.lineage.parentTaskID == nil ? "false" : "true",
            "root_task_id": task.lineage.rootTaskID
        ]
        if let parentTaskID = task.lineage.parentTaskID {
            metadata["task_parent_id"] = parentTaskID
        }
        if let workspaceRoot = task.context.workspaceRootPath ?? task.metadata["workspace_root"],
           !workspaceRoot.isEmpty {
            metadata["task_workspace_root"] = workspaceRoot
        }
        metadata.merge(
            checklistMetadata(for: task, prefix: "task"),
            uniquingKeysWith: { _, new in new }
        )
        if includeActiveMirror {
            metadata["active_task_id"] = task.id
            metadata["active_task_title"] = task.title
            metadata["active_task_objective"] = String(task.objective.prefix(220))
            metadata["active_task_status"] = task.status.rawValue
            metadata["active_task_resume_token"] = resumeToken
            metadata["active_task_is_child"] = task.lineage.parentTaskID == nil ? "false" : "true"
            if let parentTaskID = task.lineage.parentTaskID {
                metadata["active_task_parent_id"] = parentTaskID
            }
            if let workspaceRoot = metadata["task_workspace_root"], !workspaceRoot.isEmpty {
                metadata["workspace_root"] = workspaceRoot
                metadata["active_task_workspace_root"] = workspaceRoot
            }
            metadata.merge(
                checklistMetadata(for: task, prefix: "active_task"),
                uniquingKeysWith: { _, new in new }
            )
        }
        return metadata
    }

    private func taskResumeToken(for task: AskAgentTask) -> String {
        "task:\(task.id)"
    }

    private func normalizedResumeToken(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedTaskSearchText(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func preferredWorkspaceScopedTasks(
        _ tasks: [AskAgentTask],
        requestedWorkspaceRoot: String?
    ) -> [AskAgentTask] {
        guard let requestedWorkspaceRoot,
              !requestedWorkspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return tasks
        }
        let normalizedRoot = normalizedWorkspaceRoot(requestedWorkspaceRoot)
        let scopedTasks = tasks.filter { task in
            let taskRoot = task.context.workspaceRootPath ?? task.metadata["workspace_root"] ?? ""
            return normalizedWorkspaceRoot(taskRoot) == normalizedRoot
        }
        return scopedTasks.isEmpty ? tasks : scopedTasks
    }

    private func resolvedSessionID(from request: AskCapabilityExecutionRequest) -> String? {
        (firstNonEmptyValue(in: request.arguments, keys: ["session_id"]) ?? request.task.metadata["session_id"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func boolValue(
        in arguments: AskInvocationMetadata,
        keys: [String]
    ) -> Bool? {
        guard let rawValue = firstNonEmptyValue(in: arguments, keys: keys)?.lowercased() else {
            return nil
        }
        switch rawValue {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }

    private func integerValue(
        in arguments: AskInvocationMetadata,
        keys: [String]
    ) -> Int? {
        guard let rawValue = firstNonEmptyValue(in: arguments, keys: keys) else {
            return nil
        }
        return Int(rawValue)
    }

    private func taskSummaryLine(
        for task: AskAgentTask,
        includeResumeToken: Bool
    ) -> String {
        var parts = [
            "\(task.title) [\(task.status.rawValue)]"
        ]
        if task.lineage.parentTaskID != nil {
            parts.append("child")
        }
        if let workspaceRoot = task.context.workspaceRootPath ?? task.metadata["workspace_root"],
           !workspaceRoot.isEmpty {
            parts.append(URL(fileURLWithPath: workspaceRoot).lastPathComponent)
        }
        if task.todoCount > 0 {
            parts.append(task.todoProgressSummary)
        }
        if includeResumeToken {
            parts.append(taskResumeToken(for: task))
        }
        return parts.joined(separator: " · ")
    }

    private func updateMetadata(
        note: String?,
        requestedStatus: AskTaskStatus?,
        sessionID: String
    ) -> AskInvocationMetadata {
        var metadata: AskInvocationMetadata = [
            "last_manual_task_update_session_id": sessionID,
            "last_manual_task_update_at": ISO8601DateFormatter().string(from: Date())
        ]
        if let note, !note.isEmpty {
            metadata["task_note"] = String(note.prefix(220))
        }
        if let requestedStatus {
            metadata["task_manual_status"] = requestedStatus.rawValue
        }
        return metadata
    }

    private func isActiveTask(
        _ task: AskAgentTask,
        request: AskCapabilityExecutionRequest
    ) -> Bool {
        let activeTaskID = request.task.metadata["active_task_id"] ?? request.task.id
        return activeTaskID == task.id
    }

    private func checklistMetadata(
        for task: AskAgentTask,
        prefix: String
    ) -> AskInvocationMetadata {
        [
            "\(prefix)_todo_count": String(task.todoCount),
            "\(prefix)_todo_completed_count": String(task.completedTodoCount),
            "\(prefix)_todo_in_progress_count": String(task.inProgressTodoCount),
            "\(prefix)_todo_open_count": String(task.openTodoCount),
            "\(prefix)_progress_summary": String(task.todoProgressSummary.prefix(220)),
            "\(prefix)_todo_summary": String(task.todoSummary(limit: 5).prefix(1200))
        ]
    }

    private func resolvedTaskForChecklist(
        request: AskCapabilityExecutionRequest,
        requestedWorkspaceRoot: String?,
        tasks: [AskAgentTask]
    ) -> AskAgentTask? {
        let requestedTaskID = firstNonEmptyValue(in: request.arguments, keys: ["task_id", "subtask_id"])
        let requestedResumeToken = firstNonEmptyValue(in: request.arguments, keys: ["resume_token", "task_token"])
        let requestedTitle = firstNonEmptyValue(in: request.arguments, keys: ["query", "title", "task_title", "subtask_title"])
        if requestedTaskID != nil || requestedResumeToken != nil || requestedTitle != nil {
            return resolvedTaskToResume(
                requestedTaskID: requestedTaskID,
                requestedResumeToken: requestedResumeToken,
                requestedTitle: requestedTitle,
                requestedWorkspaceRoot: requestedWorkspaceRoot,
                tasks: tasks
            )
        }

        let candidateTasks = preferredWorkspaceScopedTasks(tasks, requestedWorkspaceRoot: requestedWorkspaceRoot)
        let activeTaskID = request.task.metadata["active_task_id"] ?? request.task.id
        if let activeTask = candidateTasks.last(where: { $0.id == activeTaskID }) {
            return activeTask
        }
        if let currentTask = candidateTasks.last(where: { $0.id == request.task.id }) {
            return currentTask
        }
        return preferredResumeCandidate(from: candidateTasks)
    }

    private func decodedChecklistItems(from arguments: AskInvocationMetadata) -> [AskTaskChecklistItem]? {
        guard let encoded = firstNonEmptyValue(
            in: arguments,
            keys: ["items_json", "todos_json", "checklist_json"]
        ) else {
            return nil
        }
        guard let data = encoded.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }

        let now = Date()
        let items = payload.prefix(24).enumerated().compactMap { index, entry -> AskTaskChecklistItem? in
            if let title = entry as? String {
                let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedTitle.isEmpty else { return nil }
                return AskTaskChecklistItem(
                    id: "todo-\(index + 1)",
                    title: trimmedTitle,
                    status: .pending,
                    note: nil,
                    updatedAt: now
                )
            }

            guard let object = entry as? [String: Any] else { return nil }
            guard let title = firstNonEmptyObjectValue(
                in: object,
                keys: ["content", "title", "text", "item", "step"]
            ) else {
                return nil
            }
            let status = parsedChecklistStatus(
                firstNonEmptyObjectValue(in: object, keys: ["status", "state"])
            ) ?? .pending
            let note = firstNonEmptyObjectValue(in: object, keys: ["note", "reason", "details"])
            return AskTaskChecklistItem(
                id: firstNonEmptyObjectValue(in: object, keys: ["id"]) ?? "todo-\(index + 1)",
                title: title,
                status: status,
                note: note,
                updatedAt: now
            )
        }

        if payload.isEmpty {
            return []
        }
        return items.isEmpty ? nil : items
    }

    private func parsedChecklistStatus(_ rawValue: String?) -> AskTaskChecklistStatus? {
        guard let rawValue else { return nil }
        switch rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_") {
        case "pending", "todo", "planned":
            return .pending
        case "in_progress", "inprogress", "running", "doing":
            return .inProgress
        case "completed", "done", "finished":
            return .completed
        case "blocked":
            return .blocked
        default:
            return nil
        }
    }

    private func todoWriteMetadata(
        sessionID: String,
        itemCount: Int
    ) -> AskInvocationMetadata {
        [
            "last_todo_write_session_id": sessionID,
            "last_todo_write_at": ISO8601DateFormatter().string(from: Date()),
            "last_todo_write_count": String(itemCount)
        ]
    }

    private func normalizedWorkspaceRoot(_ rawValue: String) -> String {
        URL(fileURLWithPath: rawValue).standardizedFileURL.path.lowercased()
    }

    private func isTerminal(_ status: AskTaskStatus) -> Bool {
        switch status {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .planning, .waitingApproval, .running, .blocked:
            return false
        }
    }

    private func requestAuthorizationIfNeeded(center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func firstNonEmptyValue(
        in arguments: AskInvocationMetadata,
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    private func decodedInboxActions(from arguments: AskInvocationMetadata) -> [AskInboxAction] {
        guard let encoded = firstNonEmptyValue(in: arguments, keys: ["actions_json"]) else {
            return []
        }
        guard let data = encoded.data(using: .utf8),
              let actions = try? JSONDecoder().decode([AskInboxAction].self, from: data) else {
            return []
        }
        return actions
    }

    private func resolvedAssistantBrief(request: AskCapabilityExecutionRequest) -> AskAssistantBrief {
        AskAssistantBriefFactory.make(arguments: request.arguments, task: request.task)
    }

    private func firstNonEmptyObjectValue(
        in object: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
