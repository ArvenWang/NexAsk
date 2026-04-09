import AppKit
import Foundation

enum QuickAction: String, CaseIterable {
    case translate
    case trace
    case explain
    case reply
    case schedule
    case collect
    case compress = "compress"
    case screenshotOCR = "screenshot_ocr"
    case screenshotSave = "screenshot_save"

    var skillID: String { rawValue }

    init?(skillID: String) {
        self.init(rawValue: skillID)
    }
}

struct TranslationResult: Codable {
    let translatedText: String
    let detectedLanguage: String
    let targetLanguage: String
}

package struct SourceRecord: Codable {
    package let title: String
    package let url: String
    package let snippet: String
    package let publishedAt: String?
    package let sourceType: String?
    package let isOfficial: Bool?
}

struct TraceEntity: Codable {
    let name: String
    let entityType: String
    let title: String
    let url: String
    let snippet: String
    let whyThis: String?
    let isOfficial: Bool?
}

struct TraceResult: Codable {
    let summary: String
    let confidence: Double
    let timeline: [String]
    let sources: [SourceRecord]
    let primaryEntity: TraceEntity?
    let primaryEntities: [TraceEntity]?
    let relatedEntities: [TraceEntity]?
    let whyThis: String?
    let eventSummary: String?
}

struct ReplyResult: Codable {
    let replyText: String
}

struct ExplainResult: Codable {
    let explanationText: String
}

enum ActionResult {
    case translate(TranslationResult)
    case trace(TraceResult)
    case explain(ExplainResult)
    case reply(ReplyResult)
    case info(String)
}

enum ActionError: LocalizedError, Equatable {
    case network(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .network(let message):
            return message
        case .invalidResponse:
            return L10n.text(zhHans: "服务返回异常，请稍后重试。", en: "The service returned an invalid response. Please try again shortly.")
        }
    }
}

final class SkillExecutionService {
    private let session: URLSession
    private let settings: AppSettings
    private let knowledgeBaseCollectService: KnowledgeBaseCollectService
    private let runtimeService: SkillRuntimeService
    private let managedConfigurationProvider: () -> LLMRequestConfiguration?

    init(
        session: URLSession = .shared,
        settings: AppSettings = .shared,
        knowledgeBaseCollectService: KnowledgeBaseCollectService? = nil,
        runtimeService: SkillRuntimeService = .shared,
        managedConfigurationProvider: @escaping () -> LLMRequestConfiguration? = {
            ManagedAIConfigurationService.shared.currentConfiguration()
        }
    ) {
        self.session = session
        self.settings = settings
        self.knowledgeBaseCollectService = knowledgeBaseCollectService ?? KnowledgeBaseCollectService(session: session)
        self.runtimeService = runtimeService
        self.managedConfigurationProvider = managedConfigurationProvider
    }

    func runEnvelope(request: SkillExecutionRequest) async -> Result<SkillResultEnvelope, Error> {
        if request.definition.manifest.execution.mode == .localOnly {
            return .success(await runLocalEnvelope(request: request))
        }
        do {
            let response = try await runtimeService.runEnvelope(request: request)
            return .success(response)
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch {
            if Task.isCancelled {
                return .failure(CancellationError())
            }
            if let actionError = runtimeActionError(for: error) {
                return .failure(actionError)
            }
            if shouldSurfaceRuntimeFailure(for: request.definition) {
                return .failure(error)
            }
        }

        if shouldSurfaceRuntimeFailure(for: request.definition) {
            return .failure(ActionError.network(aiUnavailableMessage(for: request.context.responseLanguage)))
        }
        return .success(localFallbackEnvelope(request: request))
    }

    func runStreamingEnvelope(
        request: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async -> Result<SkillResultEnvelope, Error> {
        if request.definition.manifest.execution.mode == .localOnly {
            if request.definition.skillID == "collect" {
                return .success(await knowledgeBaseCollectService.runStreaming(request: request, onEvent: onEvent))
            }
            return .success(await runLocalEnvelope(request: request))
        }
        do {
            let result = try await runtimeService.runStreamingEnvelope(
                request: request,
                onEvent: onEvent
            )
            return .success(result)
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch {
            if Task.isCancelled {
                return .failure(CancellationError())
            }
            if let actionError = runtimeActionError(for: error) {
                return .failure(actionError)
            }
            if shouldSurfaceRuntimeFailure(for: request.definition) {
                return .failure(error)
            }
        }

        if shouldSurfaceRuntimeFailure(for: request.definition) {
            return .failure(ActionError.network(aiUnavailableMessage(for: request.context.responseLanguage)))
        }
        let fallbackEnvelope = localFallbackEnvelope(request: request)
        let fallback = localFallback(request: request)
        switch fallback {
        case .translate(let payload):
            onEvent(.init(type: .delta, delta: payload.translatedText, fullText: payload.translatedText))
        case .trace(let payload):
            if let entities = payload.primaryEntities, !entities.isEmpty,
               let supplement = ResultSchemaAdapter.traceSupplementEvent(for: entities) {
                onEvent(supplement)
            } else if let entity = payload.primaryEntity,
                      let supplement = ResultSchemaAdapter.traceSupplementEvent(for: [entity]) {
                onEvent(supplement)
            }
            onEvent(.init(type: .delta, delta: payload.summary, fullText: payload.summary))
        case .explain(let payload):
            onEvent(.init(type: .delta, delta: payload.explanationText, fullText: payload.explanationText))
        case .reply(let payload):
            onEvent(.init(type: .delta, delta: payload.replyText, fullText: payload.replyText))
        case .info(let text):
            onEvent(.init(type: .delta, delta: text, fullText: text))
        }
        return .success(fallbackEnvelope)
    }

    private func shouldSurfaceRuntimeFailure(for definition: SkillDefinition) -> Bool {
        definition.toolCapabilities.contains(.llmChat)
    }

    private func aiUnavailableMessage(for languageCode: String) -> String {
        localizedContentText(
            zhHans: "当前托管 AI 服务暂不可用，请稍后重试。",
            en: "Managed AI is temporarily unavailable. Please try again later.",
            languageCode: languageCode
        )
    }

    private func runtimeActionError(for error: Error) -> ActionError? {
        if let actionError = error as? ActionError {
            return actionError
        }
        if let llmError = error as? LLMClientError {
            switch llmError {
            case .invalidResponse:
                return .invalidResponse
            case .server(let message):
                return .network(message)
            case .unsupportedProvider, .missingAPIKey, .invalidBaseURL:
                return .network(llmError.localizedDescription)
            }
        }
        return nil
    }

    private func runViaGatewayEnvelope(request executionRequest: SkillExecutionRequest) async throws -> SkillResultEnvelope {
        let request = try makeRequest(request: executionRequest, stream: false)
        let (data, response) = try await session.data(for: request)
        try validateGatewayResponse(response, data: data)
        return try decodeResultEnvelope(
            definition: executionRequest.definition,
            context: executionRequest.context,
            payloadData: data
        )
    }

    private func runLocalEnvelope(request executionRequest: SkillExecutionRequest) async -> SkillResultEnvelope {
        switch executionRequest.definition.skillID {
        case "collect":
            return await knowledgeBaseCollectService.run(request: executionRequest)
        default:
            return localFallbackEnvelope(request: executionRequest)
        }
    }

    private func runStreamViaGatewayEnvelope(
        request executionRequest: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async throws -> SkillResultEnvelope {
        let request = try makeRequest(request: executionRequest, stream: true)
        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ActionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw gatewayResponseError(data: try await collectGatewayErrorData(from: bytes))
        }

        var partial = ""
        var finalEnvelope: SkillResultEnvelope?

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            guard let data = trimmed.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = payload["type"] as? String else {
                continue
            }

            switch type {
            case "status", "start":
                if let status = payload["status"] as? String, !status.isEmpty {
                    onEvent(.init(type: .status, status: status, detail: payload["detail"] as? String))
                }

            case "supplement":
                let cards: [SkillResultCard]?
                if let cardsPayload = payload["cards"] {
                    let cardsData = try JSONSerialization.data(withJSONObject: cardsPayload)
                    cards = try JSONDecoder().decode([SkillResultCard].self, from: cardsData)
                } else {
                    cards = nil
                }

                let artifacts: [SkillArtifact]?
                if let artifactsPayload = payload["artifacts"] {
                    let artifactsData = try JSONSerialization.data(withJSONObject: artifactsPayload)
                    artifacts = try JSONDecoder().decode([SkillArtifact].self, from: artifactsData)
                } else {
                    artifacts = nil
                }

                onEvent(.init(type: .supplement, cards: cards, artifacts: artifacts))

            case "entities":
                if let entitiesPayload = payload["entities"] {
                    let entityData = try JSONSerialization.data(withJSONObject: entitiesPayload)
                    let entities = try JSONDecoder().decode([TraceEntity].self, from: entityData)
                    if let event = ResultSchemaAdapter.traceSupplementEvent(for: entities) {
                        onEvent(event)
                    }
                }

            case "delta":
                if let delta = payload["delta"] as? String {
                    let incoming = (payload["full_text"] as? String) ?? delta
                    let merge = mergeStreamingText(current: partial, incoming: incoming)
                    guard !merge.appended.isEmpty else { continue }
                    partial = merge.fullText
                    onEvent(.init(type: .delta, delta: merge.appended, fullText: partial))
                }

            case "done":
                if let resultDict = payload["result"] as? [String: Any] {
                    let resultData = try JSONSerialization.data(withJSONObject: resultDict)
                    finalEnvelope = try decodeResultEnvelope(
                        definition: executionRequest.definition,
                        context: executionRequest.context,
                        payloadData: resultData
                    )
                }

            case "error":
                onEvent(
                    .init(
                        type: .error,
                        detail: payload["detail"] as? String,
                        message: (payload["message"] as? String) ?? (payload["detail"] as? String)
                    )
                )

            default:
                continue
            }
        }

        if let finalEnvelope {
            return finalEnvelope
        }

        if !partial.isEmpty {
            return partialFallbackEnvelope(
                definition: executionRequest.definition,
                context: executionRequest.context,
                partial: partial
            )
        }

        throw ActionError.invalidResponse
    }

    private func mergeStreamingText(current: String, incoming: String) -> (appended: String, fullText: String) {
        let normalizedIncoming = incoming.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalizedIncoming.isEmpty else {
            return ("", current)
        }

        guard !current.isEmpty else {
            return (normalizedIncoming, normalizedIncoming)
        }

        if normalizedIncoming == current || current.hasSuffix(normalizedIncoming) {
            return ("", current)
        }

        if normalizedIncoming.hasPrefix(current) {
            let remainder = String(normalizedIncoming.dropFirst(current.count))
            return (remainder, normalizedIncoming)
        }

        let overlap = longestSuffixPrefixOverlap(current: current, incoming: normalizedIncoming)
        if overlap > 0 {
            let remainder = String(normalizedIncoming.dropFirst(overlap))
            return (remainder, current + remainder)
        }

        return (normalizedIncoming, current + normalizedIncoming)
    }

    private func longestSuffixPrefixOverlap(current: String, incoming: String) -> Int {
        let currentScalars = Array(current)
        let incomingScalars = Array(incoming)
        let maxOverlap = min(currentScalars.count, incomingScalars.count)
        guard maxOverlap > 0 else { return 0 }

        for size in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(currentScalars.suffix(size)) == Array(incomingScalars.prefix(size)) {
                return size
            }
        }
        return 0
    }

    private func makeRequest(request executionRequest: SkillExecutionRequest, stream: Bool) throws -> URLRequest {
        let environment = ProcessInfo.processInfo.environment
        let configuredBase = environment["NEXHUB_API_BASE"] ?? "http://127.0.0.1:8787"

        guard let components = URLComponents(string: configuredBase),
              let scheme = components.scheme,
              let host = components.host,
              !scheme.isEmpty,
              !host.isEmpty,
              let baseURL = components.url else {
            throw ActionError.network("Invalid API base URL")
        }

        let definition = executionRequest.definition
        let text = executionRequest.context.text
        let targetLanguage = executionRequest.context.targetLanguage
        let responseLanguage = executionRequest.context.responseLanguage
        let endpoint = endpointPath(forSkillID: definition.skillID, stream: stream)
        let requestURL = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = stream ? 90 : 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppBrand.clientIdentifier, forHTTPHeaderField: "X-NexHub-Client")

        let token = environment["NEXHUB_API_TOKEN"] ?? ""
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let managedConfiguration = managedConfigurationProvider() {
            request.setValue("Bearer \(managedConfiguration.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(managedConfiguration.provider, forHTTPHeaderField: "X-LLM-Provider")
            request.setValue(managedConfiguration.model, forHTTPHeaderField: "X-LLM-Model")
        }

        var body: [String: Any] = [
            "text": text,
            "target_language": targetLanguage,
            "response_language": responseLanguage,
            "ui_language": executionRequest.context.uiLanguage,
            "skill": skillPayload(for: definition)
        ]
        if let selectedText = executionRequest.context.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedText.isEmpty {
            body["selected_text"] = selectedText
        }
        if let selectionContextBefore = executionRequest.context.selectionContextBefore?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selectionContextBefore.isEmpty {
            body["selection_context_before"] = selectionContextBefore
        }
        if let selectionContextAfter = executionRequest.context.selectionContextAfter?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selectionContextAfter.isEmpty {
            body["selection_context_after"] = selectionContextAfter
        }
        if let translationMode = executionRequest.context.translationMode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !translationMode.isEmpty {
            body["translation_mode"] = translationMode
        }
        if !executionRequest.context.filePaths.isEmpty {
            body["file_paths"] = executionRequest.context.filePaths
        }
        if definition.usesKnowledgeBase,
           settings.isKnowledgeBaseEnabled(forSkillID: definition.skillID, defaultEnabled: definition.knowledgeBase?.enabled ?? true),
           var knowledgeBasePayload = ReplyKnowledgeBaseStore.shared.requestPayload() {
            if let configuredMaxMatches = definition.knowledgeBase?.maxMatches {
                knowledgeBasePayload["max_matches"] = configuredMaxMatches
            }
            if let includeSourceCards = definition.knowledgeBase?.includeSourceCards {
                knowledgeBasePayload["include_source_cards"] = includeSourceCards
            }
            body["knowledge_base"] = knowledgeBasePayload
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func endpointPath(forSkillID skillID: String, stream: Bool) -> String {
        let trimmed = skillID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if stream {
            return "v1/actions/\(trimmed)/stream"
        }
        return "v1/actions/\(trimmed)"
    }

    private func validateGatewayResponse(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ActionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw gatewayResponseError(data: data)
        }
    }

    private func gatewayResponseError(data: Data?) -> ActionError {
        guard let data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalidResponse
        }

        let message = [
            payload["message"] as? String,
            payload["error"] as? String,
            payload["detail"] as? String
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })

        guard let message else { return .invalidResponse }
        return .network(message)
    }

    private func collectGatewayErrorData(from bytes: URLSession.AsyncBytes) async throws -> Data? {
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

    private func skillPayload(for definition: SkillDefinition) -> [String: Any] {
        var executionPayload: [String: Any] = [
            "mode": definition.manifest.execution.mode.rawValue,
            "tools": definition.toolCapabilities.map(\.rawValue),
            "streaming": definition.isStreaming,
            "supports_followup": definition.supportsFollowup,
            "safe_to_interrupt": definition.safeToInterrupt
        ]
        if definition.usesKnowledgeBase {
            var knowledgeBasePayload: [String: Any] = ["enabled": true]
            if let maxMatches = definition.knowledgeBase?.maxMatches {
                knowledgeBasePayload["max_matches"] = maxMatches
            }
            if let includeSourceCards = definition.knowledgeBase?.includeSourceCards {
                knowledgeBasePayload["include_source_cards"] = includeSourceCards
            }
            executionPayload["knowledge_base"] = knowledgeBasePayload
        }

        var payload: [String: Any] = [
            "schema_version": definition.manifest.schemaVersion,
            "id": definition.skillID,
            "name": definition.title,
            "version": definition.version,
            "instruction": definition.instructionText ?? "",
            "display": [
                "toolbar_title": definition.toolbarTitle,
                "settings_title": definition.settingsTitle,
                "result_title": definition.resultTitle,
                "icon": definition.symbolName,
                "category": definition.manifest.display.category ?? definition.category,
                "priority_tier": definition.priorityTier.rawValue
            ],
            "description": [
                "summary": definition.summary,
                "when_to_use": definition.manifest.description.whenToUse ?? [],
                "not_for": definition.manifest.description.notFor ?? []
            ],
            "routing": [
                "intent_hints": definition.manifest.routing.intentHints,
                "content_hints": definition.manifest.routing.contentHints ?? [],
                "priority_rules": definition.manifest.routing.priorityRules ?? [:],
                "fallback_rank": definition.fallbackRank
            ],
            "execution": executionPayload,
            "result": [
                "type": definition.resultType.rawValue,
                "supports_copy": definition.supportsCopy,
                "supports_replace": definition.supportsReplace,
                "supports_open_primary": definition.supportsOpenPrimary
            ],
            "lifecycle": [
                "show_loading_in_result_window": definition.manifest.lifecycle.showLoadingInResultWindow ?? true,
                "hide_status_on_first_delta": definition.manifest.lifecycle.hideStatusOnFirstDelta ?? true,
                "reveal_footer_after_completion": definition.manifest.lifecycle.revealFooterAfterCompletion ?? false,
                "defer_supplements_until_content_complete": definition.manifest.lifecycle.deferSupplementsUntilContentComplete ?? true
            ]
        ]

        if let tags = definition.manifest.metadata?.tags {
            payload["metadata"] = [
                "category": definition.category,
                "tags": tags,
                "experimental": definition.manifest.metadata?.experimental ?? false,
                "built_in": definition.manifest.metadata?.builtIn ?? true,
                "stage": definition.stage.rawValue
            ]
        }
        payload["settings"] = [
            "title": definition.settingsTitle,
            "default_enabled": definition.defaultEnabled,
            "user_configurable": definition.isUserConfigurable,
            "stage": definition.stage.rawValue
        ]
        return payload
    }

    private func decodeActionResult(definition: SkillDefinition, payloadData: Data) throws -> ActionResult {
        switch definition.skillID {
        case "translate":
            return .translate(try JSONDecoder().decode(TranslationResult.self, from: payloadData))
        case "trace":
            return .trace(try JSONDecoder().decode(TraceResult.self, from: payloadData))
        case "explain":
            return .explain(try JSONDecoder().decode(ExplainResult.self, from: payloadData))
        case "reply":
            return .reply(try JSONDecoder().decode(ReplyResult.self, from: payloadData))
        case "schedule":
            return .info(L10n.text(zhHans: "日程已创建", en: "Schedule created"))
        case "compress":
            return .info(L10n.text(zhHans: "文件已压缩", en: "Files compressed"))
        case "screenshot_ocr":
            return .info(L10n.text(zhHans: "OCR 已完成", en: "OCR completed"))
        case "screenshot_save":
            return .info(L10n.text(zhHans: "截图已保存", en: "Screenshot saved"))
        default:
            throw ActionError.invalidResponse
        }
    }

    private func decodeResultEnvelope(
        definition: SkillDefinition,
        context: SkillExecutionContext,
        payloadData: Data
    ) throws -> SkillResultEnvelope {
        if let direct = try? JSONDecoder().decode(SkillResultEnvelope.self, from: payloadData) {
            return ResultSchemaAdapter.normalizeEnvelope(direct, definition: definition, context: context)
        }

        let legacy = try decodeActionResult(definition: definition, payloadData: payloadData)
        return ResultSchemaAdapter.resultEnvelope(for: legacy, definition: definition, context: context)
    }

    private func localFallback(request executionRequest: SkillExecutionRequest) -> ActionResult {
        let text = executionRequest.context.text
        let responseLanguage = executionRequest.context.responseLanguage
        let targetLanguage = executionRequest.context.targetLanguage
        switch executionRequest.definition.skillID {
        case "translate":
            let detected = LanguageRoutingSupport.detectedLanguage(for: text)
            let translated = "[Demo \(targetLanguage.uppercased())] \(text)"
            return .translate(.init(translatedText: translated, detectedLanguage: detected, targetLanguage: targetLanguage))
        case "trace":
            let demo = TraceResult(
                summary: localizedContentText(
                    zhHans: "当前 AI 服务不可用，返回本地演示溯源结果。",
                    en: "The AI service is currently unavailable, so NexHub is returning a local demo source result.",
                    languageCode: responseLanguage
                ),
                confidence: 0.3,
                timeline: [
                    "2026-03: Selection captured",
                    "2026-03: Fallback source ranking generated"
                ],
                sources: [
                    .init(title: "OpenAI News", url: "https://openai.com/news", snippet: L10n.text(zhHans: "OpenAI 官方新闻集合", en: "Official OpenAI news"), publishedAt: nil, sourceType: "event", isOfficial: true),
                    .init(title: "OpenAI API Release Notes", url: "https://platform.openai.com/docs/release-notes", snippet: L10n.text(zhHans: "OpenAI API 版本日志", en: "OpenAI API release notes"), publishedAt: nil, sourceType: "reference", isOfficial: true)
                ],
                primaryEntity: .init(
                    name: "OpenAI",
                    entityType: "company",
                    title: "OpenAI",
                    url: "https://openai.com/",
                    snippet: L10n.text(zhHans: "OpenAI 是一家 AI 研究与产品公司，提供 ChatGPT 与 API 平台。", en: "OpenAI is an AI research and product company behind ChatGPT and the API platform."),
                    whyThis: L10n.text(zhHans: "文本中出现了 OpenAI，且官网是最直接的实体源头链接。", en: "OpenAI appears in the text, and its official website is the most direct entity source."),
                    isOfficial: true
                ),
                primaryEntities: [
                    .init(
                        name: "OpenAI",
                        entityType: "company",
                        title: "OpenAI",
                        url: "https://openai.com/",
                        snippet: L10n.text(zhHans: "OpenAI 是一家 AI 研究与产品公司，提供 ChatGPT 与 API 平台。", en: "OpenAI is an AI research and product company behind ChatGPT and the API platform."),
                        whyThis: L10n.text(zhHans: "文本中出现了 OpenAI，且官网是最直接的实体源头链接。", en: "OpenAI appears in the text, and its official website is the most direct entity source."),
                        isOfficial: true
                    )
                ],
                relatedEntities: [],
                whyThis: L10n.text(zhHans: "当前为本地演示结果，优先返回实体官网作为源头链接。", en: "This is a local demo result, so NexHub prefers the official entity website as the primary source."),
                eventSummary: L10n.text(zhHans: "若需要事件出处，可继续查看新闻页和 API 更新页。", en: "If you need the event source, continue with the news page or API release notes.")
            )
            return .trace(demo)
        case "explain":
            let demo = localizedContentText(
                zhHans: "这是一个本地演示解释结果，用来帮助你快速理解当前选中的概念、产品或功能。",
                en: "This is a local demo explanation to help you quickly understand the selected concept, product, or feature.",
                languageCode: responseLanguage
            )
            return .explain(.init(explanationText: demo))
        case "reply":
            return .info(localizedContentText(
                zhHans: "当前 AI 服务不可用，无法基于知识库生成回复。",
                en: "The AI service is unavailable, so NexHub cannot generate a reply from the knowledge base right now.",
                languageCode: responseLanguage
            ))
        case "schedule":
            return .info(L10n.text(zhHans: "未连接 AI 服务，无法解析日程信息。", en: "The AI service is not connected, so NexHub cannot parse the schedule details."))
        case "compress":
            return .info(L10n.text(zhHans: "文件压缩暂不可用。", en: "File compression is temporarily unavailable."))
        case "screenshot_ocr":
            return .info(localOCRText(from: executionRequest.context.filePaths))
        case "screenshot_save":
            return .info(L10n.text(zhHans: "截图已保存。", en: "Screenshot saved."))
        default:
            return .info(L10n.format(zhHans: "未识别的 Skill：%@", en: "Unknown skill: %@", executionRequest.definition.skillID))
        }
    }

    private func localFallbackEnvelope(request executionRequest: SkillExecutionRequest) -> SkillResultEnvelope {
        ResultSchemaAdapter.resultEnvelope(
            for: localFallback(request: executionRequest),
            definition: executionRequest.definition,
            context: executionRequest.context
        )
    }

    private func partialFallbackEnvelope(
        definition: SkillDefinition,
        context: SkillExecutionContext,
        partial: String
    ) -> SkillResultEnvelope {
        let legacy: ActionResult

        switch definition.skillID {
        case "translate":
            let detected = LanguageRoutingSupport.detectedLanguage(for: context.text)
            legacy = .translate(
                .init(
                    translatedText: partial,
                    detectedLanguage: detected,
                    targetLanguage: context.targetLanguage
                )
            )

        case "trace":
            legacy = .trace(
                .init(
                    summary: partial,
                    confidence: 0.5,
                    timeline: [],
                    sources: [],
                    primaryEntity: nil,
                    primaryEntities: [],
                    relatedEntities: [],
                    whyThis: nil,
                    eventSummary: nil
                )
            )

        case "explain":
            legacy = .explain(.init(explanationText: partial))

        case "reply":
            legacy = .reply(.init(replyText: partial))

        case "schedule":
            legacy = .info(partial)

        case "compress":
            legacy = .info(partial)
        case "screenshot_ocr":
            legacy = .info(partial)
        case "screenshot_save":
            legacy = .info(partial)

        default:
            legacy = .info(partial)
        }

        return ResultSchemaAdapter.resultEnvelope(for: legacy, definition: definition, context: context)
    }
}

@available(*, deprecated, renamed: "SkillExecutionService")
typealias ActionService = SkillExecutionService

private extension SkillExecutionService {
    func localizedContentText(zhHans: String, en: String, languageCode: String) -> String {
        L10n.text(languageCode: languageCode, zhHans: zhHans, en: en)
    }

    func localOCRText(from filePaths: [String]) -> String {
        guard let imagePath = filePaths.first,
              let image = NSImage(contentsOfFile: imagePath) else {
            return L10n.text(zhHans: "无法读取当前截图，OCR 未执行。", en: "The current screenshot could not be read, so OCR was not run.")
        }

        do {
            let blocks = try NativeVisionScreenshotOCRService.shared.recognizeText(in: image)
            let text = blocks.map(\.text).joined(separator: "\n")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return L10n.text(zhHans: "未识别到文本内容。", en: "No text was recognized.")
            }
            return text
        } catch {
            return error.localizedDescription.isEmpty
                ? L10n.text(zhHans: "OCR 识别失败。", en: "OCR failed.")
                : error.localizedDescription
        }
    }
}
