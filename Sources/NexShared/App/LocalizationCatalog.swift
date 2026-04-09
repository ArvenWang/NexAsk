import Foundation

enum LocalizationCatalogStore {
    private static let lock = NSLock()
    private static var cachedCatalogs: [AppLanguage: [String: String]] = [:]

    static func string(for key: String, language: AppLanguage) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedCatalogs[language] {
            return cached[key]
        }

        let catalog = loadCatalog(language: language)
        cachedCatalogs[language] = catalog
        return catalog[key]
    }

    private static func loadCatalog(language: AppLanguage) -> [String: String] {
        guard let url = Bundle.module.url(forResource: language.rawValue, withExtension: "json") else {
            return [:]
        }

        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }

        return decoded
    }
}
