import Foundation

package enum AskAutomationNotificationNames {
    package static let jobsDidChange = Notification.Name("nexhub.askAutomation.jobsDidChange")
    package static let runsDidChange = Notification.Name("nexhub.askAutomation.runsDidChange")
    package static let inboxDidChange = Notification.Name("nexhub.askAutomation.inboxDidChange")
}

package enum AskSessionOrigin: String, Codable, Equatable {
    case user
    case automation
    case assistantFollowUp = "assistant_followup"
}

package enum AskAutomationRiskLevel: String, Codable, CaseIterable, Equatable {
    case safeRead = "safe_read"
    case safeOpen = "safe_open"
    case safeCreate = "safe_create"
}

package struct AskAutomationPolicy: Codable, Equatable {
    package let allowedRiskLevels: [AskAutomationRiskLevel]
    package let allowVisibleOpenActions: Bool
    package let allowCalendarCreate: Bool
    package let allowKnowledgeWrites: Bool
    package let allowClipboardWrite: Bool
    package let requireForegroundForWriteback: Bool

    package init(
        allowedRiskLevels: [AskAutomationRiskLevel],
        allowVisibleOpenActions: Bool,
        allowCalendarCreate: Bool,
        allowKnowledgeWrites: Bool,
        allowClipboardWrite: Bool,
        requireForegroundForWriteback: Bool
    ) {
        self.allowedRiskLevels = allowedRiskLevels
        self.allowVisibleOpenActions = allowVisibleOpenActions
        self.allowCalendarCreate = allowCalendarCreate
        self.allowKnowledgeWrites = allowKnowledgeWrites
        self.allowClipboardWrite = allowClipboardWrite
        self.requireForegroundForWriteback = requireForegroundForWriteback
    }

    package static let `default` = AskAutomationPolicy(
        allowedRiskLevels: AskAutomationRiskLevel.allCases,
        allowVisibleOpenActions: true,
        allowCalendarCreate: true,
        allowKnowledgeWrites: true,
        allowClipboardWrite: true,
        requireForegroundForWriteback: true
    )

    package func blockedReason(forToolNamed toolName: String) -> String? {
        switch toolName {
        case "stage_move_paths", "move_paths", "commit_staged_operation", "create_folder", "run_shell_command", "apply_workspace_patch":
            return AskRuntimeLocalization.text(
                zhHans: "这个定时任务不会自动执行高风险文件改动。",
                en: "This automation does not execute high-risk file mutations automatically."
            )
        case "workspace.commit_changes":
            return AskRuntimeLocalization.text(
                zhHans: "这个定时任务不会自动把 patch 写入工作区。",
                en: "This automation does not automatically write approved patches into the workspace."
            )
        case "write_back_to_frontmost_input", "replace_frontmost_selection":
            if requireForegroundForWriteback {
                return AskRuntimeLocalization.text(
                    zhHans: "这个定时任务不会在后台写回前台输入框或替换选区。",
                    en: "This automation does not write back into the foreground input or replace a selection in the background."
                )
            }
            return nil
        case "copy_to_clipboard":
            return allowClipboardWrite ? nil : AskRuntimeLocalization.text(
                zhHans: "这个定时任务当前不允许改写剪贴板。",
                en: "This automation is not allowed to modify the clipboard right now."
            )
        case "open_url", "open_path", "reveal_path", "reveal_in_finder":
            return allowVisibleOpenActions ? nil : AskRuntimeLocalization.text(
                zhHans: "这个定时任务当前不允许主动打开可见窗口或页面。",
                en: "This automation is not allowed to open visible windows or pages right now."
            )
        case "create_calendar_event", "create_reminder":
            return allowCalendarCreate ? nil : AskRuntimeLocalization.text(
                zhHans: "这个定时任务当前不允许创建日历或提醒事项。",
                en: "This automation is not allowed to create calendar or reminder items right now."
            )
        case "delete_reminder", "delete_calendar_item":
            return AskRuntimeLocalization.text(
                zhHans: "这个定时任务不会自动删除日历或提醒事项。",
                en: "This automation does not automatically delete calendar or reminder items."
            )
        case "collect_url", "collect_current_page", "collect_current_page_to_knowledge", "collect_paths", "save_answer_to_knowledge_note":
            return allowKnowledgeWrites ? nil : AskRuntimeLocalization.text(
                zhHans: "这个定时任务当前不允许写入知识库。",
                en: "This automation is not allowed to write into the knowledge base right now."
            )
        default:
            return nil
        }
    }
}

package struct AskAutomationDelivery: Codable, Equatable {
    package let deliverToInbox: Bool
    package let deliverSystemNotification: Bool

    package init(deliverToInbox: Bool, deliverSystemNotification: Bool) {
        self.deliverToInbox = deliverToInbox
        self.deliverSystemNotification = deliverSystemNotification
    }

    package static let `default` = AskAutomationDelivery(
        deliverToInbox: true,
        deliverSystemNotification: true
    )
}

package enum AskAutomationTriggerKind: String, Codable, Equatable {
    case onceAt = "once_at"
    case dailyAt = "daily_at"
    case weekly
    case monthlyDay = "monthly_day"
    case everyNHours = "every_n_hours"
}

package struct AskAutomationTrigger: Codable, Equatable {
    package let kind: AskAutomationTriggerKind
    package let absoluteDate: Date?
    package let hour: Int?
    package let minute: Int?
    package let weekday: Int?
    package let day: Int?
    package let intervalHours: Int?

    package init(
        kind: AskAutomationTriggerKind,
        absoluteDate: Date? = nil,
        hour: Int? = nil,
        minute: Int? = nil,
        weekday: Int? = nil,
        day: Int? = nil,
        intervalHours: Int? = nil
    ) {
        self.kind = kind
        self.absoluteDate = absoluteDate
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.day = day
        self.intervalHours = intervalHours
    }

    package func nextRun(after now: Date, lastRunAt: Date?, createdAt: Date, calendar baseCalendar: Calendar = .current) -> Date? {
        var calendar = baseCalendar
        calendar.timeZone = .current

        switch kind {
        case .onceAt:
            guard let absoluteDate else { return nil }
            return lastRunAt == nil ? absoluteDate : nil

        case .dailyAt:
            guard let hour else { return nil }
            let minute = self.minute ?? 0
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = minute
            components.second = 0
            guard var candidate = calendar.date(from: components) else { return nil }
            if candidate <= now {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate.addingTimeInterval(86_400)
            }
            return candidate

        case .weekly:
            guard let weekday, let hour else { return nil }
            let minute = self.minute ?? 0
            let components = DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday)
            return calendar.nextDate(
                after: now.addingTimeInterval(1),
                matching: components,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )

        case .monthlyDay:
            guard let day, let hour else { return nil }
            let minute = self.minute ?? 0
            var cursor = now
            for _ in 0..<24 {
                let monthComponents = calendar.dateComponents([.year, .month], from: cursor)
                guard let monthStart = calendar.date(from: monthComponents),
                      let validRange = calendar.range(of: .day, in: .month, for: monthStart) else {
                    return nil
                }
                let clampedDay = min(max(day, validRange.lowerBound), validRange.upperBound - 1)
                var candidateComponents = monthComponents
                candidateComponents.day = clampedDay
                candidateComponents.hour = hour
                candidateComponents.minute = minute
                candidateComponents.second = 0
                if let candidate = calendar.date(from: candidateComponents), candidate > now {
                    return candidate
                }
                cursor = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? cursor.addingTimeInterval(31 * 86_400)
            }
            return nil

        case .everyNHours:
            guard let intervalHours, intervalHours > 0 else { return nil }
            let interval = TimeInterval(intervalHours * 3600)
            let anchor = lastRunAt ?? createdAt
            guard interval > 0 else { return nil }
            if anchor > now {
                return anchor
            }
            let elapsed = now.timeIntervalSince(anchor)
            let steps = Int(floor(elapsed / interval)) + 1
            return anchor.addingTimeInterval(Double(steps) * interval)
        }
    }

    package var scheduleSummary: String {
        switch kind {
        case .onceAt:
            guard let absoluteDate else {
                return AskRuntimeLocalization.text(zhHans: "执行一次", en: "Run once")
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: AskRuntimeLocalization.currentLocaleIdentifier)
            formatter.timeZone = .current
            formatter.setLocalizedDateFormatFromTemplate("M d HH:mm")
            return formatter.string(from: absoluteDate)
        case .dailyAt:
            return AskRuntimeLocalization.format(
                zhHans: "每天 %02d:%02d",
                en: "Every day at %02d:%02d",
                hour ?? 0,
                minute ?? 0
            )
        case .weekly:
            return AskRuntimeLocalization.format(
                zhHans: "每周%@ %02d:%02d",
                en: "Every %@ at %02d:%02d",
                weekdayLabel(weekday),
                hour ?? 0,
                minute ?? 0
            )
        case .monthlyDay:
            return AskRuntimeLocalization.format(
                zhHans: "每月 %d 号 %02d:%02d",
                en: "Every month on day %d at %02d:%02d",
                day ?? 1,
                hour ?? 0,
                minute ?? 0
            )
        case .everyNHours:
            return AskRuntimeLocalization.format(
                zhHans: "每隔 %d 小时",
                en: "Every %d hour(s)",
                intervalHours ?? 1
            )
        }
    }

    private func weekdayLabel(_ value: Int?) -> String {
        switch value {
        case 1: return AskRuntimeLocalization.text(zhHans: "周日", en: "Sunday")
        case 2: return AskRuntimeLocalization.text(zhHans: "周一", en: "Monday")
        case 3: return AskRuntimeLocalization.text(zhHans: "周二", en: "Tuesday")
        case 4: return AskRuntimeLocalization.text(zhHans: "周三", en: "Wednesday")
        case 5: return AskRuntimeLocalization.text(zhHans: "周四", en: "Thursday")
        case 6: return AskRuntimeLocalization.text(zhHans: "周五", en: "Friday")
        case 7: return AskRuntimeLocalization.text(zhHans: "周六", en: "Saturday")
        default:
            return AskRuntimeLocalization.text(zhHans: "每周", en: "week")
        }
    }
}

package struct AskAutomationDraft: Codable, Equatable, Identifiable {
    package let id: String
    package let title: String
    package let naturalLanguageSpec: String
    package let normalizedTaskPrompt: String
    package let workspaceRoot: String?
    package let trigger: AskAutomationTrigger
    package let toolPolicy: AskAutomationPolicy
    package let delivery: AskAutomationDelivery
    package let keyToolDomains: [String]
    package let riskSummary: String
    package let allowLightWrites: Bool
    package let createdAt: Date

    package init(
        id: String,
        title: String,
        naturalLanguageSpec: String,
        normalizedTaskPrompt: String,
        workspaceRoot: String?,
        trigger: AskAutomationTrigger,
        toolPolicy: AskAutomationPolicy,
        delivery: AskAutomationDelivery,
        keyToolDomains: [String],
        riskSummary: String,
        allowLightWrites: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.naturalLanguageSpec = naturalLanguageSpec
        self.normalizedTaskPrompt = normalizedTaskPrompt
        self.workspaceRoot = workspaceRoot
        self.trigger = trigger
        self.toolPolicy = toolPolicy
        self.delivery = delivery
        self.keyToolDomains = keyToolDomains
        self.riskSummary = riskSummary
        self.allowLightWrites = allowLightWrites
        self.createdAt = createdAt
    }
}

package enum AskAutomationRunStatus: String, Codable, Equatable {
    case running
    case completed
    case partial
    case blocked
    case failed
    case skipped
}

package struct AskAutomationArtifact: Codable, Equatable {
    package let kind: String
    package let title: String
    package let value: String

    package init(kind: String, title: String, value: String) {
        self.kind = kind
        self.title = title
        self.value = value
    }
}

package struct AskAutomationJob: Codable, Equatable, Identifiable {
    package let id: String
    package var title: String
    package var naturalLanguageSpec: String
    package var normalizedTaskPrompt: String
    package var workspaceRoot: String?
    package var trigger: AskAutomationTrigger
    package var toolPolicy: AskAutomationPolicy
    package var delivery: AskAutomationDelivery
    package var enabled: Bool
    package let createdAt: Date
    package var updatedAt: Date
    package var lastRunAt: Date?
    package var nextRunAt: Date?
    package var lastRunStatus: AskAutomationRunStatus?
    package var keyToolDomains: [String]
    package var riskSummary: String
    package var responseProfileRawValue: String?

    package init(
        id: String,
        title: String,
        naturalLanguageSpec: String,
        normalizedTaskPrompt: String,
        workspaceRoot: String?,
        trigger: AskAutomationTrigger,
        toolPolicy: AskAutomationPolicy,
        delivery: AskAutomationDelivery,
        enabled: Bool,
        createdAt: Date,
        updatedAt: Date,
        lastRunAt: Date?,
        nextRunAt: Date?,
        lastRunStatus: AskAutomationRunStatus?,
        keyToolDomains: [String],
        riskSummary: String,
        responseProfileRawValue: String?
    ) {
        self.id = id
        self.title = title
        self.naturalLanguageSpec = naturalLanguageSpec
        self.normalizedTaskPrompt = normalizedTaskPrompt
        self.workspaceRoot = workspaceRoot
        self.trigger = trigger
        self.toolPolicy = toolPolicy
        self.delivery = delivery
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.lastRunStatus = lastRunStatus
        self.keyToolDomains = keyToolDomains
        self.riskSummary = riskSummary
        self.responseProfileRawValue = responseProfileRawValue
    }

    package mutating func refreshNextRun(after now: Date = Date()) {
        nextRunAt = enabled ? trigger.nextRun(after: now, lastRunAt: lastRunAt, createdAt: createdAt) : nil
    }
}

package struct AskAutomationRunRecord: Codable, Equatable, Identifiable {
    package let id: String
    package let jobID: String
    package let runID: String
    package let startedAt: Date
    package let finishedAt: Date?
    package let status: AskAutomationRunStatus
    package let summary: String
    package let toolSteps: [String]
    package let artifacts: [AskAutomationArtifact]
    package let error: String?
    package let inboxItemID: String?
    package let sessionID: String?
    package let kernelInvocationID: String?
    package let kernelTaskID: String?
    package let kernelMode: String?
    package let kernelProfileID: String?
    package let workspaceRoot: String?
    package let pendingApprovalActionID: String?
    package let agentState: String?

    package init(
        id: String,
        jobID: String,
        runID: String,
        startedAt: Date,
        finishedAt: Date?,
        status: AskAutomationRunStatus,
        summary: String,
        toolSteps: [String],
        artifacts: [AskAutomationArtifact],
        error: String?,
        inboxItemID: String?,
        sessionID: String?,
        kernelInvocationID: String?,
        kernelTaskID: String?,
        kernelMode: String?,
        kernelProfileID: String?,
        workspaceRoot: String?,
        pendingApprovalActionID: String?,
        agentState: String?
    ) {
        self.id = id
        self.jobID = jobID
        self.runID = runID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.summary = summary
        self.toolSteps = toolSteps
        self.artifacts = artifacts
        self.error = error
        self.inboxItemID = inboxItemID
        self.sessionID = sessionID
        self.kernelInvocationID = kernelInvocationID
        self.kernelTaskID = kernelTaskID
        self.kernelMode = kernelMode
        self.kernelProfileID = kernelProfileID
        self.workspaceRoot = workspaceRoot
        self.pendingApprovalActionID = pendingApprovalActionID
        self.agentState = agentState
    }
}

package struct AskInboxAction: Codable, Equatable {
    package let label: String
    package let value: String

    package init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

package struct AskInboxItem: Codable, Equatable, Identifiable {
    package let id: String
    package let kind: String
    package let title: String
    package let summary: String
    package let createdAt: Date
    package let sourceJobID: String?
    package let sourceRunID: String?
    package let sourceTaskID: String?
    package let sourceTaskStatus: String?
    package let assistantDeliveryChannel: String?
    package let activeTaskID: String?
    package let activeTaskResumeToken: String?
    package let workspaceRoot: String?
    package let actions: [AskInboxAction]
    package var isRead: Bool

    package init(
        id: String,
        kind: String,
        title: String,
        summary: String,
        createdAt: Date,
        sourceJobID: String?,
        sourceRunID: String?,
        sourceTaskID: String?,
        sourceTaskStatus: String?,
        assistantDeliveryChannel: String?,
        activeTaskID: String?,
        activeTaskResumeToken: String?,
        workspaceRoot: String?,
        actions: [AskInboxAction],
        isRead: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        self.sourceJobID = sourceJobID
        self.sourceRunID = sourceRunID
        self.sourceTaskID = sourceTaskID
        self.sourceTaskStatus = sourceTaskStatus
        self.assistantDeliveryChannel = assistantDeliveryChannel
        self.activeTaskID = activeTaskID
        self.activeTaskResumeToken = activeTaskResumeToken
        self.workspaceRoot = workspaceRoot
        self.actions = actions
        self.isRead = isRead
    }
}

package extension AskAutomationJob {
    static func make(from draft: AskAutomationDraft, now: Date = Date()) -> AskAutomationJob {
        var job = AskAutomationJob(
            id: UUID().uuidString.lowercased(),
            title: draft.title,
            naturalLanguageSpec: draft.naturalLanguageSpec,
            normalizedTaskPrompt: draft.normalizedTaskPrompt,
            workspaceRoot: draft.workspaceRoot,
            trigger: draft.trigger,
            toolPolicy: draft.toolPolicy,
            delivery: draft.delivery,
            enabled: true,
            createdAt: now,
            updatedAt: now,
            lastRunAt: nil,
            nextRunAt: nil,
            lastRunStatus: nil,
            keyToolDomains: draft.keyToolDomains,
            riskSummary: draft.riskSummary,
            responseProfileRawValue: "balanced"
        )
        job.refreshNextRun(after: now)
        return job
    }
}
