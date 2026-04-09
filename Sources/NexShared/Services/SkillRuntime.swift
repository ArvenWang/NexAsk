import Foundation

struct SkillExecutionContext {
    let skillID: String
    let text: String
    let targetLanguage: String
    let responseLanguage: String
    let uiLanguage: String
    let filePaths: [String]
    let followupDepth: Int
    let followupSourceSkillID: String?
    let selectedText: String?
    let selectionContextBefore: String?
    let selectionContextAfter: String?
    let translationMode: String?

    init(
        skillID: String,
        text: String,
        targetLanguage: String,
        responseLanguage: String,
        uiLanguage: String,
        filePaths: [String],
        followupDepth: Int,
        followupSourceSkillID: String?,
        selectedText: String? = nil,
        selectionContextBefore: String? = nil,
        selectionContextAfter: String? = nil,
        translationMode: String? = nil
    ) {
        self.skillID = skillID
        self.text = text
        self.targetLanguage = targetLanguage
        self.responseLanguage = responseLanguage
        self.uiLanguage = uiLanguage
        self.filePaths = filePaths
        self.followupDepth = followupDepth
        self.followupSourceSkillID = followupSourceSkillID
        self.selectedText = selectedText
        self.selectionContextBefore = selectionContextBefore
        self.selectionContextAfter = selectionContextAfter
        self.translationMode = translationMode
    }
}

struct SkillExecutionRequest {
    let definition: SkillDefinition
    let context: SkillExecutionContext
}

final class SkillRunner {
    private let actionRegistry: ActionRegistry
    private let actionService: SkillExecutionService

    init(actionRegistry: ActionRegistry = .shared, actionService: SkillExecutionService = SkillExecutionService()) {
        self.actionRegistry = actionRegistry
        self.actionService = actionService
    }

    func definition(for skillID: String) -> SkillDefinition? {
        actionRegistry.definition(forSkillID: skillID)
    }

    func runStreamingEnvelope(
        skillID: String,
        context: SkillExecutionContext,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async -> Result<SkillResultEnvelope, Error> {
        guard let definition = actionRegistry.definition(forSkillID: skillID) else {
            return .failure(ActionError.network("Unknown skill: \(skillID)"))
        }
        let request = SkillExecutionRequest(definition: definition, context: context)
        return await actionService.runStreamingEnvelope(
            request: request,
            onEvent: onEvent
        )
    }

    func runEnvelope(
        skillID: String,
        context: SkillExecutionContext
    ) async -> Result<SkillResultEnvelope, Error> {
        guard let definition = actionRegistry.definition(forSkillID: skillID) else {
            return .failure(ActionError.network("Unknown skill: \(skillID)"))
        }
        return await actionService.runEnvelope(request: SkillExecutionRequest(definition: definition, context: context))
    }
}
