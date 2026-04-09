import AppKit

final class SkillCenterWindowController: NSWindowController, NSSearchFieldDelegate {
    var onRequestOpenKnowledgeBaseSettings: (() -> Void)?

    private struct SkillSection {
        let title: String
        let subtitle: String?
        let items: [SkillInventoryItem]
    }

    private let registry = SkillRegistry.shared
    private let actionRegistry = ActionRegistry.shared
    private let skillPlatformSnapshotProvider = SkillPlatformSnapshotProvider.shared
    private let catalogService = SkillCatalogService.shared
    private let packageManager = SkillPackageManager.shared
    private let settings = AppSettings.shared

    private let titleLabel = NSTextField(labelWithString: L10n.text(zhHans: "技能", en: "Skills"))
    private let subtitleLabel = NSTextField(wrappingLabelWithString: L10n.text(zhHans: "已安装、可获取和可更新的技能都在这里管理。", en: "Manage installed, available, and updatable skills here."))
    private let refreshButton = SkillCenterButton(title: L10n.text(zhHans: "刷新", en: "Refresh"), role: .secondary)
    private let getButton = SkillCenterButton(title: L10n.text(zhHans: "获取技能", en: "Get Skills"), role: .primary)
    private let filterStackView = NSStackView()
    private var filterButtons: [SkillListFilter: SkillCenterButton] = [:]

    private let listScrollView = NSScrollView()
    private let listContentView = SkillCenterFlippedView()
    private let listStackView = NSStackView()
    private let emptyStateView = SkillCenterEmptyStateView()

    private let overlayBackdropButton = NSButton(title: "", target: nil, action: nil)
    private let overlayPanelSurface = SkillCenterDetailOverlaySurfaceView()
    private let overlayStackView = NSStackView()
    private let overlayCloseButton = SkillCenterIconButton()
    private let detailHeaderView = SkillCenterDetailHeaderView()
    private let detailOverviewSection = SkillCenterDetailSectionView(title: L10n.text(zhHans: "概览", en: "Overview"))
    private let detailPermissionSection = SkillCenterDetailSectionView(title: L10n.text(zhHans: "权限与执行", en: "Permissions & Execution"))
    private let detailReleaseSection = SkillCenterDetailSectionView(title: L10n.text(zhHans: "发布信息", en: "Release Notes"))
    private let detailKnowledgeBaseSection = SkillCenterDetailSectionView(title: L10n.text(zhHans: "知识库引用", en: "Knowledge Base"))
    private let primaryActionButton = SkillCenterButton(title: L10n.text(zhHans: "获取技能", en: "Get Skill"), role: .primary)
    private let knowledgeBaseCheckbox = NSButton(checkboxWithTitle: L10n.text(zhHans: "使用知识库", en: "Use Knowledge Base"), target: nil, action: nil)
    private let secondaryActionButton = SkillCenterButton(title: L10n.text(zhHans: "启用", en: "Enable"), role: .secondary)
    private let tertiaryActionButton = SkillCenterButton(title: L10n.text(zhHans: "卸载", en: "Uninstall"), role: .destructive)
    private let footerStatusLabel = NSTextField(wrappingLabelWithString: "")

    private var currentFilter: SkillListFilter = .all
    private var currentItems: [SkillInventoryItem] = []
    private var selectedSkillID: String?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.format(zhHans: "%@ 技能", en: "%@ Skills", AppBrand.displayName)
        window.minSize = NSSize(width: 820, height: 640)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = DesignTokens.Color.surfacePanel
        window.isMovableByWindowBackground = true
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }

        super.init(window: window)
        configureWindow()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSkillPlatformSnapshotChanged),
            name: .skillPlatformSnapshotDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: .appSettingsDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func presentWindow() {
        reloadInventory(preserveSelection: true)
        updateCatalogStatus()
        dismissDetailOverlay()
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { await refreshCatalog(showStatus: false) }
    }

    private func configureWindow() {
        guard let contentView = window?.contentView else { return }
        let safeGuide = contentView.safeAreaLayoutGuide

        let backdrop = SkillCenterBackdropView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backdrop)

        let contentStack = NSStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = DesignTokens.SkillCenter.Page.contentSpacing
        backdrop.addSubview(contentStack)

        configureHeader(into: contentStack)
        configureList(into: contentStack)
        configureOverlay(in: backdrop)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: DesignTokens.SkillCenter.Page.horizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -DesignTokens.SkillCenter.Page.horizontalInset),
            contentStack.topAnchor.constraint(equalTo: safeGuide.topAnchor, constant: DesignTokens.SkillCenter.Page.topInset),
            contentStack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -DesignTokens.SkillCenter.Page.bottomInset),
        ])
    }

    private func configureHeader(into stack: NSStackView) {
        let headerContainer = NSView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        let filterContainer = NSView()
        filterContainer.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = DesignTokens.SkillCenter.Page.titleFont
        titleLabel.textColor = DesignTokens.Color.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = DesignTokens.SkillCenter.Page.subtitleFont
        subtitleLabel.textColor = DesignTokens.Color.textSecondary
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        headerContainer.addSubview(titleLabel)
        headerContainer.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: headerContainer.topAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.SkillCenter.Page.titleSubtitleSpacing),
            subtitleLabel.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
        ])

        stack.addArrangedSubview(headerContainer)
        headerContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        filterStackView.orientation = .horizontal
        filterStackView.alignment = .centerY
        filterStackView.spacing = DesignTokens.SkillCenter.Page.filterSpacing
        filterStackView.translatesAutoresizingMaskIntoConstraints = false
        SkillListFilter.allCases.forEach { filter in
            let button = SkillCenterButton(title: filter.title, role: .filter(isSelected: filter == currentFilter))
            button.target = self
            button.action = #selector(handleFilterButtonTap(_:))
            button.identifier = NSUserInterfaceItemIdentifier("\(filter.rawValue)")
            filterButtons[filter] = button
            filterStackView.addArrangedSubview(button)
        }

        filterContainer.addSubview(filterStackView)
        NSLayoutConstraint.activate([
            filterStackView.leadingAnchor.constraint(equalTo: filterContainer.leadingAnchor),
            filterStackView.topAnchor.constraint(equalTo: filterContainer.topAnchor),
            filterStackView.bottomAnchor.constraint(equalTo: filterContainer.bottomAnchor),
            filterStackView.trailingAnchor.constraint(lessThanOrEqualTo: filterContainer.trailingAnchor),
        ])

        stack.addArrangedSubview(filterContainer)
        filterContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func configureList(into stack: NSStackView) {
        listScrollView.translatesAutoresizingMaskIntoConstraints = false
        listScrollView.drawsBackground = false
        listScrollView.borderType = .noBorder
        listScrollView.hasVerticalScroller = false
        listScrollView.automaticallyAdjustsContentInsets = false
        listScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: DesignTokens.SkillCenter.Page.minimumListHeight).isActive = true

        listContentView.translatesAutoresizingMaskIntoConstraints = false
        listStackView.orientation = .vertical
        listStackView.alignment = .width
        listStackView.spacing = DesignTokens.SkillCenter.Page.listSpacing
        listStackView.translatesAutoresizingMaskIntoConstraints = false
        listContentView.addSubview(listStackView)
        listScrollView.documentView = listContentView

        NSLayoutConstraint.activate([
            listStackView.leadingAnchor.constraint(equalTo: listContentView.leadingAnchor),
            listStackView.trailingAnchor.constraint(equalTo: listContentView.trailingAnchor),
            listStackView.topAnchor.constraint(equalTo: listContentView.topAnchor),
            listStackView.bottomAnchor.constraint(equalTo: listContentView.bottomAnchor),
            listStackView.widthAnchor.constraint(equalTo: listScrollView.contentView.widthAnchor),
        ])

        stack.addArrangedSubview(listScrollView)
        listScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func configureOverlay(in root: NSView) {
        overlayBackdropButton.translatesAutoresizingMaskIntoConstraints = false
        overlayBackdropButton.isBordered = false
        overlayBackdropButton.bezelStyle = .regularSquare
        overlayBackdropButton.wantsLayer = true
        overlayBackdropButton.layer?.backgroundColor = DesignTokens.SkillCenter.Detail.backdrop.cgColor
        overlayBackdropButton.target = self
        overlayBackdropButton.action = #selector(handleDismissOverlay)
        overlayBackdropButton.isHidden = true
        root.addSubview(overlayBackdropButton)

        overlayPanelSurface.translatesAutoresizingMaskIntoConstraints = false
        overlayPanelSurface.isHidden = true
        root.addSubview(overlayPanelSurface)

        overlayStackView.orientation = .vertical
        overlayStackView.alignment = .width
        overlayStackView.spacing = DesignTokens.SkillCenter.Overlay.stackSpacing
        overlayStackView.translatesAutoresizingMaskIntoConstraints = false
        overlayPanelSurface.addSubview(overlayStackView)

        overlayCloseButton.target = self
        overlayCloseButton.action = #selector(handleDismissOverlay)
        primaryActionButton.target = self
        primaryActionButton.action = #selector(handlePrimaryAction)
        knowledgeBaseCheckbox.target = self
        knowledgeBaseCheckbox.action = #selector(handleKnowledgeBaseToggle)
        knowledgeBaseCheckbox.font = DesignTokens.SkillCenter.Overlay.checkboxFont
        secondaryActionButton.target = self
        secondaryActionButton.action = #selector(handleSecondaryAction)
        tertiaryActionButton.target = self
        tertiaryActionButton.action = #selector(handleTertiaryAction)
        detailHeaderView.closeButton = overlayCloseButton

        let actionRow = NSStackView(views: [primaryActionButton, knowledgeBaseCheckbox, secondaryActionButton, tertiaryActionButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = DesignTokens.SkillCenter.Overlay.actionSpacing
        actionRow.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        footerStatusLabel.font = DesignTokens.SkillCenter.Overlay.footerFont
        footerStatusLabel.textColor = DesignTokens.Color.textTertiary
        footerStatusLabel.maximumNumberOfLines = 0

        overlayStackView.addArrangedSubview(detailHeaderView)
        overlayStackView.addArrangedSubview(detailOverviewSection)
        overlayStackView.addArrangedSubview(detailPermissionSection)
        overlayStackView.addArrangedSubview(detailReleaseSection)
        overlayStackView.addArrangedSubview(detailKnowledgeBaseSection)
        overlayStackView.addArrangedSubview(actionRow)
        overlayStackView.addArrangedSubview(footerStatusLabel)

        NSLayoutConstraint.activate([
            overlayBackdropButton.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlayBackdropButton.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlayBackdropButton.topAnchor.constraint(equalTo: root.topAnchor),
            overlayBackdropButton.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            overlayPanelSurface.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            overlayPanelSurface.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            overlayPanelSurface.widthAnchor.constraint(equalToConstant: DesignTokens.SkillCenter.Overlay.width),
            overlayPanelSurface.heightAnchor.constraint(lessThanOrEqualToConstant: DesignTokens.SkillCenter.Overlay.maxHeight),
            overlayPanelSurface.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: DesignTokens.SkillCenter.Overlay.outerInset),
            overlayPanelSurface.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -DesignTokens.SkillCenter.Overlay.outerInset),

            overlayStackView.leadingAnchor.constraint(equalTo: overlayPanelSurface.leadingAnchor, constant: DesignTokens.SkillCenter.Overlay.contentInset),
            overlayStackView.trailingAnchor.constraint(equalTo: overlayPanelSurface.trailingAnchor, constant: -DesignTokens.SkillCenter.Overlay.contentInset),
            overlayStackView.topAnchor.constraint(equalTo: overlayPanelSurface.topAnchor, constant: DesignTokens.SkillCenter.Overlay.contentInset),
            overlayStackView.bottomAnchor.constraint(lessThanOrEqualTo: overlayPanelSurface.bottomAnchor, constant: -DesignTokens.SkillCenter.Overlay.contentInset),
            detailHeaderView.widthAnchor.constraint(equalTo: overlayStackView.widthAnchor),
            detailOverviewSection.widthAnchor.constraint(equalTo: overlayStackView.widthAnchor),
            detailPermissionSection.widthAnchor.constraint(equalTo: overlayStackView.widthAnchor),
            detailReleaseSection.widthAnchor.constraint(equalTo: overlayStackView.widthAnchor),
            detailKnowledgeBaseSection.widthAnchor.constraint(equalTo: overlayStackView.widthAnchor),
        ])
    }

    @objc private func handleRefreshCatalog() {
        Task { await refreshCatalog(showStatus: true) }
    }

    @objc private func handleGetSkills() {
        currentFilter = .discover
        syncFilterButtons()
        reloadInventory(preserveSelection: false)
        Task { await refreshCatalog(showStatus: true) }
    }

    @objc private func handleFilterButtonTap(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let value = Int(rawValue),
              let filter = SkillListFilter(rawValue: value) else { return }
        currentFilter = filter
        syncFilterButtons()
        reloadInventory(preserveSelection: false)
    }

    @objc private func handlePrimaryAction() {
        guard let item = selectedItem else { return }
        if item.updateAvailable, let catalogItem = item.catalogItem {
            Task {
                await performAsyncAction(
                    await packageManager.updateCatalogItem(
                        catalogItem,
                        snapshot: skillPlatformSnapshotProvider.currentSnapshot().catalogSnapshot
                    )
                )
            }
            return
        }
        if !item.isInstalled, let catalogItem = item.catalogItem {
            Task {
                await performAsyncAction(
                    await packageManager.installCatalogItem(
                        catalogItem,
                        snapshot: skillPlatformSnapshotProvider.currentSnapshot().catalogSnapshot
                    )
                )
            }
            return
        }
        footerStatusLabel.stringValue = item.isEnabled
            ? L10n.text(zhHans: "技能已安装并可立即使用。", en: "This skill is installed and ready to use.")
            : L10n.text(zhHans: "技能已安装，但当前被禁用。", en: "This skill is installed but currently disabled.")
    }

    @objc private func handleSecondaryAction() {
        guard let item = selectedItem, item.isInstalled else { return }
        handleInstallResult(packageManager.setEnabled(!item.isEnabled, forSkillID: item.skillID))
    }

    @objc private func handleTertiaryAction() {
        guard let item = selectedItem else { return }
        guard item.installedDefinition?.skillSource == .installed || item.installedRecord != nil else {
            footerStatusLabel.stringValue = L10n.text(zhHans: "内置技能不可卸载。", en: "Built-in skills cannot be uninstalled.")
            return
        }
        handleInstallResult(packageManager.uninstallSkill(skillID: item.skillID))
    }

    @objc private func handleDismissOverlay() {
        dismissDetailOverlay()
    }

    @objc private func handleKnowledgeBaseToggle() {
        guard let item = selectedItem,
              item.installedDefinition?.usesKnowledgeBase == true else { return }
        let enabled = (knowledgeBaseCheckbox.state == .on)
        actionRegistry.setKnowledgeBaseEnabled(enabled, forSkillID: item.skillID, settings: settings)
        footerStatusLabel.stringValue = enabled
            ? L10n.text(zhHans: "这个技能会在执行时引用知识库。", en: "This skill will use the knowledge base during execution.")
            : L10n.text(zhHans: "这个技能已关闭知识库引用。", en: "Knowledge base usage is disabled for this skill.")
        reloadInventory(preserveSelection: true)
    }

    private var selectedItem: SkillInventoryItem? {
        currentItems.first(where: { $0.skillID == selectedSkillID }) ?? currentItems.first
    }

    private func reloadInventory(preserveSelection: Bool) {
        currentItems = registry.inventoryItems(settings: settings, filter: currentFilter, query: "")
        if !preserveSelection || !currentItems.contains(where: { $0.skillID == selectedSkillID }) {
            selectedSkillID = currentItems.first?.skillID
        }
        rebuildSections()
        if overlayPanelSurface.isHidden {
            return
        }
        if selectedItem == nil {
            dismissDetailOverlay()
        } else {
            updateDetailOverlay()
        }
    }

    private func rebuildSections() {
        listStackView.arrangedSubviews.forEach { view in
            listStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let sections = makeSections()
        guard !sections.isEmpty else {
            emptyStateView.configure(
                title: L10n.text(zhHans: "没有找到符合条件的技能", en: "No matching skills found"),
                message: L10n.text(zhHans: "试试切换筛选，或者刷新技能目录。", en: "Try another filter or refresh the skill catalog.")
            )
            listStackView.addArrangedSubview(emptyStateView)
            emptyStateView.widthAnchor.constraint(equalTo: listStackView.widthAnchor).isActive = true
            return
        }

        for section in sections {
            let header = SkillCenterSectionHeaderView(
                title: section.title,
                subtitle: section.subtitle,
                count: section.items.count
            )
            listStackView.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: listStackView.widthAnchor).isActive = true

            var index = 0
            while index < section.items.count {
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .top
                row.spacing = DesignTokens.SkillCenter.Page.sectionRowSpacing
                row.distribution = .fillEqually
                row.translatesAutoresizingMaskIntoConstraints = false

                for offset in 0..<2 {
                    let itemIndex = index + offset
                    if itemIndex < section.items.count {
                        let item = section.items[itemIndex]
                        let tile = SkillCenterTileView(item: item, isSelected: false)
                        tile.onSelect = { [weak self] skillID in
                            self?.presentDetailOverlay(for: skillID)
                        }
                        row.addArrangedSubview(tile)
                    } else {
                        let spacer = NSView()
                        spacer.translatesAutoresizingMaskIntoConstraints = false
                        row.addArrangedSubview(spacer)
                    }
                }

                listStackView.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: listStackView.widthAnchor).isActive = true
                index += 2
            }
        }
    }

    private func makeSections() -> [SkillSection] {
        switch currentFilter {
        case .all:
            let installed = currentItems.filter(\.isInstalled)
            let discover = currentItems.filter { !$0.isInstalled }
            var sections: [SkillSection] = []
            if !installed.isEmpty {
                sections.append(SkillSection(title: L10n.text(zhHans: "已安装", en: "Installed"), subtitle: nil, items: installed))
            }
            if !discover.isEmpty {
                sections.append(SkillSection(title: L10n.text(zhHans: "发现", en: "Discover"), subtitle: nil, items: discover))
            }
            return sections
        case .installed:
            return currentItems.isEmpty ? [] : [SkillSection(title: L10n.text(zhHans: "已安装", en: "Installed"), subtitle: nil, items: currentItems)]
        case .discover:
            return currentItems.isEmpty ? [] : [SkillSection(title: L10n.text(zhHans: "发现", en: "Discover"), subtitle: nil, items: currentItems)]
        case .updates:
            return currentItems.isEmpty ? [] : [SkillSection(title: L10n.text(zhHans: "更新可用", en: "Updates Available"), subtitle: nil, items: currentItems)]
        }
    }

    private func presentDetailOverlay(for skillID: String) {
        selectedSkillID = skillID
        rebuildSections()
        updateDetailOverlay()
        overlayBackdropButton.isHidden = false
        overlayPanelSurface.isHidden = false
        overlayPanelSurface.alphaValue = 0
        overlayBackdropButton.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.Motion.medium
            self.overlayBackdropButton.animator().alphaValue = 1
            self.overlayPanelSurface.animator().alphaValue = 1
        }
    }

    private func dismissDetailOverlay() {
        overlayBackdropButton.isHidden = true
        overlayPanelSurface.isHidden = true
        overlayBackdropButton.alphaValue = 0
        overlayPanelSurface.alphaValue = 0
    }

    private func updateDetailOverlay() {
        guard let item = selectedItem else {
            dismissDetailOverlay()
            return
        }

        let metaText = [
            item.sourceLabel,
            L10n.format(zhHans: "版本 %@", en: "Version %@", item.version),
            item.author.map { L10n.format(zhHans: "作者 %@", en: "By %@", $0) }
        ].compactMap { $0 }.joined(separator: "  ·  ")

        let badges = makeBadges(for: item).map { text in
            (text == stateLabel(for: item) ? SkillCenterBadgeLabel.Tone.accent : .neutral, text)
        }
        detailHeaderView.configure(
            symbolName: item.symbolName,
            accentColor: detailIconColor(for: item),
            title: item.displayName,
            summary: item.summary,
            badges: badges,
            meta: metaText
        )

        detailOverviewSection.configure(body: [
            L10n.format(zhHans: "支持入口：%@", en: "Entry points: %@", entryPathLabel(for: item.supportedContexts)),
            L10n.format(zhHans: "执行位置：%@", en: "Execution: %@", localityLabel(for: item.locality)),
            L10n.format(zhHans: "计费：%@", en: "Billing: %@", billingLabel(for: item.billingClass, requiredTier: item.requiredTier)),
            L10n.format(zhHans: "当前状态：%@", en: "Status: %@", stateLabel(for: item))
        ].joined(separator: "\n"))

        let permissionText = item.permissions.isEmpty
            ? L10n.text(zhHans: "权限：无额外权限声明。", en: "Permissions: no extra permissions declared.")
            : L10n.format(zhHans: "权限：%@", en: "Permissions: %@", item.permissions.map(permissionLabel(for:)).joined(separator: " · "))
        let privacyText = item.privacy?.retentionSummary ?? L10n.text(zhHans: "数据策略：未提供更多说明。", en: "Data policy: no additional details provided.")
        detailPermissionSection.configure(body: "\(permissionText)\n\(privacyText)")

        let releaseText = [
            item.catalogItem?.releaseNotes ?? L10n.text(zhHans: "暂无发布说明。", en: "No release notes yet."),
            item.catalogItem?.minAppVersion.map { L10n.format(zhHans: "最低版本：%@", en: "Minimum version: %@", $0) }
        ].compactMap { $0 }.joined(separator: "\n\n")
        detailReleaseSection.configure(body: releaseText)

        let knowledgeBaseEntries = ReplyKnowledgeBaseStore.shared.entries()
        if item.installedDefinition?.usesKnowledgeBase == true {
            let knowledgeBaseEnabled = actionRegistry.isKnowledgeBaseEnabled(item.skillID, settings: settings)
            detailKnowledgeBaseSection.isHidden = false
            if knowledgeBaseEntries.isEmpty {
                detailKnowledgeBaseSection.configure(body: L10n.text(zhHans: "当前还没有知识库资料。知识库内容统一在设置里的“知识库”Tab 管理；开启后，这个技能会在执行前先检索命中的知识片段。", en: "No knowledge base content yet. Manage knowledge in the Knowledge Base tab in Settings. Once enabled, this skill will search relevant knowledge snippets before execution."))
            } else {
                let totalChunks = knowledgeBaseEntries.reduce(0) { $0 + $1.chunkCount }
                detailKnowledgeBaseSection.configure(
                    body: L10n.format(
                        zhHans: "已导入 %d 份资料，共 %d 个解析片段。\n%@这个技能的知识库引用。知识库内容统一在设置里的“知识库”Tab 管理。",
                        en: "Imported %d knowledge sources with %d parsed chunks.\n%@ knowledge base usage for this skill. Manage all knowledge in the Knowledge Base tab in Settings.",
                        knowledgeBaseEntries.count,
                        totalChunks,
                        knowledgeBaseEnabled
                            ? L10n.text(zhHans: "当前已启用", en: "Currently enabled")
                            : L10n.text(zhHans: "当前已关闭", en: "Currently disabled")
                    )
                )
            }
            knowledgeBaseCheckbox.state = knowledgeBaseEnabled ? .on : .off
        } else {
            detailKnowledgeBaseSection.isHidden = true
            knowledgeBaseCheckbox.state = .off
        }

        primaryActionButton.title = primaryActionTitle(for: item)
        primaryActionButton.isEnabled = item.updateAvailable || !item.isInstalled

        knowledgeBaseCheckbox.isHidden = item.installedDefinition?.usesKnowledgeBase != true
        secondaryActionButton.isHidden = !item.isInstalled
        secondaryActionButton.title = item.isEnabled
            ? L10n.text(zhHans: "禁用", en: "Disable")
            : L10n.text(zhHans: "启用", en: "Enable")

        tertiaryActionButton.isHidden = !(item.installedDefinition?.skillSource == .installed || item.installedRecord != nil)
        footerStatusLabel.stringValue = item.updateAvailable ? L10n.text(zhHans: "有新版本可用。", en: "A newer version is available.") : ""
    }

    private func makeBadges(for item: SkillInventoryItem) -> [String] {
        var badges = Array(NSOrderedSet(array: item.supportedContexts.map(entryBadgeLabel(for:)))) as? [String] ?? []
        badges.append(localityLabel(for: item.locality))
        badges.append(billingBadgeLabel(for: item.billingClass))
        badges.append(stateLabel(for: item))
        return badges
    }

    private func primaryActionTitle(for item: SkillInventoryItem) -> String {
        if item.updateAvailable { return L10n.text(zhHans: "更新技能", en: "Update Skill") }
        if !item.isInstalled { return L10n.text(zhHans: "获取技能", en: "Get Skill") }
        return item.isEnabled ? L10n.text(zhHans: "已安装", en: "Installed") : L10n.text(zhHans: "已禁用", en: "Disabled")
    }

    private func stateLabel(for item: SkillInventoryItem) -> String {
        if item.updateAvailable { return L10n.text(zhHans: "更新可用", en: "Update Available") }
        if !item.isInstalled { return L10n.text(zhHans: "未安装", en: "Not Installed") }
        return item.isEnabled ? L10n.text(zhHans: "已安装", en: "Installed") : L10n.text(zhHans: "已禁用", en: "Disabled")
    }

    private func entryPathLabel(for contexts: [ActivationSource]) -> String {
        let labels = contexts.map(entryBadgeLabel(for:))
        return labels.isEmpty ? L10n.text(zhHans: "未声明", en: "Not Declared") : labels.joined(separator: " / ")
    }

    private func entryBadgeLabel(for source: ActivationSource) -> String {
        switch source {
        case .selectedText, .clipboardText:
            return L10n.text(zhHans: "文本", en: "Text")
        case .fileSelection:
            return L10n.text(zhHans: "文件", en: "Files")
        case .screenshotRegion, .imageCapture:
            return L10n.text(zhHans: "截图", en: "Screenshot")
        case .url:
            return "URL"
        case .inputBoxContext:
            return L10n.text(zhHans: "输入框", en: "Input")
        case .mixedContext:
            return L10n.text(zhHans: "混合", en: "Mixed")
        }
    }

    private func localityLabel(for locality: SkillExecutionLocality) -> String {
        switch locality {
        case .localOnly: return L10n.text(zhHans: "本地", en: "Local")
        case .localFirst: return L10n.text(zhHans: "本地优先", en: "Local First")
        case .hybrid: return L10n.text(zhHans: "混合", en: "Hybrid")
        case .cloudOnly: return L10n.text(zhHans: "云端", en: "Cloud")
        }
    }

    private func billingLabel(for billingClass: SkillBillingClass, requiredTier: SkillEntitlementTier?) -> String {
        let base = billingBadgeLabel(for: billingClass)
        if let requiredTier {
            return "\(base) · \(requiredTier.rawValue.uppercased())"
        }
        return base
    }

    private func billingBadgeLabel(for billingClass: SkillBillingClass) -> String {
        switch billingClass {
        case .free: return L10n.text(zhHans: "免费", en: "Free")
        case .proIncluded: return "Pro"
        case .usageMetered: return L10n.text(zhHans: "计量", en: "Metered")
        case .enterpriseOnly: return L10n.text(zhHans: "企业", en: "Enterprise")
        }
    }

    private func permissionLabel(for permission: SkillPermissionKind) -> String {
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

    private func syncFilterButtons() {
        for (filter, button) in filterButtons {
            button.updateRole(.filter(isSelected: filter == currentFilter))
        }
    }

    private func updateCatalogStatus() {
        subtitleLabel.stringValue = SkillCatalogStatusResolver.skillCenterSubtitleText(
            from: skillPlatformSnapshotProvider.currentSnapshot()
        )
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

    private func handleInstallResult(_ result: SkillInstallResult) {
        switch result {
        case .success(let message):
            footerStatusLabel.stringValue = message
            reloadInventory(preserveSelection: true)
        case .failure(let message):
            footerStatusLabel.stringValue = message
        }
    }

    private func performAsyncAction(_ result: SkillInstallResult) async {
        await MainActor.run {
            self.handleInstallResult(result)
        }
    }

    private func refreshCatalog(showStatus: Bool) async {
        let snapshot = await catalogService.refreshCatalog()
        await MainActor.run {
            self.registry.setCatalogSnapshot(snapshot)
            self.updateCatalogStatus()
            self.reloadInventory(preserveSelection: true)
            if showStatus {
                self.footerStatusLabel.stringValue = snapshot.source == .remote
                    ? L10n.text(zhHans: "技能目录已刷新。", en: "Skill catalog refreshed.")
                    : (snapshot.errorMessage ?? L10n.text(zhHans: "技能目录已刷新。", en: "Skill catalog refreshed."))
            }
        }
    }

    @objc private func handleSettingsChanged() {
        reloadInventory(preserveSelection: true)
    }

    @objc private func handleSkillPlatformSnapshotChanged() {
        reloadInventory(preserveSelection: true)
        updateCatalogStatus()
    }
}

private final class SkillCenterBackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        DesignTokens.Color.surfacePanel.withAlphaComponent(0.98).setFill()
        bounds.fill()
    }
}

private final class SkillCenterFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SkillCenterDetailOverlaySurfaceView: NSView {
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

private final class SkillCenterButton: NSButton {
    enum Role: Equatable {
        case primary
        case secondary
        case destructive
        case filter(isSelected: Bool)
    }

    private var role: Role
    private var isHovering = false
    private var trackingAreaRef: NSTrackingArea?

    init(title: String, role: Role) {
        self.role = role
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        focusRingType = .none
        font = DesignTokens.SkillCenter.Button.font
        wantsLayer = true
        setButtonType(.momentaryPushIn)
        applyRole()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        applyRole(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        applyRole(animated: true)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += DesignTokens.SkillCenter.Button.horizontalPadding
        size.height = DesignTokens.SkillCenter.Button.height
        return size
    }

    func updateRole(_ role: Role) {
        self.role = role
        applyRole(animated: false)
    }

    private func applyRole(animated: Bool = false) {
        layer?.cornerRadius = DesignTokens.SkillCenter.Button.cornerRadius
        layer?.borderWidth = DesignTokens.SkillCenter.Button.borderWidth

        let backgroundColor: NSColor
        let borderColor: NSColor
        let tintColor: NSColor
        switch role {
        case .primary:
            backgroundColor = isHovering ? DesignTokens.SkillCenter.Button.primaryBackgroundHover : DesignTokens.SkillCenter.Button.primaryBackground
            borderColor = isHovering ? DesignTokens.SkillCenter.Button.primaryBorderHover : DesignTokens.SkillCenter.Button.primaryBorder
            tintColor = DesignTokens.SkillCenter.Button.primaryText
        case .secondary:
            backgroundColor = isHovering ? DesignTokens.SkillCenter.Button.secondaryBackgroundHover : DesignTokens.SkillCenter.Button.secondaryBackground
            borderColor = isHovering ? DesignTokens.SkillCenter.Button.secondaryBorderHover : DesignTokens.SkillCenter.Button.secondaryBorder
            tintColor = isHovering ? DesignTokens.SkillCenter.Button.secondaryTextHover : DesignTokens.SkillCenter.Button.secondaryText
        case .destructive:
            backgroundColor = isHovering
                ? DesignTokens.SkillCenter.Button.destructiveBackgroundHover
                : DesignTokens.SkillCenter.Button.destructiveBackground
            borderColor = isHovering
                ? DesignTokens.SkillCenter.Button.destructiveBorderHover
                : DesignTokens.SkillCenter.Button.destructiveBorder
            tintColor = DesignTokens.SkillCenter.Button.destructiveText
        case .filter(let isSelected):
            backgroundColor = isSelected || isHovering ? DesignTokens.SkillCenter.Button.filterBackgroundActive : DesignTokens.SkillCenter.Button.filterBackground
            borderColor = isHovering ? DesignTokens.SkillCenter.Button.filterBorderHover : DesignTokens.SkillCenter.Button.filterBorder
            tintColor = (isSelected || isHovering) ? DesignTokens.SkillCenter.Button.filterTextActive : DesignTokens.SkillCenter.Button.filterText
        }

        let updates = {
            self.layer?.backgroundColor = backgroundColor.cgColor
            self.layer?.borderColor = borderColor.cgColor
            self.contentTintColor = tintColor
        }

        guard animated else {
            updates()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.Motion.fast
            updates()
        }
    }
}

private final class SkillCenterIconButton: NSButton {
    private var isHovering = false
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.SkillCenter.IconButton.cornerRadius
        layer?.borderWidth = DesignTokens.SkillCenter.IconButton.borderWidth
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.text(zhHans: "关闭", en: "Close"))
        contentTintColor = DesignTokens.SkillCenter.IconButton.text
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance(animated: true)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateAppearance(animated: Bool = false) {
        let backgroundColor = isHovering ? DesignTokens.SkillCenter.IconButton.backgroundHover : DesignTokens.SkillCenter.IconButton.background
        let borderColor = isHovering ? DesignTokens.SkillCenter.IconButton.borderHover : DesignTokens.SkillCenter.IconButton.border
        let tintColor = isHovering ? DesignTokens.SkillCenter.IconButton.textHover : DesignTokens.SkillCenter.IconButton.text
        let updates = {
            self.layer?.backgroundColor = backgroundColor.cgColor
            self.layer?.borderColor = borderColor.cgColor
            self.contentTintColor = tintColor
        }

        guard animated else {
            updates()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.Motion.fast
            updates()
        }
    }
}

private final class SkillCenterBadgeLabel: NSView {
    enum Tone {
        case accent
        case neutral
    }

    private let label = NSTextField(labelWithString: "")

    init(tone: Tone, text: String) {
        let style: DesignTokens.SkillCenter.BadgeStyle = switch tone {
        case .accent:
            DesignTokens.SkillCenter.Badge.accent
        case .neutral:
            DesignTokens.SkillCenter.Badge.neutral
        }
        super.init(frame: .zero)
        configure(style: style)
        label.stringValue = text
    }

    init(style: DesignTokens.SkillCenter.BadgeStyle, text: String) {
        super.init(frame: .zero)
        configure(style: style)
        label.stringValue = text
    }

    private func configure(style: DesignTokens.SkillCenter.BadgeStyle) {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.SkillCenter.Badge.cornerRadius
        layer?.borderWidth = DesignTokens.SkillCenter.Badge.borderWidth
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = DesignTokens.SkillCenter.Badge.font
        layer?.backgroundColor = style.fill.cgColor
        layer?.borderColor = style.border.cgColor
        label.textColor = style.text

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

private final class SkillCenterEmptyStateView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var minHeightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.SkillCenter.EmptyState.cornerRadius
        layer?.backgroundColor = DesignTokens.SkillCenter.EmptyState.surface.cgColor
        layer?.borderWidth = DesignTokens.SkillCenter.EmptyState.borderWidth
        layer?.borderColor = DesignTokens.SkillCenter.EmptyState.border.cgColor

        titleLabel.font = DesignTokens.SkillCenter.EmptyState.titleFont
        titleLabel.textColor = DesignTokens.Color.textPrimary
        messageLabel.font = DesignTokens.SkillCenter.EmptyState.messageFont
        messageLabel.textColor = DesignTokens.Color.textSecondary
        messageLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [titleLabel, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.SkillCenter.EmptyState.stackSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let minHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: DesignTokens.SkillCenter.EmptyState.minHeight)
        self.minHeightConstraint = minHeightConstraint

        NSLayoutConstraint.activate([
            minHeightConstraint,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.SkillCenter.EmptyState.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.SkillCenter.EmptyState.inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.SkillCenter.EmptyState.inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.SkillCenter.EmptyState.inset),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, message: String) {
        titleLabel.stringValue = title
        messageLabel.stringValue = message
    }
}

private final class SkillCenterSectionHeaderView: NSView {
    init(title: String, subtitle: String?, count: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DesignTokens.SkillCenter.SectionHeader.titleFont
        titleLabel.textColor = DesignTokens.Color.textSecondary

        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = DesignTokens.SkillCenter.SectionHeader.countFont
        countLabel.textColor = DesignTokens.Color.textTertiary

        let row = NSStackView(views: [titleLabel, countLabel])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = DesignTokens.SkillCenter.SectionHeader.rowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class SkillCenterIconPlateView: NSView {
    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.SkillCenter.Tile.iconPlateCornerRadius
        layer?.backgroundColor = DesignTokens.SkillCenter.Tile.iconPlate.cgColor
        addSubview(iconView)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(symbolName: String, accentColor: NSColor) {
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        iconView.contentTintColor = accentColor
    }
}

private final class SkillCenterDetailHeaderView: NSView {
    private let iconView = SkillCenterIconPlateView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let badgeRows = NSStackView()
    private let metaLabel = NSTextField(labelWithString: "")
    private let closeButtonSpacer = NSView()
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
                    closeButton.widthAnchor.constraint(equalToConstant: DesignTokens.SkillCenter.IconButton.size.width),
                    closeButton.heightAnchor.constraint(equalToConstant: DesignTokens.SkillCenter.IconButton.size.height),
                    closeButtonSpacer.leadingAnchor.constraint(
                        equalTo: closeButton.leadingAnchor,
                        constant: -DesignTokens.SkillCenter.Detail.headerLeadingSpacing
                    ),
                    closeButtonSpacer.trailingAnchor.constraint(equalTo: closeButton.trailingAnchor),
                ])
                closeButtonConstraintSet = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = DesignTokens.SkillCenter.Detail.titleFont
        titleLabel.textColor = DesignTokens.SkillCenter.Detail.titleText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        summaryLabel.font = DesignTokens.SkillCenter.Detail.summaryFont
        summaryLabel.textColor = DesignTokens.SkillCenter.Detail.summaryText
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        badgeRows.orientation = .horizontal
        badgeRows.alignment = .centerY
        badgeRows.spacing = DesignTokens.SkillCenter.Detail.badgeSpacing
        badgeRows.translatesAutoresizingMaskIntoConstraints = false
        badgeRows.setContentCompressionResistancePriority(.required, for: .vertical)

        metaLabel.font = DesignTokens.SkillCenter.Detail.metaFont
        metaLabel.textColor = DesignTokens.SkillCenter.Detail.metaText
        metaLabel.maximumNumberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        closeButtonSpacer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(summaryLabel)
        addSubview(badgeRows)
        addSubview(metaLabel)
        addSubview(closeButtonSpacer)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: DesignTokens.SkillCenter.Detail.headerMinHeight),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: DesignTokens.SkillCenter.Detail.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: DesignTokens.SkillCenter.Detail.iconSize),

            closeButtonSpacer.topAnchor.constraint(equalTo: topAnchor),
            closeButtonSpacer.widthAnchor.constraint(equalToConstant: DesignTokens.SkillCenter.IconButton.spacerSize.width),
            closeButtonSpacer.heightAnchor.constraint(equalToConstant: DesignTokens.SkillCenter.IconButton.spacerSize.height),
            closeButtonSpacer.trailingAnchor.constraint(equalTo: trailingAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: DesignTokens.SkillCenter.Detail.headerLeadingSpacing),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.SkillCenter.Detail.titleTopOffset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButtonSpacer.leadingAnchor, constant: -DesignTokens.SkillCenter.Detail.trailingAccessorySpacing),

            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.SkillCenter.Detail.summarySpacing),
            summaryLabel.trailingAnchor.constraint(equalTo: closeButtonSpacer.leadingAnchor, constant: -DesignTokens.SkillCenter.Detail.trailingAccessorySpacing),

            badgeRows.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            badgeRows.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: DesignTokens.SkillCenter.Detail.badgeTopSpacing),
            badgeRows.trailingAnchor.constraint(lessThanOrEqualTo: closeButtonSpacer.leadingAnchor, constant: -DesignTokens.SkillCenter.Detail.trailingAccessorySpacing),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: badgeRows.bottomAnchor, constant: DesignTokens.SkillCenter.Detail.metaSpacing),
            metaLabel.trailingAnchor.constraint(equalTo: closeButtonSpacer.leadingAnchor, constant: -DesignTokens.SkillCenter.Detail.trailingAccessorySpacing),
            metaLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(symbolName: String, accentColor: NSColor, title: String, summary: String, badges: [(SkillCenterBadgeLabel.Tone, String)], meta: String) {
        iconView.configure(symbolName: symbolName, accentColor: accentColor)
        titleLabel.stringValue = title
        summaryLabel.stringValue = summary
        metaLabel.stringValue = meta

        badgeRows.arrangedSubviews.forEach { view in
            badgeRows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for badge in badges.map({ SkillCenterBadgeLabel(tone: $0.0, text: $0.1) }) {
            badgeRows.addArrangedSubview(badge)
        }
    }
}

private final class SkillCenterDetailSectionView: NSView {
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.SkillCenter.Detail.Section.cornerRadius
        layer?.backgroundColor = DesignTokens.SkillCenter.Detail.sectionSurface.cgColor
        layer?.borderWidth = DesignTokens.SkillCenter.Detail.Section.borderWidth
        layer?.borderColor = DesignTokens.SkillCenter.Detail.sectionBorder.cgColor

        titleLabel.stringValue = title
        titleLabel.font = DesignTokens.SkillCenter.Detail.Section.titleFont
        titleLabel.textColor = DesignTokens.SkillCenter.Detail.metaText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        bodyLabel.font = DesignTokens.SkillCenter.Detail.Section.bodyFont
        bodyLabel.textColor = DesignTokens.SkillCenter.Detail.summaryText
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.SkillCenter.Detail.Section.inset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.SkillCenter.Detail.Section.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.SkillCenter.Detail.Section.inset),

            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.SkillCenter.Detail.Section.inset),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.SkillCenter.Detail.Section.inset),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.SkillCenter.Detail.Section.titleBodySpacing),
            bodyLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.SkillCenter.Detail.Section.inset),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(body: String) {
        bodyLabel.stringValue = body
    }
}

private final class SkillCenterTileView: NSView {
    private enum Tokens {
        static let cornerRadius = DesignTokens.SkillCenter.Tile.cornerRadius
        static let iconPlateSize = DesignTokens.SkillCenter.Tile.iconPlateSize
        static let iconPointSize = DesignTokens.SkillCenter.Tile.iconPointSize
        static let horizontalInset = DesignTokens.SkillCenter.Tile.horizontalInset
        static let verticalInset = DesignTokens.SkillCenter.Tile.verticalInset
        static let rowSpacing = DesignTokens.SkillCenter.Tile.rowSpacing
        static let textSpacing = DesignTokens.SkillCenter.Tile.textSpacing
        static let titleBadgeSpacing = DesignTokens.SkillCenter.Tile.titleBadgeSpacing
    }

    let item: SkillInventoryItem
    var onSelect: ((String) -> Void)?

    private let iconPlate = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let titleBadgeRow = NSStackView()
    private let isSelected: Bool
    private var isHovering = false
    private var trackingAreaRef: NSTrackingArea?

    init(item: SkillInventoryItem, isSelected: Bool) {
        self.item = item
        self.isSelected = isSelected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Tokens.cornerRadius
        setup()
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        iconPlate.translatesAutoresizingMaskIntoConstraints = false
        iconPlate.wantsLayer = true
        iconPlate.layer?.cornerRadius = DesignTokens.SkillCenter.Tile.iconPlateCornerRadius
        iconPlate.layer?.backgroundColor = DesignTokens.SkillCenter.Tile.iconPlate.cgColor

        iconView.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Tokens.iconPointSize, weight: .regular)
        iconView.contentTintColor = DesignTokens.Color.iconPrimary
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconPlate.addSubview(iconView)

        titleLabel.stringValue = item.displayName
        titleLabel.font = DesignTokens.SkillCenter.Tile.titleFont
        titleLabel.textColor = DesignTokens.SkillCenter.Tile.titleText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        summaryLabel.stringValue = item.summary
        summaryLabel.font = DesignTokens.SkillCenter.Tile.summaryFont
        summaryLabel.textColor = DesignTokens.SkillCenter.Tile.summaryText
        summaryLabel.maximumNumberOfLines = 2

        titleBadgeRow.orientation = .horizontal
        titleBadgeRow.alignment = .centerY
        titleBadgeRow.spacing = Tokens.titleBadgeSpacing
        titleBadgeRow.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleBadgeRow.setContentHuggingPriority(.required, for: .horizontal)

        let typeBadge = SkillCenterBadgeLabel(style: typeBadgeStyle(), text: primaryTypeLabel())
        let stateBadge = SkillCenterBadgeLabel(style: stateBadgeStyle(), text: item.isInstalled
            ? L10n.text(zhHans: "已安装", en: "Installed")
            : L10n.text(zhHans: "未安装", en: "Not Installed"))
        titleBadgeRow.addArrangedSubview(typeBadge)
        titleBadgeRow.addArrangedSubview(stateBadge)

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = Tokens.titleBadgeSpacing
        titleRow.detachesHiddenViews = true
        titleRow.addArrangedSubview(titleLabel)
        titleRow.addArrangedSubview(titleBadgeRow)
        titleRow.setHuggingPriority(.required, for: .vertical)
        titleRow.setContentCompressionResistancePriority(.required, for: .vertical)

        let textStack = NSStackView(views: [titleRow, summaryLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Tokens.textSpacing
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [iconPlate, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Tokens.rowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Tokens.horizontalInset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Tokens.horizontalInset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Tokens.verticalInset),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Tokens.verticalInset),

            iconPlate.widthAnchor.constraint(equalToConstant: Tokens.iconPlateSize),
            iconPlate.heightAnchor.constraint(equalToConstant: Tokens.iconPlateSize),
            iconView.centerXAnchor.constraint(equalTo: iconPlate.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconPlate.centerYAnchor),
        ])

        let tap = NSClickGestureRecognizer(target: self, action: #selector(handleSelect))
        addGestureRecognizer(tap)
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
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance(animated: true)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateAppearance(animated: Bool = false) {
        let backgroundColor: NSColor
        let borderColor: NSColor
        let iconPlateBackground: NSColor

        if isSelected {
            backgroundColor = isHovering ? DesignTokens.SkillCenter.Tile.backgroundSelectedHover : DesignTokens.SkillCenter.Tile.backgroundSelected
            borderColor = DesignTokens.SkillCenter.Tile.borderHover
            iconPlateBackground = isHovering ? DesignTokens.SkillCenter.Tile.iconPlateSelectedHover : DesignTokens.SkillCenter.Tile.iconPlateSelected
        } else if isHovering {
            backgroundColor = DesignTokens.SkillCenter.Tile.backgroundHover
            borderColor = DesignTokens.SkillCenter.Tile.borderHover
            iconPlateBackground = DesignTokens.SkillCenter.Tile.iconPlateHover
        } else {
            backgroundColor = DesignTokens.SkillCenter.Tile.background
            borderColor = DesignTokens.SkillCenter.Tile.border
            iconPlateBackground = DesignTokens.SkillCenter.Tile.iconPlate
        }

        let updates = {
            self.layer?.backgroundColor = backgroundColor.cgColor
            self.layer?.borderWidth = DesignTokens.SkillCenter.Tile.borderWidth
            self.layer?.borderColor = borderColor.cgColor
            self.iconPlate.layer?.backgroundColor = iconPlateBackground.cgColor
            self.iconPlate.layer?.borderWidth = 0
            self.iconPlate.layer?.borderColor = nil
        }

        guard animated else {
            updates()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.Motion.fast
            self.animator().alphaValue = 1
            updates()
        }
    }

    @objc private func handleSelect() {
        onSelect?(item.skillID)
    }

    private func primaryTypeLabel() -> String {
        switch item.supportedContexts.first {
        case .selectedText?, .clipboardText?:
            return L10n.text(zhHans: "文本", en: "Text")
        case .fileSelection?:
            return L10n.text(zhHans: "文件", en: "Files")
        case .screenshotRegion?, .imageCapture?:
            return L10n.text(zhHans: "截图", en: "Screenshot")
        case .url?:
            return "URL"
        case .inputBoxContext?:
            return L10n.text(zhHans: "输入框", en: "Input")
        case .mixedContext?:
            return L10n.text(zhHans: "混合", en: "Mixed")
        case nil:
            return L10n.text(zhHans: "技能", en: "Skill")
        }
    }

    private func typeBadgeStyle() -> DesignTokens.SkillCenter.BadgeStyle {
        switch item.supportedContexts.first {
        case .selectedText?, .clipboardText?:
            return DesignTokens.SkillCenter.Badge.text
        case .fileSelection?:
            return DesignTokens.SkillCenter.Badge.file
        case .screenshotRegion?, .imageCapture?:
            return DesignTokens.SkillCenter.Badge.screenshot
        default:
            return DesignTokens.SkillCenter.Badge.neutral
        }
    }

    private func stateBadgeStyle() -> DesignTokens.SkillCenter.BadgeStyle {
        item.isInstalled ? DesignTokens.SkillCenter.Badge.installed : DesignTokens.SkillCenter.Badge.uninstalled
    }
}
