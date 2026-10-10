import XCTest
@testable import SpeechSessionPersistence

final class SummarySourceCheckTests: XCTestCase {
    func testKeyedClaimsAreOrderIndependentAndRejectDuplicateIdentity() throws {
        let first = SummaryEntry(category: .symptoms, title: "Itchy rash")
        let second = SummaryEntry(category: .symptoms, title: "Headache")
        let forward = try SummarySourceCheck.input([first, second], source: "Synthetic source")
        XCTAssertEqual(forward, try SummarySourceCheck.input([second, first], source: "Synthetic source"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(forward.utf8)) as? [String: Any])
        let drafts = try XCTUnwrap(payload["drafts"] as? [String: [String: Any]])
        for entry in [first, second] {
            let row = try XCTUnwrap(drafts[entry.id.uuidString])
            XCTAssertEqual(row["id"] as? String, entry.id.uuidString)
            XCTAssertEqual((row["fieldsToCheck"] as? [String: Any])?["title"] as? String, entry.title)
        }
        XCTAssertThrowsError(try SummarySourceCheck.input([first, first], source: "Synthetic source"))
    }
    func testRequestContainsClinicalClaimsWithoutDisplayPlaceholdersOrPriorVerdicts() throws {
        var entry = SummaryEntry(category: .symptoms, title: "Itchy rash",
                                 fields: [.init(label: "Practitioner", value: "", isMissing: true)])
        entry.evidence = ClinicalEvidence()
        entry.evidence?.excerpt = "DRAFT QUOTE IS NOT EVIDENCE"
        entry.evidence?.assessment = .init(admission: .sourceLinked, reason: "PRIOR VERDICT",
            sourceHash: "old", contentHash: "old", citations: [])
        let source = "Patient reports an itchy rash."
        let input = try SummarySourceCheck.input([entry], source: source)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        XCTAssertEqual(payload["originalSource"] as? String, source)
        let rows = try XCTUnwrap(payload["drafts"] as? [String: [String: Any]])
        let fields = try XCTUnwrap(rows[entry.id.uuidString]?["fieldsToCheck"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), SummaryVerification.requiredFields(entry))
        XCTAssertEqual(fields["title"] as? String, "Itchy rash")
        XCTAssertFalse(input.contains("Practitioner"))
        XCTAssertFalse(input.contains("DRAFT QUOTE"))
        XCTAssertFalse(input.contains("PRIOR VERDICT"))
        XCTAssertFalse(input.contains("createdAt"))
    }

    func testRequestRetainsConditionalDirectionsAndConflictingPopulatedFields() throws {
        var entry = SummaryEntry(category: .carePlan, title: "Call if rash persists",
            fields: [.init(label: "Dose", value: "5 mg"), .init(label: "Dose", value: "10 mg")])
        entry.evidence = ClinicalEvidence()
        entry.evidence?.careInstruction = CareInstruction(instruction: "Call if rash persists",
            directions: "Only if still present", reviewTiming: "Friday")
        let input = try SummarySourceCheck.input([entry], source: "If the rash persists, call on Friday.")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(payload["drafts"] as? [String: [String: Any]])
        let fields = try XCTUnwrap(rows[entry.id.uuidString]?["fieldsToCheck"] as? [String: Any])
        XCTAssertEqual(fields["field:Dose"] as? [String], ["5 mg", "10 mg"])
        let instruction = try XCTUnwrap(fields["careInstruction"] as? [String: Any])
        XCTAssertEqual(instruction["directions"] as? String, "Only if still present")
        XCTAssertEqual(instruction["reviewTiming"] as? String, "Friday")
    }

    func testExclusionOverridesOtherwiseCompleteApproval() {
        let source = "If the rash persists, call on Friday."
        let draft = SummaryEntry(category: .followUp, title: "Called on Friday")
        var check = SummaryCheck(id: draft.id, supported: true, reason: "", citations: [.init(field: "title", excerpt: source)])
        check.exclusion = "contradicted"
        let result = SummaryVerification.assess(draft, check: check, source: source)
        XCTAssertEqual(result.evidence?.assessment?.admission, .sourceOnly)
        XCTAssertFalse(SummaryVerification.isVisible(result, source: source))
    }

    func testRejectedConditionalClaimDoesNotEraseSupportedPeerOrPatientEdit() {
        let source = "If the rash persists, call on Friday. Patient reports an itchy rash."
        let wrong = SummaryEntry(category: .followUp, title: "Called on Friday")
        let good = SummaryEntry(category: .symptoms, title: "Itchy rash")
        let rejected = SummaryVerification.assess(wrong, check: .init(id: wrong.id, supported: false,
            reason: "Conditional advice is not a completed call", citations: []), source: source)
        let accepted = SummaryVerification.assess(good, check: .init(id: good.id, supported: true,
            reason: "", citations: [.init(field: "title", excerpt: "Patient reports an itchy rash.")]), source: source)
        let manual = SummaryEntry(category: .otherNotes, title: "My note", origin: .userEdited)
        let snapshot = HealthMemorySnapshot(sessions: [Session(transcript: source, summaryEntries: [rejected, accepted, manual])])
        XCTAssertEqual(Set(HealthMemoryProjection.facts(in: snapshot, verifiedOnly: true).map(\.title)), ["Itchy rash", "My note"])
    }

    func testOldAdmissionCheckpointCannotResumeIntoNewRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        var session = Session(transcript: "Patient reports rash.")
        var run = SummaryRun(source: session.transcript)
        run.promptVersion = "clinical-pipeline-v4-keyed-checks"
        run.completedSourceChunks = 1
        session.summaryRun = run
        session.summaryDrafts = [SummaryEntry(category: .symptoms, title: "Old draft")]
        try await store.upsert(session)
        let fresh = try await store.beginSummaryRun(sessionID: session.id, expected: session)
        XCTAssertNotEqual(fresh.id, run.id)
        let drafts = try await store.summaryDrafts(sessionID: session.id, runID: fresh.id)
        XCTAssertTrue(drafts.isEmpty)
        XCTAssertEqual(fresh.promptVersion, SummaryVerification.promptVersion)
    }
}
