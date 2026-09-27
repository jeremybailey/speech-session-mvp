import XCTest
@testable import SpeechSessionPersistence

final class SourceLinkedAdmissionTests: XCTestCase {
    func testReviewRequiredFactStaysInRecordButCannotEnterPortrait() {
        let source = "The patient reports tingling in the right hand."
        let draft = SummaryEntry(category: .symptoms, title: "tingling", details: "Patient reports tingling in the right hand.")
        let linked = SummaryVerification.sourceLinked(draft, source: source, evidence: source)
        XCTAssertTrue(SummaryVerification.isVisible(linked, source: source))
        XCTAssertFalse(SummaryVerification.isPortraitEligible(linked, source: source))
        XCTAssertEqual(SummaryVerification.trust(of: linked, sourceHash: SummaryVerification.hash(source)), .reviewRequired)
        let patient = SummaryEntry(category: .symptoms, title: "My tingling", origin: .userAdded)
        XCTAssertEqual(SummaryVerification.trust(of: patient, sourceHash: SummaryVerification.hash(source)), .patientConfirmed)
        let snapshot = HealthMemorySnapshot(sessions: [Session(transcript: source, summaryEntries: [linked])])
        XCTAssertTrue(HealthMemoryProjection.facts(in: snapshot, verifiedOnly: true).isEmpty)
        XCTAssertEqual(HealthMemoryProjection.facts(in: snapshot, verifiedOnly: false).count, 1)
    }
    func testAttributedJournalParaphraseUsesItsOwnQuote() {
        let source = "My ankle injury still bothers me. Please include this in my health story."
        var draft = SummaryEntry(category: .chiefComplaint, title: "Persistent ankle injury", details: "Patient reports continuing difficulty from an ankle injury.")
        draft.evidence = ClinicalEvidence()
        draft.evidence?.excerpt = "My ankle injury still bothers me."
        let accepted = SummaryVerification.sourceLinked(draft, source: source, evidence: source)
        XCTAssertTrue(SummaryVerification.isVisible(accepted, source: source))
        XCTAssertEqual(accepted.evidence?.assessment?.admission, .sourceLinked)
        XCTAssertTrue(accepted.needsReview)
        let blocked = SummaryVerification.sourceLinked(draft, source: source, evidence: source, exclusion: "contradicted")
        XCTAssertFalse(SummaryVerification.isVisible(blocked, source: source))
        draft.evidence?.excerpt = "A quote absent from the transcript"
        XCTAssertFalse(SummaryVerification.isVisible(SummaryVerification.sourceLinked(draft, source: source, evidence: source), source: source))
        let meta = SummaryEntry(category: .otherNotes, title: "Please include this in my health story.")
        XCTAssertFalse(SummaryVerification.isVisible(SummaryVerification.sourceLinked(meta, source: source, evidence: source), source: source))
    }
    func testIncompleteLabIsVisibleWithoutFabricatedMetadataOrVerification() {
        let source = "Test Name\nThyroid Stimulating Hormone (TSH)\nResult\n2.03 mIU/L"
        let draft = SummaryEntry(category: .testsAndLabs, title: "Thyroid Stimulating Hormone (TSH)", fields: [.init(label: "Result", value: "2.03 mIU/L")])
        let entry = SummaryVerification.sourceLinked(draft, source: source, evidence: source)
        XCTAssertTrue(SummaryVerification.isVisible(entry, source: source))
        XCTAssertEqual(entry.evidence?.assessment?.admission, .sourceLinked)
        XCTAssertNil(entry.evidence?.eventDate)
        XCTAssertNil(entry.evidence?.practitioner)
        XCTAssertEqual(entry.fields, draft.fields)
        XCTAssertTrue(entry.needsReview)
        XCTAssertFalse(SummaryVerification.isVisible(entry, source: source + " corrected"))
    }
    func testMissingDoseDoesNotExcludeRecordedMedication() {
        let source = "Medications (Active)\nEXAMPLE DRUG 0.1% Jan 9, 2026"
        let entry = SummaryVerification.sourceLinked(.init(category: .medications, title: "EXAMPLE DRUG 0.1%"), source: source, evidence: source)
        XCTAssertTrue(SummaryVerification.isVisible(entry, source: source))
        XCTAssertNil(entry.evidence?.dose)
        XCTAssertNil(entry.evidence?.frequency)
    }
    func testBoilerplateAndExplicitContradictionsRemainExcluded() {
        let privacy = "Patient's health information is private and should be shared only with trusted individuals."
        let notice = SummaryVerification.sourceLinked(.init(category: .otherNotes, title: privacy), source: privacy, evidence: privacy)
        XCTAssertFalse(SummaryVerification.isVisible(notice, source: privacy))
        let source = "No lung mass"
        let contradicted = SummaryVerification.sourceLinked(.init(category: .findings, title: "Lung mass"), source: source, evidence: source, exclusion: "contradicted")
        XCTAssertFalse(SummaryVerification.isVisible(contradicted, source: source))
        let unrelated = SummaryVerification.sourceLinked(.init(category: .findings, title: "Kidney stone"), source: source, evidence: source)
        XCTAssertFalse(SummaryVerification.isVisible(unrelated, source: source))
    }
    func testPatientRemovalAndContentChangesStillHideSourceLinkedEntries() {
        let source = "Fatigue"
        var entry = SummaryVerification.sourceLinked(.init(category: .symptoms, title: source), source: source, evidence: source)
        entry.isDeleted = true
        XCTAssertFalse(SummaryVerification.isVisible(entry, source: source))
        entry.isDeleted = false; entry.title = "Other symptom"
        XCTAssertFalse(SummaryVerification.isVisible(entry, source: source))
    }
}
