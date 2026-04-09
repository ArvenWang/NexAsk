import Foundation

struct ResultTranscriptMessage {
    let role: ResultPanelController.MessageRole
    let text: String
    let toolKey: String?
    let toolDetails: [String]
    let toolLabel: String?
    let toolAnimatedDetail: String?
}

enum ResultTranscriptRow {
    case toolStatus(
        status: String,
        label: String?,
        details: [String],
        highlightedDetail: String?,
        isLoading: Bool,
        isDone: Bool,
        messageIndex: Int
    )
    case chatMessage(
        role: ResultPanelController.MessageRole,
        text: String,
        highlightedSuffixLength: Int,
        highlightedAlpha: CGFloat,
        isSelectable: Bool,
        messageIndex: Int
    )
    case sectionHeader(String)
    case traceCard(entity: TraceEntity, isPrimary: Bool, shouldAnimate: Bool)
    case actionCard(card: SkillResultCard, isPrimary: Bool, shouldAnimate: Bool)
}

struct ResultTranscriptRenderPlan {
    let rows: [ResultTranscriptRow]
    let shouldScrollToBottom: Bool
}

struct ResultTranscriptRenderInput {
    let messages: [ResultTranscriptMessage]
    let isStreamingMode: Bool
    let activeToolStatusKey: String?
    let streamingAssistantIndex: Int?
    let streamingHighlightedSuffixLength: Int
    let streamingHighlightedAlpha: CGFloat
    let latestTraceEntities: [TraceEntity]
    let renderedTraceCardCount: Int
    let animatingTraceCardIndex: Int?
    let latestActionCards: [SkillResultCard]
    let renderedActionCardCount: Int
    let animatingActionCardIndex: Int?
    let currentDisplayKind: ResultPanelDisplayKind
}

enum ResultPanelDisplayKind: Hashable {
    case translate
    case trace
    case explain
    case reply
    case schedule
    case info
}

struct ResultTranscriptRenderer {
    func makePlan(from input: ResultTranscriptRenderInput) -> ResultTranscriptRenderPlan {
        var rows: [ResultTranscriptRow] = []

        for (index, message) in input.messages.enumerated() {
            switch message.role {
            case .tool:
                let isLoading = input.isStreamingMode && message.toolKey == input.activeToolStatusKey
                let isDone = !isLoading && message.toolKey != nil
                rows.append(
                    .toolStatus(
                        status: message.text,
                        label: message.toolLabel,
                        details: message.toolDetails.isEmpty
                            ? localizedStatusDetail(message.toolKey).map { [$0] } ?? []
                            : message.toolDetails,
                        highlightedDetail: message.toolAnimatedDetail,
                        isLoading: isLoading,
                        isDone: isDone,
                        messageIndex: index
                    )
                )
            default:
                let highlightedSuffixLength = (message.role == .assistant && index == input.streamingAssistantIndex)
                    ? input.streamingHighlightedSuffixLength
                    : 0
                rows.append(
                    .chatMessage(
                        role: message.role,
                        text: message.text,
                        highlightedSuffixLength: highlightedSuffixLength,
                        highlightedAlpha: input.streamingHighlightedAlpha,
                        isSelectable: message.role == .assistant || message.role == .info,
                        messageIndex: index
                    )
                )
            }
        }

        let visibleTraceEntities = Array(input.latestTraceEntities.prefix(input.renderedTraceCardCount))
        if !visibleTraceEntities.isEmpty {
            rows.append(.sectionHeader(L10n.text(zhHans: "推荐入口", en: "Recommended Sources")))
            for (index, entity) in visibleTraceEntities.enumerated() {
                rows.append(.traceCard(entity: entity, isPrimary: index == 0, shouldAnimate: index == input.animatingTraceCardIndex))
            }
        }

        let visibleActionCards = Array(input.latestActionCards.prefix(input.renderedActionCardCount))
        if !visibleActionCards.isEmpty {
            rows.append(.sectionHeader(actionCardSectionTitle(for: visibleActionCards)))
            for (index, card) in visibleActionCards.enumerated() {
                rows.append(.actionCard(card: card, isPrimary: index == 0, shouldAnimate: index == input.animatingActionCardIndex))
            }
        }

        return ResultTranscriptRenderPlan(
            rows: rows,
            shouldScrollToBottom: input.currentDisplayKind == .trace || !visibleActionCards.isEmpty
        )
    }

    private func actionCardSectionTitle(for cards: [SkillResultCard]) -> String {
        guard let firstKind = cards.first?.kind else { return L10n.text(zhHans: "快捷操作", en: "Quick Actions") }
        switch firstKind {
        case "calendar_event":
            return L10n.text(zhHans: "📅 创建日历提醒", en: "📅 Create Calendar Event")
        case "reminder":
            return L10n.text(zhHans: "⏰ 创建提醒事项", en: "⏰ Create Reminder")
        case "knowledge_base_source":
            return L10n.text(zhHans: "引用来源", en: "Sources")
        default:
            return L10n.text(zhHans: "快捷操作", en: "Quick Actions")
        }
    }

    private func localizedStatusDetail(_ status: String?) -> String? {
        guard let status else { return nil }
        switch status {
        case "thinking":
            return nil
        case "connecting":
            return L10n.text(zhHans: "正在连接 AI 服务并准备生成结果。", en: "Connecting to the AI service and preparing the result.")
        case "semantic_decomposition":
            return L10n.text(zhHans: "解析原文结构，识别事件、实体和它们之间的关系。", en: "Parsing the source text structure and identifying entities, events, and their relationships.")
        case "entity_analysis":
            return L10n.text(zhHans: "判断用户最可能想打开的主目标，并区分相关实体。", en: "Determining the most likely primary target to open and separating related entities.")
        case "search_enhancement":
            return L10n.text(zhHans: "基于主目标、属主线索和别名生成搜索计划并收集候选。", en: "Building a search plan from the main target, ownership clues, and aliases, then collecting candidates.")
        case "candidate_resolution":
            return L10n.text(zhHans: "正在比较候选入口，排除新闻页、导航页和无关同名站点。", en: "Comparing candidate entries and filtering out news pages, directory pages, and irrelevant namesakes.")
        case "result_generation":
            return L10n.text(zhHans: "对候选入口做最终判定，并整理成可直接打开的结果。", en: "Making the final source decision and packaging it into something you can open directly.")
        case "model_streaming":
            return L10n.text(zhHans: "模型正在持续输出总结文本。", en: "The model is still streaming the summary.")
        case "preparing":
            return L10n.text(zhHans: "正在读取选中的文件与文件夹，并建立处理计划。", en: "Reading the selected files and folders and preparing the execution plan.")
        case "compressing":
            return L10n.text(zhHans: "正在调用对应工具处理可压缩文件。", en: "Running the appropriate tools on compressible files.")
        case "fallback":
            return L10n.text(zhHans: "模型链路不可用，已切换到降级检索与规则判定。", en: "The model path is unavailable, so NexHub switched to fallback retrieval and rule-based resolution.")
        default:
            return nil
        }
    }
}
