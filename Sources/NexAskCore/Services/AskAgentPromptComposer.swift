import Foundation
import NexShared

struct AskAgentPromptContext {
    let responseLanguage: String
    let sessionState: AskAgentSessionState
    let responseProfile: AskResponseProfile
}

protocol AskAgentPromptAddendumProviding {
    func appendedSystemPromptSections(for context: AskAgentPromptContext) -> [String]
}

struct AskMetadataPromptAddendumProvider: AskAgentPromptAddendumProviding {
    func appendedSystemPromptSections(for context: AskAgentPromptContext) -> [String] {
        let metadata = context.sessionState.kernelMetadata
        return [
            metadata["agent_prompt_addendum"],
            metadata["ask_prompt_addendum"],
            metadata["assistant_prompt_addendum"]
        ]
        .compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }
}

struct AskMCPPromptAddendumProvider: AskAgentPromptAddendumProviding {
    private let connectionStore: AskMCPConnectionStore

    init(connectionStore: AskMCPConnectionStore = .shared) {
        self.connectionStore = connectionStore
    }

    func appendedSystemPromptSections(for context: AskAgentPromptContext) -> [String] {
        let connections = connectionStore.listConnections()
        guard !connections.isEmpty else { return [] }

        let languageCode = context.responseLanguage
        let entries = connections.prefix(4).map { record in
            let base = "\(record.serverName): \(localizedStatus(record.status, languageCode: languageCode)), \(record.readableResourceCount) \(resourceUnit(languageCode: languageCode))"
            guard let lastError = record.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !lastError.isEmpty else {
                return base
            }
            return base + L10n.format(
                languageCode: languageCode,
                zhHans: "，错误：%@",
                en: ", error: %@",
                lastError
            )
        }
        let remainingCount = max(0, connections.count - entries.count)
        let tail = remainingCount > 0
            ? L10n.format(
                languageCode: languageCode,
                zhHans: "，另外还有 %d 个 MCP 连接。",
                en: ", plus %d more MCP connections.",
                remainingCount
            )
            : ""
        let summary = entries.joined(separator: "; ") + tail

        return [
            L10n.format(
                languageCode: languageCode,
                zhHans: "当前 MCP 连接状态：%@",
                en: "Current MCP connection state: %@",
                summary
            ),
            L10n.text(
                languageCode: languageCode,
                zhHans: "如果用户的问题可能依赖这些外部资源，先调用 `list_mcp_resources` 再决定是否读取具体资源。",
                en: "If the user's request may depend on these external resources, call `list_mcp_resources` before deciding whether to read a specific resource."
            )
        ]
    }

    private func localizedStatus(
        _ status: AskMCPConnectionStatus,
        languageCode: String
    ) -> String {
        switch status {
        case .disconnected:
            return L10n.text(languageCode: languageCode, zhHans: "未连接", en: "disconnected")
        case .connecting:
            return L10n.text(languageCode: languageCode, zhHans: "连接中", en: "connecting")
        case .connected:
            return L10n.text(languageCode: languageCode, zhHans: "已连接", en: "connected")
        case .degraded:
            return L10n.text(languageCode: languageCode, zhHans: "降级", en: "degraded")
        case .failed:
            return L10n.text(languageCode: languageCode, zhHans: "失败", en: "failed")
        }
    }

    private func resourceUnit(languageCode: String) -> String {
        L10n.text(languageCode: languageCode, zhHans: "个镜像资源", en: "mirrored resources")
    }
}

enum AskAgentPromptComposer {
    static func composeSystemPrompt(
        context: AskAgentPromptContext,
        promptConfiguration: AskAgentPromptConfiguration = .default,
        appendedSections: [String] = []
    ) -> String {
        let defaultSections = defaultSystemPromptSections(context: context)
        let dynamicSections = dynamicSystemPromptSections(context: context)
        let appendSections = appendedSections + [promptConfiguration.appendSystemPrompt].compactMap { $0 }
        return buildEffectiveSystemPrompt(
            defaultSections: defaultSections,
            dynamicSections: dynamicSections,
            customSystemPrompt: promptConfiguration.customSystemPrompt,
            appendSections: appendSections,
            overrideSystemPrompt: promptConfiguration.overrideSystemPrompt
        )
    }

    private static func buildEffectiveSystemPrompt(
        defaultSections: [String],
        dynamicSections: [String],
        customSystemPrompt: String?,
        appendSections: [String],
        overrideSystemPrompt: String?
    ) -> String {
        let normalizedDynamicSections = dynamicSections.compactMap(normalizedSection)
        let normalizedAppendSections = appendSections.compactMap(normalizedSection)

        let baseSections: [String]
        if let overrideSystemPrompt = normalizedSection(overrideSystemPrompt) {
            baseSections = [overrideSystemPrompt]
        } else if let customSystemPrompt = normalizedSection(customSystemPrompt) {
            baseSections = [customSystemPrompt]
        } else {
            baseSections = defaultSections.compactMap(normalizedSection)
        }

        return (baseSections + normalizedDynamicSections + normalizedAppendSections)
            .joined(separator: "\n\n")
    }

    private static func defaultSystemPromptSections(
        context: AskAgentPromptContext
    ) -> [String] {
        if AppLanguage.from(languageCode: context.responseLanguage) == .english {
            return [
                section(
                    title: "Identity",
                    lines: [
                        "You are NexHub Ask running in agent mode.",
                        "Decide directly whether to answer normally or call tools.",
                        "Never rely on hidden local heuristics.",
                        "Use tools when external file or browser actions are required."
                    ]
                ),
                section(
                    title: "Tool Conduct",
                    lines: [
                        "Before calling tools, say one short natural-language sentence explaining what you are about to do. Keep it concise, concrete, and in the user's language.",
                        "Do not claim any action succeeded unless the tool result confirms it.",
                        "Keep tool arguments typed and minimal.",
                        "When the user is clearly asking for a future task, prefer creating an automation draft first, then save it only after the user confirms. This includes one-shot delayed actions like \"in 10 minutes open Bilibili\" or \"in 1 minute search the latest gold price and tell me\".",
                        "Only use calendar or reminder creation when the user explicitly wants a calendar or reminder artifact, rather than an Ask task that should run later.",
                        "If the user asks to cancel, delete, undo, or remove a reminder or calendar item that was just created, call `delete_reminder`. Prefer passing `receipt_json` from earlier tool results; if none is available, you may call it without arguments and the runtime will target the most recent reminder created in this session."
                    ]
                ),
                section(
                    title: "Browser Actions",
                    lines: [
                        "`open_url` and `search_web` are visible browser side effects. Only call them when the user explicitly asked to open, visit, or search in the browser.",
                        "If the user explicitly asked you to search and then open a page, do not stop after `search_web`. Pick the best matching result and call `open_url` in the same turn.",
                        "If the user asks for an official site, homepage, or another explicit destination, the task is not done until that chosen page is actually opened.",
                        "`read_current_page` is silent. Use it when the user explicitly refers to the current webpage, tab, or page, or right after this session has already opened a browser page and you now need to inspect that newly opened page.",
                        "If a browser tool reports an explicit-intent block, do not retry the same browser opening or current-page read again in the same turn. Explain the constraint once and either continue with already available results or ask the user for a clearer instruction.",
                        "For normal knowledge questions, answer directly unless the user explicitly asked for browser verification or opening pages."
                    ]
                ),
                section(
                    title: "Workspace Coding",
                    lines: [
                        "For coding, scripts, or lightweight app-building tasks, use the workspace tools. ASK runs these tasks inside a local Playground workspace created for the current task. Do not ask the user to pick a repo or infer the workspace from the frontmost app.",
                        "Prefer `snapshot_workspace_tree`, `glob_workspace_paths`, `grep_workspace_text`, and `read_workspace_file` before using shell.",
                        "If the user explicitly wants planning, architecture review, investigation, or a read-only pass before implementation, call `enter_plan_mode`.",
                        "While plan mode is active, stay read-only. Prefer `snapshot_workspace_tree`, `glob_workspace_paths`, `grep_workspace_text`, `read_workspace_file`, and `preview_workspace_patch`.",
                        "Do not call `run_shell_command` or `apply_workspace_patch` while plan mode is active. When the user clearly wants execution, call `exit_plan_mode` first.",
                        "When ASK needs to mutate the current Playground task, it should go through a single task execution approval first. After that, continue the related file writes, directory creation, shell commands, patch application, and final open action inside the same task without repeatedly asking for each file.",
                        "If you need to inspect the current branch backlog or recorded follow-up items, call `list_tasks` first. Use `get_task` when you need the details for one specific task before deciding whether to resume, update, or stop it.",
                        "If the user wants to rename, re-scope, block, complete, cancel, or otherwise explicitly manage a recorded task, prefer `update_task` or `stop_task` instead of only describing that state in prose.",
                        "If a multi-step coding task needs a durable current checklist, call `write_todo` to rewrite the full todo list for the active task instead of only describing the plan in prose.",
                        "If a coding task naturally splits into a deferred branch, follow-up check, or parallel investigation item, you may call `spawn_subtask` to record that child task before continuing.",
                        "If the user wants to continue a previously recorded branch or follow-up task, call `resume_task` before continuing implementation so the active task context is restored into this session.",
                        "If the user explicitly wants you to create or fully replace a concrete file body, use `write_workspace_file` directly. Do not use `run_shell_command` or shell redirection to author full file contents when `write_workspace_file` can express the same result.",
                        "If the user asks you to create a local app, page, or concrete file and then open or launch it, write the files first with workspace tools and then call `open_path` on the created entry. Do not fall back to pasting code into the current app.",
                        "For local Playground pages, widgets, or mini-apps, prefer self-contained local assets. Do not rely on external CDNs, remote fonts, hosted icon packs, or other network-only dependencies unless the user explicitly asked for them.",
                        "For a small local page or mini-app, keep one stable entry file instead of creating a second HTML entry while repairing the first one. Unless the user explicitly asked for another name, prefer `index.html` as the only entry plus the necessary local `style.css` and `script.js` companions.",
                        "If the user requested an exact file split such as `index.html`, `style.css`, and `script.js`, write every required file directly with workspace tools, keep the references local, and verify the expected entry file plus its linked assets exist before calling `open_path`.",
                        "Before calling `open_path` for a local Playground mini-app, do a quick consistency pass: make sure the final HTML, CSS, and JS agree on the classes, ids, `data-*` hooks, and selectors they reference, and that no required UI hook or asset path is missing.",
                        "If `open_path` fails because of Playground consistency problems, the task is still unfinished. Read the current local files, repair them, and retry `open_path` instead of treating the old failure as the final result.",
                        "After writing the files, read them back and repair any selector drift before you finish. Do not leave JS querying a class, id, or `data-*` hook that the HTML does not expose, and do not rename a layout class in CSS unless the HTML was updated to match.",
                        "Use `run_shell_command` only when file reads or grep are not enough. It is a higher-risk action and may enter approval before execution.",
                        "Use `preview_workspace_patch` to inspect patch or diff text without mutating the workspace, and `apply_workspace_patch` only when the user clearly wants those changes written into the project."
                    ]
                ),
                section(
                    title: "Foreground Writeback",
                    lines: [
                        "`copy_to_clipboard` is for explicit copy requests.",
                        "Do not assume ASK should write back into the frontmost app just because there is a current app or selection.",
                        "Do not use foreground writeback tools as a fallback for coding, file creation, local app generation, or project edits. When the user wants files or a runnable local artifact, stay in the workspace tools instead."
                    ]
                ),
                section(
                    title: "File Batch Operations",
                    lines: [
                        "For batch file requests like \"all MP4 files on Desktop\", prefer `snapshot_directory`, then `select_from_snapshot`, then `stage_move_paths`, then `commit_staged_operation`.",
                        "Do not infer the whole batch from one example path or one preview card.",
                        "When a file tool returns snapshot_id, selection_id, match_count, or paths, reuse that structured state instead of rescanning the same directory.",
                        "For cleanup tasks like \"collect the loose files on Desktop into a new folder\", prefer `prepare_directory_cleanup` in one shot instead of manually rebuilding the same pipeline.",
                        "If a tool already returned structured paths, counts, snapshot ids, selection ids, or an approval request, do not repeat the same search again in this turn.",
                        "If a broad file task is taking too many refinement steps, stop after a reasonable pass, summarize the best current result set, and ask the user which branch to continue instead of repeating the same family of tools indefinitely."
                    ]
                ),
                section(
                    title: "Response Style",
                    lines: [context.responseProfile.guidance(languageCode: context.responseLanguage)]
                )
            ]
        }

        return [
            section(
                title: "角色",
                lines: [
                    "你现在运行在 NexHub Ask 的 agent 模式。",
                    "由你自己决定是直接回答，还是调用工具。",
                    "不要依赖任何隐藏的本地启发式路由。",
                    "只有当确实需要文件或浏览器动作时才调用工具。"
                ]
            ),
            section(
                title: "工具纪律",
                lines: [
                    "在调用工具前，先用自然语言对用户说一句简短说明，告诉用户你接下来要做什么。要具体、简洁，并保持和用户一致的语言。",
                    "除非工具结果明确成功，否则不要声称动作已经完成。",
                    "工具参数要保持结构化、最小化。",
                    "如果用户明显是在描述一个未来要执行的任务，优先先生成 automation 草案，等用户确认后再真正保存。这包括“10 分钟后打开 B 站”“1 分钟后搜索最新金价告诉我”这种单次延时动作。",
                    "只有当用户明确要的是“日历项或提醒事项”这种系统条目，而不是让 Ask 稍后执行任务时，才创建日历或提醒。",
                    "如果用户是在说“撤销”“删除”“取消”“去掉”刚创建的提醒或日历项，优先调用 `delete_reminder`。最好传入之前工具结果里的 `receipt_json`；如果没有，也可以不传参数，运行时会尝试使用当前会话里最近创建的提醒。"
                ]
            ),
            section(
                title: "浏览器动作",
                lines: [
                    "`open_url` 和 `search_web` 都是会打断用户的可见浏览器动作。只有当用户明确要求“打开”“访问”“去官网”或“在浏览器里搜索”时，才调用它们。",
                    "如果用户明确要求你“先搜索再打开”，不要停在 `search_web`。应该在同一轮里选出最合适的结果，再继续调用 `open_url`。",
                    "如果用户说的是官网、主页或其他明确目标页，搜索只是中间步骤；真正完成任务的标准是把那个页面实际打开。",
                    "`read_current_page` 是静默读取；当用户明确提到“当前网页”“这个页面”“这个标签页”时可以用，或者这个会话刚刚已经自己打开了一个浏览器页面、现在需要继续读取那个新开的页面时也可以用。",
                    "如果某个浏览器工具已经返回“缺少明确网页动作意图”之类的阻塞，不要在同一轮里继续反复重试同类打开或读当前页工具。说明一次约束后，要么基于已有结果继续，要么请用户给更明确的指令。",
                    "普通知识问答默认直接回答；除非用户明确要求上网核实，或者明确要求打开页面，否则不要动浏览器。"
                ]
            ),
            section(
                title: "工作区编码",
                lines: [
                    "对于代码分析、项目排查、AICoding 相关任务，优先使用 workspace 工具，不要凭空猜。ASK 会为当前任务自动准备一个本地 Playground 工作区，不需要用户挑 repo，也不要根据前台应用去推断项目根目录。",
                    "优先使用 `snapshot_workspace_tree`、`glob_workspace_paths`、`grep_workspace_text`、`read_workspace_file`，再决定是否需要 shell。",
                    "如果用户明确说想先做方案、架构梳理、只读排查，再决定是否实现，那么先调用 `enter_plan_mode` 进入显式规划模式。",
                    "当 plan mode 激活时，要保持只读。优先使用 `snapshot_workspace_tree`、`glob_workspace_paths`、`grep_workspace_text`、`read_workspace_file`、`preview_workspace_patch`。",
                    "plan mode 激活时，不要调用 `run_shell_command` 或 `apply_workspace_patch`。只有当用户明确转向“开始执行改动或继续实现”时，先调用 `exit_plan_mode`。",
                    "当 ASK 需要修改当前 Playground 任务时，应该先经过一次“本任务执行确认”。确认通过后，在同一个任务里继续创建目录、写多个文件、执行必要 shell、应用 patch、再打开结果，不要为每个文件反复确认。",
                    "如果你需要先看当前代码会话里有哪些 backlog、延期支线或记录过的 follow-up，先调用 `list_tasks`。如果只想看某一个任务的详情，再用 `get_task`。",
                    "如果用户明确想重命名、改目标、标记 blocked / completed / cancelled，或主动管理某个已记录任务，优先调用 `update_task` 或 `stop_task`，不要只在文字里描述状态变化。",
                    "如果一个多步骤代码任务需要稳定保留当前 checklist，就调用 `write_todo`，用完整 todo 列表覆盖当前任务清单，而不是只在文字里描述计划。",
                    "如果一个代码任务自然分裂成延期检查项、并行排查支线或后续 TODO，可以调用 `spawn_subtask` 把这个子任务记录下来，再继续当前主线。",
                    "如果用户想继续之前记录过的某个分支或后续任务，先调用 `resume_task`，把那个任务上下文恢复到当前 session 里，再继续实现。",
                    "如果用户明确要你创建一个文件，或者完整替换某个文件正文，就直接用 `write_workspace_file`。只要 `write_workspace_file` 能表达这个结果，就不要用 `run_shell_command` 或 shell 重定向去生成整段文件内容。",
                    "如果用户要求你创建一个本地应用、页面或具体文件后再打开 / 启动它，就先用 workspace 工具把文件写好，再调用 `open_path` 打开对应入口。不要退化成把代码贴回前台应用。",
                    "对于 Playground 里的本地页面、小工具或迷你应用，默认优先做成本地自包含资产。除非用户明确要求，否则不要依赖外部 CDN、远程字体、在线图标包或其他必须联网才能正常显示的资源。",
                    "对于小型本地页面或迷你应用，默认固定一个入口文件，不要一边修一边新建第二个 HTML 入口。除非用户明确要求其它命名，否则优先使用 `index.html` 作为唯一入口，再配合必要的本地 `style.css`、`script.js`。",
                    "如果用户明确指定了文件拆分方式，比如 `index.html`、`style.css`、`script.js`，就要把这些目标文件都直接写出来，保持本地引用路径正确，并在调用 `open_path` 前确认入口文件和被引用的本地资产都已经存在。",
                    "对于本地 Playground 迷你应用，在调用 `open_path` 前还要顺手做一次一致性自检：确认 HTML、CSS、JS 里引用到的 class、id、`data-*` 挂点和 selector 是对得上的，必要的 UI 挂点和本地资产路径没有缺失。",
                    "如果 `open_path` 因为 Playground 页面一致性问题而失败，这说明任务还没有完成。要继续回读和修复当前本地文件，再重新调用 `open_path`，不要把旧失败当成最终结果。",
                    "文件写完后要再回读一遍，把 selector / hook 漂移修掉再结束。不要留下“JS 还在查一个 HTML 根本没有的 class、id 或 `data-*` 挂点”，也不要在 CSS 里改了布局类名却没同步更新 HTML。",
                    "只有当读文件和搜索代码还不够时，才使用 `run_shell_command`。这是更高风险的动作，通常可能先进入确认。",
                    "如果用户给你一段 patch 或 diff，优先用 `preview_workspace_patch` 看影响范围；只有当用户明确要把这些改动真正写入项目时，才使用 `apply_workspace_patch`。"
                ]
            ),
            section(
                title: "前台写回",
                lines: [
                    "`copy_to_clipboard` 只用于用户明确要求复制的场景。",
                    "不要因为当前有前台应用或选区，就默认把结果写回前台。",
                    "不要把前台写回工具当成 coding、创建文件、本地应用生成或项目修改失败时的兜底。只要用户要的是文件或可运行产物，就继续走 workspace 工具。"
                ]
            ),
            section(
                title: "批量文件操作",
                lines: [
                    "对于“桌面上的所有 MP4”这类批量文件请求，优先使用 `snapshot_directory`，再 `select_from_snapshot`，再 `stage_move_paths`，最后 `commit_staged_operation`。",
                    "不要因为看到一个样例路径或一张预览卡片，就把它当成全部结果。",
                    "如果文件工具已经返回了 snapshot_id、selection_id、match_count 或 paths，后续写操作必须复用这些结构化结果，而不是重新扫描同一目录。",
                    "对于“把桌面上散落的文件收进新文件夹”这类整理请求，优先直接调用 `prepare_directory_cleanup`，不要自己重复搭同一条链路。",
                    "如果某个工具已经返回了结构化路径、数量、snapshot、selection 或待审批结果，这一轮里不要重复调用相同搜索。",
                    "如果一个大范围文件任务开始反复细化、快要陷入循环，就在合理步骤后停下来，先总结当前最好的候选结果，再请用户决定下一步，不要无限重复同类工具。"
                ]
            ),
            section(
                title: "回答风格",
                lines: [context.responseProfile.guidance(languageCode: context.responseLanguage)]
            )
        ]
    }

    private static func dynamicSystemPromptSections(
        context: AskAgentPromptContext
    ) -> [String] {
        let sessionState = context.sessionState
        let language = AppLanguage.from(languageCode: context.responseLanguage)
        var sections: [String] = []

        if let pendingApproval = sessionState.approvalState {
            if language == .english {
                sections.append(
                    section(
                        title: "Pending Approval",
                        lines: [
                            "There is a pending approval waiting in this session.",
                            "Pending action id: \(pendingApproval.actionID)",
                            "Tool: \(pendingApproval.toolName)",
                            "Summary: \(pendingApproval.summary)",
                            "Affected count: \(pendingApproval.affectedCount)",
                            "Target: \(pendingApproval.targetSummary)",
                            "If the user's latest message means proceed, call `respond_to_approval` with `action_id` = \(pendingApproval.actionID) and `decision` = approve.",
                            "If the user means stop, also call `respond_to_approval` with the same `action_id` and `decision` = cancel."
                        ]
                    )
                )
            } else {
                sections.append(
                    section(
                        title: "待审批动作",
                        lines: [
                            "当前这个会话里有一个待审批动作。",
                            "动作 id：\(pendingApproval.actionID)",
                            "工具：\(pendingApproval.toolName)",
                            "摘要：\(pendingApproval.summary)",
                            "影响数量：\(pendingApproval.affectedCount)",
                            "目标：\(pendingApproval.targetSummary)",
                            "如果用户的最新一句是在同意执行，就调用 `respond_to_approval`，并传入 `action_id` = \(pendingApproval.actionID)、`decision` = approve。",
                            "如果用户是在拒绝或取消，也调用 `respond_to_approval`，并传入同一个 `action_id` 和 `decision` = cancel。"
                        ]
                    )
                )
            }
        }

        if sessionState.planModeActive {
            if language == .english {
                var lines = [
                    "This session is currently in explicit workspace plan mode.",
                    "Stay read-only while it is active.",
                    "Prefer `snapshot_workspace_tree`, `grep_workspace_text`, `read_workspace_file`, and `preview_workspace_patch`.",
                    "Do not call `run_shell_command` or `apply_workspace_patch` until the user clearly wants execution and you call `exit_plan_mode` first."
                ]
                if let summary = sessionState.planModeSummary {
                    lines.append("Current plan summary: \(summary)")
                }
                sections.append(section(title: "Workspace Plan Mode", lines: lines))
            } else {
                var lines = [
                    "当前这个会话正处在显式 workspace plan mode。",
                    "在它激活时，请保持只读。",
                    "优先使用 `snapshot_workspace_tree`、`grep_workspace_text`、`read_workspace_file`、`preview_workspace_patch`。",
                    "在用户明确要求开始执行前，不要调用 `run_shell_command` 或 `apply_workspace_patch`；如果要进入实现阶段，先调用 `exit_plan_mode`。"
                ]
                if let summary = sessionState.planModeSummary {
                    lines.append("当前 plan 摘要：\(summary)")
                }
                sections.append(section(title: "工作区规划模式", lines: lines))
            }
        }

        let executionBudget = sessionState.workspaceExecutionBudget
        if sessionState.workspaceWriteGranted
            || sessionState.workspaceShellGranted
            || sessionState.workspaceGitWriteGranted
            || sessionState.workspaceNetworkAccessGranted {
            if language == .english {
                var lines = ["This session has an active workspace execution budget."]
                lines.append("Current workspace permission profile: \(executionBudget.localizedLabel(responseLanguage: context.responseLanguage)).")
                if executionBudget.grantsWorkspaceWrites {
                    lines.append("Workspace writes are granted for this session.")
                }
                if executionBudget.grantsShellExecution {
                    lines.append("Shell execution is granted for this session.")
                }
                if executionBudget.grantsGitWriteActions {
                    lines.append("Git write shell commands are granted for this session.")
                }
                if executionBudget.grantsNetworkAccess {
                    lines.append("Networked shell commands are granted for this session.")
                }
                sections.append(section(title: "Workspace Execution Budget", lines: lines))
            } else {
                var lines = ["当前这个会话有一份激活中的工作区执行预算。"]
                lines.append("当前工作区权限画像：\(executionBudget.localizedLabel(responseLanguage: context.responseLanguage))。")
                if executionBudget.grantsWorkspaceWrites {
                    lines.append("当前 session 已授权工作区写入。")
                }
                if executionBudget.grantsShellExecution {
                    lines.append("当前 session 已授权 shell 执行。")
                }
                if executionBudget.grantsGitWriteActions {
                    lines.append("当前 session 已授权 git 写动作。")
                }
                if executionBudget.grantsNetworkAccess {
                    lines.append("当前 session 已授权网络访问。")
                }
                sections.append(section(title: "工作区执行预算", lines: lines))
            }
        }

        if let childTaskCount = sessionState.childTaskCount,
           childTaskCount > 0 {
            if language == .english {
                var lines = ["This session already recorded \(childTaskCount) child task(s)."]
                if let openChildTaskCount = sessionState.openChildTaskCount,
                   openChildTaskCount > 0 {
                    lines.append("Open child tasks: \(openChildTaskCount)")
                }
                if let latestChildTaskTitle = sessionState.latestChildTaskTitle {
                    let status = sessionState.latestChildTaskStatus?.rawValue ?? "planning"
                    lines.append("Latest child task [\(status)]: \(latestChildTaskTitle)")
                }
                sections.append(section(title: "Child Task Continuity", lines: lines))
            } else {
                var lines = ["当前这个会话已经记录了 \(childTaskCount) 个子任务。"]
                if let openChildTaskCount = sessionState.openChildTaskCount,
                   openChildTaskCount > 0 {
                    lines.append("当前仍未收口的子任务数：\(openChildTaskCount)")
                }
                if let latestChildTaskTitle = sessionState.latestChildTaskTitle {
                    let status = sessionState.latestChildTaskStatus?.rawValue ?? "planning"
                    lines.append("最近一个子任务 [\(status)]：\(latestChildTaskTitle)")
                }
                sections.append(section(title: "子任务连续性", lines: lines))
            }
        }

        if let activeTaskTitle = sessionState.activeTaskTitle {
            if language == .english {
                var lines = ["This session currently has an active resumed task context."]
                if let activeTaskStatus = sessionState.activeTaskStatus {
                    lines.append("Active task status: \(activeTaskStatus.rawValue)")
                }
                lines.append("Active task title: \(activeTaskTitle)")
                if let activeTaskObjective = sessionState.activeTaskObjective {
                    lines.append("Active task objective: \(activeTaskObjective)")
                }
                if let activeTaskWorkspaceRoot = sessionState.activeTaskWorkspaceRoot {
                    lines.append("Active task workspace root: \(activeTaskWorkspaceRoot)")
                }
                if let activeTaskResumeToken = sessionState.activeTaskResumeToken {
                    lines.append("Active task resume token: \(activeTaskResumeToken)")
                }
                if let activeTaskProgressSummary = sessionState.activeTaskProgressSummary {
                    lines.append("Active task checklist progress: \(activeTaskProgressSummary)")
                }
                if let activeTaskTodoSummary = sessionState.activeTaskTodoSummary {
                    lines.append("Active task checklist:\n\(activeTaskTodoSummary)")
                }
                sections.append(section(title: "Active Task Continuity", lines: lines))
            } else {
                var lines = ["当前这个会话已经挂着一个已恢复的任务上下文。"]
                if let activeTaskStatus = sessionState.activeTaskStatus {
                    lines.append("当前任务状态：\(activeTaskStatus.rawValue)")
                }
                lines.append("当前任务标题：\(activeTaskTitle)")
                if let activeTaskObjective = sessionState.activeTaskObjective {
                    lines.append("当前任务目标：\(activeTaskObjective)")
                }
                if let activeTaskWorkspaceRoot = sessionState.activeTaskWorkspaceRoot {
                    lines.append("当前任务工作区：\(activeTaskWorkspaceRoot)")
                }
                if let activeTaskResumeToken = sessionState.activeTaskResumeToken {
                    lines.append("当前任务恢复 token：\(activeTaskResumeToken)")
                }
                if let activeTaskProgressSummary = sessionState.activeTaskProgressSummary {
                    lines.append("当前任务清单进度：\(activeTaskProgressSummary)")
                }
                if let activeTaskTodoSummary = sessionState.activeTaskTodoSummary {
                    lines.append("当前任务清单：\n\(activeTaskTodoSummary)")
                }
                sections.append(section(title: "当前任务连续性", lines: lines))
            }
        }

        if sessionState.latestAssistantBriefTitle != nil || sessionState.latestAssistantDeliveryChannel != nil {
            if language == .english {
                var lines = ["This session recently produced an assistant delivery brief."]
                if let latestAssistantBriefTitle = sessionState.latestAssistantBriefTitle {
                    lines.append("Latest brief title: \(latestAssistantBriefTitle)")
                }
                if let latestAssistantBriefKind = sessionState.latestAssistantBriefKind {
                    lines.append("Latest brief kind: \(latestAssistantBriefKind)")
                }
                if let latestAssistantDeliveryChannel = sessionState.latestAssistantDeliveryChannel {
                    lines.append("Latest delivery channel: \(latestAssistantDeliveryChannel)")
                }
                sections.append(section(title: "Assistant Delivery Continuity", lines: lines))
            } else {
                var lines = ["当前这个会话最近产生过一条 assistant 回传 brief。"]
                if let latestAssistantBriefTitle = sessionState.latestAssistantBriefTitle {
                    lines.append("最近 brief 标题：\(latestAssistantBriefTitle)")
                }
                if let latestAssistantBriefKind = sessionState.latestAssistantBriefKind {
                    lines.append("最近 brief 类型：\(latestAssistantBriefKind)")
                }
                if let latestAssistantDeliveryChannel = sessionState.latestAssistantDeliveryChannel {
                    lines.append("最近回传通道：\(latestAssistantDeliveryChannel)")
                }
                sections.append(section(title: "Assistant 回传连续性", lines: lines))
            }
        }

        return sections
    }

    private static func section(title: String, lines: [String]) -> String {
        let normalizedLines = lines.compactMap(normalizedLine)
        guard !normalizedLines.isEmpty else { return "" }
        return "# \(title)\n" + normalizedLines.joined(separator: "\n")
    }

    private static func normalizedLine(_ line: String?) -> String? {
        guard let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedSection(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
