import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskSessionServiceTests: XCTestCase {
    func testMakeRequestBuildsAskStreamPayload() throws {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults, secretsStore: TestSecretStore(), diagnosticsLogger: makeLogger())
        try settings.updateAIConfiguration(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")

        let service = AskSessionService(
            session: .shared,
            settings: settings,
            managedConfigurationProvider: {
                try? LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "managed-device-token")
            },
            knowledgeBasePayloadProvider: {
                ["backend": "swift_local", "entry_count": 3]
            },
            knowledgeBaseManifestProvider: {
                [[
                    "id": "source-1",
                    "title": "Roadmap Notes",
                    "summary": "Q2 planning and priorities.",
                    "source_kind": "file",
                    "content_kind": "notes",
                    "language": "en",
                    "is_enabled": true
                ]]
            }
        )
        let requestModel = AskSessionRequest(
            messages: [
                AskMessage(role: .user, content: "你好"),
                AskMessage(role: .assistant, content: "你好，我在。")
            ],
            metadata: AskSessionMetadata(
                sessionID: "session-123",
                sourceBundleID: "com.apple.finder",
                sourceAppName: "Finder",
                frame: CGRect(x: 10, y: 20, width: 300, height: 180)
            ),
            uiLanguage: "zh",
            responseLanguage: "zh"
        )

        let request = try service.makeRequest(for: requestModel)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let sessionMetadata = try XCTUnwrap(payload["session_metadata"] as? [String: Any])
        let knowledgeBase = try XCTUnwrap(payload["knowledge_base"] as? [String: Any])
        let knowledgeBaseManifest = try XCTUnwrap(payload["knowledge_base_manifest"] as? [[String: Any]])

        XCTAssertEqual(request.url?.absoluteString, "nexhub://builtin-runtime/v1/ask/stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer managed-device-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-LLM-Provider"), "openai")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-LLM-Model"), "gpt-4.1-mini")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "你好")
        XCTAssertEqual(payload["ui_language"] as? String, "zh")
        XCTAssertEqual(payload["response_language"] as? String, "zh")
        XCTAssertEqual(sessionMetadata["session_id"] as? String, "session-123")
        XCTAssertEqual(sessionMetadata["source_bundle_id"] as? String, "com.apple.finder")
        XCTAssertEqual(sessionMetadata["source_app_name"] as? String, "Finder")
        XCTAssertEqual(knowledgeBase["backend"] as? String, "swift_local")
        XCTAssertEqual(knowledgeBase["enabled"] as? Bool, true)
        XCTAssertEqual(knowledgeBaseManifest.count, 1)
        XCTAssertEqual(knowledgeBaseManifest.first?["title"] as? String, "Roadmap Notes")
        XCTAssertNil(sessionMetadata["operator_candidate"])
    }

    func testMakeRequestKeepsOriginalAskMessagesWithoutHeuristicOperatorInjection() throws {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults, secretsStore: TestSecretStore(), diagnosticsLogger: makeLogger())

        let service = AskSessionService(
            session: .shared,
            settings: settings,
            managedConfigurationProvider: { nil },
            knowledgeBasePayloadProvider: { nil },
            knowledgeBaseManifestProvider: { [] }
        )
        let requestModel = AskSessionRequest(
            messages: [
                AskMessage(role: .user, content: "帮我打开 Chrome 搜索 Xcode 26 release notes 并把相关 pdf 文件移动到桌面新文件夹")
            ],
            metadata: AskSessionMetadata(
                sessionID: "session-operator-1",
                sourceBundleID: "com.apple.finder",
                sourceAppName: "Finder",
                frame: CGRect(x: 18, y: 24, width: 400, height: 260)
            ),
            uiLanguage: "zh",
            responseLanguage: "zh"
        )

        let request = try service.makeRequest(for: requestModel)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        let sessionMetadata = try XCTUnwrap(payload["session_metadata"] as? [String: Any])

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertNil(sessionMetadata["operator_candidate"])
        XCTAssertNil(sessionMetadata["operator_scope"])
        XCTAssertNil(sessionMetadata["operator_tool_families"])
    }

    private func makeDefaults(file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
        let suiteName = "NexHubTests.AskSession.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults", file: file, line: line)
            return .standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeLogger() -> DiagnosticsLogger {
        DiagnosticsLogger(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString), maxFileSizeBytes: 4096)
    }
}

private final class TestSecretStore: SecretStoring {
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
