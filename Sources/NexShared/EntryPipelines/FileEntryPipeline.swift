import AppKit
import ApplicationServices

typealias FileEntryCoordinator = FileActivationCoordinator

struct FinderMouseUpDecision {
    let waitsForCommandRelease: Bool
    let shouldScheduleCapture: Bool
}

struct FinderDragPreviewResolution: Equatable {
    let nextPreviewCount: Int
    let nextLowCountStreak: Int
    let shouldUpdatePreviewCount: Bool
    let shouldShowCompact: Bool
    let shouldHideCompact: Bool
}

struct GlobalInputRouter {
    func isSelectionKeyboardIntent(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command), chars == "a" {
            return true
        }
        if event.modifierFlags.contains(.shift), [123, 124, 125, 126].contains(event.keyCode) {
            return true
        }
        return false
    }

    func finderMouseUpDecision(
        mouseDidDragInCurrentGesture: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> FinderMouseUpDecision {
        let relevantFlags = modifierFlags.intersection([.shift, .command])
        return FinderMouseUpDecision(
            waitsForCommandRelease: relevantFlags.contains(.command),
            shouldScheduleCapture: mouseDidDragInCurrentGesture || relevantFlags.contains(.shift)
        )
    }
}

enum FinderPreviewStateMachine {
    static func resolve(
        liveCount: Int?,
        lastPreviewCount: Int,
        lowCountStreak: Int,
        hideDebounceSamples: Int,
        toolbarIsVisible: Bool,
        toolbarIsCompactPresentation: Bool
    ) -> FinderDragPreviewResolution {
        if let liveCount, liveCount > 1 {
            return FinderDragPreviewResolution(
                nextPreviewCount: liveCount,
                nextLowCountStreak: 0,
                shouldUpdatePreviewCount: liveCount != lastPreviewCount,
                shouldShowCompact: !toolbarIsVisible || !toolbarIsCompactPresentation,
                shouldHideCompact: false
            )
        }

        let nextLowCountStreak = lowCountStreak + 1
        let shouldHideCompact = nextLowCountStreak >= hideDebounceSamples
        return FinderDragPreviewResolution(
            nextPreviewCount: shouldHideCompact ? 1 : lastPreviewCount,
            nextLowCountStreak: shouldHideCompact ? 0 : nextLowCountStreak,
            shouldUpdatePreviewCount: false,
            shouldShowCompact: false,
            shouldHideCompact: shouldHideCompact && toolbarIsCompactPresentation
        )
    }
}

final class FinderSelectionService {
    var onSelectionCountChanged: ((Int?) -> Void)?

    private let previewObserver = FinderSelectionPreviewObserver()

    init() {
        previewObserver.onSelectionCountChanged = { [weak self] count in
            self?.onSelectionCountChanged?(count)
        }
    }

    func start() {
        previewObserver.start()
    }

    func stop() {
        previewObserver.stop()
    }

    func primarySelectionContainer() -> AXUIElement? {
        SelectionAccess.finderPrimarySelectionContainer()
    }

    func selectedItemCount(onPrimaryContainer container: AXUIElement?) -> Int? {
        SelectionAccess.finderSelectedItemCount(onPrimaryContainer: container)
    }

    func liveSelectedItemCount() -> Int? {
        SelectionAccess.finderLiveSelectedItemCount()
    }

    func selectionCount(forObserverElement element: AXUIElement?) -> Int? {
        SelectionAccess.finderSelectionCount(forObserverElement: element)
    }

    func captureSelectionBySyntheticCopy(completion: @escaping (FileSelectionSnapshot?) -> Void) {
        SelectionAccess.captureFileSelectionBySyntheticCopy(completion: completion)
    }
}
