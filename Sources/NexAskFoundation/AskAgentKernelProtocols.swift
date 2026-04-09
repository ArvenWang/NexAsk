import Foundation

package protocol AskInvocationBrokering {
    func makeInvocation(
        prompt: String,
        surface: AskInvocationSurface,
        requestedMode: AskExecutionMode?,
        sessionID: String?,
        parentTaskID: String?,
        sourceBundleID: String?,
        sourceAppName: String?,
        metadata: AskInvocationMetadata
    ) async -> AskInvocation
}

package protocol AskContextCapturing {
    func captureContext(for invocation: AskInvocation) async -> AskExecutionContext
}

package protocol AskModeResolving {
    func resolveMode(for invocation: AskInvocation, context: AskExecutionContext) async -> AskExecutionMode
}

package protocol AskCapabilityRegistryProviding {
    func capabilities(for mode: AskExecutionMode, context: AskExecutionContext) -> [AskCapabilityDefinition]
}

package protocol AskPolicyEvaluating {
    func decision(
        for capability: AskCapabilityDefinition,
        invocation: AskInvocation,
        context: AskExecutionContext,
        profile: AskPolicyProfile
    ) -> AskPolicyDecision

    func executionDecision(
        for capability: AskCapabilityDefinition,
        invocation: AskInvocation,
        context: AskExecutionContext,
        profile: AskPolicyProfile,
        arguments: AskInvocationMetadata
    ) -> AskPolicyDecision
}

package extension AskPolicyEvaluating {
    func executionDecision(
        for capability: AskCapabilityDefinition,
        invocation: AskInvocation,
        context: AskExecutionContext,
        profile: AskPolicyProfile,
        arguments: AskInvocationMetadata
    ) -> AskPolicyDecision {
        _ = arguments
        return decision(
            for: capability,
            invocation: invocation,
            context: context,
            profile: profile
        )
    }
}

package protocol AskTaskStoring {
    func save(_ task: AskAgentTask) async
    func task(id: String) async -> AskAgentTask?
    func tasks(for sessionID: String?) async -> [AskAgentTask]
    func mark(
        taskID: String,
        status: AskTaskStatus,
        pendingApprovalID: String?,
        appendingArtifacts artifacts: [String],
        mergingMetadata metadata: AskInvocationMetadata
    ) async -> AskAgentTask?
}

package protocol AskMemoryFabricProviding {
    func sessionSummary(sessionID: String?) async -> String?
    func workspaceSummary(rootPath: String?) async -> String?
}

package struct AskDefaultInvocationBroker: AskInvocationBrokering {
    package init() {}

    package func makeInvocation(
        prompt: String,
        surface: AskInvocationSurface,
        requestedMode: AskExecutionMode?,
        sessionID: String?,
        parentTaskID: String?,
        sourceBundleID: String?,
        sourceAppName: String?,
        metadata: AskInvocationMetadata
    ) async -> AskInvocation {
        AskInvocation(
            id: UUID().uuidString.lowercased(),
            sessionID: sessionID,
            parentTaskID: parentTaskID,
            prompt: prompt,
            surface: surface,
            requestedMode: requestedMode,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            createdAt: Date(),
            metadata: metadata
        )
    }
}

package struct AskDefaultContextCaptureHub: AskContextCapturing {
    package init() {}

    package func captureContext(for invocation: AskInvocation) async -> AskExecutionContext {
        AskExecutionContext.empty(
            surface: invocation.surface,
            sourceBundleID: invocation.sourceBundleID,
            sourceAppName: invocation.sourceAppName,
            metadata: invocation.metadata
        )
    }
}

package struct AskDefaultModeResolver: AskModeResolving {
    package init() {}

    package func resolveMode(for invocation: AskInvocation, context: AskExecutionContext) async -> AskExecutionMode {
        if invocation.surface == .automation || invocation.metadata["automation_job_id"] != nil || invocation.requestedMode == .automate {
            return .automate
        }
        _ = context
        return .interactive
    }
}

package struct AskStaticCapabilityRegistry: AskCapabilityRegistryProviding {
    private let catalog: [AskExecutionMode: [AskCapabilityDefinition]]

    package init(catalog: [AskExecutionMode: [AskCapabilityDefinition]]) {
        self.catalog = catalog
    }

    package func capabilities(for mode: AskExecutionMode, context: AskExecutionContext) -> [AskCapabilityDefinition] {
        let capabilities = catalog[mode] ?? []
        return capabilities.filter { capability in
            capability.requiredContextKeys.allSatisfy { key in
                switch key {
                case "workspace_root":
                    return context.workspaceRootPath != nil
                default:
                    return true
                }
            }
        }
    }
}

package struct AskNoopMemoryFabric: AskMemoryFabricProviding {
    package init() {}

    package func sessionSummary(sessionID: String?) async -> String? { nil }
    package func workspaceSummary(rootPath: String?) async -> String? { nil }
}
