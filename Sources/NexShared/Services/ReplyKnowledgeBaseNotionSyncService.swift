import Foundation

struct ReplyKnowledgeBaseNotionSyncSummary {
    let importedCount: Int
    let updatedCount: Int
    let skippedCount: Int
    let failureMessages: [String]
}

final class ReplyKnowledgeBaseNotionSyncService {
    static let shared = ReplyKnowledgeBaseNotionSyncService()
    private static let notionAPIVersion = "2025-09-03"

    private let session: URLSession
    private let settings: AppSettings
    private let store: ReplyKnowledgeBaseStore

    init(
        session: URLSession = .shared,
        settings: AppSettings = .shared,
        store: ReplyKnowledgeBaseStore = .shared
    ) {
        self.session = session
        self.settings = settings
        self.store = store
    }

    func syncRecentSharedPages(limit: Int = 12) async throws -> ReplyKnowledgeBaseNotionSyncSummary {
        let token = settings.notionIntegrationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ReplyKnowledgeBaseNotionError.missingToken
        }

        let pages = try await fetchRecentPages(token: token, limit: limit)
        return try await syncPages(pages, token: token)
    }

    func syncIncrementalPages(since: Date?, bootstrapLimit: Int = 12) async throws -> ReplyKnowledgeBaseNotionSyncSummary {
        let token = settings.notionIntegrationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ReplyKnowledgeBaseNotionError.missingToken
        }

        let pages: [NotionPageSummary]
        if let since {
            pages = try await fetchPagesEdited(after: since, token: token)
        } else {
            pages = try await fetchRecentPages(token: token, limit: bootstrapLimit)
        }
        return try await syncPages(pages, token: token)
    }

    private func syncPages(_ pages: [NotionPageSummary], token: String) async throws -> ReplyKnowledgeBaseNotionSyncSummary {
        guard !pages.isEmpty else {
            return ReplyKnowledgeBaseNotionSyncSummary(importedCount: 0, updatedCount: 0, skippedCount: 0, failureMessages: [])
        }

        var documents: [ReplyKnowledgeBaseNotionDocument] = []
        var failures: [ReplyKnowledgeBaseImportFailure] = []

        for page in pages {
            do {
                let pagePayload = try await notionRequest(
                    path: "/v1/pages/\(page.id)",
                    token: token,
                    method: "GET",
                    jsonBody: nil
                )
                let text = try await fetchPageText(pageID: page.id, token: token, pagePayload: pagePayload)
                documents.append(
                    ReplyKnowledgeBaseNotionDocument(
                        sourceIdentifier: page.id,
                        title: page.title,
                        pageURL: page.url,
                        plainText: text,
                        lastEditedAt: page.lastEditedAt,
                        sourceLabel: "Notion"
                    )
                )
            } catch {
                failures.append(.init(fileName: page.title, reason: error.localizedDescription))
            }
        }

        let syncResult = await store.syncNotionDocuments(documents)
        let mergedFailures = (syncResult.failures + failures).map { "\($0.fileName)：\($0.reason)" }
        return ReplyKnowledgeBaseNotionSyncSummary(
            importedCount: syncResult.imported.count,
            updatedCount: syncResult.updated.count,
            skippedCount: syncResult.skippedCount,
            failureMessages: mergedFailures
        )
    }

    private func fetchRecentPages(token: String, limit: Int) async throws -> [NotionPageSummary] {
        guard limit > 0 else { return [] }
        var pages: [NotionPageSummary] = []
        var cursor: String?

        while pages.count < limit {
            let response = try await searchPages(token: token, pageSize: min(25, limit - pages.count), startCursor: cursor)
            if response.pages.isEmpty {
                break
            }
            pages.append(contentsOf: response.pages)
            guard response.hasMore, let nextCursor = response.nextCursor else {
                break
            }
            cursor = nextCursor
        }

        return Array(pages.prefix(limit))
    }

    private func parseConfiguredTargets() -> [NotionSyncTarget] {
        settings.knowledgeBaseNotionTargets
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(NotionSyncTarget.init(rawValue:))
    }

    private func fetchPagesEdited(after date: Date, token: String, hardLimit: Int = 48) async throws -> [NotionPageSummary] {
        var pages: [NotionPageSummary] = []
        var seenIDs: Set<String> = []
        var cursor: String?
        var shouldContinue = true

        while shouldContinue, pages.count < hardLimit {
            let response = try await searchPages(token: token, pageSize: 25, startCursor: cursor)
            if response.pages.isEmpty {
                break
            }

            for page in response.pages {
                if page.lastEditedAt <= date {
                    shouldContinue = false
                    break
                }
                guard seenIDs.insert(page.id).inserted else { continue }
                pages.append(page)
                if pages.count >= hardLimit {
                    shouldContinue = false
                    break
                }
            }

            guard shouldContinue, response.hasMore, let nextCursor = response.nextCursor else {
                break
            }
            cursor = nextCursor
        }

        return pages
    }

    private func fetchPagesForTargets(
        _ targets: [NotionSyncTarget],
        since: Date?,
        token: String
    ) async throws -> (pages: [NotionPageSummary], failures: [String]) {
        var pagesByID: [String: NotionPageSummary] = [:]
        var failures: [String] = []

        for target in targets {
            do {
                let resolvedTarget = try await resolveTarget(target, token: token)
                let pages: [NotionPageSummary]
                switch resolvedTarget.kind {
                case .page:
                    let page = try await fetchPageSummary(pageID: resolvedTarget.id, token: token)
                    pages = (since == nil || page.lastEditedAt > (since ?? .distantPast)) ? [page] : []
                case .database:
                    pages = try await fetchPagesForDatabase(databaseID: resolvedTarget.id, since: since, token: token)
                case .dataSource:
                    pages = try await fetchPagesForDataSource(dataSourceID: resolvedTarget.id, since: since, token: token)
                }

                for page in pages {
                    if let current = pagesByID[page.id], current.lastEditedAt >= page.lastEditedAt {
                        continue
                    }
                    pagesByID[page.id] = page
                }
            } catch {
                failures.append("\(target.displayName)：\(error.localizedDescription)")
            }
        }

        let sortedPages = pagesByID.values.sorted { lhs, rhs in
            if lhs.lastEditedAt == rhs.lastEditedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.lastEditedAt > rhs.lastEditedAt
        }
        return (sortedPages, failures)
    }

    private func searchPages(token: String, pageSize: Int, startCursor: String?) async throws -> NotionSearchResponse {
        var payload: [String: Any] = [
            "filter": [
                "property": "object",
                "value": "page"
            ],
            "sort": [
                "direction": "descending",
                "timestamp": "last_edited_time"
            ],
            "page_size": max(1, min(pageSize, 25))
        ]
        if let startCursor, !startCursor.isEmpty {
            payload["start_cursor"] = startCursor
        }

        let response = try await notionRequest(
            path: "/v1/search",
            token: token,
            method: "POST",
            jsonBody: payload
        )
        guard let results = response["results"] as? [[String: Any]] else {
            return NotionSearchResponse(pages: [], hasMore: false, nextCursor: nil)
        }
        return NotionSearchResponse(
            pages: results.compactMap(parsePageSummary),
            hasMore: (response["has_more"] as? Bool) == true,
            nextCursor: response["next_cursor"] as? String
        )
    }

    private func fetchPageText(pageID: String, token: String, pagePayload: [String: Any]? = nil) async throws -> String {
        let payload: [String: Any]
        if let pagePayload {
            payload = pagePayload
        } else {
            payload = try await notionRequest(
                path: "/v1/pages/\(pageID)",
                token: token,
                method: "GET",
                jsonBody: nil
            )
        }
        let propertyLines = pagePropertyLines(from: payload)
        let blockLines = try await fetchBlockChildrenRecursively(blockID: pageID, token: token, depth: 0)
        let joined = (propertyLines + blockLines).joined(separator: "\n")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchBlockChildrenRecursively(blockID: String, token: String, depth: Int) async throws -> [String] {
        let response = try await notionRequest(
            path: "/v1/blocks/\(blockID)/children?page_size=100",
            token: token,
            method: "GET",
            jsonBody: nil
        )

        guard let results = response["results"] as? [[String: Any]] else { return [] }
        var lines: [String] = []

        for block in results {
            if let line = blockPlainText(block), !line.isEmpty {
                lines.append(String(repeating: "  ", count: min(depth, 3)) + line)
            }
            if (block["has_children"] as? Bool) == true, let childID = block["id"] as? String {
                let childLines = try await fetchBlockChildrenRecursively(blockID: childID, token: token, depth: depth + 1)
                if !childLines.isEmpty {
                    lines.append(contentsOf: childLines)
                }
            }
        }

        return lines
    }

    private func resolveTarget(_ target: NotionSyncTarget, token: String) async throws -> NotionResolvedTarget {
        guard let normalizedID = normalizeNotionID(from: target.rawValue) else {
            throw ReplyKnowledgeBaseNotionError.invalidTarget
        }

        if let pagePayload = try await notionRequestIfExists(
            path: "/v1/pages/\(normalizedID)",
            token: token,
            method: "GET",
            jsonBody: nil
        ),
           (pagePayload["object"] as? String) == "page" {
            return NotionResolvedTarget(id: normalizedID, kind: .page)
        }

        if let dataSourcePayload = try await notionRequestIfExists(
            path: "/v1/data_sources/\(normalizedID)",
            token: token,
            method: "GET",
            jsonBody: nil
        ),
           (dataSourcePayload["object"] as? String) == "data_source" {
            return NotionResolvedTarget(id: normalizedID, kind: .dataSource)
        }

        if let databasePayload = try await notionRequestIfExists(
            path: "/v1/databases/\(normalizedID)",
            token: token,
            method: "GET",
            jsonBody: nil
        ),
           (databasePayload["object"] as? String) == "database" {
            return NotionResolvedTarget(id: normalizedID, kind: .database)
        }

        throw ReplyKnowledgeBaseNotionError.targetNotFound
    }

    private func normalizeNotionID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let source = trimmed.lowercased()
        let pattern = "[0-9a-f]{32}"
        if let match = source.range(of: pattern, options: .regularExpression) {
            return hyphenatedNotionID(String(source[match]))
        }

        let compact = source.replacingOccurrences(of: "-", with: "")
        guard compact.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return hyphenatedNotionID(compact)
    }

    private func hyphenatedNotionID(_ compactID: String) -> String {
        let clean = compactID.replacingOccurrences(of: "-", with: "")
        guard clean.count == 32 else { return compactID }
        return [
            String(clean.prefix(8)),
            String(clean.dropFirst(8).prefix(4)),
            String(clean.dropFirst(12).prefix(4)),
            String(clean.dropFirst(16).prefix(4)),
            String(clean.dropFirst(20))
        ].joined(separator: "-")
    }

    private func fetchPageSummary(pageID: String, token: String) async throws -> NotionPageSummary {
        let payload = try await notionRequest(
            path: "/v1/pages/\(pageID)",
            token: token,
            method: "GET",
            jsonBody: nil
        )
        guard let summary = parsePageSummary(payload) else {
            throw ReplyKnowledgeBaseNotionError.invalidResponse
        }
        return summary
    }

    private func fetchPagesForDatabase(databaseID: String, since: Date?, token: String) async throws -> [NotionPageSummary] {
        let payload = try await notionRequest(
            path: "/v1/databases/\(databaseID)",
            token: token,
            method: "GET",
            jsonBody: nil
        )

        let dataSourceIDs = (payload["data_sources"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        if !dataSourceIDs.isEmpty {
            var pages: [NotionPageSummary] = []
            for dataSourceID in dataSourceIDs {
                pages.append(contentsOf: try await fetchPagesForDataSource(dataSourceID: dataSourceID, since: since, token: token))
            }
            return dedupPageSummaries(pages)
        }

        return try await fetchPagesForLegacyDatabaseQuery(databaseID: databaseID, since: since, token: token)
    }

    private func fetchPagesForDataSource(dataSourceID: String, since: Date?, token: String, hardLimit: Int = 64) async throws -> [NotionPageSummary] {
        var pages: [NotionPageSummary] = []
        var cursor: String?
        var shouldContinue = true

        while shouldContinue, pages.count < hardLimit {
            var body: [String: Any] = [
                "page_size": min(25, hardLimit - pages.count),
                "sorts": [
                    [
                        "timestamp": "last_edited_time",
                        "direction": "descending"
                    ]
                ],
                "result_type": "page"
            ]
            if let cursor, !cursor.isEmpty {
                body["start_cursor"] = cursor
            }

            let response = try await notionRequest(
                path: "/v1/data_sources/\(dataSourceID)/query",
                token: token,
                method: "POST",
                jsonBody: body
            )
            let resultPayloads = response["results"] as? [[String: Any]] ?? []
            if resultPayloads.isEmpty {
                break
            }

            for resultPayload in resultPayloads {
                guard let summary = parsePageSummary(resultPayload) else { continue }
                if let since, summary.lastEditedAt <= since {
                    shouldContinue = false
                    break
                }
                pages.append(summary)
                if pages.count >= hardLimit {
                    shouldContinue = false
                    break
                }
            }

            guard shouldContinue,
                  (response["has_more"] as? Bool) == true,
                  let nextCursor = response["next_cursor"] as? String else {
                break
            }
            cursor = nextCursor
        }

        return dedupPageSummaries(pages)
    }

    private func fetchPagesForLegacyDatabaseQuery(databaseID: String, since: Date?, token: String, hardLimit: Int = 64) async throws -> [NotionPageSummary] {
        var pages: [NotionPageSummary] = []
        var cursor: String?
        var shouldContinue = true

        while shouldContinue, pages.count < hardLimit {
            var body: [String: Any] = [
                "page_size": min(25, hardLimit - pages.count),
                "sorts": [
                    [
                        "timestamp": "last_edited_time",
                        "direction": "descending"
                    ]
                ]
            ]
            if let cursor, !cursor.isEmpty {
                body["start_cursor"] = cursor
            }
            guard let response = try await notionRequestIfExists(
                path: "/v1/databases/\(databaseID)/query",
                token: token,
                method: "POST",
                jsonBody: body
            ) else {
                return []
            }

            let resultPayloads = response["results"] as? [[String: Any]] ?? []
            if resultPayloads.isEmpty {
                break
            }

            for resultPayload in resultPayloads {
                guard let summary = parsePageSummary(resultPayload) else { continue }
                if let since, summary.lastEditedAt <= since {
                    shouldContinue = false
                    break
                }
                pages.append(summary)
                if pages.count >= hardLimit {
                    shouldContinue = false
                    break
                }
            }

            guard shouldContinue,
                  (response["has_more"] as? Bool) == true,
                  let nextCursor = response["next_cursor"] as? String else {
                break
            }
            cursor = nextCursor
        }

        return dedupPageSummaries(pages)
    }

    private func dedupPageSummaries(_ pages: [NotionPageSummary]) -> [NotionPageSummary] {
        var pageMap: [String: NotionPageSummary] = [:]
        for page in pages {
            if let existing = pageMap[page.id], existing.lastEditedAt >= page.lastEditedAt {
                continue
            }
            pageMap[page.id] = page
        }
        return pageMap.values.sorted { lhs, rhs in
            if lhs.lastEditedAt == rhs.lastEditedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.lastEditedAt > rhs.lastEditedAt
        }
    }

    private func notionRequestIfExists(
        path: String,
        token: String,
        method: String,
        jsonBody: [String: Any]?
    ) async throws -> [String: Any]? {
        let response = try await performNotionRequest(path: path, token: token, method: method, jsonBody: jsonBody)
        if response.statusCode == 404 {
            return nil
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ReplyKnowledgeBaseNotionError.unauthorized
        }
        if response.statusCode == 429 {
            throw ReplyKnowledgeBaseNotionError.rateLimited
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ReplyKnowledgeBaseNotionError.requestFailed
        }
        return response.json
    }

    private func notionRequest(
        path: String,
        token: String,
        method: String,
        jsonBody: [String: Any]?
    ) async throws -> [String: Any] {
        let response = try await performNotionRequest(path: path, token: token, method: method, jsonBody: jsonBody)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ReplyKnowledgeBaseNotionError.unauthorized
        }
        if response.statusCode == 429 {
            throw ReplyKnowledgeBaseNotionError.rateLimited
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ReplyKnowledgeBaseNotionError.requestFailed
        }
        return response.json
    }

    private func performNotionRequest(
        path: String,
        token: String,
        method: String,
        jsonBody: [String: Any]?
    ) async throws -> NotionHTTPResponse {
        guard let url = URL(string: "https://api.notion.com\(path)") else {
            throw ReplyKnowledgeBaseNotionError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.notionAPIVersion, forHTTPHeaderField: "Notion-Version")
        let requestBody: Data?
        if let jsonBody {
            requestBody = try JSONSerialization.data(withJSONObject: jsonBody)
            request.httpBody = requestBody
        } else {
            requestBody = nil
        }

        do {
            let (data, response) = try await session.data(for: request)
            return try parseNotionResponse(data: data, response: response)
        } catch {
            throw normalizeTransportError(error)
        }
    }

    private func parseNotionResponse(data: Data, response: URLResponse) throws -> NotionHTTPResponse {
        guard let http = response as? HTTPURLResponse else {
            throw ReplyKnowledgeBaseNotionError.invalidResponse
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ReplyKnowledgeBaseNotionError.invalidResponse
        }
        return NotionHTTPResponse(statusCode: http.statusCode, json: object)
    }

    private func normalizeTransportError(_ error: Error) -> Error {
        if let notionError = error as? ReplyKnowledgeBaseNotionError {
            return notionError
        }
        return ReplyKnowledgeBaseNotionError.transportError(error.localizedDescription)
    }

    private func parsePageSummary(_ payload: [String: Any]) -> NotionPageSummary? {
        guard let id = payload["id"] as? String,
              let url = payload["url"] as? String else {
            return nil
        }
        let title = notionPageTitle(from: payload) ?? "Untitled"
        let lastEditedAt: Date
        if let raw = payload["last_edited_time"] as? String,
           let parsed = ISO8601DateFormatter().date(from: raw) {
            lastEditedAt = parsed
        } else {
            lastEditedAt = Date()
        }
        return NotionPageSummary(id: id, title: title, url: url, lastEditedAt: lastEditedAt)
    }

    private func notionPageTitle(from payload: [String: Any]) -> String? {
        if let properties = payload["properties"] as? [String: Any] {
            for (_, value) in properties {
                guard let property = value as? [String: Any],
                      let type = property["type"] as? String,
                      type == "title",
                      let titleArray = property["title"] as? [[String: Any]] else { continue }
                let title = richTextPlainText(from: titleArray)
                if !title.isEmpty {
                    return title
                }
            }
        }
        if let childPage = payload["child_page"] as? [String: Any],
           let title = childPage["title"] as? String,
           !title.isEmpty {
            return title
        }
        return nil
    }

    private func blockPlainText(_ block: [String: Any]) -> String? {
        guard let type = block["type"] as? String else { return nil }
        guard let content = block[type] as? [String: Any] else { return nil }

        if let richText = content["rich_text"] as? [[String: Any]] {
            let text = richTextPlainText(from: richText)
            if !text.isEmpty {
                return prefixedText(text, type: type, content: content)
            }
        }

        if let caption = content["caption"] as? [[String: Any]] {
            let text = richTextPlainText(from: caption)
            if !text.isEmpty {
                return text
            }
        }

        if type == "child_page", let title = content["title"] as? String, !title.isEmpty {
            return title
        }
        return nil
    }

    private func pagePropertyLines(from payload: [String: Any]) -> [String] {
        guard let properties = payload["properties"] as? [String: Any] else { return [] }
        var lines: [String] = []

        for (_, rawValue) in properties {
            guard let property = rawValue as? [String: Any],
                  let name = property["name"] as? String,
                  let type = property["type"] as? String else {
                continue
            }

            let text: String?
            switch type {
            case "title":
                let items = property["title"] as? [[String: Any]] ?? []
                text = richTextPlainText(from: items)
            case "rich_text":
                let items = property["rich_text"] as? [[String: Any]] ?? []
                text = richTextPlainText(from: items)
            case "select":
                text = (property["select"] as? [String: Any])?["name"] as? String
            case "multi_select":
                let items = property["multi_select"] as? [[String: Any]] ?? []
                text = items.compactMap { $0["name"] as? String }.joined(separator: " / ")
            case "status":
                text = (property["status"] as? [String: Any])?["name"] as? String
            case "url":
                text = property["url"] as? String
            case "email":
                text = property["email"] as? String
            case "phone_number":
                text = property["phone_number"] as? String
            case "date":
                if let date = property["date"] as? [String: Any] {
                    let start = date["start"] as? String ?? ""
                    let end = date["end"] as? String ?? ""
                    text = [start, end].filter { !$0.isEmpty }.joined(separator: " - ")
                } else {
                    text = nil
                }
            case "number":
                if let number = property["number"] as? NSNumber {
                    text = number.stringValue
                } else {
                    text = nil
                }
            case "checkbox":
                if let checked = property["checkbox"] as? Bool {
                    text = checked
                        ? L10n.text(zhHans: "是", en: "Yes")
                        : L10n.text(zhHans: "否", en: "No")
                } else {
                    text = nil
                }
            default:
                text = nil
            }

            let compact = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !compact.isEmpty else { continue }
            lines.append("\(name)：\(compact)")
        }

        return lines
    }

    private func richTextPlainText(from items: [[String: Any]]) -> String {
        items.compactMap { item in
            if let plainText = item["plain_text"] as? String {
                return plainText
            }
            return nil
        }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prefixedText(_ text: String, type: String, content: [String: Any]) -> String {
        switch type {
        case "bulleted_list_item":
            return "• \(text)"
        case "numbered_list_item":
            return "1. \(text)"
        case "to_do":
            let checked = (content["checked"] as? Bool) == true ? "[x]" : "[ ]"
            return "\(checked) \(text)"
        case "quote":
            return "“\(text)”"
        case "code":
            return L10n.format(zhHans: "代码：%@", en: "Code: %@", text)
        case "heading_1", "heading_2", "heading_3":
            return text
        default:
            return text
        }
    }
}

private struct NotionPageSummary {
    let id: String
    let title: String
    let url: String
    let lastEditedAt: Date
}

private struct NotionSyncTarget {
    let rawValue: String

    var displayName: String { rawValue }
}

private struct NotionResolvedTarget {
    enum Kind {
        case page
        case database
        case dataSource
    }

    let id: String
    let kind: Kind
}

private struct NotionSearchResponse {
    let pages: [NotionPageSummary]
    let hasMore: Bool
    let nextCursor: String?
}

private struct NotionHTTPResponse {
    let statusCode: Int
    let json: [String: Any]
}

enum ReplyKnowledgeBaseNotionError: LocalizedError {
    case missingToken
    case unauthorized
    case rateLimited
    case requestFailed
    case invalidResponse
    case invalidTarget
    case targetNotFound
    case transportError(String?)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return L10n.text(zhHans: "请先填写 Notion Integration Token。", en: "Enter a Notion Integration Token first.")
        case .unauthorized:
            return L10n.text(zhHans: "Notion 鉴权失败，请检查 Token 是否正确，以及页面是否已共享给该 Integration。", en: "Notion authentication failed. Check that the token is correct and the page is shared with this integration.")
        case .rateLimited:
            return L10n.text(zhHans: "Notion 请求过于频繁，请稍后再试。", en: "Notion is rate limiting requests. Please try again later.")
        case .requestFailed:
            return L10n.text(zhHans: "Notion 同步失败，请稍后重试。", en: "Notion sync failed. Please try again shortly.")
        case .invalidResponse:
            return L10n.text(zhHans: "Notion 返回内容无法解析。", en: "The Notion response could not be parsed.")
        case .invalidTarget:
            return L10n.text(zhHans: "这个 Notion 页面或数据库链接无法识别，请直接粘贴页面/数据库链接。", en: "This Notion page or database link could not be recognized. Paste the direct page or database link instead.")
        case .targetNotFound:
            return L10n.text(zhHans: "没有找到这个 Notion 页面或数据库，请确认它已经共享给当前 Integration。", en: "The Notion page or database could not be found. Make sure it has been shared with the current integration.")
        case .transportError(let detail):
            let normalized = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if normalized.isEmpty {
                return L10n.text(zhHans: "Notion 连接失败，请检查当前网络、代理或防火墙后重试。", en: "Notion connection failed. Check your network, proxy, or firewall and try again.")
            }
            return L10n.format(zhHans: "Notion 连接失败，请检查当前网络、代理或防火墙后重试。\n%@", en: "Notion connection failed. Check your network, proxy, or firewall and try again.\n%@", normalized)
        }
    }
}
