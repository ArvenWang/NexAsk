import Foundation

package enum AskCapabilityCatalog {
    package static func defaultCatalog() -> [AskExecutionMode: [AskCapabilityDefinition]] {
        [
            .interactive: interactiveCapabilities(),
            .automate: automateCapabilities()
        ]
    }

    private static func interactiveCapabilities() -> [AskCapabilityDefinition] {
        [
            capability(
                id: "desktop.snapshot_directory",
                domain: .desktop,
                summary: "Inspect local files or directories around the current task.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "desktop.stage_move_operation",
                domain: .desktop,
                summary: "Prepare a local file move plan without executing it yet.",
                risk: .reversible,
                visibility: .silent,
                unattended: true,
                preview: true
            ),
            capability(
                id: "desktop.cancel_move_operation",
                domain: .desktop,
                summary: "Cancel a previously staged local file move plan.",
                risk: .reversible,
                visibility: .silent,
                unattended: false,
                rollback: true
            ),
            capability(
                id: "desktop.commit_move_operation",
                domain: .desktop,
                summary: "Execute an approved local file move plan.",
                risk: .userVisible,
                visibility: .userVisible,
                unattended: false
            ),
            capability(
                id: "desktop.open_path",
                domain: .desktop,
                summary: "Open a local file or folder.",
                risk: .userVisible,
                visibility: .userVisible,
                unattended: false
            ),
            capability(
                id: "desktop.reveal_in_finder",
                domain: .desktop,
                summary: "Reveal a local path in Finder.",
                risk: .userVisible,
                visibility: .userVisible,
                unattended: false
            ),
            capability(
                id: "browser.open_url",
                domain: .browser,
                summary: "Open a URL in the browser.",
                risk: .userVisible,
                visibility: .userVisible,
                unattended: false
            ),
            capability(
                id: "browser.search_web",
                domain: .browser,
                summary: "Search the web and optionally surface the best candidate.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "browser.read_current_page",
                domain: .browser,
                summary: "Read, summarize, or extract links from the current browser page on demand.",
                risk: .observational,
                visibility: .silent,
                unattended: false
            ),
            capability(
                id: "app.focus_application",
                domain: .appControl,
                summary: "Focus or switch to a target application.",
                risk: .userVisible,
                visibility: .userVisible,
                unattended: false
            ),
            capability(
                id: "app.copy_to_clipboard",
                domain: .appControl,
                summary: "Copy a generated result into the system clipboard.",
                risk: .reversible,
                visibility: .userVisible,
                unattended: false
            ),
            capability(
                id: "knowledge.search",
                domain: .knowledge,
                summary: "Search previously collected personal and workspace knowledge.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "knowledge.save_note",
                domain: .knowledge,
                summary: "Persist a useful result or memory for future ASK runs.",
                risk: .reversible,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "time.preview_automation_job",
                domain: .time,
                summary: "Preview a scheduled or delayed automation job.",
                risk: .reversible,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "time.create_automation_job",
                domain: .time,
                summary: "Create or update a scheduled automation job.",
                risk: .reversible,
                visibility: .silent,
                unattended: true,
                preview: true,
                rollback: true
            ),
            capability(
                id: "workspace.snapshot_tree",
                domain: .workspace,
                summary: "Enumerate files and directories inside the current Playground task.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "workspace.glob_paths",
                domain: .workspace,
                summary: "Enumerate Playground files that match a glob pattern.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "workspace.grep_text",
                domain: .workspace,
                summary: "Search code or text inside the current Playground task.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "workspace.read_file",
                domain: .workspace,
                summary: "Read files from the current Playground task.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "workspace.create_directory",
                domain: .workspace,
                summary: "Create a directory inside the current Playground task.",
                risk: .reversible,
                visibility: .silent,
                unattended: false,
                preview: true,
                rollback: true
            ),
            capability(
                id: "workspace.write_file",
                domain: .workspace,
                summary: "Create or overwrite a text file inside the current Playground task.",
                risk: .destructive,
                visibility: .userVisible,
                unattended: false,
                preview: true,
                rollback: true
            ),
            capability(
                id: "workspace.run_shell_command",
                domain: .workspace,
                summary: "Run a local shell command inside the current Playground task.",
                risk: .privileged,
                visibility: .userVisible,
                unattended: false,
                preview: true
            ),
            capability(
                id: "workspace.apply_patch_preview",
                domain: .workspace,
                summary: "Prepare a patch preview without mutating the Playground yet.",
                risk: .reversible,
                visibility: .silent,
                unattended: false,
                preview: true,
                rollback: true
            ),
            capability(
                id: "workspace.commit_changes",
                domain: .workspace,
                summary: "Apply approved changes inside the current Playground task.",
                risk: .destructive,
                visibility: .userVisible,
                unattended: false,
                rollback: true
            ),
            capability(
                id: "workspace.enter_plan_mode",
                domain: .workspace,
                summary: "Switch the coding agent into read-only planning mode.",
                risk: .reversible,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "workspace.exit_plan_mode",
                domain: .workspace,
                summary: "Leave read-only planning mode and return to executable coding mode.",
                risk: .reversible,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "workspace.set_execution_budget",
                domain: .workspace,
                summary: "Update the current task execution grant for writes or shell commands.",
                risk: .reversible,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "system.prepare_assistant_brief",
                domain: .system,
                summary: "Prepare a reusable assistant follow-up brief for later delivery.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "system.deliver_notification",
                domain: .system,
                summary: "Deliver a follow-up result through a local system notification.",
                risk: .reversible,
                visibility: .background,
                unattended: true
            ),
            capability(
                id: "system.deliver_inbox_item",
                domain: .system,
                summary: "Deliver a follow-up result into the local Ask inbox.",
                risk: .reversible,
                visibility: .background,
                unattended: true
            ),
            capability(
                id: "system.list_tasks",
                domain: .system,
                summary: "List recorded tasks and child tasks for the current session.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "system.get_task",
                domain: .system,
                summary: "Load the details for a recorded task or child task in the current session.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "system.update_task",
                domain: .system,
                summary: "Update the title, objective, or status of a recorded task.",
                risk: .reversible,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "system.stop_task",
                domain: .system,
                summary: "Stop or cancel a recorded task or child task.",
                risk: .reversible,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "system.resume_task",
                domain: .system,
                summary: "Restore a previously recorded task context into the current session.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "system.write_todo",
                domain: .system,
                summary: "Persist the current task checklist and progress breakdown for later continuity.",
                risk: .reversible,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "system.spawn_subtask",
                domain: .system,
                summary: "Record a focused child task for the current session.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "system.respond_to_approval",
                domain: .system,
                summary: "Resolve a pending approval request for a task action.",
                risk: .reversible,
                visibility: .silent,
                unattended: false
            )
        ]
    }

    private static func automateCapabilities() -> [AskCapabilityDefinition] {
        [
            capability(
                id: "time.preview_automation_job",
                domain: .time,
                summary: "Parse natural language into a delayed or recurring job draft.",
                risk: .reversible,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "time.create_automation_job",
                domain: .time,
                summary: "Create or update a scheduled agent job.",
                risk: .reversible,
                visibility: .silent,
                unattended: true,
                preview: true,
                rollback: true
            ),
            capability(
                id: "system.prepare_assistant_brief",
                domain: .system,
                summary: "Prepare a reusable assistant brief envelope for inbox, notification, or follow-up delivery.",
                risk: .observational,
                visibility: .silent,
                unattended: true
            ),
            capability(
                id: "system.deliver_notification",
                domain: .system,
                summary: "Deliver results back to a local system notification.",
                risk: .reversible,
                visibility: .background,
                unattended: true
            ),
            capability(
                id: "system.deliver_inbox_item",
                domain: .system,
                summary: "Deliver results back into the local Ask inbox.",
                risk: .reversible,
                visibility: .background,
                unattended: true
            ),
            capability(
                id: "knowledge.save_note",
                domain: .knowledge,
                summary: "Persist run results into knowledge or a durable note.",
                risk: .reversible,
                visibility: .silent,
                unattended: true
            )
        ]
    }

    private static func capability(
        id: AskCapabilityID,
        domain: AskCapabilityDomain,
        summary: String,
        risk: AskRiskClass,
        visibility: AskVisibilityClass,
        unattended: Bool,
        requiredContextKeys: [String] = [],
        preview: Bool = false,
        rollback: Bool = false
    ) -> AskCapabilityDefinition {
        AskCapabilityDefinition(
            id: id,
            domain: domain,
            summary: summary,
            riskClass: risk,
            visibilityClass: visibility,
            supportsUnattendedExecution: unattended,
            supportsPreview: preview,
            supportsRollback: rollback,
            requiredContextKeys: requiredContextKeys
        )
    }
}
