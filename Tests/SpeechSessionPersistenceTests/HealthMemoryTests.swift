import XCTest
@testable import SpeechSessionPersistence

final class HealthMemoryTests: XCTestCase {
    private func occurrence(_ title: String = "Migraine", category: SummaryEntryCategory = .symptoms,
                            date: String = "2026-07-01", status: SummaryEntryClinicalStatus = .current) -> SummaryEntry {
        var entry = SummaryEntry(category: category, title: title, relevantDate: EvidenceValidation.exactDate(date),
                                 sourceSessionID: UUID(), clinicalStatus: status, factKey: title)
        var evidence = ClinicalEvidence()
        evidence.eventDate = date; evidence.statusExplicit = true; evidence.excerpt = "Source supports \(title)"
        entry.evidence = evidence
        return entry
    }
    private func snapshot(_ entries: [SummaryEntry], topics: [HealthTopic] = [], preferences: [HealthFactPreference] = []) -> HealthMemorySnapshot {
        .init(sessions: entries.map { Session(id: $0.sourceSessionID!, transcript: "Source", summaryEntries: [$0]) }, topics: topics, preferences: preferences)
    }

    func testStoryGroupsShareIdentityAndKeepUnattributedDetailsGeneral() {
        var shared = occurrence("Poor sleep")
        shared.evidence?.topicNames = ["Migraine", "Back ache"]
        let general = occurrence("Diet history", category: .otherNotes)
        let facts = HealthMemoryProjection.facts(in: snapshot([shared, general]), verifiedOnly: false)
        let groups = HealthStoryPresentation.groups(facts: facts, topics: [])
        XCTAssertEqual(groups.map(\.name), ["Back ache", "Migraine", "General health"])
        XCTAssertEqual(groups[0].facts[0].id, groups[1].facts[0].id)
        XCTAssertNotNil(groups[0].overview)
        XCTAssertEqual(groups[2].facts[0].title, "Diet history")
    }

    func testExplicitGeneralOverridesExtractedRelationship() {
        var entry = occurrence(); entry.evidence?.topicNames = ["Migraine"]
        var preference = HealthFactPreference(id: HealthMemoryProjection.key(for: entry))
        preference.topicIDs = []
        let facts = HealthMemoryProjection.facts(in: snapshot([entry], preferences: [preference]), verifiedOnly: false)
        XCTAssertEqual(HealthStoryPresentation.groups(facts: facts, topics: []).map(\.name), ["General health"])
    }

    func testStoryFallsBackToChiefComplaintAndExplicitBodyArea() {
        let chief = occurrence("Back ache", category: .chiefComplaint)
        var symptom = occurrence("Stiffness"); symptom.evidence?.bodySystem = "Musculoskeletal"
        let facts = HealthMemoryProjection.facts(in: snapshot([chief, symptom]), verifiedOnly: false)
        XCTAssertEqual(HealthStoryPresentation.groups(facts: facts, topics: []).map(\.name), ["Back ache", "Musculoskeletal"])
    }

    func testLegacyCareTextHidesSchemaButPreservesInstructions() {
        XCTAssertEqual(HealthStoryText.clean("actionKind: homecare\ndetails: Keep a headache diary\nfrequency: daily"), "Keep a headache diary\nfrequency: daily")
        XCTAssertEqual(HealthStoryText.clean("Call clinic at 9:00"), "Call clinic at 9:00")
        XCTAssertEqual(HealthStoryText.clean("{\"actionKind\":\"homecare\",\"details\":\"Keep a diary\"}"), "Keep a diary")
    }

    func testSavedContactWithoutAddressStillDecodes() throws {
        let member = CareTeamMember(name: "Sample Provider", phone: "555-0100")
        let encoded = try JSONEncoder().encode(member)
        let decoded = try JSONDecoder().decode(CareTeamMember.self, from: encoded)
        XCTAssertNil(decoded.address)
        var withAddress = decoded; withAddress.address = "123 Sample Street\nToronto, ON"
        XCTAssertEqual(try JSONDecoder().decode(CareTeamMember.self, from: JSONEncoder().encode(withAddress)).address, withAddress.address)
    }

    func testSharedFactIsStoredOnceAndAppearsInBothTopics() {
        let migraine = HealthTopic(name: "Migraine")
        let fatigue = HealthTopic(name: "Fatigue")
        var entry = occurrence("Sleep diary", category: .carePlan)
        entry.evidence?.topicNames = ["Migraine", "Fatigue"]
        let facts = HealthMemoryProjection.facts(in: snapshot([entry], topics: [migraine, fatigue]), verifiedOnly: false)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(Set(facts[0].topicIDs), Set([migraine.id, fatigue.id]))
    }

    func testUnlinkingOneTopicPreservesOtherTopicAndOriginal() {
        let a = HealthTopic(name: "Migraine"), b = HealthTopic(name: "Fatigue")
        var entry = occurrence(); entry.evidence?.topicNames = [a.name, b.name]
        var preference = HealthFactPreference(id: HealthMemoryProjection.key(for: entry))
        preference.topicIDs = [b.id]
        let facts = HealthMemoryProjection.facts(in: snapshot([entry], topics: [a, b], preferences: [preference]), verifiedOnly: false)
        XCTAssertEqual(facts[0].topicIDs, [b.id])
        XCTAssertEqual(facts[0].occurrences[0], entry)
    }

    func testNewestExplicitStatusWinsOverHistoricalCurrentMention() {
        let earlier = occurrence(date: "2026-01-01")
        let later = occurrence(date: "2026-07-01", status: .past)
        let facts = HealthMemoryProjection.facts(in: snapshot([earlier, later]), verifiedOnly: false)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].clinicalStatus, .past)
        XCTAssertEqual(facts[0].occurrences.count, 2)
    }

    func testPatientStatusOverrideDoesNotRewriteHistory() {
        let entry = occurrence()
        var preference = HealthFactPreference(id: HealthMemoryProjection.key(for: entry))
        preference.clinicalStatus = .past
        let fact = HealthMemoryProjection.facts(in: snapshot([entry], preferences: [preference]), verifiedOnly: false)[0]
        XCTAssertEqual(fact.clinicalStatus, .past)
        XCTAssertEqual(fact.latest.clinicalStatus, .current)
    }

    func testSimilarRecommendationsFromDifferentSourcesStaySeparate() {
        let a = occurrence("Stretch daily", category: .carePlan)
        let b = occurrence("Stretch daily", category: .carePlan)
        XCTAssertEqual(HealthMemoryProjection.facts(in: snapshot([a, b]), verifiedOnly: false).count, 2)
    }

    func testUnknownRelationshipStaysInGeneralHealth() {
        let facts = HealthMemoryProjection.facts(in: snapshot([occurrence()], topics: [HealthTopic(name: "Migraine")]), verifiedOnly: false)
        XCTAssertTrue(facts[0].topicIDs.isEmpty)
    }

    func testCompletedActionDisappearsFromNextStepsWithoutChangingCondition() {
        var entry = occurrence("Keep a diary", category: .carePlan)
        entry.evidence?.actionKind = "homecare"
        var preference = HealthFactPreference(id: HealthMemoryProjection.key(for: entry))
        preference.actionStatus = .completed
        let fact = HealthMemoryProjection.facts(in: snapshot([entry], preferences: [preference]), verifiedOnly: false)[0]
        XCTAssertFalse(fact.canShowAsNextStep)
        XCTAssertEqual(fact.clinicalStatus, .current)
    }

    func testTreatmentReceivedIsNeverANextStep() {
        var entry = occurrence("Manual therapy", category: .carePlan)
        entry.evidence?.actionKind = "treatment_received"
        let fact = HealthMemoryProjection.facts(in: snapshot([entry]), verifiedOnly: false)[0]
        XCTAssertFalse(fact.isAction)
        XCTAssertFalse(fact.canShowAsNextStep)
    }

    func testReviewDoesNotSurviveChangedSourceOccurrence() {
        var entry = occurrence()
        entry.evidence?.statusExplicit = false
        let original = HealthMemoryProjection.facts(in: snapshot([entry]), verifiedOnly: false)[0]
        var preference = original.preference
        preference.reviewedRevision = original.revision
        XCTAssertTrue(HealthMemoryProjection.facts(in: snapshot([entry], preferences: [preference]), verifiedOnly: false)[0].isReviewed)
        entry.updatedAt = entry.updatedAt.addingTimeInterval(10)
        XCTAssertFalse(HealthMemoryProjection.facts(in: snapshot([entry], preferences: [preference]), verifiedOnly: false)[0].isReviewed)
    }

    func testUnspecifiedCareStatusDefaultsCurrentWithoutInventingClassification() {
        var entry = occurrence("Keep a diary", category: .carePlan)
        entry.evidence?.statusExplicit = false
        entry.evidence?.actionKind = "homecare"
        entry.origin = .userEdited // A corrected title is not a status confirmation.
        let fact = HealthMemoryProjection.facts(in: snapshot([entry]), verifiedOnly: false)[0]
        var preference = fact.preference
        preference.reviewedRevision = fact.revision
        let reviewed = HealthMemoryProjection.facts(in: snapshot([entry], preferences: [preference]), verifiedOnly: false)[0]
        XCTAssertEqual(reviewed.statusTitle, "Current")
        XCTAssertTrue(reviewed.canShowAsNextStep)
    }

    func testLegacyImportCannotOverwriteAnExistingCorrection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let entry = occurrence()
        let id = entry.sourceSessionID!
        try await store.upsert(Session(id: id, transcript: "Original", summary: "Old markdown"))
        try await store.importLegacySummary(sessionID: id, expectedSummary: "Old markdown", entries: [entry])
        var corrected = entry; corrected.details = "Patient correction"; corrected.origin = .userEdited
        try await store.saveSummaryEntry(corrected)
        try await store.importLegacySummary(sessionID: id, expectedSummary: "Old markdown", entries: [entry])
        let saved = try await store.loadAll()
        XCTAssertEqual(saved[0].summaryEntries?.first?.details, "Patient correction")
        XCTAssertEqual(saved[0].transcript, "Original")
    }

    func testEvidenceMustActuallyOccurInSource() {
        XCTAssertNil(EvidenceValidation.matchingExcerpt("Cold hands", in: "We discussed headaches."))
        XCTAssertEqual(EvidenceValidation.matchingExcerpt("No cold hands", in: "No cold hands were reported."), "No cold hands")
        XCTAssertNil(EvidenceValidation.matchingExcerpt("", in: "Some source"))
    }

    func testPartialAndInvalidDatesAreNotInvented() {
        XCTAssertNil(EvidenceValidation.exactDate("2024"))
        XCTAssertNil(EvidenceValidation.exactDate("2024-02"))
        XCTAssertNil(EvidenceValidation.exactDate("2024-02-30"))
        XCTAssertNotNil(EvidenceValidation.exactDate("2024-02-29"))
    }

    func testChunkingCoversEntireUnicodeSource() {
        let source = String(repeating: "A🫶🏽é中\n", count: 1000)
        let chunks = SourceTextChunks.split(source, limit: 100, overlap: 10)
        let restored = chunks.enumerated().map { $0.offset == 0 ? $0.element : String($0.element.dropFirst(10)) }.joined()
        XCTAssertEqual(restored, source)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 100 })
        XCTAssertEqual(SourceTextChunks.split("", limit: 10), [])
    }

    func testVersionThreeMigrationPreservesOriginalAndPatientEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var generated = occurrence()
        generated.sourceExcerpt = "Unreliable opening excerpt"
        var edited = occurrence("Patient correction")
        edited.origin = .userEdited
        let original = Session(transcript: "Original transcript", summaryEntries: [generated, edited])
        var envelope = SessionsEnvelope(sessions: [original])
        envelope.version = 3
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        try data.write(to: directory.appendingPathComponent("sessions.json"))
        let store = try SessionStore(storageDirectory: directory)
        let loaded = try await store.loadAll()
        XCTAssertEqual(loaded[0].transcript, original.transcript)
        XCTAssertNil(loaded[0].summaryEntries?[0].relevantDate)
        XCTAssertNil(loaded[0].summaryEntries?[0].sourceExcerpt)
        XCTAssertNotNil(loaded[0].summaryEntries?[1].relevantDate)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("sessions-v3-backup.json")), data)
    }

    func testConcurrentOccurrenceEditsDoNotLoseOtherFields() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let id = UUID()
        var a = occurrence("A"), b = occurrence("B")
        a.sourceSessionID = id; b.sourceSessionID = id
        try await store.upsert(Session(id: id, transcript: "Original", summaryEntries: [a, b]))
        a.details = "First correction"; b.details = "Second correction"
        let firstEdit = a, secondEdit = b
        async let first: Void = store.saveSummaryEntry(firstEdit)
        async let second: Void = store.saveSummaryEntry(secondEdit)
        _ = try await (first, second)
        let entries = try await store.loadAll()[0].summaryEntries!
        XCTAssertEqual(Set(entries.map(\.details)), Set(["First correction", "Second correction"]))
    }

    func testExtractionCannotResurrectDeletedRecordOrOverwriteNewTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let session = Session(transcript: "New text")
        try await store.upsert(session)
        try await store.applyExtraction(sessionID: session.id, transcript: "Old text", title: "Old", summary: "Stale", entries: [], version: 4)
        let first = try await store.loadAll()
        XCTAssertNil(first[0].summary)
        try await store.delete(id: session.id)
        try await store.applyExtraction(sessionID: session.id, transcript: "New text", title: "Old", summary: "Stale", entries: [], version: 4)
        let second = try await store.loadAll()
        XCTAssertTrue(second.isEmpty)
    }

    func testRecordPresentationKeepsItsOwnWordingAndSharedPatientStatus() throws {
        let earlier = occurrence("Headache", category: .symptoms, date: "2026-01-01")
        let later = occurrence("Headache", category: .symptoms, date: "2026-08-01")
        var preference = HealthFactPreference(id: HealthMemoryProjection.key(for: earlier))
        preference.clinicalStatus = .past
        let original = try XCTUnwrap(HealthMemoryProjection.facts(in: snapshot([earlier, later], preferences: [preference]), verifiedOnly: false).first)
        XCTAssertEqual(original.latest.id, later.id)
        preference.reviewedRevision = original.revision

        let shared = try XCTUnwrap(HealthMemoryProjection.facts(in: snapshot([earlier, later], preferences: [preference]), verifiedOnly: false).first)
        let fromEarlierRecord = try XCTUnwrap(shared.presentedFromRecord(earlier.sourceSessionID!))
        XCTAssertEqual(fromEarlierRecord.latest.id, earlier.id)
        XCTAssertEqual(fromEarlierRecord.id, shared.id)
        XCTAssertEqual(fromEarlierRecord.clinicalStatus, .past)
        XCTAssertTrue(fromEarlierRecord.isReviewed)
        XCTAssertNil(shared.presentedFromRecord(UUID()))
    }

    func testOverviewUpdatesWhenCurrentConcernBecomesPast() {
        let entry = occurrence("Migraine", category: .chiefComplaint)
        var preference = HealthFactPreference(id: HealthMemoryProjection.key(for: entry))
        let current = HealthMemoryProjection.facts(in: snapshot([entry]), verifiedOnly: false)
        XCTAssertTrue(HealthSummaryPresentation.overview(facts: current)!.contains("Concerns include Migraine"))
        preference.clinicalStatus = .past
        let past = HealthMemoryProjection.facts(in: snapshot([entry], preferences: [preference]), verifiedOnly: false)
        XCTAssertFalse(HealthSummaryPresentation.overview(facts: past)!.contains("Concerns include"))
    }

    func testOverviewIncludesDefaultCurrentButNotCompletedCareSteps() {
        var entry = occurrence("Keep a diary", category: .carePlan)
        entry.evidence?.actionKind = "homecare"
        let current = HealthMemoryProjection.facts(in: snapshot([entry]), verifiedOnly: false)
        XCTAssertTrue(HealthSummaryPresentation.overview(facts: current)!.contains("Current care steps"))
        var preference = current[0].preference
        preference.actionStatus = .completed
        let completed = HealthMemoryProjection.facts(in: snapshot([entry], preferences: [preference]), verifiedOnly: false)
        XCTAssertFalse(HealthSummaryPresentation.overview(facts: completed)!.contains("Current care steps"))
        entry.evidence?.statusExplicit = false
        let unknown = HealthMemoryProjection.facts(in: snapshot([entry]), verifiedOnly: false)
        XCTAssertTrue(HealthSummaryPresentation.overview(facts: unknown)!.contains("Current care steps"))
    }

    func testHiddenDetailsLeaveOverviewEmpty() {
        let entry = occurrence()
        var preference = HealthFactPreference(id: HealthMemoryProjection.key(for: entry))
        preference.hidden = true
        let facts = HealthMemoryProjection.facts(in: snapshot([entry], preferences: [preference]), verifiedOnly: false)
        XCTAssertNil(HealthSummaryPresentation.overview(facts: facts))
    }

    func testRemovingAndRestoringFactPreservesOriginalAndOccurrences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let entry = occurrence()
        try await store.upsert(Session(id: entry.sourceSessionID!, transcript: "Original source words", summaryEntries: [entry]))
        var preference = HealthFactPreference(id: HealthMemoryProjection.key(for: entry))
        preference.hidden = true
        try await store.savePreference(preference)
        let hidden = try await store.healthSnapshot()
        XCTAssertTrue(HealthMemoryProjection.facts(in: hidden, verifiedOnly: false).isEmpty)
        XCTAssertEqual(hidden.sessions[0].transcript, "Original source words")
        var anchored = entry
        anchored.evidence?.factIdentity = preference.id
        XCTAssertEqual(hidden.sessions[0].summaryEntries, [anchored])
        preference.hidden = false
        try await store.savePreference(preference)
        let restored = try await store.healthSnapshot()
        XCTAssertEqual(HealthMemoryProjection.facts(in: restored, verifiedOnly: false)[0].occurrences, [anchored])
    }

    func testFiveHundredRecordsProjection() {
        let entries = (0..<10_000).map { i in occurrence("Fact \(i % 100)") }
        let records = stride(from: 0, to: entries.count, by: 20).map { offset in
            Session(transcript: "Synthetic source", summaryEntries: Array(entries[offset..<offset + 20]))
        }
        let saved = HealthMemorySnapshot(sessions: records)
        let facts = HealthMemoryProjection.facts(in: saved, verifiedOnly: false)
        XCTAssertEqual(facts.count, 100)
        XCTAssertEqual(facts.reduce(0) { $0 + $1.occurrences.count }, 10_000)
    }
}
