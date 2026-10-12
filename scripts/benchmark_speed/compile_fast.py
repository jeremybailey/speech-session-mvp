"""Compile the actual fast record adapter; do not copy or reimplement processing logic."""
import argparse,hashlib,json,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('output',type=Path);p.add_argument('--downstream',action='store_true');a=p.parse_args()
root=Path(__file__).resolve().parents[2];tools=Path(__file__).resolve().parent;out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
source=(root/'SpeechSessionApp/HealthSummaryModel.swift').read_text()
(out/'FastAdapter.swift').write_text('import Foundation\nimport OSLog\nimport SpeechSessionPersistence\n'+source[source.index('enum SummaryProcessingError:'):source.index('struct ConditionProgressUpdate:')]+source[source.index('enum FastRecordProcessing {'):])
routing=(root/'SpeechSessionApp/SummaryContentRouting.swift').read_text()
(out/'Routing.swift').write_text(routing.split('// MARK: - OpenAI classification')[0]+'\n'+routing[routing.index('enum SummaryPromptAssembly'):])
products=(root/'.build/debug').resolve();maps=products.parent.parent/'Intermediates.noindex/GeneratedModuleMaps'
if (maps/'macosx').exists(): maps=maps/'macosx'
def object_file(name):
 return products/(name+('_Module.o' if (products/(name+'_Module.o')).exists() else '.o'))
args=['swiftc','-parse-as-library','-module-cache-path',str(out/'module-cache'),'-I',str(products),'-L',str(products),str(object_file('SpeechSessionPersistence')),'-lz','-framework','Security']
for module in ['ZipArchive','TransferZip']:args+=['-Xcc','-fmodule-map-file='+str(maps/(module+'.modulemap')),str(object_file(module))]
args += [str(out/'FastAdapter.swift'),str(out/'Routing.swift')]
args += [str(root/'SpeechSessionApp'/n) for n in ['VisitSummaryModels.swift','PractitionerContactsFormatting.swift','GlobalSummaryModels.swift']]
if a.downstream:
 processor=source[source.index('private struct SummaryStageFailure:'):source.index('enum SummaryProcessingError:')]+source[source.index('struct ConditionProgressUpdate:'):source.index('    private func request(stage:')]
 method='''    private func request(stage:String, system:String, user:String, transport:OpenAIChatTransport?, onDevice:Bool, contract:OverviewResponseContract?=nil, allowedFactIDs:[String]=[], expectedCheckIDs:[UUID]=[], formatOverride:[String:Any]?=nil, model:String="gpt-4o-mini")async throws->String {
 guard !onDevice,let transport else{throw SummaryProcessingError.unavailable("Cloud benchmark requires transport")}
 let references = contract == .narrative && !allowedFactIDs.isEmpty ? OverviewReferenceEncoding(ids:allowedFactIDs,input:user+system) : nil
 let format=formatOverride ?? contract?.responseFormat(allowedFactIDs:references?.codes ?? allowedFactIDs) ?? ClinicalResponseFormat.forStage(stage,expectedCheckIDs:expectedCheckIDs)
 let raw=try await transport.durableRequest(payload:["stage":stage,"instructions":ClinicalDraftFormat.instructions(for:system,stage:stage),"input":references?.encode(user) ?? user,"response_format":format])
 return try references?.restore(raw) ?? raw
 }
}
'''
 (out/'DownstreamProcessor.swift').write_text('import Foundation\nimport OSLog\nimport SpeechSessionPersistence\nenum FastDetailsConfiguration { static let enabled = true }\n'+processor+method)
 args += [str(out/'DownstreamProcessor.swift')]
args += [str(tools/n) for n in ['Bridge.swift','Hybrid.swift','DownstreamMain.swift' if a.downstream else 'FastMain.swift']]+['-o',str(out/('downstream-replay' if a.downstream else 'fast-replay'))]
subprocess.run(args,check=True)
files=[root/'SpeechSessionApp/HealthSummaryModel.swift']+list((root/'Sources/SpeechSessionPersistence').glob('*.swift'))
(out/'compiled-source-hashes.json').write_text(json.dumps({str(f.relative_to(root)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2))
print('Actual experimental adapter and persistence pipeline compiled; no model calls.')
