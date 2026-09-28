import XCTest
@testable import SpeechSessionPersistence

final class StoryOverviewTests: XCTestCase {
    func testConditionsRemainAvailableBeforeOverviewIsCreated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let entry = SummaryEntry(category: .symptoms, title: "Persistent eye discomfort", origin: .userAdded)
        try await store.upsert(Session(transcript: "Patient reports persistent eye discomfort.", summaryEntries: [entry]))
        let facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        let grouping = ConditionSynthesis(
            groups: [.init(name: "Persistent eye concern", bodySystem: "eye", isPrimary: true,
                           reason: "The patient describes this concern directly.", entryIDs: [entry.id])],
            unassigned: []
        )
        try await store.saveConditionSynthesis(grouping, expected: facts)

        let relaunched = try SessionStore(storageDirectory: directory)
        let savedConditions = await relaunched.conditionSynthesis(for: facts)
        let overviewBeforeCreation = await relaunched.storyOverview(for: facts)
        XCTAssertEqual(savedConditions?.groups.first?.name, "Persistent eye concern")
        XCTAssertNil(overviewBeforeCreation)

        var overview = StoryOverview(text: "You reported persistent eye discomfort.", facts: facts)
        overview.conditionContext = await relaunched.currentOverviewConditionContext(facts)
        try await relaunched.saveStoryOverview(overview, expected: facts)
        let savedOverview = await relaunched.storyOverview(for: facts)
        XCTAssertEqual(savedOverview?.text, overview.text)
    }

    func testSentenceNumbersMustAppearInReferencedFacts() {
        let entry = SummaryEntry(category: .findings, title: "Pregnancy", details: "31 weeks pregnant", origin: .userAdded)
        let fact = HealthFact(id: entry.id.uuidString, occurrences: [entry], preference: .init(id: entry.id.uuidString), topicIDs: [])
        XCTAssertTrue(StoryOverview(sentences: [.init(text: "You are 31 weeks pregnant.", factIDs: [fact.id])]).hasGroundedNumbers(in: [fact]))
        XCTAssertFalse(StoryOverview(sentences: [.init(text: "You are 34 weeks pregnant.", factIDs: [fact.id])]).hasGroundedNumbers(in: [fact]))
    }
    func testMedicationHistoryDoesNotChangeIdentityOnEveryRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let source = "Example 0.5% Eye Drops filled on 2023-08-01 and 2024-05-30"
        var entries: [SummaryEntry] = []
        for day in ["2023-08-01", "2024-05-30"] {
            var entry = SummaryEntry(category: .medications, title: "Example 0.5% Eye Drops", details: "Filled on \(day)")
            entry.evidence = ClinicalEvidence()
            entry.evidence?.eventDate = day
            // Simulate an already affected installation, with distinct fills sharing
            // a previously persisted display identity.
            entry.evidence?.factIdentity = "legacy-medication-display-group"
            let contentHash = SummaryVerification.contentHash(entry)
            entry.evidence?.assessment = SummaryAssessment(admission: .supported, reason: "Fixture", sourceHash: SummaryVerification.hash(source), contentHash: contentHash, citations: [])
            entries.append(entry)
        }
        try await store.upsert(Session(transcript: source, summaryEntries: entries))
        try await store.consolidateHealthFacts()
        let initial = HealthMemoryProjection.facts(in: try await store.healthSnapshot())
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(initial.first?.occurrences.count, 2)
        let json: [String: Any] = ["sentences": [["text": "Eye drops were prescribed.", "factIDs": [try XCTUnwrap(initial.first?.id)]]]]
        var overview = try JSONDecoder().decode(StoryOverview.self, from: JSONSerialization.data(withJSONObject: json))
        overview.conditionContext = await store.currentOverviewConditionContext(initial)
        try await store.saveStoryOverview(overview, expected: initial)
        for _ in 0..<3 {
            try await store.consolidateHealthFacts()
            let next = HealthMemoryProjection.facts(in: try await store.healthSnapshot())
            XCTAssertEqual(next.map(\.id), initial.map(\.id))
            XCTAssertEqual(StoryOverview.fingerprint(next), StoryOverview.fingerprint(initial))
            let cached = await store.storyOverview(for: next)
            XCTAssertEqual(cached?.text, overview.text)
        }
    }
    func testShortRequestCodesRestoreDurableFactIDsBeforeValidation() throws {
        let overview = try JSONDecoder().decode(StoryOverview.self, from: Data(#"{"sentences":[{"text":"A recorded concern.","factIDs":["F001"]}]}"#.utf8))
        let translated = overview.replacingFactIDs(using: ["F001": "durable-fact-id"])
        XCTAssertEqual(translated.sentences[0].factIDs, ["durable-fact-id"])
        XCTAssertEqual(overview.replacingFactIDs(using: [:]).sentences[0].factIDs, ["F001"])
    }
    func testReferencesAndFingerprintInvalidateChangedPatientState() throws {
        let e = SummaryEntry(category: .symptoms, title: "Example", origin: .userAdded)
        let f = HealthFact(id: "one", occurrences: [e], preference: .init(id: "one"), topicIDs: [])
        let valid = try JSONDecoder().decode(StoryOverview.self, from: Data(#"{"sentences":[{"text":"A recorded concern is Example.","factIDs":["one"]}]}"#.utf8))
        XCTAssertTrue(valid.hasValidReferences(in: [f]))
        XCTAssertFalse(valid.hasValidReferences(in: []))
        var changed = f; changed.preference.clinicalStatus = .past
        XCTAssertNotEqual(StoryOverview.fingerprint([f]), StoryOverview.fingerprint([changed]))
        var edited = f
        edited.occurrences[0].details = "Changed within the same timestamp"
        XCTAssertEqual(edited.revision, f.revision)
        XCTAssertNotEqual(StoryOverview.fingerprint([f]), StoryOverview.fingerprint([edited]))
    }
    func testOverviewCacheSurvivesReloadAndRejectsConcurrentEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let entry = SummaryEntry(category: .symptoms, title: "Example concern", origin: .userAdded)
        try await store.upsert(Session(transcript: "Original", summaryEntries: [entry]))
        let facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot())
        let json: [String: Any] = ["sentences": [["text": "A recorded concern is Example concern.", "factIDs": [facts[0].id]]]]
        var overview = try JSONDecoder().decode(StoryOverview.self, from: JSONSerialization.data(withJSONObject: json))
        overview.conditionContext = await store.currentOverviewConditionContext(facts)
        try await store.saveStoryOverview(overview, expected: facts)
        let reopened = try SessionStore(storageDirectory: directory)
        let cached = await reopened.storyOverview(for: facts)
        XCTAssertEqual(cached?.text, overview.text)
        // Match the app's refresh path, including consolidation and a fresh projection.
        for _ in 0..<3 {
            try await reopened.consolidateHealthFacts()
            let refreshedFacts = HealthMemoryProjection.facts(in: try await reopened.healthSnapshot())
            XCTAssertEqual(refreshedFacts.map(\.id), facts.map(\.id))
            XCTAssertEqual(StoryOverview.fingerprint(refreshedFacts), StoryOverview.fingerprint(facts))
            let refreshedOverview = await reopened.storyOverview(for: refreshedFacts)
            XCTAssertEqual(refreshedOverview?.text, overview.text)
        }
        var preference = facts[0].preference; preference.hidden = true
        try await store.savePreference(preference)
        let updated = HealthMemoryProjection.facts(in: try await store.healthSnapshot())
        let invalidated = await store.storyOverview(for: updated)
        XCTAssertNil(invalidated)
        do { try await store.saveStoryOverview(overview, expected: facts); XCTFail("Stale overview must not commit") }
        catch { XCTAssertTrue(error is SummaryCommitError) }
    }

    func testLocalFallbackOrdersClinicalHistoryWithoutInventingDates() {
        func fact(_ title: String, category: SummaryEntryCategory, date: String?) -> HealthFact {
            var e = SummaryEntry(category: category, title: title)
            e.evidence = ClinicalEvidence(); e.evidence?.eventDate = date
            return HealthFact(id: title, occurrences: [e], preference: .init(id: title), topicIDs: [])
        }
        let overview = HealthSummaryPresentation.overview(facts: [fact("Later", category: .findings, date: "2025-01"), fact("Earlier", category: .symptoms, date: "2020"), fact("Undated", category: .medications, date: nil)])!
        XCTAssertLessThan(overview.range(of: "2020")!.lowerBound, overview.range(of: "2025-01")!.lowerBound)
        XCTAssertFalse(overview.contains("2026"))
    }
    func testBoundedConcurrencyAndStableOutputOrder() async throws {
        actor Counter {
            var active = 0, peak = 0
            func start() { active += 1; peak = max(peak, active) }
            func stop() { active -= 1 }
        }
        let counter = Counter()
        let result = try await SummaryParallelWork.map(Array(0..<12), limit: 3) { value in
            await counter.start()
            try await Task.sleep(nanoseconds: UInt64(12 - value) * 1_000_000)
            await counter.stop()
            return value
        }
        XCTAssertEqual(result, Array(0..<12))
        let peak = await counter.peak
        XCTAssertEqual(peak, 3)
    }
    func testCancelledParallelWorkDoesNotStartMoreItems() async {
        let task = Task {
            try await SummaryParallelWork.map(Array(0..<20), limit: 2) { value in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return value
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testOrganizedPriorityExcludesUnassignedSymptomAndInvalidatesOverview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let eye = SummaryEntry(category: .symptoms, title: "Eye discomfort", origin: .userAdded)
        let back = SummaryEntry(category: .symptoms, title: "Back tingling", origin: .userAdded)
        try await store.upsert(Session(transcript: "Synthetic", summaryEntries: [eye, back]))
        let facts = HealthMemoryProjection.facts(in: try await store.healthSnapshot(), verifiedOnly: true)
        var grouping = ConditionSynthesis(groups: [.init(name: "Ongoing eye concern", bodySystem: "eye", isPrimary: true, reason: "Explicit concern", entryIDs: [eye.id])], unassigned: [back.id])
        try await store.saveConditionSynthesis(grouping, expected: facts)
        let context = await store.currentOverviewConditionContext(facts)
        XCTAssertTrue(context.contains("Priority 1: Ongoing eye concern"))
        XCTAssertFalse(context.contains("Back tingling"))
        var overview = StoryOverview(text: "Your main concern is your eye discomfort.", facts: facts)
        overview.conditionContext = context
        try await store.saveStoryOverview(overview, expected: facts)
        grouping.groups[0].name = "Reported eye discomfort"
        try await store.saveConditionSynthesis(grouping, expected: facts)
        let stale = await store.storyOverview(for: facts)
        XCTAssertNil(stale)
        do {
            try await store.saveStoryOverview(overview, expected: facts)
            XCTFail("An overview generated under outdated organization must not commit")
        } catch { XCTAssertTrue(error is SummaryCommitError) }
    }

}
