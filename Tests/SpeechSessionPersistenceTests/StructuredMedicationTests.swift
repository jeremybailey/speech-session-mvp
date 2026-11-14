import XCTest
@testable import SpeechSessionPersistence

final class StructuredMedicationTests: XCTestCase {
    private func b(_ text: String, status: String = "prescribed") -> SummaryEntry {
        var e = SummaryEntry(category: .medications, title: text, details: "Recorded status: " + status + "\nAttribution: Prescription label\nRecorded date: ")
        var evidence = ClinicalEvidence(); evidence.assessmentMethod = WholeHistoryPublication.version
        evidence.practitioner = "Prescription label"; evidence.eventDate = ""
        e.evidence = evidence; return e
    }
    private func fact(_ entry: SummaryEntry, id: String = "sample") -> HealthFact {
        HealthFact(id: id, occurrences: [entry], preference: .init(id: id), topicIDs: [])
    }
    func testSourceSelectedFieldsBecomeShortHeadingsAndLabelledFields() {
        var e = b("Long narrative medication statement; directions and provenance remain in the original.")
        e.evidence?.medication = .init(values: ["name":"Example", "strength":"5 mg", "form":"tablet", "instructions":"Take one tablet at night", "clinician":"Dr. Jane Doe"])
        let displayed = fact(e).displayEntry
        XCTAssertEqual(displayed.title,"Example")
        XCTAssertTrue(displayed.details.isEmpty)
        XCTAssertEqual(displayed.fields.first { $0.label == "Strength" }?.value,"5 mg")
        XCTAssertEqual(displayed.fields.first { $0.label == "Recorded instructions" }?.value,"Take one tablet at night")
        XCTAssertEqual(displayed.evidence?.practitioner,"Dr. Jane Doe")
        XCTAssertEqual(e.title,"Long narrative medication statement; directions and provenance remain in the original.")
    }
    func testGroundingDropsUnsupportedFieldsWithoutGuessingFromNarrative() {
        let m = StructuredMedication.grounded(["name":"Example","strength":"10 mg","instructions":"Twice daily","clinician":"Prescription label"], in:["Example 5 mg once daily"])
        XCTAssertEqual(m["name"],"Example"); XCTAssertNil(m["strength"]); XCTAssertNil(m["instructions"])
        var e = b("Example 10 mg; take twice daily")
        e.evidence?.medication = m
        let display = fact(e).displayEntry
        XCTAssertFalse(display.fields.contains { $0.label == "Strength" || $0.label == "Recorded instructions" })
    }
    func testAttributionIsNotPractitionerAndAbsentDatesAreNotRendered() {
        for label in ["Prescription label","Health record fills list","Patient","Medication report","Invoice"] {
            var e = b("Example 5mg tablet")
            e.evidence?.practitioner = label
            let display = fact(e).displayEntry
            XCTAssertNil(display.evidence?.practitioner,label)
            XCTAssertFalse(display.fields.contains { $0.label == "Record date" })
            XCTAssertFalse(display.details.contains("Attribution"))
        }
        XCTAssertEqual(BClinicalPresentation.namedPractitioner("Dr. Jane Doe"),"Dr. Jane Doe")
        XCTAssertEqual(BClinicalPresentation.namedPractitioner("Jane Doe"),"Jane Doe")
    }
    func testPrescriptionAndOldActiveRecordDoNotBecomeCurrentPatientUse() {
        for status in ["prescribed","reported","historical"] {
            var e = b("Medication record lists Example 5mg tablet as active; start date Jan 1, 2024.",status:status)
            e.evidence?.statusExplicit = true
            let f = fact(e)
            XCTAssertFalse(f.hasKnownStatus)
            XCTAssertEqual(CareInstructionPresentation.status(f),"Current use unknown")
            XCTAssertEqual(ConditionSummaryProjection.status(of:f),.unknown)
            var confirmed = f; confirmed.preference.clinicalStatus = .current
            XCTAssertEqual(CareInstructionPresentation.status(confirmed),"Current")
        }
    }
    func testCombinationStrengthAndFormFormattingGroupsWithoutMergingDistinctProducts() {
        let a = b("EXAMPLE OP DRP 0.2/0.5%; label direction: instill 1 drop in right eye twice daily.")
        let c = b("Fill: EXAMPLE 0.2%-0.5% EYE DROPS; Pharmacy; filled Jun 16, 2024.")
        XCTAssertEqual(MedicationIdentity.key(a),MedicationIdentity.key(c))
        let grouped = MedicationHistoryPresentation.group([fact(a,id:"a"),fact(c,id:"b")])
        XCTAssertEqual(grouped.count,1); XCTAssertEqual(grouped[0].occurrences.count,2)
        for text in ["Fill: OTHER 0.2%-0.5% EYE DROPS; Pharmacy", "Fill: EXAMPLE 0.1%-0.5% EYE DROPS; Pharmacy", "Fill: EXAMPLE 0.2%-0.5% EYE OINTMENT; Pharmacy"] {
            XCTAssertNotEqual(MedicationIdentity.key(a),MedicationIdentity.key(b(text)))
        }
        XCTAssertNotEqual(MedicationIdentity.key(b("Example 5mg/ml solution")),MedicationIdentity.key(b("Example 5mg/5ml solution")))
    }
    func testUnclearPrescriptionIsConciseAndDoesNotExpandShorthandOrAmbiguousDate() {
        let e = b("Prescription image wording: 'Example Plasma 20% ODI Jos / 4x / 6x / 8x per day for 1 month'; preserved as transcribed, without resolving the unclear instructions. Date shown as 6-2-2026.")
        let display = fact(e).displayEntry
        XCTAssertEqual(display.title,"Example Plasma")
        XCTAssertEqual(display.fields.first { $0.label == "Strength" }?.value,"20%")
        XCTAssertEqual(display.fields.first { $0.label == "Record date" }?.value,"6-2-2026")
        XCTAssertTrue(display.fields.contains { $0.label == "Review" })
        XCTAssertFalse(display.fields.contains { $0.label == "Route" || $0.label == "Recorded frequency" })
        XCTAssertTrue(e.title.contains("ODI Jos"))
    }
    func testPatientEditsAndUnknownProductsAreProtected() {
        var e = b("Prescription: 'Example 5mg tablet'; source wording unclear")
        e.origin = .userEdited
        XCTAssertEqual(BClinicalPresentation.display(e),e)
        var a = b("Unknown eye drops"); var c = b("Unknown eye drops")
        a.evidence?.medication = .init(values:["name":"Unknown eye drops"])
        c.evidence?.medication = .init(values:["name":"Unknown eye drops"])
        XCTAssertNotEqual(MedicationIdentity.key(a),MedicationIdentity.key(c))
    }
    func testNamedDropsAcrossCaptureFormatsShareOneHistory() {
        var label = b("Label")
        label.evidence?.medication = .init(values: ["name": "PRP eye drops", "form": "Eye drops"])
        var mention = b("Mention")
        mention.evidence?.medication = .init(values: ["name": "PRP eye drops", "form": "eye drop"])
        let patient = SummaryEntry(category: .medications, title: "PRP eye drops",
                                   details: "Patient reports using drops as needed every two hours.")
        var specific = b("Specific strength")
        specific.evidence?.medication = .init(values: ["name": "PRP eye drops", "strength": "50%", "form": "eye drops"])
        let grouped = MedicationHistoryPresentation.group([label, mention, patient, specific].map { fact($0, id: $0.id.uuidString) })
        XCTAssertEqual(grouped.count, 2)
        XCTAssertTrue(grouped.contains { Set($0.occurrences.map(\.id)) == Set([label.id, mention.id, patient.id]) })
    }

    func testFillDoesNotEraseRecordedPrescriptionInstructionsAndConflictsRemainExplicit() {
        var prescription = b("Prescription source")
        prescription.evidence?.medication = .init(values:["name":"Example", "strength":"5mg", "form":"tablet", "instructions":"Take one tablet at night"])
        var fill = b("Fill source")
        fill.evidence?.medication = .init(values:["name":"Example", "strength":"5mg", "form":"tablet"])
        let grouped = MedicationHistoryPresentation.group([fact(prescription,id:"p"),fact(fill,id:"f")])[0]
        XCTAssertEqual(grouped.displayEntry.fields.first { $0.label == "Recorded instructions" }?.value,"Take one tablet at night")
        var changed = prescription
        changed.id = UUID(); changed.evidence?.medication = .init(values:["name":"Example", "strength":"5mg", "form":"tablet", "instructions":"Take one tablet in the morning"])
        let conflict = MedicationHistoryPresentation.group([fact(prescription,id:"p"),fact(changed,id:"c")])[0]
        XCTAssertEqual(conflict.displayEntry.fields.first { $0.label == "Recorded instructions" }?.value,"Varies across records — see history.")
        XCTAssertEqual(conflict.occurrences.count,2)
    }

}
