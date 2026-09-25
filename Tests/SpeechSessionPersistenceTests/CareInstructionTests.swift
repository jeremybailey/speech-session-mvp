import XCTest
@testable import SpeechSessionPersistence

final class CareInstructionTests: XCTestCase {
    private func pair() -> (Session, SummaryEntry, SummaryEntry) {
        let id = UUID()
        var a = SummaryEntry(category: .carePlan, title: "Adjust knapsack to reduce pressure on spine", sourceSessionID: id)
        var b = SummaryEntry(category: .carePlan, title: "Backpack Adjustment", details: "Adjust the backpack to reduce pressure on the spine.", sourceSessionID: id)
        var evidence = ClinicalEvidence()
        evidence.excerpt = "Adjust the backpack to reduce pressure on the spine."
        evidence.practitioner = "Sample RMT"; evidence.eventDate = "2026-09-01"
        a.evidence = evidence; b.evidence = evidence
        return (Session(id: id, transcript: evidence.excerpt!, summaryEntries: [a,b]), a,b)
    }
    func testScreenshotDuplicateAndRedundantDescription() {
        let (_,a,b) = pair()
        XCTAssertTrue(CareInstructionPresentation.equivalent(a,b))
        XCTAssertEqual(CareInstructionPresentation.instruction(b), b.details)
        XCTAssertEqual(CareInstructionPresentation.supportingText(b), [])
    }
    func testDifferencesAreNotMerged() {
        let (_,a,original) = pair()
        for suffix in [" daily", " weekly", " only if comfortable", " on the left side", " not on the right side", " for 10 minutes"] {
            var b = original; b.details += suffix
            XCTAssertFalse(CareInstructionPresentation.equivalent(a,b))
        }
        var b = original; b.sourceSessionID = UUID()
        XCTAssertFalse(CareInstructionPresentation.equivalent(a,b))
        b = original; b.evidence?.practitioner = "Other RMT"
        XCTAssertFalse(CareInstructionPresentation.equivalent(a,b))
        b = original; b.evidence?.excerpt = nil
        XCTAssertFalse(CareInstructionPresentation.equivalent(a,b))
    }
    func testHeadingQualifiersCannotBeDiscardedByCombination() {
        let (_,a,original) = pair()
        for title in ["Left backpack adjustment", "Backpack adjustment daily", "Backpack adjustment 10 minutes"] {
            var b = original; b.title = title
            XCTAssertFalse(CareInstructionPresentation.equivalent(a,b))
        }
    }
    func testAutomaticLinkIsPersistedAndKeepsSources() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let (session,_,_) = pair(); try await store.upsert(session)
        try await store.consolidateCareInstructions()
        let reopened = try SessionStore(storageDirectory: dir)
        let snapshot = try await reopened.healthSnapshot()
        let facts = HealthMemoryProjection.facts(in: snapshot, verifiedOnly: false)
        XCTAssertEqual(facts.count,1); XCTAssertEqual(facts[0].occurrences.count,2)
        XCTAssertEqual(snapshot.sessions[0].transcript,session.transcript)
        XCTAssertEqual(snapshot.sessions[0].summaryEntries?.count,2)
        let identity = facts[0].id
        try await reopened.consolidateCareInstructions()
        let again = try await reopened.healthSnapshot()
        XCTAssertEqual(HealthMemoryProjection.facts(in: again, verifiedOnly: false)[0].id,identity)
    }
    func testSavedPreferencesSurviveAutomaticCombination() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let (session,a,_) = pair(); try await store.upsert(session)
        var pref = HealthFactPreference(id: HealthMemoryProjection.key(for:a))
        pref.actionStatus = .completed; pref.reminderEnabled = true; pref.dueDate = Date()
        try await store.savePreference(pref); try await store.consolidateCareInstructions()
        let snapshot = try await store.healthSnapshot()
        XCTAssertEqual(HealthMemoryProjection.facts(in:snapshot, verifiedOnly: false).count,1)
        XCTAssertEqual(snapshot.preferences,[pref])
    }
    func testManualCombineUndoAndSettingsSurvive() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let (session,a,b) = pair(); try await store.upsert(session)
        let root = HealthMemoryProjection.key(for:a), other = HealthMemoryProjection.key(for:b)
        var pref = HealthFactPreference(id:root); pref.actionStatus = .completed
        try await store.savePreference(pref)
        let undo = try await store.combineCareInstructions(keeping:root, duplicateID:other)
        var snapshot = try await store.healthSnapshot()
        var facts = HealthMemoryProjection.facts(in:snapshot, verifiedOnly: false)
        XCTAssertEqual(facts.count,1); XCTAssertEqual(facts[0].latest.id,a.id)
        XCTAssertEqual(facts[0].preference.actionStatus,.completed)
        try await store.undoCareCombination(undo)
        try await store.consolidateCareInstructions()
        snapshot = try await store.healthSnapshot(); facts = HealthMemoryProjection.facts(in:snapshot, verifiedOnly: false)
        XCTAssertEqual(facts.count,2); XCTAssertEqual(snapshot.preferences,[pref])
    }
    func testConflictingDuplicatePreferencesAreRejected() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let (session,a,b) = pair(); try await store.upsert(session)
        var pref = HealthFactPreference(id:HealthMemoryProjection.key(for:b)); pref.actionStatus = .completed
        try await store.savePreference(pref)
        do {
            _ = try await store.combineCareInstructions(keeping:HealthMemoryProjection.key(for:a),duplicateID:pref.id)
            XCTFail("Conflicting settings must not be lost")
        } catch { }
        let snapshot = try await store.healthSnapshot()
        XCTAssertEqual(snapshot.preferences,[pref])
        XCTAssertEqual(HealthMemoryProjection.facts(in:snapshot, verifiedOnly: false).count,2)
    }
    func testCompletionStatusIsNotReportedAsUnknown() {
        let (session,a,_) = pair()
        var pref = HealthFactPreference(id:HealthMemoryProjection.key(for:a)); pref.actionStatus = .completed
        let facts = HealthMemoryProjection.facts(in:.init(sessions:[session],preferences:[pref]), verifiedOnly: false)
        XCTAssertEqual(CareInstructionPresentation.status(facts.first { $0.id == pref.id }!),"Completed")
    }
    func testReextractionPreservesLinkedHistoryAndIdentity() {
        let (_,a,b) = pair()
        var linkedA = a, linkedB = b
        let key = HealthMemoryProjection.key(for:a)
        linkedA.evidence?.instructionIdentity = key; linkedB.evidence?.instructionIdentity = key
        let result = SummaryEntryMerge.merging(generated:[a],existing:[linkedA,linkedB])
        XCTAssertEqual(result.count,2)
        XCTAssertTrue(result.allSatisfy { $0.evidence?.instructionIdentity == key })
    }
    func testOptionalCareFieldsAndReviewHaveNoInventedAdvice() {
        let (_,a,_) = pair()
        let fact = HealthMemoryProjection.facts(in:.init(sessions:[Session(transcript: "Synthetic", summaryEntries:[a])]), verifiedOnly: false)[0]
        XCTAssertEqual(CareInstructionPresentation.status(fact), "Current")
        XCTAssertNotEqual(CareInstructionPresentation.reviewIndicator(fact), "Confirm whether still current")
        XCTAssertEqual(CareInstructionPresentation.supportingText(a),[])
        var recurring = a; recurring.evidence?.careInstruction = CareInstruction(instruction:a.title,schedule:"Daily",isRecurring:true)
        XCTAssertTrue(CareInstructionPresentation.recurring(recurring))
        XCTAssertEqual(CareInstructionPresentation.supportingText(recurring),["When: Daily"])
    }
}

extension CareInstructionTests {
    func testCheckedPelvisInstructionsMergeDespiteDifferentExcerptsAndKeepPatientState() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let id = UUID()
        let source = "Find a neutral position of the pelvis while sitting. While seated, find that neutral pelvic position."
        func checked(_ excerpt: String) -> SummaryEntry {
            var e = SummaryEntry(category: .carePlan, title: "Find a neutral position of the pelvis while sitting", sourceSessionID: id)
            e.evidence = ClinicalEvidence(); e.evidence?.excerpt = excerpt; e.evidence?.actionKind = "homecare"
            let check = SummaryCheck(id: e.id, supported: true, reason: "Supported", citations: SummaryVerification.requiredFields(e).map { .init(field: $0, excerpt: excerpt) })
            return SummaryVerification.assess(e, check: check, source: source)
        }
        let a = checked("Find a neutral position of the pelvis while sitting.")
        let b = checked("While seated, find that neutral pelvic position.")
        try await store.upsert(Session(id: id, transcript: source, summaryEntries: [a,b]))
        let key = HealthMemoryProjection.key(for: a)
        var preference = HealthFactPreference(id: key); preference.actionStatus = .past
        preference.reviewedRevision = HealthMemoryProjection.facts(in: .init(sessions: [.init(id: id, transcript: source, summaryEntries: [a])])).first?.revision
        try await store.savePreference(preference)
        try await store.consolidateCareInstructions()
        let snapshot = try await store.healthSnapshot()
        let facts = HealthMemoryProjection.facts(in: snapshot)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.id, key)
        XCTAssertEqual(facts.first?.occurrences.count, 2)
        XCTAssertEqual(facts.first?.actionStatus, .past)
        XCTAssertEqual(facts.first?.isReviewed, false)
        XCTAssertEqual(Set(facts[0].occurrences.compactMap(\.supportingExcerpt)).count, 2)
        let before = try Data(contentsOf: dir.appendingPathComponent("sessions.json"))
        try await store.consolidateCareInstructions()
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("sessions.json")), before)
        let reopened = try SessionStore(storageDirectory: dir)
        let reloaded = try await reopened.healthSnapshot()
        XCTAssertEqual(HealthMemoryProjection.facts(in: reloaded).count, 1)
    }

    func testCareMatchingRetainsClinicalAndEvidenceSafeguards() {
        let (_, a, original) = pair()
        var b = original; b.evidence?.excerpt = "A different source passage"
        XCTAssertFalse(CareInstructionPresentation.equivalent(a,b))
        XCTAssertTrue(CareInstructionPresentation.equivalent(a,b, allowDifferentEvidence: true))
        b.evidence?.practitioner = "Different practitioner"
        XCTAssertFalse(CareInstructionPresentation.equivalent(a,b, allowDifferentEvidence: true))
        b = original; b.evidence?.frequency = "hourly"
        XCTAssertFalse(CareInstructionPresentation.equivalent(a,b, allowDifferentEvidence: true))
        b = original; b.evidence?.actionKind = "treatment_received"
        XCTAssertFalse(CareInstructionPresentation.equivalent(a,b, allowDifferentEvidence: true))
        b = original; b.evidence?.combinationExcluded = true
        XCTAssertFalse(CareInstructionPresentation.equivalent(a,b, allowDifferentEvidence: true))
        var x = a; x.title = "Take 0.5 mg"
        var y = a; y.title = "Take 0 5 mg"
        XCTAssertFalse(CareInstructionPresentation.equivalent(x,y, allowDifferentEvidence: true))
    }

    func testConflictingPatientStatusesPreventAutomaticCareMerge() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SessionStore(storageDirectory: dir)
        let (session,a,b) = pair(); try await store.upsert(session)
        var current = HealthFactPreference(id: HealthMemoryProjection.key(for: a)); current.actionStatus = .current
        var past = HealthFactPreference(id: HealthMemoryProjection.key(for: b)); past.actionStatus = .past
        try await store.savePreference(current); try await store.savePreference(past)
        try await store.consolidateCareInstructions()
        let snapshot = try await store.healthSnapshot()
        XCTAssertEqual(HealthMemoryProjection.facts(in: snapshot, verifiedOnly: false).count, 2)
        XCTAssertEqual(Set(snapshot.preferences.map(\.id)), [current.id, past.id])
    }
}
