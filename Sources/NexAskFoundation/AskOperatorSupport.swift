import Foundation

package enum AskOperatorScope: String, Equatable {
    case file
    case web
    case mixed
}

package struct AskOperatorDirective: Equatable {
    package let scope: AskOperatorScope
    package let toolFamilies: [String]

    package init(scope: AskOperatorScope, toolFamilies: [String]) {
        self.scope = scope
        self.toolFamilies = toolFamilies
    }
}

package enum AskOperatorSupport {
    private static let actionTerms: [String] = [
        "open", "search", "find", "look up", "browse", "visit", "click",
        "move", "copy", "rename", "delete", "remove", "organize", "create",
        "read", "summarize", "list", "show",
        "打开", "搜索", "查找", "查一下", "找一下", "找", "浏览", "访问", "点击",
        "移动", "复制", "重命名", "删除", "移除", "整理", "创建", "新建",
        "读取", "读一下", "总结", "概括", "列出", "显示"
    ]

    private static let fileTerms: [String] = [
        "file", "files", "folder", "folders", "directory", "desktop", "finder", "download",
        "文件", "文件夹", "目录", "桌面", "访达", "finder", "下载"
    ]

    private static let webTerms: [String] = [
        "web", "website", "browser", "chrome", "safari", "edge", "tab", "page", "url", "link", "google",
        "网页", "网站", "浏览器", "标签页", "页面", "链接", "网址", "谷歌"
    ]

    private static let conceptualTerms: [String] = [
        "why", "what is", "how does", "architecture", "strategy", "spec", "design", "feasibility",
        "为什么", "是什么", "怎么实现", "架构", "方案", "设计", "可行性", "评估"
    ]

    package static func directive(for messages: [AskMessage]) -> AskOperatorDirective? {
        guard let latestUserMessage = latestUserMessage(in: messages) else {
            return nil
        }

        let normalized = normalize(latestUserMessage)
        guard !normalized.isEmpty else { return nil }
        guard containsAny(normalized, in: actionTerms) else { return nil }
        guard !containsAny(normalized, in: conceptualTerms) else { return nil }

        let mentionsFile = containsAny(normalized, in: fileTerms)
        let mentionsWeb = containsAny(normalized, in: webTerms)

        switch (mentionsFile, mentionsWeb) {
        case (true, true):
            return AskOperatorDirective(
                scope: .mixed,
                toolFamilies: ["file_read", "file_write", "finder_control", "browser_open", "browser_search", "page_read"]
            )
        case (true, false):
            return AskOperatorDirective(
                scope: .file,
                toolFamilies: ["file_read", "file_write", "finder_control", "app_launch"]
            )
        case (false, true):
            return AskOperatorDirective(
                scope: .web,
                toolFamilies: ["browser_open", "browser_search", "page_read"]
            )
        case (false, false):
            return nil
        }
    }

    package static func augmentedMessages(
        from messages: [AskMessage],
        metadata: AskSessionMetadata,
        responseLanguage: String
    ) -> (messages: [AskMessage], directive: AskOperatorDirective?) {
        guard let directive = directive(for: messages) else {
            return (messages, nil)
        }

        let prompt = operatorSystemPrompt(
            directive: directive,
            metadata: metadata,
            responseLanguage: responseLanguage
        )

        var augmented: [AskMessage] = [.init(role: .system, content: prompt)]
        augmented.append(contentsOf: messages)
        return (augmented, directive)
    }

    private static func latestUserMessage(in messages: [AskMessage]) -> String? {
        messages.last(where: { $0.role == .user })?.content
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAny(_ haystack: String, in needles: [String]) -> Bool {
        needles.contains(where: { haystack.contains($0) })
    }

    private static func operatorSystemPrompt(
        directive: AskOperatorDirective,
        metadata: AskSessionMetadata,
        responseLanguage: String
    ) -> String {
        let scopeLabel = scopeLabel(for: directive.scope, languageCode: responseLanguage)
        let appHint = metadata.sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appLine: String
        if let appHint, !appHint.isEmpty {
            appLine = AskRuntimeLocalization.format(
                languageCode: responseLanguage,
                zhHans: "当前 Ask 会话来自 %@。",
                en: "This Ask session originated from %@.",
                appHint
            )
        } else {
            appLine = AskRuntimeLocalization.text(
                languageCode: responseLanguage,
                zhHans: "当前 Ask 会话没有稳定的来源应用提示。",
                en: "This Ask session does not have a stable source-app hint."
            )
        }

        let toolLine = directive.toolFamilies.joined(separator: ", ")
        return AskRuntimeLocalization.format(
            languageCode: responseLanguage,
            zhHans: """
            这是一个 Ask 内的 operator 任务草案阶段。
            任务范围限定为：%@。
            %@
            可预留的工具族：%@。

            请遵守以下规则：
            1. 不要声称任何外部动作已经执行完成。
            2. 把用户请求整理成简洁、可执行的步骤计划。
            3. 如果请求有破坏性、批量移动、删除、覆盖重命名等风险，先要求确认。
            4. 如果缺少关键目标，比如路径、文件名、筛选条件或目标网站，先问一个最小澄清问题。
            5. 优先考虑结构化文件操作和浏览器操作，不要默认走像素级点击。
            """,
            en: """
            This Ask turn is in the operator planning stage.
            Task scope is limited to: %@.
            %@
            Reserved tool families: %@.

            Follow these rules:
            1. Do not claim that any external action has already been completed.
            2. Turn the user's request into a concise execution-ready plan.
            3. Ask for confirmation before destructive, batch-move, delete, or overwrite actions.
            4. If key targets are missing, ask one minimal clarifying question first.
            5. Prefer structured file and browser actions over pixel-level clicking.
            """,
            scopeLabel,
            appLine,
            toolLine
        )
    }

    private static func scopeLabel(for scope: AskOperatorScope, languageCode: String) -> String {
        switch scope {
        case .file:
            return AskRuntimeLocalization.text(languageCode: languageCode, zhHans: "文件操作", en: "file operations")
        case .web:
            return AskRuntimeLocalization.text(languageCode: languageCode, zhHans: "网页操作", en: "web operations")
        case .mixed:
            return AskRuntimeLocalization.text(languageCode: languageCode, zhHans: "文件与网页联合操作", en: "combined file and web operations")
        }
    }
}
