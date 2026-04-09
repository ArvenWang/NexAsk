import Foundation
import NexShared

struct AskAssistantFollowUpActivationEnvelope: Codable, Equatable {
    let kind: String
    let version: Int
    let activation: AskAssistantFollowUpActivation
}

struct AskAssistantFollowUpActivation: Codable, Equatable {
    static let payloadKind = "assistant_followup_activation"
    static let payloadVersion = 1

    let title: String
    let summary: String
    let kind: String
    let sourceTaskID: String?
    let activeTaskID: String?
    let sourceTaskStatus: String?
    let sourceSessionID: String?
    let sourceJobID: String?
    let sourceRunID: String?
    let resumeToken: String?
    let workspaceRoot: String?
    let deliveryChannel: String?

    static func from(
        brief: AskAssistantBrief,
        channel: AskAssistantDeliveryChannel
    ) -> AskAssistantFollowUpActivation {
        AskAssistantFollowUpActivation(
            title: normalizedValue(brief.title, fallback: "Assistant follow-up"),
            summary: normalizedValue(brief.summary, fallback: brief.body),
            kind: normalizedValue(brief.kind, fallback: "assistant_update"),
            sourceTaskID: normalizedOptional(brief.sourceTaskID),
            activeTaskID: normalizedOptional(brief.activeTaskID) ?? normalizedOptional(brief.sourceTaskID),
            sourceTaskStatus: normalizedOptional(brief.sourceTaskStatus),
            sourceSessionID: normalizedOptional(brief.sourceSessionID),
            sourceJobID: normalizedOptional(brief.sourceJobID),
            sourceRunID: normalizedOptional(brief.sourceRunID),
            resumeToken: normalizedOptional(brief.activeTaskResumeToken),
            workspaceRoot: normalizedOptional(brief.workspaceRoot),
            deliveryChannel: channel.rawValue
        )
    }

    static func from(inboxItem: AskInboxItem) -> AskAssistantFollowUpActivation? {
        let title = normalizedOptional(inboxItem.title)
        let summary = normalizedOptional(inboxItem.summary)
        guard title != nil || summary != nil || inboxItem.activeTaskResumeToken != nil || inboxItem.sourceTaskID != nil else {
            return nil
        }
        return AskAssistantFollowUpActivation(
            title: normalizedValue(title, fallback: "Assistant follow-up"),
            summary: normalizedValue(summary, fallback: title ?? "Continue the previous assistant task."),
            kind: normalizedValue(inboxItem.kind, fallback: "assistant_update"),
            sourceTaskID: normalizedOptional(inboxItem.sourceTaskID),
            activeTaskID: normalizedOptional(inboxItem.activeTaskID) ?? normalizedOptional(inboxItem.sourceTaskID),
            sourceTaskStatus: normalizedOptional(inboxItem.sourceTaskStatus),
            sourceSessionID: nil,
            sourceJobID: normalizedOptional(inboxItem.sourceJobID),
            sourceRunID: normalizedOptional(inboxItem.sourceRunID),
            resumeToken: normalizedOptional(inboxItem.activeTaskResumeToken),
            workspaceRoot: normalizedOptional(inboxItem.workspaceRoot),
            deliveryChannel: normalizedOptional(inboxItem.assistantDeliveryChannel)
        )
    }

    var sessionOrigin: AskSessionOrigin {
        .assistantFollowUp
    }

    var invocationSurface: AskInvocationSurface {
        switch deliveryChannel {
        case AskAssistantDeliveryChannel.notification.rawValue:
            return .notification
        case AskAssistantDeliveryChannel.inbox.rawValue:
            return .inbox
        default:
            return .askWindow
        }
    }

    var requestedMode: AskExecutionMode {
        .interactive
    }

    var persistenceKey: String? {
        Self.persistenceKey(
            resumeToken: resumeToken,
            activeTaskID: activeTaskID,
            sourceTaskID: sourceTaskID,
            sourceRunID: sourceRunID,
            sourceJobID: sourceJobID
        )
    }

    var initialKernelMetadata: [String: String] {
        var metadata: [String: String] = [
            "latest_assistant_brief_title": clippedText(title, limit: 160),
            "latest_assistant_brief_kind": clippedText(kind, limit: 64),
            "active_task_title": clippedText(title, limit: 160),
            "active_task_objective": clippedText(summary, limit: 220)
        ]
        if let resolvedTaskID = activeTaskID ?? sourceTaskID {
            metadata["active_task_id"] = resolvedTaskID
        }
        if let sourceTaskStatus {
            metadata["active_task_status"] = sourceTaskStatus
        }
        if let resumeToken {
            metadata["active_task_resume_token"] = resumeToken
        }
        if let workspaceRoot {
            metadata["workspace_root"] = workspaceRoot
            metadata["active_task_workspace_root"] = workspaceRoot
        }
        if let deliveryChannel {
            metadata["latest_assistant_delivery_channel"] = deliveryChannel
        }
        if let sourceSessionID {
            metadata["assistant_delivery_session_id"] = sourceSessionID
        }
        if let sourceRunID {
            metadata["assistant_delivery_source_run_id"] = sourceRunID
        }
        if let sourceJobID {
            metadata["assistant_delivery_source_job_id"] = sourceJobID
        }
        return metadata
    }

    func suggestedPrompt(responseLanguage: String) -> String {
        if AppLanguage.from(languageCode: responseLanguage) == .english {
            return "Continue the previous assistant task: \(title)"
        }
        return "继续之前的任务：\(title)"
    }

    func encodedPayload() -> String? {
        let envelope = AskAssistantFollowUpActivationEnvelope(
            kind: Self.payloadKind,
            version: Self.payloadVersion,
            activation: self
        )
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(envelope),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    static func decodePayload(_ value: String) -> AskAssistantFollowUpActivation? {
        guard let data = value.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AskAssistantFollowUpActivationEnvelope.self, from: data),
              envelope.kind == payloadKind,
              envelope.version == payloadVersion else {
            return nil
        }
        return envelope.activation
    }

    var notificationUserInfo: [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [:]
        for (key, value) in initialKernelMetadata {
            userInfo[key] = value
        }
        if let payload = encodedPayload() {
            userInfo["assistant_followup_activation_payload"] = payload
        }
        userInfo["session_origin"] = sessionOrigin.rawValue
        userInfo["invocation_surface"] = invocationSurface.rawValue
        return userInfo
    }

    static func persistenceKey(from metadata: [String: String]) -> String? {
        persistenceKey(
            resumeToken: normalizedOptional(metadata["active_task_resume_token"]),
            activeTaskID: normalizedOptional(metadata["active_task_id"]),
            sourceTaskID: normalizedOptional(metadata["assistant_delivery_source_task_id"]),
            sourceRunID: normalizedOptional(metadata["assistant_delivery_source_run_id"]),
            sourceJobID: normalizedOptional(metadata["assistant_delivery_source_job_id"])
        )
    }

    static func persistenceKey(
        resumeToken: String?,
        activeTaskID: String?,
        sourceTaskID: String?,
        sourceRunID: String?,
        sourceJobID: String?
    ) -> String? {
        if let resumeToken = normalizedOptional(resumeToken) {
            return "resume:\(resumeToken)"
        }
        if let activeTaskID = normalizedOptional(activeTaskID) {
            return "task:\(activeTaskID)"
        }
        if let sourceTaskID = normalizedOptional(sourceTaskID) {
            return "source_task:\(sourceTaskID)"
        }
        if let sourceRunID = normalizedOptional(sourceRunID) {
            return "source_run:\(sourceRunID)"
        }
        if let sourceJobID = normalizedOptional(sourceJobID) {
            return "source_job:\(sourceJobID)"
        }
        return nil
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedValue(_ value: String?, fallback: String) -> String {
        normalizedOptional(value) ?? fallback
    }

    private func clippedText(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return ""
        }
        return String(normalized.prefix(limit))
    }
}

extension AskInboxItem {
    var assistantFollowUpActivation: AskAssistantFollowUpActivation? {
        AskAssistantFollowUpActivation.from(inboxItem: self)
    }
}
