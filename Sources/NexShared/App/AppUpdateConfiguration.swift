import Foundation

struct AppUpdateConfiguration {
    enum Issue: Equatable {
        case missingFeedURL
        case invalidFeedURL
        case missingPublicKey
    }

    let feedURL: URL?
    let publicEDKey: String?
    let automaticallyChecksForUpdates: Bool
    let automaticallyDownloadsUpdates: Bool
    let updateCheckInterval: TimeInterval?

    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        let feedURLString = (infoDictionary["SUFeedURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKeyString = (infoDictionary["SUPublicEDKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let feedURLString, !feedURLString.isEmpty {
            feedURL = URL(string: feedURLString)
        } else {
            feedURL = nil
        }

        if let publicKeyString, !publicKeyString.isEmpty {
            publicEDKey = publicKeyString
        } else {
            publicEDKey = nil
        }

        automaticallyChecksForUpdates = infoDictionary["SUEnableAutomaticChecks"] as? Bool ?? true
        automaticallyDownloadsUpdates = infoDictionary["SUAutomaticallyUpdate"] as? Bool ?? true
        updateCheckInterval = infoDictionary["SUScheduledCheckInterval"] as? TimeInterval
    }

    var issue: Issue? {
        guard let feedURL else {
            return .missingFeedURL
        }
        guard let scheme = feedURL.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              feedURL.host?.isEmpty == false else {
            return .invalidFeedURL
        }
        guard publicEDKey?.isEmpty == false else {
            return .missingPublicKey
        }
        return nil
    }

    var isConfigured: Bool {
        issue == nil
    }
}
