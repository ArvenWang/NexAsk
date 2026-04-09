import Foundation

struct ToolCapability {
    let id: ToolCapabilityID
    let title: String
    let summary: String
}

final class ToolRegistry {
    static let shared = ToolRegistry()

    let capabilities: [ToolCapabilityID: ToolCapability] = [
        .llmChat: ToolCapability(id: .llmChat, title: "LLM Chat", summary: L10n.text(zhHans: "通用语言理解与生成", en: "General language understanding and generation")),
        .webSearch: ToolCapability(id: .webSearch, title: "Web Search", summary: L10n.text(zhHans: "搜索公开网页候选", en: "Search public web candidates")),
        .pageFetch: ToolCapability(id: .pageFetch, title: "Page Fetch", summary: L10n.text(zhHans: "抓取页面标题与摘要", en: "Fetch page titles and summaries")),
        .sourceRank: ToolCapability(id: .sourceRank, title: "Source Rank", summary: L10n.text(zhHans: "对候选来源重排序", en: "Re-rank candidate sources")),
        .imageCompress: ToolCapability(id: .imageCompress, title: "Image Compress", summary: L10n.text(zhHans: "压缩并导出图片", en: "Compress and export images")),
        .pdfCompress: ToolCapability(id: .pdfCompress, title: "PDF Compress", summary: L10n.text(zhHans: "压缩并导出 PDF", en: "Compress and export PDFs")),
    ]

    private init() {}
}

struct SkillDefinition {
    let legacyAction: QuickAction?
    let manifest: SkillManifest
    let instructionText: String?
    let sourceDirectory: URL?
    let skillSource: SkillSource

    var skillID: String { manifest.id }
    var version: String { manifest.version ?? "0.1.0" }
    var title: String { localizedBuiltinCopy?.title ?? manifest.name }
    var toolbarTitle: String { localizedBuiltinCopy?.toolbarTitle ?? manifest.display.toolbarTitle }
    var settingsTitle: String {
        if let localized = localizedBuiltinCopy?.settingsTitle {
            return localized
        }
        return manifest.settings?.title
            ?? manifest.display.settingsTitle
            ?? L10n.format(zhHans: "启用%@动作", en: "Enable %@", manifest.name)
    }
    var resultTitle: String { localizedBuiltinCopy?.resultTitle ?? manifest.display.resultTitle }
    var symbolName: String { manifest.display.icon }
    var summary: String { localizedBuiltinCopy?.summary ?? manifest.description.summary }
    var category: String { manifest.metadata?.category ?? manifest.display.category ?? "general" }
    var instructionFileName: String? { manifest.execution.instructionFile }
    var toolCapabilities: [ToolCapabilityID] { manifest.execution.tools }
    var knowledgeBase: SkillKnowledgeBaseContract? { manifest.execution.knowledgeBase }
    var usesKnowledgeBase: Bool { manifest.execution.knowledgeBase?.enabled == true }
    var priorityTier: SkillPriorityTier { manifest.display.priorityTier ?? .recommended }
    var supportedContexts: [ActivationSource] { manifest.input.supportedContexts }
    var preferredContentTypes: [ActivationContentType] { manifest.input.preferredContentTypes ?? [.text] }
    var fallbackRank: Int { manifest.routing.fallbackRank ?? 99 }
    var resultType: SkillResultType { manifest.result.type }
    var supportsCopy: Bool { manifest.result.supportsCopy ?? false }
    var supportsReplace: Bool { manifest.result.supportsReplace ?? false }
    var supportsOpenPrimary: Bool { manifest.result.supportsOpenPrimary ?? false }
    var supportsWriteback: Bool { manifest.result.supportsWriteback ?? false }
    var supportsFooter: Bool { manifest.result.supportsFooter ?? false }
    var supportsActionCards: Bool { manifest.result.supportsActionCards ?? false }
    var supportsRegenerate: Bool { manifest.result.supportsRegenerate ?? false }
    var supportsFollowup: Bool { manifest.execution.supportsFollowup ?? false }
    var isStreaming: Bool { manifest.execution.streaming ?? false }
    var safeToInterrupt: Bool { manifest.execution.safeToInterrupt ?? true }
    var defaultEnabled: Bool { manifest.settings?.defaultEnabled ?? true }
    var billingClass: SkillBillingClass { manifest.billing?.billingClass ?? .free }
    var requiredEntitlementTier: SkillEntitlementTier? { manifest.billing?.requiredTier }
    var executionLocality: SkillExecutionLocality { manifest.execution.locality ?? (manifest.execution.mode == .localOnly ? .localOnly : .cloudOnly) }
    var isCapabilityShim: Bool {
        switch skillID {
        case "screenshot_ocr", "screenshot_save":
            return true
        default:
            return false
        }
    }
    var isUserConfigurable: Bool {
        if isCapabilityShim {
            return false
        }
        if let explicit = manifest.settings?.userConfigurable {
            return explicit
        }
        return true
    }
    var stage: SkillStage {
        manifest.settings?.stage
            ?? manifest.metadata?.stage
            ?? (manifest.execution.mode == .localOnly ? .local : .cloud)
    }

    private var localizedBuiltinCopy: LocalizedBuiltinSkillCopy? {
        LocalizedBuiltinSkillCopy.resolve(for: skillID)
    }
}

@available(*, deprecated, renamed: "SkillDefinition")
typealias ActionDefinition = SkillDefinition

private struct LocalizedBuiltinSkillCopy {
    let title: String
    let toolbarTitle: String
    let settingsTitle: String?
    let resultTitle: String
    let summary: String

    static func resolve(for skillID: String) -> LocalizedBuiltinSkillCopy? {
        switch skillID {
        case "translate":
            return .init(
                title: L10n.text(zhHans: "文本翻译", en: "Text Translation"),
                toolbarTitle: L10n.text(zhHans: "翻译", en: "Translate"),
                settingsTitle: L10n.text(zhHans: "启用翻译动作", en: "Enable Translate"),
                resultTitle: L10n.text(zhHans: "翻译结果", en: "Translation"),
                summary: L10n.text(zhHans: "将选中文本翻译成目标语言，并尽量保持原意与语气。", en: "Translate the selected text into the target language while preserving meaning and tone.")
            )
        case "trace":
            return .init(
                title: L10n.text(zhHans: "深度溯源", en: "Source Lookup"),
                toolbarTitle: L10n.text(zhHans: "溯源", en: "Source"),
                settingsTitle: L10n.text(zhHans: "启用溯源动作", en: "Enable Source"),
                resultTitle: L10n.text(zhHans: "溯源结果", en: "Source Result"),
                summary: L10n.text(zhHans: "理解用户意图，找到最值得直接打开的官方入口、体验页或原始来源。", en: "Understand intent and find the most relevant official entry, experience page, or original source to open directly.")
            )
        case "explain":
            return .init(
                title: L10n.text(zhHans: "内容解释", en: "Text Explanation"),
                toolbarTitle: L10n.text(zhHans: "解释", en: "Explain"),
                settingsTitle: L10n.text(zhHans: "启用解释动作", en: "Enable Explain"),
                resultTitle: L10n.text(zhHans: "解释结果", en: "Explanation"),
                summary: L10n.text(zhHans: "用简短自然的话解释选中文本是什么、为什么重要。", en: "Explain what the selected text is and why it matters in concise, natural language.")
            )
        case "reply":
            return .init(
                title: L10n.text(zhHans: "高情商回复", en: "Smart Reply"),
                toolbarTitle: L10n.text(zhHans: "回复", en: "Reply"),
                settingsTitle: L10n.text(zhHans: "启用高情商回复动作", en: "Enable Reply"),
                resultTitle: L10n.text(zhHans: "高情商回复", en: "Reply Draft"),
                summary: L10n.text(zhHans: "基于选中文本和知识库资料生成可直接发送的自然回复。", en: "Generate a natural reply you can send directly from the selected text and knowledge base context.")
            )
        case "schedule":
            return .init(
                title: L10n.text(zhHans: "日程提醒", en: "Schedule Reminder"),
                toolbarTitle: L10n.text(zhHans: "日程", en: "Schedule"),
                settingsTitle: L10n.text(zhHans: "启用日程动作", en: "Enable Schedule"),
                resultTitle: L10n.text(zhHans: "日程提醒", en: "Schedule Reminder"),
                summary: L10n.text(zhHans: "从选中文本中识别时间意图，一键创建日历提醒。", en: "Detect time intent from the selected text and create a calendar reminder in one step.")
            )
        case "collect":
            return .init(
                title: L10n.text(zhHans: "知识采集", en: "Knowledge Capture"),
                toolbarTitle: L10n.text(zhHans: "采集", en: "Collect"),
                settingsTitle: L10n.text(zhHans: "启用采集动作", en: "Enable Collect"),
                resultTitle: L10n.text(zhHans: "采集结果", en: "Collected"),
                summary: L10n.text(zhHans: "把当前链接或文件采集到本地知识库，便于后续检索和引用。", en: "Collect the current link or file into the local knowledge base for later retrieval and reuse.")
            )
        case "compress":
            return .init(
                title: L10n.text(zhHans: "无损压缩", en: "File Compression"),
                toolbarTitle: L10n.text(zhHans: "压缩", en: "Compress"),
                settingsTitle: L10n.text(zhHans: "启用压缩动作", en: "Enable Compress"),
                resultTitle: L10n.text(zhHans: "文件压缩", en: "Compression Result"),
                summary: L10n.text(zhHans: "压缩选中的文件，按类型调用对应压缩工具并输出到统一目录。", en: "Compress selected files with the appropriate tool for each type and save them to a unified output location.")
            )
        case "screenshot_ocr":
            return .init(
                title: L10n.text(zhHans: "文字识别", en: "Text Recognition"),
                toolbarTitle: "OCR",
                settingsTitle: nil,
                resultTitle: L10n.text(zhHans: "OCR 结果", en: "OCR Result"),
                summary: L10n.text(zhHans: "识别当前截图中的文字，并输出可复制文本。", en: "Recognize text in the current screenshot and return copyable output.")
            )
        case "screenshot_save":
            return .init(
                title: L10n.text(zhHans: "截图保存", en: "Save Screenshot"),
                toolbarTitle: L10n.text(zhHans: "保存", en: "Save"),
                settingsTitle: nil,
                resultTitle: L10n.text(zhHans: "截图保存", en: "Screenshot Saved"),
                summary: L10n.text(zhHans: "保存当前截图到桌面目录。", en: "Save the current screenshot to the desktop.")
            )
        default:
            return nil
        }
    }
}

final class ActionRegistry {
    static let shared = ActionRegistry()

    private let skillRegistry: SkillRegistry

    private init(skillRegistry: SkillRegistry = .shared) {
        self.skillRegistry = skillRegistry
    }

    var all: [SkillDefinition] {
        skillRegistry.allDefinitions
    }

    func definition(for action: QuickAction) -> SkillDefinition {
        definition(forSkillID: action.skillID) ?? ActionRegistry.defaultDefinition(for: action)
    }

    func definition(forSkillID skillID: String) -> SkillDefinition? {
        skillRegistry.definition(forSkillID: skillID)
    }

    func enabledDefinitions(settings: AppSettings) -> [SkillDefinition] {
        all.filter { isEnabled($0.skillID, settings: settings) }
    }

    func settingsDefinitions() -> [SkillDefinition] {
        all.filter(\.isUserConfigurable)
    }

    func defaultPrimarySkillIDs(settings: AppSettings, maxCount: Int = 3) -> [String] {
        let enabled = enabledDefinitions(settings: settings)
        let anchors = enabled
            .filter { $0.priorityTier == .anchor }
            .sorted(by: ActionRegistry.sortForPresentation)
        let recommended = enabled
            .filter { $0.priorityTier != .hidden && $0.priorityTier != .anchor }
            .sorted(by: ActionRegistry.sortForPresentation)
        let primary = Array((anchors + recommended).prefix(maxCount))
        return primary.map(\.skillID)
    }

    func defaultSecondarySkillIDs(settings: AppSettings, excluding primarySkillIDs: [String]) -> [String] {
        let primarySet = Set(primarySkillIDs)
        return enabledDefinitions(settings: settings)
            .filter { !primarySet.contains($0.skillID) && $0.priorityTier != .hidden }
            .sorted(by: ActionRegistry.sortForPresentation)
            .map(\.skillID)
    }

    func isEnabled(_ skillID: String, settings: AppSettings) -> Bool {
        guard let definition = definition(forSkillID: skillID) else { return true }
        let defaultEnabled = skillRegistry.defaultEnabled(forSkillID: skillID) ?? definition.defaultEnabled
        return settings.isSkillEnabled(skillID, defaultEnabled: defaultEnabled)
    }

    func isEnabled(_ action: QuickAction, settings: AppSettings) -> Bool {
        isEnabled(action.skillID, settings: settings)
    }

    func isKnowledgeBaseEnabled(_ skillID: String, settings: AppSettings) -> Bool {
        guard let definition = definition(forSkillID: skillID),
              let knowledgeBase = definition.knowledgeBase else {
            return false
        }
        return settings.isKnowledgeBaseEnabled(forSkillID: skillID, defaultEnabled: knowledgeBase.enabled)
    }

    func setEnabled(_ enabled: Bool, forSkillID skillID: String, settings: AppSettings) {
        guard let definition = definition(forSkillID: skillID), definition.isUserConfigurable else { return }
        settings.setSkillEnabled(enabled, forSkillID: skillID, defaultEnabled: definition.defaultEnabled)
    }

    func setKnowledgeBaseEnabled(_ enabled: Bool, forSkillID skillID: String, settings: AppSettings) {
        guard let definition = definition(forSkillID: skillID),
              let knowledgeBase = definition.knowledgeBase else {
            return
        }
        settings.setKnowledgeBaseEnabled(enabled, forSkillID: skillID, defaultEnabled: knowledgeBase.enabled)
    }

    func setEnabled(_ enabled: Bool, for action: QuickAction, settings: AppSettings) {
        setEnabled(enabled, forSkillID: action.skillID, settings: settings)
    }

    static func loadAvailableBuiltinDefinitions(from bundle: Bundle = .main) -> [SkillDefinition] {
        for root in candidateSkillRoots(bundle: bundle) {
            guard let definitions = try? loadBuiltinDefinitions(fromRoot: root), !definitions.isEmpty else {
                continue
            }
            return definitions
        }
        let fallback = defaultDefinitions()
        return fallback.sorted(by: sortForPresentation)
    }

    private static func candidateSkillRoots(bundle: Bundle) -> [URL] {
        var roots: [URL] = []
        if let resourceURL = bundle.resourceURL {
            roots.append(resourceURL.appendingPathComponent("BuiltinSkills", isDirectory: true))
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        roots.append(cwd.appendingPathComponent("BuiltinSkills", isDirectory: true))
        return roots
    }

    private static func loadBuiltinDefinitions(fromRoot root: URL) throws -> [SkillDefinition] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        let subdirectories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let decoder = JSONDecoder()
        var definitions: [SkillDefinition] = []

        for directory in subdirectories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
            let data = try Data(contentsOf: manifestURL)
            let manifest = try decoder.decode(SkillManifest.self, from: data)
            definitions.append(
                SkillDefinition(
                    legacyAction: QuickAction(skillID: manifest.id),
                    manifest: manifest,
                    instructionText: loadInstructionText(from: directory, fileName: manifest.execution.instructionFile),
                    sourceDirectory: directory,
                    skillSource: .builtin
                )
            )
        }

        return definitions
    }

    private static func loadInstructionText(from directory: URL, fileName: String?) -> String? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func defaultDefinitions() -> [SkillDefinition] {
        QuickAction.allCases.map(defaultDefinition(for:))
    }

    private static func defaultDefinition(for action: QuickAction) -> SkillDefinition {
        SkillDefinition(
            legacyAction: action,
            manifest: defaultManifest(for: action),
            instructionText: nil,
            sourceDirectory: nil,
            skillSource: .builtin
        )
    }

    static func sortForPresentation(_ lhs: SkillDefinition, _ rhs: SkillDefinition) -> Bool {
        let lhsWeight = priorityWeight(lhs.priorityTier)
        let rhsWeight = priorityWeight(rhs.priorityTier)
        if lhsWeight != rhsWeight {
            return lhsWeight < rhsWeight
        }
        if lhs.fallbackRank != rhs.fallbackRank {
            return lhs.fallbackRank < rhs.fallbackRank
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private static func priorityWeight(_ tier: SkillPriorityTier) -> Int {
        switch tier {
        case .anchor: return 0
        case .recommended: return 1
        case .secondary: return 2
        case .hidden: return 3
        }
    }

    private static func defaultManifest(for action: QuickAction) -> SkillManifest {
        func text(_ zhHans: String, _ en: String) -> String {
            L10n.text(zhHans: zhHans, en: en)
        }

        switch action {
        case .translate:
            return SkillManifest(
                schemaVersion: "0.1",
                id: "translate",
                name: text("文本翻译", "Text Translation"),
                version: "0.1.0",
                author: nil,
                homepage: nil,
                license: nil,
                display: SkillDisplay(
                    toolbarTitle: text("翻译", "Translate"),
                    settingsTitle: text("启用翻译动作", "Enable Translate"),
                    resultTitle: text("翻译结果", "Translation"),
                    icon: "character.book.closed",
                    category: "language",
                    priorityTier: .anchor
                ),
                description: SkillDescription(
                    summary: text("将选中文本翻译成目标语言，并尽量保持原意与语气。", "Translate the selected text into the target language while preserving meaning and tone."),
                    whenToUse: nil,
                    notFor: nil
                ),
                input: SkillInput(
                    supportedContexts: [.selectedText, .screenshotRegion, .imageCapture],
                    preferredContentTypes: [.text, .image],
                    minLength: 1,
                    maxLength: 12000,
                    requiresNonemptySelection: true
                ),
                routing: SkillRouting(
                    intentHints: ["translation", "foreign_text", "quick_language_switch"],
                    contentHints: ["foreign_text", "mixed_language", "long_foreign_text"],
                    priorityRules: [
                        "foreign_text": 0.96,
                        "mixed_language": 0.74,
                        "technical_paragraph": 0.32,
                        "chat_message": 0.12
                    ],
                    fallbackRank: 1,
                    replaceSelectionBonus: 0.04
                ),
                execution: SkillExecution(
                    mode: .promptOnly,
                    tools: [.llmChat],
                    streaming: true,
                    supportsFollowup: false,
                    safeToInterrupt: true,
                    instructionFile: "instruction.md"
                ),
                result: SkillResultContract(
                    type: .plainTextWithReplace,
                    supportsCopy: true,
                    supportsReplace: true,
                    supportsOpenPrimary: false,
                    supportsWriteback: false,
                    supportsRegenerate: true,
                    supportsFooter: true,
                    supportsActionCards: false
                ),
                lifecycle: SkillLifecycle(
                    showLoadingInResultWindow: true,
                    hideStatusOnFirstDelta: true,
                    revealFooterAfterCompletion: true,
                    deferSupplementsUntilContentComplete: true
                ),
                metadata: SkillMetadata(
                    category: "language",
                    tags: ["language", "translation"],
                    experimental: false,
                    builtIn: true
                )
            )
        case .trace:
            return SkillManifest(
                schemaVersion: "0.1",
                id: "trace",
                name: text("深度溯源", "Source Lookup"),
                version: "0.1.0",
                author: nil,
                homepage: nil,
                license: nil,
                display: SkillDisplay(
                    toolbarTitle: text("溯源", "Source"),
                    settingsTitle: text("启用溯源动作", "Enable Source"),
                    resultTitle: text("溯源结果", "Source Result"),
                    icon: "network",
                    category: "research",
                    priorityTier: .recommended
                ),
                description: SkillDescription(
                    summary: text("理解用户意图，找到最值得直接打开的官方入口、体验页或原始来源。", "Understand intent and find the most relevant official entry, experience page, or original source to open directly."),
                    whenToUse: nil,
                    notFor: nil
                ),
                input: SkillInput(
                    supportedContexts: [.selectedText, .screenshotRegion, .imageCapture],
                    preferredContentTypes: [.text, .image],
                    minLength: 1,
                    maxLength: 12000,
                    requiresNonemptySelection: true
                ),
                routing: SkillRouting(
                    intentHints: ["product_lookup", "official_source", "experience_entry", "documentation"],
                    contentHints: ["product_or_model_mention", "news_or_announcement", "documentation_query", "feature_or_api_lookup"],
                    priorityRules: [
                        "product_or_model_mention": 0.92,
                        "news_or_announcement": 0.96,
                        "documentation_query": 0.81,
                        "feature_or_api_lookup": 0.79,
                        "chat_message": 0.08
                    ],
                    fallbackRank: 2
                ),
                execution: SkillExecution(
                    mode: .toolAugmented,
                    tools: [.webSearch, .pageFetch, .sourceRank, .llmChat],
                    streaming: true,
                    supportsFollowup: false,
                    safeToInterrupt: true,
                    instructionFile: "instruction.md"
                ),
                result: SkillResultContract(
                    type: .summaryWithCards,
                    supportsCopy: true,
                    supportsReplace: false,
                    supportsOpenPrimary: true,
                    supportsWriteback: false,
                    supportsRegenerate: true,
                    supportsFooter: true,
                    supportsActionCards: false
                ),
                lifecycle: SkillLifecycle(
                    showLoadingInResultWindow: true,
                    hideStatusOnFirstDelta: true,
                    revealFooterAfterCompletion: true,
                    deferSupplementsUntilContentComplete: true
                ),
                metadata: SkillMetadata(
                    category: "research",
                    tags: ["research", "entry", "official"],
                    experimental: false,
                    builtIn: true
                )
            )
        case .explain:
            return SkillManifest(
                schemaVersion: "0.1",
                id: "explain",
                name: text("内容解释", "Text Explanation"),
                version: "0.1.0",
                author: nil,
                homepage: nil,
                license: nil,
                display: SkillDisplay(
                    toolbarTitle: text("解释", "Explain"),
                    settingsTitle: text("启用解释动作", "Enable Explain"),
                    resultTitle: text("解释结果", "Explanation"),
                    icon: "text.magnifyingglass",
                    category: "understanding",
                    priorityTier: .recommended
                ),
                description: SkillDescription(
                    summary: text("用简短自然的话解释选中文本是什么、为什么重要。", "Explain what the selected text is and why it matters in concise, natural language."),
                    whenToUse: nil,
                    notFor: nil
                ),
                input: SkillInput(
                    supportedContexts: [.selectedText, .screenshotRegion, .imageCapture],
                    preferredContentTypes: [.text, .image],
                    minLength: 1,
                    maxLength: 6000,
                    requiresNonemptySelection: true
                ),
                routing: SkillRouting(
                    intentHints: ["definition", "explanation", "concept_understanding"],
                    contentHints: ["unclear_term", "product_or_model_mention", "technical_paragraph"],
                    priorityRules: [
                        "unclear_term": 0.95,
                        "product_or_model_mention": 0.72,
                        "technical_paragraph": 0.74,
                        "chat_message": 0.22,
                        "foreign_text": 0.48
                    ],
                    fallbackRank: 3
                ),
                execution: SkillExecution(
                    mode: .promptOnly,
                    tools: [.llmChat],
                    streaming: true,
                    supportsFollowup: false,
                    safeToInterrupt: true,
                    instructionFile: "instruction.md"
                ),
                result: SkillResultContract(
                    type: .summaryText,
                    supportsCopy: true,
                    supportsReplace: false,
                    supportsOpenPrimary: false,
                    supportsWriteback: false,
                    supportsRegenerate: true,
                    supportsFooter: true,
                    supportsActionCards: false
                ),
                lifecycle: SkillLifecycle(
                    showLoadingInResultWindow: true,
                    hideStatusOnFirstDelta: true,
                    revealFooterAfterCompletion: false,
                    deferSupplementsUntilContentComplete: true
                ),
                metadata: SkillMetadata(
                    category: "understanding",
                    tags: ["understanding", "definition"],
                    experimental: false,
                    builtIn: true
                )
            )
        case .reply:
            return SkillManifest(
                schemaVersion: "0.1",
                id: "reply",
                name: text("高情商回复", "Smart Reply"),
                version: "0.1.0",
                author: nil,
                homepage: nil,
                license: nil,
                display: SkillDisplay(
                    toolbarTitle: text("回复", "Reply"),
                    settingsTitle: text("启用高情商回复动作", "Enable Reply"),
                    resultTitle: text("高情商回复", "Reply Draft"),
                    icon: "bubble.left.and.text.bubble.right",
                    category: "communication",
                    priorityTier: .recommended
                ),
                description: SkillDescription(
                    summary: text("基于选中文本和知识库资料生成可直接发送的自然回复。", "Generate a natural reply you can send directly from the selected text and knowledge base context."),
                    whenToUse: nil,
                    notFor: nil
                ),
                input: SkillInput(
                    supportedContexts: [.selectedText, .screenshotRegion, .imageCapture],
                    preferredContentTypes: [.text, .image],
                    minLength: 1,
                    maxLength: 8000,
                    requiresNonemptySelection: true
                ),
                routing: SkillRouting(
                    intentHints: ["reply", "chat_response", "feedback_reply"],
                    contentHints: ["chat_message", "feedback_request", "long_quote"],
                    priorityRules: [
                        "chat_message": 0.97,
                        "feedback_request": 0.91,
                        "long_quote": 0.74,
                        "foreign_text": 0.08,
                        "product_or_model_mention": 0.12
                    ],
                    fallbackRank: 4,
                    requiresMessageWriteback: true,
                    messageWritebackBonus: 0.34
                ),
                execution: SkillExecution(
                    mode: .promptOnly,
                    tools: [.llmChat],
                    streaming: true,
                    supportsFollowup: false,
                    safeToInterrupt: true,
                    instructionFile: "instruction.md"
                ),
                result: SkillResultContract(
                    type: .responseText,
                    supportsCopy: true,
                    supportsReplace: false,
                    supportsOpenPrimary: false,
                    supportsWriteback: true,
                    supportsRegenerate: true,
                    supportsFooter: true,
                    supportsActionCards: true
                ),
                lifecycle: SkillLifecycle(
                    showLoadingInResultWindow: true,
                    hideStatusOnFirstDelta: true,
                    revealFooterAfterCompletion: true,
                    deferSupplementsUntilContentComplete: true
                ),
                metadata: SkillMetadata(
                    category: "communication",
                    tags: ["communication", "reply"],
                    experimental: false,
                    builtIn: true
                )
            )
        case .schedule:
            return SkillManifest(
                schemaVersion: "0.1",
                id: "schedule",
                name: text("日程提醒", "Schedule Reminder"),
                version: "0.1.0",
                author: nil,
                homepage: nil,
                license: nil,
                display: SkillDisplay(
                    toolbarTitle: text("日程", "Schedule"),
                    settingsTitle: text("启用日程动作", "Enable Schedule"),
                    resultTitle: text("日程提醒", "Schedule Reminder"),
                    icon: "calendar.badge.plus",
                    category: "productivity",
                    priorityTier: .recommended
                ),
                description: SkillDescription(
                    summary: text("从选中文本中识别时间意图，一键创建日历提醒。", "Detect time intent from the selected text and create a calendar reminder in one step."),
                    whenToUse: nil,
                    notFor: nil
                ),
                input: SkillInput(
                    supportedContexts: [.selectedText, .screenshotRegion, .imageCapture],
                    preferredContentTypes: [.text, .image],
                    minLength: 2,
                    maxLength: 4000,
                    requiresNonemptySelection: true
                ),
                routing: SkillRouting(
                    intentHints: ["schedule", "reminder", "deadline", "meeting", "appointment"],
                    contentHints: ["time_reference", "schedule_intent", "deadline_mention"],
                    priorityRules: [
                        "time_reference": 0.96,
                        "schedule_intent": 0.94,
                        "deadline_mention": 0.92,
                        "chat_message": 0.38,
                        "foreign_text": 0.04
                    ],
                    fallbackRank: 5,
                    requiredContentCategories: ["time_reference"]
                ),
                execution: SkillExecution(
                    mode: .promptOnly,
                    tools: [.llmChat],
                    streaming: true,
                    supportsFollowup: false,
                    safeToInterrupt: true,
                    instructionFile: "instruction.md"
                ),
                result: SkillResultContract(
                    type: .summaryWithCards,
                    supportsCopy: false,
                    supportsReplace: false,
                    supportsOpenPrimary: false,
                    supportsWriteback: false,
                    supportsRegenerate: true,
                    supportsFooter: true,
                    supportsActionCards: true
                ),
                lifecycle: SkillLifecycle(
                    showLoadingInResultWindow: true,
                    hideStatusOnFirstDelta: true,
                    revealFooterAfterCompletion: false,
                    deferSupplementsUntilContentComplete: false
                ),
                metadata: SkillMetadata(
                    category: "productivity",
                    tags: ["productivity", "calendar", "reminder", "schedule"],
                    experimental: false,
                    builtIn: true
                )
            )
        case .collect:
            return SkillManifest(
                schemaVersion: "0.1",
                id: "collect",
                name: text("知识采集", "Knowledge Capture"),
                version: "0.1.0",
                author: nil,
                homepage: nil,
                license: nil,
                display: SkillDisplay(
                    toolbarTitle: text("采集", "Collect"),
                    settingsTitle: text("启用采集动作", "Enable Collect"),
                    resultTitle: text("采集结果", "Collected"),
                    icon: "tray.and.arrow.down",
                    category: "knowledge",
                    priorityTier: .secondary
                ),
                description: SkillDescription(
                    summary: text("把当前链接或文件采集到本地知识库，便于后续检索和引用。", "Collect the current link or file into the local knowledge base for later retrieval and reuse."),
                    whenToUse: nil,
                    notFor: nil
                ),
                input: SkillInput(
                    supportedContexts: [.selectedText, .fileSelection, .screenshotRegion, .imageCapture],
                    preferredContentTypes: [.text, .file, .image],
                    minLength: 1,
                    maxLength: 12000,
                    requiresNonemptySelection: true
                ),
                routing: SkillRouting(
                    intentHints: ["collect", "archive_reference", "save_to_knowledge_base", "knowledge_ingest"],
                    contentHints: ["standalone_url", "embedded_url", "file_selection"],
                    priorityRules: [
                        "standalone_url": 0.97,
                        "embedded_url": 0.91,
                        "file_selection": 0.95,
                        "image_file": 0.14
                    ],
                    fallbackRank: 7,
                    requiredContentCategories: ["standalone_url", "embedded_url", "file_selection", "image_file"]
                ),
                execution: SkillExecution(
                    mode: .localOnly,
                    tools: [],
                    streaming: false,
                    supportsFollowup: false,
                    safeToInterrupt: true,
                    instructionFile: "instruction.md"
                ),
                result: SkillResultContract(
                    type: .summaryWithCards,
                    supportsCopy: false,
                    supportsReplace: false,
                    supportsOpenPrimary: false,
                    supportsWriteback: false,
                    supportsRegenerate: false,
                    supportsFooter: false,
                    supportsActionCards: false
                ),
                lifecycle: SkillLifecycle(
                    showLoadingInResultWindow: true,
                    hideStatusOnFirstDelta: true,
                    revealFooterAfterCompletion: false,
                    deferSupplementsUntilContentComplete: true
                ),
                metadata: SkillMetadata(
                    category: "knowledge",
                    tags: ["knowledge", "collect", "archive"],
                    experimental: false,
                    builtIn: true
                )
            )
        case .compress:
            return SkillManifest(
                schemaVersion: "0.1",
                id: "compress",
                name: text("无损压缩", "File Compression"),
                version: "0.1.0",
                author: nil,
                homepage: nil,
                license: nil,
                display: SkillDisplay(
                    toolbarTitle: text("压缩", "Compress"),
                    settingsTitle: text("启用压缩动作", "Enable Compress"),
                    resultTitle: text("文件压缩", "Compression Result"),
                    icon: "archivebox",
                    category: "files",
                    priorityTier: .recommended
                ),
                description: SkillDescription(
                    summary: text("压缩选中的文件，按类型调用对应压缩工具并输出到统一目录。", "Compress selected files with the appropriate tool for each type and save them to a unified output location."),
                    whenToUse: nil,
                    notFor: nil
                ),
                input: SkillInput(
                    supportedContexts: [.fileSelection],
                    preferredContentTypes: [.file],
                    minLength: nil,
                    maxLength: nil,
                    requiresNonemptySelection: true
                ),
                routing: SkillRouting(
                    intentHints: ["compress", "file_compress", "image_compress", "pdf_compress"],
                    contentHints: ["image_file", "file_selection"],
                    priorityRules: [
                        "image_file": 0.99,
                        "file_selection": 0.76,
                        "image_capture": 0.95
                    ],
                    fallbackRank: 6
                ),
                execution: SkillExecution(
                    mode: .toolAugmented,
                    tools: [.imageCompress, .pdfCompress],
                    streaming: true,
                    supportsFollowup: false,
                    safeToInterrupt: true,
                    instructionFile: "instruction.md"
                ),
                result: SkillResultContract(
                    type: .summaryWithCards,
                    supportsCopy: false,
                    supportsReplace: false,
                    supportsOpenPrimary: false,
                    supportsWriteback: false,
                    supportsRegenerate: false,
                    supportsFooter: false,
                    supportsActionCards: true
                ),
                lifecycle: SkillLifecycle(
                    showLoadingInResultWindow: true,
                    hideStatusOnFirstDelta: false,
                    revealFooterAfterCompletion: false,
                    deferSupplementsUntilContentComplete: false
                ),
                metadata: SkillMetadata(
                    category: "files",
                    tags: ["files", "compression", "batch"],
                    experimental: true,
                    builtIn: true
                )
            )
        case .screenshotOCR:
            return SkillManifest(
                schemaVersion: "0.1",
                id: "screenshot_ocr",
                name: text("文字识别", "Text Recognition"),
                version: "0.1.0",
                author: nil,
                homepage: nil,
                license: nil,
                display: SkillDisplay(
                    toolbarTitle: "OCR",
                    settingsTitle: nil,
                    resultTitle: text("OCR 结果", "OCR Result"),
                    icon: "text.viewfinder",
                    category: "image",
                    priorityTier: .anchor
                ),
                description: SkillDescription(
                    summary: text("识别当前截图中的文字，并输出可复制文本。", "Recognize text in the current screenshot and return copyable output."),
                    whenToUse: nil,
                    notFor: nil
                ),
                input: SkillInput(
                    supportedContexts: [.screenshotRegion, .imageCapture],
                    preferredContentTypes: [.image],
                    minLength: nil,
                    maxLength: nil,
                    requiresNonemptySelection: true
                ),
                routing: SkillRouting(
                    intentHints: ["ocr", "text_recognition", "extract_text", "image_ocr"],
                    contentHints: ["image_capture", "image_file"],
                    priorityRules: [
                        "image_capture": 0.99,
                        "image_file": 0.94
                    ],
                    fallbackRank: 0
                ),
                execution: SkillExecution(
                    mode: .localOnly,
                    tools: [],
                    streaming: false,
                    supportsFollowup: false,
                    safeToInterrupt: true,
                    instructionFile: "instruction.md"
                ),
                result: SkillResultContract(
                    type: .plainText,
                    supportsCopy: true,
                    supportsReplace: false,
                    supportsOpenPrimary: false,
                    supportsWriteback: false,
                    supportsRegenerate: false,
                    supportsFooter: true,
                    supportsActionCards: false
                ),
                lifecycle: SkillLifecycle(
                    showLoadingInResultWindow: true,
                    hideStatusOnFirstDelta: true,
                    revealFooterAfterCompletion: true,
                    deferSupplementsUntilContentComplete: true
                ),
                metadata: SkillMetadata(
                    category: "image",
                    tags: ["image", "ocr", "text", "screenshot"],
                    experimental: false,
                    builtIn: true
                )
            )
        case .screenshotSave:
            return SkillManifest(
                schemaVersion: "0.1",
                id: "screenshot_save",
                name: text("截图保存", "Save Screenshot"),
                version: "0.1.0",
                author: nil,
                homepage: nil,
                license: nil,
                display: SkillDisplay(
                    toolbarTitle: text("保存", "Save"),
                    settingsTitle: nil,
                    resultTitle: text("截图保存", "Screenshot Saved"),
                    icon: "square.and.arrow.down",
                    category: "image",
                    priorityTier: .hidden
                ),
                description: SkillDescription(
                    summary: text("保存当前截图到桌面目录。", "Save the current screenshot to the desktop."),
                    whenToUse: nil,
                    notFor: nil
                ),
                input: SkillInput(
                    supportedContexts: [.screenshotRegion, .imageCapture],
                    preferredContentTypes: [.image],
                    minLength: nil,
                    maxLength: nil,
                    requiresNonemptySelection: true
                ),
                routing: SkillRouting(
                    intentHints: ["save", "screenshot_save", "capture_save"],
                    contentHints: ["image_capture"],
                    priorityRules: [
                        "image_capture": 0.98,
                        "image_file": 0.72
                    ],
                    fallbackRank: 1
                ),
                execution: SkillExecution(
                    mode: .localOnly,
                    tools: [],
                    streaming: false,
                    supportsFollowup: false,
                    safeToInterrupt: true,
                    instructionFile: "instruction.md"
                ),
                result: SkillResultContract(
                    type: .plainText,
                    supportsCopy: false,
                    supportsReplace: false,
                    supportsOpenPrimary: false,
                    supportsWriteback: false,
                    supportsRegenerate: false,
                    supportsFooter: false,
                    supportsActionCards: false
                ),
                lifecycle: SkillLifecycle(
                    showLoadingInResultWindow: false,
                    hideStatusOnFirstDelta: true,
                    revealFooterAfterCompletion: false,
                    deferSupplementsUntilContentComplete: true
                ),
                metadata: SkillMetadata(
                    category: "image",
                    tags: ["image", "screenshot", "save"],
                    experimental: false,
                    builtIn: true
                )
            )
        }
    }
}
