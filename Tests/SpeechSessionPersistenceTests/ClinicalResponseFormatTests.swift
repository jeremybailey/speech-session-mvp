import XCTest
@testable import SpeechSessionPersistence

final class ClinicalResponseFormatTests: XCTestCase {
    func testConditionContractsCannotEmitAnUnsupportedBodySystem() throws {
        for (stage, key) in [("condition-synthesis", "groups"), ("condition-context-recovery", "links"), ("condition-verification", "decisions")] {
            let format = ClinicalResponseFormat.forStage(stage)
            let wrapper = try XCTUnwrap(format["json_schema"] as? [String: Any])
            let schema = try XCTUnwrap(wrapper["schema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let array = try XCTUnwrap(properties[key] as? [String: Any])
            let item = try XCTUnwrap(array["items"] as? [String: Any])
            let fields = try XCTUnwrap(item["properties"] as? [String: Any])
            let system = try XCTUnwrap(fields["bodySystem"] as? [String: Any])
            let allowed = try XCTUnwrap(system["enum"] as? [String])
            XCTAssertTrue(allowed.contains("cardiovascular"))
            XCTAssertTrue(allowed.contains("unknown"))
            XCTAssertFalse(allowed.contains("circulatory"), "Observed invalid response must be excluded at generation")
            XCTAssertEqual(Set(allowed), Set(ConditionSynthesis.bodySystems))
        }
    }
    func testConditionMappingSchemaBoundsMatchThePersistedValidator() throws {
        let format = ClinicalResponseFormat.forStage("condition-synthesis")
        let wrapper = try XCTUnwrap(format["json_schema"] as? [String: Any])
        let schema = try XCTUnwrap(wrapper["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let groups = try XCTUnwrap(properties["groups"] as? [String: Any])
        let item = try XCTUnwrap(groups["items"] as? [String: Any])
        let fields = try XCTUnwrap(item["properties"] as? [String: Any])
        XCTAssertEqual((fields["name"] as? [String: Any])?["maxLength"] as? Int, 80)
        XCTAssertEqual((fields["reason"] as? [String: Any])?["maxLength"] as? Int, 300)
        // The generator constraint must not weaken strict unknown-field rejection.
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
    }

    func testContextRecoveryUsesDedicatedStrictLinkSchema() throws {
        let format = ClinicalResponseFormat.forStage("condition-context-recovery")
        let wrapper = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(wrapper["name"] as? String, "health_condition_context_recovery")
        let schema = try XCTUnwrap(wrapper["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let links = try XCTUnwrap(properties["links"] as? [String: Any])
        let link = try XCTUnwrap(links["items"] as? [String: Any])
        XCTAssertEqual(Set(link["required"] as? [String] ?? []), Set(["name", "bodySystem", "entryID", "reason"]))
    }

    func testCheckerSchemaOnlyAllowsCurrentBatchIdentities() throws {
        let first = UUID(), second = UUID(), otherBatch = UUID()
        func identifier(_ ids: [UUID]) throws -> [String: Any] {
            let format = ClinicalResponseFormat.forStage("checking", expectedCheckIDs: ids)
            let wrapper = try XCTUnwrap(format["json_schema"] as? [String: Any])
            XCTAssertEqual(wrapper["strict"] as? Bool, true)
            let schema = try XCTUnwrap(wrapper["schema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let decisions = try XCTUnwrap(properties["decisions"] as? [String: Any])
            XCTAssertEqual(Set(decisions["required"] as? [String] ?? []), Set(ids.map(\.uuidString)))
            XCTAssertEqual(decisions["additionalProperties"] as? Bool, false)
            let keyed = try XCTUnwrap(decisions["properties"] as? [String: Any])
            let items = try XCTUnwrap(keyed[ids[0].uuidString] as? [String: Any])
            let fields = try XCTUnwrap(items["properties"] as? [String: Any])
            return try XCTUnwrap(fields["id"] as? [String: Any])
        }
        XCTAssertEqual(try identifier([first, second])["enum"] as? [String], [first.uuidString])
        XCTAssertEqual(try identifier([otherBatch])["enum"] as? [String], [otherBatch.uuidString])
        // Schema constraints supplement, never replace exact coverage validation.
        let row: [String: Any] = ["id": first.uuidString, "supported": true, "reason": "test", "citations": []]
        XCTAssertThrowsError(try SummaryResponseError.decodeChecks([row, row], expectedIDs: [first, second]))
        XCTAssertThrowsError(try SummaryResponseError.decodeChecks([row], expectedIDs: [first, second]))
    }
}
