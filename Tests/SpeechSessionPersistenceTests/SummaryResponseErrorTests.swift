import XCTest
@testable import SpeechSessionPersistence

final class SummaryResponseErrorTests: XCTestCase {
    private func row(_ id: UUID) -> [String: Any] {
        ["id": id.uuidString, "supported": true, "reason": "Supported", "citations": []]
    }
    func testMissingDuplicateAndWrongDecisionsHaveDifferentExplanations() throws {
        let a = UUID(), b = UUID()
        XCTAssertThrowsError(try SummaryResponseError.decodeChecks([row(a)], expectedIDs: [a,b])) {
            XCTAssertEqual($0 as? SummaryResponseError, .missingDecisions)
        }
        XCTAssertThrowsError(try SummaryResponseError.decodeChecks([row(a),row(a)], expectedIDs: [a])) {
            XCTAssertEqual($0 as? SummaryResponseError, .duplicateDecisions)
        }
        XCTAssertThrowsError(try SummaryResponseError.decodeChecks([row(b)], expectedIDs: [a])) {
            XCTAssertEqual($0 as? SummaryResponseError, .wrongDecisions)
        }
        XCTAssertEqual(try SummaryResponseError.decodeChecks([row(a)], expectedIDs: [a]).count, 1)
    }
    func testInvalidResponseIsNotMistakenForUnsupportedHealthData() {
        XCTAssertThrowsError(try SummaryResponseError.decodeChecks(["unexpected": "value"], expectedIDs: [UUID()])) {
            XCTAssertEqual($0 as? SummaryResponseError, .invalidFormat)
        }
    }
    func testResponseLimitsAndAuthorizationHaveSpecificRecovery() throws {
        XCTAssertThrowsError(try SummaryResponseError.validateFinishReason("length")) {
            XCTAssertEqual($0 as? SummaryResponseError, .responseTooLong)
        }
        XCTAssertThrowsError(try SummaryResponseError.validateHTTPStatus(401)) {
            XCTAssertEqual($0 as? SummaryResponseError, .signInRequired)
        }
        XCTAssertThrowsError(try SummaryResponseError.validateHTTPStatus(429)) {
            XCTAssertEqual($0 as? SummaryResponseError, .busy)
        }
        XCTAssertTrue(SummaryResponseError.signInRequired.recoverySuggestion!.contains("Settings"))
        XCTAssertTrue(SummaryResponseError.network.recoverySuggestion!.contains("internet"))
        try SummaryResponseError.validateHTTPStatus(200)
        try SummaryResponseError.validateFinishReason("stop")
    }
}
