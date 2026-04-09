import Foundation

package enum AskRuntimeLocalization {
    private static let appLanguageDefaultsKey = "appLanguage"

    private enum Language {
        case simplifiedChinese
        case english
    }

    package static func text(zhHans: String, en: String) -> String {
        switch currentLanguage {
        case .simplifiedChinese:
            return zhHans
        case .english:
            return en
        }
    }

    package static func text(languageCode: String, zhHans: String, en: String) -> String {
        if languageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("en") {
            return en
        }
        return zhHans
    }

    package static func format(zhHans: String, en: String, _ arguments: CVarArg...) -> String {
        String(
            format: text(zhHans: zhHans, en: en),
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: arguments
        )
    }

    package static func format(languageCode: String, zhHans: String, en: String, _ arguments: CVarArg...) -> String {
        String(
            format: text(languageCode: languageCode, zhHans: zhHans, en: en),
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: arguments
        )
    }

    package static var currentLocaleIdentifier: String {
        switch currentLanguage {
        case .simplifiedChinese:
            return "zh_CN"
        case .english:
            return "en_US"
        }
    }

    private static var currentLanguage: Language {
        if let rawValue = UserDefaults.standard.string(forKey: appLanguageDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !rawValue.isEmpty {
            if rawValue.hasPrefix("en") {
                return .english
            }
            return .simplifiedChinese
        }

        if let preferred = Locale.preferredLanguages.first?.lowercased(), preferred.hasPrefix("en") {
            return .english
        }
        return .simplifiedChinese
    }
}
