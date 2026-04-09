import Foundation

struct ResultSessionState {
    var definition: SkillDefinition?
    var sourceText: String?
    var sourceBundleID: String?
    var sourceInteractionContext: SourceInteractionContext
    var replacementTarget: ReplacementTargetSnapshot?
    var metadata: [String: String]
    var footerModel: ResultFooterModel
    var latestReplaceText: String?
    var latestWritebackText: String?
    var latestSourceURL: URL?
    var latestTextToCopy: String

    static let empty = ResultSessionState(
        definition: nil,
        sourceText: nil,
        sourceBundleID: nil,
        sourceInteractionContext: .empty,
        replacementTarget: nil,
        metadata: [:],
        footerModel: ResultFooterModel(resultActions: [], skillFollowups: [], capabilityActions: []),
        latestReplaceText: nil,
        latestWritebackText: nil,
        latestSourceURL: nil,
        latestTextToCopy: ""
    )
}

final class ResultSessionStore {
    private(set) var state = ResultSessionState.empty

    func beginStreaming(
        definition: SkillDefinition,
        sourceText: String,
        sourceBundleID: String?,
        sourceInteractionContext: SourceInteractionContext?,
        replacementTarget: ReplacementTargetSnapshot?,
        keepConversation: Bool
    ) {
        if !keepConversation {
            state = .empty
        }

        state.definition = definition
        state.sourceText = sourceText
        if let sourceBundleID {
            state.sourceBundleID = sourceBundleID
        } else if let interactionBundleID = sourceInteractionContext?.bundleID {
            state.sourceBundleID = interactionBundleID
        } else if !keepConversation {
            state.sourceBundleID = nil
        }
        if let sourceInteractionContext {
            state.sourceInteractionContext = sourceInteractionContext
        } else if !keepConversation {
            state.sourceInteractionContext = .empty
        }
        if let replacementTarget {
            state.replacementTarget = replacementTarget
        } else if !keepConversation {
            state.replacementTarget = nil
        }
        state.metadata = [:]
        state.footerModel = ResultFooterModel(resultActions: [], skillFollowups: [], capabilityActions: [])
        state.latestReplaceText = nil
        state.latestWritebackText = nil
        state.latestSourceURL = nil
        state.latestTextToCopy = ""
    }

    func complete(
        definition: SkillDefinition?,
        metadata: [String: String],
        footerModel: ResultFooterModel,
        latestTextToCopy: String,
        latestReplaceText: String?,
        latestWritebackText: String?,
        latestSourceURL: URL?
    ) {
        if let definition {
            state.definition = definition
        }
        state.metadata = metadata
        state.footerModel = footerModel
        state.latestTextToCopy = latestTextToCopy
        state.latestReplaceText = latestReplaceText
        state.latestWritebackText = latestWritebackText
        state.latestSourceURL = latestSourceURL
    }

    func clear() {
        state = .empty
    }

    func footerActionContext(resolvedFooterSourceText: String?) -> ResultFooterActionContext {
        ResultFooterActionContext(
            definition: state.definition,
            currentSourceText: state.sourceText,
            currentSourceBundleID: state.sourceBundleID,
            currentReplacementTarget: state.replacementTarget,
            currentSourceInteractionContext: state.sourceInteractionContext,
            latestReplaceText: state.latestReplaceText,
            latestWritebackText: state.latestWritebackText,
            latestSourceURL: state.latestSourceURL,
            currentResultMetadata: state.metadata,
            resolvedFooterSourceText: resolvedFooterSourceText
        )
    }
}
