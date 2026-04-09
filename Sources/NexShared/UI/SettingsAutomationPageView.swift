import AppKit

package typealias SettingsAutomationPageLayoutSnapshot = (
    scrollBounds: NSRect,
    contentFrame: NSRect,
    metricFrame: NSRect,
    jobListFrame: NSRect,
    detailFrame: NSRect,
    runHistoryFrame: NSRect,
    inboxFrame: NSRect,
    detailTitleFrame: NSRect,
    detailSpecFrame: NSRect,
    responseProfileFrame: NSRect,
    saveButtonFrame: NSRect,
    usesSystemScroller: Bool
)

package protocol SettingsAutomationPageView: AnyObject {
    var pageView: NSView { get }
    var onScrollStateChanged: ((Bool) -> Void)? { get set }

    func reloadData()
    func refreshScrollLayout()
    func updateSharedScrollIndicator(_ indicator: SettingsScrollIndicatorView, showTemporarily: Bool)
    func scrollTo(offsetY targetOffset: CGFloat)
    func resetScrollPosition()
    func testingLayoutSnapshot(frame: NSRect) -> SettingsAutomationPageLayoutSnapshot
}

package final class DefaultSettingsAutomationPageView: NSView, SettingsAutomationPageView {
    package var pageView: NSView { self }
    package var onScrollStateChanged: ((Bool) -> Void)?

    package override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = true
    }

    package convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package func reloadData() {}

    package func refreshScrollLayout() {}

    package func updateSharedScrollIndicator(
        _ indicator: SettingsScrollIndicatorView,
        showTemporarily: Bool
    ) {
        indicator.update(
            contentHeight: bounds.height,
            visibleHeight: bounds.height,
            offsetY: 0,
            showTemporarily: showTemporarily
        )
    }

    package func scrollTo(offsetY targetOffset: CGFloat) {
        _ = targetOffset
        onScrollStateChanged?(true)
    }

    package func resetScrollPosition() {
        onScrollStateChanged?(false)
    }

    package func testingLayoutSnapshot(
        frame: NSRect = NSRect(x: 0, y: 0, width: 1200, height: 900)
    ) -> SettingsAutomationPageLayoutSnapshot {
        (
            scrollBounds: frame,
            contentFrame: frame,
            metricFrame: .zero,
            jobListFrame: .zero,
            detailFrame: .zero,
            runHistoryFrame: .zero,
            inboxFrame: .zero,
            detailTitleFrame: .zero,
            detailSpecFrame: .zero,
            responseProfileFrame: .zero,
            saveButtonFrame: .zero,
            usesSystemScroller: false
        )
    }
}
