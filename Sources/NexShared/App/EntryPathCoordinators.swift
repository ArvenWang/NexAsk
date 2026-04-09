import CoreGraphics
import Foundation

enum ToolbarPresentationStyle {
    case compact
    case reveal
    case revealImmediately
    case show
}

struct ToolbarPresentationIntent {
    let style: ToolbarPresentationStyle
    let anchorPoint: CGPoint
    let delay: TimeInterval?
    let snapshotTextGuard: String?
}

struct TextPresentationContext {
    let mouseSelectionActive: Bool
    let mouseDidDragInCurrentGesture: Bool
    let pendingClickSelectionExpansion: Bool
    let toolbarIsVisible: Bool
    let toolbarIsCompactPresentation: Bool
    let clickSelectionPresentationDelay: TimeInterval
    let dragSelectionPresentationDelay: TimeInterval
}

struct TextActivationUpdate {
    let snapshot: SelectionSnapshot
    let previousSnapshot: SelectionSnapshot?
    let artifact: TextSelectionArtifact
    let isSameSelection: Bool
}

final class TextActivationCoordinator {
    private let artifactBuilder: TextArtifactBuilder

    private(set) var currentSnapshot: SelectionSnapshot?
    private(set) var currentArtifact: TextSelectionArtifact?

    init(artifactBuilder: TextArtifactBuilder = TextArtifactBuilder()) {
        self.artifactBuilder = artifactBuilder
    }

    @discardableResult
    func update(with snapshot: SelectionSnapshot) -> TextActivationUpdate {
        let previousSnapshot = currentSnapshot
        let artifact = artifactBuilder.build(from: snapshot)
        currentSnapshot = snapshot
        currentArtifact = artifact
        return TextActivationUpdate(
            snapshot: snapshot,
            previousSnapshot: previousSnapshot,
            artifact: artifact,
            isSameSelection: Self.isSameSelection(snapshot, previousSnapshot)
        )
    }

    @discardableResult
    func clear() -> Bool {
        let hadState = currentSnapshot != nil || currentArtifact != nil
        currentSnapshot = nil
        currentArtifact = nil
        return hadState
    }

    func makePresentationIntent(
        for update: TextActivationUpdate,
        context: TextPresentationContext
    ) -> ToolbarPresentationIntent? {
        if context.mouseSelectionActive && context.mouseDidDragInCurrentGesture {
            return ToolbarPresentationIntent(
                style: .compact,
                anchorPoint: update.snapshot.anchorPoint,
                delay: nil,
                snapshotTextGuard: nil
            )
        }

        let prefersDirectExpansion =
            (context.mouseSelectionActive && !context.mouseDidDragInCurrentGesture)
            || context.pendingClickSelectionExpansion

        let style: ToolbarPresentationStyle
        if !context.toolbarIsVisible {
            style = prefersDirectExpansion ? .revealImmediately : .reveal
        } else if context.toolbarIsCompactPresentation || !update.isSameSelection {
            style = .show
        } else {
            return nil
        }

        let delay: TimeInterval?
        if context.mouseSelectionActive {
            delay = context.mouseDidDragInCurrentGesture
                ? context.dragSelectionPresentationDelay
                : context.clickSelectionPresentationDelay
        } else {
            delay = nil
        }

        return ToolbarPresentationIntent(
            style: style,
            anchorPoint: update.snapshot.anchorPoint,
            delay: delay,
            snapshotTextGuard: context.mouseSelectionActive ? update.snapshot.text : nil
        )
    }

    private static func isSameSelection(_ lhs: SelectionSnapshot, _ rhs: SelectionSnapshot?) -> Bool {
        guard let rhs else { return false }
        return lhs.text == rhs.text && lhs.sourceBundleID == rhs.sourceBundleID
    }
}

struct FileActivationUpdate {
    let snapshot: FileSelectionSnapshot
    let previousSnapshot: FileSelectionSnapshot?
    let artifact: FileSelectionArtifact
    let isSameSelection: Bool
    let presentationIntent: ToolbarPresentationIntent?
}

final class FileActivationCoordinator {
    private let artifactBuilder: FileArtifactBuilder

    private(set) var currentSnapshot: FileSelectionSnapshot?
    private(set) var currentArtifact: FileSelectionArtifact?

    init(artifactBuilder: FileArtifactBuilder = FileArtifactBuilder()) {
        self.artifactBuilder = artifactBuilder
    }

    @discardableResult
    func update(with snapshot: FileSelectionSnapshot, toolbarIsVisible: Bool) -> FileActivationUpdate {
        let previousSnapshot = currentSnapshot
        let artifact = artifactBuilder.build(from: snapshot)
        currentSnapshot = snapshot
        currentArtifact = artifact
        return FileActivationUpdate(
            snapshot: snapshot,
            previousSnapshot: previousSnapshot,
            artifact: artifact,
            isSameSelection: Self.isSameSelection(snapshot, previousSnapshot),
            presentationIntent: ToolbarPresentationIntent(
                style: toolbarIsVisible ? .show : .reveal,
                anchorPoint: snapshot.anchorPoint,
                delay: nil,
                snapshotTextGuard: nil
            )
        )
    }

    @discardableResult
    func clear() -> Bool {
        let hadState = currentSnapshot != nil || currentArtifact != nil
        currentSnapshot = nil
        currentArtifact = nil
        return hadState
    }

    private static func isSameSelection(_ lhs: FileSelectionSnapshot, _ rhs: FileSelectionSnapshot?) -> Bool {
        guard let rhs else { return false }
        return lhs.sourceBundleID == rhs.sourceBundleID
            && lhs.fileURLs.map(\.path) == rhs.fileURLs.map(\.path)
    }
}

struct ScreenshotActivationUpdate {
    let snapshot: ImageSelectionSnapshot
    let previousSnapshot: ImageSelectionSnapshot?
    let artifact: ImageSelectionArtifact
    let isSameSelection: Bool
    let shouldPreserveToolbarPosition: Bool
    let shouldRefreshToolbarLayout: Bool
}

final class ScreenshotActivationCoordinator {
    private let artifactBuilder: ImageArtifactBuilder

    private(set) var currentSnapshot: ImageSelectionSnapshot?
    private(set) var currentArtifact: ImageSelectionArtifact?

    init(artifactBuilder: ImageArtifactBuilder = ImageArtifactBuilder()) {
        self.artifactBuilder = artifactBuilder
    }

    @discardableResult
    func update(
        with snapshot: ImageSelectionSnapshot,
        selectedTool: ScreenshotEditingTool,
        toolbarIsVisible: Bool
    ) -> ScreenshotActivationUpdate {
        let previousSnapshot = currentSnapshot
        let artifact = artifactBuilder.build(from: snapshot)
        currentSnapshot = snapshot
        currentArtifact = artifact
        let shouldPreserveToolbarPosition =
            previousSnapshot?.selectionRect == snapshot.selectionRect
            && selectedTool != .none
            && toolbarIsVisible
        return ScreenshotActivationUpdate(
            snapshot: snapshot,
            previousSnapshot: previousSnapshot,
            artifact: artifact,
            isSameSelection: Self.isSameSelection(snapshot, previousSnapshot),
            shouldPreserveToolbarPosition: shouldPreserveToolbarPosition,
            shouldRefreshToolbarLayout: !shouldPreserveToolbarPosition
        )
    }

    @discardableResult
    func clear() -> Bool {
        let hadState = currentSnapshot != nil || currentArtifact != nil
        currentSnapshot = nil
        currentArtifact = nil
        return hadState
    }

    private static func isSameSelection(_ lhs: ImageSelectionSnapshot, _ rhs: ImageSelectionSnapshot?) -> Bool {
        guard let rhs else { return false }
        return lhs.imageURL == rhs.imageURL
            && lhs.selectionRect == rhs.selectionRect
            && lhs.sourceBundleID == rhs.sourceBundleID
    }
}
