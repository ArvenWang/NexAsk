import Foundation
import NexShared

struct AskWorkspaceExecutor: AskCapabilityExecuting {
    let supportedCapabilityIDs: [AskCapabilityID] = [
        "workspace.snapshot_tree",
        "workspace.glob_paths",
        "workspace.grep_text",
        "workspace.read_file",
        "workspace.create_directory",
        "workspace.write_file",
        "workspace.run_shell_command",
        "workspace.apply_patch_preview",
        "workspace.commit_changes",
        "workspace.enter_plan_mode",
        "workspace.exit_plan_mode",
        "workspace.set_execution_budget"
    ]

    func execute(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        switch request.capability.id {
        case "workspace.snapshot_tree":
            return await snapshotTree(request: request)
        case "workspace.glob_paths":
            return await globPaths(request: request)
        case "workspace.grep_text":
            return await grepText(request: request)
        case "workspace.read_file":
            return await readFile(request: request)
        case "workspace.create_directory":
            return await createDirectory(request: request)
        case "workspace.write_file":
            return await writeFile(request: request)
        case "workspace.run_shell_command":
            return await runShellCommand(request: request)
        case "workspace.apply_patch_preview":
            return applyPatchPreview(request: request)
        case "workspace.commit_changes":
            return await commitChanges(request: request)
        case "workspace.enter_plan_mode":
            return await enterPlanMode(request: request)
        case "workspace.exit_plan_mode":
            return await exitPlanMode(request: request)
        case "workspace.set_execution_budget":
            return await setExecutionBudget(request: request)
        default:
            return .unsupported(summary: "Unsupported workspace capability: \(request.capability.id)")
        }
    }

    private func enterPlanMode(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let root = await resolvedWorkspaceRoot(for: request) else {
            return missingWorkspaceRoot()
        }

        let requestedScope = firstNonEmptyValue(
            in: request.arguments,
            keys: ["plan_scope", "goal", "objective", "summary"]
        ) ?? request.task.objective
        let normalizedScope = requestedScope.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = normalizedScope.isEmpty
            ? "Entered read-only planning mode for the workspace."
            : "Entered read-only planning mode for the workspace: \(String(normalizedScope.prefix(220)))."

        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: summary,
            approvalID: nil,
            artifacts: [
                AskCapabilityArtifact(kind: "plan_mode_workspace_root", value: root),
                AskCapabilityArtifact(kind: "plan_mode_summary", value: normalizedScope),
                AskCapabilityArtifact(kind: "workspace_permission_profile", value: AskWorkspacePermissionProfile.manualApproval.rawValue)
            ],
            metadata: [
                "workspace_root": root,
                "plan_mode_active": "true",
                "plan_mode_summary": normalizedScope,
                "edit_scope_limited": "true",
                "workspace_write_granted": "false",
                "workspace_patch_granted": "false",
                "workspace_shell_granted": "false",
                "workspace_git_write_granted": "false",
                "workspace_network_access_granted": "false",
                "workspace_permission_profile": AskWorkspacePermissionProfile.manualApproval.rawValue,
                "workspace_execution_budget": AskWorkspacePermissionProfile.manualApproval.executionBudgetValue(planModeActive: true)
            ]
        )
    }

    private func exitPlanMode(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let root = await resolvedWorkspaceRoot(for: request) else {
            return missingWorkspaceRoot()
        }

        let executionScope = firstNonEmptyValue(
            in: request.arguments,
            keys: ["execution_scope", "next_step", "goal", "objective", "summary"]
        ) ?? request.task.objective
        let normalizedScope = executionScope.trimmingCharacters(in: .whitespacesAndNewlines)
        let executionBudget = resolvedExecutionBudget(
            request: request,
            fallbackMetadata: request.task.context.metadata
        )
        let executionBudgetValue = executionBudget.executionBudgetValue(planModeActive: false)
        let summary = normalizedScope.isEmpty
            ? "Exited read-only planning mode for the workspace."
            : "Exited read-only planning mode for the workspace: \(String(normalizedScope.prefix(220)))."
        let budgetSuffix = executionBudget.permissionProfile == .manualApproval
            ? ""
            : " Session grants: \(executionBudget.executionBudgetValue(planModeActive: false))."

        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: summary + budgetSuffix,
            approvalID: nil,
            artifacts: [
                AskCapabilityArtifact(kind: "plan_mode_workspace_root", value: root),
                AskCapabilityArtifact(kind: "execution_scope", value: normalizedScope),
                AskCapabilityArtifact(kind: "workspace_execution_budget", value: executionBudgetValue),
                AskCapabilityArtifact(kind: "workspace_permission_profile", value: executionBudget.permissionProfile.rawValue)
            ],
            metadata: executionBudgetMetadata(
                root: root,
                planModeActive: false,
                planModeSummary: normalizedScope,
                editScopeLimited: false,
                budget: executionBudget,
                executionBudgetValue: executionBudgetValue
            )
        )
    }

    private func setExecutionBudget(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let root = await resolvedWorkspaceRoot(for: request) else {
            return missingWorkspaceRoot()
        }

        let requestedProfile = permissionProfileValue(
            in: request.arguments,
            keys: ["permission_profile", "workspace_permission_profile", "execution_budget"]
        )
        let requestedWorkspaceWrites = boolValue(
            in: request.arguments,
            keys: ["grant_workspace_writes", "allow_workspace_writes", "grant_writes"]
        )
        let requestedShellExecution = boolValue(
            in: request.arguments,
            keys: ["grant_shell_execution", "allow_shell_execution", "grant_shell"]
        )
        let requestedGitWriteActions = boolValue(
            in: request.arguments,
            keys: ["grant_git_write_actions", "allow_git_write_actions", "grant_git_writes", "grant_git_write"]
        )
        let requestedNetworkAccess = boolValue(
            in: request.arguments,
            keys: ["grant_network_access", "allow_network_access", "grant_network"]
        )
        guard requestedProfile != nil
                || requestedWorkspaceWrites != nil
                || requestedShellExecution != nil
                || requestedGitWriteActions != nil
                || requestedNetworkAccess != nil else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No workspace execution budget update was requested.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "workspace_root": root
                ]
            )
        }

        let fallbackBudget = AskWorkspaceExecutionBudget.from(metadata: request.task.context.metadata)
        let executionBudget = AskWorkspaceExecutionBudget.resolve(
            explicitProfile: requestedProfile,
            requestedWorkspaceWrites: requestedWorkspaceWrites,
            requestedShellExecution: requestedShellExecution,
            requestedGitWriteActions: requestedGitWriteActions,
            requestedNetworkAccess: requestedNetworkAccess,
            fallback: fallbackBudget
        )
        let budgetSummary = firstNonEmptyValue(
            in: request.arguments,
            keys: ["budget_summary", "summary", "goal", "objective"]
        )
        let planModeActive = boolValue(in: request.task.context.metadata, keys: ["plan_mode_active"]) ?? false
        let executionBudgetValue = executionBudget.executionBudgetValue(planModeActive: planModeActive)
        let summaryPrefix: String
        if executionBudget.permissionProfile == .manualApproval && !executionBudget.hasExtendedShellGrants {
            summaryPrefix = "Reset the workspace session execution budget to per-action approval."
        } else {
            summaryPrefix = "Updated the workspace session execution budget: \(executionBudget.executionBudgetValue(planModeActive: false))."
        }
        let scopeSuffix = budgetSummary.flatMap { summary in
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return " Scope: \(String(trimmed.prefix(220)))."
        } ?? ""
        let planModeSuffix = planModeActive ? " Planning mode remains active." : ""

        let metadata = executionBudgetMetadata(
            root: root,
            planModeActive: planModeActive,
            planModeSummary: request.task.context.metadata["plan_mode_summary"],
            editScopeLimited: boolValue(in: request.task.context.metadata, keys: ["edit_scope_limited"]) ?? false,
            budget: executionBudget,
            executionBudgetValue: executionBudgetValue
        )

        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: summaryPrefix + scopeSuffix + planModeSuffix,
            approvalID: nil,
            artifacts: [
                AskCapabilityArtifact(kind: "workspace_execution_budget", value: executionBudgetValue),
                AskCapabilityArtifact(kind: "workspace_permission_profile", value: executionBudget.permissionProfile.rawValue)
            ],
            metadata: metadata
        )
    }

    private func snapshotTree(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let root = await resolvedWorkspaceRoot(for: request) else {
            return missingWorkspaceRoot()
        }

        let limit = Int(request.arguments["limit"] ?? "") ?? 200
        let entries = enumeratedPaths(root: root, limit: max(1, min(limit, 500)))
        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: entries.isEmpty ? "No visible files were found in the workspace." : "Enumerated \(entries.count) workspace path(s).",
            approvalID: nil,
            artifacts: [AskCapabilityArtifact(kind: "workspace_tree", value: entries.joined(separator: "\n"))],
            metadata: [
                "workspace_root": root,
                "count": String(entries.count)
            ]
        )
    }

    private func globPaths(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let root = await resolvedWorkspaceRoot(for: request) else {
            return missingWorkspaceRoot()
        }
        guard let glob = firstNonEmptyValue(in: request.arguments, keys: ["glob", "pattern", "file_glob"]) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No workspace glob pattern was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let limit = Int(request.arguments["limit"] ?? "") ?? 120
        let result = runProcess(
            executable: "/usr/bin/env",
            arguments: ["rg", "--files", root, "--glob", glob],
            currentDirectory: root
        )
        let output = firstNonEmpty(result.stdout, result.stderr)
        let matches = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let limitedMatches = Array(matches.prefix(max(1, min(limit, 500))))
        let searchSucceeded = result.exitCode == 0 || (result.exitCode == 1 && result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        return AskCapabilityExecutionResult(
            status: searchSucceeded ? .succeeded : .failed,
            summary: limitedMatches.isEmpty
                ? "No workspace paths matched the requested glob."
                : "Matched \(limitedMatches.count) workspace path(s) for the glob.",
            approvalID: nil,
            artifacts: limitedMatches.isEmpty ? [] : [AskCapabilityArtifact(kind: "workspace_glob_matches", value: limitedMatches.joined(separator: "\n"))],
            metadata: [
                "workspace_root": root,
                "glob": glob,
                "count": String(limitedMatches.count),
                "exit_code": String(result.exitCode)
            ]
        )
    }

    private func grepText(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let root = await resolvedWorkspaceRoot(for: request) else {
            return missingWorkspaceRoot()
        }
        guard let pattern = firstNonEmptyValue(in: request.arguments, keys: ["pattern", "query", "text"]) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No grep pattern was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let limit = Int(request.arguments["limit"] ?? "") ?? 80
        var arguments = [
            "--color", "never",
            "--line-number",
            "--no-heading",
            "--max-count", String(max(1, min(limit, 200))),
            pattern,
            root
        ]
        if let glob = firstNonEmptyValue(in: request.arguments, keys: ["glob", "file_glob"]) {
            arguments.insert(contentsOf: ["--glob", glob], at: 0)
        }

        let rgResult = runProcess(executable: "/usr/bin/env", arguments: ["rg"] + arguments, currentDirectory: root)
        let finalResult: AskShellCommandResult
        if rgResult.exitCode == 0 || !rgResult.stdout.isEmpty {
            finalResult = rgResult
        } else {
            finalResult = runProcess(
                executable: "/usr/bin/env",
                arguments: ["grep", "-RIn", pattern, root],
                currentDirectory: root
            )
        }

        let output = firstNonEmpty(finalResult.stdout, finalResult.stderr)
        let searchSucceeded = finalResult.exitCode == 0 || finalResult.exitCode == 1
        return AskCapabilityExecutionResult(
            status: searchSucceeded ? .succeeded : .failed,
            summary: output.isEmpty ? "No matching lines were found in the workspace." : "Searched the workspace for matching text.",
            approvalID: nil,
            artifacts: output.isEmpty ? [] : [AskCapabilityArtifact(kind: "grep_output", value: output)],
            metadata: [
                "workspace_root": root,
                "pattern": pattern,
                "exit_code": String(finalResult.exitCode)
            ]
        )
    }

    private func readFile(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let root = await resolvedWorkspaceRoot(for: request) else {
            return missingWorkspaceRoot()
        }
        guard let rawPath = firstNonEmptyValue(in: request.arguments, keys: ["path", "file", "file_path"]),
              let fileURL = resolvedPath(rawPath, workspaceRoot: root) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No readable file path was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        do {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let maxLength = Int(request.arguments["max_length"] ?? "") ?? 24_000
            let truncated = String(contents.prefix(max(1, min(maxLength, 80_000))))
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Read \(fileURL.lastPathComponent) from the workspace.",
                approvalID: nil,
                artifacts: [AskCapabilityArtifact(kind: "file_contents", value: truncated)],
                metadata: [
                    "workspace_root": root,
                    "path": fileURL.path,
                    "truncated": String(contents.count > truncated.count)
                ]
            )
        } catch {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "Failed to read the requested workspace file.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "workspace_root": root,
                    "path": fileURL.path,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private func createDirectory(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        let workspaceRoot = await resolvedWorkspaceRoot(for: request)
        guard let folderName = firstNonEmptyValue(in: request.arguments, keys: ["name", "directory_name", "folder_name"]) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No folder name was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let rawParent = firstNonEmptyValue(in: request.arguments, keys: ["parent_directory", "path", "directory"])
        guard let parentURL = resolvedWorkspacePath(rawParent, workspaceRoot: workspaceRoot) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No valid parent directory was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "workspace_root": workspaceRoot ?? ""
                ]
            )
        }

        let targetURL = parentURL.appendingPathComponent(folderName, isDirectory: true).standardizedFileURL
        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared to create the directory \(targetURL.lastPathComponent).",
                approvalID: nil,
                artifacts: [AskCapabilityArtifact(kind: "planned_directory", value: targetURL.path)],
                metadata: [
                    "workspace_root": workspaceRoot ?? "",
                    "active_task_workspace_root": workspaceRoot ?? "",
                    "parent_directory": parentURL.path,
                    "created_path": targetURL.path,
                    "dry_run": "true"
                ]
            )
        }

        guard FileManager.default.fileExists(atPath: parentURL.path) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "The target parent directory does not exist.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "workspace_root": workspaceRoot ?? "",
                    "parent_directory": parentURL.path,
                    "created_path": targetURL.path
                ]
            )
        }

        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Created the directory \(targetURL.lastPathComponent).",
                approvalID: nil,
                artifacts: [AskCapabilityArtifact(kind: "created_directory", value: targetURL.path)],
                metadata: [
                    "workspace_root": workspaceRoot ?? "",
                    "active_task_workspace_root": workspaceRoot ?? "",
                    "parent_directory": parentURL.path,
                    "created_path": targetURL.path
                ]
            )
        } catch {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "Failed to create the requested directory.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "workspace_root": workspaceRoot ?? "",
                    "active_task_workspace_root": workspaceRoot ?? "",
                    "parent_directory": parentURL.path,
                    "created_path": targetURL.path,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private func writeFile(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let root = await resolvedWorkspaceRoot(for: request) else {
            return missingWorkspaceRoot()
        }
        guard let content = request.arguments["content"] ?? request.arguments["text"] ?? request.arguments["body"] else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No file content was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "workspace_root": root
                ]
            )
        }

        let rawPath = firstNonEmptyValue(in: request.arguments, keys: ["path", "file", "file_path"])
        guard let resolvedTarget = resolvedWritableFileTarget(
            rawPath: rawPath,
            content: content,
            request: request,
            workspaceRoot: root
        ) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No writable file path was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "workspace_root": root,
                    "requested_path": rawPath ?? ""
                ]
            )
        }
        let fileURL = resolvedTarget.fileURL

        let createParentDirectories = boolValue(
            in: request.arguments,
            keys: ["create_parent_directories", "create_parents", "mkdir_p"]
        ) ?? false
        let overwrite = boolValue(
            in: request.arguments,
            keys: ["overwrite", "overwrite_if_exists"]
        ) ?? true
        let fileManager = FileManager.default
        let fileAlreadyExists = fileManager.fileExists(atPath: fileURL.path)
        let parentDirectory = fileURL.deletingLastPathComponent()
        let contentPreview = String(content.prefix(400))
        let metadata: AskInvocationMetadata = [
            "workspace_root": root,
            "path": fileURL.path,
            "overwrite": String(overwrite),
            "create_parent_directories": String(createParentDirectories),
            "byte_count": String(content.lengthOfBytes(using: .utf8)),
            "file_already_exists": String(fileAlreadyExists)
        ].merging(resolvedTarget.repairMetadata) { _, new in new }

        if fileAlreadyExists && !overwrite {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "The requested file already exists and overwrite was not allowed.",
                approvalID: nil,
                artifacts: [],
                metadata: metadata
            )
        }

        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared to write \(fileURL.lastPathComponent) inside the workspace.",
                approvalID: nil,
                artifacts: [
                    AskCapabilityArtifact(kind: "planned_file_write_path", value: fileURL.path),
                    AskCapabilityArtifact(kind: "planned_file_write_preview", value: contentPreview)
                ],
                metadata: metadata.merging(["dry_run": "true"]) { _, new in new }
            )
        }

        if !fileManager.fileExists(atPath: parentDirectory.path) {
            guard createParentDirectories else {
                return AskCapabilityExecutionResult(
                    status: .failed,
                    summary: "The target parent directory does not exist.",
                    approvalID: nil,
                    artifacts: [],
                    metadata: metadata
                )
            }
            do {
                try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            } catch {
                return AskCapabilityExecutionResult(
                    status: .failed,
                    summary: "Failed to create the parent directory for the requested file.",
                    approvalID: nil,
                    artifacts: [],
                    metadata: metadata.merging(["error": error.localizedDescription]) { _, new in new }
                )
            }
        }

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            let artifact = AskPlaygroundStore.shared.recordArtifact(
                task: request.task,
                filePath: fileURL.path,
                content: content
            )
            var resultMetadata = metadata
            resultMetadata["active_task_workspace_root"] = root
            if let artifact {
                resultMetadata["playground_artifact_id"] = artifact.id
                resultMetadata["playground_artifact_entry_file"] = artifact.entryFile
            }
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: fileAlreadyExists
                    ? "Overwrote \(fileURL.lastPathComponent) inside the workspace."
                    : "Created \(fileURL.lastPathComponent) inside the workspace.",
                approvalID: nil,
                artifacts: [
                    AskCapabilityArtifact(kind: "written_file_path", value: fileURL.path),
                    AskCapabilityArtifact(kind: "written_file_preview", value: contentPreview)
                ],
                metadata: resultMetadata
            )
        } catch {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "Failed to write the requested workspace file.",
                approvalID: nil,
                artifacts: [],
                metadata: metadata.merging(["error": error.localizedDescription]) { _, new in new }
            )
        }
    }

    private func runShellCommand(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let root = await resolvedWorkspaceRoot(for: request) else {
            return missingWorkspaceRoot()
        }
        guard let command = firstNonEmptyValue(in: request.arguments, keys: ["command", "cmd", "shell_command"]) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No shell command was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared to run a shell command inside the workspace.",
                approvalID: nil,
                artifacts: [AskCapabilityArtifact(kind: "shell_command", value: command)],
                metadata: [
                    "workspace_root": root,
                    "active_task_workspace_root": root,
                    "command": command,
                    "dry_run": "true"
                ]
            )
        }

        let result = runProcess(
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            currentDirectory: root
        )
        let output = firstNonEmpty(result.stdout, result.stderr)
        return AskCapabilityExecutionResult(
            status: result.exitCode == 0 ? .succeeded : .failed,
            summary: result.exitCode == 0
                ? "Ran the shell command in the workspace."
                : "The shell command failed in the workspace.",
            approvalID: nil,
            artifacts: output.isEmpty ? [] : [AskCapabilityArtifact(kind: "shell_output", value: output)],
            metadata: [
                "workspace_root": root,
                "active_task_workspace_root": root,
                "command": command,
                "exit_code": String(result.exitCode)
            ]
        )
    }

    private func applyPatchPreview(request: AskCapabilityExecutionRequest) -> AskCapabilityExecutionResult {
        guard let patch = firstNonEmptyValue(in: request.arguments, keys: ["patch", "diff"]) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No patch text was provided for preview.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let preview = patchPreview(from: patch)
        return AskCapabilityExecutionResult(
            status: .succeeded,
            summary: preview.summary,
            approvalID: nil,
            artifacts: preview.artifacts,
            metadata: preview.metadata
        )
    }

    private func commitChanges(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let root = await resolvedWorkspaceRoot(for: request) else {
            return missingWorkspaceRoot()
        }
        guard let patch = firstNonEmptyValue(in: request.arguments, keys: ["patch", "diff"]) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No patch text was provided for applying changes.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        let preview = patchPreview(from: patch)
        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: preview.summary,
                approvalID: nil,
                artifacts: preview.artifacts,
                metadata: preview.metadata.merging(
                    [
                        "workspace_root": root,
                        "active_task_workspace_root": root,
                        "dry_run": "true"
                    ]
                ) { current, _ in current }
            )
        }

        let normalizedPatch = normalizedUnifiedDiff(from: patch)
        guard !normalizedPatch.isEmpty else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "The patch format is not supported for workspace apply.",
                approvalID: nil,
                artifacts: preview.artifacts,
                metadata: preview.metadata.merging(
                    [
                        "workspace_root": root,
                        "active_task_workspace_root": root
                    ]
                ) { current, _ in current }
            )
        }

        let result = runProcess(
            executable: "/usr/bin/env",
            arguments: ["git", "-C", root, "apply", "--whitespace=nowarn", "--recount", "-"],
            currentDirectory: root,
            stdin: normalizedPatch
        )
        let output = firstNonEmpty(result.stdout, result.stderr)
        let metadata = preview.metadata.merging(
            [
                "workspace_root": root,
                "active_task_workspace_root": root,
                "exit_code": String(result.exitCode)
            ]
        ) { current, _ in current }

        return AskCapabilityExecutionResult(
            status: result.exitCode == 0 ? .succeeded : .failed,
            summary: result.exitCode == 0
                ? "Applied the approved patch inside the workspace."
                : "Failed to apply the approved patch inside the workspace.",
            approvalID: nil,
            artifacts: preview.artifacts + (output.isEmpty ? [] : [AskCapabilityArtifact(kind: "patch_apply_output", value: output)]),
            metadata: metadata
        )
    }

    private func missingWorkspaceRoot() -> AskCapabilityExecutionResult {
        AskCapabilityExecutionResult(
            status: .failed,
            summary: "No active workspace root is available for this task.",
            approvalID: nil,
            artifacts: [],
            metadata: [:]
        )
    }

    private func resolvedWorkspaceRoot(for request: AskCapabilityExecutionRequest) async -> String? {
        AskWorkspaceRootSupport.normalizedWorkspaceRoot(
            firstNonEmptyValue(in: request.arguments, keys: ["workspace_root", "project_root", "cwd"])
        )
        ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(request.task.context.workspaceRootPath)
        ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(request.task.metadata["workspace_root"])
        ?? AskWorkspaceRootSupport.normalizedWorkspaceRoot(request.task.metadata["active_task_workspace_root"])
        ?? AskPlaygroundStore.shared.ensureTaskWorkspace(for: request.task)
    }

    private func resolvedWritableFileTarget(
        rawPath: String?,
        content: String,
        request: AskCapabilityExecutionRequest,
        workspaceRoot: String
    ) -> (fileURL: URL, repairMetadata: AskInvocationMetadata)? {
        if let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty,
           let fileURL = resolvedPath(rawPath, workspaceRoot: workspaceRoot) {
            return (fileURL, [:])
        }

        guard AskPlaygroundStore.shared.isInsidePlayground(path: workspaceRoot),
              let repairedPath = repairedPlaygroundWritePath(
                rawPath: rawPath,
                content: content,
                request: request
              ),
              let repairedURL = resolvedPath(repairedPath, workspaceRoot: workspaceRoot) else {
            return nil
        }

        var metadata: AskInvocationMetadata = [
            "repaired_write_path": "true",
            "inferred_path": repairedPath
        ]
        if let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty {
            metadata["requested_path"] = rawPath
        }
        return (repairedURL, metadata)
    }

    private func repairedPlaygroundWritePath(
        rawPath: String?,
        content: String,
        request: AskCapabilityExecutionRequest
    ) -> String? {
        if let rawPath,
           let candidate = sanitizedPlaygroundFileBasename(from: rawPath) {
            return candidate
        }

        let requestedFileNames = referencedFileNames(in: [request.task.objective, request.task.title].joined(separator: "\n"))
        guard let inferredExtension = inferredPlaygroundFileExtension(for: content) else {
            return requestedFileNames.count == 1 ? requestedFileNames.first : nil
        }

        if let requestedMatch = requestedFileNames.first(where: {
            $0.lowercased().hasSuffix(".\(inferredExtension)")
        }) {
            return requestedMatch
        }

        switch inferredExtension {
        case "html":
            return "index.html"
        case "css":
            return "style.css"
        case "js":
            return "script.js"
        default:
            return nil
        }
    }

    private func sanitizedPlaygroundFileBasename(from rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidatePath: String
        if let url = URL(string: trimmed), url.isFileURL {
            candidatePath = url.path
        } else {
            candidatePath = trimmed
        }

        let basename = URL(fileURLWithPath: candidatePath).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !basename.isEmpty,
              basename != ".",
              basename != "..",
              !basename.contains("/") else {
            return nil
        }
        return basename
    }

    private func referencedFileNames(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let pattern = #"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen: Set<String> = []
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let value = String(text[matchRange])
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized.lowercased()).inserted else {
                return nil
            }
            return normalized
        }
    }

    private func inferredPlaygroundFileExtension(for content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercase = trimmed.lowercased()
        if lowercase.contains("<!doctype html")
            || lowercase.contains("<html")
            || lowercase.contains("<body")
            || lowercase.contains("<head") {
            return "html"
        }

        if lowercase.contains("document.")
            || lowercase.contains("addEventListener")
            || lowercase.contains("function ")
            || lowercase.contains("const ")
            || lowercase.contains("let ")
            || lowercase.contains("=>") {
            return "js"
        }

        if lowercase.contains("@media")
            || lowercase.contains(":root")
            || lowercase.contains("body {")
            || lowercase.contains("body{")
            || lowercase.contains(".calculator")
            || lowercase.contains("#app {")
            || lowercase.contains("#app{") {
            return "css"
        }

        return nil
    }

    private func enumeratedPaths(root: String, limit: Int) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        )

        var results: [String] = []
        let skippedDirectoryNames: Set<String> = [".git", "node_modules", ".build", "DerivedData"]

        while let fileURL = enumerator?.nextObject() as? URL, results.count < limit {
            if skippedDirectoryNames.contains(fileURL.lastPathComponent) {
                enumerator?.skipDescendants()
                continue
            }

            let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            results.append(relativePath)
        }

        return results
    }

    private func resolvedPath(_ rawPath: String, workspaceRoot: String) -> URL? {
        let candidateURL: URL
        if rawPath.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: rawPath)
        } else {
            candidateURL = URL(fileURLWithPath: workspaceRoot, isDirectory: true)
                .appendingPathComponent(rawPath)
        }

        let standardizedCandidate = candidateURL.standardizedFileURL
        let standardizedRoot = URL(fileURLWithPath: workspaceRoot, isDirectory: true).standardizedFileURL
        let rootPath = standardizedRoot.path
        let candidatePath = standardizedCandidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        return standardizedCandidate
    }

    private func resolvedWorkspacePath(_ rawPath: String?, workspaceRoot: String?) -> URL? {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return workspaceRoot.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        }

        if let workspaceRoot,
           let resolved = resolvedPath(rawPath, workspaceRoot: workspaceRoot) {
            return resolved
        }

        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
        }

        return nil
    }

    private func firstNonEmptyValue(in metadata: AskInvocationMetadata, keys: [String]) -> String? {
        for key in keys {
            guard let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    private func boolValue(in metadata: AskInvocationMetadata, keys: [String]) -> Bool? {
        for key in keys {
            guard let value = metadata[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !value.isEmpty else {
                continue
            }
            switch value {
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

    private func permissionProfileValue(
        in metadata: AskInvocationMetadata,
        keys: [String]
    ) -> AskWorkspacePermissionProfile? {
        for key in keys {
            if let profile = AskWorkspacePermissionProfile.parse(metadata[key]) {
                return profile
            }
        }
        return nil
    }

    private func resolvedExecutionBudget(
        request: AskCapabilityExecutionRequest,
        fallbackMetadata: AskInvocationMetadata
    ) -> AskWorkspaceExecutionBudget {
        AskWorkspaceExecutionBudget.resolve(
            explicitProfile: permissionProfileValue(
                in: request.arguments,
                keys: ["permission_profile", "workspace_permission_profile", "execution_budget"]
            ),
            requestedWorkspaceWrites: boolValue(
                in: request.arguments,
                keys: ["grant_workspace_writes", "allow_workspace_writes", "grant_writes"]
            ),
            requestedShellExecution: boolValue(
                in: request.arguments,
                keys: ["grant_shell_execution", "allow_shell_execution", "grant_shell"]
            ),
            requestedGitWriteActions: boolValue(
                in: request.arguments,
                keys: ["grant_git_write_actions", "allow_git_write_actions", "grant_git_writes", "grant_git_write"]
            ),
            requestedNetworkAccess: boolValue(
                in: request.arguments,
                keys: ["grant_network_access", "allow_network_access", "grant_network"]
            ),
            fallback: AskWorkspaceExecutionBudget.from(metadata: fallbackMetadata)
        )
    }

    private func executionBudgetMetadata(
        root: String,
        planModeActive: Bool,
        planModeSummary: String?,
        editScopeLimited: Bool,
        budget: AskWorkspaceExecutionBudget,
        executionBudgetValue: String
    ) -> AskInvocationMetadata {
        var metadata: AskInvocationMetadata = [
            "workspace_root": root,
            "active_task_workspace_root": root,
            "plan_mode_active": planModeActive ? "true" : "false",
            "edit_scope_limited": editScopeLimited ? "true" : "false",
            "workspace_write_granted": budget.grantsWorkspaceWrites ? "true" : "false",
            "workspace_patch_granted": budget.grantsWorkspaceWrites ? "true" : "false",
            "workspace_shell_granted": budget.grantsShellExecution ? "true" : "false",
            "workspace_git_write_granted": budget.grantsGitWriteActions ? "true" : "false",
            "workspace_network_access_granted": budget.grantsNetworkAccess ? "true" : "false",
            "workspace_permission_profile": budget.permissionProfile.rawValue,
            "workspace_execution_budget": executionBudgetValue
        ]
        if let planModeSummary {
            metadata["plan_mode_summary"] = planModeSummary
        }
        return metadata
    }

    private func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return ""
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: String,
        stdin: String? = nil
    ) -> AskShellCommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        process.standardOutput = stdout
        process.standardError = stderr
        let stdinPipe = Pipe()
        if stdin != nil {
            process.standardInput = stdinPipe
        }

        do {
            try process.run()
            if let stdin,
               let data = stdin.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            if stdin != nil {
                try? stdinPipe.fileHandleForWriting.close()
            }
            process.waitUntilExit()
        } catch {
            return AskShellCommandResult(
                stdout: "",
                stderr: error.localizedDescription,
                exitCode: -1
            )
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return AskShellCommandResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private func patchPreview(from patch: String) -> (summary: String, artifacts: [AskCapabilityArtifact], metadata: AskInvocationMetadata) {
        let lines = patch.components(separatedBy: .newlines)
        var touchedFiles: [String] = []
        var addCount = 0
        var deleteCount = 0
        var updateCount = 0
        var moveTargets: [String] = []

        for line in lines {
            if let file = prefixedValue(line, prefix: "*** Add File: ") {
                touchedFiles.append(file)
                addCount += 1
            } else if let file = prefixedValue(line, prefix: "*** Update File: ") {
                touchedFiles.append(file)
                updateCount += 1
            } else if let file = prefixedValue(line, prefix: "*** Delete File: ") {
                touchedFiles.append(file)
                deleteCount += 1
            } else if let moveTo = prefixedValue(line, prefix: "*** Move to: ") {
                moveTargets.append(moveTo)
            } else if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                let rawPath = line.dropFirst(4)
                if rawPath != "/dev/null" {
                    touchedFiles.append(String(rawPath))
                }
            }
        }

        let uniqueFiles = Array(NSOrderedSet(array: touchedFiles).compactMap { $0 as? String })
        var summaryParts: [String] = []
        if addCount > 0 { summaryParts.append("add \(addCount)") }
        if updateCount > 0 { summaryParts.append("update \(updateCount)") }
        if deleteCount > 0 { summaryParts.append("delete \(deleteCount)") }
        if !moveTargets.isEmpty { summaryParts.append("move \(moveTargets.count)") }
        if summaryParts.isEmpty {
            summaryParts.append("inspect patch")
        }

        let filePreview = uniqueFiles.prefix(12).joined(separator: "\n")
        var artifacts: [AskCapabilityArtifact] = []
        if !filePreview.isEmpty {
            artifacts.append(AskCapabilityArtifact(kind: "patch_files", value: filePreview))
        }
        if !moveTargets.isEmpty {
            artifacts.append(AskCapabilityArtifact(kind: "patch_moves", value: moveTargets.prefix(12).joined(separator: "\n")))
        }

        return (
            summary: "Prepared a patch preview: \(summaryParts.joined(separator: ", ")).",
            artifacts: artifacts,
            metadata: [
                "file_count": String(uniqueFiles.count),
                "add_count": String(addCount),
                "update_count": String(updateCount),
                "delete_count": String(deleteCount),
                "move_count": String(moveTargets.count)
            ]
        )
    }

    private func prefixedValue(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedUnifiedDiff(from patch: String) -> String {
        let trimmed = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("diff --git ") || trimmed.contains("\n--- ") || trimmed.hasPrefix("--- ") {
            return trimmed + "\n"
        }
        return ""
    }
}

private struct AskShellCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}
