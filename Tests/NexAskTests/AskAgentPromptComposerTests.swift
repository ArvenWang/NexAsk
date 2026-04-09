import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskAgentPromptComposerTests: XCTestCase {
    func testMCPPromptAddendumIncludesConnectionStateSummary() throws {
        let root = makeRootDirectory()
        let connectionStore = AskMCPConnectionStore(
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: root
        )
        _ = connectionStore.replaceConnections([
            AskMCPConnectionRecord(
                serverName: "docs",
                status: .connected,
                readableResourceCount: 3
            ),
            AskMCPConnectionRecord(
                serverName: "repo",
                status: .failed,
                readableResourceCount: 0,
                lastError: "timeout"
            )
        ])
        let provider = AskMCPPromptAddendumProvider(connectionStore: connectionStore)

        let sections = provider.appendedSystemPromptSections(
            for: AskAgentPromptContext(
                responseLanguage: "zh",
                sessionState: .make(sessionID: "prompt", maxToolCalls: 8),
                responseProfile: .detailed
            )
        )

        XCTAssertEqual(sections.count, 2)
        XCTAssertTrue(sections[0].contains("docs"))
        XCTAssertTrue(sections[0].contains("已连接"))
        XCTAssertTrue(sections[0].contains("repo"))
        XCTAssertTrue(sections[0].contains("失败"))
        XCTAssertTrue(sections[0].contains("timeout"))
        XCTAssertTrue(sections[1].contains("list_mcp_resources"))
    }

    func testMCPPromptAddendumIsEmptyWhenNoConnectionsExist() throws {
        let root = makeRootDirectory()
        let provider = AskMCPPromptAddendumProvider(
            connectionStore: AskMCPConnectionStore(
                notificationCenter: NotificationCenter(),
                rootDirectoryURL: root
            )
        )

        let sections = provider.appendedSystemPromptSections(
            for: AskAgentPromptContext(
                responseLanguage: "en",
                sessionState: .make(sessionID: "prompt-empty", maxToolCalls: 8),
                responseProfile: .detailed
            )
        )

        XCTAssertTrue(sections.isEmpty)
    }

    private func makeRootDirectory(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ask-agent-prompt-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to prepare prompt test root: \(error)", file: file, line: line)
        }
        return root
    }
}
