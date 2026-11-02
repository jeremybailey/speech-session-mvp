import XCTest
@testable import SpeechSessionPersistence

final class ConditionContactsTests: XCTestCase {
    func fact(_ entry: SummaryEntry, contact: UUID? = nil) -> HealthFact {
        var preference = HealthFactPreference(id: entry.id.uuidString)
        preference.practitionerContactID = contact
        return HealthFact(id: preference.id, occurrences: [entry], preference: preference, topicIDs: [])
    }
    func groups(_ facts: [HealthFact], members: [CareTeamMember], sessions: [Session] = []) -> [ContactPresentationGroup] {
        ConditionContacts.groups(for: .init(id: "pain", name: "Pain", bodySystem: "", facts: facts),
                                 allFacts: facts, snapshot: .init(sessions: sessions, careTeam: members))
    }
    func testExplicitLinksDeduplicateAcrossDetails() {
        let member = CareTeamMember(name: "Dr Lee")
        let facts = [fact(.init(category: .carePlan, title: "Rest"), contact: member.id),
                     fact(.init(category: .followUp, title: "Review"), contact: member.id)]
        XCTAssertEqual(groups(facts, members: [member]).flatMap(\.members).map(\.id), [member.id])
    }
    func testDirectContactFactResolvesSavedContactWithoutDuplicate() {
        let entry = SummaryEntry(category: .practitionerContact, title: "Dr Lee")
        let member = CareTeamMember(name: "Dr Lee", sourceEntryIDs: [entry.id])
        let result = groups([fact(entry)], members: [member])
        XCTAssertEqual(result.reduce(0) { $0 + $1.count }, 1)
        XCTAssertEqual(result.first?.members.first?.id, member.id)
    }
    func testSameDocumentDoesNotLinkContacts() {
        let session = Session(transcript: "Clinic letterhead: Dr Lee. Rest.")
        let entry = SummaryEntry(category: .carePlan, title: "Rest", sourceSessionID: session.id)
        XCTAssertTrue(groups([fact(entry)], members: [.init(name: "Dr Lee")], sessions: [session]).isEmpty)
    }
    func testVerifiedAttributionMatchesOnlyUniqueContact() {
        let session = Session(transcript: "Dr Lee advised rest.")
        var entry = SummaryEntry(category: .carePlan, title: "Rest", sourceSessionID: session.id)
        entry.evidence = ClinicalEvidence()
        entry.evidence?.practitioner = "Dr Lee"
        let hash = SummaryVerification.contentHash(entry)
        entry.evidence?.assessment = .init(admission: .supported, reason: "Supported",
            sourceHash: SummaryVerification.hash(session.transcript), contentHash: hash,
            citations: [.init(field: "practitioner", excerpt: session.transcript)])
        let member = CareTeamMember(name: "Dr Lee")
        XCTAssertEqual(groups([fact(entry)], members: [member], sessions: [session]).count, 1)
        XCTAssertTrue(groups([fact(entry)], members: [member, .init(name: "Dr Lee")], sessions: [session]).isEmpty)
        entry.evidence?.assessment?.citations = [.init(field: "practitioner", excerpt: "Invented quotation")]
        XCTAssertTrue(groups([fact(entry)], members: [member], sessions: [session]).isEmpty)
    }
    func testStaleOrUncheckedAttributionDoesNotMatch() {
        let session = Session(transcript: "Dr Lee advised rest.")
        var entry = SummaryEntry(category: .carePlan, title: "Rest", sourceSessionID: session.id)
        entry.evidence = ClinicalEvidence()
        entry.evidence?.practitioner = "Dr Lee"
        XCTAssertTrue(groups([fact(entry)], members: [.init(name: "Dr Lee")], sessions: [session]).isEmpty)
        let hash = SummaryVerification.contentHash(entry)
        entry.evidence?.assessment = .init(admission: .supported, reason: "Supported", sourceHash: "stale", contentHash: hash, citations: [.init(field: "practitioner", excerpt: session.transcript)])
        XCTAssertTrue(groups([fact(entry)], members: [.init(name: "Dr Lee")], sessions: [session]).isEmpty)
    }
}
