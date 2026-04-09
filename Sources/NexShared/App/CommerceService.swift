import Foundation

extension Notification.Name {
    static let commerceStateDidChange = Notification.Name("nexhub.commerceStateDidChange")
}

enum CommerceSubscriptionPlan: String, CaseIterable, Codable {
    case proMonthly = "pro_monthly"
    case proAnnual = "pro_annual"

    var displayName: String {
        switch self {
        case .proMonthly:
            return "NexHub Pro"
        case .proAnnual:
            return "NexHub Pro Annual"
        }
    }

    var displayPrice: String {
        switch self {
        case .proMonthly:
            return L10n.text(zhHans: "¥39/月", en: "CNY 39/mo")
        case .proAnnual:
            return L10n.text(zhHans: "¥299/年", en: "CNY 299/yr")
        }
    }
}

enum CommerceInviteKind: String, CaseIterable, Codable {
    case internalAccess = "internal"
    case beta
    case referral
    case founder
    case trial
    case partner
    case custom

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = CommerceInviteKind(rawValue: rawValue) ?? .custom
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .internalAccess:
            return "Internal"
        case .beta:
            return "Beta"
        case .referral:
            return "Referral"
        case .founder:
            return "Founder"
        case .trial:
            return "Trial"
        case .partner:
            return "Partner"
        case .custom:
            return "Custom"
        }
    }
}

enum CommerceAccessTier: String, Codable {
    case free
    case pro
}

struct CommerceInviteRedemption: Codable {
    let code: String
    let kind: CommerceInviteKind
    let campaign: String
    let redeemedAt: Date
    let expiresAt: Date?
    let grantsPermanentPro: Bool
    let founderAnnualPrice: String?
}

struct CommerceSubscriptionState: Codable {
    let planID: String
    let startedAt: Date
    let expiresAt: Date
    let source: String

    var plan: CommerceSubscriptionPlan? {
        CommerceSubscriptionPlan(rawValue: planID)
    }

    var displayName: String {
        if let plan {
            return plan.displayName
        }
        return planID
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    var displayPrice: String? {
        plan?.displayPrice
    }
}

struct CommerceEntitlementSnapshot: Codable {
    let accessTier: CommerceAccessTier
    let activeSubscription: CommerceSubscriptionState?
    let activeInvite: CommerceInviteRedemption?
    let founderAnnualPrice: String?

    var isPro: Bool {
        accessTier == .pro
    }

    static let free = CommerceEntitlementSnapshot(
        accessTier: .free,
        activeSubscription: nil,
        activeInvite: nil,
        founderAnnualPrice: nil
    )
}

enum CommerceRedemptionResult {
    case success(message: String)
    case failure(message: String)
}

final class CommerceService {
    static let shared = CommerceService()

    private enum CommerceSettingKey {
        static let entitlementSnapshot = "commerce.entitlementSnapshot"
        static let redeemedInvites = "commerce.redeemedInvites"
        static let installationIDCache = "commerce.installationID.cache"
        static let deviceTokenCache = "commerce.deviceToken.cache"
    }

    private enum SecretKey {
        static let installationID = "commerce.installationID"
        static let deviceToken = "commerce.deviceToken"
    }

    private let defaults: UserDefaults
    private let nowProvider: () -> Date
    private let session: URLSession
    private let secretsStore: any SecretStoring
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var didStart = false

    init(
        defaults: UserDefaults = .standard,
        nowProvider: @escaping () -> Date = Date.init,
        session: URLSession = .shared,
        secretsStore: any SecretStoring = SecretsStore.shared
    ) {
        self.defaults = defaults
        self.nowProvider = nowProvider
        self.session = session
        self.secretsStore = secretsStore
        self.decoder = Self.makeJSONDecoder()
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
    }

    var entitlementSnapshot: CommerceEntitlementSnapshot {
        guard let data = defaults.data(forKey: CommerceSettingKey.entitlementSnapshot),
              let decoded = try? decoder.decode(CommerceEntitlementSnapshot.self, from: data) else {
            return recoveredLocalEntitlementFallback() ?? .free
        }
        return mergedEntitlementSnapshot(serverSnapshot: decoded)
    }

    var entitlementSnapshotIsReady: Bool {
        didStart || defaults.data(forKey: CommerceSettingKey.entitlementSnapshot) != nil
    }

    var founderAnnualPrice: String? {
        entitlementSnapshot.founderAnnualPrice
            ?? redeemedInvites.compactMap(\.founderAnnualPrice).last
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        Task {
            _ = try? await ensureRegisteredDevice()
            _ = await refreshEntitlements()
            _ = await ManagedAIConfigurationService.shared.refreshIfPossible()
        }
    }

    func canAccess(_ definition: SkillDefinition) -> Bool {
        let requiredTier = definition.requiredEntitlementTier
        switch requiredTier {
        case .none, .some(.free):
            return true
        case .some(.pro):
            return entitlementSnapshot.isPro
        }
    }

    func redemptionHistoryText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppSettings.shared.appLanguage.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let history = redeemedInvites.sorted { $0.redeemedAt > $1.redeemedAt }
        if !history.isEmpty {
            return history.map { redemption in
                let expiryText: String
                if redemption.grantsPermanentPro {
                    expiryText = L10n.text(zhHans: "永久权益", en: "Lifetime access")
                } else if let expiresAt = redemption.expiresAt {
                    expiryText = L10n.format(zhHans: "到期：%@", en: "Expires: %@", formatter.string(from: expiresAt))
                } else {
                    expiryText = L10n.text(zhHans: "无有效期", en: "No expiration")
                }
                return "\(redemption.kind.displayName) | \(redemption.campaign) | \(expiryText)"
            }
            .joined(separator: "\n")
        }

        if let invite = entitlementSnapshot.activeInvite {
            if invite.grantsPermanentPro {
                return L10n.format(zhHans: "%@ | 服务器权益 | 永久权益", en: "%@ | Server entitlement | Lifetime access", invite.kind.displayName)
            }
            if let expiresAt = invite.expiresAt {
                return L10n.format(zhHans: "%@ | 服务器权益 | 到期：%@", en: "%@ | Server entitlement | Expires: %@", invite.kind.displayName, formatter.string(from: expiresAt))
            }
        }

        return L10n.text(zhHans: "暂无邀请码兑换记录", en: "No invite redemptions yet")
    }

    @discardableResult
    func refreshEntitlements() async -> Bool {
        do {
            let deviceToken = try await ensureRegisteredDevice()
            let remote: RemoteEntitlementResponse = try await request(
                path: "/v1/entitlements/me",
                method: "GET",
                body: Optional<String>.none,
                deviceToken: deviceToken
            )
            persistEntitlementSnapshot(makeSnapshot(from: remote))
            return true
        } catch {
            return false
        }
    }

    func redeemInvite(code rawCode: String) async -> CommerceRedemptionResult {
        let normalized = Self.normalizeInviteCode(rawCode)
        guard !normalized.isEmpty else {
            return .failure(message: L10n.text(zhHans: "请输入激活码。", en: "Enter an activation code."))
        }

        do {
            let deviceToken = try await ensureRegisteredDevice()
            let response: RemoteRedeemResponse = try await request(
                path: "/v1/licenses/redeem",
                method: "POST",
                body: RedeemInviteRequest(code: normalized),
                deviceToken: deviceToken
            )

            let snapshot = makeSnapshot(from: response.entitlement)
            persistEntitlementSnapshot(snapshot)
            if let invite = snapshot.activeInvite {
                persistRedeemedInviteIfNeeded(invite)
            }
            return .success(message: response.message)
        } catch let error as CommerceServiceError {
            return .failure(message: error.localizedDescription)
        } catch {
            return .failure(message: L10n.text(zhHans: "激活码兑换失败，请稍后重试。", en: "Activation code redemption failed. Please try again shortly."))
        }
    }

    func activateLocalSubscription(_ plan: CommerceSubscriptionPlan) async -> CommerceRedemptionResult {
        let preview = "\(plan.displayName) · \(plan.displayPrice)"
        _ = await refreshEntitlements()
        return .failure(message: L10n.format(zhHans: "正式订阅支付还在接入中，当前先支持真实激活码；计划预览：%@。", en: "Direct subscription checkout is still being integrated. Real activation codes are supported for now; plan preview: %@.", preview))
    }

    func cancelSubscription() async -> CommerceRedemptionResult {
        let refreshed = await refreshEntitlements()
        return refreshed
            ? .success(message: L10n.text(zhHans: "已刷新服务器权益状态。", en: "Server entitlement status refreshed."))
            : .failure(message: L10n.text(zhHans: "刷新权益状态失败，请检查网络后重试。", en: "Failed to refresh entitlement status. Check your network and try again."))
    }

    func resetAllCommerceState() {
        defaults.removeObject(forKey: CommerceSettingKey.entitlementSnapshot)
        defaults.removeObject(forKey: CommerceSettingKey.redeemedInvites)
        defaults.removeObject(forKey: CommerceSettingKey.installationIDCache)
        defaults.removeObject(forKey: CommerceSettingKey.deviceTokenCache)
        _ = secretsStore.removeString(for: SecretKey.deviceToken)
        _ = secretsStore.removeString(for: SecretKey.installationID)
        defaults.synchronize()
        postStateDidChange()
    }

    private var redeemedInvites: [CommerceInviteRedemption] {
        guard let data = defaults.data(forKey: CommerceSettingKey.redeemedInvites),
              let decoded = try? decoder.decode([CommerceInviteRedemption].self, from: data) else {
            return []
        }
        return decoded
    }

    private func persistEntitlementSnapshot(_ snapshot: CommerceEntitlementSnapshot) {
        if let data = try? encoder.encode(snapshot) {
            defaults.set(data, forKey: CommerceSettingKey.entitlementSnapshot)
            defaults.synchronize()
            postStateDidChange()
        }
    }

    private func persistRedeemedInvites(_ invites: [CommerceInviteRedemption]) {
        if let data = try? encoder.encode(invites) {
            defaults.set(data, forKey: CommerceSettingKey.redeemedInvites)
            defaults.synchronize()
            postStateDidChange()
        }
    }

    private func persistRedeemedInviteIfNeeded(_ invite: CommerceInviteRedemption) {
        var history = redeemedInvites
        guard history.contains(where: { $0.code == invite.code }) == false else { return }
        history.append(invite)
        persistRedeemedInvites(history)
    }

    func ensureDeviceToken() async throws -> String {
        try await ensureRegisteredDevice()
    }

    func currentDeviceToken() -> String? {
        let token = (
            secretsStore.string(for: SecretKey.deviceToken)
            ?? defaults.string(forKey: CommerceSettingKey.deviceTokenCache)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }

    private func ensureRegisteredDevice() async throws -> String {
        if let existing = currentDeviceToken() {
            return existing
        }
        let installationID = resolvedInstallationID()
        let response: DeviceRegistrationResponse = try await request(
            path: "/v1/device/register",
            method: "POST",
            body: DeviceRegistrationRequest(
                installationId: installationID,
                deviceName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                platform: "macos",
                appVersion: Self.appVersion,
                buildNumber: Self.buildNumber
            )
        )
        persistDeviceCredentials(
            installationID: response.installationId.isEmpty ? installationID : response.installationId,
            deviceToken: response.deviceToken
        )
        return response.deviceToken
    }

    private func resolvedInstallationID() -> String {
        if let existing = (
            secretsStore.string(for: SecretKey.installationID)
            ?? defaults.string(forKey: CommerceSettingKey.installationIDCache)
        ),
           existing.isEmpty == false {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        persistInstallationID(generated)
        return generated
    }

    private func persistInstallationID(_ installationID: String) {
        defaults.set(installationID, forKey: CommerceSettingKey.installationIDCache)
        _ = secretsStore.setString(installationID, for: SecretKey.installationID)
    }

    private func persistDeviceCredentials(installationID: String, deviceToken: String) {
        persistInstallationID(installationID)
        defaults.set(deviceToken, forKey: CommerceSettingKey.deviceTokenCache)
        defaults.synchronize()
        _ = secretsStore.setString(deviceToken, for: SecretKey.deviceToken)
    }

    private func mergedEntitlementSnapshot(serverSnapshot: CommerceEntitlementSnapshot) -> CommerceEntitlementSnapshot {
        guard let localInvite = recoveredLocalEntitlementFallback()?.activeInvite else {
            return serverSnapshot
        }

        if serverSnapshot.isPro {
            return CommerceEntitlementSnapshot(
                accessTier: .pro,
                activeSubscription: serverSnapshot.activeSubscription,
                activeInvite: serverSnapshot.activeInvite ?? localInvite,
                founderAnnualPrice: serverSnapshot.founderAnnualPrice ?? localInvite.founderAnnualPrice
            )
        }

        return CommerceEntitlementSnapshot(
            accessTier: .pro,
            activeSubscription: serverSnapshot.activeSubscription,
            activeInvite: localInvite,
            founderAnnualPrice: serverSnapshot.founderAnnualPrice ?? localInvite.founderAnnualPrice
        )
    }

    private func recoveredLocalEntitlementFallback() -> CommerceEntitlementSnapshot? {
        let validInvites = redeemedInvites
            .filter { invite in
                if invite.grantsPermanentPro {
                    return true
                }
                guard let expiresAt = invite.expiresAt else {
                    return false
                }
                return expiresAt > nowProvider()
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.expiresAt ?? .distantFuture
                let rhsDate = rhs.expiresAt ?? .distantFuture
                if lhsDate == rhsDate {
                    return lhs.redeemedAt > rhs.redeemedAt
                }
                return lhsDate > rhsDate
            }

        guard let invite = validInvites.first else { return nil }
        return CommerceEntitlementSnapshot(
            accessTier: .pro,
            activeSubscription: nil,
            activeInvite: invite,
            founderAnnualPrice: invite.founderAnnualPrice
        )
    }

    private func makeSnapshot(from response: RemoteEntitlementResponse) -> CommerceEntitlementSnapshot {
        let subscription = response.activeSubscription.map {
            CommerceSubscriptionState(
                planID: $0.planId,
                startedAt: $0.startedAt,
                expiresAt: $0.currentPeriodEnd,
                source: $0.provider
            )
        }

        let invite = response.activeLicense.map {
            CommerceInviteRedemption(
                code: $0.code,
                kind: $0.kind,
                campaign: $0.kind.rawValue,
                redeemedAt: $0.redeemedAt,
                expiresAt: $0.expiresAt,
                grantsPermanentPro: $0.grantsPermanentPro,
                founderAnnualPrice: $0.founderAnnualPrice
            )
        }

        return CommerceEntitlementSnapshot(
            accessTier: response.accessTier,
            activeSubscription: subscription,
            activeInvite: invite,
            founderAnnualPrice: response.founderAnnualPrice
        )
    }

    private func postStateDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .commerceStateDidChange, object: nil)
        }
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body? = nil,
        deviceToken: String? = nil
    ) async throws -> Response {
        let baseURL = Self.configuredAPIBaseURL()
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw CommerceServiceError.local(L10n.text(zhHans: "接口地址无效", en: "Invalid API URL"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppBrand.clientIdentifier, forHTTPHeaderField: "X-Client-Id")
        if let deviceToken, deviceToken.isEmpty == false {
            request.setValue(deviceToken, forHTTPHeaderField: "x-device-token")
        }
        if let body {
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CommerceServiceError.network(L10n.text(zhHans: "服务器响应异常", en: "The server returned an invalid response"))
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? decoder.decode(APIErrorResponse.self, from: data)
            throw CommerceServiceError.network(apiError?.error ?? L10n.format(zhHans: "请求失败（%d）", en: "Request failed (%d)", httpResponse.statusCode))
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw CommerceServiceError.local(L10n.text(zhHans: "返回数据无法解析", en: "The response data could not be parsed"))
        }
    }

    private static func normalizeInviteCode(_ code: String) -> String {
        code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

    static func configuredAPIBaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["NEXHUB_COMMERCE_API_BASE_URL"],
           let url = URL(string: override.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil {
            return url
        }
        return URL(string: "https://api.nefish.net")!
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.iso8601WithFractional.date(from: value) ?? Self.iso8601.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
        }
        return decoder
    }

    static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

private enum CommerceServiceError: LocalizedError {
    case network(String)
    case local(String)

    var errorDescription: String? {
        switch self {
        case .network(let message), .local(let message):
            return message
        }
    }
}

private struct DeviceRegistrationRequest: Encodable {
    let installationId: String
    let deviceName: String
    let platform: String
    let appVersion: String
    let buildNumber: String
}

private struct RedeemInviteRequest: Encodable {
    let code: String
}

private struct DeviceRegistrationResponse: Decodable {
    let deviceId: String
    let installationId: String
    let deviceToken: String
}

private struct RemoteActiveLicense: Decodable {
    let code: String
    let kind: CommerceInviteKind
    let redeemedAt: Date
    let expiresAt: Date?
    let grantsPermanentPro: Bool
    let founderAnnualPrice: String?
}

private struct RemoteActiveSubscription: Decodable {
    let planId: String
    let provider: String
    let status: String
    let startedAt: Date
    let currentPeriodEnd: Date
}

private struct RemoteEntitlementResponse: Decodable {
    let accessTier: CommerceAccessTier
    let activeLicense: RemoteActiveLicense?
    let activeSubscription: RemoteActiveSubscription?
    let founderAnnualPrice: String?
    let skillCatalogUrl: String?
}

private struct RemoteRedeemResponse: Decodable {
    let ok: Bool
    let entitlement: RemoteEntitlementResponse
    let message: String
}

private struct APIErrorResponse: Decodable {
    let error: String
}
