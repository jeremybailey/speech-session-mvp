"""Offline recovery checks against the actual app transport implementation."""
import subprocess,tempfile,os
from pathlib import Path
root=Path(__file__).resolve().parents[1]
source=r'''import Foundation
@main struct Tests {
 static func main() async throws {
  assert(FastDetailsConfiguration.enabled && !FastDetailsConfiguration.experimental, "Normal build must use checked details without experiment accounting")
  do {try OpenAIChatTransport.validateDurableCompletion(state:"incomplete",incompleteReason:"max_output_tokens");fatalError("Output limit not classified")}
  catch {assert((error as NSError).domain=="AIProcessingOutput")}
  try OpenAIChatTransport.validateDurableCompletion(state:"completed",incompleteReason:"max_output_tokens")
  try OpenAIChatTransport.validateDurableCompletion(state:"incomplete",incompleteReason:"content_filter")
  let normal=OpenAIChatTransport.kindeProxy(chatURL:URL(string:"https://speech-session-mvp.vercel.app/api/v1/chat/completions")!,accessToken:{"Bearer synthetic"})
  let fast=try normal.fastDetailsTransport(experimental:true)
  let release=try normal.fastDetailsTransport(experimental:false)
  var releaseRequest=URLRequest(url:normal.chatCompletionsURL)
  release.applyExperimentHeader(to:&releaseRequest)
  assert(releaseRequest.value(forHTTPHeaderField:"X-CollectiveCare-Pipeline")==nil)
  assert(fast.chatCompletionsURL==normal.chatCompletionsURL)
  var request=URLRequest(url:normal.chatCompletionsURL)
  normal.applyExperimentHeader(to:&request)
  assert(request.value(forHTTPHeaderField:"X-CollectiveCare-Pipeline")==nil)
  fast.applyExperimentHeader(to:&request)
  assert(request.value(forHTTPHeaderField:"X-CollectiveCare-Pipeline")=="fast-details")
  do {_ = try OpenAIChatTransport.direct(apiKey:"synthetic").fastDetailsTransport();fatalError("Direct route allowed")} catch {}
  var attempts=0
  let value=try await DurableNetworkRecovery.run(sleep:{_ in}) {
   attempts += 1
   if attempts<3 {throw URLError(.networkConnectionLost)}
   return "same-job-output"
  }
  assert(attempts==3 && value=="same-job-output")
  for code in [401,402,403,500] {
   attempts=0
   do { _ = try await DurableNetworkRecovery.run(sleep:{_ in}) { () -> String in
    attempts += 1;throw NSError(domain:"AIProcessing",code:code)
   };fatalError("Expected failure") } catch {assert(attempts==1)}
  }
  attempts=0
  do {_ = try await DurableNetworkRecovery.run(sleep:{_ in}) { () -> String in
   attempts += 1;throw URLError(.timedOut)
  };fatalError("Expected timeout") } catch {assert(attempts==3)}
  let task=Task {try await DurableNetworkRecovery.run { () -> Int in try Task.checkCancellation();throw URLError(.timedOut) }}
  task.cancel()
  do {_=try await task.value;fatalError("Cancellation lost")} catch is CancellationError {}
  print("Transient exchanges retry at most twice; auth, budget and service errors do not retry; cancellation exits.")
 }
}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp);(p/'Test.swift').write_text(source)
 subprocess.run(['swiftc','-module-cache-path',str(p/'cache'),str(root/'SpeechSessionApp/OpenAIRouting.swift'),str(p/'Test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,env={k:v for k,v in os.environ.items() if k != "COLLECTIVECARE_FAST_DETAILS"})
