import Foundation

extension Notification.Name {
    static let skillPlatformSnapshotDidChange = Notification.Name("nexhub.skillPlatformSnapshotDidChange")
}

protocol SkillPlatformRegistryReading: AnyObject {
    var allDefinitions: [SkillDefinition] { get }
    var catalogSnapshot: SkillCatalogSnapshot? { get }
    func inventoryItems(settings: AppSettings, filter: SkillListFilter, query: String) -> [SkillInventoryItem]
}

protocol SkillPlatformRuntimeProviding: AnyObject {
    func currentSnapshot() -> GatewayRuntimeSnapshot
}

protocol SkillPlatformEntitlementProviding: AnyObject {
    var entitlementSnapshot: CommerceEntitlementSnapshot { get }
    var entitlementSnapshotIsReady: Bool { get }
}

extension SkillRegistry: SkillPlatformRegistryReading {}
extension GatewayRuntimeManager: SkillPlatformRuntimeProviding {}
extension CommerceService: SkillPlatformEntitlementProviding {}

final class SkillPlatformSnapshotProvider {
    static let shared = SkillPlatformSnapshotProvider()

    private let registry: SkillPlatformRegistryReading
    private let runtimeProvider: SkillPlatformRuntimeProviding
    private let entitlementProvider: SkillPlatformEntitlementProviding
    private let notificationCenter: NotificationCenter
    private let stateLock = NSLock()
    private var observers: [NSObjectProtocol] = []
    private var snapshot: SkillPlatformSnapshot

    init(
        registry: SkillPlatformRegistryReading = SkillRegistry.shared,
        runtimeProvider: SkillPlatformRuntimeProviding = GatewayRuntimeManager.shared,
        entitlementProvider: SkillPlatformEntitlementProviding = CommerceService.shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.registry = registry
        self.runtimeProvider = runtimeProvider
        self.entitlementProvider = entitlementProvider
        self.notificationCenter = notificationCenter
        self.snapshot = SkillPlatformSnapshotProvider.makeSnapshot(
            registry: registry,
            runtimeProvider: runtimeProvider,
            entitlementProvider: entitlementProvider
        )
        startObserving()
    }

    deinit {
        observers.forEach(notificationCenter.removeObserver)
    }

    func currentSnapshot() -> SkillPlatformSnapshot {
        stateLock.withLock { snapshot }
    }

    func refresh() {
        let newSnapshot = Self.makeSnapshot(
            registry: registry,
            runtimeProvider: runtimeProvider,
            entitlementProvider: entitlementProvider
        )
        stateLock.lock()
        snapshot = newSnapshot
        stateLock.unlock()
        notificationCenter.post(name: .skillPlatformSnapshotDidChange, object: self)
    }

    private func startObserving() {
        let names: [Notification.Name] = [
            .skillRegistryDidReload,
            .skillInstallStateDidChange,
            .commerceStateDidChange,
            .gatewayRuntimeDidChange,
        ]
        observers = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    private static func makeSnapshot(
        registry: SkillPlatformRegistryReading,
        runtimeProvider: SkillPlatformRuntimeProviding,
        entitlementProvider: SkillPlatformEntitlementProviding
    ) -> SkillPlatformSnapshot {
        let inventory = registry.inventoryItems(settings: .shared, filter: .all, query: "")
        let catalogSnapshot = registry.catalogSnapshot
        return SkillPlatformSnapshot(
            catalogSnapshot: catalogSnapshot,
            installedSkillIDs: inventory.filter { $0.isInstalled }.map { $0.skillID }.sorted(),
            catalogSkillIDs: (catalogSnapshot?.items.map(\.skillID) ?? []).sorted(),
            skillsWithUpdates: inventory.filter { $0.updateAvailable }.map { $0.skillID }.sorted(),
            verification: SkillPlatformVerificationState(
                invalidPackageCount: 0,
                lastErrorMessage: catalogSnapshot?.errorMessage
            ),
            entitlementSnapshot: entitlementProvider.entitlementSnapshot,
            entitlementIsReady: entitlementProvider.entitlementSnapshotIsReady,
            runtimeSnapshot: runtimeProvider.currentSnapshot()
        )
    }
}
