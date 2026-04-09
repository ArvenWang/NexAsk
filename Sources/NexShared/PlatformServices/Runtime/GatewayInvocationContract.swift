import Foundation

struct GatewayInvocationContract: Codable {
    let version: String
    let requestID: String
    let skillID: String
    let activationContext: ActivationContext
    let executionContext: GatewayExecutionContext

    init(
        version: String = "v1",
        requestID: String,
        skillID: String,
        activationContext: ActivationContext,
        executionContext: GatewayExecutionContext
    ) {
        self.version = version
        self.requestID = requestID
        self.skillID = skillID
        self.activationContext = activationContext
        self.executionContext = executionContext
    }

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case skillID = "skill_id"
        case activationContext = "activation_context"
        case executionContext = "execution_context"
    }
}

struct GatewayExecutionContext: Codable {
    let text: String
    let filePaths: [String]
    let targetLanguage: String
    let responseLanguage: String
    let uiLanguage: String
    let followupDepth: Int
    let followupSourceSkillID: String?
    let selectedText: String?
    let selectionContextBefore: String?
    let selectionContextAfter: String?
    let translationMode: String?

    enum CodingKeys: String, CodingKey {
        case text
        case filePaths = "file_paths"
        case targetLanguage = "target_language"
        case responseLanguage = "response_language"
        case uiLanguage = "ui_language"
        case followupDepth = "followup_depth"
        case followupSourceSkillID = "followup_source_skill_id"
        case selectedText = "selected_text"
        case selectionContextBefore = "selection_context_before"
        case selectionContextAfter = "selection_context_after"
        case translationMode = "translation_mode"
    }
}
