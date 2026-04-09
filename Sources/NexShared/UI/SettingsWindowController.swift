import AppKit
import ObjectiveC.runtime

enum SettingsTab: Int {
    case general = 0
    case actions = 1
    case shortcuts = 2
    case startup = 3
    case privacy = 4
    case membership = 5
    case ai = 6
    case knowledgeBase = 7
    case learning = 8
    case automation = 9
}

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    fileprivate struct SidebarSymbolSpec {
        let name: String
        let pointSize: CGFloat
        let weight: NSFont.Weight
        let scale: NSImage.SymbolScale
    }

    var onRequestLaunchAtLoginToggle: ((Bool) -> Void)?
    var onRequestTriggerScreenshotCapture: (() -> Void)?

    let settings: AppSettings
    let actionRegistry = ActionRegistry.shared
    private let skillRegistry = SkillRegistry.shared
    private let skillPlatformSnapshotProvider = SkillPlatformSnapshotProvider.shared
    private let packageManager = SkillPackageManager.shared
    private let catalogService = SkillCatalogService.shared
    private let commerceService = CommerceService.shared
    let usageLearningStore = UsageLearningStore.shared
    let routeDiagnosticsStore = RouteDiagnosticsStore.shared
    private let diagnosticsLogger = DiagnosticsLogger.shared
    private let permissionManager = PermissionManager()
    let knowledgeBaseStore = ReplyKnowledgeBaseStore.shared
    private let knowledgeBaseAutoSyncCoordinator = ReplyKnowledgeBaseAutoSyncCoordinator.shared
    private let contentSurface = NSView()
    private let tabView = NSTabView()
    private let actionsScrollView = NSScrollView()
    private let actionsContentViewHost = SettingsFlippedView()
    private let actionsPageStack = NSStackView()
    private let actionsScrollIndicator = SettingsScrollIndicatorView()
    private let membershipScrollView = NSScrollView()
    private let membershipContentHost = SettingsFlippedView()
    private let membershipContentStack = NSStackView()
    private let privacyScrollView = NSScrollView()
    private let privacyContentHost = SettingsFlippedView()
    private let privacyContentStack = NSStackView()
    let learningScrollView = NSScrollView()
    let learningContentHost = SettingsFlippedView()
    let learningContentStack = NSStackView()
    private var actionsBehaviorCard: NSView?
    private var actionsSkillsCard: NSView?
    private let skillDetailBackdropButton = NSButton(title: "", target: nil, action: nil)
    let skillDetailPanel = SettingsSkillDetailPanelView()
    private let skillDetailStack = NSStackView()
    private let skillDetailCloseButton = SettingsSkillDetailIconButton()
    private let skillDetailHeaderView = SettingsSkillDetailHeaderView()
    private let skillDetailOverviewSection = SettingsSkillDetailSectionView(title: L10n.text(zhHans: "概览", en: "Overview"))
    private let skillDetailKnowledgeBaseSection = SettingsSkillDetailSectionView(title: L10n.text(zhHans: "知识库引用", en: "Knowledge Base"))
    private let skillDetailPrimaryButton = SettingsActionButton(title: L10n.text(zhHans: "获取", en: "Get"), target: nil, action: nil)
    private let skillDetailKnowledgeBaseCheckbox = NSButton(checkboxWithTitle: L10n.text(zhHans: "使用知识库", en: "Use knowledge base"), target: nil, action: nil)
    private let skillDetailSecondaryButton = SettingsActionButton(title: L10n.text(zhHans: "启用", en: "Enable"), target: nil, action: nil)
    private let skillDetailTertiaryButton = SettingsActionButton(title: L10n.text(zhHans: "卸载", en: "Uninstall"), target: nil, action: nil)
    private let skillDetailFooterLabel = NSTextField(wrappingLabelWithString: "")
    private var compatibilityAppPicker: CompatibilityAppPickerWindowController?
    private var skillToggleCheckboxes: [String: NSButton] = [:]
    private var sidebarButtons: [SettingsTab: SettingsSidebarButton] = [:]
    private var sidebarItemViews: [SettingsTab: SettingsSidebarItemView] = [:]
    private var selectedSkillDetailID: String?

    private let autoToolbarCheckbox = NSButton(checkboxWithTitle: L10n.text(zhHans: "启用划词入口", en: "Enable text selection"), target: nil, action: nil)
    private let fileSelectionCheckbox = NSButton(checkboxWithTitle: L10n.text(zhHans: "启用文件选择", en: "Enable file selection"), target: nil, action: nil)
    private let screenshotEntryCheckbox = NSButton(checkboxWithTitle: L10n.text(zhHans: "启用截图入口", en: "Enable screenshot entry"), target: nil, action: nil)
    private let conversationBoxEntryCheckbox = NSButton(checkboxWithTitle: L10n.text(zhHans: "启用画框对话入口", en: "Enable conversation box entry"), target: nil, action: nil)
    private let compatibilityAppsButton = SettingsActionButton(title: L10n.text(zhHans: "选择兼容应用", en: "Choose compatible apps"), target: nil, action: nil)
    private let compatibilityAppsLabel = NSTextField(wrappingLabelWithString: "")
    private let screenshotSavePathButton = SettingsActionButton(title: L10n.text(zhHans: "选择保存位置", en: "Choose save location"), target: nil, action: nil)
    private let screenshotSavePathResetButton = SettingsActionButton(title: L10n.text(zhHans: "默认路径", en: "Default path"), target: nil, action: nil)
    private let screenshotSavePathLabel = NSTextField(wrappingLabelWithString: "")
    private let languagePopup = SettingsDropdownButton()
    private let screenshotShortcutLabel = NSTextField(labelWithString: "")
    private let screenshotShortcutHintLabel = NSTextField(wrappingLabelWithString: "")
    private let screenshotShortcutRecordButton = SettingsActionButton(title: L10n.Settings.Shortcuts.recordButton, target: nil, action: nil)
    private let screenshotShortcutResetButton = SettingsActionButton(title: L10n.Settings.Shortcuts.resetButton, target: nil, action: nil)
    private let screenshotShortcutTestButton = SettingsActionButton(title: L10n.Settings.Shortcuts.testButton, target: nil, action: nil)
    private let skillManagementHintLabel = NSTextField(wrappingLabelWithString: L10n.Settings.Skills.managementHint)
    private let skillActionsStack = NSStackView()
    private let skillCatalogFilterStack = NSStackView()
    private var skillCatalogFilterButtons: [SkillListFilter: SettingsFilterPillButton] = [:]
    private let skillCatalogRefreshButton = NSButton(title: L10n.text(zhHans: "刷新目录", en: "Refresh catalog"), target: nil, action: nil)
    private let skillCatalogStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let skillCatalogListStack = NSStackView()

    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: L10n.text(zhHans: "开机自动运行", en: "Launch at login"), target: nil, action: nil)
    private let dismissOutsideCheckbox = NSButton(checkboxWithTitle: L10n.text(zhHans: "点击区域外自动关闭浮条和结果窗", en: "Close toolbar and result panel on outside click"), target: nil, action: nil)
    private let permissionStatusLabel = NSTextField(labelWithString: "")
    private let permissionActionLabel = NSTextField(labelWithString: L10n.Settings.Privacy.sectionHint)
    private let permissionDiagnosticsLabel = NSTextField(wrappingLabelWithString: L10n.text(zhHans: "诊断：暂无", en: "Diagnostics: none"))
    private let permissionListStack = NSStackView()
    private let accessibilityPermissionRow = SettingsPermissionRowView(
        title: L10n.Settings.Privacy.accessibilityTitle,
        description: L10n.Settings.Privacy.accessibilityDescription,
        buttonTitle: L10n.Settings.Privacy.authorize
    )
    private let calendarPermissionRow = SettingsPermissionRowView(
        title: L10n.Settings.Privacy.calendarTitle,
        description: L10n.Settings.Privacy.calendarDescription,
        buttonTitle: L10n.Settings.Privacy.authorize
    )
    private let automationPermissionRow = SettingsPermissionRowView(
        title: L10n.Settings.Privacy.automationTitle,
        description: L10n.Settings.Privacy.automationDescription,
        buttonTitle: L10n.Settings.Privacy.authorize
    )
    private let inputMonitoringPermissionRow = SettingsPermissionRowView(
        title: L10n.Settings.Privacy.inputMonitoringTitle,
        description: L10n.Settings.Privacy.inputMonitoringDescription,
        buttonTitle: L10n.Settings.Privacy.openSettings
    )
    private let screenRecordingPermissionRow = SettingsPermissionRowView(
        title: L10n.Settings.Privacy.screenRecordingTitle,
        description: L10n.Settings.Privacy.screenRecordingDescription,
        buttonTitle: L10n.Settings.Privacy.openSettings
    )
    private let filesAndFoldersPermissionRow = SettingsPermissionRowView(
        title: L10n.Settings.Privacy.filesAndFoldersTitle,
        description: L10n.Settings.Privacy.filesAndFoldersDescription,
        buttonTitle: L10n.Settings.Privacy.openSettings
    )
    private let fullDiskAccessPermissionRow = SettingsPermissionRowView(
        title: L10n.Settings.Privacy.fullDiskAccessTitle,
        description: L10n.Settings.Privacy.fullDiskAccessDescription,
        buttonTitle: L10n.Settings.Privacy.openSettings
    )

    private let providerPopup = SettingsDropdownButton()
    private let modelPopup = SettingsDropdownButton()
    private let apiKeyField = PasteFriendlySecureField(string: "")
    private let aiCurrentConfigLabel = NSTextField(wrappingLabelWithString: "")
    private let aiDraftStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let aiRuntimeStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let aiValidateButton = SettingsActionButton(title: L10n.Settings.AI.testConnection, target: nil, action: nil)
    private let knowledgeBaseDescriptionLabel = NSTextField(wrappingLabelWithString: L10n.text(zhHans: "把常用网页、FAQ、产品资料、服务说明和本地文件采集进来。知识库会统一完成采集、索引、检索和后续 Skill 复用。", en: "Collect common web pages, FAQs, product notes, service docs, and local files here. The knowledge base handles ingestion, indexing, retrieval, and future Skill reuse in one place."))
    let knowledgeBaseSearchField = PasteFriendlyTextField(frame: .zero)
    private let knowledgeBaseFormatLabel = NSTextField(wrappingLabelWithString: "")
    private let knowledgeBaseStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let knowledgeBaseAddButton = SettingsActionButton(title: L10n.Settings.KnowledgeBase.addFilesButton, target: nil, action: nil)
    private let knowledgeBaseManageButton = SettingsActionButton(title: L10n.text(zhHans: "管理", en: "Manage"), target: nil, action: nil)
    private let knowledgeBaseSourceFilterStack = NSStackView()
    private var knowledgeBaseSourceFilterButtons: [KnowledgeBaseSourceTab: SettingsFilterPillButton] = [:]
    private let knowledgeBaseBindNotionButton = SettingsActionButton(title: L10n.text(zhHans: "绑定", en: "Connect"), target: nil, action: nil)
    private let knowledgeBaseNotionModuleView = NSView()
    private let knowledgeBaseNotionTokenField = PasteFriendlyTextField(frame: .zero)
    private let knowledgeBaseNotionHintLabel = NSTextField(wrappingLabelWithString: L10n.text(zhHans: "粘贴 Notion Integration Token 后点击绑定。首次绑定会立即同步最近共享给当前 Integration 的页面，后续继续走后台增量同步。", en: "Paste the Notion integration token and click Connect. The first connection immediately syncs recently shared pages for this integration, and later updates continue via background incremental sync."))
    private var knowledgeBaseNotionDefaultHintText: String {
        L10n.text(
            zhHans: "粘贴 Notion Integration Token 后点击绑定。首次绑定会立即同步最近共享给当前 Integration 的页面，后续继续走后台增量同步。",
            en: "Paste the Notion integration token and click Connect. The first connection immediately syncs recently shared pages for this integration, and later updates continue via background incremental sync."
        )
    }
    private let knowledgeBaseScrollView = NSScrollView()
    private let knowledgeBaseContentViewHost = SettingsFlippedView()
    private let knowledgeBaseListStack = NSStackView()
    private let knowledgeBaseEmptyLabel = NSTextField(wrappingLabelWithString: "")
    private var knowledgeBaseStatusTopConstraint: NSLayoutConstraint?
    private var knowledgeBaseScrollTopToStatusConstraint: NSLayoutConstraint?
    private var knowledgeBaseScrollTopToSearchConstraint: NSLayoutConstraint?
    private var knowledgeBaseEmptyTopToStatusConstraint: NSLayoutConstraint?
    private var knowledgeBaseEmptyTopToSearchConstraint: NSLayoutConstraint?
    var isKnowledgeBaseManaging = false
    var selectedKnowledgeBaseEntryIDs: Set<String> = []
    private var selectedKnowledgeBaseDetailEntryID: String?
    private var selectedKnowledgeBaseDetailEntry: ReplyKnowledgeBaseEntry?
    private var selectedKnowledgeBaseDetailSnapshot: KnowledgeBaseSnapshot?
    var replyKnowledgeBaseWindowController: ReplyKnowledgeBaseWindowController?
    private let entitlementSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let founderOfferLabel = NSTextField(wrappingLabelWithString: "")
    private let inviteCodeField = PasteFriendlyTextField(string: "")
    private let inviteRedeemButton = SettingsActionButton(title: L10n.Settings.Membership.redeemInvite, target: nil, action: nil)
    private let inviteResultLabel = NSTextField(wrappingLabelWithString: "")
    private let subscriptionPlanPopup = SettingsDropdownButton()
    private let subscriptionStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let commerceHistoryContentLabel = NSTextField(wrappingLabelWithString: "")
    private let membershipInviteLabel = NSTextField(labelWithString: L10n.Settings.Membership.inviteCode)
    private let membershipInviteRow = NSStackView()
    private let membershipPlanRow = NSStackView()
    private let membershipActionRow = NSStackView()
    private let membershipHistoryLabel = NSTextField(labelWithString: L10n.Settings.Membership.historyLabel)
    private let membershipHistoryBlock = NSView()
    private let activateSubscriptionButton = SettingsActionButton(title: L10n.Settings.Membership.purchaseComing, target: nil, action: nil)
    private let refreshEntitlementButton = SettingsActionButton(title: L10n.Settings.Membership.refreshEntitlement, target: nil, action: nil)
    private let aiValidationLabel = NSTextField(labelWithString: "")
    let statisticsMetricStripView = SettingsStatisticsMetricStripView()
    let statisticsSkillChartView = SettingsStatisticsBarSectionView(title: L10n.text(zhHans: "最近最常点的技能", en: "Skills You Use Most"))
    let statisticsAppChartView = SettingsStatisticsBarSectionView(title: L10n.text(zhHans: "最近最常出现的 App", en: "Apps You Use Most"))
    let statisticsCategoryChartView = SettingsStatisticsBarSectionView(title: L10n.text(zhHans: "最近常见内容类型", en: "Common Content Types"))
    let statisticsTrendSectionView = SettingsStatisticsTrendSectionView()
    let statisticsRouteSnapshotView = SettingsStatisticsRouteSnapshotView()
    private lazy var automationPageView = AppProductFeatureRegistry.makeAutomationPageView()
    lazy var settingsLearningSnapshotFormatter = SettingsLearningSnapshotFormatter(
        resolveSkillTitle: { [weak self] skillID in
            self?.actionRegistry.definition(forSkillID: skillID)?.title
        },
        resolveBundleName: { [weak self] bundleID in
            self?.displayName(forBundleID: bundleID) ?? bundleID ?? L10n.text(zhHans: "未知应用", en: "Unknown App")
        },
        resolveCategoryName: { [weak self] category in
            self?.friendlyCategoryName(category) ?? category
        },
        resolveConfidenceText: { [weak self] confidence in
            self?.friendlyConfidenceText(confidence) ?? String(format: "%.2f", confidence)
        },
        resolveRecommendationStyleText: { [weak self] style in
            self?.friendlyRecommendationStyleText(style) ?? style.rawValue
        }
    )
    lazy var aiConfigurationCoordinator = SettingsAIConfigurationCoordinator(
        settings: settings,
        aiConfigurationService: AIConfigurationService.shared,
        providerPopup: providerPopup,
        modelPopup: modelPopup,
        apiKeyField: apiKeyField,
        aiCurrentConfigLabel: aiCurrentConfigLabel,
        aiDraftStatusLabel: aiDraftStatusLabel,
        aiRuntimeStatusLabel: aiRuntimeStatusLabel,
        aiValidationLabel: aiValidationLabel
    )
    lazy var knowledgeBaseCoordinator = SettingsKnowledgeBaseCoordinator(
        knowledgeBaseStore: knowledgeBaseStore,
        updateStatusMessage: { [weak self] message in
            self?.updateKnowledgeBaseStatusMessage(message)
        },
        updateSourceButtons: { [weak self] counts, selectedTab in
            guard let self else { return }
            for tab in KnowledgeBaseSourceTab.availableTabs {
                self.knowledgeBaseSourceFilterButtons[tab]?.title = "\(tab.title) \(counts[tab, default: 0])"
                self.knowledgeBaseSourceFilterButtons[tab]?.setSelected(tab == selectedTab)
            }
            for (tab, button) in self.knowledgeBaseSourceFilterButtons where !KnowledgeBaseSourceTab.availableTabs.contains(tab) {
                button.isHidden = true
            }
            self.updateKnowledgeBaseNotionBindingUI()
        },
        onEntriesChanged: { [weak self] in
            self?.renderKnowledgeBaseRows()
        }
    )
    private lazy var knowledgeBaseListCoordinator = SettingsKnowledgeBaseListCoordinator(
        knowledgeBaseStore: knowledgeBaseStore,
        diagnosticsLogger: diagnosticsLogger,
        scrollView: knowledgeBaseScrollView,
        hostView: knowledgeBaseContentViewHost,
        listStack: knowledgeBaseListStack,
        emptyLabel: knowledgeBaseEmptyLabel,
        setStatusMessage: { [weak self] message in
            self?.updateKnowledgeBaseStatusMessage(message)
        },
        makeRow: { [weak self] entry, onOpen, onRefresh, onReindex, onToggleEnabled, onDelete in
            guard let self else { return NSView() }
            let row = KnowledgeBaseRowView(
                entry: entry,
                isManaging: self.isKnowledgeBaseManaging,
                isSelected: self.selectedKnowledgeBaseEntryIDs.contains(entry.id),
                isFocused: self.selectedKnowledgeBaseDetailEntryID == entry.id
            )
            row.onOpen = onOpen
            row.onRefresh = onRefresh
            row.onReindex = onReindex
            row.onToggleEnabled = onToggleEnabled
            row.onDelete = onDelete
            row.onInspect = { [weak self] entryID in
                self?.showKnowledgeBaseDetail(for: entryID)
            }
            row.onSelectionChanged = { [weak self] entryID, isSelected in
                self?.updateKnowledgeBaseSelection(id: entryID, isSelected: isSelected)
            }
            return row
        },
        onReloadRequested: { [weak self] status in
            self?.reloadKnowledgeBaseEntries(status: status)
        },
        onLayoutRefreshRequested: { [weak self] in
            self?.refreshKnowledgeBaseScrollLayout()
        }
    )
    lazy var membershipPresenter = SettingsMembershipPresenter(
        settings: settings,
        commerceService: commerceService,
        membershipContentStack: membershipContentStack,
        entitlementSummaryLabel: entitlementSummaryLabel,
        founderOfferLabel: founderOfferLabel,
        inviteCodeField: inviteCodeField,
        inviteResultLabel: inviteResultLabel,
        subscriptionPlanPopup: subscriptionPlanPopup,
        subscriptionStatusLabel: subscriptionStatusLabel,
        commerceHistoryContentLabel: commerceHistoryContentLabel,
        membershipActionRow: membershipActionRow,
        membershipHistoryBlock: membershipHistoryBlock,
        membershipHistoryLabel: membershipHistoryLabel,
        membershipInviteLabel: membershipInviteLabel,
        membershipInviteRow: membershipInviteRow,
        membershipPlanRow: membershipPlanRow,
        activateSubscriptionButton: activateSubscriptionButton,
        refreshEntitlementButton: refreshEntitlementButton,
        refreshLayout: { [weak self] in
            guard let self else { return }
            self.refreshScrollableTabLayout(
                scrollView: self.membershipScrollView,
                hostView: self.membershipContentHost,
                contentView: self.membershipContentStack
            )
        }
    )
    private lazy var skillsTabCoordinator = SettingsSkillsTabCoordinator(snapshotProvider: skillPlatformSnapshotProvider)
    lazy var aiTabCoordinator = SettingsAITabCoordinator(snapshotProvider: skillPlatformSnapshotProvider)
    lazy var membershipTabCoordinator = SettingsMembershipTabCoordinator(snapshotProvider: skillPlatformSnapshotProvider)
    lazy var screenshotShortcutCoordinator = SettingsScreenshotShortcutCoordinator(
        settings: settings,
        shortcutLabel: screenshotShortcutLabel,
        hintLabel: screenshotShortcutHintLabel,
        recordButton: screenshotShortcutRecordButton
    )
    lazy var permissionCoordinator = SettingsPermissionCoordinator(
        settings: settings,
        permissionManager: permissionManager,
        statusLabel: permissionStatusLabel,
        actionLabel: permissionActionLabel,
        diagnosticsLabel: permissionDiagnosticsLabel,
        accessibilityRow: accessibilityPermissionRow,
        calendarRow: calendarPermissionRow,
        automationRow: automationPermissionRow,
        inputMonitoringRow: inputMonitoringPermissionRow,
        screenRecordingRow: screenRecordingPermissionRow,
        filesAndFoldersRow: filesAndFoldersPermissionRow,
        fullDiskAccessRow: fullDiskAccessPermissionRow,
        activateApp: { [weak self] in
            self?.activateForPermissionPrompt()
        }
    )
    lazy var knowledgeBaseImportCoordinator = SettingsKnowledgeBaseImportCoordinator(
        knowledgeBaseStore: knowledgeBaseStore,
        addButton: knowledgeBaseAddButton,
        statusLabel: knowledgeBaseStatusLabel,
        reloadEntries: { [weak self] status in
            self?.reloadKnowledgeBaseEntries(status: status)
        }
    )
    private var isLoadingSettings = false
    private var currentSkillCatalogFilter: SkillListFilter = .all
    private var currentSelectedTab: SettingsTab = .general

    init(settings: AppSettings = .shared) {
        self.settings = settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppBrand.displayName) Settings"
        window.center()
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.contentMaxSize = NSSize(width: 860, height: 560)

        super.init(window: window)

        configureWindow()
        automationPageView.onScrollStateChanged = { [weak self] showTemporarily in
            guard let self, self.currentSelectedTab == .automation else { return }
            self.refreshScrollIndicatorForCurrentTab(showTemporarily: showTemporarily)
        }
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCommerceStateChanged),
            name: .commerceStateDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSkillRegistryReloaded),
            name: .skillRegistryDidReload,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKnowledgeBaseChanged),
            name: .knowledgeBaseDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKnowledgeBaseAutoSyncChanged),
            name: .knowledgeBaseAutoSyncDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGatewayRuntimeStatusChanged),
            name: .gatewayRuntimeDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSecureStorageFailure(_:)),
            name: .appSettingsSecureStorageDidFail,
            object: nil
        )
        loadFromSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private var productProfile: AppProductProfile {
        AppProductProfile.current
    }

    private var productDisplayName: String {
        AppBrand.displayName
    }

    private func settingsAccessibilityLabel(_ suffix: String) -> String {
        "\(productDisplayName) Settings \(suffix)"
    }

    private func settingsAccessibilityIdentifier(_ suffix: String) -> String {
        AppBrand.accessibilityIdentifier("settings.\(suffix)")
    }

    private func privacyPermissionRows() -> [SettingsPermissionRowView] {
        var rows: [SettingsPermissionRowView] = []
        if productProfile.requiresAccessibilityPermission {
            rows.append(accessibilityPermissionRow)
        }
        if productProfile.requiresCalendarPermission {
            rows.append(calendarPermissionRow)
        }
        if productProfile.requiresAutomationPermission {
            rows.append(automationPermissionRow)
        }
        if productProfile.requiresInputMonitoringPermission {
            rows.append(inputMonitoringPermissionRow)
        }
        if productProfile.requiresScreenRecordingPermission {
            rows.append(screenRecordingPermissionRow)
        }
        if productProfile.requiresFilesAndFoldersPermission {
            rows.append(filesAndFoldersPermissionRow)
        }
        if productProfile.requiresFullDiskAccessPermission {
            rows.append(fullDiskAccessPermissionRow)
        }
        return rows
    }

    private var availableSidebarTabs: [SettingsTab] {
        [SettingsTab.general, .actions, .automation, .knowledgeBase, .shortcuts, .privacy, .membership, .learning]
            .filter(isTabAvailable)
    }

    private func isTabAvailable(_ tab: SettingsTab) -> Bool {
        switch tab {
        case .general, .privacy, .membership, .knowledgeBase:
            return true
        case .actions:
            return productProfile.supportsSkillLibrary
        case .shortcuts:
            return productProfile.supportsShortcutsTab
        case .learning:
            return productProfile.supportsLearningTab
        case .automation:
            return productProfile.supportsAutomationTab
        case .startup, .ai:
            return false
        }
    }

    private func resolvedAvailableTab(_ tab: SettingsTab) -> SettingsTab {
        let resolvedTab: SettingsTab = (tab == .startup || tab == .ai) ? .general : tab
        if isTabAvailable(resolvedTab) {
            return resolvedTab
        }
        return availableSidebarTabs.first ?? .general
    }

    private func generalPageSubtitleText() -> String {
        productProfile.settingsGeneralSubtitleText
    }

    private func sidebarTitle(for tab: SettingsTab) -> String {
        switch tab {
        case .general: return L10n.Settings.Tabs.general
        case .actions: return L10n.Settings.Tabs.skills
        case .shortcuts: return L10n.text(zhHans: "快捷键", en: "Shortcuts")
        case .startup: return L10n.text(zhHans: "启动", en: "Startup")
        case .privacy: return L10n.Settings.Tabs.privacy
        case .membership: return L10n.Settings.Tabs.membership
        case .ai: return "AI"
        case .knowledgeBase: return L10n.Settings.Tabs.knowledgeBase
        case .learning: return L10n.Settings.Tabs.stats
        case .automation: return L10n.text(zhHans: "自动化", en: "Automation")
        }
    }

    private func sidebarSymbolSpec(for tab: SettingsTab) -> SidebarSymbolSpec {
        switch tab {
        case .general:
            return SidebarSymbolSpec(name: "slider.horizontal.3", pointSize: 18, weight: .medium, scale: .medium)
        case .actions:
            return SidebarSymbolSpec(name: "sparkles", pointSize: 20, weight: .medium, scale: .medium)
        case .shortcuts:
            return SidebarSymbolSpec(name: "command", pointSize: 19, weight: .medium, scale: .medium)
        case .startup:
            return SidebarSymbolSpec(name: "power", pointSize: 18, weight: .medium, scale: .medium)
        case .privacy:
            return SidebarSymbolSpec(name: "lock.shield", pointSize: 18, weight: .medium, scale: .medium)
        case .membership:
            return SidebarSymbolSpec(name: "person.crop.circle.badge.checkmark", pointSize: 16, weight: .medium, scale: .medium)
        case .ai:
            return SidebarSymbolSpec(name: "cpu", pointSize: 17, weight: .medium, scale: .medium)
        case .knowledgeBase:
            return SidebarSymbolSpec(name: "books.vertical", pointSize: 16, weight: .medium, scale: .medium)
        case .learning:
            return SidebarSymbolSpec(name: "chart.xyaxis.line", pointSize: 19, weight: .medium, scale: .medium)
        case .automation:
            return SidebarSymbolSpec(name: "clock.arrow.circlepath", pointSize: 18, weight: .medium, scale: .medium)
        }
    }

    private func smokeIdentifier(for tab: SettingsTab) -> String {
        switch tab {
        case .general:
            return settingsAccessibilityIdentifier("tab.general")
        case .actions:
            return settingsAccessibilityIdentifier("tab.skills")
        case .shortcuts:
            return settingsAccessibilityIdentifier("tab.shortcuts")
        case .startup:
            return settingsAccessibilityIdentifier("tab.startup")
        case .privacy:
            return settingsAccessibilityIdentifier("tab.privacy")
        case .membership:
            return settingsAccessibilityIdentifier("tab.membership")
        case .ai:
            return settingsAccessibilityIdentifier("tab.ai")
        case .knowledgeBase:
            return settingsAccessibilityIdentifier("tab.knowledge-base")
        case .learning:
            return settingsAccessibilityIdentifier("tab.stats")
        case .automation:
            return settingsAccessibilityIdentifier("tab.automation")
        }
    }

    func show(tab: SettingsTab) {
        let resolvedTab = resolvedAvailableTab(tab)
        _ = NSApp.setActivationPolicy(.regular)
        loadFromSettings()
        selectSidebarTab(resolvedTab)
        showWindow(nil)
        window?.deminiaturize(nil)
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        resetScrollPositionIfNeeded(for: resolvedTab)
        refreshScrollIndicatorForCurrentTab(showTemporarily: false)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        setKnowledgeBaseManaging(false)
        _ = NSApp.setActivationPolicy(.accessory)
    }

    @objc private func handleSidebarSelection(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let value = Int(raw),
              let tab = SettingsTab(rawValue: value) else { return }
        selectSidebarTab(tab)
    }

    private func selectSidebarTab(_ tab: SettingsTab) {
        let resolvedTab = resolvedAvailableTab(tab)
        if currentSelectedTab == .knowledgeBase, resolvedTab != .knowledgeBase {
            setKnowledgeBaseManaging(false)
        }
        currentSelectedTab = resolvedTab
        tabView.selectTabViewItem(withIdentifier: resolvedTab.rawValue)
        for (candidate, button) in sidebarButtons {
            button.setSelected(candidate == resolvedTab)
        }
        for (candidate, itemView) in sidebarItemViews {
            itemView.setSelected(candidate == resolvedTab)
        }
        resetScrollPositionIfNeeded(for: resolvedTab)
        refreshScrollIndicatorForCurrentTab(showTemporarily: false)
        if resolvedTab == .actions {
            refreshSkillCatalogAutomatically()
        } else if resolvedTab == .automation {
            automationPageView.reloadData()
        }
    }

    private func configureWindow() {
        guard let contentView = window?.contentView else { return }
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        window?.isMovableByWindowBackground = true

        let root = NSView(frame: contentView.bounds)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier(settingsAccessibilityIdentifier("window"))
        root.setAccessibilityLabel("\(AppBrand.displayName) Settings Window")
        contentView.addSubview(root)

        let backdrop = PanelSurfaceView(style: .toolbar)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.tintOpacityOverride = 0.92
        root.addSubview(backdrop)

        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        contentSurface.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyPageSurface(to: contentSurface)

        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .noTabsNoBorder
        contentSurface.addSubview(tabView)
        contentSurface.addSubview(actionsScrollIndicator)
        actionsScrollIndicator.onScrollRequested = { [weak self] targetOffset in
            self?.handleSharedScrollIndicatorRequested(targetOffset)
        }

        let sidebarStack = NSStackView()
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .width
        sidebarStack.spacing = DesignTokens.Settings.Page.sidebarStackSpacing

        sidebar.addSubview(sidebarStack)

        for tab in availableSidebarTabs {
            let button = SettingsSidebarButton(title: sidebarTitle(for: tab), symbol: sidebarSymbolSpec(for: tab))
            button.target = self
            button.action = #selector(handleSidebarSelection(_:))
            button.identifier = NSUserInterfaceItemIdentifier("\(tab.rawValue)")
            button.setAccessibilityIdentifier(smokeIdentifier(for: tab))
            button.setAccessibilityLabel(settingsAccessibilityLabel(sidebarTitle(for: tab)))
            sidebarButtons[tab] = button
            let itemView = SettingsSidebarItemView(button: button)
            sidebarItemViews[tab] = itemView
            sidebarStack.addArrangedSubview(itemView)
            itemView.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        }

        backdrop.addSubview(sidebar)
        backdrop.addSubview(contentSurface)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            sidebar.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: DesignTokens.Settings.Page.sidebarLeadingInset),
            sidebar.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: DesignTokens.Settings.Page.sidebarTopInset),
            sidebar.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -DesignTokens.Settings.Page.sidebarBottomInset),
            sidebar.widthAnchor.constraint(equalToConstant: 196),

            contentSurface.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: DesignTokens.Settings.Page.surfaceGap),
            contentSurface.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -DesignTokens.Settings.Page.surfaceInset),
            contentSurface.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: DesignTokens.Settings.Page.surfaceInset),
            contentSurface.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -DesignTokens.Settings.Page.surfaceInset),

            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarStack.bottomAnchor.constraint(lessThanOrEqualTo: sidebar.bottomAnchor),

            tabView.leadingAnchor.constraint(equalTo: contentSurface.leadingAnchor, constant: DesignTokens.Settings.Page.surfaceInset),
            tabView.trailingAnchor.constraint(equalTo: contentSurface.trailingAnchor, constant: -DesignTokens.Settings.Page.surfaceInset),
            tabView.topAnchor.constraint(equalTo: contentSurface.topAnchor, constant: DesignTokens.Settings.Page.surfaceInset),
            tabView.bottomAnchor.constraint(equalTo: contentSurface.bottomAnchor, constant: -DesignTokens.Settings.Page.surfaceInset),

            actionsScrollIndicator.trailingAnchor.constraint(equalTo: contentSurface.trailingAnchor, constant: -DesignTokens.Settings.Page.indicatorTrailingInset),
            actionsScrollIndicator.topAnchor.constraint(equalTo: tabView.topAnchor, constant: DesignTokens.Settings.Page.indicatorVerticalInset),
            actionsScrollIndicator.bottomAnchor.constraint(equalTo: tabView.bottomAnchor, constant: -DesignTokens.Settings.Page.indicatorVerticalInset),
            actionsScrollIndicator.widthAnchor.constraint(equalToConstant: DesignTokens.ScrollIndicator.width)
        ])

        configureSkillDetailOverlay(in: backdrop)

        var tabItems: [NSTabViewItem] = [makeGeneralTab()]
        if productProfile.supportsSkillLibrary {
            tabItems.append(makeActionsTab())
        }
        if productProfile.supportsAutomationTab {
            tabItems.append(makeAutomationTab())
        }
        if productProfile.supportsShortcutsTab {
            tabItems.append(makeShortcutsTab())
        }
        tabItems.append(makePrivacyTab())
        tabItems.append(makeMembershipTab())
        tabItems.append(makeKnowledgeBaseTab())
        if productProfile.supportsLearningTab {
            tabItems.append(makeLearningTab())
        }
        tabItems.forEach { tabView.addTabViewItem($0) }

        selectSidebarTab(resolvedAvailableTab(.general))
    }

    private func makeGeneralTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: SettingsTab.general.rawValue)
        item.label = L10n.Settings.Tabs.general

        let view = SettingsFlippedView()
        view.translatesAutoresizingMaskIntoConstraints = true

        autoToolbarCheckbox.target = self
        autoToolbarCheckbox.action = #selector(handleToggleAutoToolbar)
        fileSelectionCheckbox.target = self
        fileSelectionCheckbox.action = #selector(handleToggleFileSelection)
        screenshotEntryCheckbox.target = self
        screenshotEntryCheckbox.action = #selector(handleToggleScreenshotEntry)
        conversationBoxEntryCheckbox.target = self
        conversationBoxEntryCheckbox.action = #selector(handleToggleConversationBoxEntry)

        compatibilityAppsButton.target = self
        compatibilityAppsButton.action = #selector(handleConfigureCompatibilityApps)
        SettingsControlStyle.applyActionButton(compatibilityAppsButton)
        compatibilityAppsLabel.textColor = DesignTokens.Color.textSecondary
        compatibilityAppsLabel.lineBreakMode = .byWordWrapping
        compatibilityAppsLabel.maximumNumberOfLines = 0
        compatibilityAppsLabel.usesSingleLineMode = false
        compatibilityAppsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        compatibilityAppsLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        screenshotSavePathButton.target = self
        screenshotSavePathButton.action = #selector(handleSelectScreenshotSaveDirectory)
        SettingsControlStyle.applyActionButton(screenshotSavePathButton)
        screenshotSavePathResetButton.target = self
        screenshotSavePathResetButton.action = #selector(handleResetScreenshotSaveDirectory)
        SettingsControlStyle.applyActionButton(screenshotSavePathResetButton)
        screenshotSavePathLabel.textColor = DesignTokens.Color.textSecondary
        screenshotSavePathLabel.lineBreakMode = .byTruncatingMiddle
        screenshotSavePathLabel.maximumNumberOfLines = 2
        screenshotSavePathLabel.usesSingleLineMode = false

        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: AppLanguage.allCases.map(\.settingsDisplayName))
        SettingsControlStyle.applyPopupButton(languagePopup)
        languagePopup.target = self
        languagePopup.action = #selector(handleLanguageChanged)

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(handleLaunchAtLoginToggle)
        launchAtLoginCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let launchTip = NSTextField(wrappingLabelWithString: L10n.text(zhHans: "通过签名后的 .app 包运行时，才能稳定启用开机自动运行。", en: "Launch at login works reliably only when you run the signed .app bundle."))
        launchTip.textColor = DesignTokens.Color.textSecondary
        launchTip.maximumNumberOfLines = 0
        launchTip.translatesAutoresizingMaskIntoConstraints = false

        let pageTitle = NSTextField(labelWithString: L10n.text(zhHans: "通用", en: "General"))
        pageTitle.font = DesignTokens.Typography.settingsPageTitle
        pageTitle.textColor = DesignTokens.Color.textPrimary
        pageTitle.translatesAutoresizingMaskIntoConstraints = false

        let pageSubtitle = NSTextField(wrappingLabelWithString: generalPageSubtitleText())
        pageSubtitle.font = DesignTokens.Typography.settingsPageSubtitle
        pageSubtitle.textColor = DesignTokens.Color.textSecondary
        pageSubtitle.maximumNumberOfLines = 0
        pageSubtitle.translatesAutoresizingMaskIntoConstraints = false

        let languageHint = NSTextField(wrappingLabelWithString: L10n.format(
            zhHans: "语言切换会在重新打开设置窗口或重启 %@ 后完整生效。",
            en: "Language changes fully apply after reopening Settings or restarting %@.",
            productDisplayName
        ))
        languageHint.font = DesignTokens.Typography.settingsSectionBody
        languageHint.textColor = DesignTokens.Color.textSecondary
        languageHint.maximumNumberOfLines = 0
        languageHint.translatesAutoresizingMaskIntoConstraints = false

        var contentViews: [NSView] = [
            makeSettingsButtonRow(title: L10n.text(zhHans: "语言", en: "Language"), button: languagePopup),
            languageHint
        ]
        let entryCheckboxes = [
            productProfile.supportsTextSelectionEntry ? autoToolbarCheckbox : nil,
            productProfile.supportsFileSelectionEntry ? fileSelectionCheckbox : nil,
            productProfile.supportsScreenshotEntry ? screenshotEntryCheckbox : nil,
            productProfile.supportsConversationBoxEntry ? conversationBoxEntryCheckbox : nil
        ].compactMap { $0 }
        if !entryCheckboxes.isEmpty {
            contentViews.append(makeSettingsCheckboxLine(entryCheckboxes))
        }
        contentViews.append(makeSettingsCheckboxRow(launchAtLoginCheckbox))
        contentViews.append(launchTip)
        if productProfile.supportsTextSelectionEntry || productProfile.supportsFileSelectionEntry {
            contentViews.append(makeSettingsButtonRow(title: L10n.text(zhHans: "兼容应用", en: "Compatible apps"), button: compatibilityAppsButton))
            contentViews.append(compatibilityAppsLabel)
        }
        if productProfile.supportsScreenshotEntry {
            contentViews.append(makeScreenshotSavePathRow())
            contentViews.append(screenshotSavePathLabel)
        }

        let contentBlock = makeSettingsPlainSection(contentViews: contentViews)

        let stack = NSStackView(views: [pageTitle, pageSubtitle, contentBlock])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Settings.Page.stackSpacing
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Settings.Page.contentTrailingInset),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: DesignTokens.Settings.Page.titleTopInset)
        ])

        [pageTitle, pageSubtitle, contentBlock].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        item.view = view
        return item
    }

    private func makeActionsTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: SettingsTab.actions.rawValue)
        item.label = L10n.Settings.Tabs.skills

        let view = SettingsFlippedView()
        view.translatesAutoresizingMaskIntoConstraints = true

        actionsScrollView.translatesAutoresizingMaskIntoConstraints = false
        actionsScrollView.drawsBackground = false
        actionsScrollView.borderType = .noBorder
        actionsScrollView.hasVerticalScroller = false
        actionsScrollView.hasHorizontalScroller = false
        actionsScrollView.contentView.postsBoundsChangedNotifications = true

        actionsContentViewHost.translatesAutoresizingMaskIntoConstraints = true

        skillCatalogFilterStack.translatesAutoresizingMaskIntoConstraints = false
        skillCatalogFilterStack.orientation = .horizontal
        skillCatalogFilterStack.alignment = .centerY
        skillCatalogFilterStack.spacing = DesignTokens.Settings.Page.filterRowSpacing
        if skillCatalogFilterStack.arrangedSubviews.isEmpty {
            SkillListFilter.allCases.forEach { filter in
                let button = SettingsFilterPillButton(title: filter.title)
                button.target = self
                button.action = #selector(handleSkillCatalogFilterTap(_:))
                button.identifier = NSUserInterfaceItemIdentifier("\(filter.rawValue)")
                skillCatalogFilterButtons[filter] = button
                skillCatalogFilterStack.addArrangedSubview(button)
            }
        }

        skillCatalogRefreshButton.isHidden = true

        skillCatalogStatusLabel.textColor = DesignTokens.Color.textSecondary
        skillCatalogStatusLabel.maximumNumberOfLines = 0
        skillCatalogStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        skillCatalogStatusLabel.isHidden = true

        skillCatalogListStack.orientation = .vertical
        skillCatalogListStack.spacing = DesignTokens.Settings.Page.skillListSpacing
        skillCatalogListStack.alignment = .leading
        skillCatalogListStack.translatesAutoresizingMaskIntoConstraints = false

        let pageTitle = NSTextField(labelWithString: L10n.Settings.Skills.title)
        pageTitle.font = DesignTokens.Typography.settingsPageTitle
        pageTitle.textColor = DesignTokens.Color.textPrimary
        pageTitle.translatesAutoresizingMaskIntoConstraints = false

        let pageSubtitle = NSTextField(wrappingLabelWithString: L10n.Settings.Skills.subtitle)
        pageSubtitle.font = DesignTokens.Typography.settingsPageSubtitle
        pageSubtitle.textColor = DesignTokens.Color.textSecondary
        pageSubtitle.maximumNumberOfLines = 0
        pageSubtitle.translatesAutoresizingMaskIntoConstraints = false

        let skillsSection = makeSettingsPlainSection(
            contentViews: [
                makeSkillCatalogControlsBlock(),
                skillCatalogListStack
            ]
        )
        actionsBehaviorCard = nil
        actionsSkillsCard = skillsSection

        actionsPageStack.arrangedSubviews.forEach { subview in
            actionsPageStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        actionsPageStack.translatesAutoresizingMaskIntoConstraints = false
        actionsPageStack.orientation = .vertical
        actionsPageStack.spacing = DesignTokens.Settings.Page.stackSpacing
        actionsPageStack.alignment = .leading
        [pageTitle, pageSubtitle, skillsSection].forEach {
            actionsPageStack.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: actionsPageStack.widthAnchor).isActive = true
        }

        if actionsPageStack.superview == nil {
            actionsContentViewHost.addSubview(actionsPageStack)
        }
        if actionsScrollView.documentView !== actionsContentViewHost {
            actionsScrollView.documentView = actionsContentViewHost
        }
        view.addSubview(actionsScrollView)
        rebuildSkillCatalogViews()

        NSLayoutConstraint.activate([
            actionsScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionsScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionsScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            actionsScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            actionsPageStack.leadingAnchor.constraint(equalTo: actionsContentViewHost.leadingAnchor),
            actionsPageStack.trailingAnchor.constraint(equalTo: actionsContentViewHost.trailingAnchor),
            actionsPageStack.topAnchor.constraint(equalTo: actionsContentViewHost.topAnchor, constant: DesignTokens.Settings.Page.titleTopInset),
            actionsPageStack.bottomAnchor.constraint(lessThanOrEqualTo: actionsContentViewHost.bottomAnchor, constant: -DesignTokens.Settings.Page.plainSectionSpacing),

        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActionsScrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: actionsScrollView.contentView
        )

        refreshActionsScrollLayout()

        item.view = view
        return item
    }

    private func makeSettingsPlainSection(contentViews: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Settings.Page.plainSectionSpacing

        for view in contentViews {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return stack
    }

    private func makeScreenshotSavePathRow() -> NSView {
        let titleLabel = NSTextField(labelWithString: L10n.text(zhHans: "截图保存位置", en: "Screenshot save location"))
        titleLabel.font = DesignTokens.Typography.settingsFieldLabel
        titleLabel.textColor = DesignTokens.Color.textPrimary

        let actions = NSStackView(views: [screenshotSavePathButton, screenshotSavePathResetButton])
        actions.orientation = .horizontal
        actions.spacing = DesignTokens.Settings.Page.formRowSpacing
        actions.alignment = .centerY

        let stack = NSStackView(views: [titleLabel, actions])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = DesignTokens.Settings.Page.formRowSpacing
        stack.alignment = .leading
        return stack
    }

    private func makeSettingsCheckboxRow(_ checkbox: NSButton) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyCheckbox(checkbox)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(checkbox)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            checkbox.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            checkbox.topAnchor.constraint(equalTo: row.topAnchor),
            checkbox.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])

        return row
    }

    private func makeSettingsCheckboxLine(_ checkboxes: [NSButton]) -> NSView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DesignTokens.Settings.Page.checkboxLineSpacing

        for checkbox in checkboxes {
            SettingsControlStyle.applyCheckbox(checkbox)
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            checkbox.setContentHuggingPriority(.required, for: .horizontal)
            checkbox.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.addArrangedSubview(checkbox)
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        return stack
    }

    private func makeSettingsButtonRow(title: String, button: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DesignTokens.Typography.settingsFieldLabel
        titleLabel.textColor = DesignTokens.Color.textPrimary

        let stack = NSStackView(views: [titleLabel, button])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Settings.Page.formRowSpacing
        return stack
    }

    private func makeSkillCatalogControlsBlock() -> NSView {
        let row = NSStackView(views: [skillCatalogFilterStack])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        return row
    }

    private func makeSettingsSectionCard(title: String, subtitle: String, contentViews: [NSView]) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = DesignTokens.Settings.Card.cornerRadius
        card.layer?.borderWidth = DesignTokens.Settings.Card.borderWidth
        card.layer?.borderColor = DesignTokens.Settings.Card.border.cgColor
        card.layer?.backgroundColor = DesignTokens.Settings.Card.surface.cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DesignTokens.Typography.settingsCardTitle
        titleLabel.textColor = DesignTokens.Color.textPrimary

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = DesignTokens.Typography.settingsCardSubtitle
        subtitleLabel.textColor = DesignTokens.Color.textSecondary
        subtitleLabel.maximumNumberOfLines = 0

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = DesignTokens.Settings.rowSpacing

        for view in contentViews {
            contentStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        let stack = NSStackView(views: [titleLabel, subtitleLabel, contentStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Settings.rowSpacing

        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: DesignTokens.Settings.Card.insetHorizontal),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -DesignTokens.Settings.Card.insetHorizontal),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: DesignTokens.Settings.Card.insetVertical),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -DesignTokens.Settings.Card.insetVertical)
        ])

        titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        contentStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return card
    }

    private func configureSkillDetailOverlay(in root: NSView) {
        skillDetailBackdropButton.translatesAutoresizingMaskIntoConstraints = false
        skillDetailBackdropButton.isBordered = false
        skillDetailBackdropButton.bezelStyle = .regularSquare
        skillDetailBackdropButton.wantsLayer = true
        skillDetailBackdropButton.layer?.backgroundColor = DesignTokens.SkillCenter.Detail.backdrop.cgColor
        skillDetailBackdropButton.target = self
        skillDetailBackdropButton.action = #selector(handleDismissSkillDetailOverlay)
        skillDetailBackdropButton.isHidden = true
        root.addSubview(skillDetailBackdropButton)

        skillDetailPanel.translatesAutoresizingMaskIntoConstraints = false
        skillDetailPanel.isHidden = true
        root.addSubview(skillDetailPanel)

        skillDetailStack.translatesAutoresizingMaskIntoConstraints = false
        skillDetailStack.orientation = .vertical
        skillDetailStack.alignment = .width
        skillDetailStack.spacing = DesignTokens.Settings.Page.stackSpacing
        skillDetailPanel.addSubview(skillDetailStack)

        skillDetailCloseButton.target = self
        skillDetailCloseButton.action = #selector(handleDismissSkillDetailOverlay)
        skillDetailHeaderView.closeButton = skillDetailCloseButton

        [skillDetailPrimaryButton, skillDetailSecondaryButton, skillDetailTertiaryButton].forEach {
            SettingsControlStyle.applyActionButton($0)
        }
        skillDetailPrimaryButton.target = self
        skillDetailPrimaryButton.action = #selector(handleSkillDetailPrimaryAction)
        skillDetailSecondaryButton.target = self
        skillDetailSecondaryButton.action = #selector(handleSkillDetailSecondaryAction)
        skillDetailTertiaryButton.target = self
        skillDetailTertiaryButton.action = #selector(handleSkillDetailTertiaryAction)
        SettingsControlStyle.applyCheckbox(skillDetailKnowledgeBaseCheckbox)
        skillDetailKnowledgeBaseCheckbox.target = self
        skillDetailKnowledgeBaseCheckbox.action = #selector(handleSkillDetailKnowledgeBaseToggle)
        skillDetailFooterLabel.textColor = DesignTokens.Color.textSecondary
        skillDetailFooterLabel.maximumNumberOfLines = 0

        let actionRow = NSStackView(views: [
            skillDetailPrimaryButton,
            skillDetailKnowledgeBaseCheckbox,
            skillDetailSecondaryButton,
            skillDetailTertiaryButton
        ])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = DesignTokens.Settings.Page.formRowSpacing

        skillDetailStack.addArrangedSubview(skillDetailHeaderView)
        skillDetailStack.addArrangedSubview(skillDetailOverviewSection)
        skillDetailStack.addArrangedSubview(skillDetailKnowledgeBaseSection)
        skillDetailStack.addArrangedSubview(actionRow)
        skillDetailStack.addArrangedSubview(skillDetailFooterLabel)

        NSLayoutConstraint.activate([
            skillDetailBackdropButton.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            skillDetailBackdropButton.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            skillDetailBackdropButton.topAnchor.constraint(equalTo: root.topAnchor),
            skillDetailBackdropButton.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            skillDetailPanel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            skillDetailPanel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            skillDetailPanel.widthAnchor.constraint(equalToConstant: DesignTokens.SkillCenter.Overlay.width),
            skillDetailPanel.heightAnchor.constraint(lessThanOrEqualToConstant: 760),
            skillDetailPanel.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: DesignTokens.SkillCenter.Overlay.outerInset),
            skillDetailPanel.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -DesignTokens.SkillCenter.Overlay.outerInset),

            skillDetailStack.leadingAnchor.constraint(equalTo: skillDetailPanel.leadingAnchor, constant: DesignTokens.SkillCenter.Overlay.contentInset),
            skillDetailStack.trailingAnchor.constraint(equalTo: skillDetailPanel.trailingAnchor, constant: -DesignTokens.SkillCenter.Overlay.contentInset),
            skillDetailStack.topAnchor.constraint(equalTo: skillDetailPanel.topAnchor, constant: DesignTokens.SkillCenter.Overlay.contentInset),
            skillDetailStack.bottomAnchor.constraint(lessThanOrEqualTo: skillDetailPanel.bottomAnchor, constant: -DesignTokens.SkillCenter.Overlay.contentInset),

            skillDetailHeaderView.widthAnchor.constraint(equalTo: skillDetailStack.widthAnchor),
            skillDetailOverviewSection.widthAnchor.constraint(equalTo: skillDetailStack.widthAnchor),
            skillDetailKnowledgeBaseSection.widthAnchor.constraint(equalTo: skillDetailStack.widthAnchor),
        ])
    }

    private func makeSkillActionViews() -> [NSView] {
        skillToggleCheckboxes.removeAll()

        return actionRegistry.settingsDefinitions().flatMap { definition -> [NSView] in
            let checkbox = NSButton(
                checkboxWithTitle: definition.settingsTitle,
                target: self,
                action: #selector(handleToggleSkill(_:))
            )
            checkbox.identifier = NSUserInterfaceItemIdentifier(definition.skillID)
            skillToggleCheckboxes[definition.skillID] = checkbox

            let views: [NSView] = [
                makeActionRow(
                    title: definition.title,
                    checkbox: checkbox,
                    settingsButton: nil
                )
            ]
            return views
        }
    }

    private func rebuildSkillActionViews() {
        skillActionsStack.arrangedSubviews.forEach { view in
            skillActionsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let installedDefinitions = actionRegistry.settingsDefinitions()
        if installedDefinitions.isEmpty {
            let emptyLabel = NSTextField(wrappingLabelWithString: L10n.text(zhHans: "当前还没有可管理的技能。去技能中心获取更多技能后，会自动出现在这里。", en: "There are no manageable skills yet. After you get more skills from the skill center, they will appear here automatically."))
            emptyLabel.textColor = DesignTokens.Color.textSecondary
            emptyLabel.maximumNumberOfLines = 0
            skillActionsStack.addArrangedSubview(emptyLabel)
            emptyLabel.widthAnchor.constraint(equalTo: skillActionsStack.widthAnchor).isActive = true
            refreshActionsScrollLayout()
            return
        }

        makeSkillActionViews().forEach {
            skillActionsStack.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: skillActionsStack.widthAnchor).isActive = true
        }
        refreshActionsScrollLayout()
    }

    private func updateSkillCatalogFilterButtons() {
        for (filter, button) in skillCatalogFilterButtons {
            button.setSelected(filter == currentSkillCatalogFilter)
        }
    }

    func rebuildSkillCatalogViews(status: String? = nil) {
        skillCatalogListStack.arrangedSubviews.forEach { view in
            skillCatalogListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if let status {
            skillCatalogStatusLabel.stringValue = status
        } else if skillCatalogStatusLabel.stringValue.isEmpty {
            skillCatalogStatusLabel.stringValue = skillsTabCoordinator.statusText()
        }

        let items = skillRegistry.inventoryItems(settings: settings, filter: currentSkillCatalogFilter, query: "")
        guard !items.isEmpty else {
            let emptyLabel = NSTextField(wrappingLabelWithString: L10n.text(zhHans: "当前没有符合筛选条件的技能。", en: "No skills match the current filter."))
            emptyLabel.textColor = DesignTokens.Color.textSecondary
            emptyLabel.maximumNumberOfLines = 0
            skillCatalogListStack.addArrangedSubview(emptyLabel)
            emptyLabel.widthAnchor.constraint(equalTo: skillCatalogListStack.widthAnchor).isActive = true
            refreshActionsScrollLayout()
            return
        }

        var pendingRowViews: [SettingsSkillCatalogRowView] = []

        for item in items {
            let row = SettingsSkillCatalogRowView(
                item: item,
                isSelected: shouldHighlightSkillCatalogItem(item)
            )
            row.onOpenDetail = { [weak self] item in
                self?.presentSkillDetailOverlay(for: item.skillID)
            }
            row.onPrimaryAction = { [weak self] item in
                self?.performPrimarySkillCatalogAction(item)
            }
            row.onSecondaryAction = { [weak self] item in
                self?.performSecondarySkillCatalogAction(item)
            }
            row.onTertiaryAction = { [weak self] item in
                self?.performTertiarySkillCatalogAction(item)
            }
            pendingRowViews.append(row)

            if pendingRowViews.count == 2 {
                let gridRow = makeSkillCatalogGridRow(left: pendingRowViews[0], right: pendingRowViews[1])
                skillCatalogListStack.addArrangedSubview(gridRow)
                gridRow.widthAnchor.constraint(equalTo: skillCatalogListStack.widthAnchor).isActive = true
                pendingRowViews.removeAll(keepingCapacity: true)
            }
        }

        if let last = pendingRowViews.first {
            let gridRow = makeSkillCatalogGridRow(left: last, right: nil)
            skillCatalogListStack.addArrangedSubview(gridRow)
            gridRow.widthAnchor.constraint(equalTo: skillCatalogListStack.widthAnchor).isActive = true
        }

        refreshActionsScrollLayout()
    }

    private func shouldHighlightSkillCatalogItem(_ item: SkillInventoryItem) -> Bool {
        skillDetailPanel.isHidden == false && selectedSkillDetailID == item.skillID
    }

    private func makeSkillCatalogGridRow(left: NSView, right: NSView?) -> NSView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = DesignTokens.Settings.rowSpacing

        row.addArrangedSubview(left)
        if let right {
            row.addArrangedSubview(right)
            left.heightAnchor.constraint(equalTo: right.heightAnchor).isActive = true
        } else {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(spacer)
        }

        return row
    }

    private func performPrimarySkillCatalogAction(_ item: SkillInventoryItem) {
        if item.updateAvailable, let catalogItem = item.catalogItem {
            Task { [weak self] in
                guard let self else { return }
                let result = await self.packageManager.updateCatalogItem(
                    catalogItem,
                    snapshot: self.skillPlatformSnapshotProvider.currentSnapshot().catalogSnapshot
                )
                await MainActor.run {
                    self.handleSkillCatalogInstallResult(result)
                }
            }
            return
        }
        if !item.isInstalled, let catalogItem = item.catalogItem {
            Task { [weak self] in
                guard let self else { return }
                let result = await self.packageManager.installCatalogItem(
                    catalogItem,
                    snapshot: self.skillPlatformSnapshotProvider.currentSnapshot().catalogSnapshot
                )
                await MainActor.run {
                    self.handleSkillCatalogInstallResult(result)
                }
            }
            return
        }
        presentSkillDetailOverlay(for: item.skillID)
    }

    private func performSecondarySkillCatalogAction(_ item: SkillInventoryItem) {
        guard item.isInstalled else { return }
        if skillRegistry.installedRecord(forSkillID: item.skillID) != nil {
            handleSkillCatalogInstallResult(packageManager.setEnabled(!item.isEnabled, forSkillID: item.skillID))
            return
        }
        actionRegistry.setEnabled(!item.isEnabled, forSkillID: item.skillID, settings: settings)
        rebuildSkillCatalogViews(status: !item.isEnabled
            ? L10n.format(zhHans: "已启用 %@。", en: "Enabled %@.", item.displayName)
            : L10n.format(zhHans: "已禁用 %@。", en: "Disabled %@.", item.displayName))
    }

    private func performTertiarySkillCatalogAction(_ item: SkillInventoryItem) {
        guard item.installedDefinition?.skillSource == .installed || item.installedRecord != nil else {
            skillCatalogStatusLabel.stringValue = L10n.text(zhHans: "内置技能不可卸载。", en: "Built-in skills cannot be uninstalled.")
            return
        }
        handleSkillCatalogInstallResult(packageManager.uninstallSkill(skillID: item.skillID))
    }

    private func handleSkillCatalogInstallResult(_ result: SkillInstallResult) {
        switch result {
        case .success(let message):
            skillCatalogStatusLabel.stringValue = message
            rebuildSkillCatalogViews()
            refreshSkillCatalogAutomatically(status: message)
            if skillDetailPanel.isHidden == false {
                updateSkillDetailOverlay()
            }
        case .failure(let message):
            skillCatalogStatusLabel.stringValue = message
            refreshSkillCatalogAutomatically(status: message)
        }
    }

    private func refreshSkillCatalogAutomatically(status: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.catalogService.refreshCatalog()
            await MainActor.run {
                self.skillRegistry.setCatalogSnapshot(snapshot)
                self.rebuildSkillCatalogViews(status: status)
                if self.skillDetailPanel.isHidden == false {
                    self.updateSkillDetailOverlay()
                }
            }
        }
    }

    private func makeAutomationTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: SettingsTab.automation.rawValue)
        item.label = L10n.text(zhHans: "自动化", en: "Automation")
        automationPageView.reloadData()
        item.view = automationPageView.pageView
        return item
    }

    private func makeShortcutsTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: SettingsTab.shortcuts.rawValue)
        item.label = L10n.text(zhHans: "快捷键", en: "Shortcuts")

        let view = NSView()
        let title = NSTextField(labelWithString: L10n.text(zhHans: "截图快捷键", en: "Screenshot shortcut"))
        title.font = DesignTokens.Typography.settingsDialogTitle
        title.textColor = DesignTokens.Color.textPrimary
        title.translatesAutoresizingMaskIntoConstraints = false

        screenshotShortcutLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        screenshotShortcutLabel.textColor = DesignTokens.Color.textPrimary
        screenshotShortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        screenshotShortcutHintLabel.textColor = DesignTokens.Color.textSecondary
        screenshotShortcutHintLabel.translatesAutoresizingMaskIntoConstraints = false

        screenshotShortcutRecordButton.target = self
        screenshotShortcutRecordButton.action = #selector(handleRecordScreenshotShortcut)
        screenshotShortcutRecordButton.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyActionButton(screenshotShortcutRecordButton)

        screenshotShortcutResetButton.target = self
        screenshotShortcutResetButton.action = #selector(handleResetScreenshotShortcut)
        screenshotShortcutResetButton.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyActionButton(screenshotShortcutResetButton)

        screenshotShortcutTestButton.target = self
        screenshotShortcutTestButton.action = #selector(handleTestScreenshotShortcut)
        screenshotShortcutTestButton.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyActionButton(screenshotShortcutTestButton)

        let buttonRow = NSStackView(views: [screenshotShortcutRecordButton, screenshotShortcutResetButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = DesignTokens.Settings.Page.compactButtonRowSpacing
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let tip = NSTextField(wrappingLabelWithString: productProfile.settingsShortcutTipText)
        tip.font = DesignTokens.Typography.settingsSectionBody
        tip.textColor = DesignTokens.Color.textSecondary
        tip.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(title)
        view.addSubview(screenshotShortcutLabel)
        view.addSubview(screenshotShortcutHintLabel)
        view.addSubview(buttonRow)
        view.addSubview(tip)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.Page.compactHeaderInset),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: DesignTokens.Settings.Page.compactHeaderTopInset),

            screenshotShortcutLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.Page.compactHeaderInset),
            screenshotShortcutLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: DesignTokens.Settings.controlSpacing),

            screenshotShortcutHintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.Page.compactHeaderInset),
            screenshotShortcutHintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Settings.Page.compactHeaderInset),
            screenshotShortcutHintLabel.topAnchor.constraint(equalTo: screenshotShortcutLabel.bottomAnchor, constant: DesignTokens.Settings.Page.formRowSpacing),

            buttonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.Page.compactHeaderInset),
            buttonRow.topAnchor.constraint(equalTo: screenshotShortcutHintLabel.bottomAnchor, constant: DesignTokens.Settings.Page.compactSectionSpacing),

            tip.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.Page.compactHeaderInset),
            tip.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Settings.Page.compactHeaderInset),
            tip.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: DesignTokens.Settings.Page.stackSpacing)
        ])

        item.view = view
        return item
    }

    private func makeStartupTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: SettingsTab.startup.rawValue)
        item.label = L10n.text(zhHans: "启动", en: "Startup")

        let view = NSView()
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(handleLaunchAtLoginToggle)
        launchAtLoginCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let tip = NSTextField(wrappingLabelWithString: L10n.text(zhHans: "说明：通过签名后的 .app 包运行时才能稳定启用开机启动。", en: "Notes: Launch at login works reliably only when the signed .app bundle is used."))
        tip.font = DesignTokens.Typography.settingsSectionBody
        tip.textColor = DesignTokens.Color.textSecondary
        tip.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(launchAtLoginCheckbox)
        view.addSubview(tip)

        NSLayoutConstraint.activate([
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.Page.compactHeaderInset),
            launchAtLoginCheckbox.topAnchor.constraint(equalTo: view.topAnchor, constant: DesignTokens.Settings.Page.compactHeaderTopInset),

            tip.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.Page.compactHeaderInset),
            tip.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Settings.Page.compactHeaderInset),
            tip.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: DesignTokens.Settings.Page.compactSectionSpacing)
        ])

        item.view = view
        return item
    }

    private func makePrivacyTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: SettingsTab.privacy.rawValue)
        item.label = L10n.Settings.Tabs.privacy

        let view = NSView()

        permissionStatusLabel.textColor = DesignTokens.Color.textPrimary
        permissionStatusLabel.font = DesignTokens.Typography.settingsSectionTitle
        permissionStatusLabel.lineBreakMode = .byWordWrapping
        permissionStatusLabel.maximumNumberOfLines = 0
        permissionStatusLabel.usesSingleLineMode = false
        permissionStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        permissionStatusLabel.setAccessibilityIdentifier(settingsAccessibilityIdentifier("privacy.status"))
        permissionStatusLabel.setAccessibilityLabel(settingsAccessibilityLabel("Privacy Status"))

        permissionActionLabel.textColor = DesignTokens.Color.textSecondary
        permissionActionLabel.lineBreakMode = .byTruncatingTail
        permissionActionLabel.maximumNumberOfLines = 1
        permissionActionLabel.usesSingleLineMode = true
        permissionActionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        permissionActionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        permissionActionLabel.translatesAutoresizingMaskIntoConstraints = false

        let refreshPermission = SettingsActionButton(title: L10n.Settings.Privacy.refreshStatus, target: self, action: #selector(handleRefreshPermissionStatus))
        refreshPermission.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyActionButton(refreshPermission)
        let requestAllNecessaryPermissions = SettingsActionButton(title: L10n.Settings.Privacy.authorizeRequired, target: self, action: #selector(handleRequestAllNecessaryPermissions))
        requestAllNecessaryPermissions.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyActionButton(requestAllNecessaryPermissions)

        accessibilityPermissionRow.translatesAutoresizingMaskIntoConstraints = false
        accessibilityPermissionRow.setAction(target: self, action: #selector(handleRequestAccessibilityPermission))
        calendarPermissionRow.translatesAutoresizingMaskIntoConstraints = false
        calendarPermissionRow.setAction(target: self, action: #selector(handleRequestCalendarPermission))
        automationPermissionRow.translatesAutoresizingMaskIntoConstraints = false
        automationPermissionRow.setAction(target: self, action: #selector(handleRequestAutomationPermission))
        inputMonitoringPermissionRow.translatesAutoresizingMaskIntoConstraints = false
        inputMonitoringPermissionRow.setAction(target: self, action: #selector(handleOpenInputMonitoringSettings))
        screenRecordingPermissionRow.translatesAutoresizingMaskIntoConstraints = false
        screenRecordingPermissionRow.setAction(target: self, action: #selector(handleOpenScreenRecordingSettings))
        filesAndFoldersPermissionRow.translatesAutoresizingMaskIntoConstraints = false
        filesAndFoldersPermissionRow.setAction(target: self, action: #selector(handleOpenFilesAndFoldersSettings))
        fullDiskAccessPermissionRow.translatesAutoresizingMaskIntoConstraints = false
        fullDiskAccessPermissionRow.setAction(target: self, action: #selector(handleOpenFullDiskAccessSettings))

        permissionListStack.orientation = .vertical
        permissionListStack.alignment = .width
        permissionListStack.spacing = DesignTokens.Settings.rowSpacing
        permissionListStack.translatesAutoresizingMaskIntoConstraints = false
        permissionListStack.arrangedSubviews.forEach { subview in
            permissionListStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        privacyPermissionRows().forEach {
            permissionListStack.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: permissionListStack.widthAnchor).isActive = true
        }

        let permissionHeader = NSStackView()
        permissionHeader.translatesAutoresizingMaskIntoConstraints = false
        permissionHeader.orientation = .horizontal
        permissionHeader.alignment = .centerY
        permissionHeader.spacing = DesignTokens.Settings.rowSpacing

        let permissionHeaderSpacer = NSView()
        permissionHeaderSpacer.translatesAutoresizingMaskIntoConstraints = false
        permissionHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let permissionActionButtons = NSStackView(views: [requestAllNecessaryPermissions, refreshPermission])
        permissionActionButtons.orientation = .horizontal
        permissionActionButtons.alignment = .centerY
        permissionActionButtons.spacing = DesignTokens.Settings.Page.formRowSpacing
        permissionActionButtons.translatesAutoresizingMaskIntoConstraints = false

        permissionHeader.addArrangedSubview(permissionActionLabel)
        permissionHeader.addArrangedSubview(permissionHeaderSpacer)
        permissionHeader.addArrangedSubview(permissionActionButtons)

        let tip = NSTextField(wrappingLabelWithString: L10n.text(zhHans: "默认不持久化选中文本。仅在执行当前 AI 请求时发送必要内容。", en: "Selected text is not persisted by default. Only the required content is sent for the active AI request."))
        tip.font = DesignTokens.Typography.settingsSectionBody
        tip.textColor = DesignTokens.Color.textSecondary
        tip.translatesAutoresizingMaskIntoConstraints = false

        privacyContentStack.arrangedSubviews.forEach { subview in
            privacyContentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        privacyContentStack.translatesAutoresizingMaskIntoConstraints = false
        privacyContentStack.orientation = .vertical
        privacyContentStack.spacing = DesignTokens.Settings.Page.learningStackSpacing
        privacyContentStack.alignment = .leading

        [permissionStatusLabel, permissionHeader, permissionListStack, tip].forEach {
            privacyContentStack.addArrangedSubview($0)
        }
        [permissionStatusLabel, permissionHeader, permissionListStack, tip].forEach {
            $0.widthAnchor.constraint(equalTo: privacyContentStack.widthAnchor).isActive = true
        }

        configureScrollableTab(
            scrollView: privacyScrollView,
            hostView: privacyContentHost,
            contentView: privacyContentStack,
            in: view
        )

        item.view = view
        return item
    }

    private func makeMembershipTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: SettingsTab.membership.rawValue)
        item.label = L10n.Settings.Tabs.membership

        let view = NSView()

        entitlementSummaryLabel.textColor = DesignTokens.Color.textPrimary
        entitlementSummaryLabel.font = DesignTokens.Typography.settingsSectionTitle
        entitlementSummaryLabel.maximumNumberOfLines = 0

        founderOfferLabel.textColor = DesignTokens.Settings.Status.warning
        founderOfferLabel.font = DesignTokens.Typography.settingsSectionBody
        founderOfferLabel.maximumNumberOfLines = 0

        inviteCodeField.placeholderString = L10n.Settings.Membership.invitePlaceholder
        inviteCodeField.delegate = self
        SettingsControlStyle.applyInputField(inviteCodeField)

        inviteRedeemButton.target = self
        inviteRedeemButton.action = #selector(handleRedeemInvite)
        SettingsControlStyle.applyActionButton(inviteRedeemButton, size: .inputAligned)

        inviteResultLabel.textColor = DesignTokens.Settings.Status.neutral
        inviteResultLabel.maximumNumberOfLines = 0

        subscriptionPlanPopup.removeAllItems()
        subscriptionPlanPopup.addItems(withTitles: CommerceSubscriptionPlan.allCases.map { "\($0.displayName) · \($0.displayPrice)" })
        SettingsControlStyle.applyPopupButton(subscriptionPlanPopup)

        subscriptionStatusLabel.textColor = DesignTokens.Settings.Status.neutral
        subscriptionStatusLabel.maximumNumberOfLines = 0

        SettingsControlStyle.applyReadonlyTextBlock(container: membershipHistoryBlock, label: commerceHistoryContentLabel, minHeight: 120)

        activateSubscriptionButton.target = self
        activateSubscriptionButton.action = #selector(handleActivateLocalSubscription)
        SettingsControlStyle.applyActionButton(activateSubscriptionButton)

        refreshEntitlementButton.target = self
        refreshEntitlementButton.action = #selector(handleCancelSubscription)
        SettingsControlStyle.applyActionButton(refreshEntitlementButton)

        membershipPlanRow.setViews([labeledRow(label: L10n.Settings.Membership.planLabel, control: subscriptionPlanPopup)], in: .leading)
        membershipPlanRow.orientation = .vertical
        membershipPlanRow.spacing = 0
        membershipPlanRow.alignment = .leading

        membershipActionRow.setViews([activateSubscriptionButton, refreshEntitlementButton], in: .leading)
        membershipActionRow.orientation = .horizontal
        membershipActionRow.spacing = DesignTokens.Settings.Page.formRowSpacing
        membershipActionRow.alignment = .centerY

        membershipInviteLabel.font = DesignTokens.Typography.settingsSectionTitle
        membershipInviteLabel.textColor = DesignTokens.Color.textPrimary

        membershipInviteRow.setViews([inviteCodeField, inviteRedeemButton], in: .leading)
        membershipInviteRow.orientation = .horizontal
        membershipInviteRow.spacing = DesignTokens.Settings.rowSpacing
        membershipInviteRow.alignment = .centerY
        inviteCodeField.widthAnchor.constraint(equalToConstant: 340).isActive = true

        membershipHistoryLabel.font = DesignTokens.Typography.settingsSectionTitle
        membershipHistoryLabel.textColor = DesignTokens.Color.textPrimary

        membershipContentStack.arrangedSubviews.forEach { subview in
            membershipContentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        membershipContentStack.translatesAutoresizingMaskIntoConstraints = false
        membershipContentStack.orientation = .vertical
        membershipContentStack.spacing = DesignTokens.Settings.controlSpacing
        membershipContentStack.alignment = .leading

        [
            entitlementSummaryLabel,
            founderOfferLabel,
            membershipInviteLabel,
            membershipInviteRow,
            inviteResultLabel,
            membershipPlanRow,
            subscriptionStatusLabel,
            membershipActionRow,
            membershipHistoryLabel,
            membershipHistoryBlock
        ].forEach { membershipContentStack.addArrangedSubview($0) }

        [entitlementSummaryLabel, founderOfferLabel, inviteResultLabel, subscriptionStatusLabel, membershipHistoryBlock].forEach {
            $0.widthAnchor.constraint(equalTo: membershipContentStack.widthAnchor).isActive = true
        }

        configureScrollableTab(
            scrollView: membershipScrollView,
            hostView: membershipContentHost,
            contentView: membershipContentStack,
            in: view
        )

        item.view = view
        return item
    }

    private func makeAITab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: SettingsTab.ai.rawValue)
        item.label = "AI"

        let view = NSView()
        providerPopup.removeAllItems()
        providerPopup.addItems(withTitles: aiConfigurationCoordinator.providerNames)
        providerPopup.target = self
        providerPopup.action = #selector(handleProviderChanged)
        SettingsControlStyle.applyPopupButton(providerPopup)

        modelPopup.removeAllItems()
        modelPopup.target = self
        modelPopup.action = #selector(handleModelChanged)
        SettingsControlStyle.applyPopupButton(modelPopup)
        apiKeyField.placeholderString = L10n.Settings.AI.apiKeyPlaceholder
        apiKeyField.delegate = self
        SettingsControlStyle.applyInputField(apiKeyField)
        apiKeyField.setAccessibilityIdentifier(settingsAccessibilityIdentifier("ai.api-key"))
        apiKeyField.setAccessibilityLabel(settingsAccessibilityLabel("AI API Key"))

        aiValidateButton.target = self
        aiValidateButton.action = #selector(handleValidateAIConfig)
        SettingsControlStyle.applyActionButton(aiValidateButton)

        let rows = NSStackView(views: [
            aiCurrentConfigLabel,
            aiDraftStatusLabel,
            labeledRow(label: L10n.Settings.AI.provider, control: providerPopup),
            labeledRow(label: L10n.Settings.AI.model, control: modelPopup),
            labeledRow(label: "API Key", control: apiKeyField),
            aiRuntimeStatusLabel,
            aiValidateButton,
            aiValidationLabel
        ])
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.spacing = DesignTokens.Settings.rowSpacing
        rows.alignment = .leading

        [aiCurrentConfigLabel, aiDraftStatusLabel, aiRuntimeStatusLabel].forEach {
            $0.textColor = DesignTokens.Color.textSecondary
            $0.font = DesignTokens.Typography.settingsSectionBody
            $0.maximumNumberOfLines = 0
            $0.lineBreakMode = .byWordWrapping
        }
        aiValidationLabel.textColor = DesignTokens.Settings.Status.neutral
        aiValidationLabel.font = DesignTokens.Typography.settingsSectionBody
        aiValidationLabel.isHidden = true

        let tip = NSTextField(wrappingLabelWithString: L10n.Settings.AI.configHint)
        tip.font = DesignTokens.Typography.settingsSectionBody
        tip.textColor = DesignTokens.Color.textSecondary
        tip.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rows)
        view.addSubview(tip)

        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.Page.compactHeaderInset),
            rows.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Settings.Page.compactHeaderInset),
            rows.topAnchor.constraint(equalTo: view.topAnchor, constant: DesignTokens.Settings.Page.compactHeaderTopInset),

            tip.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.Page.compactHeaderInset),
            tip.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Settings.Page.compactHeaderInset),
            tip.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: DesignTokens.Settings.controlSpacing)
        ])

        item.view = view
        return item
    }

    private func makeKnowledgeBaseTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: SettingsTab.knowledgeBase.rawValue)
        item.label = L10n.Settings.Tabs.knowledgeBase

        let view = NSView()

        knowledgeBaseDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        knowledgeBaseDescriptionLabel.textColor = DesignTokens.Color.textSecondary
        knowledgeBaseDescriptionLabel.maximumNumberOfLines = 0
        knowledgeBaseDescriptionLabel.lineBreakMode = .byWordWrapping
        knowledgeBaseDescriptionLabel.usesSingleLineMode = false
        knowledgeBaseDescriptionLabel.font = DesignTokens.Typography.settingsSectionBody

        knowledgeBaseSearchField.translatesAutoresizingMaskIntoConstraints = false
        knowledgeBaseSearchField.placeholderString = L10n.text(zhHans: "搜索知识库来源、摘要或主题", en: "Search sources, summaries, or topics")
        knowledgeBaseSearchField.delegate = self
        SettingsControlStyle.applyInputField(knowledgeBaseSearchField)
        knowledgeBaseSearchField.setAccessibilityIdentifier(settingsAccessibilityIdentifier("knowledge-base.search"))
        knowledgeBaseSearchField.setAccessibilityLabel(settingsAccessibilityLabel("Knowledge Base Search"))

        knowledgeBaseStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        knowledgeBaseStatusLabel.textColor = DesignTokens.Settings.Status.neutral
        knowledgeBaseStatusLabel.maximumNumberOfLines = 0
        knowledgeBaseStatusLabel.lineBreakMode = .byWordWrapping
        knowledgeBaseStatusLabel.usesSingleLineMode = false
        knowledgeBaseStatusLabel.isHidden = true

        knowledgeBaseAddButton.translatesAutoresizingMaskIntoConstraints = false
        knowledgeBaseAddButton.target = self
        knowledgeBaseAddButton.action = #selector(handleAddKnowledgeBaseFiles)
        SettingsControlStyle.applyActionButton(knowledgeBaseAddButton)

        knowledgeBaseManageButton.translatesAutoresizingMaskIntoConstraints = false
        knowledgeBaseManageButton.target = self
        knowledgeBaseManageButton.action = #selector(handleToggleKnowledgeBaseManageMode)
        SettingsControlStyle.applyActionButton(knowledgeBaseManageButton)

        knowledgeBaseBindNotionButton.translatesAutoresizingMaskIntoConstraints = false
        knowledgeBaseBindNotionButton.target = self
        knowledgeBaseBindNotionButton.action = #selector(handleBindKnowledgeBaseNotion)
        SettingsControlStyle.applyActionButton(knowledgeBaseBindNotionButton)
        knowledgeBaseBindNotionButton.isHidden = false

        knowledgeBaseNotionModuleView.translatesAutoresizingMaskIntoConstraints = false
        knowledgeBaseNotionModuleView.isHidden = true

        knowledgeBaseNotionTokenField.translatesAutoresizingMaskIntoConstraints = false
        knowledgeBaseNotionTokenField.placeholderString = L10n.text(zhHans: "输入 Notion Integration Token", en: "Enter Notion integration token")
        knowledgeBaseNotionTokenField.stringValue = settings.notionIntegrationToken
        knowledgeBaseNotionTokenField.delegate = self
        SettingsControlStyle.applyInputField(knowledgeBaseNotionTokenField)

        knowledgeBaseNotionHintLabel.translatesAutoresizingMaskIntoConstraints = false
        knowledgeBaseNotionHintLabel.font = DesignTokens.Typography.settingsSectionBody
        knowledgeBaseNotionHintLabel.textColor = DesignTokens.Color.textSecondary
        knowledgeBaseNotionHintLabel.maximumNumberOfLines = 2
        knowledgeBaseNotionHintLabel.lineBreakMode = .byWordWrapping

        knowledgeBaseSourceFilterStack.translatesAutoresizingMaskIntoConstraints = false
        knowledgeBaseSourceFilterStack.orientation = .horizontal
        knowledgeBaseSourceFilterStack.alignment = .centerY
        knowledgeBaseSourceFilterStack.spacing = DesignTokens.Settings.Filter.spacing
        if knowledgeBaseSourceFilterStack.arrangedSubviews.isEmpty {
            for tab in KnowledgeBaseSourceTab.availableTabs {
                let button = SettingsFilterPillButton(title: tab.title)
                button.target = self
                button.action = #selector(handleKnowledgeBaseSourceFilterTap(_:))
                button.tag = tab.rawValue
                knowledgeBaseSourceFilterButtons[tab] = button
                knowledgeBaseSourceFilterStack.addArrangedSubview(button)
            }
        }

        knowledgeBaseScrollView.translatesAutoresizingMaskIntoConstraints = false
        knowledgeBaseScrollView.drawsBackground = false
        knowledgeBaseScrollView.hasVerticalScroller = false
        knowledgeBaseScrollView.hasHorizontalScroller = false
        knowledgeBaseScrollView.autohidesScrollers = false
        knowledgeBaseScrollView.contentView.postsBoundsChangedNotifications = true
        knowledgeBaseScrollView.borderType = .noBorder

        knowledgeBaseContentViewHost.translatesAutoresizingMaskIntoConstraints = true
        knowledgeBaseListStack.orientation = .vertical
        knowledgeBaseListStack.alignment = .width
        knowledgeBaseListStack.spacing = DesignTokens.Settings.controlSpacing
        knowledgeBaseListStack.translatesAutoresizingMaskIntoConstraints = false
        if knowledgeBaseListStack.superview == nil {
            knowledgeBaseContentViewHost.addSubview(knowledgeBaseListStack)
        }
        NSLayoutConstraint.activate([
            knowledgeBaseListStack.leadingAnchor.constraint(equalTo: knowledgeBaseContentViewHost.leadingAnchor),
            knowledgeBaseListStack.trailingAnchor.constraint(equalTo: knowledgeBaseContentViewHost.trailingAnchor),
            knowledgeBaseListStack.topAnchor.constraint(equalTo: knowledgeBaseContentViewHost.topAnchor, constant: DesignTokens.Settings.controlSpacing),
            knowledgeBaseListStack.bottomAnchor.constraint(equalTo: knowledgeBaseContentViewHost.bottomAnchor, constant: -DesignTokens.Settings.controlSpacing)
        ])
        knowledgeBaseScrollView.documentView = knowledgeBaseContentViewHost
        knowledgeBaseEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        knowledgeBaseEmptyLabel.textColor = DesignTokens.Color.textSecondary
        knowledgeBaseEmptyLabel.maximumNumberOfLines = 0
        knowledgeBaseEmptyLabel.lineBreakMode = .byWordWrapping
        knowledgeBaseEmptyLabel.isHidden = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSharedScrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: knowledgeBaseScrollView.contentView
        )

        view.addSubview(knowledgeBaseDescriptionLabel)
        view.addSubview(knowledgeBaseSourceFilterStack)
        view.addSubview(knowledgeBaseAddButton)
        view.addSubview(knowledgeBaseManageButton)
        view.addSubview(knowledgeBaseSearchField)
        view.addSubview(knowledgeBaseNotionModuleView)
        view.addSubview(knowledgeBaseScrollView)
        view.addSubview(knowledgeBaseEmptyLabel)
        view.addSubview(knowledgeBaseStatusLabel)

        knowledgeBaseNotionModuleView.addSubview(knowledgeBaseNotionTokenField)
        knowledgeBaseNotionModuleView.addSubview(knowledgeBaseBindNotionButton)
        knowledgeBaseNotionModuleView.addSubview(knowledgeBaseNotionHintLabel)

        knowledgeBaseStatusTopConstraint = knowledgeBaseStatusLabel.topAnchor.constraint(equalTo: knowledgeBaseSearchField.bottomAnchor, constant: DesignTokens.Settings.controlSpacing)
        knowledgeBaseScrollTopToStatusConstraint = knowledgeBaseScrollView.topAnchor.constraint(equalTo: knowledgeBaseStatusLabel.bottomAnchor, constant: DesignTokens.Settings.Page.compactSectionSpacing)
        knowledgeBaseScrollTopToSearchConstraint = knowledgeBaseScrollView.topAnchor.constraint(equalTo: knowledgeBaseSearchField.bottomAnchor, constant: DesignTokens.Settings.Page.compactSectionSpacing)
        knowledgeBaseEmptyTopToStatusConstraint = knowledgeBaseEmptyLabel.topAnchor.constraint(equalTo: knowledgeBaseStatusLabel.bottomAnchor, constant: DesignTokens.Settings.Page.stackSpacing)
        knowledgeBaseEmptyTopToSearchConstraint = knowledgeBaseEmptyLabel.topAnchor.constraint(equalTo: knowledgeBaseSearchField.bottomAnchor, constant: DesignTokens.Settings.Page.stackSpacing)

        NSLayoutConstraint.activate([
            knowledgeBaseDescriptionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.pageInset),
            knowledgeBaseDescriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Settings.pageInset),
            knowledgeBaseDescriptionLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: DesignTokens.Settings.pageInset),

            knowledgeBaseStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.pageInset),
            knowledgeBaseStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Settings.pageInset),

            knowledgeBaseSourceFilterStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.pageInset),
            knowledgeBaseSourceFilterStack.topAnchor.constraint(equalTo: knowledgeBaseDescriptionLabel.bottomAnchor, constant: DesignTokens.Settings.Page.filterRowSpacing),

            knowledgeBaseAddButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Settings.pageInset),
            knowledgeBaseAddButton.centerYAnchor.constraint(equalTo: knowledgeBaseSourceFilterStack.centerYAnchor),

            knowledgeBaseManageButton.trailingAnchor.constraint(equalTo: knowledgeBaseAddButton.leadingAnchor, constant: -DesignTokens.Settings.rowSpacing),
            knowledgeBaseManageButton.centerYAnchor.constraint(equalTo: knowledgeBaseSourceFilterStack.centerYAnchor),

            knowledgeBaseSearchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.pageInset),
            knowledgeBaseSearchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Settings.pageInset),
            knowledgeBaseSearchField.topAnchor.constraint(equalTo: knowledgeBaseSourceFilterStack.bottomAnchor, constant: DesignTokens.Settings.controlSpacing),
            knowledgeBaseSearchField.heightAnchor.constraint(equalToConstant: DesignTokens.Settings.controlHeight),

            knowledgeBaseNotionModuleView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            knowledgeBaseNotionModuleView.centerYAnchor.constraint(equalTo: knowledgeBaseScrollView.centerYAnchor, constant: -54),
            knowledgeBaseNotionModuleView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 72),
            knowledgeBaseNotionModuleView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -72),
            knowledgeBaseNotionModuleView.widthAnchor.constraint(lessThanOrEqualToConstant: 760),

            knowledgeBaseScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignTokens.Settings.pageInset),
            knowledgeBaseScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignTokens.Settings.pageInset),
            knowledgeBaseScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -DesignTokens.Settings.pageInset),

            knowledgeBaseEmptyLabel.leadingAnchor.constraint(equalTo: knowledgeBaseScrollView.leadingAnchor, constant: DesignTokens.Spacing.xxs),
            knowledgeBaseEmptyLabel.trailingAnchor.constraint(equalTo: knowledgeBaseScrollView.trailingAnchor, constant: -DesignTokens.Spacing.xxs),

            knowledgeBaseNotionTokenField.leadingAnchor.constraint(equalTo: knowledgeBaseNotionModuleView.leadingAnchor),
            knowledgeBaseNotionTokenField.topAnchor.constraint(equalTo: knowledgeBaseNotionModuleView.topAnchor),
            knowledgeBaseNotionTokenField.heightAnchor.constraint(equalToConstant: 36),

            knowledgeBaseBindNotionButton.leadingAnchor.constraint(equalTo: knowledgeBaseNotionTokenField.trailingAnchor, constant: 12),
            knowledgeBaseBindNotionButton.trailingAnchor.constraint(equalTo: knowledgeBaseNotionModuleView.trailingAnchor),
            knowledgeBaseBindNotionButton.centerYAnchor.constraint(equalTo: knowledgeBaseNotionTokenField.centerYAnchor),
            knowledgeBaseBindNotionButton.widthAnchor.constraint(equalToConstant: 132),

            knowledgeBaseNotionHintLabel.leadingAnchor.constraint(equalTo: knowledgeBaseNotionModuleView.leadingAnchor),
            knowledgeBaseNotionHintLabel.trailingAnchor.constraint(equalTo: knowledgeBaseNotionModuleView.trailingAnchor),
            knowledgeBaseNotionHintLabel.topAnchor.constraint(equalTo: knowledgeBaseNotionTokenField.bottomAnchor, constant: 28),
            knowledgeBaseNotionHintLabel.heightAnchor.constraint(equalToConstant: 52),
            knowledgeBaseNotionHintLabel.bottomAnchor.constraint(equalTo: knowledgeBaseNotionModuleView.bottomAnchor)
        ])

        knowledgeBaseStatusTopConstraint?.isActive = true
        knowledgeBaseScrollTopToSearchConstraint?.isActive = true
        knowledgeBaseEmptyTopToSearchConstraint?.isActive = true
        updateKnowledgeBaseStatusMessage(nil)
        updateKnowledgeBaseNotionBindingUI()

        knowledgeBaseCoordinator.reloadEntries()

        item.view = view
        return item
    }

    private func makeLearningTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: SettingsTab.learning.rawValue)
        item.label = L10n.Settings.Tabs.stats

        let view = NSView()

        let refreshButton = SettingsActionButton(title: L10n.text(zhHans: "刷新数据", en: "Refresh data"), target: self, action: #selector(handleRefreshLearningDiagnostics))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyActionButton(refreshButton)

        let titleLabel = NSTextField(labelWithString: L10n.Settings.Stats.title)
        titleLabel.font = DesignTokens.Typography.settingsLearningHeader
        titleLabel.textColor = DesignTokens.Color.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let tip = NSTextField(wrappingLabelWithString: L10n.format(
            zhHans: "看看你最近怎么使用 %@，以及系统为什么会在不同场景下这样推荐技能。",
            en: "See how you've been using %@ recently and why %@ recommends certain skills in different contexts.",
            productDisplayName,
            productDisplayName
        ))
        tip.font = DesignTokens.Typography.settingsSectionBody
        tip.textColor = DesignTokens.Color.textSecondary
        tip.translatesAutoresizingMaskIntoConstraints = false
        tip.maximumNumberOfLines = 0

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let headerRow = NSStackView(views: [titleLabel, headerSpacer, refreshButton])
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = DesignTokens.Settings.Page.learningHeaderSpacing

        learningContentStack.arrangedSubviews.forEach { subview in
            learningContentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        learningContentStack.translatesAutoresizingMaskIntoConstraints = false
        learningContentStack.orientation = .vertical
        learningContentStack.spacing = DesignTokens.Settings.Page.learningStackSpacing
        learningContentStack.alignment = .leading

        [
            headerRow,
            tip,
            statisticsMetricStripView,
            statisticsSkillChartView,
            statisticsAppChartView,
            statisticsCategoryChartView,
            statisticsTrendSectionView,
            statisticsRouteSnapshotView
        ].forEach {
            learningContentStack.addArrangedSubview($0)
        }
        [
            headerRow,
            tip,
            statisticsMetricStripView,
            statisticsSkillChartView,
            statisticsAppChartView,
            statisticsCategoryChartView,
            statisticsTrendSectionView,
            statisticsRouteSnapshotView
        ].forEach {
            $0.widthAnchor.constraint(equalTo: learningContentStack.widthAnchor).isActive = true
        }

        configureScrollableTab(
            scrollView: learningScrollView,
            hostView: learningContentHost,
            contentView: learningContentStack,
            in: view
        )

        item.view = view
        return item
    }

    private func makeActionRow(title: String, checkbox: NSButton, settingsButton: NSButton?) -> NSView {
        checkbox.title = ""
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DesignTokens.Typography.settingsSectionTitle
        titleLabel.textColor = DesignTokens.Color.textPrimary
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [checkbox, titleLabel, spacer]
        if let settingsButton {
            views.append(settingsButton)
        }

        let rowStack = NSStackView(views: views)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = DesignTokens.Settings.rowSpacing

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(rowStack)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 46),
            rowStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: DesignTokens.Settings.rowSpacing),
            rowStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -DesignTokens.Settings.rowSpacing),
            rowStack.topAnchor.constraint(equalTo: row.topAnchor, constant: DesignTokens.Spacing.xs),
            rowStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -DesignTokens.Spacing.xs),
        ])
        return row
    }

    private func labeledRow(label: String, control: NSView) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = DesignTokens.Typography.settingsFieldLabel
        title.textColor = DesignTokens.Color.textPrimary
        title.setContentCompressionResistancePriority(.required, for: .horizontal)

        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DesignTokens.Settings.rowSpacing

        if let textField = control as? NSTextField {
            textField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        }
        if control is SettingsDropdownButton {
            control.widthAnchor.constraint(equalToConstant: 230).isActive = true
        }

        return row
    }

    private func makeReadonlyTextBlock(label: NSTextField, minHeight: CGFloat) -> NSView {
        let container = NSView()
        SettingsControlStyle.applyReadonlyTextBlock(container: container, label: label, minHeight: minHeight)
        return container
    }

    private func configureScrollableTab(
        scrollView: NSScrollView,
        hostView: SettingsFlippedView,
        contentView: NSView,
        in rootView: NSView
    ) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        hostView.translatesAutoresizingMaskIntoConstraints = true
        if contentView.superview !== hostView {
            hostView.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor, constant: DesignTokens.Settings.Page.scrollContentInset),
                contentView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor, constant: -DesignTokens.Settings.Page.scrollContentInset),
                contentView.topAnchor.constraint(equalTo: hostView.topAnchor, constant: DesignTokens.Settings.Page.scrollContentInset),
                contentView.bottomAnchor.constraint(lessThanOrEqualTo: hostView.bottomAnchor, constant: -DesignTokens.Settings.Page.scrollContentInset),
            ])
        }

        if scrollView.documentView !== hostView {
            scrollView.documentView = hostView
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSharedScrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        if scrollView.superview !== rootView {
            rootView.addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            ])
        }

        refreshScrollableTabLayout(scrollView: scrollView, hostView: hostView, contentView: contentView)
    }

    func refreshScrollableTabLayout(
        scrollView: NSScrollView,
        hostView: SettingsFlippedView,
        contentView: NSView,
        minimumWidth: CGFloat = 560
    ) {
        guard scrollView.superview != nil else { return }
        scrollView.superview?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        let visibleWidth = max(scrollView.contentView.bounds.width, scrollView.bounds.width)
        let targetWidth = max(visibleWidth, minimumWidth)
        hostView.frame = NSRect(x: 0, y: 0, width: targetWidth, height: max(hostView.frame.height, 10))
        hostView.layoutSubtreeIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        let height = max(contentView.fittingSize.height + 36, scrollView.contentSize.height)
        hostView.frame = NSRect(x: 0, y: 0, width: targetWidth, height: height)
        hostView.layoutSubtreeIfNeeded()
        refreshScrollIndicatorForCurrentTab(showTemporarily: false)
    }

    private func refreshKnowledgeBaseScrollLayout() {
        refreshScrollableTabLayout(
            scrollView: knowledgeBaseScrollView,
            hostView: knowledgeBaseContentViewHost,
            contentView: knowledgeBaseListStack,
            minimumWidth: 1
        )
    }

    func reloadKnowledgeBaseEntries(status: String? = nil) {
        knowledgeBaseCoordinator.reloadEntries(status: status)
    }

    func renderKnowledgeBaseRows() {
        let visibleEntries = knowledgeBaseCoordinator.visibleEntries
        selectedKnowledgeBaseEntryIDs = selectedKnowledgeBaseEntryIDs.intersection(Set(visibleEntries.map(\.id)))
        if let selectedKnowledgeBaseDetailEntryID,
           !visibleEntries.contains(where: { $0.id == selectedKnowledgeBaseDetailEntryID }) {
            clearKnowledgeBaseDetail()
        }
        knowledgeBaseListCoordinator.render(
            entries: visibleEntries,
            emptyStateText: knowledgeBaseCoordinator.emptyStateText(),
            topAccessoryView: knowledgeBaseTopAccessoryView(for: knowledgeBaseCoordinator.filteredEntries)
        )
    }

    func updateKnowledgeBaseStatusMessage(_ message: String?) {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasMessage = !trimmed.isEmpty
        knowledgeBaseStatusLabel.stringValue = trimmed
        knowledgeBaseStatusLabel.isHidden = !hasMessage
        knowledgeBaseStatusTopConstraint?.isActive = hasMessage
        knowledgeBaseScrollTopToStatusConstraint?.isActive = hasMessage
        knowledgeBaseEmptyTopToStatusConstraint?.isActive = hasMessage
        knowledgeBaseScrollTopToSearchConstraint?.isActive = !hasMessage
        knowledgeBaseEmptyTopToSearchConstraint?.isActive = !hasMessage
        knowledgeBaseStatusLabel.superview?.layoutSubtreeIfNeeded()
        refreshKnowledgeBaseScrollLayout()
    }

    func updateKnowledgeBaseNotionBindingUI() {
        guard KnowledgeBaseFeatureFlags.notionEnabled else {
            knowledgeBaseNotionModuleView.isHidden = true
            knowledgeBaseSearchField.isHidden = false
            knowledgeBaseScrollView.isHidden = false
            knowledgeBaseEmptyLabel.isHidden = !knowledgeBaseCoordinator.filteredEntries.isEmpty
            refreshKnowledgeBaseScrollLayout()
            return
        }
        let isNotionSelected = knowledgeBaseCoordinator.selectedSourceTab == .notion
        let needsBinding = settings.notionIntegrationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shouldShowBindModule = isNotionSelected && needsBinding
        knowledgeBaseNotionModuleView.isHidden = !shouldShowBindModule
        knowledgeBaseSearchField.isHidden = shouldShowBindModule
        knowledgeBaseScrollView.isHidden = shouldShowBindModule
        knowledgeBaseEmptyLabel.isHidden = shouldShowBindModule || !knowledgeBaseCoordinator.filteredEntries.isEmpty
        knowledgeBaseBindNotionButton.isEnabled = !knowledgeBaseAutoSyncCoordinator.snapshot.isSyncing
        if shouldShowBindModule {
            updateKnowledgeBaseStatusMessage(nil)
            setKnowledgeBaseNotionFeedback(nil, isError: false)
        }
        refreshKnowledgeBaseScrollLayout()
    }

    func handleInlineKnowledgeBaseNotionBinding() {
        let token = knowledgeBaseNotionTokenField.stringValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !token.isEmpty else {
            setKnowledgeBaseNotionFeedback(
                L10n.text(zhHans: "请先填写 Notion Integration Token。", en: "Enter the Notion integration token first."),
                isError: true
            )
            return
        }

        let previousToken = settings.notionIntegrationToken
        do {
            try settings.updateNotionIntegrationToken(token)
        } catch {
            setKnowledgeBaseNotionFeedback(error.localizedDescription, isError: true)
            return
        }

        knowledgeBaseBindNotionButton.isEnabled = false
        setKnowledgeBaseNotionFeedback(
            L10n.text(zhHans: "正在同步 Notion 最近共享页面...", en: "Syncing recently shared Notion pages..."),
            isError: false
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.knowledgeBaseAutoSyncCoordinator.syncNow(mode: .full)
                self.knowledgeBaseBindNotionButton.isEnabled = true
                self.knowledgeBaseNotionTokenField.stringValue = self.settings.notionIntegrationToken
                self.reloadKnowledgeBaseEntries(status: self.knowledgeBaseAutoSyncCoordinator.snapshot.statusMessage)
                self.updateKnowledgeBaseNotionBindingUI()
            } catch {
                self.knowledgeBaseBindNotionButton.isEnabled = true
                do {
                    try self.settings.updateNotionIntegrationToken(previousToken)
                } catch {}
                self.setKnowledgeBaseNotionFeedback(error.localizedDescription, isError: true)
                self.updateKnowledgeBaseNotionBindingUI()
            }
        }
    }

    private func setKnowledgeBaseNotionFeedback(_ message: String?, isError: Bool) {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        knowledgeBaseNotionHintLabel.stringValue = trimmed.isEmpty ? knowledgeBaseNotionDefaultHintText : trimmed
        knowledgeBaseNotionHintLabel.textColor = isError ? DesignTokens.Color.accentOrange : DesignTokens.Color.textSecondary
    }

    private func knowledgeBaseManagementAccessoryView(for entries: [ReplyKnowledgeBaseEntry]) -> NSView? {
        guard isKnowledgeBaseManaging, !entries.isEmpty else { return nil }
        let allSelected = !entries.isEmpty && entries.allSatisfy { selectedKnowledgeBaseEntryIDs.contains($0.id) }
        let selectedCount = selectedKnowledgeBaseEntryIDs.count

        let selectAllButton = SettingsActionButton(
            title: allSelected ? L10n.text(zhHans: "取消全选", en: "Clear All") : L10n.text(zhHans: "全选", en: "Select All"),
            target: self,
            action: #selector(handleToggleSelectAllKnowledgeBaseEntries)
        )
        SettingsControlStyle.applyActionButton(selectAllButton)
        selectAllButton.translatesAutoresizingMaskIntoConstraints = false

        let deleteButton = SettingsActionButton(
            title: L10n.text(zhHans: "删除所选", en: "Delete Selected"),
            target: self,
            action: #selector(handleDeleteSelectedKnowledgeBaseEntries)
        )
        SettingsControlStyle.applyActionButton(deleteButton)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.isEnabled = selectedCount > 0

        let summaryLabel = NSTextField(labelWithString: L10n.format(
            zhHans: "已选 %d 项",
            en: "%d selected",
            selectedCount
        ))
        summaryLabel.font = DesignTokens.KnowledgeBaseWindow.Row.metaFont
        summaryLabel.textColor = DesignTokens.Color.textSecondary
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [selectAllButton, deleteButton, NSView(), summaryLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func knowledgeBasePaginationAccessoryView(for entries: [ReplyKnowledgeBaseEntry]) -> NSView? {
        guard entries.count > SettingsKnowledgeBaseCoordinator.pageSize else { return nil }

        let previousButton = SettingsActionButton(
            title: L10n.text(zhHans: "上一页", en: "Previous"),
            target: self,
            action: #selector(handleKnowledgeBasePreviousPage)
        )
        SettingsControlStyle.applyActionButton(previousButton)
        previousButton.translatesAutoresizingMaskIntoConstraints = false
        previousButton.isEnabled = knowledgeBaseCoordinator.currentPageNumber > 1

        let nextButton = SettingsActionButton(
            title: L10n.text(zhHans: "下一页", en: "Next"),
            target: self,
            action: #selector(handleKnowledgeBaseNextPage)
        )
        SettingsControlStyle.applyActionButton(nextButton)
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        nextButton.isEnabled = knowledgeBaseCoordinator.currentPageNumber < knowledgeBaseCoordinator.totalPageCount

        let summaryLabel = NSTextField(labelWithString: L10n.format(
            zhHans: "第 %d 页 · %@",
            en: "Page %d · %@",
            knowledgeBaseCoordinator.currentPageNumber,
            knowledgeBaseCoordinator.visibleRangeText
        ))
        summaryLabel.font = DesignTokens.KnowledgeBaseWindow.Row.metaFont
        summaryLabel.textColor = DesignTokens.Color.textSecondary
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [summaryLabel, NSView(), previousButton, nextButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func knowledgeBaseTopAccessoryView(for entries: [ReplyKnowledgeBaseEntry]) -> NSView? {
        let managementView = knowledgeBaseManagementAccessoryView(for: knowledgeBaseCoordinator.visibleEntries)
        let paginationView = knowledgeBasePaginationAccessoryView(for: entries)

        switch (managementView, paginationView) {
        case (nil, nil):
            return nil
        case let (view?, nil), let (nil, view?):
            return view
        case let (managementView?, paginationView?):
            let stack = NSStackView(views: [managementView, NSView(), paginationView])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            return stack
        }
    }

    private func updateKnowledgeBaseSelection(id: String, isSelected: Bool) {
        if isSelected {
            selectedKnowledgeBaseEntryIDs.insert(id)
        } else {
            selectedKnowledgeBaseEntryIDs.remove(id)
        }
        renderKnowledgeBaseRows()
    }

    private func showKnowledgeBaseDetail(for entryID: String) {
        guard !isKnowledgeBaseManaging else { return }
        selectedKnowledgeBaseDetailEntryID = entryID
        selectedKnowledgeBaseDetailEntry = knowledgeBaseStore.entry(id: entryID)
        selectedKnowledgeBaseDetailSnapshot = knowledgeBaseStore.sourceSnapshot(id: entryID, kind: "readable")
        let title = selectedKnowledgeBaseDetailEntry.map(displayTitle(forKnowledgeEntry:)) ?? L10n.text(zhHans: "知识库预览", en: "Knowledge Preview")
        let text = knowledgeBaseDetailPreviewText()
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KnowledgeBaseTextPreviewWindowController.shared.show(title: title, text: text)
        }
    }

    private func clearKnowledgeBaseDetail() {
        selectedKnowledgeBaseDetailEntryID = nil
        selectedKnowledgeBaseDetailEntry = nil
        selectedKnowledgeBaseDetailSnapshot = nil
    }

    private func knowledgeBaseDetailPreviewText() -> String {
        let snapshot = selectedKnowledgeBaseDetailSnapshot
        let snapshotText = snapshot?.markdownText ?? snapshot?.plainText ?? ""
        if !snapshotText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(snapshotText.prefix(12000))
        }
        if let fullText = selectedKnowledgeBaseDetailEntry?.fullText,
           !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(fullText.prefix(12000))
        }
        if let fallback = selectedKnowledgeBaseDetailEntry?.preview, !fallback.isEmpty {
            return fallback
        }
        return L10n.text(zhHans: "这份来源暂时没有可展示的快照内容。", en: "There is no snapshot content available to preview yet.")
    }

    private func displayTitle(forKnowledgeEntry entry: ReplyKnowledgeBaseEntry) -> String {
        if entry.sourceKind == .url {
            let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? (entry.externalURL ?? entry.originalFilename) : trimmed
        }
        return entry.originalFilename
    }

    func resetKnowledgeBaseScrollPosition() {
        knowledgeBaseScrollView.contentView.scroll(to: .zero)
        knowledgeBaseScrollView.reflectScrolledClipView(knowledgeBaseScrollView.contentView)
    }


    func setKnowledgeBaseManaging(_ isManaging: Bool) {
        isKnowledgeBaseManaging = isManaging
        if !isManaging {
            selectedKnowledgeBaseEntryIDs.removeAll()
        } else {
            clearKnowledgeBaseDetail()
        }
        knowledgeBaseManageButton.title = isManaging
            ? L10n.text(zhHans: "完成", en: "Done")
            : L10n.text(zhHans: "管理", en: "Manage")
        renderKnowledgeBaseRows()
    }

    private func knowledgeBaseEmptyStateText(for tab: KnowledgeBaseSourceTab) -> String {
        knowledgeBaseCoordinator.emptyStateText()
    }

    private func loadFromSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        isKnowledgeBaseManaging = false
        selectedKnowledgeBaseEntryIDs.removeAll()
        clearKnowledgeBaseDetail()
        knowledgeBaseManageButton.title = L10n.text(zhHans: "管理", en: "Manage")
        updateKnowledgeBaseNotionBindingUI()

        autoToolbarCheckbox.state = settings.textSelectionEnabled ? .on : .off
        fileSelectionCheckbox.state = settings.fileSelectionEnabled ? .on : .off
        screenshotEntryCheckbox.state = settings.screenshotEnabled ? .on : .off
        conversationBoxEntryCheckbox.state = settings.conversationBoxEnabled ? .on : .off
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: settings.appLanguage) ?? 0)
        for definition in actionRegistry.settingsDefinitions() {
            skillToggleCheckboxes[definition.skillID]?.state = actionRegistry.isEnabled(definition.skillID, settings: settings) ? .on : .off
        }
        dismissOutsideCheckbox.state = settings.dismissOnOutsideClick ? .on : .off
        launchAtLoginCheckbox.state = settings.launchAtLoginPreferred ? .on : .off

        aiConfigurationCoordinator.handleGatewayRuntimeStatusChanged(aiTabCoordinator.runtimeSnapshot())
        aiConfigurationCoordinator.loadFromSettings()
        knowledgeBaseSearchField.stringValue = ""
        knowledgeBaseNotionTokenField.stringValue = settings.notionIntegrationToken
        knowledgeBaseCoordinator.loadFromSettings()
        updateSkillCatalogFilterButtons()
        refreshCompatibilityAppsLabel()
        refreshScreenshotSavePathLabel()
        permissionCoordinator.refreshStatus()
        permissionCoordinator.refreshCalendarAutomationStatusIfNeeded()
        refreshLearningDiagnostics()
        screenshotShortcutCoordinator.refreshDisplay()
        refreshCommerceUI()
        rebuildSkillCatalogViews()
    }

    @objc private func handleLanguageChanged() {
        guard !isLoadingSettings else { return }
        let index = max(0, languagePopup.indexOfSelectedItem)
        let language = AppLanguage.allCases[min(index, AppLanguage.allCases.count - 1)]
        guard settings.appLanguage != language else { return }
        settings.appLanguage = language
        showLanguageRestartAlert()
    }

    private func showLanguageRestartAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.text(
            zhHans: "语言已更新",
            en: "Language Updated"
        )
        alert.informativeText = L10n.format(
            zhHans: "为了让所有界面、技能和结果窗口完整切换到新语言，请重启 %@。",
            en: "Restart %@ to apply the new language across the full app, including skills and result windows.",
            productDisplayName
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.text(zhHans: "知道了", en: "OK"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func handleToggleAutoToolbar() {
        settings.textSelectionEnabled = (autoToolbarCheckbox.state == .on)
    }

    @objc private func handleToggleFileSelection() {
        settings.fileSelectionEnabled = (fileSelectionCheckbox.state == .on)
    }

    @objc private func handleToggleScreenshotEntry() {
        settings.screenshotEnabled = (screenshotEntryCheckbox.state == .on)
    }

    @objc private func handleToggleConversationBoxEntry() {
        settings.conversationBoxEnabled = (conversationBoxEntryCheckbox.state == .on)
    }

    @objc private func handleConfigureCompatibilityApps() {
        let picker = CompatibilityAppPickerWindowController(selectedBundleIDs: Set(settings.compatibilityBridgeBundleIDs))
        picker.onSave = { [weak self] bundleIDs in
            guard let self else { return }
            self.settings.compatibilityBridgeBundleIDs = bundleIDs
            self.refreshCompatibilityAppsLabel()
            self.compatibilityAppPicker = nil
        }
        picker.onClose = { [weak self] in
            self?.compatibilityAppPicker = nil
        }
        compatibilityAppPicker = picker
        if let window = self.window {
            picker.showAsSheet(for: window)
        } else {
            picker.showWindow(nil)
        }
    }

    @objc private func handleSelectScreenshotSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.screenshotSaveDirectoryURL
        panel.prompt = L10n.text(zhHans: "选择", en: "Choose")
        panel.message = L10n.text(zhHans: "选择截图保存目录", en: "Choose a screenshot save folder")
        if panel.runModal() == .OK, let url = panel.url {
            settings.screenshotSaveDirectoryPath = url.path
            refreshScreenshotSavePathLabel()
        }
    }

    @objc private func handleResetScreenshotSaveDirectory() {
        settings.screenshotSaveDirectoryPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .path
        refreshScreenshotSavePathLabel()
    }

    @objc private func handleToggleSkill(_ sender: NSButton) {
        guard !isLoadingSettings,
              let skillID = sender.identifier?.rawValue else { return }
        if skillRegistry.installedRecord(forSkillID: skillID) != nil {
            let result = packageManager.setEnabled(sender.state == .on, forSkillID: skillID)
            if case .failure = result {
                loadFromSettings()
            }
            return
        }
        actionRegistry.setEnabled(sender.state == .on, forSkillID: skillID, settings: settings)
    }

    @objc private func handleSkillCatalogFilterTap(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let value = Int(rawValue),
              let filter = SkillListFilter(rawValue: value) else { return }
        currentSkillCatalogFilter = filter
        updateSkillCatalogFilterButtons()
        rebuildSkillCatalogViews()
    }

    @objc private func handleRefreshSkillCatalog() {
        skillCatalogStatusLabel.stringValue = L10n.text(zhHans: "正在刷新技能目录...", en: "Refreshing skill catalog...")
        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.catalogService.refreshCatalog()
            await MainActor.run {
                self.skillRegistry.setCatalogSnapshot(snapshot)
                self.rebuildSkillCatalogViews(
                    status: snapshot.source == .remote
                        ? L10n.text(zhHans: "技能目录已刷新。", en: "Skill catalog refreshed.")
                        : (snapshot.errorMessage ?? L10n.text(zhHans: "技能目录已刷新。", en: "Skill catalog refreshed."))
                )
            }
        }
    }

    @objc private func handleCommerceStateChanged() {
        refreshCommerceUI()
    }

    @objc private func handleSkillRegistryReloaded() {
        loadFromSettings()
        if skillDetailPanel.isHidden == false {
            updateSkillDetailOverlay()
        }
    }

    @objc private func handleDismissSkillDetailOverlay() {
        dismissSkillDetailOverlay()
    }

    @objc private func handleSkillDetailPrimaryAction() {
        guard let item = selectedSkillDetailItem else { return }
        performPrimarySkillCatalogAction(item)
        updateSkillDetailOverlay()
    }

    @objc private func handleSkillDetailSecondaryAction() {
        guard let item = selectedSkillDetailItem else { return }
        performSecondarySkillCatalogAction(item)
        updateSkillDetailOverlay()
    }

    @objc private func handleSkillDetailTertiaryAction() {
        guard let item = selectedSkillDetailItem else { return }
        performTertiarySkillCatalogAction(item)
        if selectedSkillDetailItem == nil {
            dismissSkillDetailOverlay()
        } else {
            updateSkillDetailOverlay()
        }
    }

    @objc private func handleSkillDetailKnowledgeBaseToggle() {
        guard let item = selectedSkillDetailItem,
              item.installedDefinition?.usesKnowledgeBase == true else { return }
        let enabled = (skillDetailKnowledgeBaseCheckbox.state == .on)
        actionRegistry.setKnowledgeBaseEnabled(enabled, forSkillID: item.skillID, settings: settings)
        skillDetailFooterLabel.stringValue = enabled
            ? L10n.text(zhHans: "这个技能会在执行时引用知识库。", en: "This skill will use the knowledge base during execution.")
            : L10n.text(zhHans: "这个技能已关闭知识库引用。", en: "Knowledge base usage is disabled for this skill.")
        rebuildSkillCatalogViews()
        updateSkillDetailOverlay()
    }

    @objc private func handleKnowledgeBaseChanged() {
        if Thread.isMainThread {
            knowledgeBaseCoordinator.handleKnowledgeBaseChanged()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.knowledgeBaseCoordinator.handleKnowledgeBaseChanged()
            }
        }
    }

    @objc private func handleKnowledgeBaseAutoSyncChanged() {
        reloadKnowledgeBaseEntries()
    }

    @objc private func handleActionsScrollBoundsChanged() {
        refreshScrollIndicatorForCurrentTab(showTemporarily: true)
    }

    @objc private func handleSharedScrollBoundsChanged(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView else { return }
        switch clipView {
        case privacyScrollView.contentView:
            refreshScrollableTabLayout(scrollView: privacyScrollView, hostView: privacyContentHost, contentView: privacyContentStack)
        case membershipScrollView.contentView:
            refreshScrollableTabLayout(scrollView: membershipScrollView, hostView: membershipContentHost, contentView: membershipContentStack)
        case learningScrollView.contentView:
            refreshScrollableTabLayout(scrollView: learningScrollView, hostView: learningContentHost, contentView: learningContentStack)
        case knowledgeBaseScrollView.contentView:
            refreshKnowledgeBaseScrollLayout()
        default:
            return
        }
        refreshScrollIndicatorForCurrentTab(showTemporarily: true)
    }

    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        switch currentSelectedTab {
        case .actions:
            refreshActionsScrollLayout()
        case .automation:
            automationPageView.refreshScrollLayout()
        case .privacy:
            refreshScrollableTabLayout(scrollView: privacyScrollView, hostView: privacyContentHost, contentView: privacyContentStack)
        case .membership:
            refreshScrollableTabLayout(scrollView: membershipScrollView, hostView: membershipContentHost, contentView: membershipContentStack)
        case .learning:
            refreshScrollableTabLayout(scrollView: learningScrollView, hostView: learningContentHost, contentView: learningContentStack)
        case .knowledgeBase:
            refreshKnowledgeBaseScrollLayout()
        default:
            break
        }
    }

    private func refreshScreenshotSavePathLabel() {
        screenshotSavePathLabel.stringValue = settings.screenshotSaveDirectoryPath
    }

    private func refreshActionsScrollLayout() {
        guard window?.isVisible == true else { return }
        guard actionsPageStack.superview != nil else { return }

        actionsScrollView.superview?.layoutSubtreeIfNeeded()
        actionsScrollView.layoutSubtreeIfNeeded()
        actionsPageStack.layoutSubtreeIfNeeded()
        let visibleWidth = max(actionsScrollView.contentView.bounds.width, actionsScrollView.bounds.width)
        let containerWidth = actionsScrollView.superview?.bounds.width ?? 0
        let targetWidth = max(visibleWidth, containerWidth, 1)
        actionsContentViewHost.frame = NSRect(x: 0, y: 0, width: targetWidth, height: 10)
        actionsContentViewHost.layoutSubtreeIfNeeded()
        actionsPageStack.layoutSubtreeIfNeeded()

        let targetHeight = max(actionsPageStack.fittingSize.height + 20, actionsScrollView.contentSize.height)
        actionsContentViewHost.frame = NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        actionsContentViewHost.layoutSubtreeIfNeeded()

        let clipView = actionsScrollView.contentView
        let maxY = max(targetHeight - clipView.bounds.height, 0)
        let nextOrigin = NSPoint(x: 0, y: min(max(clipView.bounds.origin.y, 0), maxY))
        clipView.scroll(to: nextOrigin)
        actionsScrollView.reflectScrolledClipView(clipView)
        updateActionsScrollIndicator(showTemporarily: false)
        if ProcessInfo.processInfo.environment["NEXHUB_SETTINGS_LAYOUT_DEBUG"] == "1" {
            writeActionsLayoutDebugLog(reason: "refresh_layout")
        }
    }

    private func writeActionsLayoutDebugLog(reason: String) {
        let clipView = actionsScrollView.contentView
        let firstSkillRow = skillCatalogListStack.arrangedSubviews.first
        let behaviorCardFrame = actionsBehaviorCard.map { NSStringFromRect($0.frame) } ?? "nil"
        let behaviorCardFitting = actionsBehaviorCard.map { NSStringFromSize($0.fittingSize) } ?? "nil"
        let skillsCardFrame = actionsSkillsCard.map { NSStringFromRect($0.frame) } ?? "nil"
        let skillsCardFitting = actionsSkillsCard.map { NSStringFromSize($0.fittingSize) } ?? "nil"
        let lines: [String] = [
            "=== \(ISO8601DateFormatter().string(from: Date())) | \(reason) ===",
            "actionsScrollView frame=\(NSStringFromRect(actionsScrollView.frame)) bounds=\(NSStringFromRect(actionsScrollView.bounds)) contentSize=\(NSStringFromSize(actionsScrollView.contentSize))",
            "actionsScrollView hidden=\(actionsScrollView.isHidden) alpha=\(actionsScrollView.alphaValue)",
            "clipView frame=\(NSStringFromRect(clipView.frame)) bounds=\(NSStringFromRect(clipView.bounds))",
            "actionsContentViewHost frame=\(NSStringFromRect(actionsContentViewHost.frame)) fitting=\(NSStringFromSize(actionsContentViewHost.fittingSize))",
            "actionsPageStack frame=\(NSStringFromRect(actionsPageStack.frame)) fitting=\(NSStringFromSize(actionsPageStack.fittingSize))",
            "actionsPageStack subviews=\(actionsPageStack.arrangedSubviews.count)",
            "behaviorCard frame=\(behaviorCardFrame) fitting=\(behaviorCardFitting)",
            "skillsCard frame=\(skillsCardFrame) fitting=\(skillsCardFitting)",
            "skillCatalogListStack frame=\(NSStringFromRect(skillCatalogListStack.frame)) fitting=\(NSStringFromSize(skillCatalogListStack.fittingSize))",
            "skillCatalogListStack hidden=\(skillCatalogListStack.isHidden) rows=\(skillCatalogListStack.arrangedSubviews.count)",
            "firstSkillRow frame=\(firstSkillRow.map { NSStringFromRect($0.frame) } ?? "nil") fitting=\(firstSkillRow.map { NSStringFromSize($0.fittingSize) } ?? "nil")",
            "skillCatalogFilterStack frame=\(NSStringFromRect(skillCatalogFilterStack.frame)) fitting=\(NSStringFromSize(skillCatalogFilterStack.fittingSize))",
            "skillCatalogRefreshButton frame=\(NSStringFromRect(skillCatalogRefreshButton.frame)) fitting=\(NSStringFromSize(skillCatalogRefreshButton.fittingSize))",
            "compatibilityAppsButton frame=\(NSStringFromRect(compatibilityAppsButton.frame)) fitting=\(NSStringFromSize(compatibilityAppsButton.fittingSize))",
            "screenshotSavePathButton frame=\(NSStringFromRect(screenshotSavePathButton.frame)) fitting=\(NSStringFromSize(screenshotSavePathButton.fittingSize))",
            "screenshotSavePathResetButton frame=\(NSStringFromRect(screenshotSavePathResetButton.frame)) fitting=\(NSStringFromSize(screenshotSavePathResetButton.fittingSize))"
        ]
        diagnosticsLogger.log("settings.actions_layout", lines.joined(separator: "\n"))
    }

    private func updateActionsScrollIndicator(showTemporarily: Bool) {
        let visibleHeight = actionsScrollView.contentView.bounds.height
        let contentHeight = actionsContentViewHost.frame.height
        let offsetY = actionsScrollView.contentView.bounds.origin.y
        actionsScrollIndicator.update(contentHeight: contentHeight, visibleHeight: visibleHeight, offsetY: offsetY, showTemporarily: showTemporarily)
    }

    private func handleSharedScrollIndicatorRequested(_ targetOffset: CGFloat) {
        switch currentSelectedTab {
        case .actions:
            scrollSettingsTab(actionsScrollView, to: targetOffset)
        case .automation:
            automationPageView.scrollTo(offsetY: targetOffset)
        case .privacy:
            scrollSettingsTab(privacyScrollView, to: targetOffset)
        case .membership:
            scrollSettingsTab(membershipScrollView, to: targetOffset)
        case .learning:
            scrollSettingsTab(learningScrollView, to: targetOffset)
        case .knowledgeBase:
            scrollSettingsTab(knowledgeBaseScrollView, to: targetOffset)
        default:
            break
        }
    }

    private func scrollSettingsTab(_ scrollView: NSScrollView, to targetOffset: CGFloat) {
        let clipView = scrollView.contentView
        let contentHeight = scrollView.documentView?.frame.height ?? 0
        let maxOffset = max(contentHeight - clipView.bounds.height, 0)
        let clampedOffset = max(0, min(targetOffset, maxOffset))
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: clampedOffset))
        scrollView.reflectScrolledClipView(clipView)
        refreshScrollIndicatorForCurrentTab(showTemporarily: true)
    }

    private func resetScrollPositionIfNeeded(for tab: SettingsTab) {
        switch tab {
        case .actions:
            actionsScrollView.contentView.scroll(to: .zero)
            actionsScrollView.reflectScrolledClipView(actionsScrollView.contentView)
            refreshActionsScrollLayout()
            writeActionsLayoutDebugLog(reason: "select_actions")
        case .automation:
            automationPageView.resetScrollPosition()
        case .privacy:
            privacyScrollView.contentView.scroll(to: .zero)
            privacyScrollView.reflectScrolledClipView(privacyScrollView.contentView)
            refreshScrollableTabLayout(scrollView: privacyScrollView, hostView: privacyContentHost, contentView: privacyContentStack)
        case .membership:
            membershipScrollView.contentView.scroll(to: .zero)
            membershipScrollView.reflectScrolledClipView(membershipScrollView.contentView)
            refreshScrollableTabLayout(scrollView: membershipScrollView, hostView: membershipContentHost, contentView: membershipContentStack)
        case .learning:
            learningScrollView.contentView.scroll(to: .zero)
            learningScrollView.reflectScrolledClipView(learningScrollView.contentView)
            refreshScrollableTabLayout(scrollView: learningScrollView, hostView: learningContentHost, contentView: learningContentStack)
        case .knowledgeBase:
            knowledgeBaseScrollView.contentView.scroll(to: .zero)
            knowledgeBaseScrollView.reflectScrolledClipView(knowledgeBaseScrollView.contentView)
            renderKnowledgeBaseRows()
        default:
            break
        }
    }

    private func refreshScrollIndicatorForCurrentTab(showTemporarily: Bool) {
        switch currentSelectedTab {
        case .actions:
            updateActionsScrollIndicator(showTemporarily: showTemporarily)
        case .automation:
            automationPageView.updateSharedScrollIndicator(actionsScrollIndicator, showTemporarily: showTemporarily)
        case .privacy:
            updateSharedScrollIndicator(
                scrollView: privacyScrollView,
                contentHeight: privacyContentHost.frame.height,
                showTemporarily: showTemporarily
            )
        case .membership:
            updateSharedScrollIndicator(
                scrollView: membershipScrollView,
                contentHeight: membershipContentHost.frame.height,
                showTemporarily: showTemporarily
            )
        case .learning:
            updateSharedScrollIndicator(
                scrollView: learningScrollView,
                contentHeight: learningContentHost.frame.height,
                showTemporarily: showTemporarily
            )
        case .knowledgeBase:
            updateSharedScrollIndicator(
                scrollView: knowledgeBaseScrollView,
                contentHeight: knowledgeBaseContentViewHost.frame.height,
                showTemporarily: showTemporarily
            )
        default:
            actionsScrollIndicator.isHidden = true
        }
    }

    private func updateSharedScrollIndicator(
        scrollView: NSScrollView,
        contentHeight: CGFloat,
        showTemporarily: Bool
    ) {
        let visibleHeight = scrollView.contentView.bounds.height
        let offsetY = scrollView.contentView.bounds.origin.y
        actionsScrollIndicator.update(
            contentHeight: contentHeight,
            visibleHeight: visibleHeight,
            offsetY: offsetY,
            showTemporarily: showTemporarily
        )
    }

    private var selectedSkillDetailItem: SkillInventoryItem? {
        let allItems = skillRegistry.inventoryItems(settings: settings, filter: .all, query: "")
        guard let selectedSkillDetailID else { return nil }
        return allItems.first(where: { $0.skillID == selectedSkillDetailID })
    }

    private func presentSkillDetailOverlay(for skillID: String) {
        selectedSkillDetailID = skillID
        rebuildSkillCatalogViews()
        updateSkillDetailOverlay()
        skillDetailBackdropButton.isHidden = false
        skillDetailPanel.isHidden = false
        skillDetailBackdropButton.alphaValue = 0
        skillDetailPanel.alphaValue = 0
        refreshSkillDetailOverlayHoverTracking()
        postSettingsOverlayHoverContextDidChange()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            self.skillDetailBackdropButton.animator().alphaValue = 1
            self.skillDetailPanel.animator().alphaValue = 1
        }
    }

    private func dismissSkillDetailOverlay() {
        skillDetailBackdropButton.isHidden = true
        skillDetailPanel.isHidden = true
        skillDetailBackdropButton.alphaValue = 0
        skillDetailPanel.alphaValue = 0
        rebuildSkillCatalogViews()
        postSettingsOverlayHoverContextDidChange()
    }

    func updateSkillDetailOverlay() {
        guard let item = selectedSkillDetailItem else {
            dismissSkillDetailOverlay()
            return
        }

        let metaText = [
            item.sourceLabel,
            L10n.format(zhHans: "版本 %@", en: "Version %@", item.version),
            item.author.map { L10n.format(zhHans: "作者 %@", en: "By %@", $0) }
        ]
        .compactMap { $0 }
        .joined(separator: "  ·  ")

        let badges: [(SettingsSkillDetailBadgeView.Tone, String)] = [
            (.neutral, item.isInstalled ? (item.isEnabled ? L10n.text(zhHans: "已启用", en: "Enabled") : L10n.text(zhHans: "已禁用", en: "Disabled")) : L10n.text(zhHans: "未安装", en: "Not installed")),
            item.updateAvailable ? (.accent, L10n.text(zhHans: "有更新", en: "Update available")) : nil,
            item.installedDefinition?.usesKnowledgeBase == true ? (.neutral, L10n.text(zhHans: "可用知识库", en: "Knowledge Base")) : nil
        ]
        .compactMap { $0 }

        skillDetailHeaderView.configure(
            symbolName: item.symbolName,
            accentColor: detailIconColor(for: item),
            title: item.displayName,
            summary: item.summary,
            badges: badges,
            meta: metaText
        )

        skillDetailOverviewSection.configure(body: [
            L10n.format(zhHans: "来源：%@", en: "Source: %@", item.sourceLabel),
            L10n.format(zhHans: "状态：%@", en: "Status: %@", item.isInstalled ? (item.isEnabled ? L10n.text(zhHans: "已启用", en: "Enabled") : L10n.text(zhHans: "已禁用", en: "Disabled")) : L10n.text(zhHans: "未安装", en: "Not installed")),
            L10n.format(zhHans: "执行位置：%@", en: "Execution: %@", detailLocalityLabel(for: item.locality)),
            L10n.format(zhHans: "权限：%@", en: "Permissions: %@", item.permissions.isEmpty ? L10n.text(zhHans: "无额外权限声明", en: "No extra permissions declared") : item.permissions.map(detailPermissionLabel(for:)).joined(separator: " · "))
        ].joined(separator: "\n"))

        if item.installedDefinition?.usesKnowledgeBase == true {
            let knowledgeBaseEntries = knowledgeBaseStore.entries()
            let enabled = actionRegistry.isKnowledgeBaseEnabled(item.skillID, settings: settings)
            skillDetailKnowledgeBaseSection.isHidden = false
            skillDetailKnowledgeBaseSection.configure(
                body: knowledgeBaseEntries.isEmpty
                    ? L10n.text(zhHans: "当前还没有知识库资料。导入资料后，这个技能可以在执行前先检索命中的知识片段。", en: "There is no knowledge base content yet. After importing content, this skill can search matching snippets before execution.")
                    : L10n.format(zhHans: "当前已导入 %d 份资料，%@这个技能的知识库引用。", en: "%d knowledge item(s) are imported and knowledge base usage for this skill is currently %@.", knowledgeBaseEntries.count, enabled ? L10n.text(zhHans: "已启用", en: "enabled") : L10n.text(zhHans: "已关闭", en: "disabled"))
            )
            skillDetailKnowledgeBaseCheckbox.isHidden = false
            skillDetailKnowledgeBaseCheckbox.state = enabled ? .on : .off
        } else {
            skillDetailKnowledgeBaseSection.isHidden = true
            skillDetailKnowledgeBaseCheckbox.isHidden = true
        }

        skillDetailPrimaryButton.title = detailPrimaryActionTitle(for: item)
        skillDetailPrimaryButton.isEnabled = item.updateAvailable || !item.isInstalled
        skillDetailSecondaryButton.isHidden = !item.isInstalled
        skillDetailSecondaryButton.title = item.isEnabled ? L10n.text(zhHans: "禁用", en: "Disable") : L10n.text(zhHans: "启用", en: "Enable")
        skillDetailTertiaryButton.isHidden = !(item.installedDefinition?.skillSource == .installed || item.installedRecord != nil)
        skillDetailFooterLabel.stringValue = item.updateAvailable ? L10n.text(zhHans: "有新版本可用。", en: "A newer version is available.") : ""
    }

    private func refreshSkillDetailOverlayHoverTracking() {
        [skillDetailPrimaryButton, skillDetailSecondaryButton, skillDetailTertiaryButton].forEach {
            $0.updateTrackingAreas()
        }
        skillDetailCloseButton.updateTrackingAreas()
        skillDetailCloseButton.needsDisplay = true
    }

    private func detailPrimaryActionTitle(for item: SkillInventoryItem) -> String {
        if item.updateAvailable { return L10n.text(zhHans: "更新", en: "Update") }
        if !item.isInstalled { return L10n.text(zhHans: "获取", en: "Get") }
        return L10n.text(zhHans: "已安装", en: "Installed")
    }

    private func detailIconColor(for item: SkillInventoryItem) -> NSColor {
        if item.updateAvailable {
            return DesignTokens.SkillCenter.Detail.updateIconTint
        }
        if item.isInstalled {
            return DesignTokens.Color.iconPrimary
        }
        return DesignTokens.Color.textSecondary
    }

    private func detailLocalityLabel(for locality: SkillExecutionLocality) -> String {
        switch locality {
        case .localOnly: return L10n.text(zhHans: "本地", en: "Local")
        case .localFirst: return L10n.text(zhHans: "本地优先", en: "Local First")
        case .hybrid: return L10n.text(zhHans: "混合", en: "Hybrid")
        case .cloudOnly: return L10n.text(zhHans: "云端", en: "Cloud")
        }
    }

    private func detailPermissionLabel(for permission: SkillPermissionKind) -> String {
        switch permission {
        case .readSelectedText: return L10n.text(zhHans: "读文本", en: "Read Text")
        case .readSelectedFiles: return L10n.text(zhHans: "读文件", en: "Read Files")
        case .readScreenshotImage: return L10n.text(zhHans: "读截图", en: "Read Screenshot")
        case .writeClipboard: return L10n.text(zhHans: "写剪贴板", en: "Write Clipboard")
        case .writeFiles: return L10n.text(zhHans: "写文件", en: "Write Files")
        case .useCloudExecution: return L10n.text(zhHans: "云执行", en: "Cloud Execution")
        case .accessWeb: return L10n.text(zhHans: "访问网页", en: "Access Web")
        }
    }

    func refreshCommerceUI() {
        membershipPresenter.refresh(
            entitlementSnapshot: membershipTabCoordinator.entitlementSnapshot(),
            redemptionHistoryText: commerceService.redemptionHistoryText()
        )
    }

    @objc private func handleLaunchAtLoginToggle() {
        let enabled = launchAtLoginCheckbox.state == .on
        settings.launchAtLoginPreferred = enabled
        onRequestLaunchAtLoginToggle?(enabled)
    }

    @objc private func handleDismissOutsideToggle() {
        settings.dismissOnOutsideClick = (dismissOutsideCheckbox.state == .on)
    }

    @objc private func handleProviderChanged() {
        guard !isLoadingSettings else { return }
        aiConfigurationCoordinator.handleProviderChanged()
    }

    @objc private func handleModelChanged() {
        guard !isLoadingSettings else { return }
        aiConfigurationCoordinator.handleModelChanged()
    }

    @objc private func handleValidateAIConfig() {
        aiConfigurationCoordinator.validate()
    }

    @objc private func handleRefreshLearningDiagnostics() {
        refreshLearningDiagnostics()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isLoadingSettings else { return }
        guard let field = obj.object as? NSTextField else { return }
        if field === apiKeyField {
            aiConfigurationCoordinator.handleAPIKeyChanged()
        } else if field === knowledgeBaseSearchField {
            knowledgeBaseCoordinator.handleSearchQueryChanged(knowledgeBaseSearchField.stringValue)
            resetKnowledgeBaseScrollPosition()
        } else if field === knowledgeBaseNotionTokenField {
            updateKnowledgeBaseStatusMessage(nil)
            setKnowledgeBaseNotionFeedback(nil, isError: false)
        } else if field === inviteCodeField {
            inviteResultLabel.stringValue = ""
        }
    }

    private func activateForPermissionPrompt() {
        window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func handleGatewayRuntimeStatusChanged(_ notification: Notification) {
        aiConfigurationCoordinator.handleGatewayRuntimeStatusChanged(aiTabCoordinator.runtimeSnapshot())
    }

    @objc private func handleSecureStorageFailure(_ notification: Notification) {
        guard let failure = notification.object as? AppSettingsSecureStorageFailure else { return }
        if failure.settingKey == SettingKey.notionIntegrationToken {
            setKnowledgeBaseNotionFeedback(
                AppSettingsError.secureStorageFailed(settingKey: failure.settingKey).localizedDescription,
                isError: true
            )
            return
        }
        aiConfigurationCoordinator.handleSecureStorageFailure(failure)
    }

    private func signingSummary() -> String {
        guard let bundlePath = Bundle.main.bundlePath.removingPercentEncoding else {
            return "unknown"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=2", bundlePath]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return "unknown" }
            if output.contains("Signature=adhoc") {
                return L10n.text(zhHans: "adhoc（可能导致重装后掉授权）", en: "adhoc (may drop permissions after reinstall)")
            }
            let authority = output
                .split(separator: "\n")
                .first(where: { $0.hasPrefix("Authority=") })?
                .replacingOccurrences(of: "Authority=", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return authority ?? "signed"
        } catch {
            return "unknown"
        }
    }

    private func refreshCompatibilityAppsLabel() {
        let selected = settings.compatibilityBridgeBundleIDs
        guard !selected.isEmpty else {
            compatibilityAppsLabel.stringValue = L10n.text(zhHans: "当前未启用兼容抓取应用。", en: "No compatibility capture apps are enabled.")
            return
        }

        let known = RunningApplicationCatalog.currentApplicationsByBundleID()
        let names = selected.prefix(5).map { bundleID in
            known[bundleID]?.displayName
                ?? RunningApplicationCatalog.fallbackDisplayName(for: bundleID)
                ?? bundleID
        }
        compatibilityAppsLabel.stringValue = L10n.Settings.General.compatibilityAppsSummary(
            names: Array(names),
            totalCount: selected.count
        )
    }

}

package final class SettingsFlippedView: NSView {
    package override var isFlipped: Bool { true }
}

package final class OverlayScrollIndicatorView: NSView {
    private let thumbView = NSView()
    private var hideWorkItem: DispatchWorkItem?
    private var trackingAreaRef: NSTrackingArea?
    private var contentHeight: CGFloat = 0
    private var visibleHeight: CGFloat = 0
    private var offsetY: CGFloat = 0
    private var isHovered = false
    private var isDragging = false
    private var dragThumbOffsetY: CGFloat = 0
    package var onScrollRequested: ((CGFloat) -> Void)?

    package override var isFlipped: Bool { true }
    package override var mouseDownCanMoveWindow: Bool { false }

    package override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        thumbView.translatesAutoresizingMaskIntoConstraints = true
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = DesignTokens.ScrollIndicator.cornerRadius
        thumbView.layer?.backgroundColor = NSColor.white.withAlphaComponent(DesignTokens.ScrollIndicator.idleAlpha).cgColor
        thumbView.alphaValue = 0
        addSubview(thumbView)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package func update(contentHeight: CGFloat, visibleHeight: CGFloat, offsetY: CGFloat, showTemporarily: Bool) {
        hideWorkItem?.cancel()
        self.contentHeight = contentHeight
        self.visibleHeight = visibleHeight
        self.offsetY = offsetY

        guard contentHeight > visibleHeight + 1, visibleHeight > 0, bounds.height > 0 else {
            isHidden = true
            thumbView.alphaValue = 0
            return
        }

        isHidden = false
        let trackHeight = bounds.height
        let ratio = max(min(visibleHeight / contentHeight, 1), 0)
        let thumbHeight = max(trackHeight * ratio, DesignTokens.ScrollIndicator.minThumbHeight)
        let maxOffset = max(contentHeight - visibleHeight, 1)
        let progress = max(min(offsetY / maxOffset, 1), 0)
        let thumbY = (trackHeight - thumbHeight) * progress
        thumbView.frame = NSRect(
            x: DesignTokens.ScrollIndicator.trackInset,
            y: thumbY,
            width: max(bounds.width - (DesignTokens.ScrollIndicator.trackInset * 2), DesignTokens.ScrollIndicator.width),
            height: thumbHeight
        )
        refreshThumbAppearance(showTemporarily: showTemporarily)
    }

    package override func layout() {
        super.layout()
        if !isHidden {
            thumbView.frame.size.width = max(
                bounds.width - (DesignTokens.ScrollIndicator.trackInset * 2),
                DesignTokens.ScrollIndicator.width
            )
        }
    }

    package override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    package override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        refreshThumbAppearance(showTemporarily: false)
    }

    package override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard !isDragging else { return }
        isHovered = false
        refreshThumbAppearance(showTemporarily: true)
    }

    package override func mouseDown(with event: NSEvent) {
        guard canInteract else { return }
        isHovered = true
        refreshThumbAppearance(showTemporarily: false)
        let location = convert(event.locationInWindow, from: nil)
        if thumbView.frame.contains(location) {
            isDragging = true
            dragThumbOffsetY = location.y - thumbView.frame.minY
            requestScroll(for: location, mode: .drag)
        } else {
            isDragging = false
            let mode: ScrollRequestMode = location.y > thumbView.frame.maxY ? .trackAfter : .trackBefore
            requestScroll(for: location, mode: mode)
        }
    }

    package override func mouseDragged(with event: NSEvent) {
        guard canInteract, isDragging else { return }
        let location = convert(event.locationInWindow, from: nil)
        requestScroll(for: location, mode: .drag)
    }

    package override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        isDragging = false
        dragThumbOffsetY = 0
        let location = convert(event.locationInWindow, from: nil)
        isHovered = bounds.contains(location)
        refreshThumbAppearance(showTemporarily: !isHovered)
    }

    private var canInteract: Bool {
        !isHidden && contentHeight > visibleHeight + 1 && visibleHeight > 0 && bounds.height > 0
    }

    private enum ScrollRequestMode {
        case drag
        case trackBefore
        case trackAfter
    }

    private func requestScroll(for location: CGPoint, mode: ScrollRequestMode) {
        let thumbHeight = thumbView.frame.height
        let trackHeight = bounds.height
        guard trackHeight > thumbHeight else {
            onScrollRequested?(0)
            return
        }
        let rawY: CGFloat
        switch mode {
        case .drag:
            rawY = location.y - dragThumbOffsetY
        case .trackBefore:
            rawY = location.y
        case .trackAfter:
            rawY = location.y - thumbHeight
        }
        let clampedY = max(0, min(rawY, trackHeight - thumbHeight))
        let progress = clampedY / max(trackHeight - thumbHeight, 1)
        let targetOffset = progress * max(contentHeight - visibleHeight, 0)
        onScrollRequested?(targetOffset)
        update(contentHeight: contentHeight, visibleHeight: visibleHeight, offsetY: targetOffset, showTemporarily: true)
    }

    private func refreshThumbAppearance(showTemporarily: Bool) {
        let emphasized = isDragging || isHovered
        thumbView.layer?.backgroundColor = NSColor.white.withAlphaComponent(
            emphasized ? DesignTokens.ScrollIndicator.emphasizedAlpha : DesignTokens.ScrollIndicator.idleAlpha
        ).cgColor
        thumbView.layer?.cornerRadius = emphasized
            ? DesignTokens.ScrollIndicator.emphasizedCornerRadius
            : DesignTokens.ScrollIndicator.cornerRadius

        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.ScrollIndicator.showAnimationDuration
            thumbView.animator().alphaValue = emphasized ? 1 : (showTemporarily ? 1 : 0)
        }

        guard !emphasized, showTemporarily else { return }
        let workItem = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DesignTokens.ScrollIndicator.hideAnimationDuration
                self?.thumbView.animator().alphaValue = 0
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.ScrollIndicator.hideDelay, execute: workItem)
    }
}

package typealias SettingsScrollIndicatorView = OverlayScrollIndicatorView

private final class SettingsSidebarItemView: NSView {
    private let backgroundView = NSView()
    private let button: SettingsSidebarButton
    private var isSelectedState = false

    init(button: SettingsSidebarButton) {
        self.button = button
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = DesignTokens.Settings.Sidebar.itemCornerRadius
        backgroundView.layer?.backgroundColor = DesignTokens.Settings.Sidebar.selectedFill.cgColor
        backgroundView.layer?.borderWidth = DesignTokens.Settings.Card.borderWidth
        backgroundView.layer?.borderColor = DesignTokens.Settings.Sidebar.selectedBorder.cgColor
        backgroundView.isHidden = true

        addSubview(backgroundView)
        addSubview(button)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Settings.Sidebar.itemHeight),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Settings.Sidebar.itemInsetVertical),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Settings.Sidebar.itemInsetVertical),

            button.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: DesignTokens.Settings.Sidebar.itemInsetLeading),
            button.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -DesignTokens.Settings.Sidebar.itemInsetTrailing),
            button.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: DesignTokens.Settings.Card.borderWidth),
            button.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -DesignTokens.Settings.Card.borderWidth),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        isSelectedState = selected
        backgroundView.isHidden = !selected
        backgroundView.layer?.backgroundColor = DesignTokens.Settings.Sidebar.selectedFill.cgColor
        backgroundView.layer?.borderWidth = selected ? 0 : DesignTokens.Settings.Card.borderWidth
        backgroundView.layer?.borderColor = DesignTokens.Settings.Sidebar.selectedBorder.cgColor
    }
}

final class SettingsSkillDetailPanelView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.SkillCenter.Overlay.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = DesignTokens.SkillCenter.Detail.surface.cgColor
        layer?.borderWidth = DesignTokens.SkillCenter.Overlay.borderWidth
        layer?.borderColor = DesignTokens.SkillCenter.Detail.surfaceBorder.cgColor
        layer?.shadowColor = DesignTokens.SkillCenter.Overlay.shadowColor.cgColor
        layer?.shadowOpacity = DesignTokens.SkillCenter.Overlay.shadowOpacity
        layer?.shadowRadius = DesignTokens.SkillCenter.Overlay.shadowRadius
        layer?.shadowOffset = DesignTokens.SkillCenter.Overlay.shadowOffset
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class SettingsSkillDetailIconButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.text(zhHans: "关闭", en: "Close"))
        contentTintColor = DesignTokens.Color.textSecondary
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        let borderColor: NSColor
        let tintColor: NSColor

        if isHighlighted {
            backgroundColor = DesignTokens.Settings.Button.pressedSurface
            borderColor = DesignTokens.Settings.Button.pressedBorder
            tintColor = DesignTokens.Color.textPrimary
        } else if isHovering {
            backgroundColor = DesignTokens.Settings.Button.hoverSurface
            borderColor = DesignTokens.Settings.Button.hoverBorder
            tintColor = DesignTokens.Color.textPrimary
        } else {
            backgroundColor = DesignTokens.Settings.Input.surface
            borderColor = DesignTokens.Settings.Input.border
            tintColor = DesignTokens.Color.textSecondary
        }

        layer?.cornerRadius = DesignTokens.Settings.Input.cornerRadius
        layer?.borderWidth = DesignTokens.Settings.Input.borderWidth
        layer?.borderColor = borderColor.cgColor
        layer?.backgroundColor = backgroundColor.cgColor
        contentTintColor = tintColor
    }
}

private final class SettingsSkillDetailBadgeView: NSView {
    enum Tone {
        case accent
        case neutral
    }

    init(tone: Tone, text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.SkillCenter.Badge.cornerRadius
        layer?.borderWidth = DesignTokens.SkillCenter.Badge.borderWidth
        let style: DesignTokens.SkillCenter.BadgeStyle = switch tone {
        case .accent:
            DesignTokens.SkillCenter.Badge.accent
        case .neutral:
            DesignTokens.SkillCenter.Badge.neutral
        }
        layer?.backgroundColor = style.fill.cgColor
        layer?.borderColor = style.border.cgColor

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = DesignTokens.SkillCenter.Badge.font
        label.textColor = style.text
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.SkillCenter.Badge.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.SkillCenter.Badge.horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.SkillCenter.Badge.verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.SkillCenter.Badge.verticalPadding),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class SettingsSkillDetailHeaderView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let badgeRow = NSStackView()
    private let metaLabel = NSTextField(labelWithString: "")
    private var closeButtonConstraintSet = false

    var closeButton: NSButton? {
        didSet {
            guard let closeButton, closeButton !== oldValue else { return }
            if closeButton.superview !== self {
                addSubview(closeButton)
            }
            if !closeButtonConstraintSet {
                closeButton.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    closeButton.topAnchor.constraint(equalTo: topAnchor),
                    closeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
                    closeButton.widthAnchor.constraint(equalToConstant: DesignTokens.SkillCenter.Detail.closeButtonSize),
                    closeButton.heightAnchor.constraint(equalToConstant: DesignTokens.SkillCenter.Detail.closeButtonSize),
                ])
                closeButtonConstraintSet = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeRow.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = DesignTokens.SkillCenter.Detail.titleFont
        titleLabel.textColor = DesignTokens.SkillCenter.Detail.titleText
        summaryLabel.font = DesignTokens.SkillCenter.Detail.summaryFont
        summaryLabel.textColor = DesignTokens.SkillCenter.Detail.summaryText
        summaryLabel.maximumNumberOfLines = 2
        badgeRow.orientation = .horizontal
        badgeRow.alignment = .centerY
        badgeRow.spacing = DesignTokens.SkillCenter.Detail.badgeSpacing
        metaLabel.font = DesignTokens.SkillCenter.Detail.metaFont
        metaLabel.textColor = DesignTokens.SkillCenter.Detail.metaText

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(summaryLabel)
        addSubview(badgeRow)
        addSubview(metaLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: DesignTokens.SkillCenter.Detail.headerMinHeight),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: DesignTokens.SkillCenter.Detail.headerIconSize),
            iconView.heightAnchor.constraint(equalToConstant: DesignTokens.SkillCenter.Detail.headerIconSize),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: DesignTokens.SkillCenter.Detail.headerLeadingSpacing),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -52),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),

            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.SkillCenter.Detail.summarySpacing),

            badgeRow.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            badgeRow.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: DesignTokens.Spacing.md),
            badgeRow.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.trailingAnchor),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: badgeRow.bottomAnchor, constant: DesignTokens.SkillCenter.Detail.metaSpacing),
            metaLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(symbolName: String, accentColor: NSColor, title: String, summary: String, badges: [(SettingsSkillDetailBadgeView.Tone, String)], meta: String) {
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        iconView.contentTintColor = accentColor
        titleLabel.stringValue = title
        summaryLabel.stringValue = summary
        metaLabel.stringValue = meta

        badgeRow.arrangedSubviews.forEach {
            badgeRow.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for badge in badges {
            badgeRow.addArrangedSubview(SettingsSkillDetailBadgeView(tone: badge.0, text: badge.1))
        }
    }
}

private class SettingsSkillDetailSectionView: NSView {
    fileprivate let titleLabel = NSTextField(labelWithString: "")
    fileprivate let contentContainer = NSView()

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyCardSurface(to: self)

        titleLabel.stringValue = title
        titleLabel.font = DesignTokens.SkillCenter.Detail.Section.titleFont
        titleLabel.textColor = DesignTokens.Color.textSecondary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(contentContainer)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.SkillCenter.Detail.Section.inset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.SkillCenter.Detail.Section.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.SkillCenter.Detail.Section.inset),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.SkillCenter.Detail.Section.inset),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.SkillCenter.Detail.Section.inset),
            contentContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.SkillCenter.Detail.Section.titleBodySpacing),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.SkillCenter.Detail.Section.inset),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(body: String) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.font = DesignTokens.SkillCenter.Detail.Section.bodyFont
        bodyLabel.textColor = DesignTokens.SkillCenter.Detail.summaryText
        bodyLabel.maximumNumberOfLines = 0
        contentContainer.addSubview(bodyLabel)

        NSLayoutConstraint.activate([
            bodyLabel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            bodyLabel.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }
}

private extension Notification.Name {
    static let settingsOverlayHoverContextDidChange = Notification.Name("SettingsOverlayHoverContextDidChange")
}

private func postSettingsOverlayHoverContextDidChange() {
    NotificationCenter.default.post(name: .settingsOverlayHoverContextDidChange, object: nil)
}

private func activeSkillDetailPanel(in window: NSWindow?) -> SettingsSkillDetailPanelView? {
    guard let root = window?.contentView else { return nil }
    return firstVisibleDescendant(of: root, as: SettingsSkillDetailPanelView.self)
}

private func firstVisibleDescendant<T: NSView>(of root: NSView, as type: T.Type) -> T? {
    if let typedRoot = root as? T, typedRoot.isHidden == false, typedRoot.alphaValue > 0.01 {
        return typedRoot
    }
    for subview in root.subviews {
        if let match = firstVisibleDescendant(of: subview, as: type) {
            return match
        }
    }
    return nil
}

private func isDescendantView(_ view: NSView, of ancestor: NSView) -> Bool {
    var current: NSView? = view
    while let candidate = current {
        if candidate === ancestor {
            return true
        }
        current = candidate.superview
    }
    return false
}

private func isSettingsHoverSuppressed(for view: NSView?) -> Bool {
    guard let view,
          let detailPanel = activeSkillDetailPanel(in: view.window) else {
        return false
    }
    return !isDescendantView(view, of: detailPanel)
}

private final class SettingsSidebarButton: NSButton {
    private var isSelectedState = false
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false
    private let displayTitle: String
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(title: String, symbol: SettingsWindowController.SidebarSymbolSpec) {
        self.displayTitle = title
        super.init(frame: .zero)

        self.title = ""
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        image = nil

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: title)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: symbol.pointSize,
            weight: symbol.weight,
            scale: symbol.scale
        )
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = DesignTokens.Typography.settingsSidebarTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: DesignTokens.Spacing.md),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setSelected(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        isSelectedState = selected
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateAppearance() {
        let selected = isSelectedState
        let color: NSColor
        if selected {
            color = DesignTokens.Settings.Sidebar.selectedText
        } else if isHovering {
            color = DesignTokens.Settings.Sidebar.hoverText
        } else {
            color = DesignTokens.Settings.Sidebar.defaultText
        }
        iconView.contentTintColor = color
        titleLabel.textColor = color
        toolTip = displayTitle
    }
}

package enum SettingsControlStyle {
    package enum ActionButtonSize {
        case compact
        case inputAligned
        case catalogPrimary
        case catalogSecondary
        case textOnly

        var height: CGFloat {
            switch self {
            case .compact:
                return DesignTokens.Settings.compactControlHeight
            case .inputAligned:
                return DesignTokens.Settings.controlHeight
            case .catalogPrimary:
                return DesignTokens.Settings.Button.catalogPrimaryHeight
            case .catalogSecondary:
                return DesignTokens.Settings.Button.catalogSecondaryHeight
            case .textOnly:
                return DesignTokens.Settings.Button.textOnlyHeight
            }
        }

        var minimumWidth: CGFloat {
            switch self {
            case .compact, .inputAligned:
                return DesignTokens.Settings.Button.minimumWidth
            case .catalogPrimary:
                return DesignTokens.Settings.Button.catalogPrimaryMinimumWidth
            case .catalogSecondary:
                return DesignTokens.Settings.Button.catalogSecondaryMinimumWidth
            case .textOnly:
                return 0
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .compact, .inputAligned:
                return DesignTokens.Settings.Button.horizontalPadding
            case .catalogPrimary:
                return DesignTokens.Settings.Button.catalogPrimaryHorizontalPadding
            case .catalogSecondary:
                return DesignTokens.Settings.Button.catalogSecondaryHorizontalPadding
            case .textOnly:
                return DesignTokens.Settings.Button.textOnlyHorizontalPadding
            }
        }
    }

    package enum ActionButtonVisualStyle {
        case standard
        case accentPrimary
        case ghostSecondary
        case textAction
    }

    private static let controlHeightConstraintIdentifier = "settings-control-height"
    private static let controlMinWidthConstraintIdentifier = "settings-control-min-width"

    private static func installHeightConstraint(on view: NSView, height: CGFloat) {
        if let constraint = view.constraints.first(where: { $0.identifier == controlHeightConstraintIdentifier }) {
            constraint.constant = height
            return
        }
        let constraint = view.heightAnchor.constraint(equalToConstant: height)
        constraint.identifier = controlHeightConstraintIdentifier
        constraint.isActive = true
    }

    private static func installMinWidthConstraint(on view: NSView, width: CGFloat) {
        if let constraint = view.constraints.first(where: { $0.identifier == controlMinWidthConstraintIdentifier }) {
            constraint.constant = width
            constraint.isActive = width > 0
            return
        }
        let constraint = view.widthAnchor.constraint(greaterThanOrEqualToConstant: width)
        constraint.identifier = controlMinWidthConstraintIdentifier
        constraint.isActive = width > 0
    }

    package static func applyCardSurface(to view: NSView, hovered: Bool = false) {
        view.wantsLayer = true
        view.layer?.cornerRadius = DesignTokens.Settings.Card.cornerRadius
        view.layer?.borderWidth = DesignTokens.Settings.Card.borderWidth
        view.layer?.borderColor = (hovered
            ? DesignTokens.Settings.Card.hoverBorder
            : DesignTokens.Settings.Card.border).cgColor
        view.layer?.backgroundColor = (hovered
            ? DesignTokens.Settings.Card.hoverSurface
            : DesignTokens.Settings.Card.surface).cgColor
    }

    package static func applyActionButton(
        _ button: NSButton,
        size: ActionButtonSize = .compact,
        style: ActionButtonVisualStyle = .standard
    ) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.controlSize = .regular
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.font = DesignTokens.Typography.settingsButtonLabel
        button.contentTintColor = DesignTokens.Color.textPrimary
        button.wantsLayer = true
        button.layer?.masksToBounds = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        SettingsActionButtonHoverTracker.install(on: button)
        if let button = button as? SettingsActionButton {
            button.actionButtonSize = size
            button.actionButtonVisualStyle = style
        }
        refreshActionButtonAppearance(button)
        installHeightConstraint(on: button, height: size.height)
        installMinWidthConstraint(on: button, width: size.minimumWidth)
        (button as? SettingsActionButton)?.invalidateIntrinsicContentSize()
    }

    package static func applyCheckbox(_ button: NSButton) {
        button.font = DesignTokens.Typography.settingsControlValue
        guard !button.title.isEmpty else { return }
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .font: DesignTokens.Typography.settingsControlValue,
                .foregroundColor: DesignTokens.Color.textPrimary
            ]
        )
    }

    package static func refreshActionButtonAppearance(_ button: NSButton) {
        let isHovering = SettingsActionButtonHoverTracker.isHovering(for: button)
        let isSubtleSecondary = button.identifier?.rawValue == "ai-secondary-subtle"
        let visualStyle = (button as? SettingsActionButton)?.actionButtonVisualStyle ?? .standard
        let backgroundColor: NSColor
        let borderColor: NSColor

        switch visualStyle {
        case .standard:
            if !button.isEnabled {
                backgroundColor = DesignTokens.Settings.Button.disabledSurface
                borderColor = DesignTokens.Settings.Button.disabledBorder
            } else if button.isHighlighted {
                backgroundColor = isSubtleSecondary
                    ? DesignTokens.Settings.Button.pressedSurface.withAlphaComponent(0.42)
                    : DesignTokens.Settings.Button.pressedSurface
                borderColor = isSubtleSecondary
                    ? DesignTokens.Settings.Button.pressedBorder.withAlphaComponent(0.22)
                    : DesignTokens.Settings.Button.pressedBorder
            } else if isHovering {
                backgroundColor = isSubtleSecondary
                    ? DesignTokens.Settings.Button.hoverSurface.withAlphaComponent(0.28)
                    : DesignTokens.Settings.Button.hoverSurface
                borderColor = isSubtleSecondary
                    ? DesignTokens.Settings.Button.hoverBorder.withAlphaComponent(0.28)
                    : DesignTokens.Settings.Button.hoverBorder
            } else {
                backgroundColor = isSubtleSecondary
                    ? DesignTokens.Settings.Button.surface.withAlphaComponent(0.18)
                    : DesignTokens.Settings.Button.surface
                borderColor = isSubtleSecondary
                    ? DesignTokens.Settings.Button.border.withAlphaComponent(0.22)
                    : DesignTokens.Settings.Button.border
            }
        case .accentPrimary:
            backgroundColor = button.isEnabled
                ? (isHovering ? DesignTokens.Settings.Button.accentHoverSurface : DesignTokens.Settings.Button.accentSurface)
                : DesignTokens.Settings.Button.accentSurface.withAlphaComponent(0.55)
            borderColor = button.isEnabled
                ? (isHovering ? DesignTokens.Settings.Button.accentHoverBorder : DesignTokens.Settings.Button.accentBorder)
                : DesignTokens.Settings.Button.accentBorder.withAlphaComponent(0.6)
        case .ghostSecondary:
            backgroundColor = button.isEnabled
                ? (isHovering ? DesignTokens.Settings.Button.ghostHoverSurface : DesignTokens.Settings.Button.ghostSurface)
                : DesignTokens.Settings.Button.ghostSurface
            borderColor = button.isEnabled
                ? (isHovering ? DesignTokens.Settings.Button.ghostHoverBorder : DesignTokens.Settings.Button.ghostBorder)
                : DesignTokens.Settings.Button.ghostBorder
        case .textAction:
            backgroundColor = .clear
            borderColor = .clear
        }

        let cornerRadius: CGFloat = switch visualStyle {
        case .standard:
            DesignTokens.Settings.Button.cornerRadius
        case .accentPrimary:
            DesignTokens.Settings.Button.catalogPrimaryCornerRadius
        case .ghostSecondary:
            DesignTokens.Settings.Button.catalogSecondaryCornerRadius
        case .textAction:
            0
        }
        let borderWidth: CGFloat = switch visualStyle {
        case .textAction:
            0
        case .ghostSecondary:
            0
        case .standard, .accentPrimary:
            DesignTokens.Settings.Button.borderWidth
        }

        button.layer?.cornerRadius = cornerRadius
        button.layer?.borderWidth = borderWidth
        button.layer?.borderColor = borderColor.cgColor
        button.layer?.backgroundColor = backgroundColor.cgColor
        let titleColor: NSColor = switch visualStyle {
        case .standard, .accentPrimary:
            button.isEnabled
                ? DesignTokens.Color.textPrimary
                : DesignTokens.Settings.Button.disabledText
        case .ghostSecondary:
            button.isEnabled
                ? (isHovering ? DesignTokens.Settings.Button.ghostHoverText : DesignTokens.Settings.Button.ghostText)
                : DesignTokens.Settings.Button.textActionDisabled
        case .textAction:
            button.isEnabled
                ? (isHovering ? DesignTokens.Settings.Button.textActionHover : DesignTokens.Settings.Button.textAction)
                : DesignTokens.Settings.Button.textActionDisabled
        }
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .font: button.font ?? DesignTokens.Typography.settingsButtonLabel,
                .foregroundColor: titleColor
            ]
        )
        button.needsDisplay = true
    }

    package static func applyInputField(_ field: NSTextField) {
        field.focusRingType = .none
        field.font = DesignTokens.Typography.settingsControlValue
        field.textColor = DesignTokens.Color.inputText
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.wantsLayer = true
        field.layer?.cornerRadius = DesignTokens.Settings.Input.cornerRadius
        field.layer?.borderWidth = DesignTokens.Settings.Input.borderWidth
        field.layer?.borderColor = DesignTokens.Settings.Input.border.cgColor
        field.layer?.backgroundColor = DesignTokens.Settings.Input.surface.cgColor
        if let cell = field.cell as? NSTextFieldCell {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byClipping
            cell.placeholderAttributedString = NSAttributedString(
                string: field.placeholderString ?? "",
                attributes: [
                    .foregroundColor: DesignTokens.Color.inputPlaceholder,
                    .font: DesignTokens.Typography.settingsControlValue,
                    .paragraphStyle: paragraphStyle
                ]
            )
            cell.lineBreakMode = .byClipping
            cell.wraps = false
            cell.isScrollable = true
        }
        installHeightConstraint(on: field, height: DesignTokens.Settings.controlHeight)
        (field as? SettingsInputStylable)?.applySettingsInputStyle()
    }

    package static func applyPopupButton(_ button: SettingsDropdownButton) {
        button.applySettingsStyle()
    }

    package static func applyReadonlyTextBlock(container: NSView, label: NSTextField, minHeight: CGFloat) {
        container.translatesAutoresizingMaskIntoConstraints = false
        applyCardSurface(to: container)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = DesignTokens.Typography.settingsSectionBody
        label.textColor = DesignTokens.Color.textSecondary
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.usesSingleLineMode = false

        if label.superview !== container {
            container.addSubview(label)
        }

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: DesignTokens.Settings.TextBlock.horizontalInset),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -DesignTokens.Settings.TextBlock.horizontalInset),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: DesignTokens.Settings.TextBlock.verticalInset),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DesignTokens.Settings.TextBlock.verticalInset)
        ])
    }

    package static func applyPageSurface(to view: NSView) {
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = DesignTokens.Settings.Surface.pageCornerRadius
        view.layer?.borderWidth = 1
        view.layer?.borderColor = DesignTokens.Settings.Surface.pageBorder.cgColor
        view.layer?.backgroundColor = DesignTokens.Settings.Surface.pageFill.cgColor
    }
}

private var settingsActionButtonHoverTrackerKey: UInt8 = 0

package final class SettingsActionButton: NSButton {
    var actionButtonSize: SettingsControlStyle.ActionButtonSize = .compact {
        didSet { invalidateIntrinsicContentSize() }
    }

    var actionButtonVisualStyle: SettingsControlStyle.ActionButtonVisualStyle = .standard {
        didSet {
            invalidateIntrinsicContentSize()
            SettingsControlStyle.refreshActionButtonAppearance(self)
        }
    }

    package override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            SettingsControlStyle.refreshActionButtonAppearance(self)
        }
    }

    package override var font: NSFont? {
        didSet { invalidateIntrinsicContentSize() }
    }

    package override var isEnabled: Bool {
        didSet { SettingsControlStyle.refreshActionButtonAppearance(self) }
    }

    package convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    package override var intrinsicContentSize: NSSize {
        let buttonFont = font ?? DesignTokens.Typography.settingsButtonLabel
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: buttonFont]).width)
        let width = max(
            actionButtonSize.minimumWidth,
            titleWidth + (actionButtonSize.horizontalPadding * 2)
        )
        return NSSize(width: width, height: actionButtonSize.height)
    }

    package override func highlight(_ flag: Bool) {
        super.highlight(flag)
        SettingsControlStyle.refreshActionButtonAppearance(self)
    }

    package override func updateTrackingAreas() {
        super.updateTrackingAreas()
        SettingsActionButtonHoverTracker.install(on: self)
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        SettingsActionButtonHoverTracker.install(on: self)
    }

    package override func viewDidUnhide() {
        super.viewDidUnhide()
        SettingsActionButtonHoverTracker.install(on: self)
        SettingsControlStyle.refreshActionButtonAppearance(self)
    }

    package override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class SettingsPassthroughLabel: NSTextField {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class SettingsActionButtonHoverTracker: NSObject {
    private weak var button: NSButton?
    private var trackingArea: NSTrackingArea?
    private var enabledObservation: NSKeyValueObservation?
    private var overlayObserver: NSObjectProtocol?
    private(set) var isHovering = false {
        didSet {
            if let button {
                SettingsControlStyle.refreshActionButtonAppearance(button)
            }
        }
    }

    static func install(on button: NSButton) {
        if let tracker = objc_getAssociatedObject(button, &settingsActionButtonHoverTrackerKey) as? SettingsActionButtonHoverTracker {
            tracker.attach(to: button)
            return
        }
        let tracker = SettingsActionButtonHoverTracker(button: button)
        objc_setAssociatedObject(button, &settingsActionButtonHoverTrackerKey, tracker, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func isHovering(for button: NSButton?) -> Bool {
        guard let button,
              let tracker = objc_getAssociatedObject(button, &settingsActionButtonHoverTrackerKey) as? SettingsActionButtonHoverTracker else {
            return false
        }
        return tracker.isHovering && !isSettingsHoverSuppressed(for: button)
    }

    init(button: NSButton) {
        super.init()
        attach(to: button)
    }

    func attach(to button: NSButton) {
        self.button = button
        if let trackingArea, trackingArea.owner === self {
            button.removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(area)
        trackingArea = area
        enabledObservation = button.observe(\.isEnabled, options: [.initial, .new]) { observedButton, _ in
            SettingsControlStyle.refreshActionButtonAppearance(observedButton)
        }
        if overlayObserver == nil {
            overlayObserver = NotificationCenter.default.addObserver(
                forName: .settingsOverlayHoverContextDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let button = self?.button else { return }
                SettingsControlStyle.refreshActionButtonAppearance(button)
            }
        }
        isHovering = false
        button.window?.invalidateCursorRects(for: button)
    }

    @objc(mouseEntered:) func handleMouseEntered(_ event: NSEvent) {
        isHovering = true
    }

    @objc(mouseExited:) func handleMouseExited(_ event: NSEvent) {
        isHovering = false
    }

    deinit {
        if let overlayObserver {
            NotificationCenter.default.removeObserver(overlayObserver)
        }
    }
}

package final class SettingsDropdownButton: NSControl {
    package override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    private var trackingAreaRef: NSTrackingArea?
    private var hovering = false {
        didSet { updateAppearance() }
    }
    private var pressing = false {
        didSet { updateAppearance() }
    }
    private var items: [String] = []
    private var selectedIndexInternal: Int = -1
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()

    package init() {
        super.init(frame: .zero)
        setupStyle()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupStyle()
    }

    package var indexOfSelectedItem: Int {
        selectedIndexInternal
    }

    package var selectedItem: NSMenuItem? {
        guard items.indices.contains(selectedIndexInternal) else { return nil }
        return NSMenuItem(title: items[selectedIndexInternal], action: nil, keyEquivalent: "")
    }

    package override var intrinsicContentSize: NSSize {
        NSSize(width: 230, height: DesignTokens.Settings.controlHeight)
    }

    package func removeAllItems() {
        items.removeAll()
        selectedIndexInternal = -1
        titleLabel.stringValue = ""
    }

    package func addItems(withTitles titles: [String]) {
        items.append(contentsOf: titles)
        if selectedIndexInternal == -1, !items.isEmpty {
            selectedIndexInternal = 0
        }
        refreshDisplayedTitle()
    }

    package func selectItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndexInternal = index
        refreshDisplayedTitle()
    }

    package func selectItem(withTitle title: String) {
        guard let index = items.firstIndex(of: title) else { return }
        selectItem(at: index)
    }

    package func applySettingsStyle() {
        titleLabel.font = DesignTokens.Typography.settingsSectionTitle
        refreshDisplayedTitle()
        updateAppearance()
    }

    package override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressing = true
        showMenu()
        pressing = false
    }

    package override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    package override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovering = true
    }

    package override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
        pressing = false
    }

    package override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func setupStyle() {
        wantsLayer = true
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = DesignTokens.Typography.settingsSectionTitle
        titleLabel.textColor = DesignTokens.Color.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        chevronView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        chevronView.contentTintColor = DesignTokens.Color.textSecondary
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(titleLabel)
        addSubview(chevronView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignTokens.Settings.controlHeight),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Dropdown.horizontalInset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Dropdown.indicatorInset),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateAppearance()
    }

    private func refreshDisplayedTitle() {
        titleLabel.stringValue = items.indices.contains(selectedIndexInternal) ? items[selectedIndexInternal] : ""
    }

    private func updateAppearance() {
        let backgroundColor: NSColor
        let borderColor: NSColor
        if pressing {
            backgroundColor = DesignTokens.Settings.Dropdown.pressedSurface
            borderColor = DesignTokens.Settings.Dropdown.pressedBorder
        } else if hovering {
            backgroundColor = DesignTokens.Settings.Dropdown.hoverSurface
            borderColor = DesignTokens.Settings.Dropdown.hoverBorder
        } else {
            backgroundColor = DesignTokens.Settings.Dropdown.surface
            borderColor = DesignTokens.Settings.Dropdown.border
        }
        layer?.cornerRadius = DesignTokens.Settings.Dropdown.cornerRadius
        layer?.borderWidth = DesignTokens.Settings.Dropdown.borderWidth
        layer?.borderColor = borderColor.cgColor
        layer?.backgroundColor = backgroundColor.cgColor
        titleLabel.textColor = isEnabled ? DesignTokens.Color.textPrimary : DesignTokens.Color.textTertiary
        chevronView.contentTintColor = isEnabled ? DesignTokens.Color.textSecondary : DesignTokens.Color.textTertiary
    }

    private func showMenu() {
        guard !items.isEmpty else { return }
        let menu = NSMenu()
        for (index, title) in items.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(handleSelect(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selectedIndexInternal ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func handleSelect(_ sender: NSMenuItem) {
        selectedIndexInternal = sender.tag
        refreshDisplayedTitle()
        if let action {
            _ = NSApp.sendAction(action, to: target, from: self)
        }
    }
}

private final class SettingsSkillCatalogRowView: NSView {
    var onOpenDetail: ((SkillInventoryItem) -> Void)?
    var onPrimaryAction: ((SkillInventoryItem) -> Void)?
    var onSecondaryAction: ((SkillInventoryItem) -> Void)?
    var onTertiaryAction: ((SkillInventoryItem) -> Void)?

    private let item: SkillInventoryItem
    private let iconPlate = NSView()
    private var isHovered = false
    private let isSelectedState: Bool
    private var trackingAreaRef: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?
    private var overlayObserver: NSObjectProtocol?

    init(item: SkillInventoryItem, isSelected: Bool) {
        self.item = item
        self.isSelectedState = isSelected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        updateCardAppearance()

        iconPlate.translatesAutoresizingMaskIntoConstraints = false
        iconPlate.wantsLayer = true
        iconPlate.layer?.cornerRadius = DesignTokens.Settings.Card.catalogIconPlateCornerRadius
        iconPlate.layer?.backgroundColor = DesignTokens.Settings.Card.catalogIconPlateFill.cgColor

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: DesignTokens.Settings.Card.catalogIconPointSize,
            weight: .regular
        )
        iconView.contentTintColor = DesignTokens.Color.accentOrange
        iconPlate.addSubview(iconView)

        let versionLabel = SettingsPassthroughLabel(labelWithString: versionText(for: item))
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.font = DesignTokens.Typography.settingsCatalogVersion
        versionLabel.textColor = DesignTokens.Settings.Card.catalogVersionColor
        versionLabel.alignment = .right
        if let style = versionLabel.cell as? NSTextFieldCell {
            style.backgroundStyle = .raised
        }

        let stateLabel = SettingsPassthroughLabel(labelWithString: stateText(for: item))
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = DesignTokens.Typography.settingsCatalogState
        stateLabel.textColor = DesignTokens.Settings.Card.catalogStateColor
        stateLabel.alignment = .right

        let topMetaStack = NSStackView(views: [versionLabel, stateLabel])
        topMetaStack.translatesAutoresizingMaskIntoConstraints = false
        topMetaStack.orientation = .vertical
        topMetaStack.alignment = .trailing
        topMetaStack.spacing = DesignTokens.Settings.Card.catalogMetaSpacing
        topMetaStack.setContentHuggingPriority(.required, for: .horizontal)
        topMetaStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let topRow = NSStackView(views: [iconPlate, NSView(), topMetaStack])
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = DesignTokens.Settings.Card.catalogHeaderSpacing

        let titleLabel = SettingsPassthroughLabel(labelWithString: item.displayName)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = DesignTokens.Typography.settingsCatalogTitle
        titleLabel.textColor = DesignTokens.Settings.Card.catalogTitleColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        let summaryLabel = SettingsPassthroughLabel(wrappingLabelWithString: item.summary)
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = DesignTokens.Typography.settingsCatalogSummary
        summaryLabel.textColor = DesignTokens.Settings.Card.catalogSummaryColor
        summaryLabel.maximumNumberOfLines = 3
        summaryLabel.lineBreakMode = .byCharWrapping
        summaryLabel.usesSingleLineMode = false
        (summaryLabel.cell as? NSTextFieldCell)?.wraps = true
        if let paragraphStyle = (summaryLabel.cell as? NSTextFieldCell)?.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
            let mutableStyle = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            mutableStyle.lineSpacing = DesignTokens.Settings.Card.catalogSummaryLineSpacing
            mutableStyle.lineBreakMode = .byCharWrapping
            summaryLabel.attributedStringValue = NSAttributedString(
                string: item.summary,
                attributes: [
                    .font: DesignTokens.Typography.settingsCatalogSummary,
                    .foregroundColor: DesignTokens.Settings.Card.catalogSummaryColor,
                    .paragraphStyle: mutableStyle
                ]
            )
        } else {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = DesignTokens.Settings.Card.catalogSummaryLineSpacing
            paragraphStyle.lineBreakMode = .byCharWrapping
            summaryLabel.attributedStringValue = NSAttributedString(
                string: item.summary,
                attributes: [
                    .font: DesignTokens.Typography.settingsCatalogSummary,
                    .foregroundColor: DesignTokens.Settings.Card.catalogSummaryColor,
                    .paragraphStyle: paragraphStyle
                ]
            )
        }

        let primaryButton = SettingsActionButton(title: primaryActionTitle(for: item), target: self, action: #selector(handlePrimaryAction))
        SettingsControlStyle.applyActionButton(primaryButton, size: .catalogPrimary, style: .standard)
        primaryButton.translatesAutoresizingMaskIntoConstraints = false

        let secondaryButton = SettingsActionButton(title: secondaryActionTitle(for: item), target: self, action: #selector(handleSecondaryAction))
        SettingsControlStyle.applyActionButton(secondaryButton, size: .catalogSecondary, style: .ghostSecondary)
        secondaryButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryButton.isHidden = !item.isInstalled

        primaryButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        secondaryButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        secondaryButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actionRow = NSView()
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionRow.addSubview(primaryButton)
        if secondaryButton.isHidden == false {
            actionRow.addSubview(secondaryButton)
        }

        addSubview(topRow)
        addSubview(titleLabel)
        addSubview(summaryLabel)
        addSubview(actionRow)

        NSLayoutConstraint.activate([
            iconPlate.widthAnchor.constraint(equalToConstant: DesignTokens.Settings.Card.catalogIconPlateSize),
            iconPlate.heightAnchor.constraint(equalToConstant: DesignTokens.Settings.Card.catalogIconPlateSize),
            iconView.centerXAnchor.constraint(equalTo: iconPlate.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconPlate.centerYAnchor),

            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Card.catalogInsetHorizontal),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Card.catalogInsetHorizontal),
            topRow.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Settings.Card.catalogInsetVertical),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Card.catalogInsetHorizontal),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Card.catalogInsetHorizontal),
            titleLabel.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: DesignTokens.Settings.Card.catalogTitleTopSpacing),

            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Card.catalogInsetHorizontal),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Card.catalogInsetHorizontal),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.Settings.Card.catalogTitleSummarySpacing),

            actionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Card.catalogInsetHorizontal),
            actionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Card.catalogInsetHorizontal),
            actionRow.topAnchor.constraint(greaterThanOrEqualTo: summaryLabel.bottomAnchor, constant: DesignTokens.Settings.Card.catalogActionTopSpacing),
            actionRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Settings.Card.catalogInsetVertical)
        ])

        if secondaryButton.isHidden == false {
            NSLayoutConstraint.activate([
                primaryButton.leadingAnchor.constraint(equalTo: actionRow.leadingAnchor),
                primaryButton.topAnchor.constraint(equalTo: actionRow.topAnchor),
                primaryButton.bottomAnchor.constraint(equalTo: actionRow.bottomAnchor),

                secondaryButton.leadingAnchor.constraint(
                    equalTo: primaryButton.trailingAnchor,
                    constant: DesignTokens.Settings.Card.catalogActionSpacing
                ),
                secondaryButton.trailingAnchor.constraint(equalTo: actionRow.trailingAnchor),
                secondaryButton.topAnchor.constraint(equalTo: actionRow.topAnchor),
                secondaryButton.bottomAnchor.constraint(equalTo: actionRow.bottomAnchor),

                primaryButton.widthAnchor.constraint(
                    equalTo: secondaryButton.widthAnchor,
                    multiplier: DesignTokens.Settings.Card.catalogPrimaryWidthRatio
                )
            ])
        } else {
            NSLayoutConstraint.activate([
                primaryButton.leadingAnchor.constraint(equalTo: actionRow.leadingAnchor),
                primaryButton.trailingAnchor.constraint(equalTo: actionRow.trailingAnchor),
                primaryButton.topAnchor.constraint(equalTo: actionRow.topAnchor),
                primaryButton.bottomAnchor.constraint(equalTo: actionRow.bottomAnchor)
            ])
        }

        topRow.setCustomSpacing(0, after: iconPlate)
        if topRow.arrangedSubviews.indices.contains(1) {
            let spacer = topRow.arrangedSubviews[1]
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        updateCardAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        if let overlayObserver {
            NotificationCenter.default.removeObserver(overlayObserver)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        rebuildScrollObserver()
        refreshHoverState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildScrollObserver()
        rebuildOverlayObserver()
        refreshHoverState()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onOpenDetail?(item)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(false)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func handlePrimaryAction() {
        onPrimaryAction?(item)
    }

    @objc private func handleSecondaryAction() {
        onSecondaryAction?(item)
    }

    @objc private func handleTertiaryAction() {
        onTertiaryAction?(item)
    }

    private func primaryActionTitle(for item: SkillInventoryItem) -> String {
        if item.updateAvailable { return L10n.text(zhHans: "更新", en: "Update") }
        if !item.isInstalled { return L10n.text(zhHans: "获取", en: "Get") }
        return L10n.text(zhHans: "详情", en: "Details")
    }

    private func secondaryActionTitle(for item: SkillInventoryItem) -> String {
        item.isEnabled
            ? L10n.text(zhHans: "禁用", en: "Disable")
            : L10n.text(zhHans: "启用", en: "Enable")
    }

    private func versionText(for item: SkillInventoryItem) -> String {
        L10n.format(zhHans: "VERSION %@", en: "VERSION %@", item.version)
    }

    private func stateText(for item: SkillInventoryItem) -> String {
        if item.updateAvailable {
            return L10n.text(zhHans: "• 有更新", en: "• Update Available")
        }
        if !item.isInstalled {
            return L10n.text(zhHans: "• 可获取", en: "• Available")
        }
        if item.isEnabled {
            return L10n.text(zhHans: "• 已启用", en: "• Enabled")
        }
        return L10n.text(zhHans: "• 已禁用", en: "• Disabled")
    }

    private func rebuildScrollObserver() {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        guard let clipView = enclosingScrollView?.contentView else { return }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHoverState()
        }
    }

    private func rebuildOverlayObserver() {
        if let overlayObserver {
            NotificationCenter.default.removeObserver(overlayObserver)
            self.overlayObserver = nil
        }
        overlayObserver = NotificationCenter.default.addObserver(
            forName: .settingsOverlayHoverContextDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHoverState()
        }
    }

    private func refreshHoverState() {
        guard let window, !isHidden, !isSettingsHoverSuppressed(for: self) else {
            setHovered(false)
            return
        }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(bounds.contains(location))
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateCardAppearance()
    }

    private func updateCardAppearance() {
        let surfaceColor: NSColor
        let borderColor: NSColor
        let iconPlateColor: NSColor

        if isSelectedState {
            surfaceColor = DesignTokens.Settings.Card.catalogSelectedSurface
            borderColor = DesignTokens.Settings.Card.catalogSelectedBorder
            iconPlateColor = DesignTokens.Settings.Card.catalogIconPlateSelectedFill
        } else if isHovered {
            surfaceColor = DesignTokens.Settings.Card.hoverSurface
            borderColor = DesignTokens.Settings.Card.hoverBorder
            iconPlateColor = DesignTokens.Settings.Card.catalogIconPlateHoverFill
        } else {
            surfaceColor = DesignTokens.Settings.Card.surface
            borderColor = DesignTokens.Settings.Card.border
            iconPlateColor = DesignTokens.Settings.Card.catalogIconPlateFill
        }

        layer?.cornerRadius = DesignTokens.Settings.Card.cornerRadius
        layer?.borderWidth = DesignTokens.Settings.Card.borderWidth
        layer?.borderColor = borderColor.cgColor
        layer?.backgroundColor = surfaceColor.cgColor
        iconPlate.layer?.backgroundColor = iconPlateColor.cgColor
    }
}

private final class SettingsFilterPillButton: NSButton {
    private var isSelectedState = false
    private var isHovering = false
    private var isPressedState = false
    private var trackingAreaRef: NSTrackingArea?

    override var title: String {
        didSet { applyAppearance() }
    }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
        bezelStyle = .regularSquare
        font = DesignTokens.Typography.settingsSectionTitle
        wantsLayer = true
        setButtonType(.momentaryChange)
        applyAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += DesignTokens.Settings.Filter.horizontalPadding
        size.height = DesignTokens.Settings.Filter.height
        return size
    }

    func setSelected(_ selected: Bool) {
        isSelectedState = selected
        applyAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressedState = false
        applyAppearance()
    }

    override func highlight(_ flag: Bool) {
        isPressedState = flag
        applyAppearance()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func applyAppearance() {
        layer?.cornerRadius = DesignTokens.Settings.Filter.cornerRadius
        layer?.borderWidth = DesignTokens.Settings.Filter.borderWidth

        let backgroundColor: NSColor
        let borderColor: NSColor
        let titleColor: NSColor

        if isPressedState {
            backgroundColor = DesignTokens.Settings.Filter.pressedFill
            borderColor = DesignTokens.Settings.Filter.pressedBorder
            titleColor = isSelectedState
                ? DesignTokens.Settings.Filter.selectedText
                : DesignTokens.Settings.Filter.hoverText
        } else if isSelectedState {
            backgroundColor = DesignTokens.Settings.Filter.selectedFill
            borderColor = DesignTokens.Settings.Filter.selectedBorder
            titleColor = DesignTokens.Settings.Filter.selectedText
        } else if isHovering {
            backgroundColor = DesignTokens.Settings.Filter.hoverFill
            borderColor = DesignTokens.Settings.Filter.hoverBorder
            titleColor = DesignTokens.Settings.Filter.hoverText
        } else {
            backgroundColor = DesignTokens.Settings.Filter.defaultFill
            borderColor = DesignTokens.Settings.Filter.defaultBorder
            titleColor = DesignTokens.Settings.Filter.defaultText
        }

        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: DesignTokens.Typography.settingsSectionTitle,
                .foregroundColor: titleColor
            ]
        )
    }
}

final class SettingsPermissionRowView: NSView {
    private let titleLabel: NSTextField
    private let descriptionLabel: NSTextField
    private let statusNoteLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton: NSButton
    private let grantedIconView = NSImageView()
    private var isHovered = false
    private var trackingAreaRef: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?
    private var overlayObserver: NSObjectProtocol?

    init(title: String, description: String, buttonTitle: String) {
        self.titleLabel = NSTextField(labelWithString: title)
        self.descriptionLabel = NSTextField(wrappingLabelWithString: description)
        self.actionButton = SettingsActionButton(title: buttonTitle, target: nil, action: nil)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyCardSurface(to: self)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = DesignTokens.Typography.settingsSectionTitle
        titleLabel.textColor = DesignTokens.Color.textPrimary

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = DesignTokens.Typography.settingsSectionBody
        descriptionLabel.textColor = DesignTokens.Color.textSecondary
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.usesSingleLineMode = false

        statusNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        statusNoteLabel.font = DesignTokens.Typography.settingsSectionNote
        statusNoteLabel.textColor = DesignTokens.Color.textTertiary
        statusNoteLabel.maximumNumberOfLines = 1
        statusNoteLabel.isHidden = true

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyActionButton(actionButton)

        grantedIconView.translatesAutoresizingMaskIntoConstraints = false
        grantedIconView.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: L10n.text(zhHans: "已授权", en: "Authorized")
        )
        grantedIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        grantedIconView.contentTintColor = DesignTokens.Settings.Status.success
        grantedIconView.isHidden = true

        let textStack = NSStackView(views: [titleLabel, descriptionLabel, statusNoteLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = DesignTokens.Spacing.xxs

        let trailingContainer = NSView()
        trailingContainer.translatesAutoresizingMaskIntoConstraints = false
        trailingContainer.addSubview(actionButton)
        trailingContainer.addSubview(grantedIconView)

        addSubview(textStack)
        addSubview(trailingContainer)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Card.insetHorizontal),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Settings.Card.insetVertical),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Settings.Card.insetVertical),

            trailingContainer.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: DesignTokens.Settings.Card.insetHorizontal),
            trailingContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Card.insetHorizontal),
            trailingContainer.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Settings.Card.insetVertical),
            trailingContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Settings.Card.insetVertical),
            trailingContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),

            actionButton.centerYAnchor.constraint(equalTo: trailingContainer.centerYAnchor),
            actionButton.trailingAnchor.constraint(equalTo: trailingContainer.trailingAnchor),

            grantedIconView.centerYAnchor.constraint(equalTo: trailingContainer.centerYAnchor),
            grantedIconView.trailingAnchor.constraint(equalTo: trailingContainer.trailingAnchor),
            grantedIconView.widthAnchor.constraint(equalToConstant: 20),
            grantedIconView.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        if let overlayObserver {
            NotificationCenter.default.removeObserver(overlayObserver)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        rebuildScrollObserver()
        refreshHoverState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildScrollObserver()
        rebuildOverlayObserver()
        refreshHoverState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(false)
    }

    func setAction(target: AnyObject?, action: Selector) {
        actionButton.target = target
        actionButton.action = action
    }

    func setButtonTitle(_ title: String) {
        actionButton.title = title
    }

    func setAuthorized(_ granted: Bool) {
        grantedIconView.isHidden = !granted
        actionButton.isHidden = granted
    }

    func setStatusNote(_ note: String?) {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        statusNoteLabel.stringValue = trimmed
        statusNoteLabel.isHidden = trimmed.isEmpty
    }

    private func rebuildScrollObserver() {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        guard let clipView = enclosingScrollView?.contentView else { return }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHoverState()
        }
    }

    private func rebuildOverlayObserver() {
        if let overlayObserver {
            NotificationCenter.default.removeObserver(overlayObserver)
            self.overlayObserver = nil
        }
        overlayObserver = NotificationCenter.default.addObserver(
            forName: .settingsOverlayHoverContextDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHoverState()
        }
    }

    private func refreshHoverState() {
        guard let window, !isHidden, !isSettingsHoverSuppressed(for: self) else {
            setHovered(false)
            return
        }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(bounds.contains(location))
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        SettingsControlStyle.applyCardSurface(to: self, hovered: hovered)
    }
}

extension SettingsWindowController {
    func reloadAutomationSettingsPage() {
        automationPageView.reloadData()
    }

#if DEBUG
    func testingAutomationPageLayoutSnapshot(frame: NSRect = NSRect(x: 0, y: 0, width: 1200, height: 900)) -> (
        scrollBounds: NSRect,
        contentFrame: NSRect,
        metricFrame: NSRect,
        jobListFrame: NSRect,
        detailFrame: NSRect,
        runHistoryFrame: NSRect,
        inboxFrame: NSRect,
        detailTitleFrame: NSRect,
        detailSpecFrame: NSRect,
        responseProfileFrame: NSRect,
        saveButtonFrame: NSRect,
        usesSystemScroller: Bool
    ) {
        automationPageView.testingLayoutSnapshot(frame: frame)
    }
#endif
}

private final class KnowledgeBaseRowView: NSView {
    var onOpen: ((ReplyKnowledgeBaseEntry) -> Void)?
    var onRefresh: ((String) -> Void)?
    var onReindex: ((String) -> Void)?
    var onToggleEnabled: ((String, Bool) -> Void)?
    var onDelete: ((String) -> Void)?
    var onInspect: ((String) -> Void)?
    var onSelectionChanged: ((String, Bool) -> Void)?

    private let entry: ReplyKnowledgeBaseEntry
    private let isManaging: Bool
    private let isFocused: Bool
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false
    private var scrollObserver: NSObjectProtocol?
    private var overlayObserver: NSObjectProtocol?
    private let titleLabel: NSTextField
    private let summaryLabel: NSTextField
    private let metaLabel: NSTextField
    private let selectionCheckbox: NSButton
    private let actionSection: NSView
    private let primaryActionRow: NSStackView
    private let refreshButton: NSButton
    private let openButton: NSButton
    private let toggleButton: NSButton
    private let deleteButton: NSButton
    private var selectionCheckboxWidthConstraint: NSLayoutConstraint?
    private var contentBottomToActionConstraint: NSLayoutConstraint?
    private var contentBottomToMetaConstraint: NSLayoutConstraint?

    init(entry: ReplyKnowledgeBaseEntry, isManaging: Bool, isSelected: Bool, isFocused: Bool) {
        self.entry = entry
        self.isManaging = isManaging
        self.isFocused = isFocused
        self.titleLabel = NSTextField(labelWithString: Self.displayTitle(for: entry))
        self.summaryLabel = NSTextField(wrappingLabelWithString: Self.summaryText(for: entry))
        self.metaLabel = NSTextField(labelWithString: Self.metaText(for: entry))
        self.selectionCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        self.actionSection = NSView()
        self.primaryActionRow = NSStackView()
        self.refreshButton = SettingsActionButton(
            title: L10n.text(zhHans: "更新", en: "Refresh"),
            target: nil,
            action: nil
        )
        self.openButton = SettingsActionButton(
            title: L10n.text(zhHans: "查看来源", en: "Open"),
            target: nil,
            action: nil
        )
        self.toggleButton = SettingsActionButton(
            title: (entry.isEnabled ?? true)
                ? L10n.text(zhHans: "停用", en: "Disable")
                : L10n.text(zhHans: "启用", en: "Enable"),
            target: nil,
            action: nil
        )
        self.deleteButton = SettingsActionButton(
            title: L10n.text(zhHans: "删除", en: "Delete"),
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        applyAppearance()

        titleLabel.font = DesignTokens.KnowledgeBaseWindow.Row.titleFont
        titleLabel.textColor = DesignTokens.KnowledgeBaseWindow.Row.titleColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        summaryLabel.font = DesignTokens.KnowledgeBaseWindow.Row.summaryFont
        summaryLabel.textColor = DesignTokens.KnowledgeBaseWindow.Row.summaryColor
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.lineBreakMode = .byTruncatingTail

        metaLabel.font = DesignTokens.KnowledgeBaseWindow.Row.metaFont
        metaLabel.textColor = DesignTokens.KnowledgeBaseWindow.Row.metaColor
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.maximumNumberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        selectionCheckbox.translatesAutoresizingMaskIntoConstraints = false
        selectionCheckbox.state = isSelected ? .on : .off
        selectionCheckbox.target = self
        selectionCheckbox.action = #selector(handleSelectionToggle)
        selectionCheckbox.isHidden = !isManaging
        selectionCheckboxWidthConstraint = selectionCheckbox.widthAnchor.constraint(equalToConstant: isManaging ? 20 : 0)
        selectionCheckboxWidthConstraint?.isActive = true

        SettingsControlStyle.applyActionButton(toggleButton)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.target = self
        toggleButton.action = #selector(handleToggleEnabled)

        openButton.target = self
        openButton.action = #selector(handleOpen)
        SettingsControlStyle.applyActionButton(openButton)
        openButton.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(handleRefresh)
        SettingsControlStyle.applyActionButton(refreshButton)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.isHidden = entry.refreshable == false

        deleteButton.target = self
        deleteButton.action = #selector(handleDelete)
        SettingsControlStyle.applyActionButton(deleteButton)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        actionSection.translatesAutoresizingMaskIntoConstraints = false
        actionSection.isHidden = isManaging
        actionSection.setContentHuggingPriority(.required, for: .horizontal)
        actionSection.setContentCompressionResistancePriority(.required, for: .horizontal)

        primaryActionRow.orientation = .horizontal
        primaryActionRow.alignment = .centerY
        primaryActionRow.spacing = 10
        primaryActionRow.translatesAutoresizingMaskIntoConstraints = false
        primaryActionRow.setContentHuggingPriority(.required, for: .vertical)
        primaryActionRow.setContentCompressionResistancePriority(.required, for: .vertical)

        addSubview(selectionCheckbox)
        addSubview(summaryLabel)
        addSubview(metaLabel)
        addSubview(titleLabel)
        addSubview(actionSection)
        actionSection.addSubview(primaryActionRow)
        if !refreshButton.isHidden {
            primaryActionRow.addArrangedSubview(refreshButton)
        }
        primaryActionRow.addArrangedSubview(openButton)
        primaryActionRow.addArrangedSubview(toggleButton)
        primaryActionRow.addArrangedSubview(deleteButton)

        NSLayoutConstraint.activate([
            selectionCheckbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Card.insetHorizontal),
            selectionCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Settings.Card.insetVertical + 2),

            titleLabel.leadingAnchor.constraint(equalTo: selectionCheckbox.trailingAnchor, constant: isManaging ? 10 : 0),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Card.insetHorizontal),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Settings.Card.insetVertical),

            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Card.insetHorizontal),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.Settings.Card.textSpacing),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionSection.leadingAnchor, constant: -DesignTokens.Settings.Card.textSpacing),
            metaLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: DesignTokens.Settings.Card.metaSpacing),

            actionSection.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.leadingAnchor),
            actionSection.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Card.insetHorizontal),
            actionSection.centerYAnchor.constraint(equalTo: metaLabel.centerYAnchor)
        ])

        NSLayoutConstraint.activate([
            primaryActionRow.leadingAnchor.constraint(equalTo: actionSection.leadingAnchor),
            primaryActionRow.trailingAnchor.constraint(equalTo: actionSection.trailingAnchor),
            primaryActionRow.topAnchor.constraint(equalTo: actionSection.topAnchor),
            primaryActionRow.bottomAnchor.constraint(equalTo: actionSection.bottomAnchor)
        ])

        contentBottomToActionConstraint = actionSection.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Settings.Card.insetVertical)
        contentBottomToMetaConstraint = metaLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Settings.Card.insetVertical)
        contentBottomToActionConstraint?.isActive = !isManaging
        contentBottomToMetaConstraint?.isActive = isManaging
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        if let overlayObserver {
            NotificationCenter.default.removeObserver(overlayObserver)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        rebuildScrollObserver()
        refreshHoverState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildScrollObserver()
        rebuildOverlayObserver()
        refreshHoverState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        switch hitView {
        case selectionCheckbox, openButton, refreshButton, toggleButton, deleteButton:
            return hitView
        case titleLabel, summaryLabel, metaLabel, actionSection, primaryActionRow, self:
            return self
        default:
            return hitView
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard !isManaging else { return }
        onInspect?(entry.id)
    }

    @objc private func handleDelete() {
        onDelete?(entry.id)
    }

    @objc private func handleOpen() {
        onOpen?(entry)
    }

    @objc private func handleRefresh() {
        onRefresh?(entry.id)
    }

    @objc private func handleReindex() {
        onReindex?(entry.id)
    }

    @objc private func handleToggleEnabled() {
        onToggleEnabled?(entry.id, !(entry.isEnabled ?? true))
    }

    @objc private func handleSelectionToggle() {
        onSelectionChanged?(entry.id, selectionCheckbox.state == .on)
    }

    private static func displayTitle(for entry: ReplyKnowledgeBaseEntry) -> String {
        if entry.sourceKind == .url {
            return entry.title.isEmpty ? (entry.externalURL ?? entry.originalFilename) : entry.title
        }
        return entry.originalFilename
    }

    private static func metaText(for entry: ReplyKnowledgeBaseEntry) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        var parts: [String] = []
        if entry.isEnabled == false {
            parts.append(L10n.text(zhHans: "已停用", en: "Disabled"))
        }

        if let reference = sourceReference(for: entry) {
            parts.append(reference)
        } else {
            parts.append(sourceLabel(for: entry))
        }

        if entry.sourceKind == .file {
            parts.append(formatter.string(fromByteCount: entry.byteCount))
        }

        if let status = entry.status, !status.isEmpty, status != "ready" {
            parts.append(userFacingStatus(status))
        }
        if let refreshedAt = entry.lastRefreshedAt {
            parts.append(L10n.format(zhHans: "刷新于 %@", en: "Refreshed %@", dateFormatter.string(from: refreshedAt)))
        } else {
            parts.append(L10n.format(zhHans: "导入于 %@", en: "Imported %@", dateFormatter.string(from: entry.importedAt)))
        }

        return parts
        .joined(separator: "  ·  ")
    }

    private static func sourceLabel(for entry: ReplyKnowledgeBaseEntry) -> String {
        if entry.sourceKind == .url {
            return L10n.text(zhHans: "网页", en: "Web")
        }
        if let kind = fileKindLabel(for: entry) {
            return kind
        }
        return entry.contentType
    }

    private static func summaryText(for entry: ReplyKnowledgeBaseEntry) -> String {
        var summary = entry.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = displayTitle(for: entry)
        if !title.isEmpty, summary.hasPrefix(title) {
            summary.removeFirst(title.count)
            summary = summary.trimmingCharacters(in: CharacterSet(charactersIn: ":- \n\t"))
        }
        summary = summary.replacingOccurrences(of: "\n", with: " ")
        summary = summary.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if summary.isEmpty {
            return entry.sourceKind == .url
                ? L10n.text(zhHans: "已保存网页来源，可用于后续知识检索。", en: "Saved this web source for future knowledge retrieval.")
                : L10n.text(zhHans: "已保存文件来源，可用于后续知识检索。", en: "Saved this file source for future knowledge retrieval.")
        }
        return summary
    }

    private static func sourceReference(for entry: ReplyKnowledgeBaseEntry) -> String? {
        if entry.sourceKind == .url,
           let rawURL = entry.canonicalURL ?? entry.externalURL,
           let host = URL(string: rawURL)?.host(percentEncoded: false),
           !host.isEmpty {
            return host
        }
        return fileKindLabel(for: entry)
    }

    private static func fileKindLabel(for entry: ReplyKnowledgeBaseEntry) -> String? {
        let fileExtension = URL(fileURLWithPath: entry.originalFilename).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return nil }
        switch fileExtension {
        case "pdf":
            return "PDF"
        case "md", "markdown":
            return "Markdown"
        case "txt", "text":
            return "TXT"
        case "doc", "docx":
            return "Word"
        case "ppt", "pptx":
            return "PowerPoint"
        case "xls", "xlsx", "csv", "tsv":
            return "Spreadsheet"
        case "html", "htm":
            return "HTML"
        default:
            return fileExtension.uppercased()
        }
    }

    private static func userFacingStatus(_ status: String) -> String {
        switch status.lowercased() {
        case "failed":
            return L10n.text(zhHans: "导入失败", en: "Import failed")
        case "indexing":
            return L10n.text(zhHans: "正在处理", en: "Processing")
        default:
            return status
        }
    }

    private func applyAppearance(hovered: Bool = false) {
        SettingsControlStyle.applyCardSurface(to: self, hovered: hovered)
        if entry.isEnabled == false {
            layer?.backgroundColor = DesignTokens.Settings.Card.surface.withAlphaComponent(0.72).cgColor
        }
        if isFocused {
            layer?.borderColor = DesignTokens.Color.accentOrangeStrongBorder.cgColor
        }
    }

    private func rebuildScrollObserver() {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        guard let clipView = enclosingScrollView?.contentView else { return }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHoverState()
        }
    }

    private func rebuildOverlayObserver() {
        if let overlayObserver {
            NotificationCenter.default.removeObserver(overlayObserver)
            self.overlayObserver = nil
        }
        overlayObserver = NotificationCenter.default.addObserver(
            forName: .settingsOverlayHoverContextDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHoverState()
        }
    }

    private func refreshHoverState() {
        guard let window, !isHidden, !isSettingsHoverSuppressed(for: self) else {
            setHovered(false)
            return
        }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(bounds.contains(location))
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        applyAppearance(hovered: hovered)
    }
}

private final class CompatibilityAppPickerWindowController: NSWindowController {
    var onSave: (([String]) -> Void)?
    var onClose: (() -> Void)?

    private let searchField = NSSearchField(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: L10n.text(zhHans: "当前没有检测到可选的打开应用。", en: "No eligible open apps were detected right now."))
    private let scrollView = NSScrollView()
    private let contentViewHost = NSView()
    private let appStack = NSStackView()

    private let allApps: [RunningApplicationInfo]
    private var filteredApps: [RunningApplicationInfo] = []
    private var selectedBundleIDs: Set<String>

    init(selectedBundleIDs: Set<String>) {
        self.selectedBundleIDs = selectedBundleIDs
        self.allApps = RunningApplicationCatalog.currentApplications()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text(zhHans: "兼容应用", en: "Compatible Apps")
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        configureWindow()
        reloadFilteredApps()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAsSheet(for parentWindow: NSWindow) {
        guard let window else { return }
        parentWindow.beginSheet(window)
        DispatchQueue.main.async { [weak window] in
            window?.makeFirstResponder(nil)
        }
    }

    private func configureWindow() {
        guard let window, let root = window.contentView else { return }

        let titleLabel = NSTextField(
            wrappingLabelWithString: L10n.format(
                zhHans: "从当前打开的 app 中选择需要启用兼容抓取的目标。适合微信、企业微信文档、Bilibili 这类标准 AX 选区不稳定的场景。勾选后仍然优先走 AX，只有 AX 没及时拿到选区时才会追加兼容抓取。",
                en: "Choose open apps that should use compatibility capture. This is useful for apps like WeChat, WeCom Docs, and Bilibili where standard AX selection can be unreliable. When enabled, %@ still prefers AX first and only falls back to compatibility capture if AX does not provide the selection in time.",
                AppBrand.displayName
            )
        )
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = DesignTokens.Typography.settingsSectionBody
        titleLabel.textColor = DesignTokens.Color.textSecondary
        titleLabel.maximumNumberOfLines = 0

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = L10n.text(zhHans: "搜索当前打开的应用", en: "Search open apps")
        searchField.target = self
        searchField.action = #selector(handleSearchChanged)
        searchField.focusRingType = .none
        searchField.controlSize = .large
        searchField.font = DesignTokens.Typography.settingsDialogSearch

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        contentViewHost.translatesAutoresizingMaskIntoConstraints = true
        appStack.orientation = .vertical
        appStack.alignment = .leading
        appStack.spacing = DesignTokens.Settings.Dialog.listInset
        appStack.translatesAutoresizingMaskIntoConstraints = false
        contentViewHost.addSubview(appStack)
        NSLayoutConstraint.activate([
            appStack.leadingAnchor.constraint(equalTo: contentViewHost.leadingAnchor, constant: DesignTokens.Settings.Dialog.listInset),
            appStack.trailingAnchor.constraint(equalTo: contentViewHost.trailingAnchor, constant: -DesignTokens.Settings.Dialog.listInset),
            appStack.topAnchor.constraint(equalTo: contentViewHost.topAnchor, constant: DesignTokens.Settings.Dialog.listInset),
            appStack.bottomAnchor.constraint(equalTo: contentViewHost.bottomAnchor, constant: -DesignTokens.Settings.Dialog.listInset),
        ])
        scrollView.documentView = contentViewHost

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = DesignTokens.Color.textSecondary
        emptyLabel.isHidden = true

        let cancelButton = SettingsActionButton(title: L10n.text(zhHans: "取消", en: "Cancel"), target: self, action: #selector(handleCancel))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyActionButton(cancelButton)

        let saveButton = SettingsActionButton(title: L10n.text(zhHans: "保存", en: "Save"), target: self, action: #selector(handleSave))
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyActionButton(saveButton)

        root.addSubview(titleLabel)
        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(cancelButton)
        root.addSubview(saveButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.Settings.Dialog.inset),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DesignTokens.Settings.Dialog.inset),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: DesignTokens.Settings.Dialog.inset),

            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.Settings.Dialog.inset),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DesignTokens.Settings.Dialog.inset),
            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.Settings.Dialog.verticalSpacing),
            searchField.heightAnchor.constraint(equalToConstant: DesignTokens.Settings.Dialog.searchFieldHeight),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.Settings.Dialog.inset),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DesignTokens.Settings.Dialog.inset),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: DesignTokens.Settings.Dialog.verticalSpacing),
            scrollView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -DesignTokens.Settings.Dialog.footerSpacing),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            saveButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DesignTokens.Settings.Dialog.inset),
            saveButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -DesignTokens.Settings.Dialog.inset),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -DesignTokens.Settings.Dialog.actionSpacing),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
    }

    @objc private func handleSearchChanged() {
        reloadFilteredApps()
    }

    @objc private func handleCancel() {
        closeWindow()
    }

    @objc private func handleSave() {
        let resolved: [String]
        if selectedBundleIDs.isEmpty {
            resolved = []
        } else {
            let order = allApps.map(\.bundleID)
            let sorted = selectedBundleIDs.sorted { lhs, rhs in
                (order.firstIndex(of: lhs) ?? .max) < (order.firstIndex(of: rhs) ?? .max)
            }
            resolved = sorted
        }
        onSave?(resolved)
        closeWindow()
    }

    @objc private func handleToggleSelection(_ sender: NSButton) {
        guard let bundleID = sender.identifier?.rawValue else { return }
        if sender.state == .on {
            selectedBundleIDs.insert(bundleID)
        } else {
            selectedBundleIDs.remove(bundleID)
        }
    }

    private func reloadFilteredApps() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredApps = allApps
        } else {
            filteredApps = allApps.filter { app in
                app.displayName.localizedCaseInsensitiveContains(query)
                    || app.bundleID.localizedCaseInsensitiveContains(query)
            }
        }
        renderAppRows()
    }

    private func renderAppRows() {
        for view in appStack.arrangedSubviews {
            appStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        emptyLabel.isHidden = !filteredApps.isEmpty
        scrollView.isHidden = filteredApps.isEmpty

        for app in filteredApps {
            let row = CompatibilityAppRowView(
                app: app,
                selected: selectedBundleIDs.contains(app.bundleID),
                target: self,
                action: #selector(handleToggleSelection(_:))
            )
            row.translatesAutoresizingMaskIntoConstraints = false
            appStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: appStack.widthAnchor).isActive = true
        }

        scrollView.layoutSubtreeIfNeeded()
        contentViewHost.layoutSubtreeIfNeeded()
        let width = max(scrollView.contentSize.width, 560)
        let height = max(appStack.fittingSize.height + 20, scrollView.contentSize.height)
        contentViewHost.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    private func closeWindow() {
        if let sheetParent = window?.sheetParent, let window {
            sheetParent.endSheet(window)
            window.orderOut(nil)
        } else {
            close()
        }
        onClose?()
    }
}

private final class CompatibilityAppRowView: NSView {
    private let actionTarget: AnyObject
    private let actionSelector: Selector
    private let checkbox: NSButton
    private var isHovered = false {
        didSet { updateAppearance() }
    }
    private var isPressed = false {
        didSet { updateAppearance() }
    }
    private var trackingArea: NSTrackingArea?

    init(app: RunningApplicationInfo, selected: Bool, target: AnyObject, action: Selector) {
        self.actionTarget = target
        self.actionSelector = action
        self.checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.state = selected ? .on : .off
        checkbox.identifier = NSUserInterfaceItemIdentifier(app.bundleID)
        checkbox.target = self
        checkbox.action = #selector(handleCheckboxToggle(_:))

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSWorkspace.shared.icon(forFile: app.url.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let titleLabel = NSTextField(labelWithString: app.displayName)
        titleLabel.font = DesignTokens.Typography.settingsSectionTitle
        titleLabel.textColor = DesignTokens.Color.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [checkbox, iconView, titleLabel, NSView()])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = DesignTokens.Settings.rowSpacing
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        addSubview(row)
        SettingsControlStyle.applyCardSurface(to: self)
        updateAppearance()

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Settings.Dialog.rowHorizontalInset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Settings.Dialog.rowHorizontalInset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Settings.Dialog.rowVerticalInset),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Settings.Dialog.rowVerticalInset),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isPressed = bounds.contains(point)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        isPressed = false
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        let checkboxPoint = checkbox.convert(event.locationInWindow, from: nil)
        if checkbox.bounds.contains(checkboxPoint) {
            return
        }
        checkbox.performClick(nil)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func handleCheckboxToggle(_ sender: NSButton) {
        updateAppearance()
        NSApp.sendAction(actionSelector, to: actionTarget, from: sender)
    }

    private func updateAppearance() {
        if isPressed {
            layer?.backgroundColor = DesignTokens.Color.hoverFill.withAlphaComponent(0.2).cgColor
            layer?.borderColor = DesignTokens.Settings.Card.hoverBorder.withAlphaComponent(0.9).cgColor
        } else if isHovered {
            SettingsControlStyle.applyCardSurface(to: self, hovered: true)
        } else {
            SettingsControlStyle.applyCardSurface(to: self)
        }
    }
}
