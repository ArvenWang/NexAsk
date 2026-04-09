import Foundation
import NexShared

struct AskTimeExecutor: AskCapabilityExecuting {
    let supportedCapabilityIDs: [AskCapabilityID] = [
        "time.preview_automation_job",
        "time.create_automation_job"
    ]

    private let automationDraftParser: AskAutomationDraftParser
    private let automationStore: AskAutomationStore

    init(
        automationDraftParser: AskAutomationDraftParser = .shared,
        automationStore: AskAutomationStore = .shared
    ) {
        self.automationDraftParser = automationDraftParser
        self.automationStore = automationStore
    }

    func execute(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        switch request.capability.id {
        case "time.preview_automation_job":
            return previewAutomationJob(request: request)
        case "time.create_automation_job":
            return createAutomationJob(request: request)
        default:
            return .unsupported(summary: "Unsupported time capability: \(request.capability.id)")
        }
    }

    private func previewAutomationJob(request: AskCapabilityExecutionRequest) -> AskCapabilityExecutionResult {
        guard let spec = resolvedSpec(from: request.arguments) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No automation request was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        guard let draft = automationDraftParser.parse(
            spec,
            now: request.requestedAt,
            workspaceRoot: resolvedWorkspaceRoot(for: request)
        ) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "I could not turn that request into a stable automation draft yet.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        automationStore.saveDraft(draft)
        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Prepared a local automation draft.",
            approvalID: nil,
            artifacts: artifacts(for: draft),
            metadata: [
                "pending_automation_draft_id": draft.id,
                "automation_title": draft.title,
                "automation_schedule": draft.trigger.scheduleSummary,
                "automation_domains": draft.keyToolDomains.joined(separator: ","),
                "workspace_root": draft.workspaceRoot ?? ""
            ]
        )
    }

    private func createAutomationJob(request: AskCapabilityExecutionRequest) -> AskCapabilityExecutionResult {
        let draft: AskAutomationDraft?
        if let draftID = firstNonEmptyValue(in: request.arguments, keys: ["draft_id", "pending_automation_draft_id"]) {
            draft = automationStore.draft(id: draftID)
        } else if let spec = resolvedSpec(from: request.arguments) {
            draft = automationDraftParser.parse(
                spec,
                now: request.requestedAt,
                workspaceRoot: resolvedWorkspaceRoot(for: request)
            )
        } else {
            draft = nil
        }

        guard let draft else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No automation draft or request was available to save.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        if request.dryRun {
            automationStore.saveDraft(draft)
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared an automation draft without saving a job yet.",
                approvalID: nil,
                artifacts: artifacts(for: draft),
                metadata: [
                    "pending_automation_draft_id": draft.id,
                    "automation_title": draft.title,
                    "automation_schedule": draft.trigger.scheduleSummary,
                    "automation_domains": draft.keyToolDomains.joined(separator: ","),
                    "workspace_root": draft.workspaceRoot ?? ""
                ]
            )
        }

        let job = automationStore.createJob(from: draft, now: request.requestedAt)
        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: "Created the local automation job.",
            approvalID: nil,
            artifacts: artifacts(for: job),
            metadata: [
                "saved_automation_job_id": job.id,
                "automation_title": job.title,
                "automation_schedule": job.trigger.scheduleSummary,
                "automation_domains": job.keyToolDomains.joined(separator: ","),
                "workspace_root": job.workspaceRoot ?? ""
            ]
        )
    }

    private func artifacts(for draft: AskAutomationDraft) -> [AskCapabilityArtifact] {
        var artifacts: [AskCapabilityArtifact] = [
            AskCapabilityArtifact(kind: "automation_title", value: draft.title),
            AskCapabilityArtifact(kind: "automation_schedule", value: draft.trigger.scheduleSummary),
            AskCapabilityArtifact(kind: "automation_risk_summary", value: draft.riskSummary)
        ]
        artifacts.append(contentsOf: draft.keyToolDomains.map {
            AskCapabilityArtifact(kind: "automation_domain", value: $0)
        })
        if let workspaceRoot = draft.workspaceRoot, !workspaceRoot.isEmpty {
            artifacts.append(AskCapabilityArtifact(kind: "workspace_root", value: workspaceRoot))
        }
        return artifacts
    }

    private func artifacts(for job: AskAutomationJob) -> [AskCapabilityArtifact] {
        var artifacts: [AskCapabilityArtifact] = [
            AskCapabilityArtifact(kind: "automation_title", value: job.title),
            AskCapabilityArtifact(kind: "automation_schedule", value: job.trigger.scheduleSummary),
            AskCapabilityArtifact(kind: "automation_risk_summary", value: job.riskSummary)
        ]
        artifacts.append(contentsOf: job.keyToolDomains.map {
            AskCapabilityArtifact(kind: "automation_domain", value: $0)
        })
        if let workspaceRoot = job.workspaceRoot, !workspaceRoot.isEmpty {
            artifacts.append(AskCapabilityArtifact(kind: "workspace_root", value: workspaceRoot))
        }
        return artifacts
    }

    private func resolvedSpec(from arguments: AskInvocationMetadata) -> String? {
        firstNonEmptyValue(in: arguments, keys: ["spec", "text", "prompt", "request"])
    }

    private func resolvedWorkspaceRoot(for request: AskCapabilityExecutionRequest) -> String? {
        firstNonEmptyValue(in: request.arguments, keys: ["workspace_root", "root", "project_root"])
            ?? request.task.context.workspaceRootPath
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
}
