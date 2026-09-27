import XCTest
@testable import SpeechSessionPersistence

final class SummaryVerificationTests: XCTestCase {
    private let source = "Patient reports tingling in back when wearing a heavy knapsack."
    private func supported(_ entry: SummaryEntry, source: String) -> SummaryEntry {
        SummaryVerification.assess(entry, check: SummaryCheck(id: entry.id, supported: true, reason: "Source supports the patient statement",
            citations: SummaryVerification.requiredFields(entry).map { SummaryCitation(field: $0, excerpt: source) }), source: source)
    }
    func testDraftsLegacyAndRejectedNeverReachVerifiedProjection() {
        let draft = SummaryEntry(category: .symptoms, title: "Tingling in back")
        var rejected = draft; rejected.id = UUID()
        rejected = SummaryVerification.assess(rejected, check: nil, source: source)
        var manual = draft; manual.id = UUID(); manual.origin = .userAdded; manual.title = "My concern"
        let accepted = supported(draft, source: source)
        let snapshot = HealthMemorySnapshot(sessions: [Session(transcript: source, summaryEntries: [draft,rejected,manual,accepted])])
        let facts = HealthMemoryProjection.facts(in: snapshot, verifiedOnly: true)
        XCTAssertEqual(facts.flatMap(\.occurrences).count, 2)
        XCTAssertEqual(Set(facts.map(\.title)), ["My concern", "Tingling in back"])
        XCTAssertFalse(SummaryVerification.isVisible(accepted, source: "Different source"))
    }
    func testEveryPopulatedFieldMustHaveValidEvidence() {
        let entry = SummaryEntry(category: .medications, title: "Drug", fields: [.init(label: "Dose", value: "20 mg")])
        let partial = SummaryCheck(id: entry.id, supported: true, reason: "", citations: [.init(field: "title", excerpt: source)])
        XCTAssertFalse(SummaryVerification.isVisible(SummaryVerification.assess(entry, check: partial, source: source), source: source))
        let bad = SummaryCheck(id: entry.id, supported: true, reason: "", citations: [.init(field: "title", excerpt: "invented passage")])
        XCTAssertEqual(SummaryVerification.assess(entry, check: bad, source: source).evidence?.assessment?.admission, .sourceOnly)
    }
    func testChangedContentInvalidatesApprovalButIdentityDoesNot() {
        var entry = supported(SummaryEntry(category: .symptoms, title: "Tingling"), source: source)
        entry.evidence?.factIdentity = "durable"; entry.id = UUID()
        XCTAssertTrue(SummaryVerification.isVisible(entry, source: source))
        entry.details = "On the left"
        XCTAssertFalse(SummaryVerification.isVisible(entry, source: source))
    }
    func testContaminatedAddressFailsEvenWithModelApproval() {
        let bad = SummaryEntry(category: .practitionerContact, title: "Dr Example", fields: [.init(label: "Address", value: "address: Suite 245, 520 3rd Ave SW; org: Eye Care; role: Optometrist")])
        XCTAssertFalse(SummaryVerification.isVisible(supported(bad, source: source), source: source))
        let good = SummaryEntry(category: .practitionerContact, title: "Dr Example", fields: [.init(label: "Address", value: "Suite 245, 520 3rd Ave SW, Calgary, AB")])
        XCTAssertTrue(SummaryVerification.validContactFields(good))
    }
    func testRejectedEducationAndServiceLabelsStaySourceOnly() {
        for title in ["Attachment Styles Overview", "Four Attachment Styles", "Partial Exam", "Optomap + OCT"] {
            let entry = SummaryEntry(category: .findings, title: title)
            let check = SummaryCheck(id: entry.id, supported: false, reason: "No patient-specific finding", citations: [])
            XCTAssertFalse(SummaryVerification.isVisible(SummaryVerification.assess(entry, check: check, source: title), source: title))
        }
    }
    func testAtomicPublicationRetainsEditsHistoryAndPreferences() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        var old = SummaryEntry(category: .findings, title: "Partial Exam")
        old.evidence = ClinicalEvidence(); old.evidence?.factIdentity = "legacy-exam"
        let manual = SummaryEntry(category: .otherNotes, title: "My note", origin: .userAdded)
        var session = Session(transcript: source, summaryEntries: [old,manual])
        try await store.upsert(session)
        let run = try await store.beginSummaryRun(sessionID: session.id, expected: session)
        let entry = supported(SummaryEntry(category: .symptoms, title: "Tingling in back", sourceSessionID: session.id), source: source)
        try await store.publishVerifiedSummary(expected: session, runID: run.id, entries: [entry])
        var snapshot = try await store.healthSnapshot()
        XCTAssertEqual(HealthMemoryProjection.facts(in: snapshot, verifiedOnly: true).count, 2)
        XCTAssertEqual(snapshot.sessions[0].summaryRevisions?.first?.entries.count, 2)
        XCTAssertEqual(snapshot.sessions[0].summaryRun?.stage, .complete)
        session = snapshot.sessions[0]
        let retry = try await store.beginSummaryRun(sessionID: session.id, expected: session)
        try await store.updateSummaryRun(sessionID: session.id, runID: retry.id, stage: .failed)
        snapshot = try await store.healthSnapshot()
        XCTAssertEqual(HealthMemoryProjection.facts(in: snapshot, verifiedOnly: true).count, 2)
        let reload = try SessionStore(storageDirectory: dir)
        let restored = try await reload.healthSnapshot()
        XCTAssertEqual(restored.sessions[0].summaryEntries?.map(\.id), snapshot.sessions[0].summaryEntries?.map(\.id))
        XCTAssertEqual(HealthMemoryProjection.facts(in: restored, verifiedOnly: true).count, 2)
    }
    func testSourceAndConcurrentPatientEditsBlockCommit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let session = Session(transcript: source)
        try await store.upsert(session)
        let run = try await store.beginSummaryRun(sessionID: session.id, expected: session)
        let manual = SummaryEntry(category: .otherNotes, title: "Keep this", sourceSessionID: session.id, origin: .userAdded)
        try await store.saveSummaryEntry(manual)
        do { try await store.publishVerifiedSummary(expected: session, runID: run.id, entries: []); XCTFail("Must preserve concurrent edits") }
        catch SummaryCommitError.patientChanged {}
        try await store.updateTranscript(sessionID: session.id, transcript: "Changed", error: nil)
        do { try await store.publishVerifiedSummary(expected: session, runID: run.id, entries: []); XCTFail("Must reject stale source") }
        catch SummaryCommitError.sourceChanged {}
    }
    func testEmptyVerifiedResultIsSuccessful() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let session = Session(transcript: "Educational handout")
        try await store.upsert(session)
        let run = try await store.beginSummaryRun(sessionID: session.id, expected: session)
        try await store.publishVerifiedSummary(expected: session, runID: run.id, entries: [])
        let snapshot = try await store.healthSnapshot()
        XCTAssertEqual(snapshot.sessions[0].extractionVersion, SummaryVerification.version)
        XCTAssertEqual(snapshot.sessions[0].summary, "")
    }

    func testInterruptedRunResumesCheckedChunksAfterRelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = "Patient reports migraine.\nFollow-up documents improvement."
        let session = Session(transcript: source)
        let firstStore = try SessionStore(storageDirectory: dir)
        try await firstStore.upsert(session)
        let run = try await firstStore.beginSummaryRun(sessionID: session.id, expected: session)
        let checked = supported(SummaryEntry(category: .symptoms, title: "Migraine",
            sourceSessionID: session.id), source: source)
        try await firstStore.checkpointSummaryDraft(sessionID: session.id, runID: run.id,
            entries: [checked], completedSourceChunks: 1)
        try await firstStore.updateSummaryRun(sessionID: session.id, runID: run.id, stage: .interrupted)

        let relaunchedStore = try SessionStore(storageDirectory: dir)
        let restored = try await relaunchedStore.healthSnapshot().sessions.first!
        let resumed = try await relaunchedStore.beginSummaryRun(sessionID: session.id, expected: restored)
        let drafts = try await relaunchedStore.summaryDrafts(sessionID: session.id, runID: resumed.id)

        XCTAssertEqual(resumed.id, run.id)
        XCTAssertEqual(resumed.completedSourceChunks, 1)
        XCTAssertEqual(resumed.promptVersion, "clinical-pipeline-v1")
        XCTAssertEqual(drafts.map(\.id), [checked.id])
    }
}

extension SummaryVerificationTests {
    func testCorrectionsAndOmissionsMustBeCheckedAgainAndCannotLoop() async throws {
        let draft = SummaryEntry(category: .findings, title: "Partial Exam")
        let correction = SummaryEntry(category: .testsAndLabs, title: "OCT ordered")
        let unverifiedThirdPass = SummaryEntry(category: .findings, title: "Invented result")
        var calls: [Bool] = []
        let result = try await SummaryReviewPipeline.run(draft: [draft]) { entries, allowCorrection in
            calls.append(allowCorrection)
            if allowCorrection {
                return SummaryReview(assessed: [SummaryVerification.assess(draft, check: nil, source: self.source)], corrections: [correction])
            }
            XCTAssertEqual(entries.map(\.id), [correction.id])
            return SummaryReview(assessed: [self.supported(correction, source: self.source)], corrections: [unverifiedThirdPass])
        }
        XCTAssertEqual(calls, [true, false])
        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(result.contains { $0.id == unverifiedThirdPass.id })
    }
    func testReverificationFailureReturnsNoPartialResult() async {
        struct Failed: Error {}
        let draft = SummaryEntry(category: .symptoms, title: "Tingling")
        do {
            _ = try await SummaryReviewPipeline.run(draft: [draft]) { _, allowCorrection in
                if !allowCorrection { throw Failed() }
                return SummaryReview(assessed: [], corrections: [draft])
            }
            XCTFail("Failure must not publish a partial draft")
        } catch { XCTAssertTrue(error is Failed) }
    }
    func testVerifiedFiveHundredRecordProjection() {
        let text = "Patient reports tingling in back when wearing a heavy knapsack."
        let records = (0..<500).map { _ in
            Session(transcript: text, summaryEntries: (0..<20).map { index in
                supported(SummaryEntry(category: .symptoms, title: "Synthetic symptom \(index)"), source: text)
            })
        }
        let facts = HealthMemoryProjection.facts(in: HealthMemorySnapshot(sessions: records))
        XCTAssertEqual(facts.count, 20)
        XCTAssertEqual(facts.flatMap(\.occurrences).count, 10_000)
    }

    func testSyntheticPresentationFixture() async throws {
        guard let destination = ProcessInfo.processInfo.environment["VERIFIED_QA_FIXTURE_PATH"] else { return }
        let store = try SessionStore(storageDirectory: URL(fileURLWithPath: destination))
        let transcript = "Patient reports tingling in back when wearing a heavy knapsack. Dr Example recommended adjusting the backpack. Partial Exam."
        var symptom = SummaryEntry(category: .symptoms, title: "Tingling in back", details: "When wearing a heavy backpack")
        var care = SummaryEntry(category: .carePlan, title: "Adjust your backpack")
        var unsupported = SummaryEntry(category: .findings, title: "Partial Exam")
        let id = UUID()
        symptom.sourceSessionID = id; care.sourceSessionID = id; unsupported.sourceSessionID = id
        symptom = supported(symptom, source: transcript); care = supported(care, source: transcript)
        unsupported = SummaryVerification.assess(unsupported, check: .init(id: unsupported.id, supported: false, reason: "An exam service is not a patient finding", citations: []), source: transcript)
        var session = Session(id: id, transcript: transcript, title: "Synthetic verification test", summaryEntries: [symptom,care,unsupported])
        session.extractionVersion = SummaryVerification.version
        try await store.upsert(session)
    }
}

extension SummaryVerificationTests {
    func testPrescriptionMirroredFieldsAndLineWrappingDoNotRejectSupportedFact() {
        let original = "Autologous PRP Serum Drops\nDose: One drop twice daily\n2026-09-18\nDr Example"
        var entry = SummaryEntry(category: .medications, title: "Autologous PRP Serum Drops", details: "One drop twice daily",
            fields: [.init(label: "Details", value: "One drop twice daily"), .init(label: "Dose", value: "One drop"), .init(label: "Practitioner", value: "Dr Example")])
        var evidence = ClinicalEvidence(); evidence.dose = "One drop"; evidence.practitioner = "Dr Example"; evidence.eventDate = "2026-09-18"
        entry.evidence = evidence
        let check = SummaryCheck(id: entry.id, supported: true, reason: "All required fields are supported by the source",
            citations: ["title", "details", "dose", "practitioner", "event_date"].map {
                .init(field: $0, excerpt: original.replacingOccurrences(of: "\n", with: " "))
            })
        let checked = SummaryVerification.assess(entry, check: check, source: original)
        XCTAssertTrue(SummaryVerification.isVisible(checked, source: original))
        XCTAssertEqual(checked.evidence?.assessment?.citations.first?.excerpt, original)
    }
    func testDifferentDoseFieldCannotBorrowEvidenceFromStructuredDose() {
        let source = "Drug: 5 mg"
        var entry = SummaryEntry(category: .medications, title: "Drug", fields: [.init(label: "Dose", value: "50 mg")])
        entry.evidence = ClinicalEvidence(); entry.evidence?.dose = "5 mg"
        let check = SummaryCheck(id: entry.id, supported: true, reason: "All fields are supported", citations: ["title", "dose"].map { .init(field: $0, excerpt: source) })
        let checked = SummaryVerification.assess(entry, check: check, source: source)
        XCTAssertFalse(SummaryVerification.isVisible(checked, source: source))
        XCTAssertTrue(checked.evidence!.assessment!.reason.contains("missing for: Dose"))
        XCTAssertNotEqual(checked.evidence?.assessment?.reason, check.reason)
    }
    func testWhitespaceToleranceDoesNotChangeNumbersNegationOrPunctuation() {
        XCTAssertNil(SummaryVerification.matchingCitation("Take 50 mg", source: "Take 5 mg"))
        XCTAssertNil(SummaryVerification.matchingCitation("No pain", source: "Pain"))
        XCTAssertNil(SummaryVerification.matchingCitation("Value +0.5", source: "Value -0.5"))
        XCTAssertEqual(SummaryVerification.matchingCitation("Take 5 mg", source: "Take\n5\tmg"), "Take\n5\tmg")
    }
    func testRecheckedSameAssertionReplacesInitialRejection() async throws {
        let entry = SummaryEntry(category: .symptoms, title: "Tingling")
        let result = try await SummaryReviewPipeline.run(draft: [entry]) { _, first in
            if first { return .init(assessed: [SummaryVerification.assess(entry, check: nil, source: self.source)], corrections: [entry]) }
            return .init(assessed: [self.supported(entry, source: self.source)], corrections: [])
        }
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(SummaryVerification.isVisible(result[0], source: source))
    }
    func testUnchangedRegenerationDoesNotSupersedeSuccessfullyMatchedFact() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let id = UUID()
        let original = supported(SummaryEntry(category: .symptoms, title: "Tingling", sourceSessionID: id), source: source)
        let session = Session(id: id, transcript: source, summaryEntries: [original])
        try await store.upsert(session)
        let run = try await store.beginSummaryRun(sessionID: id, expected: session)
        var regenerated = original; regenerated.id = UUID(); regenerated.updatedAt = Date().addingTimeInterval(10)
        regenerated = supported(regenerated, source: source)
        try await store.publishVerifiedSummary(expected: session, runID: run.id, entries: [regenerated])
        let snapshot = try await store.healthSnapshot()
        let facts = HealthMemoryProjection.facts(in: snapshot)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.latest.id, original.id)
        XCTAssertEqual(facts.first?.latest.updatedAt, original.updatedAt)
        XCTAssertEqual(facts.first?.latest.evidence?.assessment?.admission, .supported)
    }
}

extension SummaryVerificationTests {
    func testConflictingRepeatedFieldLabelsCannotShareApproval() {
        let original = "Drug: 5 mg"
        let entry = SummaryEntry(category: .medications, title: "Drug", fields: [.init(label: "Dose", value: "5 mg"), .init(label: "Dose", value: "50 mg")])
        let check = SummaryCheck(id: entry.id, supported: true, reason: "All supported", citations: ["title", "field:Dose"].map { .init(field: $0, excerpt: original) })
        let assessed = SummaryVerification.assess(entry, check: check, source: original)
        XCTAssertFalse(SummaryVerification.isVisible(assessed, source: original))
        XCTAssertTrue(assessed.evidence!.assessment!.reason.contains("conflicting values"))
    }
}

extension SummaryVerificationTests {
    func testSourceHistoryUsesCheckedCitationNotGeneratedDetails() {
        let original = "Patient says tingling happens while wearing a knapsack."
        let entry = SummaryEntry(category: .symptoms, title: "Tingling", details: "Triggered by backpack")
        XCTAssertNil(entry.supportingExcerpt)
        let accepted = supported(entry, source: original)
        XCTAssertEqual(accepted.supportingExcerpt, original)
    }
}

extension SummaryVerificationTests {
    func testPrescriptionCoreSurvivesUncertainPrintedOptionsOnlyAfterRechecking() async throws {
        let text = "Platelet Rich Plasma 20%\n4x / 6x / 8x per day for 1 month"
        var draft = SummaryEntry(category: .medications, title: "Platelet Rich Plasma", details: "Administered at 20% concentration.",
            fields: [.init(label: "Details", value: "Administered at 20% concentration."), .init(label: "Dose", value: "4x / 6x / 8x per day"), .init(label: "Frequency", value: "8x per day")])
        draft.evidence = ClinicalEvidence(); draft.evidence?.dose = "4x / 6x / 8x per day"; draft.evidence?.frequency = "8x per day"
        let check = SummaryCheck(id: draft.id, supported: false, reason: "Selected schedule and administration are not established",
            citations: [.init(field: "title", excerpt: "Platelet Rich Plasma")], coreSupported: true,
            uncertainFields: ["details", "field:Dose", "frequency"])
        let core = try XCTUnwrap(SummaryVerification.supportedCoreForRechecking(draft, check: check, source: text))
        XCTAssertEqual(core.title, "Platelet Rich Plasma")
        XCTAssertEqual(core.details, "")
        XCTAssertTrue(core.fields.isEmpty)
        XCTAssertNil(core.evidence?.dose); XCTAssertNil(core.evidence?.frequency)
        XCTAssertFalse(SummaryVerification.isVisible(core, source: text))
        var calls = 0
        let output = try await SummaryReviewPipeline.run(draft: [draft]) { entries, first in
            calls += 1
            if first { return .init(assessed: [SummaryVerification.assess(draft, check: check, source: text)], corrections: [core]) }
            return .init(assessed: entries.map { self.supported($0, source: text) }, corrections: [])
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(SummaryVerification.isVisible(output[0], source: text))
        XCTAssertFalse(output[0].evidence!.omittedFields!.isEmpty)
    }
    func testSupportedContactDoesNotRequireOptionalAddressDateOrRole() throws {
        let text = "Dr Example\nExample Clinic\nPhone: 403 555 0100"
        var entry = SummaryEntry(category: .practitionerContact, title: "Dr Example",
            fields: [.init(label: "Name", value: "Dr Example"), .init(label: "Phone", value: "403 555 0100"), .init(label: "Address", value: "Unreadable postcode")])
        entry.evidence = ClinicalEvidence()
        let check = SummaryCheck(id: entry.id, supported: false, reason: "Address uncertain", citations: [
            .init(field: "title", excerpt: "Dr Example"), .init(field: "field:Phone", excerpt: "403 555 0100")], coreSupported: true, uncertainFields: ["field:Address"])
        let core = try XCTUnwrap(SummaryVerification.supportedCoreForRechecking(entry, check: check, source: text))
        XCTAssertEqual(core.fields.map(\.label), ["Name", "Phone"])
        XCTAssertNil(core.evidence?.eventDate)
        XCTAssertTrue(SummaryVerification.isVisible(supported(core, source: text), source: text))
    }
    func testCoreReductionRequiresExplicitIdentityApprovalAndNeverDropsClinicalQualifiersForSymptoms() {
        let source = "Possible left-sided pain"
        let symptom = SummaryEntry(category: .symptoms, title: "Pain", details: "Possible left-sided pain")
        let check = SummaryCheck(id: symptom.id, supported: false, reason: "", citations: [.init(field: "title", excerpt: "pain")], coreSupported: true)
        XCTAssertNil(SummaryVerification.supportedCoreForRechecking(symptom, check: check, source: source))
        let medication = SummaryEntry(category: .medications, title: "Drug", details: "Incorrect")
        let incomplete = SummaryCheck(id: medication.id, supported: false, reason: "Missing citations", citations: [.init(field: "title", excerpt: "Drug")])
        XCTAssertNil(SummaryVerification.supportedCoreForRechecking(medication, check: incomplete, source: "Drug"))
    }
}


extension SummaryVerificationTests {
    func testApprovalCannotOverrideExplicitFieldUncertainty() {
        let source = "Drug 5 mg"
        let entry = SummaryEntry(category: .medications, title: "Drug", fields: [.init(label: "Dose", value: "5 mg")])
        let check = SummaryCheck(id: entry.id, supported: true, reason: "Supported", citations: ["title", "field:Dose"].map { .init(field: $0, excerpt: source) }, coreSupported: true, uncertainFields: ["dose"])
        let assessed = SummaryVerification.assess(entry, check: check, source: source)
        XCTAssertFalse(SummaryVerification.isVisible(assessed, source: source))
        XCTAssertTrue(assessed.evidence!.assessment!.reason.contains("uncertain fields"))
    }
}
