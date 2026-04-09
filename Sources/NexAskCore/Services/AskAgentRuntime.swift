import Foundation
import NexShared

final class AskAgentRuntime: AskAgentRuntimeProviding {
    private final class StreamTextBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        func append(_ delta: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            text += delta
            return text
        }

        func snapshot() -> String {
            lock.lock()
            defer { lock.unlock() }
            return text
        }
    }

    private final class StreamProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var deltaCount = 0
        private var deltaChars = 0
        private var firstDeltaAt: Date?

        func record(delta: String) -> (count: Int, chars: Int, firstDeltaAt: Date?) {
            lock.lock()
            defer { lock.unlock() }
            deltaCount += 1
            deltaChars += delta.count
            if firstDeltaAt == nil {
                firstDeltaAt = Date()
            }
            return (deltaCount, deltaChars, firstDeltaAt)
        }

        func snapshot() -> (count: Int, chars: Int, firstDeltaAt: Date?) {
            lock.lock()
            defer { lock.unlock() }
            return (deltaCount, deltaChars, firstDeltaAt)
        }
    }

    private let agentLLMClient: AgentLLMClient
    private let toolRegistry: AskToolProviding
    private let toolExecutor: AskToolExecuting
    private let sessionStore: AskAgentSessionStore
    private let diagnosticsLogger: DiagnosticsLogger
    private let promptConfiguration: AskAgentPromptConfiguration
    private let systemPromptAddendumProviders: [any AskAgentPromptAddendumProviding]

    init(
        agentLLMClient: AgentLLMClient = AgentLLMClient(),
        toolRegistry: AskToolProviding,
        toolExecutor: AskToolExecuting,
        sessionStore: AskAgentSessionStore = AskAgentSessionStore(),
        diagnosticsLogger: DiagnosticsLogger = .shared,
        promptConfiguration: AskAgentPromptConfiguration = .default,
        systemPromptAddendumProviders: [any AskAgentPromptAddendumProviding] = []
    ) {
        self.agentLLMClient = agentLLMClient
        self.toolRegistry = toolRegistry
        self.toolExecutor = toolExecutor
        self.sessionStore = sessionStore
        self.diagnosticsLogger = diagnosticsLogger
        self.promptConfiguration = promptConfiguration
        self.systemPromptAddendumProviders = systemPromptAddendumProviders.isEmpty
            ? [AskMetadataPromptAddendumProvider()]
            : systemPromptAddendumProviders
    }

    func run(
        request: AskSessionRequest,
        compiledMessages: [LLMChatMessage],
        configuration: LLMRequestConfiguration,
        responseProfile: AskResponseProfile = .detailed,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async throws -> AskSessionResponse {
        let rawMessages = compiledMessages.map(agentMessage(from:))

        var cards: [SkillResultCard] = []
        var toolCallCount = 0
        let maxToolCalls = 18
        let previousState = await sessionStore.sessionState(for: request.metadata.sessionID)
        let compressedContext = AskAgentContextCompressor.compress(
            messages: rawMessages,
            sessionState: previousState,
            responseLanguage: request.responseLanguage
        )
        var messages = compressedContext.messages
        var currentState = await sessionStore.beginTurn(
            sessionID: request.metadata.sessionID,
            conversationMessages: rawMessages,
            maxToolCalls: maxToolCalls,
            sessionOrigin: request.metadata.sessionOrigin,
            kernelMetadata: request.metadata.kernelMetadata
        )
        if compressedContext.summaryIncluded || compressedContext.droppedConversationMessageCount > 0 {
            diagnosticsLogger.log(
                "ask.agent",
                "session=\(request.metadata.sessionID) context_compressed dropped_messages=\(compressedContext.droppedConversationMessageCount) summary=\(compressedContext.summaryIncluded)"
            )
        }
        messages.insert(
            .system(
                agentSystemPrompt(
                    responseLanguage: request.responseLanguage,
                    sessionState: currentState,
                    responseProfile: responseProfile
                )
            ),
            at: 0
        )

        var previousResponseID: String?
        var cachedToolResults: [String: AskToolExecutionResult] = [:]

        if let pendingApprovalDecision = pendingApprovalDecisionOverride(
            for: request,
            sessionState: currentState
        ) {
            let toolCall = syntheticPendingApprovalToolCall(
                actionID: currentState.approvalState?.actionID ?? "",
                decision: pendingApprovalDecision
            )
            messages.append(.assistantToolCalls([toolCall], content: nil))
            if shouldPresentToolStartStep(for: toolCall) {
                onEvent(.runtimeStep(toolStartStepEvent(for: toolCall, request: request)))
            }
            _ = await sessionStore.recordToolPlanning(toolCall: toolCall, for: request.metadata.sessionID)
            toolCallCount += 1
            let effectiveRequest = requestWithCurrentSessionState(
                request,
                sessionState: currentState
            )
            let result = await toolExecutor.executeTool(
                named: toolCall.name,
                argumentsJSON: toolCall.argumentsJSON,
                request: effectiveRequest,
                onEvent: onEvent
            )
            diagnosticsLogger.log(
                "ask.agent",
                "session=\(request.metadata.sessionID) auto_resolved_pending_approval decision=\(pendingApprovalDecision.rawValue) ok=\(result.ok) waiting_approval=\(result.approvalRequest != nil) summary=\(result.summary) error=\(result.error ?? "")"
            )
            cards = mergedCards(existing: cards, incoming: result.cards)
            if let completionStep = toolCompletionStepEvent(
                for: toolCall,
                result: result,
                request: request
            ) {
                onEvent(.runtimeStep(completionStep))
            }
            let toolContent = serializedToolPayload(result.modelPayload)
            messages.append(.tool(toolCallID: toolCall.id, toolName: toolCall.name, content: toolContent))
            currentState = await sessionStore.recordToolExecution(
                sessionID: request.metadata.sessionID,
                toolCall: toolCall,
                result: result
            )

            if let approvalRequest = result.approvalRequest {
                return AskSessionResponse(
                    message: approvalRequest.message,
                    cards: approvalRequest.cards,
                    metadata: metadata(
                        sessionID: request.metadata.sessionID,
                        toolCallCount: toolCallCount,
                        state: currentState,
                        agentState: "waiting_approval"
                    )
                )
            }
        }

        while toolCallCount < maxToolCalls {
            messages[0] = .system(
                agentSystemPrompt(
                    responseLanguage: request.responseLanguage,
                    sessionState: currentState,
                    responseProfile: responseProfile
                )
            )
            let tools = availableTools(
                responseLanguage: request.responseLanguage,
                sessionState: currentState
            )
            let streamedAssistantText = StreamTextBuffer()
            let streamProgress = StreamProgress()
            let modelTurnStartedAt = Date()
            let modelTurn = try await agentLLMClient.respond(
                configuration: configuration,
                messages: messages,
                tools: tools,
                previousResponseID: previousResponseID,
                responseProfile: responseProfile,
                onOutputTextDelta: { delta in
                    let normalizedDelta = delta.replacingOccurrences(of: "\r\n", with: "\n")
                    guard !normalizedDelta.isEmpty else { return }
                    let progress = streamProgress.record(delta: normalizedDelta)
                    if progress.count == 1, let firstDeltaAt = progress.firstDeltaAt {
                        self.diagnosticsLogger.log(
                            "ask.agent",
                            "session=\(request.metadata.sessionID) first_model_delta elapsed_ms=\(Int(firstDeltaAt.timeIntervalSince(modelTurnStartedAt) * 1000)) delta_chars=\(normalizedDelta.count)"
                        )
                    }
                    let fullText = streamedAssistantText.append(normalizedDelta)
                    onEvent(.delta(normalizedDelta, fullText: fullText))
                },
                onToolCallDelta: { toolCall in
                    guard let step = self.streamingToolStepEvent(for: toolCall, request: request) else {
                        return
                    }
                    onEvent(.runtimeStep(step))
                }
            )
            previousResponseID = modelTurn.responseID
            let progress = streamProgress.snapshot()
            diagnosticsLogger.log(
                "ask.agent",
                "session=\(request.metadata.sessionID) model_turn_finished elapsed_ms=\(Int(Date().timeIntervalSince(modelTurnStartedAt) * 1000)) streamed_deltas=\(progress.count) streamed_chars=\(progress.chars) has_streamed_text=\(!streamedAssistantText.snapshot().isEmpty)"
            )

            switch modelTurn.response {
            case .final(let message):
                let finalMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? fallbackEmptyResponse(languageCode: request.responseLanguage)
                    : message
                currentState = await sessionStore.recordFinalResponse(message: finalMessage, for: request.metadata.sessionID)
                if streamedAssistantText.snapshot().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onEvent(.delta(finalMessage, fullText: finalMessage))
                }
                diagnosticsLogger.log("ask.agent", "session=\(request.metadata.sessionID) completed tool_calls=\(toolCallCount)")
                return AskSessionResponse(
                    message: finalMessage,
                    cards: Array(cards.prefix(3)),
                    metadata: metadata(
                        sessionID: request.metadata.sessionID,
                        toolCallCount: toolCallCount,
                        state: currentState,
                        agentState: "completed"
                    )
                )

            case .toolCalls(let toolCalls, let assistantText):
                let toolNames = toolCalls.map(\.name).joined(separator: ",")
                diagnosticsLogger.log(
                    "ask.agent",
                    "session=\(request.metadata.sessionID) tool_calls=\(toolNames)"
                )
                if streamedAssistantText.snapshot().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let assistantText,
                   !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onEvent(.assistantPreamble(assistantText))
                }
                let streamedText = streamedAssistantText.snapshot()
                let assistantContent = streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? assistantText
                    : streamedText
                messages.append(.assistantToolCalls(toolCalls, content: assistantContent))

                for toolCall in toolCalls {
                    if shouldPresentToolStartStep(for: toolCall) {
                        onEvent(.runtimeStep(toolStartStepEvent(for: toolCall, request: request)))
                    }
                    _ = await sessionStore.recordToolPlanning(toolCall: toolCall, for: request.metadata.sessionID)
                    let cacheKey = toolCacheKey(for: toolCall)
                    let result: AskToolExecutionResult
                    if shouldCacheToolResult(named: toolCall.name),
                       let cached = cachedToolResults[cacheKey] {
                        diagnosticsLogger.log(
                            "ask.agent",
                            "session=\(request.metadata.sessionID) reused_cached_tool_result=\(toolCall.name)"
                        )
                        result = cached
                    } else {
                        toolCallCount += 1
                        let effectiveRequest = requestWithCurrentSessionState(
                            request,
                            sessionState: currentState
                        )
                        result = await toolExecutor.executeTool(
                            named: toolCall.name,
                            argumentsJSON: toolCall.argumentsJSON,
                            request: effectiveRequest,
                            onEvent: onEvent
                        )
                        if shouldCacheToolResult(named: toolCall.name),
                           result.approvalRequest == nil {
                            cachedToolResults[cacheKey] = result
                        } else {
                            invalidateCachedToolResultsIfNeeded(
                                afterExecuting: toolCall.name,
                                sessionID: request.metadata.sessionID,
                                cache: &cachedToolResults
                            )
                        }
                    }
                    diagnosticsLogger.log(
                        "ask.agent",
                        "session=\(request.metadata.sessionID) tool_result name=\(toolCall.name) ok=\(result.ok) waiting_approval=\(result.approvalRequest != nil) summary=\(result.summary) error=\(result.error ?? "")"
                    )

                    cards = mergedCards(existing: cards, incoming: result.cards)
                    if let completionStep = toolCompletionStepEvent(
                        for: toolCall,
                        result: result,
                        request: request
                    ) {
                        onEvent(.runtimeStep(completionStep))
                    }
                    let toolContent = serializedToolPayload(result.modelPayload)
                    messages.append(.tool(toolCallID: toolCall.id, toolName: toolCall.name, content: toolContent))
                    currentState = await sessionStore.recordToolExecution(
                        sessionID: request.metadata.sessionID,
                        toolCall: toolCall,
                        result: result
                    )

                    if let approvalRequest = result.approvalRequest {
                        return AskSessionResponse(
                            message: approvalRequest.message,
                            cards: approvalRequest.cards,
                            metadata: metadata(
                                sessionID: request.metadata.sessionID,
                                toolCallCount: toolCallCount,
                                state: currentState,
                                agentState: "waiting_approval"
                            )
                        )
                    }

                    if toolCall.name == "respond_to_approval" {
                        _ = await sessionStore.clearPendingApproval(for: request.metadata.sessionID)
                    }
                }
            }
        }

        let state = await sessionStore.sessionState(for: request.metadata.sessionID)
            ?? AskAgentSessionState.make(sessionID: request.metadata.sessionID, maxToolCalls: maxToolCalls)
        return AskSessionResponse(
            message: L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "这轮 Ask 执行步骤过多，我先在这里停下。你可以继续告诉我下一步要保留哪个结果或继续哪个分支。",
                en: "This Ask turn required too many execution steps, so I stopped here. You can tell me which result or branch to continue next."
            ),
            cards: Array(cards.prefix(3)),
            metadata: metadata(
                sessionID: request.metadata.sessionID,
                toolCallCount: toolCallCount,
                state: state,
                agentState: "loop_limit"
            )
        )
    }

    private func agentMessage(from message: LLMChatMessage) -> AskAgentMessage {
        switch message.role {
        case .system:
            return .system(message.content)
        case .user:
            return .user(message.content)
        case .assistant:
            return .assistant(message.content)
        }
    }

    private func agentSystemPrompt(
        responseLanguage: String,
        sessionState: AskAgentSessionState,
        responseProfile: AskResponseProfile
    ) -> String {
        let context = AskAgentPromptContext(
            responseLanguage: responseLanguage,
            sessionState: sessionState,
            responseProfile: responseProfile
        )
        let appendedSections = systemPromptAddendumProviders.flatMap { provider in
            provider.appendedSystemPromptSections(for: context)
        }
        let resolvedPromptConfiguration = promptConfiguration.merging(
            AskAgentPromptConfiguration.from(metadata: sessionState.kernelMetadata)
        )
        return AskAgentPromptComposer.composeSystemPrompt(
            context: context,
            promptConfiguration: resolvedPromptConfiguration,
            appendedSections: appendedSections
        )
    }

    private func fallbackEmptyResponse(languageCode: String) -> String {
        L10n.text(
            languageCode: languageCode,
            zhHans: "这轮 Ask 我没有拿到足够明确的最终回答。我可以继续执行，或者你也可以补充一下想达成的结果。",
            en: "I did not get a clear final answer for this Ask turn. I can continue, or you can clarify the result you want."
        )
    }

    private func serializedToolPayload(_ payload: [String: Any]) -> String {
        let compactedPayload = AskAgentToolPayloadCompactor.compact(payload)
        guard JSONSerialization.isValidJSONObject(compactedPayload),
              let data = try? JSONSerialization.data(withJSONObject: compactedPayload),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"summary":"serialization_failed"}"#
        }
        return string
    }

    private func mergedCards(existing: [SkillResultCard], incoming: [SkillResultCard]) -> [SkillResultCard] {
        var merged = existing
        let existingIDs = Set(existing.map(\.id))
        for card in incoming where !existingIDs.contains(card.id) {
            merged.append(card)
        }
        return merged
    }

    private func toolCacheKey(for toolCall: AskToolCall) -> String {
        "\(toolCall.name)\n\(toolCall.argumentsJSON)"
    }

    private func shouldCacheToolResult(named toolName: String) -> Bool {
        switch toolName {
        case "snapshot_workspace_tree",
             "glob_workspace_paths",
             "grep_workspace_text",
             "read_workspace_file",
             "preview_workspace_patch",
             "list_tasks",
             "get_task":
            return true
        default:
            return false
        }
    }

    private func invalidateCachedToolResultsIfNeeded(
        afterExecuting toolName: String,
        sessionID: String,
        cache: inout [String: AskToolExecutionResult]
    ) {
        guard !cache.isEmpty else { return }
        diagnosticsLogger.log(
            "ask.agent",
            "session=\(sessionID) invalidated_cached_tool_results_after=\(toolName) cleared=\(cache.count)"
        )
        cache.removeAll(keepingCapacity: true)
    }

    private func pendingApprovalDecisionOverride(
        for request: AskSessionRequest,
        sessionState: AskAgentSessionState
    ) -> AskApprovalDecision? {
        guard sessionState.approvalState != nil,
              let latestUserMessage = request.messages.last,
              latestUserMessage.role == .user else {
            return nil
        }

        let normalized = latestUserMessage.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "确认", "确认执行", "confirm", "approve":
            return .approve
        case "取消", "cancel", "deny":
            return .cancel
        default:
            return nil
        }
    }

    private func syntheticPendingApprovalToolCall(
        actionID: String,
        decision: AskApprovalDecision
    ) -> AskToolCall {
        let payload: [String: String] = [
            "action_id": actionID,
            "decision": decision.rawValue
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data(#"{"action_id":"","decision":"cancel"}"#.utf8)
        let argumentsJSON = String(data: data, encoding: .utf8)
            ?? #"{"action_id":"","decision":"cancel"}"#
        return AskToolCall(
            id: "call_pending_approval_\(UUID().uuidString.lowercased())",
            name: "respond_to_approval",
            argumentsJSON: argumentsJSON
        )
    }

    private func toolStartStepEvent(
        for toolCall: AskToolCall,
        request: AskSessionRequest
    ) -> AskRuntimeStepEvent {
        let copy = toolPresentation(for: toolCall, request: request)
        return AskRuntimeStepEvent(
            id: toolCall.id,
            kind: .toolCall,
            title: copy.title,
            detail: copy.detail,
            state: .running,
            codeBlock: codeBlockPreview(for: toolCall, isStreaming: false)
        )
    }

    private func toolCompletionStepEvent(
        for toolCall: AskToolCall,
        result: AskToolExecutionResult,
        request: AskSessionRequest
    ) -> AskRuntimeStepEvent? {
        let copy = toolPresentation(for: toolCall, request: request)
        if let approvalRequest = result.approvalRequest {
            return AskRuntimeStepEvent(
                id: toolCall.id,
                kind: .awaitingApproval,
                title: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "等待你的确认",
                    en: "Waiting for your confirmation"
                ),
                detail: approvalRequest.summary,
                state: .waiting,
                codeBlock: codeBlockPreview(for: toolCall, isStreaming: false)
            )
        }

        if shouldSuppressToolCompletionStep(for: toolCall, result: result) {
            return nil
        }

        if result.ok {
            return AskRuntimeStepEvent(
                id: toolCall.id,
                kind: .toolCall,
                title: copy.title,
                detail: result.summary,
                state: .completed,
                codeBlock: codeBlockPreview(for: toolCall, isStreaming: false)
            )
        }

        return AskRuntimeStepEvent(
            id: toolCall.id,
            kind: .executionResult,
            title: L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "这一步执行失败",
                en: "Step failed"
            ),
            detail: result.error ?? result.summary,
            state: .failed,
            codeBlock: codeBlockPreview(for: toolCall, isStreaming: false)
        )
    }

    private func shouldPresentToolStartStep(for toolCall: AskToolCall) -> Bool {
        switch toolCall.name {
        case "open_url", "read_current_page":
            return false
        default:
            return true
        }
    }

    private func shouldSuppressToolCompletionStep(
        for toolCall: AskToolCall,
        result: AskToolExecutionResult
    ) -> Bool {
        guard !result.ok, result.approvalRequest == nil else {
            return false
        }

        switch toolCall.name {
        case "open_url":
            return result.data["visible_browser_action_blocked"] as? Bool == true
        case "read_current_page":
            return result.data["current_page_read_blocked"] as? Bool == true
        default:
            return false
        }
    }

    private func streamingToolStepEvent(
        for toolCall: AskToolCall,
        request: AskSessionRequest
    ) -> AskRuntimeStepEvent? {
        guard let codeBlock = codeBlockPreview(for: toolCall, isStreaming: true) else {
            return nil
        }
        let copy = toolPresentation(for: toolCall, request: request)
        return AskRuntimeStepEvent(
            id: toolCall.id,
            kind: .toolCall,
            title: copy.title,
            detail: copy.detail,
            state: .running,
            codeBlock: codeBlock
        )
    }

    private func toolPresentation(
        for toolCall: AskToolCall,
        request: AskSessionRequest
    ) -> (title: String, detail: String) {
        let args = parsedArguments(from: toolCall.argumentsJSON)
        let languageCode = request.responseLanguage
        switch toolCall.name {
        case "snapshot_directory":
            let directory = normalizedToolLabel(args["directory"] as? String)
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在扫描目录", en: "Scanning the directory"),
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "我先扫描 %@ 的内容，建立一个后续可复用的文件快照。",
                    en: "I’m first scanning %@ to build a reusable file snapshot for the next steps.",
                    directory.isEmpty ? localizedDesktopLabel(languageCode: languageCode) : directory
                )
            )
        case "inspect_paths":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在核对路径详情", en: "Inspecting the path details"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先核对这些路径到底是文件、文件夹还是目标目录，避免后面误操作。",
                    en: "I’m first checking whether these paths are files, folders, or destination directories so we avoid mistakes later."
                )
            )
        case "select_from_snapshot":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在筛选候选文件", en: "Selecting the candidate files"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先从已有快照里筛出符合条件的文件，尽量避免重复全盘扫描。",
                    en: "I’m selecting matching files from the existing snapshot so we can avoid rescanning the whole directory."
                )
            )
        case "stage_move_paths":
            let destination = normalizedToolLabel(args["destination_directory"] as? String)
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在生成移动预案", en: "Preparing the move plan"),
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "我先生成一份移动预案，看看哪些文件会被移到 %@，然后再交给你确认。",
                    en: "I’m preparing a move plan to see which files would go into %@ before asking for confirmation.",
                    destination.isEmpty ? localizedDestinationLabel(languageCode: languageCode) : destination
                )
            )
        case "commit_staged_operation":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在提交已确认的操作", en: "Committing the approved operation"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我现在提交你刚才确认过的操作，并返回真实执行结果。",
                    en: "I’m now committing the operation you approved and will return the real execution result."
                )
            )
        case "cancel_staged_operation":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在取消这次操作", en: "Cancelling the operation"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把这次待执行的方案取消掉，确保不会改动文件。",
                    en: "I’m cancelling the staged plan so no file changes are applied."
                )
            )
        case "prepare_directory_cleanup":
            let source = normalizedToolLabel(args["source_directory"] as? String)
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在整理散落文件", en: "Preparing the cleanup plan"),
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "我先把 %@ 里散落的文件整理成候选集合，再生成一份可确认的归档方案。",
                    en: "I’m first gathering the loose files in %@, then turning that into a cleanup plan you can confirm.",
                    source.isEmpty ? localizedDesktopLabel(languageCode: languageCode) : source
                )
            )
        case "list_workspace_roots":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在查找工作区", en: "Looking for workspace roots"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先查一下当前有哪些可用项目根目录，再决定后面的代码动作落在哪个工作区。",
                    en: "I’m first checking which project roots are available before choosing the workspace for the next coding steps."
                )
            )
        case "set_active_workspace":
            let root = normalizedToolLabel(args["workspace_root"] as? String)
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在切换当前工作区", en: "Switching the active workspace"),
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "我先把 %@ 设成当前会话的工作区，后续代码动作会沿用它。",
                    en: "I’m setting %@ as the active workspace for this session so later coding steps reuse it.",
                    root.isEmpty ? L10n.text(languageCode: languageCode, zhHans: "目标项目", en: "the target project") : root
                )
            )
        case "enter_plan_mode":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在进入规划模式", en: "Entering planning mode"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把当前工作区切到只读规划模式，接下来优先做结构分析和代码排查，不直接落地改动。",
                    en: "I’m switching the current workspace into read-only planning mode so I can inspect the structure and code paths before making changes."
                )
            )
        case "exit_plan_mode":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在退出规划模式", en: "Exiting planning mode"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先退出只读规划模式，再继续真正执行后续实现动作。",
                    en: "I’m leaving read-only planning mode first so I can continue with actual implementation work."
                )
            )
        case "set_workspace_execution_budget":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在更新 session 权限", en: "Updating session permissions"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先调整当前工作区的 session 权限预算，决定后续 shell 或写入是否可以直接执行。",
                    en: "I’m updating the current workspace session execution budget so later shell or write actions use the right permission path."
                )
            )
        case "list_tasks":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在查看任务列表", en: "Inspecting recorded tasks"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把这个代码会话里已经记录的任务和子任务列出来，再决定接下来继续哪一条。",
                    en: "I’m listing the tasks and child tasks already recorded in this coding session first so we can choose the right branch to continue."
                )
            )
        case "get_task":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在读取任务详情", en: "Reading task details"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把这个已记录任务的详情读出来，确认它当前状态和上下文。",
                    en: "I’m reading the details of this recorded task first so we can confirm its current state and context."
                )
            )
        case "update_task":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在更新任务状态", en: "Updating the task"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把这个任务的标题、目标或状态更新掉，让后续连续性保持一致。",
                    en: "I’m updating the title, objective, or status of this task first so later continuity stays accurate."
                )
            )
        case "stop_task":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在停止任务", en: "Stopping the task"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把这条不再继续的任务停掉，避免它继续挂在当前会话里。",
                    en: "I’m stopping this task first so it no longer stays open in the current session."
                )
            )
        case "resume_task":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在恢复任务上下文", en: "Restoring task context"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把之前记录过的任务上下文恢复到当前会话里，这样后面继续这个分支时不会丢失连续性。",
                    en: "I’m restoring the previously recorded task context into this session first so we can continue that branch without losing continuity."
                )
            )
        case "spawn_subtask":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在记录子任务", en: "Recording a child task"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把这条延期分支或后续检查项记成一个子任务，方便后面继续追踪。",
                    en: "I’m recording this deferred branch or follow-up check as a child task so we can track it later."
                )
            )
        case "snapshot_workspace_tree":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在查看项目结构", en: "Inspecting the project tree"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把工作区里的目录和文件结构过一遍，再决定读哪些代码文件。",
                    en: "I’m walking the workspace tree first so I can choose which code files to read next."
                )
            )
        case "glob_workspace_paths":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在按模式匹配路径", en: "Matching workspace paths"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先按给定的 glob 模式把相关文件路径筛出来，再继续读文件或做下一步分析。",
                    en: "I’m first matching the relevant file paths by glob pattern so I can decide what to inspect next."
                )
            )
        case "grep_workspace_text":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在搜索工作区文本", en: "Searching the workspace text"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先在代码里搜索相关关键字，锁定真正相关的位置。",
                    en: "I’m searching the codebase first so we can lock onto the relevant places."
                )
            )
        case "read_workspace_file":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在读取工作区文件", en: "Reading the workspace file"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把相关源码或配置文件读出来，再给你准确结论。",
                    en: "I’m reading the relevant source or config file first so I can give you an accurate answer."
                )
            )
        case "write_workspace_file":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在准备写入文件", en: "Preparing to write the file"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把这次文件写入动作整理好；如果当前还在只读或需要确认，我会先走对应的安全路径。",
                    en: "I’m preparing this file write first; if the session is still read-only or needs approval, I’ll follow that safety path before writing."
                )
            )
        case "workspace_git_status":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在查看 git 状态", en: "Inspecting git status"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先看一下当前工作区有哪些已改动内容。",
                    en: "I’m checking what has already changed in the current workspace."
                )
            )
        case "workspace_git_diff":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在查看 git diff", en: "Inspecting git diff"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先看一下当前改动的具体 diff，再继续判断下一步。",
                    en: "I’m looking at the exact diff first before deciding on the next step."
                )
            )
        case "run_shell_command":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在准备工作区命令", en: "Preparing the workspace command"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把这条工作区命令整理好；如果风险较高，会先进入确认。",
                    en: "I’m preparing this workspace command first; if it is riskier, it will go through approval."
                )
            )
        case "preview_workspace_patch":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在预览 patch 影响", en: "Previewing patch impact"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把这段 patch 会影响哪些文件整理出来，但还不会真正写入项目。",
                    en: "I’m summarizing which files this patch would affect without writing it into the project yet."
                )
            )
        case "apply_workspace_patch":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在准备应用 patch", en: "Preparing to apply the patch"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把 patch 的落地动作整理好；因为这是写入项目的动作，通常会先进入确认。",
                    en: "I’m preparing the patch application now; because this writes into the project, it will usually go through approval first."
                )
            )
        case "move_paths":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在整理移动方案", en: "Preparing the move operation"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先整理这些文件的移动方案，先给你看影响范围，再决定是否真正执行。",
                    en: "I’m preparing the move operation first so you can review the impact before anything is executed."
                )
            )
        case "read_current_page":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在读取当前网页", en: "Reading the current page"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先读取你当前打开的网页内容，再基于页面信息回答你。",
                    en: "I’m reading the page you already have open, then I’ll answer from that page content."
                )
            )
        case "extract_current_page_summary":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在整理当前页摘要", en: "Summarizing the current page"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把当前网页的标题、URL 和正文摘要整理出来。",
                    en: "I’m first organizing the title, URL, and readable summary for the current page."
                )
            )
        case "extract_current_page_links":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在提取当前页链接", en: "Extracting current-page links"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把当前页面里可见的链接候选整理出来。",
                    en: "I’m extracting visible link candidates from the current page first."
                )
            )
        case "capture_best_web_result":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在挑选最佳网页结果", en: "Picking the best web result"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先静默搜索网页，再锁定一个最值得继续跟进的结果。",
                    en: "I’m silently searching the web and picking the single best result to continue from."
                )
            )
        case "search_knowledge":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在搜索知识库", en: "Searching the knowledge base"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先在本地知识库里找能直接继续引用的来源。",
                    en: "I’m first looking through the local knowledge base for sources we can continue from."
                )
            )
        case "collect_url", "collect_current_page", "collect_current_page_to_knowledge", "collect_paths", "save_answer_to_knowledge_note":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在写入知识库", en: "Writing into the knowledge base"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把这一步需要的内容采集或保存进知识库。",
                    en: "I’m collecting or saving the relevant content into the knowledge base first."
                )
            )
        case "copy_to_clipboard":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在复制到剪贴板", en: "Copying to the clipboard"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把结果复制到剪贴板里。",
                    en: "I’m copying the result into the clipboard first."
                )
            )
        case "write_back_to_frontmost_input":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在写回前台输入框", en: "Writing back into the foreground input"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把内容写回你当前正在输入的位置。",
                    en: "I’m writing the content back into where you are currently typing."
                )
            )
        case "replace_frontmost_selection":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在替换当前选区", en: "Replacing the current selection"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把你前台应用里的当前选区替换成指定内容。",
                    en: "I’m replacing the current foreground selection with the requested content."
                )
            )
        case "preview_calendar_intent":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在解析时间意图", en: "Previewing the schedule intent"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把这句话里的时间意图解析出来，确认时间和提醒方式。",
                    en: "I’m first parsing the schedule intent from the request so we can confirm the timing and reminder behavior."
                )
            )
        case "create_calendar_event", "create_reminder":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在创建日历项", en: "Creating the calendar item"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我现在把刚才确认好的时间意图真正写成一个日历项。",
                    en: "I’m now turning the confirmed schedule intent into a real calendar item."
                )
            )
        case "delete_reminder", "delete_calendar_item":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在撤销提醒", en: "Deleting the reminder"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先定位这个提醒，再把它从日历里删除。",
                    en: "I’m locating that reminder first and then deleting it from the calendar."
                )
            )
        case "preview_automation_job":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在生成定时任务草案", en: "Drafting the automation"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先把你的自然语言任务整理成一个可确认的定时任务草案。",
                    en: "I’m first turning your request into an automation draft that you can review."
                )
            )
        case "create_automation_job":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在保存定时任务", en: "Saving the automation"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我现在把这个草案保存成一个本地定时任务。",
                    en: "I’m saving this draft as a local automation now."
                )
            )
        case "search_web":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在查找网页资料", en: "Looking up web sources"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先静默查找相关网页资料，再把有用的信息整理给你。",
                    en: "I’m quietly looking up relevant web sources and then I’ll summarize the useful information."
                )
            )
        case "open_url":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在打开页面", en: "Opening the page"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我会按你的要求打开这个页面，并继续基于打开后的内容协助你。",
                    en: "I’m opening the page you asked for and will continue from there."
                )
            )
        case "respond_to_approval":
            return (
                L10n.text(languageCode: languageCode, zhHans: "正在处理你的确认", en: "Processing your decision"),
                L10n.text(
                    languageCode: languageCode,
                    zhHans: "我先根据你刚才的确认或取消，继续这条操作链路。",
                    en: "I’m continuing this operation chain based on your latest approve / cancel decision."
                )
            )
        default:
            return (
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "正在调用 %@",
                    en: "Running %@",
                    toolCall.name
                ),
                L10n.format(
                    languageCode: languageCode,
                    zhHans: "我先调用 %@ 补齐这一步需要的信息或动作。",
                    en: "I’m calling %@ to gather the information or action needed for this step.",
                    toolCall.name
                )
            )
        }
    }

    private func parsedArguments(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return payload
    }

    private func codeBlockPreview(
        for toolCall: AskToolCall,
        isStreaming: Bool
    ) -> AskRuntimeCodeBlockPreview? {
        let arguments = parsedArguments(from: toolCall.argumentsJSON)
        switch toolCall.name {
        case "write_workspace_file":
            guard let content = stringArgumentValue(
                keys: ["content", "text", "body"],
                arguments: arguments,
                rawJSON: toolCall.argumentsJSON
            ) else {
                return nil
            }
            let path = stringArgumentValue(
                keys: ["path", "file", "file_path"],
                arguments: arguments,
                rawJSON: toolCall.argumentsJSON
            )
            return AskRuntimeCodeBlockPreview(
                content: content,
                languageHint: codeLanguageHint(for: path),
                isStreaming: isStreaming
            )
        case "apply_workspace_patch":
            guard let patch = stringArgumentValue(
                keys: ["patch", "diff"],
                arguments: arguments,
                rawJSON: toolCall.argumentsJSON
            ) else {
                return nil
            }
            return AskRuntimeCodeBlockPreview(
                content: patch,
                languageHint: "diff",
                isStreaming: isStreaming
            )
        case "run_shell_command":
            guard let command = stringArgumentValue(
                keys: ["command", "cmd", "shell_command"],
                arguments: arguments,
                rawJSON: toolCall.argumentsJSON
            ) else {
                return nil
            }
            return AskRuntimeCodeBlockPreview(
                content: command,
                languageHint: "shell",
                isStreaming: isStreaming
            )
        default:
            return nil
        }
    }

    private func stringArgumentValue(
        keys: [String],
        arguments: [String: Any],
        rawJSON: String
    ) -> String? {
        for key in keys {
            if let value = arguments[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        for key in keys {
            if let value = partialJSONStringValue(forKey: key, in: rawJSON),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private func partialJSONStringValue(forKey key: String, in json: String) -> String? {
        guard let keyRange = json.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        skipJSONWhitespace(in: json, index: &index)
        guard index < json.endIndex, json[index] == ":" else { return nil }
        index = json.index(after: index)
        skipJSONWhitespace(in: json, index: &index)
        guard index < json.endIndex, json[index] == "\"" else { return nil }
        return decodePartialJSONStringLiteral(in: json, from: json.index(after: index))
    }

    private func skipJSONWhitespace(in json: String, index: inout String.Index) {
        while index < json.endIndex, json[index].isWhitespace {
            index = json.index(after: index)
        }
    }

    private func decodePartialJSONStringLiteral(
        in json: String,
        from start: String.Index
    ) -> String {
        var result = ""
        var index = start
        var unicodeMode = false
        var unicodeBuffer = ""

        while index < json.endIndex {
            let character = json[index]
            index = json.index(after: index)

            if unicodeMode {
                unicodeBuffer.append(character)
                if unicodeBuffer.count == 4 {
                    if let scalarValue = UInt32(unicodeBuffer, radix: 16),
                       let scalar = UnicodeScalar(scalarValue) {
                        result.unicodeScalars.append(scalar)
                    }
                    unicodeMode = false
                    unicodeBuffer = ""
                }
                continue
            }

            if character == "\"" {
                break
            }
            if character != "\\" {
                result.append(character)
                continue
            }

            guard index < json.endIndex else { break }
            let escaped = json[index]
            index = json.index(after: index)
            switch escaped {
            case "\"":
                result.append("\"")
            case "\\":
                result.append("\\")
            case "/":
                result.append("/")
            case "b":
                result.append("\u{8}")
            case "f":
                result.append("\u{c}")
            case "n":
                result.append("\n")
            case "r":
                result.append("\r")
            case "t":
                result.append("\t")
            case "u":
                unicodeMode = true
                unicodeBuffer = ""
            default:
                result.append(escaped)
            }
        }

        return result
    }

    private func codeLanguageHint(for path: String?) -> String? {
        guard let path,
              let ext = path.split(separator: ".").last?.lowercased(),
              !ext.isEmpty else {
            return nil
        }
        switch ext {
        case "html", "htm", "css", "scss", "sass", "less", "js", "jsx", "ts", "tsx",
             "json", "md", "swift", "py", "rb", "go", "rs", "java", "kt", "sh", "zsh",
             "yml", "yaml", "xml", "sql":
            return ext == "htm" ? "html" : ext
        default:
            return nil
        }
    }

    private func normalizedToolLabel(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func localizedDesktopLabel(languageCode: String) -> String {
        L10n.text(languageCode: languageCode, zhHans: "桌面", en: "Desktop")
    }

    private func localizedDestinationLabel(languageCode: String) -> String {
        L10n.text(languageCode: languageCode, zhHans: "目标文件夹", en: "the destination folder")
    }

    private func metadata(
        sessionID: String,
        toolCallCount: Int,
        state: AskAgentSessionState,
        agentState: String
    ) -> [String: String] {
        var metadata = [
            "agent_handled": "true",
            "agent_state": agentState,
            "agent_tool_calls": String(toolCallCount),
            "latest_tool_name": state.toolCallHistory.last?.toolName ?? "",
            "session_id": sessionID,
            "session_origin": state.sessionOrigin.rawValue,
            "active_operation_id": state.activeOperationID ?? "",
            "pending_approval_action_id": state.approvalState?.actionID ?? "",
            "pending_automation_draft_id": state.pendingAutomationDraftID ?? "",
            "saved_automation_job_id": state.savedAutomationJobID ?? "",
            "inbox_item_id": state.inboxItemID ?? ""
        ]
        for (key, value) in state.kernelMetadata where !value.isEmpty {
            metadata[key] = value
        }
        if let encodedTimeline = AskAgentTimelineMetadataCodec.encode(state.currentTurnTimeline) {
            metadata["agent_timeline"] = encodedTimeline
        }
        return metadata
    }

    private func requestWithCurrentSessionState(
        _ request: AskSessionRequest,
        sessionState: AskAgentSessionState
    ) -> AskSessionRequest {
        AskSessionRequest(
            messages: request.messages,
            metadata: AskSessionMetadata(
                sessionID: request.metadata.sessionID,
                sourceBundleID: request.metadata.sourceBundleID,
                sourceAppName: request.metadata.sourceAppName,
                frame: request.metadata.frame,
                sessionOrigin: request.metadata.sessionOrigin,
                automationJobID: request.metadata.automationJobID,
                automationPolicy: request.metadata.automationPolicy,
                invocationSurface: request.metadata.invocationSurface,
                requestedMode: request.metadata.requestedMode,
                kernelMetadata: request.metadata.kernelMetadata.merging(sessionState.kernelMetadata) { _, current in current }
            ),
            uiLanguage: request.uiLanguage,
            responseLanguage: request.responseLanguage
        )
    }

    private func availableTools(
        responseLanguage: String,
        sessionState: AskAgentSessionState
    ) -> [AskToolDefinition] {
        toolRegistry.availableTools(
            context: .session(
                responseLanguage: responseLanguage,
                sessionState: sessionState
            )
        )
    }
}
