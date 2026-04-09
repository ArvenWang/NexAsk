import Foundation
import NexShared

enum AskAssistantDeliveryChannel: String, Codable, CaseIterable, Sendable {
    case brief = "assistant_brief"
    case inbox = "ask_inbox"
    case notification = "system_notification"
}

struct AskAssistantBrief: Codable, Equatable, Sendable {
    let title: String
    let summary: String
    let body: String
    let kind: String
    let sourceTaskID: String
    let sourceSessionID: String?
    let sourceRunID: String?
    let sourceJobID: String?
    let workspaceRoot: String?
    let activeTaskID: String?
    let activeTaskResumeToken: String?
    let sourceTaskStatus: String?

    func metadata(channel: AskAssistantDeliveryChannel) -> AskInvocationMetadata {
        var metadata: AskInvocationMetadata = [
            "assistant_brief_title": title,
            "assistant_brief_summary": String(summary.prefix(220)),
            "assistant_brief_body": String(body.prefix(420)),
            "assistant_brief_kind": kind,
            "assistant_delivery_channel": channel.rawValue,
            "assistant_delivery_source_task_id": sourceTaskID
        ]
        if let sourceSessionID, !sourceSessionID.isEmpty {
            metadata["assistant_delivery_session_id"] = sourceSessionID
        }
        if let sourceRunID, !sourceRunID.isEmpty {
            metadata["assistant_delivery_source_run_id"] = sourceRunID
        }
        if let sourceJobID, !sourceJobID.isEmpty {
            metadata["assistant_delivery_source_job_id"] = sourceJobID
        }
        if let workspaceRoot, !workspaceRoot.isEmpty {
            metadata["assistant_delivery_workspace_root"] = workspaceRoot
            metadata["workspace_root"] = workspaceRoot
        }
        if let activeTaskID, !activeTaskID.isEmpty {
            metadata["assistant_delivery_active_task_id"] = activeTaskID
        }
        if let activeTaskResumeToken, !activeTaskResumeToken.isEmpty {
            metadata["assistant_delivery_resume_token"] = activeTaskResumeToken
        }
        if let sourceTaskStatus, !sourceTaskStatus.isEmpty {
            metadata["assistant_delivery_source_task_status"] = sourceTaskStatus
        }
        return metadata
    }

    func artifacts() -> [AskCapabilityArtifact] {
        [
            AskCapabilityArtifact(kind: "assistant_brief_title", value: title),
            AskCapabilityArtifact(kind: "assistant_brief_summary", value: String(summary.prefix(220))),
            AskCapabilityArtifact(kind: "assistant_brief_kind", value: kind)
        ]
    }
}

enum AskAssistantBriefFactory {
    static func make(
        arguments: AskInvocationMetadata,
        task: AskAgentTask
    ) -> AskAssistantBrief {
        let title = firstNonEmptyValue(
            in: arguments,
            keys: ["title", "brief_title", "inbox_title", "notification_title"]
        ) ?? task.title

        let fallbackBody = firstNonEmptyValue(
            in: task.context.metadata,
            keys: ["latest_kernel_result_summary", "latest_kernel_task_title", "plan_mode_summary"]
        ) ?? task.objective

        let body = firstNonEmptyValue(
            in: arguments,
            keys: ["body", "brief_body", "message", "text", "detail", "summary", "inbox_summary"]
        ) ?? fallbackBody

        let summary = firstNonEmptyValue(
            in: arguments,
            keys: ["summary", "brief_summary", "inbox_summary"]
        ) ?? clippedText(body, limit: 220)

        let workspaceRoot = firstNonEmptyValue(
            in: arguments,
            keys: ["workspace_root", "assistant_delivery_workspace_root"]
        ) ?? task.context.workspaceRootPath
            ?? firstNonEmptyValue(
                in: task.metadata,
                keys: ["workspace_root", "active_task_workspace_root"]
            )

        let activeTaskID = firstNonEmptyValue(
            in: arguments,
            keys: ["active_task_id", "resumed_task_id", "task_id"]
        ) ?? firstNonEmptyValue(
            in: task.metadata,
            keys: ["active_task_id", "resumed_task_id"]
        )

        let activeTaskResumeToken = firstNonEmptyValue(
            in: arguments,
            keys: ["active_task_resume_token", "resume_token", "task_resume_token", "assistant_delivery_resume_token"]
        ) ?? firstNonEmptyValue(
            in: task.metadata,
            keys: ["active_task_resume_token"]
        )

        let kind = firstNonEmptyValue(
            in: arguments,
            keys: ["kind", "brief_kind", "inbox_kind"]
        ) ?? defaultKind(task: task)

        return AskAssistantBrief(
            title: normalizedNonEmpty(title, fallback: task.title),
            summary: normalizedNonEmpty(summary, fallback: clippedText(fallbackBody, limit: 220)),
            body: normalizedNonEmpty(body, fallback: fallbackBody),
            kind: normalizedNonEmpty(kind, fallback: defaultKind(task: task)),
            sourceTaskID: firstNonEmptyValue(
                in: arguments,
                keys: ["source_task_id", "kernel_task_id", "assistant_delivery_source_task_id"]
            ) ?? task.id,
            sourceSessionID: firstNonEmptyValue(
                in: arguments,
                keys: ["session_id", "assistant_delivery_session_id"]
            ) ?? task.metadata["session_id"],
            sourceRunID: firstNonEmptyValue(
                in: arguments,
                keys: ["source_run_id", "run_id", "assistant_delivery_source_run_id"]
            ),
            sourceJobID: firstNonEmptyValue(
                in: arguments,
                keys: ["source_job_id", "job_id", "assistant_delivery_source_job_id"]
            ) ?? task.lineage.automationJobID,
            workspaceRoot: workspaceRoot,
            activeTaskID: activeTaskID,
            activeTaskResumeToken: activeTaskResumeToken,
            sourceTaskStatus: firstNonEmptyValue(
                in: arguments,
                keys: ["assistant_delivery_source_task_status"]
            ) ?? task.status.rawValue
        )
    }

    private static func defaultKind(task: AskAgentTask) -> String {
        switch task.mode {
        case .automate:
            return "assistant_update"
        case .interactive:
            return "workspace_followup"
        }
    }

    private static func clippedText(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return ""
        }
        return String(normalized.prefix(limit))
    }

    private static func normalizedNonEmpty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackTrimmed.isEmpty ? "Assistant update" : fallbackTrimmed
    }

    private static func firstNonEmptyValue(
        in metadata: AskInvocationMetadata,
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }
}
