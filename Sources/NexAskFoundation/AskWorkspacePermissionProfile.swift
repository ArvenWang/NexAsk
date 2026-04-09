import Foundation

package enum AskWorkspacePermissionProfile: String, CaseIterable, Codable, Sendable {
    case manualApproval = "manual_approval"
    case shellExecution = "shell_execution"
    case workspaceWrites = "workspace_writes"
    case workspaceWritesAndShellExecution = "workspace_writes_and_shell_execution"

    package static func parse(_ rawValue: String?) -> AskWorkspacePermissionProfile? {
        guard let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }

        switch normalized {
        case AskWorkspacePermissionProfile.manualApproval.rawValue:
            return .manualApproval
        case AskWorkspacePermissionProfile.shellExecution.rawValue:
            return .shellExecution
        case AskWorkspacePermissionProfile.workspaceWrites.rawValue:
            return .workspaceWrites
        case AskWorkspacePermissionProfile.workspaceWritesAndShellExecution.rawValue,
             "workspace_writes,shell_execution":
            return .workspaceWritesAndShellExecution
        default:
            return nil
        }
    }

    package static func resolve(
        workspaceWritesGranted: Bool,
        shellGranted: Bool
    ) -> AskWorkspacePermissionProfile {
        switch (workspaceWritesGranted, shellGranted) {
        case (true, true):
            return .workspaceWritesAndShellExecution
        case (true, false):
            return .workspaceWrites
        case (false, true):
            return .shellExecution
        case (false, false):
            return .manualApproval
        }
    }

    package static func from(metadata: [String: String]) -> AskWorkspacePermissionProfile {
        if let explicitProfile = AskWorkspacePermissionProfile.parse(
            firstNonEmptyValue(
                in: metadata,
                keys: ["workspace_permission_profile", "permission_profile"]
            )
        ) {
            return explicitProfile
        }

        let workspaceWritesGranted = metadata["workspace_write_granted"]?.lowercased() == "true"
        let shellGranted = metadata["workspace_shell_granted"]?.lowercased() == "true"
        return resolve(
            workspaceWritesGranted: workspaceWritesGranted,
            shellGranted: shellGranted
        )
    }

    package var grantsWorkspaceWrites: Bool {
        switch self {
        case .manualApproval, .shellExecution:
            return false
        case .workspaceWrites, .workspaceWritesAndShellExecution:
            return true
        }
    }

    package var grantsShellExecution: Bool {
        switch self {
        case .manualApproval, .workspaceWrites:
            return false
        case .shellExecution, .workspaceWritesAndShellExecution:
            return true
        }
    }

    package func executionBudgetValue(planModeActive: Bool) -> String {
        planModeActive ? "read_only_plan" : rawValue
    }

    package func localizedLabel(responseLanguage: String) -> String {
        switch self {
        case .manualApproval:
            return AskRuntimeLocalization.text(
                languageCode: responseLanguage,
                zhHans: "按动作确认",
                en: "per-action approval"
            )
        case .shellExecution:
            return AskRuntimeLocalization.text(
                languageCode: responseLanguage,
                zhHans: "shell 执行",
                en: "shell execution"
            )
        case .workspaceWrites:
            return AskRuntimeLocalization.text(
                languageCode: responseLanguage,
                zhHans: "工作区写入",
                en: "workspace writes"
            )
        case .workspaceWritesAndShellExecution:
            return AskRuntimeLocalization.text(
                languageCode: responseLanguage,
                zhHans: "工作区写入 + shell 执行",
                en: "workspace writes + shell execution"
            )
        }
    }

    package func localizedCompactLabel(responseLanguage: String) -> String {
        switch self {
        case .manualApproval:
            return AskRuntimeLocalization.text(
                languageCode: responseLanguage,
                zhHans: "按动作确认",
                en: "per-action approval"
            )
        case .shellExecution:
            return AskRuntimeLocalization.text(
                languageCode: responseLanguage,
                zhHans: "shell",
                en: "shell"
            )
        case .workspaceWrites:
            return AskRuntimeLocalization.text(
                languageCode: responseLanguage,
                zhHans: "写入",
                en: "writes"
            )
        case .workspaceWritesAndShellExecution:
            return AskRuntimeLocalization.text(
                languageCode: responseLanguage,
                zhHans: "写入 + shell",
                en: "writes + shell"
            )
        }
    }

    fileprivate static func firstNonEmptyValue(
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
}

package struct AskWorkspaceExecutionBudget: Codable, Equatable, Sendable {
    package let permissionProfile: AskWorkspacePermissionProfile
    package let grantsGitWriteActions: Bool
    package let grantsNetworkAccess: Bool

    package init(
        permissionProfile: AskWorkspacePermissionProfile,
        grantsGitWriteActions: Bool = false,
        grantsNetworkAccess: Bool = false
    ) {
        self.permissionProfile = permissionProfile
        if permissionProfile.grantsShellExecution {
            self.grantsGitWriteActions = grantsGitWriteActions
            self.grantsNetworkAccess = grantsNetworkAccess
        } else {
            self.grantsGitWriteActions = false
            self.grantsNetworkAccess = false
        }
    }

    package static func from(metadata: [String: String]) -> AskWorkspaceExecutionBudget {
        AskWorkspaceExecutionBudget(
            permissionProfile: AskWorkspacePermissionProfile.from(metadata: metadata),
            grantsGitWriteActions: metadataBool(
                in: metadata,
                keys: ["workspace_git_write_granted", "git_write_actions_granted"]
            ) ?? false,
            grantsNetworkAccess: metadataBool(
                in: metadata,
                keys: ["workspace_network_access_granted", "network_access_granted"]
            ) ?? false
        )
    }

    package static func resolve(
        explicitProfile: AskWorkspacePermissionProfile?,
        requestedWorkspaceWrites: Bool?,
        requestedShellExecution: Bool?,
        requestedGitWriteActions: Bool?,
        requestedNetworkAccess: Bool?,
        fallback: AskWorkspaceExecutionBudget
    ) -> AskWorkspaceExecutionBudget {
        let permissionProfile: AskWorkspacePermissionProfile
        if let explicitProfile {
            permissionProfile = explicitProfile
        } else {
            permissionProfile = AskWorkspacePermissionProfile.resolve(
                workspaceWritesGranted: requestedWorkspaceWrites ?? fallback.grantsWorkspaceWrites,
                shellGranted: requestedShellExecution ?? fallback.grantsShellExecution
            )
        }

        return AskWorkspaceExecutionBudget(
            permissionProfile: permissionProfile,
            grantsGitWriteActions: requestedGitWriteActions ?? fallback.grantsGitWriteActions,
            grantsNetworkAccess: requestedNetworkAccess ?? fallback.grantsNetworkAccess
        )
    }

    package var grantsWorkspaceWrites: Bool {
        permissionProfile.grantsWorkspaceWrites
    }

    package var grantsShellExecution: Bool {
        permissionProfile.grantsShellExecution
    }

    package var grantsMutatingShellExecution: Bool {
        grantsWorkspaceWrites && grantsShellExecution
    }

    package var hasExtendedShellGrants: Bool {
        grantsGitWriteActions || grantsNetworkAccess
    }

    package func allowsDirectExecution(for shellCommandProfile: AskWorkspaceShellCommandProfile) -> Bool {
        guard grantsShellExecution else {
            return false
        }
        if shellCommandProfile.mutatesWorkspace && !grantsWorkspaceWrites {
            return false
        }
        if shellCommandProfile.requiresGitWriteActions && !grantsGitWriteActions {
            return false
        }
        if shellCommandProfile.requiresNetworkAccess && !grantsNetworkAccess {
            return false
        }
        return true
    }

    package func executionBudgetValue(planModeActive: Bool) -> String {
        guard !planModeActive else {
            return "read_only_plan"
        }

        var components = [permissionProfile.rawValue]
        if grantsGitWriteActions {
            components.append("git_write_actions")
        }
        if grantsNetworkAccess {
            components.append("network_access")
        }
        return components.joined(separator: "+")
    }

    package func localizedLabel(responseLanguage: String) -> String {
        var labels = [permissionProfile.localizedLabel(responseLanguage: responseLanguage)]
        if grantsGitWriteActions {
            labels.append(
                AskRuntimeLocalization.text(
                    languageCode: responseLanguage,
                    zhHans: "git 写动作",
                    en: "git write actions"
                )
            )
        }
        if grantsNetworkAccess {
            labels.append(
                AskRuntimeLocalization.text(
                    languageCode: responseLanguage,
                    zhHans: "网络访问",
                    en: "network access"
                )
            )
        }
        return labels.joined(separator: " + ")
    }

    package func localizedCompactLabel(responseLanguage: String) -> String {
        var labels = [permissionProfile.localizedCompactLabel(responseLanguage: responseLanguage)]
        if grantsGitWriteActions {
            labels.append(
                AskRuntimeLocalization.text(
                    languageCode: responseLanguage,
                    zhHans: "git",
                    en: "git"
                )
            )
        }
        if grantsNetworkAccess {
            labels.append(
                AskRuntimeLocalization.text(
                    languageCode: responseLanguage,
                    zhHans: "网络",
                    en: "net"
                )
            )
        }
        return labels.joined(separator: " + ")
    }

    private static func metadataBool(
        in metadata: [String: String],
        keys: [String]
    ) -> Bool? {
        for key in keys {
            guard let normalized = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !normalized.isEmpty else {
                continue
            }
            switch normalized {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                continue
            }
        }
        return nil
    }
}
