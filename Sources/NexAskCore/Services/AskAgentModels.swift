import Foundation
import NexShared

struct AskToolDefinition {
    let name: String
    let description: String
    let parameters: [String: Any]
}

struct AskToolCall: Equatable {
    let id: String
    let name: String
    let argumentsJSON: String
}

enum AskApprovalDecision: String, Equatable {
    case approve
    case cancel
}

struct AskApprovalConflictSummary: Equatable {
    let collisionCount: Int
    let skippedCount: Int
    let sampleDestinationPaths: [String]
    let summary: String

    var modelPayload: [String: Any] {
        [
            "collision_count": collisionCount,
            "skipped_count": skippedCount,
            "sample_destination_paths": sampleDestinationPaths,
            "summary": summary
        ]
    }
}

struct AskReversibilityHint: Equatable {
    let kind: String
    let summary: String

    var modelPayload: [String: Any] {
        [
            "kind": kind,
            "summary": summary
        ]
    }
}

struct AskApprovalRequestRecord: Equatable {
    let actionID: String
    let toolName: String
    let targetSummary: String
    let affectedCount: Int
    let conflictSummary: AskApprovalConflictSummary
    let reversibilityHint: AskReversibilityHint
    let expiry: Date?
    let operationID: String?
    let summary: String
    let message: String
    let cards: [SkillResultCard]

    var modelPayload: [String: Any] {
        var payload: [String: Any] = [
            "action_id": actionID,
            "tool_name": toolName,
            "target_summary": targetSummary,
            "affected_count": affectedCount,
            "conflict_summary": conflictSummary.modelPayload,
            "reversibility_hint": reversibilityHint.modelPayload,
            "summary": summary,
            "message": message,
            "operation_id": operationID ?? ""
        ]
        if let expiry {
            payload["expiry"] = ISO8601DateFormatter().string(from: expiry)
        } else {
            payload["expiry"] = NSNull()
        }
        return payload
    }
}

typealias AskApprovalRequest = AskApprovalRequestRecord

struct AskToolExecutionResult {
    let ok: Bool
    let summary: String
    let data: [String: Any]
    let cards: [SkillResultCard]
    let approvalRequest: AskApprovalRequest?
    let error: String?

    var modelPayload: [String: Any] {
        var payload: [String: Any] = [
            "ok": ok,
            "summary": summary,
            "data": data
        ]
        if let approvalRequest {
            payload["requires_approval"] = true
            payload["approval_request"] = approvalRequest.modelPayload
        } else {
            payload["requires_approval"] = false
        }
        if let error, !error.isEmpty {
            payload["error"] = error
        }
        return payload
    }
}

enum AskAgentModelResponse {
    case final(String)
    case toolCalls([AskToolCall], assistantText: String?)
}

struct AskAgentModelTurn {
    let response: AskAgentModelResponse
    let responseID: String?
}

enum AskAgentMessageRole: String {
    case system
    case user
    case assistant
    case tool
}

struct AskAgentMessage: Equatable {
    let role: AskAgentMessageRole
    let content: String?
    let toolCallID: String?
    let toolName: String?
    let toolCalls: [AskToolCall]?

    static func system(_ content: String) -> AskAgentMessage {
        AskAgentMessage(role: .system, content: content, toolCallID: nil, toolName: nil, toolCalls: nil)
    }

    static func user(_ content: String) -> AskAgentMessage {
        AskAgentMessage(role: .user, content: content, toolCallID: nil, toolName: nil, toolCalls: nil)
    }

    static func assistant(_ content: String) -> AskAgentMessage {
        AskAgentMessage(role: .assistant, content: content, toolCallID: nil, toolName: nil, toolCalls: nil)
    }

    static func assistantToolCalls(_ toolCalls: [AskToolCall], content: String?) -> AskAgentMessage {
        AskAgentMessage(role: .assistant, content: content, toolCallID: nil, toolName: nil, toolCalls: toolCalls)
    }

    static func tool(toolCallID: String, toolName: String, content: String) -> AskAgentMessage {
        AskAgentMessage(role: .tool, content: content, toolCallID: toolCallID, toolName: toolName, toolCalls: nil)
    }
}

struct AskAgentToolCallRecord: Equatable {
    let toolCallID: String
    let toolName: String
    let argumentsJSON: String
    let ok: Bool
    let summary: String
    let actionID: String?
    let operationID: String?
    let createdAt: Date
}

enum AskAgentTimelineStepKind: String, Codable, Equatable {
    case planning
    case toolCall
    case awaitingApproval
    case executionResult
    case finalAnswer
}

struct AskAgentTimelineStep: Equatable {
    let id: String
    let kind: AskAgentTimelineStepKind
    let summary: String
    let detail: String?
    let actionID: String?
    let operationID: String?
    let createdAt: Date
}

struct AskAgentTurnBudget: Equatable {
    let maxToolCalls: Int
    var usedToolCalls: Int
}

struct AskAgentSessionState: Equatable {
    let sessionID: String
    var sessionOrigin: AskSessionOrigin
    var conversationMessages: [AskAgentMessage]
    var toolCallHistory: [AskAgentToolCallRecord]
    var snapshotRefs: [String]
    var selectionRefs: [String]
    var stagedOperationRefs: [String]
    var approvalState: AskApprovalRequestRecord?
    var pendingAutomationDraftID: String?
    var savedAutomationJobID: String?
    var inboxItemID: String?
    var kernelMetadata: [String: String]
    var stepTimeline: [AskAgentTimelineStep]
    var turnBudget: AskAgentTurnBudget
    var lastFinalResponse: String?

    static func make(
        sessionID: String,
        maxToolCalls: Int,
        sessionOrigin: AskSessionOrigin = .user
    ) -> AskAgentSessionState {
        AskAgentSessionState(
            sessionID: sessionID,
            sessionOrigin: sessionOrigin,
            conversationMessages: [],
            toolCallHistory: [],
            snapshotRefs: [],
            selectionRefs: [],
            stagedOperationRefs: [],
            approvalState: nil,
            pendingAutomationDraftID: nil,
            savedAutomationJobID: nil,
            inboxItemID: nil,
            kernelMetadata: [:],
            stepTimeline: [],
            turnBudget: AskAgentTurnBudget(maxToolCalls: maxToolCalls, usedToolCalls: 0),
            lastFinalResponse: nil
        )
    }

    var activeOperationID: String? {
        approvalState?.operationID ?? stagedOperationRefs.last
    }

    var currentTurnTimeline: [AskAgentTimelineStep] {
        guard let planningIndex = stepTimeline.lastIndex(where: { $0.kind == .planning }) else {
            return stepTimeline
        }
        return Array(stepTimeline[planningIndex...])
    }

    var planModeActive: Bool {
        kernelMetadata["plan_mode_active"]?.lowercased() == "true"
    }

    var planModeSummary: String? {
        let summary = kernelMetadata["plan_mode_summary"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary?.isEmpty == false ? summary : nil
    }

    var editScopeLimited: Bool {
        kernelMetadata["edit_scope_limited"]?.lowercased() == "true"
    }

    var workspaceWriteGranted: Bool {
        kernelMetadata["workspace_write_granted"]?.lowercased() == "true"
    }

    var workspaceShellGranted: Bool {
        kernelMetadata["workspace_shell_granted"]?.lowercased() == "true"
    }

    var workspaceGitWriteGranted: Bool {
        kernelMetadata["workspace_git_write_granted"]?.lowercased() == "true"
    }

    var workspaceNetworkAccessGranted: Bool {
        kernelMetadata["workspace_network_access_granted"]?.lowercased() == "true"
    }

    var workspacePermissionProfile: AskWorkspacePermissionProfile {
        AskWorkspacePermissionProfile.from(metadata: kernelMetadata)
    }

    var workspaceExecutionBudget: AskWorkspaceExecutionBudget {
        AskWorkspaceExecutionBudget.from(metadata: kernelMetadata)
    }

    var latestAssistantBriefTitle: String? {
        let value = kernelMetadata["latest_assistant_brief_title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    var latestAssistantBriefKind: String? {
        let value = kernelMetadata["latest_assistant_brief_kind"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    var latestAssistantDeliveryChannel: String? {
        let value = kernelMetadata["latest_assistant_delivery_channel"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    var childTaskCount: Int? {
        kernelCount(for: "kernel_child_task_count")
    }

    var openChildTaskCount: Int? {
        kernelCount(for: "kernel_open_child_task_count")
    }

    var latestChildTaskStatus: AskTaskStatus? {
        guard let rawValue = kernelMetadata["latest_kernel_child_task_status"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return AskTaskStatus(rawValue: rawValue)
    }

    var latestChildTaskTitle: String? {
        let title = kernelMetadata["latest_kernel_child_task_title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    var activeTaskID: String? {
        let value = kernelMetadata["active_task_id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    var activeTaskTitle: String? {
        let value = kernelMetadata["active_task_title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    var activeTaskObjective: String? {
        let value = kernelMetadata["active_task_objective"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    var activeTaskStatus: AskTaskStatus? {
        guard let rawValue = kernelMetadata["active_task_status"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return AskTaskStatus(rawValue: rawValue)
    }

    var activeTaskResumeToken: String? {
        let value = kernelMetadata["active_task_resume_token"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    var activeTaskWorkspaceRoot: String? {
        AskWorkspaceRootSupport.normalizedWorkspaceRoot(kernelMetadata["active_task_workspace_root"])
            ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(kernelMetadata["interactive_task_scope_root"])
            ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(kernelMetadata["workspace_root"])
    }

    var activeTaskTodoCount: Int? {
        kernelCount(for: "active_task_todo_count")
    }

    var activeTaskCompletedTodoCount: Int? {
        kernelCount(for: "active_task_todo_completed_count")
    }

    var activeTaskInProgressTodoCount: Int? {
        kernelCount(for: "active_task_todo_in_progress_count")
    }

    var activeTaskOpenTodoCount: Int? {
        kernelCount(for: "active_task_todo_open_count")
    }

    var activeTaskProgressSummary: String? {
        let value = kernelMetadata["active_task_progress_summary"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return (activeTaskTodoCount ?? 0) > 0 ? value : nil
    }

    var activeTaskTodoSummary: String? {
        let value = kernelMetadata["active_task_todo_summary"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return (activeTaskTodoCount ?? 0) > 0 ? value : nil
    }

    private func kernelCount(for key: String) -> Int? {
        guard let rawValue = kernelMetadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let count = Int(rawValue) else {
            return nil
        }
        return count
    }
}

struct AskAgentTimelineMetadataEntry: Codable, Equatable {
    let kind: AskAgentTimelineStepKind
    let summary: String
    let detail: String?
    let actionID: String?
    let operationID: String?
}

enum AskAgentTimelineMetadataCodec {
    static func encode(_ steps: [AskAgentTimelineStep]) -> String? {
        guard !steps.isEmpty else { return nil }
        let payload = steps.map {
            AskAgentTimelineMetadataEntry(
                kind: $0.kind,
                summary: $0.summary,
                detail: $0.detail,
                actionID: $0.actionID,
                operationID: $0.operationID
            )
        }
        guard let data = try? JSONEncoder().encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func decode(_ rawValue: String) -> [AskAgentTimelineMetadataEntry] {
        guard let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode([AskAgentTimelineMetadataEntry].self, from: data) else {
            return []
        }
        return payload
    }
}

actor AskAgentSessionStore {
    private var states: [String: AskAgentSessionState] = [:]

    func sessionState(for sessionID: String) -> AskAgentSessionState? {
        states[sessionID]
    }

    func pendingApproval(for sessionID: String) -> AskApprovalRequestRecord? {
        states[sessionID]?.approvalState
    }

    @discardableResult
    func beginTurn(
        sessionID: String,
        conversationMessages: [AskAgentMessage],
        maxToolCalls: Int,
        sessionOrigin: AskSessionOrigin,
        kernelMetadata: [String: String]
    ) -> AskAgentSessionState {
        var state = states[sessionID] ?? AskAgentSessionState.make(
            sessionID: sessionID,
            maxToolCalls: maxToolCalls,
            sessionOrigin: sessionOrigin
        )
        state.sessionOrigin = sessionOrigin
        state.conversationMessages = conversationMessages
        state.turnBudget = AskAgentTurnBudget(maxToolCalls: maxToolCalls, usedToolCalls: 0)
        mergeKernelMetadata(from: kernelMetadata, into: &state.kernelMetadata)
        state.stepTimeline.append(
            AskAgentTimelineStep(
                id: UUID().uuidString.lowercased(),
                kind: .planning,
                summary: "turn_started",
                detail: nil,
                actionID: state.approvalState?.actionID,
                operationID: state.activeOperationID,
                createdAt: Date()
            )
        )
        states[sessionID] = state
        return state
    }

    @discardableResult
    func recordToolExecution(
        sessionID: String,
        toolCall: AskToolCall,
        result: AskToolExecutionResult
    ) -> AskAgentSessionState {
        var state = states[sessionID] ?? AskAgentSessionState.make(sessionID: sessionID, maxToolCalls: 12)
        state.turnBudget.usedToolCalls += 1

        let actionID = result.approvalRequest?.actionID ?? stringValue(for: "action_id", in: result.data)
        let operationID = result.approvalRequest?.operationID ?? stringValue(for: "operation_id", in: result.data)
        state.toolCallHistory.append(
            AskAgentToolCallRecord(
                toolCallID: toolCall.id,
                toolName: toolCall.name,
                argumentsJSON: toolCall.argumentsJSON,
                ok: result.ok,
                summary: result.summary,
                actionID: actionID,
                operationID: operationID,
                createdAt: Date()
            )
        )
        appendReferenceIfNeeded(stringValue(for: "snapshot_id", in: result.data), to: &state.snapshotRefs)
        appendReferenceIfNeeded(stringValue(for: "source_snapshot_id", in: result.data), to: &state.snapshotRefs)
        appendReferenceIfNeeded(stringValue(for: "selection_id", in: result.data), to: &state.selectionRefs)
        appendReferenceIfNeeded(operationID, to: &state.stagedOperationRefs)
        state.pendingAutomationDraftID = stringValue(for: "pending_automation_draft_id", in: result.data) ?? state.pendingAutomationDraftID
        state.savedAutomationJobID = stringValue(for: "saved_automation_job_id", in: result.data) ?? state.savedAutomationJobID
        state.inboxItemID = stringValue(for: "inbox_item_id", in: result.data) ?? state.inboxItemID
        mergeKernelMetadata(from: result.data, into: &state.kernelMetadata)
        if state.savedAutomationJobID != nil {
            state.pendingAutomationDraftID = nil
        }

        if let approvalRequest = result.approvalRequest {
            state.approvalState = approvalRequest
            state.stepTimeline.append(
                AskAgentTimelineStep(
                    id: UUID().uuidString.lowercased(),
                    kind: .awaitingApproval,
                    summary: approvalRequest.summary,
                    detail: approvalRequest.message,
                    actionID: approvalRequest.actionID,
                    operationID: approvalRequest.operationID,
                    createdAt: Date()
                )
            )
        } else {
            if toolCall.name == "respond_to_approval" {
                state.approvalState = nil
            }
            state.stepTimeline.append(
                AskAgentTimelineStep(
                    id: UUID().uuidString.lowercased(),
                    kind: .executionResult,
                    summary: result.summary,
                    detail: result.error,
                    actionID: actionID,
                    operationID: operationID,
                    createdAt: Date()
                )
            )
        }

        states[sessionID] = state
        return state
    }

    @discardableResult
    func setPendingApproval(_ approval: AskApprovalRequestRecord, for sessionID: String) -> AskAgentSessionState {
        var state = states[sessionID] ?? AskAgentSessionState.make(sessionID: sessionID, maxToolCalls: 12)
        state.approvalState = approval
        states[sessionID] = state
        return state
    }

    @discardableResult
    func clearPendingApproval(for sessionID: String) -> AskAgentSessionState {
        var state = states[sessionID] ?? AskAgentSessionState.make(sessionID: sessionID, maxToolCalls: 12)
        state.approvalState = nil
        states[sessionID] = state
        return state
    }

    @discardableResult
    func recordFinalResponse(message: String, for sessionID: String) -> AskAgentSessionState {
        var state = states[sessionID] ?? AskAgentSessionState.make(sessionID: sessionID, maxToolCalls: 12)
        state.lastFinalResponse = message
        state.stepTimeline.append(
            AskAgentTimelineStep(
                id: UUID().uuidString.lowercased(),
                kind: .finalAnswer,
                summary: message,
                detail: nil,
                actionID: state.approvalState?.actionID,
                operationID: state.activeOperationID,
                createdAt: Date()
            )
        )
        states[sessionID] = state
        return state
    }

    @discardableResult
    func recordToolPlanning(toolCall: AskToolCall, for sessionID: String) -> AskAgentSessionState {
        var state = states[sessionID] ?? AskAgentSessionState.make(sessionID: sessionID, maxToolCalls: 12)
        state.stepTimeline.append(
            AskAgentTimelineStep(
                id: UUID().uuidString.lowercased(),
                kind: .toolCall,
                summary: toolCall.name,
                detail: toolCall.argumentsJSON,
                actionID: nil,
                operationID: nil,
                createdAt: Date()
            )
        )
        states[sessionID] = state
        return state
    }

    private func appendReferenceIfNeeded(_ value: String?, to storage: inout [String]) {
        guard let value, !value.isEmpty, !storage.contains(value) else { return }
        storage.append(value)
    }

    private func stringValue(for key: String, in data: [String: Any]) -> String? {
        guard let value = data[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private func mergeKernelMetadata(from payload: [String: Any], into metadata: inout [String: String]) {
        let relevantKeys = [
            "workspace_root",
            "current_page_url",
            "page_url",
            "current_page_title",
            "page_title",
            "selection_preview",
            "plan_mode_active",
            "plan_mode_summary",
            "edit_scope_limited",
            "workspace_permission_profile",
            "workspace_patch_granted",
            "interactive_task_scope_granted",
            "interactive_task_scope_root",
            "active_task_id",
            "active_task_title",
            "active_task_objective",
            "active_task_status",
            "active_task_resume_token",
            "active_task_parent_id",
            "active_task_is_child",
            "active_task_workspace_root",
            "active_task_plan_summary",
            "active_task_todo_count",
            "active_task_todo_completed_count",
            "active_task_todo_in_progress_count",
            "active_task_todo_open_count",
            "active_task_progress_summary",
            "active_task_todo_summary",
            "agent_custom_system_prompt",
            "ask_custom_system_prompt",
            "custom_system_prompt",
            "agent_append_system_prompt",
            "ask_append_system_prompt",
            "append_system_prompt",
            "agent_override_system_prompt",
            "ask_override_system_prompt",
            "override_system_prompt",
            "agent_prompt_addendum",
            "ask_prompt_addendum",
            "assistant_prompt_addendum",
            "workspace_write_granted",
            "workspace_shell_granted",
            "workspace_git_write_granted",
            "workspace_network_access_granted",
            "workspace_execution_budget",
            "kernel_result_count",
            "kernel_result_success_count",
            "kernel_result_failure_count",
            "kernel_result_waiting_count",
            "kernel_task_count",
            "kernel_child_task_count",
            "kernel_open_child_task_count",
            "kernel_waiting_task_count",
            "latest_kernel_capability_id",
            "latest_kernel_result_status",
            "latest_kernel_result_summary",
            "latest_assistant_brief_title",
            "latest_assistant_brief_kind",
            "latest_assistant_delivery_channel",
            "latest_kernel_task_status",
            "latest_kernel_task_title",
            "latest_kernel_child_task_status",
            "latest_kernel_child_task_title"
        ]
        for key in relevantKeys {
            guard let value = stringValue(for: key, in: payload) else { continue }
            switch key {
            case "page_url":
                metadata["current_page_url"] = value
            case "page_title":
                metadata["current_page_title"] = value
            default:
                metadata[key] = value
            }
        }
    }

    private func mergeKernelMetadata(from payload: [String: String], into metadata: inout [String: String]) {
        let bridgedPayload = payload.reduce(into: [String: Any]()) { partialResult, entry in
            partialResult[entry.key] = entry.value
        }
        mergeKernelMetadata(from: bridgedPayload, into: &metadata)
    }
}

protocol AskAgentRuntimeProviding {
    func run(
        request: AskSessionRequest,
        compiledMessages: [LLMChatMessage],
        configuration: LLMRequestConfiguration,
        responseProfile: AskResponseProfile,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async throws -> AskSessionResponse
}

protocol AskToolExecuting {
    func executeTool(
        named name: String,
        argumentsJSON: String,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult
}
