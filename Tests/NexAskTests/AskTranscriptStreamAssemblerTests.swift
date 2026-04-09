import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskTranscriptStreamAssemblerTests: XCTestCase {
    func testAssemblerCommitsParagraphAndListIncrementally() {
        var assembler = AskTranscriptStreamAssembler()

        _ = assembler.apply(
            appendedChunk: "第一段开头",
            fullText: "第一段开头",
            highlightedSuffixLength: 4,
            finalize: false
        )
        XCTAssertEqual(assembler.state.committedBlocks.count, 0)
        XCTAssertEqual(assembler.state.tailBlock?.kind, .paragraph)
        XCTAssertEqual(assembler.state.tailBlock?.text, "第一段开头")

        let patch = assembler.apply(
            appendedChunk: "\n- 第一项\n",
            fullText: "第一段开头\n- 第一项\n",
            highlightedSuffixLength: 4,
            finalize: false
        )

        XCTAssertEqual(
            patch.appendedBlocks.map(\.kind),
            [.paragraph]
        )
        XCTAssertEqual(assembler.state.committedBlocks.count, 1)
        XCTAssertEqual(assembler.state.tailBlock?.kind, .unorderedList)
        XCTAssertEqual(assembler.state.tailBlock?.text, "- 第一项")
    }

    func testAssemblerKeepsCodeBlockStreamingAsSingleTail() {
        var assembler = AskTranscriptStreamAssembler()

        _ = assembler.apply(
            appendedChunk: "```swift\nlet value = 1",
            fullText: "```swift\nlet value = 1",
            highlightedSuffixLength: 5,
            finalize: false
        )

        XCTAssertEqual(assembler.state.committedBlocks.count, 0)
        XCTAssertEqual(assembler.state.tailBlock?.kind, .codeBlock(language: "swift"))
        XCTAssertEqual(assembler.state.tailBlock?.text, "let value = 1")

        let patch = assembler.apply(
            appendedChunk: "\nprint(value)\n```",
            fullText: "```swift\nlet value = 1\nprint(value)\n```",
            highlightedSuffixLength: 5,
            finalize: true
        )

        XCTAssertEqual(patch.appendedBlocks.count, 1)
        XCTAssertEqual(patch.appendedBlocks.first?.kind, .codeBlock(language: "swift"))
        XCTAssertEqual(
            patch.appendedBlocks.first?.text,
            "let value = 1\nprint(value)"
        )
        XCTAssertNil(assembler.state.tailBlock)
    }

    func testAssemblerReplaceAllBuildsCommittedAndTailBlocks() {
        var assembler = AskTranscriptStreamAssembler()
        let patch = assembler.replaceAll(
            with: "第一段\n\n1. 第一项\n2. 第二项\n未完成",
            highlightedSuffixLength: 0,
            finalize: false
        )

        XCTAssertTrue(patch.reset)
        XCTAssertEqual(
            assembler.state.committedBlocks.map(\.kind),
            [.paragraph, .orderedList]
        )
        XCTAssertEqual(assembler.state.tailBlock?.kind, .paragraph)
        XCTAssertEqual(assembler.state.tailBlock?.text, "未完成")
    }

    func testAssemblerFinalizesTailWithoutForcingWholeMessageReset() {
        var assembler = AskTranscriptStreamAssembler()

        _ = assembler.apply(
            appendedChunk: "第一段仍在输出中",
            fullText: "第一段仍在输出中",
            highlightedSuffixLength: 4,
            finalize: false
        )

        let patch = assembler.apply(
            appendedChunk: "",
            fullText: "第一段仍在输出中",
            highlightedSuffixLength: 0,
            finalize: true
        )

        XCTAssertFalse(patch.reset)
        XCTAssertEqual(patch.appendedBlocks.map(\.text), ["第一段仍在输出中"])
        XCTAssertEqual(assembler.state.committedBlocks.map(\.text), ["第一段仍在输出中"])
        XCTAssertNil(assembler.state.tailBlock)
    }

    func testAssemblerInfersMissingIncrementalChunkFromAuthoritativeFullText() {
        var assembler = AskTranscriptStreamAssembler()

        _ = assembler.apply(
            appendedChunk: "Hello",
            fullText: "Hello",
            highlightedSuffixLength: 5,
            finalize: false
        )

        let patch = assembler.apply(
            appendedChunk: "",
            fullText: "Hello world",
            highlightedSuffixLength: 6,
            finalize: false
        )

        XCTAssertFalse(patch.reset)
        XCTAssertEqual(patch.state.tailBlock?.text, "Hello world")
        XCTAssertEqual(patch.state.fullText, "Hello world")
    }

    func testAssemblerSoftJoinsLeadingPunctuationIntoPreviousParagraph() {
        var assembler = AskTranscriptStreamAssembler()

        let patch = assembler.apply(
            appendedChunk: "你好\n！我是 NexHub 的 Ask 助手",
            fullText: "你好\n！我是 NexHub 的 Ask 助手",
            highlightedSuffixLength: 6,
            finalize: false
        )

        XCTAssertFalse(patch.reset)
        XCTAssertEqual(assembler.state.tailBlock?.kind, .paragraph)
        XCTAssertEqual(assembler.state.tailBlock?.text, "你好！我是 NexHub 的 Ask 助手")
    }

    func testAssemblerFinalizedParagraphKeepsSoftJoinedPunctuation() {
        var assembler = AskTranscriptStreamAssembler()

        _ = assembler.apply(
            appendedChunk: "你好\n！我是 NexHub 的 Ask 助手",
            fullText: "你好\n！我是 NexHub 的 Ask 助手",
            highlightedSuffixLength: 6,
            finalize: false
        )

        let patch = assembler.apply(
            appendedChunk: "",
            fullText: "你好\n！我是 NexHub 的 Ask 助手",
            highlightedSuffixLength: 0,
            finalize: true
        )

        XCTAssertEqual(patch.appendedBlocks.map(\.text), ["你好！我是 NexHub 的 Ask 助手"])
        XCTAssertEqual(assembler.state.committedBlocks.map(\.text), ["你好！我是 NexHub 的 Ask 助手"])
        XCTAssertNil(assembler.state.tailBlock)
    }
}
