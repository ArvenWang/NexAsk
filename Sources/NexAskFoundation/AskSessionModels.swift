import AppKit
import Foundation

package enum AskMessageRole: String, Codable {
    case system
    case user
    case assistant
    case info
}

package struct AskMessage: Codable, Equatable {
    package let role: AskMessageRole
    package let content: String

    package init(role: AskMessageRole, content: String) {
        self.role = role
        self.content = content
    }
}

package struct AskSessionMetadata: Equatable {
    package let sessionID: String
    package let sourceBundleID: String?
    package let sourceAppName: String?
    package let frame: NSRect
    package let sessionOrigin: AskSessionOrigin
    package let automationJobID: String?
    package let automationPolicy: AskAutomationPolicy?
    package let invocationSurface: AskInvocationSurface
    package let requestedMode: AskExecutionMode?
    package let kernelMetadata: [String: String]

    package init(
        sessionID: String,
        sourceBundleID: String?,
        sourceAppName: String?,
        frame: NSRect,
        sessionOrigin: AskSessionOrigin = .user,
        automationJobID: String? = nil,
        automationPolicy: AskAutomationPolicy? = nil,
        invocationSurface: AskInvocationSurface? = nil,
        requestedMode: AskExecutionMode? = nil,
        kernelMetadata: [String: String] = [:]
    ) {
        self.sessionID = sessionID
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.frame = frame
        self.sessionOrigin = sessionOrigin
        self.automationJobID = automationJobID
        self.automationPolicy = automationPolicy
        self.invocationSurface = invocationSurface ?? AskSessionMetadata.defaultSurface(for: sessionOrigin)
        self.requestedMode = requestedMode
        self.kernelMetadata = kernelMetadata
    }

    private static func defaultSurface(for sessionOrigin: AskSessionOrigin) -> AskInvocationSurface {
        switch sessionOrigin {
        case .user:
            return .askWindow
        case .automation:
            return .automation
        case .assistantFollowUp:
            return .inbox
        }
    }
}

package struct AskSessionRequest: Equatable {
    package let messages: [AskMessage]
    package let metadata: AskSessionMetadata
    package let uiLanguage: String
    package let responseLanguage: String

    package init(
        messages: [AskMessage],
        metadata: AskSessionMetadata,
        uiLanguage: String,
        responseLanguage: String
    ) {
        self.messages = messages
        self.metadata = metadata
        self.uiLanguage = uiLanguage
        self.responseLanguage = responseLanguage
    }
}

package struct AskSessionState: Equatable {
    package let sessionID: String
    package let sourceBundleID: String?
    package let sourceAppName: String?
    package let sessionOrigin: AskSessionOrigin
    package let invocationSurface: AskInvocationSurface
    package let requestedMode: AskExecutionMode?
    package var messages: [AskMessage]
    package var isStreaming: Bool

    package init(
        sessionID: String,
        sourceBundleID: String?,
        sourceAppName: String?,
        sessionOrigin: AskSessionOrigin,
        invocationSurface: AskInvocationSurface,
        requestedMode: AskExecutionMode?,
        messages: [AskMessage],
        isStreaming: Bool
    ) {
        self.sessionID = sessionID
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.sessionOrigin = sessionOrigin
        self.invocationSurface = invocationSurface
        self.requestedMode = requestedMode
        self.messages = messages
        self.isStreaming = isStreaming
    }

    package static func make(
        sourceBundleID: String?,
        sourceAppName: String?,
        sessionOrigin: AskSessionOrigin = .user,
        invocationSurface: AskInvocationSurface = .askWindow,
        requestedMode: AskExecutionMode? = nil,
        sessionID: String? = nil
    ) -> AskSessionState {
        AskSessionState(
            sessionID: sessionID ?? UUID().uuidString.lowercased(),
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName,
            sessionOrigin: sessionOrigin,
            invocationSurface: invocationSurface,
            requestedMode: requestedMode,
            messages: [],
            isStreaming: false
        )
    }
}

package enum AskRuntimeStepKind: String, Equatable {
    case planning
    case toolCall
    case awaitingApproval
    case executionResult
    case finalAnswer
}

package enum AskRuntimeStepState: String, Equatable {
    case running
    case waiting
    case completed
    case blocked
    case saved
    case failed
}

package struct AskRuntimeStepEvent: Equatable {
    package let id: String
    package let kind: AskRuntimeStepKind
    package let title: String
    package let detail: String?
    package let state: AskRuntimeStepState
    package let codeBlock: AskRuntimeCodeBlockPreview?

    package init(
        id: String,
        kind: AskRuntimeStepKind,
        title: String,
        detail: String?,
        state: AskRuntimeStepState,
        codeBlock: AskRuntimeCodeBlockPreview? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.state = state
        self.codeBlock = codeBlock
    }
}

package struct AskRuntimeCodeBlockPreview: Equatable {
    package let content: String
    package let languageHint: String?
    package let isStreaming: Bool

    package init(content: String, languageHint: String?, isStreaming: Bool) {
        self.content = content
        self.languageHint = languageHint
        self.isStreaming = isStreaming
    }
}
