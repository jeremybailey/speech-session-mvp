"""Compile the actual app parser and prompt assembly against the built Swift library.

Run `swift test` first. Only the networking classifier is omitted; parser, entry
factory and prompt bodies are compiled from their production sources unchanged.
All assertions use synthetic content. No model calls.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--export-contracts', type=Path)
options = parser.parse_args()
products = root / '.build/out/Products/Debug'
maps = root / '.build/out/Intermediates.noindex/GeneratedModuleMaps'
routing = (root / 'SpeechSessionApp/SummaryContentRouting.swift').read_text()
kind = routing.split('// MARK: - OpenAI classification')[0]
prompts = routing[routing.index('enum SummaryPromptAssembly'):]
test = r'''
import Foundation
import SpeechSessionPersistence
let raw = #"{"medications":[{"name":"Example tablet","strength":"5 mg","frequency":"daily","instructions":"Take with food; stop if dizzy","reasonStarted":"For the documented concern","sourceExcerpt":"Take the example tablet with food.","eventDate":"2026-01-02","clinicalStatus":"current","factKey":"example-tablet","topicNames":["Example concern"],"actionKind":"homecare","statusExplicit":true,"reviewReason":"Check timing","practitioner":"Example clinician","assessmentMethod":"Patient report"}]}"#
let fields = VisitSummaryJSONParser.fields(fromAssistantContent: raw)!
let fact = fields.factsByCategory[.medications]!.first!
assert(fact.details.contains("5 mg") && fact.details.contains("daily"))
assert(fact.details.contains("Take with food; stop if dizzy"))
assert(fact.details.contains("Reason started: For the documented concern"))
for key in ["sourceExcerpt", "factKey", "topicNames", "actionKind", "clinicalStatus", "statusExplicit", "reviewReason", "eventDate", "practitioner", "assessmentMethod"] {
    assert(!fact.details.contains(key + ":"), key)
}
assert(fact.evidence?.excerpt == "Take the example tablet with food.")
assert(fact.evidence?.topicNames == ["Example concern"])
assert(fact.evidence?.eventDate == "2026-01-02")
assert(fact.evidence?.practitioner == "Example clinician")
assert(fact.evidence?.reasonStarted == "For the documented concern")
let legacy = VisitSummaryJSONParser.fields(fromAssistantContent: #"{"treatmentPlan":["Take a walk if comfortable."]}"#)!
assert(legacy.factsByCategory[.carePlan]!.count == 1)
let plan = VisitSummaryJSONParser.fields(fromAssistantContent: #"{"treatmentPlan":[{"title":"Try a short walk","instruction":"Try a short walk if comfortable.","sourceExcerpt":"Try a short walk if comfortable.","actionKind":"homecare","reviewTiming":"in two weeks"}]}"#)!
assert(plan.factsByCategory[.carePlan]!.first!.evidence?.careInstruction?.reviewTiming == "in two weeks")
let combined = VisitSummaryJSONParser.fields(fromAssistantContent: #"{"medications":[{"name":"Example tablet","details":"Patient reports missing doses for the last week.","strength":"5 mg","instructions":"Take with food; stop if dizzy","reportedBy":"Patient","statementType":"Patient report","statementStatus":"Current"}]}"#)!
let combinedFact = combined.factsByCategory[.medications]!.first!
assert(combinedFact.details.contains("missing doses for the last week"))
assert(combinedFact.details.contains("5 mg") && combinedFact.details.contains("Take with food; stop if dizzy"))
assert(!combinedFact.details.contains("reportedBy:") && !combinedFact.details.contains("details:"))
let planned = VisitSummaryJSONParser.fields(fromAssistantContent: #"{"followUp":[{"title":"Return if the rash persists","details":"Nurse recommends returning in ten days only if the rash persists; not yet booked.","instruction":"Return in ten days only if the rash persists.","reportedBy":"Nurse","statementType":"Follow-up","statementStatus":"Planned","statusExplicit":false,"actionKind":"follow_up","sourceExcerpt":"Come back in ten days if the rash persists."}]}"#)!
let session = Session(transcript: "Nurse: Come back in ten days if the rash persists. Patient: I have not booked yet.")
let entry = SummaryEntryFactory.entries(from: planned, session: session).first!
let shown = HealthDetailPresentation.fields(entry)
assert(shown.contains { $0.label == "Reported by" && $0.value == "Nurse" })
assert(shown.contains { $0.label == "Statement status" && $0.value == "Planned" })
assert(shown.contains { $0.label == "Statement type" && $0.value == "Follow-up" })
assert(entry.evidence?.statusExplicit == false && entry.evidence?.actionKind == "follow_up")
// A boolean alone cannot turn a default current status into a source claim.
for status in ["Planned", "Uncertain", ""] {
    let raw = "{\"treatmentPlan\":[{\"title\":\"Optional review\",\"details\":\"Consider review if needed.\",\"statementStatus\":\"" + status + "\",\"statusExplicit\":true}]}"
    let parsed = VisitSummaryJSONParser.fields(fromAssistantContent: raw)!
    let item = SummaryEntryFactory.entries(from: parsed, session: session).first!
    assert(item.evidence?.statusExplicit == false)
    assert(!SummaryVerification.requiredFields(item).contains("clinicalStatus"))
}
let historical = VisitSummaryJSONParser.fields(fromAssistantContent: #"{"treatmentPlan":[{"title":"Counselling provided","details":"Counselling was provided at the prior visit.","statementStatus":"Historical","statusExplicit":true}]}"#)!
let historicalEntry = SummaryEntryFactory.entries(from: historical, session: session).first!
assert(historicalEntry.clinicalStatus == .past && historicalEntry.evidence?.statusExplicit == true)
// Exercise the strict extraction format used by the cloud pipeline, including
// statusExplicit inside attributes, persistence, and the independent checker.
let strictHistorical = #"{"title":"Prior counselling","facts":[{"category":"carePlan","title":"Counselling provided","details":"Counselling was provided at the prior visit.","sourceExcerpt":"Counselling was provided at the prior visit.","reportedBy":"Clinician","statementType":"Education","statementStatus":"Historical","attributes":[{"name":"statusExplicit","value":true}]}]}"#
let strictHistoricalEntry = SummaryEntryFactory.entries(from: VisitSummaryJSONParser.fields(fromAssistantContent: strictHistorical)!, session: session).first!
assert(strictHistoricalEntry.clinicalStatus == .past)
assert(strictHistoricalEntry.evidence?.statusExplicit == true)
assert(SummaryVerification.requiredFields(strictHistoricalEntry).contains("clinicalStatus"))
let persistedHistorical = try JSONDecoder().decode(SummaryEntry.self, from: JSONEncoder().encode(strictHistoricalEntry))
assert(persistedHistorical.clinicalStatus == .past)
let historicalCheckInput = try SummarySourceCheck.input([persistedHistorical], source: session.transcript)
assert(historicalCheckInput.contains("past") && historicalCheckInput.contains("Historical"))
let conflicting = VisitSummaryJSONParser.fields(fromAssistantContent: #"{"treatmentPlan":[{"title":"Review","details":"A review.","clinicalStatus":"current","statementStatus":"Historical","statusExplicit":true}]}"#)!
let conflictingEntry = SummaryEntryFactory.entries(from: conflicting, session: session).first!
assert(conflictingEntry.clinicalStatus == .current)
assert(conflictingEntry.fields.contains { $0.label == "Statement status" && $0.value == "Historical" })
// Explicit conflicting claims remain visible to the checker rather than silently reconciled.
assert(entry.evidence?.careInstruction?.isRecurring == nil)
let required = SummaryVerification.requiredFields(entry)
assert(required.contains("field:Reported by") && required.contains("field:Statement status"))
assert(!required.contains("clinicalStatus"))
let checkInput = try SummarySourceCheck.input([entry], source: session.transcript)
assert(checkInput.contains("field:Statement type") && checkInput.contains("not yet booked"))
let saved = try JSONEncoder().encode(entry)
let restored = try JSONDecoder().decode(SummaryEntry.self, from: saved)
assert(HealthDetailPresentation.fields(restored).map(\.value) == shown.map(\.value))
let malformedLegacy = VisitSummaryJSONParser.fields(fromAssistantContent: #"{"otherNotes":[{"factKey":"not-a-fact","reportedBy":"Patient","sourceExcerpt":"An excerpt alone is not a clinical draft."}]}"#)!
assert(SummaryEntryFactory.entries(from: malformedLegacy, session: session).isEmpty)
assert(!malformedLegacy.markdownFromStructuredSections().contains("factKey"))
let strict = #"{"title":"Rash follow-up","facts":[{"category":"followUp","title":"Return if rash persists","details":"Nurse recommends a return in ten days only if the rash persists; not yet booked.","sourceExcerpt":"Come back in ten days if the rash persists.","reportedBy":"Nurse","statementType":"Follow-up","statementStatus":"Planned","attributes":[{"name":"actionKind","value":"follow_up"},{"name":"statusExplicit","value":false}]}]}"#
let strictFields = VisitSummaryJSONParser.fields(fromAssistantContent: strict)!
let strictEntry = SummaryEntryFactory.entries(from: strictFields, session: session).first!
assert(strictEntry.details.contains("not yet booked") && strictEntry.category == .followUp)
assert(HealthDetailPresentation.fields(strictEntry).contains { $0.label == "Statement status" && $0.value == "Planned" })
assert(VisitSummaryJSONParser.fields(fromAssistantContent: #"{"title":"Bad response","facts":[{"category":"symptoms","sourceExcerpt":"quote only"}]}"#) == nil)
let strictMedicine = #"{"title":"Medicine review","facts":[{"category":"medications","title":"Example tablet","details":"Patient reports missing doses.","sourceExcerpt":"I missed doses of the example tablet.","reportedBy":"Patient","statementType":"Patient report","statementStatus":"Current","attributes":[{"name":"dose","value":"5 mg"},{"name":"instructions","value":"Take with food."}]}]}"#
let medicineEntry = SummaryEntryFactory.entries(from: VisitSummaryJSONParser.fields(fromAssistantContent: strictMedicine)!, session: session).first!
assert(medicineEntry.details.contains("missing doses") && medicineEntry.details.contains("5 mg") && medicineEntry.details.contains("Take with food."))
assert(!medicineEntry.details.contains("title:") && !medicineEntry.details.contains("reportedBy:"))
for kind in SummaryContentKind.allCases {
    let prompt = SummaryPromptAssembly.openAISummaryPrompts(contentKind: kind)
    assert(prompt.system.contains("each fact needs its own sourceExcerpt"))
    assert(prompt.system.contains("Relative timing remains verbatim"))
}
print("Production parser preserves clinical directions and structured evidence without metadata leakage; legacy decoding remains supported.")
if CommandLine.arguments.count == 2 {
    let contracts = Dictionary(uniqueKeysWithValues: SummaryContentKind.allCases.map { kind in
        let prompt = SummaryPromptAssembly.openAISummaryPrompts(contentKind: kind)
        return (kind.rawValue, ["instructions": ClinicalDraftFormat.instructions(for: prompt.system, stage: "extraction"), "userPrefix": prompt.userPrefix,
                               "response_format": ClinicalResponseFormat.forStage("extraction")] as [String: Any])
    })
    try JSONSerialization.data(withJSONObject: contracts, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
'''
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp)
    (path / 'Routing.swift').write_text(kind + '\n' + prompts)
    (path / 'main.swift').write_text(test)
    args = ['swiftc', '-module-cache-path', str(path / 'cache'), '-I', str(products), '-L', str(products),
            '-lSpeechSessionPersistence', '-lz', '-framework', 'Security']
    for module in ('ZipArchive', 'TransferZip'):
        args += ['-Xcc', '-fmodule-map-file=' + str(maps / (module + '.modulemap')), str(products / (module + '.o'))]
    args += [str(root / 'SpeechSessionApp' / name) for name in
             ('VisitSummaryModels.swift', 'PractitionerContactsFormatting.swift', 'GlobalSummaryModels.swift')]
    args += [str(path / 'Routing.swift'), str(path / 'main.swift'), '-o', str(path / 'test')]
    subprocess.run(args, check=True)
    subprocess.run([str(path / 'test')] + ([str(options.export_contracts)] if options.export_contracts else []), check=True)
