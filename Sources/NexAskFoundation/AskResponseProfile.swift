import AppKit

package enum AskResponseProfile: String, Equatable {
    case concise
    case balanced
    case detailed

    package static func resolved(for frame: NSRect) -> AskResponseProfile {
        let width = max(frame.width, 280)
        let height = max(frame.height, 200)
        let readableWidth = max(width - 64, 180)
        let readableHeight = max(height - 136, 96)
        let estimatedLines = readableHeight / 24
        let estimatedCharactersPerLine = readableWidth / 13
        let visibleCapacity = estimatedLines * estimatedCharactersPerLine

        switch visibleCapacity {
        case ..<300:
            return .concise
        case ..<900:
            return .balanced
        default:
            return .detailed
        }
    }

    package var chatCompletionsMaxTokens: Int {
        switch self {
        case .concise:
            return 900
        case .balanced:
            return 1800
        case .detailed:
            return 3200
        }
    }

    package var responsesMaxOutputTokens: Int {
        switch self {
        case .concise:
            return 1000
        case .balanced:
            return 2000
        case .detailed:
            return 3600
        }
    }

    package func guidance(languageCode: String) -> String {
        if languageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("en") {
            switch self {
            case .concise:
                return "The current Ask window is compact. Default to a concise answer: lead with the answer, keep it short, and only expand if the user explicitly asks for more detail."
            case .balanced:
                return "The current Ask window has a medium canvas. Default to a balanced answer: clear first, then enough detail to act without becoming long-winded."
            case .detailed:
                return "The current Ask window is large. It is okay to answer in more depth when helpful: cover the main answer, tradeoffs, and concrete examples without padding."
            }
        }

        switch self {
        case .concise:
            return "当前 Ask 窗比较紧凑。默认给出简洁回答：先直说结论，尽量短，只有在用户明确要求展开时再继续细讲。"
        case .balanced:
            return "当前 Ask 窗大小适中。默认给出平衡回答：先说清结论，再补足够的执行细节，但不要写得冗长。"
        case .detailed:
            return "当前 Ask 窗比较大。可以在有帮助时回答得更深入一些：覆盖核心结论、取舍和具体示例，但不要为了变长而灌水。"
        }
    }
}
