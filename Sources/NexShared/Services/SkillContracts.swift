import Foundation

enum ToolCapabilityID: String, CaseIterable, Codable {
    case llmChat = "llm_chat"
    case webSearch = "web_search"
    case pageFetch = "page_fetch"
    case sourceRank = "source_rank"
    case imageCompress = "image_compress"
    case pdfCompress = "pdf_compress"
}

enum SkillPriorityTier: String, Codable {
    case anchor
    case recommended
    case secondary
    case hidden
}

enum SkillStage: String, Codable {
    case local
    case cloud
}

enum SkillBillingClass: String, Codable {
    case free
    case proIncluded = "pro_included"
    case usageMetered = "usage_metered"
    case enterpriseOnly = "enterprise_only"
}

enum SkillEntitlementTier: String, Codable {
    case free
    case pro
}

enum SkillExecutionMode: String, Codable {
    case promptOnly = "prompt_only"
    case toolAugmented = "tool_augmented"
    case localThenModel = "local_then_model"
    case localOnly = "local_only"
}

enum SkillExecutionLocality: String, Codable {
    case localOnly = "local_only"
    case localFirst = "local_first"
    case hybrid
    case cloudOnly = "cloud_only"
}

enum SkillDistributionChannel: String, Codable {
    case bundled
    case officialStore = "official_store"
    case sideloaded
}

enum SkillPermissionKind: String, Codable, CaseIterable {
    case readSelectedText = "read_selected_text"
    case readSelectedFiles = "read_selected_files"
    case readScreenshotImage = "read_screenshot_image"
    case writeClipboard = "write_clipboard"
    case writeFiles = "write_files"
    case useCloudExecution = "use_cloud_execution"
    case accessWeb = "access_web"
}

package enum SkillResultType: String, Codable {
    case plainText = "plain_text"
    case plainTextWithReplace = "plain_text_with_replace"
    case summaryText = "summary_text"
    case summaryWithCards = "summary_with_cards"
    case responseText = "response_text"
    case structuredExtract = "structured_extract"
}

enum ActivationSource: String, Codable {
    case selectedText = "selected_text"
    case clipboardText = "clipboard_text"
    case fileSelection = "file_selection"
    case screenshotRegion = "screenshot_region"
    case imageCapture = "image_capture"
    case url
    case inputBoxContext = "input_box_context"
    case mixedContext = "mixed_context"
}

enum ActivationContentType: String, Codable {
    case text
    case file
    case image
    case url
    case mixed
}

struct ActivationContextRaw: Codable {
    let text: String?
    let filePaths: [String]?
    let selectionLength: Int?
    let fileCount: Int?
    let directoryCount: Int?
    let totalByteCount: Int64?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let recognizedTextLength: Int?
    let ocrLineCount: Int?
    let hasAnnotations: Bool?
    let isScrollingCapture: Bool?

    init(
        text: String?,
        filePaths: [String]?,
        selectionLength: Int? = nil,
        fileCount: Int? = nil,
        directoryCount: Int? = nil,
        totalByteCount: Int64? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        recognizedTextLength: Int? = nil,
        ocrLineCount: Int? = nil,
        hasAnnotations: Bool? = nil,
        isScrollingCapture: Bool? = nil
    ) {
        self.text = text
        self.filePaths = filePaths
        self.selectionLength = selectionLength
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.totalByteCount = totalByteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.recognizedTextLength = recognizedTextLength
        self.ocrLineCount = ocrLineCount
        self.hasAnnotations = hasAnnotations
        self.isScrollingCapture = isScrollingCapture
    }

    enum CodingKeys: String, CodingKey {
        case text
        case filePaths = "file_paths"
        case selectionLength = "selection_length"
        case fileCount = "file_count"
        case directoryCount = "directory_count"
        case totalByteCount = "total_byte_count"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case recognizedTextLength = "recognized_text_length"
        case ocrLineCount = "ocr_line_count"
        case hasAnnotations = "has_annotations"
        case isScrollingCapture = "is_scrolling_capture"
    }
}

struct ActivationArtifactDetails: Codable, Equatable {
    let selectionLength: Int?
    let fileCount: Int?
    let directoryCount: Int?
    let totalByteCount: Int64?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let recognizedTextLength: Int?
    let ocrLineCount: Int?
    let hasAnnotations: Bool?
    let isScrollingCapture: Bool?

    init(
        selectionLength: Int? = nil,
        fileCount: Int? = nil,
        directoryCount: Int? = nil,
        totalByteCount: Int64? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        recognizedTextLength: Int? = nil,
        ocrLineCount: Int? = nil,
        hasAnnotations: Bool? = nil,
        isScrollingCapture: Bool? = nil
    ) {
        self.selectionLength = selectionLength
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.totalByteCount = totalByteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.recognizedTextLength = recognizedTextLength
        self.ocrLineCount = ocrLineCount
        self.hasAnnotations = hasAnnotations
        self.isScrollingCapture = isScrollingCapture
    }
}

struct ActivationContextMetadata: Codable {
    let bundleID: String?
    let appName: String?
    let timestamp: String
    let artifact: ActivationArtifactDetails?

    init(
        bundleID: String?,
        appName: String?,
        timestamp: String,
        artifact: ActivationArtifactDetails? = nil
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.timestamp = timestamp
        self.artifact = artifact
    }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case appName = "app_name"
        case timestamp
        case artifact
    }
}

struct ActivationContext: Codable {
    let id: String
    let source: ActivationSource
    let contentType: ActivationContentType
    let raw: ActivationContextRaw
    let metadata: ActivationContextMetadata

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case contentType = "content_type"
        case raw
        case metadata
    }

    var text: String {
        if let text = raw.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        let fileNames = raw.filePaths?
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .filter { !$0.isEmpty } ?? []
        return fileNames.joined(separator: "\n")
    }
}

struct SkillDisplay: Codable {
    let toolbarTitle: String
    let settingsTitle: String?
    let resultTitle: String
    let icon: String
    let category: String?
    let priorityTier: SkillPriorityTier?

    enum CodingKeys: String, CodingKey {
        case toolbarTitle = "toolbar_title"
        case settingsTitle = "settings_title"
        case resultTitle = "result_title"
        case icon
        case category
        case priorityTier = "priority_tier"
    }
}

struct SkillDescription: Codable {
    let summary: String
    let whenToUse: [String]?
    let notFor: [String]?

    enum CodingKeys: String, CodingKey {
        case summary
        case whenToUse = "when_to_use"
        case notFor = "not_for"
    }
}

struct SkillInput: Codable {
    let supportedContexts: [ActivationSource]
    let preferredContentTypes: [ActivationContentType]?
    let minLength: Int?
    let maxLength: Int?
    let requiresNonemptySelection: Bool?

    enum CodingKeys: String, CodingKey {
        case supportedContexts = "supported_contexts"
        case preferredContentTypes = "preferred_content_types"
        case minLength = "min_length"
        case maxLength = "max_length"
        case requiresNonemptySelection = "requires_nonempty_selection"
    }
}

struct SkillRouting: Codable {
    let intentHints: [String]
    let contentHints: [String]?
    let priorityRules: [String: Double]?
    let fallbackRank: Int?
    let requiredContentCategories: [String]?
    let requiresMessageWriteback: Bool?
    let requiresReplaceSelection: Bool?
    let messageWritebackBonus: Double?
    let replaceSelectionBonus: Double?

    init(
        intentHints: [String],
        contentHints: [String]? = nil,
        priorityRules: [String: Double]? = nil,
        fallbackRank: Int? = nil,
        requiredContentCategories: [String]? = nil,
        requiresMessageWriteback: Bool? = nil,
        requiresReplaceSelection: Bool? = nil,
        messageWritebackBonus: Double? = nil,
        replaceSelectionBonus: Double? = nil
    ) {
        self.intentHints = intentHints
        self.contentHints = contentHints
        self.priorityRules = priorityRules
        self.fallbackRank = fallbackRank
        self.requiredContentCategories = requiredContentCategories
        self.requiresMessageWriteback = requiresMessageWriteback
        self.requiresReplaceSelection = requiresReplaceSelection
        self.messageWritebackBonus = messageWritebackBonus
        self.replaceSelectionBonus = replaceSelectionBonus
    }

    enum CodingKeys: String, CodingKey {
        case intentHints = "intent_hints"
        case contentHints = "content_hints"
        case priorityRules = "priority_rules"
        case fallbackRank = "fallback_rank"
        case requiredContentCategories = "required_content_categories"
        case requiresMessageWriteback = "requires_message_writeback"
        case requiresReplaceSelection = "requires_replace_selection"
        case messageWritebackBonus = "message_writeback_bonus"
        case replaceSelectionBonus = "replace_selection_bonus"
    }
}

struct SkillExecution: Codable {
    let mode: SkillExecutionMode
    let locality: SkillExecutionLocality?
    let tools: [ToolCapabilityID]
    let knowledgeBase: SkillKnowledgeBaseContract?
    let streaming: Bool?
    let supportsFollowup: Bool?
    let safeToInterrupt: Bool?
    let instructionFile: String?

    init(
        mode: SkillExecutionMode,
        locality: SkillExecutionLocality? = nil,
        tools: [ToolCapabilityID],
        knowledgeBase: SkillKnowledgeBaseContract? = nil,
        streaming: Bool? = nil,
        supportsFollowup: Bool? = nil,
        safeToInterrupt: Bool? = nil,
        instructionFile: String? = nil
    ) {
        self.mode = mode
        self.locality = locality
        self.tools = tools
        self.knowledgeBase = knowledgeBase
        self.streaming = streaming
        self.supportsFollowup = supportsFollowup
        self.safeToInterrupt = safeToInterrupt
        self.instructionFile = instructionFile
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case locality
        case tools
        case knowledgeBase = "knowledge_base"
        case streaming
        case supportsFollowup = "supports_followup"
        case safeToInterrupt = "safe_to_interrupt"
        case instructionFile = "instruction_file"
    }
}

struct SkillKnowledgeBaseContract: Codable {
    let enabled: Bool
    let maxMatches: Int?
    let includeSourceCards: Bool?

    init(
        enabled: Bool = true,
        maxMatches: Int? = nil,
        includeSourceCards: Bool? = nil
    ) {
        self.enabled = enabled
        self.maxMatches = maxMatches
        self.includeSourceCards = includeSourceCards
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case maxMatches = "max_matches"
        case includeSourceCards = "include_source_cards"
    }
}

struct SkillResultContract: Codable {
    let type: SkillResultType
    let supportsCopy: Bool?
    let supportsReplace: Bool?
    let supportsOpenPrimary: Bool?
    let supportsWriteback: Bool?
    let supportsRegenerate: Bool?
    let supportsFooter: Bool?
    let supportsActionCards: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case supportsCopy = "supports_copy"
        case supportsReplace = "supports_replace"
        case supportsOpenPrimary = "supports_open_primary"
        case supportsWriteback = "supports_writeback"
        case supportsRegenerate = "supports_regenerate"
        case supportsFooter = "supports_footer"
        case supportsActionCards = "supports_action_cards"
    }
}

struct SkillLifecycle: Codable {
    let showLoadingInResultWindow: Bool?
    let hideStatusOnFirstDelta: Bool?
    let revealFooterAfterCompletion: Bool?
    let deferSupplementsUntilContentComplete: Bool?

    enum CodingKeys: String, CodingKey {
        case showLoadingInResultWindow = "show_loading_in_result_window"
        case hideStatusOnFirstDelta = "hide_status_on_first_delta"
        case revealFooterAfterCompletion = "reveal_footer_after_completion"
        case deferSupplementsUntilContentComplete = "defer_supplements_until_content_complete"
    }
}

struct SkillMetadata: Codable {
    let category: String?
    let tags: [String]?
    let experimental: Bool?
    let builtIn: Bool?
    let stage: SkillStage?

    init(
        category: String? = nil,
        tags: [String]? = nil,
        experimental: Bool? = nil,
        builtIn: Bool? = nil,
        stage: SkillStage? = nil
    ) {
        self.category = category
        self.tags = tags
        self.experimental = experimental
        self.builtIn = builtIn
        self.stage = stage
    }

    enum CodingKeys: String, CodingKey {
        case category
        case tags
        case experimental
        case builtIn = "built_in"
        case stage
    }
}

struct SkillSettingsContract: Codable {
    let title: String?
    let defaultEnabled: Bool?
    let userConfigurable: Bool?
    let stage: SkillStage?

    enum CodingKeys: String, CodingKey {
        case title
        case defaultEnabled = "default_enabled"
        case userConfigurable = "user_configurable"
        case stage
    }
}

struct SkillBillingContract: Codable {
    let billingClass: SkillBillingClass
    let requiredTier: SkillEntitlementTier?

    enum CodingKeys: String, CodingKey {
        case billingClass = "class"
        case requiredTier = "required_tier"
    }
}

struct SkillDistributionContract: Codable {
    let channel: SkillDistributionChannel?
    let vendor: String?
    let packageID: String?
    let signatureRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case channel
        case vendor
        case packageID = "package_id"
        case signatureRequired = "signature_required"
    }
}

struct SkillPermissionContract: Codable {
    let permissions: [SkillPermissionKind]

    init(permissions: [SkillPermissionKind]) {
        self.permissions = permissions
    }
}

struct SkillPrivacyContract: Codable {
    let dataLeavesDevice: Bool?
    let retentionSummary: String?

    enum CodingKeys: String, CodingKey {
        case dataLeavesDevice = "data_leaves_device"
        case retentionSummary = "retention_summary"
    }
}

struct SkillEntitlementsContract: Codable {
    let requiredTier: SkillEntitlementTier?
    let quotaFeature: String?
    let featureFlags: [String]?

    enum CodingKeys: String, CodingKey {
        case requiredTier = "required_tier"
        case quotaFeature = "quota_feature"
        case featureFlags = "feature_flags"
    }
}

struct SkillManifest: Codable {
    let schemaVersion: String
    let id: String
    let name: String
    let version: String?
    let author: String?
    let homepage: String?
    let license: String?
    let display: SkillDisplay
    let description: SkillDescription
    let input: SkillInput
    let routing: SkillRouting
    let execution: SkillExecution
    let result: SkillResultContract
    let lifecycle: SkillLifecycle
    let metadata: SkillMetadata?
    let settings: SkillSettingsContract?
    let billing: SkillBillingContract?
    let distribution: SkillDistributionContract?
    let permissions: SkillPermissionContract?
    let privacy: SkillPrivacyContract?
    let entitlements: SkillEntitlementsContract?

    init(
        schemaVersion: String,
        id: String,
        name: String,
        version: String? = nil,
        author: String? = nil,
        homepage: String? = nil,
        license: String? = nil,
        display: SkillDisplay,
        description: SkillDescription,
        input: SkillInput,
        routing: SkillRouting,
        execution: SkillExecution,
        result: SkillResultContract,
        lifecycle: SkillLifecycle,
        metadata: SkillMetadata? = nil,
        settings: SkillSettingsContract? = nil,
        billing: SkillBillingContract? = nil,
        distribution: SkillDistributionContract? = nil,
        permissions: SkillPermissionContract? = nil,
        privacy: SkillPrivacyContract? = nil,
        entitlements: SkillEntitlementsContract? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.homepage = homepage
        self.license = license
        self.display = display
        self.description = description
        self.input = input
        self.routing = routing
        self.execution = execution
        self.result = result
        self.lifecycle = lifecycle
        self.metadata = metadata
        self.settings = settings
        self.billing = billing
        self.distribution = distribution
        self.permissions = permissions
        self.privacy = privacy
        self.entitlements = entitlements
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case name
        case version
        case author
        case homepage
        case license
        case display
        case description
        case input
        case routing
        case execution
        case result
        case lifecycle
        case metadata
        case settings
        case billing
        case distribution
        case permissions
        case privacy
        case entitlements
    }
}

package enum SkillResultActionType: String, Codable, Equatable {
    case openURL = "open_url"
    case openFile = "open_file"
    case revealInFinder = "reveal_in_finder"
    case showCapturedText = "show_captured_text"
    case copyText = "copy_text"
    case replaceSelection = "replace_selection"
    case createCalendarEvent = "create_calendar_event"
    case createReminder = "create_reminder"
    case none
}

package struct SkillResultAction: Codable, Equatable {
    package let type: SkillResultActionType
    package let label: String
    package let value: String?

    package init(type: SkillResultActionType, label: String, value: String?) {
        self.type = type
        self.label = label
        self.value = value
    }
}

package enum SkillCardPriority: String, Codable, Equatable {
    case primary
    case secondary
    case reference
}

package struct SkillResultCard: Codable, Equatable {
    package let id: String
    package let kind: String
    package let title: String
    package let badges: [String]?
    package let subtitle: String?
    package let description: String?
    package let action: SkillResultAction?
    package let priority: SkillCardPriority?
    package let isOfficial: Bool?

    package init(
        id: String,
        kind: String,
        title: String,
        badges: [String]?,
        subtitle: String?,
        description: String?,
        action: SkillResultAction?,
        priority: SkillCardPriority?,
        isOfficial: Bool?
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.badges = badges
        self.subtitle = subtitle
        self.description = description
        self.action = action
        self.priority = priority
        self.isOfficial = isOfficial
    }

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case badges
        case subtitle
        case description
        case action
        case priority
        case isOfficial = "is_official"
    }
}

struct SkillArtifact: Codable {
    let kind: String
    let items: [[String: String]]?
}

enum SkillFollowupInputSource: String, Codable {
    case currentResult = "current_result"
    case originalSelection = "original_selection"
}

struct SkillFollowupContract: Codable {
    let skillID: String
    let label: String
    let inputSource: SkillFollowupInputSource?
    let maxDepth: Int?
    let sourceSkillID: String?

    init(
        skillID: String,
        label: String,
        inputSource: SkillFollowupInputSource? = nil,
        maxDepth: Int? = nil,
        sourceSkillID: String? = nil
    ) {
        self.skillID = skillID
        self.label = label
        self.inputSource = inputSource
        self.maxDepth = maxDepth
        self.sourceSkillID = sourceSkillID
    }

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case label
        case inputSource = "input_source"
        case maxDepth = "max_depth"
        case sourceSkillID = "source_skill_id"
    }
}

typealias SkillFollowup = SkillFollowupContract

package struct SkillResultEnvelope: Codable {
    let schemaVersion: String
    let skillID: String
    let resultType: SkillResultType
    let summary: String?
    let body: String?
    let primaryAction: SkillResultAction?
    let secondaryActions: [SkillResultAction]?
    let cards: [SkillResultCard]?
    let artifacts: [SkillArtifact]?
    let copyPayload: String?
    let replacePayload: String?
    let followups: [SkillFollowupContract]?
    let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case skillID = "skill_id"
        case resultType = "result_type"
        case summary
        case body
        case primaryAction = "primary_action"
        case secondaryActions = "secondary_actions"
        case cards
        case artifacts
        case copyPayload = "copy_payload"
        case replacePayload = "replace_payload"
        case followups
        case metadata
    }
}

enum SkillRuntimeEventType: String, Codable {
    case status
    case delta
    case supplement
    case done
    case error
}

struct SkillRuntimeEvent: Codable {
    let type: SkillRuntimeEventType
    let status: String?
    let detail: String?
    let delta: String?
    let fullText: String?
    let cards: [SkillResultCard]?
    let artifacts: [SkillArtifact]?
    let result: SkillResultEnvelope?
    let message: String?

    init(
        type: SkillRuntimeEventType,
        status: String? = nil,
        detail: String? = nil,
        delta: String? = nil,
        fullText: String? = nil,
        cards: [SkillResultCard]? = nil,
        artifacts: [SkillArtifact]? = nil,
        result: SkillResultEnvelope? = nil,
        message: String? = nil
    ) {
        self.type = type
        self.status = status
        self.detail = detail
        self.delta = delta
        self.fullText = fullText
        self.cards = cards
        self.artifacts = artifacts
        self.result = result
        self.message = message
    }
}
