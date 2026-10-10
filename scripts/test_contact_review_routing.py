"""Execute the real prepareSummaries method with offline stage doubles.
No model requests or personal data. Verifies the records-only and retry paths.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root/'SpeechSessionApp/HealthSummaryModel.swift').read_text()
method = source[source.index('    func prepareSummaries('):source.index('    /// An explicit user request must always end')]
program = r'''
import Foundation
import SpeechSessionPersistence
struct OpenAIChatTransport {}
struct SummaryProcessingIssue {
 init(error: Error, session: Session?, completed: Int, remaining: Int) {}
}
@MainActor final class Processor {
 var records = 0, contacts = 0, symptoms = 0
 var failContacts = false
 func process(_ session: Session, related: [SummaryEntry], store: SessionStore, transport: OpenAIChatTransport?, onDevice: Bool,
              progress: @escaping @Sendable (String) async -> Void) async throws { records += 1 }
 func reconcileContacts(store: SessionStore, transport: OpenAIChatTransport?, onDevice: Bool,
                        didCombine: (HealthCombinationUndo) async -> Void) async throws {
  contacts += 1
  if failContacts { throw SummaryResponseError.invalidFormat }
 }
 func reconcileSymptoms(store: SessionStore, transport: OpenAIChatTransport?, onDevice: Bool, force: Bool) async throws { symptoms += 1 }
}
@MainActor final class Model {
 var isProcessing = false, isTransferringData = false
 var error: String?, processingIssue: SummaryProcessingIssue?, overviewNotice: String?, overviewCheckerExplanation: String?
 var snapshot = HealthMemorySnapshot(sessions: [Session(transcript: "Synthetic record")])
 var progressTitle = "", progress = "", progressCurrent = 0, progressTotal = 0, progressValue = 0.0, progressShowsRecordCount = false
 var retryRecordIDs: Set<UUID> = [], contactReviewUndos: [HealthCombinationUndo] = []
 var facts: [HealthFact] = [], overview: String?, needsConditionOrganization = false
 var conditions = 0, overviews = 0
 let processor = Processor()
 let store: SessionStore
 init(store: SessionStore) { self.store = store }
 func refresh() async {}
 static func progressWithinRecord(for stage: String) -> Double { 0 }
 func createOverview(transport: OpenAIChatTransport?, onDevice: Bool) async { overviews += 1 }
 func synthesizeAcceptedConditions(transport: OpenAIChatTransport?, onDevice: Bool, reviewContacts: Bool = true) async {
  conditions += 1
  if reviewContacts { try? await processor.reconcileContacts(store: store, transport: transport, onDevice: onDevice) { _ in } }
 }
''' + method + r'''
}
@main struct Run {
 @MainActor static func main() async throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let store = try SessionStore(storageDirectory: dir)
  let recordsOnly = Model(store: store)
  await recordsOnly.prepareSummaries(transport: nil, onDevice: false, forceAll: true, organizeConditionsAfterRecords: false)
  assert(recordsOnly.processor.records == 1 && recordsOnly.processor.contacts == 1)
  assert(recordsOnly.conditions == 0 && !recordsOnly.isProcessing)
  let combined = Model(store: store)
  await combined.prepareSummaries(transport: nil, onDevice: false, forceAll: true)
  assert(combined.processor.contacts == 1 && combined.conditions == 1)
  let failed = Model(store: store); failed.processor.failContacts = true
  await failed.prepareSummaries(transport: nil, onDevice: false, forceAll: true, organizeConditionsAfterRecords: false)
  assert(failed.processingIssue != nil && !failed.isProcessing)
  failed.processor.failContacts = false
  await failed.prepareSummaries(transport: nil, onDevice: false, retryUnfinished: true, organizeConditionsAfterRecords: false)
  assert(failed.processor.contacts == 2 && failed.processingIssue == nil)
  let overview = Model(store: store)
  await overview.prepareSummaries(transport: nil, onDevice: false, overviewOnly: true)
  assert(overview.overviews == 1 && overview.processor.contacts == 0)
  print("Actual record-processing method: contact review runs for records-only and combined paths, failures surface, retries review contacts, overview stays separate.")
 }
}
'''
products = root/'.build/out/Products/Debug'
maps = root/'.build/out/Intermediates.noindex/GeneratedModuleMaps'
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp); (path/'Run.swift').write_text(program)
    args = ['swiftc','-parse-as-library','-module-cache-path',str(path/'cache'),'-I',str(products),'-L',str(products),'-lSpeechSessionPersistence','-lz','-framework','Security']
    for module in ['ZipArchive','TransferZip']:
        args += ['-Xcc','-fmodule-map-file='+str(maps/(module+'.modulemap')),str(products/(module+'.o'))]
    subprocess.run(args+[str(path/'Run.swift'),'-o',str(path/'run')],check=True)
    subprocess.run([str(path/'run')],check=True)
