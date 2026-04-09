import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskAgentRuntimeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AskAgentRuntimeMockURLProtocol.requestHandler = nil
        clearSharedApprovalRouter()
    }

    override func tearDown() {
        AskAgentRuntimeMockURLProtocol.requestHandler = nil
        clearSharedApprovalRouter()
        super.tearDown()
    }

    func testAgentStoresApprovalStateAndResumesWithStructuredActionID() async throws {
        let home = makeHomeDirectory()
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        try "alpha".write(to: desktop.appendingPathComponent("alpha.pdf"), atomically: true, encoding: .utf8)
        try "beta".write(to: desktop.appendingPathComponent("beta.pdf"), atomically: true, encoding: .utf8)

        let requestCounter = AgentCounterBox()
        var expectedActionID = ""
        AskAgentRuntimeMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let index = requestCounter.increment()
            let requestBody = try XCTUnwrap(request.httpBody ?? requestBody(from: request))
            let requestJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)

            let body: String
            switch index {
            case 1:
                let input = try XCTUnwrap(requestJSON["input"] as? [[String: Any]])
                let contents = input.compactMap { $0["content"] as? String }
                XCTAssertTrue(contents.contains(where: { $0.contains("把桌面上散落的文件收进新文件夹") }))
                body = #"""
                {"id":"resp_ask_1","output":[{"type":"function_call","call_id":"call_cleanup_1","name":"prepare_directory_cleanup","arguments":"{\"source_directory\":\"desktop\",\"destination_folder_name\":\"桌面归档\"}"}]}
                """#
            case 2:
                body = #"""
                {"id":"resp_ask_2","output_text":"我已实际移动 2 个文件到桌面归档。","output":[{"type":"message","content":[{"type":"output_text","text":"我已实际移动 2 个文件到桌面归档。"}]}]}
                """#
            default:
                XCTFail("Unexpected request index \(index)")
                body = #"""{"id":"resp_unexpected","output_text":"unexpected"}"""#
            }

            client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let operatorRuntime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: AgentWorkspaceControllerMock(),
            browserPageProvider: AgentBrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { home }
        )
        let sessionStore = AskAgentSessionStore()
        let runtime = AskAgentRuntime(
            agentLLMClient: AgentLLMClient(session: makeSession()),
            toolRegistry: AskToolRegistry(providers: [operatorRuntime]),
            toolExecutor: operatorRuntime,
            sessionStore: sessionStore,
            diagnosticsLogger: makeLogger()
        )
        let configuration = try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")

        let firstResponse = try await runtime.run(
            request: makeRequest(
                sessionID: "agent-approval",
                messages: [.init(role: .user, content: "把桌面上散落的文件收进新文件夹")]
            ),
            compiledMessages: [LLMChatMessage(role: .user, content: "把桌面上散落的文件收进新文件夹")],
            configuration: configuration,
            onEvent: { _ in }
        )

        XCTAssertEqual(firstResponse.metadata["agent_state"], "waiting_approval")
        expectedActionID = try XCTUnwrap(firstResponse.metadata["pending_approval_action_id"])
        XCTAssertFalse(expectedActionID.isEmpty)

        let storedStateValue = await sessionStore.sessionState(for: "agent-approval")
        let storedState: AskAgentSessionState = try XCTUnwrap(storedStateValue)
        XCTAssertEqual(storedState.approvalState?.actionID, expectedActionID)
        XCTAssertEqual(storedState.snapshotRefs.count, 1)
        XCTAssertEqual(storedState.selectionRefs.count, 1)
        XCTAssertEqual(storedState.stagedOperationRefs.count, 1)
        XCTAssertTrue(storedState.stepTimeline.contains(where: { $0.kind == .awaitingApproval }))

        let secondResponse = try await runtime.run(
            request: makeRequest(
                sessionID: "agent-approval",
                messages: [.init(role: .user, content: "确认")]
            ),
            compiledMessages: [LLMChatMessage(role: .user, content: "确认")],
            configuration: configuration,
            onEvent: { _ in }
        )

        XCTAssertEqual(secondResponse.metadata["agent_state"], "completed")
        XCTAssertEqual(secondResponse.metadata["pending_approval_action_id"], "")
        XCTAssertEqual(secondResponse.message, "我已实际移动 2 个文件到桌面归档。")
        XCTAssertEqual(requestCounter.snapshot(), 2)
    }

    func testApprovalConfirmationInjectsTaskScopeGrantBeforeNextWrite() async throws {
        let toolExecutor = PendingApprovalGrantingToolExecutor()
        let runtime = AskAgentRuntime(
            agentLLMClient: AgentLLMClient(session: makeSession()),
            toolRegistry: PendingApprovalGrantingToolRegistry(),
            toolExecutor: toolExecutor,
            sessionStore: AskAgentSessionStore(),
            diagnosticsLogger: makeLogger()
        )
        let configuration = try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")

        let requestCounter = AgentCounterBox()
        AskAgentRuntimeMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let index = requestCounter.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)

            let body: String
            switch index {
            case 1:
                body = #"""
                {"id":"resp_write_waiting","output":[{"type":"function_call","call_id":"call_write_waiting","name":"write_workspace_file","arguments":"{\"file_path\":\"index.html\",\"text\":\"<html>v1</html>\"}"}]}
                """#
            case 2:
                body = #"""
                {"id":"resp_write_after_approval","output":[{"type":"function_call","call_id":"call_write_after_approval","name":"write_workspace_file","arguments":"{\"file_path\":\"index.html\",\"text\":\"<html>v2</html>\"}"}]}
                """#
            case 3:
                body = #"""
                {"id":"resp_write_done","output_text":"已经写好 Playground 文件。","output":[{"type":"message","content":[{"type":"output_text","text":"已经写好 Playground 文件。"}]}]}
                """#
            default:
                XCTFail("Unexpected request index \(index)")
                body = #"""{"id":"resp_unexpected","output_text":"unexpected"}"""#
            }

            client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let firstResponse = try await runtime.run(
            request: makeRequest(
                sessionID: "agent-task-scope-approval",
                messages: [.init(role: .user, content: "创建 Playground 文件")]
            ),
            compiledMessages: [LLMChatMessage(role: .user, content: "创建 Playground 文件")],
            configuration: configuration,
            onEvent: { _ in }
        )

        XCTAssertEqual(firstResponse.metadata["agent_state"], "waiting_approval")

        let secondResponse = try await runtime.run(
            request: makeRequest(
                sessionID: "agent-task-scope-approval",
                messages: [.init(role: .user, content: "确认")]
            ),
            compiledMessages: [LLMChatMessage(role: .user, content: "确认")],
            configuration: configuration,
            onEvent: { _ in }
        )

        XCTAssertEqual(secondResponse.metadata["agent_state"], "completed")
        XCTAssertEqual(secondResponse.metadata["interactive_task_scope_granted"], "true")
        XCTAssertEqual(secondResponse.metadata["workspace_write_granted"], "true")
        XCTAssertEqual(toolExecutor.respondToApprovalInvocationCount, 1)
        XCTAssertEqual(toolExecutor.writeInvocationKernelMetadataAfterApproval["interactive_task_scope_granted"], "true")
        XCTAssertEqual(toolExecutor.writeInvocationKernelMetadataAfterApproval["workspace_write_granted"], "true")
        XCTAssertEqual(
            toolExecutor.writeInvocationKernelMetadataAfterApproval["workspace_root"],
            "/tmp/nexhub-playground"
        )
    }

    func testAgentFailureDoesNotLosePendingApprovalState() async throws {
        let home = makeHomeDirectory()
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        try "alpha".write(to: desktop.appendingPathComponent("alpha.pdf"), atomically: true, encoding: .utf8)

        AskAgentRuntimeMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = #"""
            {"id":"resp_fail_1","output":[{"type":"function_call","call_id":"call_cleanup_1","name":"prepare_directory_cleanup","arguments":"{\"source_directory\":\"desktop\",\"destination_folder_name\":\"桌面归档\"}"}]}
            """#
            client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let operatorRuntime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: AgentWorkspaceControllerMock(),
            browserPageProvider: AgentBrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { home }
        )
        let sessionStore = AskAgentSessionStore()
        let runtime = AskAgentRuntime(
            agentLLMClient: AgentLLMClient(session: makeSession()),
            toolRegistry: AskToolRegistry(providers: [operatorRuntime]),
            toolExecutor: operatorRuntime,
            sessionStore: sessionStore,
            diagnosticsLogger: makeLogger()
        )
        let configuration = try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")

        _ = try await runtime.run(
            request: makeRequest(
                sessionID: "agent-failure",
                messages: [.init(role: .user, content: "把桌面上散落的文件收进新文件夹")]
            ),
            compiledMessages: [LLMChatMessage(role: .user, content: "把桌面上散落的文件收进新文件夹")],
            configuration: configuration,
            onEvent: { _ in }
        )
        let pendingApproval = await sessionStore.pendingApproval(for: "agent-failure")
        let actionID = try XCTUnwrap(pendingApproval?.actionID)

        AskAgentRuntimeMockURLProtocol.requestHandler = { _, client, protocolInstance in
            client?.urlProtocol(protocolInstance, didFailWithError: URLError(.notConnectedToInternet))
        }

        do {
            _ = try await runtime.run(
                request: makeRequest(
                    sessionID: "agent-failure",
                    messages: [.init(role: .user, content: "继续")]
                ),
                compiledMessages: [LLMChatMessage(role: .user, content: "继续")],
                configuration: configuration,
                onEvent: { _ in }
            )
            XCTFail("Expected runtime.run to throw")
        } catch {
            let retainedApproval = await sessionStore.pendingApproval(for: "agent-failure")
            XCTAssertEqual(retainedApproval?.actionID, actionID)
        }
    }

    func testWorkspaceWriteToolAliasesStillReachTaskApproval() async throws {
        let home = makeHomeDirectory()
        AskAgentRuntimeMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = #"""
            {"id":"resp_alias_write_1","output":[{"type":"function_call","call_id":"call_alias_write_1","name":"write_workspace_file","arguments":"{\"file_path\":\"index.html\",\"text\":\"<html><body>hi</body></html>\",\"create_parents\":true}"}]}
            """#
            client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let operatorRuntime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: AgentWorkspaceControllerMock(),
            browserPageProvider: AgentBrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { home }
        )
        let sessionStore = AskAgentSessionStore()
        let runtime = AskAgentRuntime(
            agentLLMClient: AgentLLMClient(session: makeSession()),
            toolRegistry: AskToolRegistry(providers: [operatorRuntime]),
            toolExecutor: operatorRuntime,
            sessionStore: sessionStore,
            diagnosticsLogger: makeLogger()
        )
        let configuration = try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")

        let response = try await runtime.run(
            request: makeRequest(
                sessionID: "agent-write-aliases",
                messages: [.init(role: .user, content: "创建一个简单 HTML 文件")]
            ),
            compiledMessages: [LLMChatMessage(role: .user, content: "创建一个简单 HTML 文件")],
            configuration: configuration,
            onEvent: { _ in }
        )

        XCTAssertEqual(response.metadata["agent_state"], "waiting_approval")
        XCTAssertFalse((response.metadata["pending_approval_action_id"] ?? "").isEmpty)

        let storedState = await sessionStore.sessionState(for: "agent-write-aliases")
        XCTAssertEqual(storedState?.approvalState?.toolName, "workspace.write_file")
        XCTAssertFalse((storedState?.approvalState?.actionID ?? "").isEmpty)
    }

    func testToolRegistryDeduplicatesProviderToolsByName() {
        struct Provider: AskToolProviding {
            let tools: [AskToolDefinition]

            func availableTools(context: AskToolPoolContext) -> [AskToolDefinition] {
                tools
            }
        }

        let registry = AskToolRegistry(
            providers: [
                Provider(tools: [
                    AskToolDefinition(name: "snapshot_directory", description: "a", parameters: [:]),
                    AskToolDefinition(name: "inspect_paths", description: "b", parameters: [:])
                ]),
                Provider(tools: [
                    AskToolDefinition(name: "snapshot_directory", description: "c", parameters: [:]),
                    AskToolDefinition(name: "search_web", description: "d", parameters: [:])
                ])
            ]
        )

        let names = registry.availableTools(responseLanguage: "zh").map(\.name)
        XCTAssertEqual(names, ["snapshot_directory", "inspect_paths", "search_web"])
    }

    func testAgentResponseMetadataIncludesCurrentTurnTimeline() async throws {
        AskAgentRuntimeMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = #"""
            {"id":"resp_timeline_1","output_text":"直接回答。","output":[{"type":"message","content":[{"type":"output_text","text":"直接回答。"}]}]}
            """#
            client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let operatorRuntime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: AgentWorkspaceControllerMock(),
            browserPageProvider: AgentBrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { [self] in makeHomeDirectory() }
        )
        let runtime = AskAgentRuntime(
            agentLLMClient: AgentLLMClient(session: makeSession()),
            toolRegistry: AskToolRegistry(providers: [operatorRuntime]),
            toolExecutor: operatorRuntime,
            diagnosticsLogger: makeLogger()
        )
        let configuration = try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")

        let response = try await runtime.run(
            request: makeRequest(
                sessionID: "agent-timeline",
                messages: [.init(role: .user, content: "直接回答这个问题")]
            ),
            compiledMessages: [LLMChatMessage(role: .user, content: "直接回答这个问题")],
            configuration: configuration,
            onEvent: { _ in }
        )

        let encodedTimeline: String = try XCTUnwrap(response.metadata["agent_timeline"])
        let timeline = AskAgentTimelineMetadataCodec.decode(encodedTimeline)
        XCTAssertEqual(timeline.first?.kind, .planning)
        XCTAssertEqual(timeline.last?.kind, .finalAnswer)
    }

    func testAgentEmitsStructuredRuntimeStepEvents() async throws {
        AskAgentRuntimeMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = #"""
            {"id":"resp_steps_1","output_text":"我找到了结果。","output":[{"type":"message","content":[{"type":"output_text","text":"我找到了结果。"}]}]}
            """#
            client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let operatorRuntime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: AgentWorkspaceControllerMock(),
            browserPageProvider: AgentBrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { [self] in makeHomeDirectory() }
        )
        let runtime = AskAgentRuntime(
            agentLLMClient: AgentLLMClient(session: makeSession()),
            toolRegistry: AskToolRegistry(providers: [operatorRuntime]),
            toolExecutor: operatorRuntime,
            diagnosticsLogger: makeLogger()
        )
        let configuration = try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")

        let runtimeSteps = RuntimeStepCollector()
        _ = try await runtime.run(
            request: makeRequest(
                sessionID: "agent-runtime-steps",
                messages: [.init(role: .user, content: "直接告诉我结果")]
            ),
            compiledMessages: [LLMChatMessage(role: .user, content: "直接告诉我结果")],
            configuration: configuration,
            onEvent: { event in
                if case .runtimeStep(let step) = event {
                    runtimeSteps.append(step)
                }
            }
        )

        let collected = runtimeSteps.snapshot()
        XCTAssertTrue(collected.isEmpty)
    }

    func testSuccessfulToolStepKeepsOriginalTitleWhenMarkedCompleted() async throws {
        let requestCounter = AgentCounterBox()
        AskAgentRuntimeMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let index = requestCounter.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)

            let body: String
            switch index {
            case 1:
                body = #"""
                {"id":"resp_tool_title_1","output":[{"type":"function_call","call_id":"call_snapshot_1","name":"snapshot_directory","arguments":"{\"directory\":\"desktop\",\"extensions\":[\"png\"]}"}]}
                """#
            case 2:
                body = #"""
                {"id":"resp_tool_title_2","output_text":"我已经列出了桌面上的 PNG。","output":[{"type":"message","content":[{"type":"output_text","text":"我已经列出了桌面上的 PNG。"}]}]}
                """#
            default:
                XCTFail("Unexpected request index \(index)")
                body = #"""{"id":"resp_unexpected","output_text":"unexpected"}"""#
            }

            client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let home = makeHomeDirectory()
        try "demo".write(
            to: home.appendingPathComponent("Desktop/example.png"),
            atomically: true,
            encoding: .utf8
        )

        let operatorRuntime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: AgentWorkspaceControllerMock(),
            browserPageProvider: AgentBrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { home }
        )
        let runtime = AskAgentRuntime(
            agentLLMClient: AgentLLMClient(session: makeSession()),
            toolRegistry: AskToolRegistry(providers: [operatorRuntime]),
            toolExecutor: operatorRuntime,
            diagnosticsLogger: makeLogger()
        )
        let configuration = try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")

        let runtimeSteps = RuntimeStepCollector()
        _ = try await runtime.run(
            request: makeRequest(
                sessionID: "agent-tool-title",
                messages: [.init(role: .user, content: "列出桌面上的 PNG")]
            ),
            compiledMessages: [LLMChatMessage(role: .user, content: "列出桌面上的 PNG")],
            configuration: configuration,
            onEvent: { event in
                if case .runtimeStep(let step) = event {
                    runtimeSteps.append(step)
                }
            }
        )

        let collected = runtimeSteps.snapshot()
        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(collected.first?.state, .running)
        XCTAssertEqual(collected.last?.state, .completed)
        XCTAssertEqual(collected.first?.title, collected.last?.title)
        XCTAssertEqual(collected.first?.title, "正在扫描目录")
    }

    func testBlockedOpenURLDoesNotSurfaceFailureRuntimeStep() async throws {
        let toolExecutor = SuppressedRuntimeStepToolExecutor()
        let runtime = AskAgentRuntime(
            agentLLMClient: AgentLLMClient(session: makeSession()),
            toolRegistry: SuppressedRuntimeStepToolRegistry(toolNames: ["open_url"]),
            toolExecutor: toolExecutor,
            sessionStore: AskAgentSessionStore(),
            diagnosticsLogger: makeLogger()
        )
        let configuration = try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")

        let requestCounter = AgentCounterBox()
        AskAgentRuntimeMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let index = requestCounter.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)

            let body: String
            switch index {
            case 1:
                body = #"""
                {"id":"resp_block_open_url","output":[{"type":"function_call","call_id":"call_open_url","name":"open_url","arguments":"{\"url\":\"https://example.com\"}"}]}
                """#
            case 2:
                body = #"""
                {"id":"resp_done_open_url","output_text":"我没有打开页面，但我已经继续给你整理结果。","output":[{"type":"message","content":[{"type":"output_text","text":"我没有打开页面，但我已经继续给你整理结果。"}]}]}
                """#
            default:
                XCTFail("Unexpected request index \(index)")
                body = #"""{"id":"resp_unexpected","output_text":"unexpected"}"""#
            }

            client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let runtimeSteps = RuntimeStepCollector()
        let response = try await runtime.run(
            request: makeRequest(
                sessionID: "agent-suppress-open-url",
                messages: [.init(role: .user, content: "帮我看看这个链接说了什么")]
            ),
            compiledMessages: [LLMChatMessage(role: .user, content: "帮我看看这个链接说了什么")],
            configuration: configuration,
            onEvent: { event in
                if case .runtimeStep(let step) = event {
                    runtimeSteps.append(step)
                }
            }
        )

        XCTAssertEqual(response.message, "我没有打开页面，但我已经继续给你整理结果。")
        XCTAssertEqual(toolExecutor.invocations, ["open_url"])
        XCTAssertTrue(runtimeSteps.snapshot().isEmpty)
    }

    func testBlockedReadCurrentPageDoesNotSurfaceFailureRuntimeStep() async throws {
        let toolExecutor = SuppressedRuntimeStepToolExecutor()
        let runtime = AskAgentRuntime(
            agentLLMClient: AgentLLMClient(session: makeSession()),
            toolRegistry: SuppressedRuntimeStepToolRegistry(toolNames: ["read_current_page"]),
            toolExecutor: toolExecutor,
            sessionStore: AskAgentSessionStore(),
            diagnosticsLogger: makeLogger()
        )
        let configuration = try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")

        let requestCounter = AgentCounterBox()
        AskAgentRuntimeMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let index = requestCounter.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)

            let body: String
            switch index {
            case 1:
                body = #"""
                {"id":"resp_block_read_page","output":[{"type":"function_call","call_id":"call_read_page","name":"read_current_page","arguments":"{\"query\":\"pricing\"}"}]}
                """#
            case 2:
                body = #"""
                {"id":"resp_done_read_page","output_text":"我没有读取当前页，但已经继续基于现有上下文回答。","output":[{"type":"message","content":[{"type":"output_text","text":"我没有读取当前页，但已经继续基于现有上下文回答。"}]}]}
                """#
            default:
                XCTFail("Unexpected request index \(index)")
                body = #"""{"id":"resp_unexpected","output_text":"unexpected"}"""#
            }

            client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let runtimeSteps = RuntimeStepCollector()
        let response = try await runtime.run(
            request: makeRequest(
                sessionID: "agent-suppress-read-page",
                messages: [.init(role: .user, content: "OpenAI Responses API 和 Chat Completions 有什么区别")],
                sourceBundleID: "com.google.Chrome",
                sourceAppName: "Google Chrome"
            ),
            compiledMessages: [LLMChatMessage(role: .user, content: "OpenAI Responses API 和 Chat Completions 有什么区别")],
            configuration: configuration,
            onEvent: { event in
                if case .runtimeStep(let step) = event {
                    runtimeSteps.append(step)
                }
            }
        )

        XCTAssertEqual(response.message, "我没有读取当前页，但已经继续基于现有上下文回答。")
        XCTAssertEqual(toolExecutor.invocations, ["read_current_page"])
        XCTAssertTrue(runtimeSteps.snapshot().isEmpty)
    }

    func testStateChangingToolExecutionInvalidatesCachedOpenPathFailures() async throws {
        let toolExecutor = OpenPathCacheRegressionToolExecutor()
        let runtime = AskAgentRuntime(
            agentLLMClient: AgentLLMClient(session: makeSession()),
            toolRegistry: OpenPathCacheRegressionToolRegistry(),
            toolExecutor: toolExecutor,
            sessionStore: AskAgentSessionStore(),
            diagnosticsLogger: makeLogger()
        )
        let configuration = try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")

        let requestCounter = AgentCounterBox()
        AskAgentRuntimeMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let index = requestCounter.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)

            let body: String
            switch index {
            case 1:
                body = #"""
                {"id":"resp_open_1","output":[{"type":"function_call","call_id":"call_open_1","name":"open_path","arguments":"{\"path\":\"index.html\"}"}]}
                """#
            case 2:
                body = #"""
                {"id":"resp_write_1","output":[{"type":"function_call","call_id":"call_write_1","name":"write_workspace_file","arguments":"{\"file_path\":\"index.html\",\"text\":\"<html><body>ok</body></html>\"}"}]}
                """#
            case 3:
                body = #"""
                {"id":"resp_open_2","output":[{"type":"function_call","call_id":"call_open_2","name":"open_path","arguments":"{\"path\":\"index.html\"}"}]}
                """#
            case 4:
                body = #"""
                {"id":"resp_done","output_text":"已经修好并成功打开 index.html。","output":[{"type":"message","content":[{"type":"output_text","text":"已经修好并成功打开 index.html。"}]}]}
                """#
            default:
                XCTFail("Unexpected request index \(index)")
                body = #"""{"id":"resp_unexpected","output_text":"unexpected"}"""#
            }

            client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let response = try await runtime.run(
            request: makeRequest(
                sessionID: "agent-open-path-cache",
                messages: [.init(role: .user, content: "创建一个简单页面并打开")]
            ),
            compiledMessages: [LLMChatMessage(role: .user, content: "创建一个简单页面并打开")],
            configuration: configuration,
            onEvent: { _ in }
        )

        XCTAssertEqual(response.message, "已经修好并成功打开 index.html。")
        XCTAssertEqual(toolExecutor.writeWorkspaceFileInvocationCount, 1)
        XCTAssertEqual(toolExecutor.openPathInvocationCount, 2)
        XCTAssertEqual(requestCounter.snapshot(), 4)
    }

    private func makeRequest(
        sessionID: String,
        messages: [AskMessage],
        sourceBundleID: String = "com.apple.finder",
        sourceAppName: String = "Finder"
    ) -> AskSessionRequest {
        AskSessionRequest(
            messages: messages,
            metadata: AskSessionMetadata(
                sessionID: sessionID,
                sourceBundleID: sourceBundleID,
                sourceAppName: sourceAppName,
                frame: .zero
            ),
            uiLanguage: "zh",
            responseLanguage: "zh"
        )
    }

    private func makeHomeDirectory(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop", isDirectory: true), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Downloads", isDirectory: true), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents", isDirectory: true), withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to prepare home directory: \(error)", file: file, line: line)
        }
        return home
    }

    private func makeLogger() -> DiagnosticsLogger {
        DiagnosticsLogger(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),
            maxFileSizeBytes: 4096
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AskAgentRuntimeMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func clearSharedApprovalRouter(file: StaticString = #filePath, line: UInt = #line) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await AskInMemoryApprovalRouter.shared.clearAll()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 1) != .success {
            XCTFail("Timed out clearing shared approval router", file: file, line: line)
        }
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

private final class AgentCounterBox {
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

private final class RuntimeStepCollector {
    private let lock = NSLock()
    private var steps: [AskRuntimeStepEvent] = []

    func append(_ step: AskRuntimeStepEvent) {
        lock.lock()
        defer { lock.unlock() }
        steps.append(step)
    }

    func snapshot() -> [AskRuntimeStepEvent] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }
}

private final class AskAgentRuntimeMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest, URLProtocolClient?, URLProtocol) throws -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("AskAgentRuntimeMockURLProtocol.requestHandler not set")
        }

        do {
            try handler(request, client, self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class AgentWorkspaceControllerMock: AskOperatorWorkspaceControlling {
    func openURL(_ url: URL, preferredBundleID: String?) async -> Bool { true }
    func openFile(_ url: URL) async -> Bool { true }
    func revealInFinder(_ url: URL) async {}
}

private struct AgentBrowserPageProviderMock: AskOperatorBrowserPageProviding {
    let result: Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure>

    func currentPage(fromBundleID bundleID: String?) async -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure> {
        result
    }
}

private struct PendingApprovalGrantingToolRegistry: AskToolProviding {
    func availableTools(context: AskToolPoolContext) -> [AskToolDefinition] {
        [
            AskToolDefinition(name: "write_workspace_file", description: "write", parameters: [:]),
            AskToolDefinition(name: "respond_to_approval", description: "approval", parameters: [:])
        ]
    }
}

private final class PendingApprovalGrantingToolExecutor: AskToolExecuting {
    private(set) var respondToApprovalInvocationCount = 0
    private(set) var writeInvocationCount = 0
    private(set) var writeInvocationKernelMetadataAfterApproval: [String: String] = [:]
    private let approvalActionID = "approval-task-scope"

    func executeTool(
        named name: String,
        argumentsJSON: String,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        switch name {
        case "write_workspace_file":
            writeInvocationCount += 1
            if writeInvocationCount == 1 {
                return AskToolExecutionResult(
                    ok: false,
                    summary: "需要确认后才能写入 Playground。",
                    data: [:],
                    cards: [],
                    approvalRequest: AskApprovalRequestRecord(
                        actionID: approvalActionID,
                        toolName: "workspace.write_file",
                        targetSummary: "index.html",
                        affectedCount: 1,
                        conflictSummary: AskApprovalConflictSummary(
                            collisionCount: 0,
                            skippedCount: 0,
                            sampleDestinationPaths: [],
                            summary: "No conflicts."
                        ),
                        reversibilityHint: AskReversibilityHint(
                            kind: "workspace",
                            summary: "This write stays inside the Playground workspace."
                        ),
                        expiry: nil,
                        operationID: "playground-operation",
                        summary: "等待 Playground 写入确认",
                        message: "这次写入会创建 Playground 文件，确认后继续。",
                        cards: []
                    ),
                    error: nil
                )
            }

            writeInvocationKernelMetadataAfterApproval = request.metadata.kernelMetadata
            return AskToolExecutionResult(
                ok: true,
                summary: "写入成功。",
                data: [
                    "workspace_root": "/tmp/nexhub-playground",
                    "active_task_workspace_root": "/tmp/nexhub-playground"
                ],
                cards: [],
                approvalRequest: nil,
                error: nil
            )

        case "respond_to_approval":
            respondToApprovalInvocationCount += 1
            guard let data = argumentsJSON.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return AskToolExecutionResult(
                    ok: false,
                    summary: "参数解析失败。",
                    data: [:],
                    cards: [],
                    approvalRequest: nil,
                    error: "参数解析失败。"
                )
            }
            XCTAssertEqual(payload["action_id"], approvalActionID)
            XCTAssertEqual(payload["decision"], "approve")
            return AskToolExecutionResult(
                ok: true,
                summary: "审批已确认。",
                data: [
                    "action_id": approvalActionID,
                    "decision": "approve",
                    "interactive_task_scope_granted": "true",
                    "interactive_task_scope_root": "/tmp/nexhub-playground",
                    "workspace_root": "/tmp/nexhub-playground",
                    "active_task_workspace_root": "/tmp/nexhub-playground",
                    "workspace_write_granted": "true",
                    "workspace_patch_granted": "true",
                    "workspace_shell_granted": "true"
                ],
                cards: [],
                approvalRequest: nil,
                error: nil
            )

        default:
            return AskToolExecutionResult(
                ok: false,
                summary: "unknown tool",
                data: [:],
                cards: [],
                approvalRequest: nil,
                error: "unknown tool"
            )
        }
    }
}

private struct OpenPathCacheRegressionToolRegistry: AskToolProviding {
    func availableTools(context: AskToolPoolContext) -> [AskToolDefinition] {
        [
            AskToolDefinition(name: "open_path", description: "open a local path", parameters: [:]),
            AskToolDefinition(name: "write_workspace_file", description: "write a workspace file", parameters: [:])
        ]
    }
}

private final class OpenPathCacheRegressionToolExecutor: AskToolExecuting {
    private(set) var openPathInvocationCount = 0
    private(set) var writeWorkspaceFileInvocationCount = 0
    private var indexWritten = false

    func executeTool(
        named name: String,
        argumentsJSON: String,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        _ = argumentsJSON
        _ = request
        _ = onEvent

        switch name {
        case "open_path":
            openPathInvocationCount += 1
            if indexWritten {
                return AskToolExecutionResult(
                    ok: true,
                    summary: "index.html 已成功打开。",
                    data: ["opened_path": "index.html"],
                    cards: [],
                    approvalRequest: nil,
                    error: nil
                )
            }
            return AskToolExecutionResult(
                ok: false,
                summary: "open_path 校验失败：入口文件尚未写好。",
                data: [:],
                cards: [],
                approvalRequest: nil,
                error: "入口文件尚未写好。"
            )

        case "write_workspace_file":
            writeWorkspaceFileInvocationCount += 1
            indexWritten = true
            return AskToolExecutionResult(
                ok: true,
                summary: "index.html 写入成功。",
                data: ["file_path": "index.html"],
                cards: [],
                approvalRequest: nil,
                error: nil
            )

        default:
            return AskToolExecutionResult(
                ok: false,
                summary: "unknown tool",
                data: [:],
                cards: [],
                approvalRequest: nil,
                error: "unknown tool"
            )
        }
    }
}

private struct SuppressedRuntimeStepToolRegistry: AskToolProviding {
    let toolNames: [String]

    func availableTools(context: AskToolPoolContext) -> [AskToolDefinition] {
        toolNames.map { AskToolDefinition(name: $0, description: $0, parameters: [:]) }
    }
}

private final class SuppressedRuntimeStepToolExecutor: AskToolExecuting {
    private(set) var invocations: [String] = []

    func executeTool(
        named name: String,
        argumentsJSON: String,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        _ = argumentsJSON
        _ = request
        _ = onEvent
        invocations.append(name)

        switch name {
        case "open_url":
            return AskToolExecutionResult(
                ok: false,
                summary: "我没有替你打开浏览器，因为你这句话里没有明确要求可见的网页打开动作。",
                data: [
                    "visible_browser_action_blocked": true,
                    "tool_name": name
                ],
                cards: [],
                approvalRequest: nil,
                error: nil
            )
        case "read_current_page":
            return AskToolExecutionResult(
                ok: false,
                summary: "我没有读取当前网页，因为用户这句话没有明确提到当前页面或标签页。",
                data: [
                    "current_page_read_blocked": true
                ],
                cards: [],
                approvalRequest: nil,
                error: nil
            )
        default:
            return AskToolExecutionResult(
                ok: false,
                summary: "unknown tool",
                data: [:],
                cards: [],
                approvalRequest: nil,
                error: "unknown tool"
            )
        }
    }
}
