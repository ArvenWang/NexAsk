import AppKit
import Foundation
import NexShared

#if !NEXHUB_PRODUCT_NEXHUB

final class AskAutomationRunner: @unchecked Sendable {
    static let shared = AskAutomationRunner()

    private final class RunObservationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var toolSteps: [String] = []
        private var failureCount = 0

        func record(step: AskRuntimeStepEvent) {
            lock.lock()
            defer { lock.unlock() }
            toolSteps.append(step.title + (step.detail.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""))
            if step.state == .failed {
                failureCount += 1
            }
        }

        func snapshot() -> (toolSteps: [String], failureCount: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (toolSteps, failureCount)
        }
    }

    private let askSessionService: AskSessionService
    private let agentKernel: AskAgentKernel
    private let askSessionKernelBridge: AskSessionKernelBridge
    private let automationStore: AskAutomationStore
    private let diagnosticsLogger: DiagnosticsLogger

    init(
        askSessionService: AskSessionService = AskSessionService(),
        agentKernel: AskAgentKernel = .shared,
        askSessionKernelBridge: AskSessionKernelBridge? = nil,
        automationStore: AskAutomationStore = .shared,
        diagnosticsLogger: DiagnosticsLogger = .shared
    ) {
        self.askSessionService = askSessionService
        self.agentKernel = agentKernel
        self.askSessionKernelBridge = askSessionKernelBridge ?? AskSessionKernelBridge(kernel: agentKernel)
        self.automationStore = automationStore
        self.diagnosticsLogger = diagnosticsLogger
    }

    func run(job: AskAutomationJob) async -> AskAutomationRunRecord {
        let runID = UUID().uuidString.lowercased()
        let startedAt = Date()
        let sessionID = "automation-\(runID)"
        let running = AskAutomationRunRecord(
            id: runID,
            jobID: job.id,
            runID: runID,
            startedAt: startedAt,
            finishedAt: nil,
            status: .running,
            summary: L10n.text(zhHans: "任务开始执行。", en: "Automation started running."),
            toolSteps: [],
            artifacts: [],
            error: nil,
            inboxItemID: nil,
            sessionID: sessionID,
            kernelInvocationID: nil,
            kernelTaskID: nil,
            kernelMode: nil,
            kernelProfileID: nil,
            workspaceRoot: nil,
            pendingApprovalActionID: nil,
            agentState: "running"
        )
        automationStore.recordRun(running)

        let baseRequest = AskSessionRequest(
            messages: [
                AskMessage(role: .user, content: job.normalizedTaskPrompt)
            ],
            metadata: AskSessionMetadata(
                sessionID: sessionID,
                sourceBundleID: nil,
                sourceAppName: nil,
                frame: NSRect(x: 0, y: 0, width: 760, height: 540),
                sessionOrigin: .automation,
                automationJobID: job.id,
                automationPolicy: job.toolPolicy,
                invocationSurface: .automation,
                requestedMode: .automate,
                kernelMetadata: job.workspaceRoot.map { ["workspace_root": $0] } ?? [:]
            ),
            uiLanguage: AppSettings.shared.appLanguage.languageCode,
            responseLanguage: AppSettings.shared.appLanguage.languageCode
        )
        let prepared = await askSessionKernelBridge.prepare(request: baseRequest)
        let preparedKernel = kernelRunMetadata(from: prepared)

        let observation = RunObservationBox()
        let result: Result<AskSessionResponse, Error> = await withCheckedContinuation { continuation in
            _ = askSessionService.streamReply(
                request: prepared.request,
                onEvent: { event in
                    if case .runtimeStep(let step) = event {
                        observation.record(step: step)
                    }
                },
                onComplete: { completion in
                    continuation.resume(returning: completion)
                }
            )
        }

        let finishedAt = Date()
        let snapshot = observation.snapshot()
        switch result {
        case .success(let response):
            let baseStatus: AskAutomationRunStatus
            if !(response.metadata["pending_approval_action_id"] ?? "").isEmpty {
                baseStatus = .blocked
            } else if snapshot.failureCount > 0 {
                baseStatus = .partial
            } else {
                baseStatus = .completed
            }

            let preparedBrief = await prepareAssistantBriefViaKernel(
                title: job.title,
                summary: response.message,
                body: response.message,
                kind: baseStatus == .completed ? "automation_result" : "automation_attention",
                sessionID: sessionID,
                runID: runID,
                sourceTaskID: preparedKernel.kernelTaskID,
                job: job
            )

            let inboxDelivery = job.delivery.deliverToInbox
                ? await deliverInboxItemViaKernel(
                    briefMetadata: preparedBrief?.metadata,
                    actions: inboxActions(from: response),
                    sessionID: sessionID,
                    runID: runID,
                    job: job
                )
                : nil
            let notificationDelivery = job.delivery.deliverSystemNotification
                ? await deliverNotificationViaKernel(
                    briefMetadata: preparedBrief?.metadata,
                    sessionID: sessionID,
                    job: job
                )
                : nil
            let status: AskAutomationRunStatus
            let deliveryFailures = [inboxDelivery, notificationDelivery]
                .compactMap { $0 }
                .filter { $0.status != .succeeded }
                .count
            if baseStatus == .blocked {
                status = .blocked
            } else if baseStatus == .partial || deliveryFailures > 0 {
                status = .partial
            } else {
                status = .completed
            }

            let artifacts = automationArtifacts(from: response.cards)
            let runArtifacts = artifacts
                + deliveryArtifacts(channel: .inbox, from: inboxDelivery)
                + deliveryArtifacts(channel: .notification, from: notificationDelivery)

            let finalRun = AskAutomationRunRecord(
                id: runID,
                jobID: job.id,
                runID: runID,
                startedAt: startedAt,
                finishedAt: finishedAt,
                status: status,
                summary: response.message,
                toolSteps: snapshot.toolSteps,
                artifacts: runArtifacts,
                error: nil,
                inboxItemID: inboxDelivery?.metadata["saved_inbox_item_id"],
                sessionID: sessionID,
                kernelInvocationID: preparedKernel.kernelInvocationID,
                kernelTaskID: preparedKernel.kernelTaskID,
                kernelMode: response.metadata["kernel_mode"] ?? preparedKernel.kernelMode,
                kernelProfileID: response.metadata["kernel_profile_id"] ?? preparedKernel.kernelProfileID,
                workspaceRoot: response.metadata["workspace_root"] ?? preparedKernel.workspaceRoot,
                pendingApprovalActionID: response.metadata["pending_approval_action_id"],
                agentState: response.metadata["agent_state"]
            )
            automationStore.recordRun(finalRun)
            _ = automationStore.updateJobAfterRun(jobID: job.id, status: status, finishedAt: finishedAt, now: finishedAt)
            diagnosticsLogger.log(
                "ask.automation",
                "job=\(job.id) run=\(runID) status=\(status.rawValue) chars=\(response.message.count) steps=\(snapshot.toolSteps.count)"
            )
            return finalRun

        case .failure(let error):
            let summary = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let failureSummary = summary.isEmpty ? L10n.text(zhHans: "任务执行失败。", en: "Automation failed.") : summary
            let preparedBrief = await prepareAssistantBriefViaKernel(
                title: job.title,
                summary: failureSummary,
                body: failureSummary,
                kind: "automation_error",
                sessionID: sessionID,
                runID: runID,
                sourceTaskID: preparedKernel.kernelTaskID,
                job: job
            )
            let inboxDelivery = job.delivery.deliverToInbox
                ? await deliverInboxItemViaKernel(
                    briefMetadata: preparedBrief?.metadata,
                    actions: [],
                    sessionID: sessionID,
                    runID: runID,
                    job: job
                )
                : nil
            let notificationDelivery = job.delivery.deliverSystemNotification
                ? await deliverNotificationViaKernel(
                    briefMetadata: preparedBrief?.metadata,
                    sessionID: sessionID,
                    job: job
                )
                : nil

            let failedRun = AskAutomationRunRecord(
                id: runID,
                jobID: job.id,
                runID: runID,
                startedAt: startedAt,
                finishedAt: finishedAt,
                status: .failed,
                summary: failureSummary,
                toolSteps: snapshot.toolSteps,
                artifacts: deliveryArtifacts(channel: .inbox, from: inboxDelivery)
                    + deliveryArtifacts(channel: .notification, from: notificationDelivery),
                error: failureSummary,
                inboxItemID: inboxDelivery?.metadata["saved_inbox_item_id"],
                sessionID: sessionID,
                kernelInvocationID: preparedKernel.kernelInvocationID,
                kernelTaskID: preparedKernel.kernelTaskID,
                kernelMode: preparedKernel.kernelMode,
                kernelProfileID: preparedKernel.kernelProfileID,
                workspaceRoot: preparedKernel.workspaceRoot,
                pendingApprovalActionID: nil,
                agentState: "failed"
            )
            automationStore.recordRun(failedRun)
            _ = automationStore.updateJobAfterRun(jobID: job.id, status: .failed, finishedAt: finishedAt, now: finishedAt)
            diagnosticsLogger.log(
                "ask.automation",
                "job=\(job.id) run=\(runID) status=failed error=\(failureSummary)"
            )
            return failedRun
        }
    }

    private func kernelRunMetadata(from preparation: AskSessionKernelPreparation) -> (
        kernelInvocationID: String?,
        kernelTaskID: String?,
        kernelMode: String?,
        kernelProfileID: String?,
        workspaceRoot: String?
    ) {
        let metadata = preparation.request.metadata.kernelMetadata
        return (
            kernelInvocationID: metadata["kernel_invocation_id"],
            kernelTaskID: metadata["kernel_task_id"],
            kernelMode: metadata["kernel_mode"],
            kernelProfileID: metadata["kernel_profile_id"],
            workspaceRoot: metadata["workspace_root"]
        )
    }

    private func automationArtifacts(from cards: [SkillResultCard]) -> [AskAutomationArtifact] {
        cards.prefix(4).map { card in
            AskAutomationArtifact(
                kind: card.kind,
                title: card.title,
                value: card.action?.value ?? card.subtitle ?? card.description ?? ""
            )
        }
    }

    private func inboxActions(from response: AskSessionResponse) -> [AskInboxAction] {
        response.cards.prefix(3).compactMap { card in
            guard let action = card.action,
                  let value = action.value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return AskInboxAction(label: action.label, value: value)
        }
    }

    private func deliverNotificationViaKernel(
        briefMetadata: [String: String]?,
        sessionID: String,
        job: AskAutomationJob
    ) async -> AskCapabilityExecutionResult? {
        let title = briefMetadata?["assistant_brief_title"] ?? job.title
        let body = briefMetadata?["assistant_brief_body"] ?? briefMetadata?["assistant_brief_summary"] ?? job.naturalLanguageSpec
        let preparedTask = await agentKernel.prepareTask(
            prompt: body,
            surface: .automation,
            requestedMode: .automate,
            sessionID: sessionID,
            sourceBundleID: nil,
            sourceAppName: nil,
            metadata: compactKernelMetadata([
                "automation_job_id": job.id,
                "workspace_root": job.workspaceRoot,
                "delivery_channel": "system_notification"
            ])
        )
        return await agentKernel.makeExecutionCoordinator().execute(
            preparedTask: preparedTask,
            capabilityID: "system.deliver_notification",
            arguments: compactKernelMetadata(
                mergedKernelMetadata(
                    base: [
                        "title": title,
                        "body": body
                    ],
                    extras: briefMetadata
                )
            )
        )
    }

    private func deliverInboxItemViaKernel(
        briefMetadata: [String: String]?,
        actions: [AskInboxAction],
        sessionID: String,
        runID: String,
        job: AskAutomationJob
    ) async -> AskCapabilityExecutionResult? {
        let title = briefMetadata?["assistant_brief_title"] ?? job.title
        let summary = briefMetadata?["assistant_brief_summary"] ?? job.naturalLanguageSpec
        let kind = briefMetadata?["assistant_brief_kind"] ?? "automation_result"
        let preparedTask = await agentKernel.prepareTask(
            prompt: summary,
            surface: .automation,
            requestedMode: .automate,
            sessionID: sessionID,
            sourceBundleID: nil,
            sourceAppName: nil,
            metadata: compactKernelMetadata([
                "automation_job_id": job.id,
                "workspace_root": job.workspaceRoot,
                "delivery_channel": "ask_inbox"
            ])
        )

        return await agentKernel.makeExecutionCoordinator().execute(
            preparedTask: preparedTask,
            capabilityID: "system.deliver_inbox_item",
            arguments: compactKernelMetadata(
                mergedKernelMetadata(
                    base: [
                        "title": title,
                        "summary": summary,
                        "kind": kind,
                        "source_job_id": job.id,
                        "source_run_id": runID,
                        "actions_json": encodedInboxActions(actions)
                    ],
                    extras: briefMetadata
                )
            )
        )
    }

    private func prepareAssistantBriefViaKernel(
        title: String,
        summary: String,
        body: String,
        kind: String,
        sessionID: String,
        runID: String,
        sourceTaskID: String?,
        job: AskAutomationJob
    ) async -> AskCapabilityExecutionResult? {
        let preparedTask = await agentKernel.prepareTask(
            prompt: summary,
            surface: .automation,
            requestedMode: .automate,
            sessionID: sessionID,
            sourceBundleID: nil,
            sourceAppName: nil,
            metadata: compactKernelMetadata([
                "automation_job_id": job.id,
                "workspace_root": job.workspaceRoot,
                "delivery_channel": AskAssistantDeliveryChannel.brief.rawValue
            ])
        )

        return await agentKernel.makeExecutionCoordinator().execute(
            preparedTask: preparedTask,
            capabilityID: "system.prepare_assistant_brief",
            arguments: compactKernelMetadata([
                "title": title,
                "summary": summary,
                "body": body,
                "kind": kind,
                "source_job_id": job.id,
                "source_run_id": runID,
                "source_task_id": sourceTaskID
            ])
        )
    }

    private enum DeliveryChannel {
        case inbox
        case notification
    }

    private func deliveryArtifacts(
        channel: DeliveryChannel,
        from result: AskCapabilityExecutionResult?
    ) -> [AskAutomationArtifact] {
        guard let result else { return [] }
        let title: String
        switch (channel, result.status == .succeeded) {
        case (.inbox, true):
            title = L10n.text(zhHans: "Inbox 已回投", en: "Inbox delivery completed")
        case (.inbox, false):
            title = L10n.text(zhHans: "Inbox 回投失败", en: "Inbox delivery failed")
        case (.notification, true):
            title = L10n.text(zhHans: "系统通知已发送", en: "System notification delivered")
        case (.notification, false):
            title = L10n.text(zhHans: "系统通知未发送", en: "System notification not delivered")
        }
        return [
            AskAutomationArtifact(
                kind: channel == .inbox ? "inbox_delivery" : "notification_delivery",
                title: title,
                value: result.summary
            )
        ]
    }

    private func encodedInboxActions(_ actions: [AskInboxAction]) -> String? {
        guard !actions.isEmpty,
              let data = try? JSONEncoder().encode(actions),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func compactKernelMetadata(_ pairs: [String: String?]) -> [String: String] {
        var metadata: [String: String] = [:]
        for (key, value) in pairs {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            metadata[key] = value
        }
        return metadata
    }

    private func mergedKernelMetadata(
        base: [String: String?],
        extras: [String: String]?
    ) -> [String: String?] {
        var merged = base
        for (key, value) in extras ?? [:] where merged[key] == nil {
            merged[key] = value
        }
        return merged
    }
}

#endif
