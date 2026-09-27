import XCTest
@testable import SpeechSessionPersistence

final class ClinicalResponseFormatTests: XCTestCase {
    func testCheckerSchemaOnlyAllowsCurrentBatchIdentities() throws {
        let first = UUID(), second = UUID(), otherBatch = UUID()
        func identifier(_ ids: [UUID]) throws -> [String: Any] {
            let format = ClinicalResponseFormat.forStage("checking", expectedCheckIDs: ids)
            let wrapper = try XCTUnwrap(format["json_schema"] as? [String: Any])
            XCTAssertEqual(wrapper["strict"] as? Bool, true)
            let schema = try XCTUnwrap(wrapper["schema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let decisions = try XCTUnwrap(properties["decisions"] as? [String: Any])
            let items = try XCTUnwrap(decisions["items"] as? [String: Any])
            let fields = try XCTUnwrap(items["properties"] as? [String: Any])
            return try XCTUnwrap(fields["id"] as? [String: Any])
        }
        XCTAssertEqual(try identifier([first, second])["enum"] as? [String], [first.uuidString, second.uuidString])
        XCTAssertEqual(try identifier([otherBatch])["enum"] as? [String], [otherBatch.uuidString])
        // Schema constraints supplement, never replace exact coverage validation.
        let row: [String: Any] = ["id": first.uuidString, "supported": true, "reason": "test", "citations": []]
        XCTAssertThrowsError(try SummaryResponseError.decodeChecks([row, row], expectedIDs: [first, second]))
        XCTAssertThrowsError(try SummaryResponseError.decodeChecks([row], expectedIDs: [first, second]))
    }
}
