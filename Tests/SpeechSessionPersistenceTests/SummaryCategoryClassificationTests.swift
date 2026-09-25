import XCTest
@testable import SpeechSessionPersistence

final class SummaryCategoryClassificationTests: XCTestCase {
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
