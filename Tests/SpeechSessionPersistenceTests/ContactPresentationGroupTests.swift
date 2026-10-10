import XCTest
@testable import SpeechSessionPersistence

final class ContactPresentationGroupTests: XCTestCase {
    private func fact(_ id: String, name: String = "Example contact", details: String = "", address: String = "") -> HealthFact {
        let entry = SummaryEntry(category: .practitionerContact, title: name, details: details,
                                 fields: [.init(label: "Address", value: address)], sourceSessionID: UUID())
        return HealthFact(id: id, occurrences: [entry], preference: .init(id: id), topicIDs: [])
    }

    func testDifferentDescriptionsShareHeadingWithoutMergingIdentity() {
        let a = fact("a", details: "Provided one service")
        let b = fact("b", details: "Provided another service")
        let groups = ContactPresentationGroup.groups(facts: [a,b], members: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].facts.map(\.id), ["a", "b"])
        XCTAssertEqual(groups[0].facts.map { $0.latest.details }, [a.latest.details, b.latest.details])
        XCTAssertEqual(Set(groups[0].facts.flatMap(\.occurrences).map(\.id)), Set([a.latest.id,b.latest.id]))
    }

    func testConflictingAddressesStayAvailableUnderSameHeading() {
        let a = fact("a", address: "10 Main St, A1A 1A/")
        let b = fact("b", address: "10 Main St, A1A 1A7")
        let c = fact("c", address: "99 Other St")
        let groups = ContactPresentationGroup.groups(facts: [a,b,c], members: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].facts.count, 3)
        XCTAssertEqual(groups[0].facts.map { $0.latest.fields[0].value }, [a,b,c].map { $0.latest.fields[0].value })
        XCTAssertTrue(groups[0].facts.allSatisfy { $0.latest.evidence?.factIdentity == nil })
    }

    func testChoicesAndSourceLinksArePreservedAndExplicitSeparationRespected() {
        var a = fact("a"), b = fact("b"), hidden = fact("hidden"), separated = fact("separate")
        a.preference.clinicalStatus = .current
        b.preference.clinicalStatus = .past
        hidden.preference.hidden = true
        separated.occurrences[0].evidence = ClinicalEvidence()
        separated.occurrences[0].evidence?.combinationExcluded = true
        let groups = ContactPresentationGroup.groups(facts: [a,b,hidden,separated], members: [])
        XCTAssertEqual(groups.count, 2)
        let shared = groups.first { $0.count == 2 }!
        XCTAssertEqual(shared.facts.map { $0.preference.clinicalStatus }, [.current,.past])
        XCTAssertEqual(shared.facts.map { $0.latest.sourceSessionID }, [a.latest.sourceSessionID,b.latest.sourceSessionID])
    }

    func testSavedContactsAndExtractedFactsShareHeadingAndStableOrder() {
        let a = fact("a", name: "  EXAMPLE   contact ")
        let member = CareTeamMember(name: "Example contact", address: "Distinct saved address")
        let other = fact("other", name: "Other contact")
        let groups = ContactPresentationGroup.groups(facts: [other,a], members: [member])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual(groups[0].members[0], member)
        XCTAssertEqual(groups.map(\.id), ContactPresentationGroup.groups(facts: [a,other], members: [member]).map(\.id))
        XCTAssertEqual(ContactPresentationGroup.groups(facts: [fact("x", name: ""),fact("y", name: "")], members: []).count, 2)
    }
}
