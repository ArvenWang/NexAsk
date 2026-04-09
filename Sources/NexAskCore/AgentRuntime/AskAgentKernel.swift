import Foundation
import NexShared

struct AskAgentKernelDependencies {
    let invocationBroker: AskInvocationBrokering
    let contextCaptureHub: AskContextCapturing
    let modeResolver: AskModeResolving
    let capabilityRegistry: AskCapabilityRegistryProviding
    let policyEngine: AskPolicyEvaluating
    let taskStore: AskTaskStoring
    let memoryFabric: AskMemoryFabricProviding
    let executorRegistry: AskCapabilityExecutorRegistryProviding
    let approvalRouter: AskApprovalRouting
    let resultStore: AskKernelResultStore
    let resultDelivery: AskResultDelivering

    static func `default`(
        resultStore: AskKernelResultStore = .shared,
        approvalRouter: AskApprovalRouting = AskInMemoryApprovalRouter.shared,
        resultDelivery: AskResultDelivering? = nil,
        timeExecutor: AskTimeExecutor = AskTimeExecutor(),
        desktopExecutor: AskDesktopExecutor = AskDesktopExecutor(),
        browserExecutor: AskBrowserExecutor = AskBrowserExecutor()
    ) -> AskAgentKernelDependencies {
        let taskStore = AskInMemoryTaskStore.shared
        let resolvedResultDelivery = resultDelivery ?? AskStoreBackedResultDelivery(store: resultStore)
        return AskAgentKernelDependencies(
            invocationBroker: AskDefaultInvocationBroker(),
            contextCaptureHub: AskLiveContextCaptureHub(),
            modeResolver: AskDefaultModeResolver(),
            capabilityRegistry: AskCapabilityCatalog.defaultRegistry(),
            policyEngine: AskDefaultPolicyEngine(),
            taskStore: taskStore,
            memoryFabric: AskStoreBackedMemoryFabric(
                resultStore: resultStore,
                taskStore: taskStore
            ),
            executorRegistry: AskStaticCapabilityExecutorRegistry(executors: [
                timeExecutor,
                AskSystemExecutor(taskStore: taskStore),
                desktopExecutor,
                browserExecutor,
                AskAppControlExecutor(),
                AskWorkspaceExecutor()
            ]),
            approvalRouter: approvalRouter,
            resultStore: resultStore,
            resultDelivery: resolvedResultDelivery
        )
    }
}

final class AskAgentKernel {
    static let shared = AskAgentKernel()

    private let dependencies: AskAgentKernelDependencies

    init(dependencies: AskAgentKernelDependencies = .default()) {
        self.dependencies = dependencies
    }

    func prepareTask(
        prompt: String,
        surface: AskInvocationSurface,
        requestedMode: AskExecutionMode? = nil,
        sessionID: String? = nil,
        parentTaskID: String? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        metadata: AskInvocationMetadata = [:],
        policyProfile: AskPolicyProfile? = nil
    ) async -> AskPreparedTask {
        let invocation = await dependencies.invocationBroker.makeInvocation(
            prompt: prompt,
            surface: surface,
            requestedMode: requestedMode,
            sessionID: sessionID,
            parentTaskID: parentTaskID,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            metadata: metadata.merging(sessionID.map { ["session_id": $0] } ?? [:]) { current, _ in current }
        )
        let capturedContext = await dependencies.contextCaptureHub.captureContext(for: invocation)
        let sessionMemorySummary = await dependencies.memoryFabric.sessionSummary(sessionID: invocation.sessionID)
        let workspaceMemorySummary = await dependencies.memoryFabric.workspaceSummary(
            rootPath: capturedContext.workspaceRootPath ?? invocation.metadata["workspace_root"]
        )
        let context = enrichedContext(
            from: capturedContext,
            sessionMemorySummary: sessionMemorySummary,
            workspaceMemorySummary: workspaceMemorySummary
        )
        let resolvedMode = await dependencies.modeResolver.resolveMode(for: invocation, context: context)
        let effectiveProfile = policyProfile ?? AskPolicyProfile.preset(for: resolvedMode)
        let capabilities = dependencies.capabilityRegistry.capabilities(for: resolvedMode, context: context)
        let decisions = Dictionary(uniqueKeysWithValues: capabilities.map { capability in
            (
                capability.id,
                dependencies.policyEngine.decision(
                    for: capability,
                    invocation: invocation,
                    context: context,
                    profile: effectiveProfile
                )
            )
        })
        let task = AskAgentTask.make(
            title: taskTitle(for: prompt, mode: resolvedMode),
            objective: prompt,
            mode: resolvedMode,
            invocation: invocation,
            context: context,
            automationJobID: metadata["automation_job_id"]
        )
        await dependencies.taskStore.save(task)
        return AskPreparedTask(
            invocation: invocation,
            context: context,
            task: task,
            profile: effectiveProfile,
            capabilities: capabilities,
            capabilityDecisions: decisions
        )
    }

    func task(id: String) async -> AskAgentTask? {
        await dependencies.taskStore.task(id: id)
    }

    func tasks(sessionID: String?) async -> [AskAgentTask] {
        await dependencies.taskStore.tasks(for: sessionID)
    }

    func resultRecords(taskID: String) async -> [AskKernelDeliveredResultRecord] {
        await dependencies.resultStore.records(taskID: taskID)
    }

    func resultRecords(sessionID: String?, limit: Int = 40) async -> [AskKernelDeliveredResultRecord] {
        await dependencies.resultStore.records(sessionID: sessionID, limit: limit)
    }

    func makeExecutionCoordinator() -> AskTaskExecutionCoordinator {
        AskTaskExecutionCoordinator(
            policyEngine: dependencies.policyEngine,
            executorRegistry: dependencies.executorRegistry,
            approvalRouter: dependencies.approvalRouter,
            resultDelivery: dependencies.resultDelivery,
            taskStore: dependencies.taskStore
        )
    }

    private func enrichedContext(
        from context: AskExecutionContext,
        sessionMemorySummary: String?,
        workspaceMemorySummary: String?
    ) -> AskExecutionContext {
        var metadata = context.metadata
        if let sessionMemorySummary, !sessionMemorySummary.isEmpty {
            metadata["session_memory_summary"] = sessionMemorySummary
        }
        if let workspaceMemorySummary, !workspaceMemorySummary.isEmpty {
            metadata["workspace_memory_summary"] = workspaceMemorySummary
        }
        guard metadata != context.metadata else { return context }
        return AskExecutionContext(
            surface: context.surface,
            sourceBundleID: context.sourceBundleID,
            sourceAppName: context.sourceAppName,
            workspaceRootPath: context.workspaceRootPath,
            ambientContext: context.ambientContext,
            timeZoneIdentifier: context.timeZoneIdentifier,
            isUserPresent: context.isUserPresent,
            metadata: metadata
        )
    }

    private func taskTitle(for prompt: String, mode: AskExecutionMode) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback: String
        switch mode {
        case .interactive:
            fallback = "Interactive Ask"
        case .automate:
            fallback = "Automate"
        }
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(64))
    }
}
