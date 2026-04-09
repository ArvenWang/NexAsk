import AppKit
import Foundation
import NexShared

typealias AskBrowserURLOpener = @Sendable (URL, String?) async -> Bool

struct AskBrowserExecutor: AskCapabilityExecuting {
    private static let supportedBrowserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac"
    ]

    let supportedCapabilityIDs: [AskCapabilityID] = [
        "browser.open_url",
        "browser.search_web",
        "browser.read_current_page"
    ]

    private let pageCaptureProvider: BrowserPageCaptureProviding
    private let urlOpener: AskBrowserURLOpener

    init(
        pageCaptureProvider: BrowserPageCaptureProviding = BrowserPageCaptureService(),
        urlOpener: @escaping AskBrowserURLOpener = { url, preferredBundleID in
            await AskBrowserExecutor.defaultURLOpener(url: url, preferredBundleID: preferredBundleID)
        }
    ) {
        self.pageCaptureProvider = pageCaptureProvider
        self.urlOpener = urlOpener
    }

    func execute(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        switch request.capability.id {
        case "browser.open_url":
            return await openURL(request: request)
        case "browser.search_web":
            return await searchWeb(request: request)
        case "browser.read_current_page":
            return await readCurrentPage(request: request)
        default:
            return .unsupported(summary: "Unsupported browser capability: \(request.capability.id)")
        }
    }

    private func openURL(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let rawURL = firstNonEmptyValue(in: request.arguments, keys: ["url", "page_url", "link"]),
              let url = URL(string: rawURL) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No valid URL was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        if request.dryRun {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: "Prepared to open the requested URL.",
                approvalID: nil,
                artifacts: [AskCapabilityArtifact(kind: "url", value: url.absoluteString)],
                metadata: [
                    "url": url.absoluteString,
                    "host": url.host ?? url.absoluteString,
                    "dry_run": "true"
                ]
            )
        }

        let preferredBundleID = firstNonEmptyValue(in: request.arguments, keys: ["preferred_browser_bundle_id", "browser_bundle_id"])
        let opened = await urlOpener(url, preferredBundleID)
        let host = url.host ?? url.absoluteString
        return AskCapabilityExecutionResult(
            status: opened ? .succeeded : .failed,
            summary: opened ? "Opened \(host)." : "Failed to open \(host).",
            approvalID: nil,
            artifacts: [AskCapabilityArtifact(kind: "url", value: url.absoluteString)],
            metadata: [
                "url": url.absoluteString,
                "host": host,
                "preferred_browser_bundle_id": preferredBundleID ?? "",
                "opened": String(opened)
            ]
        )
    }

    private func searchWeb(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        guard let query = firstNonEmptyValue(in: request.arguments, keys: ["query", "text", "search_query"]) else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "No web search query was provided.",
                approvalID: nil,
                artifacts: [],
                metadata: [:]
            )
        }

        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encodedQuery)") else {
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: "The web search query could not be turned into a valid URL.",
                approvalID: nil,
                artifacts: [],
                metadata: ["query": query]
            )
        }

        let openInBrowser = boolValue(in: request.arguments, keys: ["open_in_browser", "open"]) ?? false
        if request.dryRun || !openInBrowser {
            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: openInBrowser
                    ? "Prepared the search results URL."
                    : "Prepared the search results URL without opening the browser.",
                approvalID: nil,
                artifacts: [AskCapabilityArtifact(kind: "search_url", value: url.absoluteString)],
                metadata: [
                    "query": query,
                    "search_url": url.absoluteString,
                    "opened_in_browser": "false",
                    "dry_run": String(request.dryRun)
                ]
            )
        }

        let preferredBundleID = firstNonEmptyValue(in: request.arguments, keys: ["preferred_browser_bundle_id", "browser_bundle_id"])
        let opened = await urlOpener(url, preferredBundleID)
        return AskCapabilityExecutionResult(
            status: opened ? .succeeded : .failed,
            summary: opened ? "Opened search results for \(query)." : "Failed to open search results for \(query).",
            approvalID: nil,
            artifacts: [AskCapabilityArtifact(kind: "search_url", value: url.absoluteString)],
            metadata: [
                "query": query,
                "search_url": url.absoluteString,
                "opened_in_browser": String(opened),
                "preferred_browser_bundle_id": preferredBundleID ?? ""
            ]
        )
    }

    private func readCurrentPage(request: AskCapabilityExecutionRequest) async -> AskCapabilityExecutionResult {
        let hasExplicitSourceBundleArgument = request.arguments.keys.contains("source_bundle_id")
            || request.arguments.keys.contains("bundle_id")
        let sourceBundleID: String?
        if hasExplicitSourceBundleArgument {
            sourceBundleID = firstNonEmptyValue(in: request.arguments, keys: ["source_bundle_id", "bundle_id"])
        } else {
            sourceBundleID = request.task.context.sourceBundleID
                ?? request.task.context.frontmostBundleID
        }
        let query = firstNonEmptyValue(in: request.arguments, keys: ["query", "text", "topic"])

        let capture = await pageCaptureProvider.captureReadableCurrentPage(fromBundleID: sourceBundleID)
        switch capture {
        case .failure(let error):
            return AskCapabilityExecutionResult(
                status: .failed,
                summary: error.message,
                approvalID: nil,
                artifacts: [],
                metadata: [
                    "source_bundle_id": sourceBundleID ?? ""
                ]
            )
        case .success(let page):
            let pageURL = page.canonicalURL?.absoluteString ?? page.pageURL.absoluteString
            let trimmedPageText = trimmedPageTextPayload(from: page.text)
            let summary: String
            var artifacts: [AskCapabilityArtifact] = [
                AskCapabilityArtifact(kind: "page_text", value: trimmedPageText)
            ]

            if let query, !query.isEmpty {
                let matches = currentPageMatches(in: page.text, query: query)
                let preview = matches.joined(separator: "\n\n")
                summary = matches.isEmpty
                    ? "The current page did not contain a direct visible match for \(query)."
                    : "Read the current page and found relevant passages for \(query)."
                if !matches.isEmpty {
                    artifacts.append(AskCapabilityArtifact(kind: "page_matches", value: preview))
                }
            } else {
                let snippet = pageSnippet(from: page.text)
                summary = "Read the current page \(page.title)."
                if !snippet.isEmpty {
                    artifacts.append(AskCapabilityArtifact(kind: "page_summary", value: snippet))
                }
            }

            return AskCapabilityExecutionResult(
                status: .succeeded,
                summary: summary,
                approvalID: nil,
                artifacts: artifacts,
                metadata: [
                    "source_bundle_id": sourceBundleID ?? "",
                    "page_url": pageURL,
                    "page_title": page.title,
                    "query": query ?? "",
                    "page_text_truncated": String(page.text.count > trimmedPageText.count)
                ]
            )
        }
    }

    private static func defaultURLOpener(url: URL, preferredBundleID: String?) async -> Bool {
        guard let preferredBundleID,
              Self.supportedBrowserBundleIDs.contains(preferredBundleID) else {
            return await MainActor.run { NSWorkspace.shared.open(url) }
        }

        let appURL = await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferredBundleID)
        }
        guard let appURL else {
            return await MainActor.run { NSWorkspace.shared.open(url) }
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
                    continuation.resume(returning: error == nil)
                }
            }
        }
    }

    private func pageSnippet(from text: String) -> String {
        let paragraphs = text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 24 }

        let snippet = paragraphs.prefix(2).joined(separator: "\n\n")
        if snippet.count <= 420 {
            return snippet
        }
        let index = snippet.index(snippet.startIndex, offsetBy: 417)
        return String(snippet[..<index]) + "..."
    }

    private func trimmedPageTextPayload(from text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(normalized.prefix(32_000))
        return capped
    }

    private func currentPageMatches(in text: String, query: String) -> [String] {
        let queryTokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !queryTokens.isEmpty else { return [] }

        let candidates = text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 18 }

        let scored = candidates.compactMap { line -> (String, Int)? in
            let normalized = line.lowercased()
            let score = queryTokens.reduce(into: 0) { partialResult, token in
                if normalized.contains(token) {
                    partialResult += 1
                }
            }
            guard score > 0 else { return nil }
            return (line, score)
        }

        return scored
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.count < $1.0.count
                }
                return $0.1 > $1.1
            }
            .map(\.0)
            .prefix(3)
            .map { line in
                if line.count <= 220 {
                    return line
                }
                let index = line.index(line.startIndex, offsetBy: 217)
                return String(line[..<index]) + "..."
            }
    }

    private func firstNonEmptyValue(in arguments: AskInvocationMetadata, keys: [String]) -> String? {
        for key in keys {
            guard let value = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    private func boolValue(in arguments: AskInvocationMetadata, keys: [String]) -> Bool? {
        for key in keys {
            guard let rawValue = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !rawValue.isEmpty else {
                continue
            }
            switch rawValue {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                continue
            }
        }
        return nil
    }
}
