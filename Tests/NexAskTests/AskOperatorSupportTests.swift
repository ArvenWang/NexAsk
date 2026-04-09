import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskOperatorSupportTests: XCTestCase {
    func testDirectiveDetectsFileOperatorIntent() {
        let directive = AskOperatorSupport.directive(
            for: [
                AskMessage(role: .user, content: "帮我把桌面上的文件按类型移动到不同文件夹")
            ]
        )

        XCTAssertEqual(directive?.scope, .file)
        XCTAssertEqual(directive?.toolFamilies, ["file_read", "file_write", "finder_control", "app_launch"])
    }

    func testDirectiveDetectsWebOperatorIntent() {
        let directive = AskOperatorSupport.directive(
            for: [
                AskMessage(role: .user, content: "Open Chrome and search for the latest OpenAI release notes")
            ]
        )

        XCTAssertEqual(directive?.scope, .web)
        XCTAssertEqual(directive?.toolFamilies, ["browser_open", "browser_search", "page_read"])
    }

    func testDirectiveIgnoresConceptualDiscussion() {
        let directive = AskOperatorSupport.directive(
            for: [
                AskMessage(role: .user, content: "网页操作的架构应该怎么设计？")
            ]
        )

        XCTAssertNil(directive)
    }

    func testAugmentedMessagesInjectOperatorSystemPrompt() {
        let metadata = AskSessionMetadata(
            sessionID: "session-operator",
            sourceBundleID: "com.apple.finder",
            sourceAppName: "Finder",
            frame: CGRect(x: 8, y: 12, width: 320, height: 200)
        )

        let augmented = AskOperatorSupport.augmentedMessages(
            from: [
                AskMessage(role: .user, content: "帮我打开浏览器搜索 SwiftData migration guide")
            ],
            metadata: metadata,
            responseLanguage: "zh"
        )

        XCTAssertEqual(augmented.directive?.scope, .web)
        XCTAssertEqual(augmented.messages.count, 2)
        XCTAssertEqual(augmented.messages.first?.role, .system)
        XCTAssertTrue(augmented.messages.first?.content.contains("operator") == true)
        XCTAssertTrue(augmented.messages.first?.content.contains("网页操作") == true)
    }
}
