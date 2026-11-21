import XCTest
@testable import SpeechSessionPersistence

final class PractitionerCarePlanTests:XCTestCase {
    func testGroupsRepeatedTreatmentsWithoutCombiningDifferentDecisionsOrDates() {
        let first="Treatment — declined today",second="Treatment — considering next month"
        var summary=StorySharedSummary(templateID:"practitioner",text:"## Clinical Snapshot\n- Symptoms — intermittent\n## Care Plan & Interventions\n- \(first)\n- Other treatment — stopped after nausea\n- \(second)\n## Labs & Investigations\n- LDL — elevated",evidence:[])
        summary.bulletDates=[.init(text:first,labels:["Date: 2024-09-06"]),.init(text:second,labels:["Date: 2024-10-06"])]
        let overview=PractitionerCarePlan(summary:summary)
        XCTAssertEqual(overview.groups.map(\.title),["Treatment","Other treatment"])
        XCTAssertEqual(overview.groups[0].items.map(\.note),["declined today","considering next month"])
        XCTAssertEqual(overview.groups[0].items.map(\.date),["6 Sep 2024","6 Oct 2024"])
        XCTAssertEqual(overview.groups[1].items.first?.note,"stopped after nausea")
        XCTAssertTrue(overview.groups.flatMap(\.items).allSatisfy{$0.citationIDs.isEmpty})
    }

    func testLinksOnlyExactStatementsWithSavedPointReferences() {
        let text="Exercise — proposed; stop if painful"
        var summary=StorySharedSummary(templateID:"practitioner",text:"## Care Plan & Interventions\n- \(text)",evidence:[.init(id:"E1",text:"Source",recordID:UUID(),title:"Visit"),.init(id:"E2",text:"Different source",recordID:UUID(),title:"Other visit")])
        summary.pointReferences=[.init(heading:"Care Plan & Interventions",text:text,citationIDs:["E1","invented"]),.init(heading:"Care Plan & Interventions",text:"Exercise — daily",citationIDs:["E2"]),.init(heading:"Clinical Snapshot",text:text,citationIDs:["E2"])]
        let overview=PractitionerCarePlan(summary:summary)
        XCTAssertEqual(overview.groups.count,1)
        XCTAssertTrue(overview.groups[0].items.allSatisfy{$0.citationIDs==["E1"]})
        XCTAssertTrue(overview.groups[0].items.map(\.note).joined().contains("stop if painful"))
        summary.text="## Care Plan & Interventions\n- Exercise — my edited instruction"
        XCTAssertTrue(PractitionerCarePlan(summary:summary).groups[0].items[0].citationIDs.isEmpty)
    }

    func testPreservesLegacyNotesAndUnknownDatesWithoutInventingActions() throws {
        let summary=StorySharedSummary(templateID:"practitioner",text:"## Care Plan & Interventions\n- Might discuss another option",evidence:[])
        let groups=PractitionerCarePlan(summary:summary).groups
        XCTAssertEqual(groups[0].title,"Other care notes")
        XCTAssertEqual(groups[0].items[0].note,"Might discuss another option")
        XCTAssertNil(groups[0].items[0].date)
        let decoded=try JSONDecoder().decode(StorySharedSummary.self,from:JSONEncoder().encode(summary))
        XCTAssertNil(decoded.pointReferences)
        XCTAssertEqual(PractitionerCarePlan(summary:decoded),PractitionerCarePlan(summary:summary))
        XCTAssertTrue(PractitionerCarePlan(summary:.init(templateID:"practitioner",text:"## Care Plan & Interventions\n\n## Labs & Investigations\n- LDL — elevated",evidence:[])).groups.isEmpty)
    }
}
