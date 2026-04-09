import AppKit

enum KnowledgeBaseSourceTab: Int {
    case all
    case url
    case file
    case notion

    static var availableTabs: [KnowledgeBaseSourceTab] {
        var tabs: [KnowledgeBaseSourceTab] = [.all, .url, .file]
        if KnowledgeBaseFeatureFlags.notionEnabled {
            tabs.append(.notion)
        }
        return tabs
    }

    var title: String {
        switch self {
        case .all:
            return L10n.text(zhHans: "全部", en: "All")
        case .url:
            return L10n.text(zhHans: "链接", en: "URLs")
        case .file:
            return L10n.text(zhHans: "文件", en: "Files")
        case .notion:
            return "Notion"
        }
    }

    func includes(_ entry: ReplyKnowledgeBaseEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .url:
            return entry.sourceKind == .url
        case .file:
            return entry.sourceKind == .file
        case .notion:
            return entry.sourceKind == .notion
        }
    }
}

struct AIConfigDraft: Equatable {
    var provider: String
    var model: String
    var apiKey: String
}

@MainActor
final class SettingsAIConfigurationCoordinator {
    private let settings: AppSettings
    private let aiConfigurationService: AIConfigurationService
    private let providerPopup: SettingsDropdownButton
    private let modelPopup: SettingsDropdownButton
    private let apiKeyField: PasteFriendlySecureField
    private let aiCurrentConfigLabel: NSTextField
    private let aiDraftStatusLabel: NSTextField
    private let aiRuntimeStatusLabel: NSTextField
    private let aiValidationLabel: NSTextField
    private var latestRuntimeSnapshot: GatewayRuntimeSnapshot

    private(set) var savedConfig = AIConfigDraft(provider: "openai", model: "gpt-4.1-mini", apiKey: "")
    private(set) var draftConfig = AIConfigDraft(provider: "openai", model: "gpt-4.1-mini", apiKey: "")
    private var lastValidatedConfig: AIConfigDraft?
    private var lastValidationSucceeded = false

    init(
        settings: AppSettings,
        aiConfigurationService: AIConfigurationService,
        providerPopup: SettingsDropdownButton,
        modelPopup: SettingsDropdownButton,
        apiKeyField: PasteFriendlySecureField,
        aiCurrentConfigLabel: NSTextField,
        aiDraftStatusLabel: NSTextField,
        aiRuntimeStatusLabel: NSTextField,
        aiValidationLabel: NSTextField
    ) {
        self.settings = settings
        self.aiConfigurationService = aiConfigurationService
        self.providerPopup = providerPopup
        self.modelPopup = modelPopup
        self.apiKeyField = apiKeyField
        self.aiCurrentConfigLabel = aiCurrentConfigLabel
        self.aiDraftStatusLabel = aiDraftStatusLabel
        self.aiRuntimeStatusLabel = aiRuntimeStatusLabel
        self.aiValidationLabel = aiValidationLabel
        self.latestRuntimeSnapshot = GatewayRuntimeManager.shared.currentSnapshot()
    }

    var providerNames: [String] {
        providerCatalog.map(\.name)
    }

    func loadFromSettings() {
        savedConfig = AIConfigDraft(
            provider: settings.llmProvider,
            model: settings.llmModel,
            apiKey: settings.llmApiKey
        )
        draftConfig = savedConfig
        lastValidatedConfig = nil
        lastValidationSucceeded = false
        applyDraftToControls(draftConfig)
        aiValidationLabel.stringValue = ""
        aiValidationLabel.isHidden = true
        refreshUI()
    }

    func handleProviderChanged() {
        let providerID = providerIDForSelection()
        let selectedModel = models(for: providerID).contains(draftConfig.model)
            ? draftConfig.model
            : (models(for: providerID).first ?? "gpt-4.1-mini")
        reloadModelPopup(for: providerID, selectedModel: selectedModel)
        draftConfig.provider = providerID
        draftConfig.model = modelPopup.selectedItem?.title ?? selectedModel
        clearValidationStateIfNeeded()
        refreshUI()
    }

    func handleModelChanged() {
        guard let model = modelPopup.selectedItem?.title else { return }
        draftConfig.model = model
        clearValidationStateIfNeeded()
        refreshUI()
    }

    func handleAPIKeyChanged() {
        draftConfig.apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        clearValidationStateIfNeeded()
        refreshUI()
    }

    func handleGatewayRuntimeStatusChanged(_ snapshot: GatewayRuntimeSnapshot? = nil) {
        if let snapshot {
            latestRuntimeSnapshot = snapshot
        } else {
            latestRuntimeSnapshot = GatewayRuntimeManager.shared.currentSnapshot()
        }
        refreshUI()
    }

    func handleSecureStorageFailure(_ failure: AppSettingsSecureStorageFailure) {
        guard failure.settingKey == SettingKey.llmApiKey else { return }
        aiValidationLabel.stringValue = AppSettingsError.secureStorageFailed(settingKey: failure.settingKey).localizedDescription
        aiValidationLabel.textColor = DesignTokens.Settings.Status.warning
        aiValidationLabel.isHidden = false
    }

    func validate() {
        syncDraftFromControls()
        let apiKey = draftConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty {
            aiValidationLabel.stringValue = L10n.text(zhHans: "请先输入 API Key。", en: "Enter the API key first.")
            aiValidationLabel.textColor = DesignTokens.Settings.Status.warning
            aiValidationLabel.isHidden = false
            return
        }

        let provider = draftConfig.provider
        let model = draftConfig.model

        aiValidationLabel.stringValue = L10n.text(zhHans: "验证中...", en: "Validating...")
        aiValidationLabel.textColor = DesignTokens.Settings.Status.neutral
        aiValidationLabel.isHidden = false

        Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await GatewayRuntimeManager.shared.ensureReady()
            guard ready else {
                let snapshot = GatewayRuntimeManager.shared.currentSnapshot()
                self.latestRuntimeSnapshot = snapshot
                self.lastValidationSucceeded = false
                self.lastValidatedConfig = nil
                self.refreshUI()
                self.aiValidationLabel.stringValue = snapshot.inlinePromptMessage
                self.aiValidationLabel.textColor = DesignTokens.Settings.Status.warning
                self.aiValidationLabel.isHidden = false
                return
            }

            let result = await self.aiConfigurationService.validate(provider: provider, model: model, apiKey: apiKey)
            self.lastValidatedConfig = self.draftConfig
            self.lastValidationSucceeded = result.ok
            if result.ok {
                do {
                    try self.settings.updateAIConfiguration(
                        provider: self.draftConfig.provider,
                        model: self.draftConfig.model,
                        apiKey: self.draftConfig.apiKey
                    )
                    self.savedConfig = self.draftConfig
                } catch {
                    self.lastValidationSucceeded = false
                    self.refreshUI()
                    self.aiValidationLabel.stringValue = error.localizedDescription
                    self.aiValidationLabel.textColor = DesignTokens.Settings.Status.warning
                    self.aiValidationLabel.isHidden = false
                    return
                }
            }
            self.refreshUI()
            self.aiValidationLabel.stringValue = result.ok
                ? L10n.text(zhHans: "连接成功，已自动生效。", en: "Connection succeeded and is now active.")
                : result.message
            self.aiValidationLabel.textColor = result.ok ? DesignTokens.Settings.Status.success : DesignTokens.Settings.Status.warning
            self.aiValidationLabel.isHidden = false
        }
    }

    private var providerCatalog: [(id: String, name: String)] {
        [("openai", "OpenAI"), ("gemini", "Gemini"), ("deepseek", "DeepSeek")]
    }

    private func models(for provider: String) -> [String] {
        switch provider {
        case "gemini":
            return ["gemini-2.0-flash", "gemini-2.0-flash-lite"]
        case "deepseek":
            return ["deepseek-chat", "deepseek-reasoner"]
        default:
            return ["gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o-mini"]
        }
    }

    private func providerIDForSelection() -> String {
        let index = max(0, providerPopup.indexOfSelectedItem)
        guard index < providerCatalog.count else { return "openai" }
        return providerCatalog[index].id
    }

    private func reloadModelPopup(for provider: String, selectedModel: String?) {
        let list = models(for: provider)
        modelPopup.removeAllItems()
        modelPopup.addItems(withTitles: list)

        if let selectedModel, list.contains(selectedModel) {
            modelPopup.selectItem(withTitle: selectedModel)
        } else {
            modelPopup.selectItem(at: 0)
        }
    }

    private func applyDraftToControls(_ draft: AIConfigDraft) {
        let providerIndex = providerCatalog.firstIndex(where: { $0.id == draft.provider }) ?? 0
        providerPopup.selectItem(at: providerIndex)
        reloadModelPopup(for: draft.provider, selectedModel: draft.model)
        apiKeyField.stringValue = draft.apiKey
    }

    private func syncDraftFromControls() {
        draftConfig.provider = providerIDForSelection()
        draftConfig.model = modelPopup.selectedItem?.title ?? models(for: draftConfig.provider).first ?? "gpt-4.1-mini"
        draftConfig.apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clearValidationStateIfNeeded() {
        syncDraftFromControls()
        if lastValidatedConfig != draftConfig {
            lastValidatedConfig = nil
            lastValidationSucceeded = false
            aiValidationLabel.stringValue = ""
            aiValidationLabel.isHidden = true
        }
    }

    private func refreshUI() {
        syncDraftFromControls()
        let runtimeSnapshot = latestRuntimeSnapshot
        let currentProviderName = providerCatalog.first(where: { $0.id == savedConfig.provider })?.name ?? savedConfig.provider
        aiCurrentConfigLabel.stringValue = L10n.format(
            zhHans: "当前生效：%@ · %@",
            en: "Active now: %@ · %@",
            currentProviderName,
            savedConfig.model
        )

        if draftConfig != savedConfig {
            aiDraftStatusLabel.stringValue = L10n.text(zhHans: "你有未生效修改。点一次“测试连接”，通过后会自动生效。", en: "You have unapplied changes. Run Test Connection once and they'll become active after validation succeeds.")
            aiDraftStatusLabel.textColor = DesignTokens.Settings.Status.warning
        } else {
            aiDraftStatusLabel.stringValue = L10n.text(zhHans: "这就是当前正在使用的配置。", en: "This is the configuration currently in use.")
            aiDraftStatusLabel.textColor = DesignTokens.Settings.Status.neutral
        }

        switch runtimeSnapshot.phase {
        case .ready:
            aiRuntimeStatusLabel.stringValue = ""
            aiRuntimeStatusLabel.isHidden = true
        case .degraded:
            aiRuntimeStatusLabel.stringValue = L10n.text(zhHans: "内建 AI 运行时当前处于受限模式。", en: "The built-in AI runtime is currently in a limited mode.")
            aiRuntimeStatusLabel.textColor = DesignTokens.Settings.Status.neutral
            aiRuntimeStatusLabel.isHidden = false
        case .starting:
            aiRuntimeStatusLabel.stringValue = L10n.text(zhHans: "内建 AI 运行时启动中...", en: "The built-in AI runtime is starting...")
            aiRuntimeStatusLabel.textColor = DesignTokens.Settings.Status.neutral
            aiRuntimeStatusLabel.isHidden = false
        case .failed:
            aiRuntimeStatusLabel.stringValue = L10n.text(zhHans: "内建 AI 运行时暂不可用，请稍后重试。", en: "The built-in AI runtime is temporarily unavailable. Please try again later.")
            aiRuntimeStatusLabel.textColor = DesignTokens.Settings.Status.warning
            aiRuntimeStatusLabel.isHidden = false
        case .stopped:
            aiRuntimeStatusLabel.stringValue = L10n.text(zhHans: "内建 AI 运行时尚未启动。", en: "The built-in AI runtime has not started yet.")
            aiRuntimeStatusLabel.textColor = DesignTokens.Settings.Status.neutral
            aiRuntimeStatusLabel.isHidden = false
        }
    }
}

@MainActor
final class SettingsKnowledgeBaseCoordinator {
    static let pageSize = 10

    private let knowledgeBaseStore: ReplyKnowledgeBaseStore
    private let updateStatusMessage: (String?) -> Void
    private let updateSourceButtons: ([KnowledgeBaseSourceTab: Int], KnowledgeBaseSourceTab) -> Void
    private let onEntriesChanged: () -> Void

    private(set) var entries: [ReplyKnowledgeBaseEntry] = []
    private(set) var selectedSourceTab: KnowledgeBaseSourceTab = .all
    private(set) var searchQuery: String = ""
    private(set) var currentPageIndex: Int = 0

    init(
        knowledgeBaseStore: ReplyKnowledgeBaseStore,
        updateStatusMessage: @escaping (String?) -> Void,
        updateSourceButtons: @escaping ([KnowledgeBaseSourceTab: Int], KnowledgeBaseSourceTab) -> Void,
        onEntriesChanged: @escaping () -> Void
    ) {
        self.knowledgeBaseStore = knowledgeBaseStore
        self.updateStatusMessage = updateStatusMessage
        self.updateSourceButtons = updateSourceButtons
        self.onEntriesChanged = onEntriesChanged
    }

    var filteredEntries: [ReplyKnowledgeBaseEntry] {
        entries.filter { entry in
            guard selectedSourceTab.includes(entry) else { return false }
            let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuery.isEmpty else { return true }
            let loweredQuery = trimmedQuery.localizedLowercase
            return [
                entry.title,
                entry.originalFilename,
                entry.summary,
                entry.preview,
                entry.externalURL ?? "",
                entry.topics?.joined(separator: " ") ?? "",
                entry.entities?.joined(separator: " ") ?? ""
            ]
            .joined(separator: "\n")
            .localizedLowercase
            .contains(loweredQuery)
        }
    }

    var visibleEntries: [ReplyKnowledgeBaseEntry] {
        let filtered = filteredEntries
        guard !filtered.isEmpty else { return [] }
        let startIndex = currentPageIndex * Self.pageSize
        guard startIndex < filtered.count else { return Array(filtered.prefix(Self.pageSize)) }
        let endIndex = min(startIndex + Self.pageSize, filtered.count)
        return Array(filtered[startIndex..<endIndex])
    }

    var totalPageCount: Int {
        max(1, Int(ceil(Double(filteredEntries.count) / Double(Self.pageSize))))
    }

    var currentPageNumber: Int {
        min(currentPageIndex + 1, totalPageCount)
    }

    var visibleRangeText: String {
        let filtered = filteredEntries
        guard !filtered.isEmpty else {
            return L10n.text(zhHans: "0 / 0", en: "0 / 0")
        }
        let start = currentPageIndex * Self.pageSize + 1
        let end = min(start + Self.pageSize - 1, filtered.count)
        return L10n.format(
            zhHans: "%d-%d / %d",
            en: "%d-%d / %d",
            start,
            end,
            filtered.count
        )
    }

    func loadFromSettings() {
        if KnowledgeBaseSourceTab.availableTabs.contains(selectedSourceTab) == false {
            selectedSourceTab = .all
        }
        searchQuery = ""
        currentPageIndex = 0
        reloadEntries()
    }

    func reloadEntries(status: String? = nil) {
        if KnowledgeBaseSourceTab.availableTabs.contains(selectedSourceTab) == false {
            selectedSourceTab = .all
        }
        entries = knowledgeBaseStore.entries()
        clampCurrentPageIndex()
        updateStatusMessage(status)
        updateSourceTabs()
        onEntriesChanged()
    }

    func handleSourceFilterTap(tab: KnowledgeBaseSourceTab) {
        selectedSourceTab = KnowledgeBaseSourceTab.availableTabs.contains(tab) ? tab : .all
        currentPageIndex = 0
        updateSourceTabs()
        onEntriesChanged()
    }

    func handleSearchQueryChanged(_ query: String) {
        if KnowledgeBaseSourceTab.availableTabs.contains(selectedSourceTab) == false {
            selectedSourceTab = .all
        }
        searchQuery = query
        currentPageIndex = 0
        onEntriesChanged()
    }

    func goToPreviousPage() {
        guard currentPageIndex > 0 else { return }
        currentPageIndex -= 1
        onEntriesChanged()
    }

    func goToNextPage() {
        guard currentPageIndex + 1 < totalPageCount else { return }
        currentPageIndex += 1
        onEntriesChanged()
    }

    func handleKnowledgeBaseChanged() {
        reloadEntries()
    }

    func emptyStateText() -> String {
        switch selectedSourceTab {
        case .all:
            return L10n.text(zhHans: "还没有知识库内容。你可以先导入 URL 或文件，后续支持知识库的技能就能直接复用这些资料。", en: "There is no knowledge base content yet. Import a URL or file first, and future knowledge-base skills can reuse it directly.")
        case .url:
            return L10n.text(zhHans: "还没有链接来源。把产品页、帮助中心、文档链接等采集进来后，就能被知识库检索到。", en: "There are no URL sources yet. Collect product pages, help-center articles, or docs so the knowledge base can retrieve them.")
        case .file:
            return L10n.text(zhHans: "还没有文件知识库。你可以把常用 PDF、文档或说明文件放进来。", en: "There are no file-based knowledge entries yet. Add your common PDFs, docs, or reference files here.")
        case .notion:
            return ""
        }
    }

    private func updateSourceTabs() {
        let counts: [KnowledgeBaseSourceTab: Int] = [
            .all: entries.count,
            .url: entries.filter { $0.sourceKind == .url }.count,
            .file: entries.filter { $0.sourceKind == .file }.count,
            .notion: entries.filter { $0.sourceKind == .notion }.count
        ]
        updateSourceButtons(counts, selectedSourceTab)
    }

    private func clampCurrentPageIndex() {
        currentPageIndex = max(0, min(currentPageIndex, totalPageCount - 1))
    }
}

@MainActor
final class SettingsKnowledgeBaseListCoordinator {
    private let knowledgeBaseStore: ReplyKnowledgeBaseStore
    private let diagnosticsLogger: DiagnosticsLogger
    private let scrollView: NSScrollView
    private let hostView: NSView
    private let listStack: NSStackView
    private let emptyLabel: NSTextField
    private let setStatusMessage: (String?) -> Void
    private let makeRow: (
        ReplyKnowledgeBaseEntry,
        @escaping (ReplyKnowledgeBaseEntry) -> Void,
        @escaping (String) -> Void,
        @escaping (String) -> Void,
        @escaping (String, Bool) -> Void,
        @escaping (String) -> Void
    ) -> NSView
    private let onReloadRequested: (String?) -> Void
    private let onLayoutRefreshRequested: () -> Void

    init(
        knowledgeBaseStore: ReplyKnowledgeBaseStore,
        diagnosticsLogger: DiagnosticsLogger,
        scrollView: NSScrollView,
        hostView: NSView,
        listStack: NSStackView,
        emptyLabel: NSTextField,
        setStatusMessage: @escaping (String?) -> Void,
        makeRow: @escaping (
            ReplyKnowledgeBaseEntry,
            @escaping (ReplyKnowledgeBaseEntry) -> Void,
            @escaping (String) -> Void,
            @escaping (String) -> Void,
            @escaping (String, Bool) -> Void,
            @escaping (String) -> Void
        ) -> NSView,
        onReloadRequested: @escaping (String?) -> Void,
        onLayoutRefreshRequested: @escaping () -> Void
    ) {
        self.knowledgeBaseStore = knowledgeBaseStore
        self.diagnosticsLogger = diagnosticsLogger
        self.scrollView = scrollView
        self.hostView = hostView
        self.listStack = listStack
        self.emptyLabel = emptyLabel
        self.setStatusMessage = setStatusMessage
        self.makeRow = makeRow
        self.onReloadRequested = onReloadRequested
        self.onLayoutRefreshRequested = onLayoutRefreshRequested
    }

    func render(entries: [ReplyKnowledgeBaseEntry], emptyStateText: String, topAccessoryView: NSView? = nil) {
        listStack.arrangedSubviews.forEach { view in
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if let topAccessoryView {
            listStack.addArrangedSubview(topAccessoryView)
            topAccessoryView.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }

        if entries.isEmpty {
            emptyLabel.stringValue = emptyStateText
            emptyLabel.isHidden = false
            scrollView.isHidden = true
            onLayoutRefreshRequested()
            return
        }

        emptyLabel.isHidden = true
        scrollView.isHidden = false

        for entry in entries {
            let row = makeRow(
                entry,
                { [weak self] entry in self?.openSource(for: entry) },
                { [weak self] entryID in self?.refreshEntry(id: entryID) },
                { [weak self] entryID in self?.reindexEntry(id: entryID) },
                { [weak self] entryID, isEnabled in self?.toggleEntry(id: entryID, isEnabled: isEnabled) },
                { [weak self] entryID in self?.deleteEntry(id: entryID) }
            )
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
        onLayoutRefreshRequested()
    }

    private func openSource(for entry: ReplyKnowledgeBaseEntry) {
        diagnosticsLogger.log("settings.knowledge_base", "open source kind=\(entry.sourceKind?.rawValue ?? "unknown") id=\(entry.id)")
        Task { @MainActor in
            KnowledgeBaseSourceActionResolver.performPrimaryAction(
                for: entry,
                languageCode: AppSettings.shared.appLanguage.languageCode
            )
        }
    }

    private func toggleEntry(id: String, isEnabled: Bool) {
        diagnosticsLogger.log("settings.knowledge_base", "toggle id=\(id) enabled=\(isEnabled)")
        if knowledgeBaseStore.setEntryEnabled(id: id, isEnabled: isEnabled) {
            onReloadRequested(isEnabled
                ? L10n.text(zhHans: "已启用这份知识。", en: "This knowledge source is enabled.")
                : L10n.text(zhHans: "已停用这份知识，不会再参与检索。", en: "This knowledge source is disabled and will no longer be used for retrieval."))
        } else {
            setStatusMessage(L10n.text(zhHans: "更新知识状态失败，请稍后重试。", en: "Failed to update the knowledge state. Please try again shortly."))
        }
    }

    private func refreshEntry(id: String) {
        diagnosticsLogger.log("settings.knowledge_base", "refresh id=\(id)")
        setStatusMessage(L10n.text(zhHans: "正在刷新来源...", en: "Refreshing source..."))
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.knowledgeBaseStore.refreshEntry(id: id) != nil {
                self.onReloadRequested(L10n.text(zhHans: "来源已刷新。", en: "Source refreshed."))
            } else {
                self.setStatusMessage(L10n.text(zhHans: "刷新失败，请稍后重试。", en: "Refresh failed. Please try again shortly."))
            }
        }
    }

    private func reindexEntry(id: String) {
        diagnosticsLogger.log("settings.knowledge_base", "reindex id=\(id)")
        setStatusMessage(L10n.text(zhHans: "正在重建索引...", en: "Rebuilding index..."))
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.knowledgeBaseStore.reindexEntry(id: id) != nil {
                self.onReloadRequested(L10n.text(zhHans: "索引已重建。", en: "Index rebuilt."))
            } else {
                self.setStatusMessage(L10n.text(zhHans: "重建索引失败，请稍后重试。", en: "Reindex failed. Please try again shortly."))
            }
        }
    }

    private func deleteEntry(id: String) {
        let alert = NSAlert()
        alert.messageText = L10n.text(zhHans: "删除这份知识库文件？", en: "Delete this knowledge file?")
        alert.informativeText = L10n.text(zhHans: "删除后，这份资料将不会再参与任何技能的知识库检索。", en: "After deletion, this content will no longer participate in any skill's knowledge retrieval.")
        alert.addButton(withTitle: L10n.text(zhHans: "删除", en: "Delete"))
        alert.addButton(withTitle: L10n.text(zhHans: "取消", en: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        diagnosticsLogger.log("settings.knowledge_base", "delete id=\(id)")
        if knowledgeBaseStore.deleteEntry(id: id) {
            onReloadRequested(L10n.text(zhHans: "已删除知识库文件。", en: "Knowledge file deleted."))
        } else {
            setStatusMessage(L10n.text(zhHans: "删除失败，请稍后重试。", en: "Delete failed. Please try again shortly."))
        }
    }
}

private enum MembershipActionLayout {
    case entitlementRefreshOnly
    case activationAndRefresh
}

@MainActor
final class SettingsMembershipPresenter {
    private let settings: AppSettings
    private let commerceService: CommerceService
    private let membershipContentStack: NSStackView
    private let entitlementSummaryLabel: NSTextField
    private let founderOfferLabel: NSTextField
    private let inviteCodeField: NSTextField
    private let inviteResultLabel: NSTextField
    private let subscriptionPlanPopup: SettingsDropdownButton
    private let subscriptionStatusLabel: NSTextField
    private let commerceHistoryContentLabel: NSTextField
    private let membershipActionRow: NSStackView
    private let membershipHistoryBlock: NSView
    private let membershipHistoryLabel: NSTextField
    private let membershipInviteLabel: NSTextField
    private let membershipInviteRow: NSStackView
    private let membershipPlanRow: NSStackView
    private let activateSubscriptionButton: NSButton
    private let refreshEntitlementButton: NSButton
    private let refreshLayout: () -> Void

    init(
        settings: AppSettings,
        commerceService: CommerceService,
        membershipContentStack: NSStackView,
        entitlementSummaryLabel: NSTextField,
        founderOfferLabel: NSTextField,
        inviteCodeField: NSTextField,
        inviteResultLabel: NSTextField,
        subscriptionPlanPopup: SettingsDropdownButton,
        subscriptionStatusLabel: NSTextField,
        commerceHistoryContentLabel: NSTextField,
        membershipActionRow: NSStackView,
        membershipHistoryBlock: NSView,
        membershipHistoryLabel: NSTextField,
        membershipInviteLabel: NSTextField,
        membershipInviteRow: NSStackView,
        membershipPlanRow: NSStackView,
        activateSubscriptionButton: NSButton,
        refreshEntitlementButton: NSButton,
        refreshLayout: @escaping () -> Void
    ) {
        self.settings = settings
        self.commerceService = commerceService
        self.membershipContentStack = membershipContentStack
        self.entitlementSummaryLabel = entitlementSummaryLabel
        self.founderOfferLabel = founderOfferLabel
        self.inviteCodeField = inviteCodeField
        self.inviteResultLabel = inviteResultLabel
        self.subscriptionPlanPopup = subscriptionPlanPopup
        self.subscriptionStatusLabel = subscriptionStatusLabel
        self.commerceHistoryContentLabel = commerceHistoryContentLabel
        self.membershipActionRow = membershipActionRow
        self.membershipHistoryBlock = membershipHistoryBlock
        self.membershipHistoryLabel = membershipHistoryLabel
        self.membershipInviteLabel = membershipInviteLabel
        self.membershipInviteRow = membershipInviteRow
        self.membershipPlanRow = membershipPlanRow
        self.activateSubscriptionButton = activateSubscriptionButton
        self.refreshEntitlementButton = refreshEntitlementButton
        self.refreshLayout = refreshLayout
    }

    func redeemInvite() {
        let code = inviteCodeField.stringValue
        inviteResultLabel.stringValue = L10n.text(zhHans: "正在兑换激活码...", en: "Redeeming activation code...")
        inviteResultLabel.textColor = DesignTokens.Settings.Status.neutral
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.commerceService.redeemInvite(code: code)
            switch result {
            case .success(let message):
                self.inviteResultLabel.stringValue = message
                self.inviteResultLabel.textColor = DesignTokens.Settings.Status.success
                self.inviteCodeField.stringValue = ""
            case .failure(let message):
                self.inviteResultLabel.stringValue = message
                self.inviteResultLabel.textColor = DesignTokens.Settings.Status.warning
            }
            self.refresh()
        }
    }

    func activateLocalSubscription() {
        let selectedPlanIndex = max(0, subscriptionPlanPopup.indexOfSelectedItem)
        let clampedIndex = min(selectedPlanIndex, CommerceSubscriptionPlan.allCases.count - 1)
        let plan = CommerceSubscriptionPlan.allCases[clampedIndex]
        subscriptionStatusLabel.stringValue = L10n.text(zhHans: "正在检查订阅接入状态...", en: "Checking subscription availability...")
        subscriptionStatusLabel.textColor = DesignTokens.Settings.Status.neutral
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.commerceService.activateLocalSubscription(plan)
            switch result {
            case .success(let message):
                self.subscriptionStatusLabel.stringValue = message
                self.subscriptionStatusLabel.textColor = DesignTokens.Settings.Status.success
            case .failure(let message):
                self.subscriptionStatusLabel.stringValue = message
                self.subscriptionStatusLabel.textColor = DesignTokens.Settings.Status.neutral
            }
            self.refresh()
        }
    }

    func cancelSubscription() {
        subscriptionStatusLabel.stringValue = L10n.text(zhHans: "正在刷新权益状态...", en: "Refreshing entitlement status...")
        subscriptionStatusLabel.textColor = DesignTokens.Settings.Status.neutral
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.commerceService.cancelSubscription()
            switch result {
            case .success(let message):
                self.subscriptionStatusLabel.stringValue = message
                self.subscriptionStatusLabel.textColor = DesignTokens.Settings.Status.success
            case .failure(let message):
                self.subscriptionStatusLabel.stringValue = message
                self.subscriptionStatusLabel.textColor = DesignTokens.Settings.Status.warning
            }
            self.refresh()
        }
    }

    func refresh() {
        refresh(
            entitlementSnapshot: commerceService.entitlementSnapshot,
            redemptionHistoryText: commerceService.redemptionHistoryText()
        )
    }

    func refresh(
        entitlementSnapshot snapshot: CommerceEntitlementSnapshot,
        redemptionHistoryText: String
    ) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.appLanguage.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let hasActiveSubscription = (snapshot.activeSubscription != nil)
        let hasActiveInvite = (snapshot.activeInvite != nil)
        let hasActivatedEntitlement = hasActiveSubscription || hasActiveInvite

        entitlementSummaryLabel.stringValue = summaryText(snapshot: snapshot, formatter: formatter)
        founderOfferLabel.stringValue = founderOfferText(snapshot: snapshot)

        let selectedIndex = max(0, subscriptionPlanPopup.indexOfSelectedItem)
        let statusPresentation = statusPresentation(snapshot: snapshot)
        subscriptionStatusLabel.stringValue = statusPresentation.text
        subscriptionStatusLabel.textColor = statusPresentation.color
        commerceHistoryContentLabel.stringValue = redemptionHistoryText

        let historyText = commerceHistoryContentLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHistory = !historyText.isEmpty
        let showInviteResult = !hasActivatedEntitlement && !inviteResultLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasActivatedEntitlement {
            subscriptionPlanPopup.selectItem(at: selectedIndex)
        }

        configureActionRow(hasActivatedEntitlement ? .entitlementRefreshOnly : .activationAndRefresh)
        rebuildMembershipContent(
            hasActivatedEntitlement: hasActivatedEntitlement,
            showInviteResult: showInviteResult,
            showHistory: hasHistory
        )
        refreshLayout()
    }

    private func summaryText(snapshot: CommerceEntitlementSnapshot, formatter: DateFormatter) -> String {
        var summaryLines: [String] = []
        summaryLines.append(snapshot.isPro
            ? L10n.text(zhHans: "当前权益：NexHub Pro", en: "Current entitlement: NexHub Pro")
            : L10n.text(zhHans: "当前权益：免费版", en: "Current entitlement: Free"))

        if let subscription = snapshot.activeSubscription {
            summaryLines.append(L10n.format(
                zhHans: "正式订阅：%@ · 到期：%@",
                en: "Subscription: %@ · Expires %@",
                subscription.displayName,
                formatter.string(from: subscription.expiresAt)
            ))
        } else if let invite = snapshot.activeInvite {
            if invite.grantsPermanentPro {
                summaryLines.append(L10n.format(
                    zhHans: "当前邀请码权益：%@ · 长期有效",
                    en: "Invite entitlement: %@ · Permanent",
                    invite.kind.displayName
                ))
            } else if let expiresAt = invite.expiresAt {
                summaryLines.append(L10n.format(
                    zhHans: "当前邀请码权益：%@ · 到期：%@",
                    en: "Invite entitlement: %@ · Expires %@",
                    invite.kind.displayName,
                    formatter.string(from: expiresAt)
                ))
            } else {
                summaryLines.append(L10n.format(
                    zhHans: "当前邀请码权益：%@",
                    en: "Invite entitlement: %@",
                    invite.kind.displayName
                ))
            }
        }
        return summaryLines.joined(separator: "\n")
    }

    private func founderOfferText(snapshot: CommerceEntitlementSnapshot) -> String {
        if let founderPrice = snapshot.founderAnnualPrice {
            return L10n.format(
                zhHans: "Founder 年付资格已解锁：%@",
                en: "Founder annual price unlocked: %@",
                founderPrice
            )
        }
        return L10n.text(
            zhHans: "Founder 邀请码可解锁专属年付价。",
            en: "A Founder invite unlocks the Founder annual price."
        )
    }

    private func statusPresentation(snapshot: CommerceEntitlementSnapshot) -> (text: String, color: NSColor) {
        if snapshot.activeSubscription != nil {
            return (
                L10n.text(zhHans: "你已激活正式订阅。", en: "Your subscription is active."),
                DesignTokens.Settings.Status.success
            )
        }
        if let invite = snapshot.activeInvite {
            return (
                L10n.format(
                    zhHans: "你已通过 %@ 邀请码激活 Pro。",
                    en: "Pro is active through your %@ invite.",
                    invite.kind.displayName
                ),
                DesignTokens.Settings.Status.success
            )
        }
        return (
            L10n.text(zhHans: "可先兑换邀请码，或预览下方订阅计划。", en: "Redeem an invite code or preview the plans below."),
            DesignTokens.Settings.Status.neutral
        )
    }

    private func configureActionRow(_ layout: MembershipActionLayout) {
        let actions: [NSView]
        switch layout {
        case .entitlementRefreshOnly:
            actions = [refreshEntitlementButton]
        case .activationAndRefresh:
            actions = [activateSubscriptionButton, refreshEntitlementButton]
        }
        membershipActionRow.setViews(actions, in: .leading)
    }

    private func rebuildMembershipContent(
        hasActivatedEntitlement: Bool,
        showInviteResult: Bool,
        showHistory: Bool
    ) {
        membershipContentStack.arrangedSubviews.forEach { subview in
            membershipContentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        var sections: [NSView] = [
            entitlementSummaryLabel,
            subscriptionStatusLabel
        ]

        if hasActivatedEntitlement {
            sections.append(membershipActionRow)
        } else {
            sections.append(founderOfferLabel)
            sections.append(membershipInviteLabel)
            sections.append(membershipInviteRow)
            if showInviteResult {
                sections.append(inviteResultLabel)
            }
            sections.append(membershipPlanRow)
            sections.append(membershipActionRow)
        }

        if showHistory {
            sections.append(membershipHistoryLabel)
            sections.append(membershipHistoryBlock)
        }

        sections.forEach { membershipContentStack.addArrangedSubview($0) }

        [entitlementSummaryLabel, founderOfferLabel, inviteResultLabel, subscriptionStatusLabel, membershipHistoryBlock].forEach {
            guard sections.contains($0) else { return }
            $0.widthAnchor.constraint(equalTo: membershipContentStack.widthAnchor).isActive = true
        }
    }
}
