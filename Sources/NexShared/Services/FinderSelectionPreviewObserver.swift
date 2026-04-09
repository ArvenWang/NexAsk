import AppKit

final class FinderSelectionPreviewObserver {
    private static let focusedWindowChangedName = kAXFocusedWindowChangedNotification as String
    private static let focusedUIElementChangedName = kAXFocusedUIElementChangedNotification as String
    var onSelectionCountChanged: ((Int?) -> Void)?

    private let resolutionQueue = DispatchQueue(label: "com.nexhub.finder-selection-preview", qos: .userInitiated)
    private var observer: AXObserver?
    private var observedElements: [AXUIElement] = []
    private var appElement: AXUIElement?
    private var sessionID: UInt64 = 0

    func start() {
        stop()
        guard let finderPID = SelectionAccess.finderProcessIdentifier() else { return }

        var createdObserver: AXObserver?
        let result = AXObserverCreate(finderPID, Self.observerCallback, &createdObserver)
        guard result == .success, let createdObserver else { return }

        observer = createdObserver
        appElement = AXUIElementCreateApplication(finderPID)
        sessionID &+= 1
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .commonModes
        )

        rebuildObservedElements()
        scheduleSelectionCountResolution(using: nil)
    }

    func stop() {
        guard let observer else { return }

        if let appElement {
            removeNotifications(
                from: appElement,
                names: [
                    Self.focusedWindowChangedName,
                    Self.focusedUIElementChangedName
                ]
            )
        }
        for element in observedElements {
            removeNotifications(from: element, names: Self.selectionNotificationNames)
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )

        observedElements.removeAll()
        appElement = nil
        self.observer = nil
        sessionID &+= 1
    }

    private func rebuildObservedElements() {
        guard let observer, let appElement else { return }

        addNotifications(
            to: appElement,
            names: [
                Self.focusedWindowChangedName,
                Self.focusedUIElementChangedName
            ],
            observer: observer
        )

        for element in observedElements {
            removeNotifications(from: element, names: Self.selectionNotificationNames)
        }

        observedElements = SelectionAccess.finderSelectionObserverElements()
        for element in observedElements {
            addNotifications(to: element, names: Self.selectionNotificationNames, observer: observer)
        }
    }

    private func addNotifications(to element: AXUIElement, names: [String], observer: AXObserver) {
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        for name in names {
            _ = AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
    }

    private func removeNotifications(from element: AXUIElement, names: [String]) {
        guard let observer else { return }
        for name in names {
            _ = AXObserverRemoveNotification(observer, element, name as CFString)
        }
    }

    private func handleNotification(element: AXUIElement, name: String) {
        switch name {
        case Self.focusedWindowChangedName,
             Self.focusedUIElementChangedName:
            rebuildObservedElements()
            scheduleSelectionCountResolution(using: element)

        case Self.selectionNotificationNames[0],
             Self.selectionNotificationNames[1],
             Self.selectionNotificationNames[2]:
            scheduleSelectionCountResolution(using: element)

        default:
            break
        }
    }

    private func scheduleSelectionCountResolution(using element: AXUIElement?) {
        let currentSessionID = sessionID
        resolutionQueue.async { [weak self] in
            guard let self else { return }
            let count = SelectionAccess.finderSelectionCount(forObserverElement: element)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionID == currentSessionID else { return }
                self.onSelectionCountChanged?(count)
            }
        }
    }

    private static let selectionNotificationNames = [
        kAXSelectedChildrenChangedNotification as String,
        kAXSelectedRowsChangedNotification as String,
        kAXSelectedCellsChangedNotification as String
    ]

    private static let observerCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let instance = Unmanaged<FinderSelectionPreviewObserver>.fromOpaque(refcon).takeUnretainedValue()
        instance.handleNotification(element: element, name: notification as String)
    }
}
