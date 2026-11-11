import XCTest
import PDFKit
@testable import SpeechSessionPersistence
final class StoryTemplateTests:XCTestCase {
    func testExplicitPatientNameAcrossRecords() {
        let name = StorySummaryDocument.recordedPatientName(in:)
        XCTAssertEqual(name(["Patient: Rivera, Alex", "Patient name: Alex Rivera"]), "Alex Rivera")
        XCTAssertNil(name(["Prescriber: Alex Rivera", "Patient: Not documented"]))
        XCTAssertNil(name(["Patient: Alex Rivera", "Patient: Morgan Li"]))
    }

    func testTemplateRequiresItsSectionsAndDoesNotContainExamplePatient() {
        let template=StorySummaryTemplate.practitioner
        XCTAssertFalse(template.prompt.contains("Morgan Lee"))
        XCTAssertNil(template.validatedText("A short answer without sections."))
        let text=template.sections.map{"## "+$0+"\nNot documented in the available saved details."}.joined(separator:"\n\n")
        XCTAssertNotNil(template.validatedText(text))
        XCTAssertNil(template.validatedText(text+"\n## Invented section\nExtra"))
    }
    func testCheckedSummaryWithRestyledHeadingsRetainsFactsAndRejectsOmittedSections() {
        let template=StorySummaryTemplate.practitioner
        let sections=template.sections.map { "**"+$0+":**\nA recorded observation." }
        let checked=template.validatedText(sections.joined(separator:"\n"))
        XCTAssertEqual(checked,template.sections.map{"## "+$0+"\nA recorded observation."}.joined(separator:"\n"))
        XCTAssertNil(template.validatedText(sections.dropLast().joined(separator:"\n")))
    }
    func testSummaryPublicationIsSeparateAndCancellationWins() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(storageDirectory:root)
        try await store.saveStoryNarrativeText("Patient's unchanged overview.")
        let template=StorySummaryTemplate.practitioner
        let text=template.sections.map{"## "+$0+"\nNot documented in the available saved details."}.joined(separator:"\n\n")
        let summary=StorySharedSummary(templateID:template.rawValue,text:text,evidence:[])
        let id=try await store.addStoryMessage(role:"system",text:"Share template: "+template.rawValue,state:"queued")
        try await store.completeStorySharedSummary(id,summary:summary)
        let reopened=try SessionStore(storageDirectory:root)
        let workspace=try await reopened.storyWorkspace()
        XCTAssertEqual(workspace.sharedSummary?.text,text)
        XCTAssertEqual(workspace.narrativeText,"Patient's unchanged overview.")
        XCTAssertFalse(workspace.messages.contains{$0.role=="user" || $0.role=="assistant"})
        let cancelled=try await store.addStoryMessage(role:"system",text:"Share template",state:"queued")
        try await store.cancelStoryOperation(cancelled)
        do {try await store.completeStorySharedSummary(cancelled,summary:summary);XCTFail("Cancelled work published")} catch {}
    }
    func testFullSnapshotDoesNotUseCurrentPlanQueryOrDropFactsAtOneHundred() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(storageDirectory:root),id=UUID()
        let entries=(0..<110).map {SummaryEntry(category:.otherNotes,title:"Distinct patient report number \($0)",sourceSessionID:id,origin:.userAdded)}
        try await store.save([Session(id:id,transcript:"Synthetic record",summaryEntries:entries)])
        let evidence=try await store.storySummaryEvidence()
        let text=evidence.map(\.text).joined(separator:"\n")
        for index in 0..<110 {XCTAssertTrue(text.contains("Distinct patient report number \(index)"))}
        XCTAssertTrue(text.contains("Not explicitly adopted"))
    }
    func testLargeHistoryBatchesPreserveEveryEvidenceItemAndRespectWireBudget() throws {
        let items=(0..<250).map {StoryEvidence(id:"E\($0)",text:String(repeating:"Quoted \"value\" 🩺\n",count:200),recordID:UUID(),title:"Source \( $0 )")}
        let batches=try StorySummaryBatching.batches(items)
        XCTAssertGreaterThan(batches.count,1)
        XCTAssertEqual(batches.flatMap{$0},items)
        for batch in batches {
            XCTAssertLessThanOrEqual(batch.count,100)
            XCTAssertLessThanOrEqual(batch.reduce(0){$0+$1.text.count},70000)
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(batch).count,120000)
        }
        // Even worst-case Unicode intermediate answers can be combined, so reduction terminates.
        let summaries=(0..<4).map{StoryEvidence(id:"E\($0)",text:String(repeating:"🩺",count:12000),recordID:nil,title:"Partial")}
        XCTAssertLessThan(try StorySummaryBatching.batches(summaries).count,summaries.count)
    }
    func testSummaryStagesSurviveReopenAndParentCancellationPreventsPublication() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(storageDirectory:root)
        let parent=try await store.addStoryMessage(role:"system",text:"Summary",state:"queued")
        let first=try await store.prepareSummaryStage(parentID:parent,stage:"0:0")
        let text=StorySummaryTemplate.practitioner.sections.map{"## "+$0+"\nNot documented in the available saved details."}.joined(separator:"\n\n")
        let original=StoryEvidence(id:"E1",text:"Source fact",recordID:UUID(),title:"Original")
        try await store.completeSummaryStage(first.id,text:text,evidence:[original])
        let reopened=try SessionStore(storageDirectory:root)
        let resumed=try await reopened.prepareSummaryStage(parentID:parent,stage:"0:0")
        XCTAssertEqual(resumed.id,first.id);XCTAssertEqual(resumed.state,"completed")
        XCTAssertEqual(resumed.evidence,[original]);XCTAssertEqual(resumed.text,text)
        let second=try await reopened.prepareSummaryStage(parentID:parent,stage:"0:1")
        try await reopened.cancelStoryOperation(parent)
        let cancelled=try await reopened.storyWorkspace().messages.first{$0.id==second.id}
        XCTAssertEqual(cancelled?.state,"cancelled");XCTAssertEqual(cancelled?.cancellationPending,true)
        do {try await reopened.completeSummaryStage(second.id,text:text,evidence:[original]);XCTFail("Late stage published")} catch {}
        do {_ = try await reopened.prepareSummaryStage(parentID:parent,stage:"0:2");XCTFail("Cancelled parent started work")} catch {}
    }
    func testPatientNameIsExplicitAndSavedWithoutChangingClinicalText() async throws {
        XCTAssertNil(StorySummaryDocument.patientName(in:"## Clinical Snapshot\nDr. Example recommended follow-up."))
        XCTAssertNil(StorySummaryDocument.patientName(in:"Patient name: Not documented"))
        XCTAssertEqual(StorySummaryDocument.patientName(in:"Patient name: Synthetic Patient\n## Clinical Snapshot"),"Synthetic Patient")
        XCTAssertEqual(StorySummaryDocument.body("Patient name: Synthetic Patient\n## Clinical Snapshot"),"## Clinical Snapshot")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(storageDirectory:root)
        let text=StorySummaryTemplate.practitioner.sections.map{"## "+$0+"\nNot documented in the available saved details."}.joined(separator:"\n")
        let id=try await store.addStoryMessage(role:"system",text:"Summary",state:"queued")
        try await store.completeStorySharedSummary(id,summary:StorySharedSummary(templateID:"practitioner-v1",text:text,evidence:[]))
        try await store.setSharedSummaryPatientName("Synthetic Patient")
        let saved=try await store.storyWorkspace().sharedSummary
        XCTAssertEqual(saved?.patientName,"Synthetic Patient");XCTAssertEqual(saved?.text,text)
        let data=try StorySummaryPDF.render(text:text,title:"Practitioner summary",generatedAt:Date(),patientName:saved?.patientName)
        let pdf=try XCTUnwrap(PDFDocument(data:data))
        XCTAssertGreaterThan(pdf.pageCount,0)
        XCTAssertTrue(pdf.page(at:0)?.string?.contains("Synthetic Patient") == true)
        XCTAssertFalse(pdf.page(at:0)?.string?.contains("Prepared") == true)
    }
    func testSharedPresentationParsesSubheadsAndTablesWithoutDroppingMalformedLines() {
        let blocks=StorySummaryDocument.blocks("## History\n### Earlier events\n| Date | Event |\n| --- | --- |\n| 2024 | Recorded event |\n| Incorrect cell count |\nLegacy paragraph")
        XCTAssertEqual(blocks,[.heading("History",level:2),.heading("Earlier events",level:3),.table(headers:["Date","Event"],rows:[["2024","Recorded event"]]),.paragraph("Part of this table is incomplete in the saved summary."),.paragraph("Legacy paragraph")])
    }
    func testPDFTablesRepeatHeadersAndPreserveLongCellsAcrossPages() throws {
        let rows=(0..<50).map{"| Date \($0) | Recorded event \($0), with timing, uncertainty and attribution retained. |"}.joined(separator:"\n")
        let long=String(repeating:"Long cell context and qualifier. ",count:300)+"LAST CELL WORDS"
        let text="## Comprehensive Health History\n| Date / period | Health events and course |\n| --- | --- |\n"+rows+"\n| Final date | "+long+" |"
        let pdf=try XCTUnwrap(PDFDocument(data:StorySummaryPDF.render(text:text,title:"Synthetic pagination check",generatedAt:Date(timeIntervalSince1970:0))))
        XCTAssertGreaterThan(pdf.pageCount,2)
        for index in 0..<pdf.pageCount {XCTAssertTrue(pdf.page(at:index)?.string?.contains("Health events and course") == true)}
        let extracted=(0..<pdf.pageCount).compactMap{pdf.page(at:$0)?.string}.joined(separator:"\n")
        for index in 0..<50 {XCTAssertTrue(extracted.contains("Recorded event \(index),"))}
        XCTAssertTrue(extracted.contains("LAST CELL WORDS"))
    }
    func testFormattedSummaryPreview() throws {
        let text="""
        ## Clinical Snapshot
        Synthetic example: intermittent discomfort affects daily activity. The patient reports improvement over time; the record does not establish a treatment effect.
        ### Patient priorities
        Understand the recorded plan and prepare questions for the next visit.
        ## Care Coordination Summary
        ### Allergies and sensitivities
        Not documented in the available saved details.
        ### Actions and responsibilities
        A clinician recommended a symptom diary. Patient adoption is not documented.
        ## Appointment Preparation Brief
        ### Questions
        Review the symptom diary and clarify the timing of follow-up.
        ## Comprehensive Health History
        | Date / period | Health events and course |
        | --- | --- |
        | January 2025 | Intermittent discomfort first recorded; timing is approximate. |
        | June 2025 | Symptoms described as less frequent. No cause established. |
        | Date unknown | Previous investigation described as negative; it is not an active diagnosis. |
        ### Background
        Family history is not documented in the available saved details.
        ## Condition-Specific Summary
        ### Recorded discomfort
        The patient describes an intermittent course with some improvement. No confirmed diagnosis is documented.
        ## Care Plan & Interventions
        ### Medications
        | Intervention / purpose | Dose and timing | Response / recorded plan |
        | --- | --- | --- |
        | Example recorded medication; purpose not documented | Dose not documented; historical use reported | Current use unknown. No treatment effect established. |
        ### Lifestyle plans
        A clinician recommended keeping a symptom diary if symptoms persist. Adoption is not documented.
        ### Previous treatments and responses
        | Treatment / dates | Response | Status |
        | --- | --- | --- |
        | Prior activity change; date unknown | Patient reports no clear change | No longer followed, according to the patient |
        ## Labs & Investigations
        ### Results
        | Test / date | Result and units | Reference interval | Recorded interpretation |
        | --- | --- | --- | --- |
        | Example test; June 2025 | 12 units, as recorded | Not documented | Not documented |
        ### Investigations and follow-up
        Follow-up was recommended if symptoms persisted; no due date was documented.
        """
        XCTAssertNotNil(StorySummaryTemplate.practitioner.validatedText(text))
        let data=try StorySummaryPDF.render(text:text,title:"Practitioner summary",generatedAt:Date(timeIntervalSince1970:0),patientName:"Synthetic Patient")
        XCTAssertNotNil(PDFDocument(data:data))
        if let path=ProcessInfo.processInfo.environment["STORY_SUMMARY_PREVIEW_PATH"] {try data.write(to:URL(fileURLWithPath:path))}
    }
    @MainActor func testSavedLabSeriesAndPrintedValues() throws {
        func reading(_ name: String, _ result: String, _ date: String?, _ units: String = "µg/L") throws -> StoryLabReading {
            var entry = SummaryEntry(category: .testsAndLabs, title: name, fields: [
                .init(label: "Result", value: result), .init(label: "Units", value: units),
                .init(label: "Reference range", value: "30–150")
            ], sourceSessionID: UUID(), sourceDate: Date())
            entry.evidence = ClinicalEvidence()
            entry.evidence?.eventDate = date
            return try XCTUnwrap(StoryLabReading(entry))
        }
        let first = try reading("Example marker", "11", "2026-08-12")
        let second = try reading("Example marker", "15", "2026-09-16")
        let latest = try reading("Example marker", "18", "2026-10-28")
        let undated = try reading("Example marker", "<5", nil)
        let alternate = try reading("Example marker", "12", "2026-08-13", "mg/dL")
        let observations = [second, undated, alternate, latest, first]
        let series = StoryLabSeries.grouped(observations)
        XCTAssertEqual(series.count, 3)
        XCTAssertNil(undated.number)
        XCTAssertNil(undated.date)
        let trend = try XCTUnwrap(series.first { !$0.points.isEmpty })
        XCTAssertEqual(trend.points.map(\.result), ["11","15","18"])
        XCTAssertEqual(trend.latest.recordID, latest.recordID)
        let conflict = try reading("Example marker","19","2026-10-28")
        XCTAssertTrue(StoryLabSeries.grouped([first, latest, conflict]).allSatisfy { $0.points.isEmpty })
        var summary = StorySharedSummary(templateID:"practitioner-v1", text:"## Labs & Investigations\n### Investigations and follow-up\nThe report records a follow-up appointment.", evidence:[])
        summary.labReadings = observations
        let saved = try JSONDecoder().decode(StorySharedSummary.self, from: JSONEncoder().encode(summary))
        let data = try StorySummaryPDF.renderSummary(saved,title:"Practitioner summary",patientName:"Synthetic patient")
        let pdf = try XCTUnwrap(PDFDocument(data:data))
        let text = try XCTUnwrap(pdf.string)
        for value in ["11 µg/L", "15 µg/L", "18 µg/L", "<5 µg/L", "12 mg/dL", "Date unknown", "30–150", "follow-up appointment"] {
            XCTAssertTrue(text.contains(value),value)
        }
        if let path = ProcessInfo.processInfo.environment["STORY_LAB_CHART_PREVIEW"] {
            try data.write(to:URL(fileURLWithPath:path))
        }
    }
    func testReopenOlderSummaryRecoversSavedPanelOnlyFromMatchingRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let record = UUID()
        var panel = SummaryEntry(category: .testsAndLabs, title: "Panel: Example A 20 mg/dL (reference 10-30); Example B 7 mg/dL (reference 5-9)", sourceSessionID: record)
        panel.evidence = ClinicalEvidence()
        panel.evidence?.assessmentMethod = WholeHistoryPublication.version
        panel.evidence?.eventDate = "2026-09-15"
        let source = panel.title
        panel = SummaryVerification.sourceLinked(panel,source:source,evidence:source)
        try await store.save([Session(id:record,transcript:source,summaryEntries:[panel])])
        let currentSnapshot = try await store.storySummarySnapshot()
        XCTAssertEqual(currentSnapshot.labs.count, 2, String(describing: BArtifactPresentation.display(panel).fields))
        let input = try await store.storySummaryEvidence(legacyDates:true)
        let parent = try await store.addStoryMessage(role:"system",text:"Share template: practitioner-v1",state:"queued")
        _ = try await store.storyRequestBody(parent, proposed:String(decoding:try JSONEncoder().encode(input),as:UTF8.self))
        let stage = try await store.prepareSummaryStage(parentID:parent,stage:"0:0")
        let text = StorySummaryTemplate.practitioner.sections.map{"## "+$0+"\nRecorded details."}.joined(separator:"\n")
        try await store.completeSummaryStage(stage.id,text:text,evidence:input)
        try await store.completeStorySharedSummary(parent,summary:StorySharedSummary(templateID:"practitioner-v1",text:text,evidence:input))
        let recovered = try await store.recoveredStorySharedSummary()
        XCTAssertEqual(Set(recovered?.labReadings?.map(\.valueLabel) ?? []), ["20 mg/dL","7 mg/dL"])
        panel.title = "Example A 99 mg/dL (reference 10-30)"
        try await store.save([Session(id:record,transcript:"Edited",summaryEntries:[panel])])
        let changed = try await store.recoveredStorySharedSummary()
        XCTAssertNil(changed?.labReadings)
    }
    func testTruncatedLabTableIsNotPublishable() {
        let template = StorySummaryTemplate.practitioner
        let preamble = template.sections.map { "## " + $0 + "\nRecorded information." }.joined(separator:"\n")
        let text = preamble + "\n### Results\n| Test / date | Result |\n|---|---|\n| Estra"
        XCTAssertNil(template.validatedText(text))
        XCTAssertTrue(StorySummaryDocument.blocks(text).contains(.paragraph("Part of this table is incomplete in the saved summary.")))
        XCTAssertFalse(StorySummaryDocument.hasBrokenTable("| Test | Result |\n\n|---|---|\n\n| Example | 3 |"))
    }
    func testPDFPaginatesLongParagraphWithoutLosingLastLine() throws {
        let body=(0..<300).map{"Unique line \($0): Recorded information with timing and context."}.joined(separator:"\n")+"\nEND OF SUMMARY"
        let data=try StorySummaryPDF.render(text:"## Clinical Snapshot\n"+body,title:"Synthetic summary",generatedAt:Date(timeIntervalSince1970:0))
        let pdf=try XCTUnwrap(PDFDocument(data:data))
        XCTAssertGreaterThan(pdf.pageCount,1)
        let text=(0..<pdf.pageCount).compactMap{pdf.page(at:$0)?.string}.joined(separator:"\n")
        XCTAssertTrue(text.contains("Unique line 0:"));XCTAssertTrue(text.contains("Unique line 299:"));XCTAssertTrue(text.contains("END OF SUMMARY"))
    }
}
