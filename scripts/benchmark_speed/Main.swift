import Foundation
import CryptoKit
import SpeechSessionPersistence
@main struct SpeedRun {
 static func main()async throws{
  let args=CommandLine.arguments;guard args.count==3 || (args.count==4 && args[3]=="--resume-snapshot") else{fatalError("Usage: replay experiment-root arm-N [--resume-snapshot]")}
  let resumed=args.count==4
  let root=URL(fileURLWithPath:args[1]),run=args[2],out=root.appendingPathComponent(run)
  guard !FileManager.default.fileExists(atPath:out.path) else{fatalError("Cold runs cannot reuse an output directory")}
  let storeURL=out.appendingPathComponent("store")
  if resumed {
   try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
   try FileManager.default.copyItem(at:root.appendingPathComponent("snapshot"),to:storeURL)
  } else {
   try FileManager.default.createDirectory(at:storeURL,withIntermediateDirectories:true)
   try FileManager.default.copyItem(at:root.appendingPathComponent("seed.json"),to:storeURL.appendingPathComponent(SessionStore.sessionsFileName))
  }
  let store=try SessionStore(storageDirectory:storeURL),bridge=try BenchmarkBridge(root:root,run:run,trace:out.appendingPathComponent("trace")),processor=RecordSummaryProcessor()
  let transport=OpenAIChatTransport(bridge:bridge)
  let initial=try await store.healthSnapshot();guard initial.sessions.count==5,resumed || (initial.preferences.isEmpty && initial.topics.isEmpty) else{fatalError("Isolation failed")}
  var phases:[[String:Any]]=[],failure:String?=nil
  var sourceOccurrenceIDs=Set<UUID>()
  let start=ProcessInfo.processInfo.systemUptime
  func phase(_ name:String,_ work:()async throws->Void)async throws{
   let t=ProcessInfo.processInfo.systemUptime
   do{try await work();phases.append(["phase":name,"seconds":ProcessInfo.processInfo.systemUptime-t,"completed":true])}
   catch{phases.append(["phase":name,"seconds":ProcessInfo.processInfo.systemUptime-t,"completed":false]);throw error}
  }
  do{
   if !resumed {
   for session in initial.sessions{
    try await phase("record:"+session.id.uuidString){
     let snapshot=try await store.healthSnapshot()
     try await processor.process(session,related:snapshot.sessions.flatMap{$0.summaryEntries ?? []},store:store,transport:transport,onDevice:false){_ in}
    }
   }
   sourceOccurrenceIDs=Set(try await store.healthSnapshot().sessions.flatMap{$0.summaryEntries ?? []}.map(\.id))
   try await phase("contact-reconciliation"){try await processor.reconcileContacts(store:store,transport:transport,onDevice:false){_ in}}
   try await phase("symptom-reconciliation"){try await processor.reconcileSymptoms(store:store,transport:transport,onDevice:false,force:true)}
   } else {sourceOccurrenceIDs=Set(initial.sessions.flatMap{$0.summaryEntries ?? []}.map(\.id))}
   try await phase("conditions"){
    let snapshot=try await store.healthSnapshot(),facts=HealthMemoryProjection.facts(in:snapshot,verifiedOnly:true)
    let synthesis=try await processor.synthesizeConditions(facts:facts,transport:transport,store:store){_ in}
    try await store.saveConditionSynthesis(synthesis,expected:facts)
   }
   try await phase("overview"){
    let snapshot=try await store.healthSnapshot(),facts=HealthMemoryProjection.facts(in:snapshot,verifiedOnly:true)
    let displayed=await store.displayedConditionFacts(for:facts)
    let narrative=try await processor.makeOverview(facts:facts,conditionContext:StoryOverview.conditionContext(facts:displayed,topics:snapshot.topics),transport:transport,onDevice:false){_ in}
    try await store.saveStoryOverview(narrative,expected:facts)
    guard await store.storyOverview(for:facts) != nil else{throw SummaryProcessingError.unavailable("Overview readback failed")}
   }
  }catch{failure=String(describing:error)}
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
  let savedIDs=Set(snapshot.sessions.flatMap{$0.summaryEntries ?? []}.map(\.id))
  let preserved=sourceOccurrenceIDs.isSubset(of:savedIDs)
  if !preserved { failure="Source occurrence IDs lost during reconciliation" }
  let occurrenceAudit:Any = sourceOccurrenceIDs.isEmpty ? NSNull() : preserved
  let report:[String:Any]=["run":run,"completed":failure==nil,"failure":failure as Any? ?? NSNull(),"elapsedSeconds":elapsed,"phases":phases,"timingScope":resumed ? "Saved-record downstream replay only: conditions + saved/readback overview; NOT cold full reprocessing" : "Full saved-text processing + contact/symptom reconciliation + conditions + saved/readback overview; includes diagnostic CLI overhead","cold": !resumed,"sourceOccurrencesPreserved":occurrenceAudit,"originalOccurrenceCount":sourceOccurrenceIDs.count]
  try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:out.appendingPathComponent("run.json"))
  if let accounting=try? await bridge.send(["action":"status"]) {try JSONSerialization.data(withJSONObject:accounting,options:[.sortedKeys,.prettyPrinted]).write(to:out.appendingPathComponent("ledger.json"))}
  print("\(run): \(failure == nil ? "complete" : "incomplete"), \(Int(elapsed)) seconds. See private report.")
 }
}
