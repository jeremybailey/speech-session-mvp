import XCTest
@testable import SpeechSessionPersistence

final class SummaryStatementTypeRepairTests: XCTestCase {
    let source = "The clinician discussed an optional follow-up if symptoms persist."
    func fixture() -> (SummaryEntry, SummaryCheck) {
        var entry = SummaryEntry(category: .carePlan, title: "Optional follow-up", details: source)
        entry.fields = [.init(label: "Statement type", value: "Care instruction"), .init(label: "Reported by", value: "Clinician")]
        let check = SummaryCheck(id: entry.id, supported: false, reason: "Type unsupported; remaining claims supported.",
            citations: ["title", "details", "field:Reported by"].map { .init(field: $0, excerpt: source) },
            uncertainFields: ["field:Statement type"])
        return (entry, check)
    }
    func testOnlyLabelIsRemovedAndCandidateRequiresNewVerification() throws {
        let (entry, check) = fixture()
        let reduced = try XCTUnwrap(SummaryVerification.statementTypeRepairCandidate(entry, check: check, source: source))
        XCTAssertEqual(reduced.id, entry.id)
        XCTAssertEqual(reduced.title, entry.title)
        XCTAssertEqual(reduced.details, entry.details)
        XCTAssertEqual(reduced.category, entry.category)
        XCTAssertEqual(reduced.clinicalStatus, entry.clinicalStatus)
        XCTAssertEqual(reduced.fields.map(\.label), ["Reported by"])
        XCTAssertEqual(reduced.evidence?.omittedFields, ["field:Statement type"])
        XCTAssertFalse(SummaryVerification.isVisible(reduced, source: source))
        XCTAssertNil(SummaryVerification.statementTypeRepairCandidate(reduced, check: check, source: source))
        var fresh = check; fresh.supported = true; fresh.uncertainFields = []
        XCTAssertTrue(SummaryVerification.isVisible(SummaryVerification.assess(reduced, check: fresh, source: source), source: source))
        XCTAssertFalse(SummaryVerification.isVisible(SummaryVerification.assess(reduced, check: check, source: source), source: source))
    }
    func testOtherUncertaintyExclusionAndWrongDecisionCannotTriggerRepair() {
        let (entry, check) = fixture()
        for fields in [[], ["details"], ["field:Statement type", "field:Reported by"], ["clinicalStatus"], ["eventDate"]] {
            var bad = check; bad.uncertainFields = fields
            XCTAssertNil(SummaryVerification.statementTypeRepairCandidate(entry, check: bad, source: source))
        }
        var wrong = check; wrong.id = UUID()
        var excluded = check; excluded.exclusion = "wrong_patient"
        var supported = check; supported.supported = true
        for bad in [wrong, excluded, supported] {
            XCTAssertNil(SummaryVerification.statementTypeRepairCandidate(entry, check: bad, source: source))
        }
    }
    func testMissingEvidenceAndDifferentSourceCannotTriggerRepair() {
        let (entry, check) = fixture()
        var missing = check; missing.citations.removeLast()
        XCTAssertNil(SummaryVerification.statementTypeRepairCandidate(entry, check: missing, source: source))
        XCTAssertNil(SummaryVerification.statementTypeRepairCandidate(entry, check: check, source: "Different record"))
    }
    func testHumanEditsAndDuplicateTypeLabelsAreProtected() {
        let (entry, check) = fixture()
        var edited = entry; edited.origin = .userEdited
        XCTAssertNil(SummaryVerification.statementTypeRepairCandidate(edited, check: check, source: source))
        var duplicate = entry; duplicate.fields.append(.init(label: "Statement type", value: "Confirmed diagnosis"))
        XCTAssertNil(SummaryVerification.statementTypeRepairCandidate(duplicate, check: check, source: source))
    }
}
