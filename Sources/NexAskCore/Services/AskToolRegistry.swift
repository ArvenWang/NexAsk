import Foundation
import NexShared

struct AskToolPoolContext {
    let responseLanguage: String
    let sessionID: String?
    let sessionOrigin: AskSessionOrigin?
    let requestedMode: AskExecutionMode?
    let planModeActive: Bool
    let activeWorkspaceRoot: String?
    let kernelMetadata: [String: String]

    static func minimal(responseLanguage: String) -> AskToolPoolContext {
        AskToolPoolContext(
            responseLanguage: responseLanguage,
            sessionID: nil,
            sessionOrigin: nil,
            requestedMode: nil,
            planModeActive: false,
            activeWorkspaceRoot: nil,
            kernelMetadata: [:]
        )
    }

    static func session(
        responseLanguage: String,
        sessionState: AskAgentSessionState
    ) -> AskToolPoolContext {
        AskToolPoolContext(
            responseLanguage: responseLanguage,
            sessionID: sessionState.sessionID,
            sessionOrigin: sessionState.sessionOrigin,
            requestedMode: nil,
            planModeActive: sessionState.planModeActive,
            activeWorkspaceRoot: sessionState.activeTaskWorkspaceRoot
                ?? sessionState.kernelMetadata["workspace_root"],
            kernelMetadata: sessionState.kernelMetadata
        )
    }
}

protocol AskToolProviding {
    func availableTools(context: AskToolPoolContext) -> [AskToolDefinition]
}

extension AskToolProviding {
    func availableTools(responseLanguage: String) -> [AskToolDefinition] {
        availableTools(context: .minimal(responseLanguage: responseLanguage))
    }
}

struct AskToolRegistry: AskToolProviding {
    private let providers: [AskToolProviding]

    init(providers: [AskToolProviding]) {
        self.providers = providers
    }

    func availableTools(context: AskToolPoolContext) -> [AskToolDefinition] {
        var seenNames: Set<String> = []
        var merged: [AskToolDefinition] = []

        for provider in providers {
            for tool in provider.availableTools(context: context) where seenNames.insert(tool.name).inserted {
                merged.append(tool)
            }
        }

        return merged
    }

    func availableTools(responseLanguage: String) -> [AskToolDefinition] {
        availableTools(context: .minimal(responseLanguage: responseLanguage))
    }
}
