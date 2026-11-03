import Foundation

/// One source encounter's plan, shared by All and every linked condition.
/// A derived entity: original facts, preferences, quotes and edits stay intact.
public struct HealthCarePlan: Identifiable, Sendable {
    public struct Action: Identifiable, Sendable {
        public let id: String
        public let text: String
        public let timing: String?
        public let context: String?
        public let owner: String?
        public let bucket: CarePlanBucket
        public let status: String
        public let factIDs: [String]
        public let entries: [SummaryEntry]
        public let patientWritten: Bool
        public let reminder: Date?
        public var metadata: [String] {
            [("When",timing),("Context",entries.allSatisfy{$0.evidence?.careInstruction?.isConcise==true} || patientWritten || context?.range(of:#"(?i)\b(if|unless|only when|only if)\b"#,options:.regularExpression) != nil ? context:nil),("Owner",owner)].compactMap { label,value in
                guard let value, !value.isEmpty, !text.localizedCaseInsensitiveContains(value) else{return nil}
                return label+": "+value
            } + (status == "Current" ? (reminder.map{["Reminder: "+$0.formatted(date:.abbreviated,time:.shortened)]} ?? []):[])
        }
    }
    public let id: String
    public let title: String
    public let sourceSessionID: UUID?
    public let sourceLabel: String
    public let practitioner: String?
    public let conditionIDs: [String]
    public let conditionNames: [String]
    public let actions: [Action]
    public let fictional: Bool
    public let reviewed: Bool
    public let unverified: Bool
    public var factIDs: [String] {Array(Set(actions.flatMap(\.factIDs))).sorted()}
    public var entries: [SummaryEntry] {actions.flatMap(\.entries).sorted{$0.id.uuidString<$1.id.uuidString}}
    public var hasLegacyActions: Bool {actions.contains{$0.entries.contains{$0.origin == .generated && $0.evidence?.careInstruction?.isConcise != true}}}

    private struct Member {
        let fact: HealthFact
        let entry: SummaryEntry
        let practitioner: String?
        let conditions: [ConditionSummary]
        let fictional: Bool
    }
    public static func project(facts: [HealthFact], conditions: [ConditionSummary], sessions: [Session], practitionerNames: [String:String] = [:]) -> [Self] {
        var memberships:[String:[ConditionSummary]]=[:]
        for condition in conditions {for fact in condition.facts {memberships[fact.id,default:[]].append(condition)}}
        var groups:[String:[Member]]=[:]
        for fact in facts where !fact.preference.hidden && CareInstructionPresentation.applies(fact.latest) {
            for entry in fact.occurrences where !entry.isDeleted {
                let linked=memberships[fact.id] ?? []
                let practitioner=practitionerNames[fact.id] ?? BClinicalPresentation.namedPractitioner(entry.evidence?.practitioner)
                let fictional=([entry.evidence?.careInstruction?.consideration ?? ""]+linked.map(\.name)).contains {
                    $0.localizedCaseInsensitiveContains("fictional") || $0.localizedCaseInsensitiveContains("role-play") || $0.localizedCaseInsensitiveContains("role play")
                }
                let source=entry.sourceSessionID?.uuidString ?? "unsourced:"+entry.id.uuidString
                let provider=fact.preference.practitionerContactID?.uuidString ?? practitioner?.lowercased() ?? "unknown"
                let group=entry.evidence?.careInstruction?.planID ?? "record-advice"
                let key=[source,provider,entry.evidence?.eventDate ?? "",group,fictional ? "fictional":"recorded"].joined(separator:"|")
                groups[key,default:[]].append(.init(fact:fact,entry:entry,practitioner:practitioner,conditions:linked,fictional:fictional))
            }
        }
        return groups.map { key,members in
            let ordered=members.sorted{$0.entry.id.uuidString<$1.entry.id.uuidString}
            let id=SummaryVerification.hash("care-plan-entity-v1|"+key)
            var actionGroups:[String:[Member]]=[:]
            for member in ordered {
                let entry=member.entry,care=entry.evidence?.careInstruction
                let patient=entry.origin == .userEdited || entry.origin == .userAdded
                let text=patient ? CarePlanCardInput.patientWording(entry) : compact(CareInstructionPresentation.instruction(entry))
                // Only identical concise advice and every material qualifier can
                // coalesce locally. Never merge differing doses, schedules, owner,
                // status, conditionality, patient edits or explicit separation.
                let separate=patient || entry.evidence?.combinationExcluded == true
                let signature=[text,care?.schedule ?? "",care?.consideration ?? "",care?.owner ?? "",
                    (care?.bucket ?? (entry.category == .followUp ? .followUp:.carePlan)).rawValue,
                    recordedStatus(member.fact,entry:entry),member.fact.hasKnownStatus ? "known":"unknown",
                    member.fact.preference.dueDate.map{String($0.timeIntervalSince1970)} ?? "",separate ? entry.id.uuidString: ""].joined(separator:"|")
                actionGroups[signature,default:[]].append(member)
            }
            let actions=actionGroups.map { signature,rows in
                let row=rows[0],entry=row.entry,care=entry.evidence?.careInstruction
                let patient=entry.origin == .userEdited || entry.origin == .userAdded
                return Action(id:SummaryVerification.hash(id+signature),text:patient ? CarePlanCardInput.patientWording(entry):compact(CareInstructionPresentation.instruction(entry)),
                    timing:nonempty(care?.schedule),context:nonempty(care?.consideration),owner:nonempty(care?.owner),
                    bucket:care?.bucket ?? (entry.category == .followUp ? .followUp:.carePlan),status:recordedStatus(row.fact,entry:entry),
                    factIDs:Array(Set(rows.map{$0.fact.id})).sorted(),entries:rows.map(\.entry),patientWritten:patient,reminder:row.fact.preference.dueDate)
            }.sorted { a,b in
                let ai=CarePlanBucket.allCases.firstIndex(of:a.bucket) ?? 0,bi=CarePlanBucket.allCases.firstIndex(of:b.bucket) ?? 0
                return ai==bi ? a.text.localizedStandardCompare(b.text) == .orderedAscending:ai<bi
            }
            let related=Dictionary(grouping:ordered.flatMap(\.conditions),by:\.id).values.compactMap(\.first).sorted{$0.id<$1.id}
            let headings=Set(ordered.compactMap{nonempty($0.entry.evidence?.careInstruction?.planTitle)})
            let title=headings.count==1 ? headings.first! : (related.count==1 && related[0].name.count<=60 ? related[0].name+" · Care plan":"Care plan")
            let labels=Set(ordered.map{CareInstructionPresentation.dateLabel($0.entry,sessions:sessions)})
            let providers=Set(ordered.compactMap(\.practitioner))
            return Self(id:id,title:title,sourceSessionID:ordered[0].entry.sourceSessionID,sourceLabel:labels.count==1 ? labels.first!:"Multiple recorded dates",
                practitioner:providers.count==1 ? providers.first:nil,conditionIDs:related.map(\.id),conditionNames:related.map(\.name),actions:actions,
                fictional:ordered.contains(where:\.fictional),reviewed:ordered.allSatisfy{$0.fact.isReviewed},unverified:ordered.contains{$0.entry.origin == .generated && $0.entry.evidence?.assessment?.admission != .supported})
        }.sorted { a,b in
            let ad=a.entries.compactMap{CareInstructionPresentation.sourceOrderDate($0,sessions:sessions)}.max() ?? .distantPast
            let bd=b.entries.compactMap{CareInstructionPresentation.sourceOrderDate($0,sessions:sessions)}.max() ?? .distantPast
            return ad==bd ? a.id<b.id:ad>bd
        }
    }
    public var exportText: String {
        ([title]+actions.map { action in
            ([action.bucket == .followUp ? "Follow-up: "+action.text:action.bucket == .considerations ? "Consideration: "+action.text:action.text]+action.metadata+(action.status == "Current" ? []:[action.status])).joined(separator:" · ")
        }).joined(separator:"\n")
    }
    private static func recordedStatus(_ fact:HealthFact,entry:SummaryEntry)->String {
        if fact.preference.actionStatus != nil || fact.preference.clinicalStatus != nil {return CareInstructionPresentation.status(fact)}
        let old=entry.details.components(separatedBy:.newlines).first{$0.hasPrefix("Recorded status: ")}.map{String($0.dropFirst("Recorded status: ".count))}
        let state=entry.evidence?.careInstruction?.recordStatus ?? old
        return ["declined":"Declined","conditional":"Conditional","planned":"Planned","performed":"Completed","historical":"Historical","resolved":"Resolved","reported":"Reported","unclear":"Unclear"][state ?? ""] ?? CareInstructionPresentation.status(fact)
    }
    private static func nonempty(_ s:String?) -> String? {s.flatMap{$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil:$0}}
    /// Syntax-only recovery for cached wording. Do not truncate or invent a summary.
    public static func compact(_ text:String) -> String {
        var value=text.replacingOccurrences(of:#"(?i)^(?:the )?(?:clinician|doctor|practitioner|therapist)\s+(?:recommends?|advises?|suggests?)\s+"#,with:"",options:.regularExpression)
        let verbs=["continuing":"Continue","adjusting":"Adjust","keeping":"Keep","finding":"Find","trying to find":"Find","trying to keep":"Keep","using":"Use","taking":"Take","discussing":"Discuss","noticing":"Notice"]
        for prefix in verbs.keys.sorted(by:{$0.count>$1.count}) where value.lowercased().hasPrefix(prefix+" ") {
            value=verbs[prefix]!+value.dropFirst(prefix.count);break
        }
        return value
    }
}
