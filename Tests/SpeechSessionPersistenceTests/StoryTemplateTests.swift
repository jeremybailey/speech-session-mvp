import XCTest
import PDFKit
import CoreText
@testable import SpeechSessionPersistence
final class StoryTemplateTests:XCTestCase {
    func testNewHandoffRequiresFragmentsAndPreservesQualifiers() {
        let template = StorySummaryTemplate.practitioner
        func handoff(_ bullet: String) -> String {
            template.sections.enumerated().map { index, heading in
                "## " + heading + (index == 0 ? "\n- " + bullet : "")
            }.joined(separator: "\n")
        }
        XCTAssertNotNil(template.validatedHandoff(handoff("Membrane sweep — declined today, possible reconsideration next week")))
        XCTAssertNotNil(template.validatedHandoff(handoff("Vitamin K — tentative preference for injection")))
        XCTAssertNil(template.validatedHandoff(handoff("The patient reports improvement.")))
        XCTAssertNil(template.validatedHandoff(handoff("Vision — the patient reports improvement")))
        XCTAssertNil(template.validatedHandoff(handoff("Vision — improvement is slow")))
        XCTAssertNil(template.validatedHandoff(handoff("A clinician reported — receiving a referral")))
        XCTAssertNil(template.validatedHandoff(handoff("Vision — Patient  reports slow improvement")))
        XCTAssertNotNil(template.validatedHandoff(handoff("Vision — slow improvement per patient")))
    }

    func testHandoffRetainsDistinctConcisePointsBeyondTwoHundredWords() {
        let template = StorySummaryTemplate.practitioner
        let raw = template.sections.enumerated().map { index, heading in
            "## " + heading + (index == 0 ? "\n" + (0..<30).map { "- Concern \($0) — distinct relevant concern w/ ongoing clinical follow-up" }.joined(separator: "\n") : "")
        }.joined(separator: "\n")
        XCTAssertNotNil(template.validatedText(raw))
        XCTAssertNotNil(template.validatedHandoff(raw))
    }

    func testShareItemsSplitWithTopicAndKeepQuotedSemicolons() {
        XCTAssertEqual(StorySummaryDocument.practitionerBlocks(
            "## Clinical Snapshot\n- Eye care — PRP drops; slow improvement\n- Follow-up booked; questions for Nicole",
            hasAbnormalLabs: false), [
                .heading("Clinical Snapshot", level: 2),
                .bullet("Eye care — PRP drops"),
                .bullet("Eye care — slow improvement"),
                .bullet("Follow-up booked"),
                .bullet("questions for Nicole")
            ])
        let quoted = "- Preference — “maybe; next week” (conditional; timing uncertain)"
        XCTAssertEqual(StorySummaryDocument.practitionerBlocks(quoted, hasAbnormalLabs: false),
                       [.bullet(String(quoted.dropFirst(2)))])
    }

    func testShareShorthandUsesWholeWordsAndProtectsQuotes() {
        XCTAssertEqual(StorySummaryDocument.shareShorthand("Pain with walking, without weakness"), "Pain w/ walking, without weakness")
        XCTAssertEqual(StorySummaryDocument.shareShorthand("“Pain with walking”"), "“Pain with walking”")
        XCTAssertEqual(StorySummaryDocument.practitionerBlocks("- Follow-up — with Nicole", hasAbnormalLabs: false),
                       [.bullet("Follow-up — w/ Nicole")])
    }

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
    func testShortHandoffQualifierUsesRemainingBulletBudget() {
        let template=StorySummaryTemplate.practitioner
        let line="- Follow-up — booked for next Tuesday morning with the care team to discuss remaining questions"
        let text=template.sections.enumerated().map { index, heading in "## "+heading+(index == 0 ? "\n"+line : "") }.joined(separator:"\n\n")
        XCTAssertNotNil(template.validatedHandoff(text))
        XCTAssertNil(template.validatedHandoff(text.replacingOccurrences(of:line,with:line+" and additional treatment options")))
    }
    func testFailedShareRecoveryRetainsFrozenRequestAndOnlyResumesLatest() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=try SessionStore(storageDirectory:root)
        let template=StorySummaryTemplate.practitioner.rawValue
        let first=try await store.addStoryMessage(role:"system",text:"Share template: "+template,state:"queued")
        _ = try await store.storyRequestBody(first,proposed:"frozen synthetic source")
        try await store.failStorySharedSummary(first)
        let resumed=try await store.resumeFailedStorySharedSummary(first,templateID:template)
        XCTAssertTrue(resumed)
        let workspace=try await store.storyWorkspace()
        XCTAssertEqual(workspace.messages.first?.requestJSON,"frozen synthetic source")
        XCTAssertEqual(workspace.messages.first?.state,"queued")
        try await store.failStorySharedSummary(first)
        let second=try await store.addStoryMessage(role:"system",text:"Share template: "+template,state:"queued")
        _ = try await store.storyRequestBody(second,proposed:"new frozen source")
        let older=try await store.resumeFailedStorySharedSummary(first,templateID:template)
        XCTAssertFalse(older)
        try await store.cancelStoryOperation(second)
        let cancelled=try await store.resumeFailedStorySharedSummary(second,templateID:template)
        XCTAssertFalse(cancelled)
        for reason in ["incomplete","provider_outcome_unknown","provider_failed","invalid_summary_output","budget_exhausted"] {
            XCTAssertTrue(SummaryWorkflowFailureMessage.keepsUnfinishedWork(reason:reason))
        }
        for reason in ["expired","cancelled","superseded"] {
            XCTAssertFalse(SummaryWorkflowFailureMessage.keepsUnfinishedWork(reason:reason))
        }
    }
    func testSummaryBulletDateMetadataRoundTrips() throws {
        var summary=StorySharedSummary(templateID:"practitioner-v1",text:"",evidence:[])
        summary.bulletDates=[StorySummaryBulletDate(text:"Follow-up — review with care team",labels:["Record: 20 Nov 2026","Date: 2026-09-15","Date: 2026-10-20"])]
        let restored=try JSONDecoder().decode(StorySharedSummary.self,from:JSONEncoder().encode(summary))
        XCTAssertEqual(restored.dates(for:"Follow-up — review w/ care team"),["20 Oct 2026"])
        XCTAssertEqual(restored.dates(for:"Unrelated bullet"),[])
        XCTAssertEqual(StorySummaryBulletDate.displayDate(["Record: 20 Nov 2026","Date unknown","Date: next week","Date: 2026-02-30"]),"Recorded 20 Nov 2026")
        XCTAssertNil(StorySummaryBulletDate.displayDate(["Date unknown","Record: unknown","Date: 2026-02-30"]))
        XCTAssertNil(StorySummaryBulletDate.displayDate([]))
        XCTAssertEqual(StorySummaryBulletDate.displayDate(["Record: 2024","Record: 2026-09"]),"Recorded Sep 2026")
        XCTAssertEqual(StorySummaryBulletDate.displayDate(["Record: 2026-11-20","Record: 2026-11-15"]),"Recorded 20 Nov 2026")
        XCTAssertEqual(StorySummaryBulletDate.displayDate(["Date: 2024","Record: 2026-11-20"]),"2024")
        XCTAssertEqual(StorySummaryBulletDate.displayDate(["Date: 2024","Date: 2026-09"]),"Sep 2026")
        let pdf=try StorySummaryPDF.render(text:"## Clinical Snapshot\n- Follow-up — review w/ care team",title:"Practitioner summary",generatedAt:Date(timeIntervalSince1970:0),bulletDates:restored.bulletDates ?? [])
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data:pdf)?.string).contains("20 Oct 2026"))
        let longBullet="Follow-up — review outstanding questions and treatment options w/ the care team at the next appointment"
        let fallbackPDF=try StorySummaryPDF.render(text:"## Clinical Snapshot\n- Follow-up — review w/ care team\n- " + longBullet + "\n- Support — family available",title:"Practitioner summary",generatedAt:Date(timeIntervalSince1970:0),bulletDates:[
            StorySummaryBulletDate(text:"Follow-up — review w/ care team",labels:["Record: 2026-11-15"]),
            StorySummaryBulletDate(text:longBullet,labels:["Record: 2026-11-20"]),
            StorySummaryBulletDate(text:"Support — family available",labels:["Record: 2026-09"])])
        let extracted=try XCTUnwrap(PDFDocument(data:fallbackPDF)?.string).replacingOccurrences(of:"\u{00a0}",with:" ")
        XCTAssertTrue(extracted.contains("Recorded 15 Nov 2026"))
        XCTAssertTrue(extracted.contains("Recorded 20 Nov 2026"))
        XCTAssertTrue(extracted.contains("Recorded Sep 2026"))
        if let path=ProcessInfo.processInfo.environment["STORY_DATE_PREVIEW"] {try fallbackPDF.write(to:URL(fileURLWithPath:path))}
    }
    func testSummarySourceRevisionIgnoresOrderButPreservesContentAndDuplicates() throws {
        let a=StoryEvidence(id:"a",text:"Synthetic concern",recordID:nil,title:"Record")
        let b=StoryEvidence(id:"b",text:"Synthetic follow-up",recordID:nil,title:"Record")
        let labA=try XCTUnwrap(StoryLabReading(SummaryEntry(category:.testsAndLabs,title:"Example A",fields:[.init(label:"Result",value:"10")],sourceSessionID:UUID())))
        let labB=try XCTUnwrap(StoryLabReading(SummaryEntry(category:.testsAndLabs,title:"Example B",fields:[.init(label:"Result",value:"20")],sourceSessionID:UUID())))
        let labs=StorySummarySnapshot(evidence:[a,b],labs:[labA,labB])
        XCTAssertTrue(try labs.hasSameSources(as:StorySummarySnapshot(evidence:[a,b],labs:[labB,labA])))
        XCTAssertFalse(try labs.hasSameSources(as:StorySummarySnapshot(evidence:[a,b],labs:[labA])))
        let original=StorySummarySnapshot(evidence:[a,b],labs:[])
        var dated=a;dated.timelineLabel="Record: 20 Nov 2026"
        XCTAssertTrue(try original.hasSameSources(as:StorySummarySnapshot(evidence:[dated,b],labs:[])))
        XCTAssertTrue(try original.hasSameSources(as:StorySummarySnapshot(evidence:[b,a],labs:[])))
        XCTAssertFalse(try original.hasSameSources(as:StorySummarySnapshot(evidence:[a,a,b],labs:[])))
        let changed=StoryEvidence(id:"b",text:"Changed follow-up",recordID:nil,title:"Record")
        XCTAssertFalse(try original.hasSameSources(as:StorySummarySnapshot(evidence:[a,changed],labs:[])))
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
        XCTAssertTrue(pdf.page(at:0)?.string?.contains("Prepared") == true)
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
    func testShareLabNamesAndDuplicateImportsKeepDistinctMeasurements() throws {
        let record=UUID()
        func reading(_ name:String, _ value:String, _ date:String, _ range:String="", _ source:UUID?=nil) throws -> StoryLabReading {
            var entry=SummaryEntry(category:.testsAndLabs,title:name,fields:[
                .init(label:"Result",value:value),.init(label:"Units",value:"mmol/L"),
                .init(label:"Reference range",value:range),.init(label:"Interpretation",value:"High")
            ],sourceSessionID:source ?? record)
            entry.evidence=ClinicalEvidence();entry.evidence?.eventDate=date
            return try XCTUnwrap(StoryLabReading(entry))
        }
        let name="Low Density Lipoprotein Cholesterol (Calculated)"
        let first=try reading(name,"4.56","2025-07-11")
        let imported=try reading(name,"4.56","Jul 11, 2025 02:32 PM","<3.50")
        XCTAssertEqual(first.shareName,"LDL (calculated)")
        XCTAssertEqual(try reading("Non High Density Lipoprotein Cholesterol","5.09","2025-07-11").shareName,"Non-HDL")
        XCTAssertNotNil(imported.date)
        XCTAssertEqual(StoryLabReading.distinctForSharing([first,imported]),[imported])
        let different=try reading(name,"4.60","2025-07-11")
        let later=try reading(name,"4.56","Jul 11, 2025 03:32 PM","<3.50")
        let otherRecord=try reading(name,"4.56","2025-07-11","",UUID())
        XCTAssertEqual(StoryLabReading.distinctForSharing([imported,later,different,otherRecord]).count,4)
        let conflictingRange=try reading(name,"4.56","2025-07-11","<3.00")
        XCTAssertEqual(StoryLabReading.distinctForSharing([imported,conflictingRange]).count,2)
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
        let normal = try reading("Normal marker", "30", "2026-10-29")
        let unknown = try reading("Unknown marker", "pending", nil)
        let high = try reading("Low density lipoprotein", "155", "2026-10-29")
        XCTAssertNil(normal.abnormalLabel)
        XCTAssertNil(unknown.abnormalLabel)
        XCTAssertEqual(high.abnormalLabel, "↑ High")
        XCTAssertEqual(undated.abnormalLabel, "↓ Low")
        XCTAssertTrue(latest.isImproving(in: [first, second, latest]))
        XCTAssertFalse(first.isImproving(in: [first, second, latest]))
        XCTAssertFalse(second.isImproving(in: [latest, alternate]))
        let highEarlier = try reading("High marker", "200", "2026-08-12")
        let highLater = try reading("High marker", "170", "2026-09-16")
        XCTAssertTrue(highLater.isImproving(in: [highEarlier, highLater]))
        let lowFalling = try reading("Example marker", "8", "2026-11-01")
        XCTAssertFalse(lowFalling.isImproving(in: [first, latest, lowFalling]))
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
        summary.labReadings = observations + [normal, unknown, high]
        let saved = try JSONDecoder().decode(StorySharedSummary.self, from: JSONEncoder().encode(summary))
        let data = try StorySummaryPDF.renderSummary(saved,title:"Practitioner summary",patientName:"Synthetic patient")
        let pdf = try XCTUnwrap(PDFDocument(data:data))
        let text = try XCTUnwrap(pdf.string)
        for value in ["11 µg/L", "15 µg/L", "18 µg/L", "<5 µg/L", "12 mg/dL", "LDL", "High", "Low", "30–150", "follow-up appointment"] {
            XCTAssertTrue(text.contains(value),value)
        }
        XCTAssertFalse(text.contains("Normal marker"))
        XCTAssertFalse(text.contains("Unknown marker"))
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
        var frozen=try await store.storySummarySnapshot()
        frozen.publicationSummary=recovered
        let retry=try await store.addStoryMessage(role:"system",text:"Share template: practitioner-v1",state:"queued")
        try await store.completeStorySharedSummary(retry,summary:try XCTUnwrap(recovered),expectedSnapshot:frozen)
        let conflict=try await store.addStoryMessage(role:"system",text:"Share template: practitioner-v1",state:"queued")
        try await store.setSharedSummaryPatientName("Edited name")
        do { try await store.completeStorySharedSummary(conflict,summary:try XCTUnwrap(recovered),expectedSnapshot:frozen);XCTFail("Patient edit overwritten") } catch {}
        // Restore the old summary to retain the original missing-lab recovery check.
        let restore=try await store.addStoryMessage(role:"system",text:"Share template: practitioner-v1",state:"queued")
        try await store.completeStorySharedSummary(restore,summary:StorySharedSummary(templateID:"practitioner-v1",text:text,evidence:input))
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
    func testBulletsRenderBesideClinicalValuesAndLegacyProse() throws {
        let text = "## Clinical Snapshot\n- Reported improvement after rest.\n• Follow-up pending.\nPrior paragraph."
        XCTAssertEqual(StorySummaryDocument.blocks(text), [.heading("Clinical Snapshot", level: 2),
            .bullet("Reported improvement after rest."), .bullet("Follow-up pending."), .paragraph("Prior paragraph.")])
        let data = try StorySummaryPDF.render(text: text, title: "Practitioner summary", generatedAt: Date())
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("Follow-up pending.") == true)
        XCTAssertTrue(pdf.string?.contains("•") == true)
    }

    func testCompactPractitionerHandoffFitsTwoPages() throws {
        let sections = [
            "The patient describes ankle stiffness after longer walks and intermittent headaches that interrupt desk work. The priority for the next visit is returning to a full shift and understanding which symptoms to track between appointments.",
            "Primary care coordinates follow-up with physiotherapy. The patient reported skin irritation with adhesive dressings. Medication allergies were not documented. The physiotherapist requested the prior imaging report before the next appointment.",
            "The patient wants to discuss how long stiffness lasts after walking, whether the exercise schedule still fits workdays, and what to bring to the next review. No appointment date was recorded.",
            "An ankle injury was documented in spring 2024. The patient returned to part-time desk work that summer and described greater walking tolerance the following winter. A later note documents a change to longer shifts. Exact dates for the work changes were not recorded.",
            "Ankle discomfort is described after prolonged standing, with stiffness the following morning. A later physiotherapy note reports improvement on stairs. Headaches were reported mainly at the end of longer shifts. The record does not establish a cause or connect the headaches to the ankle symptoms.",
            "The physiotherapist recommended a short home exercise routine on workdays if comfortable. The patient reports following it twice last week and missing one session because of travel. The recommendation and the reported activity are recorded separately. Earlier manual treatment was associated with brief relief according to the patient.",
            "An imaging report describes no acute fracture at the time of evaluation. The clinician requested review of the prior films if symptoms persisted. The record does not document whether that review occurred. The patient plans to bring the report to the next visit."
        ]
        let template = StorySummaryTemplate.practitioner
        let text = zip(template.sections, sections).map { "## " + $0 + "\n" + $1 }.joined(separator: "\n\n")
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SpeechSessionApp/BrandFonts")
        func font(_ file: String, size: CGFloat) throws -> CTFont {
            let url = fonts.appendingPathComponent(file)
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
            return CTFontCreateWithFontDescriptor(try XCTUnwrap(descriptors?.first), size, nil)
        }
        let title = try font("ebgaramond.ttf", size: 22)
        let body = try font("inter.ttf", size: 11)
        let typography = StorySummaryPDF.Typography(
            title: title, heading: CTFontCreateCopyWithSymbolicTraits(body, 14, nil, .boldTrait, .boldTrait) ?? body,
            body: body, ink: CGColor(gray: 0.2, alpha: 1), tableFill: CGColor(gray: 0.95, alpha: 1))
        let data = try StorySummaryPDF.render(text: text, title: template.title, generatedAt: Date(),
                                              patientName: "Example Patient", typography: typography)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertLessThanOrEqual(pdf.pageCount, 2)
        XCTAssertTrue(pdf.string?.contains("next visit.") == true)
        if let path = ProcessInfo.processInfo.environment["STORY_HANDOFF_PREVIEW"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    func testStyledHandoffPreservesBulletsDatesAndContinuationPages() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["ebgaramond","inter"] {
            CTFontManagerRegisterFontsForURL(root.appendingPathComponent("SpeechSessionApp/BrandFonts/"+name+".ttf") as CFURL,.process,nil)
        }
        let inter=CTFontCreateWithName("Inter-Regular" as CFString,11.5,nil)
        let heading=CTFontCreateCopyWithSymbolicTraits(inter,14,nil,.boldTrait,.boldTrait) ?? inter
        let typography=StorySummaryPDF.Typography(title:CTFontCreateWithName("EBGaramond-Regular" as CFString,32,nil),heading:heading,body:inter,
            ink:CGColor(red:0.282,green:0.239,blue:0.247,alpha:1),tableFill:CGColor(red:1,green:0.933,blue:0.812,alpha:1))
        let sections=[
            ("Clinical Snapshot",["Pregnancy — documented at the latest visit", "Lower-back pain — intermittent, especially while sitting", "Support — family available after birth"]),
            ("Care Coordination Summary",["Vitamin K — tentative preference for newborn injection", "Membrane sweep — declined today, possible reconsideration next week", "Castor oil — declined this time"]),
            ("Appointment Preparation Brief",["Next visit — booked w/ Nicole for the 19th at 10 a.m.", "Screening — bilirubin decision deferred pending newborn assessment"]),
            ("Comprehensive Health History",["Previous pregnancy — gastrointestinal discomfort following castor oil", "Oral vitamin K — previous dosing history uncertain"]),
            ("Care Plan & Interventions",["Testing — ultrasound and NST offered at 41 weeks if agreed", "Practical support — meal train arranged", "Visit questions — review outstanding concerns w/ care team"])]
        let text=sections.map { "## " + $0.0 + "\n" + $0.1.map{"- "+$0}.joined(separator:"\n") }.joined(separator:"\n\n")
        let dates=sections.flatMap{$0.1}.enumerated().map {StorySummaryBulletDate(text:$0.element,labels:[$0.offset % 2 == 0 ? "Date: 2026-11-15":"Record: 2026-11-15"])}
        let data=try StorySummaryPDF.render(text:text,title:"Practitioner summary",generatedAt:Date(),patientName:"Example Patient",bulletDates:dates,typography:typography)
        let pdf=try XCTUnwrap(PDFDocument(data:data))
        XCTAssertGreaterThan(pdf.pageCount,0)
        let extracted=try XCTUnwrap(pdf.string)
        for section in sections {for bullet in section.1 {XCTAssertTrue(extracted.contains(bullet.components(separatedBy:" — ")[0]))}}
        let additional=(0..<20).map{"- Review item \($0) — outstanding questions for discussion at the next visit"}.joined(separator:"\n")
        let longData=try StorySummaryPDF.render(text:text+"\n"+additional,title:"Practitioner summary",generatedAt:Date(),patientName:"Example Patient",bulletDates:dates,typography:typography)
        let longPDF=try XCTUnwrap(PDFDocument(data:longData))
        XCTAssertGreaterThan(longPDF.pageCount,1)
        XCTAssertTrue(longPDF.page(at:1)?.string?.contains("Example Patient") == true)
        XCTAssertTrue(longPDF.string?.contains("Review item 19") == true)
        if let path=ProcessInfo.processInfo.environment["STORY_STYLED_PREVIEW"] {
            try data.write(to:URL(fileURLWithPath:path))
            try longData.write(to:URL(fileURLWithPath:path.replacingOccurrences(of:".pdf",with:"-long.pdf")))
        }
    }

    @MainActor func testReferenceAlignedSummaryPreservesHistoryAndLabTrends() throws {
        struct FixturePoint:Decodable {let heading:String;let text:String;let topic:String?}
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let points=try JSONDecoder().decode([FixturePoint].self,from:Data(contentsOf:root.appendingPathComponent("Fixtures/practitioner-reference-summary.json")))
        let markers=["Ferritin","Vitamin D","LDL cholesterol","HbA1c","hs-CRP"]
        let narrative=points.filter{!($0.heading == "Labs & Investigations" && markers.contains($0.topic ?? ""))}
        let text=StorySummaryTemplate.practitioner.sections.map { h in "## "+h+"\n"+narrative.filter{$0.heading==h}.map{"- "+$0.text}.joined(separator:"\n") }.joined(separator:"\n\n")
        var summary=StorySharedSummary(templateID:"practitioner-v1",text:text,generatedAt:ISO8601DateFormatter().date(from:"2026-11-09T12:00:00Z")!,evidence:[],patientName:"Morgan Lee")
        let fixtures:[(String,String,String,[String])]=[("Ferritin","µg/L","30–150",["11","15","18"]),("Vitamin D","nmol/L","50–125",["32","39","44"]),("LDL cholesterol","mmol/L","<3.0",["4.1","3.9","3.8"]),("HbA1c","%","4.0–5.6",["5.8","5.9","6.0"]),("hs-CRP","mg/L","<3.0",["5.6","4.8","4.1"])]
        let dates=["2026-08-12","2026-09-16","2026-10-28"]
        summary.labReadings=try fixtures.flatMap { name,unit,range,values in try values.enumerated().map { index,value in
            var entry=SummaryEntry(category:.testsAndLabs,title:name,fields:[.init(label:"Result",value:value),.init(label:"Units",value:unit),.init(label:"Reference range",value:range)],sourceDate:Date())
            entry.evidence=ClinicalEvidence();entry.evidence?.eventDate=dates[index]
            return try XCTUnwrap(StoryLabReading(entry))
        }}
        let pdfData=try StorySummaryPDF.renderSummary(summary,title:"Practitioner summary",patientName:"Morgan Lee")
        let pdf=try XCTUnwrap(PDFDocument(data:pdfData));let extracted=try XCTUnwrap(pdf.string)
        let normalized=extracted.components(separatedBy:.whitespacesAndNewlines).filter{!$0.isEmpty}.joined(separator:" ")
        for point in narrative {XCTAssertTrue(normalized.contains(point.text.components(separatedBy:" — ")[0]),point.text)}
        XCTAssertTrue(extracted.contains("Appendectomy"));XCTAssertTrue(extracted.contains("2017"))
        XCTAssertTrue(extracted.contains("Earlier results"));XCTAssertTrue(extracted.contains("Lab interval"))
        XCTAssertFalse(extracted.contains("325 mg"));XCTAssertLessThanOrEqual(pdf.pageCount,4)
        if let path=ProcessInfo.processInfo.environment["STORY_REFERENCE_PREVIEW"] {try pdfData.write(to:URL(fileURLWithPath:path))}
    }

    func testPresentationGroupsOnlyAdjacentCompatibleTopicsAndRetainsDates() {
        let lines = ["Fetal status — active movement", "Fetal status — head down", "Fetal status — heart rate 130", "Mood — tearful", "Fetal status — reassuring"]
        let input = "## Clinical Snapshot\n" + lines.map { "- " + $0 }.joined(separator: "\n")
        let dates = lines.map { StorySummaryBulletDate(text:$0,labels:["Date: 2026-09-22"]) }
        let result = StorySummaryDocument.practitionerPresentation(input,hasAbnormalLabs:false,bulletDates:dates)
        let combined = "Fetal status — active movement; head down; heart rate 130"
        XCTAssertTrue(result.blocks.contains(.bullet(combined)))
        XCTAssertTrue(result.blocks.contains(.bullet("Fetal status — reassuring")))
        XCTAssertEqual(result.dates.first?.labels,["Date: 2026-09-22"])
        XCTAssertEqual(dates.count,5)
        let distinctDates = [StorySummaryBulletDate(text:lines[0],labels:["Date: 2025-09-22"]), dates[1]]
        let separate = StorySummaryDocument.practitionerPresentation(input,hasAbnormalLabs:false,bulletDates:distinctDates)
        XCTAssertTrue(separate.blocks.contains(.bullet(lines[0])))
        let choices = "## Care Plan & Interventions\n- Medication — declined today\n- Medication — considering next week"
        XCTAssertEqual(StorySummaryDocument.practitionerPresentation(choices,hasAbnormalLabs:false,bulletDates:[]).blocks.count,3)
    }

    func testCarePlanCombinesComplementaryNotesAndKeepsDateInDescription() throws {
        let points=["Pepcid AC — agreed trial for reflux", "Pepcid AC — Tums for breakthrough", "Counselling — continuation planned", "Counselling — two further sessions available"]
        let dates=points.map {StorySummaryBulletDate(text:$0,labels:["Record: 2026-09-22"])}
        let text="## Care Plan & Interventions\n"+points.map{"- "+$0}.joined(separator:"\n")
        let grouped=StorySummaryDocument.practitionerPresentation(text,hasAbnormalLabs:false,bulletDates:dates)
        XCTAssertTrue(grouped.blocks.contains(.bullet("Pepcid AC — agreed trial for reflux; Tums for breakthrough")))
        XCTAssertTrue(grouped.blocks.contains(.bullet("Counselling — continuation planned; two further sessions available")))
        let data=try StorySummaryPDF.render(text:text,title:"Practitioner summary",generatedAt:Date(),bulletDates:dates)
        let pdf=try XCTUnwrap(PDFDocument(data:data))
        XCTAssertTrue(pdf.string?.contains("Recorded") == true)
        if let path=ProcessInfo.processInfo.environment["STORY_CARE_PREVIEW"] { try data.write(to:URL(fileURLWithPath:path)) }
    }

    func testSharedTopicsKeepDistinctStatusesAndDatesWithoutRepeatedHeadings() throws {
        let points=["Pregnancy — 31w6d on Sep 17, 2026", "Pregnancy — EDD Nov 18", "Pregnancy — posterior placenta", "Sumatriptan — used during migraine attacks", "Sumatriptan — use unconfirmed"]
        let dates=points.map {StorySummaryBulletDate(text:$0,labels:["Record: 2026-09-22"])}
        let text="## Clinical Snapshot\n"+points.prefix(3).map{"- "+$0}.joined(separator:"\n")+"\n## Care Plan & Interventions\n"+points.suffix(2).map{"- "+$0}.joined(separator:"\n")
        let grouped=StorySummaryDocument.practitionerPresentation(text,hasAbnormalLabs:false,bulletDates:dates)
        XCTAssertTrue(grouped.blocks.contains(.bullet("Pregnancy — 31w6d on Sep 17, 2026; EDD Nov 18; posterior placenta")))
        XCTAssertTrue(grouped.blocks.contains(.bullet(points[3])))
        XCTAssertTrue(grouped.blocks.contains(.bullet(points[4])))
        XCTAssertEqual(StorySummaryDocument.displayNote(points[4],after:.bullet(points[3])),"use unconfirmed")
        let data=try StorySummaryPDF.render(text:text,title:"Practitioner summary",generatedAt:Date(),bulletDates:dates)
        let pdf=try XCTUnwrap(PDFDocument(data:data));let content=try XCTUnwrap(pdf.string)
        XCTAssertEqual(content.components(separatedBy:"Sumatriptan").count-1,1)
        XCTAssertTrue(content.contains("use unconfirmed"))
        XCTAssertFalse(content.contains("Topic"))
        XCTAssertFalse(content.contains("Notes"))
        XCTAssertFalse(content.contains("Treatment / action"))
        XCTAssertTrue(content.contains("Recorded"))
        if let path=ProcessInfo.processInfo.environment["STORY_TOPIC_PREVIEW"] { try data.write(to:URL(fileURLWithPath:path)) }
    }

    func testHistoryDatesPreferExplicitMilestonesWithoutGuessingBetweenEvents() {
        for point in ["Breastfeeding — documented Sep 6, 2024", "Right Achilles tendinosis — chronic, documented Aug 2024", "Pain — ongoing as of July 2024"] {
            XCTAssertEqual(StorySummaryBulletDate.historyDisplayDate(text:point,labels:[]),"2024")
        }
        for point in ["Previous breastfeeding — documented Sep 6, 2024", "Appendectomy — documented Aug 2024", "Breastfeeding — stopped, documented Sep 6, 2024"] {
            XCTAssertNil(StorySummaryBulletDate.historyDisplayDate(text:point,labels:[]))
        }
        XCTAssertEqual(StorySummaryBulletDate.historyDisplayDate(text:"Pelvic weakness — about 10 years before Sep 2024",labels:[]),"c. 2014")
        XCTAssertEqual(StorySummaryBulletDate.historyDisplayDate(text:"Tailbone fractures — twice 5–6 years before Sep 2024",labels:[]),"2018–2019")
        XCTAssertEqual(StorySummaryBulletDate.historyDisplayDate(text:"Treatment — 2 years after 2020",labels:[]),"2022")
        XCTAssertNil(StorySummaryBulletDate.historyDisplayDate(text:"Treatment — ten years ago",labels:["Record: 2024-09-01"]))
        for point in ["Achilles tendinosis — documented Aug 2024", "First birth — vaginal delivery"] {
            XCTAssertNil(StorySummaryBulletDate.historyDisplayDate(text:point,labels:["Date: 2024-09-06"]))
        }
        XCTAssertEqual(StorySummaryBulletDate.historyDisplayDate(text:"Surgery — 2026-08-12",labels:[]),"2026")
        XCTAssertEqual(StorySummaryBulletDate.historyDisplayDate(text:"Surgery — August 2026",labels:[]),"2026")
        XCTAssertNil(StorySummaryBulletDate.historyDisplayDate(text:"Surgery",labels:["Date: 2025-08-12","Record: 2026-11-20"]))
        XCTAssertNil(StorySummaryBulletDate.historyDisplayDate(text:"Supplement — 2000 IU daily",labels:[]))
        XCTAssertEqual(StorySummaryBulletDate.historyDisplayDate(text:"Appendectomy — 2017, uncomplicated recovery",labels:["Record: 2026-11-20"]),"2017")
        XCTAssertEqual(StorySummaryBulletDate.historyDisplayDate(text:"Back pain — 2019–2020, improved w/ physiotherapy",labels:[]),"2019–2020")
        XCTAssertEqual(StorySummaryBulletDate.historyDisplayDate(text:"Treatment — started 2025, changed 2026",labels:[]),nil)
        XCTAssertNil(StorySummaryBulletDate.historyDisplayDate(text:"Surgery — uncomplicated recovery",labels:["Record: 2026-11-20"]))
    }
    func testHistoryTablePreservesMilestonesAndRepeatsHeaderAcrossPages() throws {
        let milestones=(0..<35).map { "Milestone \($0) — historical treatment in \(1980+$0), subsequent course" }
        let text="## Comprehensive Health History\n"+milestones.map{"- "+$0}.joined(separator:"\n")
        let dates=milestones.enumerated().map { StorySummaryBulletDate(text:$0.element,labels:["Date: \(1980+$0.offset)"]) }
        let data=try StorySummaryPDF.render(text:text,title:"Practitioner summary",generatedAt:Date(),bulletDates:dates)
        let pdf=try XCTUnwrap(PDFDocument(data:data));XCTAssertGreaterThan(pdf.pageCount,1)
        let extracted=try XCTUnwrap(pdf.string)
        for i in 0..<35 {XCTAssertTrue(extracted.contains("Milestone \(i)"));XCTAssertTrue(extracted.contains("\(1980+i)"))}
        XCTAssertTrue(pdf.page(at:1)?.string?.contains("Year") == true)
        XCTAssertTrue(pdf.page(at:1)?.string?.contains("Health events and course") == true)
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

extension StoryTemplateTests {
    func testServiceRequestSurvivesReopenAndDeletionKeepsOnlyCancellation() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(storageDirectory:root)
        let record=Session(id:UUID(),transcript:"Synthetic source",title:"Synthetic")
        try await store.save([record])
        let id=UUID(),source=StoryEvidence(id:"E1",text:"Synthetic source",recordID:record.id,title:"Synthetic")
        let request=ServiceSummaryRequest(id:id,kind:"record",target:record.id.uuidString,sourceRevision:"source-1",publicationRevision:"edit-1",template:"detailed",evidence:[source])
        _=try await store.prepareServiceSummary(request)
        let reopened=try SessionStore(storageDirectory:root)
        var changed=request;changed.sourceRevision="source-2"
        let frozen=try await reopened.prepareServiceSummary(changed)
        XCTAssertEqual(frozen.sourceRevision,"source-1")
        try await reopened.delete(id:record.id)
        let pending=try await reopened.storyWorkspace().messages.first{$0.id==id}
        XCTAssertEqual(pending?.state,"cancelled");XCTAssertEqual(pending?.cancellationPending,true)
        XCTAssertNil(pending?.requestJSON);XCTAssertNil(pending?.evidence)
        do {_=try await reopened.prepareServiceSummary(request);XCTFail("Deleted work resumed")} catch {}
    }
    func testServiceOverviewPublishesAndCompletesAtomicallyWithoutOverwritingEdits() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(storageDirectory:root),id=UUID()
        _=try await store.prepareServiceSummary(ServiceSummaryRequest(id:id,kind:"overview",target:"overview",sourceRevision:"s1",publicationRevision:"0",template:"overview",evidence:[]))
        try await store.saveStoryNarrativeText("My own writing")
        do {try await store.publishStoryNarrative("Late result",revision:0,evidence:[],serviceOperationID:id);XCTFail("Overwrote patient edit")} catch {}
        let saved=try await store.storyWorkspace();XCTAssertEqual(saved.narrativeText,"My own writing");XCTAssertEqual(saved.messages.first?.state,"queued")
        try await store.publishStoryNarrative("Explicit new result",revision:1,evidence:[],serviceOperationID:id)
        let completed=try await store.storyWorkspace();XCTAssertEqual(completed.messages.first?.state,"completed");XCTAssertNil(completed.messages.first?.requestJSON)
    }
    func testClearingHistoryRetainsOnlyCloudDeletionTombstones() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(storageDirectory:root),id=UUID()
        _=try await store.prepareServiceSummary(ServiceSummaryRequest(id:id,kind:"overview",target:"overview",sourceRevision:"s1",publicationRevision:"0",template:"overview",evidence:[StoryEvidence(id:"E1",text:"Private synthetic text",recordID:nil,title:"Source")]))
        try await store.clearLocalStoryHistory()
        let pending=try await store.storyWorkspace().messages
        XCTAssertEqual(pending.count,1);XCTAssertEqual(pending[0].id,id)
        XCTAssertEqual(pending[0].cancellationPending,true);XCTAssertNil(pending[0].requestJSON);XCTAssertNil(pending[0].evidence)
    }
}

extension StoryTemplateTests {
    func testServiceRequestIgnoresPDFSeparatorsWithoutRenumberingEvidence() throws {
        let evidence = ["\n\u{c}\r\t ", "Declined a sweep today.", "\n", "May reconsider next week."].enumerated().map {
            StoryEvidence(id: String($0.offset + 1001), text: $0.element, recordID: nil, title: "Synthetic")
        }
        let request = ServiceSummaryRequest(id: UUID(), kind: "record", target: "synthetic", sourceRevision: "source", publicationRevision: "revision", template: "visit", evidence: evidence)
        XCTAssertEqual(request.evidence.map(\.id), ["1002", "1004"])
        XCTAssertEqual(request.evidence.map(\.text), [evidence[1].text, evidence[3].text])
        let roundTrip = try JSONDecoder().decode(ServiceSummaryRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(roundTrip.evidence, request.evidence)
    }
}

extension StoryTemplateTests {
    func testSummaryFailureExplainsSavedProgressWithoutInternalErrorCodes() {
        let failed = SummaryWorkflowFailureMessage.message(reason: "provider_failed")
        XCTAssertTrue(failed.contains("unfinished work"))
        XCTAssertTrue(failed.contains("saved summary is unchanged"))
        for reason in ["provider_failed", "provider_outcome_unknown", "workflow_limit", "budget_exhausted"] {
            XCTAssertFalse(SummaryWorkflowFailureMessage.message(reason: reason).contains(reason))
        }
        XCTAssertFalse(SummaryWorkflowFailureMessage.message(reason: "workflow_limit").contains("Tap Retry"))
    }
}
