import Foundation
import SpeechSessionPersistence
struct Fixture:Decodable {let jobID:String;let raw:String;let entries:[SummaryEntry];let source:String}
@main struct OfflineCheck {
 static func main()throws{
  let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
  let fixtures=try decoder.decode([Fixture].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
  var result:[[String:Any]]=[]
  for f in fixtures {
   do {let checks=try FastDetailsCheck.decode(f.raw,entries:f.entries,source:f.source);result.append(["jobID":f.jobID,"decoded":true,"checks":checks.count])}
   catch {result.append(["jobID":f.jobID,"decoded":false,"error":String(describing:error)])}
  }
  try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
  print("Offline checks replayed against the combined decoder; no API requests.")
 }
}
