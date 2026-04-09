import Foundation

package enum AskRenderableBlockKind: Equatable {
    case paragraph
    case unorderedList
    case orderedList
    case quote
    case codeBlock(language: String?)
}

package struct AskRenderableBlock: Equatable {
    package let id: Int
    package let kind: AskRenderableBlockKind
    package let text: String

    package init(id: Int, kind: AskRenderableBlockKind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

package struct AskMutableTailBlock: Equatable {
    package let id: Int
    package let kind: AskRenderableBlockKind
    package let text: String
    package let highlightedSuffixLength: Int

    package init(
        id: Int,
        kind: AskRenderableBlockKind,
        text: String,
        highlightedSuffixLength: Int
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.highlightedSuffixLength = highlightedSuffixLength
    }
}

package struct AskAssistantRenderState: Equatable {
    package var committedBlocks: [AskRenderableBlock]
    package var tailBlock: AskMutableTailBlock?
    package var fullText: String

    package init(
        committedBlocks: [AskRenderableBlock],
        tailBlock: AskMutableTailBlock?,
        fullText: String
    ) {
        self.committedBlocks = committedBlocks
        self.tailBlock = tailBlock
        self.fullText = fullText
    }

    package static let empty = AskAssistantRenderState(
        committedBlocks: [],
        tailBlock: nil,
        fullText: ""
    )
}

package struct AskRenderPatch: Equatable {
    package let reset: Bool
    package let appendedBlocks: [AskRenderableBlock]
    package let state: AskAssistantRenderState

    package init(
        reset: Bool,
        appendedBlocks: [AskRenderableBlock],
        state: AskAssistantRenderState
    ) {
        self.reset = reset
        self.appendedBlocks = appendedBlocks
        self.state = state
    }
}

package struct AskTranscriptStreamAssembler {
    private struct ClassifiedLine {
        let kind: AskRenderableBlockKind
        let content: String
    }

    package private(set) var state: AskAssistantRenderState = .empty

    private var committedBlocks: [AskRenderableBlock] = []
    private var openBlockID: Int?
    private var openBlockKind: AskRenderableBlockKind?
    private var openBlockText = ""
    private var previewBlockID: Int?
    private var previewBlockKind: AskRenderableBlockKind?
    private var lineBuffer = ""
    private var insideCodeBlock = false
    private var codeFenceLanguage: String?
    private var nextBlockID = 0

    package init() {}

    package mutating func replaceAll(
        with text: String,
        highlightedSuffixLength: Int = 0,
        finalize: Bool = true
    ) -> AskRenderPatch {
        resetParserState()
        let normalized = normalizedText(text)
        _ = consumeChunk(
            normalized,
            highlightedSuffixLength: highlightedSuffixLength,
            finalize: finalize
        )
        return AskRenderPatch(
            reset: true,
            appendedBlocks: state.committedBlocks,
            state: state
        )
    }

    package mutating func apply(
        appendedChunk: String,
        fullText: String,
        highlightedSuffixLength: Int = 0,
        finalize: Bool = false
    ) -> AskRenderPatch {
        let normalizedFullText = normalizedText(fullText)
        let normalizedChunk = normalizedText(appendedChunk)

        guard !normalizedFullText.isEmpty else {
            resetParserState()
            state = .empty
            return AskRenderPatch(reset: true, appendedBlocks: [], state: state)
        }

        if normalizedFullText.hasPrefix(state.fullText) {
            let incrementalChunk: String
            if !normalizedChunk.isEmpty {
                incrementalChunk = normalizedChunk
            } else if normalizedFullText.count > state.fullText.count {
                incrementalChunk = String(normalizedFullText.dropFirst(state.fullText.count))
            } else {
                incrementalChunk = ""
            }

            if !incrementalChunk.isEmpty || finalize {
                let patch = consumeChunk(
                    incrementalChunk,
                    highlightedSuffixLength: highlightedSuffixLength,
                    finalize: finalize
                )
                state.fullText = normalizedFullText
                return AskRenderPatch(
                    reset: patch.reset,
                    appendedBlocks: patch.appendedBlocks,
                    state: AskAssistantRenderState(
                        committedBlocks: state.committedBlocks,
                        tailBlock: state.tailBlock,
                        fullText: normalizedFullText
                    )
                )
            }

            state.fullText = normalizedFullText
            return AskRenderPatch(reset: false, appendedBlocks: [], state: state)
        }

        return replaceAll(
            with: normalizedFullText,
            highlightedSuffixLength: highlightedSuffixLength,
            finalize: finalize
        )
    }

    private mutating func consumeChunk(
        _ chunk: String,
        highlightedSuffixLength: Int,
        finalize: Bool
    ) -> AskRenderPatch {
        var appendedBlocks: [AskRenderableBlock] = []
        lineBuffer.append(chunk)

        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<newlineRange.lowerBound])
            lineBuffer.removeSubrange(lineBuffer.startIndex..<newlineRange.upperBound)
            consumeCompletedLine(line, appendedBlocks: &appendedBlocks)
        }

        synchronizeOpenBlockWithPreview(appendedBlocks: &appendedBlocks)

        if finalize {
            finalizeTail(appendedBlocks: &appendedBlocks)
        }

        state = AskAssistantRenderState(
            committedBlocks: committedBlocks,
            tailBlock: currentTailBlock(highlightedSuffixLength: highlightedSuffixLength),
            fullText: state.fullText + chunk
        )

        return AskRenderPatch(
            reset: false,
            appendedBlocks: appendedBlocks,
            state: state
        )
    }

    private mutating func consumeCompletedLine(
        _ line: String,
        appendedBlocks: inout [AskRenderableBlock]
    ) {
        let classificationLine = normalizedClassificationLine(line)
        let trimmed = classificationLine.trimmingCharacters(in: .whitespacesAndNewlines)

        if insideCodeBlock {
            if isFenceLine(trimmed) {
                commitOpenBlockIfNeeded(into: &appendedBlocks)
                insideCodeBlock = false
                codeFenceLanguage = nil
            } else {
                ensureOpenBlock(kind: .codeBlock(language: codeFenceLanguage))
                if openBlockText.isEmpty {
                    openBlockText = line
                } else {
                    openBlockText += "\n" + line
                }
            }
            return
        }

        if trimmed.isEmpty {
            commitOpenBlockIfNeeded(into: &appendedBlocks)
            return
        }

        if isFenceLine(trimmed) {
            commitOpenBlockIfNeeded(into: &appendedBlocks)
            insideCodeBlock = true
            let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            codeFenceLanguage = language.isEmpty ? nil : language
            return
        }

        let classified = classify(line: trimmed)
        switch classified.kind {
        case .paragraph, .quote, .unorderedList, .orderedList:
            if openBlockKind == classified.kind, openBlockID != nil {
                if openBlockText.isEmpty {
                    openBlockText = classified.content
                } else {
                    openBlockText = appendedContent(
                        existing: openBlockText,
                        next: classified.content,
                        kind: classified.kind
                    )
                }
            } else {
                commitOpenBlockIfNeeded(into: &appendedBlocks)
                openBlockID = consumePreviewBlockID(for: classified.kind) ?? nextID()
                openBlockKind = classified.kind
                openBlockText = classified.content
            }
        case .codeBlock:
            break
        }
    }

    private mutating func synchronizeOpenBlockWithPreview(appendedBlocks: inout [AskRenderableBlock]) {
        guard !insideCodeBlock else { return }
        let classificationLine = normalizedClassificationLine(lineBuffer)
        let trimmed = classificationLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isFenceLine(trimmed) else {
            commitOpenBlockIfNeeded(into: &appendedBlocks)
            return
        }

        let classified = classify(line: classificationLine)
        guard let openBlockKind else { return }
        guard !isJoinable(openBlockKind, with: classified.kind) else { return }
        commitOpenBlockIfNeeded(into: &appendedBlocks)
    }

    private mutating func finalizeTail(appendedBlocks: inout [AskRenderableBlock]) {
        if insideCodeBlock {
            let trimmedBuffer = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if isFenceLine(trimmedBuffer) {
                lineBuffer.removeAll(keepingCapacity: false)
            } else if !lineBuffer.isEmpty {
                ensureOpenBlock(kind: .codeBlock(language: codeFenceLanguage))
                if openBlockText.isEmpty {
                    openBlockText = lineBuffer
                } else {
                    openBlockText += "\n" + lineBuffer
                }
                lineBuffer.removeAll(keepingCapacity: false)
            }
            insideCodeBlock = false
            codeFenceLanguage = nil
            commitOpenBlockIfNeeded(into: &appendedBlocks)
            return
        }

        let classificationLine = normalizedClassificationLine(lineBuffer)
        if !classificationLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            consumeCompletedLine(classificationLine, appendedBlocks: &appendedBlocks)
        }
        lineBuffer.removeAll(keepingCapacity: false)
        commitOpenBlockIfNeeded(into: &appendedBlocks)
    }

    private mutating func currentTailBlock(highlightedSuffixLength: Int) -> AskMutableTailBlock? {
        if insideCodeBlock {
            let previewText: String
            if openBlockText.isEmpty {
                previewText = lineBuffer
            } else if lineBuffer.isEmpty {
                previewText = openBlockText
            } else {
                previewText = openBlockText + "\n" + lineBuffer
            }
            guard !previewText.isEmpty else { return nil }
            let kind = AskRenderableBlockKind.codeBlock(language: codeFenceLanguage)
            let id = openBlockID ?? previewBlockID(for: kind)
            return AskMutableTailBlock(
                id: id,
                kind: kind,
                text: previewText,
                highlightedSuffixLength: min(highlightedSuffixLength, (previewText as NSString).length)
            )
        }

        let classificationLine = normalizedClassificationLine(lineBuffer)
        if !classificationLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let classified = classify(line: classificationLine)
            if let openBlockKind,
               openBlockID != nil,
               isJoinable(openBlockKind, with: classified.kind) {
                let combinedText = openBlockText.isEmpty
                    ? classified.content
                    : appendedContent(
                        existing: openBlockText,
                        next: classified.content,
                        kind: classified.kind
                    )
                return AskMutableTailBlock(
                    id: openBlockID ?? previewBlockID(for: classified.kind),
                    kind: classified.kind,
                    text: combinedText,
                    highlightedSuffixLength: min(highlightedSuffixLength, (combinedText as NSString).length)
                )
            }

            let id = previewBlockID(for: classified.kind)
            return AskMutableTailBlock(
                id: id,
                kind: classified.kind,
                text: classified.content,
                highlightedSuffixLength: min(highlightedSuffixLength, (classified.content as NSString).length)
            )
        }

        guard let openBlockKind, let openBlockID, !openBlockText.isEmpty else { return nil }
        return AskMutableTailBlock(
            id: openBlockID,
            kind: openBlockKind,
            text: openBlockText,
            highlightedSuffixLength: min(highlightedSuffixLength, (openBlockText as NSString).length)
        )
    }

    private mutating func ensureOpenBlock(kind: AskRenderableBlockKind) {
        if openBlockKind == kind, openBlockID != nil {
            return
        }
        openBlockID = consumePreviewBlockID(for: kind) ?? nextID()
        openBlockKind = kind
        openBlockText.removeAll(keepingCapacity: false)
    }

    private mutating func commitOpenBlockIfNeeded(into appendedBlocks: inout [AskRenderableBlock]) {
        guard let openBlockID, let openBlockKind, !openBlockText.isEmpty else {
            openBlockID = nil
            openBlockKind = nil
            openBlockText.removeAll(keepingCapacity: false)
            return
        }

        let block = AskRenderableBlock(
            id: openBlockID,
            kind: openBlockKind,
            text: openBlockText
        )
        committedBlocks.append(block)
        appendedBlocks.append(block)
        self.openBlockID = nil
        self.openBlockKind = nil
        self.openBlockText.removeAll(keepingCapacity: false)
    }

    private mutating func previewBlockID(for kind: AskRenderableBlockKind) -> Int {
        if previewBlockKind == kind, let previewBlockID {
            return previewBlockID
        }
        let id = nextID()
        previewBlockID = id
        previewBlockKind = kind
        return id
    }

    private mutating func consumePreviewBlockID(for kind: AskRenderableBlockKind) -> Int? {
        guard previewBlockKind == kind else { return nil }
        let id = previewBlockID
        previewBlockID = nil
        previewBlockKind = nil
        return id
    }

    private mutating func nextID() -> Int {
        defer { nextBlockID += 1 }
        return nextBlockID
    }

    private mutating func resetParserState() {
        committedBlocks.removeAll(keepingCapacity: false)
        openBlockID = nil
        openBlockKind = nil
        openBlockText.removeAll(keepingCapacity: false)
        previewBlockID = nil
        previewBlockKind = nil
        lineBuffer.removeAll(keepingCapacity: false)
        insideCodeBlock = false
        codeFenceLanguage = nil
        nextBlockID = 0
        state = .empty
    }

    private func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func normalizedClassificationLine(_ line: String) -> String {
        line.replacingOccurrences(
            of: #"^\s+"#,
            with: "",
            options: .regularExpression
        )
    }

    private func isFenceLine(_ line: String) -> Bool {
        line.hasPrefix("```")
    }

    private func isJoinable(_ lhs: AskRenderableBlockKind, with rhs: AskRenderableBlockKind) -> Bool {
        switch (lhs, rhs) {
        case (.paragraph, .paragraph),
             (.quote, .quote),
             (.unorderedList, .unorderedList),
             (.orderedList, .orderedList):
            return true
        case let (.codeBlock(lhsLanguage), .codeBlock(rhsLanguage)):
            return lhsLanguage == rhsLanguage
        default:
            return false
        }
    }

    private func classify(line: String) -> ClassifiedLine {
        if let orderedMatch = line.range(of: #"^(\d+[.)])\s+(.+)$"#, options: .regularExpression) {
            let matched = String(line[orderedMatch])
            return ClassifiedLine(kind: .orderedList, content: matched)
        }

        if let unorderedMatch = line.range(of: #"^(?:[-*•])\s+(.+)$"#, options: .regularExpression) {
            let matched = String(line[unorderedMatch])
            let content = matched.replacingOccurrences(
                of: #"^(?:[-*•])\s+"#,
                with: "",
                options: .regularExpression
            )
            return ClassifiedLine(kind: .unorderedList, content: "- \(content)")
        }

        if line.hasPrefix(">") {
            let content = line.replacingOccurrences(
                of: #"^>\s?"#,
                with: "",
                options: .regularExpression
            )
            return ClassifiedLine(kind: .quote, content: "> \(content)")
        }

        return ClassifiedLine(kind: .paragraph, content: line)
    }

    private func appendedContent(
        existing: String,
        next: String,
        kind: AskRenderableBlockKind
    ) -> String {
        guard shouldSoftJoin(next: next, kind: kind) else {
            return existing + "\n" + next
        }
        return existing + next
    }

    private func shouldSoftJoin(next: String, kind: AskRenderableBlockKind) -> Bool {
        switch kind {
        case .paragraph, .quote:
            break
        default:
            return false
        }

        guard let first = next.unicodeScalars.first else { return false }
        let punctuation = CharacterSet(charactersIn: "!！?？,，.。:：;；、)]}）】》」』")
        return punctuation.contains(first)
    }
}
