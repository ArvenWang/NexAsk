import Foundation

package struct AskCapabilityExecutionRequest: Codable, Equatable, Sendable {
    package let task: AskAgentTask
    package let capability: AskCapabilityDefinition
    package let decision: AskPolicyDecision
    package let arguments: AskInvocationMetadata
    package let dryRun: Bool
    package let requestedAt: Date

    package init(
        task: AskAgentTask,
        capability: AskCapabilityDefinition,
        decision: AskPolicyDecision,
        arguments: AskInvocationMetadata,
        dryRun: Bool,
        requestedAt: Date
    ) {
        self.task = task
        self.capability = capability
        self.decision = decision
        self.arguments = arguments
        self.dryRun = dryRun
        self.requestedAt = requestedAt
    }
}

package enum AskCapabilityExecutionStatus: String, Codable, Sendable {
    case succeeded
    case waitingApproval
    case denied
    case failed
    case unsupported
}

package struct AskCapabilityArtifact: Codable, Equatable, Sendable {
    package let kind: String
    package let value: String

    package init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}

package struct AskCapabilityExecutionResult: Codable, Equatable, Sendable {
    package let status: AskCapabilityExecutionStatus
    package let summary: String
    package let approvalID: String?
    package let artifacts: [AskCapabilityArtifact]
    package let metadata: AskInvocationMetadata

    package init(
        status: AskCapabilityExecutionStatus,
        summary: String,
        approvalID: String?,
        artifacts: [AskCapabilityArtifact],
        metadata: AskInvocationMetadata
    ) {
        self.status = status
        self.summary = summary
        self.approvalID = approvalID
        self.artifacts = artifacts
        self.metadata = metadata
    }

    package static func denied(summary: String) -> AskCapabilityExecutionResult {
        AskCapabilityExecutionResult(
            status: .denied,
            summary: summary,
            approvalID: nil,
            artifacts: [],
            metadata: [:]
        )
    }

    package static func unsupported(summary: String) -> AskCapabilityExecutionResult {
        AskCapabilityExecutionResult(
            status: .unsupported,
            summary: summary,
            approvalID: nil,
            artifacts: [],
            metadata: [:]
        )
    }
}

package protocol AskCapabilityExecuting {
    var supportedCapabilityIDs: [AskCapabilityID] { get }
    func execute(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult
}

package protocol AskCapabilityExecutorRegistryProviding {
    func executor(for capabilityID: AskCapabilityID) -> (any AskCapabilityExecuting)?
}

package protocol AskApprovalRouting {
    func createApprovalRequest(for request: AskCapabilityExecutionRequest, reason: String) async -> AskCapabilityApprovalRecord
    func approvalRequest(id: String) async -> AskCapabilityApprovalRecord?
    func removeApprovalRequest(id: String) async -> AskCapabilityApprovalRecord?
}

package protocol AskResultDelivering {
    func deliver(
        result: AskCapabilityExecutionResult,
        for task: AskAgentTask,
        capabilityID: AskCapabilityID
    ) async
}

package struct AskStaticCapabilityExecutorRegistry: AskCapabilityExecutorRegistryProviding {
    private let executorsByCapabilityID: [AskCapabilityID: any AskCapabilityExecuting]

    package init(executors: [any AskCapabilityExecuting]) {
        var byID: [AskCapabilityID: any AskCapabilityExecuting] = [:]
        for executor in executors {
            for capabilityID in executor.supportedCapabilityIDs {
                byID[capabilityID] = executor
            }
        }
        self.executorsByCapabilityID = byID
    }

    package func executor(for capabilityID: AskCapabilityID) -> (any AskCapabilityExecuting)? {
        executorsByCapabilityID[capabilityID]
    }
}

package struct AskCapabilityApprovalRecord: Codable, Equatable, Sendable {
    package let approvalID: String
    package let request: AskCapabilityExecutionRequest
    package let reason: String
    package let createdAt: Date

    package init(
        approvalID: String,
        request: AskCapabilityExecutionRequest,
        reason: String,
        createdAt: Date
    ) {
        self.approvalID = approvalID
        self.request = request
        self.reason = reason
        self.createdAt = createdAt
    }
}

package struct AskNoopResultDelivery: AskResultDelivering {
    package init() {}

    package func deliver(
        result: AskCapabilityExecutionResult,
        for task: AskAgentTask,
        capabilityID: AskCapabilityID
    ) async {
        _ = result
        _ = task
        _ = capabilityID
    }
}

package struct AskNoopCapabilityExecutor: AskCapabilityExecuting {
    package let supportedCapabilityIDs: [AskCapabilityID]

    package init(supportedCapabilityIDs: [AskCapabilityID] = []) {
        self.supportedCapabilityIDs = supportedCapabilityIDs
    }

    package func execute(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        AskCapabilityExecutionResult(
            status: .failed,
            summary: "No concrete executor is wired for \(request.capability.id) yet.",
            approvalID: nil,
            artifacts: [],
            metadata: [:]
        )
    }
}
