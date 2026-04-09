import Foundation

package typealias AskCapabilityID = String
package typealias AskInvocationMetadata = [String: String]

package enum AskInvocationSurface: String, Codable, CaseIterable, Sendable {
    case askBox
    case globalHotkey
    case askWindow
    case automation
    case inbox
    case menuBar
    case proactivePopup = "proactive_popup"
    case cli
    case ide
    case api
    case notification
    case remoteChannel
}

package enum AskExecutionMode: String, CaseIterable, Sendable {
    case interactive
    case automate
}

extension AskExecutionMode: Codable {
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case AskExecutionMode.interactive.rawValue,
             "assist",
             "operate",
             "code",
             "converse":
            self = .interactive
        case AskExecutionMode.automate.rawValue:
            self = .automate
        default:
            self = .interactive
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

package enum AskCapabilityDomain: String, Codable, CaseIterable, Sendable {
    case desktop
    case browser
    case appControl
    case workspace
    case knowledge
    case time
    case system
}

package enum AskRiskClass: String, Codable, CaseIterable, Comparable, Sendable {
    case observational
    case reversible
    case userVisible
    case privileged
    case destructive

    private var sortRank: Int {
        switch self {
        case .observational: return 0
        case .reversible: return 1
        case .userVisible: return 2
        case .privileged: return 3
        case .destructive: return 4
        }
    }

    package static func < (lhs: AskRiskClass, rhs: AskRiskClass) -> Bool {
        lhs.sortRank < rhs.sortRank
    }
}

package enum AskVisibilityClass: String, Codable, CaseIterable, Sendable {
    case silent
    case userVisible
    case foregroundWriteback
    case background
}

package enum AskTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case planning
    case waitingApproval
    case running
    case blocked
    case completed
    case failed
    case cancelled
}

package enum AskTaskChecklistStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case blocked

    package var marker: String {
        switch self {
        case .pending:
            return "[ ]"
        case .inProgress:
            return "[-]"
        case .completed:
            return "[x]"
        case .blocked:
            return "[!]"
        }
    }
}

package struct AskTaskChecklistItem: Codable, Equatable, Sendable {
    package let id: String
    package let title: String
    package let status: AskTaskChecklistStatus
    package let note: String?
    package let updatedAt: Date

    package init(
        id: String,
        title: String,
        status: AskTaskChecklistStatus,
        note: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.note = note
        self.updatedAt = updatedAt
    }
}

package struct AskAmbientContext: Codable, Equatable, Sendable {
    package let frontmostBundleID: String?
    package let currentPageURL: String?
    package let currentPageTitle: String?
    package let currentPageTextPreview: String?
    package let selectedTextPreview: String?

    package init(
        frontmostBundleID: String?,
        currentPageURL: String?,
        currentPageTitle: String?,
        currentPageTextPreview: String?,
        selectedTextPreview: String?
    ) {
        self.frontmostBundleID = frontmostBundleID
        self.currentPageURL = currentPageURL
        self.currentPageTitle = currentPageTitle
        self.currentPageTextPreview = currentPageTextPreview
        self.selectedTextPreview = selectedTextPreview
    }
}

package struct AskExecutionContext: Codable, Equatable, Sendable {
    package let surface: AskInvocationSurface
    package let sourceBundleID: String?
    package let sourceAppName: String?
    package let workspaceRootPath: String?
    package let ambientContext: AskAmbientContext
    package let timeZoneIdentifier: String
    package let isUserPresent: Bool
    package let metadata: AskInvocationMetadata

    package init(
        surface: AskInvocationSurface,
        sourceBundleID: String?,
        sourceAppName: String?,
        workspaceRootPath: String?,
        ambientContext: AskAmbientContext,
        timeZoneIdentifier: String,
        isUserPresent: Bool,
        metadata: AskInvocationMetadata
    ) {
        self.surface = surface
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.workspaceRootPath = workspaceRootPath
        self.ambientContext = ambientContext
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isUserPresent = isUserPresent
        self.metadata = metadata
    }

    package var frontmostBundleID: String? { ambientContext.frontmostBundleID }
    package var currentPageURL: String? { ambientContext.currentPageURL }
    package var currentPageTitle: String? { ambientContext.currentPageTitle }
    package var currentPageTextPreview: String? { ambientContext.currentPageTextPreview }
    package var selectedTextPreview: String? { ambientContext.selectedTextPreview }

    package static func empty(
        surface: AskInvocationSurface,
        sourceBundleID: String?,
        sourceAppName: String?,
        metadata: AskInvocationMetadata = [:]
    ) -> AskExecutionContext {
        let workspaceRoot =
            AskWorkspaceRootSupport.normalizedWorkspaceRoot(metadata["interactive_task_scope_root"])
            ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(metadata["active_task_workspace_root"])
            ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(metadata["workspace_root"])
        return AskExecutionContext(
            surface: surface,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            workspaceRootPath: workspaceRoot,
            ambientContext: AskAmbientContext(
                frontmostBundleID: sourceBundleID,
                currentPageURL: metadata["current_page_url"],
                currentPageTitle: metadata["current_page_title"],
                currentPageTextPreview: metadata["current_page_text_preview"],
                selectedTextPreview: metadata["selection_preview"]
            ),
            timeZoneIdentifier: TimeZone.current.identifier,
            isUserPresent: true,
            metadata: metadata
        )
    }
}

package struct AskInvocation: Codable, Equatable, Sendable {
    package let id: String
    package let sessionID: String?
    package let parentTaskID: String?
    package let prompt: String
    package let surface: AskInvocationSurface
    package let requestedMode: AskExecutionMode?
    package let sourceBundleID: String?
    package let sourceAppName: String?
    package let createdAt: Date
    package let metadata: AskInvocationMetadata

    package init(
        id: String,
        sessionID: String?,
        parentTaskID: String?,
        prompt: String,
        surface: AskInvocationSurface,
        requestedMode: AskExecutionMode?,
        sourceBundleID: String?,
        sourceAppName: String?,
        createdAt: Date,
        metadata: AskInvocationMetadata
    ) {
        self.id = id
        self.sessionID = sessionID
        self.parentTaskID = parentTaskID
        self.prompt = prompt
        self.surface = surface
        self.requestedMode = requestedMode
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

package struct AskCapabilityDefinition: Codable, Equatable, Sendable {
    package let id: AskCapabilityID
    package let domain: AskCapabilityDomain
    package let summary: String
    package let riskClass: AskRiskClass
    package let visibilityClass: AskVisibilityClass
    package let supportsUnattendedExecution: Bool
    package let supportsPreview: Bool
    package let supportsRollback: Bool
    package let requiredContextKeys: [String]

    package init(
        id: AskCapabilityID,
        domain: AskCapabilityDomain,
        summary: String,
        riskClass: AskRiskClass,
        visibilityClass: AskVisibilityClass,
        supportsUnattendedExecution: Bool,
        supportsPreview: Bool,
        supportsRollback: Bool,
        requiredContextKeys: [String]
    ) {
        self.id = id
        self.domain = domain
        self.summary = summary
        self.riskClass = riskClass
        self.visibilityClass = visibilityClass
        self.supportsUnattendedExecution = supportsUnattendedExecution
        self.supportsPreview = supportsPreview
        self.supportsRollback = supportsRollback
        self.requiredContextKeys = requiredContextKeys
    }
}

package struct AskPolicyProfile: Codable, Equatable, Sendable {
    package let id: String
    package let summary: String
    package let allowedModes: [AskExecutionMode]
    package let allowedDomains: [AskCapabilityDomain]
    package let allowedRiskClasses: [AskRiskClass]
    package let requiresApprovalForVisibleActions: Bool
    package let requiresApprovalForDestructiveActions: Bool
    package let allowUnattendedExecution: Bool
    package let requireForegroundForAppControl: Bool
    package let allowClipboardWrite: Bool
    package let allowWorkspaceMutation: Bool
    package let allowShellExecution: Bool

    package init(
        id: String,
        summary: String,
        allowedModes: [AskExecutionMode],
        allowedDomains: [AskCapabilityDomain],
        allowedRiskClasses: [AskRiskClass],
        requiresApprovalForVisibleActions: Bool,
        requiresApprovalForDestructiveActions: Bool,
        allowUnattendedExecution: Bool,
        requireForegroundForAppControl: Bool,
        allowClipboardWrite: Bool,
        allowWorkspaceMutation: Bool,
        allowShellExecution: Bool
    ) {
        self.id = id
        self.summary = summary
        self.allowedModes = allowedModes
        self.allowedDomains = allowedDomains
        self.allowedRiskClasses = allowedRiskClasses
        self.requiresApprovalForVisibleActions = requiresApprovalForVisibleActions
        self.requiresApprovalForDestructiveActions = requiresApprovalForDestructiveActions
        self.allowUnattendedExecution = allowUnattendedExecution
        self.requireForegroundForAppControl = requireForegroundForAppControl
        self.allowClipboardWrite = allowClipboardWrite
        self.allowWorkspaceMutation = allowWorkspaceMutation
        self.allowShellExecution = allowShellExecution
    }

    package static func preset(for mode: AskExecutionMode) -> AskPolicyProfile {
        switch mode {
        case .automate:
            return AskPolicyProfile(
                id: "automate",
                summary: "Background and scheduled execution with inbox-returning outcomes.",
                allowedModes: [.automate],
                allowedDomains: [.time, .knowledge, .system],
                allowedRiskClasses: [.observational, .reversible],
                requiresApprovalForVisibleActions: true,
                requiresApprovalForDestructiveActions: true,
                allowUnattendedExecution: true,
                requireForegroundForAppControl: true,
                allowClipboardWrite: false,
                allowWorkspaceMutation: false,
                allowShellExecution: false
            )
        case .interactive:
            return AskPolicyProfile(
                id: "interactive",
                summary: "Foreground ASK execution across browser, desktop, workspace, automation drafting, and local tools.",
                allowedModes: [.interactive],
                allowedDomains: [.desktop, .browser, .appControl, .workspace, .knowledge, .time, .system],
                allowedRiskClasses: [.observational, .reversible, .userVisible, .privileged, .destructive],
                requiresApprovalForVisibleActions: true,
                requiresApprovalForDestructiveActions: true,
                allowUnattendedExecution: false,
                requireForegroundForAppControl: true,
                allowClipboardWrite: true,
                allowWorkspaceMutation: true,
                allowShellExecution: true
            )
        }
    }
}

package enum AskPolicyDecisionKind: String, Codable, Sendable {
    case allow
    case requireApproval
    case deny
}

package struct AskPolicyDecision: Codable, Equatable, Sendable {
    package let kind: AskPolicyDecisionKind
    package let reason: String
    package let requiresForeground: Bool
    package let profileID: String

    package init(
        kind: AskPolicyDecisionKind,
        reason: String,
        requiresForeground: Bool,
        profileID: String
    ) {
        self.kind = kind
        self.reason = reason
        self.requiresForeground = requiresForeground
        self.profileID = profileID
    }
}

package struct AskTaskLineage: Codable, Equatable, Sendable {
    package let invocationID: String
    package let rootTaskID: String
    package let parentTaskID: String?
    package let automationJobID: String?

    package init(
        invocationID: String,
        rootTaskID: String,
        parentTaskID: String?,
        automationJobID: String?
    ) {
        self.invocationID = invocationID
        self.rootTaskID = rootTaskID
        self.parentTaskID = parentTaskID
        self.automationJobID = automationJobID
    }
}

package struct AskAgentTask: Codable, Equatable, Sendable {
    package let id: String
    package let title: String
    package let objective: String
    package let mode: AskExecutionMode
    package let status: AskTaskStatus
    package let lineage: AskTaskLineage
    package let context: AskExecutionContext
    package let createdAt: Date
    package let updatedAt: Date
    package let pendingApprovalID: String?
    package let artifacts: [String]
    package let checklist: [AskTaskChecklistItem]?
    package let metadata: AskInvocationMetadata

    package init(
        id: String,
        title: String,
        objective: String,
        mode: AskExecutionMode,
        status: AskTaskStatus,
        lineage: AskTaskLineage,
        context: AskExecutionContext,
        createdAt: Date,
        updatedAt: Date,
        pendingApprovalID: String?,
        artifacts: [String],
        checklist: [AskTaskChecklistItem]?,
        metadata: AskInvocationMetadata
    ) {
        self.id = id
        self.title = title
        self.objective = objective
        self.mode = mode
        self.status = status
        self.lineage = lineage
        self.context = context
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pendingApprovalID = pendingApprovalID
        self.artifacts = artifacts
        self.checklist = checklist
        self.metadata = metadata
    }

    package static func make(
        title: String,
        objective: String,
        mode: AskExecutionMode,
        invocation: AskInvocation,
        context: AskExecutionContext,
        automationJobID: String? = nil
    ) -> AskAgentTask {
        let taskID = UUID().uuidString.lowercased()
        return AskAgentTask(
            id: taskID,
            title: title,
            objective: objective,
            mode: mode,
            status: .planning,
            lineage: AskTaskLineage(
                invocationID: invocation.id,
                rootTaskID: taskID,
                parentTaskID: invocation.parentTaskID,
                automationJobID: automationJobID
            ),
            context: context,
            createdAt: invocation.createdAt,
            updatedAt: invocation.createdAt,
            pendingApprovalID: nil,
            artifacts: [],
            checklist: [],
            metadata: invocation.metadata
        )
    }

    package static func makeSubtask(
        title: String,
        objective: String,
        parentTask: AskAgentTask,
        workspaceRoot: String? = nil,
        metadata: AskInvocationMetadata = [:],
        createdAt: Date = Date()
    ) -> AskAgentTask {
        let taskID = UUID().uuidString.lowercased()
        let effectiveWorkspaceRoot = workspaceRoot
            ?? parentTask.context.workspaceRootPath
            ?? parentTask.metadata["workspace_root"]
        var contextMetadata = parentTask.context.metadata.merging(metadata, uniquingKeysWith: { _, new in new })
        if let effectiveWorkspaceRoot, !effectiveWorkspaceRoot.isEmpty {
            contextMetadata["workspace_root"] = effectiveWorkspaceRoot
        }
        return AskAgentTask(
            id: taskID,
            title: title,
            objective: objective,
            mode: parentTask.mode,
            status: .planning,
            lineage: AskTaskLineage(
                invocationID: parentTask.lineage.invocationID,
                rootTaskID: parentTask.lineage.rootTaskID,
                parentTaskID: parentTask.id,
                automationJobID: parentTask.lineage.automationJobID
            ),
            context: AskExecutionContext(
                surface: parentTask.context.surface,
                sourceBundleID: parentTask.context.sourceBundleID,
                sourceAppName: parentTask.context.sourceAppName,
                workspaceRootPath: effectiveWorkspaceRoot,
                ambientContext: parentTask.context.ambientContext,
                timeZoneIdentifier: parentTask.context.timeZoneIdentifier,
                isUserPresent: parentTask.context.isUserPresent,
                metadata: contextMetadata
            ),
            createdAt: createdAt,
            updatedAt: createdAt,
            pendingApprovalID: nil,
            artifacts: [],
            checklist: [],
            metadata: parentTask.metadata.merging(metadata, uniquingKeysWith: { _, new in new })
        )
    }

    package func updated(
        status: AskTaskStatus,
        pendingApprovalID: String?,
        appendingArtifacts newArtifacts: [String] = [],
        mergingMetadata newMetadata: AskInvocationMetadata = [:],
        updatedAt: Date = Date()
    ) -> AskAgentTask {
        AskAgentTask(
            id: id,
            title: title,
            objective: objective,
            mode: mode,
            status: status,
            lineage: lineage,
            context: context,
            createdAt: createdAt,
            updatedAt: updatedAt,
            pendingApprovalID: pendingApprovalID,
            artifacts: mergedArtifacts(existing: artifacts, incoming: newArtifacts),
            checklist: checklistItems,
            metadata: metadata.merging(newMetadata, uniquingKeysWith: { _, new in new })
        )
    }

    package func revised(
        title newTitle: String? = nil,
        objective newObjective: String? = nil,
        status newStatus: AskTaskStatus? = nil,
        pendingApprovalID newPendingApprovalID: String? = nil,
        checklist newChecklist: [AskTaskChecklistItem]? = nil,
        appendingArtifacts newArtifacts: [String] = [],
        mergingMetadata newMetadata: AskInvocationMetadata = [:],
        updatedAt newUpdatedAt: Date = Date()
    ) -> AskAgentTask {
        AskAgentTask(
            id: id,
            title: normalizedReplacement(newTitle) ?? title,
            objective: normalizedReplacement(newObjective) ?? objective,
            mode: mode,
            status: newStatus ?? status,
            lineage: lineage,
            context: context,
            createdAt: createdAt,
            updatedAt: newUpdatedAt,
            pendingApprovalID: newPendingApprovalID ?? pendingApprovalID,
            artifacts: mergedArtifacts(existing: artifacts, incoming: newArtifacts),
            checklist: newChecklist ?? checklistItems,
            metadata: metadata.merging(newMetadata, uniquingKeysWith: { _, new in new })
        )
    }

    package var checklistItems: [AskTaskChecklistItem] {
        checklist ?? []
    }

    package var todoCount: Int {
        checklistItems.count
    }

    package var completedTodoCount: Int {
        checklistItems.filter { $0.status == .completed }.count
    }

    package var inProgressTodoCount: Int {
        checklistItems.filter { $0.status == .inProgress }.count
    }

    package var openTodoCount: Int {
        checklistItems.filter { $0.status != .completed }.count
    }

    package var todoProgressSummary: String {
        guard todoCount > 0 else {
            return "No checklist items recorded."
        }

        var parts = ["\(completedTodoCount)/\(todoCount) completed"]
        if inProgressTodoCount > 0 {
            parts.append("\(inProgressTodoCount) in progress")
        }
        let blockedCount = checklistItems.filter { $0.status == .blocked }.count
        if blockedCount > 0 {
            parts.append("\(blockedCount) blocked")
        }
        let pendingCount = checklistItems.filter { $0.status == .pending }.count
        if pendingCount > 0 {
            parts.append("\(pendingCount) pending")
        }
        return parts.joined(separator: ", ")
    }

    package func todoSummary(limit: Int = 5) -> String {
        guard !checklistItems.isEmpty else {
            return "No checklist items recorded."
        }

        var lines = checklistItems.prefix(limit).map { item in
            var line = "\(item.status.marker) \(item.title)"
            if let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines),
               !note.isEmpty {
                line += " (\(note))"
            }
            return line
        }
        let remainder = checklistItems.count - lines.count
        if remainder > 0 {
            lines.append("+\(remainder) more")
        }
        return lines.joined(separator: "\n")
    }

    private func mergedArtifacts(existing: [String], incoming: [String]) -> [String] {
        var merged = existing
        for artifact in incoming where !artifact.isEmpty && !merged.contains(artifact) {
            merged.append(artifact)
        }
        return merged
    }

    private func normalizedReplacement(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

package struct AskPreparedTask: Sendable {
    package let invocation: AskInvocation
    package let context: AskExecutionContext
    package let task: AskAgentTask
    package let profile: AskPolicyProfile
    package let capabilities: [AskCapabilityDefinition]
    package let capabilityDecisions: [AskCapabilityID: AskPolicyDecision]

    package init(
        invocation: AskInvocation,
        context: AskExecutionContext,
        task: AskAgentTask,
        profile: AskPolicyProfile,
        capabilities: [AskCapabilityDefinition],
        capabilityDecisions: [AskCapabilityID: AskPolicyDecision]
    ) {
        self.invocation = invocation
        self.context = context
        self.task = task
        self.profile = profile
        self.capabilities = capabilities
        self.capabilityDecisions = capabilityDecisions
    }
}
