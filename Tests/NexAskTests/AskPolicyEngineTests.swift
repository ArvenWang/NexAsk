import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskPolicyEngineTests: XCTestCase {
    func testInteractivePlaygroundWriteRequiresTaskScopeApprovalEvenWhenSessionWriteGrantExists() {
        let playgroundRoot = AskPlaygroundStore.shared
            .playgroundRootURL()
            .appendingPathComponent("Tasks/policy-test", isDirectory: true)
            .path
        let metadata: AskInvocationMetadata = [
            "workspace_write_granted": "true",
            "active_task_workspace_root": playgroundRoot
        ]
        let invocation = AskInvocation(
            id: "invocation-1",
            sessionID: "session-1",
            parentTaskID: nil,
            prompt: "Write a file in the Playground",
            surface: .askWindow,
            requestedMode: .interactive,
            sourceBundleID: nil,
            sourceAppName: nil,
            createdAt: Date(),
            metadata: metadata
        )
        let context = AskExecutionContext.empty(
            surface: .askWindow,
            sourceBundleID: nil,
            sourceAppName: nil,
            metadata: metadata
        )
        let capability = AskCapabilityDefinition(
            id: "workspace.write_file",
            domain: .workspace,
            summary: "Write a file into the current workspace.",
            riskClass: .reversible,
            visibilityClass: .userVisible,
            supportsUnattendedExecution: false,
            supportsPreview: false,
            supportsRollback: false,
            requiredContextKeys: []
        )

        let decision = AskDefaultPolicyEngine().executionDecision(
            for: capability,
            invocation: invocation,
            context: context,
            profile: .preset(for: .interactive),
            arguments: ["path": "index.html"]
        )

        XCTAssertEqual(decision.kind, .requireApproval)
    }

    func testInteractivePlaygroundWriteIsAllowedAfterTaskScopeApprovalIsGranted() {
        let playgroundRoot = AskPlaygroundStore.shared
            .playgroundRootURL()
            .appendingPathComponent("Tasks/policy-test", isDirectory: true)
            .path
        let metadata: AskInvocationMetadata = [
            "workspace_write_granted": "true",
            "active_task_workspace_root": playgroundRoot,
            "interactive_task_scope_granted": "true",
            "interactive_task_scope_root": playgroundRoot
        ]
        let invocation = AskInvocation(
            id: "invocation-2",
            sessionID: "session-2",
            parentTaskID: nil,
            prompt: "Write a file in the Playground",
            surface: .askWindow,
            requestedMode: .interactive,
            sourceBundleID: nil,
            sourceAppName: nil,
            createdAt: Date(),
            metadata: metadata
        )
        let context = AskExecutionContext.empty(
            surface: .askWindow,
            sourceBundleID: nil,
            sourceAppName: nil,
            metadata: metadata
        )
        let capability = AskCapabilityDefinition(
            id: "workspace.write_file",
            domain: .workspace,
            summary: "Write a file into the current workspace.",
            riskClass: .reversible,
            visibilityClass: .userVisible,
            supportsUnattendedExecution: false,
            supportsPreview: false,
            supportsRollback: false,
            requiredContextKeys: []
        )

        let decision = AskDefaultPolicyEngine().executionDecision(
            for: capability,
            invocation: invocation,
            context: context,
            profile: .preset(for: .interactive),
            arguments: ["path": "index.html"]
        )

        XCTAssertEqual(decision.kind, .allow)
    }

    func testExecutionContextPrefersGrantedPlaygroundRootOverLegacyWorkspaceRoot() {
        let playgroundRoot = AskPlaygroundStore.shared
            .playgroundRootURL()
            .appendingPathComponent("Tasks/policy-context-root", isDirectory: true)
            .path
        let metadata: AskInvocationMetadata = [
            "workspace_root": ".",
            "active_task_workspace_root": playgroundRoot,
            "interactive_task_scope_root": playgroundRoot
        ]

        let context = AskExecutionContext.empty(
            surface: .askWindow,
            sourceBundleID: nil,
            sourceAppName: nil,
            metadata: metadata
        )

        XCTAssertEqual(context.workspaceRootPath, playgroundRoot)
    }
}
