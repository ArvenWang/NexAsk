import Foundation

struct SkillCatalogStatusSummary: Equatable {
    let installedCount: Int
    let catalogCount: Int
    let updateCount: Int
    let hasCatalogError: Bool
}

enum SkillCatalogStatusResolver {
    static func summary(from snapshot: SkillPlatformSnapshot) -> SkillCatalogStatusSummary {
        SkillCatalogStatusSummary(
            installedCount: snapshot.installedSkillIDs.count,
            catalogCount: snapshot.catalogSkillIDs.count,
            updateCount: snapshot.skillsWithUpdates.count,
            hasCatalogError: !(snapshot.verification.lastErrorMessage?.isEmpty ?? true)
        )
    }

    static func settingsStatusText(from snapshot: SkillPlatformSnapshot) -> String {
        let summary = summary(from: snapshot)
        if summary.hasCatalogError {
            return snapshot.verification.lastErrorMessage
                ?? L10n.text(zhHans: "技能目录暂时不可用。", en: "The skill catalog is temporarily unavailable.")
        }
        if summary.catalogCount == 0 {
            return L10n.text(zhHans: "可在这里直接获取、更新、启用或卸载技能。", en: "Install, update, enable, or uninstall skills directly here.")
        }
        if summary.updateCount > 0 {
            return L10n.format(
                zhHans: "已安装 %d 个技能，目录共 %d 个，其中 %d 个可更新。",
                en: "%d skills installed, %d in catalog, with %d updates available.",
                summary.installedCount,
                summary.catalogCount,
                summary.updateCount
            )
        }
        return L10n.format(
            zhHans: "已安装 %d 个技能，目录共 %d 个，当前已同步。",
            en: "%d skills installed, %d in catalog, and everything is in sync.",
            summary.installedCount,
            summary.catalogCount
        )
    }

    static func skillCenterSubtitleText(from snapshot: SkillPlatformSnapshot) -> String {
        let summary = summary(from: snapshot)
        if summary.hasCatalogError {
            return snapshot.verification.lastErrorMessage
                ?? L10n.text(zhHans: "技能目录暂时不可用。", en: "The skill catalog is temporarily unavailable.")
        }
        if summary.catalogCount == 0 {
            return L10n.text(zhHans: "已安装、可获取和可更新的技能都在这里管理。", en: "Manage installed, available, and updatable skills here.")
        }
        if summary.updateCount > 0 {
            return L10n.format(
                zhHans: "已安装 %d 个技能，发现 %d 个目录项，%d 个待更新。",
                en: "%d installed, %d in the catalog, and %d updates waiting.",
                summary.installedCount,
                summary.catalogCount,
                summary.updateCount
            )
        }
        return L10n.format(
            zhHans: "已安装 %d 个技能，发现 %d 个目录项。",
            en: "%d installed skills and %d catalog entries found.",
            summary.installedCount,
            summary.catalogCount
        )
    }
}

final class SettingsSkillsTabCoordinator {
    private let snapshotProvider: SkillPlatformSnapshotProvider

    init(snapshotProvider: SkillPlatformSnapshotProvider = .shared) {
        self.snapshotProvider = snapshotProvider
    }

    func statusText() -> String {
        SkillCatalogStatusResolver.settingsStatusText(from: snapshotProvider.currentSnapshot())
    }
}

final class SettingsAITabCoordinator {
    private let snapshotProvider: SkillPlatformSnapshotProvider

    init(snapshotProvider: SkillPlatformSnapshotProvider = .shared) {
        self.snapshotProvider = snapshotProvider
    }

    func runtimeSnapshot() -> GatewayRuntimeSnapshot {
        snapshotProvider.currentSnapshot().runtimeSnapshot
    }
}

final class SettingsMembershipTabCoordinator {
    private let snapshotProvider: SkillPlatformSnapshotProvider

    init(snapshotProvider: SkillPlatformSnapshotProvider = .shared) {
        self.snapshotProvider = snapshotProvider
    }

    func entitlementSnapshot() -> CommerceEntitlementSnapshot {
        snapshotProvider.currentSnapshot().entitlementSnapshot
    }
}
