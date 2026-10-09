import XCTest
@testable import SpeechSessionPersistence

final class ClinicalDraftFormatTests: XCTestCase {
    private func draft(attributes: [[String: Any]] = []) -> [String: Any] {
        ["title": "Review", "facts": [["category": "carePlan", "title": "Call if rash persists",
            "details": "The nurse recommends calling on Friday only if the rash persists.",
            "sourceExcerpt": "Call on Friday if the rash persists.", "reportedBy": "Nurse",
            "statementType": "Care instruction", "statementStatus": "Planned", "attributes": attributes]]]
    }
    func testSupportedContextAndConditionalInstructionSurviveNormalization() throws {
        let result = try ClinicalDraftFormat.sections(from: draft(attributes: [
            ["name": "instruction", "value": "Call on Friday if the rash persists."],
            ["name": "topicNames", "value": ["Rash"]], ["name": "statusExplicit", "value": false]]))
        let rows = try XCTUnwrap(result["treatmentPlan"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["statementStatus"] as? String, "Planned")
        XCTAssertEqual(rows[0]["reportedBy"] as? String, "Nurse")
        XCTAssertEqual(rows[0]["instruction"] as? String, "Call on Friday if the rash persists.")
        XCTAssertNil(rows[0]["isRecurring"])
    }
    func testMalformedOrConflictingAttributesCannotSilentlyBecomeFacts() throws {
        XCTAssertThrowsError(try ClinicalDraftFormat.sections(from: draft(attributes: [
            ["name": "dose", "value": "5 mg"], ["name": "dose", "value": "10 mg"]])))
        XCTAssertThrowsError(try ClinicalDraftFormat.sections(from: draft(attributes: [["name": "isRecurring", "value": "false"]])))
        XCTAssertThrowsError(try ClinicalDraftFormat.sections(from: draft(attributes: [["name": "reportedBy", "value": "Someone else"]])))
        var object = draft(); var rows = object["facts"] as! [[String: Any]]
        rows[0]["details"] = ""; object["facts"] = rows
        XCTAssertThrowsError(try ClinicalDraftFormat.sections(from: object))
        rows[0].removeValue(forKey: "title"); object["facts"] = rows
        XCTAssertThrowsError(try ClinicalDraftFormat.sections(from: object))
    }
    func testEmptyFactsRemainEmptyAndNonExtractionPromptsStayUnchanged() throws {
        let result = try ClinicalDraftFormat.sections(from: ["title": "No facts", "facts": [[String: Any]]()])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(ClinicalDraftFormat.instructions(for: "Check source", stage: "checking"), "Check source")
        let format = ClinicalResponseFormat.forStage("extraction")
        XCTAssertEqual(format["type"] as? String, "json_schema")
    }
}
