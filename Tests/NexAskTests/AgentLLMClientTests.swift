import XCTest
@testable import NexShared
@testable import NexAskCore

final class AgentLLMClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AgentLLMClientMockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        AgentLLMClientMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testDeepSeekChatCompletionsStreamingEmitsTextDeltas() async throws {
        AgentLLMClientMockURLProtocol.requestHandler = { request, client, protocolInstance in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")

            let requestBody = try XCTUnwrap(request.httpBody ?? requestBody(from: request))
            let requestJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            XCTAssertEqual(requestJSON["stream"] as? Bool, true)
            XCTAssertEqual(requestJSON["max_tokens"] as? Int, 3200)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(protocolInstance, didLoad: try sseData([
                "id": "chatcmpl_text_1",
                "choices": [
                    [
                        "delta": ["content": "你好"],
                        "finish_reason": NSNull()
                    ]
                ]
            ]))
            client?.urlProtocol(protocolInstance, didLoad: try sseData([
                "id": "chatcmpl_text_1",
                "choices": [
                    [
                        "delta": ["content": "世界"],
                        "finish_reason": "stop"
                    ]
                ]
            ]))
            client?.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let client = AgentLLMClient(
            session: makeSession(),
            diagnosticsLogger: makeLogger()
        )
        let configuration = LLMRequestConfiguration(
            provider: "deepseek",
            model: "deepseek-chat",
            apiKey: "test-key",
            baseURL: "https://api.nefish.net"
        )

        let deltaCollector = StreamDeltaCollector()
        let result = try await client.respond(
            configuration: configuration,
            messages: [.user("给我一个示例")],
            tools: [],
            onOutputTextDelta: { delta in
                deltaCollector.append(delta)
            }
        )

        switch result.response {
        case .final(let message):
            XCTAssertEqual(message, "你好世界")
        case .toolCalls:
            XCTFail("Expected final text response")
        }
        XCTAssertEqual(deltaCollector.snapshot(), ["你好", "世界"])
    }

    func testDeepSeekChatCompletionsStreamingAccumulatesToolCalls() async throws {
        AgentLLMClientMockURLProtocol.requestHandler = { request, client, protocolInstance in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")

            let requestBody = try XCTUnwrap(request.httpBody ?? requestBody(from: request))
            let requestJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            XCTAssertEqual(requestJSON["stream"] as? Bool, true)
            XCTAssertEqual(requestJSON["max_tokens"] as? Int, 3200)

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(protocolInstance, didLoad: try sseData([
                "id": "chatcmpl_tool_1",
                "choices": [
                    [
                        "delta": [
                            "content": "我先检查一下。",
                            "tool_calls": [
                                [
                                    "index": 0,
                                    "id": "call_1",
                                    "type": "function",
                                    "function": [
                                        "name": "snapshot_directory",
                                        "arguments": #"{"source_directory":"des"#
                                    ]
                                ]
                            ]
                        ],
                        "finish_reason": NSNull()
                    ]
                ]
            ]))
            client?.urlProtocol(protocolInstance, didLoad: try sseData([
                "id": "chatcmpl_tool_1",
                "choices": [
                    [
                        "delta": [
                            "tool_calls": [
                                [
                                    "index": 0,
                                    "function": [
                                        "arguments": #"ktop"}"#
                                    ]
                                ]
                            ]
                        ],
                        "finish_reason": "tool_calls"
                    ]
                ]
            ]))
            client?.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let client = AgentLLMClient(
            session: makeSession(),
            diagnosticsLogger: makeLogger()
        )
        let configuration = LLMRequestConfiguration(
            provider: "deepseek",
            model: "deepseek-chat",
            apiKey: "test-key",
            baseURL: "https://api.nefish.net"
        )
        let deltaCollector = StreamDeltaCollector()

        let result = try await client.respond(
            configuration: configuration,
            messages: [.user("看看桌面内容")],
            tools: [
                AskToolDefinition(
                    name: "snapshot_directory",
                    description: "snapshot",
                    parameters: [:]
                )
            ],
            onOutputTextDelta: { delta in
                deltaCollector.append(delta)
            }
        )

        switch result.response {
        case .final:
            XCTFail("Expected tool calls")
        case .toolCalls(let toolCalls, let assistantText):
            XCTAssertEqual(assistantText, "我先检查一下。")
            XCTAssertEqual(toolCalls.count, 1)
            XCTAssertEqual(toolCalls.first?.id, "call_1")
            XCTAssertEqual(toolCalls.first?.name, "snapshot_directory")
            XCTAssertEqual(toolCalls.first?.argumentsJSON, #"{"source_directory":"desktop"}"#)
        }
        XCTAssertEqual(deltaCollector.snapshot(), ["我先检查一下。"])
    }

    func testDeepSeekChatCompletionsStreamingEmitsToolCallArgumentUpdates() async throws {
        AgentLLMClientMockURLProtocol.requestHandler = { request, client, protocolInstance in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(protocolInstance, didLoad: try sseData([
                "id": "chatcmpl_write_1",
                "choices": [
                    [
                        "delta": [
                            "tool_calls": [
                                [
                                    "index": 0,
                                    "id": "call_write_1",
                                    "type": "function",
                                    "function": [
                                        "name": "write_workspace_file",
                                        "arguments": #"{"path":"src/index.html","content":"<div>"#
                                    ]
                                ]
                            ]
                        ],
                        "finish_reason": NSNull()
                    ]
                ]
            ]))
            client?.urlProtocol(protocolInstance, didLoad: try sseData([
                "id": "chatcmpl_write_1",
                "choices": [
                    [
                        "delta": [
                            "tool_calls": [
                                [
                                    "index": 0,
                                    "function": [
                                        "arguments": #"Hello</div>"}"#
                                    ]
                                ]
                            ]
                        ],
                        "finish_reason": "tool_calls"
                    ]
                ]
            ]))
            client?.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let client = AgentLLMClient(
            session: makeSession(),
            diagnosticsLogger: makeLogger()
        )
        let configuration = LLMRequestConfiguration(
            provider: "deepseek",
            model: "deepseek-chat",
            apiKey: "test-key",
            baseURL: "https://api.nefish.net"
        )
        let toolCallCollector = StreamToolCallCollector()

        _ = try await client.respond(
            configuration: configuration,
            messages: [.user("写一个 html 文件")],
            tools: [
                AskToolDefinition(
                    name: "write_workspace_file",
                    description: "write",
                    parameters: [:]
                )
            ],
            onOutputTextDelta: nil,
            onToolCallDelta: { toolCall in
                toolCallCollector.append(toolCall)
            }
        )

        let snapshot = toolCallCollector.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.first?.name, "write_workspace_file")
        XCTAssertEqual(snapshot.first?.argumentsJSON, #"{"path":"src/index.html","content":"<div>"#)
        XCTAssertEqual(snapshot.last?.argumentsJSON, #"{"path":"src/index.html","content":"<div>Hello</div>"}"#)
    }

    func testDeepSeekChatCompletionsLengthFallbackRetriesWithHigherTokenBudget() async throws {
        var requestCount = 0
        AgentLLMClientMockURLProtocol.requestHandler = { request, client, protocolInstance in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")

            let requestBody = try XCTUnwrap(request.httpBody ?? requestBody(from: request))
            let requestJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])

            if requestCount == 1 {
                XCTAssertEqual(requestJSON["stream"] as? Bool, true)
                XCTAssertEqual(requestJSON["max_tokens"] as? Int, 3200)

                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(protocolInstance, didLoad: try sseData([
                    "id": "chatcmpl_tool_length",
                    "choices": [
                        [
                            "delta": [
                                "tool_calls": [
                                    [
                                        "index": 0,
                                        "id": "call_shell_1",
                                        "type": "function",
                                        "function": [
                                            "name": "run_shell_command",
                                            "arguments": #"{"command":"cat <<'EOF' > index.html\n<ht"#
                                        ]
                                    ]
                                ]
                            ],
                            "finish_reason": NSNull()
                        ]
                    ]
                ]))
                client?.urlProtocol(protocolInstance, didLoad: try sseData([
                    "id": "chatcmpl_tool_length",
                    "choices": [
                        [
                            "delta": [:],
                            "finish_reason": "length"
                        ]
                    ]
                ]))
                client?.urlProtocol(protocolInstance, didLoad: Data("data: [DONE]\n\n".utf8))
                client?.urlProtocolDidFinishLoading(protocolInstance)
                return
            }

            XCTAssertEqual(requestCount, 2)
            XCTAssertEqual(requestJSON["stream"] as? Bool, false)
            XCTAssertEqual(requestJSON["max_tokens"] as? Int, 8000)

            let payload: [String: Any] = [
                "id": "chatcmpl_retry_ok",
                "choices": [[
                    "message": [
                        "role": "assistant",
                        "tool_calls": [[
                            "id": "call_shell_1",
                            "type": "function",
                            "function": [
                                "name": "run_shell_command",
                                "arguments": #"{"command":"printf 'ok\n'"}"#
                            ]
                        ]]
                    ],
                    "finish_reason": "tool_calls"
                ]]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(protocolInstance, didLoad: data)
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let client = AgentLLMClient(
            session: makeSession(),
            diagnosticsLogger: makeLogger()
        )
        let configuration = LLMRequestConfiguration(
            provider: "deepseek",
            model: "deepseek-chat",
            apiKey: "test-key",
            baseURL: "https://api.nefish.net"
        )
        let toolCallCollector = StreamToolCallCollector()

        let result = try await client.respond(
            configuration: configuration,
            messages: [.user("写一个最小化网页")],
            tools: [
                AskToolDefinition(
                    name: "run_shell_command",
                    description: "shell",
                    parameters: [:]
                )
            ],
            onOutputTextDelta: nil,
            onToolCallDelta: { toolCall in
                toolCallCollector.append(toolCall)
            }
        )

        XCTAssertEqual(requestCount, 2)
        let streamSnapshot = toolCallCollector.snapshot()
        XCTAssertEqual(streamSnapshot.count, 1)
        XCTAssertEqual(streamSnapshot.first?.argumentsJSON, #"{"command":"cat <<'EOF' > index.html\n<ht"#)

        switch result.response {
        case .final:
            XCTFail("Expected tool calls after the retry fallback")
        case .toolCalls(let toolCalls, let assistantText):
            XCTAssertNil(assistantText)
            XCTAssertEqual(toolCalls.count, 1)
            XCTAssertEqual(toolCalls.first?.name, "run_shell_command")
            XCTAssertEqual(toolCalls.first?.argumentsJSON, #"{"command":"printf 'ok\n'"}"#)
        }
    }

    func testChatCompletionsRequestUsesConciseResponseProfileBudget() async throws {
        AgentLLMClientMockURLProtocol.requestHandler = { request, client, protocolInstance in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            let requestBody = try XCTUnwrap(request.httpBody ?? requestBody(from: request))
            let requestJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            XCTAssertEqual(requestJSON["max_tokens"] as? Int, 900)

            let payload: [String: Any] = [
                "id": "chatcmpl_budget",
                "choices": [[
                    "message": ["role": "assistant", "content": "简短回答"],
                    "finish_reason": "stop"
                ]]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(protocolInstance, didLoad: data)
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let client = AgentLLMClient(
            session: makeSession(),
            diagnosticsLogger: makeLogger()
        )
        let configuration = LLMRequestConfiguration(
            provider: "deepseek",
            model: "deepseek-chat",
            apiKey: "test-key",
            baseURL: "https://api.nefish.net"
        )

        let result = try await client.respond(
            configuration: configuration,
            messages: [.user("短答")],
            tools: [],
            responseProfile: .concise,
            onOutputTextDelta: nil
        )

        switch result.response {
        case .final(let message):
            XCTAssertEqual(message, "简短回答")
        case .toolCalls:
            XCTFail("Expected final response")
        }
    }

    private func makeLogger() -> DiagnosticsLogger {
        DiagnosticsLogger(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),
            maxFileSizeBytes: 4096
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentLLMClientMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private func sseData(_ payload: [String: Any]) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: payload)
    guard let json = String(data: data, encoding: .utf8) else {
        throw NSError(domain: "AgentLLMClientTests", code: 1)
    }
    return Data("data: \(json)\n\n".utf8)
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

private final class StreamDeltaCollector {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class StreamToolCallCollector {
    private let lock = NSLock()
    private var values: [AskToolCall] = []

    func append(_ value: AskToolCall) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func snapshot() -> [AskToolCall] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class AgentLLMClientMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest, URLProtocolClient?, URLProtocol) throws -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("AgentLLMClientMockURLProtocol.requestHandler not set")
        }

        do {
            try handler(request, client, self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
