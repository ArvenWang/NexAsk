import Foundation

struct KnowledgeBaseImportURLStreamEvent {
    let status: String?
    let detail: String?
}

final class KnowledgeBaseGatewayClient {
    static let shared = KnowledgeBaseGatewayClient()

    private let session: URLSession
    private let baseURLProvider: () -> String
    private let encoder = JSONEncoder()

    init(
        session: URLSession = .shared,
        baseURLProvider: @escaping () -> String = {
            ProcessInfo.processInfo.environment["NEXHUB_API_BASE"] ?? "http://127.0.0.1:8787"
        }
    ) {
        self.session = session
        self.baseURLProvider = baseURLProvider
        self.encoder.dateEncodingStrategy = .iso8601
    }

    func listSources(sourceKind: ReplyKnowledgeBaseSourceKind? = nil, query: String? = nil) -> [ReplyKnowledgeBaseEntry] {
        GatewayRuntimeManager.shared.startIfNeeded()
        var components = baseComponents(path: "/v1/kb/sources")
        var queryItems: [URLQueryItem] = []
        if let sourceKind {
            queryItems.append(.init(name: "source_type", value: sourceKind.rawValue))
        }
        if let query, !query.isEmpty {
            queryItems.append(.init(name: "query", value: query))
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let requestURL = components.url else { return [] }
        let response: SourcesResponse? = performSync(request: makeRequest(url: requestURL, method: "GET"))
        return response?.entries ?? []
    }

    func source(id: String) -> ReplyKnowledgeBaseEntry? {
        GatewayRuntimeManager.shared.startIfNeeded()
        guard let url = baseComponents(path: "/v1/kb/sources/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)").url else {
            return nil
        }
        let response: SourceResponse? = performSync(request: makeRequest(url: url, method: "GET"))
        return response?.entry
    }

    func sourceSnapshot(id: String, kind: String = "readable") -> KnowledgeBaseSnapshot? {
        GatewayRuntimeManager.shared.startIfNeeded()
        var components = baseComponents(path: "/v1/kb/sources/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/snapshot")
        components.queryItems = [.init(name: "kind", value: kind)]
        guard let url = components.url else { return nil }
        let response: SnapshotResponse? = performSync(request: makeRequest(url: url, method: "GET"))
        return response?.snapshot
    }

    func importFiles(urls: [URL]) async -> ReplyKnowledgeBaseBatchImportResult {
        let ready = await GatewayRuntimeManager.shared.ensureReady()
        guard ready else {
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: [],
                updated: [],
                failures: [.init(fileName: L10n.text(zhHans: "知识库", en: "Knowledge Base"), reason: GatewayRuntimeManager.shared.currentSnapshot().inlinePromptMessage)]
            )
        }
        guard let url = baseComponents(path: "/v1/kb/import-files").url else {
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: [],
                updated: [],
                failures: [.init(fileName: L10n.text(zhHans: "知识库", en: "Knowledge Base"), reason: L10n.text(zhHans: "知识库网关地址无效。", en: "The knowledge base gateway URL is invalid."))]
            )
        }
        let payload = ["paths": urls.map(\.path)]
        let request = makeJSONRequest(url: url, method: "POST", payload: payload)
        let response: ImportFilesResponse? = await perform(request: request)
        if let entries = response?.entries {
            return .init(inserted: entries, updated: [], failures: [])
        }
        let message = response?.message ?? L10n.text(zhHans: "文件导入失败。", en: "File import failed.")
        return .init(inserted: [], updated: [], failures: [.init(fileName: urls.first?.lastPathComponent ?? "Files", reason: message)])
    }

    func importURL(
        _ url: URL,
        title: String? = nil,
        text: String? = nil,
        capturePipeline: [String]? = nil,
        captureFailures: [KnowledgeBaseCaptureFailure]? = nil
    ) async -> ReplyKnowledgeBaseBatchImportResult {
        let ready = await GatewayRuntimeManager.shared.ensureReady()
        guard ready else {
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: [],
                updated: [],
                failures: [.init(fileName: url.absoluteString, reason: GatewayRuntimeManager.shared.currentSnapshot().inlinePromptMessage)]
            )
        }
        guard let requestURL = baseComponents(path: "/v1/kb/import-url").url else {
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: [],
                updated: [],
                failures: [.init(fileName: url.absoluteString, reason: L10n.text(zhHans: "知识库网关地址无效。", en: "The knowledge base gateway URL is invalid."))]
            )
        }
        var payload: [String: Any] = ["url": url.absoluteString]
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var browserCapture: [String: Any] = [
                "pageURL": url.absoluteString,
                "canonicalURL": url.absoluteString,
                "text": text
            ]
            if let title, !title.isEmpty {
                browserCapture["title"] = title
            }
            if let capturePipeline, !capturePipeline.isEmpty {
                browserCapture["capturePipeline"] = capturePipeline
            }
            if let captureFailures, !captureFailures.isEmpty {
                browserCapture["captureFailures"] = captureFailures.map { ["kind": $0.kind.rawValue, "message": $0.message] }
            }
            payload["browser_capture"] = browserCapture
        }
        let request = makeJSONRequest(url: requestURL, method: "POST", payload: payload)
        let response: SourceResponse? = await perform(request: request)
        if let entry = response?.entry {
            return .init(inserted: [entry], updated: [], failures: [])
        }
        let message = response?.message ?? L10n.text(zhHans: "链接采集失败。", en: "URL collection failed.")
        return .init(inserted: [], updated: [], failures: [.init(fileName: url.absoluteString, reason: message)])
    }

    func importURLStream(
        _ url: URL,
        title: String? = nil,
        text: String? = nil,
        capturePipeline: [String]? = nil,
        captureFailures: [KnowledgeBaseCaptureFailure]? = nil,
        uiLanguage: String,
        onEvent: @escaping (KnowledgeBaseImportURLStreamEvent) -> Void
    ) async -> ReplyKnowledgeBaseBatchImportResult {
        let ready = await GatewayRuntimeManager.shared.ensureReady()
        guard ready else {
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: [],
                updated: [],
                failures: [.init(fileName: url.absoluteString, reason: GatewayRuntimeManager.shared.currentSnapshot().inlinePromptMessage)]
            )
        }
        guard let requestURL = baseComponents(path: "/v1/kb/import-url/stream").url else {
            return ReplyKnowledgeBaseBatchImportResult(
                inserted: [],
                updated: [],
                failures: [.init(fileName: url.absoluteString, reason: L10n.text(zhHans: "知识库网关地址无效。", en: "The knowledge base gateway URL is invalid."))]
            )
        }

        var payload: [String: Any] = [
            "url": url.absoluteString,
            "ui_language": uiLanguage
        ]
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var browserCapture: [String: Any] = [
                "pageURL": url.absoluteString,
                "canonicalURL": url.absoluteString,
                "text": text
            ]
            if let title, !title.isEmpty {
                browserCapture["title"] = title
            }
            if let capturePipeline, !capturePipeline.isEmpty {
                browserCapture["capturePipeline"] = capturePipeline
            }
            if let captureFailures, !captureFailures.isEmpty {
                browserCapture["captureFailures"] = captureFailures.map { ["kind": $0.kind.rawValue, "message": $0.message] }
            }
            payload["browser_capture"] = browserCapture
        }

        let request = makeJSONRequest(url: requestURL, method: "POST", payload: payload)
        do {
            let (bytes, _) = try await session.bytes(for: request)
            var streamedEntry: ReplyKnowledgeBaseEntry?
            var streamedFailure: ReplyKnowledgeBaseImportFailure?
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = payload["type"] as? String else {
                    continue
                }

                switch type {
                case "status":
                    onEvent(.init(status: payload["status"] as? String, detail: payload["detail"] as? String))
                case "error":
                    streamedFailure = .init(
                        fileName: url.absoluteString,
                        reason: (payload["message"] as? String) ?? L10n.text(zhHans: "链接采集失败。", en: "URL collection failed.")
                    )
                case "done":
                    if let entryPayload = payload["entry"] {
                        let entryData = try JSONSerialization.data(withJSONObject: entryPayload)
                        streamedEntry = try Self.makeDecoder().decode(ReplyKnowledgeBaseEntry.self, from: entryData)
                    }
                default:
                    continue
                }
            }

            if let streamedEntry {
                return .init(inserted: [streamedEntry], updated: [], failures: [])
            }
            if let streamedFailure {
                return .init(inserted: [], updated: [], failures: [streamedFailure])
            }
        } catch {
            return .init(inserted: [], updated: [], failures: [.init(fileName: url.absoluteString, reason: error.localizedDescription)])
        }

        return .init(
            inserted: [],
            updated: [],
            failures: [.init(fileName: url.absoluteString, reason: L10n.text(zhHans: "链接采集失败。", en: "URL collection failed."))]
        )
    }

    func deleteSource(id: String) -> Bool {
        GatewayRuntimeManager.shared.startIfNeeded()
        guard let url = baseComponents(path: "/v1/kb/sources/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)").url else {
            return false
        }
        let response: BasicResponse? = performSync(request: makeRequest(url: url, method: "DELETE"))
        return response?.ok == true
    }

    func setSourceEnabled(id: String, isEnabled: Bool) -> Bool {
        GatewayRuntimeManager.shared.startIfNeeded()
        guard let url = baseComponents(path: "/v1/kb/sources/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/enabled").url else {
            return false
        }
        let request = makeJSONRequest(url: url, method: "POST", payload: ["is_enabled": isEnabled])
        let response: BasicResponse? = performSync(request: request)
        return response?.ok == true
    }

    func refreshSource(id: String) async -> ReplyKnowledgeBaseEntry? {
        let ready = await GatewayRuntimeManager.shared.ensureReady()
        guard ready,
              let url = baseComponents(path: "/v1/kb/sources/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/refresh").url else {
            return nil
        }
        let response: SourceResponse? = await perform(request: makeJSONRequest(url: url, method: "POST", payload: [:]))
        return response?.entry
    }

    func reindexSource(id: String) async -> ReplyKnowledgeBaseEntry? {
        let ready = await GatewayRuntimeManager.shared.ensureReady()
        guard ready,
              let url = baseComponents(path: "/v1/kb/sources/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/reindex").url else {
            return nil
        }
        let response: SourceResponse? = await perform(request: makeJSONRequest(url: url, method: "POST", payload: [:]))
        return response?.entry
    }

    func reset() async -> Bool {
        let ready = await GatewayRuntimeManager.shared.ensureReady()
        guard ready, let url = baseComponents(path: "/v1/kb/reset").url else { return false }
        let response: BasicResponse? = await perform(request: makeJSONRequest(url: url, method: "POST", payload: [:]))
        return response?.ok == true
    }

    func search(
        query: String,
        filters: [String: [String]] = [:],
        limit: Int = 8
    ) -> [KnowledgeBaseSearchMatch] {
        GatewayRuntimeManager.shared.startIfNeeded()
        guard let url = baseComponents(path: "/v1/kb/search").url else { return [] }
        let request = makeJSONRequest(url: url, method: "POST", payload: ["query": query, "filters": filters, "limit": limit])
        let response: SearchResponse? = performSync(request: request)
        return response?.results?.map {
            KnowledgeBaseSearchMatch(
                entry: $0.entry,
                score: $0.score,
                matchedChunk: $0.matchedChunk,
                matchedFacets: $0.matchedFacets,
                reason: $0.reason,
                citation: $0.citation
            )
        } ?? []
    }

    private func baseComponents(path: String) -> URLComponents {
        let base = baseURLProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: base) ?? URLComponents()
        let normalizedBasePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = normalizedBasePath.isEmpty ? "/\(normalizedPath)" : "/\(normalizedBasePath)/\(normalizedPath)"
        return components
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func makeJSONRequest(url: URL, method: String, payload: [String: Any]) -> URLRequest {
        var request = makeRequest(url: url, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func performSync<Response: Decodable>(request: URLRequest) -> Response? {
        let semaphore = DispatchSemaphore(value: 0)
        var decoded: Response?
        let task = session.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data else { return }
            let decoder = Self.makeDecoder()
            decoded = try? decoder.decode(Response.self, from: data)
        }
        task.resume()
        semaphore.wait()
        return decoded
    }

    private func perform<Response: Decodable>(request: URLRequest) async -> Response? {
        do {
            let (data, _) = try await session.data(for: request)
            return try Self.makeDecoder().decode(Response.self, from: data)
        } catch {
            return nil
        }
    }

    private static var gatewayDateDecodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = fractionalISO8601Formatter.date(from: raw) ?? plainISO8601Formatter.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid gateway ISO8601 date: \(raw)")
        }
    }

    private static let fractionalISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = gatewayDateDecodingStrategy
        return decoder
    }
}

private struct BasicResponse: Decodable {
    let ok: Bool?
    let message: String?
}

private struct SourcesResponse: Decodable {
    let ok: Bool?
    let entries: [ReplyKnowledgeBaseEntry]
}

private struct SourceResponse: Decodable {
    let ok: Bool?
    let entry: ReplyKnowledgeBaseEntry?
    let message: String?
}

private struct SnapshotResponse: Decodable {
    let ok: Bool?
    let snapshot: KnowledgeBaseSnapshot?
}

private struct ImportFilesResponse: Decodable {
    let ok: Bool?
    let entries: [ReplyKnowledgeBaseEntry]?
    let message: String?
}

private struct SearchResponse: Decodable {
    let ok: Bool?
    let results: [GatewayKnowledgeSearchResult]?
}

private struct GatewayKnowledgeSearchResult: Decodable {
    let entry: ReplyKnowledgeBaseEntry
    let score: Double
    let matchedChunk: ReplyKnowledgeBaseChunk?
    let matchedFacets: [String]
    let reason: String
    let sourceID: String?
    let snapshotID: String?
    let chunkID: String?
    let citation: KnowledgeBaseCitation?

    private enum CodingKeys: String, CodingKey {
        case entry
        case score
        case matchedChunk = "matched_chunk"
        case matchedFacets = "matched_facets"
        case reason
        case sourceID = "source_id"
        case snapshotID = "snapshot_id"
        case chunkID = "chunk_id"
        case citation
    }
}
