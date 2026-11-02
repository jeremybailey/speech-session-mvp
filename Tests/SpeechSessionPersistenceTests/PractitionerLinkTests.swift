import XCTest
@testable import SpeechSessionPersistence

final class PractitionerLinkTests: XCTestCase {
    func testDifferentPractitionersPreventAutomaticFactCombination() {
        let entry = SummaryEntry(category: .findings, title: "Finding")
        var first = HealthFactPreference(id: "a")
        var second = HealthFactPreference(id: "b")
        first.practitionerContactID = UUID()
        second.practitionerContactID = UUID()
        let a = HealthFact(id: "a", occurrences: [entry], preference: first, topicIDs: [])
        let b = HealthFact(id: "b", occurrences: [entry], preference: second, topicIDs: [])
        XCTAssertFalse(HealthFactConsolidation.preferencesAgree(a, b, savedIDs: ["a", "b"]))
    }

    func testPractitionerFieldAliasesUseContactSelection() {
        for label in ["Practitioner", "Practitioner name", "Provider", "Doctor", "Clinician", "Health care provider"] {
            XCTAssertTrue(HealthDetailPresentation.isPractitionerField(label), label)
        }
        for label in ["Details", "Dose", "Provider instructions", "Follow-up owner"] {
            XCTAssertFalse(HealthDetailPresentation.isPractitionerField(label), label)
        }
    }

    func testLegacyPreferenceDecodesWithoutContact() throws {
        let preference = HealthFactPreference(id: "old")
        let data = try JSONEncoder().encode(preference)
        XCTAssertNil(try JSONDecoder().decode(HealthFactPreference.self, from: data).practitionerContactID)
    }

    func testLinksPersistAndContactEditsAreShared() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        var contact = CareTeamMember(name: "Dr Lee", role: "Physician", organization: "Clinic", email: "lee@example.com", phone: "123", address: "Main Street", notes: "Office hours")
        try await store.saveCareTeamMember(contact)
        var preference = HealthFactPreference(id: "a")
        preference.hidden = true
        try await store.savePreference(preference)
        try await store.assignPractitioner(contact.id, factIDs: ["a", "b"])
        contact.name = "Dr Lee Updated"
        try await store.saveCareTeamMember(contact)
        let reopened = try SessionStore(storageDirectory: directory)
        let snapshot = try await reopened.healthSnapshot()
        XCTAssertEqual(snapshot.preferences.count, 2)
        XCTAssertTrue(snapshot.preferences.allSatisfy { $0.practitionerContactID == contact.id })
        XCTAssertTrue(snapshot.preferences.first { $0.id == "a" }!.hidden)
        XCTAssertEqual(snapshot.careTeam.first?.name, "Dr Lee Updated")
        XCTAssertEqual(snapshot.careTeam.first?.address, "Main Street")
    }

    func testMissingContactDoesNotPartiallyAssign() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        do { try await store.assignPractitioner(UUID(), factIDs: ["a", "b"]); XCTFail("Expected rejection") }
        catch { }
        let snapshot = try await store.healthSnapshot()
        XCTAssertTrue(snapshot.preferences.isEmpty)
    }

    func testRemovalClearsLinksWithoutChangingSourceAttribution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let contact = CareTeamMember(name: "Dr Lee")
        try await store.saveCareTeamMember(contact)
        var entry = SummaryEntry(category: .carePlan, title: "Rest")
        entry.evidence = ClinicalEvidence()
        entry.evidence?.practitioner = "Source clinician"
        let session = Session(transcript: "Rest", summaryEntries: [entry])
        try await store.upsert(session)
        try await store.assignPractitioner(contact.id, factIDs: ["a"])
        try await store.deleteCareTeamMember(id: contact.id)
        let snapshot = try await store.healthSnapshot()
        XCTAssertNil(snapshot.preferences.first?.practitionerContactID)
        XCTAssertEqual(snapshot.sessions.first?.summaryEntries?.first?.evidence?.practitioner, "Source clinician")
    }

    func testCombinedContactResolvesToCanonicalIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let root = CareTeamMember(name: "Dr Lee")
        var alias = CareTeamMember(name: "Lee")
        alias.duplicateOf = root.id
        try await store.saveCareTeamMember(root)
        try await store.saveCareTeamMember(alias)
        try await store.assignPractitioner(alias.id, factIDs: ["a"])
        let snapshot = try await store.healthSnapshot()
        XCTAssertEqual(snapshot.preferences.first?.practitionerContactID, root.id)
    }
}
