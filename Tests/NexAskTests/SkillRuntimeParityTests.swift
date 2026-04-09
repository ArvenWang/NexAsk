import Foundation
import XCTest
@testable import NexShared
@testable import NexAskCore

final class SkillRuntimeParityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SkillRuntimeParityMockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        SkillRuntimeParityMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testInstalledGenericSkillKeepsDeclaredResultContract() {
        let definition = SkillDefinition(
            legacyAction: nil,
            manifest: SkillManifest(
                schemaVersion: "0.1",
                id: "custom_skill",
                name: "Custom Skill",
                display: SkillDisplay(
                    toolbarTitle: "Custom",
                    settingsTitle: "Custom",
                    resultTitle: "Custom Result",
                    icon: "sparkles",
                    category: "custom",
                    priorityTier: .secondary
                ),
                description: SkillDescription(summary: "Custom skill", whenToUse: nil, notFor: nil),
                input: SkillInput(
                    supportedContexts: [.selectedText],
                    preferredContentTypes: [.text],
                    minLength: 1,
                    maxLength: 2000,
                    requiresNonemptySelection: true
                ),
                routing: SkillRouting(intentHints: ["custom"], contentHints: nil, priorityRules: nil, fallbackRank: 99),
                execution: SkillExecution(mode: .promptOnly, tools: [.llmChat], streaming: true, supportsFollowup: false, safeToInterrupt: true, instructionFile: "instruction.md"),
                result: SkillResultContract(
                    type: .summaryText,
                    supportsCopy: true,
                    supportsReplace: true,
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
                metadata: SkillMetadata(category: "custom", tags: ["custom"], experimental: false, builtIn: false)
            ),
            instructionText: "Return a short answer.",
            sourceDirectory: nil,
            skillSource: .installed
        )

        let envelope = ResultSchemaAdapter.resultEnvelope(
            for: .info("Final custom output"),
            definition: definition,
            context: nil
        )

        XCTAssertEqual(envelope.resultType, .summaryText)
        XCTAssertEqual(envelope.copyPayload, "Final custom output")
        XCTAssertEqual(envelope.replacePayload, "Final custom output")
        XCTAssertEqual(envelope.metadata?["generic_skill"], "true")
    }

    func testTranslateRetriesWhenInitialModelOutputEchoesSource() async throws {
        let callCounter = CounterBox()
        SkillRuntimeParityMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let callIndex = callCounter.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": callIndex == 1 ? "text/event-stream" : "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)

            if callIndex == 1 {
                client?.urlProtocol(protocolInstance, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"这个 API endpoint 是做什么的\"}}]}\n\n".utf8))
                client?.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            } else {
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data(#"{"choices":[{"message":{"content":"这个 API 端点是做什么用的"}}]}"#.utf8)
                )
            }
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let settings = makeSettings()
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "secret")
        let session = makeSession()
        let runtime = makeRuntime(settings: settings, session: session)

        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: ActionRegistry.shared.definition(for: .translate),
                context: SkillExecutionContext(
                    skillID: "translate",
                    text: "这个 API endpoint 是做什么的",
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        XCTAssertEqual(callCounter.snapshot(), 2)
        XCTAssertEqual(envelope.body, "这个 API 端点是做什么用的")
    }

    func testTranslateMixedFallbackRepairsByTranslatingSegmentsOnly() async throws {
        let callCounter = CounterBox()
        SkillRuntimeParityMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let callIndex = callCounter.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": callIndex == 1 ? "text/event-stream" : "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)

            switch callIndex {
            case 1:
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"这个 first-time user 会在 payment retry 失败后 fallback 到 manual review。\"}}]}\n\n".utf8)
                )
                client?.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            case 2:
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data(#"{"choices":[{"message":{"content":"这个 first-time user 会在 payment retry 失败后 fallback 到 manual review。"}}]}"#.utf8)
                )
            default:
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data(#"{"choices":[{"message":{"content":"这个首次用户会在支付重试失败后回退到人工审核。"}}]}"#.utf8)
                )
            }

            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let settings = makeSettings()
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "secret")
        let session = makeSession()
        let runtime = makeRuntime(settings: settings, session: session)

        let source = "这个 first-time user 会在 payment retry 失败后 fallback 到 manual review。"
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: ActionRegistry.shared.definition(for: .translate),
                context: SkillExecutionContext(
                    skillID: "translate",
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil,
                    translationMode: "translate_foreign_segments_to_local"
                )
            )
        )

        XCTAssertEqual(callCounter.snapshot(), 3)
        XCTAssertEqual(envelope.body, "这个首次用户会在支付重试失败后回退到人工审核。")
    }

    func testTranslateIdentifierGlossaryFallbackRepairsLiteralEcho() async throws {
        let callCounter = CounterBox()
        SkillRuntimeParityMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let callIndex = callCounter.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": callIndex == 1 ? "text/event-stream" : "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)

            switch callIndex {
            case 1:
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"priorityTier、supportedContexts、preferredContentTypes、routing.priorityRules、intentHints、contentHints\"}}]}\n\n".utf8)
                )
                client?.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            case 2:
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data(#"{"choices":[{"message":{"content":"priorityTier、supportedContexts、preferredContentTypes、routing.priorityRules、intentHints、contentHints"}}]}"#.utf8)
                )
            default:
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data(#"{"choices":[{"message":{"content":"优先级层级、支持的上下文、首选内容类型、路由优先级规则、意图提示、内容提示"}}]}"#.utf8)
                )
            }

            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let settings = makeSettings()
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "secret")
        let session = makeSession()
        let runtime = makeRuntime(settings: settings, session: session)

        let source = "「priorityTier、supportedContexts、preferredContentTypes、routing.priorityRules、intentHints、contentHints」"
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: ActionRegistry.shared.definition(for: .translate),
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

        XCTAssertEqual(callCounter.snapshot(), 3)
        XCTAssertEqual(envelope.body, "优先级层级、支持的上下文、首选内容类型、路由优先级规则、意图提示、内容提示")
    }

    func testAskRuntimeCompilesSessionAndKnowledgeContextMessages() async throws {
        let bodyRecorder = RequestBodyRecorder()
        SkillRuntimeParityMockURLProtocol.requestHandler = { request, client, protocolInstance in
            XCTAssertEqual(request.url?.path, "/v1/responses")
            let body = try XCTUnwrap(request.httpBody ?? requestBody(from: request))
            bodyRecorder.record(body)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(
                protocolInstance,
                didLoad: Data(#"{"id":"resp_ask_1","output_text":"可以，当前资料里有一份产品路线文档。","output":[{"type":"message","content":[{"type":"output_text","text":"可以，当前资料里有一份产品路线文档。"}]}]}"#.utf8)
            )
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let settings = makeSettings()
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "secret")

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ReplyKnowledgeBaseStore(fileManager: .default, rootDirectoryURL: tempRoot)
        let fileURL = tempRoot.appendingPathComponent("roadmap.txt")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try "Q2 产品路线图，重点是 Ask 与知识库。".write(to: fileURL, atomically: true, encoding: .utf8)
        _ = await store.importFiles(urls: [fileURL])

        let session = makeSession()
        let runtime = makeAskRuntime(settings: settings, session: session, store: store)

        _ = try await runtime.streamAsk(
            request: AskSessionRequest(
                messages: [
                    .init(role: .user, content: "知识库里有什么？"),
                    .init(role: .assistant, content: "我可以帮你查。"),
                    .init(role: .user, content: "能结合当前资料回答吗？")
                ],
                metadata: .init(
                    sessionID: "session-1",
                    sourceBundleID: "com.apple.finder",
                    sourceAppName: "Finder",
                    frame: .zero
                ),
                uiLanguage: "zh",
                responseLanguage: "zh"
            ),
            onEvent: { _ in }
        )

        let payload = try XCTUnwrap(bodyRecorder.snapshot())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        _ = try XCTUnwrap(json["input"] as? [[String: Any]])
        let instructions = json["instructions"] as? String

        XCTAssertTrue(instructions?.contains("你是 NexHub 的 Ask 对话助手") == true)
        XCTAssertTrue(instructions?.contains("来自应用：Finder") == true)
        XCTAssertTrue(instructions?.contains("知识库工作区") == true)
        XCTAssertTrue(instructions?.contains("知识库资料清单") == true && instructions?.contains("roadmap") == true)
    }

    func testExplainFallsBackInsteadOfReturningEchoWhenRepairFails() async throws {
        let callCounter = CounterBox()
        SkillRuntimeParityMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let callIndex = callCounter.increment()
            if callIndex == 1 {
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(protocolInstance, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"The capture pipeline now performs staged reconciliation before dispatch.\"}}]}\n\n".utf8))
                client?.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
                client?.urlProtocolDidFinishLoading(protocolInstance)
                return
            }

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(protocolInstance, didLoad: Data(#"{"error":{"message":"repair failed"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let settings = makeSettings()
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "secret")
        let session = makeSession()
        let runtime = makeRuntime(settings: settings, session: session)

        let source = "The capture pipeline now performs staged reconciliation before dispatch."
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: ActionRegistry.shared.definition(for: .explain),
                context: SkillExecutionContext(
                    skillID: "explain",
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        XCTAssertEqual(callCounter.snapshot(), 2)
        XCTAssertNotEqual(envelope.body, source)
        XCTAssertTrue((envelope.body ?? "").contains("这段内容"))
    }

    func testTranslateUsesDynamicStreamingBudgetForLongSelection() async throws {
        let bodyRecorder = RequestBodyRecorder()
        let streamedTranslation = Array(
            repeating: "This paragraph should be fully translated in one continuous streaming response so we can verify the dynamic token budget remains large enough for long selections.",
            count: 5
        ).joined(separator: " ")
        SkillRuntimeParityMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = try XCTUnwrap(request.httpBody ?? requestBody(from: request))
            bodyRecorder.record(body)
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(protocolInstance, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(streamedTranslation)\"}}]}\n\n".utf8))
            client?.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let settings = makeSettings()
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "secret")
        let session = makeSession()
        let runtime = makeRuntime(settings: settings, session: session)

        let longSource = Array(repeating: "这是一个需要完整翻译的长段落，用来验证长文本会切成多个片段再翻译。", count: 30).joined()
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: ActionRegistry.shared.definition(for: .translate),
                context: SkillExecutionContext(
                    skillID: "translate",
                    text: longSource,
                    targetLanguage: "en",
                    responseLanguage: "en",
                    uiLanguage: "zh",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        let payload = try XCTUnwrap(bodyRecorder.snapshot())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertGreaterThan((json["max_tokens"] as? Int) ?? 0, 1400)
        XCTAssertNotEqual(envelope.body, longSource)
        XCTAssertTrue((envelope.body ?? "").contains("dynamic token budget"))
        XCTAssertGreaterThan((envelope.body ?? "").count, 120)
    }

    func testTranslateMixedLanguageUsesParityPromptAndChineseTarget() async throws {
        let bodyRecorder = RequestBodyRecorder()
        SkillRuntimeParityMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = try XCTUnwrap(request.httpBody ?? requestBody(from: request))
            bodyRecorder.record(body)
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(protocolInstance, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"这个 API 端点是做什么的\"}}]}\n\n".utf8))
            client?.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let settings = makeSettings()
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "secret")
        let session = makeSession()
        let runtime = makeRuntime(settings: settings, session: session)

        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: ActionRegistry.shared.definition(for: .translate),
                context: SkillExecutionContext(
                    skillID: "translate",
                    text: "这个 API endpoint 是做什么的",
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil,
                    translationMode: "translate_foreign_segments_to_local"
                )
            )
        )

        let payload = try XCTUnwrap(bodyRecorder.snapshot())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)
        let userPrompt = try XCTUnwrap(messages.last?["content"] as? String)

        XCTAssertEqual(envelope.body, "这个 API 端点是做什么的")
        XCTAssertTrue(systemPrompt.contains("# Translate Skill"))
        XCTAssertTrue(userPrompt.contains("Translation mode: translate_foreign_segments_to_local"))
        XCTAssertTrue(userPrompt.contains("Target language: zh"))
        XCTAssertTrue(userPrompt.contains("Response language: zh"))
        XCTAssertTrue(userPrompt.contains("Translate the selected text into Simplified Chinese"))
        XCTAssertTrue(userPrompt.contains("The selection is mixed-language."))
        XCTAssertTrue(userPrompt.contains("Foreign segments detected"))
        XCTAssertTrue(userPrompt.contains("API endpoint"))
        XCTAssertTrue(userPrompt.contains("Return only the translated text."))
    }

    func testTraceSearchesByEntityInsteadOfWholeLongParagraph() async throws {
        let requestedURLs = LockedArray<String>()
        let postCounter = CounterBox()
        SkillRuntimeParityMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let url = try XCTUnwrap(request.url)
            requestedURLs.append(url.absoluteString)

            if request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!
                client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data("""
                    <html><body>
                    <a class="result__a" href="https://blog.duolingo.com/">Duolingo Blog</a>
                    <div class="result__snippet">Official Duolingo updates and product notes.</div>
                    </body></html>
                    """.utf8)
                )
                client?.urlProtocolDidFinishLoading(protocolInstance)
                return
            }

            let postIndex = postCounter.increment()

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            if postIndex == 1 {
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data(#"{"choices":[{"message":{"content":"{\"intent_type\":\"experience_entry\",\"intent_summary\":\"优先定位 Duolingo 这一最值得打开的对象。\",\"action_goal\":\"优先返回可直接体验或最贴近体验路径的官方入口。\",\"primary_entity\":{\"name\":\"Duolingo\",\"entity_type\":\"product\",\"why_this\":\"这是原文里最明确的主产品对象。\",\"owner_hints\":[\"Duolingo\"]}}"}}]}"#.utf8)
                )
            } else {
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data(#"{"choices":[{"message":{"content":"Duolingo 是这里最核心的目标，最值得先打开的是它的官方博客入口，因为当前候选里它最接近一手产品更新来源。"}}]}"#.utf8)
                )
            }
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let settings = makeSettings()
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "secret")
        let session = makeSession()
        let runtime = makeRuntime(settings: settings, session: session)

        let source = "Duolingo 通过迭代 streak、push 时机和文案模板，把用户留存率显著拉高。现在我想溯源这段话最值得先打开的一手入口，而不是继续搜索整段分析结论。"
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: ActionRegistry.shared.definition(for: .trace),
                context: SkillExecutionContext(
                    skillID: "trace",
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        let urls = requestedURLs.snapshot()
        XCTAssertEqual(postCounter.snapshot(), 2)
        XCTAssertTrue(urls.contains(where: { $0.contains("html.duckduckgo.com") && $0.localizedCaseInsensitiveContains("Duolingo") }))
        XCTAssertFalse(urls.contains(where: { $0.localizedCaseInsensitiveContains("留存率显著拉高") }))
        XCTAssertTrue((envelope.body ?? "").contains("Duolingo"))
        XCTAssertFalse((envelope.body ?? "").contains("文案模板"))
    }

    func testTraceFallsBackToResolvedSourceTitleWhenEntityHeuristicBecomesNarrative() async throws {
        let postCounter = CounterBox()
        SkillRuntimeParityMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let url = try XCTUnwrap(request.url)

            if request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!
                client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data("""
                    <html><body>
                    <a class="result__a" href="https://example.com/docs">Example Docs</a>
                    <div class="result__snippet">Official documentation entry for the resolved feature.</div>
                    </body></html>
                    """.utf8)
                )
                client?.urlProtocolDidFinishLoading(protocolInstance)
                return
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)

            let postIndex = postCounter.increment()
            if postIndex == 1 {
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data(#"{"choices":[{"message":{"content":"not-json"}}]}"#.utf8)
                )
            } else {
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data(#"{"choices":[{"message":{"content":"这里详细描述了某个功能迁移后的实现细节、回退逻辑、UI 渲染方式，以及为什么当前最值得优先打开的入口还没有完全收敛下来。"}}]}"#.utf8)
                )
            }
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let settings = makeSettings()
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "secret")
        let session = makeSession()
        let runtime = makeRuntime(settings: settings, session: session)

        let source = """
        这里详细描述了某个功能迁移后的实现细节、回退逻辑、UI 渲染方式，以及为什么当前最值得优先打开的入口还没有完全收敛下来。请帮我溯源最该先打开的说明页。
        """
        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: ActionRegistry.shared.definition(for: .trace),
                context: SkillExecutionContext(
                    skillID: "trace",
                    text: source,
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        XCTAssertEqual(postCounter.snapshot(), 2)
        XCTAssertTrue((envelope.body ?? "").contains("Example Docs"))
        XCTAssertFalse((envelope.body ?? "").contains("这里详细描述了某个功能迁移后的实现细节"))
    }

    func testTraceStreamsDynamicStatusDetailsForResultPanel() async throws {
        let postCounter = CounterBox()
        SkillRuntimeParityMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let url = try XCTUnwrap(request.url)

            if request.httpMethod == "GET" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!
                client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data("""
                    <html><body>
                    <a class="result__a" href="https://www.duolingo.com/">Duolingo</a>
                    <div class="result__snippet">Official product homepage.</div>
                    <a class="result__a" href="https://blog.duolingo.com/">Duolingo Blog</a>
                    <div class="result__snippet">Official updates and growth posts.</div>
                    <a class="result__a" href="https://example.com/analysis">Third-party analysis</a>
                    <div class="result__snippet">Secondary commentary page.</div>
                    </body></html>
                    """.utf8)
                )
                client?.urlProtocolDidFinishLoading(protocolInstance)
                return
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)

            let postIndex = postCounter.increment()
            if postIndex == 1 {
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data(#"{"choices":[{"message":{"content":"{\"intent_type\":\"official_source\",\"intent_summary\":\"优先定位 Duolingo 相关的官方原始出处。\",\"action_goal\":\"优先返回官方公告、博客或最早发布来源。\",\"primary_entity\":{\"name\":\"Duolingo\",\"entity_type\":\"product\",\"why_this\":\"这是原文里最明确的主产品对象。\",\"owner_hints\":[\"Duolingo\"]}}"}}]}"#.utf8)
                )
            } else {
                client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data(#"{"choices":[{"message":{"content":"Duolingo Blog 是当前最值得先打开的一手入口，因为它最接近官方更新与增长策略原始表达。"}}]}"#.utf8)
                )
            }
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let settings = makeSettings()
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "secret")
        let session = makeSession()
        let runtime = SkillRuntimeService(
            llmClient: LLMClient(session: session),
            settings: settings,
            knowledgeBaseStore: ReplyKnowledgeBaseStore(
                fileManager: .default,
                rootDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            session: session,
            diagnosticsLogger: makeLogger(),
            aiConfigurationProvider: {
                try LLMRequestConfiguration.from(settings: settings)
            },
            traceSourceAugmentationProvider: { _, _, _ in [] }
        )

        let events = LockedArray<SkillRuntimeEvent>()
        _ = try await runtime.runStreamingEnvelope(
            request: SkillExecutionRequest(
                definition: ActionRegistry.shared.definition(for: .trace),
                context: SkillExecutionContext(
                    skillID: "trace",
                    text: "我想溯源 Duolingo 增长策略这段说法最该先打开的一手官方入口。",
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            ),
            onEvent: { event in
                if event.type == .status {
                    events.append(event)
                }
            }
        )

        let details = events.snapshot().compactMap(\.detail)
        XCTAssertTrue(details.contains(where: { $0.hasPrefix("主目标先锁定为 ") }))
        XCTAssertTrue(details.contains(where: { $0.hasPrefix("搜索 ") }))
        XCTAssertTrue(details.contains(where: { $0.hasPrefix("命中 ") }))
        XCTAssertTrue(details.contains(where: { $0.hasPrefix("候选已收束到：") }))
        XCTAssertTrue(details.contains(where: { $0.hasPrefix("已锁定 ") }))
        XCTAssertTrue(details.contains(where: { $0.contains("Duolingo") && $0.contains("打开结论") }))
    }

    func testReplyUsesSkillInstructionAndKnowledgeContext() async throws {
        let bodyRecorder = RequestBodyRecorder()
        SkillRuntimeParityMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let body = try XCTUnwrap(request.httpBody ?? requestBody(from: request))
            bodyRecorder.record(body)
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(protocolInstance, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"可以，今天下午三点我来确认排期。\"}}]}\n\n".utf8))
            client?.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let settings = makeSettings()
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "secret")

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ReplyKnowledgeBaseStore(fileManager: .default, rootDirectoryURL: tempRoot)
        let fileURL = tempRoot.appendingPathComponent("design-review-style.txt")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try "设计评审回复口径：先确认评审时间，再给出明确下一步。".write(to: fileURL, atomically: true, encoding: .utf8)
        _ = await store.importFiles(urls: [fileURL])

        let session = makeSession()
        let runtime = makeRuntime(settings: settings, session: session, store: store)

        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: ActionRegistry.shared.definition(for: .reply),
                context: SkillExecutionContext(
                    skillID: "reply",
                    text: "今天能不能确认一下设计评审时间？",
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        let payload = try XCTUnwrap(bodyRecorder.snapshot())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)
        let userPrompt = try XCTUnwrap(messages.last?["content"] as? String)

        XCTAssertEqual(envelope.body, "可以，今天下午三点我来确认排期。")
        XCTAssertTrue(systemPrompt.contains("# Reply Skill"))
        XCTAssertTrue(userPrompt.contains("Incoming text"))
        XCTAssertTrue(userPrompt.contains("今天能不能确认一下设计评审时间"))
    }

    func testScheduleUsesSkillInstructionWhenLocalParsingNeedsLLM() async throws {
        let bodyRecorder = RequestBodyRecorder()
        SkillRuntimeParityMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = try XCTUnwrap(request.httpBody ?? requestBody(from: request))
            bodyRecorder.record(body)
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(
                protocolInstance,
                didLoad: Data("""
                {"choices":[{"message":{"content":"<calendar_intent>{\\"title\\":\\"设计评审\\",\\"date\\":\\"2026-03-30\\",\\"all_day\\":true,\\"reminder_minutes\\":480}</calendar_intent>"}}]}
                """.utf8)
            )
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let settings = makeSettings()
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "secret")
        let session = makeSession()
        let runtime = makeRuntime(settings: settings, session: session)

        let envelope = try await runtime.runEnvelope(
            request: SkillExecutionRequest(
                definition: ActionRegistry.shared.definition(for: .schedule),
                context: SkillExecutionContext(
                    skillID: "schedule",
                    text: "提醒我下周找个时间做设计评审",
                    targetLanguage: "zh",
                    responseLanguage: "zh",
                    uiLanguage: "zh",
                    filePaths: [],
                    followupDepth: 0,
                    followupSourceSkillID: nil
                )
            )
        )

        let payload = try XCTUnwrap(bodyRecorder.snapshot())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let systemPrompt = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertTrue(systemPrompt.contains("# Schedule Skill"))
        XCTAssertEqual(envelope.metadata?["used_llm"], "true")
        XCTAssertTrue((envelope.cards ?? []).count >= 1)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SkillRuntimeParityMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeRuntime(
        settings: AppSettings,
        session: URLSession,
        store: ReplyKnowledgeBaseStore? = nil
    ) -> SkillRuntimeService {
        let resolvedStore = store ?? ReplyKnowledgeBaseStore(
            fileManager: .default,
            rootDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        return SkillRuntimeService(
            llmClient: LLMClient(session: session),
            settings: settings,
            knowledgeBaseStore: resolvedStore,
            session: session,
            diagnosticsLogger: makeLogger(),
            aiConfigurationProvider: {
                try LLMRequestConfiguration.from(settings: settings)
            }
        )
    }

    private func makeAskRuntime(
        settings: AppSettings,
        session: URLSession,
        store: ReplyKnowledgeBaseStore? = nil
    ) -> AskSkillRuntimeService {
        let resolvedStore = store ?? ReplyKnowledgeBaseStore(
            fileManager: .default,
            rootDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        return AskSkillRuntimeService(
            knowledgeBaseStore: resolvedStore,
            session: session,
            diagnosticsLogger: makeLogger(),
            askOperatorRuntime: AskOperatorRuntime(
                diagnosticsLogger: makeLogger(),
                sessionStore: AskOperatorSessionStore()
            ),
            aiConfigurationProvider: {
                try LLMRequestConfiguration.from(settings: settings)
            }
        )
    }

    private func makeSettings(file: StaticString = #filePath, line: UInt = #line) -> AppSettings {
        let suiteName = "NexHubTests.SkillRuntimeParity.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults", file: file, line: line)
            return .shared
        }
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults, secretsStore: SkillRuntimeParitySecretStore(), diagnosticsLogger: makeLogger())
    }

    private func makeLogger() -> DiagnosticsLogger {
        DiagnosticsLogger(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString), maxFileSizeBytes: 4096)
    }
}

private final class LockedArray<Element> {
    private var values: [Element] = []
    private let lock = NSLock()

    func append(_ value: Element) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Element] {
        lock.lock()
        let copy = values
        lock.unlock()
        return copy
    }
}

private func requestBody(from request: URLRequest) -> Data? {
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }

    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read <= 0 {
            break
        }
        data.append(buffer, count: read)
    }
    return data.isEmpty ? nil : data
}

private final class RequestBodyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var body: Data?

    func record(_ data: Data) {
        lock.lock()
        body = data
        lock.unlock()
    }

    func snapshot() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return body
    }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class SkillRuntimeParitySecretStore: SecretStoring {
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

private final class SkillRuntimeParityMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest, URLProtocolClient?, URLProtocol) throws -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            try handler(request, client, self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
