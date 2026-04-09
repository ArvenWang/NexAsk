import Foundation
import Security

protocol SecretStoring {
    func string(for account: String) -> String?
    @discardableResult
    func setString(_ value: String, for account: String) -> Bool
    @discardableResult
    func removeString(for account: String) -> Bool
}

final class SecretsStore: SecretStoring {
    static let shared = SecretsStore()

    private let service: String

    init(service: String = AppBrand.bundleIdentifier) {
        self.service = service
    }

    func string(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    func setString(_ value: String, for account: String) -> Bool {
        let data = Data(value.utf8)
        let query = baseQuery(for: account)

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    func removeString(for account: String) -> Bool {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
