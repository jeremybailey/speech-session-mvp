import XCTest
@testable import SpeechSessionPersistence

final class SummaryCategoryClassificationTests: XCTestCase {
    func testRelatedSymptomsShareConcernWithoutRewritingSourceDetails() throws {
        let entries = [SummaryEntry(category: .symptoms, title: "Electric pain with backpack"),
                       SummaryEntry(category: .symptoms, title: "Tingling in back")]
        let raw = #"{"decisions":[{"id":0,"category":"symptoms","conditionGroup":"Back symptoms with backpack","conditionGroupReason":"The narrative links these descriptions to carrying a backpack."},{"id":1,"category":"symptoms","conditionGroup":"Back symptoms with backpack","conditionGroupReason":"The narrative links these descriptions to carrying a backpack."}]}"#
        let output = try SummaryCategoryClassification.apply(raw, to: entries)
        let facts = output.map { HealthFact(id: $0.id.uuidString, occurrences: [$0], preference: .init(id: $0.id.uuidString), topicIDs: []) }
        let groups = ConditionSummaryProjection.groups(facts: facts, topics: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].facts.map(\.title)), Set(entries.map(\.title)))
        XCTAssertEqual(output.map(\.id), entries.map(\.id))
    }
    func testConditionAssociationWithoutExplanationIsIgnored() throws {
        let entry = SummaryEntry(category: .symptoms, title: "Tingling")
        let output = try SummaryCategoryClassification.apply(#"{"decisions":[{"id":0,"category":"symptoms","conditionGroup":"Diabetes"}]}"#, to: [entry])
        XCTAssertNil(output[0].evidence?.conditionGroup)
    }
    func testEveryCategoryHasDefinitionAndAcceptsDecision() throws {
        for category in SummaryEntryCategory.allCases {
            XCTAssertFalse(SummaryCategoryClassification.definition(for: category).isEmpty)
            let entry = SummaryEntry(category: .otherNotes, title: "Original title", details: "Original details")
            let output = try SummaryCategoryClassification.apply("{\"decisions\":[{\"id\":0,\"category\":\"\(category.rawValue)\"}]}", to: [entry])
            var expected = entry
            expected.category = category
            XCTAssertEqual(output, [expected])
        }
    }
    func testUncertainCategoryRetainsEntryAndDecisionsUseIDsNotOrder() throws {
        let entries = [SummaryEntry(category: .symptoms, title: "Fatigue", details: ""),
                       SummaryEntry(category: .findings, title: "Ferritin", details: "Reported test result")]
        let output = try SummaryCategoryClassification.apply("{\"decisions\":[{\"id\":1,\"category\":\"testsAndLabs\"},{\"id\":0,\"category\":null}]}", to: entries)
        XCTAssertEqual(output[0], entries[0])
        XCTAssertEqual(output[1].category, .testsAndLabs)
        XCTAssertEqual(output[1].id, entries[1].id)
    }
    func testInvalidDecisionsCannotSilentlyDropOrMisrouteEntries() {
        let entries = [SummaryEntry(category: .symptoms, title: "Fatigue", details: "")]
        for response in ["{}", "{\"decisions\":[]}",
                         "{\"decisions\":[{\"id\":3,\"category\":\"symptoms\"}]}",
                         "{\"decisions\":[{\"id\":0,\"category\":\"invented\"}]}",
                         "{\"decisions\":[{\"id\":0,\"category\":null},{\"id\":0,\"category\":null}]}"] {
            XCTAssertThrowsError(try SummaryCategoryClassification.apply(response, to: entries))
        }
    }
}
