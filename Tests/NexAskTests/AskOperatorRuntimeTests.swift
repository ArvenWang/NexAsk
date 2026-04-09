import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskOperatorRuntimeTests: XCTestCase {
    private actor IntentCaptureBox {
        private(set) var intent: CalendarEventIntent?

        func set(_ intent: CalendarEventIntent) {
            self.intent = intent
        }
    }

    private actor ReceiptCaptureBox {
        private(set) var receipt: CalendarCreatedItemReceipt?

        func set(_ receipt: CalendarCreatedItemReceipt) {
            self.receipt = receipt
        }
    }

    override func setUp() {
        super.setUp()
        AskAgentMockURLProtocol.requestHandler = nil
        clearSharedApprovalRouter()
    }

    override func tearDown() {
        AskAgentMockURLProtocol.requestHandler = nil
        clearSharedApprovalRouter()
        super.tearDown()
    }

    func testCreateFolderExecutesImmediately() async throws {
        let home = makeHomeDirectory()
        let workspace = WorkspaceControllerMock()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: workspace,
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { home }
        )

        let rawResponse = await runtime.handle(
            request: makeRequest(
                sessionID: "create-folder",
                messages: [.init(role: .user, content: "在桌面创建名为 项目归档 的文件夹")]
            ),
            onEvent: { _ in }
        )
        let response: AskSessionResponse = try XCTUnwrap(rawResponse)

        let folderURL = home.appendingPathComponent("Desktop/项目归档", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(response.metadata["operator_action"], "create_folder")
        XCTAssertEqual(response.cards.first?.action?.type, .openFile)
    }

    func testAvailableToolsExposePlaygroundWorkspaceToolsWithoutManualWorkspaceSelection() {
        let runtime = AskOperatorRuntime(
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore()
        )

        let namesWithoutWorkspace = Set(runtime.availableTools(
            context: AskToolPoolContext(
                responseLanguage: "zh",
                sessionID: "tool-pool-no-workspace",
                sessionOrigin: .user,
                requestedMode: nil,
                planModeActive: false,
                activeWorkspaceRoot: nil,
                kernelMetadata: [:]
            )
        ).map(\.name))
        XCTAssertFalse(namesWithoutWorkspace.contains("list_workspace_roots"))
        XCTAssertFalse(namesWithoutWorkspace.contains("set_active_workspace"))
        XCTAssertTrue(namesWithoutWorkspace.contains("snapshot_workspace_tree"))
        XCTAssertTrue(namesWithoutWorkspace.contains("write_workspace_file"))
        XCTAssertTrue(namesWithoutWorkspace.contains("run_shell_command"))
        XCTAssertFalse(namesWithoutWorkspace.contains("write_back_to_frontmost_input"))
        XCTAssertFalse(namesWithoutWorkspace.contains("replace_frontmost_selection"))
        XCTAssertTrue(namesWithoutWorkspace.contains("promote_playground_artifact"))

        let namesWithWorkspace = Set(runtime.availableTools(
            context: AskToolPoolContext(
                responseLanguage: "zh",
                sessionID: "tool-pool-with-workspace",
                sessionOrigin: .user,
                requestedMode: nil,
                planModeActive: false,
                activeWorkspaceRoot: "/tmp/demo-workspace",
                kernelMetadata: ["workspace_root": "/tmp/demo-workspace"]
            )
        ).map(\.name))
        XCTAssertTrue(namesWithWorkspace.contains("snapshot_workspace_tree"))
        XCTAssertTrue(namesWithWorkspace.contains("write_workspace_file"))
        XCTAssertTrue(namesWithWorkspace.contains("run_shell_command"))
        XCTAssertFalse(namesWithWorkspace.contains("workspace_git_status"))
        XCTAssertFalse(namesWithWorkspace.contains("workspace_git_diff"))
        XCTAssertFalse(namesWithWorkspace.contains("write_back_to_frontmost_input"))
        XCTAssertFalse(namesWithWorkspace.contains("replace_frontmost_selection"))
        XCTAssertTrue(namesWithWorkspace.contains("promote_playground_artifact"))
    }

    func testCompatibilityCapabilitiesFollowingKernelApprovalAreCentralized() {
        XCTAssertEqual(
            AskOperatorRuntime.compatibilityCapabilityInventory,
            Set<AskCapabilityID>([
                "desktop.snapshot_directory",
                "desktop.stage_move_operation",
                "desktop.commit_move_operation",
                "desktop.cancel_move_operation",
                "workspace.create_directory",
                "workspace.list_roots",
                "workspace.set_active_root",
                "workspace.snapshot_tree",
                "workspace.glob_paths",
                "workspace.enter_plan_mode",
                "workspace.exit_plan_mode",
                "workspace.set_execution_budget",
                "system.list_tasks",
                "system.get_task",
                "system.update_task",
                "system.stop_task",
                "system.spawn_subtask",
                "system.write_todo",
                "system.resume_task",
                "workspace.grep_text",
                "workspace.read_file",
                "workspace.write_file",
                "workspace.git_status",
                "workspace.git_diff",
                "workspace.run_shell_command",
                "workspace.apply_patch_preview",
                "workspace.commit_changes",
                "desktop.open_path",
                "desktop.reveal_in_finder",
                "browser.open_url",
                "browser.search_web",
                "browser.read_current_page",
                "app.copy_to_clipboard",
                "app.write_back_to_frontmost_input",
                "app.replace_frontmost_selection",
                "time.preview_automation_job",
                "time.create_automation_job"
            ])
        )
        XCTAssertEqual(
            AskOperatorRuntime.compatibilityCapabilitiesFollowingKernelApproval,
            Set<AskCapabilityID>([
                "desktop.commit_move_operation",
                "workspace.run_shell_command",
                "workspace.commit_changes"
            ])
        )
        XCTAssertEqual(
            AskOperatorRuntime.compatibilityStateMirroringCapabilities,
            Set<AskCapabilityID>([
                "desktop.snapshot_directory",
                "desktop.stage_move_operation",
                "desktop.commit_move_operation",
                "desktop.cancel_move_operation",
                "workspace.run_shell_command",
                "workspace.commit_changes",
                "browser.open_url",
                "browser.search_web",
                "time.preview_automation_job",
                "time.create_automation_job"
            ])
        )
        XCTAssertEqual(
            AskOperatorRuntime.compatibilityBehaviorOwningCapabilities,
            Set<AskCapabilityID>([
                "desktop.open_path",
                "browser.read_current_page",
                "app.copy_to_clipboard",
                "app.write_back_to_frontmost_input",
                "app.replace_frontmost_selection"
            ])
        )
        XCTAssertEqual(
            AskOperatorRuntime.compatibilityKernelOwnedCapabilities,
            AskOperatorRuntime.compatibilityCapabilityInventory
                .subtracting(AskOperatorRuntime.compatibilityStateMirroringCapabilities)
                .subtracting(AskOperatorRuntime.compatibilityBehaviorOwningCapabilities)
        )
        XCTAssertTrue(
            AskOperatorRuntime.compatibilityKernelOwnedCapabilities
                .intersection(AskOperatorRuntime.compatibilityStateMirroringCapabilities)
                .isEmpty
        )
        XCTAssertTrue(
            AskOperatorRuntime.compatibilityKernelOwnedCapabilities
                .intersection(AskOperatorRuntime.compatibilityBehaviorOwningCapabilities)
                .isEmpty
        )
        XCTAssertTrue(
            AskOperatorRuntime.compatibilityStateMirroringCapabilities
                .intersection(AskOperatorRuntime.compatibilityBehaviorOwningCapabilities)
                .isEmpty
        )
    }

    func testListMCPResourcesReflectsKnownConnectionsWithoutMirroredResources() async throws {
        let root = makeMCPRootDirectory()
        let connectionStore = AskMCPConnectionStore(
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: root
        )
        _ = connectionStore.upsert(
            AskMCPConnectionRecord(
                serverName: "Docs",
                displayName: "Docs",
                status: .connected,
                endpointSummary: "stdio",
                readableResourceCount: 0
            )
        )
        let catalog = AskSharedMCPResourceCatalog(
            notificationCenter: NotificationCenter(),
            persistToDisk: false,
            rootDirectoryURL: root,
            connectionStore: connectionStore
        )
        let runtime = AskOperatorRuntime(
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            mcpResourceCatalog: catalog,
            mcpConnectionStore: connectionStore
        )

        let result = await runtime.executeTool(
            named: "list_mcp_resources",
            argumentsJSON: "{}",
            request: makeRequest(
                sessionID: "mcp-list-connections-only",
                messages: [.init(role: .user, content: "列出 MCP 资源")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.data["servers"] as? [String], ["docs"])
        XCTAssertEqual(result.data["resource_count"] as? Int, 0)
        let connections = try XCTUnwrap(result.data["connections"] as? [[String: Any]])
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections.first?["server"] as? String, "docs")
        XCTAssertEqual(connections.first?["status"] as? String, "connected")
        XCTAssertTrue(result.summary.contains("镜像"))
    }

    func testListMCPResourcesIncludesConnectionDiagnosticsSnapshot() async throws {
        let root = makeMCPRootDirectory()
        let notificationCenter = NotificationCenter()
        let connectionStore = AskMCPConnectionStore(
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )
        _ = connectionStore.replaceConnections([
            AskMCPConnectionRecord(
                serverName: "Docs",
                status: .connected,
                readableResourceCount: 0
            ),
            AskMCPConnectionRecord(
                serverName: "Repo",
                status: .failed,
                readableResourceCount: 0,
                lastError: "timeout"
            )
        ])
        let catalog = AskSharedMCPResourceCatalog(
            notificationCenter: notificationCenter,
            persistToDisk: false,
            rootDirectoryURL: root,
            connectionStore: connectionStore
        )
        catalog.replaceResources(
            serverName: "Docs",
            resources: [
                AskMCPResourceRecord(
                    serverName: "Docs",
                    uri: "mcp://docs/spec",
                    name: "Spec",
                    description: "Spec",
                    mimeType: "text/plain",
                    textContent: "hello",
                    updatedAt: Date(timeIntervalSince1970: 1_775_149_200),
                    metadata: [:]
                )
            ]
        )
        let runtime = AskOperatorRuntime(
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            mcpResourceCatalog: catalog,
            mcpConnectionStore: connectionStore
        )

        let result = await runtime.executeTool(
            named: "list_mcp_resources",
            argumentsJSON: "{}",
            request: makeRequest(
                sessionID: "mcp-diagnostics",
                messages: [.init(role: .user, content: "列出 MCP 资源")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(result.ok)
        let diagnostics = try XCTUnwrap(result.data["connection_diagnostics"] as? [String: Any])
        XCTAssertEqual(diagnostics["total_connections"] as? Int, 2)
        XCTAssertEqual(diagnostics["connected_count"] as? Int, 1)
        XCTAssertEqual(diagnostics["failed_count"] as? Int, 1)
        XCTAssertEqual(diagnostics["mirrored_readable_resource_count"] as? Int, 1)
        XCTAssertEqual(diagnostics["mirrored_server_count"] as? Int, 1)
    }

    func testReadMCPResourceReturnsMirroredTextContent() async throws {
        let root = makeMCPRootDirectory()
        let notificationCenter = NotificationCenter()
        let connectionStore = AskMCPConnectionStore(
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )
        let catalog = AskSharedMCPResourceCatalog(
            notificationCenter: notificationCenter,
            persistToDisk: false,
            rootDirectoryURL: root,
            connectionStore: connectionStore
        )
        catalog.replaceResources(
            serverName: "Docs",
            resources: [
                AskMCPResourceRecord(
                    serverName: "Docs",
                    uri: "mcp://docs/guide",
                    name: "Guide",
                    description: "Setup guide",
                    mimeType: "text/plain",
                    textContent: "step one\nstep two",
                    updatedAt: Date(timeIntervalSince1970: 1_775_149_200),
                    metadata: ["topic": "setup"]
                )
            ]
        )
        let runtime = AskOperatorRuntime(
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            mcpResourceCatalog: catalog,
            mcpConnectionStore: connectionStore
        )

        let result = await runtime.executeTool(
            named: "read_mcp_resource",
            argumentsJSON: #"{"server":"docs","uri":"mcp://docs/guide"}"#,
            request: makeRequest(
                sessionID: "mcp-read-success",
                messages: [.init(role: .user, content: "读取 docs guide")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.data["server"] as? String, "Docs")
        XCTAssertEqual(result.data["uri"] as? String, "mcp://docs/guide")
        XCTAssertEqual(result.data["has_text_content"] as? Bool, true)
        XCTAssertEqual(result.data["text_content"] as? String, "step one\nstep two")
    }

    func testReadMCPResourceExplainsWhenConnectionExistsButMirrorIsMissing() async throws {
        let root = makeMCPRootDirectory()
        let notificationCenter = NotificationCenter()
        let connectionStore = AskMCPConnectionStore(
            notificationCenter: notificationCenter,
            rootDirectoryURL: root
        )
        _ = connectionStore.upsert(
            AskMCPConnectionRecord(
                serverName: "Docs",
                displayName: "Docs",
                status: .connected,
                endpointSummary: "stdio",
                readableResourceCount: 0
            )
        )
        let catalog = AskSharedMCPResourceCatalog(
            notificationCenter: notificationCenter,
            persistToDisk: false,
            rootDirectoryURL: root,
            connectionStore: connectionStore
        )
        let runtime = AskOperatorRuntime(
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            mcpResourceCatalog: catalog,
            mcpConnectionStore: connectionStore
        )

        let result = await runtime.executeTool(
            named: "read_mcp_resource",
            argumentsJSON: #"{"server":"docs","uri":"mcp://docs/guide"}"#,
            request: makeRequest(
                sessionID: "mcp-read-missing-mirror",
                messages: [.init(role: .user, content: "读取 docs guide")]
            ),
            onEvent: { _ in }
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.data["server"] as? String, "docs")
        XCTAssertEqual(result.data["uri"] as? String, "mcp://docs/guide")
        let connection = try XCTUnwrap(result.data["connection"] as? [String: Any])
        XCTAssertEqual(connection["status"] as? String, "connected")
        XCTAssertTrue(result.summary.contains("镜像") || result.summary.contains("mirrored"))
    }

    func testAppWritebackToolsStayBlockedWithoutExplicitIntent() async {
        let runtime = AskOperatorRuntime(
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore()
        )
        let request = makeRequest(
            sessionID: "writeback-blocked",
            messages: [.init(role: .user, content: "把这个结果整理一下")]
        )

        let copyResult = await runtime.executeTool(
            named: "copy_to_clipboard",
            argumentsJSON: #"{"text":"alpha"}"#,
            request: request,
            onEvent: { _ in }
        )
        XCTAssertFalse(copyResult.ok)
        XCTAssertEqual(copyResult.data["clipboard_write_blocked"] as? Bool, true)

        let writebackResult = await runtime.executeTool(
            named: "write_back_to_frontmost_input",
            argumentsJSON: #"{"text":"alpha"}"#,
            request: request,
            onEvent: { _ in }
        )
        XCTAssertFalse(writebackResult.ok)
        XCTAssertEqual(writebackResult.data["writeback_blocked"] as? Bool, true)

        let replaceResult = await runtime.executeTool(
            named: "replace_frontmost_selection",
            argumentsJSON: #"{"text":"alpha"}"#,
            request: request,
            onEvent: { _ in }
        )
        XCTAssertFalse(replaceResult.ok)
        XCTAssertEqual(replaceResult.data["replace_blocked"] as? Bool, true)
    }

    func testWorkspaceMutationToolsExecuteThroughSharedApprovalBridge() async throws {
        let home = makeHomeDirectory()
        let shellWorkspaceRoot = AskPlaygroundStore.shared
            .playgroundRootURL()
            .appendingPathComponent("Tasks/workspace-shell-\(UUID().uuidString)", isDirectory: true)
        let patchWorkspaceRoot = AskPlaygroundStore.shared
            .playgroundRootURL()
            .appendingPathComponent("Tasks/workspace-patch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: shellWorkspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: patchWorkspaceRoot, withIntermediateDirectories: true)

        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { home }
        )

        let shellRequest = makeRequest(
            sessionID: "workspace-shell-approval",
            kernelMetadata: [
                "workspace_root": shellWorkspaceRoot.path,
                "active_task_workspace_root": shellWorkspaceRoot.path
            ],
            messages: [.init(role: .user, content: "在 playground 里运行一个命令")]
        )
        let shellResult = await runtime.executeTool(
            named: "run_shell_command",
            argumentsJSON: #"{"command":"touch marker.txt","workspace_root":"\#(shellWorkspaceRoot.path)"}"#,
            request: shellRequest,
            onEvent: { _ in }
        )

        let shellActionID = try XCTUnwrap(shellResult.approvalRequest?.actionID)
        XCTAssertTrue(shellResult.ok)
        XCTAssertFalse(shellResult.cards.isEmpty)

        let approvedShell = await runtime.executeTool(
            named: "respond_to_approval",
            argumentsJSON: #"{"action_id":"\#(shellActionID)","decision":"approve"}"#,
            request: makeRequest(
                sessionID: "workspace-shell-approval",
                kernelMetadata: shellRequest.metadata.kernelMetadata,
                messages: [.init(role: .user, content: "确认")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(approvedShell.ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shellWorkspaceRoot.appendingPathComponent("marker.txt").path))

        let patch = """
        diff --git a/note.txt b/note.txt
        new file mode 100644
        --- /dev/null
        +++ b/note.txt
        @@ -0,0 +1 @@
        +hello from patch
        """
        let patchRequest = makeRequest(
            sessionID: "workspace-patch-approval",
            kernelMetadata: [
                "workspace_root": patchWorkspaceRoot.path,
                "active_task_workspace_root": patchWorkspaceRoot.path
            ],
            messages: [.init(role: .user, content: "把 patch 应用到 playground")]
        )
        let patchResult = await runtime.executeTool(
            named: "apply_workspace_patch",
            argumentsJSON: try jsonString([
                "patch": patch,
                "workspace_root": patchWorkspaceRoot.path
            ]),
            request: patchRequest,
            onEvent: { _ in }
        )

        let patchActionID = try XCTUnwrap(patchResult.approvalRequest?.actionID)
        XCTAssertTrue(patchResult.ok)
        XCTAssertFalse(patchResult.cards.isEmpty)

        let approvedPatch = await runtime.executeTool(
            named: "respond_to_approval",
            argumentsJSON: #"{"action_id":"\#(patchActionID)","decision":"approve"}"#,
            request: makeRequest(
                sessionID: "workspace-patch-approval",
                kernelMetadata: patchRequest.metadata.kernelMetadata,
                messages: [.init(role: .user, content: "确认")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(approvedPatch.ok)
        XCTAssertEqual(
            try String(contentsOf: patchWorkspaceRoot.appendingPathComponent("note.txt"), encoding: .utf8),
            "hello from patch\n"
        )
    }

    func testMoveRequiresConfirmationThenExecutes() async throws {
        let home = makeHomeDirectory()
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let sourceOne = desktop.appendingPathComponent("alpha.pdf")
        let sourceTwo = desktop.appendingPathComponent("beta.pdf")
        try "alpha".write(to: sourceOne, atomically: true, encoding: .utf8)
        try "beta".write(to: sourceTwo, atomically: true, encoding: .utf8)

        let workspace = WorkspaceControllerMock()
        let sessionStore = AskOperatorSessionStore()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: workspace,
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: sessionStore,
            homeDirectoryProvider: { home }
        )

        let firstRawResponse = await runtime.handle(
            request: makeRequest(
                sessionID: "move-files",
                messages: [.init(role: .user, content: "把桌面上的 pdf 文件移动到桌面新文件夹 资料归档")]
            ),
            onEvent: { _ in }
        )
        let firstResponse: AskSessionResponse = try XCTUnwrap(firstRawResponse)

        XCTAssertEqual(firstResponse.metadata["operator_action"], "move_prepare")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceOne.path))
        let pendingMove = await sessionStore.pendingMove(for: "move-files")
        XCTAssertNotNil(pendingMove)

        let secondRawResponse = await runtime.handle(
            request: makeRequest(
                sessionID: "move-files",
                messages: [.init(role: .user, content: "确认")]
            ),
            onEvent: { _ in }
        )
        let secondResponse: AskSessionResponse = try XCTUnwrap(secondRawResponse)

        let destinationDirectory = desktop.appendingPathComponent("资料归档", isDirectory: true)
        XCTAssertEqual(secondResponse.metadata["operator_action"], "move_execute")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceOne.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationDirectory.appendingPathComponent("alpha.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationDirectory.appendingPathComponent("beta.pdf").path))
        let clearedPendingMove = await sessionStore.pendingMove(for: "move-files")
        XCTAssertNil(clearedPendingMove)
    }

    func testMoveDesktopMP4FilesCollectsAllMatches() async throws {
        let home = makeHomeDirectory()
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let videoOne = desktop.appendingPathComponent("clip-1.mp4")
        let videoTwo = desktop.appendingPathComponent("clip-2.mp4")
        let videoThree = desktop.appendingPathComponent("clip-3.mp4")
        try "one".write(to: videoOne, atomically: true, encoding: .utf8)
        try "two".write(to: videoTwo, atomically: true, encoding: .utf8)
        try "three".write(to: videoThree, atomically: true, encoding: .utf8)

        let sessionStore = AskOperatorSessionStore()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: sessionStore,
            homeDirectoryProvider: { home }
        )

        let rawResponse = await runtime.handle(
            request: makeRequest(
                sessionID: "move-mp4-files",
                messages: [.init(role: .user, content: "把桌面上的 MP4 文件移动到桌面新文件夹 视频归档")]
            ),
            onEvent: { _ in }
        )
        let response: AskSessionResponse = try XCTUnwrap(rawResponse)

        XCTAssertEqual(response.metadata["operator_action"], "move_prepare")
        XCTAssertEqual(response.metadata["operator_match_count"], "3")

        let pendingMoveValue = await sessionStore.pendingMove(for: "move-mp4-files")
        let pendingMove: AskStagedOperation = try XCTUnwrap(pendingMoveValue)
        let actualPaths = Set(pendingMove.matchedFilePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let expectedPaths = Set([videoOne, videoTwo, videoThree].map { $0.standardizedFileURL.path })
        XCTAssertEqual(actualPaths, expectedPaths)
    }

    func testMoveDesktopMP4FilesDoesNotDropRootFilesWhenNestedMatchesAreMany() async throws {
        let home = makeHomeDirectory()
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let nestedDirectory = desktop.appendingPathComponent("DEMO", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        let rootVideo = desktop.appendingPathComponent("root-video.mp4")
        try "root".write(to: rootVideo, atomically: true, encoding: .utf8)

        for index in 0..<45 {
            let nestedVideo = nestedDirectory.appendingPathComponent("nested-\(index).mp4")
            try "nested-\(index)".write(to: nestedVideo, atomically: true, encoding: .utf8)
        }

        let sessionStore = AskOperatorSessionStore()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: sessionStore,
            homeDirectoryProvider: { home }
        )

        let rawResponse = await runtime.handle(
            request: makeRequest(
                sessionID: "move-many-mp4-files",
                messages: [.init(role: .user, content: "把桌面上的 MP4 文件移动到桌面新文件夹 视频归档")]
            ),
            onEvent: { _ in }
        )
        let response: AskSessionResponse = try XCTUnwrap(rawResponse)

        XCTAssertEqual(response.metadata["operator_action"], "move_prepare")
        XCTAssertEqual(response.metadata["operator_match_count"], "46")

        let pendingMoveValue = await sessionStore.pendingMove(for: "move-many-mp4-files")
        let pendingMove: AskStagedOperation = try XCTUnwrap(pendingMoveValue)
        let pendingPaths = Set(pendingMove.matchedFilePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        XCTAssertTrue(pendingPaths.contains(rootVideo.standardizedFileURL.path))
    }

    func testPrepareDirectoryCleanupCollectsOnlyLooseDesktopFiles() async throws {
        let home = makeHomeDirectory()
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let nestedDirectory = desktop.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        let rootFileOne = desktop.appendingPathComponent("alpha.txt")
        let rootFileTwo = desktop.appendingPathComponent("beta.pdf")
        let nestedFile = nestedDirectory.appendingPathComponent("nested.txt")
        try "alpha".write(to: rootFileOne, atomically: true, encoding: .utf8)
        try "beta".write(to: rootFileTwo, atomically: true, encoding: .utf8)
        try "nested".write(to: nestedFile, atomically: true, encoding: .utf8)

        let sessionStore = AskOperatorSessionStore()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: sessionStore,
            homeDirectoryProvider: { home }
        )

        let result = await runtime.executeTool(
            named: "prepare_directory_cleanup",
            argumentsJSON: #"{"source_directory":"desktop","destination_folder_name":"桌面归档"}"#,
            request: makeRequest(
                sessionID: "desktop-cleanup",
                messages: [.init(role: .user, content: "把桌面上散落的文件收进新文件夹")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(result.ok)
        XCTAssertNotNil(result.approvalRequest)
        XCTAssertEqual(result.data["match_count"] as? Int, 2)
        XCTAssertEqual(result.data["destination_folder_name"] as? String, "桌面归档")

        let pendingMoveValue = await sessionStore.pendingMove(for: "desktop-cleanup")
        let pendingMove: AskStagedOperation = try XCTUnwrap(pendingMoveValue)
        let actualPaths = Set(pendingMove.matchedFilePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let expectedPaths = Set([rootFileOne, rootFileTwo].map { $0.standardizedFileURL.path })
        XCTAssertEqual(actualPaths, expectedPaths)
        XCTAssertFalse(actualPaths.contains(nestedFile.standardizedFileURL.path))
        XCTAssertEqual(pendingMove.destinationDirectoryPath, desktop.appendingPathComponent("桌面归档", isDirectory: true).path)
        XCTAssertTrue(pendingMove.createDestinationIfNeeded)

        let snapshotID = try XCTUnwrap(result.data["snapshot_id"] as? String)
        let selectionID = try XCTUnwrap(result.data["selection_id"] as? String)
        let storedSnapshot = await sessionStore.snapshot(for: snapshotID)
        let storedSelection = await sessionStore.selection(for: selectionID)
        XCTAssertEqual(storedSnapshot?.items.count, 2)
        XCTAssertEqual(storedSelection?.paths.count, 2)
    }

    func testSnapshotSelectStageCommitFlowStoresReusableOperationState() async throws {
        let home = makeHomeDirectory()
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let movie = desktop.appendingPathComponent("demo.mp4")
        let note = desktop.appendingPathComponent("note.txt")
        try "movie".write(to: movie, atomically: true, encoding: .utf8)
        try "note".write(to: note, atomically: true, encoding: .utf8)

        let sessionStore = AskOperatorSessionStore()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: sessionStore,
            homeDirectoryProvider: { home }
        )

        let request = makeRequest(
            sessionID: "snapshot-stage-commit",
            messages: [.init(role: .user, content: "把桌面上的 MP4 文件移动到桌面新文件夹 视频归档")]
        )

        let snapshotResult = await runtime.executeTool(
            named: "snapshot_directory",
            argumentsJSON: #"{"directory":"desktop","extensions":["mp4"]}"#,
            request: request,
            onEvent: { _ in }
        )
        XCTAssertTrue(snapshotResult.ok)
        let snapshotID = try XCTUnwrap(snapshotResult.data["snapshot_id"] as? String)

        let selectionResult = await runtime.executeTool(
            named: "select_from_snapshot",
            argumentsJSON: #"{"snapshot_id":"\#(snapshotID)","extensions":["mp4"],"files_only":true}"#,
            request: request,
            onEvent: { _ in }
        )
        XCTAssertTrue(selectionResult.ok)
        let selectionID = try XCTUnwrap(selectionResult.data["selection_id"] as? String)

        let stageResult = await runtime.executeTool(
            named: "stage_move_paths",
            argumentsJSON: #"{"selection_id":"\#(selectionID)","destination_directory":"desktop/视频归档","create_destination_if_needed":true}"#,
            request: request,
            onEvent: { _ in }
        )
        XCTAssertTrue(stageResult.ok)
        XCTAssertEqual(stageResult.data["affected_count"] as? Int, 1)
        let operationID = try XCTUnwrap(stageResult.data["operation_id"] as? String)
        let stagedOperationValue = await sessionStore.operation(for: operationID)
        let stagedOperation: AskStagedOperation = try XCTUnwrap(stagedOperationValue)
        XCTAssertEqual(stagedOperation.status, .staged)
        XCTAssertEqual(stagedOperation.sourceSnapshotID, snapshotID)
        XCTAssertEqual(stagedOperation.selectionID, selectionID)

        let commitResult = await runtime.executeTool(
            named: "commit_staged_operation",
            argumentsJSON: #"{"operation_id":"\#(operationID)"}"#,
            request: request,
            onEvent: { _ in }
        )
        XCTAssertTrue(commitResult.ok)
        XCTAssertNotNil(commitResult.approvalRequest)
        XCTAssertEqual(commitResult.data["requires_approval"] as? Bool, true)
        let pendingMove = await sessionStore.pendingMove(for: "snapshot-stage-commit")
        XCTAssertEqual(pendingMove?.matchedFilePaths.count, 1)
    }

    func testCancelConfirmationLeavesFilesUnchanged() async throws {
        let home = makeHomeDirectory()
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let sourceOne = desktop.appendingPathComponent("alpha.pdf")
        let sourceTwo = desktop.appendingPathComponent("beta.pdf")
        try "alpha".write(to: sourceOne, atomically: true, encoding: .utf8)
        try "beta".write(to: sourceTwo, atomically: true, encoding: .utf8)

        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { home }
        )

        _ = await runtime.handle(
            request: makeRequest(
                sessionID: "cancel-move",
                messages: [.init(role: .user, content: "把桌面上的 pdf 文件移动到桌面新文件夹 资料归档")]
            ),
            onEvent: { _ in }
        )

        let cancelResponseValue = await runtime.handle(
            request: makeRequest(
                sessionID: "cancel-move",
                messages: [.init(role: .user, content: "取消")]
            ),
            onEvent: { _ in }
        )
        let cancelResponse: AskSessionResponse = try XCTUnwrap(cancelResponseValue)

        XCTAssertEqual(cancelResponse.metadata["operator_action"], "move_cancelled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceOne.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceTwo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: desktop.appendingPathComponent("资料归档/alpha.pdf").path))
    }

    func testRespondToApprovalRejectsMismatchedActionID() async throws {
        let home = makeHomeDirectory()
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let source = desktop.appendingPathComponent("alpha.pdf")
        try "alpha".write(to: source, atomically: true, encoding: .utf8)

        let sessionStore = AskOperatorSessionStore()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: sessionStore,
            homeDirectoryProvider: { home }
        )

        let prepare = await runtime.executeTool(
            named: "prepare_directory_cleanup",
            argumentsJSON: #"{"source_directory":"desktop","destination_folder_name":"资料归档"}"#,
            request: makeRequest(
                sessionID: "approval-mismatch",
                messages: [.init(role: .user, content: "把桌面上散落的文件收进新文件夹")]
            ),
            onEvent: { _ in }
        )
        let actionID = try XCTUnwrap(prepare.approvalRequest?.actionID)

        let mismatch = await runtime.executeTool(
            named: "respond_to_approval",
            argumentsJSON: #"{"action_id":"wrong-\#(actionID)","decision":"approve"}"#,
            request: makeRequest(
                sessionID: "approval-mismatch",
                messages: [.init(role: .user, content: "确认")]
            ),
            onEvent: { _ in }
        )

        XCTAssertFalse(mismatch.ok)
        XCTAssertEqual(mismatch.approvalRequest?.actionID, actionID)
        XCTAssertEqual(mismatch.data["action_id"] as? String, actionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let pending = await sessionStore.pendingMove(for: "approval-mismatch")
        XCTAssertEqual(pending?.matchedFilePaths, [source.path])
    }

    func testRespondToApprovalReturnsExecutedCountAfterApproval() async throws {
        let home = makeHomeDirectory()
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let sourceOne = desktop.appendingPathComponent("alpha.pdf")
        let sourceTwo = desktop.appendingPathComponent("beta.pdf")
        try "alpha".write(to: sourceOne, atomically: true, encoding: .utf8)
        try "beta".write(to: sourceTwo, atomically: true, encoding: .utf8)

        let sessionStore = AskOperatorSessionStore()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: sessionStore,
            homeDirectoryProvider: { home }
        )

        let prepare = await runtime.executeTool(
            named: "prepare_directory_cleanup",
            argumentsJSON: #"{"source_directory":"desktop","destination_folder_name":"资料归档"}"#,
            request: makeRequest(
                sessionID: "approval-count",
                messages: [.init(role: .user, content: "把桌面上散落的文件收进新文件夹")]
            ),
            onEvent: { _ in }
        )
        let actionID = try XCTUnwrap(prepare.approvalRequest?.actionID)

        let approved = await runtime.executeTool(
            named: "respond_to_approval",
            argumentsJSON: #"{"action_id":"\#(actionID)","decision":"approve"}"#,
            request: makeRequest(
                sessionID: "approval-count",
                messages: [.init(role: .user, content: "确认")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(approved.ok)
        XCTAssertEqual(approved.data["action_id"] as? String, actionID)
        XCTAssertEqual(approved.data["decision"] as? String, "approve")
        XCTAssertEqual(approved.data["executed_count"] as? Int, 2)
        XCTAssertEqual(approved.data["skipped_count"] as? Int, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceOne.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceTwo.path))
    }

    func testPlaygroundWriteDoesNotRequireAnotherApprovalAfterTaskScopeGrant() async throws {
        let home = makeHomeDirectory()
        let playgroundRoot = AskPlaygroundStore.shared
            .playgroundRootURL()
            .appendingPathComponent("Tasks/operator-task-scope", isDirectory: true)
        try FileManager.default.createDirectory(at: playgroundRoot, withIntermediateDirectories: true)

        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { home }
        )

        let initialMetadata: AskInvocationMetadata = [
            "workspace_root": playgroundRoot.path,
            "active_task_workspace_root": playgroundRoot.path
        ]
        let firstResult = await runtime.executeTool(
            named: "write_workspace_file",
            argumentsJSON: #"{"file_path":"index.html","text":"<html>first</html>","create_parents":true,"workspace_root":"\#(playgroundRoot.path)"}"#,
            request: makeRequest(
                sessionID: "playground-task-scope",
                kernelMetadata: initialMetadata,
                messages: [.init(role: .user, content: "先写 index.html")]
            ),
            onEvent: { _ in }
        )

        let actionID = try XCTUnwrap(firstResult.approvalRequest?.actionID)

        let approvalResult = await runtime.executeTool(
            named: "respond_to_approval",
            argumentsJSON: #"{"action_id":"\#(actionID)","decision":"approve"}"#,
            request: makeRequest(
                sessionID: "playground-task-scope",
                kernelMetadata: initialMetadata,
                messages: [.init(role: .user, content: "确认")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(approvalResult.ok)
        XCTAssertEqual(approvalResult.data["interactive_task_scope_granted"] as? String, "true")
        XCTAssertEqual(approvalResult.data["workspace_write_granted"] as? String, "true")

        let mergedMetadata = approvalResult.data.reduce(into: initialMetadata) { partialResult, entry in
            if let value = entry.value as? String, !value.isEmpty {
                partialResult[entry.key] = value
            }
        }

        let secondResult = await runtime.executeTool(
            named: "write_workspace_file",
            argumentsJSON: #"{"file_path":"style.css","text":"body { color: red; }","create_parents":true}"#,
            request: makeRequest(
                sessionID: "playground-task-scope",
                kernelMetadata: mergedMetadata,
                messages: [.init(role: .user, content: "继续写 style.css")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(secondResult.ok)
        XCTAssertNil(secondResult.approvalRequest)
        XCTAssertEqual(secondResult.data["path"] as? String, playgroundRoot.appendingPathComponent("style.css").path)
    }

    func testPlaygroundWriteRepairsMissingPathAndRelativeWorkspaceRoot() async throws {
        let home = makeHomeDirectory()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { home }
        )

        let firstResult = await runtime.executeTool(
            named: "write_workspace_file",
            argumentsJSON: #"{"text":"<!DOCTYPE html><html><head><title>Calculator</title><link rel=\"stylesheet\" href=\"style.css\"></head><body><script src=\"script.js\"></script></body></html>","create_parents":true}"#,
            request: makeRequest(
                sessionID: "playground-write-repair-missing-path",
                kernelMetadata: ["workspace_root": "."],
                messages: [.init(
                    role: .user,
                    content: "Create a very small calculator app in the Playground using exactly three compact local files: index.html, style.css, and script.js."
                )]
            ),
            onEvent: { _ in }
        )

        let actionID = try XCTUnwrap(firstResult.approvalRequest?.actionID)

        let approvalResult = await runtime.executeTool(
            named: "respond_to_approval",
            argumentsJSON: #"{"action_id":"\#(actionID)","decision":"approve"}"#,
            request: makeRequest(
                sessionID: "playground-write-repair-missing-path",
                kernelMetadata: ["workspace_root": "."],
                messages: [.init(role: .user, content: "确认")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(approvalResult.ok)
        let workspaceRoot = try XCTUnwrap(approvalResult.data["workspace_root"] as? String)
        let writtenPath = try XCTUnwrap(approvalResult.data["path"] as? String)
        XCTAssertTrue(AskPlaygroundStore.shared.isInsidePlayground(path: workspaceRoot))
        XCTAssertTrue(AskPlaygroundStore.shared.isInsidePlayground(path: writtenPath))
        XCTAssertEqual(approvalResult.data["interactive_task_scope_root"] as? String, workspaceRoot)
        XCTAssertEqual(approvalResult.data["inferred_path"] as? String, "index.html")
        XCTAssertEqual(URL(fileURLWithPath: writtenPath).lastPathComponent, "index.html")
        XCTAssertNotEqual(workspaceRoot, ".")
        XCTAssertTrue(FileManager.default.fileExists(atPath: writtenPath))
    }

    func testPlaygroundWriteRepairsAbsolutePathBackIntoPlaygroundWorkspace() async throws {
        let home = makeHomeDirectory()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { home }
        )

        let firstResult = await runtime.executeTool(
            named: "write_workspace_file",
            argumentsJSON: #"{"file_path":"/tmp/calculator_app/script.js","text":"const display = document.getElementById('display');","create_parents":true}"#,
            request: makeRequest(
                sessionID: "playground-write-repair-absolute-path",
                kernelMetadata: ["workspace_root": "."],
                messages: [.init(
                    role: .user,
                    content: "Create a very small calculator app in the Playground using exactly three compact local files: index.html, style.css, and script.js."
                )]
            ),
            onEvent: { _ in }
        )

        let actionID = try XCTUnwrap(firstResult.approvalRequest?.actionID)

        let approvalResult = await runtime.executeTool(
            named: "respond_to_approval",
            argumentsJSON: #"{"action_id":"\#(actionID)","decision":"approve"}"#,
            request: makeRequest(
                sessionID: "playground-write-repair-absolute-path",
                kernelMetadata: ["workspace_root": "."],
                messages: [.init(role: .user, content: "确认")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(approvalResult.ok)
        let workspaceRoot = try XCTUnwrap(approvalResult.data["workspace_root"] as? String)
        let writtenPath = try XCTUnwrap(approvalResult.data["path"] as? String)
        XCTAssertTrue(AskPlaygroundStore.shared.isInsidePlayground(path: workspaceRoot))
        XCTAssertTrue(AskPlaygroundStore.shared.isInsidePlayground(path: writtenPath))
        XCTAssertEqual(approvalResult.data["requested_path"] as? String, "/tmp/calculator_app/script.js")
        XCTAssertEqual(approvalResult.data["inferred_path"] as? String, "script.js")
        XCTAssertEqual(URL(fileURLWithPath: writtenPath).lastPathComponent, "script.js")
        XCTAssertTrue(FileManager.default.fileExists(atPath: writtenPath))
    }

    func testOpenPathBlocksBrokenPlaygroundHTMLArtifactBeforeOpening() async throws {
        let home = makeHomeDirectory()
        let artifactRoot = AskPlaygroundStore.shared
            .playgroundRootURL()
            .appendingPathComponent("Tasks/open-path-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)

        let htmlURL = artifactRoot.appendingPathComponent("index.html")
        let cssURL = artifactRoot.appendingPathComponent("style.css")
        let scriptURL = artifactRoot.appendingPathComponent("script.js")
        try """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <title>Broken Playground</title>
          <link rel="stylesheet" href="style.css">
          <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;700&display=swap">
        </head>
        <body>
          <div class="container">
            <div class="buttons">
              <button data-number="1">1</button>
            </div>
          </div>
          <script src="script.js"></script>
        </body>
        </html>
        """.write(to: htmlURL, atomically: true, encoding: .utf8)
        try """
        body { margin: 0; }
        .buttons-grid { display: grid; }
        """.write(to: cssURL, atomically: true, encoding: .utf8)
        try """
        document.querySelector('[data-all-clear]').addEventListener('click', () => {});
        """.write(to: scriptURL, atomically: true, encoding: .utf8)

        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { home }
        )

        let result = await runtime.executeTool(
            named: "open_path",
            argumentsJSON: #"{"path":"\#(htmlURL.path)"}"#,
            request: makeRequest(
                sessionID: "open-path-validation",
                messages: [.init(role: .user, content: "打开这个 Playground 页面")]
            ),
            onEvent: { _ in }
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.data["path"] as? String, htmlURL.path)
        XCTAssertTrue(result.summary.contains("一致性问题"))
        XCTAssertTrue(result.summary.contains("远程 URL") || result.summary.contains("CDN"))
        XCTAssertTrue(result.summary.contains("data 挂点") || result.summary.contains("class"))
    }

    func testWebSearchOpensGoogleQueryInPreferredBrowser() async throws {
        let workspace = WorkspaceControllerMock()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: workspace,
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
        )

        let rawResponse = await runtime.handle(
            request: makeRequest(
                sessionID: "web-search",
                sourceBundleID: "com.google.Chrome",
                sourceAppName: "Google Chrome",
                messages: [.init(role: .user, content: "用 Chrome 搜索 OpenAI Responses API docs")]
            ),
            onEvent: { _ in }
        )
        let response: AskSessionResponse = try XCTUnwrap(rawResponse)

        XCTAssertEqual(response.metadata["operator_action"], "web_search")
        XCTAssertEqual(workspace.openedURLs.count, 1)
        XCTAssertEqual(workspace.openedURLs.first?.preferredBundleID, "com.google.Chrome")
        XCTAssertTrue(workspace.openedURLs.first?.url.absoluteString.contains("google.com/search") == true)
        XCTAssertTrue(workspace.openedURLs.first?.url.absoluteString.contains("Responses") == true)
    }

    func testAgentSearchWebDoesNotOpenBrowserWithoutExplicitOpenIntent() async throws {
        let workspace = WorkspaceControllerMock()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: workspace,
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
        )

        let result = await runtime.executeTool(
            named: "search_web",
            argumentsJSON: #"{"query":"OpenAI Responses API docs","open_in_browser":true}"#,
            request: makeRequest(
                sessionID: "silent-web-search",
                messages: [.init(role: .user, content: "OpenAI Responses API 和 Chat Completions 有什么区别")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.data["open_in_browser"] as? Bool, false)
        XCTAssertEqual(workspace.openedURLs.count, 0)
        XCTAssertTrue(result.summary.contains("没有主动打开浏览器"))
    }

    func testAgentOpenURLIsBlockedWithoutExplicitOpenIntent() async throws {
        let workspace = WorkspaceControllerMock()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: workspace,
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
        )

        let result = await runtime.executeTool(
            named: "open_url",
            argumentsJSON: #"{"url":"https://platform.openai.com/docs/api-reference/responses"}"#,
            request: makeRequest(
                sessionID: "block-open-url",
                messages: [.init(role: .user, content: "Responses API 和 Chat Completions 有什么区别")]
            ),
            onEvent: { _ in }
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(workspace.openedURLs.count, 0)
        XCTAssertEqual(result.data["visible_browser_action_blocked"] as? Bool, true)
    }

    func testAgentOpenURLIsAllowedForExplicitSearchIntent() async throws {
        let workspace = WorkspaceControllerMock()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: workspace,
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
        )

        let result = await runtime.executeTool(
            named: "open_url",
            argumentsJSON: #"{"url":"https://www.gold.org/goldhub/data/gold-prices"}"#,
            request: makeRequest(
                sessionID: "allow-open-url-search-intent",
                messages: [.init(role: .user, content: "帮我去搜索一下当前最新金价")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(workspace.openedURLs.count, 1)
    }

    func testAgentReadCurrentPageIsBlockedWithoutExplicitPageReference() async throws {
        let workspace = WorkspaceControllerMock()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: workspace,
            browserPageProvider: BrowserPageProviderMock(
                result: .success(
                    BrowserPageCaptureResult(
                        browserBundleID: "com.google.Chrome",
                        pageURL: URL(string: "https://example.com")!,
                        canonicalURL: nil,
                        title: "Example",
                        text: "Example page text"
                    )
                )
            ),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
        )

        let result = await runtime.executeTool(
            named: "read_current_page",
            argumentsJSON: #"{"query":"pricing"}"#,
            request: makeRequest(
                sessionID: "block-read-page",
                messages: [.init(role: .user, content: "OpenAI Responses API 和 Chat Completions 有什么区别")]
            ),
            onEvent: { _ in }
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(workspace.openedURLs.count, 0)
        XCTAssertEqual(result.data["current_page_read_blocked"] as? Bool, true)
    }

    func testAgentReadCurrentPageIsAllowedAfterSessionOpenedBrowserPage() async throws {
        let workspace = WorkspaceControllerMock()
        let browserProvider = BrowserPageProviderMock(
            result: .success(
                BrowserPageCaptureResult(
                    browserBundleID: "com.google.Chrome",
                    pageURL: URL(string: "https://www.gold.org/goldhub/data/gold-prices")!,
                    canonicalURL: nil,
                    title: "Gold Price",
                    text: "Spot gold is trading near a record high."
                )
            )
        )
        let sessionStore = AskOperatorSessionStore()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: workspace,
            browserPageProvider: browserProvider,
            diagnosticsLogger: makeLogger(),
            sessionStore: sessionStore,
            homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
        )

        let openResult = await runtime.executeTool(
            named: "open_url",
            argumentsJSON: #"{"url":"https://www.gold.org/goldhub/data/gold-prices"}"#,
            request: makeRequest(
                sessionID: "read-opened-page",
                messages: [.init(role: .user, content: "帮我去搜索一下当前最新金价")]
            ),
            onEvent: { _ in }
        )
        XCTAssertTrue(openResult.ok)

        let readResult = await runtime.executeTool(
            named: "read_current_page",
            argumentsJSON: #"{"query":"gold price"}"#,
            request: makeRequest(
                sessionID: "read-opened-page",
                sourceBundleID: "com.todesktop.230313mzl4w4u92",
                messages: [.init(role: .user, content: "继续看看结果")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(readResult.ok)
        XCTAssertEqual(browserProvider.requestedBundleIDs.count, 1)
        let requestedBundleID = browserProvider.requestedBundleIDs.first ?? "__missing__"
        XCTAssertNil(requestedBundleID)
    }

    func testSkillRuntimeStreamAskUsesModelDrivenToolCalls() async throws {
        let home = makeHomeDirectory()
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let fileURL = downloads.appendingPathComponent("invoice-2026.pdf")
        try "invoice".write(to: fileURL, atomically: true, encoding: .utf8)

        let requestCounter = CounterBox()
        AskAgentMockURLProtocol.requestHandler = { request, client, protocolInstance in
            XCTAssertEqual(request.url?.path, "/v1/responses")
            let index = requestCounter.increment()
            let requestBody = try XCTUnwrap(request.httpBody ?? requestBody(from: request))
            let requestJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)

            let body: String
            if index == 1 {
                let input = try XCTUnwrap(requestJSON["input"] as? [[String: Any]])
                let contents = input.compactMap { $0["content"] as? String }
                let instructions = requestJSON["instructions"] as? String
                XCTAssertEqual(requestJSON["store"] as? Bool, true)
                XCTAssertTrue(contents.contains(where: { $0.contains("在下载文件夹里查找 invoice") }))
                XCTAssertTrue(instructions?.contains("You are NexHub Ask running in agent mode.") == true || instructions?.contains("你现在运行在 NexHub Ask 的 agent 模式。") == true)
                body = #"""
                {"id":"resp_1","output":[{"type":"function_call","call_id":"call_search_1","name":"search_files","arguments":"{\"roots\":[\"downloads\"],\"name_contains\":\"invoice\",\"extensions\":[\"pdf\"]}"}]}
                """#
            } else {
                XCTAssertEqual(requestJSON["previous_response_id"] as? String, "resp_1")
                XCTAssertEqual(requestJSON["store"] as? Bool, true)
                let instructions = requestJSON["instructions"] as? String
                XCTAssertTrue(instructions?.contains("You are NexHub Ask running in agent mode.") == true || instructions?.contains("你现在运行在 NexHub Ask 的 agent 模式。") == true)
                let input = try XCTUnwrap(requestJSON["input"] as? [[String: Any]])
                XCTAssertEqual(input.count, 1)
                XCTAssertEqual(input.first?["type"] as? String, "function_call_output")
                XCTAssertEqual(input.first?["call_id"] as? String, "call_search_1")
                let output = try XCTUnwrap(input.first?["output"] as? String)
                XCTAssertTrue(output.contains("invoice-2026.pdf"))
                body = #"""
                {"id":"resp_2","output_text":"我已经找到下载目录里的 invoice-2026.pdf，并把结果附在下方卡片里。","output":[{"type":"message","content":[{"type":"output_text","text":"我已经找到下载目录里的 invoice-2026.pdf，并把结果附在下方卡片里。"}]}]}
                """#
            }

            client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let workspace = WorkspaceControllerMock()
        let operatorRuntime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: workspace,
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { home }
        )
        let runtime = AskSkillRuntimeService(
            knowledgeBaseStore: ReplyKnowledgeBaseStore(
                fileManager: .default,
                rootDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            session: makeSession(),
            diagnosticsLogger: makeLogger(),
            askOperatorRuntime: operatorRuntime,
            aiConfigurationProvider: {
                try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")
            }
        )

        let response = try await runtime.streamAsk(
            request: makeRequest(
                sessionID: "stream-operator",
                messages: [.init(role: .user, content: "在下载文件夹里查找 invoice")]
            ),
            onEvent: { _ in }
        )

        XCTAssertEqual(requestCounter.snapshot(), 2)
        XCTAssertEqual(response.metadata["agent_handled"], "true")
        XCTAssertEqual(response.cards.first?.action?.type, .revealInFinder)
        XCTAssertTrue(response.message.contains("invoice"))
    }

    func testSkillRuntimeStreamAskCompressesOlderConversationBeforeAgentRequest() async throws {
        let veryLongAssistantText = String(repeating: "旧内容很长。", count: 5000)
        AskAgentMockURLProtocol.requestHandler = { request, client, protocolInstance in
            let requestBody = try XCTUnwrap(request.httpBody ?? requestBody(from: request))
            let requestJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let input = try XCTUnwrap(requestJSON["input"] as? [[String: Any]])
            let contents = input.compactMap { $0["content"] as? String }
            let instructions = requestJSON["instructions"] as? String

            XCTAssertTrue(contents.contains(where: { $0.contains("最新问题：现在只告诉我还剩多少个文件") }))
            XCTAssertTrue(instructions?.contains("较早轮次的压缩记忆") == true)
            XCTAssertTrue(instructions?.contains("较早的用户目标") == true)
            XCTAssertFalse(contents.contains(where: { $0.contains(veryLongAssistantText.prefix(200)) }))

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = #"""
            {"id":"resp_trim_1","output_text":"当前还剩 0 个待处理文件。","output":[{"type":"message","content":[{"type":"output_text","text":"当前还剩 0 个待处理文件。"}]}]}
            """#
            client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        let runtime = AskSkillRuntimeService(
            knowledgeBaseStore: ReplyKnowledgeBaseStore(
                fileManager: .default,
                rootDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            session: makeSession(),
            diagnosticsLogger: makeLogger(),
            askOperatorRuntime: AskOperatorRuntime(
                fileManager: .default,
                workspaceController: WorkspaceControllerMock(),
                browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
                diagnosticsLogger: makeLogger(),
                sessionStore: AskOperatorSessionStore(),
                homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
            ),
            aiConfigurationProvider: {
                try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")
            }
        )

        let response = try await runtime.streamAsk(
            request: makeRequest(
                sessionID: "trim-long-ask",
                messages: [
                    .init(role: .user, content: "第一轮问题"),
                    .init(role: .assistant, content: veryLongAssistantText),
                    .init(role: .user, content: "第二轮问题"),
                    .init(role: .assistant, content: "第二轮回答，里面也提到了之前的大列表。"),
                    .init(role: .user, content: "第三轮问题"),
                    .init(role: .assistant, content: "第三轮回答"),
                    .init(role: .assistant, content: "中间回答"),
                    .init(role: .user, content: "最新问题：现在只告诉我还剩多少个文件")
                ]
            ),
            onEvent: { _ in }
        )

        XCTAssertEqual(response.message, "当前还剩 0 个待处理文件。")
    }

    func testSkillRuntimeAskFailureMessageExplainsContextLimit() async throws {
        let runtime = AskSkillRuntimeService(
            knowledgeBaseStore: ReplyKnowledgeBaseStore(
                fileManager: .default,
                rootDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            session: makeSession(),
            diagnosticsLogger: makeLogger(),
            askOperatorRuntime: AskOperatorRuntime(
                fileManager: .default,
                workspaceController: WorkspaceControllerMock(),
                browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
                diagnosticsLogger: makeLogger(),
                sessionStore: AskOperatorSessionStore(),
                homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
            ),
            askAgentRuntime: FailingAskAgentRuntime(error: AgentLLMClientError.server("maximum context length exceeded")),
            aiConfigurationProvider: {
                try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")
            }
        )

        let response = try await runtime.streamAsk(
            request: makeRequest(
                sessionID: "ask-context-limit",
                messages: [
                    .init(role: .user, content: "第一轮"),
                    .init(role: .assistant, content: "回答"),
                    .init(role: .user, content: "继续说")
                ]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(response.message.contains("上下文已经超过"))
        XCTAssertFalse(response.message.contains("当前 AI 服务不可用"))
    }

    func testToolPayloadCompactorTruncatesLargeArraysForModelContext() {
        let longPaths = (0..<40).map { "/Users/nefish/Desktop/\($0)-very-long-file-name-that-should-not-be-fully-echoed.png" }
        let compacted = AskAgentToolPayloadCompactor.compact([
            "snapshot_id": "snap_1",
            "match_count": 40,
            "paths": longPaths,
            "preview": Array(longPaths.prefix(5))
        ])

        XCTAssertEqual(compacted["snapshot_id"] as? String, "snap_1")
        XCTAssertEqual(compacted["match_count"] as? Int, 40)
        let paths = compacted["paths"] as? [String: Any]
        XCTAssertEqual(paths?["total_count"] as? Int, 40)
        let items = paths?["items"] as? [String]
        XCTAssertEqual(items?.count, 12)
        XCTAssertEqual(compacted["preview"] as? [String], Array(longPaths.prefix(5)))
    }

    func testInspectCurrentPageReturnsMatchedSnippets() async throws {
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(
                result: .success(
                    BrowserPageCaptureResult(
                        browserBundleID: "com.google.Chrome",
                        pageURL: URL(string: "https://platform.openai.com/docs/pricing")!,
                        canonicalURL: nil,
                        title: "Pricing",
                        text: """
                        Pricing overview
                        Responses API pricing is usage based.
                        Batch API pricing can be lower for asynchronous workloads.
                        """
                    )
                )
            ),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
        )

        let rawResponse = await runtime.handle(
            request: makeRequest(
                sessionID: "page-query",
                sourceBundleID: "com.google.Chrome",
                sourceAppName: "Google Chrome",
                messages: [.init(role: .user, content: "在当前网页里找 pricing")]
            ),
            onEvent: { _ in }
        )
        let response: AskSessionResponse = try XCTUnwrap(rawResponse)

        XCTAssertEqual(response.metadata["operator_action"], "inspect_page_query")
        XCTAssertTrue(response.message.contains("Pricing"))
        XCTAssertTrue(response.message.contains("usage based"))
        XCTAssertEqual(response.cards.first?.action?.type, .openURL)
    }

    func testPreviewCalendarIntentFallsBackToLatestUserMessageWhenArgumentsAreEmpty() async throws {
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
        )

        let result = await runtime.executeTool(
            named: "preview_calendar_intent",
            argumentsJSON: "{}",
            request: makeRequest(
                sessionID: "preview-calendar-fallback",
                messages: [.init(role: .user, content: "5分钟后提醒我喝水")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.data["intent_title"] as? String, "喝水")
    }

    func testCreateReminderFallsBackToLatestUserMessageWhenArgumentsAreEmpty() async throws {
        let expectation = expectation(description: "calendar creator called")
        let captureBox = IntentCaptureBox()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser },
            calendarEventCreator: { intent, _, completion in
                Task {
                    await captureBox.set(intent)
                }
                completion(true)
                expectation.fulfill()
            }
        )

        let result = await runtime.executeTool(
            named: "create_reminder",
            argumentsJSON: "{}",
            request: makeRequest(
                sessionID: "create-reminder-fallback",
                messages: [.init(role: .user, content: "5分钟后提醒我喝水")]
            ),
            onEvent: { _ in }
        )

        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertTrue(result.ok)
        let capturedIntent = await captureBox.intent
        XCTAssertEqual(capturedIntent?.title, "喝水")
        XCTAssertEqual(capturedIntent?.reminderMinutes, 0)
        XCTAssertEqual(result.data["calendar_item_title"] as? String, "喝水")
        XCTAssertNotNil(result.data["calendar_item_receipt_json"] as? String)
    }

    func testDeleteReminderFallsBackToLatestCreatedReminderInSession() async throws {
        let createExpectation = expectation(description: "calendar creator called")
        let deleteExpectation = expectation(description: "calendar deleter called")
        let captureBox = IntentCaptureBox()
        let receiptBox = ReceiptCaptureBox()
        let sessionStore = AskOperatorSessionStore()
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            diagnosticsLogger: makeLogger(),
            sessionStore: sessionStore,
            homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser },
            calendarEventCreator: { intent, _, completion in
                Task {
                    await captureBox.set(intent)
                }
                completion(true)
                createExpectation.fulfill()
            },
            calendarItemDeleter: { receipt, completion in
                Task {
                    await receiptBox.set(receipt)
                }
                completion(true)
                deleteExpectation.fulfill()
            }
        )

        let createResult = await runtime.executeTool(
            named: "create_reminder",
            argumentsJSON: "{}",
            request: makeRequest(
                sessionID: "delete-reminder-fallback",
                messages: [.init(role: .user, content: "5分钟后提醒我喝水")]
            ),
            onEvent: { _ in }
        )
        XCTAssertTrue(createResult.ok)

        let deleteResult = await runtime.executeTool(
            named: "delete_reminder",
            argumentsJSON: "{}",
            request: makeRequest(
                sessionID: "delete-reminder-fallback",
                messages: [.init(role: .user, content: "撤销掉这个提醒")]
            ),
            onEvent: { _ in }
        )

        await fulfillment(of: [createExpectation, deleteExpectation], timeout: 1)
        XCTAssertTrue(deleteResult.ok)
        let capturedIntent = await captureBox.intent
        XCTAssertEqual(capturedIntent?.title, "喝水")
        let capturedReceipt = await receiptBox.receipt
        XCTAssertEqual(capturedReceipt?.title, "喝水")
        XCTAssertEqual(capturedReceipt?.kind, .reminder)
    }

    func testPreviewAutomationJobStoresDraftForAsk() async throws {
        let automationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: automationRoot, withIntermediateDirectories: true)
        let automationStore = AskAutomationStore(
            fileManager: .default,
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: automationRoot
        )
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            automationStore: automationStore,
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
        )

        let result = await runtime.executeTool(
            named: "preview_automation_job",
            argumentsJSON: #"{"spec":"每天 9 点帮我检查 OpenAI 官网更新，有变化就告诉我"}"#,
            request: makeRequest(
                sessionID: "preview-automation",
                messages: [.init(role: .user, content: "以后每天 9 点帮我检查 OpenAI 官网更新，有变化就告诉我")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(result.ok)
        let draftID = try XCTUnwrap(result.data["pending_automation_draft_id"] as? String)
        XCTAssertNotNil(automationStore.draft(id: draftID))
    }

    func testCreateAutomationJobPersistsJob() async throws {
        let automationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: automationRoot, withIntermediateDirectories: true)
        let automationStore = AskAutomationStore(
            fileManager: .default,
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: automationRoot
        )
        let runtime = AskOperatorRuntime(
            fileManager: .default,
            workspaceController: WorkspaceControllerMock(),
            browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
            automationStore: automationStore,
            diagnosticsLogger: makeLogger(),
            sessionStore: AskOperatorSessionStore(),
            homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
        )

        let preview = await runtime.executeTool(
            named: "preview_automation_job",
            argumentsJSON: #"{"spec":"每周一上午 10 点整理下载文件夹里的 PDF，并写个总结到知识库"}"#,
            request: makeRequest(
                sessionID: "create-automation",
                messages: [.init(role: .user, content: "每周一上午 10 点整理下载文件夹里的 PDF，并写个总结到知识库")]
            ),
            onEvent: { _ in }
        )
        let draftID = try XCTUnwrap(preview.data["pending_automation_draft_id"] as? String)

        let create = await runtime.executeTool(
            named: "create_automation_job",
            argumentsJSON: #"{"draft_id":"\#(draftID)"}"#,
            request: makeRequest(
                sessionID: "create-automation",
                messages: [.init(role: .user, content: "保存这个定时任务")]
            ),
            onEvent: { _ in }
        )

        XCTAssertTrue(create.ok)
        XCTAssertEqual(automationStore.listJobs().count, 1)
        XCTAssertEqual(automationStore.listJobs().first?.trigger.kind, .weekly)
        XCTAssertNotNil(create.data["saved_automation_job_id"] as? String)
    }

    func testSkillRuntimeStreamAskDelegatesAutomationJudgmentToAgentRuntime() async throws {
        let automationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: automationRoot, withIntermediateDirectories: true)
        let automationStore = AskAutomationStore(
            fileManager: .default,
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: automationRoot
        )
        let agentRuntime = RecordingAskAgentRuntime(
            response: AskSessionResponse(
                message: "agent decided to preview an automation",
                cards: [],
                metadata: [
                    "agent_handled": "true",
                    "pending_automation_draft_id": "draft_from_agent"
                ]
            )
        )
        let runtime = AskSkillRuntimeService(
            knowledgeBaseStore: ReplyKnowledgeBaseStore(
                fileManager: .default,
                rootDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            session: makeSession(),
            diagnosticsLogger: makeLogger(),
            askOperatorRuntime: AskOperatorRuntime(
                fileManager: .default,
                workspaceController: WorkspaceControllerMock(),
                browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
                automationStore: automationStore,
                diagnosticsLogger: makeLogger(),
                sessionStore: AskOperatorSessionStore(),
                homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
            ),
            askAgentRuntime: agentRuntime,
            aiConfigurationProvider: {
                try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")
            }
        )

        let response = try await runtime.streamAsk(
            request: makeRequest(
                sessionID: "stream-automation-local",
                messages: [
                    .init(role: .user, content: "先看看我上次问了什么"),
                    .init(role: .assistant, content: "你上次在问官网更新。"),
                    .init(role: .user, content: "每天 9 点帮我检查 OpenAI 官网更新，有变化就告诉我")
                ]
            ),
            onEvent: { _ in }
        )

        XCTAssertEqual(response.message, "agent decided to preview an automation")
        XCTAssertEqual(response.metadata["pending_automation_draft_id"], "draft_from_agent")
        XCTAssertEqual(agentRuntime.runCount, 1)
        XCTAssertEqual(agentRuntime.lastUserMessage, "每天 9 点帮我检查 OpenAI 官网更新，有变化就告诉我")
    }

    func testSkillRuntimeStreamAskDelegatesRelativeOneShotAutomationJudgmentToAgentRuntime() async throws {
        let automationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: automationRoot, withIntermediateDirectories: true)
        let automationStore = AskAutomationStore(
            fileManager: .default,
            notificationCenter: NotificationCenter(),
            rootDirectoryURL: automationRoot
        )
        let agentRuntime = RecordingAskAgentRuntime(
            response: AskSessionResponse(
                message: "agent handled the delayed action",
                cards: [],
                metadata: [
                    "agent_handled": "true"
                ]
            )
        )
        let runtime = AskSkillRuntimeService(
            knowledgeBaseStore: ReplyKnowledgeBaseStore(
                fileManager: .default,
                rootDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            ),
            session: makeSession(),
            diagnosticsLogger: makeLogger(),
            askOperatorRuntime: AskOperatorRuntime(
                fileManager: .default,
                workspaceController: WorkspaceControllerMock(),
                browserPageProvider: BrowserPageProviderMock(result: .failure(.init(kind: .browserCaptureUnavailable, message: "unsupported"))),
                automationStore: automationStore,
                diagnosticsLogger: makeLogger(),
                sessionStore: AskOperatorSessionStore(),
                homeDirectoryProvider: { FileManager.default.homeDirectoryForCurrentUser }
            ),
            askAgentRuntime: agentRuntime,
            aiConfigurationProvider: {
                try LLMRequestConfiguration.from(provider: "openai", model: "gpt-4.1-mini", apiKey: "test-key")
            }
        )

        let response = try await runtime.streamAsk(
            request: makeRequest(
                sessionID: "stream-relative-automation-local",
                messages: [
                    .init(role: .user, content: "1分钟后帮我打开B站")
                ]
            ),
            onEvent: { _ in }
        )

        XCTAssertEqual(response.message, "agent handled the delayed action")
        XCTAssertEqual(agentRuntime.runCount, 1)
        XCTAssertEqual(agentRuntime.lastUserMessage, "1分钟后帮我打开B站")
    }

    private func makeRequest(
        sessionID: String,
        sourceBundleID: String? = "com.apple.finder",
        sourceAppName: String? = "Finder",
        kernelMetadata: AskInvocationMetadata = [:],
        messages: [AskMessage]
    ) -> AskSessionRequest {
        AskSessionRequest(
            messages: messages,
            metadata: AskSessionMetadata(
                sessionID: sessionID,
                sourceBundleID: sourceBundleID,
                sourceAppName: sourceAppName,
                frame: .zero,
                kernelMetadata: kernelMetadata
            ),
            uiLanguage: "zh",
            responseLanguage: "zh"
        )
    }

    private func makeHomeDirectory(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop", isDirectory: true), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Downloads", isDirectory: true), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents", isDirectory: true), withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to prepare home directory: \(error)", file: file, line: line)
        }
        return home
    }

    private func makeLogger() -> DiagnosticsLogger {
        DiagnosticsLogger(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),
            maxFileSizeBytes: 4096
        )
    }

    private func makeMCPRootDirectory(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to prepare MCP root directory: \(error)", file: file, line: line)
        }
        return root
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AskAgentMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeSettings(file: StaticString = #filePath, line: UInt = #line) -> AppSettings {
        let suiteName = "NexHubTests.AskOperatorRuntime.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults", file: file, line: line)
            return .shared
        }
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults, secretsStore: TestSecretStore(), diagnosticsLogger: makeLogger())
    }

    private func clearSharedApprovalRouter(file: StaticString = #filePath, line: UInt = #line) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await AskInMemoryApprovalRouter.shared.clearAll()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 1) != .success {
            XCTFail("Timed out clearing shared approval router", file: file, line: line)
        }
    }
}

private func requestBody(from request: URLRequest) -> Data? {
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }

    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read <= 0 {
            break
        }
        data.append(buffer, count: read)
    }
    return data.isEmpty ? nil : data
}

private func jsonString(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object)
    guard let string = String(data: data, encoding: .utf8) else {
        throw NSError(domain: "AskOperatorRuntimeTests", code: 1)
    }
    return string
}

private final class CounterBox {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class AskAgentMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest, URLProtocolClient?, URLProtocol) throws -> Void)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("AskAgentMockURLProtocol.requestHandler not set")
        }

        do {
            try handler(request, client, self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct FailingAskAgentRuntime: AskAgentRuntimeProviding {
    let error: Error

    func run(
        request: AskSessionRequest,
        compiledMessages: [LLMChatMessage],
        configuration: LLMRequestConfiguration,
        responseProfile: AskResponseProfile,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async throws -> AskSessionResponse {
        throw error
    }
}

private final class RecordingAskAgentRuntime: AskAgentRuntimeProviding {
    let response: AskSessionResponse

    private let lock = NSLock()
    private(set) var runCount = 0
    private(set) var lastUserMessage: String?

    init(response: AskSessionResponse) {
        self.response = response
    }

    func run(
        request: AskSessionRequest,
        compiledMessages: [LLMChatMessage],
        configuration: LLMRequestConfiguration,
        responseProfile: AskResponseProfile,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async throws -> AskSessionResponse {
        lock.withLock {
            runCount += 1
            lastUserMessage = request.messages.last(where: { $0.role == .user })?.content
        }
        return response
    }
}

private final class WorkspaceControllerMock: AskOperatorWorkspaceControlling {
    struct OpenedURL {
        let url: URL
        let preferredBundleID: String?
    }

    private(set) var openedURLs: [OpenedURL] = []
    private(set) var openedFiles: [URL] = []
    private(set) var revealedFiles: [URL] = []

    func openURL(_ url: URL, preferredBundleID: String?) async -> Bool {
        openedURLs.append(.init(url: url, preferredBundleID: preferredBundleID))
        return true
    }

    func openFile(_ url: URL) async -> Bool {
        openedFiles.append(url)
        return true
    }

    func revealInFinder(_ url: URL) async {
        revealedFiles.append(url)
    }
}

private final class BrowserPageProviderMock: AskOperatorBrowserPageProviding {
    let result: Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure>
    private(set) var requestedBundleIDs: [String?] = []

    init(result: Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure>) {
        self.result = result
    }

    func currentPage(fromBundleID bundleID: String?) async -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure> {
        requestedBundleIDs.append(bundleID)
        return result
    }
}

private final class TestSecretStore: SecretStoring {
    private var storage: [String: String] = [:]

    func string(for account: String) -> String? {
        storage[account]
    }

    @discardableResult
    func setString(_ value: String, for account: String) -> Bool {
        storage[account] = value
        return true
    }

    @discardableResult
    func removeString(for account: String) -> Bool {
        storage.removeValue(forKey: account)
        return true
    }
}
