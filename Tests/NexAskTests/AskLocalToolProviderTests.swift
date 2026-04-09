import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskLocalToolProviderTests: XCTestCase {
    func testPromotedDescriptorsAppearAsInteractiveTools() {
        let provider = AskLocalToolProvider(
            descriptorsProvider: {
                [
                    AskLocalPromotedToolDescriptor(
                        id: "playground_tool_batch_clean",
                        name: "playground_tool_batch_clean",
                        summary: "Batch rename downloaded files.",
                        rootPath: "/tmp/playground-tool",
                        entryFile: "clean.py",
                        languageRuntime: "python"
                    )
                ]
            }
        )

        let tools = provider.availableTools(
            context: AskToolPoolContext(
                responseLanguage: "en",
                sessionID: "local-tool-provider",
                sessionOrigin: .user,
                requestedMode: nil,
                planModeActive: false,
                activeWorkspaceRoot: nil,
                kernelMetadata: [:]
            )
        )

        XCTAssertEqual(tools.map(\.name), ["playground_tool_batch_clean"])
        XCTAssertTrue(tools[0].description.contains("Playground"))
        XCTAssertNotNil((tools[0].parameters["properties"] as? [String: Any])?["input"])
    }
}
