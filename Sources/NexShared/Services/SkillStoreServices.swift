import CryptoKit
import Foundation

extension Notification.Name {
    static let skillRegistryDidReload = Notification.Name("nexhub.skillRegistryDidReload")
    static let skillInstallStateDidChange = Notification.Name("nexhub.skillInstallStateDidChange")
}

enum SkillSource: String, Codable {
    case builtin
    case installed
}

enum SkillReloadReason: String {
    case startup
    case catalogRefresh
    case install
    case update
    case uninstall
    case enablement
    case filesystemChange
    case manual
}

enum SkillCatalogSource: String, Codable {
    case remote
    case cache
    case bundledDemo = "bundled_demo"
}

enum SkillInstallOrigin: String, Codable {
    case officialStore = "official_store"
    case bundledDemo = "bundled_demo"
}

enum SkillListFilter: Int, CaseIterable {
    case all
    case installed
    case discover
    case updates

    var title: String {
        switch self {
        case .all: return L10n.text(zhHans: "全部", en: "All")
        case .installed: return L10n.text(zhHans: "已安装", en: "Installed")
        case .discover: return L10n.text(zhHans: "发现", en: "Discover")
        case .updates: return L10n.text(zhHans: "更新", en: "Updates")
        }
    }
}

enum SkillInstallResult {
    case success(message: String)
    case failure(message: String)
}

struct InstalledSkillRecord: Codable, Equatable {
    let skillID: String
    let currentVersion: String
    let isEnabled: Bool
    let source: SkillInstallOrigin
    let vendor: String
    let installedAt: Date
    let updateChannel: String?
    let lastVerificationPassed: Bool

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case currentVersion = "current_version"
        case isEnabled = "is_enabled"
        case source
        case vendor
        case installedAt = "installed_at"
        case updateChannel = "update_channel"
        case lastVerificationPassed = "last_verification_passed"
    }
}

struct SkillCatalogManifestSummary: Codable, Equatable {
    let id: String
    let name: String
    let version: String
    let author: String?
    let summary: String
    let icon: String
    let supportedContexts: [ActivationSource]
    let locality: SkillExecutionLocality
    let billingClass: SkillBillingClass
    let requiredTier: SkillEntitlementTier?
    let tags: [String]
    let vendor: String?
    let priorityTier: SkillPriorityTier?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case author
        case summary
        case icon
        case supportedContexts = "supported_contexts"
        case locality
        case billingClass = "billing_class"
        case requiredTier = "required_tier"
        case tags
        case vendor
        case priorityTier = "priority_tier"
    }
}

struct SkillCatalogItem: Codable, Equatable {
    let skillID: String
    let version: String
    let manifestSummary: SkillCatalogManifestSummary
    let iconURL: String?
    let packageURL: String
    let signatureURL: String?
    let releaseNotes: String?
    let minAppVersion: String?
    let isFeatured: Bool

    enum CodingKeys: String, CodingKey {
        case skillID = "skill_id"
        case version
        case manifestSummary = "manifest_summary"
        case iconURL = "icon_url"
        case packageURL = "package_url"
        case signatureURL = "signature_url"
        case releaseNotes = "release_notes"
        case minAppVersion = "min_app_version"
        case isFeatured = "is_featured"
    }
}

struct SkillCatalogSnapshot: Codable, Equatable {
    let items: [SkillCatalogItem]
    let source: SkillCatalogSource
    let fetchedAt: Date
    let catalogURL: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case items
        case source
        case fetchedAt = "fetched_at"
        case catalogURL = "catalog_url"
        case errorMessage = "error_message"
    }
}

struct SkillPackageRunner: Codable, Equatable {
    let relativePath: String

    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
    }
}

struct SkillPackageSignature: Codable, Equatable {
    let keyID: String
    let vendor: String
    let signedAt: String
    let payloadSHA256: String
    let signatureBase64: String

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case vendor
        case signedAt = "signed_at"
        case payloadSHA256 = "payload_sha256"
        case signatureBase64 = "signature_base64"
    }
}

struct SkillPackageArchive: Codable {
    let schemaVersion: String
    let manifest: SkillManifest
    let instruction: String
    let iconDataBase64: String?
    let runner: SkillPackageRunner?
    let signature: SkillPackageSignature?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case manifest
        case instruction
        case iconDataBase64 = "icon_data_base64"
        case runner
        case signature
    }

    func packageJSONObjectExcludingSignature() -> [String: Any] {
        var object: [String: Any] = [
            "schema_version": schemaVersion,
            "manifest": manifest.jsonObject(),
            "instruction": instruction,
        ]
        if let iconDataBase64 {
            object["icon_data_base64"] = iconDataBase64
        }
        if let runner {
            object["runner"] = ["relative_path": runner.relativePath]
        }
        return object
    }
}

struct SkillInventoryItem {
    let skillID: String
    let installedDefinition: SkillDefinition?
    let installedRecord: InstalledSkillRecord?
    let catalogItem: SkillCatalogItem?
    let isEnabled: Bool
    let updateAvailable: Bool

    var displayName: String {
        installedDefinition?.title
            ?? catalogItem?.manifestSummary.name
            ?? skillID
    }

    var summary: String {
        installedDefinition?.summary
            ?? catalogItem?.manifestSummary.summary
            ?? L10n.text(zhHans: "暂无描述", en: "No description yet")
    }

    var version: String {
        installedDefinition?.version
            ?? catalogItem?.version
            ?? "0.0.0"
    }

    var author: String? {
        installedDefinition?.manifest.author
            ?? catalogItem?.manifestSummary.author
    }

    var symbolName: String {
        installedDefinition?.symbolName
            ?? catalogItem?.manifestSummary.icon
            ?? "square.grid.2x2"
    }

    var supportedContexts: [ActivationSource] {
        installedDefinition?.supportedContexts
            ?? catalogItem?.manifestSummary.supportedContexts
            ?? []
    }

    var locality: SkillExecutionLocality {
        installedDefinition?.manifest.execution.locality
            ?? catalogItem?.manifestSummary.locality
            ?? .cloudOnly
    }

    var billingClass: SkillBillingClass {
        installedDefinition?.billingClass
            ?? catalogItem?.manifestSummary.billingClass
            ?? .free
    }

    var requiredTier: SkillEntitlementTier? {
        installedDefinition?.requiredEntitlementTier
            ?? catalogItem?.manifestSummary.requiredTier
    }

    var permissions: [SkillPermissionKind] {
        installedDefinition?.manifest.permissions?.permissions ?? []
    }

    var privacy: SkillPrivacyContract? {
        installedDefinition?.manifest.privacy
    }

    var sourceLabel: String {
        if installedDefinition?.skillSource == .builtin {
            return L10n.text(zhHans: "内置", en: "Built-in")
        }
        if let vendor = installedDefinition?.manifest.distribution?.vendor {
            return vendor == "nexhub" ? L10n.text(zhHans: "NexHub 官方", en: "Official") : vendor
        }
        if let vendor = catalogItem?.manifestSummary.vendor {
            return vendor == "nexhub" ? L10n.text(zhHans: "NexHub 官方", en: "Official") : vendor
        }
        return L10n.text(zhHans: "NexHub 官方", en: "Official")
    }

    var isInstalled: Bool {
        installedDefinition != nil || installedRecord != nil
    }
}

package enum SkillStorePaths {
    package static func appSupportRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = base.appendingPathComponent(AppBrand.supportDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func skillsRoot(fileManager: FileManager = .default) -> URL {
        let root = appSupportRoot(fileManager: fileManager).appendingPathComponent("Skills", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func skillDirectory(skillID: String, fileManager: FileManager = .default) -> URL {
        let root = skillsRoot(fileManager: fileManager).appendingPathComponent(skillID, isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func versionDirectory(skillID: String, version: String, fileManager: FileManager = .default) -> URL {
        let root = skillDirectory(skillID: skillID, fileManager: fileManager).appendingPathComponent(version, isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func installedRecordURL(skillID: String, fileManager: FileManager = .default) -> URL {
        skillDirectory(skillID: skillID, fileManager: fileManager).appendingPathComponent("installed.json")
    }

    static func catalogCacheURL(fileManager: FileManager = .default) -> URL {
        let root = appSupportRoot(fileManager: fileManager).appendingPathComponent("Store", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("catalog-cache.json")
    }
}

final class InstalledSkillStore {
    static let shared = InstalledSkillStore()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func installedRecords() -> [InstalledSkillRecord] {
        let root = SkillStorePaths.skillsRoot(fileManager: fileManager)
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return directories.compactMap { directory in
            let recordURL = directory.appendingPathComponent("installed.json")
            guard let data = try? Data(contentsOf: recordURL) else { return nil }
            return try? decoder.decode(InstalledSkillRecord.self, from: data)
        }
    }

    func record(forSkillID skillID: String) -> InstalledSkillRecord? {
        let url = SkillStorePaths.installedRecordURL(skillID: skillID, fileManager: fileManager)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstalledSkillRecord.self, from: data)
    }

    func persist(_ record: InstalledSkillRecord) throws {
        let url = SkillStorePaths.installedRecordURL(skillID: record.skillID, fileManager: fileManager)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: url, options: .atomic)
    }

    func setEnabled(_ enabled: Bool, forSkillID skillID: String) throws {
        guard let record = record(forSkillID: skillID) else { return }
        try persist(
            InstalledSkillRecord(
                skillID: record.skillID,
                currentVersion: record.currentVersion,
                isEnabled: enabled,
                source: record.source,
                vendor: record.vendor,
                installedAt: record.installedAt,
                updateChannel: record.updateChannel,
                lastVerificationPassed: record.lastVerificationPassed
            )
        )
    }

    func uninstall(skillID: String) throws {
        let root = SkillStorePaths.skillDirectory(skillID: skillID, fileManager: fileManager)
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
    }
}

final class SkillCatalogService {
    static let shared = SkillCatalogService()

    private let session: URLSession
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
    }

    func currentSnapshot() -> SkillCatalogSnapshot? {
        let cacheURL = SkillStorePaths.catalogCacheURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? decoder.decode(SkillCatalogSnapshot.self, from: data)
    }

    func refreshCatalog() async -> SkillCatalogSnapshot {
        if let remoteURL = configuredCatalogURL() {
            do {
                let (items, resolvedURL) = try await fetchCatalog(from: remoteURL)
                let snapshot = SkillCatalogSnapshot(
                    items: items,
                    source: .remote,
                    fetchedAt: Date(),
                    catalogURL: resolvedURL.absoluteString,
                    errorMessage: nil
                )
                persist(snapshot)
                return snapshot
            } catch {
                if let cached = currentSnapshot() {
                    return SkillCatalogSnapshot(
                        items: cached.items,
                        source: .cache,
                        fetchedAt: cached.fetchedAt,
                        catalogURL: cached.catalogURL,
                        errorMessage: error.localizedDescription
                    )
                }
            }
        }

        if let bundled = loadBundledCatalog() {
            let snapshot = SkillCatalogSnapshot(
                items: bundled.items,
                source: .bundledDemo,
                fetchedAt: Date(),
                catalogURL: bundled.baseURL.absoluteString,
                errorMessage: nil
            )
            persist(snapshot)
            return snapshot
        }

        return SkillCatalogSnapshot(
            items: [],
            source: .cache,
            fetchedAt: Date(),
            catalogURL: nil,
            errorMessage: L10n.text(zhHans: "暂无可用技能目录", en: "No skill catalog is currently available")
        )
    }

    func resolvePackageURL(for item: SkillCatalogItem, snapshot: SkillCatalogSnapshot?) -> URL? {
        if let direct = URL(string: item.packageURL), direct.scheme != nil {
            return direct
        }
        guard let base = snapshot?.catalogURL.flatMap(URL.init(string:)) else { return nil }
        return URL(string: item.packageURL, relativeTo: base)?.absoluteURL
    }

    private func configuredCatalogURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["NEXHUB_SKILL_CATALOG_URL"],
           let url = URL(string: override.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme != nil {
            return url
        }
        return URL(string: "https://skills.nefish.net/v1/skills/catalog")
    }

    private func fetchCatalog(from url: URL) async throws -> ([SkillCatalogItem], URL) {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ActionError.network("Skill catalog unavailable")
        }
        let items = try decoder.decode([SkillCatalogItem].self, from: data)
        return (items, url.deletingLastPathComponent())
    }

    private func loadBundledCatalog() -> (items: [SkillCatalogItem], baseURL: URL)? {
        for root in SkillRegistry.skillStoreRoots() {
            let catalogURL = root.appendingPathComponent("catalog.json")
            guard let data = try? Data(contentsOf: catalogURL),
                  let items = try? decoder.decode([SkillCatalogItem].self, from: data) else {
                continue
            }
            return (items, root)
        }
        return nil
    }

    private func persist(_ snapshot: SkillCatalogSnapshot) {
        let cacheURL = SkillStorePaths.catalogCacheURL(fileManager: fileManager)
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}

final class SkillPackageManager {
    static let shared = SkillPackageManager()

    private let catalogService: SkillCatalogService
    private let installedStore: InstalledSkillStore
    private let fileManager: FileManager
    private let session: URLSession
    private let settings: AppSettings
    private let publicKeysByID: [String: P256.Signing.PublicKey]

    init(
        catalogService: SkillCatalogService = .shared,
        installedStore: InstalledSkillStore = .shared,
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        settings: AppSettings = .shared
    ) {
        self.catalogService = catalogService
        self.installedStore = installedStore
        self.fileManager = fileManager
        self.session = session
        self.settings = settings
        self.publicKeysByID = Self.makePublicKeys()
    }

    func installCatalogItem(_ item: SkillCatalogItem, snapshot: SkillCatalogSnapshot?) async -> SkillInstallResult {
        guard let packageURL = catalogService.resolvePackageURL(for: item, snapshot: snapshot) else {
            return .failure(message: L10n.text(zhHans: "无法解析技能包地址", en: "Unable to resolve the skill package URL"))
        }

        do {
            let data = try await downloadPackage(from: packageURL)
            let archive = try decodePackage(from: data)
            try validatePackage(archive, packageData: data)
            try install(archive: archive, source: snapshot?.source == .bundledDemo ? .bundledDemo : .officialStore)
            SkillRegistry.shared.reload(reason: .install)
            postInstallStateChanged()
            return .success(message: L10n.format(zhHans: "已安装 %@", en: "Installed %@", archive.manifest.name))
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    func updateCatalogItem(_ item: SkillCatalogItem, snapshot: SkillCatalogSnapshot?) async -> SkillInstallResult {
        let result = await installCatalogItem(item, snapshot: snapshot)
        if case .success = result {
            SkillRegistry.shared.reload(reason: .update)
        }
        return result
    }

    func uninstallSkill(skillID: String) -> SkillInstallResult {
        do {
            try installedStore.uninstall(skillID: skillID)
            settings.clearSkillEnabledOverride(forSkillID: skillID)
            SkillRegistry.shared.reload(reason: .uninstall)
            postInstallStateChanged()
            return .success(message: L10n.format(zhHans: "已卸载 %@", en: "Uninstalled %@", skillID))
        } catch {
            return .failure(message: L10n.format(zhHans: "卸载失败：%@", en: "Uninstall failed: %@", error.localizedDescription))
        }
    }

    func setEnabled(_ enabled: Bool, forSkillID skillID: String) -> SkillInstallResult {
        do {
            try installedStore.setEnabled(enabled, forSkillID: skillID)
            settings.clearSkillEnabledOverride(forSkillID: skillID)
            SkillRegistry.shared.reload(reason: .enablement)
            postInstallStateChanged()
            return .success(message: enabled
                ? L10n.text(zhHans: "已启用", en: "Enabled")
                : L10n.text(zhHans: "已禁用", en: "Disabled"))
        } catch {
            return .failure(message: L10n.format(zhHans: "更新技能状态失败：%@", en: "Failed to update the skill state: %@", error.localizedDescription))
        }
    }

    private func postInstallStateChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .skillInstallStateDidChange, object: nil)
        }
    }

    private func downloadPackage(from url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ActionError.network(L10n.text(zhHans: "下载技能包失败", en: "Failed to download the skill package"))
        }
        return data
    }

    private func decodePackage(from data: Data) throws -> SkillPackageArchive {
        let decoder = JSONDecoder()
        return try decoder.decode(SkillPackageArchive.self, from: data)
    }

    private func validatePackage(_ archive: SkillPackageArchive, packageData: Data) throws {
        let vendor = archive.manifest.distribution?.vendor ?? archive.signature?.vendor ?? ""
        if vendor == "nexhub" {
            guard let signature = archive.signature else {
                throw ActionError.network(L10n.text(zhHans: "官方技能包缺少签名", en: "Official skill package is missing a signature"))
            }
            try validateOfficialSignature(signature, archive: archive)
        }

        if archive.runner != nil && vendor != "nexhub" {
            throw ActionError.network(L10n.text(zhHans: "仅官方技能允许携带本地 runner", en: "Only official skills may include a local runner"))
        }

        _ = packageData
    }

    private func validateOfficialSignature(_ signature: SkillPackageSignature, archive: SkillPackageArchive) throws {
        guard let publicKey = publicKeysByID[signature.keyID] else {
            throw ActionError.network(L10n.text(zhHans: "技能签名密钥不可识别", en: "Unrecognized skill signature key"))
        }
        let payload = archive.packageJSONObjectExcludingSignature()
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let payloadHash = SHA256.hash(data: payloadData).hexString
        guard payloadHash == signature.payloadSHA256.lowercased() else {
            throw ActionError.network(L10n.text(zhHans: "技能包签名摘要不匹配", en: "Skill package signature digest mismatch"))
        }
        guard let signatureData = Data(base64Encoded: signature.signatureBase64) else {
            throw ActionError.network(L10n.text(zhHans: "技能包签名格式无效", en: "Invalid skill package signature format"))
        }
        let ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        guard publicKey.isValidSignature(ecdsaSignature, for: Data(signature.payloadSHA256.utf8)) else {
            throw ActionError.network(L10n.text(zhHans: "技能包签名校验失败", en: "Skill package signature verification failed"))
        }
    }

    private func install(archive: SkillPackageArchive, source: SkillInstallOrigin) throws {
        let manifest = archive.manifest
        let version = manifest.version ?? "0.1.0"
        let versionDirectory = SkillStorePaths.versionDirectory(skillID: manifest.id, version: version, fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: versionDirectory.appendingPathComponent("manifest.json"), options: .atomic)
        try Data(archive.instruction.utf8).write(to: versionDirectory.appendingPathComponent("instruction.md"), options: .atomic)

        if let iconDataBase64 = archive.iconDataBase64,
           let iconData = Data(base64Encoded: iconDataBase64) {
            try iconData.write(to: versionDirectory.appendingPathComponent("icon.bin"), options: .atomic)
        }

        if let runner = archive.runner {
            let runnerDirectory = versionDirectory.appendingPathComponent("runner", isDirectory: true)
            try fileManager.createDirectory(at: runnerDirectory, withIntermediateDirectories: true)
            let relativePath = (runner.relativePath as NSString).lastPathComponent
            try Data("#!/usr/bin/env bash\nexit 0\n".utf8).write(
                to: runnerDirectory.appendingPathComponent(relativePath),
                options: .atomic
            )
        }

        let record = InstalledSkillRecord(
            skillID: manifest.id,
            currentVersion: version,
            isEnabled: manifest.settings?.defaultEnabled ?? true,
            source: source,
            vendor: manifest.distribution?.vendor ?? "nexhub",
            installedAt: Date(),
            updateChannel: manifest.distribution?.channel?.rawValue,
            lastVerificationPassed: true
        )
        try installedStore.persist(record)
    }

    private static func makePublicKeys() -> [String: P256.Signing.PublicKey] {
        var result: [String: P256.Signing.PublicKey] = [:]
        if let data = Data(base64Encoded: "5dD7wjGNzUv5fM7oUw8zA7HkEgdZ+LS1Xrcgzuny5uB20bkCX3PhmJQ185nwH/oV1qjq8WA/FTUHqGKJrcVDAw=="),
           let key = try? P256.Signing.PublicKey(rawRepresentation: data) {
            result["nexhub-demo-20260316"] = key
        }
        if let data = Data(base64Encoded: "BMKqH2d/o0x6e6D9dR6IjsfcwuFHq522dK37I4k4A6grIY2hNaow4hNQT2mp6GVJxk8qfj1kqygofHTANSeb4U8="),
           let key = try? P256.Signing.PublicKey(rawRepresentation: data) {
            result["nexhub-official-20260318"] = key
        }
        return result
    }
}

final class SkillHotReloadCoordinator {
    static let shared = SkillHotReloadCoordinator()

    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "nexhub.skill-hotreload")
    private var pendingReloadWorkItem: DispatchWorkItem?

    func start() {
        stop()
        let root = SkillStorePaths.skillsRoot()
        fileDescriptor = open(root.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }
        self.source = source
        source.resume()
    }

    func stop() {
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil
        source?.cancel()
        source = nil
    }

    private func scheduleReload() {
        pendingReloadWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            SkillRegistry.shared.reload(reason: .filesystemChange)
        }
        pendingReloadWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }
}

final class SkillRegistry {
    static let shared = SkillRegistry()

    private let lock = NSLock()
    private let installedStore: InstalledSkillStore
    private let catalogService: SkillCatalogService

    private var definitions: [SkillDefinition] = []
    private var installedRecordsBySkillID: [String: InstalledSkillRecord] = [:]
    private var catalogSnapshotValue: SkillCatalogSnapshot?

    init(
        installedStore: InstalledSkillStore = .shared,
        catalogService: SkillCatalogService = .shared
    ) {
        self.installedStore = installedStore
        self.catalogService = catalogService
        reload(reason: .startup)
    }

    var allDefinitions: [SkillDefinition] {
        withLock { definitions }
    }

    var catalogSnapshot: SkillCatalogSnapshot? {
        withLock { catalogSnapshotValue }
    }

    func definition(forSkillID skillID: String) -> SkillDefinition? {
        withLock { definitions.first(where: { $0.skillID == skillID }) }
    }

    func installedRecord(forSkillID skillID: String) -> InstalledSkillRecord? {
        withLock { installedRecordsBySkillID[skillID] }
    }

    func installedUserVisibleSkills() -> [SkillDefinition] {
        withLock { definitions.filter { $0.isUserConfigurable && !$0.isCapabilityShim } }
    }

    func defaultEnabled(forSkillID skillID: String) -> Bool? {
        withLock { installedRecordsBySkillID[skillID]?.isEnabled }
    }

    func inventoryItems(settings: AppSettings = .shared, filter: SkillListFilter = .all, query: String = "") -> [SkillInventoryItem] {
        let loweredQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return withLock {
            let catalogBySkillID = Dictionary(uniqueKeysWithValues: (catalogSnapshotValue?.items ?? []).map { ($0.skillID, $0) })
            let installedBySkillID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.skillID, $0) })
            let allSkillIDs = Set(catalogBySkillID.keys).union(installedBySkillID.keys)

            let items = allSkillIDs.compactMap { skillID -> SkillInventoryItem? in
                let definition = installedBySkillID[skillID]
                let record = installedRecordsBySkillID[skillID]
                let catalogItem = catalogBySkillID[skillID]
                if definition?.isCapabilityShim == true {
                    return nil
                }
                let baselineEnabled = record?.isEnabled ?? definition?.defaultEnabled ?? true
                let isEnabled = settings.isSkillEnabled(skillID, defaultEnabled: baselineEnabled)
                let updateAvailable: Bool
                if let record, let catalogItem {
                    updateAvailable = Self.compareVersion(catalogItem.version, to: record.currentVersion) == .orderedDescending
                } else {
                    updateAvailable = false
                }
                return SkillInventoryItem(
                    skillID: skillID,
                    installedDefinition: definition,
                    installedRecord: record,
                    catalogItem: catalogItem,
                    isEnabled: isEnabled,
                    updateAvailable: updateAvailable
                )
            }

            return items
                .filter { item in
                    switch filter {
                    case .all:
                        return true
                    case .installed:
                        return item.isInstalled
                    case .discover:
                        return !item.isInstalled
                    case .updates:
                        return item.updateAvailable
                    }
                }
                .filter { item in
                    guard !loweredQuery.isEmpty else { return true }
                    return item.displayName.lowercased().contains(loweredQuery)
                        || item.summary.lowercased().contains(loweredQuery)
                        || item.skillID.lowercased().contains(loweredQuery)
                }
                .sorted(by: Self.sortInventoryItems)
        }
    }

    func reload(reason: SkillReloadReason) {
        let builtin = Self.loadBuiltinDefinitions()
        let installed = Self.loadInstalledDefinitions(records: installedStore.installedRecords())
        let merged = Self.mergeDefinitions(builtin: builtin, installed: installed)
        let records = Dictionary(uniqueKeysWithValues: installedStore.installedRecords().map { ($0.skillID, $0) })
        let snapshot = catalogService.currentSnapshot()

        lock.lock()
        definitions = merged
        installedRecordsBySkillID = records
        catalogSnapshotValue = snapshot
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .skillRegistryDidReload,
                object: self,
                userInfo: ["reason": reason.rawValue]
            )
        }
    }

    func setCatalogSnapshot(_ snapshot: SkillCatalogSnapshot) {
        lock.lock()
        catalogSnapshotValue = snapshot
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .skillRegistryDidReload,
                object: self,
                userInfo: ["reason": SkillReloadReason.catalogRefresh.rawValue]
            )
        }
    }

    static func skillStoreRoots(bundle: Bundle = .main) -> [URL] {
        var roots: [URL] = []
        if let resourceURL = bundle.resourceURL {
            roots.append(resourceURL.appendingPathComponent("SkillStore", isDirectory: true))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        roots.append(cwd.appendingPathComponent("SkillStore", isDirectory: true))
        return roots
    }

    private static func loadBuiltinDefinitions(bundle: Bundle = .main) -> [SkillDefinition] {
        ActionRegistry.loadAvailableBuiltinDefinitions(from: bundle)
    }

    private static func loadInstalledDefinitions(records: [InstalledSkillRecord]) -> [SkillDefinition] {
        let decoder = JSONDecoder()
        return records.compactMap { record in
            let versionDirectory = SkillStorePaths.versionDirectory(skillID: record.skillID, version: record.currentVersion)
            let manifestURL = versionDirectory.appendingPathComponent("manifest.json")
            let instructionURL = versionDirectory.appendingPathComponent("instruction.md")
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(SkillManifest.self, from: manifestData) else {
                return nil
            }
            let instructionText = ((try? String(contentsOf: instructionURL, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return SkillDefinition(
                legacyAction: QuickAction(skillID: manifest.id),
                manifest: manifest,
                instructionText: instructionText.isEmpty ? nil : instructionText,
                sourceDirectory: versionDirectory,
                skillSource: .installed
            )
        }
    }

    private static func mergeDefinitions(builtin: [SkillDefinition], installed: [SkillDefinition]) -> [SkillDefinition] {
        var merged = Dictionary(uniqueKeysWithValues: builtin.map { ($0.skillID, $0) })
        for definition in installed {
            merged[definition.skillID] = definition
        }
        return merged.values.sorted(by: ActionRegistry.sortForPresentation)
    }

    private static func sortInventoryItems(_ lhs: SkillInventoryItem, _ rhs: SkillInventoryItem) -> Bool {
        if lhs.isInstalled != rhs.isInstalled {
            return lhs.isInstalled && !rhs.isInstalled
        }
        if lhs.updateAvailable != rhs.updateAvailable {
            return lhs.updateAvailable && !rhs.updateAvailable
        }
        if (lhs.catalogItem?.isFeatured ?? false) != (rhs.catalogItem?.isFeatured ?? false) {
            return lhs.catalogItem?.isFeatured == true
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private static func compareVersion(_ lhs: String, to rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }
}

private extension SHA256Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension SkillManifest {
    func jsonObject() -> [String: Any] {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}
