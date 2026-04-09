import AppKit
import Foundation

struct RunningApplicationInfo: Hashable {
    let bundleID: String
    let displayName: String
    let url: URL
}

enum RunningApplicationCatalog {
    static let defaultCompatibilityBundleIDs: [String] = [
        "com.tencent.xinWeChat",
        "com.tencent.WeWorkMac",
        "com.bilibili.bilibiliPC",
    ]

    private static let fallbackNames: [String: String] = [
        "com.tencent.xinWeChat": L10n.text(zhHans: "微信", en: "WeChat"),
        "com.tencent.WeWorkMac": L10n.text(zhHans: "企业微信", en: "WeCom"),
        "com.tencent.qq": "QQ",
        "com.tencent.tim": "TIM",
        "com.bytedance.feishu": L10n.text(zhHans: "飞书", en: "Feishu"),
        "com.electron.lark": L10n.text(zhHans: "飞书", en: "Feishu"),
        "com.larksuite.suite": "Lark",
        "com.bilibili.bilibiliPC": L10n.text(zhHans: "哔哩哔哩", en: "Bilibili"),
    ]

    static func currentApplications() -> [RunningApplicationInfo] {
        let running = NSWorkspace.shared.runningApplications
            .filter { app in
                guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
                guard app.activationPolicy == .regular else { return false }
                guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return false }
                guard let bundleURL = app.bundleURL else { return false }
                guard shouldInclude(bundleID: bundleID, bundleURL: bundleURL) else { return false }
                return true
            }

        var byBundle: [String: RunningApplicationInfo] = [:]
        for app in running {
            guard let bundleID = app.bundleIdentifier, let url = app.bundleURL else { continue }
            let displayName = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = (displayName?.isEmpty == false)
                ? displayName!
                : fallbackDisplayName(for: bundleID) ?? url.deletingPathExtension().lastPathComponent
            byBundle[bundleID] = RunningApplicationInfo(bundleID: bundleID, displayName: resolvedName, url: url)
        }

        return byBundle.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func currentApplicationsByBundleID() -> [String: RunningApplicationInfo] {
        Dictionary(uniqueKeysWithValues: currentApplications().map { ($0.bundleID, $0) })
    }

    static func fallbackDisplayName(for bundleID: String) -> String? {
        fallbackNames[bundleID]
    }

    static func supportsReplyWriteback(bundleID: String?) -> Bool {
        SourceAppPolicy.supportsMessageWriteback(bundleID: bundleID)
    }

    private static func shouldInclude(bundleID: String, bundleURL: URL) -> Bool {
        let standardizedPath = bundleURL.resolvingSymlinksInPath().path
        guard standardizedPath.hasSuffix(".app") else { return false }
        guard !bundleID.hasPrefix("com.apple.") else { return false }

        let allowedRoots = [
            "/Applications/",
            "\(NSHomeDirectory())/Applications/",
        ]
        return allowedRoots.contains { standardizedPath.hasPrefix($0) }
    }
}
