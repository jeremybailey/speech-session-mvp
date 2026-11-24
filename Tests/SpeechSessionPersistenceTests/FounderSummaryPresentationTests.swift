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
}
