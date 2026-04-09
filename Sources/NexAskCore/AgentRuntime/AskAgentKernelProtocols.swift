import Foundation

struct AskDefaultPolicyEngine: AskPolicyEvaluating {
    func decision(
        for capability: AskCapabilityDefinition,
        invocation: AskInvocation,
        context: AskExecutionContext,
        profile: AskPolicyProfile
    ) -> AskPolicyDecision {
        guard profile.allowedModes.contains(invocation.requestedMode ?? profile.allowedModes.first ?? .interactive) || invocation.requestedMode == nil else {
            return AskPolicyDecision(
                kind: .deny,
                reason: "The requested execution mode is not allowed by this policy profile.",
                requiresForeground: false,
                profileID: profile.id
            )
        }

        guard profile.allowedDomains.contains(capability.domain) else {
            return AskPolicyDecision(
                kind: .deny,
                reason: "This capability domain is outside the allowed policy scope.",
                requiresForeground: false,
                profileID: profile.id
            )
        }

        guard profile.allowedRiskClasses.contains(capability.riskClass) else {
            return AskPolicyDecision(
                kind: .deny,
                reason: "This capability risk class is not allowed by the current profile.",
                requiresForeground: false,
                profileID: profile.id
            )
        }

        if capability.domain == .workspace && capability.riskClass >= .reversible && !profile.allowWorkspaceMutation {
            return AskPolicyDecision(
                kind: .deny,
                reason: "Workspace mutation is disabled in the current profile.",
                requiresForeground: false,
                profileID: profile.id
            )
        }

        if capability.id == "workspace.run_shell_command" && !profile.allowShellExecution {
            return AskPolicyDecision(
                kind: .deny,
                reason: "Shell execution is disabled in the current profile.",
                requiresForeground: false,
                profileID: profile.id
            )
        }

        if capability.id == "app.copy_to_clipboard" && !profile.allowClipboardWrite {
            return AskPolicyDecision(
                kind: .deny,
                reason: "Clipboard mutation is disabled in the current profile.",
                requiresForeground: false,
                profileID: profile.id
            )
        }

        if capability.domain == .appControl && profile.requireForegroundForAppControl && !context.isUserPresent {
            return AskPolicyDecision(
                kind: .deny,
                reason: "Foreground app control requires an active user-presence context.",
                requiresForeground: true,
                profileID: profile.id
            )
        }

        if isWorkspacePlanModeBlocking(capability: capability, invocation: invocation, context: context) {
            return AskPolicyDecision(
                kind: .deny,
                reason: "This workspace session is still in read-only planning mode.",
                requiresForeground: false,
                profileID: profile.id
            )
        }

        if sessionGrantAllowsDirectExecution(
            capability: capability,
            invocation: invocation,
            context: context
        ) {
            return AskPolicyDecision(
                kind: .allow,
                reason: "Allowed by the current session execution grant.",
                requiresForeground: capability.visibilityClass == .foregroundWriteback,
                profileID: profile.id
            )
        }

        if requiresInteractiveTaskScopeApproval(
            capability: capability,
            invocation: invocation,
            context: context
        ) {
            return AskPolicyDecision(
                kind: .requireApproval,
                reason: "This task wants to modify the current Playground workspace. Approve once to allow related writes, shell commands, patch application, and opening the result for this task.",
                requiresForeground: capability.visibilityClass == .foregroundWriteback,
                profileID: profile.id
            )
        }

        if !capability.supportsUnattendedExecution && !profile.allowUnattendedExecution && invocation.surface == .automation {
            return AskPolicyDecision(
                kind: .deny,
                reason: "This capability cannot run unattended from an automation surface.",
                requiresForeground: capability.visibilityClass == .foregroundWriteback,
                profileID: profile.id
            )
        }

        if capability.riskClass == .destructive && profile.requiresApprovalForDestructiveActions {
            return AskPolicyDecision(
                kind: .requireApproval,
                reason: "Destructive actions require explicit approval.",
                requiresForeground: capability.visibilityClass == .foregroundWriteback,
                profileID: profile.id
            )
        }

        if capability.visibilityClass != .silent && profile.requiresApprovalForVisibleActions {
            return AskPolicyDecision(
                kind: .requireApproval,
                reason: "User-visible actions require explicit approval in this profile.",
                requiresForeground: capability.visibilityClass == .foregroundWriteback,
                profileID: profile.id
            )
        }

        return AskPolicyDecision(
            kind: .allow,
            reason: "Allowed by the active policy profile.",
            requiresForeground: capability.visibilityClass == .foregroundWriteback,
            profileID: profile.id
        )
    }

    func executionDecision(
        for capability: AskCapabilityDefinition,
        invocation: AskInvocation,
        context: AskExecutionContext,
        profile: AskPolicyProfile,
        arguments: AskInvocationMetadata
    ) -> AskPolicyDecision {
        let baseDecision = decision(
            for: capability,
            invocation: invocation,
            context: context,
            profile: profile
        )
        let taskScopeAllowsDirectExecution = taskScopeGrantAllowsDirectExecution(
            capability: capability,
            invocation: invocation,
            context: context,
            arguments: arguments
        )
        let taskScopeApprovalBypass = AskPolicyDecision(
            kind: .allow,
            reason: "Allowed by the current task execution grant.",
            requiresForeground: capability.visibilityClass == .foregroundWriteback,
            profileID: profile.id
        )

        if capability.id != "workspace.run_shell_command" {
            if taskScopeAllowsDirectExecution && baseDecision.kind != .deny {
                return taskScopeApprovalBypass
            }
            return baseDecision
        }

        guard invocation.surface != .automation else {
            if taskScopeAllowsDirectExecution && baseDecision.kind != .deny {
                return taskScopeApprovalBypass
            }
            return baseDecision
        }

        if baseDecision.kind == .deny {
            return baseDecision
        }

        let command = shellCommand(in: arguments)
        guard !command.isEmpty else {
            return taskScopeAllowsDirectExecution ? taskScopeApprovalBypass : baseDecision
        }

        let budget = AskWorkspaceExecutionBudget.from(
            metadata: mergedMetadata(invocation: invocation, context: context)
        )
        let commandProfile = AskWorkspaceShellCommandProfile(command: command)

        if commandProfile.mutatesWorkspace && !budget.grantsWorkspaceWrites {
            return AskPolicyDecision(
                kind: .requireApproval,
                reason: "Mutating shell commands require explicit approval unless workspace writes are granted for this session.",
                requiresForeground: capability.visibilityClass == .foregroundWriteback,
                profileID: profile.id
            )
        }

        if commandProfile.requiresGitWriteActions && !budget.grantsGitWriteActions {
            return AskPolicyDecision(
                kind: .requireApproval,
                reason: "Git write shell commands require explicit approval unless git write actions are granted for this session.",
                requiresForeground: capability.visibilityClass == .foregroundWriteback,
                profileID: profile.id
            )
        }

        if commandProfile.requiresNetworkAccess && !budget.grantsNetworkAccess {
            return AskPolicyDecision(
                kind: .requireApproval,
                reason: "Networked shell commands require explicit approval unless network access is granted for this session.",
                requiresForeground: capability.visibilityClass == .foregroundWriteback,
                profileID: profile.id
            )
        }

        if taskScopeAllowsDirectExecution {
            return taskScopeApprovalBypass
        }

        return baseDecision
    }

    private func isWorkspacePlanModeBlocking(
        capability: AskCapabilityDefinition,
        invocation: AskInvocation,
        context: AskExecutionContext
    ) -> Bool {
        guard metadataBool(["plan_mode_active"], invocation: invocation, context: context) else {
            return false
        }
        guard capability.domain == .workspace else {
            return false
        }
        let readOnlyAllowedCapabilities: Set<AskCapabilityID> = [
            "workspace.snapshot_tree",
            "workspace.glob_paths",
            "workspace.grep_text",
            "workspace.read_file",
            "workspace.apply_patch_preview",
            "workspace.enter_plan_mode",
            "workspace.exit_plan_mode",
            "workspace.set_execution_budget"
        ]
        return !readOnlyAllowedCapabilities.contains(capability.id)
    }

    private func sessionGrantAllowsDirectExecution(
        capability: AskCapabilityDefinition,
        invocation: AskInvocation,
        context: AskExecutionContext
    ) -> Bool {
        guard invocation.surface != .automation else {
            return false
        }
        if isInteractivePlaygroundMutationCapability(
            capability: capability,
            invocation: invocation,
            context: context
        ) {
            return false
        }
        let executionBudget = AskWorkspaceExecutionBudget.from(
            metadata: mergedMetadata(invocation: invocation, context: context)
        )
        switch capability.id {
        case "workspace.run_shell_command":
            return metadataBool(["workspace_shell_granted"], invocation: invocation, context: context)
                || executionBudget.grantsShellExecution
        case "workspace.commit_changes", "workspace.write_file", "workspace.create_directory":
            return metadataBool(["workspace_write_granted"], invocation: invocation, context: context)
                || executionBudget.grantsWorkspaceWrites
        default:
            return false
        }
    }

    private func isInteractivePlaygroundMutationCapability(
        capability: AskCapabilityDefinition,
        invocation: AskInvocation,
        context: AskExecutionContext
    ) -> Bool {
        guard invocation.surface != .automation else {
            return false
        }
        guard [
            "workspace.create_directory",
            "workspace.write_file",
            "workspace.run_shell_command",
            "workspace.commit_changes"
        ].contains(capability.id) else {
            return false
        }
        let metadata = mergedMetadata(invocation: invocation, context: context)
        guard let explicitWorkspaceRoot = firstNonEmptyValue(
            in: metadata,
            keys: ["workspace_root", "active_task_workspace_root"]
        ) else {
            return true
        }
        return AskPlaygroundStore.shared.isInsidePlayground(path: explicitWorkspaceRoot)
    }

    private func requiresInteractiveTaskScopeApproval(
        capability: AskCapabilityDefinition,
        invocation: AskInvocation,
        context: AskExecutionContext
    ) -> Bool {
        guard invocation.surface != .automation else {
            return false
        }
        guard [
            "workspace.create_directory",
            "workspace.write_file",
            "workspace.run_shell_command",
            "workspace.commit_changes"
        ].contains(capability.id) else {
            return false
        }
        if let explicitWorkspaceRoot = firstNonEmptyValue(
            in: mergedMetadata(invocation: invocation, context: context),
            keys: ["workspace_root", "active_task_workspace_root"]
        ), !AskPlaygroundStore.shared.isInsidePlayground(path: explicitWorkspaceRoot) {
            return false
        }
        return !metadataBool(["interactive_task_scope_granted"], invocation: invocation, context: context)
    }

    private func taskScopeGrantAllowsDirectExecution(
        capability: AskCapabilityDefinition,
        invocation: AskInvocation,
        context: AskExecutionContext,
        arguments: AskInvocationMetadata
    ) -> Bool {
        guard metadataBool(["interactive_task_scope_granted"], invocation: invocation, context: context) else {
            return false
        }
        let metadata = mergedMetadata(invocation: invocation, context: context)
        let grantedRoot = firstNonEmptyValue(
            in: metadata,
            keys: ["interactive_task_scope_root", "active_task_workspace_root", "workspace_root"]
        )

        switch capability.id {
        case "workspace.create_directory", "workspace.write_file", "workspace.run_shell_command", "workspace.commit_changes":
            return grantedRoot != nil
        case "desktop.open_path", "desktop.reveal_in_finder":
            guard let grantedRoot,
                  let rawPath = firstNonEmptyValue(in: arguments, keys: ["path", "file", "file_path"]),
                  let candidatePath = normalizedChildPath(rawPath, root: grantedRoot) else {
                return false
            }
            return candidatePath.hasPrefix(grantedRoot)
        default:
            return false
        }
    }

    private func mergedMetadata(
        invocation: AskInvocation,
        context: AskExecutionContext
    ) -> AskInvocationMetadata {
        context.metadata.merging(invocation.metadata, uniquingKeysWith: { _, new in new })
    }

    private func shellCommand(in arguments: AskInvocationMetadata) -> String {
        for key in ["command", "cmd", "shell_command"] {
            guard let command = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else {
                continue
            }
            return command
        }
        return ""
    }

    private func metadataBool(
        _ keys: [String],
        invocation: AskInvocation,
        context: AskExecutionContext
    ) -> Bool {
        for key in keys {
            let invocationValue = invocation.metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if invocationValue == "true" {
                return true
            }
            if invocationValue == "false" {
                return false
            }

            let contextValue = context.metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if contextValue == "true" {
                return true
            }
            if contextValue == "false" {
                return false
            }
        }
        return false
    }

    private func firstNonEmptyValue(
        in metadata: [String: String],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    private func normalizedChildPath(_ rawPath: String, root: String) -> String? {
        let candidateURL: URL
        if rawPath.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: rawPath)
        } else {
            candidateURL = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(rawPath)
        }
        let normalizedRoot = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
        let normalizedCandidate = candidateURL.standardizedFileURL.path
        guard normalizedCandidate == normalizedRoot || normalizedCandidate.hasPrefix(normalizedRoot + "/") else {
            return nil
        }
        return normalizedCandidate
    }
}
