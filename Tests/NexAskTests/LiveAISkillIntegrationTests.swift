import AppKit
import Foundation
import XCTest
@testable import NexShared
@testable import NexAskCore

final class LiveAISkillIntegrationTests: XCTestCase {
    private struct LiveAIConfiguration {
        let provider: String
        let model: String
        let apiKey: String
    }

    private func liveConfiguration(file: StaticString = #filePath, line: UInt = #line) throws -> LiveAIConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NEXHUB_LIVE_AI_TESTS"] == "1" else {
            throw XCTSkip("Live AI tests are disabled.")
        }

        let apiKey = environment["NEXHUB_LIVE_AI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw XCTSkip("Missing NEXHUB_LIVE_AI_API_KEY.")
        }

        let provider = environment["NEXHUB_LIVE_AI_PROVIDER"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? environment["NEXHUB_LIVE_AI_PROVIDER"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "deepseek"
        let model = environment["NEXHUB_LIVE_AI_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? environment["NEXHUB_LIVE_AI_MODEL"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "deepseek-chat"

        guard !provider.isEmpty, !model.isEmpty else {
            XCTFail("Invalid live AI configuration.", file: file, line: line)
            throw XCTSkip("Invalid live AI configuration.")
        }

        return LiveAIConfiguration(provider: provider, model: model, apiKey: apiKey)
    }

    func testLiveTranslateMixedLanguageLocalizesForeignSegment() async throws {
        let runtime = try makeRuntime()
        let source = "这个 API endpoint 是做什么的？"
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: try XCTUnwrap(ActionRegistry.shared.definition(for: .translate)),
                context: SkillExecutionContext(
                    skillID: "translate",
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh-Hans",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil,
                    translationMode: "translate_foreign_segments_to_local"
                )
            )
        )

        let output = try XCTUnwrap(envelope.body)
        print("LIVE translate output: \(output)")
        XCTAssertNotEqual(normalizedComparable(output), normalizedComparable(source))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("endpoint"))
        XCTAssertTrue(output.contains("端点") || output.contains("接口") || output.contains("终结点"))
    }

    func testLiveTranslateLongMixedParagraphLocalizesEmbeddedEnglishPhrases() async throws {
        let runtime = try makeRuntime()
        let source = """
        这个版本的 release note 里提到，新的 onboarding flow 会先做 account linking，然后在 checkout page 预取 recommendation feed。如果用户从 email campaign 回流，系统会复用 last-touch attribution，并在 payment retry 失败后 fallback 到 manual review。请直接把整段意思翻成中文，方便我贴给团队同步。
        """
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: try XCTUnwrap(ActionRegistry.shared.definition(for: .translate)),
                context: SkillExecutionContext(
                    skillID: "translate",
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh-Hans",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil,
                    translationMode: "translate_foreign_segments_to_local"
                )
            )
        )

        let output = try XCTUnwrap(envelope.body)
        print("LIVE long mixed translate output: \(output)")
        XCTAssertNotEqual(normalizedComparable(output), normalizedComparable(source))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("checkout page"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("email campaign"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("manual review"))
    }

    func testLiveTranslateIdentifierGlossaryDoesNotEchoSourceList() async throws {
        let runtime = try makeRuntime()
        let source = "「priorityTier、supportedContexts、preferredContentTypes、routing.priorityRules、intentHints、contentHints」"
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: try XCTUnwrap(ActionRegistry.shared.definition(for: .translate)),
                context: SkillExecutionContext(
                    skillID: "translate",
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh-Hans",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        let output = try XCTUnwrap(envelope.body)
        print("LIVE glossary translate output: \(output)")
        XCTAssertNotEqual(normalizedComparable(output), normalizedComparable(source))
        XCTAssertTrue(containsChinese(output))
        XCTAssertFalse(output.contains("当前翻译结果异常"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("prioritytier、supportedcontexts"))
    }

    func testLiveTranslateArticleLengthMixedParagraphLocalizesLongEmbeddedEnglish() async throws {
        let runtime = try makeRuntime()
        let source = """
        这份内部复盘里提到，新的 onboarding flow 在 first-time user 进入 app 之后，会先触发 account linking，再在 dashboard header 里预取 recommendation feed，并把 growth experiment 的入口放在 checkout page 之前。产品团队发现，如果用户是从 email campaign 或 paid search 回流，系统会沿用 last-touch attribution 和 lifecycle scoring，在 payment retry 失败后 fallback 到 manual review，同时把 risk flag 和 support ticket 一并写回 CRM。为了让运营更快判断问题，他们还把 release note、incident timeline、owner comment 和 rollback decision 都同步到了 weekly report 里。文档最后还补充说，staging build 和 production parity 还没有完全补齐，所以某些 edge case 只会在 real-world traffic 下出现，后续需要继续补 observability、error budget 和 postmortem 模板。现在请把整段意思完整翻成中文，方便我直接转给团队，不要遗漏任何一句。
        """
        XCTAssertGreaterThan(source.count, 300)

        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: try XCTUnwrap(ActionRegistry.shared.definition(for: .translate)),
                context: SkillExecutionContext(
                    skillID: "translate",
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh-Hans",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil,
                    translationMode: "translate_foreign_segments_to_local"
                )
            )
        )

        let output = try XCTUnwrap(envelope.body)
        print("LIVE 300+ mixed translate output: \(output)")
        XCTAssertNotEqual(normalizedComparable(output), normalizedComparable(source))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("checkout page"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("manual review"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("weekly report"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("real-world traffic"))
    }

    func testLiveTranslateArticleLengthMixedParagraphViaStreamingPathLocalizesEmbeddedEnglish() async throws {
        let configuration = try liveConfiguration()
        let settings = makeSettings(configuration: configuration)
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtime = SkillRuntimeService(
            settings: settings,
            knowledgeBaseStore: ReplyKnowledgeBaseStore(fileManager: .default, rootDirectoryURL: storeRoot),
            diagnosticsLogger: makeLogger(),
            aiConfigurationProvider: {
                try LLMRequestConfiguration.from(settings: settings)
            }
        )
        let service = SkillExecutionService(settings: settings, runtimeService: runtime)
        let runner = SkillRunner(actionService: service)
        let source = """
        这份面向团队同步的 Markdown 草稿里写着：**新的 onboarding flow** 会在 first-time user 完成 account linking 后，先在 dashboard header 预取 recommendation feed，再把 growth experiment 放到 checkout page 之前；如果用户从 email campaign、paid search 或 weekly report 里的链接回流，系统会继续沿用 last-touch attribution 和 lifecycle scoring，并在 payment retry 失败后 fallback 到 manual review。文档最后还提醒说，staging build 和 production parity 还没完全补齐，所以 real-world traffic 下暴露出来的 edge case 仍然需要继续补 observability、error budget 和 postmortem 模板。现在请直接把整段意思完整翻成中文。
        """
        XCTAssertGreaterThan(source.count, 300)

        var latestFullText = ""
        let result = await runner.runStreamingEnvelope(
            skillID: "translate",
            context: SkillExecutionContext(
                skillID: "translate",
                text: source,
                targetLanguage: "zh",
                responseLanguage: "zh",
                uiLanguage: "zh-Hans",
                filePaths: [],
                followupDepth: 0,
                followupSourceSkillID: nil,
                translationMode: "translate_foreign_segments_to_local"
            )
        ) { event in
            if let fullText = event.fullText, !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                latestFullText = fullText
            }
        }

        let envelope = try result.get()
        let output = try XCTUnwrap(envelope.body)
        print("LIVE streaming translate output: \(output)")
        XCTAssertFalse(normalizedComparable(output).contains(String(normalizedComparable(source).prefix(48))))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("checkout page"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("manual review"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("weekly report"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("real-world traffic"))
        XCTAssertEqual(normalizedComparable(output), normalizedComparable(latestFullText))
    }

    func testLiveTraceReturnsCardsAndNonEchoSummary() async throws {
        let runtime = try makeRuntime()
        let source = """
        Duolingo 通过持续迭代核心产品机制，把留存与增长做成了一个长期飞轮。团队一方面优化 streak 和 push 节奏，降低用户中断学习的概率；另一方面不断打磨 feed、周榜、挑战和激励动画，让用户更容易获得即时反馈与成就感。同时他们围绕模板、文案、时机做了大量实验，逐步把学习行为变成一个更顺手也更容易坚持的习惯。现在我想溯源这段分析最值得先打开的一手官方入口，而不是继续看复述这段话的二手文章。
        """
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: try XCTUnwrap(ActionRegistry.shared.definition(for: .trace)),
                context: SkillExecutionContext(
                    skillID: "trace",
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh-Hans",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        let output = try XCTUnwrap(envelope.body)
        print("LIVE trace output: \(output)")
        XCTAssertFalse(output.isEmpty)
        XCTAssertFalse(normalizedComparable(output).contains(String(normalizedComparable(source).prefix(32))))
        XCTAssertGreaterThan((envelope.cards ?? []).count, 0)
        XCTAssertFalse((envelope.cards ?? []).first?.action?.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func testLiveExplainProducesChineseExplanation() async throws {
        let runtime = try makeRuntime()
        let source = "This API endpoint flushes the cache before retrying the request."
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: try XCTUnwrap(ActionRegistry.shared.definition(for: .explain)),
                context: SkillExecutionContext(
                    skillID: "explain",
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh-Hans",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        let output = try XCTUnwrap(envelope.body)
        print("LIVE explain output: \(output)")
        XCTAssertNotEqual(normalizedComparable(output), normalizedComparable(source))
        XCTAssertTrue(containsChinese(output))
    }

    func testLiveReplyReturnsAReplyInsteadOfEcho() async throws {
        let runtime = try makeRuntime()
        let source = "今天能不能确认一下设计评审时间？如果方便的话也请把你那边的修改点同步给我。"
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: try XCTUnwrap(ActionRegistry.shared.definition(for: .reply)),
                context: SkillExecutionContext(
                    skillID: "reply",
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh-Hans",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        let output = try XCTUnwrap(envelope.body)
        print("LIVE reply output: \(output)")
        XCTAssertFalse(output.isEmpty)
        XCTAssertNotEqual(normalizedComparable(output), normalizedComparable(source))
        XCTAssertFalse(output.contains("<calendar_intent>"))
    }

    func testLiveScheduleProducesCalendarResult() async throws {
        let runtime = try makeRuntime()
        let source = "提醒我下周找个时间做设计评审，最好放在下午。"
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: try XCTUnwrap(ActionRegistry.shared.definition(for: .schedule)),
                context: SkillExecutionContext(
                    skillID: "schedule",
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh-Hans",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        print("LIVE schedule output: \(envelope.body ?? "")")
        XCTAssertEqual(envelope.skillID, "schedule")
        XCTAssertFalse((envelope.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertGreaterThan((envelope.cards ?? []).count, 0)
    }

    func testLiveAskReturnsGroundedAssistantMessage() async throws {
        let runtime = try makeAskRuntime()
        let response = try await runtime.streamAsk(
            request: AskSessionRequest(
                messages: [
                    .init(role: .user, content: "用一句中文解释一下 API endpoint 是什么。")
                ],
                metadata: .init(
                    sessionID: UUID().uuidString.lowercased(),
                    sourceBundleID: "com.apple.finder",
                    sourceAppName: "Finder",
                    frame: .zero
                ),
                uiLanguage: "zh-Hans",
                responseLanguage: "zh"
            ),
            onEvent: { _ in }
        )

        print("LIVE ask output: \(response.message)")
        XCTAssertFalse(response.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(containsChinese(response.message))
    }

    func testLiveGenericAISkillReturnsNonEchoSummary() async throws {
        let runtime = try makeRuntime()
        let definition = makeGenericDefinition()
        let source = "The staging build still returns stale data after the first refresh because the cache invalidation step is delayed."
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: definition,
                context: SkillExecutionContext(
                    skillID: definition.skillID,
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh-Hans",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        let output = try XCTUnwrap(envelope.body)
        print("LIVE generic output: \(output)")
        XCTAssertFalse(output.isEmpty)
        XCTAssertNotEqual(normalizedComparable(output), normalizedComparable(source))
        XCTAssertTrue(containsChinese(output))
    }

    private func makeRuntime() throws -> SkillRuntimeService {
        let configuration = try liveConfiguration()
        let settings = makeSettings(configuration: configuration)
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SkillRuntimeService(
            settings: settings,
            knowledgeBaseStore: ReplyKnowledgeBaseStore(fileManager: .default, rootDirectoryURL: storeRoot),
            diagnosticsLogger: makeLogger(),
            aiConfigurationProvider: {
                try LLMRequestConfiguration.from(settings: settings)
            }
        )
    }

    private func makeAskRuntime() throws -> AskSkillRuntimeService {
        let configuration = try liveConfiguration()
        let settings = makeSettings(configuration: configuration)
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return AskSkillRuntimeService(
            knowledgeBaseStore: ReplyKnowledgeBaseStore(fileManager: .default, rootDirectoryURL: storeRoot),
            diagnosticsLogger: makeLogger(),
            aiConfigurationProvider: {
                try LLMRequestConfiguration.from(settings: settings)
            }
        )
    }

    private func makeSettings(configuration: LiveAIConfiguration) -> AppSettings {
        let suiteName = "NexHubTests.LiveAI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(
            defaults: defaults,
            secretsStore: LiveAISecretStore(),
            diagnosticsLogger: makeLogger()
        )
        try? settings.updateAIConfiguration(
            provider: configuration.provider,
            model: configuration.model,
            apiKey: configuration.apiKey
        )
        settings.appLanguage = .simplifiedChinese
        return settings
    }

    private func makeLogger() -> DiagnosticsLogger {
        DiagnosticsLogger(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),
            maxFileSizeBytes: 32 * 1024
        )
    }

    private func makeGenericDefinition() -> SkillDefinition {
        SkillDefinition(
            legacyAction: nil,
            manifest: SkillManifest(
                schemaVersion: "0.1",
                id: "live_generic_summary",
                name: "Live Generic Summary",
                display: SkillDisplay(
                    toolbarTitle: "Live Generic",
                    settingsTitle: "Live Generic",
                    resultTitle: "Live Generic Result",
                    icon: "sparkles",
                    category: "custom",
                    priorityTier: .secondary
                ),
                description: SkillDescription(summary: "Live generic AI summary", whenToUse: nil, notFor: nil),
                input: SkillInput(
                    supportedContexts: [.selectedText],
                    preferredContentTypes: [.text],
                    minLength: 1,
                    maxLength: 4000,
                    requiresNonemptySelection: true
                ),
                routing: SkillRouting(intentHints: ["summary"], contentHints: nil, priorityRules: nil, fallbackRank: 99),
                execution: SkillExecution(mode: .promptOnly, tools: [.llmChat], streaming: true, supportsFollowup: false, safeToInterrupt: true, instructionFile: "instruction.md"),
                result: SkillResultContract(
                    type: .summaryText,
                    supportsCopy: true,
                    supportsReplace: false,
                    supportsOpenPrimary: false,
                    supportsWriteback: false,
                    supportsRegenerate: true,
                    supportsFooter: true,
                    supportsActionCards: false
                ),
                lifecycle: SkillLifecycle(
                    showLoadingInResultWindow: true,
                    hideStatusOnFirstDelta: true,
                    revealFooterAfterCompletion: true,
                    deferSupplementsUntilContentComplete: true
                ),
                metadata: SkillMetadata(category: "custom", tags: ["summary"], experimental: false, builtIn: false)
            ),
            instructionText: """
            用简体中文输出一句简洁总结，帮助用户马上理解选中文本的核心意思。
            不要复述原文，不要分点，不要加标题。
            """,
            sourceDirectory: nil,
            skillSource: .installed
        )
    }

    private func normalizedComparable(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[[:punct:]]+"#, with: "", options: .regularExpression)
    }

    private func containsChinese(_ text: String) -> Bool {
        text.contains { "\u{4E00}" <= $0 && $0 <= "\u{9FFF}" }
    }
}

private final class LiveAISecretStore: SecretStoring {
    private var storage: [String: String] = [:]

    func string(for account: String) -> String? {
        storage[account]
    }

    @discardableResult
    func setString(_ value: String, for account: String) -> Bool {
        storage[account] = value
        return true
    }

    @discardableResult
    func removeString(for account: String) -> Bool {
        storage.removeValue(forKey: account)
        return true
    }
}
