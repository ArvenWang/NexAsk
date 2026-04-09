import Foundation

package enum AppBrand {
    private static let supportDirectoryNameInfoKey = "NexHubSupportDirectoryName"
    private static let smokeNamespaceInfoKey = "NexHubSmokeNamespace"
    private static let legacySmokeNamespace = "nexhub"

    package static var displayName: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return "NexHub"
    }

    package static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.nexhub.mac"
    }

    package static var supportDirectoryName: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: supportDirectoryNameInfoKey) as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return "NexHub"
    }

    package static var smokeNamespace: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: smokeNamespaceInfoKey) as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty {
                return sanitizePathComponent(trimmed)
            }
        }

        switch AppProductProfile.current {
        case .nexask:
            return "nexask"
        case .unified, .nexhub:
            return legacySmokeNamespace
        }
    }

    package static var legacySmokeNamespaces: [String] {
        smokeNamespace == legacySmokeNamespace ? [] : [legacySmokeNamespace]
    }

    package static func accessibilityIdentifier(_ suffix: String) -> String {
        "\(smokeNamespace).\(suffix)"
    }

    package static func smokeNotificationName(_ action: String) -> Notification.Name {
        Notification.Name("\(smokeNamespace).smoke.\(action)")
    }

    package static func smokeNotificationNames(_ action: String) -> [Notification.Name] {
        var names = [smokeNotificationName(action)]
        for namespace in legacySmokeNamespaces {
            let legacyName = Notification.Name("\(namespace).smoke.\(action)")
            if !names.contains(legacyName) {
                names.append(legacyName)
            }
        }
        return names
    }

    package static var smokeSourceBundleIdentifier: String {
        "\(smokeNamespace).smoke"
    }

    package static func productNotificationName(_ action: String) -> Notification.Name {
        Notification.Name("\(smokeNamespace).product.\(action)")
    }

    package static var legacySupportDirectoryNames: [String] {
        var names: [String] = []
        for candidate in ["NexHub", sanitizePathComponent(bundleIdentifier), sanitizePathComponent(displayName)] {
            guard !candidate.isEmpty, candidate != supportDirectoryName, !names.contains(candidate) else { continue }
            names.append(candidate)
        }
        return names
    }

    package static var clientIdentifier: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "\(bundleIdentifier)/\(version)"
    }

    private static func sanitizePathComponent(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
        return value.components(separatedBy: invalidCharacters).joined(separator: "_")
    }
}
