import XCTest
@testable import SpeechSessionPersistence

final class SummaryCitationRepairTests: XCTestCase {
    let source = "Patient reports a dry cough. It wakes her at night. She denies fever."
    func fixture() -> (SummaryEntry, SummaryCheck) {
        let entry = SummaryEntry(category: .symptoms, title: "Dry cough", details: "It wakes her at night.")
        let check = SummaryCheck(id: entry.id, supported: true, reason: "Supported",
            citations: [.init(field: "title", excerpt: "Patient reports a dry cough.")])
        return (entry, check)
    }
    func testRepairRequiresFreshSupportAndVerbatimCoverageWithoutChangingClaim() {
        let (entry, original) = fixture()
        XCTAssertEqual(SummaryVerification.citationRepairFields(entry, check: original, source: source), ["details"])
        let repair = SummaryCheck(id: entry.id, supported: true, reason: "Independent check",
            citations: [.init(field: "details", excerpt: "It wakes her at night.")])
        let result = SummaryVerification.assessCitationRepair(entry, original: original, repair: repair, source: source)
        XCTAssertEqual(result.evidence?.assessment?.admission, .supported)
        XCTAssertEqual(result.title, entry.title)
        XCTAssertEqual(result.details, entry.details)
        XCTAssertEqual(result.id, entry.id)
    }
    func testRejectedUncertainExcludedAndCompleteChecksAreNotCandidates() {
        let (entry, original) = fixture()
        var rejected = original; rejected.supported = false
        var uncertain = original; uncertain.uncertainFields = ["details"]
        var excluded = original; excluded.exclusion = "contradicted"
        var complete = original; complete.citations.append(.init(field: "details", excerpt: "It wakes her at night."))
        for check in [rejected, uncertain, excluded, complete] {
            XCTAssertTrue(SummaryVerification.citationRepairFields(entry, check: check, source: source).isEmpty)
        }
        XCTAssertTrue(SummaryVerification.citationRepairFields(entry, check: nil, source: source).isEmpty)
    }
    func testFailedRepairNeverMakesFactVisible() {
        let (entry, original) = fixture()
        let valid = SummaryCheck(id: entry.id, supported: true, reason: "Independent check",
            citations: [.init(field: "details", excerpt: "It wakes her at night.")])
        var rejected = valid; rejected.supported = false
        var uncertain = valid; uncertain.uncertainFields = ["details"]
        var invented = valid; invented.citations = [.init(field: "details", excerpt: "She cannot breathe.")]
        var wrongID = valid; wrongID.id = UUID()
        var excluded = valid; excluded.exclusion = "contradicted"
        for repair in [rejected, uncertain, invented, wrongID, excluded] {
            let result = SummaryVerification.assessCitationRepair(entry, original: original, repair: repair, source: source)
            XCTAssertEqual(result.evidence?.assessment?.admission, .sourceOnly)
        }
    }
    func testNewSupportCannotOverrideOriginallyRejectedClaimOrChangedSource() {
        let (entry, original) = fixture()
        var rejected = original; rejected.supported = false
        let repair = SummaryCheck(id: entry.id, supported: true, reason: "Independent check",
            citations: [.init(field: "details", excerpt: "It wakes her at night.")])
        XCTAssertEqual(SummaryVerification.assessCitationRepair(entry, original: rejected, repair: repair, source: source).evidence?.assessment?.admission, .sourceOnly)
        XCTAssertEqual(SummaryVerification.assessCitationRepair(entry, original: original, repair: repair, source: "A different record.").evidence?.assessment?.admission, .sourceOnly)
    }
}
