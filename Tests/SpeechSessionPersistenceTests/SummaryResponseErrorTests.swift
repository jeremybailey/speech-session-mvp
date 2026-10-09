import XCTest
@testable import SpeechSessionPersistence

final class SummaryResponseErrorTests: XCTestCase {
    func testDurableBudgetErrorsPreserveExplanationAndDoNotRecommendBlindRetry() {
        let error = NSError(domain: "AIProcessing", code: 402, userInfo: [
            NSLocalizedDescriptionKey: "The processing budget has been reached."])
        let shown = SummaryResponseError.presentation(for: error)
        XCTAssertEqual(shown.message, "The processing budget has been reached.")
        XCTAssertTrue(shown.recovery.contains("pending requests"))
        XCTAssertTrue(shown.recovery.contains("Do not repeatedly retry"))
        let stopped = NSError(domain: "AIProcessing", code: 409, userInfo: [
            NSLocalizedDescriptionKey: "Processing stopped (uncertain). No automatic paid retry was made."])
        XCTAssertTrue(SummaryResponseError.presentation(for: stopped).message.contains("uncertain"))
        let raw = NSError(domain: "UntrustedProvider", code: 500, userInfo: [NSLocalizedDescriptionKey: "private provider payload"])
        XCTAssertEqual(SummaryResponseError.presentation(for: raw).message, SummaryResponseError.unknown.errorDescription)
    }

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
    func testKeyedDecisionsRequireCoverageAndRejectSwappedIdentities() throws {
        let a = UUID(), b = UUID()
        let valid = [a.uuidString: row(a), b.uuidString: row(b)]
        XCTAssertEqual(try SummaryResponseError.decodeKeyedChecks(valid, expectedIDs: [a,b]).map(\.id), [a,b])
        XCTAssertThrowsError(try SummaryResponseError.decodeKeyedChecks([a.uuidString: row(a)], expectedIDs: [a,b]))
        XCTAssertThrowsError(try SummaryResponseError.decodeKeyedChecks([a.uuidString: row(b), b.uuidString: row(a)], expectedIDs: [a,b]))
        XCTAssertThrowsError(try SummaryResponseError.decodeKeyedChecks([a.uuidString: row(a), b.uuidString: row(a)], expectedIDs: [a,b]))
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
