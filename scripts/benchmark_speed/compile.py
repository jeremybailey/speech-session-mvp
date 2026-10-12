"""Compile frozen app processor with benchmark-only hooks. Shipping app source is untouched."""
import subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parents[2];tools=Path(__file__).resolve().parent;out=Path(sys.argv[1]).resolve();code=out/'client'
subprocess.run(['git','diff','--exit-code','0e499b6','--','Sources'],cwd=root,check=True,stdout=subprocess.DEVNULL)
processor=(code/'HealthSummaryModel.swift').read_text();processor=processor[processor.index('private struct SummaryStageFailure'):processor.index('    private func request(stage:')]
marker='SummaryParallelWork.map(batches, limit: 1)';assert processor.count(marker)==1
processor=processor.replace(marker,'SummaryParallelWork.map(batches, limit: ["parallel", "combined"].contains(ProcessInfo.processInfo.environment["BENCHMARK_ARM"] ?? "") ? 2 : 1)')
a='''            let raw = try await request(stage: "checking", system: instructions, user: input, transport: transport, onDevice: onDevice, expectedCheckIDs: batch.map(\\.id))
            guard let data = raw.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw invalidResponse }
            var checks = try SummaryResponseError.decodeKeyedChecks(object["decisions"], expectedIDs: batch.map(\\.id))'''
b='''            var checks = try await transport?.bridge.hybrid(batch, source: source, original: session.transcript, contactName: contactName) ?? []
            let remaining = batch.filter { entry in !checks.contains { $0.id == entry.id } }
            if !remaining.isEmpty {
                let fallbackInput = remaining.count == batch.count ? input : try SummarySourceCheck.input(remaining, source: source)
                let raw = try await request(stage: "checking", system: remaining.count == batch.count ? instructions : SummarySourceCheck.instructions(count: remaining.count, contactName: contactName), user: fallbackInput, transport: transport, onDevice: onDevice, expectedCheckIDs: remaining.map(\\.id))
                guard let data = raw.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw invalidResponse }
                checks += try SummaryResponseError.decodeKeyedChecks(object["decisions"], expectedIDs: remaining.map(\\.id))
            }'''
assert processor.count(a)==1;processor=processor.replace(a,b)
hasOverviewEncoding='struct OverviewReferenceEncoding' in processor
requestMethod='''    private func request(stage:String, system:String, user:String, transport:OpenAIChatTransport?, onDevice:Bool, contract:OverviewResponseContract?=nil, allowedFactIDs:[String]=[], expectedCheckIDs:[UUID]=[], model:String="gpt-4o-mini")async throws->String {
 guard !onDevice,let transport else{throw SummaryProcessingError.unavailable("Cloud benchmark requires transport")}
 let format=contract?.responseFormat(allowedFactIDs:allowedFactIDs) ?? ClinicalResponseFormat.forStage(stage,expectedCheckIDs:expectedCheckIDs)
 return try await transport.durableRequest(payload:["stage":stage,"instructions":ClinicalDraftFormat.instructions(for:system,stage:stage),"input":user,"response_format":format])
 }
}
'''
if hasOverviewEncoding:
 requestMethod=requestMethod.replace(' let format=', ' let references = contract == .narrative && !allowedFactIDs.isEmpty ? OverviewReferenceEncoding(ids:allowedFactIDs,input:user+system) : nil\n let requestInput = references?.encode(user) ?? user\n let format=').replace('allowedFactIDs:allowedFactIDs','allowedFactIDs:references?.codes ?? allowedFactIDs').replace(' return try await transport.durableRequest',' let raw = try await transport.durableRequest').replace('"input":user','"input":requestInput').replace('\n }\n}', '\n return try references?.restore(raw) ?? raw\n }\n}')
processor+=requestMethod
(code/'Processor.swift').write_text('import Foundation\nimport OSLog\nimport SpeechSessionPersistence\n'+processor)
routing=(code/'SummaryContentRouting.swift').read_text();(code/'Routing.swift').write_text(routing.split('// MARK: - OpenAI classification')[0]+'\n'+routing[routing.index('enum SummaryPromptAssembly'):])
products=root/'.build/out/Products/Debug';maps=root/'.build/out/Intermediates.noindex/GeneratedModuleMaps'
args=['swiftc','-parse-as-library','-module-cache-path',str(out/'module-cache'),'-I',str(products),'-L',str(products),'-lSpeechSessionPersistence','-lz','-framework','Security']
for module in ['ZipArchive','TransferZip']:args+=['-Xcc','-fmodule-map-file='+str(maps/(module+'.modulemap')),str(products/(module+'.o'))]
baseArgs=args.copy()
args += [str(code/n) for n in ['Processor.swift','Routing.swift','VisitSummaryModels.swift','PractitionerContactsFormatting.swift','GlobalSummaryModels.swift']]
args += [str(tools/n) for n in ['Bridge.swift','Hybrid.swift','Main.swift']]+['-o',str(out/'replay')]
subprocess.run(args,check=True)
if hasOverviewEncoding:
 helper=processor[processor.index('struct OverviewReferenceEncoding'):processor.index('actor RecordSummaryProcessor')]
 (code/'OverviewReferenceEncoding.swift').write_text('import Foundation\nimport SpeechSessionPersistence\n'+helper)
 subprocess.run(baseArgs+[str(code/'OverviewReferenceEncoding.swift'),str(tools/'OverviewReferenceTests.swift'),'-o',str(out/'overview-reference-tests')],check=True)
 subprocess.run([str(out/'overview-reference-tests')],check=True)
 subprocess.run(args[:-3]+[str(tools/'OverviewReplay.swift'),'-o',str(out/'overview-replay')],check=True)
subprocess.run(baseArgs+[str(tools/'Hybrid.swift'),str(tools/'HybridTests.swift'),'-o',str(out/'hybrid-tests')],check=True)
subprocess.run([str(out/'hybrid-tests')],check=True)
subprocess.run(baseArgs+[str(tools/'Hybrid.swift'),str(tools/'Controls.swift'),'-o',str(out/'controls-generator')],check=True)
subprocess.run([str(out/'controls-generator'),str(out/'controls.json')],check=True)
print('Frozen build-10 processor compiled with isolated benchmark hooks.')
