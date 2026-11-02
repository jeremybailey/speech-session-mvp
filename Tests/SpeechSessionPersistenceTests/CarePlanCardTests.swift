import XCTest
@testable import SpeechSessionPersistence

final class CarePlanCardTests: XCTestCase {
    let source = "Dr Lee recommends rest if you can. Dr Lee will review next week."
    func input(edited: Bool = false) -> CarePlanCardInput {
        let sid = UUID()
        var a = SummaryEntry(category: .carePlan, title: "Rest", details: "Rest if you can", sourceSessionID: sid)
        if edited { a.origin = .userEdited }
        let b = SummaryEntry(category: .carePlan, title: "Try resting", details: "Rest if you can", sourceSessionID: sid)
        let facts = [a,b].map { HealthFact(id: $0.id.uuidString, occurrences: [$0], preference: .init(id: $0.id.uuidString), topicIDs: []) }
        return CarePlanCardInput(condition: .init(id: "pain", name: "Pain", bodySystem: "", facts: facts),
            session: Session(id: sid, transcript: source, summaryEntries: [a,b], inputType: .audio))
    }
    func raw(_ input: CarePlanCardInput, ids: [UUID]? = nil, quote: String? = nil, text: String = "Rest if you can") throws -> String {
        let object: [String: Any] = ["practitioner":"Dr Lee", "practitionerQuotation":source,
            "lines":[["memberIDs":(ids ?? input.entries.map(\.id)).map(\.uuidString),"text":text,
                      "bucket":"carePlan","owner":NSNull(),"quotation":quote ?? source]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func testSemanticAggregatePreservesEveryOccurrence() throws {
        let i = input()
        let card = try CarePlanCardContract.candidate(raw(i), input: i)
        XCTAssertEqual(card.lines.count, 1)
        XCTAssertEqual(Set(card.lines[0].memberIDs), Set(i.entries.map(\.id)))
        XCTAssertEqual(card.lines[0].text, "Rest if you can")
        XCTAssertEqual(card.practitioner, "Dr Lee")
    }
    func testMissingDuplicateUnknownIDsAndInventedQuotesFail() throws {
        let i = input()
        for ids in [[i.entries[0].id], [i.entries[0].id, i.entries[0].id], [UUID(), i.entries[1].id]] {
            XCTAssertThrowsError(try CarePlanCardContract.candidate(raw(i, ids: ids), input: i))
        }
        XCTAssertThrowsError(try CarePlanCardContract.candidate(raw(i, quote: "invented"), input: i))
        XCTAssertThrowsError(try CarePlanCardContract.candidate("refused", input: i))
        XCTAssertFalse(try CarePlanCardContract.accepts("{\"supported\":false,\"reason\":\"Lost conditionality or wrong owner\"}"))
        XCTAssertThrowsError(try CarePlanCardContract.accepts("{}"))
    }
    func testObservedFactKeyAndRewrittenQuotationFailures() throws {
        let i = input()
        let wrongIDs = try raw(i).replacingOccurrences(of: i.entries[0].id.uuidString, with: "rest-instruction")
        XCTAssertThrowsError(try CarePlanCardContract.candidate(wrongIDs, input: i)) {
            XCTAssertEqual($0 as? CarePlanCardValidationError, .malformed)
        }
        XCTAssertThrowsError(try CarePlanCardContract.candidate(raw(i, quote: "Dr Lee recommends some rest if you can."), input: i)) {
            XCTAssertEqual($0 as? CarePlanCardValidationError, .quotation)
        }
        let format = CarePlanCardContract.format(for: i)
        let json = format["json_schema"] as! [String: Any]
        let schema = json["schema"] as! [String: Any]
        let props = schema["properties"] as! [String: Any]
        let lines = props["lines"] as! [String: Any]
        let line = lines["items"] as! [String: Any]
        let fields = line["properties"] as! [String: Any]
        let members = fields["memberIDs"] as! [String: Any]
        let member = members["items"] as! [String: Any]
        XCTAssertEqual(Set(member["enum"] as! [String]), Set(i.entries.map { $0.id.uuidString }))
        XCTAssertNoThrow(try CarePlanCardContract.candidate(raw(i), input: i))
    }
    func evidenceRaw(_ input: CarePlanCardInput, refs: [String] = ["S1"], text: String = "Rest if you can") throws -> String {
        let object: [String: Any] = ["practitioner": NSNull(), "practitionerEvidenceIDs": [String](),
            "lines": [["memberIDs": input.entries.map { $0.id.uuidString }, "text": text,
                       "bucket": "carePlan", "owner": NSNull(), "evidenceIDs": refs]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func testEvidenceReferencesExpandWithoutRetypingSource() throws {
        let i = input()
        let result = try CarePlanCardContract.candidateFromEvidence(evidenceRaw(i), input: i)
        XCTAssertEqual(result.lines[0].quotation, i.session.transcript)
        for refs in [[], ["S999"], ["S1", "S1"], ["S1", "S999"]] {
            XCTAssertThrowsError(try CarePlanCardContract.candidateFromEvidence(evidenceRaw(i, refs: refs), input: i))
        }
        // Selecting a real source passage must never bypass the independent meaning verdict.
        XCTAssertFalse(try CarePlanCardContract.accepts("{\"supported\":false,\"reason\":\"Quotation does not support the action\"}"))
        let edited = input(edited: true)
        XCTAssertThrowsError(try CarePlanCardContract.candidateFromEvidence(evidenceRaw(edited), input: edited))
    }
    func testPassagesPreserveWhitespaceUnicodeAndBoundaryContext() throws {
        let i = input()
        var session = i.session
        session.transcript = String(repeating: "Maybe once an hour — if you can. 👩🏽‍⚕️\n", count: 100)
        let facts = i.entries.map { HealthFact(id: $0.id.uuidString, occurrences: [$0], preference: .init(id: $0.id.uuidString), topicIDs: []) }
        let long = CarePlanCardInput(condition: .init(id: "pain", name: "Pain", bodySystem: "", facts: facts), session: session)
        XCTAssertEqual(long.evidenceIDs, ["S1"])
        XCTAssertEqual(long.evidencePassages.joined(), session.transcript)
        XCTAssertEqual(try long.quotation(for: ["S1"]), session.transcript)
        let card = try CarePlanCardContract.candidateFromEvidence(evidenceRaw(long, refs: long.evidenceIDs), input: long)
        XCTAssertEqual(card.lines[0].quotation, session.transcript)
        let checking = try CarePlanCardContract.checkingPayload(card, input: long)
        let proposed = checking.components(separatedBy: "\nProposed presentation:\n").last!
        XCTAssertFalse(proposed.contains("quotation"))
        XCTAssertTrue(proposed.contains("S1"))
        let payload = try JSONSerialization.jsonObject(with: Data(long.payload().utf8)) as! [String: Any]
        XCTAssertEqual(payload["version"] as? String, "care-card-encounter-v4")
    }
    func testPatientWordingBypassesModelAndRemainsSeparate() throws {
        let i = input(edited: true)
        XCTAssertEqual(i.patientWrittenEntries.count, 1)
        XCTAssertEqual(i.generatedEntries.count, 1)
        let payload = try JSONSerialization.jsonObject(with: Data(i.payload().utf8)) as! [String: Any]
        let items = payload["items"] as! [[String: Any]]
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["id"] as? String, i.generatedEntries[0].id.uuidString)
        // The model covers only generated entries. Patient text remains available from original input.
        let card = try CarePlanCardContract.candidate(raw(i, ids: i.generatedEntries.map(\.id)), input: i)
        XCTAssertEqual(card.lines.flatMap(\.memberIDs), i.generatedEntries.map(\.id))
        XCTAssertEqual(CarePlanCardInput.patientWording(i.patientWrittenEntries[0]), "Rest\nRest if you can")
        XCTAssertThrowsError(try CarePlanCardContract.candidate(raw(i), input: i))
    }
    func testUnknownPractitionerAndCheckerFeedbackRemainDistinct() throws {
        let i = input()
        let card = try CarePlanCardContract.candidateFromEvidence(evidenceRaw(i), input: i)
        XCTAssertNil(card.practitioner)
        XCTAssertNil(card.practitionerQuotation)
        let rejected = try CarePlanCardContract.checkResult("{\"supported\":false,\"reason\":\"Unsupported dates and omitted follow-up context\"}")
        XCTAssertFalse(rejected.supported)
        XCTAssertEqual(rejected.reason, "Unsupported dates and omitted follow-up context")
        XCTAssertThrowsError(try CarePlanCardContract.checkResult("{\"supported\":false}"))
        XCTAssertThrowsError(try CarePlanCardContract.checkResult("{\"supported\":\"true\",\"reason\":\"ok\"}"))
    }
    func testSaveUsesStoredSnapshotRatherThanProjectedEntries() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let original = input()
        try await store.upsert(original.session)
        var projected = original.entries
        projected[0].title = "Display-ready instruction"
        let facts = projected.map { HealthFact(id: $0.id.uuidString, occurrences: [$0], preference: .init(id: $0.id.uuidString), topicIDs: []) }
        let i = CarePlanCardInput(condition: .init(id: "pain", name: "Pain", bodySystem: "", facts: facts), session: original.session)
        let card = try CarePlanCardContract.candidate(raw(i), input: i)
        try await store.saveCarePlanCard(card, input: i)
        let saved = await store.carePlanCards()
        XCTAssertEqual(saved, [card])
        var edited = original.session
        edited.summaryEntries![0].details = "Patient changed this during processing"
        try await store.upsert(edited)
        do { try await store.saveCarePlanCard(card, input: i); XCTFail("Saved over a changed original") } catch { }
    }
    func testPatientEditsCannotBeMergedOrParaphrased() throws {
        let i = input(edited: true)
        XCTAssertThrowsError(try CarePlanCardContract.candidate(raw(i), input: i))
    }
    func testFingerprintInvalidatesEditsAndSourceChanges() {
        let i = input()
        let facts = i.entries.map { HealthFact(id: $0.id.uuidString, occurrences: [$0], preference: .init(id: $0.id.uuidString), topicIDs: []) }
        let condition = ConditionSummary(id: "pain", name: "Pain", bodySystem: "", facts: facts)
        XCTAssertEqual(CarePlanCardInput(condition: condition, session: i.session).fingerprint, i.fingerprint)
        var changed = i.session; changed.transcript += " New information."
        XCTAssertNotEqual(CarePlanCardInput(condition: condition, session: changed).fingerprint, i.fingerprint)
        var edited = condition.facts; edited[0].preference.actionStatus = .past
        XCTAssertNotEqual(CarePlanCardInput(condition: .init(id: "pain", name: "Pain", bodySystem: "", facts: edited), session: i.session).fingerprint, i.fingerprint)
    }
    func testCacheRestartStaleWriteAndRecordDeletion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let i = input(); let card = try CarePlanCardContract.candidate(raw(i), input: i)
        try await store.upsert(i.session)
        try await store.saveCarePlanCard(card, input: i)
        let reopened = try SessionStore(storageDirectory: dir)
        let cached = await reopened.carePlanCards()
        XCTAssertEqual(cached, [card])
        var changed = i.session; changed.transcript += " changed"
        try await reopened.upsert(changed)
        do { try await reopened.saveCarePlanCard(card, input: i); XCTFail("Accepted stale input") } catch { }
        try await reopened.delete(id: i.session.id)
        let after = await reopened.carePlanCards()
        XCTAssertTrue(after.isEmpty)
    }
}
