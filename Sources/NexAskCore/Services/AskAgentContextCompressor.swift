import Foundation
import NexShared

struct AskAgentCompressedContext {
    let messages: [AskAgentMessage]
    let droppedConversationMessageCount: Int
    let summaryIncluded: Bool
}

enum AskAgentContextCompressor {
    private static let recentMessageLimit = 6
    private static let recentCharacterBudget = 4_000
    private static let perMessageCharacterLimit = 900

    static func compress(
        messages: [AskAgentMessage],
        sessionState: AskAgentSessionState?,
        responseLanguage: String
    ) -> AskAgentCompressedContext {
        let systemPrefix = Array(messages.prefix { $0.role == .system })
        let conversation = Array(messages.dropFirst(systemPrefix.count))
        let recentConversation = boundedRecentConversation(from: conversation)
        let droppedCount = max(0, conversation.count - recentConversation.count)
        let olderConversation = Array(conversation.prefix(droppedCount))

        let summary = summaryMessage(
            olderConversation: olderConversation,
            sessionState: sessionState,
            responseLanguage: responseLanguage
        )

        var compressedMessages = systemPrefix
        if let summary {
            compressedMessages.append(.system(summary))
        }
        compressedMessages.append(contentsOf: recentConversation)
        return AskAgentCompressedContext(
            messages: compressedMessages,
            droppedConversationMessageCount: droppedCount,
            summaryIncluded: summary != nil
        )
    }

    private static func boundedRecentConversation(from messages: [AskAgentMessage]) -> [AskAgentMessage] {
        var keptReversed: [AskAgentMessage] = []
        var usedCharacters = 0

        for message in messages.reversed() {
            guard let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                continue
            }

            let boundedContent = boundedText(content, limit: perMessageCharacterLimit)
            let projectedCount = usedCharacters + boundedContent.count
            if !keptReversed.isEmpty && (keptReversed.count >= recentMessageLimit || projectedCount > recentCharacterBudget) {
                break
            }

            keptReversed.append(copy(message, content: boundedContent))
            usedCharacters = projectedCount
        }

        return keptReversed.reversed()
    }

    private static func summaryMessage(
        olderConversation: [AskAgentMessage],
        sessionState: AskAgentSessionState?,
        responseLanguage: String
    ) -> String? {
        let olderUserGoals = olderConversation
            .filter { $0.role == .user }
            .compactMap { $0.content?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .map { boundedText($0, limit: 180) }

        let recentToolOutcomes = sessionState?.toolCallHistory.suffix(5).map { record -> String in
            let parts = [
                record.toolName,
                boundedText(record.summary, limit: 120),
                record.actionID.map { "action_id=\($0)" },
                record.operationID.map { "operation_id=\($0)" }
            ].compactMap { $0 }
            return parts.joined(separator: " | ")
        } ?? []

        let recentTimeline = sessionState?.stepTimeline
            .filter { $0.kind != .planning }
            .suffix(4)
            .map { step in
                boundedText(step.summary, limit: 140)
            } ?? []

        let snapshotRefs = Array((sessionState?.snapshotRefs ?? []).suffix(3))
        let selectionRefs = Array((sessionState?.selectionRefs ?? []).suffix(3))
        let operationRefs = Array((sessionState?.stagedOperationRefs ?? []).suffix(3))
        let lastFinalResponse = sessionState?.lastFinalResponse.map { boundedText($0, limit: 180) }
        let planModeSummary = sessionState?.planModeSummary.map { boundedText($0, limit: 180) }
        let planModeActive = sessionState?.planModeActive == true
        let workspaceWriteGranted = sessionState?.workspaceWriteGranted == true
        let workspaceShellGranted = sessionState?.workspaceShellGranted == true
        let workspaceGitWriteGranted = sessionState?.workspaceGitWriteGranted == true
        let workspaceNetworkAccessGranted = sessionState?.workspaceNetworkAccessGranted == true
        let workspacePermissionProfile = sessionState?.workspacePermissionProfile.rawValue
        let childTaskCount = sessionState?.childTaskCount
        let openChildTaskCount = sessionState?.openChildTaskCount
        let latestChildTaskStatus = sessionState?.latestChildTaskStatus?.rawValue
        let latestChildTaskTitle = sessionState?.latestChildTaskTitle.map { boundedText($0, limit: 140) }
        let activeTaskTitle = sessionState?.activeTaskTitle.map { boundedText($0, limit: 140) }
        let activeTaskObjective = sessionState?.activeTaskObjective.map { boundedText($0, limit: 180) }
        let activeTaskStatus = sessionState?.activeTaskStatus?.rawValue
        let activeTaskResumeToken = sessionState?.activeTaskResumeToken
        let activeTaskWorkspaceRoot = sessionState?.activeTaskWorkspaceRoot.map { boundedText($0, limit: 160) }
        let latestAssistantBriefTitle = sessionState?.latestAssistantBriefTitle.map { boundedText($0, limit: 140) }
        let latestAssistantBriefKind = sessionState?.latestAssistantBriefKind
        let latestAssistantDeliveryChannel = sessionState?.latestAssistantDeliveryChannel
        let hasChildTaskContinuity =
            (childTaskCount ?? 0) > 0
            || (openChildTaskCount ?? 0) > 0
            || latestChildTaskTitle != nil
        let hasActiveTaskContinuity =
            activeTaskTitle != nil
            || activeTaskObjective != nil
            || activeTaskStatus != nil
        let hasAssistantDeliveryContinuity =
            latestAssistantBriefTitle != nil
            || latestAssistantBriefKind != nil
            || latestAssistantDeliveryChannel != nil
        let hasExecutionBudget =
            workspaceWriteGranted
            || workspaceShellGranted
            || workspaceGitWriteGranted
            || workspaceNetworkAccessGranted

        let hasOperationalMemory =
            !(recentToolOutcomes.isEmpty && recentTimeline.isEmpty && snapshotRefs.isEmpty && selectionRefs.isEmpty && operationRefs.isEmpty)
            || sessionState?.approvalState != nil
            || lastFinalResponse != nil
            || planModeActive
            || planModeSummary != nil
            || hasExecutionBudget
            || hasChildTaskContinuity
            || hasActiveTaskContinuity
            || hasAssistantDeliveryContinuity

        guard !olderUserGoals.isEmpty || hasOperationalMemory else {
            return nil
        }

        if AppLanguage.from(languageCode: responseLanguage) == .english {
            var sections: [String] = [
                """
                Compressed session memory for older turns. Treat this as structured context, not user-visible prose.
                Prefer the recent verbatim messages for wording, and use this memory to preserve goals, approvals, tool outcomes, and reusable refs.
                """
            ]

            if !olderUserGoals.isEmpty {
                sections.append(
                    """
                    Older user goals:
                    \(olderUserGoals.map { "- \($0)" }.joined(separator: "\n"))
                    """
                )
            }
            if let approval = sessionState?.approvalState {
                sections.append(
                    """
                    Active approval:
                    - action_id=\(approval.actionID)
                    - tool=\(approval.toolName)
                    - target=\(approval.targetSummary)
                    - affected_count=\(approval.affectedCount)
                    - summary=\(boundedText(approval.summary, limit: 140))
                    """
                )
            }
            if planModeActive || planModeSummary != nil {
                sections.append(
                    """
                    Workspace planning state:
                    - plan_mode_active=\(planModeActive)
                    - edit_scope_limited=\(sessionState?.editScopeLimited == true)
                    \(planModeSummary.map { "- plan_summary=\($0)" } ?? "")
                    """
                )
            }
            if hasExecutionBudget {
                sections.append(
                    """
                    Workspace execution budget:
                    \(workspacePermissionProfile.map { "- workspace_permission_profile=\($0)" } ?? "")
                    - workspace_write_granted=\(workspaceWriteGranted)
                    - workspace_shell_granted=\(workspaceShellGranted)
                    - workspace_git_write_granted=\(workspaceGitWriteGranted)
                    - workspace_network_access_granted=\(workspaceNetworkAccessGranted)
                    """
                )
            }
            if hasChildTaskContinuity {
                sections.append(
                    """
                    Child task continuity:
                    \(childTaskCount.map { "- child_task_count=\($0)" } ?? "")
                    \(openChildTaskCount.map { "- open_child_task_count=\($0)" } ?? "")
                    \(latestChildTaskStatus.map { "- latest_child_task_status=\($0)" } ?? "")
                    \(latestChildTaskTitle.map { "- latest_child_task_title=\($0)" } ?? "")
                    """
                )
            }
            if hasActiveTaskContinuity {
                sections.append(
                    """
                    Active task continuity:
                    \(activeTaskTitle.map { "- active_task_title=\($0)" } ?? "")
                    \(activeTaskObjective.map { "- active_task_objective=\($0)" } ?? "")
                    \(activeTaskStatus.map { "- active_task_status=\($0)" } ?? "")
                    \(activeTaskWorkspaceRoot.map { "- active_task_workspace_root=\($0)" } ?? "")
                    \(activeTaskResumeToken.map { "- active_task_resume_token=\($0)" } ?? "")
                    """
                )
            }
            if hasAssistantDeliveryContinuity {
                sections.append(
                    """
                    Assistant delivery continuity:
                    \(latestAssistantBriefTitle.map { "- latest_assistant_brief_title=\($0)" } ?? "")
                    \(latestAssistantBriefKind.map { "- latest_assistant_brief_kind=\($0)" } ?? "")
                    \(latestAssistantDeliveryChannel.map { "- latest_assistant_delivery_channel=\($0)" } ?? "")
                    """
                )
            }
            if !recentToolOutcomes.isEmpty {
                sections.append(
                    """
                    Recent tool outcomes:
                    \(recentToolOutcomes.map { "- \($0)" }.joined(separator: "\n"))
                    """
                )
            }
            if !recentTimeline.isEmpty {
                sections.append(
                    """
                    Recent execution milestones:
                    \(recentTimeline.map { "- \($0)" }.joined(separator: "\n"))
                    """
                )
            }
            let refs = referenceLines(snapshotRefs: snapshotRefs, selectionRefs: selectionRefs, operationRefs: operationRefs)
            if !refs.isEmpty {
                sections.append(
                    """
                    Reusable refs:
                    \(refs.map { "- \($0)" }.joined(separator: "\n"))
                    """
                )
            }
            if let lastFinalResponse {
                sections.append("Last final answer: \(lastFinalResponse)")
            }
            return sections.joined(separator: "\n\n")
        }

        var sections: [String] = [
            """
            下面是较早轮次的压缩记忆，只用于延续同一个任务，不要把它原样复述给用户。
            回答措辞优先参考最近保留的原文消息；这段记忆主要用来保留任务目标、审批态、工具结果和可复用引用。
            """
        ]

        if !olderUserGoals.isEmpty {
            sections.append(
                """
                较早的用户目标：
                \(olderUserGoals.map { "- \($0)" }.joined(separator: "\n"))
                """
            )
        }
        if let approval = sessionState?.approvalState {
            sections.append(
                """
                当前待审批动作：
                - action_id=\(approval.actionID)
                - tool=\(approval.toolName)
                - target=\(approval.targetSummary)
                - affected_count=\(approval.affectedCount)
                - summary=\(boundedText(approval.summary, limit: 140))
                """
            )
        }
        if planModeActive || planModeSummary != nil {
            sections.append(
                """
                当前工作区规划状态：
                - plan_mode_active=\(planModeActive)
                - edit_scope_limited=\(sessionState?.editScopeLimited == true)
                \(planModeSummary.map { "- plan_summary=\($0)" } ?? "")
                """
            )
        }
        if hasExecutionBudget {
            sections.append(
                """
                当前工作区执行预算：
                \(workspacePermissionProfile.map { "- workspace_permission_profile=\($0)" } ?? "")
                - workspace_write_granted=\(workspaceWriteGranted)
                - workspace_shell_granted=\(workspaceShellGranted)
                - workspace_git_write_granted=\(workspaceGitWriteGranted)
                - workspace_network_access_granted=\(workspaceNetworkAccessGranted)
                """
            )
        }
        if hasChildTaskContinuity {
            sections.append(
                """
                子任务连续性：
                \(childTaskCount.map { "- child_task_count=\($0)" } ?? "")
                \(openChildTaskCount.map { "- open_child_task_count=\($0)" } ?? "")
                \(latestChildTaskStatus.map { "- latest_child_task_status=\($0)" } ?? "")
                \(latestChildTaskTitle.map { "- latest_child_task_title=\($0)" } ?? "")
                """
            )
        }
        if hasActiveTaskContinuity {
            sections.append(
                """
                当前任务连续性：
                \(activeTaskTitle.map { "- active_task_title=\($0)" } ?? "")
                \(activeTaskObjective.map { "- active_task_objective=\($0)" } ?? "")
                \(activeTaskStatus.map { "- active_task_status=\($0)" } ?? "")
                \(activeTaskWorkspaceRoot.map { "- active_task_workspace_root=\($0)" } ?? "")
                \(activeTaskResumeToken.map { "- active_task_resume_token=\($0)" } ?? "")
                """
            )
        }
        if hasAssistantDeliveryContinuity {
            sections.append(
                """
                Assistant 回传连续性：
                \(latestAssistantBriefTitle.map { "- latest_assistant_brief_title=\($0)" } ?? "")
                \(latestAssistantBriefKind.map { "- latest_assistant_brief_kind=\($0)" } ?? "")
                \(latestAssistantDeliveryChannel.map { "- latest_assistant_delivery_channel=\($0)" } ?? "")
                """
            )
        }
        if !recentToolOutcomes.isEmpty {
            sections.append(
                """
                最近工具结果：
                \(recentToolOutcomes.map { "- \($0)" }.joined(separator: "\n"))
                """
            )
        }
        if !recentTimeline.isEmpty {
            sections.append(
                """
                最近执行里程碑：
                \(recentTimeline.map { "- \($0)" }.joined(separator: "\n"))
                """
            )
        }
        let refs = referenceLines(snapshotRefs: snapshotRefs, selectionRefs: selectionRefs, operationRefs: operationRefs)
        if !refs.isEmpty {
            sections.append(
                """
                可复用引用：
                \(refs.map { "- \($0)" }.joined(separator: "\n"))
                """
            )
        }
        if let lastFinalResponse {
            sections.append("最近一次最终回答：\(lastFinalResponse)")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func referenceLines(
        snapshotRefs: [String],
        selectionRefs: [String],
        operationRefs: [String]
    ) -> [String] {
        var lines: [String] = []
        if !snapshotRefs.isEmpty {
            lines.append("snapshot_ids=\(snapshotRefs.joined(separator: ", "))")
        }
        if !selectionRefs.isEmpty {
            lines.append("selection_ids=\(selectionRefs.joined(separator: ", "))")
        }
        if !operationRefs.isEmpty {
            lines.append("operation_ids=\(operationRefs.joined(separator: ", "))")
        }
        return lines
    }

    private static func boundedText(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let headCount = max(0, limit - 32)
        let head = trimmed.prefix(headCount)
        return "\(head)… [truncated]"
    }

    private static func copy(_ message: AskAgentMessage, content: String) -> AskAgentMessage {
        AskAgentMessage(
            role: message.role,
            content: content,
            toolCallID: message.toolCallID,
            toolName: message.toolName,
            toolCalls: message.toolCalls
        )
    }
}
