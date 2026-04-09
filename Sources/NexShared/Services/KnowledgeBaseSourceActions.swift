import AppKit
import Foundation

package enum KnowledgeBaseCaptureBehavior: String, Codable, Equatable {
    case archive
    case distill
    case update
    case stash
}

package enum KnowledgeBaseContentKind: String, Codable, Equatable {
    case article
    case document
    case note
    case webpage
    case email
    case spreadsheet
    case presentation
    case richText = "rich_text"
    case reference
}

package enum KnowledgeBaseCaptureFailureKind: String, Codable, Equatable {
    case networkFailed = "network_failed"
    case authRequired = "auth_required"
    case unsupportedDynamicPage = "unsupported_dynamic_page"
    case noReadableContent = "no_readable_content"
    case browserCaptureUnavailable = "browser_capture_unavailable"
    case parsingFailed = "parsing_failed"
    case unsupportedFormat = "unsupported_format"
    case emptyContent = "empty_content"
}

package struct KnowledgeBaseCaptureFailure: Codable, Equatable, Error, LocalizedError {
    package let kind: KnowledgeBaseCaptureFailureKind
    package let message: String

    package init(kind: KnowledgeBaseCaptureFailureKind, message: String) {
        self.kind = kind
        self.message = message
    }

    package var errorDescription: String? { message }
}

enum KnowledgeBaseSourceActionKind: String, Codable, Equatable {
    case openURL = "open_url"
    case openFile = "open_file"
    case revealInFinder = "reveal_in_finder"
    case showCapturedText = "show_captured_text"
}

package struct KnowledgeBaseSourceAction: Codable, Equatable {
    let kind: KnowledgeBaseSourceActionKind
    let label: String
    let value: String?
}

package struct KnowledgeBaseSnapshotStatus: Codable, Equatable {
    let snapshotKind: String
    let status: String
    let snapshotID: String?
    let updatedAt: Date?
}

package struct KnowledgeBaseCaptureAttempt: Codable, Equatable {
    let provider: String
    let order: Int?
    let result: String?
    let retentionScore: Double?
    let dynamicPageSuspicion: Bool?
    let authCookieVisibility: String?
    let pageType: String?
    let failureKind: String?
    let failureMessage: String?

    private enum CodingKeys: String, CodingKey {
        case provider
        case order
        case result
        case retentionScore = "retention_score"
        case dynamicPageSuspicion = "dynamic_page_suspicion"
        case authCookieVisibility = "auth_cookie_visibility"
        case pageType = "page_type"
        case failureKind = "failure_kind"
        case failureMessage = "failure_message"
    }
}

package struct KnowledgeBaseRefreshState: Codable, Equatable {
    let refreshable: Bool?
    let lastRefreshedAt: Date?
    let recommended: Bool?
}

package struct KnowledgeBaseIngestionReport: Codable, Equatable {
    let retentionScore: Double?
    let provenanceQuality: String?
    let structureQuality: String?
    let manualRefreshRecommended: Bool?
    let preserved: [String]?
    let discarded: [String]?

    private enum CodingKeys: String, CodingKey {
        case retentionScore = "retention_score"
        case provenanceQuality = "provenance_quality"
        case structureQuality = "structure_quality"
        case manualRefreshRecommended = "manual_refresh_recommended"
        case preserved
        case discarded
    }
}

package struct KnowledgeBaseCitation: Codable, Equatable {
    let sourceID: String?
    let snapshotID: String?
    let chunkID: String?
    let sectionTitle: String?
    let charRange: [Int]?
    let sourceLocator: [String: String]?
    let previewQuote: String?

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case snapshotID = "snapshot_id"
        case chunkID = "chunk_id"
        case sectionTitle = "section_title"
        case charRange = "char_range"
        case sourceLocator = "source_locator"
        case previewQuote = "preview_quote"
    }
}

struct KnowledgeBaseSnapshot: Codable, Equatable {
    let id: String
    let sourceID: String
    let revision: Int
    let createdAt: Date
    let snapshotKind: String
    let markdownText: String
    let plainText: String
    let metadata: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceID = "source_id"
        case revision
        case createdAt = "created_at"
        case snapshotKind = "snapshot_kind"
        case markdownText = "markdown_text"
        case plainText = "plain_text"
        case metadata
    }
}

package struct KnowledgeBaseSearchMatch: Equatable {
    package let entry: ReplyKnowledgeBaseEntry
    package let score: Double
    package let matchedChunk: ReplyKnowledgeBaseChunk?
    package let matchedFacets: [String]
    package let reason: String
    package let citation: KnowledgeBaseCitation?
}

package enum KnowledgeBaseSourceActionResolver {
    private static let capturedTextReferencePrefix = "kb-entry://"

    package static func capturedTextReference(forEntryID entryID: String) -> String {
        capturedTextReferencePrefix + entryID
    }

    package static func primaryAction(
        for entry: ReplyKnowledgeBaseEntry,
        languageCode: String
    ) -> KnowledgeBaseSourceAction? {
        effectiveActions(for: entry, languageCode: languageCode).first
    }

    package static func effectiveActions(
        for entry: ReplyKnowledgeBaseEntry,
        languageCode: String
    ) -> [KnowledgeBaseSourceAction] {
        if let actions = entry.sourceActions, !actions.isEmpty {
            return actions
        }

        switch entry.sourceKind {
        case .url, .notion:
            if let url = entry.externalURL ?? fallbackURLString(from: entry.sourceFilePath) {
                return [
                    KnowledgeBaseSourceAction(
                        kind: .openURL,
                        label: localized(zhHans: "打开来源", en: "Open Source", languageCode: languageCode),
                        value: url
                    )
                ]
            }
        case .file:
            let sourceURL = URL(fileURLWithPath: entry.sourceFilePath)
            return [
                KnowledgeBaseSourceAction(
                    kind: .openFile,
                    label: localized(zhHans: "打开文件", en: "Open File", languageCode: languageCode),
                    value: sourceURL.path
                ),
                KnowledgeBaseSourceAction(
                    kind: .revealInFinder,
                    label: localized(zhHans: "在 Finder 中显示", en: "Reveal in Finder", languageCode: languageCode),
                    value: sourceURL.path
                )
            ]
        case .selectionText:
            return [
                KnowledgeBaseSourceAction(
                    kind: .showCapturedText,
                    label: localized(zhHans: "查看原文", en: "View Original", languageCode: languageCode),
                    value: capturedTextReference(forEntryID: entry.id)
                )
            ]
        case nil:
            break
        }

        if let fallbackText = entry.fullText, !fallbackText.isEmpty {
            return [
                KnowledgeBaseSourceAction(
                    kind: .showCapturedText,
                    label: localized(zhHans: "查看原文", en: "View Original", languageCode: languageCode),
                    value: fallbackText
                )
            ]
        }

        return []
    }

    package static func skillResultAction(from action: KnowledgeBaseSourceAction) -> SkillResultAction {
        switch action.kind {
        case .openURL:
            return SkillResultAction(type: .openURL, label: action.label, value: action.value)
        case .openFile:
            return SkillResultAction(type: .openFile, label: action.label, value: action.value)
        case .revealInFinder:
            return SkillResultAction(type: .revealInFinder, label: action.label, value: action.value)
        case .showCapturedText:
            return SkillResultAction(type: .showCapturedText, label: action.label, value: action.value)
        }
    }

    @MainActor
    package static func performPrimaryAction(for entry: ReplyKnowledgeBaseEntry, languageCode: String) {
        guard let action = primaryAction(for: entry, languageCode: languageCode) else { return }
        perform(action: action, title: entry.title)
    }

    @MainActor
    package static func perform(action: KnowledgeBaseSourceAction, title: String) {
        guard let value = action.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return
        }

        switch action.kind {
        case .openURL:
            if let url = URL(string: value) {
                NSWorkspace.shared.open(url)
            }
        case .openFile:
            let url = URL(fileURLWithPath: value)
            NSWorkspace.shared.open(url)
        case .revealInFinder:
            let url = URL(fileURLWithPath: value)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .showCapturedText:
            let resolved = resolveCapturedTextPayload(from: value, fallbackTitle: title)
            KnowledgeBaseTextPreviewWindowController.shared.show(title: resolved.title, text: resolved.text)
        }
    }

    static func resolveCapturedTextPayload(from value: String, fallbackTitle: String) -> (title: String, text: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(capturedTextReferencePrefix) else {
            return (fallbackTitle, trimmed)
        }

        let entryID = String(trimmed.dropFirst(capturedTextReferencePrefix.count))
        guard !entryID.isEmpty,
              let entry = ReplyKnowledgeBaseStore.shared.entry(id: entryID),
              let fullText = entry.fullText,
              !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (fallbackTitle, trimmed)
        }
        return (entry.title, fullText)
    }

    private static func fallbackURLString(from path: String) -> String? {
        guard let url = URL(string: path), url.scheme?.isEmpty == false else {
            return nil
        }
        return url.absoluteString
    }

    private static func localized(zhHans: String, en: String, languageCode: String) -> String {
        L10n.text(languageCode: languageCode, zhHans: zhHans, en: en)
    }
}

@MainActor
final class KnowledgeBaseTextPreviewWindowController: NSWindowController, NSWindowDelegate {
    static let shared = KnowledgeBaseTextPreviewWindowController()

    private enum PreviewBlock {
        case heading(String)
        case paragraph(String)
        case bullet(String)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: L10n.text(zhHans: "可读内容预览", en: "Readable Preview"))
    private let bodyCard = NSView()
    private let scrollView = NSScrollView(frame: .zero)
    private let bodyTextView = NSTextView(frame: .zero)
    private let scrollIndicator = SettingsScrollIndicatorView()
    private var scrollObserver: NSObjectProtocol?

    private init() {
        let contentRect = NSRect(x: 0, y: 0, width: 760, height: 620)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.toolbar = nil

        let root = NSView(frame: contentRect)
        root.translatesAutoresizingMaskIntoConstraints = false

        let backdrop = PanelSurfaceView(style: .toolbar)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.tintOpacityOverride = 0.92

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = DesignTokens.Color.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = DesignTokens.KnowledgeBaseWindow.Row.metaFont
        subtitleLabel.textColor = DesignTokens.Color.textSecondary

        bodyCard.translatesAutoresizingMaskIntoConstraints = false
        bodyCard.wantsLayer = true
        bodyCard.layer?.masksToBounds = true
        bodyCard.layer?.cornerRadius = DesignTokens.Settings.Surface.pageCornerRadius
        bodyCard.layer?.borderWidth = 1
        bodyCard.layer?.borderColor = DesignTokens.Settings.Surface.pageBorder.cgColor
        bodyCard.layer?.backgroundColor = DesignTokens.Settings.Surface.pageFill.cgColor

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller = nil

        bodyTextView.translatesAutoresizingMaskIntoConstraints = false
        bodyTextView.isEditable = false
        bodyTextView.isSelectable = true
        bodyTextView.drawsBackground = false
        bodyTextView.isHorizontallyResizable = false
        bodyTextView.isVerticallyResizable = true
        bodyTextView.minSize = NSSize(width: 0, height: 0)
        bodyTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        bodyTextView.textContainerInset = NSSize(width: 0, height: 0)
        bodyTextView.textContainer?.widthTracksTextView = true
        bodyTextView.textContainer?.heightTracksTextView = false
        bodyTextView.textContainer?.lineFragmentPadding = 0
        bodyTextView.textContainer?.containerSize = NSSize(width: contentRect.width, height: .greatestFiniteMagnitude)
        bodyTextView.autoresizingMask = [.width]
        scrollView.documentView = bodyTextView

        scrollIndicator.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        bodyCard.addSubview(scrollView)
        bodyCard.addSubview(scrollIndicator)
        backdrop.addSubview(titleLabel)
        backdrop.addSubview(subtitleLabel)
        backdrop.addSubview(bodyCard)
        root.addSubview(backdrop)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 48),
            titleLabel.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -32),
            titleLabel.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 56),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),

            bodyCard.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 32),
            bodyCard.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -32),
            bodyCard.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 28),
            bodyCard.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -28),

            scrollView.leadingAnchor.constraint(equalTo: bodyCard.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: bodyCard.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: bodyCard.topAnchor, constant: 24),
            scrollView.bottomAnchor.constraint(equalTo: bodyCard.bottomAnchor, constant: -24),

            scrollIndicator.trailingAnchor.constraint(equalTo: bodyCard.trailingAnchor, constant: -10),
            scrollIndicator.topAnchor.constraint(equalTo: bodyCard.topAnchor, constant: 18),
            scrollIndicator.bottomAnchor.constraint(equalTo: bodyCard.bottomAnchor, constant: -18),
            scrollIndicator.widthAnchor.constraint(equalToConstant: 4)
        ])
        window.contentView = root
        super.init(window: window)
        window.delegate = self
        configureScrollIndicatorBindings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    func show(title: String, text: String) {
        window?.title = title
        titleLabel.stringValue = title
        bodyTextView.textStorage?.setAttributedString(Self.previewAttributedString(from: text))
        relayoutDocumentView()
        refreshScrollIndicator(showTemporarily: false)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidResize(_ notification: Notification) {
        relayoutDocumentView()
        refreshScrollIndicator(showTemporarily: false)
    }

    private func relayoutDocumentView() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let contentWidth = max(scrollView.contentSize.width, 420)
        bodyTextView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 1)
        bodyTextView.layoutManager?.ensureLayout(for: bodyTextView.textContainer!)
        let fittingHeight = max(bodyTextView.layoutManager?.usedRect(for: bodyTextView.textContainer!).height ?? 1, 1)
        bodyTextView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: fittingHeight)
    }

    private func configureScrollIndicatorBindings() {
        scrollIndicator.onScrollRequested = { [weak self] targetOffset in
            guard let self else { return }
            let clipView = self.scrollView.contentView
            clipView.scroll(to: NSPoint(x: 0, y: targetOffset))
            self.scrollView.reflectScrolledClipView(clipView)
            self.refreshScrollIndicator(showTemporarily: true)
        }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshScrollIndicator(showTemporarily: true)
            }
        }
    }

    private func refreshScrollIndicator(showTemporarily: Bool) {
        let visibleHeight = scrollView.contentView.bounds.height
        let contentHeight = bodyTextView.frame.height
        let offsetY = scrollView.contentView.bounds.origin.y
        scrollIndicator.update(
            contentHeight: contentHeight,
            visibleHeight: visibleHeight,
            offsetY: offsetY,
            showTemporarily: showTemporarily
        )
    }

    private static func cleanedPreviewText(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        value = value.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "</p>", with: "\n\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "</li>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^\\)]+)\\)", with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\t", with: " ")
        value = decodeHTMLEntities(in: value)
        let noisePatterns = [
            "keyboard_arrow_down",
            "Skip to content",
            "Skip to main content",
            "Navigation Menu",
            "Toggle navigation",
            "Appearance settings",
            "Search code, repositories, users, issues, pull requests",
            "Instantly share code, notes, and snippets",
            "Cookie Settings",
            "Manage cookies",
            "By clicking",
            "Accept all cookies",
            "Reject all cookies"
        ]
        noisePatterns.forEach {
            value = value.replacingOccurrences(of: $0, with: "")
        }
        var cleanedLines: [String] = []
        var lastLine = ""
        for rawLine in value.components(separatedBy: .newlines) {
            let line = rawLine
                .replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^[-*•]\\s*", with: "• ", options: .regularExpression)
                .replacingOccurrences(of: "^\\d+\\.\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            if line.isEmpty == false,
               (lower == "home" || lower == "docs" || lower == "pricing" || lower == "blog") {
                continue
            }
            if line.isEmpty {
                if cleanedLines.last?.isEmpty == false {
                    cleanedLines.append("")
                }
                continue
            }
            if line == lastLine {
                continue
            }
            lastLine = line
            cleanedLines.append(line)
        }
        return cleanedLines.joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    private static func previewAttributedString(from text: String) -> NSAttributedString {
        let blocks = previewBlocks(from: text)
        guard !blocks.isEmpty else {
            let fallback = NSMutableAttributedString(
                string: L10n.text(zhHans: "这份来源暂时没有可展示的可读内容。", en: "There is no readable content available for this source yet.")
            )
            fallback.addAttributes([
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: DesignTokens.Color.textSecondary
            ], range: NSRange(location: 0, length: fallback.length))
            return fallback
        }

        let output = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n"))
            }
            switch block {
            case .heading(let text):
                output.append(NSAttributedString(string: softWrappedText(text), attributes: headingAttributes()))
            case .paragraph(let text):
                output.append(NSAttributedString(string: softWrappedText(text), attributes: paragraphAttributes()))
            case .bullet(let text):
                output.append(NSAttributedString(string: "• \(softWrappedText(text))", attributes: bulletAttributes()))
            }
        }
        return output
    }

    private static func previewBlocks(from text: String) -> [PreviewBlock] {
        let cleaned = cleanedPreviewText(text)
        let lines = cleaned.components(separatedBy: .newlines)
        var blocks: [PreviewBlock] = []
        var index = 0

        func normalized(_ raw: String) -> String {
            raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while index < lines.count {
            let current = normalized(lines[index])
            if current.isEmpty {
                index += 1
                continue
            }
            if isIgnorableLine(current) {
                index += 1
                continue
            }
            if let bullet = consumeBullet(from: lines, index: &index, normalize: normalized) {
                blocks.append(.bullet(bullet))
                continue
            }
            if isLikelyHeading(current) {
                blocks.append(.heading(current))
                index += 1
                continue
            }

            var paragraphParts = [current]
            index += 1
            while index < lines.count {
                let next = normalized(lines[index])
                if next.isEmpty {
                    index += 1
                    break
                }
                if isIgnorableLine(next) {
                    index += 1
                    continue
                }
                if consumeBullet(from: lines, index: &index, normalize: normalized, dryRun: true) != nil || isLikelyHeading(next) {
                    break
                }
                paragraphParts.append(next)
                index += 1
            }
            let paragraph = paragraphParts.joined(separator: " ")
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph))
            }
        }

        return blocks
    }

    private static func consumeBullet(
        from lines: [String],
        index: inout Int,
        normalize: (String) -> String,
        dryRun: Bool = false
    ) -> String? {
        guard index < lines.count else { return nil }
        let line = normalize(lines[index])
        guard let match = line.range(of: #"^(?:[-*•]|\d+[.)])\s*(.*)$"#, options: .regularExpression) else {
            return nil
        }
        var content = String(line[match]).replacingOccurrences(of: #"^(?:[-*•]|\d+[.)])\s*"#, with: "", options: .regularExpression)
        var probe = index + 1
        if content.isEmpty {
            while probe < lines.count {
                let candidate = normalize(lines[probe])
                if candidate.isEmpty {
                    probe += 1
                    continue
                }
                if isIgnorableLine(candidate) {
                    probe += 1
                    continue
                }
                if isLikelyHeading(candidate) {
                    return nil
                }
                content = candidate
                probe += 1
                break
            }
        }
        if content.isEmpty {
            return nil
        }
        while probe < lines.count {
            let candidate = normalize(lines[probe])
            if candidate.isEmpty || isIgnorableLine(candidate) {
                probe += 1
                break
            }
            if candidate.range(of: #"^(?:[-*•]|\d+[.)])\s*"#, options: .regularExpression) != nil || isLikelyHeading(candidate) {
                break
            }
            content += " " + candidate
            probe += 1
        }
        if !dryRun {
            index = probe
        }
        return content
    }

    private static func isIgnorableLine(_ line: String) -> Bool {
        if line == "•" || line == "-" || line == "*" { return true }
        if line.range(of: #"^\|[-:\s|]+\|?$"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"^\|.*\|$"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"^(?:read more|learn more|view all|show more)$"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }

    private static func isLikelyHeading(_ paragraph: String) -> Bool {
        if paragraph.count > 80 { return false }
        if paragraph.contains("。") || paragraph.contains(". ") || paragraph.contains("?") || paragraph.contains("!") { return false }
        if paragraph.range(of: #"^(?:[-*•]|\d+[.)])\s*"#, options: .regularExpression) != nil { return false }
        if paragraph.contains("http://") || paragraph.contains("https://") { return false }
        let words = paragraph.split { $0 == " " || $0 == "\t" }
        if words.count <= 10, paragraph == paragraph.uppercased() {
            return true
        }
        if paragraph.hasSuffix(":") && words.count <= 10 { return true }
        return words.count <= 8 && paragraph.first?.isLetter == true
    }

    private static func headingAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 3
        style.paragraphSpacing = 14
        return [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: DesignTokens.Color.textPrimary,
            .paragraphStyle: style
        ]
    }

    private static func paragraphAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 5
        style.paragraphSpacing = 16
        return [
            .font: NSFont.systemFont(ofSize: 15.5),
            .foregroundColor: DesignTokens.Color.textPrimary,
            .paragraphStyle: style
        ]
    }

    private static func bulletAttributes() -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 5
        style.paragraphSpacing = 14
        style.headIndent = 22
        style.firstLineHeadIndent = 0
        return [
            .font: NSFont.systemFont(ofSize: 15.5),
            .foregroundColor: DesignTokens.Color.textPrimary,
            .paragraphStyle: style
        ]
    }

    private static func softWrappedText(_ text: String) -> String {
        var output = ""
        var runLength = 0
        for character in text {
            output.append(character)
            if character.isWhitespace {
                runLength = 0
                continue
            }
            runLength += 1
            if "/?&=._-".contains(character) {
                output.append("\u{200B}")
                runLength = 0
                continue
            }
            if runLength >= 18 {
                output.append("\u{200B}")
                runLength = 0
            }
        }
        return output
    }

    private static func decodeHTMLEntities(in text: String) -> String {
        let replacements: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&middot;": "·"
        ]
        return replacements.reduce(text) { partial, pair in
            partial.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }
}
