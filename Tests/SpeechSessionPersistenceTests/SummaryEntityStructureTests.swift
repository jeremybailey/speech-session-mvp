import XCTest
@testable import SpeechSessionPersistence
final class SummaryEntityStructureTests: XCTestCase {
    func testAttributesAreNotEntitiesInAnyCategory() {
        for category in SummaryEntryCategory.allCases {
            for title in ["strength: 0.1%", "Strength: 50MCG/0.5ML", "phone: 1234567890", "Result: 2.03", "Frequency: daily"] {
                let e = SummaryEntry(category: category, title: title)
                XCTAssertNotNil(SummaryEntityStructure.exclusion(e))
                let admitted = SummaryVerification.sourceLinked(e, source: title, evidence: title)
                XCTAssertFalse(SummaryVerification.isVisible(admitted, source: title))
            }
        }
    }
    func testNamedIncompleteMedicationRemainsValid() {
        for title in ["Example drug", "5-FU", "Vitamin B12", "Example 0.1% eye drops"] {
            XCTAssertNil(SummaryEntityStructure.exclusion(.init(category: .medications, title: title)))
        }
        for title in ["0.1%", "50MCG/0.5ML", "5 mg"] {
            XCTAssertNotNil(SummaryEntityStructure.exclusion(.init(category: .medications, title: title)))
        }
    }
    func testIndentedFieldsStayWithParentAndUnboundFieldsDoNotAttach() {
        XCTAssertEqual(SummaryEntityStructure.lines("- Example drug\n  strength: 0.1%\n  frequency: daily\n- Other drug"),
                       ["Example drug — strength: 0.1%; frequency: daily", "Other drug"])
        XCTAssertEqual(SummaryEntityStructure.lines("- Example drug\n\n  strength: 0.1%"), ["Example drug", "strength: 0.1%"])
        XCTAssertEqual(SummaryEntityStructure.lines("- Example drug\n- strength: 0.1%"), ["Example drug", "strength: 0.1%"])
    }
    func testPreviouslySupportedOrphanIsHiddenWithoutDeletingOriginal() {
        let title = "strength: 0.1%"
        var e = SummaryEntry(category: .medications, title: title)
        e.evidence = ClinicalEvidence()
        let fingerprint = SummaryVerification.contentHash(e)
        e.evidence?.assessment = .init(admission: .supported, reason: "Present in source", sourceHash: SummaryVerification.hash(title), contentHash: fingerprint, citations: [])
        XCTAssertFalse(SummaryVerification.isVisible(e, source: title))
        XCTAssertFalse(e.isDeleted)
        e.origin = .userAdded
        XCTAssertTrue(SummaryVerification.isVisible(e, source: title))
    }
}
