import Foundation

struct AppBuildInfo: Decodable {
    let appVersion: String?
    let buildNumber: String?
    let gitSHA: String?
    let buildTimeUTC: String?
    let signingMode: String?
    let signingIdentity: String?
    let signingTeam: String?

    private enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case buildNumber = "build_number"
        case gitSHA = "git_sha"
        case buildTimeUTC = "build_time_utc"
        case signingMode = "signing_mode"
        case signingIdentity = "signing_identity"
        case signingTeam = "signing_team"
    }

    static func load(bundle: Bundle = .main) -> AppBuildInfo? {
        guard let url = bundle.url(forResource: "build_info", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(AppBuildInfo.self, from: data)
    }

    var signingSummary: String? {
        let identity = normalizedValue(signingIdentity)
        let team = normalizedValue(signingTeam)
        let mode = normalizedValue(signingMode)

        if let identity, let team {
            return "\(identity) / Team \(team)"
        }
        if let identity {
            return identity
        }
        if let mode {
            return mode
        }
        return nil
    }

    private func normalizedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
