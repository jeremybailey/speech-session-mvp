import XCTest
@testable import SpeechSessionPersistence

final class ContactIdentityReviewTests: XCTestCase {
    func testTenMatchingContactsUseTwoReviewsInsteadOfPairwiseCalls() async throws {
        var calls = 0
        let groups = try await ContactIdentityReview.reviewGroups(input: "Synthetic original branch references", count: 10) { _, _ in
            calls += 1
            return #"{"assignments":{"0":0,"1":0,"2":0,"3":0,"4":0,"5":0,"6":0,"7":0,"8":0,"9":0}}"#
        }
        XCTAssertEqual(groups, [Array(0..<10)])
        XCTAssertEqual(calls, 2)
    }
    func testGroupReviewUsesTwoCallsAndPreservesDisagreements() async throws {
        var calls = 0
        let groups = try await ContactIdentityReview.reviewGroups(input: "Source fixture", count: 4) { _, input in
            XCTAssertEqual(input, "Source fixture")
            calls += 1
            return calls == 1 ? #"{"assignments":{"0":0,"1":0,"2":0,"3":3}}"# : #"{"assignments":{"0":0,"1":0,"2":2,"3":2}}"#
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(groups, [[0,1],[2],[3]])
        for raw in [#"{"groups":[[0,1],[0]]}"#, // Actual rejected response: repeated membership.
                    #"{"assignments":{"0":0,"1":0}}"#, // Missing contact.
                    #"{"assignments":{"0":0,"1":0,"2":3}}"#, // Unknown label.
                    #"{"assignments":{"0":0,"1":0,"2":2,"3":3}}"#, // Unknown contact.
                    #"{"assignments":{"0":true,"1":0,"2":2}}"#,
                    #"{"assignments":{"0":0,"1":0,"2":2},"extra":true}"#, "refused"] {
            XCTAssertThrowsError(try ContactIdentityReview.groupDecision(raw, count: 3))
        }
    }
    func testAssignmentSchemaRequiresEveryContactExactlyOnce() throws {
        let format = ContactIdentityReview.groupResponseFormat(count: 3)
        let contract = try XCTUnwrap(format["json_schema"] as? [String: Any])
        let schema = try XCTUnwrap(contract["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let assignments = try XCTUnwrap(properties["assignments"] as? [String: Any])
        XCTAssertEqual(assignments["required"] as? [String], ["0", "1", "2"])
        XCTAssertEqual(assignments["additionalProperties"] as? Bool, false)
        let fields = try XCTUnwrap(assignments["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(fields.keys), ["0", "1", "2"])
        for field in fields.values { XCTAssertEqual(field["enum"] as? [Int], [0, 1, 2]) }
        XCTAssertEqual(try ContactIdentityReview.groupDecision(#"{"assignments":{"0":0,"1":0}}"#, count: 2), [[0,1]])
        XCTAssertEqual(try ContactIdentityReview.groupDecision(#"{"assignments":{"0":0,"1":1}}"#, count: 2), [[0],[1]])
    }

    func testGroupedContactCommitPreservesOccurrencesAndRejectsChangedSource() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        var session = Session(transcript: "Example Pharmacy branch 1 dispensed all three prescriptions.")
        try await store.upsert(session)
        let run = try await store.beginSummaryRun(sessionID: session.id, expected: session)
        let entries = (0..<3).map { i -> SummaryEntry in
            let draft = SummaryEntry(category: .practitionerContact, title: "Example Pharmacy",
                details: "Fill \(i)", sourceSessionID: session.id)
            return SummaryVerification.assess(draft, check: .init(id: draft.id, supported: true, reason: "Synthetic",
                citations: SummaryVerification.requiredFields(draft).map { .init(field: $0, excerpt: session.transcript) }), source: session.transcript)
        }
        try await store.publishVerifiedSummary(expected: session, runID: run.id, entries: entries)
        let saved = try await store.healthSnapshot()
        session = try XCTUnwrap(saved.sessions.first)
        let snapshot = try await store.healthSnapshot()
        let facts = HealthMemoryProjection.facts(in: snapshot)
        XCTAssertEqual(facts.count, 3)
        let groups = [facts.map(\.id)]
        var changed = session; changed.transcript += " Updated source."
        try await store.upsert(changed)
        let stale = try await store.saveContactGroupReview("stale", groups: groups, expected: facts, sources: snapshot.sessions)
        XCTAssertTrue(stale.isEmpty)
        try await store.upsert(session)
        let undos = try await store.saveContactGroupReview("accepted", groups: groups, expected: facts, sources: snapshot.sessions)
        XCTAssertEqual(undos.count, 2)
        let result = HealthMemoryProjection.facts(in: try await store.healthSnapshot())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Set(result.flatMap(\.occurrences).map(\.id)), Set(facts.flatMap(\.occurrences).map(\.id)))
        for undo in undos.reversed() { try await store.undoHealthCombination(undo) }
        let afterUndo = try await store.saveContactGroupReview("cannot-recombine", groups: groups, expected: facts, sources: snapshot.sessions)
        XCTAssertTrue(afterUndo.isEmpty)
    }
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
