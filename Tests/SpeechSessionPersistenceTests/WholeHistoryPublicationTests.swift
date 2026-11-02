import XCTest
@testable import SpeechSessionPersistence

final class WholeHistoryPublicationTests: XCTestCase {
    private func linked(_ session: Session, name: String = "Headache") -> SummaryEntry {
        var entry = SummaryEntry(category: .symptoms, title: name, sourceSessionID: session.id, sourceExcerpt: session.transcript)
        var evidence = ClinicalEvidence()
        evidence.assessmentMethod = WholeHistoryPublication.version
        evidence.topicNames = ["Migraine"]
        evidence.excerpt = session.transcript
        entry.evidence = evidence
        let hash = SummaryVerification.contentHash(entry)
        entry.evidence?.assessment = SummaryAssessment(admission: .sourceLinked, reason: "Not independently checked", sourceHash: SummaryVerification.hash(session.transcript), contentHash: hash, citations: [.init(field: "detail", excerpt: session.transcript)])
        return entry
    }
    func testPublicationPreservesPatientEditsAndSourceLinkedTrust() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let edit = SummaryEntry(category: .symptoms, title: "My correction", origin: .userEdited)
        let session = Session(transcript: "I have headaches.", summaryEntries: [edit])
        try await store.upsert(session)
        let generated = linked(session)
        try await store.publishWholeHistory(.init(entries: [session.id: [generated]], topics: [.init(name: "Migraine", bodySystem: "neurological")], overview: "You report headaches."), expected: [session])
        let snapshot = try await store.healthSnapshot()
        XCTAssertTrue(snapshot.sessions[0].summaryEntries!.contains { $0.id == edit.id && $0.title == edit.title })
        XCTAssertEqual(SummaryVerification.trust(of: generated, sourceHash: SummaryVerification.hash(session.transcript)), .reviewRequired)
        XCTAssertTrue(SummaryVerification.isPortraitEligible(generated, sourceHash: SummaryVerification.hash(session.transcript)))
        XCTAssertFalse(snapshot.sessions[0].needsSummaryVerification)
        let current = try await store.wholeHistoryIsCurrent()
        XCTAssertTrue(current)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pre-whole-history-sessions.json").path))
        let facts = HealthMemoryProjection.facts(in: snapshot)
        XCTAssertTrue(ConditionSummaryProjection.groups(facts: facts, topics: snapshot.topics).contains { $0.name == "Migraine" })
    }
    func testSourceChangeOrMissingRecordRejectsEntirePublication() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let original = Session(transcript: "I have headaches.")
        try await store.upsert(original)
        let publication = WholeHistoryPublication(entries: [original.id: [linked(original)]], topics: [], overview: "Headache")
        var changed = original; changed.transcript = "I do not have headaches."
        try await store.upsert(changed)
        do { try await store.publishWholeHistory(publication, expected: [original]); XCTFail("Stale sources must not publish") } catch {}
        let snapshot = try await store.healthSnapshot()
        XCTAssertEqual(snapshot.sessions[0].transcript, changed.transcript)
        XCTAssertNil(snapshot.sessions[0].summaryRun)
        do { try await store.publishWholeHistory(.init(entries: [:], topics: [], overview: nil), expected: [changed]); XCTFail("All record boundaries must remain accounted for") } catch {}
    }
    func testExclusionClearsOldGeneratedFactsWithoutDeletingManualFacts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let manual = SummaryEntry(category: .symptoms, title: "Patient detail", origin: .userAdded)
        let old = SummaryEntry(category: .symptoms, title: "Old generated item", origin: .generated)
        let session = Session(transcript: "Weather conversation.", summaryEntries: [manual, old])
        try await store.upsert(session)
        try await store.publishWholeHistory(.init(entries: [session.id: []], topics: [], overview: nil), expected: [session])
        let entries = try await store.healthSnapshot().sessions[0].summaryEntries!
        XCTAssertTrue(entries.contains { $0.id == manual.id })
        XCTAssertFalse(entries.contains { $0.id == old.id && $0.evidence?.assessment?.admission != .superseded })
    }
    func testMissingQuotationRejectsPublication() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let session = Session(transcript: "I have headaches.")
        try await store.upsert(session)
        var invalid = linked(session)
        invalid.evidence?.assessment?.citations = [.init(field: "detail", excerpt: "Unsupported treatment")]
        do { try await store.publishWholeHistory(.init(entries: [session.id: [invalid]], topics: [], overview: "Unsupported"), expected: [session]); XCTFail("Unsupported quotation") } catch {}
        let current = try await store.wholeHistoryIsCurrent()
        XCTAssertFalse(current)
    }
}
