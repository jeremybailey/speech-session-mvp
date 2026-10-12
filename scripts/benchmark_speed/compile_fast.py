"""Compile the actual fast record adapter; do not copy or reimplement processing logic."""
import argparse,hashlib,json,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('output',type=Path);a=p.parse_args()
root=Path(__file__).resolve().parents[2];tools=Path(__file__).resolve().parent;out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
source=(root/'SpeechSessionApp/HealthSummaryModel.swift').read_text()
(out/'FastAdapter.swift').write_text('import Foundation\nimport OSLog\nimport SpeechSessionPersistence\n'+source[source.index('enum SummaryProcessingError:'):source.index('struct ConditionProgressUpdate:')]+source[source.index('enum FastRecordProcessing {'):])
routing=(root/'SpeechSessionApp/SummaryContentRouting.swift').read_text()
(out/'Routing.swift').write_text(routing.split('// MARK: - OpenAI classification')[0]+'\n'+routing[routing.index('enum SummaryPromptAssembly'):])
products=root/'.build/apple/Products/Debug';maps=root/'.build/apple/Intermediates.noindex/GeneratedModuleMaps/macosx'
args=['swiftc','-parse-as-library','-module-cache-path',str(out/'module-cache'),'-I',str(products),'-L',str(products),str(products/'SpeechSessionPersistence_Module.o'),'-lz','-framework','Security']
for module in ['ZipArchive','TransferZip']:args+=['-Xcc','-fmodule-map-file='+str(maps/(module+'.modulemap')),str(products/(module+'_Module.o'))]
args += [str(out/'FastAdapter.swift'),str(out/'Routing.swift')]
args += [str(root/'SpeechSessionApp'/n) for n in ['VisitSummaryModels.swift','PractitionerContactsFormatting.swift','GlobalSummaryModels.swift']]
args += [str(tools/n) for n in ['Bridge.swift','Hybrid.swift','FastMain.swift']]+['-o',str(out/'fast-replay')]
subprocess.run(args,check=True)
files=[root/'SpeechSessionApp/HealthSummaryModel.swift']+list((root/'Sources/SpeechSessionPersistence').glob('*.swift'))
(out/'compiled-source-hashes.json').write_text(json.dumps({str(f.relative_to(root)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2))
print('Actual experimental adapter and persistence pipeline compiled; no model calls.')
