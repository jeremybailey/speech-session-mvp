import XCTest
@testable import SpeechSessionPersistence

final class ContactIdentityReviewTests: XCTestCase {
    func testBothIndependentReviewsMustAgreeAndFailureCannotAdmit() async throws {
        for responses in [[false], [true, false], [true, true]] {
            var calls = 0
            let accepted = try await ContactIdentityReview.review(input: "Original source") { _, input in
                XCTAssertEqual(input, "Original source")
                let response = responses[calls]; calls += 1
                return response ? #"{"equivalent":true}"# : #"{"equivalent":false}"#
            }
            XCTAssertEqual(calls, responses.count)
            XCTAssertEqual(accepted, responses == [true, true])
        }
        var calls = 0
        do {
            _ = try await ContactIdentityReview.review(input: "Source") { _, _ in
                calls += 1
                if calls == 1 { return #"{"equivalent":true}"# }
                throw CancellationError()
            }
            XCTFail("Failed reviewer must not authorize combination")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testReprocessingPublishesThenReconcilesFreshContactAssertions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        var session = Session(transcript: "Example Drug Mart branch 2387 dispensed both prescriptions.")
        try await store.upsert(session)
        for roles in [["Pharmacy", "Dispensing pharmacy"], ["Medication dispensary", "Retail pharmacy"]] {
            let run = try await store.beginSummaryRun(sessionID: session.id, expected: session)
            let entries = roles.map { role -> SummaryEntry in
                let draft = SummaryEntry(category: .practitionerContact, title: "Example Drug Mart #2387",
                    fields: [.init(label: "Role or specialty", value: role)], sourceSessionID: session.id)
                return SummaryVerification.assess(draft, check: .init(id: draft.id, supported: true, reason: "Synthetic fixture",
                    citations: SummaryVerification.requiredFields(draft).map { .init(field: $0, excerpt: session.transcript) }), source: session.transcript)
            }
            try await store.publishVerifiedSummary(expected: session, runID: run.id, entries: entries)
            try await store.consolidateHealthFacts()
            var snapshot = try await store.healthSnapshot()
            let pending = HealthMemoryProjection.facts(in: snapshot)
            XCTAssertEqual(pending.count, 2)
            let input = try XCTUnwrap(ContactIdentityReview.input(pending[0], pending[1], sessions: snapshot.sessions))
            let accepted = try await ContactIdentityReview.review(input: input) { _, _ in #"{"equivalent":true}"# }
            let undo = try await store.saveVerifiedPairDecision(SummaryVerification.hash(input), equivalent: accepted, root: pending[0], other: pending[1])
            XCTAssertNotNil(undo)
            try await store.consolidateHealthFacts()
            snapshot = try await store.healthSnapshot()
            let grouped = HealthMemoryProjection.facts(in: snapshot)
            XCTAssertEqual(grouped.count, 1)
            XCTAssertEqual(grouped.flatMap(\.occurrences).count, 2)
            session = try XCTUnwrap(snapshot.sessions.first)
        }
    }

    func testLongRecordWithRepeatedContactCitationsStillReachesReviewer() throws {
        let phrase = "Example Drug Mart #2387"
        let source = Session(transcript: String(repeating: "A prescription fill was dispensed by " + phrase + ".\n", count: 250))
        XCTAssertGreaterThan(source.transcript.count, 12000)
        func fact(_ id: String) -> HealthFact {
            var entry = SummaryEntry(category: .practitionerContact, title: phrase, sourceSessionID: source.id)
            entry.evidence = ClinicalEvidence(); entry.evidence?.excerpt = phrase
            return HealthFact(id: id, occurrences: [entry], preference: .init(id: id), topicIDs: [])
        }
        let a = fact("a"), b = fact("b")
        XCTAssertTrue(ConditionSourceContext.windows(facts: [a,b], sessions: [source]).isEmpty)
        let input = try XCTUnwrap(ContactIdentityReview.input(a,b,sessions: [source]))
        let object = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
        let texts = object["originalSources"] as! [String: [String]]
        XCTAssertEqual(texts[source.id.uuidString], [source.transcript])
        XCTAssertLessThanOrEqual(input.utf8.count, 80000)
        var oversized = source; oversized.transcript = String(repeating: source.transcript, count: 10)
        XCTAssertNil(try ContactIdentityReview.input(a,b,sessions: [oversized]))
    }

    func testInputUsesOriginalSourcesAndKeepsRoleVariantsForReviewer() throws {
        let source = Session(transcript: "Example Drug Mart #2387 dispensed both prescriptions. Different Branch #102 is also listed.")
        func fact(_ id: String, _ role: String) -> HealthFact {
            let entry = SummaryEntry(category: .practitionerContact, title: "Example Drug Mart #2387",
                fields: [.init(label: "Role or specialty", value: role)], sourceSessionID: source.id)
            return HealthFact(id: id, occurrences: [entry], preference: .init(id: id), topicIDs: [])
        }
        let a = fact("a", "Pharmacy"), b = fact("b", "Dispensing pharmacy")
        XCTAssertEqual(ContactIdentityReview.candidateName(a), ContactIdentityReview.candidateName(b))
        let input = try XCTUnwrap(ContactIdentityReview.input(a,b,sessions: [source]))
        XCTAssertTrue(input.contains("Different Branch #102"))
        XCTAssertTrue(input.contains("Dispensing pharmacy"))
        let object = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
        XCTAssertEqual((object["originalSources"] as? [String: [String]])?.count, 1)
        XCTAssertNil(try ContactIdentityReview.input(a,b,sessions: []))
    }
    func testMissingSourceContextAndMalformedDecisionsDoNotAuthorizeMatch() throws {
        XCTAssertFalse(try ContactIdentityReview.decision(#"{"equivalent":false}"#))
        XCTAssertTrue(try ContactIdentityReview.decision(#"{"equivalent":true}"#))
        for raw in [#"{"equivalent":1}"#, #"{"equivalent":"true"}"#, #"{}"#, #"{"equivalent":true,"other":true}"#] {
            XCTAssertThrowsError(try ContactIdentityReview.decision(raw))
        }
    }
    func testAcceptedContactIdentityPreservesOccurrencesAndCanBeUndone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        var session = Session(transcript: "Example Drug Mart #2387 dispensed both prescriptions.")
        session.summaryEntries = ["Pharmacy", "Dispensing pharmacy"].map { role in
            SummaryEntry(category: .practitionerContact, title: "Example Drug Mart #2387",
                fields: [.init(label: "Role or specialty", value: role)], sourceSessionID: session.id, origin: .userAdded)
        }
        try await store.upsert(session)
        let before = HealthMemoryProjection.facts(in: try await store.healthSnapshot())
        XCTAssertEqual(before.count, 2)
        let undo = try await store.combineHealthFacts(keeping: before[0].id, duplicateID: before[1].id)
        try await store.consolidateHealthFacts()
        let after = HealthMemoryProjection.facts(in: try await store.healthSnapshot())
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(Set(after.flatMap(\.occurrences).map(\.id)), Set(before.flatMap(\.occurrences).map(\.id)))
        try await store.undoHealthCombination(undo)
        let restored = HealthMemoryProjection.facts(in: try await store.healthSnapshot())
        XCTAssertEqual(restored.count, 2)
    }
}
