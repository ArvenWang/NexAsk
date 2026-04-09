import AppKit
import Foundation

package struct BrowserPageCaptureResult: Equatable {
    package let browserBundleID: String
    package let pageURL: URL
    package let canonicalURL: URL?
    package let title: String
    package let text: String
}

package protocol BrowserPageCaptureProviding {
    func captureReadablePage(matching targetURL: URL) async -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure>
    func captureReadableCurrentPage(fromBundleID bundleID: String?) async -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure>
}

package extension BrowserPageCaptureProviding {
    func captureReadableCurrentPage(fromBundleID bundleID: String?) async -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure> {
        .failure(
            KnowledgeBaseCaptureFailure(
                kind: .browserCaptureUnavailable,
                message: L10n.text(zhHans: "浏览器辅助采集不可用。", en: "Browser-assisted capture is unavailable.")
            )
        )
    }
}

package final class BrowserPageCaptureService: BrowserPageCaptureProviding {
    private let diagnosticsLogger: DiagnosticsLogger

    package init(diagnosticsLogger: DiagnosticsLogger = .shared) {
        self.diagnosticsLogger = diagnosticsLogger
    }

    package func captureReadablePage(matching targetURL: URL) async -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure> {
        await MainActor.run {
            self.captureReadablePageSynchronously(matching: targetURL)
        }
    }

    package func captureReadableCurrentPage(fromBundleID bundleID: String?) async -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure> {
        await MainActor.run {
            self.captureReadableCurrentPageSynchronously(fromBundleID: bundleID)
        }
    }

    @MainActor
    private func captureReadablePageSynchronously(matching targetURL: URL) -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure> {
        let normalizedTarget = normalizedURL(targetURL)
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier,
              let browser = SupportedBrowser(bundleID: bundleID) else {
            return .failure(
                KnowledgeBaseCaptureFailure(
                    kind: .browserCaptureUnavailable,
                    message: L10n.text(zhHans: "当前前台应用不是受支持的浏览器。", en: "The frontmost app is not a supported browser.")
                )
            )
        }

        do {
            let payload = try runAppleScript(browser: browser)
            guard let pageURL = URL(string: payload.urlString) else {
                return .failure(
                    KnowledgeBaseCaptureFailure(
                        kind: .browserCaptureUnavailable,
                        message: L10n.text(zhHans: "浏览器没有返回可用的页面地址。", en: "The browser did not return a usable page URL.")
                    )
                )
            }

            let normalizedPageURL = normalizedURL(pageURL)
            let canonicalURL = URL(string: payload.canonicalURLString ?? "")
            let normalizedCanonical = canonicalURL.map(normalizedURL)
            guard normalizedPageURL == normalizedTarget || normalizedCanonical == normalizedTarget else {
                return .failure(
                    KnowledgeBaseCaptureFailure(
                        kind: .browserCaptureUnavailable,
                        message: L10n.text(zhHans: "当前浏览器页面与待采集 URL 不一致。", en: "The current browser page does not match the URL being collected.")
                    )
                )
            }

            let normalizedText = payload.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !normalizedText.isEmpty else {
                return .failure(
                    KnowledgeBaseCaptureFailure(
                        kind: .browserCaptureUnavailable,
                        message: L10n.text(zhHans: "浏览器页面里没有读到可见正文。", en: "No readable page text was captured from the browser.")
                    )
                )
            }

            diagnosticsLogger.log("collect.browser_capture", "bundle=\(bundleID) url=\(normalizedPageURL.absoluteString) chars=\(normalizedText.count)")
            return .success(
                BrowserPageCaptureResult(
                    browserBundleID: bundleID,
                    pageURL: normalizedPageURL,
                    canonicalURL: normalizedCanonical,
                    title: payload.title.isEmpty ? (normalizedCanonical?.host ?? normalizedPageURL.host ?? normalizedPageURL.absoluteString) : payload.title,
                    text: normalizedText
                )
            )
        } catch {
            diagnosticsLogger.log("collect.browser_capture", "bundle=\(bundleID) failed=\(error.localizedDescription)")
            return .failure(
                KnowledgeBaseCaptureFailure(
                    kind: .browserCaptureUnavailable,
                    message: L10n.text(zhHans: "浏览器辅助采集不可用。", en: "Browser-assisted capture is unavailable.")
                )
            )
        }
    }

    @MainActor
    private func captureReadableCurrentPageSynchronously(fromBundleID bundleID: String?) -> Result<BrowserPageCaptureResult, KnowledgeBaseCaptureFailure> {
        let resolvedBundleID: String?
        if let bundleID, SupportedBrowser(bundleID: bundleID) != nil {
            resolvedBundleID = bundleID
        } else if let frontApp = NSWorkspace.shared.frontmostApplication,
                  let frontmostBundleID = frontApp.bundleIdentifier,
                  SupportedBrowser(bundleID: frontmostBundleID) != nil {
            resolvedBundleID = frontmostBundleID
        } else {
            resolvedBundleID = nil
        }

        guard let resolvedBundleID,
              let browser = SupportedBrowser(bundleID: resolvedBundleID) else {
            return .failure(
                KnowledgeBaseCaptureFailure(
                    kind: .browserCaptureUnavailable,
                    message: L10n.text(zhHans: "当前没有可读取的受支持浏览器页面。", en: "There is no supported browser page available to read right now.")
                )
            )
        }

        do {
            let payload = try runAppleScript(browser: browser)
            guard let pageURL = URL(string: payload.urlString) else {
                return .failure(
                    KnowledgeBaseCaptureFailure(
                        kind: .browserCaptureUnavailable,
                        message: L10n.text(zhHans: "浏览器没有返回可用的页面地址。", en: "The browser did not return a usable page URL.")
                    )
                )
            }

            let normalizedPageURL = normalizedURL(pageURL)
            let canonicalURL = URL(string: payload.canonicalURLString ?? "")
            let normalizedCanonical = canonicalURL.map(normalizedURL)
            let normalizedText = payload.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !normalizedText.isEmpty else {
                return .failure(
                    KnowledgeBaseCaptureFailure(
                        kind: .browserCaptureUnavailable,
                        message: L10n.text(zhHans: "浏览器页面里没有读到可见正文。", en: "No readable page text was captured from the browser.")
                    )
                )
            }

            diagnosticsLogger.log("collect.browser_capture", "bundle=\(resolvedBundleID) current_url=\(normalizedPageURL.absoluteString) chars=\(normalizedText.count)")
            return .success(
                BrowserPageCaptureResult(
                    browserBundleID: resolvedBundleID,
                    pageURL: normalizedPageURL,
                    canonicalURL: normalizedCanonical,
                    title: payload.title.isEmpty ? (normalizedCanonical?.host ?? normalizedPageURL.host ?? normalizedPageURL.absoluteString) : payload.title,
                    text: normalizedText
                )
            )
        } catch {
            diagnosticsLogger.log("collect.browser_capture", "bundle=\(resolvedBundleID) current_page_failed=\(error.localizedDescription)")
            return .failure(
                KnowledgeBaseCaptureFailure(
                    kind: .browserCaptureUnavailable,
                    message: L10n.text(zhHans: "浏览器辅助采集不可用。", en: "Browser-assisted capture is unavailable.")
                )
            )
        }
    }

    @MainActor
    private func runAppleScript(browser: SupportedBrowser) throws -> BrowserPayload {
        let javaScript = browserJavaScript()
        let source: String
        switch browser.kind {
        case .safari:
            source = """
            tell application "\(browser.appName)"
                if (count of documents) is 0 then error "no_document"
                set currentDocument to front document
                set pageURL to URL of currentDocument
                set pageTitle to name of currentDocument
                set pagePayload to do JavaScript "\(escapeForAppleScript(javaScript))" in currentDocument
                return pageURL & linefeed & pageTitle & linefeed & pagePayload
            end tell
            """
        case .chromium:
            source = """
            tell application "\(browser.appName)"
                if (count of windows) is 0 then error "no_window"
                set activeTabRef to active tab of front window
                set pageURL to URL of activeTabRef
                set pageTitle to title of activeTabRef
                set pagePayload to execute activeTabRef javascript "\(escapeForAppleScript(javaScript))"
                return pageURL & linefeed & pageTitle & linefeed & pagePayload
            end tell
            """
        }

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw NSError(domain: "BrowserPageCaptureService", code: 1)
        }
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw NSError(domain: "BrowserPageCaptureService", code: 2, userInfo: errorInfo as? [String: Any])
        }
        guard let output = descriptor.stringValue else {
            throw NSError(domain: "BrowserPageCaptureService", code: 3)
        }

        let components = output.components(separatedBy: "\n")
        guard components.count >= 3 else {
            throw NSError(domain: "BrowserPageCaptureService", code: 4)
        }

        let urlString = components[0]
        let title = components[1]
        let payloadJSON = components.dropFirst(2).joined(separator: "\n")
        guard let data = payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(BrowserPayloadJSON.self, from: data) else {
            throw NSError(domain: "BrowserPageCaptureService", code: 5)
        }
        return BrowserPayload(urlString: urlString, title: payload.title.isEmpty ? title : payload.title, canonicalURLString: payload.canonicalURL, text: payload.text)
    }

    private func browserJavaScript() -> String {
        """
        (() => {
          const canonical = document.querySelector('link[rel=\"canonical\"]')?.href || '';
          const title = document.title || '';
          const text = (document.body?.innerText || '').trim();
          return JSON.stringify({ title, canonicalURL: canonical, text });
        })();
        """
    }

    private func normalizedURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let normalizedScheme = components?.scheme?.lowercased()
        let normalizedHost = components?.host?.lowercased()
        components?.fragment = nil
        components?.scheme = normalizedScheme
        components?.host = normalizedHost
        return components?.url ?? url
    }

    private func escapeForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

private struct BrowserPayload {
    let urlString: String
    let title: String
    let canonicalURLString: String?
    let text: String
}

private struct BrowserPayloadJSON: Decodable {
    let title: String
    let canonicalURL: String?
    let text: String
}

private struct SupportedBrowser {
    enum Kind {
        case safari
        case chromium
    }

    let bundleID: String
    let appName: String
    let kind: Kind

    init?(bundleID: String) {
        switch bundleID {
        case "com.apple.Safari":
            self.bundleID = bundleID
            self.appName = "Safari"
            self.kind = .safari
        case "com.google.Chrome":
            self.bundleID = bundleID
            self.appName = "Google Chrome"
            self.kind = .chromium
        case "company.thebrowser.Browser":
            self.bundleID = bundleID
            self.appName = "Arc"
            self.kind = .chromium
        case "com.microsoft.edgemac":
            self.bundleID = bundleID
            self.appName = "Microsoft Edge"
            self.kind = .chromium
        default:
            return nil
        }
    }
}
