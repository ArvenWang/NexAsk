import AppKit

package final class NexHubRuntime: NSObject {
    package let settings = AppSettings.shared
    package let permissionManager = PermissionManager()
    let selectionMonitor = SelectionMonitor()
    let appUpdateCoordinator = AppUpdateCoordinator()
    lazy var toolbarController = FloatingToolbarController()
    lazy var resultController = ResultPanelController()
    lazy var inlinePromptController = InlineActionPromptController()
    let actionRegistry = ActionRegistry.shared
    let commerceService = CommerceService.shared
    let skillRunner = SkillRunner()
    let skillPresentationCoordinator = SkillPresentationCoordinator()
    let gatewayRuntime = GatewayRuntimeManager.shared
    lazy var settingsWindowShell = SettingsWindowShellController()
    package let diagnosticsLogger = DiagnosticsLogger.shared
    let textEntryCoordinator = TextEntryCoordinator()
    let fileEntryCoordinator = FileEntryCoordinator()
    let screenshotEntryCoordinator = ScreenshotEntryCoordinator()
    let screenshotHotkeyMonitor = GlobalHotkeyMonitor()
    let screenshotFeaturePlatform = ScreenshotFeaturePlatformFactory.current()
    lazy var screenshotSkillBridge = LegacyScreenshotCapabilityShim(
        capabilityFacade: ProductScreenshotCapabilityFacade(
            ocrService: screenshotFeaturePlatform.ocrService,
            settings: settings
        )
    )
    lazy var screenshotSelectionController = ScreenshotSelectionOverlayController(
        exportPipeline: screenshotFeaturePlatform.exportPipeline
    )
    lazy var screenshotScrollPreviewController = ScreenshotScrollPreviewController()
    lazy var skillInvocationCoordinator = SkillInvocationCoordinator(
        toolbarController: toolbarController,
        resultController: resultController,
        actionRegistry: actionRegistry,
        skillRunner: skillRunner,
        screenshotSkillBridge: screenshotSkillBridge,
        settings: settings,
        permissionManager: permissionManager,
        diagnosticsLogger: diagnosticsLogger
    )
    lazy var screenshotScrollCoordinator = ScreenshotScrollCaptureCoordinator(
        engine: screenshotFeaturePlatform.scrollingEngine
    )
    lazy var screenshotSessionCoordinator = ScreenshotSessionCoordinator(
        toolbarController: toolbarController,
        selectionController: screenshotSelectionController,
        previewController: screenshotScrollPreviewController,
        scrollCoordinator: screenshotScrollCoordinator
    )
    lazy var selectionPresentationCoordinator = AppSelectionPresentationCoordinator(
        settings: settings,
        textEntryCoordinator: textEntryCoordinator,
        fileEntryCoordinator: fileEntryCoordinator,
        screenshotEntryCoordinator: screenshotEntryCoordinator,
        toolbarController: toolbarController,
        inlinePromptController: inlinePromptController,
        skillInvocationCoordinator: skillInvocationCoordinator,
        skillPresentationCoordinator: skillPresentationCoordinator,
        screenshotSelectionController: screenshotSelectionController,
        diagnosticsLogger: diagnosticsLogger,
        refreshToolbarSkillLineup: { [unowned self] textSnapshot, fileSnapshot, imageSnapshot in
            self.refreshToolbarSkillLineup(
                textSnapshot: textSnapshot,
                fileSnapshot: fileSnapshot,
                imageSnapshot: imageSnapshot
            )
        },
        makePreviewImageSelectionSnapshot: { [unowned self] selectionRect, anchorPoint, sourceBundleID in
            self.makePreviewImageSelectionSnapshot(
                selectionRect: selectionRect,
                anchorPoint: anchorPoint,
                sourceBundleID: sourceBundleID
            )
        },
        presentScreenshotToolbar: { [unowned self] snapshot in
            self.screenshotSessionCoordinator.presentToolbar(for: snapshot)
        }
    )
    lazy var inputEventCoordinator = AppInputEventCoordinator(
        settings: settings,
        textSelectionCaptureService: TextSelectionCaptureService(selectionMonitor: selectionMonitor),
        toolbarController: toolbarController,
        resultController: resultController,
        inlinePromptController: inlinePromptController,
        screenshotSelectionController: screenshotSelectionController,
        diagnosticsLogger: diagnosticsLogger,
        isFinderFrontmost: { [unowned self] in self.isFinderFrontmost() },
        isScreenshotSelectionActive: { [unowned self] in self.isScreenshotSelectionActive },
        isConversationSelectionActive: { [unowned self] in
            AppProductProfile.current.supportsConversationBoxEntry
                && self.productExperienceController.isSelectionOverlayActive
        },
        dismissConversationSelection: { [unowned self] in
            guard AppProductProfile.current.supportsConversationBoxEntry else { return }
            self.productExperienceController.dismissSelection()
        },
        isProductConversationVisible: { [unowned self] in
            AppProductProfile.current.supportsConversationExperience
                && self.productExperienceController.isConversationVisible
        },
        dismissProductConversation: { [unowned self] in
            guard AppProductProfile.current.supportsConversationExperience else { return }
            self.productExperienceController.dismissConversation()
        },
        cancelScreenshotCaptureFlow: { [unowned self] in
            self.cancelScreenshotCaptureFlow()
        },
        dismissLockedScreenshotSession: { [unowned self] clearImageSnapshot in
            self.dismissLockedScreenshotSession(clearImageSnapshot: clearImageSnapshot)
        },
        dismissTransientWindows: { [unowned self] forcePinned in
            self.dismissTransientWindows(forcePinned: forcePinned)
        },
        clearFileSelectionContext: { [unowned self] in
            self.selectionPresentationCoordinator.clearFileSelectionContext()
        },
        handleNewFileSnapshot: { [unowned self] snapshot in
            self.selectionPresentationCoordinator.handleNewFileSnapshot(snapshot)
            self.productExperienceController.handleFileSelectionSnapshot(snapshot)
        },
        cancelToolbarPresentation: { [unowned self] in
            self.selectionPresentationCoordinator.cancelPendingPresentation()
        }
    )

    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?
    var autoToolbarMenuItem: NSMenuItem?
    var checkUpdatesMenuItem: NSMenuItem?
    var currentSnapshot: SelectionSnapshot? { textEntryCoordinator.currentSnapshot }
    var currentFileSnapshot: FileSelectionSnapshot? { fileEntryCoordinator.currentSnapshot }
    var currentImageSnapshot: ImageSelectionSnapshot? { screenshotEntryCoordinator.currentSnapshot }
    package var isScreenshotSelectionActive = false
    var didPresentRuntimeStartupAlert = false
}
