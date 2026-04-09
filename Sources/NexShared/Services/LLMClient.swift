import Foundation

package enum LLMClientError: LocalizedError, Equatable {
    case unsupportedProvider(String)
    case missingAPIKey
    case invalidBaseURL
    case invalidResponse
    case server(String)

    package var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            return L10n.format(zhHans: "不支持的服务商：%@", en: "Unsupported provider: %@", provider)
        case .missingAPIKey:
            return L10n.text(zhHans: "请先配置 API Key。", en: "Configure an API key first.")
        case .invalidBaseURL:
            return L10n.text(zhHans: "AI 服务地址无效。", en: "The AI service URL is invalid.")
        case .invalidResponse:
            return L10n.text(zhHans: "AI 服务返回了无效响应。", en: "The AI service returned an invalid response.")
        case .server(let message):
            return message
        }
    }
}

package struct LLMChatMessage: Equatable {
    package enum Role: String {
        case system
        case user
        case assistant
    }

    package let role: Role
    package let content: String

    package init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

struct LLMProviderDescriptor {
    let providerID: String
    let defaultModel: String
    let baseURL: String
    let baseURLEnvironmentKey: String

    static func resolve(provider rawProvider: String, model rawModel: String) throws -> LLMProviderDescriptor {
        let provider = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch provider {
        case "", "openai":
            return .init(providerID: "openai", defaultModel: rawModel.isEmpty ? "gpt-4.1-mini" : rawModel, baseURL: "https://api.openai.com", baseURLEnvironmentKey: "OPENAI_BASE_URL")
        case "gemini":
            return .init(providerID: "gemini", defaultModel: rawModel.isEmpty ? "gemini-2.0-flash" : rawModel, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", baseURLEnvironmentKey: "GEMINI_BASE_URL")
        case "deepseek":
            return .init(providerID: "deepseek", defaultModel: rawModel.isEmpty ? "deepseek-chat" : rawModel, baseURL: "https://api.deepseek.com", baseURLEnvironmentKey: "DEEPSEEK_BASE_URL")
        default:
            throw LLMClientError.unsupportedProvider(rawProvider)
        }
    }
}

package struct LLMRequestConfiguration {
    package let provider: String
    package let model: String
    package let apiKey: String
    package let baseURL: String

    package static func from(settings: AppSettings) throws -> LLMRequestConfiguration {
        let descriptor = try LLMProviderDescriptor.resolve(provider: settings.llmProvider, model: settings.llmModel)
        let baseURL = ProcessInfo.processInfo.environment[descriptor.baseURLEnvironmentKey] ?? descriptor.baseURL
        return .init(
            provider: descriptor.providerID,
            model: descriptor.defaultModel,
            apiKey: settings.llmApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL
        )
    }

    package static func from(provider: String, model: String, apiKey: String) throws -> LLMRequestConfiguration {
        let descriptor = try LLMProviderDescriptor.resolve(provider: provider, model: model)
        let baseURL = ProcessInfo.processInfo.environment[descriptor.baseURLEnvironmentKey] ?? descriptor.baseURL
        return .init(
            provider: descriptor.providerID,
            model: descriptor.defaultModel,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL
        )
    }
}

final class LLMClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validate(configuration: LLMRequestConfiguration) async -> AIConfigurationValidationResult {
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            return AIConfigurationValidationResult(
                ok: false,
                message: L10n.text(zhHans: "验证失败：请先填写 API Key。", en: "Validation failed: enter an API key first.")
            )
        }

        guard let url = modelsURL(baseURL: configuration.baseURL) else {
            return AIConfigurationValidationResult(
                ok: false,
                message: L10n.text(zhHans: "验证失败：AI 服务地址无效。", en: "Validation failed: invalid AI service URL.")
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return AIConfigurationValidationResult(
                    ok: false,
                    message: L10n.text(zhHans: "验证失败：无效响应。", en: "Validation failed: invalid response.")
                )
            }
            if (200..<300).contains(http.statusCode) {
                let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                if let message = payload?["message"] as? String, !message.isEmpty {
                    return .init(ok: true, message: message)
                }
                return .init(
                    ok: true,
                    message: L10n.text(zhHans: "连接成功。", en: "Connection succeeded.")
                )
            }
            return .init(ok: false, message: serverMessage(from: data) ?? L10n.format(zhHans: "验证失败（HTTP %@）。", en: "Validation failed (HTTP %@).", String(http.statusCode)))
        } catch {
            return .init(
                ok: false,
                message: L10n.format(zhHans: "验证失败：%@", en: "Validation failed: %@", error.localizedDescription)
            )
        }
    }

    func complete(
        configuration: LLMRequestConfiguration,
        messages: [LLMChatMessage],
        maxTokens: Int = 900,
        temperature: Double = 0.0,
        timeout: TimeInterval = 45
    ) async throws -> String {
        let request = try makeChatCompletionsRequest(
            configuration: configuration,
            messages: messages,
            stream: false,
            maxTokens: maxTokens,
            temperature: temperature,
            timeout: timeout
        )
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
        return try parseCompletionText(from: data)
    }

    func stream(
        configuration: LLMRequestConfiguration,
        messages: [LLMChatMessage],
        maxTokens: Int = 900,
        temperature: Double = 0.0,
        timeout: TimeInterval = 90,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let request = try makeChatCompletionsRequest(
            configuration: configuration,
            messages: messages,
            stream: true,
            maxTokens: maxTokens,
            temperature: temperature,
            timeout: timeout
        )
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let errorData = try await collectErrorData(from: bytes)
            try validateHTTPResponse(response, data: errorData)
            throw LLMClientError.invalidResponse
        }

        var fullText = ""
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payloadText = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard payloadText != "[DONE]" else { break }
            guard let data = payloadText.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let delta = Self.extractDeltaText(from: payload),
                  !delta.isEmpty else {
                continue
            }
            let normalizedDelta = delta.replacingOccurrences(of: "\r\n", with: "\n")
            fullText += normalizedDelta
            onDelta(normalizedDelta)
        }
        return fullText
    }

    private func makeChatCompletionsRequest(
        configuration: LLMRequestConfiguration,
        messages: [LLMChatMessage],
        stream: Bool,
        maxTokens: Int,
        temperature: Double,
        timeout: TimeInterval
    ) throws -> URLRequest {
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw LLMClientError.missingAPIKey }
        guard let url = chatCompletionsURL(baseURL: configuration.baseURL) else { throw LLMClientError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "model": configuration.model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": stream
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMClientError.server(serverMessage(from: data) ?? L10n.format(zhHans: "请求失败（HTTP %@）。", en: "Request failed (HTTP %@).", String(http.statusCode)))
        }
    }

    private func parseCompletionText(from data: Data) throws -> String {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMClientError.invalidResponse
        }

        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let content = message["content"] as? [[String: Any]] {
            let parts = content.compactMap { part -> String? in
                guard (part["type"] as? String) == "text" else { return nil }
                return part["text"] as? String
            }
            return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw LLMClientError.invalidResponse
    }

    private static func extractDeltaText(from payload: [String: Any]) -> String? {
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

    private func serverMessage(from data: Data?) -> String? {
        guard let data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return [
            payload["message"] as? String,
            payload["error"] as? String,
            payload["detail"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })
    }

    private func collectErrorData(from bytes: URLSession.AsyncBytes) async throws -> Data? {
        var lines: [String] = []
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(trimmed)
            if lines.joined(separator: "\n").count >= 2048 {
                break
            }
        }
        guard !lines.isEmpty else { return nil }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func modelsURL(baseURL: String) -> URL? {
        guard let base = URL(string: baseURL) else { return nil }
        return base.appendingPathComponent("v1/models")
    }

    private func chatCompletionsURL(baseURL: String) -> URL? {
        guard let base = URL(string: baseURL) else { return nil }
        return base.appendingPathComponent("v1/chat/completions")
    }
}
