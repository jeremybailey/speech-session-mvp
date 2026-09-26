import XCTest
@testable import SpeechSessionPersistence

final class ConditionSummaryTests: XCTestCase {
    private func fact(_ category: SummaryEntryCategory, _ title: String, condition: String? = nil,
                      system: String = "", date: String? = nil, current: Bool? = nil) -> HealthFact {
        var entry = SummaryEntry(category: category, title: title)
        entry.evidence = ClinicalEvidence()
        entry.evidence?.bodySystem = system
        entry.evidence?.eventDate = date
        entry.sourceSessionID = UUID()
        if let condition {
            entry.evidence?.topicNames = [condition]
            entry.evidence?.excerpt = "For \(condition): \(title)"
        }
        if let current {
            entry.evidence?.statusExplicit = true
            entry.clinicalStatus = current ? .current : .past
        }
        return HealthFact(id: entry.id.uuidString, occurrences: [entry], preference: .init(id: entry.id.uuidString), topicIDs: [])
    }
    func testRepeatedConcernsHaveOneConditionWithoutMergingSources() {
        let facts = [fact(.symptoms, "Migraines"), fact(.chiefComplaint, "MIGRAINE"),
                     fact(.findings, "Migraine diagnosed", condition: "Migraine")]
        let groups = ConditionSummaryProjection.groups(facts: facts, topics: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Migraine")
        XCTAssertEqual(Set(groups[0].facts.flatMap(\.occurrences).map(\.id)), Set(facts.flatMap(\.occurrences).map(\.id)))
        XCTAssertEqual(ConditionSummaryProjection.normalized("headache"), "headache")
        XCTAssertNotEqual(ConditionSummaryProjection.normalized("right knee pain"), ConditionSummaryProjection.normalized("left knee pain"))
    }
    func testEquivalentSymptomPhrasingGroupsAcrossBodySites() {
        let facts = [fact(.symptoms, "Pain in the lower back"), fact(.chiefComplaint, "Low back pain"),
                     fact(.symptoms, "Pain in the right knee"), fact(.chiefComplaint, "Right knee pain")]
        let groups = ConditionSummaryProjection.groups(facts: facts, topics: [])
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.facts.count == 2 })
        XCTAssertEqual(Set(groups.flatMap(\.facts).flatMap(\.occurrences).map(\.id)),
                       Set(facts.flatMap(\.occurrences).map(\.id)))
    }
    func testRelatedButDistinctConcernsStaySeparate() {
        let names = ["Lower back pain", "Upper back pain", "Back tingling", "Back pain",
                     "Left knee pain", "Right knee pain", "Sciatica"]
        XCTAssertEqual(ConditionSummaryProjection.groups(facts: names.map { fact(.symptoms, $0) }, topics: []).count, names.count)
    }
    func testLegacyReportGroupsStayInAllAndPrimaryConcernLeads() {
        let old = fact(.findings, "Normal heart size")
        var observation = old.latest
        observation.evidence?.conditionGroup = "Heart findings"
        observation.evidence?.conditionGroupReason = "Report section"
        let legacy = HealthFact(id: old.id, occurrences: [observation], preference: old.preference, topicIDs: [])
        let concern = fact(.chiefComplaint, "Migraine", date: "2020-01-01")
        var primary = concern.latest
        primary.evidence?.conditionIsPrimary = true
        let primaryFact = HealthFact(id: concern.id, occurrences: [primary], preference: concern.preference, topicIDs: [])
        let recent = fact(.symptoms, "Fatigue", date: "2026-01-01")
        let groups = ConditionSummaryProjection.groups(facts: [legacy, recent, primaryFact], topics: [])
        XCTAssertEqual(groups.first?.name, "Migraine")
        XCTAssertFalse(groups.contains { $0.name == "Heart findings" })
        XCTAssertEqual(groups.first { $0.isUncategorized }?.facts.first?.id, legacy.id)
    }
    func testLargePanelsAndUnrelatedFindingsRemainSeparate() {
        var facts = (1...40).map { fact(.testsAndLabs, "Analyte \($0)", condition: "Hormone testing") }
        facts += [fact(.findings, "Fetal position", condition: "Pregnancy-related care"),
                  fact(.findings, "Joint examination", condition: "Right knee pain"),
                  fact(.findings, "Unexplained result")]
        let groups = ConditionSummaryProjection.groups(facts: facts, topics: [])
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.first { $0.name == "Hormone testing" }?.facts.count, 40)
        XCTAssertEqual(groups.first { $0.isUncategorized }?.facts.count, 1)
    }
    func testOldMedicationDateDoesNotImplyCurrentOrStopped() {
        let unknown = fact(.medications, "Example tablet", condition: "Migraine", date: "2019-01-01")
        let past = fact(.medications, "Different tablet", condition: "Migraine", date: "2020-01-01", current: false)
        let current = fact(.carePlan, "Keep a diary", condition: "Migraine", date: "2026-01-01", current: true)
        XCTAssertEqual(ConditionSummaryProjection.status(of: unknown), .unknown)
        XCTAssertEqual(ConditionSummaryProjection.status(of: past), .notCurrent)
        XCTAssertEqual(ConditionSummaryProjection.status(of: current), .current)
        XCTAssertFalse(ConditionSummaryProjection.matches(unknown, status: .current))
        XCTAssertEqual(ConditionSummaryProjection.sorted([unknown, current, past]).map(\.id), [current.id,past.id,unknown.id])
    }
    func testUnsubstantiatedTopicAndBodySystemAloneDoNotCreateLinks() {
        var unrelated = fact(.medications, "Example tablet", system: "neurological")
        unrelated.occurrences[0].evidence?.topicNames = ["Migraine"]
        unrelated.occurrences[0].evidence?.excerpt = "Medication prescribed, indication unknown"
        let groups = ConditionSummaryProjection.groups(facts: [fact(.symptoms, "Migraine", system: "neurological"), unrelated], topics: [])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { $0.isUncategorized }?.facts.first?.id, unrelated.id)
    }
    func testMereMentionInSameExcerptDoesNotLinkLabToCondition() {
        var lab = fact(.testsAndLabs, "Hormone result")
        lab.occurrences[0].evidence?.topicNames = ["Migraine"]
        lab.occurrences[0].evidence?.excerpt = "Migraine noted elsewhere. Unrelated hormone result."
        XCTAssertTrue(ConditionSummaryProjection.groups(facts: [lab], topics: [])[0].isUncategorized)
    }
    func testConflictingCurrentStatusesRemainUnknownUntilPatientChooses() {
        var item = fact(.medications, "Example tablet", current: true)
        item.occurrences += fact(.medications, "Example tablet", current: false).occurrences
        XCTAssertEqual(ConditionSummaryProjection.status(of: item), .unknown)
        item.preference.clinicalStatus = .past
        XCTAssertEqual(ConditionSummaryProjection.status(of: item), .notCurrent)
    }
    func testExplicitPatientAssignmentAndUncategorizedOverride() {
        var item = fact(.medications, "Example tablet", condition: "Migraine")
        item.preference.topicIDs = []
        XCTAssertTrue(ConditionSummaryProjection.groups(facts: [item], topics: [])[0].isUncategorized)
        let topic = HealthTopic(name: "Another concern")
        item.preference.topicIDs = [topic.id]
        XCTAssertEqual(ConditionSummaryProjection.groups(facts: [item], topics: [topic])[0].name, "Another concern")
    }
    func testGroupedMedicationDoesNotLeakOneIndicationIntoAnother() {
        let a = fact(.medications, "Example tablet", condition: "Migraine")
        let b = fact(.medications, "Example tablet", condition: "Right knee pain")
        var combined = a
        combined.occurrences += b.occurrences
        let groups = ConditionSummaryProjection.groups(facts: [combined], topics: [])
        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.facts[0].occurrences.count == 1 })
    }
    func testProvidersAndOriginalDatesSurviveProjection() {
        var old = fact(.carePlan, "Old exercise advice", condition: "Right knee pain", date: "2021-01-01", current: false)
        var new = fact(.carePlan, "Updated exercise advice", condition: "Right knee pain", date: "2026-01-01", current: true)
        old.occurrences[0].evidence?.practitioner = "Dr. Example A"
        new.occurrences[0].evidence?.practitioner = "Dr. Example B"
        let group = ConditionSummaryProjection.groups(facts: [old,new], topics: [])[0]
        XCTAssertEqual(group.facts.map { $0.latest.evidence?.practitioner }, ["Dr. Example B", "Dr. Example A"])
        XCTAssertEqual(group.facts.map { ConditionSummaryProjection.status(of: $0) }, [.current,.notCurrent])
    }
    func testConflictingBodySystemsDoNotAbsorbUnspecifiedConcern() {
        let groups = ConditionSummaryProjection.groups(facts: [fact(.symptoms,"Pain",system:"digestive"),
             fact(.symptoms,"Pain",system:"musculoskeletal"),fact(.symptoms,"Pain")],topics:[])
        XCTAssertEqual(groups.count,3)
        XCTAssertTrue(groups.contains { $0.isUncategorized })
    }
}
