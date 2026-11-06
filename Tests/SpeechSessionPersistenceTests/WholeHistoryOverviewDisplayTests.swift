import XCTest
@testable import SpeechSessionPersistence

final class WholeHistoryOverviewDisplayTests: XCTestCase {
    func testSmallStyleOverrunDoesNotRejectSupportedOverview() {
        let text = Array(repeating: "word", count: 106).joined(separator: " ")
        XCTAssertTrue(WholeHistoryOverviewDisplay.withinCharacterLimit(text, compact: true, balanced: true))
        XCTAssertTrue(WholeHistoryOverviewDisplay.withinWordLimit(text, compact: true, balanced: true))
    }
    func testDisplayCeilingsStillRejectExcessiveOutput() {
        XCTAssertFalse(WholeHistoryOverviewDisplay.withinCharacterLimit(String(repeating: "x", count: 851), compact: true, balanced: true))
        XCTAssertFalse(WholeHistoryOverviewDisplay.withinWordLimit(Array(repeating: "a", count: 151).joined(separator: " "), compact: true, balanced: true))
    }
}
