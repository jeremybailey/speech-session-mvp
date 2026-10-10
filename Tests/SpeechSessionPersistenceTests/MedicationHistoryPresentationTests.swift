import XCTest
@testable import SpeechSessionPersistence

final class MedicationHistoryPresentationTests: XCTestCase {
    private func fact(_ name: String, _ date: String, id: String) -> HealthFact {
        var entry = SummaryEntry(category: .medications, title: name)
        entry.evidence = ClinicalEvidence()
        entry.evidence?.eventDate = date
        return HealthFact(id: id, occurrences: [entry], preference: .init(id: id), topicIDs: [])
    }
    func testElevenFillsShowLatestOnceAndKeepEveryOccurrence() {
        let rows = (1...11).map { fact("LOTEMAX 0.5 % GEL EYE DROPS", String(format: "2025-%02d-01", $0), id: "\($0)") }
        let result = MedicationHistoryPresentation.group(rows)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].occurrences.count, 11)
        XCTAssertEqual(result[0].latest.evidence?.eventDate, "2025-11-01")
    }
    func testDifferentStrengthsAndPatientChoicesRemainSeparate() {
        let a = fact("LOTEMAX 0.5%", "2025-01-01", id: "a")
        let b = fact("LOTEMAX 1%", "2025-02-01", id: "b")
        XCTAssertEqual(MedicationHistoryPresentation.group([a,b]).count, 2)
        var old = a; old.preference.clinicalStatus = .past
        var new = a; new.preference.clinicalStatus = .current
        XCTAssertEqual(MedicationHistoryPresentation.group([old,new]).count, 2)
    }
    func testHiddenOccurrenceDoesNotHideOtherRefills() {
        var a = fact("LOTEMAX 0.5%", "2025-01-01", id: "a")
        a.preference.hidden = true
        let b = fact("LOTEMAX 0.5%", "2025-02-01", id: "b")
        let result = MedicationHistoryPresentation.group([a,b])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.filter { $0.preference.hidden }.map(\.id), ["a"])
        XCTAssertEqual(result.filter { !$0.preference.hidden }.map(\.id), ["b"])
    }
    func testMatchingPatientChoicesDoNotSplitRefillHistory() {
        var a = fact("Lotemax 0.5% Gel Eye Drops", "2024-08-02", id: "a")
        var b = fact("LOTEMAX 0.5 % Gel Eye Drops", "2025-10-18", id: "b")
        a.preference.clinicalStatus = .current
        b.preference.clinicalStatus = .current
        b.occurrences[0].evidence?.dose = "0.5%"
        let result = MedicationHistoryPresentation.group([a,b])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.occurrences.count, 2)
        XCTAssertEqual(result.first?.latest.evidence?.eventDate, "2025-10-18")
    }
    func testOneExplicitlySeparatedEntryDoesNotSplitOtherRefills() {
        var a = fact("Example 0.5% drops", "2024-01-01", id: "a")
        a.occurrences[0].evidence?.combinationExcluded = true
        let b = fact("Example 0.5% drops", "2024-02-01", id: "b")
        let c = fact("Example 0.5% drops", "2024-03-01", id: "c")
        let result = MedicationHistoryPresentation.group([a,b,c])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map { $0.occurrences.count }.sorted(), [1,2])
    }
    func testProjectionKeepsVisibleMedicationWhenMatchingOlderFactIsHidden() {
        var rows = (1...3).map { fact("Example 0.5% drops", "2025-01-0\($0)", id: "id-\($0)").latest }
        for i in rows.indices { rows[i].evidence?.factIdentity = "id-\(i+1)" }
        var session = Session(transcript: "")
        session.summaryEntries = rows
        var hidden = HealthFactPreference(id: "id-1")
        hidden.hidden = true
        let snapshot = HealthMemorySnapshot(sessions: [session], preferences: [hidden])
        let visible = HealthMemoryProjection.facts(in: snapshot, verifiedOnly: false)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.occurrences.count, 2)
        XCTAssertFalse(visible.first?.preference.hidden ?? true)
        let includingHidden = HealthMemoryProjection.facts(in: snapshot, includingHidden: true, verifiedOnly: false)
        XCTAssertEqual(includingHidden.flatMap(\.occurrences).count, 3)
        XCTAssertEqual(includingHidden.filter { $0.preference.hidden }.count, 1)
    }
    func testLabUnitRoutesFindingsToLabsButGeneralDiagnosisStaysFinding() {
        let entry = SummaryEntry(category: .findings, title: "Ferritin", details: "161 ug/L")
        XCTAssertEqual(StructuredHealthReport.prepare(entry, for: .init(kind: .lab, source: "Ferritin 161 ug/L", heading: "Lab Results")).category, .testsAndLabs)
        XCTAssertEqual(StructuredHealthReport.prepare(entry, for: .init(kind: .general, source: "Clinical diagnosis", heading: "Note")).category, .findings)
    }
}

final class ContactHistoryPresentationTests: XCTestCase {
    private func pharmacy(_ id: String, source: UUID?, phone: String = "", address: String = "") -> HealthFact {
        let entry = SummaryEntry(category: .practitionerContact, title: "Example Pharmacy",
            details: "Mention \(id): pharmacy for listed medication fills.",
            fields: [.init(label: "Role or specialty", value: "Dispensing pharmacy"),
                     .init(label: "Phone", value: phone), .init(label: "Address", value: address)],
            sourceSessionID: source)
        return HealthFact(id: id, occurrences: [entry], preference: .init(id: id), topicIDs: [])
    }
    func testIdenticalCardsGroupAcrossRecordsWithoutSharedContactChannel() {
        let a = pharmacy("a", source: UUID())
        var b = pharmacy("b", source: UUID())
        b.occurrences[0].details = a.latest.details
        b.occurrences[0].fields.reverse()
        let original = [a, b]
        let grouped = ContactHistoryPresentation.group(original)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(Set(grouped.flatMap(\.occurrences).map(\.id)), Set(original.flatMap(\.occurrences).map(\.id)))
        XCTAssertEqual(Set(grouped[0].occurrences.compactMap(\.sourceSessionID)).count, 2)
        XCTAssertEqual(ContactHistoryPresentation.group(grouped).count, 1)
        // Pure presentation: original facts and entries still exist unchanged.
        XCTAssertEqual(original.count, 2)
        XCTAssertEqual(original[1].occurrences.count, 1)
    }

    func testExactGroupingAppliesWhenProjectingExistingSavedDetails() {
        var a = pharmacy("a", source: nil).latest
        var b = pharmacy("b", source: nil).latest
        b.details = a.details
        var session = Session(date: Date(), transcript: "Saved source")
        a.sourceSessionID = session.id
        b.sourceSessionID = session.id
        session.summaryEntries = [a, b]
        let snapshot = HealthMemorySnapshot(sessions: [session])
        let facts = HealthMemoryProjection.facts(in: snapshot, verifiedOnly: false)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(Set(facts[0].occurrences.map(\.id)), Set([a.id, b.id]))
        XCTAssertEqual(snapshot.sessions[0].summaryEntries?.count, 2)
    }

    func testExactCardsRespectConflictsAndPatientChoices() {
        let a = pharmacy("a", source: UUID())
        var b = pharmacy("b", source: UUID())
        b.occurrences[0].details = a.latest.details
        b.occurrences[0].fields.append(.init(label: "Branch ID", value: "different branch"))
        XCTAssertEqual(ContactHistoryPresentation.group([a,b]).count, 2)
        b.occurrences[0].fields = a.latest.fields
        b.preference.hidden = true
        XCTAssertEqual(ContactHistoryPresentation.group([a,b]).count, 2)
        b.preference.hidden = false
        b.occurrences[0].evidence = ClinicalEvidence()
        b.occurrences[0].evidence?.combinationExcluded = true
        XCTAssertEqual(ContactHistoryPresentation.group([a,b]).count, 2)
        b.occurrences[0].evidence = nil
        b.preference.clinicalStatus = .past
        var chosen = a
        chosen.preference.clinicalStatus = .current
        XCTAssertEqual(ContactHistoryPresentation.group([chosen,b]).count, 2)
    }

    func testIdenticalNamesWithoutDetailsDoNotEstablishContactIdentity() {
        var a = pharmacy("a", source: UUID())
        var b = pharmacy("b", source: UUID())
        a.occurrences[0].details = ""
        b.occurrences[0].details = ""
        a.occurrences[0].fields = []
        b.occurrences[0].fields = []
        XCTAssertEqual(ContactHistoryPresentation.group([a,b]).count, 2)
    }

    func testRepeatedPharmacyNeedsSourceReviewRatherThanKeywordGrouping() {
        let source = UUID()
        let facts = (0..<10).map { pharmacy(String($0), source: source) }
        let grouped = ContactHistoryPresentation.group(facts)
        XCTAssertEqual(grouped.count, 10)
        XCTAssertEqual(Set(grouped.flatMap(\.occurrences).map(\.id)), Set(facts.flatMap(\.occurrences).map(\.id)))
    }
    func testBareNameAcrossRecordsOrMissingProvenanceStaysSeparate() {
        XCTAssertEqual(ContactHistoryPresentation.group([pharmacy("a", source: UUID()), pharmacy("b", source: UUID())]).count, 2)
        XCTAssertEqual(ContactHistoryPresentation.group([pharmacy("a", source: nil), pharmacy("b", source: nil)]).count, 2)
    }
    func testConflictingBranchesCannotMergeThroughIncompleteContact() {
        let source = UUID()
        let a = pharmacy("a", source: source, phone: "5550101", address: "10 Main St")
        let b = pharmacy("b", source: source)
        let c = pharmacy("c", source: source, phone: "5550102", address: "20 Main St")
        let groups = ContactHistoryPresentation.group([a,b,c])
        XCTAssertEqual(groups.count, 3)
        XCTAssertFalse(groups.contains { Set($0.occurrences.map(\.id)).isSuperset(of: [a.latest.id, c.latest.id]) })
    }
    func testPatientSeparationAndHiddenChoicesRemainIntact() {
        let source = UUID()
        let a = pharmacy("a", source: source)
        var b = pharmacy("b", source: source)
        b.preference.hidden = true
        XCTAssertEqual(ContactHistoryPresentation.group([a,b]).count, 2)
        b.preference.hidden = false
        b.occurrences[0].evidence = ClinicalEvidence()
        b.occurrences[0].evidence?.combinationExcluded = true
        XCTAssertEqual(ContactHistoryPresentation.group([a,b]).count, 2)
    }

    func testSameProviderEnrichedAndRawContactMetadataNotRepeated() {
        func fact(_ id: String, _ address: String, _ role: String) -> HealthFact {
            let entry = SummaryEntry(category: .practitionerContact, title: "Dr. Example Person",
                details: "address: \(address); org: Example Clinic; role: \(role)",
                fields: [.init(label: "Phone", value: "403 555 0100"), .init(label: "Organization", value: "Example Clinic"),
                         .init(label: "Address", value: address), .init(label: "Role or specialty", value: role)])
            return HealthFact(id: id, occurrences: [entry], preference: .init(id: id), topicIDs: [])
        }
        let a = fact("a", "Suite 10, 123 Main St", "Practitioner")
        let b = fact("b", "North Mall, Suite 10, 123 Main St", "Eye Physician and Surgeon")
        let grouped = ContactHistoryPresentation.group([a,b])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].occurrences.count, 2)
        let display = grouped[0].displayEntry
        XCTAssertEqual(display.fields.first { $0.label == "Address" }?.value, "North Mall, Suite 10, 123 Main St")
        XCTAssertEqual(display.fields.first { $0.label == "Role or specialty" }?.value, "Eye Physician and Surgeon")
        XCTAssertTrue(HealthDetailPresentation.remainingDetails(display).isEmpty)
        var other = b
        other.occurrences[0].fields.removeAll { $0.label == "Phone" }
        XCTAssertEqual(ContactHistoryPresentation.group([a,other]).count, 2)
    }
}

final class SymptomComparisonCandidateTests: XCTestCase {
    func testDifferentSymptomTitlesReachSameSourceComparison() {
        let a = SummaryEntry(category: .symptoms, title: "Tingling in back with knapsack")
        let b = SummaryEntry(category: .symptoms, title: "Tingling with Heavy Backpack", details: "Tingling sensation in the back when wearing a heavy knapsack")
        XCTAssertEqual(HealthFactMatching.symptomComparisonKey(a), HealthFactMatching.symptomComparisonKey(b))
        // Discovery alone never merges different wording or replaces evidence checking.
        XCTAssertFalse(HealthFactMatching.equivalent(a,b))
        var repeated = a
        repeated.fields = [.init(label: "Symptoms", value: a.title)]
        XCTAssertTrue(HealthDetailPresentation.fields(repeated).isEmpty)
    }
}
