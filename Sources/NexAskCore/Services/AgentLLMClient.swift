import Foundation
import NexShared

enum AgentLLMClientError: LocalizedError, Equatable {
    case invalidBaseURL
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return L10n.text(zhHans: "Agent AI 服务地址无效。", en: "The agent AI service URL is invalid.")
        case .invalidResponse:
            return L10n.text(zhHans: "Agent AI 返回了无效响应。", en: "The agent AI returned an invalid response.")
        case .server(let message):
            return message
        }
    }
}

final class AgentLLMClient {
    private struct StreamedToolCallAccumulator {
        let key: String
        var id: String
        var name: String
        var arguments: String
    }

    private struct StreamedChatToolCallAccumulator {
        let key: String
        var id: String
        var name: String
        var arguments: String
    }

    private let session: URLSession
    private let diagnosticsLogger: DiagnosticsLogger

    init(
        session: URLSession = .shared,
        diagnosticsLogger: DiagnosticsLogger = .shared
    ) {
        self.session = session
        self.diagnosticsLogger = diagnosticsLogger
    }

    func respond(
        configuration: LLMRequestConfiguration,
        messages: [AskAgentMessage],
        tools: [AskToolDefinition],
        previousResponseID: String? = nil,
        responseProfile: AskResponseProfile = .detailed,
        onOutputTextDelta: (@Sendable (String) -> Void)? = nil,
        onToolCallDelta: (@Sendable (AskToolCall) -> Void)? = nil
    ) async throws -> AskAgentModelTurn {
        if shouldUseResponsesAPI(configuration: configuration) {
            return try await respondWithResponsesAPI(
                configuration: configuration,
                messages: messages,
                tools: tools,
                previousResponseID: previousResponseID,
                responseProfile: responseProfile,
                onOutputTextDelta: onOutputTextDelta,
                onToolCallDelta: onToolCallDelta
            )
        }

        return try await respondWithChatCompletions(
            configuration: configuration,
            messages: messages,
            tools: tools,
            responseProfile: responseProfile,
            onOutputTextDelta: onOutputTextDelta,
            onToolCallDelta: onToolCallDelta
        )
    }

    private func respondWithChatCompletions(
        configuration: LLMRequestConfiguration,
        messages: [AskAgentMessage],
        tools: [AskToolDefinition],
        responseProfile: AskResponseProfile,
        onOutputTextDelta: (@Sendable (String) -> Void)?,
        onToolCallDelta: (@Sendable (AskToolCall) -> Void)?
    ) async throws -> AskAgentModelTurn {
        if onOutputTextDelta != nil || onToolCallDelta != nil {
            return try await streamChatCompletions(
                configuration: configuration,
                messages: messages,
                tools: tools,
                responseProfile: responseProfile,
                onOutputTextDelta: onOutputTextDelta,
                onToolCallDelta: onToolCallDelta
            )
        }

        let request = try makeChatCompletionsRequest(
            configuration: configuration,
            messages: messages,
            tools: tools,
            responseProfile: responseProfile,
            stream: false
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return AskAgentModelTurn(
            response: try parseChatCompletionsResponse(from: data),
            responseID: nil
        )
    }

    private func respondWithResponsesAPI(
        configuration: LLMRequestConfiguration,
        messages: [AskAgentMessage],
        tools: [AskToolDefinition],
        previousResponseID: String?,
        responseProfile: AskResponseProfile,
        onOutputTextDelta: (@Sendable (String) -> Void)?,
        onToolCallDelta: (@Sendable (AskToolCall) -> Void)?
    ) async throws -> AskAgentModelTurn {
        if onOutputTextDelta != nil || onToolCallDelta != nil {
            return try await streamResponsesAPI(
                configuration: configuration,
                messages: messages,
                tools: tools,
                previousResponseID: previousResponseID,
                responseProfile: responseProfile,
                onOutputTextDelta: onOutputTextDelta,
                onToolCallDelta: onToolCallDelta
            )
        }
        let request = try makeResponsesRequest(
            configuration: configuration,
            messages: messages,
            tools: tools,
            previousResponseID: previousResponseID,
            responseProfile: responseProfile,
            stream: false
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try parseResponsesAPIResponse(from: data)
    }

    private func makeChatCompletionsRequest(
        configuration: LLMRequestConfiguration,
        messages: [AskAgentMessage],
        tools: [AskToolDefinition],
        responseProfile: AskResponseProfile,
        stream: Bool,
        maxTokensOverride: Int? = nil
    ) throws -> URLRequest {
        guard let url = chatCompletionsURL(baseURL: configuration.baseURL) else {
            throw AgentLLMClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")

        var payload: [String: Any] = [
            "model": configuration.model,
            "messages": messages.map(messagePayload(for:)),
            "temperature": 0,
            "max_tokens": maxTokensOverride ?? responseProfile.chatCompletionsMaxTokens,
            "stream": stream
        ]

        if !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters
                    ]
                ]
            }
            payload["tool_choice"] = "auto"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func makeResponsesRequest(
        configuration: LLMRequestConfiguration,
        messages: [AskAgentMessage],
        tools: [AskToolDefinition],
        previousResponseID: String?,
        responseProfile: AskResponseProfile,
        stream: Bool
    ) throws -> URLRequest {
        guard let url = responsesURL(baseURL: configuration.baseURL) else {
            throw AgentLLMClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")

        var payload: [String: Any] = [
            "model": configuration.model,
            "store": true,
            "max_output_tokens": responseProfile.responsesMaxOutputTokens,
            "stream": stream
        ]
        if let instructions = responsesInstructions(from: messages) {
            payload["instructions"] = instructions
        }

        if let previousResponseID,
           let toolOutputs = continuationFunctionOutputs(from: messages),
           !toolOutputs.isEmpty {
            payload["previous_response_id"] = previousResponseID
            payload["input"] = toolOutputs
        } else {
            payload["input"] = messages.compactMap(responseInputItem(for:))
        }

        if !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters
                ]
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func messagePayload(for message: AskAgentMessage) -> [String: Any] {
        switch message.role {
        case .system, .user:
            return [
                "role": message.role.rawValue,
                "content": message.content ?? ""
            ]
        case .assistant:
            var payload: [String: Any] = ["role": "assistant"]
            if let content = message.content {
                payload["content"] = content
            }
            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                payload["tool_calls"] = toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.argumentsJSON
                        ]
                    ]
                }
            }
            return payload
        case .tool:
            return [
                "role": "tool",
                "tool_call_id": message.toolCallID ?? "",
                "content": message.content ?? "",
                "name": message.toolName ?? ""
            ]
        }
    }

    private func parseChatCompletionsResponse(from data: Data) throws -> AskAgentModelResponse {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw AgentLLMClientError.invalidResponse
        }

        if let rawToolCalls = message["tool_calls"] as? [[String: Any]], !rawToolCalls.isEmpty {
            let calls = rawToolCalls.compactMap { item -> AskToolCall? in
                guard let id = item["id"] as? String,
                      let function = item["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let arguments = function["arguments"] as? String else {
                    return nil
                }
                return AskToolCall(id: id, name: name, argumentsJSON: arguments)
            }
            guard !calls.isEmpty else {
                throw AgentLLMClientError.invalidResponse
            }
            return .toolCalls(calls, assistantText: messageContent(from: message))
        }

        return .final(messageContent(from: message) ?? "")
    }

    private func parseChatCompletionsStreamFallback(from data: Data) throws -> AskAgentModelTurn {
        AskAgentModelTurn(
            response: try parseChatCompletionsResponse(from: data),
            responseID: nil
        )
    }

    private func parseResponsesAPIResponse(from data: Data) throws -> AskAgentModelTurn {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentLLMClientError.invalidResponse
        }

        let responseID = payload["id"] as? String
        let outputItems = payload["output"] as? [[String: Any]] ?? []
        let toolCalls = outputItems.compactMap { item -> AskToolCall? in
            guard (item["type"] as? String) == "function_call" else { return nil }
            let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString
            guard let name = item["name"] as? String,
                  let arguments = item["arguments"] as? String else {
                return nil
            }
            return AskToolCall(id: callID, name: name, argumentsJSON: arguments)
        }

        let assistantText = (payload["output_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? responsesOutputText(from: outputItems)

        let response: AskAgentModelResponse
        if !toolCalls.isEmpty {
            response = .toolCalls(toolCalls, assistantText: assistantText)
        } else {
            response = .final((assistantText ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return AskAgentModelTurn(response: response, responseID: responseID)
    }

    private func streamResponsesAPI(
        configuration: LLMRequestConfiguration,
        messages: [AskAgentMessage],
        tools: [AskToolDefinition],
        previousResponseID: String?,
        responseProfile: AskResponseProfile,
        onOutputTextDelta: (@Sendable (String) -> Void)?,
        onToolCallDelta: (@Sendable (AskToolCall) -> Void)?
    ) async throws -> AskAgentModelTurn {
        let traceID = String(UUID().uuidString.prefix(8)).lowercased()
        let startedAt = Date()
        diagnosticsLogger.log(
            "ask.stream",
            "trace=\(traceID) api=responses start provider=\(configuration.provider) model=\(configuration.model) host=\(hostLabel(for: configuration.baseURL)) previous_response=\(previousResponseID != nil) tool_count=\(tools.count)"
        )
        let request = try makeResponsesRequest(
            configuration: configuration,
            messages: messages,
            tools: tools,
            previousResponseID: previousResponseID,
            responseProfile: responseProfile,
            stream: true
        )
        let (bytes, response) = try await session.bytes(for: request)
        let headersAt = Date()
        guard let http = response as? HTTPURLResponse else {
            diagnosticsLogger.log("ask.stream", "trace=\(traceID) invalid_response elapsed_ms=\(elapsedMilliseconds(since: startedAt, until: headersAt))")
            throw AgentLLMClientError.invalidResponse
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        diagnosticsLogger.log(
            "ask.stream",
            "trace=\(traceID) api=responses headers status=\(http.statusCode) content_type=\(contentType) elapsed_ms=\(elapsedMilliseconds(since: startedAt, until: headersAt))"
        )
        guard (200..<300).contains(http.statusCode) else {
            let errorData = try await collectErrorData(from: bytes)
            diagnosticsLogger.log(
                "ask.stream",
                "trace=\(traceID) api=responses non_2xx status=\(http.statusCode) error_bytes=\(errorData?.count ?? 0)"
            )
            try validate(response: response, data: errorData ?? Data())
            throw AgentLLMClientError.invalidResponse
        }

        var responseID: String?
        var outputText = ""
        var toolCallsByKey: [String: StreamedToolCallAccumulator] = [:]
        var toolCallOrder: [String] = []
        var rawBodyLines: [String] = []
        var sawStreamPayload = false
        var payloadCount = 0
        var deltaCount = 0
        var firstPayloadAt: Date?
        var firstDeltaAt: Date?
        var eventTypeCounts: [String: Int] = [:]

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.hasPrefix("data:") else {
                rawBodyLines.append(trimmed)
                continue
            }
            sawStreamPayload = true
            let payloadText = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard payloadText != "[DONE]",
                  let data = payloadText.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            payloadCount += 1
            if firstPayloadAt == nil {
                firstPayloadAt = Date()
                diagnosticsLogger.log(
                    "ask.stream",
                    "trace=\(traceID) api=responses first_payload elapsed_ms=\(elapsedMilliseconds(since: startedAt, until: firstPayloadAt!))"
                )
            }
            let eventType = (payload["type"] as? String) ?? "unknown"
            eventTypeCounts[eventType, default: 0] += 1

            if let discoveredResponseID = streamedResponseID(from: payload) {
                responseID = discoveredResponseID
            }
            if let message = streamErrorMessage(from: payload) {
                diagnosticsLogger.log(
                    "ask.stream",
                    "trace=\(traceID) api=responses stream_error event_type=\(eventType) message=\(message)"
                )
                throw AgentLLMClientError.server(message)
            }
            if let delta = responsesOutputTextDelta(from: payload), !delta.isEmpty {
                let normalizedDelta = delta.replacingOccurrences(of: "\r\n", with: "\n")
                outputText += normalizedDelta
                deltaCount += 1
                if firstDeltaAt == nil {
                    firstDeltaAt = Date()
                    diagnosticsLogger.log(
                        "ask.stream",
                        "trace=\(traceID) api=responses first_delta elapsed_ms=\(elapsedMilliseconds(since: startedAt, until: firstDeltaAt!)) delta_chars=\(normalizedDelta.count) event_type=\(eventType)"
                    )
                }
                onOutputTextDelta?(normalizedDelta)
            }
            if let completeText = responsesCompletedOutputText(from: payload),
               outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outputText = completeText
            }
            let updatedToolCalls = mergeToolCallUpdate(
                from: payload,
                into: &toolCallsByKey,
                order: &toolCallOrder
            )
            updatedToolCalls.forEach { onToolCallDelta?($0) }
        }

        if !sawStreamPayload, !rawBodyLines.isEmpty {
            diagnosticsLogger.log(
                "ask.stream",
                "trace=\(traceID) api=responses non_sse_fallback raw_lines=\(rawBodyLines.count) elapsed_ms=\(elapsedMilliseconds(since: startedAt, until: Date())) content_type=\(contentType)"
            )
            return try parseResponsesAPIResponse(from: Data(rawBodyLines.joined(separator: "\n").utf8))
        }

        let toolCalls = toolCallOrder.compactMap { key -> AskToolCall? in
            guard let toolCall = toolCallsByKey[key] else { return nil }
            return AskToolCall(id: toolCall.id, name: toolCall.name, argumentsJSON: toolCall.arguments)
        }
        let assistantText = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnosticsLogger.log(
            "ask.stream",
            "trace=\(traceID) api=responses completed elapsed_ms=\(elapsedMilliseconds(since: startedAt, until: Date())) payloads=\(payloadCount) deltas=\(deltaCount) output_chars=\(assistantText.count) tool_calls=\(toolCalls.count) saw_stream=\(sawStreamPayload) saw_delta=\(firstDeltaAt != nil) event_types=\(eventTypeSummary(eventTypeCounts))"
        )
        let modelResponse: AskAgentModelResponse
        if !toolCalls.isEmpty {
            modelResponse = .toolCalls(toolCalls, assistantText: assistantText.isEmpty ? nil : assistantText)
        } else {
            modelResponse = .final(assistantText)
        }
        return AskAgentModelTurn(response: modelResponse, responseID: responseID)
    }

    private func streamChatCompletions(
        configuration: LLMRequestConfiguration,
        messages: [AskAgentMessage],
        tools: [AskToolDefinition],
        responseProfile: AskResponseProfile,
        onOutputTextDelta: (@Sendable (String) -> Void)?,
        onToolCallDelta: (@Sendable (AskToolCall) -> Void)?
    ) async throws -> AskAgentModelTurn {
        let traceID = String(UUID().uuidString.prefix(8)).lowercased()
        let startedAt = Date()
        diagnosticsLogger.log(
            "ask.stream",
            "trace=\(traceID) api=chat_completions start provider=\(configuration.provider) model=\(configuration.model) host=\(hostLabel(for: configuration.baseURL)) tool_count=\(tools.count)"
        )
        let request = try makeChatCompletionsRequest(
            configuration: configuration,
            messages: messages,
            tools: tools,
            responseProfile: responseProfile,
            stream: true
        )
        let (bytes, response) = try await session.bytes(for: request)
        let headersAt = Date()
        guard let http = response as? HTTPURLResponse else {
            diagnosticsLogger.log(
                "ask.stream",
                "trace=\(traceID) api=chat_completions invalid_response elapsed_ms=\(elapsedMilliseconds(since: startedAt, until: headersAt))"
            )
            throw AgentLLMClientError.invalidResponse
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        diagnosticsLogger.log(
            "ask.stream",
            "trace=\(traceID) api=chat_completions headers status=\(http.statusCode) content_type=\(contentType) elapsed_ms=\(elapsedMilliseconds(since: startedAt, until: headersAt))"
        )
        guard (200..<300).contains(http.statusCode) else {
            let errorData = try await collectErrorData(from: bytes)
            diagnosticsLogger.log(
                "ask.stream",
                "trace=\(traceID) api=chat_completions non_2xx status=\(http.statusCode) error_bytes=\(errorData?.count ?? 0)"
            )
            try validate(response: response, data: errorData ?? Data())
            throw AgentLLMClientError.invalidResponse
        }

        var outputText = ""
        var toolCallsByKey: [String: StreamedChatToolCallAccumulator] = [:]
        var toolCallOrder: [String] = []
        var rawBodyLines: [String] = []
        var sawStreamPayload = false
        var payloadCount = 0
        var deltaCount = 0
        var firstPayloadAt: Date?
        var firstDeltaAt: Date?
        var eventTypeCounts: [String: Int] = [:]
        var terminalFinishReason: String?

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.hasPrefix("data:") else {
                rawBodyLines.append(trimmed)
                continue
            }

            sawStreamPayload = true
            let payloadText = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard payloadText != "[DONE]",
                  let data = payloadText.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            payloadCount += 1
            if firstPayloadAt == nil {
                firstPayloadAt = Date()
                diagnosticsLogger.log(
                    "ask.stream",
                    "trace=\(traceID) api=chat_completions first_payload elapsed_ms=\(elapsedMilliseconds(since: startedAt, until: firstPayloadAt!))"
                )
            }

            let eventType = chatCompletionsEventType(from: payload)
            eventTypeCounts[eventType, default: 0] += 1
            if let finishReason = chatCompletionsFinishReason(from: payload) {
                terminalFinishReason = finishReason
            }

            if let message = streamErrorMessage(from: payload) {
                diagnosticsLogger.log(
                    "ask.stream",
                    "trace=\(traceID) api=chat_completions stream_error event_type=\(eventType) message=\(message)"
                )
                throw AgentLLMClientError.server(message)
            }

            if let delta = chatCompletionsOutputTextDelta(from: payload), !delta.isEmpty {
                let normalizedDelta = delta.replacingOccurrences(of: "\r\n", with: "\n")
                outputText += normalizedDelta
                deltaCount += 1
                if firstDeltaAt == nil {
                    firstDeltaAt = Date()
                    diagnosticsLogger.log(
                        "ask.stream",
                        "trace=\(traceID) api=chat_completions first_delta elapsed_ms=\(elapsedMilliseconds(since: startedAt, until: firstDeltaAt!)) delta_chars=\(normalizedDelta.count) event_type=\(eventType)"
                    )
                }
                onOutputTextDelta?(normalizedDelta)
            }

            let updatedToolCalls = mergeChatToolCallUpdate(
                from: payload,
                into: &toolCallsByKey,
                order: &toolCallOrder
            )
            updatedToolCalls.forEach { onToolCallDelta?($0) }
        }

        if !sawStreamPayload, !rawBodyLines.isEmpty {
            diagnosticsLogger.log(
                "ask.stream",
                "trace=\(traceID) api=chat_completions non_sse_fallback raw_lines=\(rawBodyLines.count) elapsed_ms=\(elapsedMilliseconds(since: startedAt, until: Date())) content_type=\(contentType)"
            )
            return try parseChatCompletionsStreamFallback(from: Data(rawBodyLines.joined(separator: "\n").utf8))
        }

        let toolCalls = toolCallOrder.compactMap { key -> AskToolCall? in
            guard let toolCall = toolCallsByKey[key] else { return nil }
            return AskToolCall(id: toolCall.id, name: toolCall.name, argumentsJSON: toolCall.arguments)
        }
        let assistantText = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnosticsLogger.log(
            "ask.stream",
            "trace=\(traceID) api=chat_completions completed elapsed_ms=\(elapsedMilliseconds(since: startedAt, until: Date())) payloads=\(payloadCount) deltas=\(deltaCount) output_chars=\(assistantText.count) tool_calls=\(toolCalls.count) saw_stream=\(sawStreamPayload) saw_delta=\(firstDeltaAt != nil) event_types=\(eventTypeSummary(eventTypeCounts))"
        )

        if terminalFinishReason == "length" {
            diagnosticsLogger.log(
                "ask.stream",
                "trace=\(traceID) api=chat_completions length_fallback tool_calls=\(toolCalls.count) output_chars=\(assistantText.count)"
            )
            return try await recoverLengthLimitedChatCompletions(
                configuration: configuration,
                messages: messages,
                tools: tools,
                responseProfile: responseProfile
            )
        }

        let modelResponse: AskAgentModelResponse
        if !toolCalls.isEmpty {
            modelResponse = .toolCalls(toolCalls, assistantText: assistantText.isEmpty ? nil : assistantText)
        } else {
            modelResponse = .final(assistantText)
        }
        return AskAgentModelTurn(response: modelResponse, responseID: nil)
    }

    private func messageContent(from message: [String: Any]) -> String? {
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let content = message["content"] as? [[String: Any]] {
            return content.compactMap { part -> String? in
                guard (part["type"] as? String) == "text" else { return nil }
                return part["text"] as? String
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func responsesOutputText(from items: [[String: Any]]) -> String? {
        for item in items {
            if let type = item["type"] as? String, type == "message",
               let content = item["content"] as? [[String: Any]] {
                let text = content.compactMap { part -> String? in
                    let partType = part["type"] as? String
                    if partType == "output_text" || partType == "text" {
                        return part["text"] as? String
                    }
                    return nil
                }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AgentLLMClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = [
                payload?["message"] as? String,
                payload?["error"] as? String,
                payload?["detail"] as? String,
                (payload?["error"] as? [String: Any])?["message"] as? String,
                (payload?["error"] as? [String: Any])?["detail"] as? String
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            throw AgentLLMClientError.server(
                message ?? L10n.format(zhHans: "Agent 请求失败（HTTP %@）。", en: "Agent request failed (HTTP %@).", String(http.statusCode))
            )
        }
    }

    private func streamedResponseID(from payload: [String: Any]) -> String? {
        if let response = payload["response"] as? [String: Any],
           let id = response["id"] as? String,
           !id.isEmpty {
            return id
        }
        if let responseID = payload["response_id"] as? String, !responseID.isEmpty {
            return responseID
        }
        if let id = payload["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func streamErrorMessage(from payload: [String: Any]) -> String? {
        [
            payload["message"] as? String,
            payload["error"] as? String,
            payload["detail"] as? String,
            (payload["error"] as? [String: Any])?["message"] as? String,
            (payload["error"] as? [String: Any])?["detail"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })
    }

    private func responsesOutputTextDelta(from payload: [String: Any]) -> String? {
        guard let type = payload["type"] as? String else { return nil }
        switch type {
        case "response.output_text.delta", "response.text.delta":
            return payload["delta"] as? String
        default:
            return nil
        }
    }

    private func responsesCompletedOutputText(from payload: [String: Any]) -> String? {
        if let response = payload["response"] as? [String: Any] {
            if let outputText = response["output_text"] as? String,
               !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let outputItems = response["output"] as? [[String: Any]],
               let text = responsesOutputText(from: outputItems),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func mergeToolCallUpdate(
        from payload: [String: Any],
        into storage: inout [String: StreamedToolCallAccumulator],
        order: inout [String]
    ) -> [AskToolCall] {
        let type = payload["type"] as? String
        let item = payload["item"] as? [String: Any]
        var updatedKeys: [String] = []

        if let item, (item["type"] as? String) == "function_call",
           let key = streamedToolCallKey(payload: payload, item: item) {
            if storage[key] == nil {
                order.append(key)
                storage[key] = StreamedToolCallAccumulator(
                    key: key,
                    id: streamedToolCallID(payload: payload, item: item, key: key),
                    name: item["name"] as? String ?? "",
                    arguments: item["arguments"] as? String ?? ""
                )
                updatedKeys.append(key)
            } else {
                storage[key]?.id = streamedToolCallID(payload: payload, item: item, key: key)
                if let name = item["name"] as? String, !name.isEmpty {
                    storage[key]?.name = name
                    updatedKeys.append(key)
                }
                if let arguments = item["arguments"] as? String, !arguments.isEmpty {
                    storage[key]?.arguments = arguments
                    updatedKeys.append(key)
                }
            }
        }

        guard let type else {
            return compactToolCalls(for: updatedKeys, storage: storage)
        }
        switch type {
        case "response.function_call_arguments.delta":
            guard let key = streamedToolCallKey(payload: payload, item: item) else {
                return compactToolCalls(for: updatedKeys, storage: storage)
            }
            if storage[key] == nil {
                order.append(key)
                storage[key] = StreamedToolCallAccumulator(
                    key: key,
                    id: streamedToolCallID(payload: payload, item: item, key: key),
                    name: payload["name"] as? String ?? item?["name"] as? String ?? "",
                    arguments: ""
                )
                updatedKeys.append(key)
            }
            if let delta = payload["delta"] as? String, !delta.isEmpty {
                storage[key]?.arguments += delta
                updatedKeys.append(key)
            }
        case "response.function_call_arguments.done":
            guard let key = streamedToolCallKey(payload: payload, item: item) else {
                return compactToolCalls(for: updatedKeys, storage: storage)
            }
            if storage[key] == nil {
                order.append(key)
                storage[key] = StreamedToolCallAccumulator(
                    key: key,
                    id: streamedToolCallID(payload: payload, item: item, key: key),
                    name: payload["name"] as? String ?? item?["name"] as? String ?? "",
                    arguments: ""
                )
                updatedKeys.append(key)
            }
            if let arguments = payload["arguments"] as? String, !arguments.isEmpty {
                storage[key]?.arguments = arguments
                updatedKeys.append(key)
            }
        case "response.output_item.done":
            guard let item, (item["type"] as? String) == "function_call",
                  let key = streamedToolCallKey(payload: payload, item: item) else {
                return compactToolCalls(for: updatedKeys, storage: storage)
            }
            if storage[key] == nil {
                order.append(key)
                storage[key] = StreamedToolCallAccumulator(
                    key: key,
                    id: streamedToolCallID(payload: payload, item: item, key: key),
                    name: item["name"] as? String ?? "",
                    arguments: item["arguments"] as? String ?? ""
                )
                updatedKeys.append(key)
            } else {
                storage[key]?.id = streamedToolCallID(payload: payload, item: item, key: key)
                if let name = item["name"] as? String, !name.isEmpty {
                    storage[key]?.name = name
                    updatedKeys.append(key)
                }
                if let arguments = item["arguments"] as? String, !arguments.isEmpty {
                    storage[key]?.arguments = arguments
                    updatedKeys.append(key)
                }
            }
        default:
            break
        }
        return compactToolCalls(for: updatedKeys, storage: storage)
    }

    private func chatCompletionsEventType(from payload: [String: Any]) -> String {
        guard let choices = payload["choices"] as? [[String: Any]],
              let firstChoice = choices.first else {
            return "chunk"
        }
        if let finishReason = firstChoice["finish_reason"] as? String,
           !finishReason.isEmpty {
            return "finish_\(finishReason)"
        }
        return "chunk"
    }

    private func chatCompletionsFinishReason(from payload: [String: Any]) -> String? {
        guard let choices = payload["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let finishReason = firstChoice["finish_reason"] as? String,
              !finishReason.isEmpty else {
            return nil
        }
        return finishReason
    }

    private func chatCompletionsOutputTextDelta(from payload: [String: Any]) -> String? {
        guard let choices = payload["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any] else {
            return nil
        }

        if let content = delta["content"] as? String {
            return content
        }
        if let content = delta["content"] as? [[String: Any]] {
            return content.compactMap { item -> String? in
                guard (item["type"] as? String) == "text" else { return nil }
                return item["text"] as? String
            }.joined()
        }
        return nil
    }

    private func mergeChatToolCallUpdate(
        from payload: [String: Any],
        into storage: inout [String: StreamedChatToolCallAccumulator],
        order: inout [String]
    ) -> [AskToolCall] {
        guard let choices = payload["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let toolCalls = delta["tool_calls"] as? [[String: Any]] else {
            return []
        }

        var updatedKeys: [String] = []
        for item in toolCalls {
            let key = chatCompletionsToolCallKey(from: item)
            if storage[key] == nil {
                order.append(key)
                storage[key] = StreamedChatToolCallAccumulator(
                    key: key,
                    id: chatCompletionsToolCallID(from: item, key: key),
                    name: "",
                    arguments: ""
                )
                updatedKeys.append(key)
            }

            if let id = item["id"] as? String, !id.isEmpty {
                storage[key]?.id = id
                updatedKeys.append(key)
            }
            if let function = item["function"] as? [String: Any] {
                if let name = function["name"] as? String, !name.isEmpty {
                    if storage[key]?.name.isEmpty ?? true {
                        storage[key]?.name = name
                        updatedKeys.append(key)
                    } else if storage[key]?.name != name,
                              !(storage[key]?.name.hasSuffix(name) ?? false) {
                        storage[key]?.name += name
                        updatedKeys.append(key)
                    }
                }
                if let arguments = function["arguments"] as? String, !arguments.isEmpty {
                    storage[key]?.arguments += arguments
                    updatedKeys.append(key)
                }
            }
        }
        return compactChatToolCalls(for: updatedKeys, storage: storage)
    }

    private func compactToolCalls(
        for keys: [String],
        storage: [String: StreamedToolCallAccumulator]
    ) -> [AskToolCall] {
        uniqueToolCallKeys(keys).compactMap { key in
            guard let toolCall = storage[key] else { return nil }
            return AskToolCall(id: toolCall.id, name: toolCall.name, argumentsJSON: toolCall.arguments)
        }
    }

    private func compactChatToolCalls(
        for keys: [String],
        storage: [String: StreamedChatToolCallAccumulator]
    ) -> [AskToolCall] {
        uniqueToolCallKeys(keys).compactMap { key in
            guard let toolCall = storage[key] else { return nil }
            return AskToolCall(id: toolCall.id, name: toolCall.name, argumentsJSON: toolCall.arguments)
        }
    }

    private func uniqueToolCallKeys(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    private func chatCompletionsToolCallKey(from item: [String: Any]) -> String {
        if let rawIndex = item["index"] {
            return String(describing: rawIndex)
        }
        if let id = item["id"] as? String, !id.isEmpty {
            return id
        }
        return UUID().uuidString
    }

    private func chatCompletionsToolCallID(from item: [String: Any], key: String) -> String {
        if let id = item["id"] as? String, !id.isEmpty {
            return id
        }
        return key
    }

    private func streamedToolCallKey(payload: [String: Any], item: [String: Any]?) -> String? {
        if let callID = (item?["call_id"] as? String) ?? (payload["call_id"] as? String), !callID.isEmpty {
            return callID
        }
        if let itemID = (item?["id"] as? String) ?? (payload["item_id"] as? String), !itemID.isEmpty {
            return itemID
        }
        if let outputIndex = payload["output_index"] {
            return String(describing: outputIndex)
        }
        return nil
    }

    private func streamedToolCallID(payload: [String: Any], item: [String: Any]?, key: String) -> String {
        let candidate = (item?["call_id"] as? String)
            ?? (payload["call_id"] as? String)
            ?? (item?["id"] as? String)
            ?? (payload["item_id"] as? String)
        return candidate?.isEmpty == false ? candidate! : key
    }

    private func collectErrorData(from bytes: URLSession.AsyncBytes) async throws -> Data? {
        var lines: [String] = []
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(trimmed)
            if lines.joined(separator: "\n").count >= 4096 {
                break
            }
        }
        guard !lines.isEmpty else { return nil }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func recoverLengthLimitedChatCompletions(
        configuration: LLMRequestConfiguration,
        messages: [AskAgentMessage],
        tools: [AskToolDefinition],
        responseProfile: AskResponseProfile
    ) async throws -> AskAgentModelTurn {
        let retryMaxTokens = min(
            max(
                responseProfile.chatCompletionsMaxTokens * 2,
                responseProfile.chatCompletionsMaxTokens + 1600,
                8000
            ),
            16000
        )
        let request = try makeChatCompletionsRequest(
            configuration: configuration,
            messages: messages,
            tools: tools,
            responseProfile: responseProfile,
            stream: false,
            maxTokensOverride: retryMaxTokens
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return AskAgentModelTurn(
            response: try parseChatCompletionsResponse(from: data),
            responseID: nil
        )
    }

    private func chatCompletionsURL(baseURL: String) -> URL? {
        guard let base = URL(string: baseURL) else { return nil }
        return base.appendingPathComponent("v1/chat/completions")
    }

    private func responsesURL(baseURL: String) -> URL? {
        guard let base = URL(string: baseURL) else { return nil }
        return base.appendingPathComponent("v1/responses")
    }

    private func shouldUseResponsesAPI(configuration: LLMRequestConfiguration) -> Bool {
        configuration.provider == "openai"
    }

    private func hostLabel(for baseURL: String) -> String {
        URL(string: baseURL)?.host ?? baseURL
    }

    private func elapsedMilliseconds(since start: Date, until end: Date) -> Int {
        Int(end.timeIntervalSince(start) * 1000)
    }

    private func eventTypeSummary(_ counts: [String: Int]) -> String {
        counts.keys.sorted().map { key in
            "\(key)=\(counts[key] ?? 0)"
        }.joined(separator: ",")
    }

    private func responseInputItem(for message: AskAgentMessage) -> [String: Any]? {
        switch message.role {
        case .system:
            return nil
        case .user, .assistant:
            guard let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                return nil
            }
            return [
                "role": message.role.rawValue,
                "content": content
            ]
        case .tool:
            return nil
        }
    }

    private func continuationFunctionOutputs(from messages: [AskAgentMessage]) -> [[String: Any]]? {
        var items: [[String: Any]] = []
        for message in messages.reversed() {
            guard message.role == .tool else {
                if !items.isEmpty {
                    break
                }
                continue
            }
            items.append([
                "type": "function_call_output",
                "call_id": message.toolCallID ?? "",
                "output": message.content ?? ""
            ])
        }
        return items.reversed()
    }

    private func responsesInstructions(from messages: [AskAgentMessage]) -> String? {
        let sections = messages
            .filter { $0.role == .system }
            .compactMap { $0.content?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }
}
