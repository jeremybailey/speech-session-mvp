import XCTest
@testable import SpeechSessionPersistence
final class WholeHistoryNarrativeContractTests:XCTestCase {
 private let fact=WholeHistoryDecodedFact(id:"r1.p1.1",text:"Pain started in 2024.",category:"symptoms",status:"reported",by:"Patient",event:"2024",groups:["c1"],quotes:["Pain started in 2024."],plan:nil)
 private let concern=WholeHistoryDecodedConcern(id:"c1",name:"Pain",systems:["musculoskeletal"])
 private func raw(_ text:String="Pain started in 2024.",ref:String="r1.p1.1",coverage:String="included_major") -> String {
  "{\"sentences\":[{\"text\":\"\(text)\",\"factIDs\":[\"\(ref)\"]}],\"coverage\":{\"c1\":\"\(coverage)\"}}"
 }
 func testSupportedOverview() throws {
  let result=try WholeHistoryNarrativeContract.decode(raw(),facts:[fact],concerns:[concern],writerVersion:"b-narrative-brief-v7")
  XCTAssertEqual(result.text,"Pain started in 2024.")
 }
 func testRejectsChangedNumberAndUnknownFactReference() {
  XCTAssertThrowsError(try WholeHistoryNarrativeContract.decode(raw("Pain started in 2025."),facts:[fact],concerns:[concern],writerVersion:"b-narrative-brief-v7"))
  XCTAssertThrowsError(try WholeHistoryNarrativeContract.decode(raw(ref:"r9.p1.1"),facts:[fact],concerns:[concern],writerVersion:"b-narrative-brief-v7"))
 }
 func testCannotDescribeOnlyAnOmittedCondition() {
  XCTAssertThrowsError(try WholeHistoryNarrativeContract.decode(raw(coverage:"omitted_minor"),facts:[fact],concerns:[concern],writerVersion:"b-narrative-brief-v7"))
 }
 func testContextOnlyOverviewDoesNotRequireInventingACondition() throws {
  let context=WholeHistoryDecodedFact(id:"r1.p1.1",text:"Works daytime shifts.",category:"biopsychosocialContext",status:"reported",by:"Patient",event:"",groups:[],quotes:["Works daytime shifts."],plan:nil)
  let raw="{\"sentences\":[{\"text\":\"You work daytime shifts.\",\"factIDs\":[\"r1.p1.1\"]}],\"coverage\":{}}"
  let result=try WholeHistoryNarrativeContract.decode(raw,facts:[context],concerns:[],writerVersion:"b-narrative-brief-v7")
  XCTAssertTrue(result.coverage.isEmpty)
  XCTAssertEqual(result.text,"You work daytime shifts.")
 }

}

extension WholeHistoryNarrativeContractTests {
 func testUncitedSecondaryCoverageReflectsActualCitations() throws {
  let second=WholeHistoryDecodedConcern(id:"c2",name:"Other concern",systems:["other"])
  let input=raw().replacingOccurrences(of:"\"c1\":\"included_major\"",with:"\"c1\":\"included_major\",\"c2\":\"included_secondary\"")
  let result=try WholeHistoryNarrativeContract.decode(input,facts:[fact],concerns:[concern,second],writerVersion:"b-narrative-brief-v7")
  XCTAssertEqual(result.coverage,["c1":"included_major","c2":"omitted_not_summarized"])
  XCTAssertEqual(result.text,"Pain started in 2024.")
  let neutral=input.replacingOccurrences(of:"included_secondary",with:"omitted_not_summarized")
  XCTAssertEqual(try WholeHistoryNarrativeContract.decode(neutral,facts:[fact],concerns:[concern,second],writerVersion:"b-narrative-brief-v7").coverage,result.coverage)
 }
 func testUncitedMajorTopicStillFails() {
  let second=WholeHistoryDecodedConcern(id:"c2",name:"Other concern",systems:["other"])
  let input=raw().replacingOccurrences(of:"\"c1\":\"included_major\"",with:"\"c1\":\"included_major\",\"c2\":\"included_major\"")
  XCTAssertThrowsError(try WholeHistoryNarrativeContract.decode(input,facts:[fact],concerns:[concern,second],writerVersion:"b-narrative-brief-v7"))
 }
 func testNormalizationCannotLeaveAllTopicsOmitted() {
  let ungrouped=WholeHistoryDecodedFact(id:fact.id,text:fact.text,category:fact.category,status:fact.status,by:fact.by,event:fact.event,groups:[],quotes:fact.quotes,plan:nil)
  XCTAssertThrowsError(try WholeHistoryNarrativeContract.decode(raw(coverage:"included_secondary"),facts:[ungrouped],concerns:[concern],writerVersion:"b-narrative-brief-v7"))
 }
 func testCitationToOmittedTopicStillFailsWithOtherIncludedTopic() {
  let second=WholeHistoryDecodedConcern(id:"c2",name:"Other concern",systems:["other"])
  let supported=WholeHistoryDecodedFact(id:"r1.p1.2",text:"Sleep is improving.",category:"symptoms",status:"reported",by:"Patient",event:"",groups:["c2"],quotes:["Sleep is improving."],plan:nil)
  let input=#"{"sentences":[{"text":"Pain started in 2024.","factIDs":["r1.p1.1"]},{"text":"Sleep is improving.","factIDs":["r1.p1.2"]}],"coverage":{"c1":"omitted_minor","c2":"included_major"}}"#
  XCTAssertThrowsError(try WholeHistoryNarrativeContract.decode(input,facts:[fact,supported],concerns:[concern,second],writerVersion:"b-narrative-brief-v7"))
 }
}
