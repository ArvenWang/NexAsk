import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskBoxInputInterceptorTests: XCTestCase {
    func testSystemPointConversionProducesCocoaCoordinates() {
        let systemPoint = CGPoint(x: 240, y: 120)

        let cocoaPoint = AskBoxInputInterceptor.cocoaPoint(fromSystemPoint: systemPoint, referenceMaxY: 900)

        XCTAssertEqual(cocoaPoint.x, 240)
        XCTAssertEqual(cocoaPoint.y, 780)
    }

    func testCaptureDragRequiresMinimumDistance() {
        let start = CGPoint(x: 100, y: 100)

        XCTAssertFalse(AskBoxInputInterceptor.qualifiesAsCaptureDrag(start: start, end: CGPoint(x: 102, y: 102)))
        XCTAssertTrue(AskBoxInputInterceptor.qualifiesAsCaptureDrag(start: start, end: CGPoint(x: 104, y: 100)))
        XCTAssertTrue(AskBoxInputInterceptor.qualifiesAsCaptureDrag(start: start, end: CGPoint(x: 100, y: 104)))
    }
}
