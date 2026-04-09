import Foundation

enum SettingsShellTab: CaseIterable {
    case general
    case skills
    case automation
    case knowledgeBase
    case ai
    case shortcuts
    case privacy
    case membership
    case stats

    var legacyTab: SettingsTab {
        switch self {
        case .general:
            return .general
        case .skills:
            return .actions
        case .automation:
            return .automation
        case .knowledgeBase:
            return .knowledgeBase
        case .ai:
            return .general
        case .shortcuts:
            return .shortcuts
        case .privacy:
            return .privacy
        case .membership:
            return .membership
        case .stats:
            return .learning
        }
    }
}

protocol SettingsWindowPresenting: AnyObject {
    func show(tab: SettingsTab)
}

extension SettingsWindowController: SettingsWindowPresenting {}

protocol SettingsTabCoordinating {
    var tab: SettingsShellTab { get }
    func present(using presenter: SettingsWindowPresenting)
}

struct SettingsTabCoordinator: SettingsTabCoordinating {
    let tab: SettingsShellTab

    func present(using presenter: SettingsWindowPresenting) {
        presenter.show(tab: tab.legacyTab)
    }
}

protocol SettingsTabStatePresenting: AnyObject {
    func refreshSettingsState(for tab: SettingsShellTab)
}

protocol SettingsTabStateCoordinating {
    var tab: SettingsShellTab { get }
    func refresh(using presenter: SettingsTabStatePresenting)
}

struct SettingsPlatformTabCoordinator: SettingsTabStateCoordinating {
    let tab: SettingsShellTab

    func refresh(using presenter: SettingsTabStatePresenting) {
        presenter.refreshSettingsState(for: tab)
    }
}

final class SettingsWindowShellController {
    private let presenter: SettingsWindowPresenting
    private let windowController: SettingsWindowController?
    private let statePresenter: SettingsTabStatePresenting?
    private let tabCoordinators: [SettingsShellTab: SettingsTabCoordinator]
    private let stateCoordinators: [SettingsShellTab: SettingsPlatformTabCoordinator]
    private let notificationCenter: NotificationCenter
    private var platformSnapshotObserver: NSObjectProtocol?

    init(
        windowController: SettingsWindowController = SettingsWindowController(),
        tabCoordinators: [SettingsTabCoordinator] = SettingsShellTab.allCases.map(SettingsTabCoordinator.init(tab:)),
        stateCoordinators: [SettingsPlatformTabCoordinator] = [.skills, .membership].map(SettingsPlatformTabCoordinator.init(tab:)),
        notificationCenter: NotificationCenter = .default
    ) {
        self.presenter = windowController
        self.windowController = windowController
        self.statePresenter = windowController
        self.tabCoordinators = Dictionary(
            uniqueKeysWithValues: tabCoordinators.map { ($0.tab, $0) }
        )
        self.stateCoordinators = Dictionary(
            uniqueKeysWithValues: stateCoordinators.map { ($0.tab, $0) }
        )
        self.notificationCenter = notificationCenter
        startObservingPlatformSnapshots()
    }

    init(
        presenter: SettingsWindowPresenting,
        tabCoordinators: [SettingsTabCoordinator] = SettingsShellTab.allCases.map(SettingsTabCoordinator.init(tab:)),
        stateCoordinators: [SettingsPlatformTabCoordinator] = [.skills, .membership].map(SettingsPlatformTabCoordinator.init(tab:)),
        notificationCenter: NotificationCenter = .default
    ) {
        self.presenter = presenter
        self.windowController = presenter as? SettingsWindowController
        self.statePresenter = presenter as? SettingsTabStatePresenting
        self.tabCoordinators = Dictionary(
            uniqueKeysWithValues: tabCoordinators.map { ($0.tab, $0) }
        )
        self.stateCoordinators = Dictionary(
            uniqueKeysWithValues: stateCoordinators.map { ($0.tab, $0) }
        )
        self.notificationCenter = notificationCenter
        startObservingPlatformSnapshots()
    }

    deinit {
        if let platformSnapshotObserver {
            notificationCenter.removeObserver(platformSnapshotObserver)
        }
    }

    var onRequestLaunchAtLoginToggle: ((Bool) -> Void)? {
        get { windowController?.onRequestLaunchAtLoginToggle }
        set { windowController?.onRequestLaunchAtLoginToggle = newValue }
    }

    var onRequestTriggerScreenshotCapture: (() -> Void)? {
        get { windowController?.onRequestTriggerScreenshotCapture }
        set { windowController?.onRequestTriggerScreenshotCapture = newValue }
    }

    func show(tab: SettingsShellTab) {
        guard let coordinator = tabCoordinators[tab] else {
            presenter.show(tab: tab.legacyTab)
            return
        }
        coordinator.present(using: presenter)
    }

    private func startObservingPlatformSnapshots() {
        platformSnapshotObserver = notificationCenter.addObserver(
            forName: .skillPlatformSnapshotDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPlatformBackedTabs()
        }
    }

    private func refreshPlatformBackedTabs() {
        guard let statePresenter else { return }
        for tab in [.skills, .membership] as [SettingsShellTab] {
            stateCoordinators[tab]?.refresh(using: statePresenter)
        }
    }
}
