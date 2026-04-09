import AppKit
import Foundation

@objc
private protocol SparkleStandardUpdaterControlling: NSObjectProtocol {
    init(startingUpdater: Bool, updaterDelegate: Any?, userDriverDelegate: Any?)
    @objc(checkForUpdates:)
    func checkForUpdates(_ sender: Any?)
}

private enum SparkleRuntime {
    static let checkForUpdatesSelector = NSSelectorFromString("checkForUpdates:")

    static func makeUpdaterController(delegate: AnyObject) -> (any SparkleStandardUpdaterControlling)? {
        loadFrameworkIfNeeded()
        guard let controllerClass = resolveControllerClass() else {
            return nil
        }
        return controllerClass.init(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
    }

    private static func resolveControllerClass() -> (any SparkleStandardUpdaterControlling.Type)? {
        ["SPUStandardUpdaterController", "Sparkle.SPUStandardUpdaterController"]
            .compactMap { NSClassFromString($0) as? any SparkleStandardUpdaterControlling.Type }
            .first
    }

    private static func loadFrameworkIfNeeded() {
        guard resolveControllerClass() == nil else { return }

        for url in candidateFrameworkURLs() {
            guard let bundle = Bundle(url: url) else { continue }
            _ = bundle.load()
            if resolveControllerClass() != nil {
                return
            }
        }
    }

    private static func candidateFrameworkURLs() -> [URL] {
        var urls: [URL] = []

        if let privateFrameworksURL = Bundle.main.privateFrameworksURL {
            urls.append(privateFrameworksURL.appendingPathComponent("Sparkle.framework"))
        }

        if let executableURL = Bundle.main.executableURL {
            let executableDirectoryURL = executableURL.deletingLastPathComponent()
            urls.append(
                executableDirectoryURL
                    .appendingPathComponent("../Frameworks/Sparkle.framework")
                    .standardizedFileURL
            )
            urls.append(executableDirectoryURL.appendingPathComponent("Sparkle.framework"))
        }

        urls.append(
            Bundle.main.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("Sparkle.framework")
                .standardizedFileURL
        )

        var seenPaths: Set<String> = []
        return urls.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
    }
}

final class AppUpdateCoordinator: NSObject {
    private let diagnosticsLogger = DiagnosticsLogger.shared
    private let configuration: AppUpdateConfiguration
    private var updaterController: (any SparkleStandardUpdaterControlling)?

    init(configuration: AppUpdateConfiguration = AppUpdateConfiguration()) {
        self.configuration = configuration
        super.init()
    }

    var isConfigured: Bool {
        configuration.isConfigured
    }

    func startIfConfigured() {
        guard configuration.isConfigured else {
            if let issue = configuration.issue {
                diagnosticsLogger.log("app.update", "disabled reason=\(issue.logValue)")
            }
            return
        }

        guard updaterController == nil else { return }

        diagnosticsLogger.log(
            "app.update",
            "starting feed=\(configuration.feedURL?.absoluteString ?? "missing") autoChecks=\(configuration.automaticallyChecksForUpdates) autoDownloads=\(configuration.automaticallyDownloadsUpdates)"
        )

        updaterController = SparkleRuntime.makeUpdaterController(delegate: self)
        if updaterController == nil {
            diagnosticsLogger.log("app.update", "disabled reason=sparkle_framework_unavailable")
        }
    }

    func configureMenuItem(_ menuItem: NSMenuItem, fallbackTarget: AnyObject, fallbackAction: Selector) {
        guard let updaterController else {
            menuItem.target = fallbackTarget
            menuItem.action = fallbackAction
            menuItem.isEnabled = true
            return
        }

        menuItem.target = updaterController as AnyObject
        menuItem.action = SparkleRuntime.checkForUpdatesSelector
    }

    func configurationIssueMessage() -> String {
        switch configuration.issue {
        case .missingFeedURL:
            return L10n.text(
                zhHans: "尚未配置远程更新地址。请在构建时设置 SUFeedURL / NEXHUB_UPDATE_FEED_URL，然后重新打包应用。",
                en: "Remote updates are not configured yet. Set SUFeedURL / NEXHUB_UPDATE_FEED_URL at build time and rebuild the app."
            )
        case .invalidFeedURL:
            return L10n.text(
                zhHans: "远程更新地址无效。请使用可公开访问的 http(s) appcast URL。",
                en: "The update feed URL is invalid. Use a publicly reachable http(s) appcast URL."
            )
        case .missingPublicKey:
            return L10n.text(
                zhHans: "尚未配置 Sparkle 公钥。请在构建时设置 SUPublicEDKey / NEXHUB_SPARKLE_PUBLIC_KEY。",
                en: "Sparkle public key is missing. Set SUPublicEDKey / NEXHUB_SPARKLE_PUBLIC_KEY at build time."
            )
        case nil:
            return L10n.text(
                zhHans: "远程更新已启用。",
                en: "Remote updates are enabled."
            )
        }
    }
}

extension AppUpdateCoordinator {
    @objc(updater:didAbortWithError:)
    func updater(_ updater: Any, didAbortWithError error: Error) {
        diagnosticsLogger.log("app.update", "error=\(error.localizedDescription)")
    }
}

private extension AppUpdateConfiguration.Issue {
    var logValue: String {
        switch self {
        case .missingFeedURL:
            return "missing_feed_url"
        case .invalidFeedURL:
            return "invalid_feed_url"
        case .missingPublicKey:
            return "missing_public_key"
        }
    }
}
