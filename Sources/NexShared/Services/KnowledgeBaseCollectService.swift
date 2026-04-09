import AppKit
import Foundation

final class KnowledgeBaseCollectService {
    private let store: ReplyKnowledgeBaseStore
    private let gatewayClient: KnowledgeBaseGatewayClient
    private let session: URLSession
    private let browserPageCaptureService: BrowserPageCaptureProviding

    init(
        store: ReplyKnowledgeBaseStore = .shared,
        gatewayClient: KnowledgeBaseGatewayClient = .shared,
        session: URLSession = .shared,
        browserPageCaptureService: BrowserPageCaptureProviding = BrowserPageCaptureService()
    ) {
        self.store = store
        self.gatewayClient = gatewayClient
        self.session = session
        self.browserPageCaptureService = browserPageCaptureService
    }

    func run(request: SkillExecutionRequest) async -> SkillResultEnvelope {
        if !request.context.filePaths.isEmpty {
            return await runFileCollection(request: request)
        }
        return await runTextCollection(request: request)
    }

    func runStreaming(
        request: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async -> SkillResultEnvelope {
        if !request.context.filePaths.isEmpty {
            onEvent(.init(
                type: .status,
                status: "collect_prepare",
                detail: localized(
                    zhHans: "正在整理选中的文件并准备导入知识库。",
                    en: "Preparing the selected files for the knowledge base.",
                    languageCode: request.context.uiLanguage
                )
            ))
            onEvent(.init(
                type: .status,
                status: "collect_finalize",
                detail: localized(
                    zhHans: "正在生成文件知识条目并写入索引。",
                    en: "Creating file knowledge entries and writing the index.",
                    languageCode: request.context.uiLanguage
                )
            ))
            return await runFileCollection(request: request)
        }
        return await runTextCollectionStreaming(request: request, onEvent: onEvent)
    }

    private func runFileCollection(request: SkillExecutionRequest) async -> SkillResultEnvelope {
        let urls = request.context.filePaths.map { URL(fileURLWithPath: $0) }
        let result = await store.upsertFiles(urls: urls)
        let primaryEntry = (result.inserted + result.updated).first
        let successCount = result.inserted.count + result.updated.count
        let summary = successCount > 0
            ? L10n.format(
                languageCode: request.context.uiLanguage,
                zhHans: "已采集 %d 个文件到知识库。",
                en: "Collected %d file(s) into the knowledge base.",
                successCount
            )
            : localized(
                zhHans: "没有可采集的文件内容。",
                en: "No usable file content could be collected.",
                languageCode: request.context.uiLanguage
            )

        return makeSuccessEnvelope(
            summary: summary,
            result: result,
            sourceKind: "file",
            primaryEntry: primaryEntry,
            uiLanguage: request.context.uiLanguage
        )
    }

    private func runTextCollection(request: SkillExecutionRequest) async -> SkillResultEnvelope {
        let text = request.context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return makeFailureEnvelope(
                summary: localized(
                    zhHans: "没有检测到可采集的内容。",
                    en: "No usable content was detected to collect.",
                    languageCode: request.context.uiLanguage
                ),
                body: localized(
                    zhHans: "请先选中一段文本、一个独立 URL，或在 Finder 中选中文件。",
                    en: "Select some text, a standalone URL, or files in Finder first.",
                    languageCode: request.context.uiLanguage
                ),
                sourceKind: "text",
                failureKind: .emptyContent,
                fallbackFailureKind: nil
            )
        }

        if let detection = TextURLDetector.detect(in: text) {
            return await runURLCollection(url: detection.url, request: request)
        }

        return makeFailureEnvelope(
            summary: localized(
                zhHans: "普通文本采集已停用。",
                en: "Plain-text collection is no longer supported.",
                languageCode: request.context.uiLanguage
            ),
            body: localized(
                zhHans: "采集现在只支持链接和 Finder 文件选择。如果文本里包含链接，会优先采集该链接。",
                en: "Collect now supports links and Finder file selections. If the selected text contains a link, collect will capture that link first.",
                languageCode: request.context.uiLanguage
            ),
            sourceKind: "text",
            failureKind: .unsupportedFormat,
            fallbackFailureKind: nil
        )
    }

    private func runTextCollectionStreaming(
        request: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async -> SkillResultEnvelope {
        let text = request.context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return makeFailureEnvelope(
                summary: localized(
                    zhHans: "没有检测到可采集的内容。",
                    en: "No usable content was detected to collect.",
                    languageCode: request.context.uiLanguage
                ),
                body: localized(
                    zhHans: "请先选中一段文本、一个独立 URL，或在 Finder 中选中文件。",
                    en: "Select some text, a standalone URL, or files in Finder first.",
                    languageCode: request.context.uiLanguage
                ),
                sourceKind: "text",
                failureKind: .emptyContent,
                fallbackFailureKind: nil
            )
        }

        if let detection = TextURLDetector.detect(in: text) {
            return await runURLCollectionStreaming(url: detection.url, request: request, onEvent: onEvent)
        }

        return makeFailureEnvelope(
            summary: localized(
                zhHans: "普通文本采集已停用。",
                en: "Plain-text collection is no longer supported.",
                languageCode: request.context.uiLanguage
            ),
            body: localized(
                zhHans: "采集现在只支持链接和 Finder 文件选择。如果文本里包含链接，会优先采集该链接。",
                en: "Collect now supports links and Finder file selections. If the selected text contains a link, collect will capture that link first.",
                languageCode: request.context.uiLanguage
            ),
            sourceKind: "text",
            failureKind: .unsupportedFormat,
            fallbackFailureKind: nil
        )
    }

    private func runURLCollection(url: URL, request: SkillExecutionRequest) async -> SkillResultEnvelope {
        let httpResult = await fetchURLContent(url)
        switch httpResult {
        case .success(let fetched):
            let result = await store.collectURL(
                url,
                title: fetched.title,
                text: fetched.text,
                summaryOverride: nil,
                capturePipeline: fetched.capturePipeline,
                captureFailures: nil
            )
            let entry = (result.inserted + result.updated).first
            let summary = result.inserted.isEmpty
                ? localized(
                    zhHans: "已更新知识库中的网页条目。",
                    en: "Updated the web page entry in the knowledge base.",
                    languageCode: request.context.uiLanguage
                )
                : localized(
                    zhHans: "已抓取网页正文并采集到知识库。",
                    en: "Fetched the page content and collected it into the knowledge base.",
                    languageCode: request.context.uiLanguage
                )
            return makeSuccessEnvelope(
                summary: summary,
                result: result,
                sourceKind: "url",
                primaryEntry: entry,
                uiLanguage: request.context.uiLanguage
            )
        case .failure(let httpFailure):
            if httpFailure.kind == .authRequired {
                return makeFailureEnvelope(
                    summary: localized(
                        zhHans: "链接正文采集失败，未写入知识库。",
                        en: "Failed to collect readable page content, so nothing was written to the knowledge base.",
                        languageCode: request.context.uiLanguage
                    ),
                    body: failureBody(
                        for: url,
                        failure: httpFailure,
                        fallbackFailure: nil,
                        uiLanguage: request.context.uiLanguage
                    ),
                    sourceKind: "url",
                    failureKind: httpFailure.kind,
                    fallbackFailureKind: nil
                )
            }

            let browserFallback = await browserPageCaptureService.captureReadablePage(matching: url)
            switch browserFallback {
            case .success(let capture):
                let canonical = capture.canonicalURL ?? capture.pageURL
                let result = await store.collectURL(
                    canonical,
                    title: capture.title,
                    text: capture.text,
                    summaryOverride: nil,
                    capturePipeline: ["http_collect", "browser_capture", "normalize", "chunk"],
                    captureFailures: [httpFailure]
                )
                let entry = (result.inserted + result.updated).first
                let summary = localized(
                    zhHans: "已通过浏览器页面回退采集正文并写入知识库。",
                    en: "Collected the page through browser fallback and wrote it to the knowledge base.",
                    languageCode: request.context.uiLanguage
                )
                return makeSuccessEnvelope(
                    summary: summary,
                    result: result,
                    sourceKind: "url",
                    primaryEntry: entry,
                    uiLanguage: request.context.uiLanguage
                )
            case .failure(let browserFailure):
                return makeFailureEnvelope(
                    summary: localized(
                        zhHans: "链接正文采集失败，未写入知识库。",
                        en: "Failed to collect readable page content, so nothing was written to the knowledge base.",
                        languageCode: request.context.uiLanguage
                    ),
                    body: failureBody(
                        for: url,
                        failure: httpFailure,
                        fallbackFailure: browserFailure,
                        uiLanguage: request.context.uiLanguage
                    ),
                    sourceKind: "url",
                    failureKind: httpFailure.kind,
                    fallbackFailureKind: browserFailure.kind
                )
            }
        }
    }

    private func runURLCollectionStreaming(
        url: URL,
        request: SkillExecutionRequest,
        onEvent: @escaping (SkillRuntimeEvent) -> Void
    ) async -> SkillResultEnvelope {
        onEvent(.init(
            type: .status,
            status: "collect_fetch",
            detail: localized(
                zhHans: "正在抓取网页正文…",
                en: "Fetching readable page content…",
                languageCode: request.context.uiLanguage
            )
        ))
        onEvent(.init(
            type: .status,
            status: "collect_finalize",
            detail: localized(
                zhHans: "正在写入本地知识库…",
                en: "Writing to the local knowledge base…",
                languageCode: request.context.uiLanguage
            )
        ))
        return await runURLCollection(url: url, request: request)
    }

    private func makeSuccessEnvelope(
        summary: String,
        result: ReplyKnowledgeBaseBatchImportResult,
        sourceKind: String,
        primaryEntry: ReplyKnowledgeBaseEntry?,
        uiLanguage: String
    ) -> SkillResultEnvelope {
        let primaryAction = primaryEntry.flatMap {
            KnowledgeBaseSourceActionResolver.primaryAction(for: $0, languageCode: uiLanguage)
        }.map(KnowledgeBaseSourceActionResolver.skillResultAction)

        return SkillResultEnvelope(
            schemaVersion: "0.1",
            skillID: "collect",
            resultType: .summaryWithCards,
            summary: summary,
            body: successBody(
                result: result,
                primaryEntry: primaryEntry,
                sourceKind: sourceKind,
                uiLanguage: uiLanguage
            ),
            primaryAction: primaryAction,
            secondaryActions: nil,
            cards: resourceCards(
                result: result,
                uiLanguage: uiLanguage
            ),
            artifacts: [],
            copyPayload: nil,
            replacePayload: nil,
            followups: [],
            metadata: successMetadata(
                result: result,
                primaryEntry: primaryEntry,
                sourceKind: sourceKind,
                searchableDimensions: searchableDimensions(for: primaryEntry, uiLanguage: uiLanguage)
            )
        )
    }

    private func makeFailureEnvelope(
        summary: String,
        body: String,
        sourceKind: String,
        failureKind: KnowledgeBaseCaptureFailureKind,
        fallbackFailureKind: KnowledgeBaseCaptureFailureKind?
    ) -> SkillResultEnvelope {
        var metadata = [
            "inserted_count": "0",
            "updated_count": "0",
            "failed_count": "1",
            "source_kind": sourceKind,
            "failure_kind": failureKind.rawValue
        ]
        if let fallbackFailureKind {
            metadata["fallback_failure_kind"] = fallbackFailureKind.rawValue
        }
        return SkillResultEnvelope(
            schemaVersion: "0.1",
            skillID: "collect",
            resultType: .summaryWithCards,
            summary: summary,
            body: body,
            primaryAction: nil,
            secondaryActions: nil,
            cards: [],
            artifacts: [],
            copyPayload: nil,
            replacePayload: nil,
            followups: [],
            metadata: metadata
        )
    }

    private func successMetadata(
        result: ReplyKnowledgeBaseBatchImportResult,
        primaryEntry: ReplyKnowledgeBaseEntry?,
        sourceKind: String,
        searchableDimensions: [String]
    ) -> [String: String] {
        var metadata = [
            "inserted_count": String(result.inserted.count),
            "updated_count": String(result.updated.count),
            "failed_count": String(result.failures.count),
            "source_kind": sourceKind,
            "searchable_dimensions": searchableDimensions.joined(separator: ",")
        ]
        if let behavior = primaryEntry?.captureBehavior?.rawValue {
            metadata["capture_behavior"] = behavior
        }
        if let contentKind = primaryEntry?.contentKind?.rawValue {
            metadata["content_kind"] = contentKind
        }
        if let sourceActionKind = primaryEntry?.sourceActions?.first?.kind.rawValue {
            metadata["source_action_kind"] = sourceActionKind
        }
        return metadata
    }

    private func resourceCards(
        result: ReplyKnowledgeBaseBatchImportResult,
        uiLanguage: String
    ) -> [SkillResultCard] {
        let entries = result.inserted + result.updated
        guard !entries.isEmpty else { return [] }

        return entries.prefix(4).enumerated().compactMap { index, entry in
            guard let sourceAction = KnowledgeBaseSourceActionResolver.primaryAction(for: entry, languageCode: uiLanguage) else {
                return nil
            }
            let isUpdated = result.updated.contains(where: { $0.id == entry.id })
            return SkillResultCard(
                id: "collect_resource_\(index)",
                kind: "knowledge_base_source",
                title: displayTitle(for: entry),
                badges: [
                    sourceKindLabel(entry.sourceKind, uiLanguage: uiLanguage),
                    localized(
                        zhHans: isUpdated ? "已更新" : "已保存",
                        en: isUpdated ? "Updated" : "Saved",
                        languageCode: uiLanguage
                    )
                ],
                subtitle: secondaryReference(for: entry),
                description: resourceDescription(for: entry),
                action: KnowledgeBaseSourceActionResolver.skillResultAction(from: sourceAction),
                priority: index == 0 ? .primary : .secondary,
                isOfficial: nil
            )
        }
    }

    private func successBody(
        result: ReplyKnowledgeBaseBatchImportResult,
        primaryEntry: ReplyKnowledgeBaseEntry?,
        sourceKind: String,
        uiLanguage: String
    ) -> String {
        guard let primaryEntry else {
            return localized(
                zhHans: "没有生成可用的知识条目。",
                en: "No usable knowledge entry was produced.",
                languageCode: uiLanguage
            )
        }

        var lines: [String] = [
            L10n.format(
                languageCode: uiLanguage,
                zhHans: "已将“%@”保存到知识库。",
                en: "Saved “%@” to the knowledge base.",
                displayTitle(for: primaryEntry)
            )
        ]

        if let retention = primaryEntry.retentionScore {
            lines.append(
                L10n.format(
                    languageCode: uiLanguage,
                    zhHans: "正文保留率：%d%%。",
                    en: "Readable retention: %d%%.",
                    Int((retention * 100).rounded())
                )
            )
        }
        if let provenance = primaryEntry.provenanceQuality, !provenance.isEmpty {
            let quality = localizedProvenanceQuality(provenance, uiLanguage: uiLanguage)
            lines.append(
                L10n.format(
                    languageCode: uiLanguage,
                    zhHans: "来源可信度：%@。",
                    en: "Provenance quality: %@.",
                    quality
                )
            )
        }

        return lines.joined(separator: "\n")
    }

    private func displayTitle(for entry: ReplyKnowledgeBaseEntry) -> String {
        let trimmedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        if let externalURL = entry.externalURL, !externalURL.isEmpty {
            return externalURL
        }
        return entry.originalFilename
    }

    private func localizedProvenanceQuality(_ raw: String, uiLanguage: String) -> String {
        guard AppLanguage.from(languageCode: uiLanguage) != .english else {
            return raw
        }

        switch raw.lowercased() {
        case "strong":
            return "较高"
        case "medium":
            return "中等"
        case "weak":
            return "较弱"
        default:
            return raw
        }
    }

    private func secondaryReference(for entry: ReplyKnowledgeBaseEntry) -> String {
        if let rawURL = entry.canonicalURL ?? entry.externalURL,
           let host = URL(string: rawURL)?.host(percentEncoded: false),
           !host.isEmpty {
            return host
        }
        return entry.originalFilename
    }

    private func resourceDescription(for entry: ReplyKnowledgeBaseEntry) -> String {
        if let report = entry.ingestionReport,
           let preserved = report.preserved,
           !preserved.isEmpty {
            return preserved.prefix(3).joined(separator: " · ")
        }
        let summary = normalizedSummary(for: entry)
        if !summary.isEmpty {
            return summary
        }
        if entry.sourceKind == .url {
            return L10n.text(
                zhHans: "已保存网页来源，可在知识库中继续查看和管理。",
                en: "Saved this web source. You can keep managing it from the Knowledge Base."
            )
        }
        return L10n.text(
            zhHans: "已保存文件来源，可在知识库中继续查看和管理。",
            en: "Saved this file source. You can keep managing it from the Knowledge Base."
        )
    }

    private func normalizedSummary(for entry: ReplyKnowledgeBaseEntry) -> String {
        var summary = entry.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = displayTitle(for: entry)
        if !title.isEmpty, summary.hasPrefix(title) {
            summary.removeFirst(title.count)
            summary = summary.trimmingCharacters(in: CharacterSet(charactersIn: ":- \n\t"))
        }
        summary = summary.replacingOccurrences(of: "\n", with: " ")
        summary = summary.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(summary.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func failureBody(
        for url: URL,
        failure: KnowledgeBaseCaptureFailure,
        fallbackFailure: KnowledgeBaseCaptureFailure?,
        uiLanguage: String
    ) -> String {
        var lines: [String] = [
            L10n.format(
                languageCode: uiLanguage,
                zhHans: "无法采集 %@ 的可读正文，本次未写入知识库。",
                en: "Could not collect readable content from %@, so nothing was written to the knowledge base.",
                url.absoluteString
            ),
            L10n.format(
                languageCode: uiLanguage,
                zhHans: "失败类型：%@",
                en: "Failure type: %@",
                failureKindLabel(failure.kind, uiLanguage: uiLanguage)
            ),
            L10n.format(
                languageCode: uiLanguage,
                zhHans: "原因：%@",
                en: "Reason: %@",
                failure.message
            )
        ]

        if let fallbackFailure {
            lines.append(
                L10n.format(
                    languageCode: uiLanguage,
                    zhHans: "浏览器回退：%@",
                    en: "Browser fallback: %@",
                    fallbackFailure.message
                )
            )
        }

        lines.append(
            recoveryAdvice(
                for: failure.kind,
                fallbackFailureKind: fallbackFailure?.kind,
                uiLanguage: uiLanguage
            )
        )
        return lines.joined(separator: "\n")
    }

    private func searchableDimensions(for entry: ReplyKnowledgeBaseEntry?, uiLanguage: String) -> [String] {
        guard let entry else {
            return []
        }
        var dimensions: [String] = [
            localized(zhHans: "来源类型", en: "source", languageCode: uiLanguage),
            localized(zhHans: "内容类型", en: "content type", languageCode: uiLanguage),
            localized(zhHans: "语言", en: "language", languageCode: uiLanguage)
        ]
        if !(entry.topics ?? []).isEmpty {
            dimensions.append(localized(zhHans: "主题", en: "topics", languageCode: uiLanguage))
        }
        if !(entry.entities ?? []).isEmpty {
            dimensions.append(localized(zhHans: "实体", en: "entities", languageCode: uiLanguage))
        }
        if entry.captureBehavior != nil {
            dimensions.append(localized(zhHans: "采集行为", en: "behavior", languageCode: uiLanguage))
        }
        return dimensions
    }

    private func sourceKindLabel(_ sourceKind: ReplyKnowledgeBaseSourceKind?, uiLanguage: String) -> String {
        switch sourceKind {
        case .file:
            return localized(zhHans: "文件", en: "File", languageCode: uiLanguage)
        case .url:
            return localized(zhHans: "网页", en: "Web Page", languageCode: uiLanguage)
        case .notion:
            return "Notion"
        case .selectionText:
            return localized(zhHans: "文本", en: "Text", languageCode: uiLanguage)
        case nil:
            return localized(zhHans: "未知", en: "Unknown", languageCode: uiLanguage)
        }
    }

    private func sourceKindLabel(
        _ sourceKind: ReplyKnowledgeBaseSourceKind?,
        fallbackSourceKind: String,
        uiLanguage: String
    ) -> String {
        if let sourceKind {
            return sourceKindLabel(sourceKind, uiLanguage: uiLanguage)
        }
        return sourceKindLabel(fallbackSourceKind, uiLanguage: uiLanguage)
    }

    private func sourceKindLabel(_ sourceKind: String, uiLanguage: String) -> String {
        switch sourceKind {
        case "file":
            return localized(zhHans: "文件", en: "File", languageCode: uiLanguage)
        case "url":
            return localized(zhHans: "网页", en: "Web Page", languageCode: uiLanguage)
        default:
            return localized(zhHans: "文本", en: "Text", languageCode: uiLanguage)
        }
    }

    private func failureKindLabel(_ kind: KnowledgeBaseCaptureFailureKind, uiLanguage: String) -> String {
        switch kind {
        case .networkFailed:
            return localized(zhHans: "网络失败", en: "Network Failure", languageCode: uiLanguage)
        case .authRequired:
            return localized(zhHans: "需要登录", en: "Authentication Required", languageCode: uiLanguage)
        case .unsupportedDynamicPage:
            return localized(zhHans: "动态页面暂不支持", en: "Dynamic Page Unsupported", languageCode: uiLanguage)
        case .noReadableContent:
            return localized(zhHans: "没有可读正文", en: "No Readable Content", languageCode: uiLanguage)
        case .browserCaptureUnavailable:
            return localized(zhHans: "浏览器回退不可用", en: "Browser Fallback Unavailable", languageCode: uiLanguage)
        case .parsingFailed:
            return localized(zhHans: "解析失败", en: "Parsing Failed", languageCode: uiLanguage)
        case .unsupportedFormat:
            return localized(zhHans: "格式不支持", en: "Unsupported Format", languageCode: uiLanguage)
        case .emptyContent:
            return localized(zhHans: "内容为空", en: "Empty Content", languageCode: uiLanguage)
        }
    }

    private func recoveryAdvice(
        for kind: KnowledgeBaseCaptureFailureKind,
        fallbackFailureKind: KnowledgeBaseCaptureFailureKind?,
        uiLanguage: String
    ) -> String {
        switch kind {
        case .authRequired:
            return localized(
                zhHans: "恢复建议：请先确认页面可公开访问，或把需要保留的内容另存为文件后再采集。",
                en: "Try making sure the page is publicly accessible, or save the content as a file before collecting it.",
                languageCode: uiLanguage
            )
        case .unsupportedDynamicPage:
            if fallbackFailureKind == .browserCaptureUnavailable {
                return localized(
                    zhHans: "恢复建议：请在支持的浏览器中打开该页面后重试，或保存页面内容为文件后再采集。",
                    en: "Open the page in a supported browser and try again, or save the page content as a file before collecting it.",
                    languageCode: uiLanguage
                )
            }
            return localized(
                zhHans: "恢复建议：这个页面更像动态应用，请改为在支持的浏览器中打开后重试，或导出为文件再采集。",
                en: "This page behaves like a dynamic app, so open it in a supported browser and try again, or export it as a file before collecting it.",
                languageCode: uiLanguage
            )
        case .noReadableContent:
            return localized(
                zhHans: "恢复建议：请确认页面里确实有可读正文，或将需要的内容保存成文件后再采集。",
                en: "Confirm that the page actually contains readable text, or save the needed content as a file before collecting it.",
                languageCode: uiLanguage
            )
        case .networkFailed:
            return localized(
                zhHans: "恢复建议：请稍后重试；如果这是重要资料，也可以先保存成文件再采集。",
                en: "Try again later; if the material matters, you can also save it as a file and collect that instead.",
                languageCode: uiLanguage
            )
        default:
            return localized(
                zhHans: "恢复建议：请稍后重试，或改为采集可解析的链接与文件。",
                en: "Try again later, or collect a supported link or file instead.",
                languageCode: uiLanguage
            )
        }
    }

    private func fetchURLContent(_ url: URL) async -> Result<FetchedURLContent, KnowledgeBaseCaptureFailure> {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("text/html, text/plain;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("NexHub/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(
                    KnowledgeBaseCaptureFailure(
                        kind: .networkFailed,
                        message: localized(zhHans: "服务没有返回有效的 HTTP 响应。", en: "The server did not return a valid HTTP response.", languageCode: "zh")
                    )
                )
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(
                    KnowledgeBaseCaptureFailure(
                        kind: .authRequired,
                        message: "HTTP \(http.statusCode)"
                    )
                )
            }

            guard (200..<300).contains(http.statusCode) else {
                return .failure(
                    KnowledgeBaseCaptureFailure(
                        kind: .networkFailed,
                        message: "HTTP \(http.statusCode)"
                    )
                )
            }

            let mimeType = (response.mimeType ?? "").lowercased()
            if mimeType.contains("text/plain"), let text = decodedString(from: data) {
                let normalized = normalizeFetchedText(text)
                guard !normalized.isEmpty else {
                    return .failure(
                        KnowledgeBaseCaptureFailure(
                            kind: .noReadableContent,
                            message: L10n.text(zhHans: "页面返回了文本，但没有可采集的正文。", en: "The page returned text, but no readable body content was found.")
                        )
                    )
                }
                return .success(
                    FetchedURLContent(
                        title: url.host ?? url.absoluteString,
                        text: normalized,
                        capturePipeline: ["http_collect", "text_plain", "normalize", "chunk"]
                    )
                )
            }

            let html = decodedString(from: data) ?? String(decoding: data, as: UTF8.self)
            let title = htmlTitle(from: html) ?? url.host ?? url.absoluteString
            let readable = extractReadableText(fromHTMLData: data)
            let normalized = normalizeFetchedText(readable)
            if !normalized.isEmpty {
                return .success(
                    FetchedURLContent(
                        title: title,
                        text: normalized,
                        capturePipeline: ["http_collect", "html_extract", "normalize", "chunk"]
                    )
                )
            }

            let dynamicKind = looksLikeDynamicPage(html) ? KnowledgeBaseCaptureFailureKind.unsupportedDynamicPage : .noReadableContent
            let message = dynamicKind == .unsupportedDynamicPage
                ? L10n.text(zhHans: "页面主要依赖前端运行时渲染，HTTP 抓取没有得到稳定正文。", en: "The page appears to rely on client-side rendering, so HTTP capture did not produce stable readable content.")
                : L10n.text(zhHans: "页面返回成功，但没有提取到可读正文。", en: "The page loaded successfully, but no readable body content could be extracted.")
            return .failure(KnowledgeBaseCaptureFailure(kind: dynamicKind, message: message))
        } catch {
            return .failure(
                KnowledgeBaseCaptureFailure(
                    kind: .networkFailed,
                    message: error.localizedDescription
                )
            )
        }
    }

    private func decodedString(from data: Data) -> String? {
        for encoding in [String.Encoding.utf8, .unicode, .utf16LittleEndian, .utf16BigEndian, .ascii] {
            if let string = String(data: data, encoding: encoding) {
                return string
            }
        }
        return nil
    }

    private func extractReadableText(fromHTMLData data: Data) -> String {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ) else {
            return ""
        }
        return attributed.string
    }

    private func htmlTitle(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let title = html[range].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func looksLikeDynamicPage(_ html: String) -> Bool {
        let lowered = html.lowercased()
        let scriptCount = lowered.components(separatedBy: "<script").count - 1
        let nextMarkers = ["__next", "data-reactroot", "id=\"app\"", "id=\"root\"", "chunk.js", "webpack"]
        return scriptCount >= 8 || nextMarkers.contains(where: lowered.contains)
    }

    private func normalizeFetchedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func localized(zhHans: String, en: String, languageCode: String) -> String {
        L10n.text(languageCode: languageCode, zhHans: zhHans, en: en)
    }
}

private struct FetchedURLContent {
    let title: String
    let text: String
    let capturePipeline: [String]
}
