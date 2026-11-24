"""Compile current full app orchestration, replacing only device/network adapters."""
import argparse,hashlib,json,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('experiment',type=Path);p.add_argument('products',type=Path);a=p.parse_args()
out=a.experiment.resolve();root=out/'combined';code=out/'harness';code.mkdir(exist_ok=True);tools=Path(__file__).resolve().parent
s=(root/'SpeechSessionApp/HealthSummaryModel.swift').read_text()
s=s[:s.index('/// Requests the finite')]+s[s.index('/// High-frequency'):]
s=s.replace('import UIKit\n','').replace('import FoundationModels\n','')
start=s.index('    fileprivate func request(stage:');end=s.index('\n\nprivate struct FastRecordOutcome:',start)
# Preserve exactly the durable cloud branch's formatting and reference encoding.
method='''    fileprivate func request(stage:String, system:String, user:String, transport:OpenAIChatTransport?, onDevice:Bool, contract:OverviewResponseContract?=nil, allowedFactIDs:[String]=[], expectedCheckIDs:[UUID]=[], formatOverride:[String:Any]?=nil, model:String="gpt-4o-mini")async throws->String {
 guard !onDevice,let transport else{throw SummaryProcessingError.unavailable("Cloud benchmark requires transport")}
 let references = contract == .narrative && !allowedFactIDs.isEmpty ? OverviewReferenceEncoding(ids:allowedFactIDs,input:user+system) : nil
 let format=formatOverride ?? contract?.responseFormat(allowedFactIDs:references?.codes ?? allowedFactIDs) ?? ClinicalResponseFormat.forStage(stage,expectedCheckIDs:expectedCheckIDs)
 let raw=try await transport.durableRequest(payload:["stage":stage,"instructions":ClinicalDraftFormat.instructions(for:system,stage:stage),"input":references?.encode(user) ?? user,"response_format":format])
 return try references?.restore(raw) ?? raw
 }
}
'''
s=s[:start]+method+s[end:]
configuration=(root/'SpeechSessionApp/OpenAIRouting.swift').read_text();s += '\n'+configuration[configuration.index('enum FastDetailsConfiguration {'):configuration.index('/// Retries only the same HTTP')]
s=s.replace('UserDefaults.standard','BenchmarkDefaults.value')
(code/'Model.swift').write_text(s)
routing=(root/'SpeechSessionApp/SummaryContentRouting.swift').read_text();(code/'Routing.swift').write_text(routing.split('// MARK: - OpenAI classification')[0]+'\n'+routing[routing.index('enum SummaryPromptAssembly'):])
bridge=(tools.parent/'benchmark_speed/Bridge.swift').read_text().replace('let fastExperiment = true','let fastExperiment = false')
bridge=bridge.replace(' let bridge:BenchmarkBridge',' func fastDetailsTransport() throws -> Self { self }\n let bridge:BenchmarkBridge')
bridge=bridge.replace(' func fastDetailsTransport()', ' func fastDetailsCapacity() async throws -> Int { let result = try await bridge.send(["action":"capacity"]); guard let limit=result["maxInFlight"] as? Int else { throw SummaryResponseError.invalidFormat }; return limit }\n func fastDetailsTransport()')
bridge=bridge[:bridge.index(' func hybrid(')]+bridge[bridge.index(' func perform('):]
bridge+='\nenum BenchmarkDefaults { static let value = UserDefaults(suiteName: "whole-history-" + ProcessInfo.processInfo.environment["BENCHMARK_RUN_ID"]!)! }\n'
(code/'Bridge.swift').write_text(bridge)
products=a.products.resolve();maps=products.parent.parent/'Intermediates.noindex/GeneratedModuleMaps'
if (maps/'macosx').exists():maps=maps/'macosx'
def objectfile(n):return products/(n+('_Module.o' if (products/(n+'_Module.o')).exists() else '.o'))
args=['swiftc','-parse-as-library','-module-cache-path',str(code/'module-cache'),'-I',str(products),'-L',str(products),str(objectfile('SpeechSessionPersistence')),'-lz','-framework','Security']
for module in ['ZipArchive','TransferZip']:args+=['-Xcc','-fmodule-map-file='+str(maps/(module+'.modulemap')),str(objectfile(module))]
args += [str(code/n) for n in ['Model.swift','Routing.swift','Bridge.swift']]
args += [str(root/'SpeechSessionApp'/n) for n in ['VisitSummaryModels.swift','PractitionerContactsFormatting.swift','GlobalSummaryModels.swift']]
args += [str(tools/'Main.swift'),'-o',str(code/'baseline-replay')]
subprocess.run(args,check=True)
(code/'source-hashes.json').write_text(json.dumps({str(f.relative_to(root)):hashlib.sha256(f.read_bytes()).hexdigest() for folder in ['Sources','SpeechSessionApp'] for f in (root/folder).rglob('*.swift')},indent=2))
print('Current full HealthSummaryModel compiled with isolated store, defaults and network bridge.')
