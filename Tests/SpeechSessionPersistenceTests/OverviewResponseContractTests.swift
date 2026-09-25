import XCTest
@testable import SpeechSessionPersistence

final class OverviewResponseContractTests: XCTestCase {
    func testRejectionRetainsBothReasonsForDiagnosis() {
        let error = OverviewFailure.rejectedAfterCorrection(firstReason: "Sentence 2 implies recovery.", finalReason: "Sentence 3 implies current use.")
        XCTAssertTrue(error.checkerExplanation?.contains("Sentence 2 implies recovery.") == true)
        XCTAssertTrue(error.checkerExplanation?.contains("Sentence 3 implies current use.") == true)
        XCTAssertTrue(error.errorDescription?.contains("Why it stopped") == true)
        let unexplained = OverviewFailure.rejectedAfterCorrection(firstReason: "", finalReason: "  ")
        XCTAssertTrue(unexplained.checkerExplanation?.contains("did not explain") == true)
    }
    func testCorrectionFeedbackPreservesRejectionAndRequiresACompleteDecision() throws {
        let decision = try OverviewResponseContract.decodeSupportDecision(#"{"supported":false,"reason":"Sentence 2 implies current medication use from a historical fill."}"#)
        XCTAssertFalse(decision.supported)
        XCTAssertTrue(decision.reason.contains("Sentence 2"))
        XCTAssertThrowsError(try OverviewResponseContract.decodeSupportDecision(#"{"supported":true}"#))
        XCTAssertThrowsError(try OverviewResponseContract.decodeSupportDecision(#"{"reason":"Looks good"}"#))
        XCTAssertTrue(try OverviewResponseContract.decodeSupportDecision(#"{"supported":true,"reason":""}"#).supported)
    }
    func testNarrativeAndFencedDocumentDecodeWithoutLosingReferences() throws {
        let json = #"{"sentences":[{"text":"You reported fatigue.","factIDs":["one"]}]}"#
        for raw in [json, "```json\n" + json + "\n```"] {
            let result = try OverviewResponseContract.decodeNarrative(raw)
            XCTAssertEqual(result.sentences.first?.factIDs, ["one"])
        }
        for raw in [#"{"overview":"You reported fatigue."}"#, #"{"sentences":[{"text":"Fatigue"}]}"#, String(json.dropLast())] {
            XCTAssertThrowsError(try OverviewResponseContract.decodeNarrative(raw))
        }
    }

    func testCheckerRequiresAnActualBooleanAndNeverDefaultsToApproval() throws {
        XCTAssertTrue(try OverviewResponseContract.decodeSupport(#"{"supported":true}"#))
        XCTAssertFalse(try OverviewResponseContract.decodeSupport(#"{"supported":false}"#))
        for raw in [#"{"supported":"true"}"#, #"{"supported":1}"#, "{}", "true", #"{"supported":"#] {
            XCTAssertThrowsError(try OverviewResponseContract.decodeSupport(raw)) { error in
                guard case OverviewFailure.invalidCheckFormat = error else { return XCTFail("Wrong stage") }
            }
        }
    }

    func testBothCloudSchemasRequireEveryFieldAndDisallowExtraProperties() throws {
        for contract in [OverviewResponseContract.narrative, .support] {
            let format = contract.responseFormat
            XCTAssertEqual(format["type"] as? String, "json_schema")
            let definition = try XCTUnwrap(format["json_schema"] as? [String: Any])
            XCTAssertEqual(definition["strict"] as? Bool, true)
            let schema = try XCTUnwrap(definition["schema"] as? [String: Any])
            checkObject(schema)
            if contract == .narrative {
                let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
                let sentences = try XCTUnwrap(properties["sentences"] as? [String: Any])
                checkObject(try XCTUnwrap(sentences["items"] as? [String: Any]))
            }
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: format))
        }
    }

    private func checkObject(_ schema: [String: Any]) {
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = schema["properties"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set(properties.keys))
    }
}
