import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskWindowGeometryTests: XCTestCase {
    func testResolvedFrameExpandsTinySelectionToMinimumSize() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let desiredRect = CGRect(x: 120, y: 300, width: 80, height: 60)

        let resolved = AskWindowGeometry.resolvedFrame(for: desiredRect, visibleFrame: visibleFrame)

        XCTAssertEqual(resolved.width, AskWindowGeometry.minimumSize.width)
        XCTAssertEqual(resolved.height, AskWindowGeometry.minimumSize.height)
        XCTAssertEqual(resolved.minX, desiredRect.minX)
        XCTAssertEqual(resolved.maxY, desiredRect.maxY)
    }

    func testResolvedFramePreservesStartCornerWhenDraggingFromTopRight() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let desiredRect = CGRect(x: 1200, y: 420, width: 140, height: 120)

        let resolved = AskWindowGeometry.resolvedFrame(
            for: desiredRect,
            visibleFrame: visibleFrame,
            startPoint: CGPoint(x: desiredRect.maxX, y: desiredRect.maxY),
            endPoint: CGPoint(x: desiredRect.minX, y: desiredRect.minY)
        )

        XCTAssertEqual(resolved.maxX, desiredRect.maxX)
        XCTAssertEqual(resolved.maxY, desiredRect.maxY)
        XCTAssertEqual(resolved.width, AskWindowGeometry.minimumSize.width)
        XCTAssertEqual(resolved.height, AskWindowGeometry.minimumSize.height)
    }

    func testResolvedFramePreservesStartCornerWhenDraggingFromBottomLeft() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let desiredRect = CGRect(x: 240, y: 180, width: 120, height: 90)

        let resolved = AskWindowGeometry.resolvedFrame(
            for: desiredRect,
            visibleFrame: visibleFrame,
            startPoint: CGPoint(x: desiredRect.minX, y: desiredRect.minY),
            endPoint: CGPoint(x: desiredRect.maxX, y: desiredRect.maxY)
        )

        XCTAssertEqual(resolved.minX, desiredRect.minX)
        XCTAssertEqual(resolved.minY, desiredRect.minY)
        XCTAssertEqual(resolved.width, AskWindowGeometry.minimumSize.width)
        XCTAssertEqual(resolved.height, AskWindowGeometry.minimumSize.height)
    }

    func testResolvedFrameClampsOversizedSelectionIntoVisibleFrame() {
        let visibleFrame = CGRect(x: 100, y: 80, width: 900, height: 620)
        let desiredRect = CGRect(x: 40, y: 20, width: 1600, height: 1200)

        let resolved = AskWindowGeometry.resolvedFrame(for: desiredRect, visibleFrame: visibleFrame)

        XCTAssertLessThanOrEqual(resolved.minX, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(resolved.minX, visibleFrame.minX + AskWindowGeometry.screenInset)
        XCTAssertGreaterThanOrEqual(resolved.minY, visibleFrame.minY + AskWindowGeometry.screenInset)
        XCTAssertLessThanOrEqual(resolved.maxX, visibleFrame.maxX - AskWindowGeometry.screenInset)
        XCTAssertLessThanOrEqual(resolved.maxY, visibleFrame.maxY - AskWindowGeometry.screenInset)
    }

    func testEntranceSeedFrameAnchorsAtDragStartForBottomRightExpansion() {
        let seed = AskWindowGeometry.entranceSeedFrame(
            startPoint: CGPoint(x: 120, y: 280),
            endPoint: CGPoint(x: 360, y: 120)
        )

        XCTAssertEqual(seed.minX, 120)
        XCTAssertEqual(seed.maxY, 280)
        XCTAssertEqual(seed.width, AskWindowGeometry.entranceSeedEdge)
        XCTAssertEqual(seed.height, AskWindowGeometry.entranceSeedEdge)
    }

    func testEntranceSeedFrameAnchorsAtDragStartForTopLeftExpansion() {
        let seed = AskWindowGeometry.entranceSeedFrame(
            startPoint: CGPoint(x: 420, y: 160),
            endPoint: CGPoint(x: 180, y: 360)
        )

        XCTAssertEqual(seed.maxX, 420)
        XCTAssertEqual(seed.minY, 160)
        XCTAssertEqual(seed.width, AskWindowGeometry.entranceSeedEdge)
        XCTAssertEqual(seed.height, AskWindowGeometry.entranceSeedEdge)
    }

    func testEntranceAnimationFramesCollapseToSingleContinuousTransformTrack() {
        let selectionFrame = CGRect(x: 120, y: 300, width: 80, height: 60)
        let resolvedFrame = CGRect(x: 120, y: 120, width: 400, height: 240)

        let frames = AskWindowGeometry.entranceAnimationFrames(
            selectionFrame: selectionFrame,
            resolvedFrame: resolvedFrame,
            startPoint: CGPoint(x: 120, y: 360),
            endPoint: CGPoint(x: 200, y: 300)
        )

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[1], resolvedFrame.integral)
    }
}
