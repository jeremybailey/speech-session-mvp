import Foundation
@testable import SpeechSessionPersistence
@main struct OverviewReferenceTests {
 static func main() throws {
  let pregnancy="pregnancy|durable-source-fact",cough="symptom|durable-source-fact"
  let input="Clinical text REF_A, 31 weeks. [\(pregnancy)] [\(cough)] \(pregnancy)|suffix"
  let wire=OverviewReferenceEncoding(ids:[pregnancy,cough,pregnancy],input:input)
  assert(wire.codes.count==2 && wire.codes.allSatisfy{$0.hasPrefix("REFX_")})
  let encoded=wire.encode(input);assert(encoded.contains("Clinical text REF_A, 31 weeks."))
  assert(encoded.contains(pregnancy+"|suffix"));assert(!encoded.contains("["+pregnancy+"]"))
  let pregnancyCode=wire.originalByCode.first{$0.value==pregnancy}!.key
  let coughCode=wire.originalByCode.first{$0.value==cough}!.key
  func raw(_ text:String,_ ids:[String])throws->String {
   String(decoding:try JSONSerialization.data(withJSONObject:["sentences":[["text":text,"factIDs":ids]]]),as:UTF8.self)
  }
  let entries=[SummaryEntry(category:.findings,title:"Pregnancy",details:"31 weeks pregnant",origin:.userAdded),SummaryEntry(category:.symptoms,title:"Cough",origin:.userAdded)]
  let facts=zip([pregnancy,cough],entries).map{HealthFact(id:$0.0,occurrences:[$0.1],preference:.init(id:$0.0),topicIDs:[])}
  let restored=try OverviewResponseContract.decodeNarrative(wire.restore(raw("31 weeks pregnant [\(pregnancyCode)].",[pregnancyCode]))).removingInlineReferenceIDs(in:facts)
  assert(restored.hasValidReferences(in:facts));assert(restored.hasGroundedNumbers(in:facts));assert(restored.text=="31 weeks pregnant.")
  let wrong=try OverviewResponseContract.decodeNarrative(wire.restore(raw("31 weeks pregnant.",[coughCode])))
  assert(!wrong.hasGroundedNumbers(in:facts))
  let invented=try OverviewResponseContract.decodeNarrative(wire.restore(raw("34 weeks pregnant.",[pregnancyCode])))
  assert(!invented.hasGroundedNumbers(in:facts))
  for ids in [[],["UNKNOWN"],[pregnancy]] {
   do{_ = try wire.restore(raw("A claim.",ids));fatalError("Invalid wire reference accepted")}catch OverviewFailure.invalidReferences{}
  }
  assert(OverviewReferenceEncoding(ids:[cough,pregnancy],input:input).originalByCode==wire.originalByCode)
  print("Overview ID round trips, collision avoidance, exact boundaries, unknown-reference rejection and unchanged number guards passed.")
 }
}
