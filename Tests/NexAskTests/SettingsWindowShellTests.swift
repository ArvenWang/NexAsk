import XCTest
@testable import NexShared
@testable import NexAskCore

final class SettingsWindowShellTests: XCTestCase {
    func testSettingsShellTabMapsToLegacySettingsTab() {
        XCTAssertEqual(SettingsShellTab.general.legacyTab, .general)
        XCTAssertEqual(SettingsShellTab.skills.legacyTab, .actions)
        XCTAssertEqual(SettingsShellTab.automation.legacyTab, .automation)
        XCTAssertEqual(SettingsShellTab.knowledgeBase.legacyTab, .knowledgeBase)
        XCTAssertEqual(SettingsShellTab.ai.legacyTab, .general)
        XCTAssertEqual(SettingsShellTab.shortcuts.legacyTab, .shortcuts)
        XCTAssertEqual(SettingsShellTab.privacy.legacyTab, .privacy)
        XCTAssertEqual(SettingsShellTab.membership.legacyTab, .membership)
        XCTAssertEqual(SettingsShellTab.stats.legacyTab, .learning)
    }

    func testSettingsWindowShellRoutesThroughTabCoordinator() {
        let presenter = SettingsWindowPresenterSpy()
        let shell = SettingsWindowShellController(presenter: presenter)

        shell.show(tab: .skills)
        shell.show(tab: .automation)
        shell.show(tab: .stats)

        XCTAssertEqual(presenter.presentedTabs, [.actions, .automation, .learning])
    }

    func testSettingsWindowShellRefreshesPlatformBackedTabsWhenSnapshotChanges() {
        let notificationCenter = NotificationCenter()
        let presenter = SettingsWindowPresenterSpy()
        let shell = SettingsWindowShellController(
            presenter: presenter,
            notificationCenter: notificationCenter
        )

        notificationCenter.post(name: .skillPlatformSnapshotDidChange, object: nil)
        _ = shell

        XCTAssertEqual(presenter.refreshedTabs, [.skills, .membership])
    }

    func testAutomationPageLayoutKeepsSectionsInSingleColumn() {
        let originalExperienceFactory = AppProductFeatureRegistry.makeExperienceController
        let originalAutomationFactory = AppProductFeatureRegistry.makeAutomationPageView
        defer {
            AppProductFeatureRegistry.makeExperienceController = originalExperienceFactory
            AppProductFeatureRegistry.makeAutomationPageView = originalAutomationFactory
        }
        NexAskProductBootstrap.register()

        let controller = SettingsWindowController()
        let snapshot = controller.testingAutomationPageLayoutSnapshot(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 900)
        )

        XCTAssertEqual(snapshot.contentFrame.minX, 18, accuracy: 1)
        XCTAssertEqual(snapshot.metricFrame.minX, 0, accuracy: 1)
        XCTAssertEqual(snapshot.jobListFrame.minX, 0, accuracy: 1)
        XCTAssertEqual(snapshot.detailFrame.minX, 0, accuracy: 1)
        XCTAssertEqual(snapshot.runHistoryFrame.minX, 0, accuracy: 1)
        XCTAssertEqual(snapshot.inboxFrame.minX, 0, accuracy: 1)

        XCTAssertEqual(snapshot.metricFrame.width, snapshot.contentFrame.width, accuracy: 1)
        XCTAssertEqual(snapshot.jobListFrame.width, snapshot.contentFrame.width, accuracy: 1)
        XCTAssertEqual(snapshot.detailFrame.width, snapshot.contentFrame.width, accuracy: 1)
        XCTAssertEqual(snapshot.runHistoryFrame.width, snapshot.contentFrame.width, accuracy: 1)
        XCTAssertEqual(snapshot.inboxFrame.width, snapshot.contentFrame.width, accuracy: 1)

        XCTAssertGreaterThan(snapshot.metricFrame.minY, snapshot.jobListFrame.minY)
        XCTAssertGreaterThan(snapshot.jobListFrame.minY, snapshot.detailFrame.minY)
        XCTAssertGreaterThan(snapshot.detailFrame.minY, snapshot.runHistoryFrame.minY)
        XCTAssertGreaterThan(snapshot.runHistoryFrame.minY, snapshot.inboxFrame.minY)

        XCTAssertLessThanOrEqual(snapshot.contentFrame.maxX, snapshot.scrollBounds.width - 18 + 1)
        XCTAssertFalse(snapshot.usesSystemScroller)
        XCTAssertGreaterThanOrEqual(snapshot.detailTitleFrame.minX, -3)
        XCTAssertGreaterThanOrEqual(snapshot.detailSpecFrame.minX, -3)
        XCTAssertEqual(snapshot.responseProfileFrame.minX, 0, accuracy: 1)
        XCTAssertEqual(snapshot.saveButtonFrame.minX, 0, accuracy: 1)
        XCTAssertGreaterThan(snapshot.detailTitleFrame.width, snapshot.detailFrame.width * 0.55)
        XCTAssertGreaterThan(snapshot.detailSpecFrame.width, snapshot.detailFrame.width * 0.55)
        XCTAssertGreaterThan(snapshot.responseProfileFrame.width, snapshot.detailFrame.width * 0.4)
    }
}

private final class SettingsWindowPresenterSpy: SettingsWindowPresenting, SettingsTabStatePresenting {
    private(set) var presentedTabs: [SettingsTab] = []
    private(set) var refreshedTabs: [SettingsShellTab] = []

    func show(tab: SettingsTab) {
        presentedTabs.append(tab)
    }

    func refreshSettingsState(for tab: SettingsShellTab) {
        refreshedTabs.append(tab)
    }
}
