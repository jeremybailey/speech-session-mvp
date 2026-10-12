"""Offline recovery checks against the actual app transport implementation."""
import subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
source=r'''import Foundation
@main struct Tests {
 static func main() async throws {
  do {try OpenAIChatTransport.validateDurableCompletion(state:"incomplete",incompleteReason:"max_output_tokens");fatalError("Output limit not classified")}
  catch {assert((error as NSError).domain=="AIProcessingOutput")}
  try OpenAIChatTransport.validateDurableCompletion(state:"completed",incompleteReason:"max_output_tokens")
  try OpenAIChatTransport.validateDurableCompletion(state:"incomplete",incompleteReason:"content_filter")
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
 subprocess.run([str(p/'test')],check=True)
