import Foundation
import SpeechSessionPersistence
actor Meter {
 var active=0,peak=0
 func start(){active += 1;peak=max(peak,active)}
 func finish(){active -= 1}
}
@main struct Tests {
 static func main()async throws{
  let cases:[(String,String)]=[
   ("The patient denies fever.","The patient has fever."),
   ("If symptoms persist, call Friday.","The patient called Friday."),
   ("Prescribed 5 mg once daily; not yet started.","Taking 10 mg twice daily."),
   ("The patient's sister has asthma.","The patient has asthma.")]
  for (source,claim) in cases{
   var entry=SummaryEntry(category:.symptoms,title:claim);entry.sourceExcerpt=source
   let plan=try BenchmarkHybrid.request([entry],source:source,original:source,contactName:nil)!
   let input=plan.payload["input"] as! String
   assert(input.contains(source));assert(input.contains(claim))
   for choice in ["Fail","Review"]{
    let answer:[String:Any]=["name":entry.id.uuidString,"type":"choice","choice":choice,"confidence":1.0,"probabilities":[["value":"Pass","probability":0.0],["value":"Fail","probability":choice=="Fail" ? 1.0:0.0],["value":"Review","probability":choice=="Review" ? 1.0:0.0]]]
    assert(BenchmarkHybrid.accepted(["model":"gpt-6-luna","answers":[answer]],candidates:plan.candidates).isEmpty)
   }
   assert(BenchmarkHybrid.accepted(["model":"gpt-6-luna","answers":[["name":entry.id.uuidString,"type":"refusal"]]],candidates:plan.candidates).isEmpty)
   entry.sourceExcerpt="invented quotation"
   let noQuote = try BenchmarkHybrid.request([entry],source:source,original:source,contactName:nil);assert(noQuote==nil)
   entry.sourceExcerpt=nil
   let missingQuote = try BenchmarkHybrid.request([entry],source:source,original:source,contactName:nil);assert(missingQuote==nil)
  }
  let source="The patient reports a cough."
  var entry=SummaryEntry(category:.symptoms,title:"Cough");entry.sourceExcerpt=source
  let plan=try BenchmarkHybrid.request([entry],source:source,original:source,contactName:nil)!
  let good:[String:Any]=["name":entry.id.uuidString,"type":"choice","choice":"Pass","confidence":1.0,"probabilities":[["value":"Pass","probability":1.0],["value":"Fail","probability":0.0],["value":"Review","probability":0.0]]]
  var low=good;low["confidence"]=0.98
  assert(BenchmarkHybrid.accepted(["model":"gpt-6-luna","answers":[low]],candidates:plan.candidates).isEmpty)
  var malformed=good;malformed["probabilities"]=[["value":"Pass","probability":1.0],["value":"Pass","probability":0.0],["value":"Review","probability":0.0]]
  assert(BenchmarkHybrid.accepted(["model":"gpt-6-luna","answers":[malformed]],candidates:plan.candidates).isEmpty)
  let wrongOriginal=try BenchmarkHybrid.request([entry],source:source,original:"Another original",contactName:nil);assert(wrongOriginal==nil)
  let accepted=BenchmarkHybrid.accepted(["model":"gpt-6-luna","answers":[good]],candidates:plan.candidates)
  assert(accepted.count==1 && accepted[0].citations.allSatisfy{$0.excerpt==source})
  for answers in [[],[good,good],[["name":"wrong","type":"refusal"]]] as [[[String:Any]]]{assert(BenchmarkHybrid.accepted(["model":"gpt-6-luna","answers":answers],candidates:plan.candidates).isEmpty)}
  let meter=Meter()
  let result=try await SummaryParallelWork.map([0,1,2,3],limit:2){n in await meter.start();try await Task.sleep(nanoseconds:UInt64(4-n)*10_000_000);await meter.finish();return n}
  assert(result == [0,1,2,3]);let peak=await meter.peak;assert(peak==2)
  let task=Task {try await SummaryParallelWork.map([1,2,3],limit:2){n in try await Task.sleep(nanoseconds:1_000_000_000);return n}}
  task.cancel();do{_ = try await task.value;fatalError("Cancellation ignored")}catch is CancellationError{}
  print("Hybrid quotation gates, negative/uncertain/refused/malformed fallbacks, order, concurrency and cancellation passed. Controlled verdicts do not establish live model accuracy.")
 }
}
