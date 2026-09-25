import XCTest
@testable import SpeechSessionPersistence

final class HealthStatusPresentationTests: XCTestCase {
    func testCurrentDefaultDoesNotAssertVerification() {
        var entry = SummaryEntry(category: .symptoms, title: "Headache", clinicalStatus: .past)
        entry.evidence = ClinicalEvidence(); entry.evidence?.statusExplicit = false
        let fact = HealthMemoryProjection.facts(in: .init(sessions: [Session(transcript: "", summaryEntries: [entry])]), verifiedOnly: false)[0]
        XCTAssertEqual(fact.statusTitle, "Current")
        XCTAssertTrue(fact.isCurrent)
        XCTAssertFalse(fact.isReviewed)
        entry.evidence?.statusExplicit = true
        let past = HealthMemoryProjection.facts(in: .init(sessions: [Session(transcript: "", summaryEntries: [entry])]), verifiedOnly: false)[0]
        XCTAssertEqual(past.statusTitle, "Non-current")
        XCTAssertFalse(past.isCurrent)
    }
    func testAddressDisplayedOnceWithLineBreakAndLabelDifferences() {
        let entry = SummaryEntry(category: .practitionerContact, title: "Sample Provider",
            details: "Address: 123 Sample Street\nToronto, ON A1A 1A1\nPhone: 416-555-0100\nAccepts new patients",
            fields: [.init(label:"Address",value:"123 Sample Street, Toronto, ON A1A 1A1"),
                     .init(label:"Phone",value:"416-555-0100")])
        XCTAssertEqual(HealthDetailPresentation.remainingDetails(entry), ["Accepts new patients"])
        XCTAssertEqual(HealthDetailPresentation.fields(entry).count,2)
    }
    func testClinicalProseIsNotRemovedByAnOverlappingValue() {
        let entry = SummaryEntry(category:.medications,title:"Example",details:"Take 5 mg with food",
                                 fields:[.init(label:"Dose",value:"5 mg")])
        XCTAssertEqual(HealthDetailPresentation.remainingDetails(entry),["Take 5 mg with food"])
    }
    func testPatientStatusSurvivesRenamingAndOmissionDuringRegeneration() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = try SessionStore(storageDirectory:dir)
        let sessionID = UUID()
        var original = SummaryEntry(category:.symptoms,title:"Headache", sourceSessionID:sessionID, factKey:"headache")
        original.evidence = ClinicalEvidence(); original.evidence?.excerpt = "Headache after work."
        try await store.upsert(Session(id:sessionID,transcript:"Headache after work.",summaryEntries:[original]))
        let identity = HealthMemoryProjection.key(for:original)
        var pref = HealthFactPreference(id:identity); pref.clinicalStatus = .past
        try await store.savePreference(pref)
        var changed = original; changed.id = UUID(); changed.title = "Headaches after work"; changed.factKey = "headaches-after-work"
        try await store.applyExtraction(sessionID:sessionID,transcript:"Headache after work.",title:"Example",summary:"Example",entries:[changed],version:6)
        var snapshot = try await store.healthSnapshot()
        var facts = HealthMemoryProjection.facts(in:snapshot, verifiedOnly: false)
        XCTAssertEqual(facts.count,1); XCTAssertEqual(facts[0].id,identity); XCTAssertFalse(facts[0].isCurrent)
        try await store.applyExtraction(sessionID:sessionID,transcript:"Headache after work.",title:"Example",summary:"Empty",entries:[],version:6)
        let reopened = try SessionStore(storageDirectory:dir)
        snapshot = try await reopened.healthSnapshot(); facts = HealthMemoryProjection.facts(in:snapshot, verifiedOnly: false)
        XCTAssertEqual(facts.count,1); XCTAssertEqual(facts[0].id,identity); XCTAssertFalse(facts[0].isCurrent)
    }
}
