import XCTest
@testable import SpeechSessionPersistence

private actor FastMock {
    var extracted = 0
    var sent = 0
    var ids: [UUID] = []
    var failure = false
    var failAt: Int?
    func failOn(_ value: Int) { failAt = value }
    var malformed = false
    var reject = false
    var active = 0
    var peak = 0
    func setFailure(_ value: Bool) { failure = value }
    func setMalformed(_ value: Bool) { malformed = value }
    func setReject(_ value: Bool) { reject = value }
    func extract(source: String, count: Int = 2) -> [SummaryEntry] {
        extracted += 1
        return (0..<count).map { _ in
            SummaryEntry(category: .symptoms, title: source, sourceExcerpt: source)
        }
    }
    func response(_ request: FastDetailsRequest) throws -> String {
        sent += 1
        if failure || sent == failAt { throw SummaryResponseError.network }
        if malformed { malformed = false; return "refused" }
        let body = try JSONSerialization.jsonObject(with: Data(request.input.utf8)) as! [String: Any]
        let source = body["originalSource"] as! String
        let drafts = body["drafts"] as! [String: [String: Any]]
        var decisions: [String: Any] = [:]
        for (id, draft) in drafts {
            ids.append(UUID(uuidString: id)!)
            let fields = draft["fieldsToCheck"] as! [String: Any]
            decisions[id] = ["id": id, "supported": !reject, "coreSupported": false,
                "reason": reject ? "Wrong person or unsupported claim" : "Supported in original context",
                "uncertainFields": [], "exclusion": reject ? "wrong_patient" : NSNull(),
                "citations": Dictionary(uniqueKeysWithValues: fields.keys.map { ($0, ["Q"]) })] as [String: Any]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["evidence": [["id": "Q", "excerpt": source]], "decisions": decisions]), as: UTF8.self)
    }
    func work() async throws -> Int {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 10_000_000)
        return 1
    }
}

final class FastDetailsTests: XCTestCase {
    private func store() throws -> (URL, SessionStore) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (path, try SessionStore(storageDirectory: path))
    }
    func testReservationPressureWaitsForExistingWorkInsteadOfStopping() async throws {
        let scheduler = FastDetailsScheduler(limit: 4)
        actor Gate {
            var active = 0
            var paid = 0
            var rejected = 0
            func run() async throws -> Int {
                if active >= 2 {
                    rejected += 1
                    throw NSError(domain: "AIProcessing", code: 402, userInfo: ["reservationRejected": true])
                }
                active += 1; paid += 1
                try await Task.sleep(nanoseconds: 30_000_000)
                active -= 1
                return 1
            }
        }
        let gate = Gate()
        let results = try await SummaryParallelWork.map(Array(0..<12), limit: 4) { _ in
            try await scheduler.perform(group: UUID()) { try await gate.run() }
        }
        XCTAssertEqual(results.count, 12)
        let paid = await gate.paid, rejected = await gate.rejected, stopped = await scheduler.isStopped
        XCTAssertEqual(paid, 12)
        XCTAssertGreaterThan(rejected, 0)
        XCTAssertFalse(stopped)
    }
    func testTrueBudgetExhaustionStillStopsWithoutLooping() async throws {
        let scheduler = FastDetailsScheduler(limit: 1)
        do {
            let _: Int = try await scheduler.perform(group: UUID()) {
                throw NSError(domain: "AIProcessing", code: 402, userInfo: ["reservationRejected": true])
            }
            XCTFail("Expected budget stop")
        } catch { XCTAssertEqual((error as NSError).code, 402) }
        let stopped = await scheduler.isStopped
        XCTAssertTrue(stopped)
    }
    func testKnownEvidenceNeedsNoRepeatedQuoteAndFieldsAreConstrained() throws {
        let source = "Patient denies pain."
        let entry = SummaryEntry(category: .symptoms, title: source, sourceExcerpt: source)
        let request = try FastDetailsCheck.request([entry], source: source)
        let input = try JSONSerialization.jsonObject(with: Data(request.input.utf8)) as! [String: Any]
        XCTAssertEqual(input["candidateEvidence"] as? [String: String], ["Q0": source])
        let format = try JSONSerialization.jsonObject(with: request.responseFormat) as! [String: Any]
        let schema = (format["json_schema"] as! [String: Any])["schema"] as! [String: Any]
        let properties = schema["properties"] as! [String: Any]
        let rows = (properties["decisions"] as! [String: Any])["properties"] as! [String: Any]
        let fields = (rows[entry.id.uuidString] as! [String: Any])["properties"] as! [String: Any]
        let citation = (fields["citations"] as! [String: Any])["properties"] as! [String: Any]
        XCTAssertEqual(Set(citation.keys), SummaryVerification.requiredFields(entry))
        XCTAssertNil(fields["id"])
        func response(field: String = "title", evidence: [[String: String]] = []) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["evidence": evidence,
                "decisions": [entry.id.uuidString: ["id": entry.id.uuidString, "supported": true,
                    "reason": "Supported", "citations": [field: ["Q0"]]]]]), as: UTF8.self)
        }
        let checks = try FastDetailsCheck.decode(response(), entries: [entry], source: source)
        XCTAssertEqual(checks[0].citations.first?.excerpt, source)
        XCTAssertThrowsError(try FastDetailsCheck.decode(response(field: "careInstruction.instruction"), entries: [entry], source: source))
        XCTAssertThrowsError(try FastDetailsCheck.decode(response(evidence: [["id": "Q0", "excerpt": "Changed"]]), entries: [entry], source: source))
    }
    func testCompletedFactsSurviveRestartAndPresentationChangesWithoutProviderCalls() async throws {
        let (path, store) = try store(); defer { try? FileManager.default.removeItem(at: path) }
        let session = Session(transcript: "Patient reports pain."); try await store.upsert(session)
        let mock = FastMock(), pipeline = FastDetailsPipeline(scheduler: FastDetailsScheduler())
        try await pipeline.process(session: session, sources: [session.transcript], store: store,
            extract: { source, _ in await mock.extract(source: source) }, send: { try await mock.response($0) })
        let before = try await store.healthSnapshot().sessions.first!
        let savedBytes = try Data(contentsOf: path.appendingPathComponent(SessionStore.sessionsFileName))
        let reopened = try SessionStore(storageDirectory: path)
        // Presentation is a projection of checked facts, not an extraction input.
        for grouped in [true, false] {
            let facts = HealthMemoryProjection.facts(in: try await reopened.healthSnapshot(), groupHistoryForDisplay: grouped)
            XCTAssertFalse(facts.isEmpty)
            try await pipeline.process(session: before, sources: [before.transcript], store: reopened,
                extract: { _, _ in XCTFail("Presentation change restarted extraction"); return [] },
                send: { _ in XCTFail("Presentation change restarted checking"); throw SummaryResponseError.network })
        }
        let after = try await reopened.healthSnapshot().sessions.first!
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent(SessionStore.sessionsFileName)), savedBytes)
        XCTAssertEqual(after.summaryEntries?.map(\.id), before.summaryEntries?.map(\.id))
        XCTAssertEqual(after.summaryRun?.id, before.summaryRun?.id)
    }
    func testExtractionSplitPersistsSuccessfulHalvesAcrossRestart() async throws {
        let (path, store) = try store(); defer { try? FileManager.default.removeItem(at: path) }
        let source = "First symptom.\n\nSecond symptom."
        let session = Session(transcript: source); try await store.upsert(session)
        let mock = FastMock(), pipeline = FastDetailsPipeline(scheduler: FastDetailsScheduler())
        do {
            try await pipeline.process(session: session, sources: [source], store: store,
                extract: { text, _ in
                    if text == source { throw SummaryResponseError.responseTooLong }
                    if text.contains("Second") { try await Task.sleep(nanoseconds: 30_000_000); throw SummaryResponseError.network }
                    return await mock.extract(source: text, count: 1)
                }, send: { try await mock.response($0) })
            XCTFail("Expected interrupted extraction")
        } catch { XCTAssertEqual(error as? SummaryResponseError, .network) }
        let reopened = try SessionStore(storageDirectory: path)
        try await pipeline.process(session: session, sources: [source], store: reopened,
            extract: { text, _ in
                XCTAssertNotEqual(text, source)
                XCTAssertFalse(text.contains("First"), "Successful first half was repeated")
                return await mock.extract(source: text, count: 1)
            }, send: { try await mock.response($0) })
        let result = try await reopened.healthSnapshot().sessions.first!
        XCTAssertEqual(result.summaryEntries?.count, 2)
        XCTAssertTrue(result.summaryEntries!.first!.title.contains("First"))
    }
    func testWholeRecordLimitAndSplitsPreserveUnicodeSource() {
        let small = String(repeating: "é", count: 24_000)
        XCTAssertEqual(FastDetailsPipeline.extractionSources(small), [small])
        let large = String(repeating: "A paragraph with emoji 🫀.\n\n", count: 3_000)
        let chunks = FastDetailsPipeline.extractionSources(large)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 24_000 })
        XCTAssertEqual(chunks.joined(), large)
    }
    func testParentCareInstructionFieldIsRequiredAndNestedFieldRejected() throws {
        let source = "Rest and drink fluids."
        var entry = SummaryEntry(category: .carePlan, title: source, sourceExcerpt: source)
        entry.evidence = ClinicalEvidence()
        entry.evidence?.careInstruction = CareInstruction(instruction: source)
        let request = try FastDetailsCheck.request([entry], source: source)
        XCTAssertTrue(request.input.contains("careInstruction"))
        let mockJSON: [String: Any] = ["evidence": [], "decisions": [entry.id.uuidString: [
            "id": entry.id.uuidString, "supported": true, "reason": "Source explicitly instructs this",
            "citations": ["title": ["Q0"], "careInstruction": ["Q0"]]]]]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: mockJSON), as: UTF8.self)
        let checks = try FastDetailsCheck.decode(raw, entries: [entry], source: source)
        XCTAssertEqual(SummaryVerification.assess(entry, check: checks[0], source: source).evidence?.assessment?.admission, .supported)
    }
    func testCompletedReusePreservesPatientEditWithStaleCaller() async throws {
        let (path, store) = try store(); defer { try? FileManager.default.removeItem(at: path) }
        let session = Session(transcript: "Patient reports pain."); try await store.upsert(session)
        let mock = FastMock(), pipeline = FastDetailsPipeline(scheduler: FastDetailsScheduler())
        try await pipeline.process(session: session, sources: [session.transcript], store: store,
            extract: { text, _ in await mock.extract(source: text, count: 1) }, send: { try await mock.response($0) })
        var entry = try await store.healthSnapshot().sessions.first!.summaryEntries!.first!
        entry.sourceSessionID = session.id
        entry.title = "My edited wording"
        try await store.saveSummaryEntry(entry)
        let savedBytes = try Data(contentsOf: path.appendingPathComponent(SessionStore.sessionsFileName))
        try await pipeline.process(session: session, sources: [session.transcript], store: store,
            extract: { _, _ in XCTFail("Re-extracted despite completed facts"); return [] },
            send: { _ in XCTFail("Rechecked despite presentation-only reuse"); throw SummaryResponseError.network })
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent(SessionStore.sessionsFileName)), savedBytes)
    }
    func testCheckpointMergeAndBackwardDecoding() async throws {
        let (path, store) = try store(); defer { try? FileManager.default.removeItem(at: path) }
        let session = Session(transcript: "Original")
        try await store.upsert(session)
        let run = try await store.beginSummaryRun(sessionID: session.id, expected: session, promptVersion: FastDetailsPipeline.version)
        _ = try await SummaryParallelWork.map(Array(0..<32), limit: 4) { i in
            try await store.checkpointSummaryUnit(sessionID: session.id, runID: run.id, key: String(i), unit: FastDetailsWorkUnit(entries: []))
            return i
        }
        let reopened = try SessionStore(storageDirectory: path)
        let units = try await reopened.summaryWorkUnits(sessionID: session.id, runID: run.id)
        XCTAssertEqual(units.count, 32)
        let resumed = try await reopened.beginSummaryRun(sessionID: session.id, expected: session, promptVersion: FastDetailsPipeline.version)
        XCTAssertEqual(resumed.id, run.id)
        let old = SummaryRun(source: "Old source")
        let decoded = try JSONDecoder().decode(SummaryRun.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.workUnits)
        let legacy = try await reopened.beginSummaryRun(sessionID: session.id, expected: session)
        XCTAssertNotEqual(legacy.id, run.id)
    }
    func testFailedCheckResumesExtractionAndKeepsOccurrenceIDs() async throws {
        let (path, store) = try store(); defer { try? FileManager.default.removeItem(at: path) }
        let session = Session(transcript: "Patient reports pain.")
        try await store.upsert(session)
        let mock = FastMock(); await mock.setFailure(true)
        let pipeline = FastDetailsPipeline(scheduler: FastDetailsScheduler())
        do {
            try await pipeline.process(session: session, sources: [session.transcript], store: store,
                extract: { source, _ in await mock.extract(source: source) }, send: { try await mock.response($0) })
            XCTFail("Network failure must not publish")
        } catch { XCTAssertEqual(error as? SummaryResponseError, .network) }
        let before = try await store.healthSnapshot().sessions.first!
        XCTAssertNil(before.summaryEntries)
        let drafts = before.summaryRun!.workUnits!.values.first!.entries
        await mock.setFailure(false)
        try await pipeline.process(session: session, sources: [session.transcript], store: store,
            extract: { source, _ in await mock.extract(source: source) }, send: { try await mock.response($0) })
        let count = await mock.extracted
        XCTAssertEqual(count, 1)
        let after = try await store.healthSnapshot().sessions.first!
        XCTAssertEqual(Set(after.summaryEntries!.map(\.id)), Set(drafts.map(\.id)))
        XCTAssertEqual(after.summaryRun?.stage, .complete)
    }
    func testMalformedBatchSplitsOnceAndPreservesOutputOrder() async throws {
        let (path, store) = try store(); defer { try? FileManager.default.removeItem(at: path) }
        let session = Session(transcript: "Patient reports pain."); try await store.upsert(session)
        let mock = FastMock(); await mock.setMalformed(true)
        try await FastDetailsPipeline(scheduler: FastDetailsScheduler()).process(session: session, sources: [session.transcript], store: store,
            extract: { source, _ in await mock.extract(source: source, count: 16) }, send: { try await mock.response($0) })
        let sent = await mock.sent
        XCTAssertEqual(sent, 3)
        let result = try await store.healthSnapshot().sessions.first!
        let extraction = result.summaryRun!.workUnits!.first { $0.key.hasSuffix("/extract") }!.value.entries
        XCTAssertEqual(result.summaryEntries!.map(\.id), extraction.map(\.id))
    }
    func testSplitResumeDoesNotRepeatParentOrSuccessfulHalf() async throws {
        let (path, store) = try store(); defer { try? FileManager.default.removeItem(at: path) }
        let session = Session(transcript: "Patient reports pain."); try await store.upsert(session)
        let mock = FastMock(); await mock.setMalformed(true); await mock.failOn(3)
        let pipeline = FastDetailsPipeline(scheduler: FastDetailsScheduler())
        do {
            try await pipeline.process(session: session, sources: [session.transcript], store: store,
                extract: { source, _ in await mock.extract(source: source, count: 16) }, send: { try await mock.response($0) })
            XCTFail("Second half should fail")
        } catch { XCTAssertEqual(error as? SummaryResponseError, .network) }
        try await pipeline.process(session: session, sources: [session.transcript], store: store,
            extract: { source, _ in await mock.extract(source: source, count: 16) }, send: { try await mock.response($0) })
        let requests = await mock.sent, extractions = await mock.extracted, ids = await mock.ids
        XCTAssertEqual(requests, 4) // malformed parent, successful left, failed right, resumed right
        XCTAssertEqual(extractions, 1)
        XCTAssertEqual(ids.count, 16)
        XCTAssertEqual(Set(ids).count, 16)
    }
    func testPipelineCancellationRetainsExtractionForResume() async throws {
        let (path, store) = try store(); defer { try? FileManager.default.removeItem(at: path) }
        let session = Session(transcript: "Patient reports pain."); try await store.upsert(session)
        let mock = FastMock(), pipeline = FastDetailsPipeline(scheduler: FastDetailsScheduler())
        do {
            try await pipeline.process(session: session, sources: [session.transcript], store: store,
                extract: { source, _ in await mock.extract(source: source) }, send: { _ in throw CancellationError() })
            XCTFail("Cancellation should exit")
        } catch is CancellationError { }
        let interrupted = try await store.healthSnapshot().sessions.first!
        XCTAssertEqual(interrupted.summaryRun?.stage, .interrupted)
        XCTAssertNil(interrupted.summaryEntries)
        try await pipeline.process(session: session, sources: [session.transcript], store: store,
            extract: { source, _ in await mock.extract(source: source) }, send: { try await mock.response($0) })
        let extractions = await mock.extracted; XCTAssertEqual(extractions, 1)
    }
    func testSectionsCompleteOutOfOrderButPublishInSourceOrder() async throws {
        let (path, store) = try store(); defer { try? FileManager.default.removeItem(at: path) }
        let source = "First symptom. Second symptom."
        let session = Session(transcript: source); try await store.upsert(session)
        let mock = FastMock()
        try await FastDetailsPipeline(scheduler: FastDetailsScheduler()).process(session: session,
            sources: ["First symptom.", "Second symptom."], store: store,
            extract: { text, index in
                if index == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
                return await mock.extract(source: text, count: 1)
            }, send: { try await mock.response($0) })
        let result = try await store.healthSnapshot().sessions.first!
        XCTAssertEqual(result.summaryEntries!.map(\.title), ["First symptom.", "Second symptom."])
        XCTAssertTrue(result.summaryEntries!.allSatisfy { SummaryVerification.isVisible($0, source: source) })
    }
    func testSchedulerBoundsConcurrencyAndCancelledWaiters() async throws {
        let scheduler = FastDetailsScheduler(), mock = FastMock()
        let result = try await SummaryParallelWork.map(Array(0..<20), limit: 20) { _ in
            try await scheduler.perform(group: UUID()) { try await mock.work() }
        }
        XCTAssertEqual(result.count, 20)
        let peak = await mock.peak; XCTAssertEqual(peak, 4)
        let serial = FastDetailsScheduler(limit: 1)
        let first = Task { try await serial.perform(group: UUID()) { try await Task.sleep(nanoseconds: 50_000_000); return 1 } }
        try await Task.sleep(nanoseconds: 5_000_000)
        let cancelled = Task { try await serial.perform(group: UUID()) { XCTFail("Cancelled queued work dispatched"); return 2 } }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancellation lost") } catch is CancellationError { }
        _ = try await first.value
        let next = try await serial.perform(group: UUID()) { 3 }; XCTAssertEqual(next, 3)
    }
    func testAuthAndBudgetCloseNewAdmission() async throws {
        for code in [401, 402, 403] {
            let scheduler = FastDetailsScheduler(limit: 1)
            do { _ = try await scheduler.perform(group: UUID()) { () -> Int in throw NSError(domain: "AIProcessing", code: code) } }
            catch { XCTAssertEqual((error as NSError).code, code) }
            do { _ = try await scheduler.perform(group: UUID()) { XCTFail("Closed scheduler dispatched"); return 1 } }
            catch { XCTAssertEqual((error as NSError).code, code) }
        }
    }
    func testCompactEvidenceRejectsMissingInventedAndDuplicateQuotes() throws {
        let entry = SummaryEntry(category: .symptoms, title: "No pain")
        let id = entry.id.uuidString
        func response(_ evidence: [[String: String]]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["evidence": evidence, "decisions": [id: [
                "id": id, "supported": true, "reason": "", "citations": ["title": ["Q"]]
            ]]]), as: UTF8.self)
        }
        for evidence in [[], [["id":"Q","excerpt":"No pain"],["id":"Q","excerpt":"No pain"]]] {
            XCTAssertThrowsError(try FastDetailsCheck.decode(response(evidence), entries: [entry], source: "No pain"))
        }
        let invented = try FastDetailsCheck.decode(response([["id":"Q","excerpt":"Has pain"]]), entries: [entry], source: "No pain")
        XCTAssertTrue(invented[0].citations.isEmpty)
        let rejected = SummaryVerification.assess(entry, check: invented[0], source: "No pain")
        XCTAssertNotEqual(rejected.evidence?.assessment?.admission, .supported)
        XCTAssertFalse(SummaryVerification.citationRepairFields(entry, check: invented[0], source: "No pain").isEmpty)
        let checks = try FastDetailsCheck.decode(response([["id":"Q","excerpt":"No pain"]]), entries: [entry], source: "No pain")
        XCTAssertEqual(checks.first?.citations.first?.excerpt, "No pain")
        XCTAssertThrowsError(try FastDetailsCheck.decode("I refuse", entries: [entry], source: "No pain"))
    }
    func testNegationConditionalMedicationAndAttributionRemainClaims() async throws {
        let source = "Patient denies pain. Nurse: If pain returns take Example 5 mg once daily. Sister reports nausea."
        let entries = [
            SummaryEntry(category: .symptoms, title: "Patient denies pain", details: "Patient denies pain.", sourceExcerpt: "Patient denies pain."),
            SummaryEntry(category: .carePlan, title: "Conditional plan", details: "If pain returns take Example 5 mg once daily.", sourceExcerpt: "If pain returns take Example 5 mg once daily."),
            SummaryEntry(category: .medications, title: "Example", fields: [.init(label: "Dose", value: "5 mg"), .init(label: "Frequency", value: "once daily")]),
            SummaryEntry(category: .symptoms, title: "Patient reports nausea", details: "Patient reports nausea.")
        ]
        let request = try FastDetailsCheck.request(entries, source: source)
        for claim in ["denies pain", "If pain returns", "5 mg", "once daily", "Patient reports nausea"] { XCTAssertTrue(request.input.contains(claim)) }
        let mock = FastMock(); await mock.setReject(true)
        let checks = try FastDetailsCheck.decode(await mock.response(request), entries: entries, source: source)
        for entry in entries {
            XCTAssertFalse(SummaryVerification.isVisible(SummaryVerification.assess(entry, check: checks.first { $0.id == entry.id }, source: source), source: source))
        }
    }
    func testSourceEditInvalidatesCheckpoint() async throws {
        let (path, store) = try store(); defer { try? FileManager.default.removeItem(at: path) }
        let session = Session(transcript: "Original"); try await store.upsert(session)
        let run = try await store.beginSummaryRun(sessionID: session.id, expected: session, promptVersion: FastDetailsPipeline.version)
        try await store.updateTranscript(sessionID: session.id, transcript: "Changed", error: nil)
        do { try await store.checkpointSummaryUnit(sessionID: session.id, runID: run.id, key: "old", unit: FastDetailsWorkUnit(entries: [])); XCTFail("Stale source accepted") }
        catch { XCTAssertEqual(error as? SummaryCommitError, .sourceChanged) }
    }
}
