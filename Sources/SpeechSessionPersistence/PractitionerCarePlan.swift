import Foundation

/// A read-only view of the saved handoff, not new actions or inferred adoption.
public struct PractitionerCarePlan: Equatable, Sendable {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let note: String
        public let date: String?
        public let citationIDs: [String]
    }
    public struct Group: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public var items: [Item]
    }
    public let groups: [Group]
    public init(summary: StorySharedSummary) {
        let section="Care Plan & Interventions"
        let presentation=StorySummaryDocument.practitionerPresentation(summary.text,hasAbnormalLabs:false,bulletDates:summary.bulletDates ?? [])
        var groups:[Group]=[],positions:[String:Int]=[:],inside=false,seen=Set<String>()
        let allowed=Set(summary.evidence.map(\.id))
        for block in presentation.blocks {
            if case let .heading(title,level)=block,level==2 {inside=title==section}
            guard inside,case let .bullet(text)=block else{continue}
            let fields=StorySummaryDocument.topicAndNote(text)
            let title=fields.topic.isEmpty ? "Other care notes":fields.topic
            let parts=Set(StorySummaryDocument.splitShareItems(.bullet(text)).compactMap { if case let .bullet(value)=$0{return value};return nil })
            // Match the full displayed statement, never topic/category membership alone.
            let refs=(summary.pointReferences ?? []).filter { ref in
                guard ref.heading==section else{return false}
                return StorySummaryDocument.splitShareItems(.bullet(StorySummaryDocument.shareShorthand(ref.text))).contains { if case let .bullet(value)=$0{return parts.contains(value)};return false }
            }.flatMap(\.citationIDs).filter{allowed.contains($0)}
            let ids=Array(Set(refs)).sorted()
            let date=presentation.dates.first(where:{$0.text==text})?.displayLabel()
            let key=title.lowercased()
            let identity=SummaryVerification.hash(text+"|"+(date ?? "")+"|"+ids.joined(separator:"|"))
            guard seen.insert(identity).inserted else{continue}
            let item=Item(id:identity,note:fields.note,date:date,citationIDs:ids)
            if let index=positions[key] {groups[index].items.append(item)}
            else {positions[key]=groups.count;groups.append(Group(id:SummaryVerification.hash("care-overview:"+key),title:title,items:[item]))}
        }
        self.groups=groups
    }
}

public struct StorySummaryPointReference: Codable, Equatable, Sendable {
    public var conditionGroup: String? = nil
    public var careStatus: String? = nil
    public var timeLabel: String? = nil
    public let heading: String
    public let text: String
    public let citationIDs: [String]
    public init(heading:String,text:String,citationIDs:[String]) {
        self.heading=heading;self.text=text;self.citationIDs=citationIDs
    }
}
