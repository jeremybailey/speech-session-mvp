import Foundation
import SpeechSessionPersistence

/// Synthetic source/claim pairs, passed through the exact experimental prompt builder.
@main struct Controls {
 static func main() throws {
  let cases = [
   ("negation", "The patient denies fever.", "The patient has fever.", "Fail"),
   ("conditional", "If symptoms persist, call Friday.", "The patient called Friday.", "Fail"),
   ("medication", "Prescribed 5 mg once daily; not yet started.", "Taking 10 mg twice daily.", "Fail"),
   ("wrong-person", "The patient's sister has asthma.", "The patient has asthma.", "Fail"),
   ("supported", "The patient reports a cough.", "The patient reports a cough.", "Pass")
  ]
  let rows = try cases.map { name, source, claim, expected -> [String:Any] in
   var entry = SummaryEntry(category:.symptoms,title:claim);entry.sourceExcerpt=source
   let request = try BenchmarkHybrid.request([entry],source:source,original:source,contactName:nil)!
   // Expected verdict is local test metadata; controls.py sends only payload.
   return ["name":name,"expected":expected,"payload":request.payload]
  }
  try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
 }
}
