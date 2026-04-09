import Foundation
import NexShared

final class AskTaskExecutionCoordinator {
    private let policyEngine: AskPolicyEvaluating
    private let executorRegistry: AskCapabilityExecutorRegistryProviding
    private let approvalRouter: AskApprovalRouting
    private let resultDelivery: AskResultDelivering
    private let taskStore: AskTaskStoring

    init(
        policyEngine: AskPolicyEvaluating,
        executorRegistry: AskCapabilityExecutorRegistryProviding,
        approvalRouter: AskApprovalRouting,
        resultDelivery: AskResultDelivering,
        taskStore: AskTaskStoring
    ) {
        self.policyEngine = policyEngine
        self.executorRegistry = executorRegistry
        self.approvalRouter = approvalRouter
        self.resultDelivery = resultDelivery
        self.taskStore = taskStore
    }

    func execute(
        preparedTask: AskPreparedTask,
        capabilityID: AskCapabilityID,
        arguments: AskInvocationMetadata = [:],
        dryRun: Bool = false
    ) async -> AskCapabilityExecutionResult {
        guard let capability = preparedTask.capabilities.first(where: { $0.id == capabilityID }) else {
            let result = AskCapabilityExecutionResult.unsupported(
                summary: "The requested capability is not available for this task."
            )
            return await deliverAndTrack(
                result: result,
                for: preparedTask.task,
                capabilityID: capabilityID,
                taskStatus: .failed,
                pendingApprovalID: nil
            )
        }

        let decision = policyEngine.executionDecision(
            for: capability,
            invocation: preparedTask.invocation,
            context: preparedTask.context,
            profile: preparedTask.profile,
            arguments: arguments
        )

        let request = AskCapabilityExecutionRequest(
            task: preparedTask.task,
            capability: capability,
            decision: decision,
            arguments: arguments,
            dryRun: dryRun,
            requestedAt: Date()
        )

        switch decision.kind {
        case .deny:
            let result = AskCapabilityExecutionResult.denied(summary: decision.reason)
            return await deliverAndTrack(
                result: result,
                for: preparedTask.task,
                capabilityID: capabilityID,
                taskStatus: .blocked,
                pendingApprovalID: nil
            )
        case .requireApproval:
            let approval = await approvalRouter.createApprovalRequest(for: request, reason: decision.reason)
            let result = AskCapabilityExecutionResult(
                status: .waitingApproval,
                summary: decision.reason,
                approvalID: approval.approvalID,
                artifacts: [],
                metadata: [
                    "approval_id": approval.approvalID,
                    "capability_id": capabilityID
                ]
            )
            return await deliverAndTrack(
                result: result,
                for: preparedTask.task,
                capabilityID: capabilityID,
                taskStatus: .waitingApproval,
                pendingApprovalID: approval.approvalID
            )
        case .allow:
            _ = await taskStore.mark(
                taskID: preparedTask.task.id,
                status: .running,
                pendingApprovalID: nil,
                appendingArtifacts: [],
                mergingMetadata: [
                    "latest_capability_id": capabilityID,
                    "latest_result_status": AskTaskStatus.running.rawValue,
                    "pending_approval_id": ""
                ]
            )
            guard let executor = executorRegistry.executor(for: capabilityID) else {
                let result = AskCapabilityExecutionResult.unsupported(
                    summary: "No executor is registered for \(capabilityID)."
                )
                return await deliverAndTrack(
                    result: result,
                    for: preparedTask.task,
                    capabilityID: capabilityID,
                    taskStatus: .failed,
                    pendingApprovalID: nil
                )
            }
            let result = await executor.execute(request: request)
            return await deliverAndTrack(
                result: result,
                for: preparedTask.task,
                capabilityID: capabilityID,
                taskStatus: taskStatus(for: result),
                pendingApprovalID: result.approvalID
            )
        }
    }

    func resolveApproval(
        approvalID: String,
        shouldApprove: Bool
    ) async -> AskCapabilityExecutionResult {
        guard let approval = await approvalRouter.approvalRequest(id: approvalID) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No pending approval request was found for this action.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "approval_id": approvalID,
                    "decision": shouldApprove ? "approve" : "cancel"
                ]
            )
        }

        _ = await approvalRouter.removeApprovalRequest(id: approvalID)

        guard shouldApprove else {
            let result = AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Cancelled the pending approval request.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "approval_id": approvalID,
                    "decision": "cancel",
                    "capability_id": approval.request.capability.id
                ]
            )
            return await deliverAndTrack(
                result: result,
                for: approval.request.task,
                capabilityID: approval.request.capability.id,
                taskStatus: .cancelled,
                pendingApprovalID: nil
            )
        }

        _ = await taskStore.mark(
            taskID: approval.request.task.id,
            status: .running,
            pendingApprovalID: nil,
            appendingArtifacts: [],
            mergingMetadata: [
                "latest_capability_id": approval.request.capability.id,
                "latest_result_status": AskTaskStatus.running.rawValue,
                "pending_approval_id": ""
            ]
        )

        guard let executor = executorRegistry.executor(for: approval.request.capability.id) else {
            let result = AskCapabilityExecutionResult(
                status: .unsupported,
                summary: "No executor is registered for \(approval.request.capability.id).",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "approval_id": approvalID,
                    "decision": "approve",
                    "capability_id": approval.request.capability.id
                ]
            )
            return await deliverAndTrack(
                result: result,
                for: approval.request.task,
                capabilityID: approval.request.capability.id,
                taskStatus: .failed,
                pendingApprovalID: nil
            )
        }

        let result = await executor.execute(request: approval.request)
        var resolved = AskCapabilityExecutionResult(
            status: result.status,
            summary: result.summary,
            approvalID: nil,
            artifacts: result.artifacts,
            metadata: result.metadata.merging(
                [
                    "approval_id": approvalID,
                    "decision": "approve",
                    "capability_id": approval.request.capability.id
                ]
            ) { current, _ in current }
        )
        resolved = resultWithTaskScopeGrantIfNeeded(
            resolved,
            approval: approval
        )
        return await deliverAndTrack(
            result: resolved,
            for: approval.request.task,
            capabilityID: approval.request.capability.id,
            taskStatus: taskStatus(for: resolved),
            pendingApprovalID: nil
        )
    }

    private func deliverAndTrack(
        result: AskCapabilityExecutionResult,
        for task: AskAgentTask,
        capabilityID: AskCapabilityID,
        taskStatus: AskTaskStatus,
        pendingApprovalID: String?
    ) async -> AskCapabilityExecutionResult {
        await resultDelivery.deliver(
            result: result,
            for: task,
            capabilityID: capabilityID
        )
        _ = await taskStore.mark(
            taskID: task.id,
            status: taskStatus,
            pendingApprovalID: pendingApprovalID,
            appendingArtifacts: result.artifacts.map(\.value),
            mergingMetadata: taskMetadata(
                from: result,
                capabilityID: capabilityID,
                pendingApprovalID: pendingApprovalID
            )
        )
        return result
    }

    private func taskStatus(for result: AskCapabilityExecutionResult) -> AskTaskStatus {
        switch result.status {
        case .succeeded:
            return .completed
        case .waitingApproval:
            return .waitingApproval
        case .denied:
            return .blocked
        case .failed, .unsupported:
            return .failed
        }
    }

    private func taskMetadata(
        from result: AskCapabilityExecutionResult,
        capabilityID: AskCapabilityID,
        pendingApprovalID: String?
    ) -> AskInvocationMetadata {
        var metadata = result.metadata
        metadata["latest_capability_id"] = capabilityID
        metadata["latest_result_status"] = result.status.rawValue
        metadata["latest_result_summary"] = clippedSummary(result.summary)
        metadata["pending_approval_id"] = pendingApprovalID ?? ""
        return metadata
    }

    private func resultWithTaskScopeGrantIfNeeded(
        _ result: AskCapabilityExecutionResult,
        approval: AskCapabilityApprovalRecord
    ) -> AskCapabilityExecutionResult {
        guard [
            "workspace.create_directory",
            "workspace.write_file",
            "workspace.run_shell_command",
            "workspace.commit_changes"
        ].contains(approval.request.capability.id) else {
            return result
        }

        let grantedRoot =
            AskWorkspaceRootSupport.normalizedWorkspaceRoot(result.metadata["workspace_root"])
            ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(result.metadata["active_task_workspace_root"])
            ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(approval.request.arguments["workspace_root"])
            ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(approval.request.task.metadata["workspace_root"])
            ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(approval.request.task.metadata["active_task_workspace_root"])
            ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(approval.request.task.context.workspaceRootPath)

        guard let grantedRoot,
              !grantedRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return result
        }

        let grantMetadata: AskInvocationMetadata = [
            "interactive_task_scope_granted": "true",
            "interactive_task_scope_root": grantedRoot,
            "workspace_root": grantedRoot,
            "active_task_workspace_root": grantedRoot,
            "workspace_write_granted": "true",
            "workspace_patch_granted": "true",
            "workspace_shell_granted": "true",
            "workspace_permission_profile": AskWorkspacePermissionProfile.workspaceWritesAndShellExecution.rawValue,
            "workspace_execution_budget": AskWorkspacePermissionProfile.workspaceWritesAndShellExecution.rawValue
        ]

        return AskCapabilityExecutionResult(
            status: result.status,
            summary: result.summary,
            approvalID: result.approvalID,
            artifacts: result.artifacts,
            metadata: result.metadata.merging(grantMetadata) { current, _ in current }
        )
    }

    private func clippedSummary(_ summary: String) -> String {
        let normalized = summary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(180))
    }
}
