import Foundation
import CryptoKit

public struct RecordUpdateReceipt: Codable, Sendable, Equatable {
    public var id: UUID
    public var sources: [String:String]
    public var state: String
    public var publishedUnits: [String]
    public init(id: UUID = UUID(), sources: [String:String], state: String = "queued", publishedUnits: [String] = []) {
        self.id=id; self.sources=sources; self.state=state; self.publishedUnits=publishedUnits
    }
}
public enum IncrementalRecordUpdate {
    public static let version = "incremental-records-v1"
    public static func mayReplaceOverview(state: String, explicitlyRequested: Bool) -> Bool {
        explicitlyRequested && ["blocked", "completed_with_withheld_items"].contains(state)
    }
    public static func sourceHash(_ text: String) -> String { SHA256.hash(data:Data(text.utf8)).map {String(format:"%02x",$0)}.joined() }
    public static func stableID(_ text: String) -> UUID {
        let h=sourceHash(text); let parts=[String(h.prefix(8)),String(h.dropFirst(8).prefix(4)),String(h.dropFirst(12).prefix(4)),String(h.dropFirst(16).prefix(4)),String(h.dropFirst(20).prefix(12))]
        return UUID(uuidString:parts.joined(separator:"-"))!
    }
    public static func entries(_ facts: [IncrementalRecordFact], session: Session) throws -> [SummaryEntry] {
        var seen=Set<String>()
        return try facts.compactMap { f in
            guard f.recordID.lowercased()==session.id.uuidString.lowercased(), f.sourceHash==sourceHash(session.transcript),
                  let category=SummaryEntryCategory(rawValue:f.category),!f.quote.isEmpty,session.transcript.contains(f.quote),
                  f.start>=0, !f.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw SummaryCommitError.sourceChanged}
            let scalars=Array(session.transcript.unicodeScalars),length=f.quote.unicodeScalars.count
            guard f.start+length<=scalars.count,String(String.UnicodeScalarView(scalars[f.start..<f.start+length]))==f.quote else {throw SummaryCommitError.sourceChanged}
            guard seen.insert(f.occurrenceID).inserted else {return nil}
            let values=Dictionary(f.fields.map {($0.key,$0.value)},uniquingKeysWith: {first,_ in first})
            guard values.count==f.fields.count,values.values.allSatisfy({!$0.isEmpty && f.quote.contains($0)}),f.name.map({f.quote.contains($0)}) ?? true else {throw SummaryCommitError.sourceChanged}
            var e=SummaryEntry(id:stableID(f.occurrenceID),category:category,title:f.text,fields:f.fields.map {.init(label:$0.key,value:$0.value)},sourceSessionID:session.id,sourceTitle:session.displayTitle,sourceDate:session.date,sourceExcerpt:f.quote,provenance:"Source linked",needsReview:false,clinicalStatus:["historical","resolved","performed"].contains(f.status) ? .past:.current,factKey:"record:"+f.occurrenceID)
            var evidence=ClinicalEvidence();evidence.assessmentMethod=WholeHistoryPublication.version
            evidence.factIdentity="record:"+f.occurrenceID;evidence.excerpt=f.quote
            evidence.sourceAssertion=SourceAssertion(name:f.name,status:f.status,start:f.start,sourceHash:f.sourceHash,signature:sourceHash(([f.name ?? "",f.status,f.date,f.attribution]+f.fields.sorted {$0.key<$1.key}.map {$0.key+"="+$0.value}).joined(separator:"\n")))
            evidence.eventDate=f.date.isEmpty ? nil:f.date;evidence.sourceAttribution=f.attribution.isEmpty ? nil:f.attribution
            evidence.topicNames=f.conditions
            evidence.wholeHistoryTopicIDs=f.conditions.map {stableID("condition:"+$0.lowercased())}
            evidence.statusExplicit=category != .medications && ["historical","resolved","performed"].contains(f.status)
            if category == .medications {
                var medication=values;if let name=f.name {medication["name"]=name}
                evidence.medication=StructuredMedication.grounded(medication,in:[f.quote])
            }
            if category == .carePlan || category == .followUp {
                var instruction=CareInstruction(instruction:f.text,schedule:values["schedule"])
                instruction.owner=f.attribution.isEmpty ? nil:f.attribution
                instruction.recordStatus=f.status;instruction.bucket=category == .followUp ? .followUp:.carePlan
                evidence.careInstruction=instruction
            }
            e.evidence=evidence
            if category == .medications,let key=BClinicalPresentation.productKey(e) {
                e.evidence?.medicationProductID=stableID(key)
                // Prescribed is not dispensed and neither establishes current use.
                e.evidence?.medicationEventKind=["prescribed":"prescription","dispensed":"dispensing","patientReportedUse":"patient_reported_use"][f.status] ?? "recorded"
            }
            guard HealthStoryEligibility.includes(e) else {return nil}
            var assessment=SummaryAssessment(admission:.sourceLinked,reason:"Independently checked against the source; not clinician confirmed.",sourceHash:SummaryVerification.hash(session.transcript),contentHash:SummaryVerification.contentHash(e),citations:[.init(field:"assertion",excerpt:f.quote)])
            assessment.modelSupported=true;e.evidence?.assessment=assessment
            return e
        }
    }
}

/// Source metadata and identity are independent of presentation wording and categories.
public struct SourceAssertion: Codable, Equatable, Hashable, Sendable {
    public var name: String?
    public var status: String
    public var start: Int
    public var sourceHash: String
    public var signature: String?
}
public struct AssertionReconciliation: Codable, Equatable, Sendable {
    public var updateID: UUID
    public var recordID: UUID
    public var occurrenceID: UUID
    public var previousID: UUID?
    public var outcome: String
}
public struct MedicationProduct: Codable, Equatable, Sendable {
    public var id: UUID
    public var key: String
    public var name: String
    public var strength: String?
    public var form: String?
}
public enum AssertionReconciler {
    /// Exact unique source evidence can survive shifted offsets and revised prose.
    /// Never match ambiguous repeated quotes or incompatible assertions heuristically.
    public static func match(_ entry: SummaryEntry, in prior: [SummaryEntry]) -> SummaryEntry? {
        if let exact=prior.first(where: {$0.id==entry.id || $0.evidence?.factIdentity==entry.evidence?.factIdentity}) {return exact}
        guard let source=entry.evidence?.sourceAssertion,let quote=entry.sourceExcerpt,!quote.isEmpty else {return nil}
        let matches=prior.filter { old in
            guard let other=old.evidence?.sourceAssertion else {return false}
            return old.sourceExcerpt==quote && other.name==source.name && other.status==source.status
                && source.signature != nil && source.signature==other.signature
        }
        return matches.count==1 ? matches[0]:nil
    }
    public static func outcome(_ entry:SummaryEntry,previous:SummaryEntry?) -> String {
        guard let previous else {return "added"}
        if previous.origin == .userEdited || previous.origin == .userAdded || previous.isDeleted {return "patient_preserved"}
        if previous.category != entry.category {return "recategorized"}
        return previous.title==entry.title && previous.fields==entry.fields ? "unchanged":"corrected"
    }
}
