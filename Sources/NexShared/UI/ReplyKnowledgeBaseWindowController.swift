import AppKit
import Foundation
import UniformTypeIdentifiers

final class ReplyKnowledgeBaseWindowController: NSWindowController, NSTextFieldDelegate, NSTextViewDelegate {
    private enum SourceTab: Int {
        case all
        case file

        func includes(_ entry: ReplyKnowledgeBaseEntry) -> Bool {
            switch self {
            case .all:
                return true
            case .file:
                return entry.sourceKind != .notion
            }
        }
    }

    var onClose: (() -> Void)?

    private let store = ReplyKnowledgeBaseStore.shared
    private let descriptionLabel = NSTextField(wrappingLabelWithString: L10n.text(zhHans: "把常用口径、FAQ、产品资料、服务说明等文件导入进来。系统会先解析成可检索片段，之后声明使用知识库的技能会优先参考命中的内容再生成结果。", en: "Import FAQs, product docs, service notes, and other reference files here. NexHub turns them into searchable chunks so knowledge-enabled skills can reference relevant matches before generating results."))
    private let formatLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton(title: L10n.text(zhHans: "添加文件", en: "Add Files"), target: nil, action: nil)
    private let closeButton = NSButton(title: L10n.text(zhHans: "关闭", en: "Close"), target: nil, action: nil)
    private lazy var sourceTabs = NSSegmentedControl(
        labels: [L10n.text(zhHans: "全部", en: "All"), L10n.text(zhHans: "文件", en: "Files")],
        trackingMode: .selectOne,
        target: self,
        action: #selector(handleSourceTabChanged)
    )
    private let scrollView = NSScrollView()
    private let contentViewHost = NSView()
    private let stackView = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: L10n.text(zhHans: "还没有知识库文件。导入后，回复会先检索命中的资料片段。", en: "No knowledge files yet. After import, reply will search matching snippets first."))

    private var currentEntries: [ReplyKnowledgeBaseEntry] = []
    private var selectedSourceTab: SourceTab = .all

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text(zhHans: "知识库", en: "Knowledge Base")
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        NotificationCenter.default.addObserver(self, selector: #selector(handleKnowledgeBaseChanged), name: .knowledgeBaseDidChange, object: nil)
        configureWindow()
        reloadEntries()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func showAsSheet(for parentWindow: NSWindow) {
        guard let window else { return }
        parentWindow.beginSheet(window)
    }

    private func configureWindow() {
        guard let window, let root = window.contentView else { return }

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = DesignTokens.KnowledgeBaseWindow.bodyFont
        descriptionLabel.textColor = DesignTokens.KnowledgeBaseWindow.bodyColor
        descriptionLabel.maximumNumberOfLines = 0

        formatLabel.translatesAutoresizingMaskIntoConstraints = false
        formatLabel.font = DesignTokens.KnowledgeBaseWindow.formatFont
        formatLabel.textColor = DesignTokens.KnowledgeBaseWindow.formatColor
        formatLabel.stringValue = store.supportedFormatsDescription

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = DesignTokens.KnowledgeBaseWindow.statusFont
        statusLabel.maximumNumberOfLines = 0
        statusLabel.textColor = DesignTokens.KnowledgeBaseWindow.statusColor

        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.target = self
        addButton.action = #selector(handleAddFiles)
        addButton.bezelStyle = .rounded

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        closeButton.bezelStyle = .rounded

        sourceTabs.translatesAutoresizingMaskIntoConstraints = false
        sourceTabs.selectedSegment = SourceTab.all.rawValue
        sourceTabs.segmentStyle = .rounded

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        contentViewHost.translatesAutoresizingMaskIntoConstraints = true
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = DesignTokens.KnowledgeBaseWindow.verticalSpacing
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentViewHost.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentViewHost.leadingAnchor, constant: DesignTokens.KnowledgeBaseWindow.listInset),
            stackView.trailingAnchor.constraint(equalTo: contentViewHost.trailingAnchor, constant: -DesignTokens.KnowledgeBaseWindow.listInset),
            stackView.topAnchor.constraint(equalTo: contentViewHost.topAnchor, constant: DesignTokens.KnowledgeBaseWindow.listInset),
            stackView.bottomAnchor.constraint(equalTo: contentViewHost.bottomAnchor, constant: -DesignTokens.KnowledgeBaseWindow.listInset)
        ])
        scrollView.documentView = contentViewHost

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = DesignTokens.KnowledgeBaseWindow.emptyFont
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.textColor = DesignTokens.KnowledgeBaseWindow.bodyColor
        emptyLabel.alignment = .center

        root.addSubview(descriptionLabel)
        root.addSubview(formatLabel)
        root.addSubview(addButton)
        root.addSubview(sourceTabs)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(statusLabel)
        root.addSubview(closeButton)

        NSLayoutConstraint.activate([
            descriptionLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.KnowledgeBaseWindow.pageInset),
            descriptionLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DesignTokens.KnowledgeBaseWindow.pageInset),
            descriptionLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: DesignTokens.KnowledgeBaseWindow.pageInset),

            formatLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.KnowledgeBaseWindow.pageInset),
            formatLabel.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: DesignTokens.KnowledgeBaseWindow.verticalSpacing),

            addButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DesignTokens.KnowledgeBaseWindow.pageInset),
            addButton.centerYAnchor.constraint(equalTo: sourceTabs.centerYAnchor),

            sourceTabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.KnowledgeBaseWindow.pageInset),
            sourceTabs.topAnchor.constraint(equalTo: formatLabel.bottomAnchor, constant: DesignTokens.KnowledgeBaseWindow.sectionSpacing),
            sourceTabs.heightAnchor.constraint(equalToConstant: DesignTokens.KnowledgeBaseWindow.tabHeight),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.KnowledgeBaseWindow.pageInset),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DesignTokens.KnowledgeBaseWindow.pageInset),
            scrollView.topAnchor.constraint(equalTo: sourceTabs.bottomAnchor, constant: DesignTokens.KnowledgeBaseWindow.sectionSpacing),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -DesignTokens.KnowledgeBaseWindow.sectionSpacing),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -DesignTokens.KnowledgeBaseWindow.emptyWidthInset),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.KnowledgeBaseWindow.pageInset),
            statusLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -DesignTokens.KnowledgeBaseWindow.sectionSpacing),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -DesignTokens.KnowledgeBaseWindow.statusBottomInset),

            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DesignTokens.KnowledgeBaseWindow.pageInset),
            closeButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -DesignTokens.KnowledgeBaseWindow.closeBottomInset)
        ])

        updateSourceTabs()
    }

    private func reloadEntries(status: String? = nil) {
        currentEntries = store.entries()
        if let status {
            statusLabel.stringValue = status
        }
        updateSourceTabs()
        renderRows()
    }

    private func renderRows() {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let visibleEntries = currentEntries.filter { selectedSourceTab.includes($0) }
        emptyLabel.stringValue = emptyStateText(for: selectedSourceTab)
        emptyLabel.isHidden = !visibleEntries.isEmpty
        scrollView.isHidden = visibleEntries.isEmpty

        for entry in visibleEntries {
            let row = ReplyKnowledgeBaseRowView(entry: entry)
            row.onOpen = { [weak self] entry in
                self?.openSource(for: entry)
            }
            row.onToggleEnabled = { [weak self] entryID, isEnabled in
                self?.handleToggleEntry(id: entryID, isEnabled: isEnabled)
            }
            row.onDelete = { [weak self] entryID in
                self?.handleDeleteEntry(id: entryID)
            }
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }

        scrollView.layoutSubtreeIfNeeded()
        contentViewHost.layoutSubtreeIfNeeded()
        let width = max(scrollView.contentSize.width, 640)
        let height = max(stackView.fittingSize.height + (DesignTokens.KnowledgeBaseWindow.listInset * 2), scrollView.contentSize.height)
        contentViewHost.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    @objc private func handleAddFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ReplyKnowledgeBaseStore.supportedFilenameExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = L10n.text(zhHans: "选择要导入到回复知识库的文件", en: "Choose files to import into the reply knowledge base")
        panel.prompt = L10n.text(zhHans: "导入", en: "Import")
        if panel.runModal() != .OK {
            return
        }

        let urls = panel.urls
        guard !urls.isEmpty else { return }

        addButton.isEnabled = false
        statusLabel.stringValue = L10n.format(zhHans: "正在解析 %d 个文件...", en: "Parsing %d files...", urls.count)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.store.importFiles(urls: urls)
            self.addButton.isEnabled = true

            let successCount = result.imported.count
            let failureCount = result.failures.count
            let failureText = result.failures.prefix(2).map { "\($0.fileName)：\($0.reason)" }.joined(separator: "；")
            let status: String
            if successCount > 0 && failureCount > 0 {
                status = L10n.format(zhHans: "已导入 %d 个文件，%d 个失败。%@", en: "Imported %d files, with %d failures. %@", successCount, failureCount, failureText)
            } else if successCount > 0 {
                status = L10n.format(zhHans: "已导入 %d 个文件。", en: "Imported %d files.", successCount)
            } else if failureCount > 0 {
                status = failureText.isEmpty
                    ? L10n.text(zhHans: "导入失败。", en: "Import failed.")
                    : L10n.format(zhHans: "没有导入成功。%@", en: "Nothing was imported successfully. %@", failureText)
            } else {
                status = L10n.text(zhHans: "没有导入新文件。", en: "No new files were imported.")
            }
            self.reloadEntries(status: status)
        }
    }

    @objc private func handleSourceTabChanged() {
        selectedSourceTab = SourceTab(rawValue: sourceTabs.selectedSegment) ?? .all
        renderRows()
    }

    @objc private func handleKnowledgeBaseChanged() {
        if Thread.isMainThread {
            reloadEntries()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.reloadEntries()
            }
        }
    }

    private func handleDeleteEntry(id: String) {
        let alert = NSAlert()
        alert.messageText = L10n.text(zhHans: "删除这份知识库文件？", en: "Delete this knowledge file?")
        alert.informativeText = L10n.text(zhHans: "删除后，这份资料将不会再参与“回复”技能检索。", en: "After deletion, this file will no longer be used by the Reply skill.")
        alert.addButton(withTitle: L10n.text(zhHans: "删除", en: "Delete"))
        alert.addButton(withTitle: L10n.text(zhHans: "取消", en: "Cancel"))
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        if store.deleteEntry(id: id) {
            reloadEntries(status: L10n.text(zhHans: "已删除知识库文件。", en: "Knowledge file deleted."))
        } else {
            statusLabel.stringValue = L10n.text(zhHans: "删除失败，请稍后重试。", en: "Delete failed. Please try again.")
        }
    }

    @objc private func handleClose() {
        closeWindow()
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

    private func updateSourceTabs() {
        let allCount = currentEntries.count
        let fileCount = currentEntries.filter { $0.sourceKind != .notion }.count
        sourceTabs.setLabel(L10n.format(zhHans: "全部 %d", en: "All %d", allCount), forSegment: SourceTab.all.rawValue)
        sourceTabs.setLabel(L10n.format(zhHans: "文件 %d", en: "Files %d", fileCount), forSegment: SourceTab.file.rawValue)
    }

    private func emptyStateText(for tab: SourceTab) -> String {
        switch tab {
        case .all:
            return L10n.text(zhHans: "还没有知识库内容。导入文件后，声明使用知识库的技能会先检索命中的资料片段。", en: "No knowledge content yet. After importing files, knowledge-enabled skills will search matching snippets first.")
        case .file:
            return L10n.text(zhHans: "还没有文件知识库。你可以把常用 PDF、文档或说明文件放进来。", en: "No file-based knowledge yet. You can add PDFs, docs, or reference files here.")
        }
    }

    private func openSource(for entry: ReplyKnowledgeBaseEntry) {
        Task { @MainActor in
            KnowledgeBaseSourceActionResolver.performPrimaryAction(
                for: entry,
                languageCode: AppSettings.shared.appLanguage.languageCode
            )
        }
    }

    private func handleToggleEntry(id: String, isEnabled: Bool) {
        if store.setEntryEnabled(id: id, isEnabled: isEnabled) {
            reloadEntries(status: isEnabled
                ? L10n.text(zhHans: "已启用这份知识。", en: "This knowledge source is enabled.")
                : L10n.text(zhHans: "已停用这份知识，不会再参与检索。", en: "This knowledge source is disabled and will no longer be searched."))
        } else {
            statusLabel.stringValue = L10n.text(zhHans: "更新知识状态失败，请稍后重试。", en: "Failed to update the knowledge state. Please try again.")
        }
    }
}

private final class ReplyKnowledgeBaseRowView: NSView {
    var onOpen: ((ReplyKnowledgeBaseEntry) -> Void)?
    var onToggleEnabled: ((String, Bool) -> Void)?
    var onDelete: ((String) -> Void)?

    private let entry: ReplyKnowledgeBaseEntry

    init(entry: ReplyKnowledgeBaseEntry) {
        self.entry = entry
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.KnowledgeBaseWindow.Row.cornerRadius
        layer?.borderWidth = DesignTokens.KnowledgeBaseWindow.Row.borderWidth
        layer?.borderColor = DesignTokens.KnowledgeBaseWindow.Row.border.cgColor
        layer?.backgroundColor = backgroundColor(for: entry).cgColor

        let titleLabel = NSTextField(labelWithString: displayTitle(for: entry))
        titleLabel.font = DesignTokens.KnowledgeBaseWindow.Row.titleFont
        titleLabel.textColor = DesignTokens.KnowledgeBaseWindow.Row.titleColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let summaryLabel = NSTextField(wrappingLabelWithString: entry.summary)
        summaryLabel.font = DesignTokens.KnowledgeBaseWindow.Row.summaryFont
        summaryLabel.textColor = DesignTokens.KnowledgeBaseWindow.Row.summaryColor
        summaryLabel.maximumNumberOfLines = 3
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let metaLabel = NSTextField(labelWithString: metaText(for: entry))
        metaLabel.font = DesignTokens.KnowledgeBaseWindow.Row.metaFont
        metaLabel.textColor = DesignTokens.KnowledgeBaseWindow.Row.metaColor
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        let toggleButton = NSButton(title: (entry.isEnabled ?? true)
            ? L10n.text(zhHans: "停用", en: "Disable")
            : L10n.text(zhHans: "启用", en: "Enable"), target: self, action: #selector(handleToggleEnabled))
        toggleButton.bezelStyle = .rounded
        toggleButton.translatesAutoresizingMaskIntoConstraints = false

        let sourceActionLabel = KnowledgeBaseSourceActionResolver.primaryAction(
            for: entry,
            languageCode: AppSettings.shared.appLanguage.languageCode
        )?.label ?? L10n.text(zhHans: "打开来源", en: "Open Source")
        let openButton = NSButton(title: sourceActionLabel, target: self, action: #selector(handleOpen))
        openButton.bezelStyle = .rounded
        openButton.translatesAutoresizingMaskIntoConstraints = false

        let deleteButton = NSButton(title: L10n.text(zhHans: "删除", en: "Delete"), target: self, action: #selector(handleDelete))
        deleteButton.bezelStyle = .rounded
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(summaryLabel)
        addSubview(metaLabel)
        addSubview(toggleButton)
        addSubview(openButton)
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.KnowledgeBaseWindow.Row.horizontalInset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.KnowledgeBaseWindow.Row.topInset),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleButton.leadingAnchor, constant: -DesignTokens.KnowledgeBaseWindow.Row.titleActionSpacing),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.KnowledgeBaseWindow.Row.horizontalInset),
            deleteButton.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.KnowledgeBaseWindow.Row.actionTopInset),

            toggleButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -DesignTokens.KnowledgeBaseWindow.Row.actionSpacing),
            toggleButton.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.KnowledgeBaseWindow.Row.actionTopInset),

            openButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -DesignTokens.KnowledgeBaseWindow.Row.actionSpacing),
            openButton.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.KnowledgeBaseWindow.Row.actionTopInset),

            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.KnowledgeBaseWindow.Row.horizontalInset),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.KnowledgeBaseWindow.Row.horizontalInset),
            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: DesignTokens.KnowledgeBaseWindow.Row.titleSummarySpacing),

            metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.KnowledgeBaseWindow.Row.horizontalInset),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.KnowledgeBaseWindow.Row.horizontalInset),
            metaLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: DesignTokens.KnowledgeBaseWindow.Row.summaryMetaSpacing),
            metaLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.KnowledgeBaseWindow.Row.bottomInset)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleDelete() {
        onDelete?(entry.id)
    }

    @objc private func handleOpen() {
        onOpen?(entry)
    }

    @objc private func handleToggleEnabled() {
        onToggleEnabled?(entry.id, !(entry.isEnabled ?? true))
    }

    private func displayTitle(for entry: ReplyKnowledgeBaseEntry) -> String {
        if entry.sourceKind == .notion {
            return entry.title
        }
        return entry.originalFilename
    }

    private func metaText(for entry: ReplyKnowledgeBaseEntry) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: AppSettings.shared.appLanguage.localeIdentifier)
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        return [
            (entry.isEnabled ?? true) ? L10n.text(zhHans: "已启用", en: "Enabled") : L10n.text(zhHans: "已停用", en: "Disabled"),
            entry.syncLabel,
            entry.contentKind?.rawValue.uppercased(),
            entry.captureBehavior?.rawValue,
            entry.contentType,
            formatter.string(fromByteCount: entry.byteCount),
            L10n.format(zhHans: "%d 个片段", en: "%d chunks", entry.chunkCount),
            L10n.format(zhHans: "导入于 %@", en: "Imported %@", dateFormatter.string(from: entry.importedAt))
        ]
        .compactMap { $0 }
        .joined(separator: "  ·  ")
    }

    private func backgroundColor(for entry: ReplyKnowledgeBaseEntry) -> NSColor {
        if entry.isEnabled == false {
            return DesignTokens.KnowledgeBaseWindow.Row.disabledSurface
        }
        return DesignTokens.KnowledgeBaseWindow.Row.enabledSurface
    }
}
