import Foundation
import CryptoKit
import SpeechSessionPersistence
struct OnDeviceSummaryService {
 static let isAvailable=false
 func generateFields(transcript:String,contentKind:SummaryContentKind)async throws->VisitSummaryFields{throw SummaryResponseError.network}
}
struct OpenAIChatTransport {
    let fastExperiment = true // All bridge requests belong to the cumulative isolated experiment.
 let bridge:BenchmarkBridge
 let durableJobsURL:URL?=URL(string:"https://benchmark.invalid/jobs")
 let durableConditionWorkflowsURL:URL?=URL(string:"https://benchmark.invalid/conditions")
 let healthProcessingURL:URL?=nil
 func durableRequest(payload:[String:Any],conditionWorkflow:Bool=false,transferProgress:@escaping @Sendable(String)async->Void={_ in})async throws->String{
  try await bridge.perform(payload:payload,conditionWorkflow:conditionWorkflow)
 }
}
actor BenchmarkBridge {
 let root:URL,trace:URL,run:String
 init(root:URL,run:String,trace:URL)throws{self.root=root;self.run=run;self.trace=trace;try FileManager.default.createDirectory(at:trace,withIntermediateDirectories:true)}
 func send(_ value:[String:Any])async throws->[String:Any]{
  try Task.checkCancellation()
  let tag=UUID().uuidString, start=ProcessInfo.processInfo.systemUptime
  let request=trace.appendingPathComponent(tag+".send.json"),response=trace.appendingPathComponent(tag+".receive.json")
  var body=value;body["run"]=run
  try JSONSerialization.data(withJSONObject:body,options:.sortedKeys).write(to:request)
  let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/env")
  process.arguments=["python3",ProcessInfo.processInfo.environment["BENCHMARK_REQUEST_HELPER"]!,root.path,request.path,response.path]
  process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
  let status:Int32=try await withCheckedThrowingContinuation { continuation in
   process.terminationHandler={p in continuation.resume(returning:p.terminationStatus)}
   do{try process.run()}catch{continuation.resume(throwing:error)}
  }
  let elapsed=ProcessInfo.processInfo.systemUptime-start
  try JSONSerialization.data(withJSONObject:["action":value["action"] ?? "unknown","elapsedSeconds":elapsed,"exitCode":status],options:.sortedKeys).write(to:trace.appendingPathComponent(tag+".transport.json"))
  try Task.checkCancellation()
  guard status==0,let data=try? Data(contentsOf:response),let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw SummaryProcessingError.unavailable("Benchmark transport failed; no automatic paid retry")}
  if let error=object["error"] as? String {
   if ["experiment_budget_exhausted","budget_exhausted"].contains(error) { throw SummaryResponseError.quotaExceeded }
   if error == "unauthorized" || error.hasPrefix("Benchmark deployment authentication rejected") { throw SummaryResponseError.signInRequired }
   throw SummaryProcessingError.unavailable(error)
  }
  return object
 }
 func hybrid(_ entries:[SummaryEntry],source:String,original:String,contactName:String?)async throws->[SummaryCheck]{
  guard run.hasPrefix("hybrid-") || run.hasPrefix("combined-") else{return []}
  let start=ProcessInfo.processInfo.systemUptime
  var checks:[SummaryCheck]=[],eligible=0
  if let request=try BenchmarkHybrid.request(entries,source:source,original:original,contactName:contactName){
   eligible=request.candidates.count
   do {
    let job=try await send(["action":"decisions","payload":request.payload])
    if job["state"] as? String == "completed",let result=job["result"] as? [String:Any],let decision=result["decision"] as? [String:Any]{checks=BenchmarkHybrid.accepted(decision,candidates:request.candidates)}
   } catch {
    try Task.checkCancellation()
    if String(describing:error).contains("budget") { throw error }
    // Unknown paid Outcomes retain their reservation; fallback is a distinct Responses request.
   }
  }
  try JSONSerialization.data(withJSONObject:["entries":entries.count,"eligible":eligible,"accepted":checks.count,"fallback":entries.count-checks.count,"elapsedSeconds":ProcessInfo.processInfo.systemUptime-start],options:.sortedKeys).write(to:trace.appendingPathComponent(UUID().uuidString+".hybrid.json"))
  return checks
 }
 func perform(payload:[String:Any],conditionWorkflow:Bool)async throws->String{
  let tag=UUID().uuidString,start=ProcessInfo.processInfo.systemUptime
  try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys).write(to:trace.appendingPathComponent(tag+".request.json"))
  var result=try await send(["action":conditionWorkflow ? "condition-submit":"submit","payload":payload])
  guard let id=result["id"] as? String else{throw SummaryResponseError.invalidFormat}
  // Idempotent submission omits output/diagnostics. Read the full result even when
  // an existing job is already incomplete, before deciding whether to split it.
  if !conditionWorkflow { result=try await send(["action":"job","id":id]) }
  let deadline=ProcessInfo.processInfo.systemUptime+(conditionWorkflow ? 1800:300)
  while true{
   try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:trace.appendingPathComponent(tag+".receipt.json"))
   let state=result["state"] as? String ?? ""
   if state=="completed",let object=result["result"] as? [String:Any],let output=object["output"] as? String{
    try JSONSerialization.data(withJSONObject:["stage":payload["stage"] ?? "condition-workflow","elapsedSeconds":ProcessInfo.processInfo.systemUptime-start,"jobID":id],options:.sortedKeys).write(to:trace.appendingPathComponent(tag+".timing.json"));return output
   }
   if state == "incomplete", let result = result["result"] as? [String:Any],
      let diagnostics = result["diagnostics"] as? [String:Any], diagnostics["incompleteReason"] as? String == "max_output_tokens" {
    throw SummaryResponseError.responseTooLong
   }
   guard ["queued","running","completed"].contains(state) else{throw SummaryProcessingError.unavailable("Benchmark job state: "+state)}
   guard ProcessInfo.processInfo.systemUptime<deadline else{throw SummaryProcessingError.unavailable("Benchmark waiting limit; no paid redispatch")}
   if state=="running"{try await Task.sleep(nanoseconds:1_000_000_000)}
   result=try await send(["action":conditionWorkflow ? "condition-step":(state=="queued" ? "run":"job"),"id":id])
  }
 }
}
