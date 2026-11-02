import Foundation
import CryptoKit
import SpeechSessionPersistence
@main struct WholeHistoryBaseline {
 @MainActor static func main()async throws{
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),run=CommandLine.arguments[2],out=root.appendingPathComponent(run)
  guard !FileManager.default.fileExists(atPath:out.path) else{fatalError("Fresh store required")}
  let storeURL=out.appendingPathComponent("store")
  try FileManager.default.createDirectory(at:storeURL,withIntermediateDirectories:true)
  try FileManager.default.copyItem(at:root.appendingPathComponent("seed.json"),to:storeURL.appendingPathComponent(SessionStore.sessionsFileName))
  defer { BenchmarkDefaults.value.removePersistentDomain(forName:"whole-history-"+ProcessInfo.processInfo.environment["BENCHMARK_RUN_ID"]!) }
  let store=try SessionStore(storageDirectory:storeURL),bridge=try BenchmarkBridge(root:root,run:run,trace:out.appendingPathComponent("trace")),model=HealthSummaryModel(store:store)
  let initial=try await store.healthSnapshot();guard initial.sessions.count==20,initial.preferences.isEmpty,initial.topics.isEmpty,initial.sessions.allSatisfy({($0.summaryEntries ?? []).isEmpty}) else{fatalError("Source-only isolation failed")}
  if ProcessInfo.processInfo.environment["BENCHMARK_DRY_RUN"] == "1" { print("Verified 20 source-only records in a fresh private store; no model requests."); return }
  await model.refresh()
  let start=ProcessInfo.processInfo.systemUptime
  await model.updateHealthStory(transport:OpenAIChatTransport(bridge:bridge),onDevice:false,explicitlyRequested:true)
  let elapsed=ProcessInfo.processInfo.systemUptime-start
  let snapshot=try await store.healthSnapshot(),facts=HealthMemoryProjection.facts(in:snapshot,verifiedOnly:true)
  let displayed=await store.displayedConditionFacts(for:facts),groups=ConditionSummaryProjection.groups(facts:displayed,topics:snapshot.topics)
  let visible=Set(facts.flatMap(\.occurrences).map(\.id)),encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
  for session in snapshot.sessions{
   let entries=try (session.summaryEntries ?? []).map{entry->[String:Any] in
    var row=try JSONSerialization.jsonObject(with:encoder.encode(entry)) as! [String:Any]
    row["displayDetails"]=HealthDetailPresentation.remainingDetails(entry)
    row["displayFields"]=try JSONSerialization.jsonObject(with:encoder.encode(HealthDetailPresentation.fields(entry)))
    row["visible"]=visible.contains(entry.id);row["accepted"]=SummaryVerification.isVisible(entry,source:session.transcript)
    row["conditions"]=groups.filter{!$0.isUncategorized && $0.facts.flatMap(\.occurrences).contains{$0.id==entry.id}}.map{["name":$0.name,"bodySystem":$0.bodySystem,"appSection":HealthAreaKind.classify($0).title]}
    return row
   }
   let output:[String:Any]=["recordID":session.id.uuidString,"sourceSHA256":SHA256.hash(data:Data(session.transcript.utf8)).map{String(format:"%02x",$0)}.joined(),"mode":run,"entries":entries]
   try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys,.prettyPrinted]).write(to:out.appendingPathComponent(session.id.uuidString+".output.json"))
  }
  try encoder.encode(snapshot.sessions).write(to:out.appendingPathComponent("sessions.json"))
  try encoder.encode(snapshot.topics).write(to:out.appendingPathComponent("topics.json"))
  try JSONSerialization.data(withJSONObject:["text":model.overview ?? ""]).write(to:out.appendingPathComponent("overview.json"))
  try encoder.encode(model.careCards).write(to:out.appendingPathComponent("care-cards.json"))
  let issues=[model.error,model.updateError,model.conditionNotice,model.overviewNotice,model.careOrganizationNotice].compactMap{$0}
  let complete=issues.isEmpty && model.processingIssue==nil && model.overviewIsCurrent && model.state(for:.details) == .ready && model.state(for:.conditions) == .ready
  let report:[String:Any]=["run":run,"completed":complete,"elapsedSeconds":elapsed,"issues":issues,"processingIssue":String(describing:model.processingIssue),"timingScope":"Current combined full app updateHealthStory; harness timing including diagnostic transport, not phone performance","cold":true,"overviewCurrent":model.overviewIsCurrent,"careCardCount":model.careCards.count,"visibleFactCount":facts.count]
  try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:out.appendingPathComponent("run.json"))
  if let accounting=try? await bridge.send(["action":"status"]){try JSONSerialization.data(withJSONObject:accounting,options:[.sortedKeys,.prettyPrinted]).write(to:out.appendingPathComponent("ledger.json"))}
  print("\(run): \(complete ? "complete" : "incomplete"), \(Int(elapsed)) seconds; private report saved.")
 }
}
