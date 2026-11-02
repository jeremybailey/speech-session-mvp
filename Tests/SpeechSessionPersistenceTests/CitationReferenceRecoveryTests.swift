import XCTest
@testable import SpeechSessionPersistence

private actor CitationRecoveryMock {
    let badID: UUID
    let repaired: Bool
    var phases: [String] = []
    var failRepairOnce: Bool
    init(badID: UUID, repaired: Bool, failRepairOnce: Bool = false) {
        self.badID = badID; self.repaired = repaired; self.failRepairOnce = failRepairOnce
    }
    func response(_ request: FastDetailsRequest) throws -> String {
        phases.append(request.phase)
        if request.phase == "repair", failRepairOnce {
            failRepairOnce = false
            throw SummaryResponseError.network
        }
        let body = try JSONSerialization.jsonObject(with: Data(request.input.utf8)) as! [String: Any]
        let drafts = body["drafts"] as! [String: [String: Any]]
        let source = body["originalSource"] as! String
        var decisions: [String: Any] = [:]
        for (id, draft) in drafts {
            let fields = draft["fieldsToCheck"] as! [String: Any]
            let missing = id == badID.uuidString && (request.phase != "repair" || !repaired)
            decisions[id] = ["supported": true, "reason": "", "coreSupported": false,
                "exclusion": NSNull(), "uncertainFields": [],
                "citations": Dictionary(uniqueKeysWithValues: fields.keys.map { ($0, [missing ? "originalSource" : "N1"]) })]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: [
            "evidence": [["id": "N1", "excerpt": source]], "decisions": decisions]), as: UTF8.self)
    }
}

final class CitationReferenceRecoveryTests: XCTestCase {
    func testUndefinedReferencesInvalidateWholeFieldWithoutDiscardingPeer() throws {
        let source = "Patient denies pain. Nurse: If pain returns, take Example 5 mg."
        let good = SummaryEntry(category: .symptoms, title: "Patient denies pain.", sourceExcerpt: "Patient denies pain.")
        let bad = SummaryEntry(category: .carePlan, title: "Conditional medication plan", details: "Nurse: If pain returns, take Example 5 mg.", sourceExcerpt: source)
        for unknown in ["N21", "N22", "N23", "originalSource", ""] {
            var decisions: [String: Any] = [:]
            for entry in [good, bad] {
                var citations = Dictionary(uniqueKeysWithValues: SummaryVerification.requiredFields(entry).map { ($0, ["N1"]) })
                if entry.id == bad.id { citations["details"] = ["N1", unknown] }
                decisions[entry.id.uuidString] = ["supported": true, "reason": "", "citations": citations]
            }
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: [
                "evidence": [["id": "N1", "excerpt": source]], "decisions": decisions]), as: UTF8.self)
            let checks = try FastDetailsCheck.decode(raw, entries: [good, bad], source: source)
            let goodCheck = checks.first { $0.id == good.id }!, badCheck = checks.first { $0.id == bad.id }!
            XCTAssertTrue(SummaryVerification.isVisible(SummaryVerification.assess(good, check: goodCheck, source: source), source: source))
            XCTAssertFalse(badCheck.citations.contains { $0.field == "details" }, "A valid peer locator must not mask an unresolved reference for the same field")
            XCTAssertTrue(badCheck.citations.contains { $0.field == "title" })
            XCTAssertFalse(SummaryVerification.isVisible(SummaryVerification.assess(bad, check: badCheck, source: source), source: source))
            XCTAssertEqual(SummaryVerification.citationRepairFields(bad, check: badCheck, source: source), ["details"])
        }
    }

    func testNonSourceQuotationCannotBeMaskedByValidLocatorForSameField() throws {
        let source = "Patient denies pain."
        let entry = SummaryEntry(category: .symptoms, title: source)
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: [
            "evidence": [["id": "N1", "excerpt": source], ["id": "N2", "excerpt": "Patient has pain."]],
            "decisions": [entry.id.uuidString: ["supported": true, "reason": "", "citations": ["title": ["N1", "N2"]]]]]), as: UTF8.self)
        let check = try FastDetailsCheck.decode(raw, entries: [entry], source: source)[0]
        XCTAssertTrue(check.citations.isEmpty)
        XCTAssertFalse(SummaryVerification.isVisible(SummaryVerification.assess(entry, check: check, source: source), source: source))
    }

    func testUndefinedCitationRecoversInOneTargetedPassAndCompletedWorkIsReusable() async throws {
        try await run(repaired: true)
    }

    func testUnresolvedClaimStaysHiddenWhileValidPeerIsPublishedWithoutRetryLoop() async throws {
        try await run(repaired: false)
    }

    func testInterruptedRepairResumesWithoutRepeatingExtractionOrGoodPeerCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let source = "Patient reports headache. Patient reports nausea."
        let session = Session(transcript: source)
        try await store.upsert(session)
        let good = SummaryEntry(category: .symptoms, title: "Patient reports headache.", sourceSessionID: session.id, sourceExcerpt: "Patient reports headache.")
        let bad = SummaryEntry(category: .symptoms, title: "Patient reports nausea.", sourceSessionID: session.id, sourceExcerpt: "Patient reports nausea.")
        let mock = CitationRecoveryMock(badID: bad.id, repaired: true, failRepairOnce: true)
        let pipeline = FastDetailsPipeline(scheduler: FastDetailsScheduler())
        do {
            try await pipeline.process(session: session, sources: [source], store: store,
                extract: { _, _ in [good, bad] }, send: { try await mock.response($0) })
            XCTFail("Expected the repair interruption")
        } catch { XCTAssertEqual(error as? SummaryResponseError, .network) }
        let interrupted = try await store.healthSnapshot().sessions.first!
        XCTAssertEqual(interrupted.summaryRun?.stage, .failed)
        let reopened = try SessionStore(storageDirectory: directory)
        try await pipeline.process(session: interrupted, sources: [source], store: reopened,
            extract: { _, _ in XCTFail("Saved extraction was repeated"); return [] },
            send: { request in
                XCTAssertEqual(request.phase, "repair")
                let body = try JSONSerialization.jsonObject(with: Data(request.input.utf8)) as! [String: Any]
                XCTAssertEqual(Set((body["drafts"] as! [String: Any]).keys), [bad.id.uuidString])
                return try await mock.response(request)
            })
        let result = try await reopened.healthSnapshot().sessions.first!
        XCTAssertEqual(result.summaryRun?.id, interrupted.summaryRun?.id)
        XCTAssertEqual(result.summaryRun?.stage, .complete)
        XCTAssertEqual(result.summaryEntries?.filter { SummaryVerification.isVisible($0, source: source) }.count, 2)
        let phases = await mock.phases
        XCTAssertEqual(phases, ["checking", "repair", "repair"])
    }

    private func run(repaired: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let source = "Patient reports headache. Patient reports nausea."
        let session = Session(transcript: source)
        try await store.upsert(session)
        let good = SummaryEntry(category: .symptoms, title: "Patient reports headache.", sourceSessionID: session.id, sourceExcerpt: "Patient reports headache.")
        let bad = SummaryEntry(category: .symptoms, title: "Patient reports nausea.", sourceSessionID: session.id, sourceExcerpt: "Patient reports nausea.")
        let mock = CitationRecoveryMock(badID: bad.id, repaired: repaired)
        let pipeline = FastDetailsPipeline(scheduler: FastDetailsScheduler())
        try await pipeline.process(session: session, sources: [source], store: store,
            extract: { _, _ in [good, bad] }, send: { try await mock.response($0) })
        let result = try await store.healthSnapshot().sessions.first!
        XCTAssertEqual(result.summaryRun?.stage, .complete)
        XCTAssertEqual(Set(result.summaryEntries!.map(\.id)), Set([good.id, bad.id]))
        let savedBad = result.summaryEntries!.first { $0.id == bad.id }!
        let savedGood = result.summaryEntries!.first { $0.id == good.id }!
        XCTAssertTrue(SummaryVerification.isVisible(savedGood, source: source))
        XCTAssertEqual(SummaryVerification.isVisible(savedBad, source: source), repaired)
        XCTAssertEqual(savedBad.title, bad.title)
        let phases = await mock.phases
        XCTAssertEqual(phases, ["checking", "repair"])
        try await pipeline.process(session: result, sources: [source], store: store,
            extract: { _, _ in XCTFail("Completed extraction was repeated"); return [] },
            send: { _ in XCTFail("Completed source checking was repeated"); throw SummaryResponseError.network })
    }
}
