import XCTest
import PDFKit
@testable import SpeechSessionPersistence

final class FounderSummaryPresentationTests: XCTestCase {
    func fixture() -> StorySharedSummary {
        let statements: [(String,String,String,String?,String?)] = [
            ("Clinical Snapshot","Migraine — attacks limit activity","Migraine",nil,nil),
            ("Clinical Snapshot","Pregnancy — last documented at 30 weeks","Pregnancy",nil,nil),
            ("Care Coordination Summary","Alex Smith, PT — North clinic; treated hip pain; Licence number 12345","",nil,nil),
            ("Care Coordination Summary","Alex Smith — treated ankle pain","",nil,nil),
            ("Care Coordination Summary","Jamie Jones — recommended, not booked","",nil,nil),
            ("Comprehensive Health History","Headache — childhood onset","Migraine",nil,"Childhood"),
            ("Comprehensive Health History","Pelvic weakness — about 10 years before September 2024","Pelvic symptoms",nil,"about 10 years before September 2024"),
            ("Condition-Specific Summary","Headache — childhood onset","Migraine",nil,"Childhood"),
            ("Condition-Specific Summary","Headache — monthly attacks","Migraine",nil,nil),
            ("Care Plan & Interventions","Physiotherapy — partially helpful, discontinued due to discomfort","Pelvic symptoms","Past",nil),
            ("Care Plan & Interventions","Birth preparation — discussed","Pregnancy — birth preparation & contingency plans","Discussed, not started",nil),
            ("Appointment Preparation Brief","Visit — review tomorrow","",nil,nil)
        ]
        let text = StorySummaryTemplate.practitioner.sections.map { heading in "## " + heading + "\n" + statements.filter{$0.0==heading}.map{"- " + $0.1}.joined(separator:"\n") }.joined(separator:"\n\n")
        var summary=StorySharedSummary(templateID:"practitioner-v1",text:text,evidence:statements.enumerated().map { index,item in StoryEvidence(id:"e\(index)",text:item.1,recordID:UUID(),title:"Synthetic source") })
        summary.practitionerPolicy="founder-v1"
        summary.pointReferences=statements.enumerated().map { index,item in
            var ref=StorySummaryPointReference(heading:item.0,text:item.1,citationIDs:["e\(index)"])
            ref.conditionGroup=item.2;ref.careStatus=item.3;ref.timeLabel=item.4;return ref
        }
        summary.bulletDates=[StorySummaryBulletDate(text:"Headache — monthly attacks",labels:[],temporal:StorySummaryTemporal(role:"ongoing",start:"2026-06",end:nil,approximate:false))]
        return summary
    }
    func testHistoryMovedWithoutLosingFactsAndDuplicateCitationsCombined() {
        let summary=fixture(),view=FounderSummaryPresentation(summary:summary,hasAbnormalLabs:false,patientName:nil)
        XCTAssertFalse(view.blocks.contains(.heading("Comprehensive Health History",level:2)))
        XCTAssertFalse(view.blocks.contains(.heading("Appointment Preparation Brief",level:2)))
        let rows=view.blocks.flatMap { if case let .table(_,rows)=$0{return rows};return [] }
        XCTAssertEqual(rows.filter{$0.contains("Headache — childhood onset")}.count,1)
        XCTAssertEqual(view.sources["Headache — childhood onset"], ["e5","e7"])
        XCTAssertTrue(rows.contains{ $0.contains("about 10 years before September 2024") })
        XCTAssertFalse(rows.flatMap{$0}.contains{"2014" == $0})
        XCTAssertTrue(rows.contains{ $0.contains("Past") && $0.contains("partially helpful, discontinued due to discomfort") })
        XCTAssertTrue(summary.text.contains("Comprehensive Health History"))
    }
    func testProviderDedupExcludesUnseenAndLicenceNumbers() {
        let view=FounderSummaryPresentation(summary:fixture(),hasAbnormalLabs:false,patientName:nil)
        let rows=view.blocks.flatMap { if case let .table(headers,rows)=$0,headers.first=="Practitioner"{return rows};return [] }
        XCTAssertEqual(rows.count,1)
        XCTAssertEqual(rows[0][0],"Alex Smith, PT")
        XCTAssertTrue(rows[0][1].contains("hip pain"));XCTAssertTrue(rows[0][1].contains("ankle pain"))
        XCTAssertFalse(rows[0][1].contains("12345"))
    }
    func testLegacyProseAndTablesAreRetained() {
        let summary = StorySharedSummary(templateID: "practitioner-v1", text: "## Comprehensive Health History\n\nA historical account preserved as prose.\n\n| Year | Event |\n| --- | --- |\n| 2020 | Documented milestone |", evidence: [])
        let original = StorySummaryDocument.practitionerPresentation(summary.text, hasAbnormalLabs: false, bulletDates: [], providerContacts: [], patientName: nil)
        XCTAssertEqual(FounderSummaryPresentation(summary: summary, hasAbnormalLabs: false, patientName: nil).blocks, original.blocks)
    }
    func testDocumentationDatesNeverBecomeHistoricalEventDates() {
        let metadata=StorySummaryBulletDate(text:"Birth — prior pregnancy",labels:["Record: 2026-11-24"],temporal:StorySummaryTemporal(role:"documented",start:"2026-11-24",end:nil,approximate:false))
        XCTAssertEqual(FounderSummaryPresentation.when(text:metadata.text,metadata:metadata,period:nil).label,"Prior pregnancy")
        XCTAssertNil(FounderSummaryPresentation.when(text:metadata.text,metadata:metadata,period:nil).sort)
    }
    @MainActor func testOrganizedPDFAndPrivacyFilter() throws {
        let summary=fixture()
        let data=try StorySummaryPDF.renderSummary(summary,title:"Practitioner summary",patientName:"Synthetic Patient",excludeSensitiveDetails:true)
        let text=try XCTUnwrap(PDFDocument(data:data)?.string)
        XCTAssertTrue(text.contains("Condition-Specific Summary"));XCTAssertFalse(text.contains("Comprehensive Health History"))
        XCTAssertTrue(text.contains("Status"));XCTAssertTrue(text.contains("Childhood"))
        XCTAssertFalse(text.contains("12345"));XCTAssertFalse(text.contains("Appointment Preparation Brief"))
        try data.write(to:URL(fileURLWithPath:"/tmp/cc-founder-summary.pdf"))
    }
    func groupedSummary(_ items: [(String, String, String, String?)]) -> StorySharedSummary {
        let text = StorySummaryTemplate.practitioner.sections.map { heading in
            "## " + heading + "\n" + items.filter { $0.0 == heading }.map { "- " + $0.1 }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        var summary = StorySharedSummary(templateID: "practitioner-v1", text: text, evidence: items.enumerated().map {
            StoryEvidence(id: "e\($0.offset)", text: $0.element.1, recordID: UUID(), title: "Synthetic source")
        })
        summary.practitionerPolicy = "founder-v1"
        summary.pointReferences = items.enumerated().map { index, item in
            var ref = StorySummaryPointReference(heading: item.0, text: item.1, citationIDs: ["e\(index)"])
            ref.conditionGroup = item.2; ref.careStatus = item.3
            return ref
        }
        return summary
    }

    func testAdjacentTreatmentsKeepTheirOwnStatusesAndSources() {
        let summary = groupedSummary([
            ("Care Plan & Interventions", "Physiotherapy — partially helpful", "Hip pain", "Active"),
            ("Care Plan & Interventions", "Physiotherapy — reassessment if symptoms persist", "Hip pain", "Contingency")
        ])
        let view = FounderSummaryPresentation(summary: summary, hasAbnormalLabs: false, patientName: nil)
        let rows = view.blocks.flatMap { if case let .table(headers, rows) = $0, headers.contains("Status") { return rows }; return [] }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0[2] }, ["Active", "Contingency"])
        XCTAssertEqual(view.sources["Physiotherapy — partially helpful"], ["e0"])
        XCTAssertEqual(view.sources["Physiotherapy — reassessment if symptoms persist"], ["e1"])
    }

    func testAdjacentTopicsCannotMergeDifferentConditionGroups() {
        let summary = groupedSummary([
            ("Clinical Snapshot", "Pain — limits walking", "Hip pain", nil),
            ("Clinical Snapshot", "Pain — limits gripping", "Wrist pain", nil)
        ])
        let view = FounderSummaryPresentation(summary: summary, hasAbnormalLabs: false, patientName: nil)
        XCTAssertTrue(view.blocks.contains(.heading("Hip pain", level: 3)))
        XCTAssertTrue(view.blocks.contains(.heading("Wrist pain", level: 3)))
        XCTAssertEqual(view.sources["Pain — limits walking"], ["e0"])
        XCTAssertEqual(view.sources["Pain — limits gripping"], ["e1"])
    }



    @MainActor func testMultiPageHandoffRetainsCompleteRowsAndProviderAlignment() throws {
        var items: [(String, String, String, String?)] = [
            ("Clinical Snapshot", "Migraine — attacks prevent activity", "Migraine", nil),
            ("Clinical Snapshot", "Hip pain — limits walking", "Hip pain", nil)
        ]
        for number in 1...8 {
            items.append(("Care Coordination Summary", "Clinician \(number), PT — Clinic \(number); treated concern \(number); clinic\(number)@example.com", "", nil))
        }
        for number in 1...24 {
            items.append(("Condition-Specific Summary", "Episode \(number) — symptoms affected work; improvement with documented treatment; residual discomfort during activity", "Concern \((number - 1) / 6 + 1)", nil))
        }
        items.append(("Care Plan & Interventions", "Physiotherapy — partially helpful; stopped due to discomfort", "Hip pain", "Past"))
        let summary = groupedSummary(items)
        let data = try StorySummaryPDF.renderSummary(summary, title: "Practitioner summary", patientName: "Synthetic Patient")
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        let text = try XCTUnwrap(pdf.string)
        for number in 1...24 { XCTAssertTrue(text.contains("Episode \(number)"), "Missing episode \(number)") }
        for number in 1...8 {
            let page = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.first { $0.contains("Clinician \(number), PT") }
            XCTAssertNotNil(page)
            XCTAssertTrue(page?.contains("clinic\(number)@example.com") == true)
            XCTAssertTrue(page?.contains("treated concern \(number)") == true)
        }
        XCTAssertFalse(text.contains("Appointment Preparation Brief"))
        XCTAssertFalse(text.contains("Comprehensive Health History"))
        try data.write(to: URL(fileURLWithPath: "/tmp/cc-founder-audit-multipage.pdf"))
    }

    func testLegacyStructuredSummaryKeepsItsSectionsAndSourceLinksUntilRegenerated() {
        var summary = groupedSummary([
            ("Clinical Snapshot", "Pain — limits walking", "Hip pain", nil),
            ("Appointment Preparation Brief", "Visit purpose — discuss walking tolerance", "Hip pain", nil)
        ])
        summary.practitionerPolicy = nil
        let original = StorySummaryDocument.practitionerPresentation(summary.text, hasAbnormalLabs: false, bulletDates: [])
        let view = FounderSummaryPresentation(summary: summary, hasAbnormalLabs: false, patientName: nil)
        XCTAssertEqual(view.blocks, original.blocks)
        XCTAssertTrue(view.blocks.contains(.heading("Appointment Preparation Brief", level: 2)))
        XCTAssertEqual(view.sources["Pain — limits walking"], ["e0"])
        XCTAssertEqual(view.sources["Visit purpose — discuss walking tolerance"], ["e1"])
    }

    func testFragmentsOfOneTreatmentRemainCompactWithTheirStatusAndSources() {
        let summary = groupedSummary([
            ("Care Plan & Interventions", "Physiotherapy — partially helpful; stopped due to discomfort", "Hip pain", "Past")
        ])
        let view = FounderSummaryPresentation(summary: summary, hasAbnormalLabs: false, patientName: nil)
        let rows = view.blocks.flatMap { if case let .table(headers, rows) = $0, headers.contains("Status") { return rows }; return [] }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?[2], "Past")
        XCTAssertTrue(rows.first?[1].contains("partially helpful; stopped due to discomfort") == true)
        XCTAssertEqual(view.sources["Physiotherapy — partially helpful; stopped due to discomfort"], ["e0"])
    }

}
