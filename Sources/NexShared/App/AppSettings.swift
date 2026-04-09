import AppKit
import Foundation

extension Notification.Name {
    static let appSettingsDidChange = Notification.Name("nexhub.appSettingsDidChange")
    static let appSettingsSecureStorageDidFail = Notification.Name("nexhub.appSettingsSecureStorageDidFail")
}

struct AppSettingsSecureStorageFailure {
    let settingKey: String
    let account: String
}

enum AppSettingsError: Error, LocalizedError, Equatable {
    case secureStorageFailed(settingKey: String)

    var errorDescription: String? {
        switch self {
        case .secureStorageFailed(let settingKey):
            switch settingKey {
            case SettingKey.llmApiKey:
                return L10n.text(
                    zhHans: "API Key 没有安全保存成功，请检查钥匙串访问权限后重试。",
                    en: "The API key could not be saved securely. Check Keychain access and try again."
                )
            case SettingKey.notionIntegrationToken:
                return L10n.text(
                    zhHans: "Notion Token 没有安全保存成功，请检查钥匙串访问权限后重试。",
                    en: "The Notion token could not be saved securely. Check Keychain access and try again."
                )
            default:
                return L10n.text(
                    zhHans: "敏感配置没有安全保存成功，请检查钥匙串访问权限后重试。",
                    en: "The sensitive setting could not be saved securely. Check Keychain access and try again."
                )
            }
        }
    }
}

enum SettingKey {
    static let autoToolbarEnabled = "autoToolbarEnabled"
    static let textSelectionEnabled = "textSelectionEnabled"
    static let fileSelectionEnabled = "fileSelectionEnabled"
    static let screenshotEnabled = "screenshotEnabled"
    static let conversationBoxEnabled = "conversationBoxEnabled"
    static let legacyConversationBoxEnabled = "askBoxEnabled"
    static let compatibilityBridgeBundleIDs = "compatibilityBridgeBundleIDs"
    static let skillEnabledOverrides = "skillEnabledOverrides"
    static let knowledgeBaseEnabledOverrides = "knowledgeBaseEnabledOverrides"
    static let translateEnabled = "translateEnabled"
    static let traceEnabled = "traceEnabled"
    static let explainEnabled = "explainEnabled"
    static let replyEnabled = "replyEnabled"
    static let scheduleEnabled = "scheduleEnabled"
    static let compressEnabled = "compressEnabled"
    static let legacyImageCompressEnabled = "imageCompressEnabled"
    static let llmProvider = "llmProvider"
    static let llmApiKey = "llmApiKey"
    static let llmModel = "llmModel"
    static let notionIntegrationToken = "notionIntegrationToken"
    static let knowledgeBaseNotionTargets = "knowledgeBaseNotionTargets"
    static let knowledgeBaseNotionAutoSyncEnabled = "knowledgeBaseNotionAutoSyncEnabled"
    static let knowledgeBaseNotionLastSyncTimeInterval = "knowledgeBaseNotionLastSyncTimeInterval"
    static let legacyReplyKnowledgeBaseNotionTargets = "replyKnowledgeBaseNotionTargets"
    static let legacyReplyKnowledgeBaseNotionAutoSyncEnabled = "replyKnowledgeBaseNotionAutoSyncEnabled"
    static let legacyReplyKnowledgeBaseNotionLastSyncTimeInterval = "replyKnowledgeBaseNotionLastSyncTimeInterval"
    static let translationPromptTemplate = "translationPromptTemplate"
    static let explanationPromptTemplate = "explanationPromptTemplate"
    static let replyPromptTemplate = "replyPromptTemplate"
    static let dismissOnOutsideClick = "dismissOnOutsideClick"
    static let appLanguage = "appLanguage"
    static let launchAtLoginPreferred = "launchAtLoginPreferred"
    static let didAttemptDefaultLaunchAtLoginSetup = "didAttemptDefaultLaunchAtLoginSetup"
    static let screenshotShortcutKeyCode = "screenshotShortcutKeyCode"
    static let screenshotShortcutModifierFlags = "screenshotShortcutModifierFlags"
    static let screenshotShortcutReplaceConflicts = "screenshotShortcutReplaceConflicts"
    static let screenshotSaveDirectoryPath = "screenshotSaveDirectoryPath"
    static let calendarAutomationPermissionGranted = "calendarAutomationPermissionGranted"
}

struct KeyboardShortcut: Equatable {
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags

    static let defaultScreenshot = KeyboardShortcut(
        keyCode: 21, // 4
        modifierFlags: [.command, .shift]
    )
}

package final class AppSettings {
    package static let shared = AppSettings()
    private static let llmApiKeyAccount = "llmApiKey"
    private static let notionIntegrationTokenAccount = "notionIntegrationToken"
    private let defaults: UserDefaults
    private let secretsStore: any SecretStoring
    private let diagnosticsLogger: DiagnosticsLogger

    init(
        defaults: UserDefaults = .standard,
        secretsStore: any SecretStoring = SecretsStore.shared,
        diagnosticsLogger: DiagnosticsLogger = .shared
    ) {
        self.defaults = defaults
        self.secretsStore = secretsStore
        self.diagnosticsLogger = diagnosticsLogger
        registerDefaults()
        migrateLegacySkillSettingsIfNeeded()
        migrateLegacySecretsIfNeeded()
    }

    var autoToolbarEnabled: Bool {
        get { textSelectionEnabled }
        set { textSelectionEnabled = newValue }
    }

    package var appLanguage: AppLanguage {
        get {
            guard let rawValue = defaults.string(forKey: SettingKey.appLanguage),
                  let language = AppLanguage(rawValue: rawValue) else {
                return .simplifiedChinese
            }
            return language
        }
        set { write(newValue.rawValue, forKey: SettingKey.appLanguage) }
    }

    var textSelectionEnabled: Bool {
        get {
            guard AppProductProfile.current.supportsTextSelectionEntry else { return false }
            if defaults.object(forKey: SettingKey.textSelectionEnabled) != nil {
                return defaults.bool(forKey: SettingKey.textSelectionEnabled)
            }
            return defaults.bool(forKey: SettingKey.autoToolbarEnabled)
        }
        set {
            guard AppProductProfile.current.supportsTextSelectionEntry else { return }
            write(newValue, forKey: SettingKey.textSelectionEnabled)
            defaults.set(newValue, forKey: SettingKey.autoToolbarEnabled)
            defaults.synchronize()
        }
    }

    var fileSelectionEnabled: Bool {
        get {
            guard AppProductProfile.current.supportsFileSelectionEntry else { return false }
            return defaults.object(forKey: SettingKey.fileSelectionEnabled) as? Bool ?? true
        }
        set {
            guard AppProductProfile.current.supportsFileSelectionEntry else { return }
            write(newValue, forKey: SettingKey.fileSelectionEnabled)
        }
    }

    var screenshotEnabled: Bool {
        get {
            guard AppProductProfile.current.supportsScreenshotEntry else { return false }
            return defaults.object(forKey: SettingKey.screenshotEnabled) as? Bool ?? true
        }
        set {
            guard AppProductProfile.current.supportsScreenshotEntry else { return }
            write(newValue, forKey: SettingKey.screenshotEnabled)
        }
    }

    package var conversationBoxEnabled: Bool {
        get {
            guard AppProductProfile.current.supportsConversationBoxEntry else { return false }
            if let currentValue = defaults.object(forKey: SettingKey.conversationBoxEnabled) as? Bool {
                return currentValue
            }
            if let legacyValue = defaults.object(forKey: SettingKey.legacyConversationBoxEnabled) as? Bool {
                return legacyValue
            }
            return true
        }
        set {
            guard AppProductProfile.current.supportsConversationBoxEntry else { return }
            write(newValue, forKey: SettingKey.conversationBoxEnabled)
        }
    }

    var compatibilityBridgeBundleIDs: [String] {
        get {
            defaults.stringArray(forKey: SettingKey.compatibilityBridgeBundleIDs)
                ?? RunningApplicationCatalog.defaultCompatibilityBundleIDs
        }
        set { write(newValue, forKey: SettingKey.compatibilityBridgeBundleIDs) }
    }

    var translateEnabled: Bool {
        get { isSkillEnabled("translate", defaultEnabled: true) }
        set { setSkillEnabled(newValue, forSkillID: "translate", defaultEnabled: true) }
    }

    var traceEnabled: Bool {
        get { isSkillEnabled("trace", defaultEnabled: true) }
        set { setSkillEnabled(newValue, forSkillID: "trace", defaultEnabled: true) }
    }

    var explainEnabled: Bool {
        get { isSkillEnabled("explain", defaultEnabled: true) }
        set { setSkillEnabled(newValue, forSkillID: "explain", defaultEnabled: true) }
    }

    var replyEnabled: Bool {
        get { isSkillEnabled("reply", defaultEnabled: true) }
        set { setSkillEnabled(newValue, forSkillID: "reply", defaultEnabled: true) }
    }

    var scheduleEnabled: Bool {
        get { isSkillEnabled("schedule", defaultEnabled: true) }
        set { setSkillEnabled(newValue, forSkillID: "schedule", defaultEnabled: true) }
    }

    var compressEnabled: Bool {
        get {
            let defaultEnabled = true
            if skillEnabledOverrideValue(forSkillID: "compress") != nil {
                return isSkillEnabled("compress", defaultEnabled: defaultEnabled)
            }
            if defaults.object(forKey: SettingKey.compressEnabled) != nil {
                return defaults.bool(forKey: SettingKey.compressEnabled)
            }
            if defaults.object(forKey: SettingKey.legacyImageCompressEnabled) != nil {
                return defaults.bool(forKey: SettingKey.legacyImageCompressEnabled)
            }
            return defaultEnabled
        }
        set {
            setSkillEnabled(newValue, forSkillID: "compress", defaultEnabled: true)
            defaults.removeObject(forKey: SettingKey.legacyImageCompressEnabled)
        }
    }

    func isSkillEnabled(_ skillID: String, defaultEnabled: Bool) -> Bool {
        if let override = skillEnabledOverrideValue(forSkillID: skillID) {
            return override
        }
        return defaultEnabled
    }

    func setSkillEnabled(_ enabled: Bool, forSkillID skillID: String, defaultEnabled: Bool) {
        var overrides = skillEnabledOverrides
        if enabled == defaultEnabled {
            overrides.removeValue(forKey: skillID)
        } else {
            overrides[skillID] = enabled
        }
        write(overrides, forKey: SettingKey.skillEnabledOverrides)
    }

    func clearSkillEnabledOverride(forSkillID skillID: String) {
        var overrides = skillEnabledOverrides
        overrides.removeValue(forKey: skillID)
        write(overrides, forKey: SettingKey.skillEnabledOverrides)
    }

    func isKnowledgeBaseEnabled(forSkillID skillID: String, defaultEnabled: Bool) -> Bool {
        if let override = knowledgeBaseEnabledOverrideValue(forSkillID: skillID) {
            return override
        }
        return defaultEnabled
    }

    func setKnowledgeBaseEnabled(_ enabled: Bool, forSkillID skillID: String, defaultEnabled: Bool) {
        var overrides = knowledgeBaseEnabledOverrides
        if enabled == defaultEnabled {
            overrides.removeValue(forKey: skillID)
        } else {
            overrides[skillID] = enabled
        }
        write(overrides, forKey: SettingKey.knowledgeBaseEnabledOverrides)
    }

    var llmProvider: String {
        get { defaults.string(forKey: SettingKey.llmProvider) ?? "openai" }
        set { write(newValue, forKey: SettingKey.llmProvider) }
    }

    var llmApiKey: String {
        get {
            if let secret = secretsStore.string(for: Self.llmApiKeyAccount) {
                return secret
            }
            return defaults.string(forKey: SettingKey.llmApiKey) ?? ""
        }
        set {
            do {
                try persistSecret(
                    newValue,
                    account: Self.llmApiKeyAccount,
                    legacySettingKey: SettingKey.llmApiKey
                )
            } catch {}
        }
    }

    var llmModel: String {
        get { defaults.string(forKey: SettingKey.llmModel) ?? "gpt-4.1-mini" }
        set { write(newValue, forKey: SettingKey.llmModel) }
    }

    var notionIntegrationToken: String {
        get {
            if let secret = secretsStore.string(for: Self.notionIntegrationTokenAccount) {
                return secret
            }
            return defaults.string(forKey: SettingKey.notionIntegrationToken) ?? ""
        }
        set {
            do {
                try persistSecret(
                    newValue,
                    account: Self.notionIntegrationTokenAccount,
                    legacySettingKey: SettingKey.notionIntegrationToken
                )
            } catch {}
        }
    }

    func updateAIConfiguration(provider: String, model: String, apiKey: String) throws {
        try persistSecret(
            apiKey,
            account: Self.llmApiKeyAccount,
            legacySettingKey: SettingKey.llmApiKey
        )
        defaults.set(provider, forKey: SettingKey.llmProvider)
        defaults.set(model, forKey: SettingKey.llmModel)
        defaults.synchronize()
        postDidChange()
    }

    func updateNotionIntegrationToken(_ value: String) throws {
        try persistSecret(
            value,
            account: Self.notionIntegrationTokenAccount,
            legacySettingKey: SettingKey.notionIntegrationToken
        )
    }

    var knowledgeBaseNotionTargets: String {
        get {
            defaults.string(forKey: SettingKey.knowledgeBaseNotionTargets)
                ?? defaults.string(forKey: SettingKey.legacyReplyKnowledgeBaseNotionTargets)
                ?? ""
        }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            write(normalized, forKey: SettingKey.knowledgeBaseNotionTargets)
            defaults.removeObject(forKey: SettingKey.legacyReplyKnowledgeBaseNotionTargets)
            defaults.synchronize()
        }
    }

    var knowledgeBaseNotionAutoSyncEnabled: Bool {
        get {
            if let value = defaults.object(forKey: SettingKey.knowledgeBaseNotionAutoSyncEnabled) as? Bool {
                return value
            }
            if let legacyValue = defaults.object(forKey: SettingKey.legacyReplyKnowledgeBaseNotionAutoSyncEnabled) as? Bool {
                return legacyValue
            }
            return true
        }
        set {
            write(newValue, forKey: SettingKey.knowledgeBaseNotionAutoSyncEnabled)
            defaults.removeObject(forKey: SettingKey.legacyReplyKnowledgeBaseNotionAutoSyncEnabled)
            defaults.synchronize()
        }
    }

    var knowledgeBaseNotionLastSyncAt: Date? {
        get {
            let raw = (defaults.object(forKey: SettingKey.knowledgeBaseNotionLastSyncTimeInterval) as? Double)
                ?? (defaults.object(forKey: SettingKey.legacyReplyKnowledgeBaseNotionLastSyncTimeInterval) as? Double)
            guard let raw, raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw)
        }
        set {
            if let newValue {
                write(newValue.timeIntervalSince1970, forKey: SettingKey.knowledgeBaseNotionLastSyncTimeInterval)
                defaults.removeObject(forKey: SettingKey.legacyReplyKnowledgeBaseNotionLastSyncTimeInterval)
                defaults.synchronize()
            } else {
                defaults.removeObject(forKey: SettingKey.knowledgeBaseNotionLastSyncTimeInterval)
                defaults.removeObject(forKey: SettingKey.legacyReplyKnowledgeBaseNotionLastSyncTimeInterval)
                defaults.synchronize()
                postDidChange()
            }
        }
    }

    var dismissOnOutsideClick: Bool {
        get { defaults.bool(forKey: SettingKey.dismissOnOutsideClick) }
        set { write(newValue, forKey: SettingKey.dismissOnOutsideClick) }
    }

    var launchAtLoginPreferred: Bool {
        get { defaults.bool(forKey: SettingKey.launchAtLoginPreferred) }
        set { write(newValue, forKey: SettingKey.launchAtLoginPreferred) }
    }

    var didAttemptDefaultLaunchAtLoginSetup: Bool {
        get { defaults.bool(forKey: SettingKey.didAttemptDefaultLaunchAtLoginSetup) }
        set { write(newValue, forKey: SettingKey.didAttemptDefaultLaunchAtLoginSetup) }
    }

    var screenshotShortcut: KeyboardShortcut {
        get {
            let defaultShortcut = KeyboardShortcut.defaultScreenshot
            let rawCode = defaults.object(forKey: SettingKey.screenshotShortcutKeyCode) as? Int
            let rawFlags = defaults.object(forKey: SettingKey.screenshotShortcutModifierFlags) as? UInt
            let keyCode = UInt16(rawCode ?? Int(defaultShortcut.keyCode))
            let flags = NSEvent.ModifierFlags(rawValue: rawFlags ?? defaultShortcut.modifierFlags.rawValue)
            return KeyboardShortcut(
                keyCode: keyCode,
                modifierFlags: AppSettings.normalizedShortcutModifierFlags(flags)
            )
        }
        set {
            let normalizedFlags = AppSettings.normalizedShortcutModifierFlags(newValue.modifierFlags)
            defaults.set(Int(newValue.keyCode), forKey: SettingKey.screenshotShortcutKeyCode)
            defaults.set(normalizedFlags.rawValue, forKey: SettingKey.screenshotShortcutModifierFlags)
            defaults.synchronize()
            postDidChange()
        }
    }

    var screenshotShortcutReplaceConflicts: Bool {
        get { defaults.bool(forKey: SettingKey.screenshotShortcutReplaceConflicts) }
        set { write(newValue, forKey: SettingKey.screenshotShortcutReplaceConflicts) }
    }

    var screenshotSaveDirectoryPath: String {
        get { defaults.string(forKey: SettingKey.screenshotSaveDirectoryPath) ?? Self.defaultScreenshotSaveDirectory.path }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            write(normalized.isEmpty ? Self.defaultScreenshotSaveDirectory.path : normalized, forKey: SettingKey.screenshotSaveDirectoryPath)
        }
    }

    var screenshotSaveDirectoryURL: URL {
        URL(fileURLWithPath: screenshotSaveDirectoryPath, isDirectory: true)
    }

    var calendarAutomationPermissionGranted: Bool? {
        get {
            guard defaults.object(forKey: SettingKey.calendarAutomationPermissionGranted) != nil else {
                return nil
            }
            return defaults.bool(forKey: SettingKey.calendarAutomationPermissionGranted)
        }
        set {
            if let newValue {
                write(newValue, forKey: SettingKey.calendarAutomationPermissionGranted)
            } else {
                defaults.removeObject(forKey: SettingKey.calendarAutomationPermissionGranted)
                defaults.synchronize()
                postDidChange()
            }
        }
    }

    func resetUserPreferences() {
        [
            SettingKey.autoToolbarEnabled,
            SettingKey.textSelectionEnabled,
            SettingKey.fileSelectionEnabled,
            SettingKey.screenshotEnabled,
            SettingKey.conversationBoxEnabled,
            SettingKey.compatibilityBridgeBundleIDs,
            SettingKey.skillEnabledOverrides,
            SettingKey.knowledgeBaseEnabledOverrides,
            SettingKey.translateEnabled,
            SettingKey.traceEnabled,
            SettingKey.explainEnabled,
            SettingKey.replyEnabled,
            SettingKey.scheduleEnabled,
            SettingKey.compressEnabled,
            SettingKey.llmProvider,
            SettingKey.llmApiKey,
            SettingKey.llmModel,
            SettingKey.notionIntegrationToken,
            SettingKey.knowledgeBaseNotionTargets,
            SettingKey.knowledgeBaseNotionAutoSyncEnabled,
            SettingKey.knowledgeBaseNotionLastSyncTimeInterval,
            SettingKey.legacyReplyKnowledgeBaseNotionTargets,
            SettingKey.legacyReplyKnowledgeBaseNotionAutoSyncEnabled,
            SettingKey.legacyReplyKnowledgeBaseNotionLastSyncTimeInterval,
            SettingKey.translationPromptTemplate,
            SettingKey.explanationPromptTemplate,
            SettingKey.replyPromptTemplate,
            SettingKey.dismissOnOutsideClick,
            SettingKey.appLanguage,
            SettingKey.launchAtLoginPreferred,
            SettingKey.didAttemptDefaultLaunchAtLoginSetup,
            SettingKey.screenshotShortcutKeyCode,
            SettingKey.screenshotShortcutModifierFlags,
            SettingKey.screenshotShortcutReplaceConflicts,
            SettingKey.screenshotSaveDirectoryPath,
            SettingKey.calendarAutomationPermissionGranted
        ].forEach { defaults.removeObject(forKey: $0) }
        _ = secretsStore.removeString(for: Self.llmApiKeyAccount)
        _ = secretsStore.removeString(for: Self.notionIntegrationTokenAccount)

        registerDefaults()
        postDidChange()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            SettingKey.autoToolbarEnabled: true,
            SettingKey.textSelectionEnabled: true,
            SettingKey.fileSelectionEnabled: true,
            SettingKey.screenshotEnabled: true,
            SettingKey.conversationBoxEnabled: true,
            SettingKey.compatibilityBridgeBundleIDs: RunningApplicationCatalog.defaultCompatibilityBundleIDs,
            SettingKey.skillEnabledOverrides: [:],
            SettingKey.knowledgeBaseEnabledOverrides: [:],
            SettingKey.llmProvider: "openai",
            SettingKey.llmModel: "gpt-4.1-mini",
            SettingKey.notionIntegrationToken: "",
            SettingKey.knowledgeBaseNotionTargets: "",
            SettingKey.knowledgeBaseNotionAutoSyncEnabled: true,
            SettingKey.dismissOnOutsideClick: true,
            SettingKey.appLanguage: AppLanguage.simplifiedChinese.rawValue,
            SettingKey.launchAtLoginPreferred: false,
            SettingKey.didAttemptDefaultLaunchAtLoginSetup: false,
            SettingKey.screenshotShortcutKeyCode: Int(KeyboardShortcut.defaultScreenshot.keyCode),
            SettingKey.screenshotShortcutModifierFlags: KeyboardShortcut.defaultScreenshot.modifierFlags.rawValue,
            SettingKey.screenshotShortcutReplaceConflicts: false,
            SettingKey.screenshotSaveDirectoryPath: Self.defaultScreenshotSaveDirectory.path
        ])
    }

    private func write(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        defaults.synchronize()
        postDidChange()
    }

    private func persistSecret(_ value: String, account: String, legacySettingKey: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let didPersist = normalized.isEmpty
            ? secretsStore.removeString(for: account)
            : secretsStore.setString(normalized, for: account)

        guard didPersist else {
            let error = AppSettingsError.secureStorageFailed(settingKey: legacySettingKey)
            reportSecureStorageFailure(settingKey: legacySettingKey, account: account, error: error)
            throw error
        }

        defaults.removeObject(forKey: legacySettingKey)
        defaults.synchronize()
        postDidChange()
    }

    private var skillEnabledOverrides: [String: Bool] {
        let raw = defaults.dictionary(forKey: SettingKey.skillEnabledOverrides) ?? [:]
        return raw.reduce(into: [String: Bool]()) { partialResult, item in
            if let boolValue = item.value as? Bool {
                partialResult[item.key] = boolValue
            } else if let numberValue = item.value as? NSNumber {
                partialResult[item.key] = numberValue.boolValue
            }
        }
    }

    private var knowledgeBaseEnabledOverrides: [String: Bool] {
        let raw = defaults.dictionary(forKey: SettingKey.knowledgeBaseEnabledOverrides) ?? [:]
        return raw.reduce(into: [String: Bool]()) { partialResult, item in
            if let boolValue = item.value as? Bool {
                partialResult[item.key] = boolValue
            } else if let numberValue = item.value as? NSNumber {
                partialResult[item.key] = numberValue.boolValue
            }
        }
    }

    private func skillEnabledOverrideValue(forSkillID skillID: String) -> Bool? {
        skillEnabledOverrides[skillID]
    }

    private func knowledgeBaseEnabledOverrideValue(forSkillID skillID: String) -> Bool? {
        knowledgeBaseEnabledOverrides[skillID]
    }

    private func migrateLegacySkillSettingsIfNeeded() {
        let legacyMappings: [(key: String, skillID: String, defaultEnabled: Bool)] = [
            (SettingKey.translateEnabled, "translate", true),
            (SettingKey.traceEnabled, "trace", true),
            (SettingKey.explainEnabled, "explain", true),
            (SettingKey.replyEnabled, "reply", true),
            (SettingKey.scheduleEnabled, "schedule", true),
            (SettingKey.compressEnabled, "compress", true),
            (SettingKey.legacyImageCompressEnabled, "compress", true)
        ]

        var overrides = skillEnabledOverrides
        var didChange = false

        for mapping in legacyMappings {
            guard defaults.object(forKey: mapping.key) != nil else { continue }
            let enabled = defaults.bool(forKey: mapping.key)
            if overrides[mapping.skillID] == nil, enabled != mapping.defaultEnabled {
                overrides[mapping.skillID] = enabled
            }
            defaults.removeObject(forKey: mapping.key)
            didChange = true
        }

        guard didChange else { return }
        defaults.set(overrides, forKey: SettingKey.skillEnabledOverrides)
        defaults.synchronize()
    }

    private func postDidChange() {
        NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
    }

    private func reportSecureStorageFailure(settingKey: String, account: String, error: Error) {
        diagnosticsLogger.log(
            "settings.security",
            "secure_store_failed setting=\(settingKey) account=\(account) error=\(error.localizedDescription)"
        )
        NotificationCenter.default.post(
            name: .appSettingsSecureStorageDidFail,
            object: AppSettingsSecureStorageFailure(settingKey: settingKey, account: account)
        )
    }

    private func migrateLegacySecretsIfNeeded() {
        migrateLegacySecret(settingKey: SettingKey.llmApiKey, account: Self.llmApiKeyAccount)
        migrateLegacySecret(settingKey: SettingKey.notionIntegrationToken, account: Self.notionIntegrationTokenAccount)
        migrateLegacyKnowledgeBaseSettingsIfNeeded()
        defaults.synchronize()
    }

    private func migrateLegacySecret(settingKey: String, account: String) {
        guard secretsStore.string(for: account) == nil else {
            defaults.removeObject(forKey: settingKey)
            return
        }

        let legacyValue = defaults.string(forKey: settingKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !legacyValue.isEmpty else { return }
        guard secretsStore.setString(legacyValue, for: account) else { return }
        defaults.removeObject(forKey: settingKey)
    }

    private func migrateLegacyKnowledgeBaseSettingsIfNeeded() {
        if defaults.object(forKey: SettingKey.knowledgeBaseNotionTargets) == nil,
           let legacyTargets = defaults.string(forKey: SettingKey.legacyReplyKnowledgeBaseNotionTargets) {
            defaults.set(legacyTargets, forKey: SettingKey.knowledgeBaseNotionTargets)
        }

        if defaults.object(forKey: SettingKey.knowledgeBaseNotionAutoSyncEnabled) == nil,
           let legacyAutoSync = defaults.object(forKey: SettingKey.legacyReplyKnowledgeBaseNotionAutoSyncEnabled) {
            defaults.set(legacyAutoSync, forKey: SettingKey.knowledgeBaseNotionAutoSyncEnabled)
        }

        if defaults.object(forKey: SettingKey.knowledgeBaseNotionLastSyncTimeInterval) == nil,
           let legacyLastSync = defaults.object(forKey: SettingKey.legacyReplyKnowledgeBaseNotionLastSyncTimeInterval) {
            defaults.set(legacyLastSync, forKey: SettingKey.knowledgeBaseNotionLastSyncTimeInterval)
        }
    }

    private static func normalizedShortcutModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .shift, .option, .control])
    }

    private static var defaultScreenshotSaveDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}
