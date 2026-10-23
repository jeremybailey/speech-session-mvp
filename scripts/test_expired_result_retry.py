"""Offline production transport regression: automatic versus explicit expired-result retry."""
from pathlib import Path
import subprocess, tempfile, plistlib
root = Path(__file__).resolve().parents[1]
source = r'''
import Foundation
import CryptoKit
final class Fixture: URLProtocol, @unchecked Sendable {
    static var replacements = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method=request.httpMethod!, url=request.url!
        var status=200
        let body:String
        if method == "POST" {
            var data=request.httpBody ?? Data()
            if let stream=request.httpBodyStream {
                stream.open(); defer {stream.close()}
                var buffer=[UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable { let n=stream.read(&buffer,maxLength:buffer.count); if n<=0 {break};data.append(contentsOf:buffer.prefix(n)) }
            }
            let p=try! JSONSerialization.jsonObject(with:data) as! [String:Any]
            if p["retry_expired_job_id"] != nil { Self.replacements += 1; body=#"{"id":"new","state":"completed"}"# }
            else {body=#"{"id":"old","state":"completed"}"#}
        } else if method == "PATCH" {status=405;body=""}
        else if url.query == "id=new" {body=#"{"id":"new","state":"completed","result":{"output":"Checked overview"}}"#}
        else {body=#"{"id":"old","state":"completed","result":null}"#}
        client!.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client!.urlProtocol(self,didLoad:Data(body.utf8));client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Tests {
    static func main() async throws {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[Fixture.self]
        let subject="synthetic-expiry-"+UUID().uuidString
        let claims=try JSONSerialization.data(withJSONObject:["sub":subject,"iss":"https://synthetic.invalid"])
        let token="Bearer e30."+claims.base64EncodedString().replacingOccurrences(of:"=",with:"")+".signature"
        var transport=OpenAIChatTransport.kindeProxy(chatURL:URL(string:"https://synthetic.invalid/api/v1/chat/completions")!,accessToken:{token})
        let payload:[String:Any]=["stage":"overview","input":"Synthetic facts","instructions":"fixture","response_format":["type":"json_object"]]
        let body=try DurableRequestIdentity.body(payload,conditionWorkflow:false)
        let key=try DurableResultReceipt.key(body:body,url:transport.durableJobsURL!,authorization:token,experimental:false)
        defer { if let dir=try? DurableResultReceipt.directory(){try? FileManager.default.removeItem(at:dir.appendingPathComponent(key+".json"))} }
        do { _ = try await transport.durableRequest(payload:payload,sessionConfiguration:config);fatalError("Automatic renewal") }
        catch {assert((error as NSError).code == 410)}
        assert(Fixture.replacements == 0)
        transport.allowsExpiredResultRetry=true
        let output=try await transport.durableRequest(payload:payload,sessionConfiguration:config)
        assert(output == "Checked overview" && Fixture.replacements == 1)
        let reused=try await transport.durableRequest(payload:payload,sessionConfiguration:config)
        assert(reused == output && Fixture.replacements == 1)
        print("PASS: automatic expiry stops; explicit retry renews once; local receipt avoids another submission")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    path=Path(directory); swift=path/'Tests.swift';swift.write_text(source)
    info=path/'Info.plist';info.write_bytes(plistlib.dumps({'DurableAIProcessingEnabled':True}))
    exe=path/'test'
    subprocess.run(['swiftc','-module-cache-path',str(path/'cache'),str(root/'SpeechSessionApp/OpenAIRouting.swift'),str(swift),'-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',str(info),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
