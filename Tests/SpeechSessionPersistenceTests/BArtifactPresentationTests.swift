import XCTest
@testable import SpeechSessionPersistence

final class BArtifactPresentationTests: XCTestCase {
    private func b(_ title: String, _ category: SummaryEntryCategory = .practitionerContact) -> SummaryEntry {
        var e = SummaryEntry(category:category,title:title,details:"Recorded status: reported\nAttribution: Patient\nRecorded date: ")
        var evidence = ClinicalEvidence(); evidence.assessmentMethod = WholeHistoryPublication.version
        evidence.eventDate = ""; evidence.practitioner = "Patient"; e.evidence = evidence; return e
    }
    private func fact(_ e: SummaryEntry) -> HealthFact {
        HealthFact(id:e.id.uuidString,occurrences:[e],preference:.init(id:e.id.uuidString),topicIDs:[])
    }
    func testNarrativeContactsHaveNamesAndKeepTheirMeaning() {
        for (text,name) in [
            ("Identifies Dr. Bama as the doctor treating this eye condition; spelling as transcribed","Dr. Bama"),
            ("Invoice identifies Dr. Jessica Yang","Dr. Jessica Yang"),
            ("Patient identifies Dr. Patrick Mitchell as the original retina doctor who performed the surgeries","Dr. Patrick Mitchell"),
            ("Patient reports Dr. Polis was involved in the evaluation in which uveitis was eliminated","Dr. Polis")
        ] {
            let original = b(text), displayed = fact(original).displayEntry
            XCTAssertEqual(displayed.title,name)
            XCTAssertTrue(displayed.details.contains(text))
            XCTAssertNil(displayed.evidence?.eventDate)
            XCTAssertNil(displayed.evidence?.practitioner)
            XCTAssertEqual(original.title,text)
            XCTAssertFalse(displayed.fields.contains { $0.value.isEmpty })
            XCTAssertEqual(fact(original).title,name)
        }
    }
    func testContactChannelsUseOnlyTheirOwnFactNotOtherSourceContacts() {
        var e = b("Dr. Jane Doe; phone: 403-555-0123; email: jane@example.org; clinic: Example Clinic; address: 1 Main Street")
        e.sourceExcerpt = "Dr. Other Person phone 416-555-9999, 99 Other Avenue"
        let d = fact(e).displayEntry
        XCTAssertEqual(d.title,"Dr. Jane Doe")
        XCTAssertEqual(d.fields.first { $0.label == "Phone" }?.value,"403-555-0123")
        XCTAssertEqual(d.fields.first { $0.label == "Organization" }?.value,"Example Clinic")
        XCTAssertEqual(d.fields.first { $0.label == "Address" }?.value,"1 Main Street")
        XCTAssertFalse(d.fields.contains { $0.value.contains("9999") })
        let signed = fact(b("Report electronically signed by Jay Zelazo MD; phone 403-555-0123. Report identifies Dr. Brett Poulis as ordering clinician.")).displayEntry
        XCTAssertEqual(signed.title,"Care team contact — check original")
        XCTAssertFalse(signed.fields.contains { $0.label == "Phone" })
        XCTAssertEqual(fact(b("Pharmacy Example #123 is named as pharmacy on the fill records.")).title,"Pharmacy Example #123")
        XCTAssertEqual(fact(b("Physiotherapist offered a referral to Stephanie, described as knowledgeable.")).title,"Stephanie")
        let ambiguous = fact(b("Dr. Jane Doe and Dr. John Roe; 403-555-0123")).displayEntry
        XCTAssertEqual(ambiguous.title,"Care team contact — check original")
        XCTAssertFalse(ambiguous.fields.contains { $0.label == "Phone" })
    }
    func testContactNavigationNormalizesNamesWithoutMergingPeopleOrLocations() {
        let a = fact(b("Invoice identifies Dr. Jane Doe"))
        let c = fact(b("Patient reports Dr. Jane Doe was consulted"))
        XCTAssertEqual(ContactHistoryPresentation.group([a,c]).count,2)
        let groups = ContactPresentationGroup.groups(facts:[a,c],members:[])
        XCTAssertEqual(groups.count,1); XCTAssertEqual(groups[0].facts.count,2)
        var separated = c; separated.occurrences[0].evidence?.combinationExcluded = true
        XCTAssertEqual(ContactPresentationGroup.groups(facts:[a,separated],members:[]).count,2)
    }
    func testEveryNonActionCategoryKeepsClinicalMeaningAndRemovesEmptyMetadata() {
        let text = "Patient reports no prior reaction, but a possible delayed reaction after the second exposure remains uncertain; do not infer resolution or current disease."
        for category in SummaryEntryCategory.allCases where ![.medications,.practitionerContact,.carePlan,.followUp].contains(category) {
            let e = b(text,category), d = fact(e).displayEntry
            XCTAssertEqual(d.title,category.displayTitle)
            XCTAssertTrue(d.details.contains(text),category.rawValue)
            XCTAssertFalse(d.details.contains("Recorded status:"))
            XCTAssertNil(d.evidence?.eventDate)
            XCTAssertEqual(e.title,text)
        }
    }
    func testLabelledLabsAllergiesVaccinesAndSymptomsKeepValuesAndQualifiers() {
        for (category,text,heading,label,value) in [
            (SummaryEntryCategory.testsAndLabs,"Test: Example assay; result: <0.2; units: mg/L; reference range: 0–1; interpretation: negative","Example assay","Result","<0.2"),
            (.allergies,"Allergen: Example; reaction: rash; severity: uncertain","Example","Reaction","rash"),
            (.vaccinations,"Vaccine: Example vaccine; dose: second; site: left arm","Example vaccine","Dose","second"),
            (.symptoms,"Symptom: left eye pain; onset: yesterday; severity: intermittent","left eye pain","Onset","yesterday")
        ] {
            let d = fact(b(text,category)).displayEntry
            XCTAssertEqual(d.title,heading)
            XCTAssertTrue(d.fields.contains { $0.label == label && $0.value == value })
            XCTAssertTrue(HealthDetailPresentation.remainingDetails(d).isEmpty)
        }
    }
    func testActionsRetainTheirSpecializedContractWithoutRawMetadata() {
        var e = b("If symptoms return, call the clinic",.followUp)
        e.evidence?.careInstruction = .init(instruction:e.title,schedule:"If symptoms return")
        e.evidence?.careInstruction?.owner = "Patient"
        e.evidence?.careInstruction?.consideration = "Conditional, not an instruction to call now"
        let d = fact(e).displayEntry
        XCTAssertEqual(d.evidence?.careInstruction,e.evidence?.careInstruction)
        XCTAssertFalse(CareInstructionPresentation.supportingText(e).joined().contains("Attribution:"))
        XCTAssertEqual(CareInstructionPresentation.instruction(d),e.title)
    }
    func testReportLabSyntaxKeepsUnitsRangesAndCommentsAndVaccineFillsStayFills() {
        let text="Hemoglobin A1c 5.1% (reference 4.3–5.9); final, no abnormality marked. General guidance is not a patient-specific plan."
        let d=fact(b(text,.testsAndLabs)).displayEntry
        XCTAssertEqual(d.title,"Hemoglobin A1c")
        XCTAssertEqual(d.fields.first{$0.label=="Result"}?.value,"5.1")
        XCTAssertEqual(d.fields.first{$0.label=="Units"}?.value,"%")
        XCTAssertEqual(d.fields.first{$0.label=="Reference range"}?.value,"4.3–5.9")
        XCTAssertTrue(d.details.contains("no abnormality marked"))
        XCTAssertTrue(d.details.contains("not a patient-specific plan"))
        let named=fact(b("Vitamin D 25-Hydroxy 65 nmol/L (reference 50–150); final.",.testsAndLabs)).displayEntry
        XCTAssertFalse(named.fields.contains { $0.label=="Result" && $0.value=="25" })
        let v=fact(b("Fill: Example vaccine; Pharmacy; filled Nov 10, 2025.",.vaccinations)).displayEntry
        XCTAssertEqual(v.title,"Example vaccine")
        XCTAssertEqual(v.fields.first{$0.label=="Record type"}?.value,"Dispensing record")
        XCTAssertFalse(v.fields.contains{$0.value=="administered"})
        let administered=fact(b("Example vaccine recorded as administered.",.vaccinations)).displayEntry
        XCTAssertEqual(administered.title,"Example vaccine")
        XCTAssertEqual(administered.fields.first{$0.label=="Recorded status"}?.value,"administered")
    }
    func testPatientEditsAndLegacyAEntriesAreUnchanged() {
        var e = b("Invoice identifies Dr. Jane Doe")
        e.origin = .userEdited; XCTAssertEqual(BClinicalPresentation.display(e),e)
        e.origin = .generated; e.evidence?.assessmentMethod = "independent-check"
        XCTAssertEqual(BClinicalPresentation.display(e),e)
    }
    func testShareExportIncludesUnknownStatusesAndEverySelectedFact() {
        let facts = [fact(b("Example 5 mg tablet",.medications)),fact(b("No rash reported",.symptoms)),fact(b("Dr. Jane Doe"))]
        let statuses = HealthFactExportPresentation.statuses(facts)
        XCTAssertTrue(statuses.contains("Current use unknown"))
        XCTAssertTrue(statuses.contains("Status unknown"))
        XCTAssertEqual(statuses.flatMap { status in facts.filter { CareInstructionPresentation.status($0) == status } }.count,facts.count)
    }
}
