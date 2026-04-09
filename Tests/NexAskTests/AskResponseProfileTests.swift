import XCTest
@testable import NexShared
@testable import NexAskCore

final class AskResponseProfileTests: XCTestCase {
    func testResolvedProfileUsesCompactFrameForConciseAnswers() {
        XCTAssertEqual(
            AskResponseProfile.resolved(for: CGRect(x: 0, y: 0, width: 320, height: 220)),
            .concise
        )
    }

    func testResolvedProfileUsesLargeFrameForDetailedAnswers() {
        XCTAssertEqual(
            AskResponseProfile.resolved(for: CGRect(x: 0, y: 0, width: 860, height: 620)),
            .detailed
        )
    }
}
