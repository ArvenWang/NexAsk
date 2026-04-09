import AppKit
import Foundation

enum TraceStatusDetailFormatter {
    static func decompositionDetails(for plan: TracePlanDescriptor, languageCode: String) -> [String] {
        var details: [String] = []
        let entity = normalizedLabel(plan.primaryEntityName)
        if !entity.isEmpty {
            details.append(
                localizedFormat(
                    languageCode: languageCode,
                    zhHans: "主目标先锁定为 %@。",
                    en: "Primary target locked to %@.",
                    entity
                )
            )
        }

        details.append(
            localizedFormat(
                languageCode: languageCode,
                zhHans: "意图判断：%@。",
                en: "Intent: %@.",
                intentSummary(plan.intent.type, languageCode: languageCode)
            )
        )

        if !plan.ownerHints.isEmpty {
            let ownerSummary = joinedSummary(plan.ownerHints, limit: 2)
            details.append(
                localizedFormat(
                    languageCode: languageCode,
                    zhHans: "属主线索：%@。",
                    en: "Owner hints: %@.",
                    ownerSummary
                )
            )
        }

        return uniqueNonEmpty(details)
    }

    static func searchProgressDetails(
        queries: [String],
        augmentedProviders: [String],
        languageCode: String
    ) -> [String] {
        var details: [String] = queries
            .map(normalizedLabel)
            .filter { !$0.isEmpty }
            .prefix(2)
            .map {
                localizedFormat(
                    languageCode: languageCode,
                    zhHans: "搜索 %@",
                    en: "Search %@",
                    $0
                )
            }

        let providers = humanReadableProviders(augmentedProviders)
        if !providers.isEmpty {
            let providerSummary = joinedSummary(providers, limit: 3)
            details.append(
                localizedFormat(
                    languageCode: languageCode,
                    zhHans: "扩展检索 %@",
                    en: "Expanded search via %@",
                    providerSummary
                )
            )
        }

        return uniqueNonEmpty(details)
    }

    static func searchSummaryDetail(sources: [SourceRecord], languageCode: String) -> String {
        let labels = sourceLabels(from: sources, limit: 3)
        if labels.isEmpty {
            return localized(
                zhHans: "暂无命中",
                en: "No hits yet",
                languageCode: languageCode
            )
        }

        let summary = labels.joined(separator: "、")
        return localizedFormat(
            languageCode: languageCode,
            zhHans: "命中 %d 个候选：%@",
            en: "Found %d candidate(s): %@",
            sources.count,
            summary
        )
    }

    static func candidateResolutionDetails(sources: [SourceRecord], languageCode: String) -> [String] {
        let labels = sourceLabels(from: sources, limit: 4)
        guard !labels.isEmpty else { return [] }

        var details: [String] = []
        let narrowed = labels.prefix(3).joined(separator: "、")
        details.append(
            localizedFormat(
                languageCode: languageCode,
                zhHans: "候选已收束到：%@。",
                en: "Narrowed candidates to: %@.",
                narrowed
            )
        )

        let keptLabels = labels.prefix(2)
        let excludedLabels = Array(labels.dropFirst(2).prefix(2))
        if !keptLabels.isEmpty && !excludedLabels.isEmpty {
            let kept = keptLabels.joined(separator: "、")
            let excluded = excludedLabels.joined(separator: "、")
            details.append(
                localizedFormat(
                    languageCode: languageCode,
                    zhHans: "保留 %@；排除 %@。",
                    en: "Kept %@; excluded %@.",
                    kept,
                    excluded
                )
            )
        }

        if let locked = labels.first {
            details.append(
                localizedFormat(
                    languageCode: languageCode,
                    zhHans: "已锁定 %@。",
                    en: "Locked %@.",
                    locked
                )
            )
        }

        return uniqueNonEmpty(details)
    }

    static func resultGenerationDetail(topSource: SourceRecord?, languageCode: String) -> String {
        guard let topSource else {
            return localized(
                zhHans: "正在整理最佳入口…",
                en: "Preparing the best source to open…",
                languageCode: languageCode
            )
        }

        let label = sourceLabel(for: topSource)
        guard !label.isEmpty else {
            return localized(
                zhHans: "正在整理最佳入口…",
                en: "Preparing the best source to open…",
                languageCode: languageCode
            )
        }

        return localizedFormat(
            languageCode: languageCode,
            zhHans: "正在整理 %@ 的打开结论…",
            en: "Preparing the opening recommendation for %@…",
            label
        )
    }

    private static func localized(zhHans: String, en: String, languageCode: String) -> String {
        L10n.text(languageCode: languageCode, zhHans: zhHans, en: en)
    }

    private static func localizedFormat(languageCode: String, zhHans: String, en: String, _ arguments: CVarArg...) -> String {
        String(
            format: L10n.text(languageCode: languageCode, zhHans: zhHans, en: en),
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: arguments
        )
    }

    private static func intentSummary(_ intentType: String, languageCode: String) -> String {
        switch intentType {
        case "documentation":
            return localized(zhHans: "优先找文档与接入说明", en: "prioritize docs and integration guidance", languageCode: languageCode)
        case "experience_entry":
            return localized(zhHans: "优先找可直接体验的入口", en: "prioritize a direct try-it entry", languageCode: languageCode)
        case "official_source":
            return localized(zhHans: "优先找官方原始出处", en: "prioritize the original official source", languageCode: languageCode)
        case "feature_lookup":
            return localized(zhHans: "优先找功能说明与入口", en: "prioritize feature guidance and entry points", languageCode: languageCode)
        case "model_lookup":
            return localized(zhHans: "优先找模型说明与能力页", en: "prioritize model pages and capability notes", languageCode: languageCode)
        default:
            return localized(zhHans: "优先找最值得直接打开的主入口", en: "prioritize the most useful main entry to open", languageCode: languageCode)
        }
    }

    private static func sourceLabels(from sources: [SourceRecord], limit: Int) -> [String] {
        uniqueNonEmpty(
            sources
                .prefix(limit)
                .map(sourceLabel(for:))
        )
    }

    private static func sourceLabel(for source: SourceRecord) -> String {
        let title = normalizedLabel(source.title)
        if !title.isEmpty {
            return title
        }

        guard let host = URL(string: source.url)?.host?.replacingOccurrences(of: "www.", with: "") else {
            return normalizedLabel(source.url)
        }
        return normalizedLabel(host)
    }

    private static func humanReadableProviders(_ providers: [String]) -> [String] {
        providers.compactMap { raw in
            switch raw {
            case "hackernews_search":
                return "Hacker News"
            case "stackoverflow_search":
                return "Stack Overflow"
            default:
                if raw.hasPrefix("devto_tag:") {
                    return "Dev.to"
                }
                if raw.hasPrefix("lobsters_tag:") {
                    return "Lobsters"
                }
                return nil
            }
        }
    }

    private static func joinedSummary(_ values: [String], limit: Int) -> String {
        values
            .prefix(limit)
            .joined(separator: "、")
    }

    private static func normalizedLabel(_ text: String) -> String {
        let trimmed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= 48 {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 45)
        return String(trimmed[..<index]) + "..."
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var results: [String] = []
        var seen: Set<String> = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            results.append(trimmed)
        }
        return results
    }
}

final class SkillRuntimeService {
    static let shared = SkillRuntimeService()

    private final class StreamAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var fullText = ""

        func append(incoming: String) -> (appended: String, fullText: String) {
            lock.lock()
            defer { lock.unlock() }
            let normalized = incoming.replacingOccurrences(of: "\r\n", with: "\n")
            guard !normalized.isEmpty else {
                return ("", fullText)
            }
            fullText += normalized
            return (normalized, fullText)
        }

        func snapshot() -> String {
            lock.lock()
            defer { lock.unlock() }
            return fullText
        }
    }

    private final class ExplainStreamAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var rawText = ""
        private var sanitizedText = ""

        func append(incoming: String) -> (appended: String, fullText: String) {
            lock.lock()
            defer { lock.unlock() }
            rawText += incoming
            let sanitized = RuntimeTextSanitizer.sanitizeExplainStreamText(rawText)
            let appended: String
            if sanitized.hasPrefix(sanitizedText) {
                appended = String(sanitized.dropFirst(sanitizedText.count))
            } else {
                appended = sanitized
            }
            sanitizedText = sanitized
            return (appended, sanitized)
        }

        func snapshot() -> (raw: String, sanitized: String) {
            lock.lock()
            defer { lock.unlock() }
            return (rawText, sanitizedText)
        }
    }

    private let llmClient: LLMClient
    private let settings: AppSettings
    private let knowledgeBaseStore: ReplyKnowledgeBaseStore
    private let session: URLSession
    private let diagnosticsLogger: DiagnosticsLogger
    private let aiConfigurationProvider: () async throws -> LLMRequestConfiguration
    private let traceSourceAugmentationProvider: @Sendable (_ sourceText: String, _ plan: TracePlanDescriptor, _ diagnosticsLogger: DiagnosticsLogger) async -> [SourceRecord]

    init(
        llmClient: LLMClient = LLMClient(),
        settings: AppSettings = .shared,
        knowledgeBaseStore: ReplyKnowledgeBaseStore = .shared,
        session: URLSession = .shared,
        diagnosticsLogger: DiagnosticsLogger = .shared,
        aiConfigurationProvider: @escaping () async throws -> LLMRequestConfiguration = {
            try await ManagedAIConfigurationService.shared.configuration()
        },
        traceSourceAugmentationProvider: @escaping @Sendable (_ sourceText: String, _ plan: TracePlanDescriptor, _ diagnosticsLogger: DiagnosticsLogger) async -> [SourceRecord] = {
            sourceText,
            plan,
            diagnosticsLogger in
            await TraceSourceAugmentationSupport.searchAdditionalSources(
                sourceText: sourceText,
                plan: plan,
                diagnosticsLogger: diagnosticsLogger
            )
        }
    ) {
        self.llmClient = llmClient
        self.settings = settings
        self.knowledgeBaseStore = knowledgeBaseStore
        self.session = session
        self.diagnosticsLogger = diagnosticsLogger
        self.aiConfigurationProvider = aiConfigurationProvider
        self.traceSourceAugmentationProvider = traceSourceAugmentationProvider
    }

    private func resolvedAIConfiguration() async throws -> LLMRequestConfiguration {
        try await aiConfigurationProvider()
    }

    func runEnvelope(request: SkillExecutionRequest) async throws -> SkillResultEnvelope {
        try await runStreamingEnvelope(request: request) { _ in }
    }

    func runStreamingEnvelope(
        request: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async throws -> SkillResultEnvelope {
        switch request.definition.skillID {
        case "translate":
            return try await runTranslate(request: request, onEvent: onEvent)
        case "explain":
            return try await runExplain(request: request, onEvent: onEvent)
        case "reply":
            return try await runReply(request: request, onEvent: onEvent)
        case "trace":
            return try await runTrace(request: request, onEvent: onEvent)
        case "schedule":
            return try await runSchedule(request: request, onEvent: onEvent)
        case "compress":
            return runCompress(request: request, onEvent: onEvent)
        default:
            return try await runGenericSkill(request: request, onEvent: onEvent)
        }
    }

    private func runTranslate(
        request: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async throws -> SkillResultEnvelope {
        let sourceText = request.context.text
        let detected = LanguageRoutingSupport.detectedLanguage(for: sourceText)
        let translationDecision = resolvedTranslationDecision(for: request.context)
        let instructionText = try skillInstruction(for: request)
        let promptPackage = translationPromptPackage(
            sourceText: sourceText,
            decision: translationDecision,
            instructionText: instructionText
        )
        let systemPrompt = promptPackage.systemPrompt
        let userPrompt = promptPackage.userPrompt
        let configuration = try await resolvedAIConfiguration()
        onEvent(.init(type: .status, status: "thinking", detail: localized(zhHans: "正在翻译…", en: "Translating…", languageCode: request.context.uiLanguage)))
        let maxTokens = translationMaxTokens(for: sourceText)
        logRuntimeInvocation(
            skillID: request.definition.skillID,
            sourceText: sourceText,
            details: [
                "phase": "start",
                "strategy": "dynamic_stream",
                "max_tokens": String(maxTokens),
                "translation_mode": translationDecision.mode.rawValue,
                "target_language": translationDecision.targetLanguage,
                "foreign_segments": String(promptPackage.foreignSegments.count)
            ]
        )

        let rawText: String
        let streamingState = StreamAccumulator()
        do {
            rawText = try await llmClient.stream(
                configuration: configuration,
                messages: [
                    .init(role: .system, content: systemPrompt),
                    .init(role: .user, content: userPrompt)
                ],
                maxTokens: maxTokens
            ) { delta in
                let merge = streamingState.append(incoming: delta)
                guard !merge.appended.isEmpty else { return }
                onEvent(.init(type: .delta, delta: merge.appended, fullText: merge.fullText))
            }
        } catch {
            let partial = streamingState.snapshot()
            if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawText = partial
            } else {
                logRuntimeInvocation(
                    skillID: request.definition.skillID,
                    sourceText: sourceText,
                    details: [
                        "phase": "stream_retry",
                        "max_tokens": String(maxTokens)
                    ]
                )
                rawText = try await llmClient.complete(
                    configuration: configuration,
                    messages: [
                        .init(role: .system, content: systemPrompt),
                        .init(role: .user, content: userPrompt)
                    ],
                    maxTokens: maxTokens,
                    timeout: 45
                )
            }
        }

        let sanitized = RuntimeTextSanitizer.sanitizeTranslationOutput(
            sourceText: sourceText,
            translated: rawText
        )
        let initialValidation = RuntimeOutputGuard.validate(
            skillID: request.definition.skillID,
            sourceText: sourceText,
            outputText: sanitized,
            responseLanguage: translationDecision.responseLanguage,
            targetLanguage: translationDecision.targetLanguage
        )
        logOutputValidation(
            skillID: request.definition.skillID,
            attempt: 1,
            validation: initialValidation,
            sourceText: sourceText,
            outputText: sanitized
        )

        let finalText: String
        if initialValidation.isValid, !sanitized.isEmpty {
            finalText = sanitized
        } else {
            logRuntimeInvocation(
                skillID: request.definition.skillID,
                sourceText: sourceText,
                details: [
                    "phase": "retry_complete",
                    "reason": initialValidation.reason,
                    "max_tokens": String(maxTokens)
                ]
            )
            let retriedRaw = try await llmClient.complete(
                configuration: configuration,
                messages: [
                    .init(role: .system, content: systemPrompt),
                    .init(role: .user, content: promptPackage.retryUserPrompt ?? userPrompt)
                ],
                maxTokens: maxTokens,
                timeout: 45
            )
            let retriedSanitized = RuntimeTextSanitizer.sanitizeTranslationOutput(
                sourceText: sourceText,
                translated: retriedRaw
            )
            let retryValidation = RuntimeOutputGuard.validate(
                skillID: request.definition.skillID,
                sourceText: sourceText,
                outputText: retriedSanitized,
                responseLanguage: translationDecision.responseLanguage,
                targetLanguage: translationDecision.targetLanguage
            )
            logOutputValidation(
                skillID: request.definition.skillID,
                attempt: 2,
                validation: retryValidation,
                sourceText: sourceText,
                outputText: retriedSanitized
            )
            if retryValidation.isValid, !retriedSanitized.isEmpty {
                finalText = retriedSanitized
            } else {
                if let repairedMixedText = try await mixedSegmentTranslationFallback(
                    sourceText: sourceText,
                    decision: translationDecision,
                    instructionText: instructionText,
                    invalidOutput: retriedSanitized,
                    invalidReason: retryValidation.reason,
                    configuration: configuration,
                    skillID: request.definition.skillID
                ) {
                    finalText = repairedMixedText
                } else if promptPackage.isIdentifierGlossary,
                          let repairedGlossaryText = try await identifierGlossaryTranslationFallback(
                            sourceText: sourceText,
                            decision: translationDecision,
                            instructionText: instructionText,
                            invalidOutput: retriedSanitized,
                            invalidReason: retryValidation.reason,
                            configuration: configuration,
                            skillID: request.definition.skillID
                          ) {
                    finalText = repairedGlossaryText
                } else {
                    diagnosticsLogger.log(
                        "ai.runtime",
                        "skill=\(request.definition.skillID) phase=fallback_invalid reason=\(retryValidation.reason)"
                    )
                    finalText = translationUnavailableMessage(responseLanguage: translationDecision.responseLanguage)
                }
            }
        }

        return ResultSchemaAdapter.resultEnvelope(
            for: .translate(
                .init(
                    translatedText: finalText,
                    detectedLanguage: detected,
                    targetLanguage: translationDecision.targetLanguage
                )
            ),
            definition: request.definition,
            context: request.context
        )
    }

    private func runExplain(
        request: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async throws -> SkillResultEnvelope {
        let fallback = RuntimeTextSanitizer.fallbackExplain(
            text: request.context.text,
            languageCode: request.context.responseLanguage
        )
        let instructionText = try skillInstruction(for: request)
        let systemPrompt = SkillPromptComposer.composeSystemPrompt(
            instructionText: instructionText,
            fallback: instructionText,
            appendedSections: []
        )
        let userPrompt = explainUserPrompt(
            selectedText: request.context.text,
            languageCode: request.context.responseLanguage
        )
        logRuntimeInvocation(
            skillID: request.definition.skillID,
            sourceText: request.context.text,
            details: ["phase": "start"]
        )

        onEvent(
            .init(
                type: .status,
                status: "thinking",
                detail: localized(zhHans: "正在解释…", en: "Explaining…", languageCode: request.context.uiLanguage)
            )
        )

        guard let configuration = try? await resolvedAIConfiguration(),
              !configuration.apiKey.isEmpty else {
            onEvent(.init(type: .delta, delta: fallback, fullText: fallback))
            return ResultSchemaAdapter.resultEnvelope(
                for: .explain(.init(explanationText: fallback)),
                definition: request.definition,
                context: request.context
            )
        }

        let explainAccumulator = ExplainStreamAccumulator()
        let finalRaw: String

        do {
            finalRaw = try await llmClient.stream(
                configuration: configuration,
                messages: [
                    .init(role: .system, content: systemPrompt),
                    .init(role: .user, content: userPrompt)
                ],
                maxTokens: max(180, min(700, request.context.text.count * 5))
            ) { delta in
                let merge = explainAccumulator.append(incoming: delta)
                let appended = merge.appended
                if !appended.isEmpty {
                    onEvent(.init(type: .delta, delta: appended, fullText: merge.fullText))
                }
            }
        } catch {
            let snapshot = explainAccumulator.snapshot()
            if snapshot.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalRaw = (try? await llmClient.complete(
                    configuration: configuration,
                    messages: [
                        .init(role: .system, content: systemPrompt),
                        .init(role: .user, content: userPrompt)
                    ],
                    maxTokens: max(180, min(700, request.context.text.count * 5))
                )) ?? ""
            } else {
                finalRaw = snapshot.raw
            }
        }

        let candidateText = RuntimeTextSanitizer.sanitizeExplanationOutput(finalRaw).isEmpty
            ? fallback
            : RuntimeTextSanitizer.sanitizeExplanationOutput(finalRaw)
        let explanationText = try await validatedOutput(
            skillID: request.definition.skillID,
            sourceText: request.context.text,
            candidateText: candidateText,
            configuration: configuration,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            responseLanguage: request.context.responseLanguage,
            targetLanguage: nil,
            sanitizer: RuntimeTextSanitizer.sanitizeExplanationOutput,
            fallback: { _ in fallback }
        )

        if explainAccumulator.snapshot().sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onEvent(.init(type: .delta, delta: explanationText, fullText: explanationText))
        }

        return ResultSchemaAdapter.resultEnvelope(
            for: .explain(.init(explanationText: explanationText)),
            definition: request.definition,
            context: request.context
        )
    }

    private func runReply(
        request: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async throws -> SkillResultEnvelope {
        let knowledgeMatches = request.definition.usesKnowledgeBase ? resolveKnowledgeMatches(query: request.context.text, limit: 4) : []
        let sourceCards = knowledgeSourceCards(from: knowledgeMatches, uiLanguage: request.context.uiLanguage)
        let knowledgeContext = knowledgeContextText(from: knowledgeMatches, responseLanguage: request.context.responseLanguage)
        let systemPrompt = try skillInstruction(for: request)

        let userPrompt = SkillPromptComposer.composeUserPrompt(
            sections: [
                "Incoming text:\n\(request.context.text)",
                "Output language: \(request.context.responseLanguage)",
                knowledgeContext.isEmpty ? nil : knowledgeContext
            ]
        )
        logRuntimeInvocation(
            skillID: request.definition.skillID,
            sourceText: request.context.text,
            details: [
                "phase": "start",
                "knowledge_matches": String(knowledgeMatches.count)
            ]
        )

        onEvent(
            .init(
                type: .status,
                status: "thinking",
                detail: localized(zhHans: "正在生成回复…", en: "Drafting a reply…", languageCode: request.context.uiLanguage)
            )
        )

        guard let configuration = try? await resolvedAIConfiguration(),
              !configuration.apiKey.isEmpty else {
            let message = replyServiceUnavailableMessage(
                authFailed: false,
                responseLanguage: request.context.responseLanguage
            )
            onEvent(.init(type: .delta, delta: message, fullText: message))
            return ResultSchemaAdapter.resultEnvelope(
                for: .info(message),
                definition: request.definition,
                context: request.context
            )
        }

        let streamingState = StreamAccumulator()
        var finalText = ""

        do {
            finalText = try await llmClient.stream(
                configuration: configuration,
                messages: [
                    .init(role: .system, content: systemPrompt),
                    .init(role: .user, content: userPrompt)
                ],
                maxTokens: 1200
            ) { delta in
                let merge = streamingState.append(incoming: delta)
                guard !merge.appended.isEmpty else { return }
                onEvent(.init(type: .delta, delta: merge.appended, fullText: merge.fullText))
            }
        } catch {
            if streamingState.snapshot().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let message = replyServiceUnavailableMessage(
                    authFailed: isLikelyAuthenticationFailure(error),
                    responseLanguage: request.context.responseLanguage
                )
                onEvent(.init(type: .delta, delta: message, fullText: message))
                return ResultSchemaAdapter.resultEnvelope(
                    for: .info(message),
                    definition: request.definition,
                    context: request.context
                )
            }
            finalText = streamingState.snapshot()
        }

        let sanitizedReply = RuntimeTextSanitizer.sanitizeReplyOutput(finalText)
        let repairedReply = try await validatedOutput(
            skillID: request.definition.skillID,
            sourceText: request.context.text,
            candidateText: sanitizedReply.isEmpty ? finalText.trimmingCharacters(in: .whitespacesAndNewlines) : sanitizedReply,
            configuration: configuration,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            responseLanguage: request.context.responseLanguage,
            targetLanguage: nil,
            sanitizer: RuntimeTextSanitizer.sanitizeReplyOutput,
            fallback: { [weak self] _ in
                self?.replyServiceUnavailableMessage(
                    authFailed: false,
                    responseLanguage: request.context.responseLanguage
                ) ?? ""
            }
        )
        let envelope = ResultSchemaAdapter.resultEnvelope(
            for: .reply(.init(replyText: repairedReply)),
            definition: request.definition,
            context: request.context
        )

        if !sourceCards.isEmpty {
            onEvent(.init(type: .supplement, cards: sourceCards, artifacts: nil))
        }

        return SkillResultEnvelope(
            schemaVersion: envelope.schemaVersion,
            skillID: envelope.skillID,
            resultType: envelope.resultType,
            summary: envelope.summary,
            body: envelope.body,
            primaryAction: envelope.primaryAction,
            secondaryActions: envelope.secondaryActions,
            cards: sourceCards,
            artifacts: envelope.artifacts,
            copyPayload: envelope.copyPayload,
            replacePayload: envelope.replacePayload,
            followups: envelope.followups,
            metadata: (envelope.metadata ?? [:]).merging([
                "used_knowledge_base": sourceCards.isEmpty ? "false" : "true",
                "knowledge_base_source_count": String(sourceCards.count)
            ]) { _, new in new }
        )
    }

    private func runTrace(
        request: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async throws -> SkillResultEnvelope {
        let configuration = try? await resolvedAIConfiguration()
        let rawPlan = try await tracePlan(
            for: request.context.text,
            configuration: configuration,
            responseLanguage: request.context.responseLanguage
        ) ?? TraceRuntimeSupport.buildPlan(
            for: request.context.text,
            languageCode: request.context.responseLanguage
        )
        let plan = sanitizedTracePlan(
            rawPlan,
            sourceText: request.context.text,
            responseLanguage: request.context.responseLanguage
        )
        logRuntimeInvocation(
            skillID: request.definition.skillID,
            sourceText: request.context.text,
            details: [
                "phase": "start",
                "intent": plan.intent.type,
                "entity": plan.primaryEntityName,
                "queries": plan.searchQueries.joined(separator: " | ")
            ]
        )
        TraceStatusDetailFormatter.decompositionDetails(for: plan, languageCode: request.context.uiLanguage).forEach { detail in
            onEvent(.init(type: .status, status: "semantic_decomposition", detail: detail))
        }

        let instructionText = try skillInstruction(for: request)
        let augmentedProviders = TraceSourceAugmentationSupport.selectedProviders(
            sourceText: request.context.text,
            plan: plan
        )
        TraceStatusDetailFormatter.searchProgressDetails(
            queries: plan.searchQueries,
            augmentedProviders: augmentedProviders,
            languageCode: request.context.uiLanguage
        ).forEach { detail in
            onEvent(.init(type: .status, status: "search_enhancement", detail: detail))
        }
        async let defaultSources = searchSources(for: plan.searchQueries, limitPerQuery: 4)
        async let augmentedSources = traceSourceAugmentationProvider(
            request.context.text,
            plan,
            diagnosticsLogger
        )

        let mergedSources = mergeSources(
            primary: try await defaultSources,
            augmented: await augmentedSources
        )
        onEvent(
            .init(
                type: .status,
                status: "search_enhancement",
                detail: TraceStatusDetailFormatter.searchSummaryDetail(
                    sources: mergedSources,
                    languageCode: request.context.uiLanguage
                )
            )
        )
        let rankedSources = TraceRuntimeSupport.rankSources(mergedSources, plan: plan)
        let resolvedSources = rankedSources.isEmpty
            ? [traceFallbackSource(for: plan, languageCode: request.context.responseLanguage)]
            : rankedSources
        let primaryEntity = traceEntity(
            from: plan,
            sources: resolvedSources,
            languageCode: request.context.responseLanguage
        )
        let sourceLines = resolvedSources.prefix(6).enumerated().map { index, source in
            """
            [\(index + 1)] \(source.title)
            URL: \(source.url)
            Snippet: \(source.snippet)
            Type: \(source.sourceType ?? "web")
            """
        }.joined(separator: "\n\n")
        if let primaryEntity,
           let supplement = ResultSchemaAdapter.traceSupplementEvent(for: [primaryEntity]) {
            onEvent(supplement)
        }

        let summary: String
        var streamedSummary = false
        if let configuration,
           !configuration.apiKey.isEmpty,
           !resolvedSources.isEmpty {
            TraceStatusDetailFormatter.candidateResolutionDetails(
                sources: resolvedSources,
                languageCode: request.context.uiLanguage
            ).forEach { detail in
                onEvent(.init(type: .status, status: "candidate_resolution", detail: detail))
            }

            let systemPrompt = traceSummarySystemPrompt(
                instructionText: instructionText,
                responseLanguage: request.context.responseLanguage
            )
            let userPrompt = traceSummaryUserPrompt(
                selectedText: request.context.text,
                plan: plan,
                primaryEntity: primaryEntity,
                responseLanguage: request.context.responseLanguage,
                sourceLines: sourceLines
            )
            let streamingState = StreamAccumulator()
            let rawSummary: String
            do {
                rawSummary = try await llmClient.stream(
                    configuration: configuration,
                    messages: [
                        .init(role: .system, content: systemPrompt),
                        .init(role: .user, content: userPrompt)
                    ],
                    maxTokens: traceSummaryMaxTokens(for: request.context.text, sourceCount: resolvedSources.count)
                ) { delta in
                    let merge = streamingState.append(incoming: delta)
                    guard !merge.appended.isEmpty else { return }
                    onEvent(.init(type: .delta, delta: merge.appended, fullText: merge.fullText))
                }
            } catch {
                let partial = streamingState.snapshot().trimmingCharacters(in: .whitespacesAndNewlines)
                if !partial.isEmpty {
                    rawSummary = partial
                } else {
                    diagnosticsLogger.log(
                        "ai.runtime",
                        "skill=\(request.definition.skillID) phase=trace_stream_failed error=\(error.localizedDescription)"
                    )
                    rawSummary = ""
                }
            }
            streamedSummary = !streamingState.snapshot().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let candidateSummary = RuntimeTextSanitizer.sanitizeTraceSummaryOutput(rawSummary)
            let validation = RuntimeOutputGuard.validate(
                skillID: request.definition.skillID,
                sourceText: request.context.text,
                outputText: candidateSummary,
                responseLanguage: request.context.responseLanguage,
                targetLanguage: nil
            )
            logOutputValidation(
                skillID: request.definition.skillID,
                attempt: 1,
                validation: validation,
                sourceText: request.context.text,
                outputText: candidateSummary
            )
            if validation.isValid, !candidateSummary.isEmpty {
                summary = candidateSummary
            } else {
                diagnosticsLogger.log(
                    "ai.runtime",
                    "skill=\(request.definition.skillID) phase=trace_fallback reason=\(validation.reason)"
                )
                summary = deterministicTraceSummary(
                    primaryEntity: primaryEntity,
                    topSource: resolvedSources.first,
                    intent: plan.intent,
                    languageCode: request.context.responseLanguage
                )
            }
        } else {
            summary = deterministicTraceSummary(
                primaryEntity: primaryEntity,
                topSource: resolvedSources.first,
                intent: plan.intent,
                languageCode: request.context.responseLanguage
            )
        }

        onEvent(
            .init(
                type: .status,
                status: "result_generation",
                detail: TraceStatusDetailFormatter.resultGenerationDetail(
                    topSource: resolvedSources.first,
                    languageCode: request.context.uiLanguage
                )
            )
        )

        let cleanedSummary = RuntimeTextSanitizer.sanitizeTraceSummaryOutput(summary)
        let finalSummary = cleanedSummary
        if !streamedSummary {
            onEvent(.init(type: .delta, delta: finalSummary, fullText: finalSummary))
        }

        let result = TraceResult(
            summary: finalSummary,
            confidence: rankedSources.isEmpty ? 0.25 : 0.72,
            timeline: [],
            sources: resolvedSources,
            primaryEntity: primaryEntity,
            primaryEntities: primaryEntity.map { [$0] },
            relatedEntities: [],
            whyThis: primaryEntity?.whyThis ?? plan.whyThis,
            eventSummary: nil
        )
        return ResultSchemaAdapter.resultEnvelope(for: .trace(result), definition: request.definition, context: request.context)
    }

    private func runSchedule(
        request: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async throws -> SkillResultEnvelope {
        onEvent(
            .init(
                type: .status,
                status: "thinking",
                detail: localized(zhHans: "正在识别日程信息…", en: "Identifying schedule details…", languageCode: request.context.uiLanguage)
            )
        )

        if !ScheduleRuntimeSupport.looksTimeRelatedText(request.context.text) {
            let summary = ScheduleRuntimeSupport.fallbackSummary(languageCode: request.context.responseLanguage)
            onEvent(.init(type: .delta, delta: summary, fullText: summary))
            return scheduleEnvelope(
                request: request,
                summary: summary,
                cards: [],
                metadata: [
                    "calendar_intent_count": "0",
                    "used_llm": "false"
                ]
            )
        }

        let localIntents = ScheduleRuntimeSupport.localIntents(from: request.context.text)
        if !localIntents.isEmpty {
            let summary = ScheduleRuntimeSupport.summary(for: localIntents, languageCode: request.context.uiLanguage)
            let cards = ScheduleRuntimeSupport.actionCards(from: localIntents, languageCode: request.context.uiLanguage)
            onEvent(.init(type: .delta, delta: summary, fullText: summary))
            if !cards.isEmpty {
                onEvent(.init(type: .supplement, cards: cards, artifacts: nil))
            }
            return scheduleEnvelope(
                request: request,
                summary: summary,
                cards: cards,
                metadata: [
                    "calendar_intent_count": String(localIntents.count),
                    "used_llm": "false"
                ]
            )
        }

        guard let configuration = try? await resolvedAIConfiguration(),
              !configuration.apiKey.isEmpty else {
            let summary = ScheduleRuntimeSupport.fallbackSummary(languageCode: request.context.responseLanguage)
            onEvent(.init(type: .delta, delta: summary, fullText: summary))
            return scheduleEnvelope(
                request: request,
                summary: summary,
                cards: [],
                metadata: [
                    "calendar_intent_count": "0",
                    "used_llm": "false"
                ]
            )
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let systemPrompt = try skillInstruction(for: request)
        let userPrompt = SkillPromptComposer.composeUserPrompt(
            sections: [
                "Selected content:\n\(request.context.text)",
                "Current timestamp: \(now)",
                "Current timezone: \(TimeZone.current.identifier)"
            ]
        )

        let rawText = (try? await llmClient.complete(
            configuration: configuration,
            messages: [
                .init(role: .system, content: systemPrompt),
                .init(role: .user, content: userPrompt)
            ],
            maxTokens: 220,
            timeout: 15
        )) ?? ""

        let extraction = IntentExtractor.extract(from: rawText)
        let cards = IntentExtractor.actionCards(from: extraction.calendarIntents)
        let summary: String
        if !extraction.calendarIntents.isEmpty {
            summary = ScheduleRuntimeSupport.summary(for: extraction.calendarIntents, languageCode: request.context.uiLanguage)
        } else if !extraction.cleanedText.isEmpty {
            summary = extraction.cleanedText
        } else {
            summary = ScheduleRuntimeSupport.fallbackSummary(languageCode: request.context.responseLanguage)
        }

        onEvent(.init(type: .delta, delta: summary, fullText: summary))
        if !cards.isEmpty {
            onEvent(.init(type: .supplement, cards: cards, artifacts: nil))
        }

        return scheduleEnvelope(
            request: request,
            summary: summary,
            cards: cards,
            metadata: [
                "calendar_intent_count": String(extraction.calendarIntents.count),
                "used_llm": "true"
            ]
        )
    }

    private func runCompress(
        request: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) -> SkillResultEnvelope {
        onEvent(
            .init(
                type: .status,
                status: "thinking",
                detail: localized(zhHans: "正在分析已选文件…", en: "Analyzing the selected files…", languageCode: request.context.uiLanguage)
            )
        )
        logRuntimeInvocation(
            skillID: request.definition.skillID,
            sourceText: request.context.filePaths.joined(separator: "\n"),
            details: [
                "phase": "start",
                "selected_paths": String(request.context.filePaths.count)
            ]
        )

        let report = CompressionRuntimeSupport.run(
            filePaths: request.context.filePaths,
            fileManager: .default,
            diagnosticsLogger: diagnosticsLogger
        )
        let summary = CompressionRuntimeSupport.summary(
            for: report,
            languageCode: request.context.responseLanguage
        )
        let cards = CompressionRuntimeSupport.cards(
            for: report,
            languageCode: request.context.uiLanguage
        )

        onEvent(.init(type: .delta, delta: summary, fullText: summary))
        if !cards.isEmpty {
            onEvent(.init(type: .supplement, cards: cards, artifacts: nil))
        }

        return SkillResultEnvelope(
            schemaVersion: request.definition.manifest.schemaVersion,
            skillID: request.definition.skillID,
            resultType: request.definition.resultType,
            summary: summary,
            body: summary,
            primaryAction: cards.first?.action,
            secondaryActions: [],
            cards: cards,
            artifacts: [],
            copyPayload: nil,
            replacePayload: nil,
            followups: [],
            metadata: [
                "compressed_count": String(report.processed.count),
                "skipped_count": String(report.skipped.count),
                "selected_item_count": String(report.selectedItemCount),
                "expanded_file_count": String(report.expandedFileCount),
                "used_llm": "false",
                "output_dir": report.outputDirectory
            ]
        )
    }

    private func runGenericSkill(
        request: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async throws -> SkillResultEnvelope {
        let knowledgeMatches = request.definition.usesKnowledgeBase ? resolveKnowledgeMatches(query: request.context.text, limit: 4) : []
        let sourceCards = knowledgeSourceCards(from: knowledgeMatches, uiLanguage: request.context.uiLanguage)
        let knowledgeContext = knowledgeContextText(from: knowledgeMatches, responseLanguage: request.context.responseLanguage)
        let instructionText = try skillInstruction(for: request)
        let systemPrompt = SkillPromptComposer.composeSystemPrompt(
            instructionText: instructionText,
            fallback: instructionText,
            appendedSections: []
        )

        let userPrompt = SkillPromptComposer.composeUserPrompt(
            sections: [
                "Selected content:\n\(request.context.text)",
                "Output language: \(request.context.responseLanguage)",
                knowledgeContext.isEmpty ? nil : knowledgeContext
            ]
        )

        onEvent(
            .init(
                type: .status,
                status: "thinking",
                detail: localized(zhHans: "正在执行技能…", en: "Running the skill…", languageCode: request.context.uiLanguage)
            )
        )
        logRuntimeInvocation(
            skillID: request.definition.skillID,
            sourceText: request.context.text,
            details: [
                "phase": "start",
                "knowledge_matches": String(knowledgeMatches.count)
            ]
        )
        let fallback = genericSkillUnavailableMessage(
            skillName: request.definition.title,
            responseLanguage: request.context.responseLanguage
        )

        guard let configuration = try? await resolvedAIConfiguration(),
              !configuration.apiKey.isEmpty else {
            onEvent(.init(type: .delta, delta: fallback, fullText: fallback))
            var envelope = ResultSchemaAdapter.resultEnvelope(
                for: .info(fallback),
                definition: request.definition,
                context: request.context
            )
            envelope = SkillResultEnvelope(
                schemaVersion: envelope.schemaVersion,
                skillID: envelope.skillID,
                resultType: envelope.resultType,
                summary: envelope.summary,
                body: envelope.body,
                primaryAction: envelope.primaryAction,
                secondaryActions: envelope.secondaryActions,
                cards: sourceCards,
                artifacts: envelope.artifacts,
                copyPayload: envelope.copyPayload,
                replacePayload: envelope.replacePayload,
                followups: envelope.followups,
                metadata: (envelope.metadata ?? [:]).merging([
                    "used_knowledge_base": sourceCards.isEmpty ? "false" : "true",
                    "knowledge_base_source_count": String(sourceCards.count)
                ]) { _, new in new }
            )
            return envelope
        }

        let streamingState = StreamAccumulator()
        var output = ""
        do {
            output = try await llmClient.stream(
                configuration: configuration,
                messages: [
                    .init(role: .system, content: systemPrompt),
                    .init(role: .user, content: userPrompt)
                ],
                maxTokens: max(220, min(1200, request.context.text.count * 3))
            ) { delta in
                let merge = streamingState.append(incoming: delta)
                guard !merge.appended.isEmpty else { return }
                onEvent(.init(type: .delta, delta: merge.appended, fullText: merge.fullText))
            }
        } catch {
            let streamedText = streamingState.snapshot()
            output = streamedText.isEmpty ? fallback : streamedText
            if streamedText.isEmpty, !fallback.isEmpty {
                onEvent(.init(type: .delta, delta: fallback, fullText: fallback))
            }
        }

        let initialOutput = RuntimeTextSanitizer.sanitizeSummaryOutput(output).isEmpty
            ? fallback
            : RuntimeTextSanitizer.sanitizeSummaryOutput(output)
        let finalOutput = try await validatedOutput(
            skillID: request.definition.skillID,
            sourceText: request.context.text,
            candidateText: initialOutput,
            configuration: configuration,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            responseLanguage: request.context.responseLanguage,
            targetLanguage: nil,
            sanitizer: RuntimeTextSanitizer.sanitizeSummaryOutput,
            fallback: { _ in fallback }
        )

        var envelope = ResultSchemaAdapter.resultEnvelope(
            for: .info(finalOutput),
            definition: request.definition,
            context: request.context
        )
        envelope = SkillResultEnvelope(
            schemaVersion: envelope.schemaVersion,
            skillID: envelope.skillID,
            resultType: envelope.resultType,
            summary: envelope.summary,
            body: envelope.body,
            primaryAction: envelope.primaryAction,
            secondaryActions: envelope.secondaryActions,
            cards: sourceCards,
            artifacts: envelope.artifacts,
            copyPayload: envelope.copyPayload,
            replacePayload: envelope.replacePayload,
            followups: envelope.followups,
            metadata: (envelope.metadata ?? [:]).merging([
                "used_knowledge_base": sourceCards.isEmpty ? "false" : "true",
                "knowledge_base_source_count": String(sourceCards.count)
            ]) { _, new in new }
        )
        return envelope
    }

    private func runLLMBackedTextSkill(
        request: SkillExecutionRequest,
        systemPrompt: String,
        userPrompt: String,
        status: String,
        onEvent: @escaping (SkillRuntimeEvent) -> Void,
        resultBuilder: @escaping (String) -> ActionResult
    ) async throws -> SkillResultEnvelope {
        let configuration = try await resolvedAIConfiguration()
        onEvent(.init(type: .status, status: "thinking", detail: status))

        let streamingState = StreamAccumulator()
        let text = try await llmClient.stream(
            configuration: configuration,
            messages: [
                .init(role: .system, content: systemPrompt),
                .init(role: .user, content: userPrompt)
            ],
            maxTokens: 1200
        ) { delta in
            let merge = streamingState.append(incoming: delta)
            guard !merge.appended.isEmpty else { return }
            onEvent(.init(type: .delta, delta: merge.appended, fullText: merge.fullText))
        }

        let result = resultBuilder(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return ResultSchemaAdapter.resultEnvelope(for: result, definition: request.definition, context: request.context)
    }

    private func resolveKnowledgeMatches(query: String, limit: Int) -> [KnowledgeBaseSearchMatch] {
        knowledgeBaseStore.searchEntries(query: query, limit: limit)
    }

    private func skillInstruction(for request: SkillExecutionRequest) throws -> String {
        guard let instruction = request.definition.instructionText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !instruction.isEmpty else {
            throw ActionError.network(
                L10n.format(
                    zhHans: "Skill %@ 缺少 instruction.md，无法执行。",
                    en: "Skill %@ is missing instruction.md and cannot run.",
                    request.definition.skillID
                )
            )
        }
        return instruction
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

    private func searchSources(for query: String) async throws -> [SourceRecord] {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encodedQuery)") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        return TraceRuntimeSupport.searchResults(from: html, query: query, limit: 6)
    }

    private func searchSources(for queries: [String], limitPerQuery: Int) async throws -> [SourceRecord] {
        var aggregated: [SourceRecord] = []
        var seenURLs: Set<String> = []

        for query in queries {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let hits = try await searchSources(for: trimmed)
            for source in hits.prefix(limitPerQuery) {
                let key = source.url.lowercased()
                guard seenURLs.insert(key).inserted else { continue }
                aggregated.append(source)
            }
        }

        return aggregated
    }

    private func mergeSources(primary: [SourceRecord], augmented: [SourceRecord]) -> [SourceRecord] {
        var merged: [SourceRecord] = []
        var seenURLs: Set<String> = []

        for source in primary + augmented {
            let key = source.url.lowercased()
            guard seenURLs.insert(key).inserted else { continue }
            merged.append(source)
        }

        return merged
    }

    private func traceEntity(from plan: TracePlanDescriptor, sources: [SourceRecord], languageCode: String) -> TraceEntity? {
        let topSource = sources.first
        let resolvedTitle = topSource?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedURL = topSource?.url ?? ""
        let plannedEntityName = plan.primaryEntityName.trimmingCharacters(in: .whitespacesAndNewlines)
        let entityName: String
        if !plannedEntityName.isEmpty, !looksLikeTraceNarrativeCandidate(plannedEntityName) {
            entityName = plannedEntityName
        } else {
            entityName = fallbackTraceEntityName(from: topSource)
        }
        guard !entityName.isEmpty else { return nil }

        return TraceEntity(
            name: entityName,
            entityType: plan.entityType,
            title: resolvedTitle?.isEmpty == false ? resolvedTitle! : entityName,
            url: resolvedURL,
            snippet: topSource?.snippet ?? "",
            whyThis: plan.whyThis,
            isOfficial: topSource?.isOfficial
        )
    }

    private func sanitizedTracePlan(
        _ plan: TracePlanDescriptor,
        sourceText: String,
        responseLanguage: String
    ) -> TracePlanDescriptor {
        let trimmedEntity = plan.primaryEntityName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEntity.isEmpty, looksLikeTraceNarrativeCandidate(trimmedEntity) else {
            return plan
        }

        return .init(
            intent: plan.intent,
            primaryEntityName: "",
            entityType: plan.entityType,
            whyThis: localized(
                zhHans: "当前选区没有抽出稳定实体，先按核心 claim 搜索候选来源，再在结果里收敛主入口。",
                en: "No stable entity could be extracted from the current selection, so NexHub falls back to claim-based search before resolving the best entry.",
                languageCode: responseLanguage
            ),
            ownerHints: plan.ownerHints,
            searchQueries: plan.searchQueries.isEmpty
                ? [TraceRuntimeSupport.searchQuery(for: sourceText, languageCode: responseLanguage)]
                : plan.searchQueries
        )
    }

    private func looksLikeTraceNarrativeCandidate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        if trimmed.range(of: #"[，。；：！？,.!?]"#, options: .regularExpression) != nil,
           trimmed.count >= 18 {
            return true
        }

        if trimmed.split(whereSeparator: \.isWhitespace).count > 6 {
            return true
        }

        let narrativeMarkers = [
            "这里更像是在找", "当前选区", "建议缩短", "继续搜索", "最值得打开",
            "正在", "优先", "说明", "分析", "一句", "入口"
        ]
        return trimmed.count >= 20 && narrativeMarkers.contains(where: trimmed.contains)
    }

    private func fallbackTraceEntityName(from source: SourceRecord?) -> String {
        guard let source else { return "" }
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, !looksLikeTraceNarrativeCandidate(title) {
            return title
        }

        guard let host = URL(string: source.url)?.host?.lowercased() else { return "" }
        let normalizedHost = host.replacingOccurrences(of: "www.", with: "")
        let parts = normalizedHost.split(separator: ".")
        if parts.count >= 2 {
            return String(parts[parts.count - 2])
        }
        return normalizedHost
    }

    private func traceFallbackSource(for plan: TracePlanDescriptor, languageCode: String) -> SourceRecord {
        let query = plan.searchQueries.first ?? plan.primaryEntityName
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return SourceRecord(
            title: "\(plan.primaryEntityName) Search Results",
            url: "https://duckduckgo.com/?q=\(encoded)",
            snippet: localized(
                zhHans: "暂时没有直接定位到稳定官方入口，先返回搜索结果页作为兜底。",
                en: "A stable official entry could not be confirmed directly, so the search results page is returned as a fallback.",
                languageCode: languageCode
            ),
            publishedAt: nil,
            sourceType: "reference",
            isOfficial: false
        )
    }

    private struct TranslationPromptPackage {
        let systemPrompt: String
        let userPrompt: String
        let retryUserPrompt: String?
        let foreignSegments: [String]
        let isIdentifierGlossary: Bool
    }

    private func translationPromptPackage(
        sourceText: String,
        decision: TranslationRoutingDecision,
        instructionText: String
    ) -> TranslationPromptPackage {
        let isIdentifierGlossary = looksIdentifierGlossarySelection(sourceText)
        let foreignSegments = LanguageRoutingSupport.foreignReadableSegments(
            in: sourceText,
            localLanguage: decision.targetLanguage
        )
        return TranslationPromptPackage(
            systemPrompt: translationSystemPrompt(instructionText: instructionText),
            userPrompt: translationUserPrompt(
                sourceText: sourceText,
                decision: decision,
                foreignSegments: foreignSegments,
                emphasizeSegments: false,
                emphasizeGlossaryTranslation: false
            ),
            retryUserPrompt: (decision.mode == .translateForeignSegmentsToLocal || isIdentifierGlossary)
                ? translationUserPrompt(
                    sourceText: sourceText,
                    decision: decision,
                    foreignSegments: foreignSegments,
                    emphasizeSegments: true,
                    emphasizeGlossaryTranslation: isIdentifierGlossary
                )
                : nil,
            foreignSegments: foreignSegments,
            isIdentifierGlossary: isIdentifierGlossary
        )
    }

    private func translationSystemPrompt(instructionText: String) -> String {
        SkillPromptComposer.composeSystemPrompt(
            instructionText: instructionText,
            fallback: instructionText
        )
    }

    private func translationUserPrompt(
        sourceText: String,
        decision: TranslationRoutingDecision,
        foreignSegments: [String],
        emphasizeSegments: Bool,
        emphasizeGlossaryTranslation: Bool
    ) -> String {
        let targetName = languageDisplayName(for: decision.targetLanguage)
        let responseName = languageDisplayName(for: decision.responseLanguage)
        let compact = sourceText.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isShortTerm = !compact.contains("\n") && compact.count <= 32 && compact.split(separator: " ").count <= 4
        let isIdentifierGlossary = looksIdentifierGlossarySelection(compact)
        let shortTermRules = "If the input is a single word or short noun phrase, return exactly one natural target-language equivalent. Do not duplicate fragments, do not add alternatives, and do not add notes."
        let longFormRules = "If the input is a sentence or paragraph, translate every sentence completely and faithfully. Do not summarize, shorten, paraphrase, or skip any part."
        let glossaryRules = "The selection is a glossary-like list of technical field names or manifest keys. Translate every item into a concise natural \(targetName) label in the same order. Do not simply echo the original identifiers. Preserve a literal token only if it is an exact brand name or code symbol with no natural translation."
        let routingRule: String
        switch decision.mode {
        case .fullTranslateToLocal:
            routingRule = "The selection is mainly in another language. Rewrite the full selection into \(targetName)."
        case .fullTranslateToCounterpart:
            routingRule = "The selection is already mainly in the user's current language. Translate the full selection into \(targetName)."
        case .translateForeignSegmentsToLocal:
            routingRule = "The selection is mixed-language. Rewrite the full selection into a single natural \(targetName) passage so it no longer reads like a bilingual original."
        }
        let identifierRule = isIdentifierGlossary
            ? glossaryRules
            : looksCodeLikeFragment(compact)
            ? "If a token is clearly a literal code-like identifier, property path, placeholder, or file path, keep it only when changing it would make it harder to locate."
            : "Only literal file paths, URLs, code-like identifiers, and exact product names may remain unchanged when needed for recognition. Ordinary foreign-language words and phrases should be localized in context."
        let executionRules = isIdentifierGlossary ? glossaryRules : (isShortTerm ? shortTermRules : longFormRules)
        let glossarySection = isIdentifierGlossary
            ? """

            Glossary handling:
            Translate each listed item separately and keep the original item order.
            \(emphasizeGlossaryTranslation ? "This is a repair attempt because the previous answer echoed the original identifiers. Do not repeat the source items verbatim." : "Return only the translated list without explanations or commentary.")
            """
            : ""

        let segmentSection: String
        if decision.mode == .translateForeignSegmentsToLocal, !foreignSegments.isEmpty {
            let renderedSegments = foreignSegments.prefix(8).map { "- \($0)" }.joined(separator: "\n")
            segmentSection = """

            Foreign segments detected:
            \(renderedSegments)
            \(emphasizeSegments ? "Translate each detected foreign-language segment above in context unless it is obviously just a standalone brand name or identifier." : "Use those detected foreign-language segments as localization targets while keeping only truly necessary anchor tokens.")
            """
        } else {
            segmentSection = ""
        }

        return """
        Runtime fields:
        Translation mode: \(decision.mode.rawValue)
        Target language: \(decision.targetLanguage)
        Response language: \(decision.responseLanguage)
        Target language display: \(targetName)
        Response language display: \(responseName)

        Task:
        Translate the selected text into \(targetName) for immediate understanding.
        \(routingRule)

        Execution rules:
        \(executionRules)
        \(identifierRule)
        Return only the translated text.
        \(glossarySection)
        \(segmentSection)

        Selected text:
        \(sourceText)
        """
    }

    private func looksCodeLikeFragment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"[\{\}\[\]\(\)_./\\]"#, options: .regularExpression) != nil {
            return true
        }
        return trimmed.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil
    }

    private func looksIdentifierGlossarySelection(_ text: String) -> Bool {
        let items = identifierGlossaryItems(in: text)
        guard items.count >= 2 else { return false }

        let identifierLikeCount = items.filter { item in
            item.range(
                of: #"^[A-Za-z][A-Za-z0-9]*(?:[._-][A-Za-z0-9]+)*$"#,
                options: .regularExpression
            ) != nil
            || item.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil
            || item.contains(".")
        }.count

        return identifierLikeCount * 2 >= items.count
    }

    private func identifierGlossaryItems(in text: String) -> [String] {
        let rawItems = text
            .components(separatedBy: CharacterSet(charactersIn: ",，、;；\n"))
            .map {
                $0.trimmingCharacters(
                    in: CharacterSet(charactersIn: " \t\r\n\"'`“”‘’()[]{}<>《》「」【】")
                )
            }
            .filter { !$0.isEmpty }

        return rawItems.filter { item in
            item.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
                && item.split(whereSeparator: \.isWhitespace).count <= 3
        }
    }

    private func mixedSegmentTranslationFallback(
        sourceText: String,
        decision: TranslationRoutingDecision,
        instructionText: String,
        invalidOutput: String,
        invalidReason: String,
        configuration: LLMRequestConfiguration,
        skillID: String
    ) async throws -> String? {
        guard decision.mode == .translateForeignSegmentsToLocal else { return nil }

        let segments = translatableMixedSegments(in: sourceText, targetLanguage: decision.targetLanguage)
        guard !segments.isEmpty else { return nil }

        logRuntimeInvocation(
            skillID: skillID,
            sourceText: sourceText,
            details: [
                "phase": "mixed_translation_repair",
                "reason": invalidReason,
                "segment_count": String(segments.count)
            ]
        )

        let repairedRaw = try await llmClient.complete(
            configuration: configuration,
            messages: mixedSegmentTranslationMessages(
                sourceText: sourceText,
                decision: decision,
                instructionText: instructionText,
                invalidOutput: invalidOutput,
                segments: segments
            ),
            maxTokens: translationMaxTokens(for: sourceText),
            timeout: 45
        )
        let sanitized = RuntimeTextSanitizer.sanitizeTranslationOutput(
            sourceText: sourceText,
            translated: repairedRaw
        )
        let validation = RuntimeOutputGuard.validate(
            skillID: skillID,
            sourceText: sourceText,
            outputText: sanitized,
            responseLanguage: decision.responseLanguage,
            targetLanguage: decision.targetLanguage
        )
        logOutputValidation(
            skillID: skillID,
            attempt: 3,
            validation: validation,
            sourceText: sourceText,
            outputText: sanitized
        )

        guard validation.isValid, !sanitized.isEmpty else { return nil }
        return sanitized
    }

    private func identifierGlossaryTranslationFallback(
        sourceText: String,
        decision: TranslationRoutingDecision,
        instructionText: String,
        invalidOutput: String,
        invalidReason: String,
        configuration: LLMRequestConfiguration,
        skillID: String
    ) async throws -> String? {
        let items = identifierGlossaryItems(in: sourceText)
        guard looksIdentifierGlossarySelection(sourceText), !items.isEmpty else { return nil }

        logRuntimeInvocation(
            skillID: skillID,
            sourceText: sourceText,
            details: [
                "phase": "identifier_glossary_repair",
                "reason": invalidReason,
                "item_count": String(items.count)
            ]
        )

        let targetName = languageDisplayName(for: decision.targetLanguage)
        let renderedItems = items.prefix(16).map { "- \($0)" }.joined(separator: "\n")
        let repairedRaw = try await llmClient.complete(
            configuration: configuration,
            messages: [
                .init(
                    role: .system,
                    content: SkillPromptComposer.composeSystemPrompt(
                        instructionText: instructionText,
                        fallback: instructionText,
                        appendedSections: [
                            "You are repairing a glossary-style translation failure. Translate every listed technical key into a natural target-language label in the same order."
                        ]
                    )
                ),
                .init(
                    role: .user,
                    content: """
                    The previous translation echoed the original identifiers instead of translating them.
                    Translate each item below into concise natural \(targetName) labels in the same order.
                    Return only the translated list. Do not add notes, bullets, or the original identifiers unless an item is an exact brand or code symbol with no natural translation.

                    Items:
                    \(renderedItems)

                    Original selection:
                    \(sourceText)

                    Previous invalid translation:
                    \(invalidOutput)
                    """
                )
            ],
            maxTokens: translationMaxTokens(for: sourceText),
            timeout: 45
        )
        let sanitized = RuntimeTextSanitizer.sanitizeTranslationOutput(
            sourceText: sourceText,
            translated: repairedRaw
        )
        let validation = RuntimeOutputGuard.validate(
            skillID: skillID,
            sourceText: sourceText,
            outputText: sanitized,
            responseLanguage: decision.responseLanguage,
            targetLanguage: decision.targetLanguage
        )
        logOutputValidation(
            skillID: skillID,
            attempt: 3,
            validation: validation,
            sourceText: sourceText,
            outputText: sanitized
        )

        guard validation.isValid, !sanitized.isEmpty else { return nil }
        return sanitized
    }

    private func mixedSegmentTranslationMessages(
        sourceText: String,
        decision: TranslationRoutingDecision,
        instructionText: String,
        invalidOutput: String,
        segments: [String]
    ) -> [LLMChatMessage] {
        let targetName = languageDisplayName(for: decision.targetLanguage)
        let renderedSegments = segments.prefix(12).map { "- \($0)" }.joined(separator: "\n")
        let systemPrompt = SkillPromptComposer.composeSystemPrompt(
            instructionText: instructionText,
            fallback: instructionText,
            appendedSections: [
                "You are repairing a mixed-language translation failure. Rewrite the entire original selection into the target language so the final result is not bilingual."
            ]
        )
        let userPrompt = """
        The previous translation still preserved untranslated foreign-language content.
        Rewrite the entire original selection into natural \(targetName).
        Return only the final translated text.

        Literal file paths, URLs, and code identifiers may remain unchanged when necessary for recognition.
        Ordinary foreign-language words and phrases must be localized in context.

        Original mixed-language text:
        \(sourceText)

        Previous invalid translation:
        \(invalidOutput)

        Foreign-language phrases detected in the original text:
        \(renderedSegments)
        """
        return [
            .init(role: .system, content: systemPrompt),
            .init(role: .user, content: userPrompt)
        ]
    }

    private func translatableMixedSegments(in sourceText: String, targetLanguage: String) -> [String] {
        LanguageRoutingSupport.foreignReadableSegments(
            in: sourceText,
            localLanguage: targetLanguage
        ).filter { segment in
            !isPreservableMixedAnchorPhrase(segment)
        }
    }

    private func isPreservableMixedAnchorPhrase(_ segment: String) -> Bool {
        let tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return false }
        if tokens.count == 1 {
            return isPreservableMixedAnchorToken(tokens[0])
        }
        return tokens.allSatisfy(isStrongPreservableMixedAnchorToken)
    }

    private func isPreservableMixedAnchorToken(_ token: String) -> Bool {
        let compact = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return false }
        return isStrongPreservableMixedAnchorToken(compact)
            || compact.range(of: #"^[A-Z][a-z]{2,24}$"#, options: .regularExpression) != nil
    }

    private func isStrongPreservableMixedAnchorToken(_ token: String) -> Bool {
        let compact = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return false }
        if compact.range(of: #"^[A-Z0-9]{2,8}$"#, options: .regularExpression) != nil {
            return true
        }
        return compact.range(of: #"[A-Z].*[A-Z]"#, options: .regularExpression) != nil
    }

    private func tracePrimaryEntitySection(_ entity: TraceEntity) -> String {
        """
        Primary entity:
        Name: \(entity.name)
        Type: \(entity.entityType)
        Title: \(entity.title)
        URL: \(entity.url)
        Summary: \(entity.snippet)
        Why this: \(entity.whyThis ?? "")
        Official: \(String(entity.isOfficial ?? false))
        """
    }

    private func deterministicTraceSummary(
        primaryEntity: TraceEntity?,
        topSource: SourceRecord?,
        intent: TraceIntentDescriptor,
        languageCode: String
    ) -> String {
        let subject = primaryEntity?.title.isEmpty == false ? primaryEntity?.title : primaryEntity?.name
        let entityName = (subject ?? primaryEntity?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceTitle = topSource?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceHost = URL(string: topSource?.url ?? "")?.host?.lowercased() ?? ""
        let unreliableSearchFallback = sourceHost.contains("duckduckgo.com")
            && (entityName.count > 36 || entityName.contains("：") || entityName.contains("，"))

        if AppLanguage.from(languageCode: languageCode) == .english {
            if !entityName.isEmpty, !sourceTitle.isEmpty, !unreliableSearchFallback {
                return "\(entityName) is the main target here. The best link to open first is \"\(sourceTitle)\" because it is the closest high-confidence entry among the current candidate sources."
            }
            if !entityName.isEmpty, !unreliableSearchFallback {
                return "This is most likely about \(entityName), but NexHub could not confirm a reliable source from the current selection yet. Try tracing a shorter sentence or the most source-specific phrase."
            }
            return "NexHub could not confirm a reliable source from the current selection yet. Try tracing a shorter sentence or the most source-specific phrase."
        }

        if !entityName.isEmpty, !sourceTitle.isEmpty, !unreliableSearchFallback {
            return "这里更像是在找「\(entityName)」相关的入口。最值得先打开的是「\(sourceTitle)」，因为它是当前候选来源里最贴近主目标的一条。"
        }
        if !entityName.isEmpty, !unreliableSearchFallback {
            return "这里更像是在找「\(entityName)」相关的来源，但当前选区还不足以确认可靠入口。建议缩短到最能代表出处的一句，再试一次。"
        }
        return "当前还没有找到足够可靠的来源入口。建议缩短到最能代表出处的一句，或只保留品牌名、标题、产品名后再试一次。"
    }

    private func traceSummaryMaxTokens(for text: String, sourceCount: Int) -> Int {
        520
    }

    private func traceSummarySystemPrompt(
        instructionText: String,
        responseLanguage: String
    ) -> String {
        return SkillPromptComposer.composeSystemPrompt(
            instructionText: instructionText,
            fallback: instructionText
        )
    }

    private func traceSummaryUserPrompt(
        selectedText: String,
        plan: TracePlanDescriptor,
        primaryEntity: TraceEntity?,
        responseLanguage: String,
        sourceLines: String
    ) -> String {
        if AppLanguage.from(languageCode: responseLanguage) == .english {
            return """
            Task: Based on the original text and the candidate sources, write a 3-4 sentence answer in English.
            Requirements:
            1. Understand the user's intent first. Do not turn it into a generic platform overview.
            2. The first sentence should directly explain what the target is, preferably as a concrete product, feature, model, or entry point.
            3. The second sentence should say which main entry is best to open.
            4. The third sentence should explain why. Add one more sentence only if event context is important.
            5. If the intent is experience_entry, emphasize direct access. If documentation, emphasize docs or integration. If official_source, emphasize the original official source.
            6. Output plain prose only.

            Original text:
            \(selectedText)

            Intent type:
            \(plan.intent.type)

            Intent summary:
            \(plan.intent.summary)

            Action goal:
            \(plan.intent.actionGoal)

            \(primaryEntity.map { tracePrimaryEntitySection($0) } ?? "")

            Candidate sources:
            \(sourceLines.isEmpty ? "None" : sourceLines)
            """
        }

        return """
        任务：根据原文和候选来源，给出 3-4 句中文回答。
        要求：
        1. 先理解用户意图，不要泛化成平台介绍。
        2. 第一句先直接回答「这是什么」，优先描述具体产品、功能、模型或入口。
        3. 第二句再说明最应该打开的主入口是什么。
        4. 第三句补一句判定依据；如果事件补充重要，可再补一句。
        5. 如果意图是 experience_entry，要强调可直接体验；如果是 documentation，要强调说明或接入；如果是 official_source，要强调官方出处。
        6. 只输出正文，不要条目符号。

        原文：
        \(selectedText)

        意图类型：
        \(plan.intent.type)

        意图摘要：
        \(plan.intent.summary)

        动作目标：
        \(plan.intent.actionGoal)

        \(primaryEntity.map { tracePrimaryEntitySection($0) } ?? "")

        候选来源：
        \(sourceLines.isEmpty ? "无" : sourceLines)
        """
    }

    private func tracePlan(
        for text: String,
        configuration: LLMRequestConfiguration?,
        responseLanguage: String
    ) async throws -> TracePlanDescriptor? {
        guard let configuration, !configuration.apiKey.isEmpty else { return nil }

        let systemPrompt = """
        You are the planning brain for a source-grounding agent.
        First deeply understand the user's text intent, then identify which concrete entity the user most likely wants to open.
        Prefer products, websites, apps, models, repos, papers, people, or companies mentioned in the text.
        When the text implies free trial, experience, playground, docs, or official announcement, reflect that in the intent type and action goal.
        Do not return the article or news post itself unless there is no better entity target.
        Return strict JSON only.
        """
        let userPrompt = """
        阅读下面文本，并返回严格 JSON。

        Text:
        \(text)

        任务要求：
        1. 先判断用户真正想找的对象和意图，而不是复述新闻。
        2. intent_type 只能从以下枚举中选择一个：product_lookup, feature_lookup, model_lookup, documentation, experience_entry, official_source。
        3. action_goal 用一句中文说明最该帮助用户打开什么样的页面，例如官网、功能页、模型页、体验页、官方公告页。
        4. 输出 primary_entity 时，要体现主目标实体，以及为什么它值得被打开。
        5. 如果文本里还提到其他相关实体，可在 owner_hints 中写出属主或品牌提示。
        6. aliases 只保留最重要的中英文别名，不要凑数量。
        7. 不需要生成 search_queries，后续会由系统根据实体自动规划。

        返回 JSON 结构：
        {
          "intent_type": "product_lookup/feature_lookup/model_lookup/documentation/experience_entry/official_source",
          "intent_summary": "一句中文，说明用户真正想找什么",
          "action_goal": "一句中文，说明最该打开哪种页面",
          "primary_entity": {
            "name": "实体名",
            "entity_type": "product/company/person/model/repo/paper/app/website/link",
            "why_this": "一句中文，说明为什么它是用户最可能想点开的对象",
            "owner_hints": ["属主或品牌提示"],
            "aliases": ["别名或中英文名称"]
          }
        }

        只返回 JSON，不要 markdown，不要解释。
        """

        let raw = try await llmClient.complete(
            configuration: configuration,
            messages: [
                .init(role: .system, content: systemPrompt),
                .init(role: .user, content: userPrompt)
            ],
            maxTokens: 260,
            timeout: 30
        )

        guard let payload = extractJSONObject(from: raw),
              let primaryPayload = payload["primary_entity"] as? [String: Any] else {
            return nil
        }

        let primaryName = (primaryPayload["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !primaryName.isEmpty else { return nil }

        let entityType = ((primaryPayload["entity_type"] as? String) ?? "product")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let whyThis = ((primaryPayload["why_this"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerHints = ((primaryPayload["owner_hints"] as? [String]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let intentType = ((payload["intent_type"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let intentSummary = ((payload["intent_summary"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actionGoal = ((payload["action_goal"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let heuristicIntent = TraceRuntimeSupport.inferIntent(for: text, languageCode: responseLanguage)
        let plannedIntent = TraceIntentDescriptor(
            type: intentType.isEmpty ? heuristicIntent.type : intentType,
            summary: intentSummary.isEmpty ? heuristicIntent.summary : intentSummary,
            actionGoal: actionGoal.isEmpty ? heuristicIntent.actionGoal : actionGoal
        )

        return TraceRuntimeSupport.composePlan(
            primaryEntityName: primaryName,
            entityType: entityType.isEmpty ? "product" : entityType,
            whyThis: whyThis.isEmpty
                ? localized(
                    zhHans: "按模型规划识别出这是当前最值得先打开的主目标实体。",
                    en: "The planning pass identified this as the main entity most worth opening first.",
                    languageCode: responseLanguage
                )
                : whyThis,
            ownerHints: ownerHints,
            intent: plannedIntent,
            text: text
        )
    }

    private func extractJSONObject(from text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return nil
        }
        let jsonText = String(text[start...end])
        guard let data = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func validatedOutput(
        skillID: String,
        sourceText: String,
        candidateText: String,
        configuration: LLMRequestConfiguration,
        systemPrompt: String,
        userPrompt: String,
        responseLanguage: String,
        targetLanguage: String?,
        repairMaxTokens: Int = 900,
        sanitizer: (String) -> String,
        fallback: @escaping @Sendable (RuntimeOutputValidation) async throws -> String
    ) async throws -> String {
        let initialValidation = RuntimeOutputGuard.validate(
            skillID: skillID,
            sourceText: sourceText,
            outputText: candidateText,
            responseLanguage: responseLanguage,
            targetLanguage: targetLanguage
        )
        logOutputValidation(
            skillID: skillID,
            attempt: 1,
            validation: initialValidation,
            sourceText: sourceText,
            outputText: candidateText
        )
        guard !initialValidation.isValid else { return candidateText }

        let repairedRaw: String?
        do {
            repairedRaw = try await llmClient.complete(
                configuration: configuration,
                messages: repairMessages(
                    skillID: skillID,
                    baseSystemPrompt: systemPrompt,
                    baseUserPrompt: userPrompt,
                sourceText: sourceText,
                invalidOutput: candidateText,
                reason: initialValidation.reason,
                responseLanguage: responseLanguage,
                targetLanguage: targetLanguage
            ),
                maxTokens: repairMaxTokens,
                timeout: 30
            )
        } catch {
            diagnosticsLogger.log(
                "ai.runtime",
                "skill=\(skillID) phase=repair_request_failed reason=\(initialValidation.reason) error=\(error.localizedDescription)"
            )
            repairedRaw = nil
        }

        if let repairedRaw {
            let repairedText = sanitizer(repairedRaw).trimmingCharacters(in: .whitespacesAndNewlines)
            let repairedValidation = RuntimeOutputGuard.validate(
                skillID: skillID,
                sourceText: sourceText,
                outputText: repairedText,
                responseLanguage: responseLanguage,
                targetLanguage: targetLanguage
            )
            logOutputValidation(
                skillID: skillID,
                attempt: 2,
                validation: repairedValidation,
                sourceText: sourceText,
                outputText: repairedText
            )
            if repairedValidation.isValid, !repairedText.isEmpty {
                return repairedText
            }
            return try await finalizedFallbackOutput(
                skillID: skillID,
                sourceText: sourceText,
                responseLanguage: responseLanguage,
                targetLanguage: targetLanguage,
                sanitizer: sanitizer,
                fallbackValidation: repairedValidation,
                fallback: fallback
            )
        }

        return try await finalizedFallbackOutput(
            skillID: skillID,
            sourceText: sourceText,
            responseLanguage: responseLanguage,
            targetLanguage: targetLanguage,
            sanitizer: sanitizer,
            fallbackValidation: initialValidation,
            fallback: fallback
        )
    }

    private func finalizedFallbackOutput(
        skillID: String,
        sourceText: String,
        responseLanguage: String,
        targetLanguage: String?,
        sanitizer: (String) -> String,
        fallbackValidation: RuntimeOutputValidation,
        fallback: @escaping @Sendable (RuntimeOutputValidation) async throws -> String
    ) async throws -> String {
        let fallbackRaw = try await fallback(fallbackValidation)
        let fallbackText = sanitizer(fallbackRaw).trimmingCharacters(in: .whitespacesAndNewlines)
        let validation = RuntimeOutputGuard.validate(
            skillID: skillID,
            sourceText: sourceText,
            outputText: fallbackText,
            responseLanguage: responseLanguage,
            targetLanguage: targetLanguage
        )
        logOutputValidation(
            skillID: skillID,
            attempt: 3,
            validation: validation,
            sourceText: sourceText,
            outputText: fallbackText
        )
        if validation.isValid, !fallbackText.isEmpty {
            return fallbackText
        }

        diagnosticsLogger.log(
            "ai.runtime",
            "skill=\(skillID) phase=fallback_invalid reason=\(validation.reason)"
        )
        return fallbackText
    }

    private func repairMessages(
        skillID: String,
        baseSystemPrompt: String,
        baseUserPrompt: String,
        sourceText: String,
        invalidOutput: String,
        reason: String,
        responseLanguage: String,
        targetLanguage: String?
    ) -> [LLMChatMessage] {
        let correctionSection: String
        if skillID == "translate" {
            correctionSection = """
            The previous output was invalid because it either repeated the source text or used the wrong language.
            You must produce an actual translation now.
            Return only the corrected translation in \(languageDisplayName(for: targetLanguage ?? responseLanguage)).
            """
        } else {
            correctionSection = """
            The previous output was invalid because it mostly repeated the selected text.
            Do not quote or restate the source. Complete the actual skill task directly.
            Return only the corrected final content.
            """
        }

        let system = SkillPromptComposer.composeSystemPrompt(
            instructionText: baseSystemPrompt,
            fallback: baseSystemPrompt,
            appendedSections: [correctionSection]
        )
        let user = SkillPromptComposer.composeUserPrompt(
            sections: [
                "Original task:\n\(baseUserPrompt)",
                "Selected content:\n\(sourceText)",
                "Previous invalid output:\n\(invalidOutput)",
                "Why invalid:\n\(reason)"
            ]
        )
        return [
            .init(role: .system, content: system),
            .init(role: .user, content: user)
        ]
    }

    private func logOutputValidation(
        skillID: String,
        attempt: Int,
        validation: RuntimeOutputValidation,
        sourceText: String,
        outputText: String
    ) {
        diagnosticsLogger.log(
            "ai.runtime",
            "skill=\(skillID) attempt=\(attempt) valid=\(validation.isValid) reason=\(validation.reason) source=\(diagnosticPreview(sourceText)) output=\(diagnosticPreview(outputText))"
        )
    }

    private func diagnosticPreview(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "<empty>" }
        return compact.count > 180 ? String(compact.prefix(180)) + "..." : compact
    }

    private func scheduleEnvelope(
        request: SkillExecutionRequest,
        summary: String,
        cards: [SkillResultCard],
        metadata: [String: String]
    ) -> SkillResultEnvelope {
        SkillResultEnvelope(
            schemaVersion: request.definition.manifest.schemaVersion,
            skillID: request.definition.skillID,
            resultType: request.definition.resultType,
            summary: summary,
            body: summary,
            primaryAction: cards.first?.action,
            secondaryActions: [],
            cards: cards,
            artifacts: [],
            copyPayload: nil,
            replacePayload: nil,
            followups: SkillFollowupResolver.resolve(
                skillID: request.definition.skillID,
                envelopeFollowups: nil,
                context: request.context
            ),
            metadata: metadata
        )
    }

    private func explainRuntimeSection(languageCode: String) -> String {
        if AppLanguage.from(languageCode: languageCode) == .english {
            return """
            The final answer must be entirely in English and should explain the selected content directly.
            Lead with the answer itself.
            Write one short paragraph, usually 1 to 3 sentences.
            Avoid bullets, headings, and meta commentary.
            """
        }
        return """
        最终回答必须全部使用简体中文，并且直接解释用户选中的内容本身。
        默认第一句就给结论，像真人自然解释那样落地。
        输出写成短自然段，通常 1 到 3 句。
        不要分点、不要小标题、不要讲自己的推理过程。
        """
    }

    private func explainUserPrompt(selectedText: String, languageCode: String) -> String {
        if AppLanguage.from(languageCode: languageCode) == .english {
            return """
            Explain the content below so the user can immediately understand what it means in context.
            Lead with the answer itself: for a term, say what it refers to; for a sentence or paragraph, say what it is actually saying.
            Use a natural first sentence such as "X refers to...", "The point here is...", or "The core idea is...".
            Write one short paragraph, usually 1 to 3 sentences.

            Selected content:
            \(selectedText)
            """
        }
        return """
        请直接解释下面这段内容，帮助用户马上看懂它在当前语境里是什么意思。
        默认第一句就给结论：术语就直接说它指什么，句子或段落就直接说它在表达什么。
        首句尽量像真人自然解释那样落地，比如「X 指…」「这里的重点是…」「核心意思是…」。
        输出写成短自然段，通常 1 到 3 句；能短就短，不要分点，不要小标题。

        用户选中的内容：
        \(selectedText)
        """
    }

    private func translationMaxTokens(for text: String) -> Int {
        max(900, min(3200, text.count * 4))
    }

    private func resolvedTranslationDecision(for context: SkillExecutionContext) -> TranslationRoutingDecision {
        let inferred = LanguageRoutingSupport.translationDecision(
            for: context.text,
            uiLanguage: context.uiLanguage
        )
        let targetLanguage = context.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? inferred.targetLanguage
            : context.targetLanguage
        let responseLanguage = context.responseLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? inferred.responseLanguage
            : context.responseLanguage
        let mode = context.translationMode
            .flatMap { TranslationMode(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? inferred.mode

        return TranslationRoutingDecision(
            targetLanguage: targetLanguage,
            responseLanguage: responseLanguage,
            mode: mode,
            detectedLanguage: inferred.detectedLanguage
        )
    }

    private func translationUnavailableMessage(responseLanguage: String) -> String {
        localized(
            zhHans: "当前翻译结果异常，暂时无法生成可靠译文。请稍后重试。",
            en: "The translation output was invalid, so NexHub could not produce a reliable translation right now. Please try again.",
            languageCode: responseLanguage
        )
    }

    private func genericSkillUnavailableMessage(skillName: String, responseLanguage: String) -> String {
        L10n.format(
            languageCode: responseLanguage,
            zhHans: "当前「%@」结果异常，暂时无法生成可靠内容。请稍后重试。",
            en: "The output from %@ was invalid, so NexHub could not produce a reliable result right now. Please try again.",
            skillName
        )
    }

    private func logRuntimeInvocation(skillID: String, sourceText: String, details: [String: String]) {
        let base = [
            "skill": skillID,
            "chars": String(sourceText.count),
            "lines": String(sourceText.components(separatedBy: "\n").count)
        ]
        let payload = base.merging(details) { _, new in new }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        diagnosticsLogger.log("ai.runtime", payload)
    }

    private func replyServiceUnavailableMessage(authFailed: Bool, responseLanguage: String) -> String {
        if AppLanguage.from(languageCode: responseLanguage) == .english {
            return authFailed
                ? "The managed AI service failed authentication, so NexHub cannot generate a knowledge-based answer right now. Contact your administrator."
                : "The AI service is unavailable right now, so NexHub cannot generate a knowledge-based answer. Please try again later."
        }
        return authFailed
            ? "当前托管 AI 服务鉴权失败，无法基于知识库生成回答。请联系管理员。"
            : "当前 AI 服务不可用，无法基于知识库生成回答。请稍后再试。"
    }

    private func isLikelyAuthenticationFailure(_ error: Error) -> Bool {
        let lowered = error.localizedDescription.lowercased()
        guard !lowered.isEmpty else { return false }
        return lowered.contains("401")
            || lowered.contains("403")
            || lowered.contains("unauthorized")
            || lowered.contains("authentication")
            || lowered.contains("invalid api key")
    }

    private func localized(zhHans: String, en: String, languageCode: String) -> String {
        L10n.text(languageCode: languageCode, zhHans: zhHans, en: en)
    }

    private func localizedAutomationDomains(_ domains: [String], languageCode: String) -> String {
        let labels = domains.map { domain in
            switch domain {
            case "web":
                return localized(zhHans: "网页", en: "Web", languageCode: languageCode)
            case "knowledge":
                return localized(zhHans: "知识库", en: "Knowledge", languageCode: languageCode)
            case "writeback":
                return localized(zhHans: "写回", en: "Writeback", languageCode: languageCode)
            case "calendar":
                return localized(zhHans: "日历", en: "Calendar", languageCode: languageCode)
            case "files":
                return localized(zhHans: "文件", en: "Files", languageCode: languageCode)
            case "automation":
                return localized(zhHans: "定时任务", en: "Automation", languageCode: languageCode)
            default:
                return domain
            }
        }
        return labels.isEmpty
            ? localized(zhHans: "通用 Agent", en: "General agent", languageCode: languageCode)
            : labels.joined(separator: " · ")
    }

    private func languageDisplayName(for code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("zh") {
            return "Simplified Chinese"
        }
        if normalized.hasPrefix("en") {
            return "English"
        }
        if normalized.isEmpty {
            return "Unknown"
        }
        return normalized
    }
}
