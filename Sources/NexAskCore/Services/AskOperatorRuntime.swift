import AppKit
import Foundation
import NexShared

protocol AskOperatorRuntimeProviding {
    func handle(
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskSessionResponse?
}

protocol AskOperatorWorkspaceControlling {
    func openURL(_ url: URL, preferredBundleID: String?) async -> Bool
    func openFile(_ url: URL) async -> Bool
    func revealInFinder(_ url: URL) async
}

typealias AskOperatorCalendarEventCreator = @Sendable (CalendarEventIntent, Bool, @escaping (Bool) -> Void) -> Void
typealias AskOperatorCalendarItemDeleter = @Sendable (CalendarCreatedItemReceipt, @escaping (Bool) -> Void) -> Void

protocol AskOperatorBrowserPageProviding {
    func currentPage(fromBundleID bundleID: String?) async -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure>
}

extension BrowserPageCaptureService: AskOperatorBrowserPageProviding {
    func currentPage(fromBundleID bundleID: String?) async -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure> {
        await captureReadableCurrentPage(fromBundleID: bundleID)
    }
}

private struct AskOperatorBrowserPageProviderAdapter: BrowserPageCaptureProviding {
    let base: any AskOperatorBrowserPageProviding

    func captureReadablePage(matching targetURL: URL) async -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure> {
        .failure(
            KnowledgeBaseCaptureFailure(
                kind: .browserCaptureUnavailable,
                message: L10n.text(
                    zhHans: "这个浏览器注入只支持读取当前页面。",
                    en: "This browser injection only supports reading the current page."
                )
            )
        )
    }

    func captureReadableCurrentPage(fromBundleID bundleID: String?) async -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure> {
        await base.currentPage(fromBundleID: bundleID)
    }
}

final class DefaultAskOperatorWorkspaceController: AskOperatorWorkspaceControlling {
    func openURL(_ url: URL, preferredBundleID: String?) async -> Bool {
        guard let preferredBundleID,
              AskOperatorSupportedBrowser.bundleIDs.contains(preferredBundleID) else {
            return await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }

        let appURL = await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferredBundleID)
        }
        guard let appURL else {
            return await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }
    }

    func openFile(_ url: URL) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    func revealInFinder(_ url: URL) async {
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

actor AskOperatorSessionStore {
    struct BrowserContext: Equatable {
        let url: URL
        let preferredBundleID: String?
        let createdAt: Date
    }

    private var snapshots: [String: AskDirectorySnapshot] = [:]
    private var selections: [String: AskPathSelection] = [:]
    private var operations: [String: AskStagedOperation] = [:]
    private var recentCalendarReceiptsBySessionID: [String: [CalendarCreatedItemReceipt]] = [:]
    private var recentBrowserContextBySessionID: [String: BrowserContext] = [:]

    func snapshot(for snapshotID: String) -> AskDirectorySnapshot? {
        snapshots[snapshotID]
    }

    func setSnapshot(_ snapshot: AskDirectorySnapshot) {
        snapshots[snapshot.id] = snapshot
    }

    func selection(for selectionID: String) -> AskPathSelection? {
        selections[selectionID]
    }

    func setSelection(_ selection: AskPathSelection) {
        selections[selection.id] = selection
    }

    func operation(for operationID: String) -> AskStagedOperation? {
        operations[operationID]
    }

    func setOperation(_ operation: AskStagedOperation) {
        operations[operation.id] = operation
    }

    func pendingMove(for sessionID: String) -> AskStagedOperation? {
        operations.values
            .filter { $0.sessionID == sessionID && $0.status == .awaitingApproval }
            .max(by: { $0.createdAt < $1.createdAt })
    }

    func appendCalendarReceipt(_ receipt: CalendarCreatedItemReceipt, for sessionID: String) {
        var receipts = recentCalendarReceiptsBySessionID[sessionID] ?? []
        receipts.append(receipt)
        if receipts.count > 8 {
            receipts.removeFirst(receipts.count - 8)
        }
        recentCalendarReceiptsBySessionID[sessionID] = receipts
    }

    func latestCalendarReceipt(
        for sessionID: String,
        kind: CalendarCreatedItemReceipt.Kind? = nil
    ) -> CalendarCreatedItemReceipt? {
        let receipts = recentCalendarReceiptsBySessionID[sessionID] ?? []
        if let kind {
            return receipts.last(where: { $0.kind == kind })
        }
        return receipts.last
    }

    func removeCalendarReceipt(_ receipt: CalendarCreatedItemReceipt, for sessionID: String) {
        guard var receipts = recentCalendarReceiptsBySessionID[sessionID] else { return }
        if let index = receipts.lastIndex(of: receipt) {
            receipts.remove(at: index)
        } else if let index = receipts.lastIndex(where: {
            $0.kind == receipt.kind
                && $0.title == receipt.title
                && $0.date == receipt.date
                && $0.time == receipt.time
        }) {
            receipts.remove(at: index)
        }
        recentCalendarReceiptsBySessionID[sessionID] = receipts
    }

    func setRecentBrowserContext(_ context: BrowserContext, for sessionID: String) {
        recentBrowserContextBySessionID[sessionID] = context
    }

    func recentBrowserContext(for sessionID: String) -> BrowserContext? {
        recentBrowserContextBySessionID[sessionID]
    }

    func clearRecentBrowserContext(for sessionID: String) {
        recentBrowserContextBySessionID.removeValue(forKey: sessionID)
    }
}

final class AskOperatorRuntime: AskOperatorRuntimeProviding, AskToolProviding, AskToolExecuting, AskMCPResourceCatalogBacked, AskMCPConnectionStoreBacked {
    private enum FileSearchAction {
        case list
        case openSingle
        case revealSingle
    }

    private enum LegacyApprovalStrategy {
        case trustExplicitIntent
        case policyDriven
    }

    private enum CompatibilityBridgeKind: String {
        case desktopDirectoryFlow
        case workspaceContext
        case workspaceMutation
        case taskControl
        case desktopPresentation
        case browserAction
        case appWriteback
        case automationDraft
        case uncataloged
    }

    private enum CompatibilityOwnership: String {
        case kernelOwned
        case stateMirroring
        case behaviorOwning
    }

    private struct CompatibilityBridgeDescriptor {
        let kind: CompatibilityBridgeKind
        let approvalStrategy: LegacyApprovalStrategy
        let ownership: CompatibilityOwnership
    }

    private static let compatibilityBridgeDescriptors: [AskCapabilityID: CompatibilityBridgeDescriptor] = [
        "desktop.snapshot_directory": .init(kind: .desktopDirectoryFlow, approvalStrategy: .trustExplicitIntent, ownership: .stateMirroring),
        "desktop.stage_move_operation": .init(kind: .desktopDirectoryFlow, approvalStrategy: .trustExplicitIntent, ownership: .stateMirroring),
        "desktop.commit_move_operation": .init(kind: .desktopDirectoryFlow, approvalStrategy: .policyDriven, ownership: .stateMirroring),
        "desktop.cancel_move_operation": .init(kind: .desktopDirectoryFlow, approvalStrategy: .trustExplicitIntent, ownership: .stateMirroring),
        "workspace.create_directory": .init(kind: .workspaceMutation, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.list_roots": .init(kind: .workspaceContext, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.set_active_root": .init(kind: .workspaceContext, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.snapshot_tree": .init(kind: .workspaceContext, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.glob_paths": .init(kind: .workspaceContext, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.enter_plan_mode": .init(kind: .taskControl, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.exit_plan_mode": .init(kind: .taskControl, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.set_execution_budget": .init(kind: .taskControl, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "system.list_tasks": .init(kind: .taskControl, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "system.get_task": .init(kind: .taskControl, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "system.update_task": .init(kind: .taskControl, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "system.stop_task": .init(kind: .taskControl, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "system.spawn_subtask": .init(kind: .taskControl, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "system.write_todo": .init(kind: .taskControl, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "system.resume_task": .init(kind: .taskControl, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.grep_text": .init(kind: .workspaceContext, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.read_file": .init(kind: .workspaceContext, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.write_file": .init(kind: .workspaceMutation, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.git_status": .init(kind: .workspaceContext, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.git_diff": .init(kind: .workspaceContext, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.run_shell_command": .init(kind: .workspaceMutation, approvalStrategy: .policyDriven, ownership: .stateMirroring),
        "workspace.apply_patch_preview": .init(kind: .workspaceMutation, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "workspace.commit_changes": .init(kind: .workspaceMutation, approvalStrategy: .policyDriven, ownership: .stateMirroring),
        "desktop.open_path": .init(kind: .desktopPresentation, approvalStrategy: .trustExplicitIntent, ownership: .behaviorOwning),
        "desktop.reveal_in_finder": .init(kind: .desktopPresentation, approvalStrategy: .trustExplicitIntent, ownership: .kernelOwned),
        "browser.open_url": .init(kind: .browserAction, approvalStrategy: .trustExplicitIntent, ownership: .stateMirroring),
        "browser.search_web": .init(kind: .browserAction, approvalStrategy: .trustExplicitIntent, ownership: .stateMirroring),
        "browser.read_current_page": .init(kind: .browserAction, approvalStrategy: .trustExplicitIntent, ownership: .behaviorOwning),
        "app.copy_to_clipboard": .init(kind: .appWriteback, approvalStrategy: .trustExplicitIntent, ownership: .behaviorOwning),
        "app.write_back_to_frontmost_input": .init(kind: .appWriteback, approvalStrategy: .trustExplicitIntent, ownership: .behaviorOwning),
        "app.replace_frontmost_selection": .init(kind: .appWriteback, approvalStrategy: .trustExplicitIntent, ownership: .behaviorOwning),
        "time.preview_automation_job": .init(kind: .automationDraft, approvalStrategy: .trustExplicitIntent, ownership: .stateMirroring),
        "time.create_automation_job": .init(kind: .automationDraft, approvalStrategy: .trustExplicitIntent, ownership: .stateMirroring)
    ]

    static let compatibilityCapabilityInventory: Set<AskCapabilityID> = Set(compatibilityBridgeDescriptors.keys)
    static let compatibilityKernelOwnedCapabilities: Set<AskCapabilityID> = Set(
        compatibilityBridgeDescriptors.compactMap { capabilityID, descriptor in
            descriptor.ownership == .kernelOwned ? capabilityID : nil
        }
    )
    static let compatibilityStateMirroringCapabilities: Set<AskCapabilityID> = Set(
        compatibilityBridgeDescriptors.compactMap { capabilityID, descriptor in
            descriptor.ownership == .stateMirroring ? capabilityID : nil
        }
    )
    static let compatibilityBehaviorOwningCapabilities: Set<AskCapabilityID> = Set(
        compatibilityBridgeDescriptors.compactMap { capabilityID, descriptor in
            descriptor.ownership == .behaviorOwning ? capabilityID : nil
        }
    )
    static let compatibilityCapabilitiesFollowingKernelApproval: Set<AskCapabilityID> = Set(
        compatibilityBridgeDescriptors.compactMap { capabilityID, descriptor in
            descriptor.approvalStrategy == .policyDriven ? capabilityID : nil
        }
    )

    private enum KernelSnapshotResolution {
        case success(AskDirectorySnapshot)
        case failure(AskToolExecutionResult)
    }

    private enum KernelCurrentPageResolution {
        case success(KernelCurrentPagePayload)
        case failure(AskToolExecutionResult)
    }

    private struct KernelCurrentPagePayload {
        let url: URL
        let title: String
        let text: String
    }

    private struct CurrentPageCapabilityPayload {
        let result: AskCapabilityExecutionResult
        let pageURL: String
        let pageTitle: String
        let pageCard: [SkillResultCard]
    }

    private enum WorkspaceMutationBridgeKind {
        case runShellCommand
        case commitChanges

        var capabilityID: AskCapabilityID {
            switch self {
            case .runShellCommand:
                return "workspace.run_shell_command"
            case .commitChanges:
                return "workspace.commit_changes"
            }
        }

        func preparingStatus(languageCode: String) -> String {
            switch self {
            case .runShellCommand:
                return L10n.text(
                    languageCode: languageCode,
                    zhHans: "正在准备工作区命令…",
                    en: "Preparing the workspace command…"
                )
            case .commitChanges:
                return L10n.text(
                    languageCode: languageCode,
                    zhHans: "正在准备把 patch 写入工作区…",
                    en: "Preparing to apply the patch into the workspace…"
                )
            }
        }

        func waitingApprovalSummary(responseLanguage: String) -> String {
            switch self {
            case .runShellCommand:
                return L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "这个工作区命令正在等待你的确认。",
                    en: "This workspace command is waiting for your approval."
                )
            case .commitChanges:
                return L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "这个 patch 正在等待你的确认。",
                    en: "This patch is waiting for your approval."
                )
            }
        }

        func failureFallback(responseLanguage: String) -> String {
            switch self {
            case .runShellCommand:
                return L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "工作区命令执行失败。",
                    en: "The workspace command failed."
                )
            case .commitChanges:
                return L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "把 patch 应用到工作区失败。",
                    en: "Failed to apply the patch into the workspace."
                )
            }
        }
    }

    private struct FileSearchCriteria: Equatable {
        let rootDirectories: [URL]
        let extensionFilters: [String]
        let nameContains: String?
        let directChildrenOnly: Bool
        let includeDirectories: Bool
    }

    private enum Command {
        case createFolder(name: String, directory: URL)
        case searchFiles(criteria: FileSearchCriteria, action: FileSearchAction)
        case moveFiles(criteria: FileSearchCriteria, destinationDirectory: URL, createDestinationIfNeeded: Bool)
        case openPath(URL)
        case revealPath(URL)
        case openURL(URL, preferredBrowserBundleID: String?)
        case searchWeb(query: String, preferredBrowserBundleID: String?)
        case inspectCurrentPage(query: String?)
        case mixedPlan
    }

    private enum AppWritebackBridgeKind {
        case clipboard
        case frontmostInput
        case selectionReplacement
    }

    private let fileManager: FileManager
    private let workspaceController: AskOperatorWorkspaceControlling
    private let urlSession: URLSession
    private let knowledgeBaseStore: ReplyKnowledgeBaseStore
    private let automationStore: AskAutomationStore
    private let automationDraftParser: AskAutomationDraftParser
    private let diagnosticsLogger: DiagnosticsLogger
    private let sessionStore: AskOperatorSessionStore
    private let kernelApprovalRouter: AskInMemoryApprovalRouter
    private let agentKernel: AskAgentKernel
    let mcpResourceCatalog: any AskMCPResourceCatalogProviding
    let mcpConnectionStore: AskMCPConnectionStore
    private let homeDirectoryProvider: () -> URL
    private let calendarEventCreator: AskOperatorCalendarEventCreator
    private let calendarItemDeleter: AskOperatorCalendarItemDeleter

    init(
        fileManager: FileManager = .default,
        workspaceController: AskOperatorWorkspaceControlling = DefaultAskOperatorWorkspaceController(),
        browserPageProvider: (any AskOperatorBrowserPageProviding)? = nil,
        urlSession: URLSession = .shared,
        knowledgeBaseStore: ReplyKnowledgeBaseStore = .shared,
        automationStore: AskAutomationStore = .shared,
        automationDraftParser: AskAutomationDraftParser = .shared,
        diagnosticsLogger: DiagnosticsLogger = .shared,
        sessionStore: AskOperatorSessionStore = AskOperatorSessionStore(),
        kernelApprovalRouter: AskInMemoryApprovalRouter = .shared,
        agentKernel: AskAgentKernel? = nil,
        mcpResourceCatalog: any AskMCPResourceCatalogProviding = AskSharedMCPResourceCatalog.shared,
        mcpConnectionStore: AskMCPConnectionStore = .shared,
        homeDirectoryProvider: @escaping () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        calendarEventCreator: @escaping AskOperatorCalendarEventCreator = { intent, revealInCalendar, completion in
            CalendarService.createEvent(from: intent, revealInCalendar: revealInCalendar, completion: completion)
        },
        calendarItemDeleter: @escaping AskOperatorCalendarItemDeleter = { receipt, completion in
            CalendarService.deleteItem(matching: receipt, completion: completion)
        }
    ) {
        self.fileManager = fileManager
        self.workspaceController = workspaceController
        self.urlSession = urlSession
        self.knowledgeBaseStore = knowledgeBaseStore
        self.automationStore = automationStore
        self.automationDraftParser = automationDraftParser
        self.diagnosticsLogger = diagnosticsLogger
        self.sessionStore = sessionStore
        self.kernelApprovalRouter = kernelApprovalRouter
        self.mcpConnectionStore = mcpConnectionStore
        if let agentKernel {
            self.agentKernel = agentKernel
        } else if browserPageProvider == nil, kernelApprovalRouter === AskInMemoryApprovalRouter.shared {
            self.agentKernel = .shared
        } else {
            let desktopExecutor = AskDesktopExecutor(
                fileManager: fileManager,
                homeDirectoryProvider: homeDirectoryProvider
            )
            let timeExecutor = AskTimeExecutor(
                automationDraftParser: automationDraftParser,
                automationStore: automationStore
            )
            let browserExecutor: AskBrowserExecutor
            if let browserPageProvider {
                browserExecutor = AskBrowserExecutor(
                    pageCaptureProvider: AskOperatorBrowserPageProviderAdapter(base: browserPageProvider),
                    urlOpener: { url, preferredBundleID in
                        await workspaceController.openURL(url, preferredBundleID: preferredBundleID)
                    }
                )
            } else {
                browserExecutor = AskBrowserExecutor(
                    urlOpener: { url, preferredBundleID in
                        await workspaceController.openURL(url, preferredBundleID: preferredBundleID)
                    }
                )
            }
            self.agentKernel = AskAgentKernel(
                dependencies: .default(
                    approvalRouter: kernelApprovalRouter,
                    timeExecutor: timeExecutor,
                    desktopExecutor: desktopExecutor,
                    browserExecutor: browserExecutor
                )
            )
        }
        self.mcpResourceCatalog = mcpResourceCatalog
        self.homeDirectoryProvider = homeDirectoryProvider
        self.calendarEventCreator = calendarEventCreator
        self.calendarItemDeleter = calendarItemDeleter
    }

    func handle(
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskSessionResponse? {
        guard let latestUserMessage = request.messages.last(where: { $0.role == .user })?.content,
              !latestUserMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if let response = await resolvePendingMoveIfNeeded(
            request: request,
            latestUserMessage: latestUserMessage,
            onEvent: onEvent
        ) {
            return response
        }

        guard AskOperatorSupport.directive(for: request.messages) != nil else {
            return nil
        }

        guard let command = parseCommand(from: latestUserMessage, metadata: request.metadata) else {
            return nil
        }

        switch command {
        case .createFolder(let name, let directory):
            let result = await createFolderViaKernel(
                named: name,
                in: directory,
                request: request,
                onEvent: onEvent
            )
            return sessionResponse(
                from: result,
                request: request,
                successAction: "create_folder",
                failureAction: "create_folder_failed"
            )
        case .searchFiles(let criteria, let action):
            return await searchFiles(
                criteria: criteria,
                action: action,
                request: request,
                onEvent: onEvent
            )
        case .moveFiles(let criteria, let destinationDirectory, let createDestinationIfNeeded):
            return await prepareMove(
                criteria: criteria,
                destinationDirectory: destinationDirectory,
                createDestinationIfNeeded: createDestinationIfNeeded,
                request: request,
                onEvent: onEvent
            )
        case .openPath(let url):
            return await openPath(url, request: request, onEvent: onEvent)
        case .revealPath(let url):
            return await revealPath(url, request: request, onEvent: onEvent)
        case .openURL(let url, let preferredBrowserBundleID):
            let result = await openURLViaKernel(
                url,
                preferredBrowserBundleID: preferredBrowserBundleID,
                request: request,
                onEvent: onEvent
            )
            return sessionResponse(
                from: result,
                request: request,
                successAction: "open_url",
                failureAction: "open_url_failed"
            )
        case .searchWeb(let query, let preferredBrowserBundleID):
            let result = await searchWebViaKernel(
                query: query,
                preferredBrowserBundleID: preferredBrowserBundleID,
                openInBrowser: true,
                request: request,
                onEvent: onEvent
            )
            return sessionResponse(
                from: result,
                request: request,
                successAction: "web_search",
                failureAction: "web_search_failed"
            )
        case .inspectCurrentPage(let query):
            let result = await readCurrentPageViaKernel(
                query: query,
                request: request,
                onEvent: onEvent
            )
            return sessionResponse(
                from: result,
                request: request,
                successAction: query == nil ? "inspect_page" : "inspect_page_query",
                failureAction: "inspect_page_failed"
            )
        case .mixedPlan:
            return mixedPlanResponse(request: request)
        }
    }

    func availableTools(responseLanguage: String) -> [AskToolDefinition] {
        availableTools(context: .minimal(responseLanguage: responseLanguage))
    }

    func availableTools(context: AskToolPoolContext) -> [AskToolDefinition] {
        let responseLanguage = context.responseLanguage
        let tools = [
            AskToolDefinition(
                name: "snapshot_directory",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "扫描一个目录并生成可复用的快照 id，供后续 select / stage 工具继续使用。优先用它替代重复 search。",
                    en: "Scan a directory and return a reusable snapshot id that later select / stage tools can continue from. Prefer this over repeating searches."
                ),
                parameters: objectSchema(
                    properties: [
                        "directory": stringSchema("Directory alias or absolute path."),
                        "direct_children_only": boolSchema("When true, scan only the direct children of the directory."),
                        "include_directories": boolSchema("When true, matching directories may be included."),
                        "extensions": arraySchema(itemType: "string", description: "Optional file extensions without dots."),
                        "name_contains": stringSchema("Optional filename keyword to match.")
                    ],
                    required: ["directory"]
                )
            ),
            AskToolDefinition(
                name: "inspect_paths",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "读取明确路径列表的存在性和元数据。",
                    en: "Inspect explicit paths and return existence plus metadata."
                ),
                parameters: objectSchema(
                    properties: [
                        "paths": arraySchema(itemType: "string", description: "Explicit paths to inspect.")
                    ],
                    required: ["paths"]
                )
            ),
            AskToolDefinition(
                name: "select_from_snapshot",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "从已有 snapshot 中按扩展名、名称关键词或目录类型筛出稳定子集，并返回 selection id。",
                    en: "Filter a stable subset from an existing snapshot by extension, name keyword, or directory type and return a selection id."
                ),
                parameters: objectSchema(
                    properties: [
                        "snapshot_id": stringSchema("The snapshot id returned by snapshot_directory or search_files."),
                        "extensions": arraySchema(itemType: "string", description: "Optional file extensions without dots."),
                        "name_contains": stringSchema("Optional filename keyword to match."),
                        "files_only": boolSchema("When true, keep only regular files."),
                        "directories_only": boolSchema("When true, keep only directories.")
                    ],
                    required: ["snapshot_id"]
                )
            ),
            AskToolDefinition(
                name: "search_files",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "兼容工具：在桌面、下载、文稿或指定目录中查找文件。内部会生成 snapshot 和 selection，并返回完整匹配路径列表。",
                    en: "Compatibility tool: search files in Desktop, Downloads, Documents, or explicit directories. Internally this creates a snapshot and selection, then returns the full matching path list."
                ),
                parameters: objectSchema(
                    properties: [
                        "roots": arraySchema(itemType: "string", description: "Path aliases or absolute paths. Use desktop, downloads, documents, or an absolute path."),
                        "name_contains": stringSchema("Optional filename keyword to match."),
                        "extensions": arraySchema(itemType: "string", description: "Optional file extensions without dots, for example pdf, csv, mp4, mov, or png."),
                        "direct_children_only": boolSchema("When true, search only the direct children of the root directories instead of recursive descendants."),
                        "include_directories": boolSchema("When true, matching directories may be returned. Leave false for normal file cleanup.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "prepare_directory_cleanup",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "兼容工具：为“把桌面上散落的文件收纳到新文件夹”这类任务做一次性准备。内部会走 snapshot -> select -> stage -> commit。",
                    en: "Compatibility tool: prepare one-shot cleanup for common tasks such as collecting loose files on Desktop into a new folder. Internally this runs snapshot -> select -> stage -> commit."
                ),
                parameters: objectSchema(
                    properties: [
                        "source_directory": stringSchema("The directory whose loose files should be organized, such as desktop."),
                        "destination_parent_directory": stringSchema("Where the destination folder should be created. Usually the same as the source directory."),
                        "destination_folder_name": stringSchema("The new folder name that should receive the matched files."),
                        "extensions": arraySchema(itemType: "string", description: "Optional file extensions without dots. Leave empty to include all direct files."),
                        "name_contains": stringSchema("Optional filename keyword to match."),
                        "direct_children_only": boolSchema("Default true. Keep true for loose-file cleanup so only direct root files are collected."),
                        "include_directories": boolSchema("Default false. Usually keep false so folders are not moved during cleanup.")
                    ],
                    required: ["source_directory", "destination_folder_name"]
                )
            ),
            AskToolDefinition(
                name: "create_folder",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "在指定父目录下创建文件夹。父目录可以是 desktop、downloads、documents 或绝对路径。",
                    en: "Create a folder inside a target parent directory. The parent can be desktop, downloads, documents, or an absolute path."
                ),
                parameters: objectSchema(
                    properties: [
                        "name": stringSchema("Folder name to create."),
                        "parent_directory": stringSchema("Parent directory alias or absolute path.")
                    ],
                    required: ["name", "parent_directory"]
                )
            ),
            AskToolDefinition(
                name: "list_workspace_roots",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "列出当前可用的工作区或仓库根目录。做代码相关任务但还没确定项目根目录时，优先先用它。",
                    en: "List available workspace or repository roots. Use this first for coding tasks when the active project root is still unclear."
                ),
                parameters: objectSchema(properties: [:])
            ),
            AskToolDefinition(
                name: "set_active_workspace",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "把某个目录设成当前会话的 active workspace。之后的读文件、grep、git、shell 都会优先沿用它。",
                    en: "Set a directory as the active workspace for the current session. Later file, grep, git, and shell actions will reuse it."
                ),
                parameters: objectSchema(
                    properties: [
                        "workspace_root": stringSchema("The absolute workspace root path to activate.")
                    ],
                    required: ["workspace_root"]
                )
            ),
            AskToolDefinition(
                name: "enter_plan_mode",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "进入当前工作区的只读规划模式。适合先看目录、grep、读文件、看 git，而不直接执行 shell 或写 patch。",
                    en: "Enter read-only planning mode for the current workspace. Use this for structure review, grep, file reads, and git inspection before any shell or patch writes."
                ),
                parameters: objectSchema(
                    properties: [
                        "workspace_root": stringSchema("Optional workspace root path. If omitted, reuse the current active workspace."),
                        "plan_scope": stringSchema("Optional short summary of the planning goal or investigation scope.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "exit_plan_mode",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "退出当前工作区的规划模式，回到可执行实现动作的状态。",
                    en: "Leave workspace planning mode and return to executable implementation work."
                ),
                parameters: objectSchema(
                    properties: [
                        "workspace_root": stringSchema("Optional workspace root path. If omitted, reuse the current active workspace."),
                        "execution_scope": stringSchema("Optional short summary of the implementation scope that should follow."),
                        "permission_profile": stringSchema("Optional workspace permission profile for this session: manual_approval, shell_execution, workspace_writes, or workspace_writes_and_shell_execution."),
                        "grant_workspace_writes": boolSchema("Whether this session should be allowed to write changes inside the current workspace after leaving plan mode."),
                        "grant_shell_execution": boolSchema("Whether this session should be allowed to run shell commands inside the current workspace after leaving plan mode."),
                        "grant_git_write_actions": boolSchema("Whether git write shell commands such as commit, push, pull, merge, or rebase may run without per-action approval in this session."),
                        "grant_network_access": boolSchema("Whether networked shell commands such as curl, package installs, fetch, or push may run without per-action approval in this session.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "set_workspace_execution_budget",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "独立更新当前工作区 session 的执行权限，不进入也不退出 plan mode。适合单独授权或撤销工作区写入、shell 执行。",
                    en: "Independently update the current workspace session execution budget without entering or leaving plan mode. Use it to grant or revoke workspace writes and shell execution."
                ),
                parameters: objectSchema(
                    properties: [
                        "workspace_root": stringSchema("Optional workspace root path. If omitted, reuse the current active workspace."),
                        "budget_summary": stringSchema("Optional short note describing why this session budget is being changed."),
                        "permission_profile": stringSchema("Optional workspace permission profile for this session: manual_approval, shell_execution, workspace_writes, or workspace_writes_and_shell_execution."),
                        "grant_workspace_writes": boolSchema("Whether this session should be allowed to write changes inside the current workspace."),
                        "grant_shell_execution": boolSchema("Whether this session should be allowed to run shell commands inside the current workspace."),
                        "grant_git_write_actions": boolSchema("Whether git write shell commands such as commit, push, pull, merge, or rebase may run without per-action approval in this session."),
                        "grant_network_access": boolSchema("Whether networked shell commands such as curl, package installs, fetch, or push may run without per-action approval in this session.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "list_tasks",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "列出当前代码会话里已经记录的任务和子任务。适合继续之前的支线、查看待办，或先看看有哪些 open tasks。",
                    en: "List the recorded tasks and child tasks in the current coding session. Use it to inspect open branches, follow-ups, or saved TODOs."
                ),
                parameters: objectSchema(
                    properties: [
                        "workspace_root": stringSchema("Optional workspace root hint used to scope the listed tasks."),
                        "include_terminal": boolSchema("Whether completed, failed, or cancelled tasks should also be included."),
                        "limit": stringSchema("Optional maximum number of tasks to return.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "get_task",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "查看某个已记录任务的详情。可以按 task id、resume token 或标题查询。",
                    en: "Fetch the details for a recorded task. You can target it by task id, resume token, or title."
                ),
                parameters: objectSchema(
                    properties: [
                        "task_id": stringSchema("Optional exact task id to inspect."),
                        "resume_token": stringSchema("Optional task resume token such as task:<id>."),
                        "query": stringSchema("Optional task title or partial title to match."),
                        "workspace_root": stringSchema("Optional workspace root hint used to scope matching.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "update_task",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "更新某个已记录任务的标题、目标或状态。适合把任务标成 blocked、running、completed 等。",
                    en: "Update the title, objective, or status of a recorded task. Use it to mark a task blocked, running, completed, and so on."
                ),
                parameters: objectSchema(
                    properties: [
                        "task_id": stringSchema("Optional exact task id to update."),
                        "resume_token": stringSchema("Optional task resume token such as task:<id>."),
                        "query": stringSchema("Optional task title or partial title to match when the exact id is unknown."),
                        "new_title": stringSchema("Optional replacement task title."),
                        "new_objective": stringSchema("Optional replacement task objective."),
                        "status": stringSchema("Optional new task status: queued, planning, waitingApproval, running, blocked, completed, failed, or cancelled."),
                        "note": stringSchema("Optional short note explaining this task update."),
                        "workspace_root": stringSchema("Optional workspace root hint used to scope matching.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "stop_task",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "停止或取消某个已记录任务。适合放弃某条支线、清掉无效 TODO，或关闭一个不再继续的子任务。",
                    en: "Stop or cancel a recorded task. Use it to abandon a branch, clear a stale TODO, or close a child task that should not continue."
                ),
                parameters: objectSchema(
                    properties: [
                        "task_id": stringSchema("Optional exact task id to stop."),
                        "resume_token": stringSchema("Optional task resume token such as task:<id>."),
                        "query": stringSchema("Optional task title or partial title to match when the exact id is unknown."),
                        "reason": stringSchema("Optional short reason for stopping the task."),
                        "workspace_root": stringSchema("Optional workspace root hint used to scope matching.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "resume_task",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "恢复当前代码会话里之前记录过的任务或子任务上下文，适合继续一个延期分支、后续检查项或待办。",
                    en: "Restore a previously recorded task or child-task context inside the current coding session. Use it to continue a deferred branch, follow-up check, or saved TODO."
                ),
                parameters: objectSchema(
                    properties: [
                        "task_id": stringSchema("Optional exact task id to resume."),
                        "resume_token": stringSchema("Optional task resume token such as task:<id>."),
                        "title": stringSchema("Optional task title or partial title to match."),
                        "workspace_root": stringSchema("Optional workspace root path hint. If omitted, reuse the resumed task workspace when available.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "write_todo",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "为当前任务或某个已记录任务写入一整份 checklist / todo 列表，用来稳定记录计划拆解和进度。",
                    en: "Write the full checklist or todo list for the current task or a recorded task so plan progress stays durable across turns."
                ),
                parameters: objectSchema(
                    properties: [
                        "task_id": stringSchema("Optional exact task id to update."),
                        "resume_token": stringSchema("Optional task resume token such as task:<id>."),
                        "query": stringSchema("Optional task title or partial title to match when the exact id is unknown."),
                        "items": [
                            "type": "array",
                            "description": "The full todo list that should replace the current checklist.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "content": [
                                        "type": "string",
                                        "description": "Short todo item text."
                                    ],
                                    "status": [
                                        "type": "string",
                                        "description": "Optional status: pending, in_progress, completed, or blocked."
                                    ],
                                    "note": [
                                        "type": "string",
                                        "description": "Optional short note for this checklist item."
                                    ]
                                ],
                                "required": ["content"]
                            ]
                        ],
                        "workspace_root": stringSchema("Optional workspace root hint used to scope matching.")
                    ],
                    required: ["items"]
                )
            ),
            AskToolDefinition(
                name: "spawn_subtask",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "为当前代码会话记录一个聚焦的子任务，适合拆分分支、延期检查项或后续 TODO，不会直接执行它。",
                    en: "Record a focused child task for the current coding session. Use it to split branches, defer checks, or save follow-up TODOs without executing them yet."
                ),
                parameters: objectSchema(
                    properties: [
                        "title": stringSchema("A short child-task title."),
                        "objective": stringSchema("A concise child-task objective or follow-up summary."),
                        "workspace_root": stringSchema("Optional workspace root path. If omitted, reuse the current active workspace.")
                    ],
                    required: ["title", "objective"]
                )
            ),
            AskToolDefinition(
                name: "snapshot_workspace_tree",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "枚举工作区里的文件和目录树，适合先看项目结构再决定读哪个文件。",
                    en: "Enumerate the workspace file tree so you can inspect project structure before choosing files to read."
                ),
                parameters: objectSchema(
                    properties: [
                        "workspace_root": stringSchema("Optional workspace root path. If omitted, use the current active workspace."),
                        "limit": stringSchema("Optional maximum number of paths to enumerate.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "glob_workspace_paths",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "按 glob 模式枚举工作区文件路径。查某类文件、某个目录模式或成组路径时优先用它。",
                    en: "Enumerate workspace paths by glob pattern. Prefer this when looking for a class of files or a grouped path pattern."
                ),
                parameters: objectSchema(
                    properties: [
                        "glob": stringSchema("A file glob such as *.md, Sources/**/*.swift, or Tests/**/Fixtures/*.json."),
                        "workspace_root": stringSchema("Optional workspace root path."),
                        "limit": stringSchema("Optional maximum number of matching paths.")
                    ],
                    required: ["glob"]
                )
            ),
            AskToolDefinition(
                name: "grep_workspace_text",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "在工作区里搜索代码或文本。查定义、关键字、字符串时优先用它。",
                    en: "Search code or text inside the workspace. Prefer this when looking for definitions, keywords, or strings."
                ),
                parameters: objectSchema(
                    properties: [
                        "pattern": stringSchema("The text or regex pattern to search for."),
                        "glob": stringSchema("Optional file glob such as *.swift or Sources/**/*.ts."),
                        "workspace_root": stringSchema("Optional workspace root path."),
                        "limit": stringSchema("Optional maximum number of matches.")
                    ],
                    required: ["pattern"]
                )
            ),
            AskToolDefinition(
                name: "read_workspace_file",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "读取工作区里的源码或配置文件。",
                    en: "Read a source or config file from the workspace."
                ),
                parameters: objectSchema(
                    properties: [
                        "path": stringSchema("A relative path inside the workspace or an absolute path inside the workspace root."),
                        "workspace_root": stringSchema("Optional workspace root path."),
                        "max_length": stringSchema("Optional maximum number of characters to return.")
                    ],
                    required: ["path"]
                )
            ),
            AskToolDefinition(
                name: "write_workspace_file",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "在工作区里创建或覆盖一个文本文件。这个动作会受 plan mode 和 session 写权限约束，并且通常需要确认。",
                    en: "Create or overwrite a text file inside the workspace. This is constrained by plan mode and session write permissions, and it will usually require approval."
                ),
                parameters: objectSchema(
                    properties: [
                        "path": stringSchema("A relative path inside the workspace or an absolute path inside the workspace root."),
                        "content": stringSchema("The full text content to write into the file."),
                        "workspace_root": stringSchema("Optional workspace root path."),
                        "create_parent_directories": boolSchema("Whether missing parent directories should be created first."),
                        "overwrite": boolSchema("Whether an existing file may be overwritten. Default true.")
                    ],
                    required: ["path", "content"]
                )
            ),
            AskToolDefinition(
                name: "workspace_git_status",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "查看工作区的 git 状态。",
                    en: "Inspect git status for the workspace."
                ),
                parameters: objectSchema(
                    properties: [
                        "workspace_root": stringSchema("Optional workspace root path.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "workspace_git_diff",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "查看工作区的 git diff，可选限制到某个文件。",
                    en: "Inspect git diff for the workspace, optionally scoped to a single file."
                ),
                parameters: objectSchema(
                    properties: [
                        "workspace_root": stringSchema("Optional workspace root path."),
                        "path": stringSchema("Optional relative file path inside the workspace.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "run_shell_command",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "在工作区里运行 shell 命令。这个动作风险更高，通常会先进入确认。",
                    en: "Run a shell command inside the workspace. This is higher risk and will usually go through approval first."
                ),
                parameters: objectSchema(
                    properties: [
                        "command": stringSchema("The shell command to run in the workspace."),
                        "workspace_root": stringSchema("Optional workspace root path.")
                    ],
                    required: ["command"]
                )
            ),
            AskToolDefinition(
                name: "preview_workspace_patch",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "预览一段 patch / diff 会影响哪些文件，但不真正写入工作区。",
                    en: "Preview which files a patch / diff would affect without applying it to the workspace."
                ),
                parameters: objectSchema(
                    properties: [
                        "patch": stringSchema("The unified diff or patch text to preview."),
                        "workspace_root": stringSchema("Optional workspace root path.")
                    ],
                    required: ["patch"]
                )
            ),
            AskToolDefinition(
                name: "apply_workspace_patch",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "把一段 unified diff patch 真正应用到当前工作区。这个动作会先进入确认。",
                    en: "Apply a unified diff patch into the current workspace. This action will go through approval first."
                ),
                parameters: objectSchema(
                    properties: [
                        "patch": stringSchema("The unified diff patch to apply."),
                        "workspace_root": stringSchema("Optional workspace root path.")
                    ],
                    required: ["patch"]
                )
            ),
            AskToolDefinition(
                name: "open_path",
                description: L10n.text(languageCode: responseLanguage, zhHans: "打开一个本地文件或文件夹。", en: "Open a local file or folder."),
                parameters: objectSchema(
                    properties: [
                        "path": stringSchema("Absolute path or alias-based path.")
                    ],
                    required: ["path"]
                )
            ),
            AskToolDefinition(
                name: "reveal_in_finder",
                description: L10n.text(languageCode: responseLanguage, zhHans: "在 Finder 中显示一个本地文件或文件夹。", en: "Reveal a local file or folder in Finder."),
                parameters: objectSchema(
                    properties: [
                        "path": stringSchema("Absolute path or alias-based path.")
                    ],
                    required: ["path"]
                )
            ),
            AskToolDefinition(
                name: "stage_move_paths",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "把 selection 或明确路径列表生成为待提交的移动操作，返回 operation id、预览、冲突和跳过信息，但此时还不真正执行移动。",
                    en: "Stage a move operation from a selection or explicit path list and return an operation id, preview, collisions, and skipped items without executing the move yet."
                ),
                parameters: objectSchema(
                    properties: [
                        "selection_id": stringSchema("Optional selection id from select_from_snapshot."),
                        "source_paths": arraySchema(itemType: "string", description: "Optional explicit source paths."),
                        "destination_directory": stringSchema("Destination alias or absolute path."),
                        "create_destination_if_needed": boolSchema("Whether the destination directory should be created if missing.")
                    ],
                    required: ["destination_directory"]
                )
            ),
            AskToolDefinition(
                name: "commit_staged_operation",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "提交一个 staged operation。对于 move，这一步会先进入审批态，批准后才真正执行。",
                    en: "Commit a staged operation. For move operations, this first enters approval state and only executes after approval."
                ),
                parameters: objectSchema(
                    properties: [
                        "operation_id": stringSchema("The staged operation id returned by stage_move_paths.")
                    ],
                    required: ["operation_id"]
                )
            ),
            AskToolDefinition(
                name: "cancel_staged_operation",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "取消一个尚未执行的 staged operation。",
                    en: "Cancel a staged operation that has not been executed yet."
                ),
                parameters: objectSchema(
                    properties: [
                        "operation_id": stringSchema("The staged operation id to cancel.")
                    ],
                    required: ["operation_id"]
                )
            ),
            AskToolDefinition(
                name: "move_paths",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "兼容工具：把明确给出的完整路径列表移动到目标目录。内部会走 stage_move_paths + commit_staged_operation。",
                    en: "Compatibility tool: move explicit source paths into a destination directory. Internally this runs stage_move_paths + commit_staged_operation."
                ),
                parameters: objectSchema(
                    properties: [
                        "source_paths": arraySchema(itemType: "string", description: "Explicit source file paths."),
                        "destination_directory": stringSchema("Destination alias or absolute path."),
                        "create_destination_if_needed": boolSchema("Whether the destination directory should be created if missing.")
                    ],
                    required: ["source_paths", "destination_directory"]
                )
            ),
            AskToolDefinition(
                name: "open_url",
                description: L10n.text(languageCode: responseLanguage, zhHans: "在浏览器中打开链接。这是可见副作用动作，只有当用户明确要求打开网页时才调用。", en: "Open a URL in the browser. This is a visible side effect, so only call it when the user explicitly asked to open a page."),
                parameters: objectSchema(
                    properties: [
                        "url": stringSchema("A valid URL."),
                        "preferred_browser_bundle_id": stringSchema("Optional preferred browser bundle id.")
                    ],
                    required: ["url"]
                )
            ),
            AskToolDefinition(
                name: "search_web",
                description: L10n.text(languageCode: responseLanguage, zhHans: "搜索网页。默认不会打开浏览器；只有当 `open_in_browser` = true 且用户明确要求时，才把搜索结果页打开。", en: "Search the web. By default this does not open the browser; only open the search results page when `open_in_browser` = true and the user explicitly asked for it."),
                parameters: objectSchema(
                    properties: [
                        "query": stringSchema("The search query."),
                        "preferred_browser_bundle_id": stringSchema("Optional preferred browser bundle id."),
                        "open_in_browser": boolSchema("Whether to visibly open the search results in the browser. Default false.")
                    ],
                    required: ["query"]
                )
            ),
            AskToolDefinition(
                name: "read_current_page",
                description: L10n.text(languageCode: responseLanguage, zhHans: "静默读取当前浏览器页面，可选传入查询词获取相关片段。只有当用户明确提到当前网页或标签页时才调用。", en: "Silently read the current browser page, optionally filtered by a query. Only call this when the user explicitly refers to the current webpage or tab."),
                parameters: objectSchema(
                    properties: [
                        "query": stringSchema("Optional query to match on the current page.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "extract_current_page_summary",
                description: L10n.text(languageCode: responseLanguage, zhHans: "静默提取当前页面的标题、URL 和正文摘要。只有当用户明确提到当前网页或标签页时才调用。", en: "Silently extract the title, URL, and readable summary for the current page. Only call this when the user explicitly refers to the current page or tab."),
                parameters: objectSchema(
                    properties: [
                        "query": stringSchema("Optional query to focus the summary.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "extract_current_page_links",
                description: L10n.text(languageCode: responseLanguage, zhHans: "静默整理当前页面里可见的链接或 URL 候选。只有当用户明确提到当前网页或标签页时才调用。", en: "Silently extract visible links or URL candidates from the current page. Only call this when the user explicitly refers to the current page or tab."),
                parameters: objectSchema(
                    properties: [:]
                )
            ),
            AskToolDefinition(
                name: "capture_best_web_result",
                description: L10n.text(languageCode: responseLanguage, zhHans: "静默搜索网页并返回一个最值得继续跟进的候选结果，不主动打开浏览器。", en: "Silently search the web and return the single best result to continue from, without opening the browser."),
                parameters: objectSchema(
                    properties: [
                        "query": stringSchema("The search query.")
                    ],
                    required: ["query"]
                )
            ),
            AskToolDefinition(
                name: "search_knowledge",
                description: L10n.text(languageCode: responseLanguage, zhHans: "搜索本地知识库，返回可继续打开或引用的来源卡片。", en: "Search the local knowledge base and return source cards that can be opened or cited next."),
                parameters: objectSchema(
                    properties: [
                        "query": stringSchema("The knowledge-base search query.")
                    ],
                    required: ["query"]
                )
            ),
            AskToolDefinition(
                name: "collect_url",
                description: L10n.text(languageCode: responseLanguage, zhHans: "把一个 URL 采集进知识库。成功后会返回可继续追问的来源卡片。", en: "Collect a URL into the knowledge base. On success, return source cards that can be queried next."),
                parameters: objectSchema(
                    properties: [
                        "url": stringSchema("The URL to collect into the knowledge base.")
                    ],
                    required: ["url"]
                )
            ),
            AskToolDefinition(
                name: "collect_current_page",
                description: L10n.text(languageCode: responseLanguage, zhHans: "把当前浏览器页面采集进知识库。只有当用户明确提到当前页面或标签页时才调用。", en: "Collect the current browser page into the knowledge base. Only call this when the user explicitly refers to the current page or tab."),
                parameters: objectSchema(
                    properties: [:]
                )
            ),
            AskToolDefinition(
                name: "collect_current_page_to_knowledge",
                description: L10n.text(languageCode: responseLanguage, zhHans: "和 collect_current_page 相同，但强调把结果直接写入知识库。", en: "Same as collect_current_page, but explicitly writes the current page into the knowledge base."),
                parameters: objectSchema(
                    properties: [:]
                )
            ),
            AskToolDefinition(
                name: "collect_paths",
                description: L10n.text(languageCode: responseLanguage, zhHans: "把一个或多个本地文件路径采集进知识库。", en: "Collect one or more local file paths into the knowledge base."),
                parameters: objectSchema(
                    properties: [
                        "paths": arraySchema(itemType: "string", description: "Absolute local file paths.")
                    ],
                    required: ["paths"]
                )
            ),
            AskToolDefinition(
                name: "save_answer_to_knowledge_note",
                description: L10n.text(languageCode: responseLanguage, zhHans: "把当前回答或指定文本保存成一条知识库 note。", en: "Save the current answer or provided text as a knowledge-base note."),
                parameters: objectSchema(
                    properties: [
                        "content": stringSchema("The note content to save."),
                        "title": stringSchema("Optional note title.")
                    ],
                    required: ["content"]
                )
            ),
            AskToolDefinition(
                name: "promote_playground_artifact",
                description: L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "把一个已经在 Playground 中生成过的脚本或小工具提升为可复用的本地 ASK 工具。只有当用户明确同意“把它注册成工具”时才调用。",
                    en: "Promote an existing Playground script or mini-app into a reusable local ASK tool. Only call this when the user explicitly agreed to register it as a tool."
                ),
                parameters: objectSchema(
                    properties: [
                        "artifact_id": stringSchema("The Playground artifact id to promote, usually taken from runtime context."),
                        "tool_name": stringSchema("Optional preferred local tool name.")
                    ],
                    required: ["artifact_id"]
                )
            ),
            AskToolDefinition(
                name: "copy_to_clipboard",
                description: L10n.text(languageCode: responseLanguage, zhHans: "把指定文本复制到剪贴板。只有当用户明确要求复制时才调用。", en: "Copy specific text to the clipboard. Only call this when the user explicitly asked to copy something."),
                parameters: objectSchema(
                    properties: [
                        "text": stringSchema("The text to copy.")
                    ],
                    required: ["text"]
                )
            ),
            AskToolDefinition(
                name: "write_back_to_frontmost_input",
                description: L10n.text(languageCode: responseLanguage, zhHans: "把指定文本写回当前前台输入框。只有当用户明确要求写回或粘贴时才调用。", en: "Write specific text back into the frontmost input. Only call this when the user explicitly asked to write back or paste."),
                parameters: objectSchema(
                    properties: [
                        "text": stringSchema("The text to write back.")
                    ],
                    required: ["text"]
                )
            ),
            AskToolDefinition(
                name: "replace_frontmost_selection",
                description: L10n.text(languageCode: responseLanguage, zhHans: "用指定文本替换前台应用中的当前选区。只有当用户明确要求替换选中内容时才调用。", en: "Replace the current foreground selection with specific text. Only call this when the user explicitly asked to replace the selection."),
                parameters: objectSchema(
                    properties: [
                        "text": stringSchema("The replacement text.")
                    ],
                    required: ["text"]
                )
            ),
            AskToolDefinition(
                name: "reveal_path",
                description: L10n.text(languageCode: responseLanguage, zhHans: "在 Finder 中显示一个本地文件或文件夹。", en: "Reveal a local file or folder in Finder."),
                parameters: objectSchema(
                    properties: [
                        "path": stringSchema("Absolute path or alias-based path.")
                    ],
                    required: ["path"]
                )
            ),
            AskToolDefinition(
                name: "preview_calendar_intent",
                description: L10n.text(languageCode: responseLanguage, zhHans: "从自然语言里预览一个日历/提醒意图，先给出解析结果，再决定是否创建。", en: "Preview a calendar or reminder intent from natural language so the parsed result can be reviewed before creation."),
                parameters: objectSchema(
                    properties: [
                        "text": stringSchema("The natural-language schedule request.")
                    ],
                    required: ["text"]
                )
            ),
            AskToolDefinition(
                name: "create_calendar_event",
                description: L10n.text(languageCode: responseLanguage, zhHans: "根据 intent_json 或自然语言创建日历事件。", en: "Create a calendar event from intent_json or natural language."),
                parameters: objectSchema(
                    properties: [
                        "intent_json": stringSchema("A serialized CalendarEventIntent JSON string."),
                        "text": stringSchema("Natural-language schedule text.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "create_reminder",
                description: L10n.text(languageCode: responseLanguage, zhHans: "根据 intent_json 或自然语言创建提醒事项。只有当用户明确想要系统里的日历项或提醒事项时才调用；不要把这种工具用于让 Ask 稍后执行一个任务。", en: "Create a reminder from intent_json or natural language. Only call this when the user explicitly wants a system calendar/reminder item; do not use it for an Ask task that should run later."),
                parameters: objectSchema(
                    properties: [
                        "intent_json": stringSchema("A serialized CalendarEventIntent JSON string."),
                        "text": stringSchema("Natural-language reminder text.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "delete_reminder",
                description: L10n.text(languageCode: responseLanguage, zhHans: "撤销、删除或取消一个刚创建的提醒。优先传 receipt_json；如果省略，运行时会尝试使用当前 Ask 会话里最近创建的提醒。", en: "Undo, delete, or cancel a reminder that was just created. Prefer receipt_json; if omitted, the runtime will try the most recently created reminder in the current Ask session."),
                parameters: objectSchema(
                    properties: [
                        "receipt_json": stringSchema("A serialized CalendarCreatedItemReceipt JSON string returned by an earlier create tool result."),
                        "intent_json": stringSchema("A serialized CalendarEventIntent JSON string if no receipt is available.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "delete_calendar_item",
                description: L10n.text(languageCode: responseLanguage, zhHans: "删除一个已创建的日历项或提醒。优先传 receipt_json；如果省略，运行时会尝试使用当前 Ask 会话里最近创建的日历项。", en: "Delete an existing calendar item or reminder. Prefer receipt_json; if omitted, the runtime will try the most recently created calendar item in the current Ask session."),
                parameters: objectSchema(
                    properties: [
                        "receipt_json": stringSchema("A serialized CalendarCreatedItemReceipt JSON string returned by an earlier create tool result."),
                        "intent_json": stringSchema("A serialized CalendarEventIntent JSON string if no receipt is available.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "preview_automation_job",
                description: L10n.text(languageCode: responseLanguage, zhHans: "把自然语言的未来任务解析成一个 automation 草案，不直接保存。适用于周期任务，也适用于“10 分钟后打开 B 站”“1 分钟后搜索最新金价告诉我”这种单次延时任务。", en: "Parse a future natural-language task into an automation draft without saving it yet. Use this for recurring jobs and also one-shot delayed tasks like “open Bilibili in 10 minutes” or “in 1 minute search the latest gold price and tell me”."),
                parameters: objectSchema(
                    properties: [
                        "spec": stringSchema("The natural-language automation request.")
                    ],
                    required: ["spec"]
                )
            ),
            AskToolDefinition(
                name: "create_automation_job",
                description: L10n.text(languageCode: responseLanguage, zhHans: "根据 automation 草案 id 或自然语言说明真正保存一个本地定时任务。对于让 Ask 稍后执行的任务，应该优先用这个，而不是创建日历提醒。", en: "Save a local automation job from an automation draft id or directly from natural language. Prefer this over calendar reminders when the user wants Ask itself to run a task later."),
                parameters: objectSchema(
                    properties: [
                        "draft_id": stringSchema("The draft id returned by preview_automation_job."),
                        "spec": stringSchema("Fallback natural-language automation request if no draft id is available.")
                    ]
                )
            ),
            AskToolDefinition(
                name: "respond_to_approval",
                description: L10n.text(languageCode: responseLanguage, zhHans: "处理当前会话中的待审批动作。必须传入 action_id 和 decision，decision 只能是 approve 或 cancel。", en: "Handle the current pending approval in this session. Pass both action_id and decision, where decision must be approve or cancel."),
                parameters: objectSchema(
                    properties: [
                        "action_id": stringSchema("The approval action id returned by commit_staged_operation."),
                        "decision": stringSchema("approve or cancel")
                    ],
                    required: ["action_id", "decision"]
                )
            )
        ]
        return assembledToolPool(from: tools, context: context)
    }

    func executeTool(
        named name: String,
        argumentsJSON: String,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        let arguments = decodedJSONObject(from: argumentsJSON)
        if let blocked = automationPolicyBlockedResult(forToolNamed: name, request: request) {
            return blocked
        }
        if let blocked = workspacePlanModeBlockedResult(forToolNamed: name, request: request) {
            return blocked
        }
        if let promotedDescriptor = AskPlaygroundStore.shared.promotedToolDescriptor(id: name) {
            return await runPromotedLocalTool(
                descriptor: promotedDescriptor,
                arguments: arguments,
                request: request,
                onEvent: onEvent
            )
        }

        switch name {
        case "snapshot_directory":
            guard let directoryValue = nonEmptyString(arguments["directory"]),
                  let directory = resolvedPathURL(from: directoryValue) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            let criteria = FileSearchCriteria(
                rootDirectories: [directory],
                extensionFilters: stringArray(arguments["extensions"]),
                nameContains: nonEmptyString(arguments["name_contains"]),
                directChildrenOnly: arguments["direct_children_only"] as? Bool ?? false,
                includeDirectories: arguments["include_directories"] as? Bool ?? false
            )
            return await snapshotDirectory(criteria: criteria, request: request, onEvent: onEvent)

        case "inspect_paths":
            let rawPaths = stringArray(arguments["paths"])
            guard !rawPaths.isEmpty else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await inspectPaths(rawPaths, request: request, onEvent: onEvent)

        case "select_from_snapshot":
            guard let snapshotID = nonEmptyString(arguments["snapshot_id"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await selectFromSnapshot(
                snapshotID: snapshotID,
                extensions: stringArray(arguments["extensions"]),
                nameContains: nonEmptyString(arguments["name_contains"]),
                filesOnly: arguments["files_only"] as? Bool ?? false,
                directoriesOnly: arguments["directories_only"] as? Bool ?? false,
                request: request,
                onEvent: onEvent
            )

        case "search_files":
            let roots = resolvedRootDirectories(from: arguments["roots"] as? [String])
            let nameContains = nonEmptyString(arguments["name_contains"])
            let extensions = stringArray(arguments["extensions"])
            let directChildrenOnly = arguments["direct_children_only"] as? Bool ?? false
            let includeDirectories = arguments["include_directories"] as? Bool ?? false
            let criteria = FileSearchCriteria(
                rootDirectories: roots,
                extensionFilters: extensions,
                nameContains: nameContains,
                directChildrenOnly: directChildrenOnly,
                includeDirectories: includeDirectories
            )
            let snapshotResolution = await resolveSnapshotViaKernel(
                criteria: criteria,
                request: request
            )
            let snapshot: AskDirectorySnapshot
            switch snapshotResolution {
            case .success(let resolvedSnapshot):
                snapshot = resolvedSnapshot
            case .failure(let failure):
                return failure
            }
            let selection = await createSelection(from: snapshot, paths: snapshot.items.map(\.path))
            let matches = selection.paths.map { URL(fileURLWithPath: $0) }
            let directMatches = directMatches(in: matches, roots: roots)
            let response = await searchFilesResponse(matches: matches, criteria: criteria, action: .list, request: request)
            return toolResult(
                from: response,
                ok: !matches.isEmpty,
                data: [
                    "snapshot_id": snapshot.id,
                    "selection_id": selection.id,
                    "paths": matches.map(\.path),
                    "match_count": matches.count,
                    "direct_paths": directMatches.map(\.path),
                    "direct_match_count": directMatches.count,
                    "nested_match_count": max(0, matches.count - directMatches.count),
                    "roots": roots.map(\.path),
                    "direct_children_only": directChildrenOnly,
                    "include_directories": includeDirectories
                ],
                error: matches.isEmpty ? response.message : nil
            )

        case "prepare_directory_cleanup":
            guard let sourceValue = nonEmptyString(arguments["source_directory"]),
                  let sourceDirectory = resolvedPathURL(from: sourceValue) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            let destinationParentValue = nonEmptyString(arguments["destination_parent_directory"]) ?? sourceValue
            guard let destinationParentDirectory = resolvedPathURL(from: destinationParentValue),
                  let destinationFolderName = nonEmptyString(arguments["destination_folder_name"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            let criteria = FileSearchCriteria(
                rootDirectories: [sourceDirectory],
                extensionFilters: stringArray(arguments["extensions"]),
                nameContains: nonEmptyString(arguments["name_contains"]),
                directChildrenOnly: arguments["direct_children_only"] as? Bool ?? true,
                includeDirectories: arguments["include_directories"] as? Bool ?? false
            )
            return await prepareDirectoryCleanup(
                criteria: criteria,
                destinationParentDirectory: destinationParentDirectory,
                destinationFolderName: destinationFolderName,
                request: request,
                onEvent: onEvent
            )

        case "create_folder":
            guard let name = nonEmptyString(arguments["name"]),
                  let parentValue = nonEmptyString(arguments["parent_directory"]),
                  let parentDirectory = resolvedPathURL(from: parentValue) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await createFolderViaKernel(
                named: name,
                in: parentDirectory,
                request: request,
                onEvent: onEvent
            )

        case "list_workspace_roots":
            return await listWorkspaceRoots(request: request)

        case "set_active_workspace":
            guard let workspaceRoot = nonEmptyString(arguments["workspace_root"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await setActiveWorkspace(
                workspaceRoot: workspaceRoot,
                request: request
            )

        case "enter_plan_mode":
            return await enterPlanModeInWorkspace(
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                planScope: nonEmptyString(arguments["plan_scope"]),
                request: request
            )

        case "exit_plan_mode":
            return await exitPlanModeInWorkspace(
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                executionScope: nonEmptyString(arguments["execution_scope"]),
                permissionProfile: nonEmptyString(arguments["permission_profile"]),
                grantWorkspaceWrites: arguments["grant_workspace_writes"] as? Bool,
                grantShellExecution: arguments["grant_shell_execution"] as? Bool,
                grantGitWriteActions: arguments["grant_git_write_actions"] as? Bool,
                grantNetworkAccess: arguments["grant_network_access"] as? Bool,
                request: request
            )

        case "set_workspace_execution_budget":
            let grantWorkspaceWrites = arguments["grant_workspace_writes"] as? Bool
            let grantShellExecution = arguments["grant_shell_execution"] as? Bool
            let grantGitWriteActions = arguments["grant_git_write_actions"] as? Bool
            let grantNetworkAccess = arguments["grant_network_access"] as? Bool
            let permissionProfile = nonEmptyString(arguments["permission_profile"])
            guard grantWorkspaceWrites != nil
                    || grantShellExecution != nil
                    || grantGitWriteActions != nil
                    || grantNetworkAccess != nil
                    || permissionProfile != nil else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await setWorkspaceExecutionBudgetInWorkspace(
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                budgetSummary: nonEmptyString(arguments["budget_summary"]),
                permissionProfile: permissionProfile,
                grantWorkspaceWrites: grantWorkspaceWrites,
                grantShellExecution: grantShellExecution,
                grantGitWriteActions: grantGitWriteActions,
                grantNetworkAccess: grantNetworkAccess,
                request: request
            )

        case "list_tasks":
            return await listTasksInKernel(
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                includeTerminal: arguments["include_terminal"] as? Bool,
                limit: nonEmptyString(arguments["limit"]),
                request: request
            )

        case "get_task":
            return await getTaskInKernel(
                taskID: nonEmptyString(arguments["task_id"]),
                resumeToken: nonEmptyString(arguments["resume_token"]),
                query: nonEmptyString(arguments["query"]),
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                request: request
            )

        case "update_task":
            return await updateTaskInKernel(
                taskID: nonEmptyString(arguments["task_id"]),
                resumeToken: nonEmptyString(arguments["resume_token"]),
                query: nonEmptyString(arguments["query"]),
                newTitle: nonEmptyString(arguments["new_title"]),
                newObjective: nonEmptyString(arguments["new_objective"]),
                status: nonEmptyString(arguments["status"]),
                note: nonEmptyString(arguments["note"]),
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                request: request
            )

        case "stop_task":
            return await stopTaskInKernel(
                taskID: nonEmptyString(arguments["task_id"]),
                resumeToken: nonEmptyString(arguments["resume_token"]),
                query: nonEmptyString(arguments["query"]),
                reason: nonEmptyString(arguments["reason"]),
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                request: request
            )

        case "write_todo":
            guard let itemsJSON = jsonString(arguments["items"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await writeTodoInKernel(
                taskID: nonEmptyString(arguments["task_id"]),
                resumeToken: nonEmptyString(arguments["resume_token"]),
                query: nonEmptyString(arguments["query"]),
                itemsJSON: itemsJSON,
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                request: request
            )

        case "spawn_subtask":
            guard let title = nonEmptyString(arguments["title"]),
                  let objective = nonEmptyString(arguments["objective"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await spawnSubtaskInKernel(
                title: title,
                objective: objective,
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                request: request
            )

        case "resume_task":
            return await resumeTaskInKernel(
                taskID: nonEmptyString(arguments["task_id"]),
                resumeToken: nonEmptyString(arguments["resume_token"]),
                title: nonEmptyString(arguments["title"]),
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                request: request
            )

        case "snapshot_workspace_tree":
            return await snapshotWorkspaceTree(
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                limit: nonEmptyString(arguments["limit"]),
                request: request
            )

        case "glob_workspace_paths":
            guard let glob = nonEmptyString(arguments["glob"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await globWorkspacePaths(
                glob: glob,
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                limit: nonEmptyString(arguments["limit"]),
                request: request
            )

        case "grep_workspace_text":
            guard let pattern = nonEmptyString(arguments["pattern"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await grepWorkspaceText(
                pattern: pattern,
                glob: nonEmptyString(arguments["glob"]),
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                limit: nonEmptyString(arguments["limit"]),
                request: request
            )

        case "read_workspace_file":
            guard let path = firstNonEmptyString(in: arguments, keys: ["path", "file", "file_path"]) else {
                return invalidArgumentsResult(
                    for: name,
                    responseLanguage: request.responseLanguage,
                    arguments: arguments,
                    diagnosticsLogger: diagnosticsLogger
                )
            }
            return await readWorkspaceFile(
                path: path,
                workspaceRoot: firstNonEmptyString(in: arguments, keys: ["workspace_root", "project_root", "cwd"]),
                maxLength: firstNonEmptyString(in: arguments, keys: ["max_length", "maxLength"]),
                request: request
            )

        case "write_workspace_file":
            guard let content = firstNonEmptyString(in: arguments, keys: ["content", "text", "body"]) else {
                return invalidArgumentsResult(
                    for: name,
                    responseLanguage: request.responseLanguage,
                    arguments: arguments,
                    diagnosticsLogger: diagnosticsLogger
                )
            }
            return await writeWorkspaceFile(
                path: firstNonEmptyString(in: arguments, keys: ["path", "file", "file_path"]),
                content: content,
                workspaceRoot: firstNonEmptyString(in: arguments, keys: ["workspace_root", "project_root", "cwd"]),
                createParentDirectories: firstBool(in: arguments, keys: ["create_parent_directories", "create_parents", "mkdir_p"]),
                overwrite: firstBool(in: arguments, keys: ["overwrite", "overwrite_if_exists"]),
                request: request
            )

        case "workspace_git_status":
            return await workspaceGitStatus(
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                request: request
            )

        case "workspace_git_diff":
            return await workspaceGitDiff(
                path: nonEmptyString(arguments["path"]),
                workspaceRoot: nonEmptyString(arguments["workspace_root"]),
                request: request
            )

        case "run_shell_command":
            guard let command = firstNonEmptyString(in: arguments, keys: ["command", "cmd", "shell_command"]) else {
                return invalidArgumentsResult(
                    for: name,
                    responseLanguage: request.responseLanguage,
                    arguments: arguments,
                    diagnosticsLogger: diagnosticsLogger
                )
            }
            return await runShellCommandInWorkspace(
                command: command,
                workspaceRoot: firstNonEmptyString(in: arguments, keys: ["workspace_root", "project_root", "cwd"]),
                request: request,
                onEvent: onEvent
            )

        case "preview_workspace_patch":
            guard let patch = firstNonEmptyString(in: arguments, keys: ["patch", "diff"]) else {
                return invalidArgumentsResult(
                    for: name,
                    responseLanguage: request.responseLanguage,
                    arguments: arguments,
                    diagnosticsLogger: diagnosticsLogger
                )
            }
            return await previewWorkspacePatch(
                patch: patch,
                workspaceRoot: firstNonEmptyString(in: arguments, keys: ["workspace_root", "project_root", "cwd"]),
                request: request
            )

        case "apply_workspace_patch":
            guard let patch = firstNonEmptyString(in: arguments, keys: ["patch", "diff"]) else {
                return invalidArgumentsResult(
                    for: name,
                    responseLanguage: request.responseLanguage,
                    arguments: arguments,
                    diagnosticsLogger: diagnosticsLogger
                )
            }
            return await applyWorkspacePatch(
                patch: patch,
                workspaceRoot: firstNonEmptyString(in: arguments, keys: ["workspace_root", "project_root", "cwd"]),
                request: request,
                onEvent: onEvent
            )

        case "open_path":
            guard let rawPath = firstNonEmptyString(in: arguments, keys: ["path", "file", "file_path"]),
                  let url = resolvedPathURL(
                    from: rawPath,
                    relativeTo: firstNonEmptyString(in: arguments, keys: ["workspace_root", "project_root", "cwd"])
                        ?? request.metadata.kernelMetadata["active_task_workspace_root"]
                        ?? request.metadata.kernelMetadata["workspace_root"]
                  ) else {
                return invalidArgumentsResult(
                    for: name,
                    responseLanguage: request.responseLanguage,
                    arguments: arguments,
                    diagnosticsLogger: diagnosticsLogger
                )
            }
            let response = await openPath(url, request: request, onEvent: onEvent)
            return toolResult(
                from: response,
                ok: response.metadata["operator_action"] == "open_path",
                data: ["path": url.path],
                error: response.metadata["operator_action"] == "open_path" ? nil : response.message
            )

        case "reveal_in_finder":
            guard let rawPath = firstNonEmptyString(in: arguments, keys: ["path", "file", "file_path"]),
                  let url = resolvedPathURL(
                    from: rawPath,
                    relativeTo: firstNonEmptyString(in: arguments, keys: ["workspace_root", "project_root", "cwd"])
                        ?? request.metadata.kernelMetadata["active_task_workspace_root"]
                        ?? request.metadata.kernelMetadata["workspace_root"]
                  ) else {
                return invalidArgumentsResult(
                    for: name,
                    responseLanguage: request.responseLanguage,
                    arguments: arguments,
                    diagnosticsLogger: diagnosticsLogger
                )
            }
            let response = await revealPath(url, request: request, onEvent: onEvent)
            return toolResult(
                from: response,
                ok: response.metadata["operator_action"] == "reveal_path",
                data: ["path": url.path],
                error: response.metadata["operator_action"] == "reveal_path" ? nil : response.message
            )

        case "reveal_path":
            guard let rawPath = firstNonEmptyString(in: arguments, keys: ["path", "file", "file_path"]),
                  let url = resolvedPathURL(
                    from: rawPath,
                    relativeTo: firstNonEmptyString(in: arguments, keys: ["workspace_root", "project_root", "cwd"])
                        ?? request.metadata.kernelMetadata["active_task_workspace_root"]
                        ?? request.metadata.kernelMetadata["workspace_root"]
                  ) else {
                return invalidArgumentsResult(
                    for: name,
                    responseLanguage: request.responseLanguage,
                    arguments: arguments,
                    diagnosticsLogger: diagnosticsLogger
                )
            }
            let response = await revealPath(url, request: request, onEvent: onEvent)
            return toolResult(
                from: response,
                ok: response.metadata["operator_action"] == "reveal_path",
                data: ["path": url.path],
                error: response.metadata["operator_action"] == "reveal_path" ? nil : response.message
            )

        case "move_paths":
            let sourcePaths = stringArray(arguments["source_paths"])
            guard !sourcePaths.isEmpty,
                  let destinationValue = nonEmptyString(arguments["destination_directory"]),
                  let destinationDirectory = resolvedPathURL(from: destinationValue) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            let createIfNeeded = arguments["create_destination_if_needed"] as? Bool ?? false
            return await prepareExplicitMove(
                sourcePaths: sourcePaths,
                destinationDirectory: destinationDirectory,
                createDestinationIfNeeded: createIfNeeded,
                request: request,
                onEvent: onEvent
            )

        case "stage_move_paths":
            guard let destinationValue = nonEmptyString(arguments["destination_directory"]),
                  let destinationDirectory = resolvedPathURL(from: destinationValue) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            let createIfNeeded = arguments["create_destination_if_needed"] as? Bool ?? false
            return await stageMovePathsViaKernel(
                selectionID: nonEmptyString(arguments["selection_id"]),
                sourcePaths: stringArray(arguments["source_paths"]),
                destinationDirectory: destinationDirectory,
                createDestinationIfNeeded: createIfNeeded,
                request: request,
                onEvent: onEvent
            )

        case "commit_staged_operation":
            guard let operationID = nonEmptyString(arguments["operation_id"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await commitStagedOperationViaKernel(
                operationID: operationID,
                request: request,
                onEvent: onEvent
            )

        case "cancel_staged_operation":
            guard let operationID = nonEmptyString(arguments["operation_id"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await cancelStagedOperationViaKernel(
                operationID: operationID,
                request: request,
                onEvent: onEvent
            )

        case "open_url":
            guard let rawURL = nonEmptyString(arguments["url"]),
                  let url = URL(string: rawURL) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            let preferredBrowserBundleID = nonEmptyString(arguments["preferred_browser_bundle_id"])
            guard allowsVisibleBrowserAction(for: request) else {
                return browserActionRequiresExplicitIntentResult(
                    toolName: name,
                    request: request,
                    data: ["url": url.absoluteString]
                )
            }
            return await openURLViaKernel(
                url,
                preferredBrowserBundleID: preferredBrowserBundleID,
                request: request,
                onEvent: onEvent
            )

        case "search_web":
            guard let query = nonEmptyString(arguments["query"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            let preferredBrowserBundleID = nonEmptyString(arguments["preferred_browser_bundle_id"])
            let openInBrowser = arguments["open_in_browser"] as? Bool ?? false
            let effectiveOpenInBrowser = openInBrowser && allowsVisibleBrowserAction(for: request)
            return await searchWebViaKernel(
                query: query,
                preferredBrowserBundleID: preferredBrowserBundleID,
                openInBrowser: effectiveOpenInBrowser,
                request: request,
                onEvent: onEvent
            )

        case "read_current_page":
            let query = nonEmptyString(arguments["query"])
            guard await allowsCurrentPageRead(for: request) else {
                return currentPageReadRequiresExplicitReferenceResult(request: request, query: query)
            }
            return await readCurrentPageViaKernel(
                query: query,
                request: request,
                onEvent: onEvent
            )

        case "extract_current_page_summary":
            let query = nonEmptyString(arguments["query"])
            guard await allowsCurrentPageRead(for: request) else {
                return currentPageReadRequiresExplicitReferenceResult(request: request, query: query)
            }
            return await extractCurrentPageSummary(query: query, request: request, onEvent: onEvent)

        case "extract_current_page_links":
            guard await allowsCurrentPageRead(for: request) else {
                return currentPageReadRequiresExplicitReferenceResult(request: request, query: nil)
            }
            return await extractCurrentPageLinks(request: request, onEvent: onEvent)

        case "capture_best_web_result":
            guard let query = nonEmptyString(arguments["query"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await captureBestWebResult(query: query, request: request, onEvent: onEvent)

        case "search_knowledge":
            guard let query = nonEmptyString(arguments["query"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return searchKnowledge(query: query, request: request)

        case "collect_url":
            guard let rawURL = nonEmptyString(arguments["url"]),
                  let url = URL(string: rawURL) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await collectURL(url, request: request, onEvent: onEvent)

        case "collect_current_page", "collect_current_page_to_knowledge":
            guard await allowsCurrentPageRead(for: request) else {
                return currentPageReadRequiresExplicitReferenceResult(request: request, query: nil)
            }
            return await collectCurrentPage(request: request, onEvent: onEvent)

        case "collect_paths":
            let rawPaths = stringArray(arguments["paths"])
            guard !rawPaths.isEmpty else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await collectPaths(rawPaths, request: request)

        case "save_answer_to_knowledge_note":
            guard let content = nonEmptyString(arguments["content"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await saveAnswerToKnowledgeNote(
                content: content,
                title: nonEmptyString(arguments["title"]),
                request: request
            )

        case "promote_playground_artifact":
            guard let artifactID = nonEmptyString(arguments["artifact_id"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return promotePlaygroundArtifact(
                artifactID: artifactID,
                toolName: nonEmptyString(arguments["tool_name"]),
                request: request
            )

        case "copy_to_clipboard":
            guard let text = nonEmptyString(arguments["text"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await copyToClipboard(text: text, request: request)

        case "write_back_to_frontmost_input":
            guard let text = nonEmptyString(arguments["text"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await writeBackToFrontmostInput(text: text, request: request)

        case "replace_frontmost_selection":
            guard let text = nonEmptyString(arguments["text"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await replaceFrontmostSelection(text: text, request: request)

        case "preview_calendar_intent":
            guard let text = fallbackScheduleToolText(from: arguments, request: request) else {
                return invalidArgumentsResult(
                    for: name,
                    responseLanguage: request.responseLanguage,
                    arguments: arguments,
                    diagnosticsLogger: diagnosticsLogger
                )
            }
            return previewCalendarIntent(text: text, request: request)

        case "create_calendar_event":
            return await createCalendarOrReminder(
                arguments: arguments,
                request: request,
                actionType: .createCalendarEvent
            )

        case "create_reminder":
            return await createCalendarOrReminder(
                arguments: arguments,
                request: request,
                actionType: .createReminder
            )

        case "delete_reminder":
            return await deleteCalendarItem(
                arguments: arguments,
                request: request,
                preferredKind: .reminder
            )

        case "delete_calendar_item":
            return await deleteCalendarItem(
                arguments: arguments,
                request: request,
                preferredKind: nil
            )

        case "preview_automation_job":
            guard let spec = nonEmptyString(arguments["spec"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return await previewAutomationJob(spec: spec, request: request)

        case "create_automation_job":
            return await createAutomationJob(
                draftID: nonEmptyString(arguments["draft_id"]),
                spec: nonEmptyString(arguments["spec"]),
                request: request
            )

        case "respond_to_approval":
            let actionID = nonEmptyString(arguments["action_id"]) ?? ""
            let decision = nonEmptyString(arguments["decision"]) ?? ""
            return await resolvePendingApproval(
                actionID: actionID,
                decision: decision,
                request: request,
                onEvent: onEvent
            )

        case "list_mcp_resources":
            return listMCPResources(
                server: nonEmptyString(arguments["server"]),
                request: request
            )

        case "read_mcp_resource":
            guard let server = nonEmptyString(arguments["server"]),
                  let uri = nonEmptyString(arguments["uri"]) else {
                return invalidArgumentsResult(for: name, responseLanguage: request.responseLanguage)
            }
            return readMCPResource(
                server: server,
                uri: uri,
                request: request
            )

        default:
            return AskToolExecutionResult(
                ok: false,
                summary: L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "未知工具：%@。",
                    en: "Unknown tool: %@.",
                    name
                ),
                data: [:],
                cards: [],
                approvalRequest: nil,
                error: name
            )
        }
    }

    private func assembledToolPool(
        from tools: [AskToolDefinition],
        context: AskToolPoolContext
    ) -> [AskToolDefinition] {
        let hiddenNames = hiddenToolNames(for: context)
        return tools.filter { !hiddenNames.contains($0.name) }
    }

    private func hiddenToolNames(for context: AskToolPoolContext) -> Set<String> {
        var hiddenNames: Set<String> = [
            "list_workspace_roots",
            "set_active_workspace",
            "set_workspace_execution_budget",
            "workspace_git_status",
            "workspace_git_diff",
            "write_back_to_frontmost_input",
            "replace_frontmost_selection"
        ]
        if context.planModeActive {
            hiddenNames.formUnion([
                "create_folder",
                "write_workspace_file",
                "run_shell_command",
                "apply_workspace_patch",
                "enter_plan_mode"
            ])
        } else {
            hiddenNames.insert("exit_plan_mode")
        }
        return hiddenNames
    }

    private func snapshotDirectory(
        criteria: FileSearchCriteria,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(.status("operator", detail: searchStatusDetail(criteria: criteria, languageCode: request.uiLanguage)))
        let resolution = await resolveSnapshotViaKernel(
            criteria: criteria,
            request: request
        )
        let snapshot: AskDirectorySnapshot
        switch resolution {
        case .success(let resolvedSnapshot):
            snapshot = resolvedSnapshot
        case .failure(let failure):
            return failure
        }
        let preview = Array(snapshot.items.prefix(5).map(\.path))
        let message = L10n.format(
            languageCode: request.responseLanguage,
            zhHans: "已生成目录快照，包含 %d 个匹配项。",
            en: "Created a directory snapshot with %d matching item(s).",
            snapshot.items.count
        )
        return AskToolExecutionResult(
            ok: true,
            summary: message,
            data: [
                "snapshot_id": snapshot.id,
                "root_directories": snapshot.rootDirectories,
                "direct_children_only": snapshot.directChildrenOnly,
                "include_directories": snapshot.includeDirectories,
                "extensions": snapshot.extensionFilters,
                "name_contains": snapshot.nameContains ?? "",
                "match_count": snapshot.items.count,
                "paths": snapshot.items.map(\.path),
                "preview": preview
            ],
            cards: [],
            approvalRequest: nil,
            error: nil
        )
    }

    private func inspectPaths(
        _ rawPaths: [String],
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(.status("operator", detail: L10n.text(languageCode: request.uiLanguage, zhHans: "正在读取路径详情…", en: "Inspecting path details…")))
        let paths = uniqueURLs(rawPaths.compactMap { resolvedPathURL(from: $0) })
        let items = paths.map(pathRecord(for:))
        let payloadItems = items.map(pathRecordPayload(for:))
        let existingCount = payloadItems.filter { ($0["exists"] as? Bool) == true }.count
        let message = L10n.format(
            languageCode: request.responseLanguage,
            zhHans: "已检查 %d 个路径，其中 %d 个存在。",
            en: "Inspected %d path(s); %d exist.",
            payloadItems.count,
            existingCount
        )
        return AskToolExecutionResult(
            ok: !payloadItems.isEmpty,
            summary: message,
            data: [
                "items": payloadItems,
                "path_count": payloadItems.count,
                "existing_count": existingCount
            ],
            cards: [],
            approvalRequest: nil,
            error: payloadItems.isEmpty ? message : nil
        )
    }

    private func selectFromSnapshot(
        snapshotID: String,
        extensions: [String],
        nameContains: String?,
        filesOnly: Bool,
        directoriesOnly: Bool,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(.status("operator", detail: L10n.text(languageCode: request.uiLanguage, zhHans: "正在从快照里筛选文件…", en: "Selecting files from the snapshot…")))
        guard let snapshot = await sessionStore.snapshot(for: snapshotID) else {
            return invalidArgumentsResult(for: "select_from_snapshot", responseLanguage: request.responseLanguage)
        }

        let normalizedExtensions = Set(extensions.map { $0.lowercased() })
        let normalizedNameQuery = nameContains?.lowercased()
        let selectedPaths = snapshot.items.filter { item in
            if filesOnly && item.isDirectory { return false }
            if directoriesOnly && !item.isDirectory { return false }
            if let normalizedNameQuery, !normalizedNameQuery.isEmpty,
               !item.name.lowercased().contains(normalizedNameQuery) {
                return false
            }
            if !normalizedExtensions.isEmpty {
                if item.isDirectory { return false }
                let ext = URL(fileURLWithPath: item.path).pathExtension.lowercased()
                guard !ext.isEmpty, normalizedExtensions.contains(ext) else {
                    return false
                }
            }
            return true
        }.map(\.path)

        let selection = await createSelection(from: snapshot, paths: selectedPaths)
        let preview = Array(selection.paths.prefix(5))
        let message = L10n.format(
            languageCode: request.responseLanguage,
            zhHans: "已从快照中筛出 %d 个项目。",
            en: "Selected %d item(s) from the snapshot.",
            selection.paths.count
        )
        return AskToolExecutionResult(
            ok: true,
            summary: message,
            data: [
                "snapshot_id": snapshot.id,
                "selection_id": selection.id,
                "paths": selection.paths,
                "affected_count": selection.paths.count,
                "preview": preview
            ],
            cards: [],
            approvalRequest: nil,
            error: nil
        )
    }

    private func createSnapshot(criteria: FileSearchCriteria) async -> AskDirectorySnapshot {
        let matches = findFileMatches(criteria: criteria)
        return await storeSnapshot(
            rootDirectories: criteria.rootDirectories.map(\.path),
            directChildrenOnly: criteria.directChildrenOnly,
            includeDirectories: criteria.includeDirectories,
            extensionFilters: criteria.extensionFilters,
            nameContains: criteria.nameContains,
            itemURLs: matches
        )
    }

    private func storeSnapshot(
        rootDirectories: [String],
        directChildrenOnly: Bool,
        includeDirectories: Bool,
        extensionFilters: [String],
        nameContains: String?,
        itemURLs: [URL]
    ) async -> AskDirectorySnapshot {
        let snapshot = AskDirectorySnapshot(
            id: UUID().uuidString.lowercased(),
            rootDirectories: rootDirectories,
            directChildrenOnly: directChildrenOnly,
            includeDirectories: includeDirectories,
            extensionFilters: extensionFilters,
            nameContains: nameContains,
            items: uniqueURLs(itemURLs).map(pathRecord(for:)),
            createdAt: Date()
        )
        await sessionStore.setSnapshot(snapshot)
        return snapshot
    }

    private func resolveSnapshotViaKernel(
        criteria: FileSearchCriteria,
        request: AskSessionRequest
    ) async -> KernelSnapshotResolution {
        let result = await executeLegacyKernelCapability(
            capabilityID: "desktop.snapshot_directory",
            arguments: compactKernelArguments(
                ("root_directories", criteria.rootDirectories.map(\.path).joined(separator: "\n")),
                ("direct_children_only", criteria.directChildrenOnly ? "true" : "false"),
                ("include_directories", criteria.includeDirectories ? "true" : "false"),
                ("extensions", criteria.extensionFilters.joined(separator: ",")),
                ("name_contains", criteria.nameContains)
            ),
            request: request
        )

        guard result.status == .succeeded else {
            let message = legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "目录快照生成失败。",
                    en: "Failed to create the directory snapshot."
                )
            )
            return .failure(
                AskToolExecutionResult(
                    ok: false,
                    summary: message,
                    data: capabilityBridgeData(from: result),
                    cards: [],
                    approvalRequest: nil,
                    error: message
                )
            )
        }

        let rootDirectories = splitKernelLines(
            result.metadata["root_directories"],
            fallback: criteria.rootDirectories.map(\.path)
        )
        let snapshotPaths = splitKernelLines(
            capabilityArtifactValue(kind: "snapshot_paths", from: result),
            fallback: []
        )
        let snapshot = await storeSnapshot(
            rootDirectories: rootDirectories,
            directChildrenOnly: kernelBool(result.metadata["direct_children_only"]) ?? criteria.directChildrenOnly,
            includeDirectories: kernelBool(result.metadata["include_directories"]) ?? criteria.includeDirectories,
            extensionFilters: splitKernelList(
                result.metadata["extensions"],
                fallback: criteria.extensionFilters
            ),
            nameContains: nonEmptyString(result.metadata["name_contains"]) ?? criteria.nameContains,
            itemURLs: snapshotPaths.map { URL(fileURLWithPath: $0) }
        )
        return .success(snapshot)
    }

    private func sessionResponse(
        from result: AskToolExecutionResult,
        request: AskSessionRequest,
        successAction: String,
        failureAction: String
    ) -> AskSessionResponse {
        var metadata: [String: String] = [
            "operator_handled": "true",
            "operator_action": result.ok ? successAction : failureAction,
            "session_id": request.metadata.sessionID
        ]
        if let actionID = result.approvalRequest?.actionID ?? (result.data["action_id"] as? String) {
            metadata["pending_approval_action_id"] = actionID
            metadata["active_action_id"] = actionID
        }
        return AskSessionResponse(
            message: result.summary,
            cards: result.cards,
            metadata: metadata
        )
    }

    private func createSelection(from snapshot: AskDirectorySnapshot, paths: [String]) async -> AskPathSelection {
        let selection = AskPathSelection(
            id: UUID().uuidString.lowercased(),
            snapshotID: snapshot.id,
            paths: paths,
            createdAt: Date()
        )
        await sessionStore.setSelection(selection)
        return selection
    }

    private func resolvePendingMoveIfNeeded(
        request: AskSessionRequest,
        latestUserMessage: String,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskSessionResponse? {
        if let approval = await pendingKernelMoveApproval(for: request.metadata.sessionID) {
            return await resolvePendingKernelMoveApprovalIfNeeded(
                approval,
                request: request,
                latestUserMessage: latestUserMessage,
                onEvent: onEvent
            )
        }
        return nil
    }

    private func resolvePendingKernelMoveApprovalIfNeeded(
        _ approval: AskCapabilityApprovalRecord,
        request: AskSessionRequest,
        latestUserMessage: String,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskSessionResponse {
        if isNegativeConfirmation(latestUserMessage) {
            let resolved = await resolveKernelApproval(
                approval,
                decision: AskApprovalDecision.cancel.rawValue,
                request: request,
                onEvent: onEvent
            )
            return AskSessionResponse(
                message: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "已取消这次文件移动。你可以继续告诉我要查找、打开，或重新组织哪一批文件。",
                    en: "Cancelled the pending file move. You can tell me what files to search, open, or reorganize next."
                ),
                cards: resolved.cards,
                metadata: [
                    "operator_handled": "true",
                    "operator_action": "move_cancelled",
                    "session_id": request.metadata.sessionID
                ]
            )
        }

        if !isAffirmativeConfirmation(latestUserMessage) {
            let approvalRequest = await approvalRequest(for: approval, request: request)
            return AskSessionResponse(
                message: approvalRequest?.message ?? L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "上一条里还有待确认的文件移动。回复“确认”执行，回复“取消”放弃，或者直接给我一个新的文件/网页操作指令。",
                    en: "There is still a pending file move waiting for confirmation. Reply with “confirm” to run it, “cancel” to drop it, or send a new file/web operator instruction."
                ),
                cards: approvalRequest?.cards ?? [],
                metadata: [
                    "operator_handled": "true",
                    "operator_action": "move_waiting_confirmation",
                    "active_operation_id": approval.request.arguments["operation_id"] ?? "",
                    "active_action_id": approval.approvalID,
                    "session_id": request.metadata.sessionID
                ]
            )
        }

        let resolved = await resolveKernelApproval(
            approval,
            decision: AskApprovalDecision.approve.rawValue,
            request: request,
            onEvent: onEvent
        )
        return AskSessionResponse(
            message: resolved.summary,
            cards: resolved.cards,
            metadata: [
                "operator_handled": "true",
                "operator_action": resolved.ok ? "move_execute" : "move_failed",
                "operator_moved_count": stringValue(from: resolved.data["moved_count"]) ?? "0",
                "operator_skipped_count": stringValue(from: resolved.data["skipped_count"]) ?? "0",
                "session_id": request.metadata.sessionID
            ]
        )
    }

    private func parseCommand(from text: String, metadata: AskSessionMetadata) -> Command? {
        let normalized = normalize(text)
        let mentionsFile = containsAny(normalized, in: AskOperatorSupportFileTerms.all)
        let mentionsWeb = containsAny(normalized, in: AskOperatorSupportWebTerms.all)

        if mentionsFile && mentionsWeb && containsAny(normalized, in: [" and ", " 并", "然后", "再把"]) {
            return .mixedPlan
        }

        if let url = firstURL(in: text) {
            return .openURL(url, preferredBrowserBundleID: preferredBrowserBundleID(from: normalized, sourceBundleID: metadata.sourceBundleID))
        }

        if mentionsWeb,
           referencesCurrentPage(normalized) {
            let pageQuery = currentPageQuery(from: text)
            return .inspectCurrentPage(query: pageQuery)
        }

        if mentionsWeb,
           let query = webSearchQuery(from: text) {
            return .searchWeb(
                query: query,
                preferredBrowserBundleID: preferredBrowserBundleID(from: normalized, sourceBundleID: metadata.sourceBundleID)
            )
        }

        if mentionsFile,
           let explicitPath = explicitPathURL(from: text) {
            if containsAny(normalized, in: ["reveal", "show in finder", "显示", "在 finder 中", "访达"]) {
                return .revealPath(explicitPath)
            }
            return .openPath(explicitPath)
        }

        if mentionsFile,
           let folderCreation = folderCreationTarget(from: text) {
            return .createFolder(name: folderCreation.name, directory: folderCreation.parentDirectory)
        }

        if mentionsFile,
           containsAny(normalized, in: ["move", "移动"]) {
            guard let criteria = fileSearchCriteria(from: text) else { return nil }
            guard let destination = moveDestination(from: text) else { return nil }
            return .moveFiles(
                criteria: criteria,
                destinationDirectory: destination.directory,
                createDestinationIfNeeded: destination.createIfMissing
            )
        }

        if mentionsFile,
           containsAny(normalized, in: ["open", "打开", "reveal", "显示"]) {
            if let namedFolder = standardFolderURL(from: normalized) {
                return containsAny(normalized, in: ["reveal", "显示", "在 finder 中"])
                    ? .revealPath(namedFolder)
                    : .openPath(namedFolder)
            }

            if let criteria = fileSearchCriteria(from: text) {
                let action: FileSearchAction = containsAny(normalized, in: ["reveal", "显示", "finder", "访达"]) ? .revealSingle : .openSingle
                return .searchFiles(criteria: criteria, action: action)
            }
        }

        if mentionsFile,
           containsAny(normalized, in: ["search", "find", "look up", "查找", "找一下", "搜索", "列出"]) {
            guard let criteria = fileSearchCriteria(from: text) else { return nil }
            return .searchFiles(criteria: criteria, action: .list)
        }

        return nil
    }

    private func prepareExplicitMove(
        sourcePaths: [String],
        destinationDirectory: URL,
        createDestinationIfNeeded: Bool,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        let staged = await stageMovePathsViaKernel(
            selectionID: nil,
            sourcePaths: sourcePaths,
            destinationDirectory: destinationDirectory,
            createDestinationIfNeeded: createDestinationIfNeeded,
            request: request,
            onEvent: onEvent
        )
        guard staged.ok,
              let operationID = staged.data["operation_id"] as? String,
              !operationID.isEmpty else {
            return staged
        }
        return await commitStagedOperationViaKernel(
            operationID: operationID,
            request: request,
            onEvent: onEvent
        )
    }

    private func stageMovePathsViaKernel(
        selectionID: String?,
        sourcePaths: [String],
        destinationDirectory: URL,
        createDestinationIfNeeded: Bool,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(
            .status(
                "operator",
                detail: L10n.format(
                    languageCode: request.uiLanguage,
                    zhHans: "正在生成移动方案到 %@…",
                    en: "Preparing the move plan to %@…",
                    displayPath(destinationDirectory)
                )
            )
        )

        let resolvedSourcePaths: [String]
        if let selectionID,
           let selection = await sessionStore.selection(for: selectionID) {
            resolvedSourcePaths = selection.paths
        } else {
            resolvedSourcePaths = sourcePaths
        }

        let result = await executeLegacyKernelCapability(
            capabilityID: "desktop.stage_move_operation",
            arguments: compactKernelArguments([
                "source_paths": resolvedSourcePaths.joined(separator: "\n"),
                "destination_directory": destinationDirectory.path,
                "create_destination_if_needed": createDestinationIfNeeded ? "true" : "false"
            ]),
            request: request
        )

        var data = capabilityBridgeData(from: result)
        if let selectionID, !selectionID.isEmpty {
            data["selection_id"] = selectionID
        }
        if let affectedCount = intValue(from: data["affected_count"]) {
            data["affected_count"] = affectedCount
        }
        if let collisionCount = intValue(from: data["collision_count"]) {
            data["collision_count"] = collisionCount
        }
        if let skippedCount = intValue(from: data["skipped_count"]) {
            data["skipped_count"] = skippedCount
        }
        if let createDestinationIfNeeded = boolValue(from: data["create_destination_if_needed"]) {
            data["create_destination_if_needed"] = createDestinationIfNeeded
        }
        if result.status == .succeeded,
           let mirroredOperation = await mirroredKernelMoveOperation(
                from: result,
                selectionID: selectionID,
                sourcePaths: resolvedSourcePaths,
                request: request
           ) {
            await sessionStore.setOperation(mirroredOperation)
        }

        let message = result.status == .succeeded
            ? L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "已生成移动方案，包含 %@ 个项目。",
                en: "Prepared a move plan with %@ item(s).",
                result.metadata["affected_count"] ?? "0"
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "没有生成可执行的移动方案。",
                    en: "I could not prepare a usable move plan."
                )
            )

        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: message,
            data: data,
            cards: [],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : message
        )
    }

    private func commitStagedOperationViaKernel(
        operationID: String,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(.status("operator", detail: L10n.text(languageCode: request.uiLanguage, zhHans: "正在提交移动方案…", en: "Submitting the staged operation…")))

        let mirroredOperation = await sessionStore.operation(for: operationID)
        var arguments: AskInvocationMetadata = [
            "operation_id": operationID
        ]
        if let mirroredOperation {
            arguments["destination_directory"] = mirroredOperation.destinationDirectoryPath
            arguments["affected_count"] = String(mirroredOperation.affectedItemCount)
        }

        let result = await executeLegacyKernelCapability(
            capabilityID: "desktop.commit_move_operation",
            arguments: arguments,
            request: request
        )

        if result.status == .waitingApproval {
            if var mirroredOperation {
                mirroredOperation.status = .awaitingApproval
                await sessionStore.setOperation(mirroredOperation)
            }
            let approvalRequest = await approvalRequestForKernelResult(
                result,
                request: request
            )
            var data = capabilityBridgeData(from: result)
            data["requires_approval"] = true
            data["action_id"] = approvalRequest?.actionID ?? data["approval_id"] ?? ""
            if let mirroredOperation {
                data["affected_count"] = mirroredOperation.affectedItemCount
                data["skipped_count"] = mirroredOperation.skippedPaths.count
                data["destination_directory"] = mirroredOperation.destinationDirectoryPath
                data["create_destination_if_needed"] = mirroredOperation.createDestinationIfNeeded
            }
            if let affectedCount = intValue(from: data["affected_count"]) {
                data["affected_count"] = affectedCount
            }
            let summary = approvalRequest?.message ?? L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "这个移动方案正在等待你的确认。",
                en: "This move plan is waiting for your approval."
            )
            return AskToolExecutionResult(
                ok: true,
                summary: summary,
                data: data,
                cards: approvalRequest?.cards ?? [],
                approvalRequest: approvalRequest,
                error: nil
            )
        }

        let message = result.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: "desktop.commit_move_operation",
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "执行文件移动失败。",
                    en: "Failed to execute the file move."
                )
            )

        var data = capabilityBridgeData(from: result)
        if let movedCount = intValue(from: data["moved_count"]) {
            data["moved_count"] = movedCount
        }
        if let skippedCount = intValue(from: data["skipped_count"]) {
            data["skipped_count"] = skippedCount
        }
        if let affectedCount = intValue(from: data["affected_count"]) {
            data["affected_count"] = affectedCount
        }

        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: message,
            data: data,
            cards: capabilityFollowupCards(
                for: "desktop.commit_move_operation",
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            ),
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : message
        )
    }

    private func cancelStagedOperationViaKernel(
        operationID: String,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(.status("operator", detail: L10n.text(languageCode: request.uiLanguage, zhHans: "正在取消移动方案…", en: "Cancelling the staged operation…")))

        let result = await executeLegacyKernelCapability(
            capabilityID: "desktop.cancel_move_operation",
            arguments: [
                "operation_id": operationID
            ],
            request: request
        )

        if result.status == .succeeded,
           var mirroredOperation = await sessionStore.operation(for: operationID) {
            mirroredOperation.status = .cancelled
            await sessionStore.setOperation(mirroredOperation)
        }

        let message = result.status == .succeeded
            ? L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "已取消这个待执行的移动方案。",
                en: "Cancelled the staged move operation."
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "取消移动方案失败。",
                    en: "Failed to cancel the move plan."
                )
            )

        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: message,
            data: capabilityBridgeData(from: result),
            cards: [],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : message
        )
    }

    private func resolvePendingApproval(
        actionID: String,
        decision: String,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        if let kernelApproval = await kernelApprovalRouter.approvalRequest(id: actionID) {
            return await resolveKernelApproval(
                kernelApproval,
                decision: decision,
                request: request,
                onEvent: onEvent
            )
        }

        if let pendingKernelApproval = await kernelApprovalRouter.latestApprovalRequest(sessionID: request.metadata.sessionID) {
            let approvalRequest = await approvalRequest(for: pendingKernelApproval, request: request)
            let message = L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "待审批动作 id 不匹配。当前会话正在等待 %@。",
                en: "The approval action id did not match. This session is currently waiting for %@.",
                pendingKernelApproval.approvalID
            )
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: [
                    "action_id": pendingKernelApproval.approvalID,
                    "capability_id": pendingKernelApproval.request.capability.id
                ],
                cards: approvalRequest?.cards ?? [],
                approvalRequest: approvalRequest,
                error: message
            )
        }

        let noPendingMessage = L10n.text(
            languageCode: request.responseLanguage,
            zhHans: "当前没有待审批的动作。",
            en: "There is no pending approval in this session."
        )
        return AskToolExecutionResult(
            ok: false,
            summary: noPendingMessage,
            data: [:],
            cards: [],
            approvalRequest: nil,
            error: noPendingMessage
        )
    }

    private func resolveKernelApproval(
        _ approval: AskCapabilityApprovalRecord,
        decision: String,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(
            .status(
                "operator",
                detail: L10n.text(
                    languageCode: request.uiLanguage,
                    zhHans: "正在处理待审批动作…",
                    en: "Resolving the pending approval…"
                )
            )
        )

        let normalizedDecision = normalize(decision)
        let shouldApprove = !containsAny(normalizedDecision, in: ["cancel", "取消", "stop", "deny", "拒绝"])
        let resolved = await agentKernel.makeExecutionCoordinator().resolveApproval(
            approvalID: approval.approvalID,
            shouldApprove: shouldApprove
        )

        if approval.request.capability.id == "desktop.commit_move_operation" {
            await synchronizeMirroredMoveApproval(
                approval: approval,
                resolved: resolved,
                approved: shouldApprove
            )
        }

        if !shouldApprove {
            var data = capabilityBridgeData(from: resolved)
            data["action_id"] = approval.approvalID
            return AskToolExecutionResult(
                ok: true,
                summary: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "已取消这次待审批动作。",
                    en: "Cancelled the pending action."
                ),
                data: data,
                cards: [],
                approvalRequest: nil,
                error: nil
            )
        }

        let message = resolved.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: approval.request.capability.id,
                metadata: resolved.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: resolved,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "这次待审批动作执行失败。",
                    en: "The approved action failed to execute."
                )
            )

        var data = capabilityBridgeData(from: resolved)
        data["action_id"] = approval.approvalID
        if let movedCount = intValue(from: data["moved_count"]) {
            data["moved_count"] = movedCount
            data["executed_count"] = movedCount
        } else if let affectedCount = intValue(from: data["affected_count"]) {
            data["executed_count"] = affectedCount
        }
        if let skippedCount = intValue(from: data["skipped_count"]) {
            data["skipped_count"] = skippedCount
        }
        if let affectedCount = intValue(from: data["affected_count"]) {
            data["affected_count"] = affectedCount
        }

        return AskToolExecutionResult(
            ok: resolved.status == .succeeded,
            summary: message,
            data: data,
            cards: capabilityFollowupCards(
                for: approval.request.capability.id,
                metadata: resolved.metadata,
                responseLanguage: request.responseLanguage
            ),
            approvalRequest: nil,
            error: resolved.status == .succeeded ? nil : message
        )
    }

    private func createFolderViaKernel(
        named folderName: String,
        in parentDirectory: URL,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(
            .status(
                "operator",
                detail: L10n.format(
                    languageCode: request.uiLanguage,
                    zhHans: "正在创建文件夹“%@”…",
                    en: "Creating the folder “%@”…",
                    folderName
                )
            )
        )

        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.create_directory",
            arguments: [
                "name": folderName,
                "parent_directory": parentDirectory.path,
                "workspace_root": parentDirectory.path
            ],
            request: request
        )

        let createdPath = result.metadata["created_path"]
            ?? parentDirectory.appendingPathComponent(folderName, isDirectory: true).path
        let createdURL = URL(fileURLWithPath: createdPath, isDirectory: true)

        if result.status == .waitingApproval {
            let approvalRequest = await approvalRequestForKernelResult(
                result,
                request: request
            )
            let summary = approvalRequest?.message ?? L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "这个文件夹创建任务正在等待你的确认。",
                en: "This folder creation task is waiting for your approval."
            )
            return AskToolExecutionResult(
                ok: true,
                summary: summary,
                data: capabilityBridgeData(from: result).merging(
                    [
                        "action_id": approvalRequest?.actionID ?? result.metadata["approval_id"] ?? ""
                    ]
                ) { _, new in new },
                cards: approvalRequest?.cards ?? [],
                approvalRequest: approvalRequest,
                error: nil
            )
        }

        let message = result.status == .succeeded
            ? L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "已创建文件夹“%@”。",
                en: "Created the folder “%@”.",
                createdURL.lastPathComponent
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "创建文件夹失败。",
                    en: "Failed to create the folder."
                )
            )

        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: message,
            data: capabilityBridgeData(from: result),
            cards: result.status == .succeeded ? [
                makeCard(
                    id: "folder-open-\(createdURL.path.hashValue)",
                    title: createdURL.lastPathComponent,
                    subtitle: displayPath(parentDirectory),
                    description: L10n.text(languageCode: request.responseLanguage, zhHans: "点击可直接打开这个文件夹。", en: "Click to open this folder directly."),
                    action: .openFile,
                    value: createdURL.path
                )
            ] : [],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : message
        )
    }

    private func listWorkspaceRoots(request: AskSessionRequest) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.list_roots",
            arguments: [:],
            request: request
        )
        let roots = result.artifacts
            .filter { $0.kind == "workspace_root" }
            .map(\.value)

        let summary = result.status == .succeeded
            ? L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "找到了 %d 个可用工作区。",
                en: "Found %d available workspace roots.",
                roots.count
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "暂时没有找到可用工作区。",
                    en: "I could not find any available workspace roots right now."
                )
            )

        let cards = roots.prefix(6).map { root in
            makeCard(
                id: "workspace-root-\(root.hashValue)",
                title: URL(fileURLWithPath: root).lastPathComponent,
                subtitle: root,
                description: nil,
                action: .revealInFinder,
                value: root
            )
        }

        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: cards,
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : summary
        )
    }

    private func setActiveWorkspace(
        workspaceRoot: String,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.set_active_root",
            arguments: compactKernelArguments([
                "workspace_root": workspaceRoot
            ]),
            request: request
        )
        let resolvedRoot = result.metadata["workspace_root"] ?? workspaceRoot
        let summary = result.status == .succeeded
            ? L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "已把 %@ 设为当前工作区。",
                en: "Set %@ as the active workspace.",
                URL(fileURLWithPath: resolvedRoot).lastPathComponent
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "设置当前工作区失败。",
                    en: "Failed to set the active workspace."
                )
            )
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: result.status == .succeeded ? [
                makeCard(
                    id: "workspace-active-\(resolvedRoot.hashValue)",
                    title: URL(fileURLWithPath: resolvedRoot).lastPathComponent,
                    subtitle: resolvedRoot,
                    description: L10n.text(
                        languageCode: request.responseLanguage,
                        zhHans: "后续代码相关动作会优先沿用这个工作区。",
                        en: "Later coding actions will reuse this workspace first."
                    ),
                    action: .revealInFinder,
                    value: resolvedRoot
                )
            ] : [],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : summary
        )
    }

    private func snapshotWorkspaceTree(
        workspaceRoot: String?,
        limit: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.snapshot_tree",
            arguments: compactKernelArguments([
                "workspace_root": workspaceRoot,
                "limit": limit
            ]),
            request: request
        )
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: result.status == .succeeded
                ? L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "我已经枚举了工作区结构。",
                    en: "I enumerated the workspace structure."
                )
                : legacyCapabilityFailureMessage(
                    from: result,
                    fallback: L10n.text(
                        languageCode: request.responseLanguage,
                        zhHans: "读取工作区结构失败。",
                        en: "Failed to enumerate the workspace structure."
                    )
                ),
            data: capabilityBridgeData(from: result),
            cards: [],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : result.summary
        )
    }

    private func globWorkspacePaths(
        glob: String,
        workspaceRoot: String?,
        limit: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.glob_paths",
            arguments: compactKernelArguments([
                "glob": glob,
                "workspace_root": workspaceRoot,
                "limit": limit
            ]),
            request: request
        )
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: result.status == .succeeded
                ? localizedCapabilitySuccessSummary(
                    capabilityID: "workspace.glob_paths",
                    metadata: result.metadata,
                    responseLanguage: request.responseLanguage
                )
                : legacyCapabilityFailureMessage(
                    from: result,
                    fallback: L10n.text(
                        languageCode: request.responseLanguage,
                        zhHans: "按 glob 枚举工作区路径失败。",
                        en: "Failed to enumerate workspace paths by glob."
                    )
                ),
            data: capabilityBridgeData(from: result),
            cards: [],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : result.summary
        )
    }

    private func enterPlanModeInWorkspace(
        workspaceRoot: String?,
        planScope: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.enter_plan_mode",
            arguments: compactKernelArguments([
                "workspace_root": workspaceRoot,
                "plan_scope": planScope
            ]),
            request: request
        )
        let resolvedRoot = result.metadata["workspace_root"]
            ?? workspaceRoot
            ?? request.metadata.kernelMetadata["workspace_root"]
            ?? ""
        let summary = result.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: "workspace.enter_plan_mode",
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "进入工作区规划模式失败。",
                    en: "Failed to enter workspace planning mode."
                )
            )
        let cards: [SkillResultCard]
        if result.status == .succeeded, !resolvedRoot.isEmpty {
            cards = [
                makeCard(
                    id: "workspace-plan-active-\(resolvedRoot.hashValue)",
                    title: L10n.text(languageCode: request.responseLanguage, zhHans: "规划模式已开启", en: "Planning mode active"),
                    subtitle: URL(fileURLWithPath: resolvedRoot).lastPathComponent,
                    description: planScope ?? result.metadata["plan_mode_summary"] ?? resolvedRoot,
                    action: .revealInFinder,
                    value: resolvedRoot
                )
            ]
        } else {
            cards = []
        }
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: cards,
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : summary
        )
    }

    private func exitPlanModeInWorkspace(
        workspaceRoot: String?,
        executionScope: String?,
        permissionProfile: String?,
        grantWorkspaceWrites: Bool?,
        grantShellExecution: Bool?,
        grantGitWriteActions: Bool?,
        grantNetworkAccess: Bool?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.exit_plan_mode",
            arguments: compactKernelArguments([
                "workspace_root": workspaceRoot,
                "execution_scope": executionScope,
                "permission_profile": permissionProfile,
                "grant_workspace_writes": grantWorkspaceWrites.map { $0 ? "true" : "false" },
                "grant_shell_execution": grantShellExecution.map { $0 ? "true" : "false" },
                "grant_git_write_actions": grantGitWriteActions.map { $0 ? "true" : "false" },
                "grant_network_access": grantNetworkAccess.map { $0 ? "true" : "false" }
            ]),
            request: request
        )
        let resolvedRoot = result.metadata["workspace_root"]
            ?? workspaceRoot
            ?? request.metadata.kernelMetadata["workspace_root"]
            ?? ""
        let summary = result.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: "workspace.exit_plan_mode",
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "退出工作区规划模式失败。",
                    en: "Failed to leave workspace planning mode."
                )
            )
        let cards: [SkillResultCard]
        if result.status == .succeeded, !resolvedRoot.isEmpty {
            cards = [
                makeCard(
                    id: "workspace-plan-inactive-\(resolvedRoot.hashValue)",
                    title: L10n.text(languageCode: request.responseLanguage, zhHans: "规划模式已退出", en: "Planning mode ended"),
                    subtitle: URL(fileURLWithPath: resolvedRoot).lastPathComponent,
                    description: localizedWorkspaceExecutionGrantDescription(
                        metadata: result.metadata,
                        fallbackScope: executionScope ?? result.metadata["plan_mode_summary"] ?? resolvedRoot,
                        responseLanguage: request.responseLanguage
                    ),
                    action: .revealInFinder,
                    value: resolvedRoot
                )
            ]
        } else {
            cards = []
        }
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: cards,
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : summary
        )
    }

    private func setWorkspaceExecutionBudgetInWorkspace(
        workspaceRoot: String?,
        budgetSummary: String?,
        permissionProfile: String?,
        grantWorkspaceWrites: Bool?,
        grantShellExecution: Bool?,
        grantGitWriteActions: Bool?,
        grantNetworkAccess: Bool?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.set_execution_budget",
            arguments: compactKernelArguments([
                "workspace_root": workspaceRoot,
                "budget_summary": budgetSummary,
                "permission_profile": permissionProfile,
                "grant_workspace_writes": grantWorkspaceWrites.map { $0 ? "true" : "false" },
                "grant_shell_execution": grantShellExecution.map { $0 ? "true" : "false" },
                "grant_git_write_actions": grantGitWriteActions.map { $0 ? "true" : "false" },
                "grant_network_access": grantNetworkAccess.map { $0 ? "true" : "false" }
            ]),
            request: request
        )
        let resolvedRoot = result.metadata["workspace_root"]
            ?? workspaceRoot
            ?? request.metadata.kernelMetadata["workspace_root"]
            ?? ""
        let summary = result.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: "workspace.set_execution_budget",
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "更新工作区 session 权限失败。",
                    en: "Failed to update the workspace session execution budget."
                )
            )
        let cards: [SkillResultCard]
        if result.status == .succeeded, !resolvedRoot.isEmpty {
            cards = [
                makeCard(
                    id: "workspace-execution-budget-\(resolvedRoot.hashValue)",
                    title: L10n.text(languageCode: request.responseLanguage, zhHans: "Session 权限已更新", en: "Session permissions updated"),
                    subtitle: URL(fileURLWithPath: resolvedRoot).lastPathComponent,
                    description: localizedWorkspaceExecutionBudgetDescription(
                        metadata: result.metadata,
                        responseLanguage: request.responseLanguage
                    ),
                    action: .revealInFinder,
                    value: resolvedRoot
                )
            ]
        } else {
            cards = []
        }
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: cards,
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : summary
        )
    }

    private func listTasksInKernel(
        workspaceRoot: String?,
        includeTerminal: Bool?,
        limit: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "system.list_tasks",
            arguments: compactKernelArguments([
                "workspace_root": workspaceRoot,
                "include_terminal": includeTerminal.map { $0 ? "true" : "false" },
                "limit": limit,
                "session_id": request.metadata.sessionID
            ]),
            request: request
        )
        let summary = result.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: "system.list_tasks",
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "查看任务列表失败。",
                    en: "Failed to list the recorded tasks."
                )
            )
        let cards: [SkillResultCard]
        if result.status == .succeeded {
            let listedCount = result.metadata["listed_task_count"] ?? "0"
            let openCount = result.metadata["open_task_count"] ?? listedCount
            cards = [
                makeCard(
                    id: "task-list-\(request.metadata.sessionID.hashValue)",
                    title: L10n.text(languageCode: request.responseLanguage, zhHans: "任务列表", en: "Task list"),
                    subtitle: L10n.format(
                        languageCode: request.responseLanguage,
                        zhHans: "已列出 %@ 个任务",
                        en: "Listed %@ tasks",
                        listedCount
                    ),
                    description: L10n.format(
                        languageCode: request.responseLanguage,
                        zhHans: "当前 open tasks：%@",
                        en: "Current open tasks: %@",
                        openCount
                    ),
                    action: nil,
                    value: nil
                )
            ]
        } else {
            cards = []
        }
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: cards,
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : summary
        )
    }

    private func getTaskInKernel(
        taskID: String?,
        resumeToken: String?,
        query: String?,
        workspaceRoot: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "system.get_task",
            arguments: compactKernelArguments([
                "task_id": taskID,
                "resume_token": resumeToken,
                "query": query,
                "workspace_root": workspaceRoot,
                "session_id": request.metadata.sessionID
            ]),
            request: request
        )
        let summary = result.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: "system.get_task",
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "读取任务详情失败。",
                    en: "Failed to load the task details."
                )
            )
        let cards: [SkillResultCard]
        if result.status == .succeeded {
            let taskTitle = result.metadata["task_title"]
                ?? query
                ?? L10n.text(languageCode: request.responseLanguage, zhHans: "目标任务", en: "Target task")
            let workspaceLabel = (result.metadata["task_workspace_root"] ?? result.metadata["workspace_root"] ?? workspaceRoot)
                .flatMap { root -> String? in
                    guard !root.isEmpty else { return nil }
                    return URL(fileURLWithPath: root).lastPathComponent
                }
            cards = [
                makeCard(
                    id: "task-detail-\((result.metadata["task_id"] ?? UUID().uuidString).hashValue)",
                    title: L10n.text(languageCode: request.responseLanguage, zhHans: "任务详情", en: "Task details"),
                    subtitle: taskTitle,
                    description: workspaceLabel,
                    action: nil,
                    value: nil
                )
            ]
        } else {
            cards = []
        }
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: cards,
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : summary
        )
    }

    private func updateTaskInKernel(
        taskID: String?,
        resumeToken: String?,
        query: String?,
        newTitle: String?,
        newObjective: String?,
        status: String?,
        note: String?,
        workspaceRoot: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "system.update_task",
            arguments: compactKernelArguments([
                "task_id": taskID,
                "resume_token": resumeToken,
                "query": query,
                "new_title": newTitle,
                "new_objective": newObjective,
                "status": status,
                "note": note,
                "workspace_root": workspaceRoot,
                "session_id": request.metadata.sessionID
            ]),
            request: request
        )
        let summary = result.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: "system.update_task",
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "更新任务失败。",
                    en: "Failed to update the task."
                )
            )
        let cards: [SkillResultCard]
        if result.status == .succeeded {
            let taskTitle = result.metadata["task_title"]
                ?? newTitle
                ?? query
                ?? L10n.text(languageCode: request.responseLanguage, zhHans: "目标任务", en: "Target task")
            cards = [
                makeCard(
                    id: "task-update-\((result.metadata["task_id"] ?? UUID().uuidString).hashValue)",
                    title: L10n.text(languageCode: request.responseLanguage, zhHans: "任务已更新", en: "Task updated"),
                    subtitle: taskTitle,
                    description: result.metadata["task_status"],
                    action: nil,
                    value: nil
                )
            ]
        } else {
            cards = []
        }
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: cards,
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : summary
        )
    }

    private func stopTaskInKernel(
        taskID: String?,
        resumeToken: String?,
        query: String?,
        reason: String?,
        workspaceRoot: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "system.stop_task",
            arguments: compactKernelArguments([
                "task_id": taskID,
                "resume_token": resumeToken,
                "query": query,
                "reason": reason,
                "workspace_root": workspaceRoot,
                "session_id": request.metadata.sessionID
            ]),
            request: request
        )
        let summary = result.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: "system.stop_task",
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "停止任务失败。",
                    en: "Failed to stop the task."
                )
            )
        let cards: [SkillResultCard]
        if result.status == .succeeded {
            let taskTitle = result.metadata["task_title"]
                ?? query
                ?? L10n.text(languageCode: request.responseLanguage, zhHans: "目标任务", en: "Target task")
            cards = [
                makeCard(
                    id: "task-stop-\((result.metadata["task_id"] ?? UUID().uuidString).hashValue)",
                    title: L10n.text(languageCode: request.responseLanguage, zhHans: "任务已停止", en: "Task stopped"),
                    subtitle: taskTitle,
                    description: result.metadata["task_status"],
                    action: nil,
                    value: nil
                )
            ]
        } else {
            cards = []
        }
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: cards,
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : summary
        )
    }

    private func spawnSubtaskInKernel(
        title: String,
        objective: String,
        workspaceRoot: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "system.spawn_subtask",
            arguments: compactKernelArguments([
                "title": title,
                "objective": objective,
                "workspace_root": workspaceRoot
            ]),
            request: request
        )
        let summary = result.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: "system.spawn_subtask",
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "记录子任务失败。",
                    en: "Failed to record the child task."
                )
            )
        let cards: [SkillResultCard]
        if result.status == .succeeded {
            let subtaskTitle = result.metadata["subtask_title"] ?? title
            let workspaceLabel = (result.metadata["workspace_root"] ?? workspaceRoot).flatMap { root -> String? in
                guard !root.isEmpty else { return nil }
                return URL(fileURLWithPath: root).lastPathComponent
            }
            cards = [
                makeCard(
                    id: "subtask-\((result.metadata["subtask_id"] ?? UUID().uuidString).hashValue)",
                    title: L10n.text(languageCode: request.responseLanguage, zhHans: "已记录子任务", en: "Child task recorded"),
                    subtitle: subtaskTitle,
                    description: workspaceLabel,
                    action: nil,
                    value: nil
                )
            ]
        } else {
            cards = []
        }
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: cards,
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : summary
        )
    }

    private func writeTodoInKernel(
        taskID: String?,
        resumeToken: String?,
        query: String?,
        itemsJSON: String,
        workspaceRoot: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "system.write_todo",
            arguments: compactKernelArguments([
                "task_id": taskID,
                "resume_token": resumeToken,
                "query": query,
                "items_json": itemsJSON,
                "workspace_root": workspaceRoot,
                "session_id": request.metadata.sessionID
            ]),
            request: request
        )
        let summary = result.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: "system.write_todo",
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "写入任务清单失败。",
                    en: "Failed to write the task checklist."
                )
            )
        let cards: [SkillResultCard]
        if result.status == .succeeded {
            let taskTitle = result.metadata["task_title"]
                ?? result.metadata["active_task_title"]
                ?? query
                ?? L10n.text(languageCode: request.responseLanguage, zhHans: "当前任务", en: "Active task")
            cards = [
                makeCard(
                    id: "task-todo-\((result.metadata["task_id"] ?? UUID().uuidString).hashValue)",
                    title: L10n.text(languageCode: request.responseLanguage, zhHans: "任务清单已更新", en: "Task checklist updated"),
                    subtitle: taskTitle,
                    description: result.metadata["task_progress_summary"] ?? result.metadata["active_task_progress_summary"],
                    action: nil,
                    value: nil
                )
            ]
        } else {
            cards = []
        }
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: cards,
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : summary
        )
    }

    private func listMCPResources(
        server: String?,
        request: AskSessionRequest
    ) -> AskToolExecutionResult {
        let availableServers = availableMCPServers()
        let connectionDiagnostics = mcpConnectionStore.diagnosticsSnapshot()
        let connectionsByServer = Dictionary(
            uniqueKeysWithValues: mcpConnectionStore.listConnections().map { ($0.serverName, $0) }
        )
        guard !availableServers.isEmpty else {
            let message = L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "当前还没有可用的 MCP 连接或镜像 resource server。",
                en: "There are no MCP connections or mirrored resource servers available right now."
            )
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: [
                    "servers": [],
                    "connections": [],
                    "connection_diagnostics": connectionDiagnostics.payload
                ],
                cards: [],
                approvalRequest: nil,
                error: message
            )
        }

        let resolvedServer = resolvedMCPServerName(from: server, availableServers: availableServers)
        if server != nil && resolvedServer == nil {
            return unknownMCPServerResult(
                requestedServer: server ?? "",
                availableServers: availableServers,
                request: request
            )
        }

        let resources = mcpResourceCatalog.listResources(serverName: resolvedServer)
        let payload = resources.map(mcpResourcePayload)
        let visibleConnections: [AskMCPConnectionRecord]
        if let resolvedServer, let record = connectionsByServer[resolvedServer] {
            visibleConnections = [record]
        } else if resolvedServer != nil {
            visibleConnections = []
        } else {
            visibleConnections = availableServers.compactMap { connectionsByServer[$0] }
        }
        let connectionPayload = visibleConnections.map(mcpConnectionPayload)
        let summary: String
        let cardDescription: String?

        if let resolvedServer {
            if resources.isEmpty {
                if let connection = connectionsByServer[resolvedServer] {
                    summary = L10n.format(
                        languageCode: request.responseLanguage,
                        zhHans: "MCP server %@ 当前状态为 %@，但还没有镜像可读资源。",
                        en: "MCP server %@ is currently %@, but it has no mirrored readable resources yet.",
                        resolvedServer,
                        localizedMCPConnectionStatus(connection.status, languageCode: request.responseLanguage)
                    )
                    cardDescription = localizedMCPConnectionStatus(connection.status, languageCode: request.responseLanguage)
                } else {
                    summary = L10n.format(
                        languageCode: request.responseLanguage,
                        zhHans: "MCP server %@ 当前没有镜像可读资源。",
                        en: "MCP server %@ currently has no mirrored readable resources.",
                        resolvedServer
                    )
                    cardDescription = nil
                }
            } else {
                summary = L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "已列出来自 %@ 的 %d 个 MCP 资源。",
                    en: "Listed %d MCP resources from %@.",
                    resources.count,
                    resolvedServer
                )
                cardDescription = L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "%d 个资源",
                    en: "%d resources",
                    resources.count
                )
            }
        } else if resources.isEmpty {
            if visibleConnections.isEmpty {
                summary = L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "当前 MCP catalog 中还没有镜像资源。",
                    en: "There are no mirrored MCP resources in the current catalog yet."
                )
                cardDescription = L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "%d 个 server",
                    en: "%d servers",
                    availableServers.count
                )
            } else {
                summary = L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "当前已记录 %d 个 MCP server，但还没有镜像可读资源。",
                    en: "There are %d recorded MCP servers, but no mirrored readable resources yet.",
                    visibleConnections.count
                )
                cardDescription = L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "%d 个连接",
                    en: "%d connections",
                    visibleConnections.count
                )
            }
        } else {
            let serverCount = Set(resources.map(\.serverName)).count
            summary = L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "已列出 %d 个 MCP 资源，来自 %d 个 server。",
                en: "Listed %d MCP resources across %d servers.",
                resources.count,
                serverCount
            )
            cardDescription = L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "%d 个 server",
                en: "%d servers",
                serverCount
            )
        }

        return AskToolExecutionResult(
            ok: true,
            summary: summary,
            data: [
                "server": resolvedServer ?? "",
                "servers": availableServers,
                "connections": connectionPayload,
                "connection_diagnostics": connectionDiagnostics.payload,
                "resource_count": resources.count,
                "resources": payload
            ],
            cards: [
                makeCard(
                    id: "mcp-resource-list-\((resolvedServer ?? "all").lowercased())",
                    title: L10n.text(languageCode: request.responseLanguage, zhHans: "MCP 资源目录", en: "MCP Resource Catalog"),
                    subtitle: resolvedServer ?? L10n.text(languageCode: request.responseLanguage, zhHans: "全部 server", en: "All servers"),
                    description: cardDescription,
                    action: nil,
                    value: nil
                )
            ],
            approvalRequest: nil,
            error: nil
        )
    }

    private func readMCPResource(
        server: String,
        uri: String,
        request: AskSessionRequest
    ) -> AskToolExecutionResult {
        let availableServers = availableMCPServers()
        let connectionDiagnostics = mcpConnectionStore.diagnosticsSnapshot()
        let connectionsByServer = Dictionary(
            uniqueKeysWithValues: mcpConnectionStore.listConnections().map { ($0.serverName, $0) }
        )
        guard !availableServers.isEmpty else {
            let message = L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "当前还没有可用的 MCP 连接或镜像 resource server。",
                en: "There are no MCP connections or mirrored resource servers available right now."
            )
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: [
                    "servers": [],
                    "connections": [],
                    "connection_diagnostics": connectionDiagnostics.payload
                ],
                cards: [],
                approvalRequest: nil,
                error: message
            )
        }

        guard let resolvedServer = resolvedMCPServerName(from: server, availableServers: availableServers) else {
            return unknownMCPServerResult(
                requestedServer: server,
                availableServers: availableServers,
                request: request
            )
        }

        guard let resource = mcpResourceCatalog.readResource(serverName: resolvedServer, uri: uri) else {
            let message: String
            if let connection = connectionsByServer[resolvedServer],
               connection.readableResourceCount == 0 {
                message = L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "MCP server %@ 当前状态为 %@，但还没有镜像到可读取的资源 %@。",
                    en: "MCP server %@ is currently %@, but the readable resource %@ has not been mirrored yet.",
                    resolvedServer,
                    localizedMCPConnectionStatus(connection.status, languageCode: request.responseLanguage),
                    uri
                )
            } else {
                message = L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "在 %@ 上找不到 MCP 资源：%@。",
                    en: "Couldn't find MCP resource on %@: %@.",
                    resolvedServer,
                    uri
                )
            }
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: [
                    "server": resolvedServer,
                    "uri": uri,
                    "servers": availableServers,
                    "connection": connectionsByServer[resolvedServer].map(mcpConnectionPayload) ?? [:],
                    "connection_diagnostics": connectionDiagnostics.payload
                ],
                cards: [],
                approvalRequest: nil,
                error: message
            )
        }

        let payload = mcpResourcePayload(resource)
        let hasTextContent = !(resource.textContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let summary = hasTextContent
            ? L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "已读取 %@ 上的 MCP 资源：%@。",
                en: "Read MCP resource on %@: %@.",
                resource.serverName,
                resource.uri
            )
            : L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "已读取 %@ 上的 MCP 资源元数据：%@，但当前没有缓存文本内容。",
                en: "Loaded MCP resource metadata on %@: %@, but no cached text content is available yet.",
                resource.serverName,
                resource.uri
            )

        let description = resource.mimeType ?? {
            hasTextContent
                ? L10n.text(languageCode: request.responseLanguage, zhHans: "包含文本内容", en: "Includes text content")
                : L10n.text(languageCode: request.responseLanguage, zhHans: "仅有元数据", en: "Metadata only")
        }()

        return AskToolExecutionResult(
            ok: true,
            summary: summary,
            data: [
                "server": resource.serverName,
                "uri": resource.uri,
                "resource": payload,
                "has_text_content": hasTextContent,
                "text_content": resource.textContent ?? "",
                "servers": availableServers,
                "connection": connectionsByServer[resolvedServer].map(mcpConnectionPayload) ?? [:],
                "connection_diagnostics": connectionDiagnostics.payload
            ],
            cards: [
                makeCard(
                    id: "mcp-resource-read-\(resource.serverName.lowercased())-\(resource.uri.hashValue)",
                    title: L10n.text(languageCode: request.responseLanguage, zhHans: "MCP 资源", en: "MCP Resource"),
                    subtitle: resource.name ?? resource.uri,
                    description: description,
                    action: nil,
                    value: nil
                )
            ],
            approvalRequest: nil,
            error: nil
        )
    }

    private func availableMCPServers() -> [String] {
        let servers = Set(mcpResourceCatalog.listServers())
            .union(mcpConnectionStore.listConnections().map(\.serverName))
        return servers.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func mcpConnectionPayload(_ record: AskMCPConnectionRecord) -> [String: Any] {
        [
            "server": record.serverName,
            "display_name": record.displayName ?? "",
            "status": record.status.rawValue,
            "status_label": localizedMCPConnectionStatus(record.status, languageCode: "en"),
            "endpoint_summary": record.endpointSummary ?? "",
            "resource_count": record.readableResourceCount,
            "last_error": record.lastError ?? "",
            "metadata": record.metadata
        ]
    }

    private func localizedMCPConnectionStatus(
        _ status: AskMCPConnectionStatus,
        languageCode: String
    ) -> String {
        switch status {
        case .disconnected:
            return L10n.text(languageCode: languageCode, zhHans: "未连接", en: "disconnected")
        case .connecting:
            return L10n.text(languageCode: languageCode, zhHans: "连接中", en: "connecting")
        case .connected:
            return L10n.text(languageCode: languageCode, zhHans: "已连接", en: "connected")
        case .degraded:
            return L10n.text(languageCode: languageCode, zhHans: "降级", en: "degraded")
        case .failed:
            return L10n.text(languageCode: languageCode, zhHans: "失败", en: "failed")
        }
    }

    private func resolvedMCPServerName(
        from requestedServer: String?,
        availableServers: [String]
    ) -> String? {
        guard let requestedServer = requestedServer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedServer.isEmpty else {
            return nil
        }
        return availableServers.first { candidate in
            candidate.compare(requestedServer, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func unknownMCPServerResult(
        requestedServer: String,
        availableServers: [String],
        request: AskSessionRequest
    ) -> AskToolExecutionResult {
        let availableLabel = availableServers.joined(separator: ", ")
        let message = L10n.format(
            languageCode: request.responseLanguage,
            zhHans: "MCP server %@ 不在当前镜像目录中。可用 server：%@。",
            en: "MCP server %@ is not in the current mirrored catalog. Available servers: %@.",
            requestedServer,
            availableLabel
        )
        return AskToolExecutionResult(
            ok: false,
            summary: message,
            data: ["servers": availableServers],
            cards: [],
            approvalRequest: nil,
            error: message
        )
    }

    private func mcpResourcePayload(_ resource: AskMCPResourceRecord) -> [String: Any] {
        var payload: [String: Any] = [
            "server": resource.serverName,
            "uri": resource.uri,
            "updated_at": ISO8601DateFormatter().string(from: resource.updatedAt),
            "metadata": resource.metadata
        ]
        if let name = resource.name, !name.isEmpty {
            payload["name"] = name
        }
        if let description = resource.description, !description.isEmpty {
            payload["description"] = description
        }
        if let mimeType = resource.mimeType, !mimeType.isEmpty {
            payload["mime_type"] = mimeType
        }
        if let textContent = resource.textContent, !textContent.isEmpty {
            payload["text_content"] = textContent
        }
        return payload
    }

    private func resumeTaskInKernel(
        taskID: String?,
        resumeToken: String?,
        title: String?,
        workspaceRoot: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "system.resume_task",
            arguments: compactKernelArguments([
                "task_id": taskID,
                "resume_token": resumeToken,
                "title": title,
                "workspace_root": workspaceRoot,
                "session_id": request.metadata.sessionID
            ]),
            request: request
        )
        let summary = result.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: "system.resume_task",
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "恢复任务上下文失败。",
                    en: "Failed to restore the task context."
                )
            )
        let cards: [SkillResultCard]
        if result.status == .succeeded {
            let activeTaskTitle = result.metadata["active_task_title"]
                ?? title
                ?? L10n.text(languageCode: request.responseLanguage, zhHans: "当前任务", en: "Active task")
            let workspaceLabel = (result.metadata["active_task_workspace_root"] ?? result.metadata["workspace_root"] ?? workspaceRoot)
                .flatMap { root -> String? in
                    guard !root.isEmpty else { return nil }
                    return URL(fileURLWithPath: root).lastPathComponent
                }
            cards = [
                makeCard(
                    id: "active-task-\((result.metadata["active_task_id"] ?? UUID().uuidString).hashValue)",
                    title: L10n.text(languageCode: request.responseLanguage, zhHans: "已恢复任务上下文", en: "Task context restored"),
                    subtitle: activeTaskTitle,
                    description: workspaceLabel,
                    action: nil,
                    value: nil
                )
            ]
        } else {
            cards = []
        }
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: cards,
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : summary
        )
    }

    private func grepWorkspaceText(
        pattern: String,
        glob: String?,
        workspaceRoot: String?,
        limit: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.grep_text",
            arguments: compactKernelArguments([
                "pattern": pattern,
                "glob": glob,
                "workspace_root": workspaceRoot,
                "limit": limit
            ]),
            request: request
        )
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: result.status == .succeeded
                ? L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "我已经在工作区里完成文本搜索。",
                    en: "I finished searching the workspace text."
                )
                : legacyCapabilityFailureMessage(
                    from: result,
                    fallback: L10n.text(
                        languageCode: request.responseLanguage,
                        zhHans: "工作区文本搜索失败。",
                        en: "Failed to search the workspace text."
                    )
                ),
            data: capabilityBridgeData(from: result),
            cards: [],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : result.summary
        )
    }

    private func readWorkspaceFile(
        path: String,
        workspaceRoot: String?,
        maxLength: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.read_file",
            arguments: compactKernelArguments([
                "path": path,
                "workspace_root": workspaceRoot,
                "max_length": maxLength
            ]),
            request: request
        )
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: result.status == .succeeded
                ? L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "我已经读取了 %@。",
                    en: "I read %@ from the workspace.",
                    URL(fileURLWithPath: path).lastPathComponent
                )
                : legacyCapabilityFailureMessage(
                    from: result,
                    fallback: L10n.text(
                        languageCode: request.responseLanguage,
                        zhHans: "读取工作区文件失败。",
                        en: "Failed to read the workspace file."
                    )
                ),
            data: capabilityBridgeData(from: result),
            cards: [],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : result.summary
        )
    }

    private func writeWorkspaceFile(
        path: String?,
        content: String,
        workspaceRoot: String?,
        createParentDirectories: Bool?,
        overwrite: Bool?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        var arguments: AskInvocationMetadata = ["content": content]
        if let path, !path.isEmpty {
            arguments["path"] = path
        }
        if let workspaceRoot, !workspaceRoot.isEmpty {
            arguments["workspace_root"] = workspaceRoot
        }
        if let createParentDirectories {
            arguments["create_parent_directories"] = createParentDirectories ? "true" : "false"
        }
        if let overwrite {
            arguments["overwrite"] = overwrite ? "true" : "false"
        }
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.write_file",
            arguments: arguments,
            request: request
        )
        if result.status == .waitingApproval {
            return AskToolExecutionResult(
                ok: false,
                summary: localizedCapabilityApprovalSummary(
                    for: "workspace.write_file",
                    responseLanguage: request.responseLanguage
                ),
                data: capabilityBridgeData(from: result),
                cards: [],
                approvalRequest: await approvalRequestForKernelResult(result, request: request),
                error: nil
            )
        }
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: result.status == .succeeded
                ? localizedCapabilitySuccessSummary(
                    capabilityID: "workspace.write_file",
                    metadata: result.metadata,
                    responseLanguage: request.responseLanguage
                )
                : legacyCapabilityFailureMessage(
                    from: result,
                    fallback: L10n.text(
                        languageCode: request.responseLanguage,
                        zhHans: "写入工作区文件失败。",
                        en: "Failed to write the workspace file."
                    )
                ),
            data: capabilityBridgeData(from: result),
            cards: [],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : result.summary
        )
    }

    private func workspaceGitStatus(
        workspaceRoot: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.git_status",
            arguments: compactKernelArguments([
                "workspace_root": workspaceRoot
            ]),
            request: request
        )
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: result.status == .succeeded
                ? L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "我已经读取了工作区的 git 状态。",
                    en: "I collected the workspace git status."
                )
                : legacyCapabilityFailureMessage(
                    from: result,
                    fallback: L10n.text(
                        languageCode: request.responseLanguage,
                        zhHans: "读取 git 状态失败。",
                        en: "Failed to collect workspace git status."
                    )
                ),
            data: capabilityBridgeData(from: result),
            cards: [],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : result.summary
        )
    }

    private func workspaceGitDiff(
        path: String?,
        workspaceRoot: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.git_diff",
            arguments: compactKernelArguments([
                "path": path,
                "workspace_root": workspaceRoot
            ]),
            request: request
        )
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: result.status == .succeeded
                ? L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "我已经读取了工作区的 git diff。",
                    en: "I collected the workspace git diff."
                )
                : legacyCapabilityFailureMessage(
                    from: result,
                    fallback: L10n.text(
                        languageCode: request.responseLanguage,
                        zhHans: "读取 git diff 失败。",
                        en: "Failed to collect workspace git diff."
                    )
                ),
            data: capabilityBridgeData(from: result),
            cards: [],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : result.summary
        )
    }

    private func runShellCommandInWorkspace(
        command: String,
        workspaceRoot: String?,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        await runWorkspaceMutationBridge(
            kind: .runShellCommand,
            arguments: compactKernelArguments([
                "command": command,
                "workspace_root": workspaceRoot
            ]),
            request: request,
            onEvent: onEvent
        )
    }

    private func previewWorkspacePatch(
        patch: String,
        workspaceRoot: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "workspace.apply_patch_preview",
            arguments: compactKernelArguments([
                "patch": patch,
                "workspace_root": workspaceRoot
            ]),
            request: request
        )
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: result.status == .succeeded
                ? L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "我已经整理好这段 patch 的影响预览。",
                    en: "I prepared a patch impact preview."
                )
                : legacyCapabilityFailureMessage(
                    from: result,
                    fallback: L10n.text(
                        languageCode: request.responseLanguage,
                        zhHans: "预览 patch 失败。",
                        en: "Failed to preview the patch."
                    )
                ),
            data: capabilityBridgeData(from: result),
            cards: [],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : result.summary
        )
    }

    private func applyWorkspacePatch(
        patch: String,
        workspaceRoot: String?,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        await runWorkspaceMutationBridge(
            kind: .commitChanges,
            arguments: compactKernelArguments([
                "patch": patch,
                "workspace_root": workspaceRoot
            ]),
            request: request,
            onEvent: onEvent
        )
    }

    private func searchFiles(
        criteria: FileSearchCriteria,
        action: FileSearchAction,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskSessionResponse {
        onEvent(.status("operator", detail: searchStatusDetail(criteria: criteria, languageCode: request.uiLanguage)))
        let resolution = await resolveSnapshotViaKernel(
            criteria: criteria,
            request: request
        )
        let snapshot: AskDirectorySnapshot
        switch resolution {
        case .success(let resolvedSnapshot):
            snapshot = resolvedSnapshot
        case .failure(let failure):
            return sessionResponse(
                from: failure,
                request: request,
                successAction: "file_search",
                failureAction: "file_search_failed"
            )
        }
        let matches = snapshot.items.map { URL(fileURLWithPath: $0.path) }
        return await searchFilesResponse(matches: matches, criteria: criteria, action: action, request: request)
    }

    private func searchFilesResponse(
        matches: [URL],
        criteria: FileSearchCriteria,
        action: FileSearchAction,
        request: AskSessionRequest
    ) async -> AskSessionResponse {
        guard !matches.isEmpty else {
            return AskSessionResponse(
                message: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "没有找到匹配的文件。你可以再补充文件名关键词、扩展名，或者指定桌面 / 下载 / 文稿目录。",
                    en: "No matching files were found. You can add a filename keyword, an extension, or specify Desktop / Downloads / Documents."
                ),
                cards: [],
                metadata: [
                    "operator_handled": "true",
                    "operator_action": "file_search_empty",
                    "session_id": request.metadata.sessionID
                ]
            )
        }

        if action == .openSingle, let onlyMatch = matches.only {
            return await openPath(onlyMatch, request: request, onEvent: { _ in })
        }

        if action == .revealSingle, let onlyMatch = matches.only {
            return await revealPath(onlyMatch, request: request, onEvent: { _ in })
        }

        let title = summarizeSearchCriteria(criteria, responseLanguage: request.responseLanguage)
        let preview = matches.prefix(5)
        let cards = preview.map { url in
            makeCard(
                id: "file-match-\(url.path.hashValue)",
                title: url.lastPathComponent,
                subtitle: displayPath(url.deletingLastPathComponent()),
                description: nil,
                action: .revealInFinder,
                value: url.path
            )
        }

        let body = preview
            .map { "• \($0.lastPathComponent)  (\(displayPath($0.deletingLastPathComponent())))" }
            .joined(separator: "\n")

        return AskSessionResponse(
            message: L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "找到了 %d 个匹配项，先给你看最相关的几条：\n%@",
                en: "Found %d matching item(s). Here are the most relevant ones first:\n%@",
                matches.count,
                body
            ),
            cards: cards.isEmpty ? [
                makeCard(
                    id: "file-search-\(request.metadata.sessionID)",
                    title: title,
                    subtitle: nil,
                    description: nil,
                    action: nil,
                    value: nil
                )
            ] : cards,
            metadata: [
                "operator_handled": "true",
                "operator_action": "file_search",
                "operator_match_count": String(matches.count),
                "session_id": request.metadata.sessionID
            ]
        )
    }

    private func prepareMove(
        criteria: FileSearchCriteria,
        destinationDirectory: URL,
        createDestinationIfNeeded: Bool,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskSessionResponse {
        let resolution = await resolveSnapshotViaKernel(
            criteria: criteria,
            request: request
        )
        let snapshot: AskDirectorySnapshot
        switch resolution {
        case .success(let resolvedSnapshot):
            snapshot = resolvedSnapshot
        case .failure(let failure):
            return sessionResponse(
                from: failure,
                request: request,
                successAction: "move_prepare",
                failureAction: "move_prepare_failed"
            )
        }
        let selection = await createSelection(from: snapshot, paths: snapshot.items.map(\.path))
        onEvent(.status("operator", detail: movePreparationStatusDetail(criteria: criteria, destinationDirectory: destinationDirectory, languageCode: request.uiLanguage)))
        let staged = await stageMovePathsViaKernel(
            selectionID: selection.id,
            sourcePaths: [],
            destinationDirectory: destinationDirectory,
            createDestinationIfNeeded: createDestinationIfNeeded,
            request: request,
            onEvent: onEvent
        )
        guard staged.ok,
              let operationID = staged.data["operation_id"] as? String else {
            return AskSessionResponse(
                message: staged.summary,
                cards: staged.cards,
                metadata: [
                    "operator_handled": "true",
                    "operator_action": "move_prepare_failed",
                    "session_id": request.metadata.sessionID
                ]
            )
        }
        let committed = await commitStagedOperationViaKernel(
            operationID: operationID,
            request: request,
            onEvent: onEvent
        )
        return AskSessionResponse(
            message: committed.summary,
            cards: committed.cards,
            metadata: [
                "operator_handled": "true",
                "operator_action": "move_prepare",
                "operator_match_count": stringValue(from: committed.data["affected_count"]) ?? "0",
                "active_operation_id": operationID,
                "session_id": request.metadata.sessionID
            ]
        )
    }

    private func prepareDirectoryCleanup(
        criteria: FileSearchCriteria,
        destinationParentDirectory: URL,
        destinationFolderName: String,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        let destinationDirectory = destinationParentDirectory.appendingPathComponent(destinationFolderName, isDirectory: true)
        onEvent(
            .status(
                "operator",
                detail: cleanupPreparationStatusDetail(
                    criteria: criteria,
                    destinationDirectory: destinationDirectory,
                    languageCode: request.uiLanguage
                )
            )
        )

        let resolution = await resolveSnapshotViaKernel(
            criteria: criteria,
            request: request
        )
        let snapshot: AskDirectorySnapshot
        switch resolution {
        case .success(let resolvedSnapshot):
            snapshot = resolvedSnapshot
        case .failure(let failure):
            return failure
        }
        let selection = await createSelection(from: snapshot, paths: snapshot.items.map(\.path))
        let staged = await stageMovePathsViaKernel(
            selectionID: selection.id,
            sourcePaths: [],
            destinationDirectory: destinationDirectory,
            createDestinationIfNeeded: true,
            request: request,
            onEvent: onEvent
        )
        guard staged.ok,
              let operationID = staged.data["operation_id"] as? String else {
            return staged
        }
        let committed = await commitStagedOperationViaKernel(
            operationID: operationID,
            request: request,
            onEvent: onEvent
        )
        var data = committed.data
        data["source_directory"] = criteria.rootDirectories.first?.path ?? ""
        data["destination_folder_name"] = destinationFolderName
        data["snapshot_id"] = snapshot.id
        data["selection_id"] = selection.id
        data["match_count"] = intValue(from: committed.data["affected_count"]) ?? 0
        return AskToolExecutionResult(
            ok: committed.ok,
            summary: committed.summary,
            data: data,
            cards: committed.cards,
            approvalRequest: committed.approvalRequest,
            error: committed.error
        )
    }

    private func openPath(
        _ url: URL,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskSessionResponse {
        if let validationFailure = playgroundOpenValidationFailureResponseIfNeeded(
            for: url,
            request: request
        ) {
            return validationFailure
        }

        onEvent(
            .status(
                "operator",
                detail: L10n.format(
                    languageCode: request.uiLanguage,
                    zhHans: "正在打开“%@”…",
                    en: "Opening “%@”…",
                    url.lastPathComponent
                )
            )
        )

        let result = await executeLegacyKernelCapability(
            capabilityID: "desktop.open_path",
            arguments: ["path": url.path],
            request: request
        )

        let message = result.status == .succeeded
            ? L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "已打开“%@”。",
                en: "Opened “%@”.",
                url.lastPathComponent
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "打开路径失败。",
                    en: "Failed to open the requested path."
                )
            )

        return AskSessionResponse(
            message: message,
            cards: result.status == .succeeded ? [
                makeCard(
                    id: "path-open-\(url.path.hashValue)",
                    title: url.lastPathComponent,
                    subtitle: displayPath(url.deletingLastPathComponent()),
                    description: nil,
                    action: .revealInFinder,
                    value: url.path
                )
            ] : [],
            metadata: [
                "operator_handled": "true",
                "operator_action": result.status == .succeeded ? "open_path" : "open_path_failed",
                "session_id": request.metadata.sessionID
            ]
        )
    }

    private func revealPath(
        _ url: URL,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskSessionResponse {
        onEvent(
            .status(
                "operator",
                detail: L10n.format(
                    languageCode: request.uiLanguage,
                    zhHans: "正在在 Finder 中定位“%@”…",
                    en: "Revealing “%@” in Finder…",
                    url.lastPathComponent
                )
            )
        )

        let result = await executeLegacyKernelCapability(
            capabilityID: "desktop.reveal_in_finder",
            arguments: ["path": url.path],
            request: request
        )

        let message = result.status == .succeeded
            ? L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "已在 Finder 中显示“%@”。",
                en: "Revealed “%@” in Finder.",
                url.lastPathComponent
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "在 Finder 中定位路径失败。",
                    en: "Failed to reveal the requested path in Finder."
                )
            )

        return AskSessionResponse(
            message: message,
            cards: result.status == .succeeded ? [
                makeCard(
                    id: "path-reveal-\(url.path.hashValue)",
                    title: url.lastPathComponent,
                    subtitle: displayPath(url.deletingLastPathComponent()),
                    description: nil,
                    action: .revealInFinder,
                    value: url.path
                )
            ] : [],
            metadata: [
                "operator_handled": "true",
                "operator_action": result.status == .succeeded ? "reveal_path" : "reveal_path_failed",
                "session_id": request.metadata.sessionID
            ]
        )
    }

    private func openURLViaKernel(
        _ url: URL,
        preferredBrowserBundleID: String?,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(
            .status(
                "operator",
                detail: L10n.format(
                    languageCode: request.uiLanguage,
                    zhHans: "正在打开网页 %@…",
                    en: "Opening %@…",
                    url.host ?? url.absoluteString
                )
            )
        )

        let result = await executeLegacyKernelCapability(
            capabilityID: "browser.open_url",
            arguments: [
                "url": url.absoluteString,
                "preferred_browser_bundle_id": preferredBrowserBundleID ?? ""
            ],
            request: request
        )

        if result.status == .succeeded {
            await sessionStore.setRecentBrowserContext(
                .init(url: url, preferredBundleID: preferredBrowserBundleID, createdAt: Date()),
                for: request.metadata.sessionID
            )
        }

        let host = url.host ?? url.absoluteString
        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: result.status == .succeeded
                ? L10n.format(languageCode: request.responseLanguage, zhHans: "已打开 %@。", en: "Opened %@.", host)
                : legacyCapabilityFailureMessage(
                    from: result,
                    fallback: L10n.format(languageCode: request.responseLanguage, zhHans: "尝试打开 %@ 失败。", en: "Failed to open %@.", host)
                ),
            data: capabilityBridgeData(from: result),
            cards: [
                makeCard(
                    id: "url-open-\(url.absoluteString.hashValue)",
                    title: host,
                    subtitle: url.absoluteString,
                    description: nil,
                    action: .openURL,
                    value: url.absoluteString
                )
            ],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : result.summary
        )
    }

    private func searchWebViaKernel(
        query: String,
        preferredBrowserBundleID: String?,
        openInBrowser: Bool,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(
            .status(
                "operator",
                detail: L10n.format(
                    languageCode: request.uiLanguage,
                    zhHans: "正在搜索“%@”…",
                    en: "Searching for “%@”…",
                    query
                )
            )
        )

        let result = await executeLegacyKernelCapability(
            capabilityID: "browser.search_web",
            arguments: [
                "query": query,
                "preferred_browser_bundle_id": preferredBrowserBundleID ?? "",
                "open_in_browser": openInBrowser ? "true" : "false"
            ],
            request: request
        )

        let searchURL = result.metadata["search_url"] ?? ""
        if openInBrowser,
           result.status == .succeeded,
           let url = URL(string: searchURL),
           (result.metadata["opened_in_browser"] ?? "").lowercased() == "true" {
            await sessionStore.setRecentBrowserContext(
                .init(url: url, preferredBundleID: preferredBrowserBundleID, createdAt: Date()),
                for: request.metadata.sessionID
            )
        }

        let summary: String
        if result.status == .succeeded {
            summary = openInBrowser
                ? L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "已为你打开“%@”的搜索结果。",
                    en: "Opened search results for “%@”.",
                    query
                )
                : L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "我已准备好“%@”的搜索结果链接，但没有主动打开浏览器。",
                    en: "I prepared the search results link for “%@”, but did not open the browser.",
                    query
                )
        } else {
            summary = legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "这次没能准备好网页搜索结果。",
                    en: "I could not prepare the web search result this time."
                )
            )
        }

        let effectiveSearchURL = searchURL.isEmpty
            ? "https://www.google.com/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
            : searchURL

        var data = capabilityBridgeData(from: result)
        data["opened_in_browser"] = boolValue(from: data["opened_in_browser"]) ?? false
        data["open_in_browser"] = openInBrowser && ((data["opened_in_browser"] as? Bool) ?? false)

        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: summary,
            data: data,
            cards: [
                makeCard(
                    id: "web-search-\(query.hashValue)",
                    title: query,
                    subtitle: "Google",
                    description: openInBrowser
                        ? L10n.text(languageCode: request.responseLanguage, zhHans: "点击可重新打开搜索结果。", en: "Click to reopen the search results.")
                        : L10n.text(languageCode: request.responseLanguage, zhHans: "如果你想亲自查看，我可以继续帮你打开搜索结果。", en: "If you want to inspect it yourself, I can open these search results next."),
                    action: .openURL,
                    value: effectiveSearchURL
                )
            ],
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : result.summary
        )
    }

    private func webSearchResults(for query: String, limit: Int) async -> [SourceRecord] {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encodedQuery)") else {
            return []
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await urlSession.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else {
                return []
            }
            return TraceRuntimeSupport.searchResults(from: html, query: query, limit: limit)
        } catch {
            diagnosticsLogger.log("ask.web", "search_failed query=\(query) error=\(error.localizedDescription)")
            return []
        }
    }

    private func preferredWebResult(from results: [SourceRecord]) -> SourceRecord? {
        results.first(where: { $0.isOfficial == true }) ?? results.first
    }

    private struct ReadableURLPayload {
        let title: String
        let text: String
    }

    private func fetchReadableURL(_ url: URL) async -> Result<ReadableURLPayload, KnowledgeBaseCaptureFailure> {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await urlSession.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeRawData)
            }
            let title = extractedHTMLTitle(html) ?? url.host ?? url.absoluteString
            let text = cleanedHTMLText(html)
            guard !text.isEmpty else {
                return .failure(
                    KnowledgeBaseCaptureFailure(
                        kind: .noReadableContent,
                        message: L10n.text(zhHans: "页面里没有提取到稳定正文。", en: "No stable readable body text could be extracted from the page.")
                    )
                )
            }
            return .success(ReadableURLPayload(title: title, text: text))
        } catch {
            return .failure(
                KnowledgeBaseCaptureFailure(
                    kind: .networkFailed,
                    message: L10n.text(zhHans: "读取这个链接失败了。", en: "Failed to read this URL.")
                )
            )
        }
    }

    private func extractedHTMLTitle(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<title[^>]*>(.*?)</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return htmlUnescaped(String(html[range]))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanedHTMLText(_ html: String) -> String {
        let noScript = html
            .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
        let plain = noScript.replacingOccurrences(of: #"<[^>]+>"#, with: "\n", options: .regularExpression)
        return htmlUnescaped(plain)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func htmlUnescaped(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
              ) else {
            return text
        }
        return attributed.string
    }

    private func playgroundOpenValidationFailureResponseIfNeeded(
        for url: URL,
        request: AskSessionRequest
    ) -> AskSessionResponse? {
        guard AskPlaygroundStore.shared.isInsidePlayground(path: url.path),
              ["html", "htm"].contains(url.pathExtension.lowercased()) else {
            return nil
        }

        let issues = playgroundHTMLValidationIssues(for: url, responseLanguage: request.responseLanguage)
        guard !issues.isEmpty else { return nil }

        let joinedIssues = issues.prefix(3).joined(separator: AppLanguage.from(languageCode: request.responseLanguage) == .english ? "; " : "；")
        let message = L10n.format(
            languageCode: request.responseLanguage,
            zhHans: "我还没有打开“%@”，因为这个 Playground 页面还有一致性问题：%@。请先修好这些本地文件，再重新调用打开。",
            en: "I did not open “%@” yet because this Playground page still has consistency problems: %@. Please repair the local files first, then try opening it again.",
            url.lastPathComponent,
            joinedIssues
        )

        return AskSessionResponse(
            message: message,
            cards: [],
            metadata: [
                "operator_handled": "true",
                "operator_action": "open_path_failed",
                "open_path_validation_failed": "true",
                "session_id": request.metadata.sessionID
            ]
        )
    }

    private func playgroundHTMLValidationIssues(
        for entryURL: URL,
        responseLanguage: String
    ) -> [String] {
        guard let html = try? String(contentsOf: entryURL, encoding: .utf8) else {
            return [
                L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "无法读取 %@",
                    en: "Could not read %@",
                    entryURL.lastPathComponent
                )
            ]
        }

        let baseDirectory = entryURL.deletingLastPathComponent()
        var styles = inlineBlocks(in: html, pattern: #"<style[^>]*>([\s\S]*?)</style>"#)
        var scripts = inlineBlocks(in: html, pattern: #"<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)</script>"#)
        var issues: [String] = []

        for reference in localHTMLAssetReferences(in: html) {
            let assetURL = baseDirectory.appendingPathComponent(reference).standardizedFileURL
            guard FileManager.default.fileExists(atPath: assetURL.path) else {
                issues.append(
                    L10n.format(
                        languageCode: responseLanguage,
                        zhHans: "缺少本地资源 %@",
                        en: "Missing local asset %@",
                        reference
                    )
                )
                continue
            }
            switch assetURL.pathExtension.lowercased() {
            case "css":
                if let text = try? String(contentsOf: assetURL, encoding: .utf8) {
                    styles.append(text)
                }
            case "js":
                if let text = try? String(contentsOf: assetURL, encoding: .utf8) {
                    scripts.append(text)
                }
            default:
                break
            }
        }

        let combinedText = ([html] + styles + scripts)
            .map(playgroundContentRemovingDataURIs)
            .joined(separator: "\n")
        if combinedText.range(of: #"https?://"#, options: .regularExpression) != nil {
            issues.append(
                L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "仍然依赖远程 URL / CDN 资源",
                    en: "Still depends on remote URLs or CDN assets"
                )
            )
        }

        let htmlClasses = htmlClassNames(in: html)
        let htmlIDs = htmlIDs(in: html)
        let htmlDataHooks = htmlDataHooks(in: html)
        for script in scripts {
            for selector in scriptClassSelectors(in: script) where !htmlClasses.contains(selector) {
                issues.append(
                    L10n.format(
                        languageCode: responseLanguage,
                        zhHans: "JS 还在查找缺失的 class .%@",
                        en: "JS still references a missing class .%@",
                        selector
                    )
                )
            }
            for elementID in scriptIDReferences(in: script) where !htmlIDs.contains(elementID) {
                issues.append(
                    L10n.format(
                        languageCode: responseLanguage,
                        zhHans: "JS 还在查找缺失的 id #%@",
                        en: "JS still references a missing id #%@",
                        elementID
                    )
                )
            }
            for hook in scriptDataHookReferences(in: script) where !htmlDataHooks.contains(hook) {
                issues.append(
                    L10n.format(
                        languageCode: responseLanguage,
                        zhHans: "JS 还在查找缺失的 data 挂点 [%@]",
                        en: "JS still references a missing data hook [%@]",
                        hook
                    )
                )
            }
        }

        if !styles.isEmpty {
            let cssClasses = cssClassNames(in: styles)
            let unmatchedClasses = htmlClasses
                .filter { className in
                    !cssClasses.contains(className)
                        && !className.hasPrefix("js-")
                        && !className.hasPrefix("is-")
                        && !className.hasPrefix("has-")
                }
                .sorted()
            if unmatchedClasses.count >= 3 {
                issues.append(
                    L10n.format(
                        languageCode: responseLanguage,
                        zhHans: "HTML 里有未匹配的布局 class：%@",
                        en: "HTML still has layout classes with no matching CSS rule: %@",
                        unmatchedClasses.prefix(4).joined(separator: ", ")
                    )
                )
            }
        }

        return Array(NSOrderedSet(array: issues)) as? [String] ?? issues
    }

    private func inlineBlocks(in text: String, pattern: String) -> [String] {
        capturedGroups(in: text, pattern: pattern, options: [.caseInsensitive])
    }

    private func localHTMLAssetReferences(in html: String) -> [String] {
        capturedGroups(
            in: html,
            pattern: #"(?:href|src)\s*=\s*["']([^"'#][^"']*)["']"#,
            options: [.caseInsensitive]
        )
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { reference in
            let lowercased = reference.lowercased()
            return !reference.isEmpty
                && !lowercased.hasPrefix("http://")
                && !lowercased.hasPrefix("https://")
                && !lowercased.hasPrefix("data:")
                && !lowercased.hasPrefix("mailto:")
                && !lowercased.hasPrefix("javascript:")
        }
    }

    private func htmlClassNames(in html: String) -> Set<String> {
        Set(
            capturedGroups(in: html, pattern: #"class\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive])
                .flatMap { value in
                    value
                        .split(whereSeparator: \.isWhitespace)
                        .map(String.init)
                }
        )
    }

    private func htmlIDs(in html: String) -> Set<String> {
        Set(capturedGroups(in: html, pattern: #"id\s*=\s*["']([A-Za-z0-9_-]+)["']"#, options: [.caseInsensitive]))
    }

    private func htmlDataHooks(in html: String) -> Set<String> {
        Set(capturedGroups(in: html, pattern: #"\b(data-[A-Za-z0-9_-]+)\s*="#, options: [.caseInsensitive]))
    }

    private func cssClassNames(in styles: [String]) -> Set<String> {
        Set(styles.flatMap { capturedGroups(in: $0, pattern: #"\.([A-Za-z_][A-Za-z0-9_-]*)"#) })
    }

    private func scriptClassSelectors(in script: String) -> Set<String> {
        Set(capturedGroups(in: script, pattern: #"querySelector(?:All)?\(\s*['"]\.([A-Za-z0-9_-]+)['"]\s*\)"#))
    }

    private func scriptIDReferences(in script: String) -> Set<String> {
        let selectors = capturedGroups(in: script, pattern: #"querySelector(?:All)?\(\s*['"]#([A-Za-z0-9_-]+)['"]\s*\)"#)
        let byID = capturedGroups(in: script, pattern: #"getElementById\(\s*['"]([A-Za-z0-9_-]+)['"]\s*\)"#)
        return Set(selectors + byID)
    }

    private func scriptDataHookReferences(in script: String) -> Set<String> {
        Set(capturedGroups(in: script, pattern: #"querySelector(?:All)?\(\s*['"]\[(data-[A-Za-z0-9_-]+)\]['"]\s*\)"#))
    }

    private func playgroundContentRemovingDataURIs(_ text: String) -> String {
        text.replacingOccurrences(of: #"data:[^"']+"#, with: "", options: .regularExpression)
    }

    private func capturedGroups(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let groupRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[groupRange])
        }
    }

    private func knowledgeCards(
        for entries: [ReplyKnowledgeBaseEntry],
        languageCode: String
    ) -> [SkillResultCard] {
        entries.prefix(4).enumerated().map { index, entry in
            let action = KnowledgeBaseSourceActionResolver.primaryAction(for: entry, languageCode: languageCode)
            return SkillResultCard(
                id: "kb-entry-\(entry.id)-\(index)",
                kind: "knowledge_base_source",
                title: entry.title,
                badges: nil,
                subtitle: entry.summary,
                description: entry.preview,
                action: action.map(KnowledgeBaseSourceActionResolver.skillResultAction),
                priority: index == 0 ? .primary : .secondary,
                isOfficial: nil
            )
        }
    }

    private func detectedLinks(in text: String, currentURL: URL) -> [URL] {
        var links: [URL] = [currentURL]
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            let detected = detector.matches(in: text, options: [], range: range).compactMap(\.url)
            links.append(contentsOf: detected)
        }
        return uniqueURLs(links)
    }

    private func allowsExplicitClipboardWrite(for request: AskSessionRequest) -> Bool {
        guard let latestUserMessage = request.messages.last(where: { $0.role == .user })?.content else {
            return false
        }
        let normalized = normalize(latestUserMessage)
        return containsAny(normalized, in: ["复制", "拷贝", "copy", "clipboard", "copy it"])
    }

    private func allowsExplicitWriteback(for request: AskSessionRequest) -> Bool {
        guard let latestUserMessage = request.messages.last(where: { $0.role == .user })?.content else {
            return false
        }
        let normalized = normalize(latestUserMessage)
        return containsAny(normalized, in: ["写回", "填回", "粘贴", "paste", "write back", "insert this"])
    }

    private func allowsExplicitReplacement(for request: AskSessionRequest) -> Bool {
        guard let latestUserMessage = request.messages.last(where: { $0.role == .user })?.content else {
            return false
        }
        let normalized = normalize(latestUserMessage)
        return containsAny(normalized, in: ["替换", "replace", "replace selection", "改成"])
    }

    private func latestBrowserContext(for request: AskSessionRequest) async -> AskOperatorSessionStore.BrowserContext? {
        await sessionStore.recentBrowserContext(for: request.metadata.sessionID)
    }

    private func formattedAutomationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppSettings.shared.appLanguage.localeIdentifier)
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("M d HH:mm")
        return formatter.string(from: date)
    }

    private func allowsVisibleBrowserAction(for request: AskSessionRequest) -> Bool {
        guard let latestUserMessage = request.messages.last(where: { $0.role == .user })?.content else {
            return false
        }
        let normalized = normalize(latestUserMessage)
        let englishPatterns = [
            #"\bopen\b"#,
            #"\bvisit\b"#,
            #"\bgo to\b"#,
            #"\bbrowse\b"#,
            #"\bsearch\b"#,
            #"\bsearch for\b"#,
            #"\blook up\b"#,
            #"\bgoogle\b"#,
            #"\bshow me the page\b"#,
            #"\bsearch in (?:the )?browser\b"#,
            #"\bopen (?:the )?(?:page|url|site|browser)\b"#
        ]
        if englishPatterns.contains(where: { normalized.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }
        return containsAny(
            normalized,
            in: [
                "打开", "访问", "去官网", "去网页", "打开网页", "打开页面", "浏览器里搜索", "给我打开", "去看",
                "搜索", "搜一下", "搜一搜", "去搜索", "去搜", "查一下", "查一查", "帮我查", "帮我搜"
            ]
        )
    }

    private func allowsCurrentPageRead(for request: AskSessionRequest) async -> Bool {
        guard let latestUserMessage = request.messages.last(where: { $0.role == .user })?.content else {
            return false
        }
        let normalized = normalize(latestUserMessage)
        if referencesCurrentPage(normalized) {
            return true
        }
        return await latestBrowserContext(for: request) != nil
    }

    private func browserBundleIDForPageRead(request: AskSessionRequest) async -> String? {
        if let recentContext = await latestBrowserContext(for: request) {
            if let preferredBundleID = recentContext.preferredBundleID,
               AskOperatorSupportedBrowser.bundleIDs.contains(preferredBundleID) {
                return preferredBundleID
            }
            return nil
        }
        return request.metadata.sourceBundleID
    }

    private func browserActionRequiresExplicitIntentResult(
        toolName: String,
        request: AskSessionRequest,
        data: [String: Any]
    ) -> AskToolExecutionResult {
        AskToolExecutionResult(
            ok: false,
            summary: L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "我没有替你打开浏览器，因为你这句话里没有明确要求可见的网页打开动作。",
                en: "I did not open the browser because the user did not explicitly ask for a visible page-opening action."
            ),
            data: data.merging([
                "visible_browser_action_blocked": true,
                "tool_name": toolName
            ]) { _, newValue in newValue },
            cards: [],
            approvalRequest: nil,
            error: nil
        )
    }

    private func currentPageReadRequiresExplicitReferenceResult(
        request: AskSessionRequest,
        query: String?
    ) -> AskToolExecutionResult {
        AskToolExecutionResult(
            ok: false,
            summary: L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "我没有读取当前网页，因为用户这句话没有明确提到当前页面或标签页。",
                en: "I did not read the current page because the user did not explicitly refer to the current page or tab."
            ),
            data: [
                "query": query ?? "",
                "current_page_read_blocked": true
            ],
            cards: [],
            approvalRequest: nil,
            error: nil
        )
    }

    private func executeCurrentPageReadCapability(
        query: String?,
        request: AskSessionRequest,
        onEvent: (@Sendable (AskSessionStreamEvent) -> Void)? = nil
    ) async -> CurrentPageCapabilityPayload {
        if let onEvent {
            let detail = if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                L10n.format(
                    languageCode: request.uiLanguage,
                    zhHans: "正在读取当前网页并查找“%@”…",
                    en: "Reading the current page and looking for “%@”…",
                    query
                )
            } else {
                L10n.text(languageCode: request.uiLanguage, zhHans: "正在读取当前网页…", en: "Reading the current page…")
            }
            onEvent(.status("operator", detail: detail))
        }

        let result = await executeLegacyKernelCapability(
            capabilityID: "browser.read_current_page",
            arguments: [
                "query": query ?? "",
                "source_bundle_id": await browserBundleIDForPageRead(request: request) ?? ""
            ],
            request: request
        )

        let pageURL = result.metadata["page_url"] ?? result.metadata["current_page_url"] ?? ""
        let pageTitle = result.metadata["page_title"] ?? result.metadata["current_page_title"] ?? ""
        let pageCard: [SkillResultCard] = {
            guard !pageURL.isEmpty else { return [] }
            return [
                makeCard(
                    id: "page-\(pageURL.hashValue)",
                    title: pageTitle.isEmpty ? pageURL : pageTitle,
                    subtitle: URL(string: pageURL)?.host ?? pageURL,
                    description: query == nil
                        ? L10n.text(languageCode: request.responseLanguage, zhHans: "点击可重新打开当前网页。", en: "Click to reopen the current webpage.")
                        : L10n.format(languageCode: request.responseLanguage, zhHans: "当前页内关于“%@”的匹配内容。", en: "Matches from the current page about “%@”.", query ?? ""),
                    action: .openURL,
                    value: pageURL
                )
            ]
        }()

        return CurrentPageCapabilityPayload(
            result: result,
            pageURL: pageURL,
            pageTitle: pageTitle,
            pageCard: pageCard
        )
    }

    private func readCurrentPageViaKernel(
        query: String?,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        let capability = await executeCurrentPageReadCapability(
            query: query,
            request: request,
            onEvent: onEvent
        )
        let result = capability.result
        let pageURL = capability.pageURL
        let pageTitle = capability.pageTitle
        let pageCard = capability.pageCard

        if result.status != .succeeded {
            let message = legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "读取当前网页失败。",
                    en: "Failed to read the current page."
                )
            )
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: capabilityBridgeData(from: result),
                cards: pageCard,
                approvalRequest: nil,
                error: message
            )
        }

        if let query, !query.isEmpty {
            let matches = capabilityArtifactValue(kind: "page_matches", from: result)
            let message = matches?.isEmpty == false
                ? L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "当前网页“%@”里和“%@”最相关的内容是：\n%@",
                    en: "On the current page “%@”, the most relevant content for “%@” is:\n%@",
                    pageTitle.isEmpty ? (URL(string: pageURL)?.host ?? pageURL) : pageTitle,
                    query,
                    matches ?? ""
                )
                : L10n.format(
                    languageCode: request.responseLanguage,
                    zhHans: "当前网页是“%@”，但我还没在可见正文里找到和“%@”直接相关的内容。",
                    en: "The current page is “%@”, but I could not find visible body text directly related to “%@”.",
                    pageTitle.isEmpty ? (URL(string: pageURL)?.host ?? pageURL) : pageTitle,
                    query
                )
            return AskToolExecutionResult(
                ok: true,
                summary: message,
                data: capabilityBridgeData(from: result),
                cards: pageCard,
                approvalRequest: nil,
                error: nil
            )
        }

        let snippet = capabilityArtifactValue(kind: "page_summary", from: result) ?? ""
        let message = L10n.format(
            languageCode: request.responseLanguage,
            zhHans: "当前网页是“%@”。\n%@",
            en: "The current page is “%@”.\n%@",
            pageTitle.isEmpty ? (URL(string: pageURL)?.host ?? pageURL) : pageTitle,
            snippet
        )
        return AskToolExecutionResult(
            ok: true,
            summary: message,
            data: capabilityBridgeData(from: result),
            cards: pageCard,
            approvalRequest: nil,
            error: nil
        )
    }

    private func resolveCurrentPageViaKernel(
        request: AskSessionRequest
    ) async -> KernelCurrentPageResolution {
        let capability = await executeCurrentPageReadCapability(
            query: nil,
            request: request
        )
        let result = capability.result

        guard result.status == .succeeded else {
            let message = legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "读取当前网页失败。",
                    en: "Failed to read the current page."
                )
            )
            return .failure(
                AskToolExecutionResult(
                    ok: false,
                    summary: message,
                    data: capabilityBridgeData(from: result),
                    cards: [],
                    approvalRequest: nil,
                    error: message
                )
            )
        }

        guard let pageURL = nonEmptyString(result.metadata["page_url"]),
              let url = URL(string: pageURL) else {
            let message = L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "当前网页缺少可用的地址信息。",
                en: "The current page did not provide a usable URL."
            )
            return .failure(
                AskToolExecutionResult(
                    ok: false,
                    summary: message,
                    data: capabilityBridgeData(from: result),
                    cards: [],
                    approvalRequest: nil,
                    error: message
                )
            )
        }

        guard let pageText = capabilityArtifactValue(kind: "page_text", from: result),
              !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let message = L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "当前网页正文暂时不可用。",
                en: "The current page text is not available right now."
            )
            return .failure(
                AskToolExecutionResult(
                    ok: false,
                    summary: message,
                    data: capabilityBridgeData(from: result),
                    cards: [],
                    approvalRequest: nil,
                    error: message
                )
            )
        }

        return .success(
            KernelCurrentPagePayload(
                url: url,
                title: nonEmptyString(result.metadata["page_title"]) ?? (url.host ?? url.absoluteString),
                text: pageText
            )
        )
    }

    private func extractCurrentPageSummary(
        query: String?,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        let result = await readCurrentPageViaKernel(
            query: query,
            request: request,
            onEvent: onEvent
        )
        var data = result.data
        data["query"] = query ?? ""
        data["page_summary"] = result.summary
        return AskToolExecutionResult(
            ok: result.ok,
            summary: result.summary,
            data: data,
            cards: result.cards,
            approvalRequest: result.approvalRequest,
            error: result.error
        )
    }

    private func extractCurrentPageLinks(
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(.status("operator", detail: L10n.text(languageCode: request.uiLanguage, zhHans: "正在整理当前页里的可见链接…", en: "Extracting visible links from the current page…")))
        let resolution = await resolveCurrentPageViaKernel(request: request)
        switch resolution {
        case .failure(let failure):
            return failure
        case .success(let page):
            let links = detectedLinks(in: page.text, currentURL: page.url)
            let cards = links.prefix(4).enumerated().map { index, link in
                makeCard(
                    id: "page-link-\(index)-\(link.absoluteString.hashValue)",
                    title: link.host ?? link.absoluteString,
                    subtitle: link.absoluteString,
                    description: L10n.text(languageCode: request.responseLanguage, zhHans: "来自当前页面的链接候选", en: "Link candidate detected from the current page"),
                    action: .openURL,
                    value: link.absoluteString
                )
            }
            let summary = links.isEmpty
                ? L10n.text(languageCode: request.responseLanguage, zhHans: "我暂时没有在当前页面正文里提取到可见链接。", en: "I could not extract visible links from the current page text right now.")
                : L10n.format(languageCode: request.responseLanguage, zhHans: "当前页面里提取到了 %d 个链接候选。", en: "Extracted %d link candidate(s) from the current page.", links.count)
            return AskToolExecutionResult(
                ok: !links.isEmpty,
                summary: summary,
                data: [
                    "links": links.map(\.absoluteString),
                    "page_url": page.url.absoluteString,
                    "page_title": page.title
                ],
                cards: cards,
                approvalRequest: nil,
                error: links.isEmpty ? summary : nil
            )
        }
    }

    private func captureBestWebResult(
        query: String,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(.status("operator", detail: L10n.format(languageCode: request.uiLanguage, zhHans: "正在为“%@”找最值得继续跟进的网页结果…", en: "Finding the best web result to continue from for “%@”…", query)))
        let results = await webSearchResults(for: query, limit: 6)
        guard let best = preferredWebResult(from: results) ?? results.first else {
            let message = L10n.text(languageCode: request.responseLanguage, zhHans: "这次没有拿到稳定的网页候选结果。", en: "No stable web result could be captured for this query.")
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: ["query": query],
                cards: [],
                approvalRequest: nil,
                error: message
            )
        }

        let card = SkillResultCard(
            id: "web-best-\(best.url.hashValue)",
            kind: "web_result",
            title: best.title,
            badges: best.isOfficial == true ? [L10n.text(zhHans: "官方", en: "Official")] : nil,
            subtitle: best.url,
            description: best.snippet,
            action: SkillResultAction(type: .openURL, label: actionLabel(for: .openURL), value: best.url),
            priority: .primary,
            isOfficial: best.isOfficial
        )

        let message = L10n.format(
            languageCode: request.responseLanguage,
            zhHans: "我先为“%@”锁定了一个最值得继续跟进的网页结果：%@。",
            en: "I picked one best web result to continue from for “%@”: %@.",
            query,
            best.title
        )
        return AskToolExecutionResult(
            ok: true,
            summary: message,
            data: [
                "query": query,
                "best_result_title": best.title,
                "best_result_url": best.url,
                "best_result_snippet": best.snippet
            ],
            cards: [card],
            approvalRequest: nil,
            error: nil
        )
    }

    private func searchKnowledge(query: String, request: AskSessionRequest) -> AskToolExecutionResult {
        let matches = knowledgeBaseStore.searchEntries(query: query, limit: 4)
        let cards = matches.enumerated().map { index, match in
            let action = KnowledgeBaseSourceActionResolver.primaryAction(for: match.entry, languageCode: request.uiLanguage)
            return SkillResultCard(
                id: "kb-search-\(match.entry.id)-\(index)",
                kind: "knowledge_base_source",
                title: match.entry.title,
                badges: match.matchedFacets.isEmpty ? nil : match.matchedFacets,
                subtitle: match.reason,
                description: match.matchedChunk?.preview ?? match.entry.preview,
                action: action.map(KnowledgeBaseSourceActionResolver.skillResultAction),
                priority: index == 0 ? .primary : .secondary,
                isOfficial: nil
            )
        }
        let summary = matches.isEmpty
            ? L10n.format(languageCode: request.responseLanguage, zhHans: "知识库里暂时没有命中“%@”。", en: "The knowledge base has no match for “%@” right now.", query)
            : L10n.format(languageCode: request.responseLanguage, zhHans: "我在知识库里为“%@”找到了 %d 个可继续引用的来源。", en: "I found %2$d knowledge-base source(s) to continue from for “%1$@”.", query, matches.count)
        return AskToolExecutionResult(
            ok: !matches.isEmpty,
            summary: summary,
            data: [
                "query": query,
                "match_count": matches.count,
                "entry_ids": matches.map(\.entry.id)
            ],
            cards: cards,
            approvalRequest: nil,
            error: matches.isEmpty ? summary : nil
        )
    }

    private func collectURL(
        _ url: URL,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(.status("operator", detail: L10n.format(languageCode: request.uiLanguage, zhHans: "正在把 %@ 采集进知识库…", en: "Collecting %@ into the knowledge base…", url.host ?? url.absoluteString)))
        let fetched = await fetchReadableURL(url)
        switch fetched {
        case .failure(let error):
            return AskToolExecutionResult(
                ok: false,
                summary: error.message,
                data: ["url": url.absoluteString],
                cards: [],
                approvalRequest: nil,
                error: error.message
            )
        case .success(let payload):
            let result = await knowledgeBaseStore.collectURL(
                url,
                title: payload.title,
                text: payload.text,
                summaryOverride: nil,
                capturePipeline: ["ask_collect", "http_fetch", "chunk"]
            )
            let entries = result.inserted + result.updated
            let cards = knowledgeCards(for: entries, languageCode: request.uiLanguage)
            let summary = entries.isEmpty
                ? L10n.text(languageCode: request.responseLanguage, zhHans: "链接没有成功写入知识库。", en: "The link was not written into the knowledge base.")
                : L10n.format(languageCode: request.responseLanguage, zhHans: "已把 %@ 采集进知识库。", en: "Collected %@ into the knowledge base.", payload.title)
            return AskToolExecutionResult(
                ok: !entries.isEmpty,
                summary: summary,
                data: [
                    "url": url.absoluteString,
                    "entry_ids": entries.map(\.id)
                ],
                cards: cards,
                approvalRequest: nil,
                error: entries.isEmpty ? summary : nil
            )
        }
    }

    private func collectCurrentPage(
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(.status("operator", detail: L10n.text(languageCode: request.uiLanguage, zhHans: "正在把当前页面采集进知识库…", en: "Collecting the current page into the knowledge base…")))
        let resolution = await resolveCurrentPageViaKernel(request: request)
        switch resolution {
        case .failure(let failure):
            return failure
        case .success(let page):
            let result = await knowledgeBaseStore.collectURL(
                page.url,
                title: page.title,
                text: page.text,
                summaryOverride: nil,
                capturePipeline: ["ask_collect", "browser_capture", "chunk", "kernel_page_context"]
            )
            let entries = result.inserted + result.updated
            let summary = entries.isEmpty
                ? L10n.text(languageCode: request.responseLanguage, zhHans: "当前页面没有成功写入知识库。", en: "The current page was not written into the knowledge base.")
                : L10n.format(languageCode: request.responseLanguage, zhHans: "已把当前页面“%@”采集进知识库。", en: "Collected the current page “%@” into the knowledge base.", page.title)
            return AskToolExecutionResult(
                ok: !entries.isEmpty,
                summary: summary,
                data: [
                    "page_url": page.url.absoluteString,
                    "entry_ids": entries.map(\.id)
                ],
                cards: knowledgeCards(for: entries, languageCode: request.uiLanguage),
                approvalRequest: nil,
                error: entries.isEmpty ? summary : nil
            )
        }
    }

    private func collectPaths(_ rawPaths: [String], request: AskSessionRequest) async -> AskToolExecutionResult {
        let urls = rawPaths.compactMap { resolvedPathURL(from: $0) }
        guard !urls.isEmpty else {
            return invalidArgumentsResult(for: "collect_paths", responseLanguage: request.responseLanguage)
        }
        let result = await knowledgeBaseStore.upsertFiles(urls: urls)
        let entries = result.inserted + result.updated
        let summary = entries.isEmpty
            ? L10n.text(languageCode: request.responseLanguage, zhHans: "这些路径暂时没有成功写入知识库。", en: "Those paths were not written into the knowledge base.")
            : L10n.format(languageCode: request.responseLanguage, zhHans: "已把 %d 个文件采集进知识库。", en: "Collected %d file(s) into the knowledge base.", entries.count)
        return AskToolExecutionResult(
            ok: !entries.isEmpty,
            summary: summary,
            data: [
                "paths": urls.map(\.path),
                "entry_ids": entries.map(\.id)
            ],
            cards: knowledgeCards(for: entries, languageCode: request.uiLanguage),
            approvalRequest: nil,
            error: entries.isEmpty ? summary : nil
        )
    }

    private func saveAnswerToKnowledgeNote(
        content: String,
        title: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await knowledgeBaseStore.collectSelectedText(content, title: title)
        let entries = result.inserted + result.updated
        let summary = entries.isEmpty
            ? L10n.text(languageCode: request.responseLanguage, zhHans: "这段内容暂时没有保存进知识库。", en: "This content was not saved into the knowledge base.")
            : L10n.text(languageCode: request.responseLanguage, zhHans: "已把这段内容保存成知识库 note。", en: "Saved this content as a knowledge-base note.")
        return AskToolExecutionResult(
            ok: !entries.isEmpty,
            summary: summary,
            data: [
                "entry_ids": entries.map(\.id)
            ],
            cards: knowledgeCards(for: entries, languageCode: request.uiLanguage),
            approvalRequest: nil,
            error: entries.isEmpty ? summary : nil
        )
    }

    private func promotePlaygroundArtifact(
        artifactID: String,
        toolName: String?,
        request: AskSessionRequest
    ) -> AskToolExecutionResult {
        guard let descriptor = AskPlaygroundStore.shared.promoteArtifact(
            artifactID: artifactID,
            preferredToolID: toolName
        ) else {
            let message = L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "没有找到这个 Playground 资产，所以暂时没法把它提升成本地工具。",
                en: "That Playground asset could not be found, so it could not be promoted into a local tool."
            )
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: ["artifact_id": artifactID],
                cards: [],
                approvalRequest: nil,
                error: message
            )
        }

        let summary = L10n.format(
            languageCode: request.responseLanguage,
            zhHans: "已把 Playground 资产提升成本地工具：%@。",
            en: "Promoted the Playground asset into a local tool: %@.",
            descriptor.id
        )
        return AskToolExecutionResult(
            ok: true,
            summary: summary,
            data: [
                "artifact_id": artifactID,
                "tool_id": descriptor.id,
                "entry_file": descriptor.entryFile,
                "root_path": descriptor.rootPath
            ],
            cards: [],
            approvalRequest: nil,
            error: nil
        )
    }

    private func runPromotedLocalTool(
        descriptor: AskLocalPromotedToolDescriptor,
        arguments: [String: Any],
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        let rootURL = URL(fileURLWithPath: descriptor.rootPath, isDirectory: true)
        let entryURL = rootURL.appendingPathComponent(descriptor.entryFile)
        guard fileManager.fileExists(atPath: entryURL.path) else {
            let message = L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "这个本地工具对应的 Playground 文件已经不存在了。",
                en: "The Playground file behind this local tool no longer exists."
            )
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: ["tool_id": descriptor.id, "entry_file": entryURL.path],
                cards: [],
                approvalRequest: nil,
                error: message
            )
        }

        let input = nonEmptyString(arguments["input"])
        let openResult = arguments["open_result"] as? Bool ?? false
        if descriptor.languageRuntime == "html" {
            let didOpen = openResult ? await workspaceController.openFile(entryURL) : false
            if let artifact = AskPlaygroundStore.shared.artifact(forPromotedToolID: descriptor.id) {
                AskPlaygroundStore.shared.markArtifactUsed(id: artifact.id)
            }
            let summary = didOpen
                ? L10n.text(languageCode: request.responseLanguage, zhHans: "已运行并打开这个本地 HTML 工具。", en: "Ran and opened the local HTML tool.")
                : L10n.text(languageCode: request.responseLanguage, zhHans: "这个本地 HTML 工具已经可用。需要时可以再打开它。", en: "The local HTML tool is available and can be opened when needed.")
            return AskToolExecutionResult(
                ok: true,
                summary: summary,
                data: [
                    "tool_id": descriptor.id,
                    "entry_file": entryURL.path,
                    "opened": didOpen
                ],
                cards: [],
                approvalRequest: nil,
                error: nil
            )
        }

        guard let invocation = localToolInvocation(
            descriptor: descriptor,
            entryURL: entryURL,
            input: input
        ) else {
            let message = L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "这个本地工具的运行时目前还不受支持。",
                en: "This promoted local tool uses a runtime that is not supported yet."
            )
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: [
                    "tool_id": descriptor.id,
                    "entry_file": entryURL.path,
                    "language_runtime": descriptor.languageRuntime
                ],
                cards: [],
                approvalRequest: nil,
                error: message
            )
        }

        onEvent(.status("operator", detail: L10n.text(
            languageCode: request.uiLanguage,
            zhHans: "正在运行已提升的本地工具…",
            en: "Running the promoted local tool…"
        )))
        let processResult = await runLocalProcess(
            executablePath: invocation.executablePath,
            arguments: invocation.arguments,
            environment: invocation.environment,
            currentDirectoryURL: rootURL
        )
        if let artifact = AskPlaygroundStore.shared.artifact(forPromotedToolID: descriptor.id) {
            AskPlaygroundStore.shared.markArtifactUsed(id: artifact.id)
        }
        if openResult {
            await workspaceController.revealInFinder(rootURL)
        }

        let output = [processResult.standardOutput, processResult.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: processResult.standardError.isEmpty ? "" : "\n")
        let truncatedOutput = String(output.prefix(1200))
        let summary: String
        if processResult.exitCode == 0 {
            summary = truncatedOutput.isEmpty
                ? L10n.text(languageCode: request.responseLanguage, zhHans: "已运行本地工具。", en: "Ran the local tool.")
                : L10n.text(languageCode: request.responseLanguage, zhHans: "已运行本地工具，并拿到了输出。", en: "Ran the local tool and captured output.")
        } else {
            summary = L10n.text(languageCode: request.responseLanguage, zhHans: "运行这个本地工具失败了。", en: "Running this local tool failed.")
        }
        return AskToolExecutionResult(
            ok: processResult.exitCode == 0,
            summary: summary,
            data: [
                "tool_id": descriptor.id,
                "entry_file": entryURL.path,
                "exit_code": processResult.exitCode,
                "output": truncatedOutput
            ],
            cards: [],
            approvalRequest: nil,
            error: processResult.exitCode == 0 ? nil : (truncatedOutput.isEmpty ? summary : truncatedOutput)
        )
    }

    private func runWorkspaceMutationBridge(
        kind: WorkspaceMutationBridgeKind,
        arguments: AskInvocationMetadata,
        request: AskSessionRequest,
        onEvent: @escaping @Sendable (AskSessionStreamEvent) -> Void
    ) async -> AskToolExecutionResult {
        onEvent(.status("operator", detail: kind.preparingStatus(languageCode: request.uiLanguage)))
        let result = await executeLegacyKernelCapability(
            capabilityID: kind.capabilityID,
            arguments: arguments,
            request: request
        )
        return await workspaceMutationBridgeResult(
            kind: kind,
            result: result,
            request: request
        )
    }

    private func workspaceMutationBridgeResult(
        kind: WorkspaceMutationBridgeKind,
        result: AskCapabilityExecutionResult,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        if result.status == .waitingApproval {
            let approvalRequest = await approvalRequestForKernelResult(
                result,
                request: request
            )
            let summary = approvalRequest?.message ?? kind.waitingApprovalSummary(responseLanguage: request.responseLanguage)
            return AskToolExecutionResult(
                ok: true,
                summary: summary,
                data: capabilityBridgeData(from: result),
                cards: approvalRequest?.cards ?? [],
                approvalRequest: approvalRequest,
                error: nil
            )
        }

        let message = result.status == .succeeded
            ? localizedCapabilitySuccessSummary(
                capabilityID: kind.capabilityID,
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            )
            : legacyCapabilityFailureMessage(
                from: result,
                fallback: kind.failureFallback(responseLanguage: request.responseLanguage)
            )

        return AskToolExecutionResult(
            ok: result.status == .succeeded,
            summary: message,
            data: capabilityBridgeData(from: result),
            cards: capabilityFollowupCards(
                for: kind.capabilityID,
                metadata: result.metadata,
                responseLanguage: request.responseLanguage
            ),
            approvalRequest: nil,
            error: result.status == .succeeded ? nil : message
        )
    }

    private func copyToClipboard(text: String, request: AskSessionRequest) async -> AskToolExecutionResult {
        await runAppWritebackBridge(
            kind: .clipboard,
            text: text,
            request: request
        )
    }

    private func writeBackToFrontmostInput(text: String, request: AskSessionRequest) async -> AskToolExecutionResult {
        await runAppWritebackBridge(
            kind: .frontmostInput,
            text: text,
            request: request
        )
    }

    private func replaceFrontmostSelection(text: String, request: AskSessionRequest) async -> AskToolExecutionResult {
        await runAppWritebackBridge(
            kind: .selectionReplacement,
            text: text,
            request: request
        )
    }

    private func runAppWritebackBridge(
        kind: AppWritebackBridgeKind,
        text: String,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        guard appWritebackBridgeAllowsExplicitIntent(kind: kind, request: request) else {
            return blockedByExplicitIntentResult(
                message: appWritebackBridgeBlockedMessage(kind: kind, languageCode: request.responseLanguage),
                data: [appWritebackBridgeBlockedDataKey(kind): true]
            )
        }

        var arguments: AskInvocationMetadata = ["text": text]
        if appWritebackBridgeNeedsSourceBundleID(kind) {
            arguments["source_bundle_id"] = request.metadata.sourceBundleID ?? ""
        }
        let result = await executeLegacyKernelCapability(
            capabilityID: appWritebackBridgeCapabilityID(kind),
            arguments: arguments,
            request: request
        )

        if kind == .frontmostInput,
           result.status == .failed,
           result.metadata["fallback"] == "clipboard" {
            return AskToolExecutionResult(
                ok: false,
                summary: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "没能直接写回，我先把内容放进了剪贴板。",
                    en: "I could not write it back directly, so I placed the content on the clipboard first."
                ),
                data: capabilityBridgeData(from: result),
                cards: [],
                approvalRequest: nil,
                error: nil
            )
        }

        if result.status == .succeeded {
            return AskToolExecutionResult(
                ok: true,
                summary: appWritebackBridgeSuccessMessage(kind: kind, languageCode: request.responseLanguage),
                data: capabilityBridgeData(from: result),
                cards: [],
                approvalRequest: nil,
                error: nil
            )
        }

        let message = legacyCapabilityFailureMessage(
            from: result,
            fallback: appWritebackBridgeFailureMessage(kind: kind, languageCode: request.responseLanguage)
        )
        return AskToolExecutionResult(
            ok: false,
            summary: message,
            data: capabilityBridgeData(from: result),
            cards: [],
            approvalRequest: nil,
            error: kind == .clipboard && (result.status == .denied || result.status == .waitingApproval) ? nil : message
        )
    }

    private func appWritebackBridgeCapabilityID(_ kind: AppWritebackBridgeKind) -> AskCapabilityID {
        switch kind {
        case .clipboard:
            return "app.copy_to_clipboard"
        case .frontmostInput:
            return "app.write_back_to_frontmost_input"
        case .selectionReplacement:
            return "app.replace_frontmost_selection"
        }
    }

    private func appWritebackBridgeNeedsSourceBundleID(_ kind: AppWritebackBridgeKind) -> Bool {
        switch kind {
        case .clipboard:
            return false
        case .frontmostInput, .selectionReplacement:
            return true
        }
    }

    private func appWritebackBridgeAllowsExplicitIntent(
        kind: AppWritebackBridgeKind,
        request: AskSessionRequest
    ) -> Bool {
        switch kind {
        case .clipboard:
            return allowsExplicitClipboardWrite(for: request)
        case .frontmostInput:
            return allowsExplicitWriteback(for: request)
        case .selectionReplacement:
            return allowsExplicitReplacement(for: request)
        }
    }

    private func appWritebackBridgeBlockedDataKey(_ kind: AppWritebackBridgeKind) -> String {
        switch kind {
        case .clipboard:
            return "clipboard_write_blocked"
        case .frontmostInput:
            return "writeback_blocked"
        case .selectionReplacement:
            return "replace_blocked"
        }
    }

    private func appWritebackBridgeBlockedMessage(
        kind: AppWritebackBridgeKind,
        languageCode: String
    ) -> String {
        switch kind {
        case .clipboard:
            return L10n.text(
                languageCode: languageCode,
                zhHans: "我没有改写剪贴板，因为用户这句话没有明确要求复制。",
                en: "I did not modify the clipboard because the user did not explicitly ask to copy anything."
            )
        case .frontmostInput:
            return L10n.text(
                languageCode: languageCode,
                zhHans: "我没有写回前台输入框，因为用户这句话没有明确要求写回或粘贴。",
                en: "I did not write back into the foreground input because the user did not explicitly ask for a write-back or paste."
            )
        case .selectionReplacement:
            return L10n.text(
                languageCode: languageCode,
                zhHans: "我没有替换当前选区，因为用户这句话没有明确要求替换选中的内容。",
                en: "I did not replace the current selection because the user did not explicitly ask to replace the selected content."
            )
        }
    }

    private func appWritebackBridgeSuccessMessage(
        kind: AppWritebackBridgeKind,
        languageCode: String
    ) -> String {
        switch kind {
        case .clipboard:
            return L10n.text(languageCode: languageCode, zhHans: "已复制到剪贴板。", en: "Copied to the clipboard.")
        case .frontmostInput:
            return L10n.text(languageCode: languageCode, zhHans: "已写回前台输入框。", en: "Wrote the text back into the foreground input.")
        case .selectionReplacement:
            return L10n.text(languageCode: languageCode, zhHans: "已替换当前选区。", en: "Replaced the current selection.")
        }
    }

    private func appWritebackBridgeFailureMessage(
        kind: AppWritebackBridgeKind,
        languageCode: String
    ) -> String {
        switch kind {
        case .clipboard:
            return L10n.text(languageCode: languageCode, zhHans: "复制到剪贴板失败。", en: "Failed to copy to the clipboard.")
        case .frontmostInput:
            return L10n.text(languageCode: languageCode, zhHans: "写回前台输入框失败。", en: "Failed to write back into the foreground input.")
        case .selectionReplacement:
            return L10n.text(languageCode: languageCode, zhHans: "替换当前选区失败。", en: "Failed to replace the current selection.")
        }
    }

    private struct AskLocalToolInvocation {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
    }

    private struct AskLocalProcessResult {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    private func localToolInvocation(
        descriptor: AskLocalPromotedToolDescriptor,
        entryURL: URL,
        input: String?
    ) -> AskLocalToolInvocation? {
        let normalizedInput = input?.trimmingCharacters(in: .whitespacesAndNewlines)
        var environment = ProcessInfo.processInfo.environment
        if let normalizedInput, !normalizedInput.isEmpty {
            environment["NEXHUB_PLAYGROUND_INPUT"] = normalizedInput
        }

        switch descriptor.languageRuntime {
        case "python":
            var arguments = ["python3", entryURL.path]
            if let normalizedInput, !normalizedInput.isEmpty {
                arguments.append(normalizedInput)
            }
            return AskLocalToolInvocation(
                executablePath: "/usr/bin/env",
                arguments: arguments,
                environment: environment
            )
        case "javascript":
            var arguments = ["node", entryURL.path]
            if let normalizedInput, !normalizedInput.isEmpty {
                arguments.append(normalizedInput)
            }
            return AskLocalToolInvocation(
                executablePath: "/usr/bin/env",
                arguments: arguments,
                environment: environment
            )
        case "shell":
            var arguments = [entryURL.path]
            if let normalizedInput, !normalizedInput.isEmpty {
                arguments.append(normalizedInput)
            }
            return AskLocalToolInvocation(
                executablePath: "/bin/zsh",
                arguments: arguments,
                environment: environment
            )
        default:
            return nil
        }
    }

    private func runLocalProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL
    ) async -> AskLocalProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.environment = environment
                process.currentDirectoryURL = currentDirectoryURL
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    continuation.resume(
                        returning: AskLocalProcessResult(
                            exitCode: process.terminationStatus,
                            standardOutput: stdout,
                            standardError: stderr
                        )
                    )
                } catch {
                    continuation.resume(
                        returning: AskLocalProcessResult(
                            exitCode: 1,
                            standardOutput: "",
                            standardError: error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    private func previewCalendarIntent(text: String, request: AskSessionRequest) -> AskToolExecutionResult {
        let intents = ScheduleRuntimeSupport.localIntents(from: text)
        guard let intent = intents.first else {
            let message = L10n.text(languageCode: request.responseLanguage, zhHans: "我还没从这句话里解析出稳定的日历时间意图。", en: "I could not parse a stable calendar intent from that request yet.")
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: [:],
                cards: [],
                approvalRequest: nil,
                error: message
            )
        }
        let cards = ScheduleRuntimeSupport.actionCards(from: [intent], languageCode: request.uiLanguage)
        let payload = (try? JSONEncoder().encode(intent)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return AskToolExecutionResult(
            ok: true,
            summary: L10n.format(languageCode: request.responseLanguage, zhHans: "我先把时间意图解析成了：%@。", en: "I first parsed the schedule intent as: %@.", intent.displayScheduleSummary),
            data: [
                "intent_json": payload,
                "intent_title": intent.title
            ],
            cards: cards,
            approvalRequest: nil,
            error: nil
        )
    }

    private func createCalendarOrReminder(
        arguments: [String: Any],
        request: AskSessionRequest,
        actionType: SkillResultActionType
    ) async -> AskToolExecutionResult {
        let intent: CalendarEventIntent?
        if let rawJSON = nonEmptyString(arguments["intent_json"]),
           let data = rawJSON.data(using: .utf8) {
            intent = try? JSONDecoder().decode(CalendarEventIntent.self, from: data)
        } else {
            intent = nil
        }

        let fallbackText = nonEmptyString(arguments["text"])
            ?? request.messages.last(where: { $0.role == .user })?.content
        let resolvedIntent = intent ?? fallbackText.flatMap { ScheduleRuntimeSupport.localIntents(from: $0).first }

        guard let intent = resolvedIntent else {
            return invalidArgumentsResult(
                for: actionType == .createReminder ? "create_reminder" : "create_calendar_event",
                responseLanguage: request.responseLanguage
            )
        }

        let created = await withCheckedContinuation { continuation in
            calendarEventCreator(intent, false) { success in
                continuation.resume(returning: success)
            }
        }

        let receipt = CalendarCreatedItemReceipt.from(
            intent: intent,
            kind: actionType == .createReminder ? .reminder : .event
        )
        if created {
            await sessionStore.appendCalendarReceipt(receipt, for: request.metadata.sessionID)
        }
        let encodedIntent = (try? JSONEncoder().encode(intent)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let encodedReceipt = (try? JSONEncoder().encode(receipt)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let label = actionType == .createReminder
            ? L10n.text(languageCode: request.responseLanguage, zhHans: "创建提醒事项", en: "Create Reminder")
            : L10n.text(languageCode: request.responseLanguage, zhHans: "创建日历事件", en: "Create Calendar Event")

        return AskToolExecutionResult(
            ok: created,
            summary: created
                ? intent.creationConfirmationText
                : L10n.text(languageCode: request.responseLanguage, zhHans: "创建日历项失败。", en: "Failed to create the calendar item."),
            data: [
                "intent_title": intent.title,
                "intent_json": encodedIntent,
                "calendar_item_receipt_json": encodedReceipt,
                "calendar_item_title": intent.title
            ],
            cards: [
                SkillResultCard(
                    id: "calendar-intent-\(intent.title.hashValue)",
                    kind: "calendar_intent",
                    title: intent.title,
                    badges: nil,
                    subtitle: nil,
                    description: "\(intent.displayScheduleSummary) · \(intent.reminderSummary)",
                    action: SkillResultAction(type: actionType, label: label, value: encodedIntent),
                    priority: .primary,
                    isOfficial: true
                )
            ],
            approvalRequest: nil,
            error: created ? nil : "create_failed"
        )
    }

    private func deleteCalendarItem(
        arguments: [String: Any],
        request: AskSessionRequest,
        preferredKind: CalendarCreatedItemReceipt.Kind?
    ) async -> AskToolExecutionResult {
        guard let receipt = await resolvedCalendarReceipt(
            from: arguments,
            request: request,
            preferredKind: preferredKind
        ) else {
            let message = L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "我还没拿到一个可撤销的提醒回执，也没在当前 Ask 会话里找到最近创建的提醒。",
                en: "I don’t have a removable reminder receipt yet, and I couldn’t find a recently created reminder in this Ask session."
            )
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: [:],
                cards: [],
                approvalRequest: nil,
                error: message
            )
        }

        let deleted = await withCheckedContinuation { continuation in
            calendarItemDeleter(receipt) { success in
                continuation.resume(returning: success)
            }
        }

        if deleted {
            await sessionStore.removeCalendarReceipt(receipt, for: request.metadata.sessionID)
        }

        let encodedReceipt = (try? JSONEncoder().encode(receipt)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let summary = deleted
            ? L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "已撤销「%@」这个提醒。",
                en: "Deleted the reminder “%@”.",
                receipt.title
            )
            : L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "没能撤销「%@」这个提醒。",
                en: "Failed to delete the reminder “%@”.",
                receipt.title
            )

        return AskToolExecutionResult(
            ok: deleted,
            summary: summary,
            data: [
                "calendar_item_receipt_json": encodedReceipt,
                "calendar_item_title": receipt.title
            ],
            cards: [],
            approvalRequest: nil,
            error: deleted ? nil : "delete_failed"
        )
    }

    private func fallbackScheduleToolText(from arguments: [String: Any], request: AskSessionRequest) -> String? {
        if let text = nonEmptyString(arguments["text"]) {
            return text
        }
        guard let fallback = request.messages.last(where: { $0.role == .user })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !fallback.isEmpty else {
            return nil
        }
        return fallback
    }

    private func resolvedCalendarReceipt(
        from arguments: [String: Any],
        request: AskSessionRequest,
        preferredKind: CalendarCreatedItemReceipt.Kind?
    ) async -> CalendarCreatedItemReceipt? {
        if let rawReceipt = nonEmptyString(arguments["receipt_json"]),
           let data = rawReceipt.data(using: .utf8),
           let receipt = try? JSONDecoder().decode(CalendarCreatedItemReceipt.self, from: data) {
            return receipt
        }

        if let rawIntent = nonEmptyString(arguments["intent_json"]),
           let data = rawIntent.data(using: .utf8),
           let intent = try? JSONDecoder().decode(CalendarEventIntent.self, from: data) {
            return CalendarCreatedItemReceipt.from(
                intent: intent,
                kind: preferredKind ?? .event
            )
        }

        if let latestReceipt = await sessionStore.latestCalendarReceipt(
            for: request.metadata.sessionID,
            kind: preferredKind
        ) {
            return latestReceipt
        }

        if let text = fallbackScheduleToolText(from: arguments, request: request),
           let intent = ScheduleRuntimeSupport.localIntents(from: text).first {
            return CalendarCreatedItemReceipt.from(
                intent: intent,
                kind: preferredKind ?? .event
            )
        }
        return nil
    }

    private func previewAutomationJob(spec: String, request: AskSessionRequest) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "time.preview_automation_job",
            arguments: compactKernelArguments([
                "spec": spec
            ]),
            request: request
        )
        guard result.status == .succeeded,
              let draftID = result.metadata["pending_automation_draft_id"],
              let draft = automationStore.draft(id: draftID) else {
            let message = legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "我还没把这句话解析成一个稳定的定时任务草案。",
                    en: "I could not turn that request into a stable automation draft yet."
                )
            )
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: capabilityBridgeData(from: result),
                cards: [],
                approvalRequest: nil,
                error: message
            )
        }

        let domains = draft.keyToolDomains.isEmpty ? "" : L10n.joinedList(draft.keyToolDomains)
        let message = L10n.format(
            languageCode: request.responseLanguage,
            zhHans: "我先把这个任务整理成了一个本地定时任务草案：%@。调度为 %@。可能会用到：%@。高风险动作不会自动执行。",
            en: "I first turned this into a local automation draft: %@. It will run on %@. It may use: %@. High-risk actions will not run automatically.",
            draft.title,
            draft.trigger.scheduleSummary,
            domains.isEmpty ? L10n.text(languageCode: request.responseLanguage, zhHans: "agent 能力", en: "agent capabilities") : domains
        )
        let card = SkillResultCard(
            id: "automation-draft-\(draft.id)",
            kind: "automation_draft",
            title: draft.title,
            badges: draft.keyToolDomains,
            subtitle: draft.trigger.scheduleSummary,
            description: automationDraftDescription(draft, responseLanguage: request.responseLanguage),
            action: nil,
            priority: .primary,
            isOfficial: true
        )
        return AskToolExecutionResult(
            ok: true,
            summary: message,
            data: capabilityBridgeData(from: result),
            cards: [card],
            approvalRequest: nil,
            error: nil
        )
    }

    private func createAutomationJob(
        draftID: String?,
        spec: String?,
        request: AskSessionRequest
    ) async -> AskToolExecutionResult {
        let result = await executeLegacyKernelCapability(
            capabilityID: "time.create_automation_job",
            arguments: compactKernelArguments([
                "draft_id": draftID,
                "spec": spec
            ]),
            request: request
        )

        guard result.status == .succeeded,
              let jobID = result.metadata["saved_automation_job_id"],
              let job = automationStore.job(id: jobID) else {
            let message = legacyCapabilityFailureMessage(
                from: result,
                fallback: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "保存本地定时任务失败。",
                    en: "Failed to save the local automation."
                )
            )
            return AskToolExecutionResult(
                ok: false,
                summary: message,
                data: capabilityBridgeData(from: result),
                cards: [],
                approvalRequest: nil,
                error: message
            )
        }

        let summary = L10n.format(
            languageCode: request.responseLanguage,
            zhHans: "已保存本地定时任务“%@”，首次执行时间：%@。结果会通过 Inbox 和系统通知回到你这里。",
            en: "Saved the local automation “%@”. First run: %@. Results will return through the inbox and a system notification.",
            job.title,
            job.nextRunAt.map(formattedAutomationDate) ?? L10n.text(languageCode: request.responseLanguage, zhHans: "待计算", en: "pending")
        )
        return AskToolExecutionResult(
            ok: true,
            summary: summary,
            data: capabilityBridgeData(from: result),
            cards: [
                SkillResultCard(
                    id: "automation-job-\(job.id)",
                    kind: "automation_job",
                    title: job.title,
                    badges: job.keyToolDomains,
                    subtitle: job.trigger.scheduleSummary,
                    description: automationJobDescription(job, responseLanguage: request.responseLanguage),
                    action: nil,
                    priority: .primary,
                    isOfficial: true
                )
            ],
            approvalRequest: nil,
            error: nil
        )
    }

    private func automationPolicyBlockedResult(
        forToolNamed toolName: String,
        request: AskSessionRequest
    ) -> AskToolExecutionResult? {
        guard request.metadata.sessionOrigin == .automation,
              let blockedReason = request.metadata.automationPolicy?.blockedReason(forToolNamed: toolName) else {
            return nil
        }
        return AskToolExecutionResult(
            ok: false,
            summary: blockedReason,
            data: [
                "automation_policy_blocked": true,
                "tool_name": toolName
            ],
            cards: [],
            approvalRequest: nil,
            error: blockedReason
        )
    }

    private func workspacePlanModeBlockedResult(
        forToolNamed toolName: String,
        request: AskSessionRequest
    ) -> AskToolExecutionResult? {
        guard isWorkspacePlanModeActive(request: request),
              toolName == "run_shell_command" || toolName == "apply_workspace_patch" else {
            return nil
        }
        let summary = request.metadata.kernelMetadata["plan_mode_summary"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = L10n.text(
            languageCode: request.responseLanguage,
            zhHans: "当前会话还处在工作区只读规划模式，我不会直接执行这个写入型工作区动作。先继续分析；如果你要我开始落地改动，我会先退出 plan mode。",
            en: "This session is still in read-only workspace planning mode, so I will not run this mutating workspace action yet. I can keep analyzing, and once you want implementation I will exit plan mode first."
        )
        let summaryLine = summary.map {
            L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "当前规划摘要：%@",
                en: "Current plan summary: %@",
                $0
            )
        }
        let message = [base, summaryLine].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n")
        return AskToolExecutionResult(
            ok: false,
            summary: message,
            data: [
                "plan_mode_active": "true",
                "plan_mode_blocked": "true",
                "blocked_tool": toolName,
                "edit_scope_limited": "true",
                "plan_mode_summary": summary ?? ""
            ],
            cards: [],
            approvalRequest: nil,
            error: message
        )
    }

    private func automationDraftDescription(
        _ draft: AskAutomationDraft,
        responseLanguage: String
    ) -> String {
        guard let workspaceRoot = draft.workspaceRoot, !workspaceRoot.isEmpty else {
            return draft.riskSummary
        }
        return draft.riskSummary + "\n" + L10n.format(
            languageCode: responseLanguage,
            zhHans: "工作区：%@",
            en: "Workspace: %@",
            workspaceRoot
        )
    }

    private func automationJobDescription(
        _ job: AskAutomationJob,
        responseLanguage: String
    ) -> String {
        guard let workspaceRoot = job.workspaceRoot, !workspaceRoot.isEmpty else {
            return job.riskSummary
        }
        return job.riskSummary + "\n" + L10n.format(
            languageCode: responseLanguage,
            zhHans: "工作区：%@",
            en: "Workspace: %@",
            workspaceRoot
        )
    }

    private func blockedByExplicitIntentResult(message: String, data: [String: Any]) -> AskToolExecutionResult {
        AskToolExecutionResult(
            ok: false,
            summary: message,
            data: data,
            cards: [],
            approvalRequest: nil,
            error: nil
        )
    }

    private func isWorkspacePlanModeActive(request: AskSessionRequest) -> Bool {
        request.metadata.kernelMetadata["plan_mode_active"]?.lowercased() == "true"
    }

    private func executeLegacyKernelCapability(
        capabilityID: AskCapabilityID,
        arguments: AskInvocationMetadata,
        request: AskSessionRequest,
        approvalStrategy: LegacyApprovalStrategy? = nil
    ) async -> AskCapabilityExecutionResult {
        let metadata = await kernelExecutionMetadata(arguments: arguments, request: request)
        let descriptor = compatibilityBridgeDescriptor(for: capabilityID)
        let mode = compatibilityMode(
            for: capabilityID,
            request: request,
            metadata: metadata
        )
        let resolvedApprovalStrategy = approvalStrategy ?? compatibilityApprovalStrategy(for: capabilityID)
        let profile = compatibilityPolicyProfile(
            for: mode,
            request: request,
            approvalStrategy: resolvedApprovalStrategy,
            ownership: descriptor.ownership
        )
        diagnosticsLogger.log(
            "ask.operator.compatibility",
            "capability=\(capabilityID) kind=\(descriptor.kind.rawValue) ownership=\(descriptor.ownership.rawValue) approval=\(resolvedApprovalStrategy == .policyDriven ? "policyDriven" : "trustExplicitIntent") mode=\(mode.rawValue)"
        )
        let prompt = request.messages.last(where: { $0.role == .user })?.content ?? ""
        let preparedTask = await agentKernel.prepareTask(
            prompt: prompt,
            surface: request.metadata.invocationSurface,
            requestedMode: mode,
            sessionID: request.metadata.sessionID,
            sourceBundleID: request.metadata.sourceBundleID,
            sourceAppName: request.metadata.sourceAppName,
            metadata: metadata,
            policyProfile: profile
        )

        let coordinator = agentKernel.makeExecutionCoordinator()
        return await coordinator.execute(
            preparedTask: preparedTask,
            capabilityID: capabilityID,
            arguments: arguments
        )
    }

    private func compatibilityMode(
        for capabilityID: AskCapabilityID,
        request: AskSessionRequest,
        metadata: AskInvocationMetadata
    ) -> AskExecutionMode {
        _ = capabilityID
        _ = metadata
        if request.metadata.sessionOrigin == .automation || request.metadata.requestedMode == .automate {
            return .automate
        }
        return .interactive
    }

    private func compatibilityApprovalStrategy(for capabilityID: AskCapabilityID) -> LegacyApprovalStrategy {
        compatibilityBridgeDescriptor(for: capabilityID).approvalStrategy
    }

    private func compatibilityBridgeDescriptor(for capabilityID: AskCapabilityID) -> CompatibilityBridgeDescriptor {
        Self.compatibilityBridgeDescriptors[capabilityID]
            ?? CompatibilityBridgeDescriptor(
                kind: .uncataloged,
                approvalStrategy: .trustExplicitIntent,
                ownership: .behaviorOwning
            )
    }

    private func compatibilityPolicyProfile(
        for mode: AskExecutionMode,
        request: AskSessionRequest,
        approvalStrategy: LegacyApprovalStrategy,
        ownership: CompatibilityOwnership
    ) -> AskPolicyProfile {
        let base = AskPolicyProfile.preset(for: mode)
        let followsKernelApproval = approvalStrategy == .policyDriven
        let ownershipSummary: String
        switch ownership {
        case .kernelOwned:
            ownershipSummary = "Compatibility bridge is only packaging kernel-owned state."
        case .stateMirroring:
            ownershipSummary = "Compatibility bridge still mirrors kernel state into local session surfaces."
        case .behaviorOwning:
            ownershipSummary = "Compatibility bridge still owns some product behavior outside the kernel path."
        }
        return AskPolicyProfile(
            id: "\(base.id)-legacy-operator",
            summary: followsKernelApproval
                ? "\(base.summary) Legacy operator actions follow the kernel approval policy. \(ownershipSummary)"
                : "\(base.summary) Legacy operator actions execute without extra visible-action approval once explicit intent has been established. \(ownershipSummary)",
            allowedModes: base.allowedModes,
            allowedDomains: base.allowedDomains,
            allowedRiskClasses: base.allowedRiskClasses,
            requiresApprovalForVisibleActions: followsKernelApproval ? base.requiresApprovalForVisibleActions : false,
            requiresApprovalForDestructiveActions: base.requiresApprovalForDestructiveActions,
            allowUnattendedExecution: base.allowUnattendedExecution || request.metadata.sessionOrigin == .automation,
            requireForegroundForAppControl: base.requireForegroundForAppControl,
            allowClipboardWrite: base.allowClipboardWrite,
            allowWorkspaceMutation: base.allowWorkspaceMutation,
            allowShellExecution: base.allowShellExecution
        )
    }

    private func kernelExecutionMetadata(
        arguments: AskInvocationMetadata,
        request: AskSessionRequest
    ) async -> AskInvocationMetadata {
        var metadata = request.metadata.kernelMetadata
        if let sourceBundleID = request.metadata.sourceBundleID, !sourceBundleID.isEmpty {
            metadata["source_bundle_id"] = sourceBundleID
        }
        if let sourceAppName = request.metadata.sourceAppName, !sourceAppName.isEmpty {
            metadata["source_app_name"] = sourceAppName
        }
        if let automationJobID = request.metadata.automationJobID, !automationJobID.isEmpty {
            metadata["automation_job_id"] = automationJobID
        }
        if let recentBrowserContext = await latestBrowserContext(for: request) {
            metadata["current_page_url"] = recentBrowserContext.url.absoluteString
        } else if let sourceBundleID = request.metadata.sourceBundleID,
                  AskOperatorSupportedBrowser.bundleIDs.contains(sourceBundleID),
                  (metadata["current_page_url"] ?? "").isEmpty {
            metadata["current_page_url"] = "__active_browser_page__"
        }
        for (key, value) in arguments where !value.isEmpty {
            metadata[key] = value
        }
        return metadata
    }

    private func capabilityBridgeData(from result: AskCapabilityExecutionResult) -> [String: Any] {
        var data = result.metadata.reduce(into: [String: Any]()) { partialResult, entry in
            partialResult[entry.key] = entry.value
        }
        if !result.artifacts.isEmpty {
            data["artifacts"] = result.artifacts.map { artifact in
                [
                    "kind": artifact.kind,
                    "value": artifact.value
                ]
            }
        }
        return data
    }

    private func legacyCapabilityFailureMessage(
        from result: AskCapabilityExecutionResult,
        fallback: String
    ) -> String {
        switch result.status {
        case .denied, .failed, .unsupported, .waitingApproval:
            let trimmed = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        case .succeeded:
            return fallback
        }
    }

    private func capabilityArtifactValue(
        kind: String,
        from result: AskCapabilityExecutionResult
    ) -> String? {
        result.artifacts.first(where: { $0.kind == kind })?.value
    }

    private func pendingKernelMoveApproval(for sessionID: String) async -> AskCapabilityApprovalRecord? {
        await kernelApprovalRouter.latestApprovalRequest(
            sessionID: sessionID,
            capabilityID: "desktop.commit_move_operation"
        )
    }

    private func compactKernelArguments(_ pairs: (String, String?)...) -> AskInvocationMetadata {
        var metadata: AskInvocationMetadata = [:]
        for (key, value) in pairs {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            metadata[key] = value
        }
        return metadata
    }

    private func compactKernelArguments(_ dictionary: [String: String?]) -> AskInvocationMetadata {
        compactKernelArguments(dictionary.map { ($0.key, $0.value) })
    }

    private func compactKernelArguments(_ pairs: [(String, String?)]) -> AskInvocationMetadata {
        var metadata: AskInvocationMetadata = [:]
        for (key, value) in pairs {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            metadata[key] = value
        }
        return metadata
    }

    private func splitKernelLines(_ value: String?, fallback: [String]) -> [String] {
        guard let value = nonEmptyString(value) else {
            return fallback
        }
        return value
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func splitKernelList(_ value: String?, fallback: [String]) -> [String] {
        guard let value = nonEmptyString(value) else {
            return fallback
        }
        return value
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func kernelBool(_ value: String?) -> Bool? {
        guard let normalized = nonEmptyString(value)?.lowercased() else { return nil }
        switch normalized {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }

    private func approvalRequestForKernelResult(
        _ result: AskCapabilityExecutionResult,
        request: AskSessionRequest
    ) async -> AskApprovalRequest? {
        guard let approvalID = result.approvalID,
              let approval = await kernelApprovalRouter.approvalRequest(id: approvalID) else {
            return nil
        }

        return await approvalRequest(for: approval, request: request)
    }

    private func approvalRequest(
        for approval: AskCapabilityApprovalRecord,
        request: AskSessionRequest
    ) async -> AskApprovalRequest? {
        let targetSummary = capabilityApprovalTargetSummary(for: approval.request)
        let summary = localizedCapabilityApprovalSummary(
            for: approval.request.capability.id,
            responseLanguage: request.responseLanguage
        )
        let message = localizedCapabilityApprovalMessage(
            for: approval.request,
            reason: approval.reason,
            targetSummary: targetSummary,
            responseLanguage: request.responseLanguage
        )
        let reversibilitySummary = approval.request.capability.supportsRollback
            ? L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "这类动作在执行后仍然保留回滚空间，但最好先确认范围。",
                en: "This action keeps some rollback room after execution, but it is still best to confirm the scope first."
            )
            : L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "在确认之前你都可以安全取消。",
                en: "You can safely cancel this any time before approval."
            )

        if approval.request.capability.id == "desktop.commit_move_operation",
           let operationID = nonEmptyString(approval.request.arguments["operation_id"]),
           let operation = await sessionStore.operation(for: operationID) {
            return AskApprovalRequest(
                actionID: approval.approvalID,
                toolName: approval.request.capability.id,
                targetSummary: displayPath(URL(fileURLWithPath: operation.destinationDirectoryPath, isDirectory: true)),
                affectedCount: operation.affectedItemCount,
                conflictSummary: AskApprovalConflictSummary(
                    collisionCount: operation.collisions.count,
                    skippedCount: operation.skippedPaths.count,
                    sampleDestinationPaths: Array(operation.collisions.prefix(3).map(\.destinationPath)),
                    summary: L10n.format(
                        languageCode: request.responseLanguage,
                        zhHans: "检测到 %d 个重名冲突，预先跳过 %d 个项目。",
                        en: "Detected %d name collision(s) and pre-skipped %d item(s).",
                        operation.collisions.count,
                        operation.skippedPaths.count
                    )
                ),
                reversibilityHint: AskReversibilityHint(
                    kind: approval.request.capability.supportsRollback ? "rollback_supported" : "pre_approval_cancel",
                    summary: reversibilitySummary
                ),
                expiry: nil,
                operationID: operation.id,
                summary: summary,
                message: message,
                cards: pendingMovePreviewCards(for: operation, responseLanguage: request.responseLanguage)
            )
        }

        return AskApprovalRequest(
            actionID: approval.approvalID,
            toolName: approval.request.capability.id,
            targetSummary: targetSummary,
            affectedCount: 1,
            conflictSummary: AskApprovalConflictSummary(
                collisionCount: 0,
                skippedCount: 0,
                sampleDestinationPaths: [],
                summary: L10n.text(
                    languageCode: request.responseLanguage,
                    zhHans: "当前未发现阻塞冲突。",
                    en: "No blocking conflicts were detected."
                )
            ),
            reversibilityHint: AskReversibilityHint(
                kind: approval.request.capability.supportsRollback ? "rollback_supported" : "pre_approval_cancel",
                summary: reversibilitySummary
            ),
            expiry: nil,
            operationID: approval.request.arguments["operation_id"] ?? approval.approvalID,
            summary: summary,
            message: message,
            cards: [
                makeCard(
                    id: "kernel-approval-\(approval.approvalID)",
                    title: summary,
                    subtitle: targetSummary,
                    description: approval.reason,
                    action: nil,
                    value: nil
                )
            ]
        )
    }

    private func localizedCapabilityApprovalSummary(
        for capabilityID: AskCapabilityID,
        responseLanguage: String
    ) -> String {
        switch capabilityID {
        case "workspace.create_directory", "workspace.commit_changes", "workspace.write_file", "workspace.run_shell_command":
            return L10n.text(languageCode: responseLanguage, zhHans: "等待确认当前任务执行", en: "Waiting for current task execution approval")
        case "desktop.commit_move_operation":
            return L10n.text(languageCode: responseLanguage, zhHans: "等待执行文件移动", en: "Waiting to execute the file move")
        case "browser.open_url":
            return L10n.text(languageCode: responseLanguage, zhHans: "等待打开网页", en: "Waiting to open the page")
        case "browser.search_web":
            return L10n.text(languageCode: responseLanguage, zhHans: "等待执行浏览器搜索", en: "Waiting to run the browser search")
        case "app.write_back_to_frontmost_input":
            return L10n.text(languageCode: responseLanguage, zhHans: "等待写回前台输入框", en: "Waiting to write back into the foreground input")
        case "app.replace_frontmost_selection":
            return L10n.text(languageCode: responseLanguage, zhHans: "等待替换当前选区", en: "Waiting to replace the current selection")
        case "app.copy_to_clipboard":
            return L10n.text(languageCode: responseLanguage, zhHans: "等待改写剪贴板", en: "Waiting to update the clipboard")
        default:
            return L10n.text(languageCode: responseLanguage, zhHans: "等待你的确认", en: "Waiting for your confirmation")
        }
    }

    private func localizedCapabilityApprovalMessage(
        for requestData: AskCapabilityExecutionRequest,
        reason: String,
        targetSummary: String,
        responseLanguage: String
    ) -> String {
        let prompt = L10n.text(
            languageCode: responseLanguage,
            zhHans: "回复“confirm”执行，或回复“cancel”放弃。",
            en: "Reply with “confirm” to execute it, or “cancel” to drop it."
        )
        let base: String
        switch requestData.capability.id {
        case "workspace.create_directory", "workspace.commit_changes", "workspace.write_file", "workspace.run_shell_command":
            let root = requestData.arguments["workspace_root"]
                ?? requestData.task.context.workspaceRootPath
                ?? requestData.task.metadata["workspace_root"]
                ?? requestData.task.metadata["active_task_workspace_root"]
                ?? "Playground"
            let workspaceName = URL(fileURLWithPath: root).lastPathComponent
            base = L10n.format(
                languageCode: responseLanguage,
                zhHans: "我准备开始执行这个 ASK 任务，并在 Playground 工作区 %@ 内继续创建目录、写文件、执行必要命令并打开结果。",
                en: "I’m ready to execute this ASK task and continue creating folders, writing files, running needed commands, and opening the result inside Playground workspace %@.",
                workspaceName
            )
        case "desktop.commit_move_operation":
            base = L10n.format(
                languageCode: responseLanguage,
                zhHans: "我已经准备好执行这个文件移动：%@。",
                en: "I’m ready to execute this file move: %@.",
                targetSummary
            )
        case "browser.open_url":
            base = L10n.format(
                languageCode: responseLanguage,
                zhHans: "我已经准备好打开这个网页：%@。",
                en: "I’m ready to open this page: %@.",
                targetSummary
            )
        default:
            base = L10n.format(
                languageCode: responseLanguage,
                zhHans: "我已经准备好执行这一步：%@。",
                en: "I’m ready to execute this step: %@.",
                targetSummary
            )
        }
        return [base, reason, prompt]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    private func capabilityApprovalTargetSummary(
        for requestData: AskCapabilityExecutionRequest
    ) -> String {
        switch requestData.capability.id {
        case "workspace.commit_changes":
            let root = requestData.arguments["workspace_root"] ?? requestData.task.context.workspaceRootPath ?? ""
            let preview = root.isEmpty ? requestData.capability.summary : URL(fileURLWithPath: root).lastPathComponent
            return String(preview.prefix(140))
        case "workspace.write_file":
            let path = requestData.arguments["path"] ?? requestData.arguments["file_path"] ?? ""
            let preview = path.isEmpty ? requestData.capability.summary : URL(fileURLWithPath: path).lastPathComponent
            return String(preview.prefix(140))
        case "workspace.run_shell_command":
            let command = requestData.arguments["command"] ?? requestData.arguments["cmd"] ?? requestData.arguments["shell_command"] ?? ""
            let root = requestData.arguments["workspace_root"] ?? requestData.task.context.workspaceRootPath ?? ""
            let combined = root.isEmpty ? command : "\(command) · \(root)"
            return String(combined.prefix(140))
        case "desktop.commit_move_operation":
            let destination = requestData.arguments["destination_directory"] ?? requestData.arguments["target_directory"] ?? ""
            let affectedCount = requestData.arguments["affected_count"] ?? ""
            let destinationLabel = destination.isEmpty
                ? requestData.capability.summary
                : URL(fileURLWithPath: destination).lastPathComponent
            let combined = affectedCount.isEmpty ? destinationLabel : "\(affectedCount) items · \(destinationLabel)"
            return String(combined.prefix(140))
        case "browser.open_url":
            return requestData.arguments["url"] ?? requestData.capability.summary
        case "browser.search_web":
            return requestData.arguments["query"] ?? requestData.capability.summary
        case "app.copy_to_clipboard", "app.write_back_to_frontmost_input", "app.replace_frontmost_selection":
            return String((requestData.arguments["text"] ?? requestData.capability.summary).prefix(140))
        default:
            return requestData.capability.summary
        }
    }

    private func localizedCapabilitySuccessSummary(
        capabilityID: AskCapabilityID,
        metadata: AskInvocationMetadata,
        responseLanguage: String
    ) -> String {
        switch capabilityID {
        case "workspace.commit_changes":
            return L10n.text(
                languageCode: responseLanguage,
                zhHans: "已把 patch 应用到工作区。",
                en: "Applied the patch into the workspace."
            )
        case "workspace.enter_plan_mode":
            return L10n.text(
                languageCode: responseLanguage,
                zhHans: "已进入当前工作区的只读规划模式。",
                en: "Entered read-only planning mode for the workspace."
            )
        case "workspace.exit_plan_mode":
            let grants = localizedWorkspaceExecutionGrantLabel(
                metadata: metadata,
                responseLanguage: responseLanguage
            )
            if let grants, !grants.isEmpty {
                return L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已退出当前工作区的规划模式，本轮会话已授权：%@。",
                    en: "Exited workspace planning mode. This session is now granted: %@.",
                    grants
                )
            }
            return L10n.text(
                languageCode: responseLanguage,
                zhHans: "已退出当前工作区的规划模式，后续执行仍会按动作继续确认。",
                en: "Exited workspace planning mode. Later execution will still use per-action approval."
            )
        case "workspace.set_execution_budget":
            let budgetLabel = localizedWorkspaceExecutionBudgetLabel(
                metadata: metadata,
                responseLanguage: responseLanguage
            )
            return L10n.format(
                languageCode: responseLanguage,
                zhHans: "已更新当前工作区的 session 权限：%@。",
                en: "Updated the workspace session permissions: %@.",
                budgetLabel
            )
        case "system.list_tasks":
            let listedCount = metadata["listed_task_count"] ?? metadata["session_task_count"] ?? "0"
            let openCount = metadata["open_task_count"] ?? listedCount
            return L10n.format(
                languageCode: responseLanguage,
                zhHans: "已列出 %@ 个任务，当前 open tasks %@ 个。",
                en: "Listed %@ tasks with %@ currently open.",
                listedCount,
                openCount
            )
        case "system.get_task":
            let title = metadata["task_title"] ?? metadata["active_task_title"] ?? ""
            let clippedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = metadata["task_status"] ?? metadata["active_task_status"] ?? ""
            return clippedTitle.isEmpty
                ? L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "已读取任务详情。",
                    en: "Loaded the task details."
                )
                : L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已读取任务详情：%@（%@）。",
                    en: "Loaded task details: %@ (%@).",
                    clippedTitle,
                    status.isEmpty ? "unknown" : status
                )
        case "system.update_task":
            let title = metadata["task_title"] ?? metadata["active_task_title"] ?? ""
            let clippedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = metadata["task_status"] ?? metadata["active_task_status"] ?? ""
            return clippedTitle.isEmpty
                ? L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "已更新任务。",
                    en: "Updated the task."
                )
                : L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已更新任务：%@（%@）。",
                    en: "Updated task: %@ (%@).",
                    clippedTitle,
                    status.isEmpty ? "unknown" : status
                )
        case "system.stop_task":
            let title = metadata["task_title"] ?? metadata["active_task_title"] ?? ""
            let clippedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return clippedTitle.isEmpty
                ? L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "已停止这个任务。",
                    en: "Stopped the task."
                )
                : L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已停止任务：%@。",
                    en: "Stopped task: %@.",
                    clippedTitle
                )
        case "system.resume_task":
            let title = metadata["active_task_title"] ?? metadata["resumed_task_title"] ?? metadata["task_title"] ?? ""
            let clippedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = AskTaskStatus(rawValue: metadata["active_task_status"] ?? "")
            if clippedTitle.isEmpty {
                return L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "已恢复之前记录的任务上下文。",
                    en: "Restored a previously recorded task context."
                )
            }
            switch status {
            case .waitingApproval:
                return L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已恢复任务上下文：%@。它当前仍在等待确认。",
                    en: "Restored task context: %@. It is still waiting for approval.",
                    clippedTitle
                )
            case .completed, .failed, .cancelled:
                return L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已恢复任务上下文：%@。当前作为历史上下文继续参考。",
                    en: "Restored task context: %@. It will continue as historical context.",
                    clippedTitle
                )
            case .queued, .planning, .running, .blocked, .none:
                return L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已恢复任务上下文：%@。",
                    en: "Restored task context: %@.",
                    clippedTitle
                )
            }
        case "system.write_todo":
            let title = metadata["task_title"] ?? metadata["active_task_title"] ?? ""
            let clippedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let progress = metadata["task_progress_summary"] ?? metadata["active_task_progress_summary"] ?? ""
            if clippedTitle.isEmpty {
                return progress.isEmpty
                    ? L10n.text(
                        languageCode: responseLanguage,
                        zhHans: "已更新任务清单。",
                        en: "Updated the task checklist."
                    )
                    : L10n.format(
                        languageCode: responseLanguage,
                        zhHans: "已更新任务清单：%@。",
                        en: "Updated the task checklist: %@.",
                        progress
                    )
            }
            return progress.isEmpty
                ? L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已更新任务清单：%@。",
                    en: "Updated the task checklist for %@.",
                    clippedTitle
                )
                : L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已更新任务清单：%@（%@）。",
                    en: "Updated the task checklist for %@ (%@).",
                    clippedTitle,
                    progress
                )
        case "system.spawn_subtask":
            let title = metadata["subtask_title"] ?? metadata["title"] ?? ""
            let clippedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return clippedTitle.isEmpty
                ? L10n.text(
                    languageCode: responseLanguage,
                    zhHans: "已记录一个新的子任务。",
                    en: "Recorded a new child task."
                )
                : L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已记录子任务：%@。",
                    en: "Recorded child task: %@.",
                    clippedTitle
                )
        case "workspace.glob_paths":
            let matchedCount = metadata["count"] ?? "0"
            let glob = metadata["glob"] ?? ""
            return glob.isEmpty
                ? L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已按模式匹配 %@ 个工作区路径。",
                    en: "Matched %@ workspace paths.",
                    matchedCount
                )
                : L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已匹配 %@ 个工作区路径（glob：%@）。",
                    en: "Matched %@ workspace paths for glob %@.",
                    matchedCount,
                    glob
                )
        case "workspace.write_file":
            let path = metadata["path"] ?? metadata["written_file_path"] ?? ""
            let fileLabel = path.isEmpty
                ? L10n.text(languageCode: responseLanguage, zhHans: "目标文件", en: "the target file")
                : URL(fileURLWithPath: path).lastPathComponent
            let overwroteExisting = kernelBool(metadata["file_already_exists"]) ?? false
            return overwroteExisting
                ? L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已覆盖工作区文件：%@。",
                    en: "Overwrote the workspace file %@.",
                    fileLabel
                )
                : L10n.format(
                    languageCode: responseLanguage,
                    zhHans: "已创建工作区文件：%@。",
                    en: "Created the workspace file %@.",
                    fileLabel
                )
        case "workspace.run_shell_command":
            return L10n.text(
                languageCode: responseLanguage,
                zhHans: "已执行工作区命令。",
                en: "Ran the workspace command."
            )
        case "desktop.commit_move_operation":
            let movedCount = Int(metadata["moved_count"] ?? "") ?? 0
            let destination = metadata["destination_directory"] ?? ""
            let destinationLabel = destination.isEmpty
                ? L10n.text(languageCode: responseLanguage, zhHans: "目标目录", en: "the destination")
                : URL(fileURLWithPath: destination).lastPathComponent
            return L10n.format(
                languageCode: responseLanguage,
                zhHans: "已把 %d 个文件移到 %@。",
                en: "Moved %d file(s) into %@.",
                movedCount,
                destinationLabel
            )
        case "browser.open_url":
            let host = URL(string: metadata["url"] ?? "")?.host ?? metadata["url"] ?? ""
            return L10n.format(
                languageCode: responseLanguage,
                zhHans: "已打开 %@。",
                en: "Opened %@.",
                host.isEmpty ? L10n.text(languageCode: responseLanguage, zhHans: "目标页面", en: "the page") : host
            )
        case "app.write_back_to_frontmost_input":
            return L10n.text(
                languageCode: responseLanguage,
                zhHans: "已写回前台输入框。",
                en: "Wrote the text back into the foreground input."
            )
        case "app.replace_frontmost_selection":
            return L10n.text(
                languageCode: responseLanguage,
                zhHans: "已替换当前选区。",
                en: "Replaced the current selection."
            )
        case "app.copy_to_clipboard":
            return L10n.text(
                languageCode: responseLanguage,
                zhHans: "已复制到剪贴板。",
                en: "Copied to the clipboard."
            )
        default:
            return L10n.text(
                languageCode: responseLanguage,
                zhHans: "已完成这一步。",
                en: "Completed the requested action."
            )
        }
    }

    private func localizedWorkspaceExecutionGrantDescription(
        metadata: AskInvocationMetadata,
        fallbackScope: String,
        responseLanguage: String
    ) -> String {
        guard let grants = localizedWorkspaceExecutionGrantLabel(
            metadata: metadata,
            responseLanguage: responseLanguage
        ) else {
            return fallbackScope
        }
        return L10n.format(
            languageCode: responseLanguage,
            zhHans: "%@\n当前 session 授权：%@",
            en: "%@\nSession grants: %@",
            fallbackScope,
            grants
        )
    }

    private func localizedWorkspaceExecutionBudgetDescription(
        metadata: AskInvocationMetadata,
        responseLanguage: String
    ) -> String {
        let budgetLabel = localizedWorkspaceExecutionBudgetLabel(
            metadata: metadata,
            responseLanguage: responseLanguage
        )
        let planModeActive = metadata["plan_mode_active"]?.lowercased() == "true"
        if planModeActive {
            return L10n.format(
                languageCode: responseLanguage,
                zhHans: "当前 session 权限：%@\n规划模式仍然保持开启",
                en: "Current session permissions: %@\nPlanning mode remains active",
                budgetLabel
            )
        }
        return L10n.format(
            languageCode: responseLanguage,
            zhHans: "当前 session 权限：%@",
            en: "Current session permissions: %@",
            budgetLabel
        )
    }

    private func localizedWorkspaceExecutionBudgetLabel(
        metadata: AskInvocationMetadata,
        responseLanguage: String
    ) -> String {
        AskWorkspaceExecutionBudget.from(metadata: metadata)
            .localizedLabel(responseLanguage: responseLanguage)
    }

    private func localizedWorkspaceExecutionGrantLabel(
        metadata: AskInvocationMetadata,
        responseLanguage: String
    ) -> String? {
        let budget = AskWorkspaceExecutionBudget.from(metadata: metadata)
        guard budget.permissionProfile != .manualApproval || budget.hasExtendedShellGrants else {
            return nil
        }
        return budget.localizedLabel(responseLanguage: responseLanguage)
    }

    private func capabilityFollowupCards(
        for capabilityID: AskCapabilityID,
        metadata: AskInvocationMetadata,
        responseLanguage: String
    ) -> [SkillResultCard] {
        switch capabilityID {
        case "workspace.commit_changes":
            if let root = metadata["workspace_root"], !root.isEmpty {
                return [
                    makeCard(
                        id: "cap-patch-root-\(root.hashValue)",
                        title: L10n.text(languageCode: responseLanguage, zhHans: "Patch 已应用", en: "Patch applied"),
                        subtitle: URL(fileURLWithPath: root).lastPathComponent,
                        description: root,
                        action: .revealInFinder,
                        value: root
                    )
                ]
            }
            return []
        case "desktop.commit_move_operation":
            guard let destination = metadata["destination_directory"], !destination.isEmpty else { return [] }
            return [
                makeCard(
                    id: "cap-move-destination-\(destination.hashValue)",
                    title: L10n.text(languageCode: responseLanguage, zhHans: "文件已移动", en: "Files moved"),
                    subtitle: URL(fileURLWithPath: destination).lastPathComponent,
                    description: destination,
                    action: .openFile,
                    value: destination
                )
            ]
        case "browser.open_url":
            guard let url = metadata["url"], !url.isEmpty else { return [] }
            return [
                makeCard(
                    id: "cap-open-url-\(url.hashValue)",
                    title: URL(string: url)?.host ?? url,
                    subtitle: url,
                    description: nil,
                    action: .openURL,
                    value: url
                )
            ]
        case "workspace.run_shell_command":
            guard let command = metadata["command"], !command.isEmpty else { return [] }
            return [
                makeCard(
                    id: "cap-shell-\(command.hashValue)",
                    title: L10n.text(languageCode: responseLanguage, zhHans: "已执行命令", en: "Command executed"),
                    subtitle: command,
                    description: metadata["workspace_root"],
                    action: nil,
                    value: nil
                )
            ]
        default:
            return []
        }
    }

    private func mixedPlanResponse(request: AskSessionRequest) -> AskSessionResponse {
        AskSessionResponse(
            message: L10n.text(
                languageCode: request.responseLanguage,
                zhHans: "这轮请求同时包含网页操作和文件改动。当前 Ask operator 已经能真实执行结构化单步网页/文件动作，但还没有把“先上网找结果，再继续批量改本地文件”串成稳定的多步代理。你可以先让我完成网页搜索或当前页读取，再下一条继续做文件操作。",
                en: "This turn mixes web actions with file changes. The current Ask operator can already execute structured single-step web and file actions, but it does not yet chain “search the web first, then batch-change local files” into a stable multi-step agent. You can let me finish the web lookup or current-page read first, then continue with the file action in the next turn."
            ),
            cards: [],
            metadata: [
                "operator_handled": "true",
                "operator_action": "mixed_plan_only",
                "session_id": request.metadata.sessionID
            ]
        )
    }

    private func missingPathResponse(
        _ url: URL,
        request: AskSessionRequest,
        action: String
    ) -> AskSessionResponse {
        AskSessionResponse(
            message: L10n.format(
                languageCode: request.responseLanguage,
                zhHans: "没有找到这个路径：%@。",
                en: "Could not find this path: %@.",
                displayPath(url)
            ),
            cards: [],
            metadata: [
                "operator_handled": "true",
                "operator_action": action,
                "session_id": request.metadata.sessionID
            ]
        )
    }

    private func pendingMovePreviewCards(
        for operation: AskStagedOperation,
        responseLanguage: String
    ) -> [SkillResultCard] {
        var cards = [
            makeCard(
                id: "pending-move-destination-\(operation.destinationDirectoryPath.hashValue)",
                title: URL(fileURLWithPath: operation.destinationDirectoryPath).lastPathComponent,
                subtitle: operation.destinationDirectoryPath,
                description: L10n.text(languageCode: responseLanguage, zhHans: "待移动的目标目录", en: "The pending destination directory"),
                action: .openFile,
                value: operation.destinationDirectoryPath
            )
        ]
        cards.append(contentsOf: operation.previewPaths.prefix(3).map { path in
            let url = URL(fileURLWithPath: path)
            return makeCard(
                id: "pending-move-source-\(path.hashValue)",
                title: url.lastPathComponent,
                subtitle: displayPath(url.deletingLastPathComponent()),
                description: L10n.text(languageCode: responseLanguage, zhHans: "待移动的源文件", en: "Pending source item"),
                action: .revealInFinder,
                value: path
            )
        })
        return cards
    }

    private func mirroredKernelMoveOperation(
        from result: AskCapabilityExecutionResult,
        selectionID: String?,
        sourcePaths: [String],
        request: AskSessionRequest
    ) async -> AskStagedOperation? {
        guard result.status == .succeeded,
              let operationID = nonEmptyString(result.metadata["operation_id"]),
              let destinationDirectory = nonEmptyString(result.metadata["destination_directory"]) else {
            return nil
        }

        let normalizedSources = uniqueURLs(sourcePaths.compactMap { resolvedPathURL(from: $0) })
        let skippedPaths = splitKernelLines(
            capabilityArtifactValue(kind: "skipped_paths", from: result),
            fallback: []
        )
        let skippedSet = Set(skippedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let existingSourcePaths = normalizedSources
            .map(\.standardizedFileURL.path)
            .filter { !skippedSet.contains($0) }
        let previewPaths = splitKernelLines(
            capabilityArtifactValue(kind: "move_preview_paths", from: result),
            fallback: Array(existingSourcePaths.prefix(5))
        )
        let collisions = splitKernelLines(
            capabilityArtifactValue(kind: "move_collisions", from: result),
            fallback: []
        ).compactMap { line -> AskStagedOperationCollision? in
            let parts = line.components(separatedBy: " -> ")
            guard parts.count == 2 else { return nil }
            return AskStagedOperationCollision(
                sourcePath: parts[0],
                destinationPath: parts[1]
            )
        }
        let selection: AskPathSelection?
        if let selectionID {
            selection = await sessionStore.selection(for: selectionID)
        } else {
            selection = nil
        }

        return AskStagedOperation(
            id: operationID,
            sessionID: request.metadata.sessionID,
            kind: .move,
            sourceSnapshotID: selection?.snapshotID,
            selectionID: selection?.id,
            sourcePaths: existingSourcePaths,
            destinationDirectoryPath: destinationDirectory,
            createDestinationIfNeeded: kernelBool(result.metadata["create_destination_if_needed"]) ?? false,
            affectedItemCount: Int(result.metadata["affected_count"] ?? "") ?? existingSourcePaths.count,
            previewPaths: previewPaths,
            collisions: collisions,
            skippedPaths: skippedPaths,
            status: AskOperationStatus(rawValue: result.metadata["status"] ?? "") ?? .staged,
            createdAt: Date()
        )
    }

    private func synchronizeMirroredMoveApproval(
        approval: AskCapabilityApprovalRecord,
        resolved: AskCapabilityExecutionResult,
        approved: Bool
    ) async {
        guard let operationID = nonEmptyString(approval.request.arguments["operation_id"]),
              var operation = await sessionStore.operation(for: operationID) else {
            return
        }

        operation.status = approved
            ? (resolved.status == .succeeded ? .committed : .failed)
            : .cancelled
        await sessionStore.setOperation(operation)
    }

    private func stringValue(from value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func intValue(from value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func boolValue(from value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private func pathRecord(for url: URL) -> AskPathRecord {
        let standardized = url.standardizedFileURL
        let resourceValues = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return AskPathRecord(
            path: standardized.path,
            name: standardized.lastPathComponent,
            parentPath: standardized.deletingLastPathComponent().path,
            isDirectory: resourceValues?.isDirectory ?? false,
            sizeBytes: resourceValues?.fileSize.map(Int64.init),
            modifiedAt: resourceValues?.contentModificationDate
        )
    }

    private func pathRecordPayload(for item: AskPathRecord) -> [String: Any] {
        let standardized = URL(fileURLWithPath: item.path).standardizedFileURL
        let exists = fileManager.fileExists(atPath: standardized.path)
        var payload: [String: Any] = [
            "path": item.path,
            "name": item.name,
            "parent_path": item.parentPath,
            "exists": exists,
            "is_directory": item.isDirectory
        ]
        if let size = item.sizeBytes {
            payload["size_bytes"] = size
        }
        if let modifiedAt = item.modifiedAt {
            payload["modified_at"] = ISO8601DateFormatter().string(from: modifiedAt)
        }
        return payload
    }

    private func findFileMatches(criteria: FileSearchCriteria) -> [URL] {
        var matches: [URL] = []
        var inspected = 0
        let normalizedExtensions = Set(criteria.extensionFilters.map { $0.lowercased() })
        let normalizedNameQuery = criteria.nameContains?.lowercased()

        for root in criteria.rootDirectories {
            guard fileManager.fileExists(atPath: root.path) else { continue }
            if fileMatches(
                root,
                includeDirectories: criteria.includeDirectories,
                normalizedExtensions: normalizedExtensions,
                normalizedNameQuery: normalizedNameQuery
            ) {
                matches.append(root)
            }

            if criteria.directChildrenOnly {
                guard let children = try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    continue
                }
                for child in children {
                    if fileMatches(
                        child,
                        includeDirectories: criteria.includeDirectories,
                        normalizedExtensions: normalizedExtensions,
                        normalizedNameQuery: normalizedNameQuery
                    ) {
                        matches.append(child)
                    }
                }
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            while let item = enumerator.nextObject() as? URL {
                inspected += 1
                if inspected > 5_000 {
                    break
                }
                if fileMatches(
                    item,
                    includeDirectories: criteria.includeDirectories,
                    normalizedExtensions: normalizedExtensions,
                    normalizedNameQuery: normalizedNameQuery
                ) {
                    matches.append(item)
                }
            }

            if inspected > 5_000 {
                break
            }
        }

        return uniqueURLs(matches).sorted { lhs, rhs in
            let lhsDepth = relativeDepth(of: lhs, under: criteria.rootDirectories)
            let rhsDepth = relativeDepth(of: rhs, under: criteria.rootDirectories)
            if lhsDepth != rhsDepth {
                return lhsDepth < rhsDepth
            }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    private func directMatches(in matches: [URL], roots: [URL]) -> [URL] {
        matches.filter { match in
            roots.contains { root in
                match.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
            }
        }
    }

    private func relativeDepth(of url: URL, under roots: [URL]) -> Int {
        let standardizedPath = url.standardizedFileURL.path
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            guard standardizedPath.hasPrefix(rootPath) else { continue }
            let suffix = standardizedPath.dropFirst(rootPath.count).split(separator: "/")
            return suffix.count
        }
        return Int.max
    }

    private func fileMatches(
        _ url: URL,
        includeDirectories: Bool,
        normalizedExtensions: Set<String>,
        normalizedNameQuery: String?
    ) -> Bool {
        let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        let isDirectory = resourceValues?.isDirectory ?? false
        let isRegularFile = resourceValues?.isRegularFile ?? !isDirectory
        if isDirectory && !includeDirectories {
            return false
        }
        if !isDirectory && !isRegularFile {
            return false
        }

        let lastPathComponent = url.lastPathComponent.lowercased()
        if let normalizedNameQuery, !normalizedNameQuery.isEmpty, !lastPathComponent.contains(normalizedNameQuery) {
            return false
        }

        if !normalizedExtensions.isEmpty {
            if isDirectory {
                return false
            }
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty, normalizedExtensions.contains(ext) else {
                return false
            }
        }

        return true
    }

    private func uniqueDestinationURL(for sourceURL: URL, inside directory: URL) -> URL {
        let initial = directory.appendingPathComponent(sourceURL.lastPathComponent)
        guard fileManager.fileExists(atPath: initial.path) else { return initial }

        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        for index in 2...1000 {
            let candidateName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    private func summarizeSearchCriteria(_ criteria: FileSearchCriteria, responseLanguage: String) -> String {
        if let nameContains = criteria.nameContains, !nameContains.isEmpty {
            return L10n.format(languageCode: responseLanguage, zhHans: "文件名包含“%@”", en: "Filename contains “%@”", nameContains)
        }
        if let ext = criteria.extensionFilters.first {
            return L10n.format(languageCode: responseLanguage, zhHans: ".%@ 文件", en: ".%@ files", ext)
        }
        return L10n.text(languageCode: responseLanguage, zhHans: "文件搜索结果", en: "File search results")
    }

    private func pageSnippet(from text: String) -> String {
        let paragraphs = text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 24 }

        let snippet = paragraphs.prefix(2).joined(separator: "\n\n")
        if snippet.count <= 420 {
            return snippet
        }
        let index = snippet.index(snippet.startIndex, offsetBy: 417)
        return String(snippet[..<index]) + "..."
    }

    private func currentPageMatches(in text: String, query: String) -> [String] {
        let queryTokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !queryTokens.isEmpty else { return [] }

        let candidates = text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 18 }

        let scored = candidates.compactMap { line -> (String, Int)? in
            let normalized = line.lowercased()
            let score = queryTokens.reduce(into: 0) { partialResult, token in
                if normalized.contains(token) {
                    partialResult += 1
                }
            }
            guard score > 0 else { return nil }
            return (line, score)
        }

        return scored
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.count < $1.0.count
                }
                return $0.1 > $1.1
            }
            .map(\.0)
            .prefix(3)
            .map { line in
                if line.count <= 220 {
                    return line
                }
                let index = line.index(line.startIndex, offsetBy: 217)
                return String(line[..<index]) + "..."
            }
    }

    private func fileSearchCriteria(from text: String) -> FileSearchCriteria? {
        let normalized = normalize(text)
        var roots: [URL] = []
        if let explicitPath = explicitPathURL(from: text) {
            roots = [explicitPath]
        } else if let namedFolder = standardFolderURL(from: normalized) {
            roots = [namedFolder]
        } else {
            let home = homeDirectoryProvider()
            roots = [
                home.appendingPathComponent("Desktop", isDirectory: true),
                home.appendingPathComponent("Downloads", isDirectory: true),
                home.appendingPathComponent("Documents", isDirectory: true)
            ]
        }

        let extensions = fileExtensions(from: normalized)
        let nameContains = fileNameQuery(from: text)
        guard !roots.isEmpty else { return nil }
        if extensions.isEmpty && (nameContains == nil || nameContains?.isEmpty == true) && standardFolderURL(from: normalized) == nil && explicitPathURL(from: text) == nil {
            return nil
        }

        return FileSearchCriteria(
            rootDirectories: uniqueURLs(roots),
            extensionFilters: Array(Set(extensions)),
            nameContains: nameContains,
            directChildrenOnly: false,
            includeDirectories: false
        )
    }

    private func folderCreationTarget(from text: String) -> (name: String, parentDirectory: URL)? {
        let normalized = normalize(text)
        let parentDirectory = standardFolderURL(from: normalized) ?? homeDirectoryProvider().appendingPathComponent("Desktop", isDirectory: true)

        let patterns = [
            #"创建(?:一个)?名为[“"「]?([^”"」]+)[”"」]?(?:的)?文件夹"#,
            #"新建(?:一个)?(?:叫|名为)?[“"「]?([^”"」]+)[”"」]?(?:的)?文件夹"#,
            #"create (?:a )?folder named [“"']?([^”"']+)[”"']?"#,
            #"new folder [“"']?([^”"']+)[”"']?"#
        ]

        for pattern in patterns {
            if let value = firstCapturedGroup(in: text, pattern: pattern) {
                let name = value
                    .replacingOccurrences(of: #"\s+的$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    return (name, parentDirectory)
                }
            }
        }
        return nil
    }

    private func moveDestination(from text: String) -> (directory: URL, createIfMissing: Bool)? {
        if let explicitPath = explicitPathURL(from: text) {
            return (explicitPath, false)
        }

        let home = homeDirectoryProvider()
        let normalized = normalize(text)

        let patterns: [(String, URL)] = [
            (#"桌面(?:上)?(?:新建|新)?文件夹[“"「]?([^”"」]+)[”"」]?"#, home.appendingPathComponent("Desktop", isDirectory: true)),
            (#"下载(?:文件夹)?(?:里)?(?:新建|新)?文件夹[“"「]?([^”"」]+)[”"」]?"#, home.appendingPathComponent("Downloads", isDirectory: true)),
            (#"文稿(?:文件夹)?(?:里)?(?:新建|新)?文件夹[“"「]?([^”"」]+)[”"」]?"#, home.appendingPathComponent("Documents", isDirectory: true)),
            (#"folder named [“"']?([^”"']+)[”"']? on desktop"#, home.appendingPathComponent("Desktop", isDirectory: true)),
            (#"folder named [“"']?([^”"']+)[”"']? in downloads"#, home.appendingPathComponent("Downloads", isDirectory: true)),
            (#"folder named [“"']?([^”"']+)[”"']? in documents"#, home.appendingPathComponent("Documents", isDirectory: true))
        ]

        for (pattern, root) in patterns {
            if let group = firstCapturedGroup(in: text, pattern: pattern) {
                let name = group.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    return (root.appendingPathComponent(name, isDirectory: true), true)
                }
            }
        }

        if normalized.contains("桌面") || normalized.contains("desktop") {
            return (home.appendingPathComponent("Desktop", isDirectory: true), false)
        }
        if normalized.contains("下载") || normalized.contains("downloads") {
            return (home.appendingPathComponent("Downloads", isDirectory: true), false)
        }
        if normalized.contains("文稿") || normalized.contains("文档") || normalized.contains("documents") {
            return (home.appendingPathComponent("Documents", isDirectory: true), false)
        }

        return nil
    }

    private func standardFolderURL(from normalizedText: String) -> URL? {
        let home = homeDirectoryProvider()
        if containsAny(normalizedText, in: ["desktop", "桌面"]) {
            return home.appendingPathComponent("Desktop", isDirectory: true)
        }
        if containsAny(normalizedText, in: ["downloads", "下载"]) {
            return home.appendingPathComponent("Downloads", isDirectory: true)
        }
        if containsAny(normalizedText, in: ["documents", "document", "文稿", "文档"]) {
            return home.appendingPathComponent("Documents", isDirectory: true)
        }
        return nil
    }

    private func explicitPathURL(from text: String) -> URL? {
        let patterns = [
            #"([~]/[^\n，。,；;]+)"#,
            #"(/[^\n，。,；;]+)"#,
            #"[“"']((?:/|~/)[^”"']+)[”"']"#
        ]

        for pattern in patterns {
            if let raw = firstCapturedGroup(in: text, pattern: pattern) {
                let expanded = (raw as NSString).expandingTildeInPath
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }

    private func preferredBrowserBundleID(from normalizedText: String, sourceBundleID: String?) -> String? {
        if normalizedText.contains("chrome") {
            return "com.google.Chrome"
        }
        if normalizedText.contains("safari") {
            return "com.apple.Safari"
        }
        if normalizedText.contains("arc") {
            return "company.thebrowser.Browser"
        }
        if normalizedText.contains("edge") {
            return "com.microsoft.edgemac"
        }
        if let sourceBundleID,
           AskOperatorSupportedBrowser.bundleIDs.contains(sourceBundleID) {
            return sourceBundleID
        }
        return nil
    }

    private func fileExtensions(from normalizedText: String) -> [String] {
        let knownExtensions = [
            "pdf", "txt", "md", "doc", "docx", "ppt", "pptx", "xls", "xlsx",
            "png", "jpg", "jpeg", "gif", "heic", "zip", "csv", "json", "swift",
            "mp4", "mov", "m4v", "avi", "mkv", "mp3", "wav"
        ]
        return knownExtensions.filter { ext in
            normalizedText.contains(".\(ext)")
                || normalizedText.contains(" \(ext) ")
                || normalizedText.contains("\(ext)文件")
                || normalizedText.contains("\(ext) file")
        }
    }

    private func searchStatusDetail(criteria: FileSearchCriteria, languageCode: String) -> String {
        let folderSummary = criteria.rootDirectories.map(displayPath).joined(separator: "、")
        let extSummary = criteria.extensionFilters.map { ".\($0)" }.joined(separator: " / ")
        let nameSummary = criteria.nameContains?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let itemSummary: String = {
            if criteria.includeDirectories && !extSummary.isEmpty {
                return L10n.format(languageCode: languageCode, zhHans: "%@ 文件和文件夹", en: "%@ files and folders", extSummary)
            }
            if criteria.includeDirectories {
                return L10n.text(languageCode: languageCode, zhHans: "文件夹和文件", en: "folders and files")
            }
            if !extSummary.isEmpty {
                return L10n.format(languageCode: languageCode, zhHans: "%@ 文件", en: "%@ files", extSummary)
            }
            return L10n.text(languageCode: languageCode, zhHans: "文件", en: "files")
        }()

        if criteria.directChildrenOnly {
            if criteria.includeDirectories && !nameSummary.isEmpty {
                return L10n.format(
                    languageCode: languageCode,
                    zhHans: "正在扫描 %@ 根目录里名称包含“%@”的文件夹和文件…",
                    en: "Scanning %@ directly inside the root for folders and files whose names contain “%@”…",
                    folderSummary,
                    nameSummary
                )
            }
            if !extSummary.isEmpty, !nameSummary.isEmpty {
                return L10n.format(
                    languageCode: languageCode,
                    zhHans: "正在扫描 %@ 根目录里名称包含“%@”的 %@ 文件…",
                    en: "Scanning %@ directly inside the root for %@ files whose names contain “%@”…",
                    folderSummary,
                    nameSummary,
                    extSummary
                )
            }
            if criteria.includeDirectories {
                return L10n.format(
                    languageCode: languageCode,
                    zhHans: "正在扫描 %@ 根目录里的文件夹和文件…",
                    en: "Scanning %@ directly inside the root for folders and files…",
                    folderSummary
                )
            }
            if !extSummary.isEmpty {
                return L10n.format(
                    languageCode: languageCode,
                    zhHans: "正在扫描 %@ 根目录里的 %@ 文件…",
                    en: "Scanning %@ directly inside the root for %@ files…",
                    folderSummary,
                    extSummary
                )
            }
            if !nameSummary.isEmpty {
                return L10n.format(
                    languageCode: languageCode,
                    zhHans: "正在扫描 %@ 根目录里名称包含“%@”的文件…",
                    en: "Scanning %@ directly inside the root for files whose names contain “%@”…",
                    folderSummary,
                    nameSummary
                )
            }
            return L10n.format(
                languageCode: languageCode,
                zhHans: "正在扫描 %@ 根目录里的 %@…",
                en: "Scanning %@ directly inside the root for %@…",
                folderSummary
                ,
                itemSummary
            )
        }

        if !extSummary.isEmpty, !nameSummary.isEmpty {
            return L10n.format(
                languageCode: languageCode,
                zhHans: "正在查找 %@ 中名称包含“%@”的 %@ 文件…",
                en: "Searching %@ for %@ files whose names contain “%@”…",
                folderSummary,
                nameSummary,
                extSummary
            )
        }
        if !extSummary.isEmpty {
            return L10n.format(
                languageCode: languageCode,
                zhHans: "正在查找 %@ 中的 %@ 文件…",
                en: "Searching %@ for %@ files…",
                folderSummary,
                extSummary
            )
        }
        if !nameSummary.isEmpty {
            return L10n.format(
                languageCode: languageCode,
                zhHans: "正在查找 %@ 中名称包含“%@”的文件…",
                en: "Searching %@ for files whose names contain “%@”…",
                folderSummary,
                nameSummary
            )
        }
        return L10n.format(languageCode: languageCode, zhHans: "正在查找 %@ 中的文件…", en: "Searching %@ for files…", folderSummary)
    }

    private func movePreparationStatusDetail(
        criteria: FileSearchCriteria,
        destinationDirectory: URL,
        languageCode: String
    ) -> String {
        L10n.format(
            languageCode: languageCode,
            zhHans: "%@，准备移动到 %@…",
            en: "%@, preparing to move them to %@…",
            searchStatusDetail(criteria: criteria, languageCode: languageCode),
            displayPath(destinationDirectory)
        )
    }

    private func cleanupPreparationStatusDetail(
        criteria: FileSearchCriteria,
        destinationDirectory: URL,
        languageCode: String
    ) -> String {
        L10n.format(
            languageCode: languageCode,
            zhHans: "%@，准备新建“%@”并收纳进去…",
            en: "%@, preparing to create “%@” and collect them into it…",
            searchStatusDetail(criteria: criteria, languageCode: languageCode),
            destinationDirectory.lastPathComponent
        )
    }

    private func cleanupSummary(for matches: [URL], languageCode: String) -> String {
        guard !matches.isEmpty else { return "" }
        let extensionBuckets = Dictionary(grouping: matches) { url in
            let ext = url.pathExtension.lowercased()
            return ext.isEmpty ? "_" : ext
        }
        let topBuckets = extensionBuckets
            .map { (ext: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count == $1.count {
                    return $0.ext < $1.ext
                }
                return $0.count > $1.count
            }
            .prefix(3)
        guard !topBuckets.isEmpty else { return "" }
        let summary = topBuckets.map { bucket in
            if bucket.ext == "_" {
                return L10n.format(languageCode: languageCode, zhHans: "%d 个无扩展名文件", en: "%d files without extensions", bucket.count)
            }
            return L10n.format(languageCode: languageCode, zhHans: "%d 个 .%@ 文件", en: "%d .%@ files", bucket.count, bucket.ext)
        }.joined(separator: "，")
        return L10n.format(languageCode: languageCode, zhHans: "（其中包括 %@）", en: " (including %@)", summary)
    }

    private func fileNameQuery(from text: String) -> String? {
        let patterns = [
            #"名字带[“"「]?([^”"」]+)[”"」]?"#,
            #"文件名(?:里)?有[“"「]?([^”"」]+)[”"」]?"#,
            #"search for [“"']?([^”"']+)[”"']?"#,
            #"find [“"']?([^”"']+)[”"']?"#,
            #"查找[“"「]?([^”"」]+)[”"」]?"#,
            #"找一下[“"「]?([^”"」]+)[”"」]?"#
        ]
        for pattern in patterns {
            if let value = firstCapturedGroup(in: text, pattern: pattern) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return quotedPhrase(in: text)
    }

    private func webSearchQuery(from text: String) -> String? {
        let patterns = [
            #"搜索(?:一下)?\s*([^，。；;\n]+)"#,
            #"查一下\s*([^，。；;\n]+)"#,
            #"search for\s+([^\n]+)"#,
            #"search\s+([^\n]+)"#,
            #"look up\s+([^\n]+)"#
        ]
        for pattern in patterns {
            if let value = firstCapturedGroup(in: text, pattern: pattern) {
                let cleaned = stripTrailingOperatorPhrases(from: value)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }
        return nil
    }

    private func currentPageQuery(from text: String) -> String? {
        let patterns = [
            #"当前(?:网页|页面).*(?:找|查|关于)\s*[“"「]?([^”"」\n]+)[”"」]?"#,
            #"这个(?:网页|页面).*(?:找|查|关于)\s*[“"「]?([^”"」\n]+)[”"」]?"#,
            #"current (?:page|tab).*(?:find|about)\s+[“"']?([^”"']+)[”"']?"#,
            #"this (?:page|tab).*(?:find|about)\s+[“"']?([^”"']+)[”"']?"#
        ]
        for pattern in patterns {
            if let value = firstCapturedGroup(in: text, pattern: pattern) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func referencesCurrentPage(_ normalizedText: String) -> Bool {
        containsAny(
            normalizedText,
            in: [
                "current page", "this page", "current tab", "this tab",
                "当前网页", "当前页面", "这个网页", "这个页面", "当前标签页"
            ]
        )
    }

    private func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(location: 0, length: (text as NSString).length)
        return detector?.matches(in: text, options: [], range: range).first?.url
    }

    private func quotedPhrase(in text: String) -> String? {
        let patterns = [
            #"[“"「]([^”"」]+)[”"」]"#,
            #"'([^']+)'"#
        ]
        for pattern in patterns {
            if let value = firstCapturedGroup(in: text, pattern: pattern) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func firstCapturedGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let groupRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[groupRange])
    }

    private func stripTrailingOperatorPhrases(from text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+(并|然后|再|and then).*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsAny(_ haystack: String, in needles: [String]) -> Bool {
        needles.contains(where: { haystack.contains($0) })
    }

    private func isAffirmativeConfirmation(_ text: String) -> Bool {
        containsAny(normalize(text), in: ["确认", "继续", "执行", "好的", "开始", "yes", "confirm", "go ahead", "do it"])
    }

    private func isNegativeConfirmation(_ text: String) -> Bool {
        containsAny(normalize(text), in: ["取消", "不用", "不要", "停止", "算了", "cancel", "stop", "no"])
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var output: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            output.append(url)
        }
        return output
    }

    private func displayPath(_ url: URL) -> String {
        displayPath(url.path)
    }

    private func displayPath(_ path: String) -> String {
        let homePath = homeDirectoryProvider().path
        if path.hasPrefix(homePath) {
            return "~" + String(path.dropFirst(homePath.count))
        }
        return path
    }

    private func makeCard(
        id: String,
        title: String,
        subtitle: String?,
        description: String?,
        action: SkillResultActionType?,
        value: String?
    ) -> SkillResultCard {
        SkillResultCard(
            id: id,
            kind: "operator_action",
            title: title,
            badges: nil,
            subtitle: subtitle,
            description: description,
            action: action.map { SkillResultAction(type: $0, label: actionLabel(for: $0), value: value) },
            priority: .primary,
            isOfficial: true
        )
    }

    private func actionLabel(for action: SkillResultActionType) -> String {
        switch action {
        case .openURL:
            return L10n.text(zhHans: "打开网页", en: "Open Link")
        case .openFile:
            return L10n.text(zhHans: "打开", en: "Open")
        case .revealInFinder:
            return L10n.text(zhHans: "在 Finder 中显示", en: "Reveal in Finder")
        default:
            return L10n.text(zhHans: "查看", en: "View")
        }
    }

    private func decodedJSONObject(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return payload
    }

    private func jsonString(_ value: Any?) -> String? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func firstNonEmptyString(in arguments: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = nonEmptyString(arguments[key]) {
                return value
            }
        }
        return nil
    }

    private func firstBool(in arguments: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = boolValue(from: arguments[key]) {
                return value
            }
        }
        return nil
    }

    private func stringArray(_ value: Any?) -> [String] {
        guard let raw = value as? [String] else { return [] }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func invalidArgumentsResult(
        for toolName: String,
        responseLanguage: String,
        arguments: [String: Any] = [:],
        diagnosticsLogger: DiagnosticsLogger? = nil
    ) -> AskToolExecutionResult {
        if let diagnosticsLogger {
            let keys = arguments.keys.sorted().joined(separator: ",")
            let preview = String(
                (jsonString(arguments)?
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(320)) ?? ""
            )
            diagnosticsLogger.log(
                "ask.operator",
                "invalid_args tool=\(toolName) keys=\(keys) preview=\(preview)"
            )
        }
        let message = L10n.format(
            languageCode: responseLanguage,
            zhHans: "工具 %@ 的参数无效。",
            en: "The arguments for tool %@ were invalid.",
            toolName
        )
        return AskToolExecutionResult(
            ok: false,
            summary: message,
            data: [:],
            cards: [],
            approvalRequest: nil,
            error: message
        )
    }

    private func toolResult(
        from response: AskSessionResponse,
        ok: Bool,
        data: [String: Any],
        error: String?
    ) -> AskToolExecutionResult {
        AskToolExecutionResult(
            ok: ok,
            summary: response.message,
            data: data,
            cards: response.cards,
            approvalRequest: nil,
            error: error
        )
    }

    private func resolvedRootDirectories(from rawValues: [String]?) -> [URL] {
        guard let rawValues, !rawValues.isEmpty else {
            let home = homeDirectoryProvider()
            return [
                home.appendingPathComponent("Desktop", isDirectory: true),
                home.appendingPathComponent("Downloads", isDirectory: true),
                home.appendingPathComponent("Documents", isDirectory: true)
            ]
        }

        let resolved = rawValues.compactMap { resolvedPathURL(from: $0) }
        return uniqueURLs(resolved)
    }

    private func resolvedPathURL(from rawValue: String, relativeTo workspaceRoot: String? = nil) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()
        let home = homeDirectoryProvider()
        if lowercased == "desktop" {
            return home.appendingPathComponent("Desktop", isDirectory: true)
        }
        if lowercased == "downloads" {
            return home.appendingPathComponent("Downloads", isDirectory: true)
        }
        if lowercased == "documents" || lowercased == "document" {
            return home.appendingPathComponent("Documents", isDirectory: true)
        }
        if lowercased.hasPrefix("desktop/") {
            return home.appendingPathComponent("Desktop", isDirectory: true).appendingPathComponent(String(trimmed.dropFirst("desktop/".count)))
        }
        if lowercased.hasPrefix("downloads/") {
            return home.appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(String(trimmed.dropFirst("downloads/".count)))
        }
        if lowercased.hasPrefix("documents/") {
            return home.appendingPathComponent("Documents", isDirectory: true).appendingPathComponent(String(trimmed.dropFirst("documents/".count)))
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        if let workspaceRoot,
           !workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: workspaceRoot, isDirectory: true)
                .appendingPathComponent(trimmed)
                .standardizedFileURL
        }
        return nil
    }

    private func objectSchema(
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    private func stringSchema(_ description: String) -> [String: Any] {
        [
            "type": "string",
            "description": description
        ]
    }

    private func arraySchema(itemType: String, description: String) -> [String: Any] {
        [
            "type": "array",
            "description": description,
            "items": [
                "type": itemType
            ]
        ]
    }

    private func boolSchema(_ description: String) -> [String: Any] {
        [
            "type": "boolean",
            "description": description
        ]
    }
}

private enum AskOperatorSupportFileTerms {
    static let all = [
        "file", "files", "folder", "folders", "directory", "desktop", "finder", "download", "downloads", "document", "documents",
        "文件", "文件夹", "目录", "桌面", "访达", "下载", "文稿", "文档"
    ]
}

private enum AskOperatorSupportWebTerms {
    static let all = [
        "web", "website", "browser", "chrome", "safari", "edge", "arc", "tab", "page", "url", "link", "google",
        "网页", "网站", "浏览器", "标签页", "页面", "链接", "网址", "谷歌"
    ]
}

private enum AskOperatorSupportedBrowser {
    static let bundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac"
    ]
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
