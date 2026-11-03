import XCTest
@testable import SpeechSessionPersistence
final class HealthCarePlanTests:XCTestCase {
 private let source=UUID()
 private func fact(_ text:String,sourceID:UUID? = nil,plan:String? = "p1",title:String? = nil,category:SummaryEntryCategory = .carePlan,context:String? = nil,timing:String? = nil)->HealthFact {
  var entry=SummaryEntry(category:category,title:text,sourceSessionID:sourceID ?? source)
  var evidence=ClinicalEvidence();evidence.assessmentMethod=WholeHistoryPublication.version
  var care=CareInstruction(instruction:text,schedule:timing);care.planID=plan;care.planTitle=title;care.isConcise=plan != nil;care.consideration=context
  care.bucket=category == .followUp ? .followUp:.carePlan;evidence.careInstruction=care;entry.evidence=evidence
  return .init(id:entry.id.uuidString,occurrences:[entry],preference:.init(id:entry.id.uuidString),topicIDs:[])
 }
 func testOnePlanIsSharedAcrossAllAndConditionsWithAllActionsAndSources() {
  let a=fact("Keep feet grounded",title:"Posture plan"),b=fact("Continue heat",timing:"At night"),c=fact("Book review",category:.followUp)
  let conditions=[ConditionSummary(id:"back",name:"Back pain",bodySystem:"musculoskeletal",facts:[a,b]),ConditionSummary(id:"movement",name:"Movement",bodySystem:"musculoskeletal",facts:[a,c])]
  let all=HealthCarePlan.project(facts:[a,b,c],conditions:conditions,sessions:[])
  XCTAssertEqual(all.count,1);XCTAssertEqual(all[0].title,"Posture plan");XCTAssertEqual(all[0].actions.count,3)
  XCTAssertEqual(Set(all[0].conditionIDs),["back","movement"])
  XCTAssertEqual(Set(all[0].entries.map(\.id)),Set([a,b,c].flatMap(\.occurrences).map(\.id)))
  XCTAssertEqual(all.filter{$0.conditionIDs.contains("back")}.first?.id,all.filter{$0.conditionIDs.contains("movement")}.first?.id)
 }
 func testDuplicateAdviceCoalescesOnlyWithIdenticalTimingContextOwnerAndStatus() {
  let a=fact("Continue heat",timing:"At night"),b=fact("Continue heat",timing:"At night")
  var c=fact("Continue heat",timing:"At night");c.preference.actionStatus = .completed
  let d=fact("Continue heat",timing:"If needed"),e=fact("Continue heat",context:"Only if agreed",timing:"At night")
  let plans=HealthCarePlan.project(facts:[a,b,c,d,e],conditions:[],sessions:[])
  XCTAssertEqual(plans.count,1);XCTAssertEqual(plans[0].actions.count,4);XCTAssertEqual(plans[0].entries.count,5)
  XCTAssertTrue(plans[0].actions.contains{$0.entries.count==2})
  XCTAssertTrue(plans[0].actions.contains{$0.status=="Completed"})
  XCTAssertTrue(plans[0].actions.contains{$0.metadata.contains("Context: Only if agreed")})
 }
 func testEncountersProvidersDatesAndExplicitPlanIDsStaySeparate() {
  let a=fact("Action A",sourceID:UUID()),b=fact("Action B",sourceID:UUID())
  XCTAssertEqual(HealthCarePlan.project(facts:[a,b],conditions:[],sessions:[]).count,2)
  var c=fact("Action C"),d=fact("Action D");c.occurrences[0].evidence?.practitioner="Dr. Jane Doe";d.occurrences[0].evidence?.practitioner="Dr. John Roe"
  XCTAssertEqual(HealthCarePlan.project(facts:[c,d],conditions:[],sessions:[]).count,2)
  var e=fact("Action E"),f=fact("Action F");e.occurrences[0].evidence?.eventDate="2026-01-01";f.occurrences[0].evidence?.eventDate="2026-01-02"
  XCTAssertEqual(HealthCarePlan.project(facts:[e,f],conditions:[],sessions:[]).count,2)
  XCTAssertEqual(HealthCarePlan.project(facts:[fact("One",plan:"p1"),fact("Two",plan:"p2")],conditions:[],sessions:[]).count,2)
 }
 func testFictionalContextNeverMixesWithActualPatientAdvice() {
  let a=fact("Try posture changes",context:"Fictional role-play"),b=fact("Continue heat")
  let plans=HealthCarePlan.project(facts:[a,b],conditions:[],sessions:[])
  XCTAssertEqual(plans.count,2);XCTAssertEqual(plans.filter(\.fictional).count,1)
 }
 func testPatientEditsSeparationHiddenChoicesAndRemindersSurvive() {
  var a=fact("My exact wording"),b=fact("My exact wording");a.occurrences[0].origin = .userEdited;b.occurrences[0].evidence?.combinationExcluded=true
  a.occurrences[0].evidence?.careInstruction?.instruction="Old generated instruction"
  let due=Date(timeIntervalSince1970:2000000000);a.preference.dueDate=due
  var hidden=fact("Hidden action");hidden.preference.hidden=true
  let plans=HealthCarePlan.project(facts:[a,b,hidden],conditions:[],sessions:[])
  XCTAssertEqual(plans.count,1);XCTAssertEqual(plans[0].actions.count,2)
  XCTAssertTrue(plans[0].actions.contains{$0.patientWritten && $0.text=="My exact wording" && $0.reminder==due})
  XCTAssertFalse(plans[0].entries.contains{$0.id==hidden.latest.id})
 }
 func testLocalCompatibilityNeverTruncatesOrDropsConditionsOrNumericInstructions() {
  let text="Clinician recommends continuing 5 mg only if agreed, not twice daily; perhaps review next week."
  let compact=HealthCarePlan.compact(text)
  XCTAssertEqual(compact,"Continue 5 mg only if agreed, not twice daily; perhaps review next week.")
  let long=String(repeating:"Do not change the stated instructions. ",count:20)
  XCTAssertEqual(HealthCarePlan.compact(long),long)
 }
 func testExportContainsOnlySelectedActionsAndKeepsTimingAndConditions() {
  let a=fact("Continue heat",title:"Back plan",timing:"At night"),b=fact("Private unselected action")
  let only=HealthCarePlan.project(facts:[a],conditions:[],sessions:[])
  XCTAssertTrue(only[0].exportText.contains("When: At night"))
  XCTAssertFalse(only[0].exportText.contains(b.title))
  XCTAssertTrue(only[0].unverified)
 }
 func testSourceDecisionStatusesStayExplicitAndPatientChoicesWin() {
  var a=fact("Do not start this option"),b=fact("Consider review")
  a.occurrences[0].evidence?.careInstruction?.recordStatus="declined"
  b.occurrences[0].details="Recorded status: conditional"
  var plans=HealthCarePlan.project(facts:[a,b],conditions:[],sessions:[])
  XCTAssertTrue(plans[0].actions.contains{$0.status=="Declined"})
  XCTAssertTrue(plans[0].actions.contains{$0.status=="Conditional"})
  a.preference.actionStatus = .completed
  plans=HealthCarePlan.project(facts:[a],conditions:[],sessions:[])
  XCTAssertEqual(plans[0].actions[0].status,"Completed")
 }
 func testOwnerIsRetainedButAbsentFromCardAndExportMetadata() {
  var a=fact("Book a review"),b=fact("Book a review")
  a.occurrences[0].evidence?.careInstruction?.owner="Patient"
  b.occurrences[0].evidence?.careInstruction?.owner="Clinic"
  let plans=HealthCarePlan.project(facts:[a,b],conditions:[],sessions:[])
  XCTAssertEqual(plans[0].actions.count,2)
  XCTAssertEqual(Set(plans[0].actions.compactMap(\.owner)),["Patient","Clinic"])
  XCTAssertFalse(plans[0].actions.flatMap(\.metadata).contains{$0.hasPrefix("Owner:")})
  XCTAssertFalse(plans[0].exportText.contains("Owner:"))
 }
 func testFollowUpTimingIsASectionOfTheSameEncounterNotAnotherPlan() {
  for timing in ["one week","2026-05-19","unknown"," "] {
   var a=fact("Adjust posture",plan:nil),b=fact("Return in one week",plan:nil,category:.followUp,timing:timing)
   a.occurrences[0].evidence?.eventDate=" "
   b.occurrences[0].evidence?.eventDate=timing
   let plans=HealthCarePlan.project(facts:[a,b],conditions:[],sessions:[])
   XCTAssertEqual(plans.count,1,timing)
   XCTAssertEqual(plans[0].actions.count,2)
   XCTAssertEqual(plans[0].actions.filter{$0.bucket == .followUp}.count,1)
   XCTAssertEqual(plans[0].actions.first{$0.bucket == .followUp}?.timing,timing.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil:timing)
  }
 }
 func testExplicitActionDateAndFutureFollowUpDateStayWithinOnePlan() {
  var a=fact("Adjust posture"),b=fact("Return next week",category:.followUp)
  a.occurrences[0].evidence?.eventDate="2026-05-12";b.occurrences[0].evidence?.eventDate="2026-05-19"
  XCTAssertEqual(HealthCarePlan.project(facts:[a,b],conditions:[],sessions:[]).count,1)
 }
 func testFollowUpDoesNotGuessBetweenTwoDatedEncountersOrProviders() {
  var a=fact("First encounter"),b=fact("Second encounter"),c=fact("Return later",category:.followUp)
  a.occurrences[0].evidence?.eventDate="2026-05-12";b.occurrences[0].evidence?.eventDate="2026-06-12"
  c.occurrences[0].evidence?.eventDate="one week"
  let plans=HealthCarePlan.project(facts:[a,b,c],conditions:[],sessions:[])
  XCTAssertEqual(plans.count,3)
  XCTAssertEqual(plans.first{$0.actions.contains{$0.bucket == .followUp}}?.actions.count,1)
  b.occurrences[0].evidence?.eventDate="2026-05-12"
  b.occurrences[0].evidence?.practitioner="Dr. Jane Doe"
  XCTAssertEqual(HealthCarePlan.project(facts:[a,b,c],conditions:[],sessions:[]).count,2)
 }
 func testScenarioContextIsRemovedOnlyFromDisplayPrefixes() {
  let source="Fictional role-play: reported lower-back pain, recurrent"
  XCTAssertEqual(HealthStoryText.displayName(source),"Reported lower-back pain, recurrent")
  XCTAssertEqual(HealthStoryText.displayName("Suspected allergy; not confirmed"),"Suspected allergy; not confirmed")
  XCTAssertEqual(HealthStoryText.displayName("Pain during role-play"),"Pain during role-play")
  XCTAssertEqual(HealthStoryText.displayName("eGFR concern"),"eGFR concern")
  let a=fact("Try posture changes",context:"Fictional role-play"),b=fact("Continue heat")
  XCTAssertEqual(HealthCarePlan.project(facts:[a,b],conditions:[],sessions:[]).count,2)
  XCTAssertEqual(a.latest.evidence?.careInstruction?.consideration,"Fictional role-play")
 }
 func testOldCareInstructionDataDecodesWithoutNewPlanMetadata() throws {
  let value=try JSONDecoder().decode(CareInstruction.self,from:Data(#"{"instruction":"Old advice","schedule":"At night"}"#.utf8))
  XCTAssertNil(value.planID);XCTAssertNil(value.isConcise);XCTAssertEqual(value.schedule,"At night")
 }
}
