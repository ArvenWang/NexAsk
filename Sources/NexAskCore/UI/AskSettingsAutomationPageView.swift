import AppKit
import NexShared

#if !NEXHUB_PRODUCT_NEXHUB
final class AskSettingsAutomationPageView: NSView, SettingsAutomationPageView, NSTextFieldDelegate {
    private let automationStore = AskAutomationStore.shared
    private let inboxStore = AskInboxStore.shared
    private let scheduler = AskAutomationScheduler.shared
    private let parser = AskAutomationDraftParser.shared
    private let notificationCenter = NotificationCenter.default

    private let scrollView = NSScrollView()
    private let hostView = SettingsFlippedView()
    private let contentStack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let metricStripView = SettingsStatisticsMetricStripView()
    private let jobsStack = NSStackView()
    private let detailTitleField = PasteFriendlyTextField(string: "")
    private let detailSpecField = PasteFriendlyTextField(string: "")
    private let detailScheduleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailTaskPromptLabel = NSTextField(wrappingLabelWithString: "")
    private let detailDomainsLabel = NSTextField(wrappingLabelWithString: "")
    private let detailRiskLabel = NSTextField(wrappingLabelWithString: "")
    private let detailDeliveryLabel = NSTextField(wrappingLabelWithString: "")
    private let detailHintLabel = NSTextField(wrappingLabelWithString: "")
    private let allowLightWritesCheckbox = NSButton(checkboxWithTitle: L10n.text(zhHans: "允许轻写操作", en: "Allow light writes"), target: nil, action: nil)
    private let responseProfilePopup = SettingsDropdownButton()
    private let saveButton = SettingsActionButton(title: L10n.text(zhHans: "保存", en: "Save"), target: nil, action: nil)
    private let runsStack = NSStackView()
    private let inboxStack = NSStackView()
    private var jobListCard: NSView?
    private var detailCard: NSView?
    private var runHistoryCard: NSView?
    private var inboxCard: NSView?

    private var selectedJobID: String?
    private var observers: [NSObjectProtocol] = []
    private var pendingStatusOverride: (message: String, color: NSColor)?
    var pageView: NSView { self }
    var onScrollStateChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = true
        buildUI()
        startObserving()
        reloadData()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observers.forEach(notificationCenter.removeObserver)
    }

    override func layout() {
        super.layout()
        refreshScrollLayout()
    }

    func reloadData() {
        let jobs = automationStore.listJobs()
        let recentRuns = automationStore.listRuns(limit: 24)
        let inboxItems = inboxStore.items(limit: 24)
        if selectedJobID == nil || jobs.contains(where: { $0.id == selectedJobID }) == false {
            selectedJobID = jobs.first?.id
        }

        metricStripView.update(items: summaryMetricItems(jobs: jobs, runs: recentRuns, inboxItems: inboxItems))
        renderJobs(jobs)
        renderDetail(job: selectedJobID.flatMap { id in jobs.first(where: { $0.id == id }) })
        renderRuns()
        renderInbox()

        let activeCount = jobs.filter(\.enabled).count
        let unreadCount = inboxItems.filter { !$0.isRead }.count
        let blockedCount = recentRuns.filter { $0.status == .blocked }.count
        applyDefaultStatus(
            jobs: jobs,
            activeCount: activeCount,
            unreadCount: unreadCount,
            blockedCount: blockedCount
        )
        refreshScrollLayout()
    }

    private func buildUI() {
        wantsLayer = true
        hostView.translatesAutoresizingMaskIntoConstraints = true
        hostView.frame = NSRect(x: 0, y: 0, width: 720, height: 10)

        let titleLabel = NSTextField(labelWithString: L10n.text(zhHans: "本地 Automation", en: "Local Automation"))
        titleLabel.font = DesignTokens.Typography.settingsPageTitle
        titleLabel.textColor = DesignTokens.Color.textPrimary

        let subtitleLabel = NSTextField(wrappingLabelWithString: L10n.text(
            zhHans: "这里管理 Ask 的本地定时任务。任务会按自然语言解析出的规则定时运行，并把结果回传到 Inbox 与系统通知。",
            en: "Manage Ask's local automations here. Jobs run on the parsed natural-language schedule and return results through the inbox and system notifications."
        ))
        subtitleLabel.font = DesignTokens.Typography.settingsPageSubtitle
        subtitleLabel.textColor = DesignTokens.Color.textSecondary
        subtitleLabel.maximumNumberOfLines = 0

        statusLabel.font = DesignTokens.Typography.settingsSectionBody
        statusLabel.textColor = DesignTokens.Settings.Status.neutral
        statusLabel.maximumNumberOfLines = 0
        metricStripView.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = DesignTokens.Settings.Page.stackSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setHuggingPriority(.required, for: .vertical)
        contentStack.setContentCompressionResistancePriority(.required, for: .vertical)

        let header = NSStackView(views: [titleLabel, subtitleLabel, statusLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, subtitleLabel, statusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
        }

        jobsStack.orientation = .vertical
        jobsStack.alignment = .width
        jobsStack.spacing = 10

        runsStack.orientation = .vertical
        runsStack.alignment = .width
        runsStack.spacing = 8

        inboxStack.orientation = .vertical
        inboxStack.alignment = .width
        inboxStack.spacing = 8

        detailTitleField.placeholderString = L10n.text(zhHans: "任务名", en: "Job title")
        detailSpecField.placeholderString = L10n.text(zhHans: "自然语言任务描述", en: "Natural-language job description")
        SettingsControlStyle.applyInputField(detailTitleField)
        SettingsControlStyle.applyInputField(detailSpecField)
        detailTitleField.alignment = .left
        detailSpecField.alignment = .left
        detailTitleField.delegate = self
        detailSpecField.delegate = self

        detailScheduleLabel.font = DesignTokens.Typography.settingsSectionBody
        detailScheduleLabel.textColor = DesignTokens.Color.textSecondary
        detailScheduleLabel.maximumNumberOfLines = 0
        detailScheduleLabel.alignment = .left

        [detailTaskPromptLabel, detailDomainsLabel, detailRiskLabel, detailDeliveryLabel, detailHintLabel].forEach {
            $0.font = DesignTokens.Typography.settingsSectionBody
            $0.textColor = DesignTokens.Color.textSecondary
            $0.maximumNumberOfLines = 0
            $0.alignment = .left
        }
        detailTaskPromptLabel.textColor = DesignTokens.Color.textPrimary
        detailHintLabel.textColor = DesignTokens.Color.textTertiary

        SettingsControlStyle.applyCheckbox(allowLightWritesCheckbox)
        allowLightWritesCheckbox.target = self
        allowLightWritesCheckbox.action = #selector(handleCheckboxChanged(_:))

        responseProfilePopup.removeAllItems()
        responseProfilePopup.addItems(withTitles: [
            L10n.text(zhHans: "简洁", en: "Concise"),
            L10n.text(zhHans: "平衡", en: "Balanced"),
            L10n.text(zhHans: "详细", en: "Detailed")
        ])
        SettingsControlStyle.applyPopupButton(responseProfilePopup)

        saveButton.target = self
        saveButton.action = #selector(handleSaveSelectedJob)
        SettingsControlStyle.applyActionButton(saveButton, style: .accentPrimary)

        let jobListCard = sectionCard(
            title: L10n.text(zhHans: "任务列表", en: "Job List"),
            content: jobsStack
        )
        let detailCard = sectionCard(
            title: L10n.text(zhHans: "任务详情", en: "Job Detail"),
            content: detailSectionContent()
        )
        let runHistoryCard = sectionCard(
            title: L10n.text(zhHans: "运行记录", en: "Run History"),
            content: runsStack
        )
        let inboxCard = sectionCard(
            title: L10n.text(zhHans: "收件箱摘要", en: "Inbox Summary"),
            content: inboxStack
        )
        self.jobListCard = jobListCard
        self.detailCard = detailCard
        self.runHistoryCard = runHistoryCard
        self.inboxCard = inboxCard

        [header, metricStripView, jobListCard, detailCard, runHistoryCard, inboxCard].forEach { section in
            contentStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        hostView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: hostView.leadingAnchor, constant: DesignTokens.Settings.Page.scrollContentInset),
            contentStack.trailingAnchor.constraint(equalTo: hostView.trailingAnchor, constant: -DesignTokens.Settings.Page.scrollContentInset),
            contentStack.topAnchor.constraint(equalTo: hostView.topAnchor, constant: DesignTokens.Settings.Page.scrollContentInset),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: hostView.bottomAnchor, constant: -DesignTokens.Settings.Page.scrollContentInset)
        ])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = hostView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        refreshScrollLayout()
    }

    private func startObserving() {
        observers.append(notificationCenter.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            self?.onScrollStateChanged?(true)
        })
        observers.append(notificationCenter.addObserver(forName: .askAutomationJobsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadData()
        })
        observers.append(notificationCenter.addObserver(forName: .askAutomationRunsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadData()
        })
        observers.append(notificationCenter.addObserver(forName: .askInboxDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadData()
        })
    }

    private func sectionCard(title: String, content: NSView) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyCardSurface(to: card)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DesignTokens.Typography.settingsSectionTitle
        titleLabel.textColor = DesignTokens.Color.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(titleLabel)
        card.addSubview(content)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),

            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }

    func refreshScrollLayout() {
        guard scrollView.superview != nil else { return }
        scrollView.superview?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()

        let visibleWidth = max(scrollView.contentView.bounds.width, scrollView.bounds.width)
        let targetWidth = max(visibleWidth, 560)
        hostView.frame = NSRect(x: 0, y: 0, width: targetWidth, height: max(hostView.frame.height, 10))
        hostView.layoutSubtreeIfNeeded()
        contentStack.layoutSubtreeIfNeeded()

        let verticalInset = DesignTokens.Settings.Page.scrollContentInset * 2
        let height = max(contentStack.fittingSize.height + verticalInset, scrollView.contentSize.height)
        hostView.frame = NSRect(x: 0, y: 0, width: targetWidth, height: max(height, 10))
        hostView.layoutSubtreeIfNeeded()
        onScrollStateChanged?(false)
    }

    func updateSharedScrollIndicator(_ indicator: SettingsScrollIndicatorView, showTemporarily: Bool) {
        indicator.update(
            contentHeight: hostView.frame.height,
            visibleHeight: scrollView.contentView.bounds.height,
            offsetY: scrollView.contentView.bounds.origin.y,
            showTemporarily: showTemporarily
        )
    }

    func scrollTo(offsetY targetOffset: CGFloat) {
        let clipView = scrollView.contentView
        let contentHeight = hostView.frame.height
        let maxOffset = max(contentHeight - clipView.bounds.height, 0)
        let clampedOffset = max(0, min(targetOffset, maxOffset))
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: clampedOffset))
        scrollView.reflectScrolledClipView(clipView)
        onScrollStateChanged?(true)
    }

    func resetScrollPosition() {
        scrollTo(offsetY: 0)
    }

    private func detailSectionContent() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let rows: [NSView] = [
            labeledControlRow(label: L10n.text(zhHans: "标题", en: "Title"), control: detailTitleField),
            labeledControlRow(label: L10n.text(zhHans: "自然语言规则", en: "Natural-language spec"), control: detailSpecField),
            detailTextRow(detailScheduleLabel),
            detailTextRow(detailTaskPromptLabel),
            detailTextRow(detailDomainsLabel),
            detailCheckboxRow(),
            detailTextRow(detailDeliveryLabel),
            detailTextRow(detailRiskLabel),
            labeledControlRow(label: L10n.text(zhHans: "响应深度", en: "Response depth"), control: responseProfilePopup),
            detailTextRow(detailHintLabel),
            detailActionRow()
        ]
        rows.forEach {
            stack.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func labeledControlRow(label: String, control: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: label)
        title.font = DesignTokens.Typography.settingsSectionBody
        title.textColor = DesignTokens.Color.textSecondary
        title.alignment = .left
        title.translatesAutoresizingMaskIntoConstraints = false

        control.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(control)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            title.topAnchor.constraint(equalTo: container.topAnchor),

            control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func detailTextRow(_ label: NSTextField) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .left
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func detailCheckboxRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        allowLightWritesCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(allowLightWritesCheckbox)
        NSLayoutConstraint.activate([
            allowLightWritesCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            allowLightWritesCheckbox.topAnchor.constraint(equalTo: container.topAnchor),
            allowLightWritesCheckbox.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            allowLightWritesCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor)
        ])
        return container
    }

    private func detailActionRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(saveButton)
        NSLayoutConstraint.activate([
            saveButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            saveButton.topAnchor.constraint(equalTo: container.topAnchor),
            saveButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            saveButton.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor)
        ])
        return container
    }

    private func renderJobs(_ jobs: [AskAutomationJob]) {
        jobsStack.arrangedSubviews.forEach {
            jobsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if jobs.isEmpty {
            let emptyState = emptyStateLabel(text: L10n.text(zhHans: "暂无任务。先在 Ask 中说“每天早上 9 点帮我…”来创建一个。", en: "No jobs yet. Create one in Ask with a request like “every day at 9am, help me…”."))
            jobsStack.addArrangedSubview(emptyState)
            emptyState.widthAnchor.constraint(equalTo: jobsStack.widthAnchor).isActive = true
            return
        }

        for job in jobs {
            let row = jobRow(for: job)
            jobsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: jobsStack.widthAnchor).isActive = true
        }
    }

    private func renderDetail(job: AskAutomationJob?) {
        guard let job else {
            detailTitleField.stringValue = ""
            detailSpecField.stringValue = ""
            detailScheduleLabel.stringValue = L10n.text(zhHans: "选择一个任务后可在这里编辑。", en: "Select a job to edit it here.")
            detailTaskPromptLabel.stringValue = L10n.text(zhHans: "执行任务预览会显示在这里。", en: "The normalized task preview appears here.")
            detailDomainsLabel.stringValue = L10n.text(zhHans: "能力域会在保存后自动归纳，例如 Web、知识库、文件或日历。", en: "Tool domains are inferred automatically after save, such as Web, Knowledge, Files, or Calendar.")
            detailDeliveryLabel.stringValue = L10n.text(zhHans: "默认回传：Inbox + 系统通知。", en: "Default delivery: Inbox + system notification.")
            detailRiskLabel.stringValue = L10n.text(zhHans: "高风险动作会被自动阻止，并转成 Inbox 待处理项。", en: "High-risk actions are blocked automatically and turned into inbox attention items.")
            detailHintLabel.stringValue = L10n.text(zhHans: "保存后会重新解析自然语言规则，并重新计算下次运行时间。", en: "Saving reparses the natural-language rule and recalculates the next run time.")
            allowLightWritesCheckbox.state = .off
            responseProfilePopup.selectItem(at: 1)
            saveButton.isEnabled = false
            return
        }

        detailTitleField.stringValue = job.title
        detailSpecField.stringValue = job.naturalLanguageSpec
        detailScheduleLabel.stringValue = L10n.format(
            zhHans: "当前调度：%@\n下次运行：%@\n上次结果：%@",
            en: "Current schedule: %@\nNext run: %@\nLast status: %@",
            job.trigger.scheduleSummary,
            job.nextRunAt.map(formattedDate) ?? L10n.text(zhHans: "待计算", en: "Pending"),
            localizedRunStatus(job.lastRunStatus)
        )
        detailTaskPromptLabel.stringValue = L10n.format(
            zhHans: "执行任务：%@",
            en: "Normalized task: %@",
            job.normalizedTaskPrompt
        )
        if let workspaceRoot = job.workspaceRoot, !workspaceRoot.isEmpty {
            detailTaskPromptLabel.stringValue += "\n" + L10n.format(
                zhHans: "工作区：%@",
                en: "Workspace: %@",
                workspaceRoot
            )
        }
        detailDomainsLabel.stringValue = L10n.format(
            zhHans: "能力域：%@",
            en: "Tool domains: %@",
            localizedDomainSummary(job.keyToolDomains)
        )
        detailDeliveryLabel.stringValue = L10n.format(
            zhHans: "结果回传：%@",
            en: "Delivery: %@",
            deliverySummary(job.delivery)
        )
        detailRiskLabel.stringValue = L10n.format(
            zhHans: "风险边界：%@",
            en: "Risk boundary: %@",
            job.riskSummary
        )
        detailHintLabel.stringValue = L10n.text(
            zhHans: "修改自然语言规则后再次保存，会同步刷新调度与能力域，不会覆盖既有运行历史。",
            en: "Saving after edits refreshes the schedule and tool domains without overwriting existing run history."
        )
        allowLightWritesCheckbox.state = (job.toolPolicy.allowKnowledgeWrites || job.toolPolicy.allowCalendarCreate) ? .on : .off
        switch job.responseProfileRawValue {
        case AskResponseProfile.concise.rawValue:
            responseProfilePopup.selectItem(at: 0)
        case AskResponseProfile.detailed.rawValue:
            responseProfilePopup.selectItem(at: 2)
        default:
            responseProfilePopup.selectItem(at: 1)
        }
        saveButton.isEnabled = true
    }

    private func renderRuns() {
        runsStack.arrangedSubviews.forEach {
            runsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let runs = automationStore.listRuns(jobID: selectedJobID, limit: 6)
        if runs.isEmpty {
            let emptyState = emptyStateLabel(text: L10n.text(zhHans: "还没有运行记录。", en: "There is no run history yet."))
            runsStack.addArrangedSubview(emptyState)
            emptyState.widthAnchor.constraint(equalTo: runsStack.widthAnchor).isActive = true
            return
        }

        for run in runs {
            let row = runRow(for: run)
            runsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: runsStack.widthAnchor).isActive = true
        }
    }

    private func renderInbox() {
        inboxStack.arrangedSubviews.forEach {
            inboxStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let items = inboxStore.items(limit: 6).filter { item in
            guard let selectedJobID else { return true }
            return item.sourceJobID == selectedJobID
        }
        if items.isEmpty {
            let emptyState = emptyStateLabel(text: L10n.text(zhHans: "这里会显示最近的异步结果与待处理项。", en: "Recent async results and attention items will appear here."))
            inboxStack.addArrangedSubview(emptyState)
            emptyState.widthAnchor.constraint(equalTo: inboxStack.widthAnchor).isActive = true
            return
        }

        for item in items {
            let row = inboxRow(for: item)
            inboxStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: inboxStack.widthAnchor).isActive = true
        }
    }

    private func jobRow(for job: AskAutomationJob) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyCardSurface(to: container, hovered: job.id == selectedJobID)

        let titleButton = NSButton(title: job.title, target: self, action: #selector(handleSelectJob(_:)))
        titleButton.identifier = NSUserInterfaceItemIdentifier(job.id)
        titleButton.isBordered = false
        titleButton.alignment = .left
        titleButton.font = DesignTokens.Typography.settingsSectionTitle
        titleButton.contentTintColor = DesignTokens.Color.textPrimary

        let scheduleLabel = NSTextField(wrappingLabelWithString: job.trigger.scheduleSummary)
        scheduleLabel.font = DesignTokens.Typography.settingsSectionBody
        scheduleLabel.textColor = DesignTokens.Color.textSecondary
        scheduleLabel.maximumNumberOfLines = 0

        let nextRunLabel = NSTextField(wrappingLabelWithString: L10n.format(
            zhHans: "下次运行：%@",
            en: "Next run: %@",
            job.nextRunAt.map(formattedDate) ?? L10n.text(zhHans: "已停止", en: "Stopped")
        ))
        nextRunLabel.font = DesignTokens.Typography.settingsSectionBody
        nextRunLabel.textColor = DesignTokens.Color.textSecondary
        nextRunLabel.maximumNumberOfLines = 0

        let workspaceLabel = NSTextField(wrappingLabelWithString: L10n.format(
            zhHans: "工作区：%@",
            en: "Workspace: %@",
            job.workspaceRoot.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L10n.text(zhHans: "未固定", en: "Not pinned")
        ))
        workspaceLabel.font = DesignTokens.Typography.settingsSectionBody
        workspaceLabel.textColor = DesignTokens.Color.textSecondary
        workspaceLabel.maximumNumberOfLines = 0

        let runButton = SettingsActionButton(title: L10n.text(zhHans: "立即运行", en: "Run now"), target: self, action: #selector(handleRunNow(_:)))
        let toggleButton = SettingsActionButton(title: job.enabled ? L10n.text(zhHans: "暂停", en: "Pause") : L10n.text(zhHans: "启用", en: "Enable"), target: self, action: #selector(handleToggleJob(_:)))
        let deleteButton = SettingsActionButton(title: L10n.text(zhHans: "删除", en: "Delete"), target: self, action: #selector(handleDeleteJob(_:)))
        [runButton, toggleButton, deleteButton].forEach {
            $0.identifier = NSUserInterfaceItemIdentifier(job.id)
            SettingsControlStyle.applyActionButton($0)
        }

        let titleRow = NSStackView(views: [
            titleButton,
            statusPill(
                text: job.enabled ? L10n.text(zhHans: "已启用", en: "Active") : L10n.text(zhHans: "已暂停", en: "Paused"),
                fillColor: job.enabled ? NSColor.systemGreen.withAlphaComponent(0.14) : DesignTokens.Color.accentOrangeSoftFill,
                borderColor: job.enabled ? NSColor.systemGreen.withAlphaComponent(0.26) : DesignTokens.Color.accentOrangeBorder,
                textColor: job.enabled ? NSColor.systemGreen : DesignTokens.Color.accentOrange
            )
        ])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        let domainBadges = NSStackView()
        domainBadges.orientation = .horizontal
        domainBadges.alignment = .centerY
        domainBadges.spacing = 6
        for domain in job.keyToolDomains.prefix(4) {
            domainBadges.addArrangedSubview(domainPill(for: domain))
        }
        if let lastRunStatus = job.lastRunStatus {
            domainBadges.addArrangedSubview(statusPill(
                text: localizedRunStatus(lastRunStatus),
                fillColor: fillColor(for: lastRunStatus),
                borderColor: borderColor(for: lastRunStatus),
                textColor: textColor(for: lastRunStatus)
            ))
        }
        domainBadges.addArrangedSubview(NSView())

        let buttonRow = NSStackView(views: [runButton, toggleButton, deleteButton, NSView()])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [titleRow, scheduleLabel, nextRunLabel, workspaceLabel, domainBadges, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        return container
    }

    private func emptyStateLabel(text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = DesignTokens.Typography.settingsSectionBody
        label.textColor = DesignTokens.Color.textSecondary
        label.maximumNumberOfLines = 0
        return label
    }

    private func applyDefaultStatus(
        jobs: [AskAutomationJob],
        activeCount: Int,
        unreadCount: Int,
        blockedCount: Int
    ) {
        if let override = pendingStatusOverride {
            statusLabel.stringValue = override.message
            statusLabel.textColor = override.color
            pendingStatusOverride = nil
            return
        }

        if jobs.isEmpty {
            statusLabel.stringValue = L10n.text(
                zhHans: "还没有本地定时任务。你可以在 Ask 里用自然语言创建，也可以先保存一个草案。",
                en: "There are no local automations yet. You can create them in Ask with natural language or save a draft first."
            )
            statusLabel.textColor = DesignTokens.Settings.Status.neutral
            return
        }

        if blockedCount > 0 || unreadCount > 0 {
            statusLabel.stringValue = L10n.format(
                zhHans: "当前共有 %d 个任务，其中 %d 个处于启用状态，%d 条结果等待处理，%d 次运行被拦截。",
                en: "There are %d automation jobs, %d active, %d inbox items awaiting attention, and %d blocked runs.",
                jobs.count,
                activeCount,
                unreadCount,
                blockedCount
            )
            statusLabel.textColor = DesignTokens.Settings.Status.warning
            return
        }

        statusLabel.stringValue = L10n.format(
            zhHans: "当前共有 %d 个任务，其中 %d 个处于启用状态，最近没有待处理阻塞。",
            en: "There are %d automation jobs, with %d active and no pending attention right now.",
            jobs.count,
            activeCount
        )
        statusLabel.textColor = DesignTokens.Settings.Status.success
    }

    private func summaryMetricItems(
        jobs: [AskAutomationJob],
        runs: [AskAutomationRunRecord],
        inboxItems: [AskInboxItem]
    ) -> [SettingsStatisticsMetricItem] {
        let activeCount = jobs.filter(\.enabled).count
        let unreadCount = inboxItems.filter { !$0.isRead }.count
        let blockedCount = runs.filter { $0.status == .blocked }.count
        let nextRunText = jobs
            .compactMap(\.nextRunAt)
            .sorted()
            .first
            .map(formattedDate)
            ?? L10n.text(zhHans: "暂无", en: "None")
        let lastStatus = runs.sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }.first?.status

        return [
            SettingsStatisticsMetricItem(
                title: L10n.text(zhHans: "启用中", en: "Active"),
                value: "\(activeCount)",
                note: jobs.isEmpty
                    ? L10n.text(zhHans: "还没有任务", en: "No jobs yet")
                    : L10n.format(zhHans: "共 %d 个定时任务", en: "%d jobs total", jobs.count)
            ),
            SettingsStatisticsMetricItem(
                title: L10n.text(zhHans: "下一次运行", en: "Next Run"),
                value: nextRunText,
                note: jobs.isEmpty
                    ? L10n.text(zhHans: "等待创建", en: "Waiting for the first job")
                    : L10n.text(zhHans: "按本地时间调度", en: "Scheduled in local time")
            ),
            SettingsStatisticsMetricItem(
                title: L10n.text(zhHans: "待处理", en: "Attention"),
                value: "\(unreadCount)",
                note: blockedCount > 0
                    ? L10n.format(zhHans: "%d 次运行被策略拦截", en: "%d runs blocked by policy", blockedCount)
                    : L10n.text(zhHans: "暂无阻塞", en: "No blocked runs")
            ),
            SettingsStatisticsMetricItem(
                title: L10n.text(zhHans: "最近状态", en: "Latest Status"),
                value: localizedRunStatus(lastStatus),
                note: lastStatus == nil
                    ? L10n.text(zhHans: "还没有执行记录", en: "No runs yet")
                    : L10n.text(zhHans: "查看下方运行记录了解细节", en: "See run history below for details")
            )
        ]
    }

    private func runRow(for run: AskAutomationRunRecord) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyCardSurface(to: container)

        let statusChip = statusPill(
            text: localizedRunStatus(run.status),
            fillColor: fillColor(for: run.status),
            borderColor: borderColor(for: run.status),
            textColor: textColor(for: run.status)
        )
        let dateLabel = NSTextField(labelWithString: formattedDate(run.finishedAt ?? run.startedAt))
        dateLabel.font = DesignTokens.Typography.settingsSectionBody
        dateLabel.textColor = DesignTokens.Color.textSecondary

        let header = NSStackView(views: [statusChip, dateLabel, NSView()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let summaryLabel = NSTextField(wrappingLabelWithString: run.summary)
        summaryLabel.font = DesignTokens.Typography.settingsSectionBody
        summaryLabel.textColor = DesignTokens.Color.textPrimary
        summaryLabel.maximumNumberOfLines = 0

        let metaLine = L10n.format(
            zhHans: "工具步骤：%d%@",
            en: "Tool steps: %d%@",
            run.toolSteps.count,
            run.artifacts.isEmpty ? "" : L10n.format(zhHans: " · 产物：%d", en: " · Artifacts: %d", run.artifacts.count)
        )
        let metaLabel = NSTextField(wrappingLabelWithString: metaLine)
        metaLabel.font = DesignTokens.Typography.settingsSectionBody
        metaLabel.textColor = DesignTokens.Color.textSecondary
        metaLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [header, summaryLabel, metaLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contextLine = automationRunContextLine(run)
        if !contextLine.isEmpty {
            let contextLabel = NSTextField(wrappingLabelWithString: contextLine)
            contextLabel.font = DesignTokens.Typography.settingsSectionBody
            contextLabel.textColor = DesignTokens.Color.textSecondary
            contextLabel.maximumNumberOfLines = 0
            stack.addArrangedSubview(contextLabel)
        }

        if let artifactsLine = automationRunArtifactsLine(run), !artifactsLine.isEmpty {
            let artifactsLabel = NSTextField(wrappingLabelWithString: artifactsLine)
            artifactsLabel.font = DesignTokens.Typography.settingsSectionBody
            artifactsLabel.textColor = DesignTokens.Color.textSecondary
            artifactsLabel.maximumNumberOfLines = 0
            stack.addArrangedSubview(artifactsLabel)
        }

        if let error = run.error, !error.isEmpty {
            let errorLabel = NSTextField(wrappingLabelWithString: error)
            errorLabel.font = DesignTokens.Typography.settingsSectionBody
            errorLabel.textColor = DesignTokens.Settings.Status.warning
            errorLabel.maximumNumberOfLines = 0
            stack.addArrangedSubview(errorLabel)
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        return container
    }

    private func automationRunContextLine(_ run: AskAutomationRunRecord) -> String {
        var parts: [String] = []
        if let mode = run.kernelMode, !mode.isEmpty {
            parts.append(
                L10n.format(zhHans: "模式 %@", en: "Mode %@", mode)
            )
        }
        if let workspaceRoot = run.workspaceRoot, !workspaceRoot.isEmpty {
            parts.append(
                L10n.format(
                    zhHans: "工作区 %@",
                    en: "Workspace %@",
                    URL(fileURLWithPath: workspaceRoot).lastPathComponent
                )
            )
        }
        if let agentState = run.agentState, !agentState.isEmpty {
            parts.append(
                L10n.format(zhHans: "状态 %@", en: "Agent %@", agentState)
            )
        }
        if let approvalID = run.pendingApprovalActionID, !approvalID.isEmpty {
            parts.append(
                L10n.text(
                    zhHans: "有待确认动作",
                    en: "Pending approval"
                )
            )
            _ = approvalID
        }
        return parts.joined(separator: " · ")
    }

    private func automationRunArtifactsLine(_ run: AskAutomationRunRecord) -> String? {
        guard !run.artifacts.isEmpty else { return nil }
        let titles = run.artifacts
            .prefix(3)
            .map(\.title)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !titles.isEmpty else { return nil }
        return L10n.format(
            zhHans: "回传记录：%@",
            en: "Delivery record: %@",
            titles.joined(separator: " · ")
        )
    }

    private func inboxRow(for item: AskInboxItem) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        SettingsControlStyle.applyCardSurface(to: container, hovered: !item.isRead)

        let readChip = statusPill(
            text: item.isRead ? L10n.text(zhHans: "已读", en: "Read") : L10n.text(zhHans: "待处理", en: "Unread"),
            fillColor: item.isRead ? DesignTokens.Color.accentOrangeSoftFill : NSColor.systemBlue.withAlphaComponent(0.14),
            borderColor: item.isRead ? DesignTokens.Color.accentOrangeBorder : NSColor.systemBlue.withAlphaComponent(0.24),
            textColor: item.isRead ? DesignTokens.Color.accentOrange : NSColor.systemBlue
        )
        let dateLabel = NSTextField(labelWithString: formattedDate(item.createdAt))
        dateLabel.font = DesignTokens.Typography.settingsSectionBody
        dateLabel.textColor = DesignTokens.Color.textSecondary

        let header = NSStackView(views: [readChip, dateLabel, NSView()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let titleLabel = NSTextField(labelWithString: item.title)
        titleLabel.font = DesignTokens.Typography.settingsSectionTitle
        titleLabel.textColor = item.isRead ? DesignTokens.Color.textSecondary : DesignTokens.Color.textPrimary

        let summaryLabel = NSTextField(wrappingLabelWithString: item.summary)
        summaryLabel.font = DesignTokens.Typography.settingsSectionBody
        summaryLabel.textColor = item.isRead ? DesignTokens.Color.textSecondary : DesignTokens.Color.textPrimary
        summaryLabel.maximumNumberOfLines = 0

        let actionsSummary = item.actions.isEmpty
            ? L10n.text(zhHans: "无需额外操作", en: "No follow-up actions")
            : L10n.format(zhHans: "可继续操作 %d 项", en: "%d follow-up actions available", item.actions.count)
        let metaLabel = NSTextField(labelWithString: actionsSummary)
        metaLabel.font = DesignTokens.Typography.settingsSectionBody
        metaLabel.textColor = DesignTokens.Color.textSecondary

        var arrangedViews: [NSView] = [header, titleLabel, summaryLabel, metaLabel]
        if item.assistantFollowUpActivation != nil {
            let continueButton = SettingsActionButton(
                title: L10n.text(zhHans: "继续处理", en: "Continue"),
                target: self,
                action: #selector(handleContinueInboxItem(_:))
            )
            continueButton.identifier = NSUserInterfaceItemIdentifier(item.id)
            SettingsControlStyle.applyActionButton(continueButton)

            let buttonRow = NSStackView(views: [continueButton, NSView()])
            buttonRow.orientation = .horizontal
            buttonRow.alignment = .centerY
            buttonRow.spacing = 8
            arrangedViews.append(buttonRow)
        }

        let stack = NSStackView(views: arrangedViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        return container
    }

    private func domainPill(for domain: String) -> NSView {
        statusPill(
            text: localizedDomain(domain),
            fillColor: DesignTokens.Color.accentOrangeSoftFill,
            borderColor: DesignTokens.Color.accentOrangeBorder,
            textColor: DesignTokens.Color.accentOrange
        )
    }

    private func statusPill(
        text: String,
        fillColor: NSColor,
        borderColor: NSColor,
        textColor: NSColor
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.layer?.backgroundColor = fillColor.cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = borderColor.cgColor

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = textColor

        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3)
        ])
        return container
    }

    private func localizedDomainSummary(_ domains: [String]) -> String {
        let resolved = domains.map(localizedDomain)
        guard !resolved.isEmpty else {
            return L10n.text(zhHans: "通用 Agent", en: "General agent")
        }
        return resolved.joined(separator: " · ")
    }

    private func localizedDomain(_ domain: String) -> String {
        switch domain {
        case "web":
            return L10n.text(zhHans: "网页", en: "Web")
        case "knowledge":
            return L10n.text(zhHans: "知识库", en: "Knowledge")
        case "calendar":
            return L10n.text(zhHans: "日历", en: "Calendar")
        case "writeback":
            return L10n.text(zhHans: "写回", en: "Writeback")
        case "files":
            return L10n.text(zhHans: "文件", en: "Files")
        case "workspace":
            return L10n.text(zhHans: "工作区", en: "Workspace")
        default:
            return L10n.text(zhHans: "Agent", en: "Agent")
        }
    }

    private func deliverySummary(_ delivery: AskAutomationDelivery) -> String {
        switch (delivery.deliverToInbox, delivery.deliverSystemNotification) {
        case (true, true):
            return L10n.text(zhHans: "Inbox + 系统通知", en: "Inbox + system notification")
        case (true, false):
            return L10n.text(zhHans: "仅 Inbox", en: "Inbox only")
        case (false, true):
            return L10n.text(zhHans: "仅系统通知", en: "System notification only")
        default:
            return L10n.text(zhHans: "不自动回传", en: "No automatic delivery")
        }
    }

    private func localizedRunStatus(_ status: AskAutomationRunStatus?) -> String {
        guard let status else {
            return L10n.text(zhHans: "尚未运行", en: "Not run yet")
        }
        switch status {
        case .running:
            return L10n.text(zhHans: "运行中", en: "Running")
        case .completed:
            return L10n.text(zhHans: "已完成", en: "Completed")
        case .partial:
            return L10n.text(zhHans: "部分完成", en: "Partial")
        case .blocked:
            return L10n.text(zhHans: "已拦截", en: "Blocked")
        case .failed:
            return L10n.text(zhHans: "失败", en: "Failed")
        case .skipped:
            return L10n.text(zhHans: "跳过", en: "Skipped")
        }
    }

    private func fillColor(for status: AskAutomationRunStatus) -> NSColor {
        switch status {
        case .completed:
            return NSColor.systemGreen.withAlphaComponent(0.14)
        case .partial:
            return NSColor.systemYellow.withAlphaComponent(0.18)
        case .blocked:
            return DesignTokens.Color.accentOrangeSoftFill
        case .failed:
            return NSColor.systemRed.withAlphaComponent(0.14)
        case .running:
            return NSColor.systemBlue.withAlphaComponent(0.14)
        case .skipped:
            return DesignTokens.Color.textTertiary.withAlphaComponent(0.16)
        }
    }

    private func borderColor(for status: AskAutomationRunStatus) -> NSColor {
        switch status {
        case .completed:
            return NSColor.systemGreen.withAlphaComponent(0.26)
        case .partial:
            return NSColor.systemYellow.withAlphaComponent(0.30)
        case .blocked:
            return DesignTokens.Color.accentOrangeBorder
        case .failed:
            return NSColor.systemRed.withAlphaComponent(0.24)
        case .running:
            return NSColor.systemBlue.withAlphaComponent(0.24)
        case .skipped:
            return DesignTokens.Color.textTertiary.withAlphaComponent(0.22)
        }
    }

    private func textColor(for status: AskAutomationRunStatus) -> NSColor {
        switch status {
        case .completed:
            return NSColor.systemGreen
        case .partial:
            return NSColor.systemYellow
        case .blocked:
            return DesignTokens.Color.accentOrange
        case .failed:
            return NSColor.systemRed
        case .running:
            return NSColor.systemBlue
        case .skipped:
            return DesignTokens.Color.textSecondary
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppSettings.shared.appLanguage.localeIdentifier)
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("M d HH:mm")
        return formatter.string(from: date)
    }

    @objc private func handleSelectJob(_ sender: NSButton) {
        selectedJobID = sender.identifier?.rawValue
        reloadData()
    }

    @objc private func handleRunNow(_ sender: NSButton) {
        guard let jobID = sender.identifier?.rawValue else { return }
        scheduler.runNow(jobID: jobID)
    }

    @objc private func handleToggleJob(_ sender: NSButton) {
        guard let jobID = sender.identifier?.rawValue,
              let job = automationStore.job(id: jobID) else { return }
        _ = automationStore.setJobEnabled(jobID, enabled: !job.enabled)
        reloadData()
    }

    @objc private func handleDeleteJob(_ sender: NSButton) {
        guard let jobID = sender.identifier?.rawValue else { return }
        _ = automationStore.deleteJob(id: jobID)
        if selectedJobID == jobID {
            selectedJobID = nil
        }
        reloadData()
    }

    @objc private func handleContinueInboxItem(_ sender: NSButton) {
        guard let itemID = sender.identifier?.rawValue,
              let item = inboxStore.items(limit: 80).first(where: { $0.id == itemID }),
              let payload = item.assistantFollowUpActivation?.encodedPayload() else {
            return
        }
        inboxStore.markRead(itemID)
        notificationCenter.post(
            name: .nexhubOpenAssistantFollowUp,
            object: nil,
            userInfo: [
                "assistant_followup_activation_payload": payload,
                "inbox_item_id": itemID
            ]
        )
        reloadData()
    }

    @objc private func handleSaveSelectedJob() {
        guard let selectedJobID,
              var job = automationStore.job(id: selectedJobID) else {
            return
        }

        let spec = detailSpecField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = detailTitleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = parser.parse(
            spec.isEmpty ? job.naturalLanguageSpec : spec,
            workspaceRoot: job.workspaceRoot
        ) else {
            statusLabel.stringValue = L10n.text(zhHans: "没能重新解析这条自然语言规则，请调整后再保存。", en: "The natural-language rule could not be parsed again. Adjust it and try saving.")
            statusLabel.textColor = DesignTokens.Settings.Status.warning
            return
        }

        job.title = title.isEmpty ? parsed.title : title
        job.naturalLanguageSpec = spec.isEmpty ? parsed.naturalLanguageSpec : spec
        job.normalizedTaskPrompt = parsed.normalizedTaskPrompt
        job.workspaceRoot = parsed.workspaceRoot
        job.trigger = parsed.trigger
        job.keyToolDomains = parsed.keyToolDomains
        job.riskSummary = parsed.riskSummary
        job.updatedAt = Date()
        job.responseProfileRawValue = selectedResponseProfile()?.rawValue ?? AskResponseProfile.balanced.rawValue

        let allowLightWrites = allowLightWritesCheckbox.state == .on
        job.toolPolicy = AskAutomationPolicy(
            allowedRiskLevels: AskAutomationPolicy.default.allowedRiskLevels,
            allowVisibleOpenActions: AskAutomationPolicy.default.allowVisibleOpenActions,
            allowCalendarCreate: allowLightWrites,
            allowKnowledgeWrites: allowLightWrites,
            allowClipboardWrite: allowLightWrites,
            requireForegroundForWriteback: AskAutomationPolicy.default.requireForegroundForWriteback
        )
        job.refreshNextRun(after: Date())
        _ = automationStore.upsert(job: job)
        pendingStatusOverride = (
            message: L10n.text(zhHans: "定时任务已保存，并已刷新调度与任务预览。", en: "Automation saved with refreshed schedule and task preview."),
            color: DesignTokens.Settings.Status.success
        )
        reloadData()
    }

    @objc private func handleCheckboxChanged(_ sender: NSButton) {
        saveButton.isEnabled = selectedJobID != nil
    }

    private func selectedResponseProfile() -> AskResponseProfile? {
        switch responseProfilePopup.indexOfSelectedItem {
        case 0:
            return .concise
        case 2:
            return .detailed
        default:
            return .balanced
        }
    }

    func testingLayoutSnapshot(frame: NSRect = NSRect(x: 0, y: 0, width: 1200, height: 900)) -> (
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
        self.frame = frame
        layoutSubtreeIfNeeded()
        refreshScrollLayout()
        layoutSubtreeIfNeeded()
        return (
            scrollBounds: scrollView.contentView.bounds,
            contentFrame: contentStack.frame,
            metricFrame: metricStripView.frame,
            jobListFrame: jobListCard?.frame ?? .zero,
            detailFrame: detailCard?.frame ?? .zero,
            runHistoryFrame: runHistoryCard?.frame ?? .zero,
            inboxFrame: inboxCard?.frame ?? .zero,
            detailTitleFrame: detailTitleField.frame,
            detailSpecFrame: detailSpecField.frame,
            responseProfileFrame: responseProfilePopup.frame,
            saveButtonFrame: saveButton.frame,
            usesSystemScroller: scrollView.hasVerticalScroller
        )
    }
}
#endif
