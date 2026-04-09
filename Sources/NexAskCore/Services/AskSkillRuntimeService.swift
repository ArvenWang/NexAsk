import Foundation
import NexShared

private enum AskServiceFailureKind {
    case authentication
    case contextLimit
    case rateLimited
    case network
    case gatewayTimeout
    case unavailable
}

final class AskSkillRuntimeService {
    static let shared = AskSkillRuntimeService()

    private let knowledgeBaseStore: ReplyKnowledgeBaseStore
    private let session: URLSession
    private let diagnosticsLogger: DiagnosticsLogger
    private let askAgentRuntime: AskAgentRuntimeProviding
    private let mcpResourceCatalog: any AskMCPResourceCatalogProviding
    private let aiConfigurationProvider: () async throws -> LLMRequestConfiguration

    init(
        knowledgeBaseStore: ReplyKnowledgeBaseStore = .shared,
        session: URLSession = .shared,
        diagnosticsLogger: DiagnosticsLogger = .shared,
        askOperatorRuntime: AskOperatorRuntimeProviding = AskOperatorRuntime(),
        askAgentRuntime: AskAgentRuntimeProviding? = nil,
        aiConfigurationProvider: @escaping () async throws -> LLMRequestConfiguration = {
            try await ManagedAIConfigurationService.shared.configuration()
        }
    ) {
        self.knowledgeBaseStore = knowledgeBaseStore
        self.session = session
        self.diagnosticsLogger = diagnosticsLogger
        let mcpResourceCatalog =
            (askOperatorRuntime as? AskMCPResourceCatalogBacked)?.mcpResourceCatalog
            ?? AskSharedMCPResourceCatalog.shared
        self.mcpResourceCatalog = mcpResourceCatalog
        let mcpConnectionStore =
            (askOperatorRuntime as? AskMCPConnectionStoreBacked)?.mcpConnectionStore
            ?? AskMCPConnectionStore.shared
        if let askAgentRuntime {
            self.askAgentRuntime = askAgentRuntime
        } else if let toolExecutor = askOperatorRuntime as? AskToolExecuting,
                  let toolProvider = askOperatorRuntime as? AskToolProviding {
            self.askAgentRuntime = AskAgentRuntime(
                agentLLMClient: AgentLLMClient(session: session),
                toolRegistry: AskToolRegistry(
                    providers: [
                        toolProvider,
                        AskMCPToolProvider(
                            resourceCatalog: mcpResourceCatalog,
                            connectionStore: mcpConnectionStore
                        ),
                        AskLocalToolProvider()
                    ]
                ),
                toolExecutor: toolExecutor,
                diagnosticsLogger: diagnosticsLogger,
                systemPromptAddendumProviders: [
                    AskMetadataPromptAddendumProvider(),
                    AskMCPPromptAddendumProvider(connectionStore: mcpConnectionStore)
                ]
            )
        } else {
            fatalError("Ask operator runtime must provide typed tool registration and execution.")
        }
        self.aiConfigurationProvider = aiConfigurationProvider
    }

    func streamAsk(
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async throws -> AskSessionResponse {
        let queryText = askUserQueryText(from: request.messages)
        let knowledgeInventoryEntries = enabledKnowledgeInventoryEntries(limit: 24)
        let knowledgeMatches = queryText.isEmpty ? [] : resolveKnowledgeMatches(query: queryText, limit: 4)
        let sourceCards = knowledgeSourceCards(from: knowledgeMatches, uiLanguage: request.uiLanguage)
        let responseProfile = AskResponseProfile.resolved(for: request.metadata.frame)
        let knowledgeContext = askKnowledgeContextText(
            matches: knowledgeMatches,
            inventoryEntries: knowledgeInventoryEntries,
            responseLanguage: request.responseLanguage
        )
        let knowledgeAvailabilityMessage = askKnowledgeAvailabilityMessage(
            inventoryEntries: knowledgeInventoryEntries,
            responseLanguage: request.responseLanguage
        )
        let compiledMessages = askModelMessages(
            for: request,
            responseProfile: responseProfile,
            knowledgeAvailabilityMessage: knowledgeAvailabilityMessage,
            knowledgeContext: knowledgeContext
        )
        logRuntimeInvocation(
            sourceText: queryText,
            details: [
                "phase": "start",
                "message_count": String(request.messages.count),
                "knowledge_matches": String(knowledgeMatches.count),
                "response_profile": responseProfile.rawValue
            ]
        )
        onEvent(
            .status(
                "thinking",
                detail: localized(
                    zhHans: "正在思考中",
                    en: "Thinking",
                    languageCode: request.uiLanguage
                )
            )
        )

        let serviceUnavailable = askServiceUnavailableMessage(
            failureKind: .unavailable,
            isContinuation: request.messages.count > 1,
            responseLanguage: request.responseLanguage
        )
        guard let configuration = try? await aiConfigurationProvider(),
              !configuration.apiKey.isEmpty else {
            let response = AskSessionResponse(
                message: serviceUnavailable,
                cards: [],
                metadata: [
                    "used_knowledge_base": "false",
                    "knowledge_base_source_count": "0",
                    "session_id": request.metadata.sessionID
                ]
            )
            onEvent(.delta(serviceUnavailable, fullText: serviceUnavailable))
            onEvent(.done(response))
            return response
        }
        diagnosticsLogger.log(
            "ask.session",
            "session=\(request.metadata.sessionID) config provider=\(configuration.provider) model=\(configuration.model) host=\(URL(string: configuration.baseURL)?.host ?? configuration.baseURL)"
        )

        let response: AskSessionResponse
        do {
            response = try await askAgentRuntime.run(
                request: request,
                compiledMessages: compiledMessages,
                configuration: configuration,
                responseProfile: responseProfile,
                onEvent: onEvent
            )
        } catch {
            diagnosticsLogger.log(
                "ask.agent",
                "session=\(request.metadata.sessionID) failed error=\(error.localizedDescription)"
            )
            let message = askServiceUnavailableMessage(
                failureKind: askServiceFailureKind(for: error),
                isContinuation: request.messages.count > 1,
                responseLanguage: request.responseLanguage
            )
            let fallbackResponse = AskSessionResponse(
                message: message,
                cards: [],
                metadata: [
                    "used_knowledge_base": "false",
                    "knowledge_base_source_count": "0",
                    "session_id": request.metadata.sessionID
                ]
            )
            onEvent(.delta(message, fullText: message))
            onEvent(.done(fallbackResponse))
            return fallbackResponse
        }

        let mergedCards = response.cards.isEmpty ? sourceCards : response.cards
        let mergedResponse = AskSessionResponse(
            message: response.message,
            cards: mergedCards,
            metadata: response.metadata.merging(
                [
                    "used_knowledge_base": mergedCards.isEmpty ? "false" : "true",
                    "knowledge_base_source_count": String(mergedCards.count),
                    "session_id": request.metadata.sessionID
                ],
                uniquingKeysWith: { current, _ in current }
            )
        )
        onEvent(.done(mergedResponse))
        return mergedResponse
    }

    private func resolveKnowledgeMatches(query: String, limit: Int) -> [KnowledgeBaseSearchMatch] {
        knowledgeBaseStore.searchEntries(query: query, limit: limit)
    }

    private func knowledgeContextText(from matches: [KnowledgeBaseSearchMatch], responseLanguage: String) -> String {
        guard !matches.isEmpty else { return "" }
        let header = responseLanguage.lowercased().hasPrefix("en") ? "Knowledge base context:" : "知识库上下文："
        let lines = matches.enumerated().map { index, match in
            let entry = match.entry
            let chunk = match.matchedChunk?.text ?? entry.preview
            return "[\(index + 1)] \(entry.title)\n\(chunk)"
        }
        return ([header] + lines).joined(separator: "\n\n")
    }

    private func knowledgeSourceCards(from matches: [KnowledgeBaseSearchMatch], uiLanguage: String) -> [SkillResultCard] {
        matches.prefix(4).enumerated().map { index, match in
            let action = KnowledgeBaseSourceActionResolver.primaryAction(for: match.entry, languageCode: uiLanguage)
            return SkillResultCard(
                id: "kb_\(match.entry.id)_\(index)",
                kind: "knowledge_base_source",
                title: match.entry.title,
                badges: match.matchedFacets.isEmpty ? nil : match.matchedFacets,
                subtitle: match.reason,
                description: match.entry.preview,
                action: action.map(KnowledgeBaseSourceActionResolver.skillResultAction),
                priority: index == 0 ? .primary : .secondary,
                isOfficial: nil
            )
        }
    }

    private func enabledKnowledgeInventoryEntries(limit: Int) -> [ReplyKnowledgeBaseEntry] {
        Array(knowledgeBaseStore.entries().filter { $0.isEnabled != false }.prefix(limit))
    }

    private func askLatestUserMessage(from messages: [AskMessage]) -> String {
        messages
            .last(where: { $0.role == .user })?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func askUserQueryText(from messages: [AskMessage]) -> String {
        let userMessages = messages
            .filter { $0.role == .user }
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return userMessages.suffix(3).joined(separator: "\n\n")
    }

    private func askModelMessages(
        for request: AskSessionRequest,
        responseProfile: AskResponseProfile,
        knowledgeAvailabilityMessage: String,
        knowledgeContext: String
    ) -> [LLMChatMessage] {
        var compiled: [LLMChatMessage] = [
            .init(role: .system, content: askDefaultPrompt(responseLanguage: request.responseLanguage))
        ]

        let sessionMessage = askSessionContextMessage(
            metadata: request.metadata,
            responseLanguage: request.responseLanguage
        )
        if !sessionMessage.isEmpty {
            compiled.append(.init(role: .system, content: sessionMessage))
        }
        let kernelMessage = askKernelContextMessage(
            metadata: request.metadata,
            responseLanguage: request.responseLanguage
        )
        if !kernelMessage.isEmpty {
            compiled.append(.init(role: .system, content: kernelMessage))
        }
        compiled.append(.init(role: .system, content: responseProfile.guidance(languageCode: request.responseLanguage)))
        if !knowledgeAvailabilityMessage.isEmpty {
            compiled.append(.init(role: .system, content: knowledgeAvailabilityMessage))
        }
        if !knowledgeContext.isEmpty {
            compiled.append(.init(role: .system, content: knowledgeContext))
        }

        compiled.append(contentsOf: request.messages.compactMap { message in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let role: LLMChatMessage.Role
            switch message.role {
            case .system, .info:
                role = .system
            case .user:
                role = .user
            case .assistant:
                role = .assistant
            }
            return .init(role: role, content: content)
        })

        return compiled
    }

    private func askDefaultPrompt(responseLanguage: String) -> String {
        if AppLanguage.from(languageCode: responseLanguage) == .english {
            return """
            You are NexHub's Ask assistant.
            Answer the user's latest message directly and naturally.
            Use knowledge-base context only when it genuinely helps, and never expose hidden retrieval steps.
            Keep the tone concise, capable, and conversational.
            """
        }
        return """
        你是 NexHub 的 Ask 对话助手。
        直接回答用户的最新问题，自然承接上下文。
        只有在知识库内容真正有帮助时才使用，不要暴露检索过程。
        语气自然、清楚、克制。
        """
    }

    private func askSessionContextMessage(
        metadata: AskSessionMetadata,
        responseLanguage: String
    ) -> String {
        let source = metadata.sourceAppName ?? metadata.sourceBundleID ?? ""
        guard !source.isEmpty else { return "" }
        if AppLanguage.from(languageCode: responseLanguage) == .english {
            return "This Ask conversation was started from: \(source). Do not mention this repeatedly unless it is genuinely useful."
        }
        return "当前这轮 Ask 对话来自应用：\(source)。如无必要，不要反复提及该信息。"
    }

    private func askKernelContextMessage(
        metadata: AskSessionMetadata,
        responseLanguage: String
    ) -> String {
        let kernel = metadata.kernelMetadata
        let workspaceRoot = kernel["workspace_root"]
        let sessionMemorySummary = kernel["session_memory_summary"]
        let workspaceMemorySummary = kernel["workspace_memory_summary"]
        let latestKernelResultSummary = kernel["latest_kernel_result_summary"]
        let activeTaskTitle = kernel["active_task_title"]
        let activeTaskObjective = kernel["active_task_objective"]
        let activeTaskStatus = kernel["active_task_status"]
        let activeTaskWorkspaceRoot = kernel["active_task_workspace_root"]
        let activeTaskProgressSummary = kernel["active_task_progress_summary"]
        let planModeActive = kernel["plan_mode_active"]
        let planModeSummary = kernel["plan_mode_summary"]
        let interactiveTaskScopeGranted = kernel["interactive_task_scope_granted"]
        let mcpServers = mcpResourceCatalog.listServers()
        let mcpResourceCount = mcpServers.isEmpty ? 0 : mcpResourceCatalog.listResources(serverName: nil).count
        let artifactQuery = activeTaskTitle ?? activeTaskObjective ?? latestKernelResultSummary ?? ""
        let recentArtifacts = AskPlaygroundStore.shared.searchArtifacts(matching: artifactQuery, limit: 3)
        let artifactSummary: String? = {
            guard !recentArtifacts.isEmpty else { return nil }
            let entries = recentArtifacts.map { artifact in
                "\(artifact.title) [id=\(String(artifact.id.prefix(8))), entry=\(artifact.entryFile)]"
            }.joined(separator: ", ")
            return entries
        }()
        let mcpSummary: String? = {
            guard !mcpServers.isEmpty else { return nil }
            let serverList = mcpServers.prefix(4).joined(separator: ", ")
            if mcpServers.count == 1 {
                return "\(serverList) (\(mcpResourceCount) mirrored resources)"
            }
            return "\(mcpServers.count) servers [\(serverList)] · \(mcpResourceCount) mirrored resources"
        }()

        let sections: [String?]
        if AppLanguage.from(languageCode: responseLanguage) == .english {
            sections = [
                sessionMemorySummary.map { "Recent session memory: \($0)." },
                workspaceMemorySummary.map { "Recent workspace memory: \($0)." },
                activeTaskStatus.map { "Active resumed task status: \($0)." },
                activeTaskTitle.map { "Active resumed task title: \($0)." },
                activeTaskObjective.map { "Active resumed task objective: \($0)." },
                activeTaskWorkspaceRoot.map { "Active resumed task workspace: \($0)." },
                activeTaskProgressSummary.map { "Active resumed task checklist progress: \($0)." },
                latestKernelResultSummary.map { "Latest kernel result summary: \($0)." },
                planModeActive.map { "Workspace plan mode active: \($0)." },
                planModeSummary.map { "Current plan mode summary: \($0)." },
                interactiveTaskScopeGranted.map { "Current task execution grant active: \($0)." },
                mcpSummary.map { "Mirrored MCP catalog: \($0)." },
                workspaceRoot.map { "Active workspace root: \($0)." },
                artifactSummary.map { "Recent Playground assets that may be reusable: \($0)." }
            ]
        } else {
            sections = [
                sessionMemorySummary.map { "最近的 session memory：\($0)。" },
                workspaceMemorySummary.map { "最近的 workspace memory：\($0)。" },
                activeTaskStatus.map { "当前已恢复任务状态：\($0)。" },
                activeTaskTitle.map { "当前已恢复任务标题：\($0)。" },
                activeTaskObjective.map { "当前已恢复任务目标：\($0)。" },
                activeTaskWorkspaceRoot.map { "当前已恢复任务工作区：\($0)。" },
                activeTaskProgressSummary.map { "当前已恢复任务清单进度：\($0)。" },
                latestKernelResultSummary.map { "最近一次 kernel 结果摘要：\($0)。" },
                planModeActive.map { "当前工作区 plan mode：\($0)。" },
                planModeSummary.map { "当前 plan mode 摘要：\($0)。" },
                interactiveTaskScopeGranted.map { "当前任务执行授权已开启：\($0)。" },
                mcpSummary.map { "当前镜像的 MCP catalog：\($0)。" },
                workspaceRoot.map { "当前工作区根目录：\($0)。" },
                artifactSummary.map { "最近可复用的 Playground 资产：\($0)。" }
            ]
        }

        let visibleSections: [String] = sections.compactMap { section in
            guard let section else { return nil }
            let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !visibleSections.isEmpty else { return "" }

        if AppLanguage.from(languageCode: responseLanguage) == .english {
            return """
            Runtime context from the new Ask kernel is available below.
            Use it when it genuinely improves grounding, but do not repeat it mechanically or mention hidden system wiring unless the user asks.

            \(visibleSections.joined(separator: "\n"))
            """
        }

        return """
        下面是新 Ask Kernel 提供的运行时上下文。
        只有在它确实能帮助你更准确回答时才使用，不要机械复述，也不要主动暴露内部系统细节，除非用户明确追问。

        \(visibleSections.joined(separator: "\n"))
        """
    }

    private func askKnowledgeAvailabilityMessage(
        inventoryEntries: [ReplyKnowledgeBaseEntry],
        responseLanguage: String
    ) -> String {
        guard !inventoryEntries.isEmpty else {
            if AppLanguage.from(languageCode: responseLanguage) == .english {
                return "This Ask conversation is already connected to the user's knowledge base, but there are no enabled sources available right now."
            }
            return "当前这轮 Ask 对话已经连接到用户的知识库，但目前没有可用的已启用资料。"
        }

        if AppLanguage.from(languageCode: responseLanguage) == .english {
            return "This Ask conversation is already connected to the user's knowledge-base workspace, and you already have the inventory of currently enabled sources."
        }
        return "当前这轮 Ask 对话已经连接到用户的知识库工作区，而且你已经拿到了当前已启用资料的 source 清单。"
    }

    private func askKnowledgeContextText(
        matches: [KnowledgeBaseSearchMatch],
        inventoryEntries: [ReplyKnowledgeBaseEntry],
        responseLanguage: String
    ) -> String {
        var sections: [String] = []
        if !inventoryEntries.isEmpty {
            let header = AppLanguage.from(languageCode: responseLanguage) == .english
                ? "Knowledge base source inventory:"
                : "知识库资料清单："
            let inventory = inventoryEntries.prefix(12).enumerated().map { index, entry in
                "[\(index + 1)] \(entry.title)\n\(entry.summary.isEmpty ? entry.preview : entry.summary)"
            }.joined(separator: "\n\n")
            sections.append([header, inventory].joined(separator: "\n\n"))
        }
        let retrievalContext = knowledgeContextText(from: matches, responseLanguage: responseLanguage)
        if !retrievalContext.isEmpty {
            sections.append(retrievalContext)
        }

        guard !sections.isEmpty else { return "" }
        if AppLanguage.from(languageCode: responseLanguage) == .english {
            return """
            Below is optional knowledge-base context for this Ask conversation. It may include a source inventory and retrieved excerpts.
            If the user is asking what is currently in the knowledge base, answer from the inventory directly.
            Otherwise use the material only when it is genuinely relevant. If it does not support a clear conclusion, ignore it. Do not invent facts or expose the retrieval process.

            \(sections.joined(separator: "\n\n"))
            """
        }
        return """
        下面是这轮 Ask 对话可参考的知识库上下文，其中可能包含资料清单和检索命中的片段。
        如果用户在问“知识库里有什么”或“现在接了哪些资料”，优先根据资料清单直接回答。
        只有在确实相关时才使用这些资料；如果资料不能支持明确结论，就忽略它，不要编造，也不要暴露检索过程。

        \(sections.joined(separator: "\n\n"))
        """
    }

    private func askServiceUnavailableMessage(
        failureKind: AskServiceFailureKind,
        isContinuation: Bool,
        responseLanguage: String
    ) -> String {
        if AppLanguage.from(languageCode: responseLanguage) == .english {
            switch failureKind {
            case .authentication:
                return isContinuation
                    ? "The managed AI service failed authentication, so NexHub cannot continue this Ask conversation right now. Contact your administrator."
                    : "The managed AI service failed authentication, so NexHub cannot start the Ask conversation right now. Contact your administrator."
            case .contextLimit:
                return "This Ask conversation has become too long for the current AI request window. Please start a new Ask thread or shorten the recent context and try again."
            case .rateLimited:
                return "The AI service is rate limiting requests right now, so Ask cannot continue yet. Please try again shortly."
            case .network:
                return "NexHub could not reach the AI service just now, so Ask cannot continue yet. Please check the network or try again shortly."
            case .gatewayTimeout:
                return "The AI service timed out upstream, so Ask could not finish this turn. Please try again shortly."
            case .unavailable:
                return isContinuation
                    ? "The AI service is unavailable right now, so NexHub cannot continue this Ask conversation yet. Please try again later."
                    : "The AI service is unavailable right now, so NexHub cannot start the Ask conversation yet. Please try again later."
            }
        }
        switch failureKind {
        case .authentication:
            return isContinuation
                ? "当前托管 AI 服务鉴权失败，暂时无法继续这轮 Ask 对话。请联系管理员。"
                : "当前托管 AI 服务鉴权失败，暂时无法开始 Ask 对话。请联系管理员。"
        case .contextLimit:
            return "这轮 Ask 对话的上下文已经超过当前 AI 请求窗口，暂时无法继续。请新开一个 Ask，或者缩短最近的对话内容后再试。"
        case .rateLimited:
            return "当前 AI 请求过于频繁，Ask 暂时无法继续。请稍后再试。"
        case .network:
            return "当前无法连接到 AI 服务，Ask 暂时无法继续。请检查网络后再试。"
        case .gatewayTimeout:
            return "当前 AI 服务上游响应超时，这轮 Ask 没能继续完成。请稍后重试。"
        case .unavailable:
            return isContinuation
                ? "当前 AI 服务不可用，暂时无法继续这轮 Ask 对话。请稍后再试。"
                : "当前 AI 服务不可用，暂时无法开始 Ask 对话。请稍后再试。"
        }
    }

    private func askServiceFailureKind(for error: Error) -> AskServiceFailureKind {
        if isLikelyAuthenticationFailure(error) {
            return .authentication
        }

        let lowered = loweredServiceErrorMessage(for: error)
        if lowered.contains("context length")
            || lowered.contains("maximum context")
            || lowered.contains("too many tokens")
            || lowered.contains("reduce the length")
            || lowered.contains("input is too long")
            || lowered.contains("prompt is too long")
            || lowered.contains("上下文")
            || lowered.contains("超出")
            || lowered.contains("过长") {
            return .contextLimit
        }
        if lowered.contains("429")
            || lowered.contains("rate limit")
            || lowered.contains("too many requests") {
            return .rateLimited
        }
        if lowered.contains("timed out")
            || lowered.contains("timeout")
            || lowered.contains("deadline exceeded")
            || lowered.contains("gateway timeout")
            || lowered.contains("504") {
            return .gatewayTimeout
        }
        if lowered.contains("network")
            || lowered.contains("socket")
            || lowered.contains("connection")
            || lowered.contains("host")
            || lowered.contains("dns")
            || lowered.contains("offline")
            || lowered.contains("could not connect")
            || lowered.contains("not connected to internet") {
            return .network
        }
        return .unavailable
    }

    private func isLikelyAuthenticationFailure(_ error: Error) -> Bool {
        let lowered = loweredServiceErrorMessage(for: error)
        guard !lowered.isEmpty else { return false }
        return lowered.contains("401")
            || lowered.contains("403")
            || lowered.contains("unauthorized")
            || lowered.contains("authentication")
            || lowered.contains("invalid api key")
    }

    private func loweredServiceErrorMessage(for error: Error) -> String {
        if let askError = error as? AskSessionServiceError {
            return askError.localizedDescription.lowercased()
        }
        if let llmError = error as? LLMClientError {
            switch llmError {
            case .server(let message):
                return message.lowercased()
            default:
                return llmError.localizedDescription.lowercased()
            }
        }
        if let agentError = error as? AgentLLMClientError {
            switch agentError {
            case .server(let message):
                return message.lowercased()
            default:
                return agentError.localizedDescription.lowercased()
            }
        }
        return error.localizedDescription.lowercased()
    }

    private func logRuntimeInvocation(sourceText: String, details: [String: String]) {
        let base = [
            "skill": "ask",
            "chars": String(sourceText.count),
            "lines": String(sourceText.components(separatedBy: "\n").count)
        ]
        let payload = base.merging(details) { _, new in new }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        diagnosticsLogger.log("ai.runtime", payload)
    }

    private func localized(zhHans: String, en: String, languageCode: String) -> String {
        L10n.text(languageCode: languageCode, zhHans: zhHans, en: en)
    }
}
