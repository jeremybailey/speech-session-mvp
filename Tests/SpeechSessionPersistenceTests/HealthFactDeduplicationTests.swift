import XCTest
@testable import SpeechSessionPersistence

final class HealthFactDeduplicationTests: XCTestCase {
    private func entry(_ title: String, category: SummaryEntryCategory = .symptoms, source: UUID = UUID(), details: String = "") -> SummaryEntry {
        var value = SummaryEntry(category: category, title: title, details: details, sourceSessionID: source, factKey: "deliberately-unreliable-model-key")
        var evidence = ClinicalEvidence(); evidence.excerpt = title; evidence.eventDate = "2026-09-01"
        value.evidence = evidence
        return value
    }
    private func snapshot(_ values: [SummaryEntry]) -> HealthMemorySnapshot {
        .init(sessions: Dictionary(grouping: values, by: { $0.sourceSessionID! }).map { Session(id: $0.key, transcript: "Original", summaryEntries: $0.value) })
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testSymptomAliasesAcrossVisitsKeepOccurrencesAndDates() throws {
        let a = entry("Pain in the lower back")
        var b = entry("Low back pain"); b.evidence?.eventDate = "2026-09-10"
        XCTAssertTrue(HealthFactMatching.equivalent(a,b))
        let facts = HealthMemoryProjection.facts(in: snapshot([a,b]), verifiedOnly: false)
        XCTAssertEqual(facts.count,1)
        XCTAssertEqual(facts[0].occurrences.count,2)
        XCTAssertEqual(Set(facts[0].occurrences.compactMap { $0.evidence?.eventDate }).count,2)
        XCTAssertEqual(facts[0].presentedFromRecord(a.sourceSessionID!)?.latest.id,a.id)
    }

    func testGeneratedKeysDoNotCollapseClinicalDifferences() {
        let pairs = [("Headache","Migraine"),("Left knee pain","Right knee pain"),("Chest pain","No chest pain"),("Headache","Headache when standing")]
        for (left,right) in pairs {
            let a = entry(left), b = entry(right)
            XCTAssertFalse(HealthFactMatching.equivalent(a,b))
            XCTAssertEqual(HealthMemoryProjection.facts(in:snapshot([a,b]), verifiedOnly: false).count,2)
        }
        for category in SummaryEntryCategory.allCases where ![.carePlan,.followUp,.practitionerContact].contains(category) {
            let a = entry("Example",category:category,details:"Value 0.5 mg")
            let b = entry("Example",category:category,details:"Value 5 mg")
            XCTAssertEqual(HealthMemoryProjection.facts(in:snapshot([a,b]), verifiedOnly: false).count,2,category.rawValue)
        }
    }

    func testExactDuplicatesAcrossNonCareCategoriesAndEventBoundaries() {
        for category in SummaryEntryCategory.allCases where ![.carePlan,.followUp,.practitionerContact].contains(category) {
            let a = entry("Example",category:category)
            var b = a; b.id = UUID()
            XCTAssertTrue(HealthFactMatching.equivalent(a,b),category.rawValue)
            XCTAssertEqual(HealthMemoryProjection.facts(in:snapshot([a,b]), verifiedOnly: false).count,1)
        }
        for category: SummaryEntryCategory in [.testsAndLabs,.vaccinations,.findings] {
            let a = entry("Example",category:category)
            var b = a; b.id = UUID(); b.evidence?.eventDate = "2026-09-02"
            XCTAssertFalse(HealthFactMatching.equivalent(a,b))
            b.evidence?.eventDate = nil
            var c = a; c.evidence?.eventDate = nil
            b.sourceSessionID = UUID()
            XCTAssertFalse(HealthFactMatching.equivalent(b,c))
        }
    }

    func testContactNamesAloneAreInsufficient() {
        let a = entry("Dr Example",category:.practitionerContact)
        var b = a; b.id = UUID()
        XCTAssertFalse(HealthFactMatching.equivalent(a,b))
        XCTAssertEqual(HealthMemoryProjection.facts(in:snapshot([a,b]), verifiedOnly: false).count,2)
    }

    func testLegacyPreferencesArePreservedAndConflictsPreventCombination() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let store = try SessionStore(storageDirectory:dir)
        var a = entry("Headache"), b = entry("Headaches")
        a.evidence?.factIdentity = "legacy-a"; b.evidence?.factIdentity = "legacy-b"
        for session in snapshot([a,b]).sessions { try await store.upsert(session) }
        var pref = HealthFactPreference(id:"legacy-a"); pref.clinicalStatus = .past
        var other = HealthFactPreference(id:"legacy-b"); other.clinicalStatus = .current
        try await store.savePreference(pref); try await store.savePreference(other)
        try await store.consolidateHealthFacts()
        var saved = try await store.healthSnapshot()
        XCTAssertEqual(HealthMemoryProjection.facts(in:saved, verifiedOnly: false).count,2)
        other.clinicalStatus = .past; try await store.savePreference(other)
        try await store.consolidateHealthFacts()
        saved = try await store.healthSnapshot()
        let fact = try XCTUnwrap(HealthMemoryProjection.facts(in:saved, verifiedOnly: false).first)
        XCTAssertEqual(HealthMemoryProjection.facts(in:saved, verifiedOnly: false).count,1)
        XCTAssertFalse(fact.isCurrent)
        let file = dir.appendingPathComponent(SessionStore.sessionsFileName)
        let before = try Data(contentsOf:file)
        try await store.consolidateHealthFacts()
        XCTAssertEqual(try Data(contentsOf:file),before)
        let reopened = try SessionStore(storageDirectory:dir)
        let reloaded = try await reopened.healthSnapshot()
        XCTAssertEqual(HealthMemoryProjection.facts(in:reloaded, verifiedOnly: false).first?.occurrences.count,2)
    }

    func testManualCombinationUndoRegenerationAndVerification() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let store = try SessionStore(storageDirectory:dir)
        let a = entry("Headache after work"), b = entry("Evening headache")
        for session in snapshot([a,b]).sessions { try await store.upsert(session) }
        let initial = HealthMemoryProjection.facts(in:snapshot([a,b]), verifiedOnly: false)
        let root = initial.first { $0.latest.id == a.id }!
        var pref = root.preference; pref.reviewedRevision = root.revision; pref.clinicalStatus = .past
        try await store.savePreference(pref)
        let undo = try await store.combineHealthFacts(keeping:root.id, duplicateID:HealthMemoryProjection.key(for:b))
        var saved = try await store.healthSnapshot()
        var facts = HealthMemoryProjection.facts(in:saved, verifiedOnly: false)
        XCTAssertEqual(facts.count,1); XCTAssertEqual(facts[0].latest.id,a.id)
        XCTAssertFalse(facts[0].isReviewed); XCTAssertFalse(facts[0].isCurrent)
        try await store.undoHealthCombination(undo)
        try await store.consolidateHealthFacts()
        saved = try await store.healthSnapshot(); facts = HealthMemoryProjection.facts(in:saved, verifiedOnly: false)
        XCTAssertEqual(facts.count,2)
        var fresh = a; fresh.id = UUID()
        try await store.applyExtraction(sessionID:a.sourceSessionID!,transcript:"Original",title:"Record",summary:"Record",entries:[fresh],version:6)
        try await store.consolidateHealthFacts()
        saved = try await store.healthSnapshot()
        XCTAssertEqual(HealthMemoryProjection.facts(in:saved, verifiedOnly: false).count,2)
        XCTAssertTrue(saved.sessions.flatMap { $0.summaryEntries ?? [] }.contains { $0.evidence?.combinationExcluded == true })
    }

    func testHiddenDuplicateDoesNotReturnAndNewEvidenceInvalidatesVerification() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let store = try SessionStore(storageDirectory:dir)
        var a = entry("Headache"); a.evidence?.factIdentity = "old-headache"
        for s in snapshot([a]).sessions { try await store.upsert(s) }
        var pref = HealthFactPreference(id:"old-headache"); pref.hidden = true
        try await store.savePreference(pref)
        let b = entry("Headaches")
        for s in snapshot([b]).sessions { try await store.upsert(s) }
        try await store.consolidateHealthFacts()
        let saved = try await store.healthSnapshot()
        XCTAssertTrue(HealthMemoryProjection.facts(in:saved, verifiedOnly: false).isEmpty)
        XCTAssertEqual(saved.sessions.flatMap { $0.summaryEntries ?? [] }.count,2)
    }

    func testSavedContactsCombineWithoutLosingSourcesAndUndoSticks() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let store = try SessionStore(storageDirectory:dir)
        let a = CareTeamMember(name:"Dr Example", email:"a@example.test", sourceEntryIDs:[UUID()])
        let b = CareTeamMember(name:"Doctor Example", phone:"5550100", sourceEntryIDs:[UUID()])
        try await store.saveCareTeamMember(a); try await store.saveCareTeamMember(b)
        let undo = try await store.combineCareTeamMembers(keeping:a.id,duplicateID:b.id)
        var saved = try await store.healthSnapshot()
        XCTAssertEqual(saved.careTeam.count,1)
        XCTAssertEqual(saved.careTeam[0].sourceEntryIDs.count,2)
        XCTAssertEqual(saved.careTeam[0].phone,b.phone)
        try await store.undoHealthCombination(undo)
        try await store.consolidateHealthFacts()
        saved = try await store.healthSnapshot()
        XCTAssertEqual(saved.careTeam.count,2)
    }
    func testReprocessingDoesNotSwapDoseIdentitiesOrTheirPreferences() {
        var low = entry("Medicine",category:.medications,details:"5 mg")
        low.evidence?.factIdentity = "low-dose"
        var high = entry("Medicine",category:.medications,source:low.sourceSessionID!,details:"10 mg")
        high.evidence?.factIdentity = "high-dose"
        var newHigh = high; newHigh.id = UUID(); newHigh.evidence?.factIdentity = nil
        var newLow = low; newLow.id = UUID(); newLow.evidence?.factIdentity = nil
        let merged = SummaryEntryMerge.merging(generated:[newHigh,newLow],existing:[low,high])
        XCTAssertEqual(merged.first { $0.details == "5 mg" }?.evidence?.factIdentity,"low-dose")
        XCTAssertEqual(merged.first { $0.details == "10 mg" }?.evidence?.factIdentity,"high-dose")
    }

    func testUnitsNegationAndSignsRemainDistinct() {
        for (a,b) in [("5%","5"),("0.5 mg","5 mg"),("<5","5"),("-5","5"),("Left knee pain","Knee pain")] {
            XCTAssertNotEqual(HealthFactMatching.canonical(a),HealthFactMatching.canonical(b))
        }
    }

    func testConsolidatedGroupIdentitySurvivesEditingOneRecord() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let store = try SessionStore(storageDirectory:dir)
        let a = entry("Headache"), b = entry("Headaches")
        for s in snapshot([a,b]).sessions { try await store.upsert(s) }
        try await store.consolidateHealthFacts()
        let saved = try await store.healthSnapshot()
        let fact = try XCTUnwrap(HealthMemoryProjection.facts(in:saved, verifiedOnly: false).first)
        var edited = try XCTUnwrap(fact.presentedFromRecord(a.sourceSessionID!)?.latest)
        edited.details = "My own wording"; edited.origin = .userEdited
        try await store.saveSummaryEntry(edited)
        try await store.consolidateHealthFacts()
        let after = try await store.healthSnapshot()
        let updated = try XCTUnwrap(HealthMemoryProjection.facts(in:after, verifiedOnly: false).first)
        XCTAssertEqual(updated.id,fact.id)
        XCTAssertEqual(updated.presentedFromRecord(a.sourceSessionID!)?.latest.details,"My own wording")
        XCTAssertEqual(updated.presentedFromRecord(b.sourceSessionID!)?.latest.details,"")
    }

    func testSameNameContactsAndConflictingAliasInformationStaySeparate() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at:dir) }
        let store = try SessionStore(storageDirectory:dir)
        for phone in ["", "111", "222"] {
            try await store.saveCareTeamMember(.init(name:"Dr Example",email:"a@example.test",phone:phone))
        }
        try await store.consolidateHealthFacts()
        let saved = try await store.healthSnapshot()
        XCTAssertEqual(saved.careTeam.count,2)
        XCTAssertEqual(Set(saved.careTeam.map(\.phone)),["111","222"])
    }

}
