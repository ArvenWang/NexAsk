import Foundation
import NexShared

struct AskSessionKernelPreparation {
    let request: AskSessionRequest
    let preparedTask: AskPreparedTask
}

struct AskKernelResultSummary: Sendable {
    let totalCount: Int
    let succeededCount: Int
    let failureCount: Int
    let waitingApprovalCount: Int
    let taskCount: Int
    let childTaskCount: Int
    let openChildTaskCount: Int
    let waitingTaskCount: Int
    let latestCapabilityID: String?
    let latestStatus: AskCapabilityExecutionStatus?
    let latestSummary: String?
    let latestTaskStatus: AskTaskStatus?
    let latestTaskTitle: String?
    let latestChildTaskStatus: AskTaskStatus?
    let latestChildTaskTitle: String?
    let latestAssistantBriefTitle: String?
    let latestAssistantBriefKind: String?
    let latestAssistantDeliveryChannel: String?
}

final class AskSessionKernelBridge {
    private let kernel: AskAgentKernel

    init(kernel: AskAgentKernel = .shared) {
        self.kernel = kernel
    }

    func prepare(request: AskSessionRequest) async -> AskSessionKernelPreparation {
        let prompt = request.messages.last(where: { $0.role == .user })?.content ?? ""
        let preparedTask = await kernel.prepareTask(
            prompt: prompt,
            surface: request.metadata.invocationSurface,
            requestedMode: request.metadata.requestedMode,
            sessionID: request.metadata.sessionID,
            sourceBundleID: request.metadata.sourceBundleID,
            sourceAppName: request.metadata.sourceAppName,
            metadata: kernelInvocationMetadata(from: request)
        )

        let enrichedMetadata = AskSessionMetadata(
            sessionID: request.metadata.sessionID,
            sourceBundleID: request.metadata.sourceBundleID,
            sourceAppName: request.metadata.sourceAppName,
            frame: request.metadata.frame,
            sessionOrigin: request.metadata.sessionOrigin,
            automationJobID: request.metadata.automationJobID,
            automationPolicy: request.metadata.automationPolicy,
            invocationSurface: request.metadata.invocationSurface,
            requestedMode: request.metadata.requestedMode,
            kernelMetadata: request.metadata.kernelMetadata.merging(
                kernelMetadata(from: preparedTask),
                uniquingKeysWith: { _, new in new }
            )
        )

        return AskSessionKernelPreparation(
            request: AskSessionRequest(
                messages: request.messages,
                metadata: enrichedMetadata,
                uiLanguage: request.uiLanguage,
                responseLanguage: request.responseLanguage
            ),
            preparedTask: preparedTask
        )
    }

    func resultSummary(sessionID: String?) async -> AskKernelResultSummary? {
        let records = await kernel.resultRecords(sessionID: sessionID, limit: 64)
        let tasks = await kernel.tasks(sessionID: sessionID)
        guard !records.isEmpty || !tasks.isEmpty else { return nil }
        let succeededCount = records.filter { $0.status == .succeeded }.count
        let waitingApprovalCount = records.filter { $0.status == .waitingApproval }.count
        let failureCount = records.filter { record in
            switch record.status {
            case .failed, .denied, .unsupported:
                return true
            case .succeeded, .waitingApproval:
                return false
            }
        }.count
        let childTasks = tasks.filter { $0.lineage.parentTaskID != nil }
        let latestTask = tasks.last
        let latestChildTask = childTasks.last
        let latestDeliveryRecord = records.first { record in
            record.metadata["assistant_brief_title"] != nil
                || record.metadata["assistant_delivery_channel"] != nil
        }
        return AskKernelResultSummary(
            totalCount: records.count,
            succeededCount: succeededCount,
            failureCount: failureCount,
            waitingApprovalCount: waitingApprovalCount,
            taskCount: tasks.count,
            childTaskCount: childTasks.count,
            openChildTaskCount: childTasks.filter { task in
                switch task.status {
                case .completed, .failed, .cancelled:
                    return false
                case .queued, .planning, .waitingApproval, .running, .blocked:
                    return true
                }
            }.count,
            waitingTaskCount: tasks.filter { $0.status == .waitingApproval }.count,
            latestCapabilityID: records.first?.capabilityID,
            latestStatus: records.first?.status,
            latestSummary: records.first?.summary,
            latestTaskStatus: latestTask?.status,
            latestTaskTitle: latestTask?.title,
            latestChildTaskStatus: latestChildTask?.status,
            latestChildTaskTitle: latestChildTask?.title,
            latestAssistantBriefTitle: latestDeliveryRecord?.metadata["assistant_brief_title"],
            latestAssistantBriefKind: latestDeliveryRecord?.metadata["assistant_brief_kind"],
            latestAssistantDeliveryChannel: latestDeliveryRecord?.metadata["assistant_delivery_channel"]
        )
    }

    private func kernelInvocationMetadata(from request: AskSessionRequest) -> AskInvocationMetadata {
        var metadata = request.metadata.kernelMetadata
        if let sourceBundleID = request.metadata.sourceBundleID {
            metadata["source_bundle_id"] = sourceBundleID
        }
        if let sourceAppName = request.metadata.sourceAppName {
            metadata["source_app_name"] = sourceAppName
        }
        metadata["session_origin"] = request.metadata.sessionOrigin.rawValue
        metadata["frame_width"] = String(Int(request.metadata.frame.width.rounded()))
        metadata["frame_height"] = String(Int(request.metadata.frame.height.rounded()))
        if let automationJobID = request.metadata.automationJobID {
            metadata["automation_job_id"] = automationJobID
        }
        return metadata
    }

    private func kernelMetadata(from preparedTask: AskPreparedTask) -> [String: String] {
        var metadata: [String: String] = [
            "kernel_invocation_id": preparedTask.invocation.id,
            "kernel_task_id": preparedTask.task.id,
            "kernel_task_status": preparedTask.task.status.rawValue,
            "kernel_task_title": preparedTask.task.title,
            "kernel_mode": preparedTask.task.mode.rawValue,
            "kernel_profile_id": preparedTask.profile.id,
            "kernel_capability_count": String(preparedTask.capabilities.count)
        ]
        if let workspaceRoot = preparedTask.context.workspaceRootPath {
            metadata["workspace_root"] = workspaceRoot
        }
        if let currentPageURL = preparedTask.context.currentPageURL {
            metadata["current_page_url"] = currentPageURL
        }
        if let currentPageTitle = preparedTask.context.currentPageTitle {
            metadata["current_page_title"] = currentPageTitle
        }
        if let selectedTextPreview = preparedTask.context.selectedTextPreview {
            metadata["selection_preview"] = selectedTextPreview
        }
        if let frontmostBundleID = preparedTask.context.frontmostBundleID {
            metadata["frontmost_bundle_id"] = frontmostBundleID
        }
        if let sessionMemorySummary = preparedTask.context.metadata["session_memory_summary"], !sessionMemorySummary.isEmpty {
            metadata["session_memory_summary"] = sessionMemorySummary
        }
        if let workspaceMemorySummary = preparedTask.context.metadata["workspace_memory_summary"], !workspaceMemorySummary.isEmpty {
            metadata["workspace_memory_summary"] = workspaceMemorySummary
        }
        return metadata
    }
}
