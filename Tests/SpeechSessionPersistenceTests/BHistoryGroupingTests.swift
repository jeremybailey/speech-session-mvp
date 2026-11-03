import XCTest
@testable import SpeechSessionPersistence

final class BHistoryGroupingTests: XCTestCase {
    private func entry(_ text: String, category: SummaryEntryCategory = .medications, id: String = "row") -> SummaryEntry {
        var entry = SummaryEntry(category: category, title: text, details: "Recorded status: reported", sourceSessionID: UUID())
        entry.evidence = ClinicalEvidence()
        entry.evidence?.assessmentMethod = WholeHistoryPublication.version
        entry.evidence?.factIdentity = id
        return entry
    }
    private func fact(_ text: String, category: SummaryEntryCategory = .medications, id: String) -> HealthFact {
        .init(id: id, occurrences: [entry(text, category: category, id: id)], preference: .init(id: id), topicIDs: [])
    }
    func testReportAndFillDescriptionsGroupByProductAndKeepAllHistory() {
        let rows = [fact("Medication report lists EXAMPLE 0.5% GEL EYE DROPS as active, started Jan 9, 2026; frequency not shown.", id: "a"),
                    fact("Medication report lists EXAMPLE 0.5% GEL EYE DROPS as discontinued Jan 9, 2026; started Oct 18, 2025.", id: "b"),
                    fact("Fill: EXAMPLE 0.5% GEL EYE DROPS; Pharmacy A; 7 days' supply; filled Jan 9, 2026.", id: "c"),
                    fact("Fill: EXAMPLE 0.5% GEL EYE DROPS; Pharmacy B; 30 days' supply; filled Oct 18, 2025.", id: "d")]
        let grouped = MedicationHistoryPresentation.group(rows)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].occurrences.count, 4)
        XCTAssertEqual(grouped[0].title, "EXAMPLE")
        XCTAssertEqual(Set(grouped[0].occurrences.map(\.title)), Set(rows.map { $0.latest.title }))
        XCTAssertTrue(grouped[0].displayEntry.details.isEmpty)
        XCTAssertTrue(grouped[0].displayEntry.fields.contains { $0.label == "Strength" && $0.value == "0.5%" })
    }
    func testDifferentProductsStrengthsFormsAndUnknownsRemainSeparate() {
        let names = ["EXAMPLE 5mg tablet", "EXAMPLE 10mg tablet", "EXAMPLE 5mg capsule", "OTHER 5mg tablet", "EXAMPLE tablet", "UNKNOWN 5mg tablet"]
        let rows = names.enumerated().map { fact("Fill: " + $0.element + "; Pharmacy; filled Jan 9, 2026.", id: String($0.offset)) }
        XCTAssertEqual(MedicationHistoryPresentation.group(rows).count, names.count)
        let narrative = entry("Patient might use an unclear eye drop; no name or strength available.")
        XCTAssertEqual(MedicationIdentity.productTitle(narrative), narrative.title)
    }
    func testPatientEditsSeparationAndConflictingPreferencesArePreserved() {
        var a = fact("Fill: EXAMPLE 5mg tablet; filled Jan 1, 2025.", id: "a")
        var b = fact("Fill: EXAMPLE 5mg tablet; filled Feb 1, 2025.", id: "b")
        a.preference.clinicalStatus = .current; b.preference.clinicalStatus = .past
        XCTAssertEqual(MedicationHistoryPresentation.group([a,b]).count, 2)
        b.preference.clinicalStatus = .current
        a.occurrences[0].evidence?.combinationExcluded = true
        XCTAssertEqual(MedicationHistoryPresentation.group([a,b]).count, 2)
        a.occurrences[0].origin = .userEdited
        XCTAssertEqual(MedicationIdentity.productTitle(a.latest), a.latest.title)
    }
    func testExactRepeatedSymptomsGroupButNegationAndClinicalValuesDoNot() {
        var a = fact("Patient reports headache.", category: .symptoms, id: "a")
        var b = fact("Patient reports headache.", category: .symptoms, id: "b")
        a.occurrences[0].details += "\nAttribution: Patient\nRecorded date: 2025-01-01"
        b.occurrences[0].details += "\nAttribution: Clinician\nRecorded date: 2026-01-01"
        let negative = fact("Patient denies headache.", category: .symptoms, id: "negative")
        let grouped = BFactHistoryPresentation.group([a,b,negative])
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(Set(grouped.flatMap(\.occurrences).map(\.id)).count, 3)
        var uncertain = b; uncertain.occurrences[0].details = "Recorded status: unclear"
        XCTAssertEqual(BFactHistoryPresentation.group([a,uncertain]).count, 2)
    }
    func testRepeatedSymptomsRespectPatientSeparationAndDistinctEventDates() {
        var a = fact("Headache", category: .symptoms, id: "a")
        let b = fact("Headache", category: .symptoms, id: "b")
        a.occurrences[0].evidence?.combinationExcluded = true
        XCTAssertEqual(BFactHistoryPresentation.group([a,b]).count, 2)
        var labA = fact("Example lab 5 mmol/L", category: .testsAndLabs, id: "labA")
        var labB = fact("Example lab 5 mmol/L", category: .testsAndLabs, id: "labB")
        labA.occurrences[0].evidence?.eventDate = "2025-01-01"
        labB.occurrences[0].evidence?.eventDate = "2026-01-01"
        XCTAssertEqual(BFactHistoryPresentation.group([labA,labB]).count, 2)
    }
    func testReportRecordAndHistoryWordingShareTheSameProduct() {
        for prefix in ["Medication report lists", "Medication record lists", "Medication history lists", "Medication list lists"] {
            let rows = [fact(prefix + " EXAMPLE 0.5% GEL EYE DROPS as active; started Jan 9, 2026.", id: "active"),
                        fact(prefix + " EXAMPLE 0.5% GEL EYE DROPS as discontinued; started Oct 18, 2025.", id: "past"),
                        fact("Fill: EXAMPLE 0.5% GEL EYE DROPS; Pharmacy; filled Jan 9, 2026.", id: "fill")]
            let grouped = MedicationHistoryPresentation.group(rows)
            XCTAssertEqual(grouped.count, 1, prefix)
            XCTAssertEqual(grouped[0].occurrences.count, 3)
        }
    }

}
