import Foundation
import SpeechSessionPersistence
@main struct OverviewReplay {
 static func main()async throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]),run=CommandLine.arguments[2],out=root.appendingPathComponent(run)
  guard !FileManager.default.fileExists(atPath:out.path) else{fatalError("Fresh replay directory required")}
  try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  try FileManager.default.copyItem(at:root.appendingPathComponent("snapshot"),to:out.appendingPathComponent("store"))
  let store=try SessionStore(storageDirectory:out.appendingPathComponent("store")),bridge=try BenchmarkBridge(root:root,run:run,trace:out.appendingPathComponent("trace"))
  let before=try Data(contentsOf:out.appendingPathComponent("store/sessions.json")),start=ProcessInfo.processInfo.systemUptime
  var failure:String?=nil
  do {
   let snapshot=try await store.healthSnapshot(),facts=HealthMemoryProjection.facts(in:snapshot,verifiedOnly:true)
   let displayed=await store.displayedConditionFacts(for:facts)
   let overview=try await RecordSummaryProcessor().makeOverview(facts:facts,conditionContext:StoryOverview.conditionContext(facts:displayed,topics:snapshot.topics),transport:OpenAIChatTransport(bridge:bridge),onDevice:false){_ in}
   guard overview.hasValidReferences(in:facts),overview.hasGroundedNumbers(in:facts) else{throw OverviewFailure.unsupported}
   try await store.saveStoryOverview(overview,expected:facts)
   guard await store.storyOverview(for:facts) != nil else{throw OverviewFailure.invalidReferences}
   guard before == (try Data(contentsOf:out.appendingPathComponent("store/sessions.json"))) else{throw SummaryProcessingError.unavailable("Source records changed")}
  } catch {failure=String(describing:error)}
  let result:[String:Any]=["completed":failure==nil,"failure":failure as Any? ?? NSNull(),"elapsedSeconds":ProcessInfo.processInfo.systemUptime-start,"scope":"Overview-only replay; not cold full reprocessing"]
  try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]).write(to:out.appendingPathComponent("result.json"))
  print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self))
 }
}
