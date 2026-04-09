import Foundation

extension Notification.Name {
    static let managedAIConfigurationDidChange = Notification.Name("nexhub.managedAIConfigurationDidChange")
}

struct ManagedAIQuotaSnapshot: Codable, Equatable {
    let monthlyRequestLimit: Int?
    let monthlyTokenLimit: Int?
    let totalRequests: Int
    let totalTokens: Int
    let periodStart: Date?
    let periodEnd: Date?
    let requestsRemaining: Int?
    let tokensRemaining: Int?
}

struct ManagedAIConfigurationSnapshot: Codable, Equatable {
    let managed: Bool
    let enabled: Bool
    let provider: String
    let model: String
    let quota: ManagedAIQuotaSnapshot
    let updatedAt: Date?
    let fetchedAt: Date
}

enum ManagedAIConfigurationError: LocalizedError {
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return L10n.text(
                zhHans: "当前服务器托管 AI 暂不可用，请稍后重试。",
                en: "Managed AI is temporarily unavailable. Please try again later."
            )
        case .invalidResponse:
            return L10n.text(
                zhHans: "服务器托管 AI 配置返回异常。",
                en: "The managed AI configuration response was invalid."
            )
        }
    }
}

package final class ManagedAIConfigurationService {
    package static let shared = ManagedAIConfigurationService()

    private enum StorageKey {
        static let snapshot = "managedAI.configuration.snapshot"
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let commerceService: CommerceService
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        commerceService: CommerceService = .shared
    ) {
        self.defaults = defaults
        self.session = session
        self.commerceService = commerceService

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = CommerceService.iso8601WithFractional.date(from: raw)
                ?? CommerceService.iso8601.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
        }
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func currentSnapshot() -> ManagedAIConfigurationSnapshot? {
        guard let data = defaults.data(forKey: StorageKey.snapshot) else {
            return nil
        }
        return try? decoder.decode(ManagedAIConfigurationSnapshot.self, from: data)
    }

    package func currentConfiguration() -> LLMRequestConfiguration? {
        guard let snapshot = currentSnapshot(),
              snapshot.enabled,
              let deviceToken = commerceService.currentDeviceToken(),
              !deviceToken.isEmpty else {
            return nil
        }

        return LLMRequestConfiguration(
            provider: snapshot.provider,
            model: snapshot.model,
            apiKey: deviceToken,
            baseURL: CommerceService.configuredAPIBaseURL().absoluteString
        )
    }

    @discardableResult
    func refreshIfPossible() async -> Bool {
        do {
            _ = try await refresh()
            return true
        } catch {
            return false
        }
    }

    func refresh() async throws -> ManagedAIConfigurationSnapshot {
        let deviceToken = try await commerceService.ensureDeviceToken()
        var request = URLRequest(url: CommerceService.configuredAPIBaseURL().appendingPathComponent("v1/ai/config"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppBrand.clientIdentifier, forHTTPHeaderField: "X-Client-Id")
        request.setValue(deviceToken, forHTTPHeaderField: "x-device-token")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ManagedAIConfigurationError.unavailable
        }

        struct RemotePayload: Decodable {
            let managed: Bool
            let enabled: Bool
            let provider: String
            let model: String
            let quota: ManagedAIQuotaSnapshot
            let updatedAt: Date?
        }

        guard let remote = try? decoder.decode(RemotePayload.self, from: data) else {
            throw ManagedAIConfigurationError.invalidResponse
        }

        let snapshot = ManagedAIConfigurationSnapshot(
            managed: remote.managed,
            enabled: remote.enabled,
            provider: remote.provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "openai" : remote.provider,
            model: remote.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-4.1-mini" : remote.model,
            quota: remote.quota,
            updatedAt: remote.updatedAt,
            fetchedAt: Date()
        )
        persist(snapshot)
        return snapshot
    }

    package func configuration() async throws -> LLMRequestConfiguration {
        if let snapshot = currentSnapshot(),
           !isStale(snapshot),
           let current = currentConfiguration() {
            return current
        }

        do {
            let snapshot = try await refresh()
            guard snapshot.enabled,
                  let current = currentConfiguration() else {
                throw ManagedAIConfigurationError.unavailable
            }
            return current
        } catch {
            if let current = currentConfiguration() {
                return current
            }
            throw error
        }
    }

    private func isStale(_ snapshot: ManagedAIConfigurationSnapshot) -> Bool {
        Date().timeIntervalSince(snapshot.fetchedAt) >= 300
    }

    private func persist(_ snapshot: ManagedAIConfigurationSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: StorageKey.snapshot)
        defaults.synchronize()
        NotificationCenter.default.post(name: .managedAIConfigurationDidChange, object: self)
    }
}
