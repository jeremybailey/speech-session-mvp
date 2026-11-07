import Foundation

public struct StorySourceRevision: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var recordID: UUID
    public var text: String
    public var createdAt: Date = Date()
    public var patientEdited: Bool = false
    public var retiredEntryIDs: [UUID]? = nil
}
public struct StoryBlock: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var revision: Int = 0
    public var text: String
    public var factIDs: [String]
    public var patientWritten: Bool = false
    public var suppressed: Bool = false
    public var evidenceChanged: Bool = false
    public var correctionRecordID: UUID? = nil
}
public struct StoryEdit: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var blockID: UUID
    public var revision: Int
    public var before: String
    public var after: String
    public var factIDs: [String]
    public var state: String = "queued"
    public var question: String? = nil
    public var createdAt: Date = Date()
    public var requestJSON: String? = nil
    public var addedRecordID: UUID? = nil
    public var retiredEntryIDs: [UUID] = []
}
public struct StoryCareEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var actionID: String
    public var kind: String
    public var text: String
    public var date: Date = Date()
    public var recordID: UUID? = nil
    public var factIDs: [String]? = nil
}
public struct StoryMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var role: String
    public var text: String
    public var citationIDs: [String] = []
    public var state: String = "saved"
    public var requestJSON: String? = nil
    public var evidence: [StoryEvidence]? = nil
    public var savedRecordID: UUID? = nil
    public var createdAt: Date = Date()
}
public struct StoryWorkspace: Codable, Equatable, Sendable {
    public var sources: [StorySourceRevision] = []
    public var sourceDrafts: [String:String]? = nil
    public var blocks: [StoryBlock] = []
    public var edits: [StoryEdit] = []
    public var careEvents: [StoryCareEvent] = []
    public var messages: [StoryMessage] = []
    public var checkInsEnabled: Bool = true
    public var lastCheckInDay: String? = nil
    public init() {}
}
public struct StoryEvidence: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var recordID: UUID?
    public var sourceRevisionID: UUID?
    public var title: String
}
public enum StoryEditError: Error { case staleRevision, invalidMutation, notFound }

extension SessionStore {
    public func storyWorkspace() throws -> StoryWorkspace { try loadEnvelope().story }
    public func synchronizeStory() throws {
        var env = try loadEnvelope()
        for session in env.sessions where !session.transcript.isEmpty {
            if env.story.sources.last(where: {$0.recordID == session.id})?.text != session.transcript {
                env.story.sources.append(StorySourceRevision(recordID: session.id, text: session.transcript))
            }
        }
        let facts = HealthMemoryProjection.facts(in: try healthSnapshot())
        let byID = Dictionary(uniqueKeysWithValues: facts.map {($0.id, $0.displayEntry.title)})
        let previousBlocks=env.story.blocks
        let protectedIDs=Set(previousBlocks.filter{$0.patientWritten || $0.suppressed}.flatMap(\.factIDs))
        if let overview=storyOverview(for:facts) {
            let generated=overview.sentences.filter{Set($0.factIDs).isDisjoint(with:protectedIDs)}.map {sentence -> StoryBlock in
                let old=previousBlocks.first{!$0.patientWritten && !$0.suppressed && Set($0.factIDs)==Set(sentence.factIDs)}
                return StoryBlock(id:old?.id ?? UUID(),revision:old?.revision ?? 0,text:sentence.text,factIDs:sentence.factIDs)
            }
            // Patient blocks retain their position; refreshed generated blocks fill the other slots.
            var remaining=generated;var merged:[StoryBlock]=[]
            for old in previousBlocks {
                if old.patientWritten || old.suppressed {merged.append(old)}
                else if !remaining.isEmpty {merged.append(remaining.removeFirst())}
            }
            env.story.blocks=merged+remaining
        } else if env.story.blocks.isEmpty {
            env.story.blocks=facts.prefix(5).map{StoryBlock(text:$0.displayEntry.title,factIDs:[$0.id])}
        }
        for i in env.story.blocks.indices where env.story.blocks[i].factIDs.contains(where: {byID[$0] == nil}) {
            env.story.blocks[i].evidenceChanged = true
        }
        try saveEnvelope(env)
    }
    @discardableResult public func addStoryBlock() throws -> UUID {
        var env = try loadEnvelope(); let block = StoryBlock(text: "", factIDs: [], patientWritten: true)
        env.story.blocks.append(block); try saveEnvelope(env); return block.id
    }
    @discardableResult public func editStoryBlock(_ id: UUID, text: String) throws -> UUID? {
        var env = try loadEnvelope()
        guard let i = env.story.blocks.firstIndex(where: {$0.id == id}) else {throw StoryEditError.notFound}
        let old = env.story.blocks[i]; guard old.text != text else { return nil }
        for j in env.story.edits.indices where env.story.edits[j].blockID == id && ["queued", "clarification"].contains(env.story.edits[j].state) {env.story.edits[j].state = "superseded"}
        env.story.blocks[i].revision += 1; env.story.blocks[i].text = text
        env.story.blocks[i].patientWritten = true; env.story.blocks[i].suppressed = text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        let initial = env.story.edits.last(where: {$0.blockID == id && $0.state == "superseded" && $0.revision == old.revision})
        var edit = StoryEdit(blockID:id, revision:env.story.blocks[i].revision, before:initial?.before ?? old.text, after:text, factIDs:old.factIDs)
        if env.story.blocks[i].suppressed {edit.state = "presentation"}
        env.story.edits.append(edit); try saveEnvelope(env); return edit.id
    }
    public func applyStoryEdit(_ id: UUID, kind: String, targets: [String], question: String? = nil) throws {
        var env = try loadEnvelope()
        guard let e = env.story.edits.firstIndex(where: {$0.id == id}), let b = env.story.blocks.firstIndex(where: {$0.id == env.story.edits[e].blockID}) else {throw StoryEditError.notFound}
        guard env.story.edits[e].state == "queued" else {return}
        let edit = env.story.edits[e]
        guard env.story.blocks[b].revision == edit.revision else {throw StoryEditError.staleRevision}
        guard ["presentation", "correction", "clarification"].contains(kind), Set(targets).isSubset(of:Set(edit.factIDs)) else {throw StoryEditError.invalidMutation}
        if kind == "clarification" {guard let question, !question.isEmpty else {throw StoryEditError.invalidMutation}; env.story.edits[e].question = question}
        if kind == "correction" {
            guard !edit.after.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw StoryEditError.invalidMutation}
            let facts = HealthMemoryProjection.facts(in: try healthSnapshot())
            let ids = Set(facts.filter {targets.contains($0.id)}.flatMap(\.occurrences).map(\.id))
            for s in env.sessions.indices { for j in env.sessions[s].summaryEntries?.indices ?? 0..<0 {
                if ids.contains(env.sessions[s].summaryEntries![j].id), !env.sessions[s].summaryEntries![j].isDeleted {
                    env.sessions[s].summaryEntries![j].isDeleted = true
                    env.story.edits[e].retiredEntryIDs.append(env.sessions[s].summaryEntries![j].id)
                }
            }}
            let record = Self.patientStoryRecord(text:edit.after, title:"Story correction")
            env.sessions.append(record); env.story.edits[e].addedRecordID = record.id
            env.story.sources.append(StorySourceRevision(recordID:record.id,text:record.transcript,patientEdited:true))
            // The correction is itself the source; never keep a stale document citation.
            env.story.blocks[b].factIDs = []
            env.story.blocks[b].correctionRecordID = record.id
        }
        env.story.edits[e].state = kind; env.wholeHistorySourceFingerprint = nil
        try saveEnvelope(env)
    }
    public func undoStoryEdit(_ id: UUID) throws {
        var env = try loadEnvelope()
        guard let e = env.story.edits.firstIndex(where: {$0.id == id}), let b = env.story.blocks.firstIndex(where: {$0.id == env.story.edits[e].blockID}) else {throw StoryEditError.notFound}
        let edit = env.story.edits[e];guard env.story.blocks[b].revision == edit.revision, edit.state != "undone" else {throw StoryEditError.staleRevision}
        for s in env.sessions.indices {for j in env.sessions[s].summaryEntries?.indices ?? 0..<0 {
            if edit.retiredEntryIDs.contains(env.sessions[s].summaryEntries![j].id) {env.sessions[s].summaryEntries![j].isDeleted = false}
            if env.sessions[s].id == edit.addedRecordID {env.sessions[s].summaryEntries![j].isDeleted = true}
        }}
        env.story.blocks[b].correctionRecordID = nil
        env.story.blocks[b].text = edit.before;env.story.blocks[b].factIDs = edit.factIDs
        env.story.blocks[b].suppressed = edit.before.isEmpty;env.story.blocks[b].revision += 1
        env.story.edits[e].state = "undone";try saveEnvelope(env)
    }
    public func saveStorySourceDraft(_ recordID: UUID, text: String) throws {
        var env = try loadEnvelope()
        guard env.sessions.contains(where: {$0.id == recordID}) else {throw StoryEditError.notFound}
        var drafts = env.story.sourceDrafts ?? [:]; drafts[recordID.uuidString] = text
        env.story.sourceDrafts = drafts; try saveEnvelope(env)
    }
    public func reviseStorySource(_ recordID: UUID, text: String) throws {
        var env = try loadEnvelope();guard let i = env.sessions.firstIndex(where: {$0.id == recordID}) else {throw StoryEditError.notFound}
        env.story.sourceDrafts?.removeValue(forKey: recordID.uuidString)
        let previous = env.sessions[i].transcript;guard text != previous else {try saveEnvelope(env);return}
        if env.story.sources.last(where: {$0.recordID == recordID})?.text != previous {env.story.sources.append(StorySourceRevision(recordID:recordID,text:previous))}
        env.story.sources.append(StorySourceRevision(recordID:recordID,text:text,patientEdited:true))
        let previouslyRetired=Set(env.story.sources.filter{$0.recordID==recordID}.flatMap{$0.retiredEntryIDs ?? []})
        var retired:[UUID]=[]
        for j in env.sessions[i].summaryEntries?.indices ?? 0..<0 {
            let entry = env.sessions[i].summaryEntries![j]
            guard entry.origin == .generated,let quote=entry.supportingExcerpt,!quote.isEmpty else {continue}
            if !text.contains(quote) {env.sessions[i].summaryEntries![j].isDeleted=true;retired.append(entry.id)}
            else if previouslyRetired.contains(entry.id), !env.story.edits.contains(where: {$0.state == "correction" && $0.retiredEntryIDs.contains(entry.id)}) {env.sessions[i].summaryEntries![j].isDeleted=false}
        }
        env.story.sources[env.story.sources.count-1].retiredEntryIDs=retired
        env.sessions[i].transcript = text;env.sessions[i].extractionVersion = nil
        env.completedRecordRevisions.removeValue(forKey:recordID.uuidString)
        env.wholeHistorySourceFingerprint = nil;try saveEnvelope(env)
    }
    private static func patientStoryRecord(text: String, title: String) -> Session {
        let id = UUID()
        let entry = SummaryEntry(category:.otherNotes,title:text,sourceSessionID:id,sourceTitle:title,sourceExcerpt:text,provenance:"Patient reported",origin:.userAdded)
        return Session(id:id,transcript:text,title:title,summaryEntries:[entry],inputType:.documentFile,entryIntent:.personalJournal)
    }
    public func recordStoryCareEvent(actionID: String, kind: String, text: String, factIDs: [String] = []) throws {
        guard ["adopted", "paused", "stopped", "completed", "progress"].contains(kind) else {throw StoryEditError.invalidMutation}
        var env = try loadEnvelope(); var event = StoryCareEvent(actionID:actionID,kind:kind,text:text)
        if kind == "progress" {
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw StoryEditError.invalidMutation}
            let record = Self.patientStoryRecord(text:text,title:"Care plan progress");env.sessions.append(record);event.recordID = record.id
            env.story.sources.append(StorySourceRevision(recordID:record.id,text:text,patientEdited:true))
        }
        event.factIDs=factIDs
        if kind != "progress" {
            let facts=HealthMemoryProjection.facts(in:try healthSnapshot())
            guard Set(factIDs).isSubset(of:Set(facts.map(\.id))) else {throw StoryEditError.invalidMutation}
            for fact in facts where factIDs.contains(fact.id) {
                var preference=fact.preference
                preference.actionStatus = kind == "adopted" ? .current:kind == "paused" ? .paused:kind == "completed" ? .completed:.past
                if let i=env.preferences.firstIndex(where:{$0.id==fact.id}) {env.preferences[i]=preference} else {env.preferences.append(preference)}
            }
        }
        env.story.careEvents.append(event);try saveEnvelope(env)
    }
    public func setStoryCheckIn(enabled: Bool, day: String? = nil) throws {
        var env = try loadEnvelope();env.story.checkInsEnabled = enabled
        if let day {env.story.lastCheckInDay = day};try saveEnvelope(env)
    }
    @discardableResult public func addStoryMessage(role:String,text:String,citations:[String] = [],state:String = "saved") throws -> UUID {
        var env = try loadEnvelope();let message = StoryMessage(role:role,text:text,citationIDs:citations,state:state)
        env.story.messages.append(message);try saveEnvelope(env);return message.id
    }
    public func saveStoryMessageAsRecord(_ id:UUID) throws {
        var env = try loadEnvelope();guard let i = env.story.messages.firstIndex(where:{$0.id == id && $0.role == "user"}) else {throw StoryEditError.notFound}
        guard env.story.messages[i].savedRecordID == nil else {return}
        let record = Self.patientStoryRecord(text:env.story.messages[i].text,title:"Personal update")
        env.sessions.append(record);env.story.messages[i].savedRecordID = record.id
        env.story.sources.append(StorySourceRevision(recordID:record.id,text:record.transcript,patientEdited:true));try saveEnvelope(env)
    }
    public func storyRequestBody(_ id:UUID, proposed:String? = nil) throws -> String? {
        var env=try loadEnvelope()
        if let i=env.story.edits.firstIndex(where:{$0.id==id}) {
            if let existing=env.story.edits[i].requestJSON {return existing}
            if let proposed {env.story.edits[i].requestJSON=proposed;try saveEnvelope(env)}
        } else if let i=env.story.messages.firstIndex(where:{$0.id==id}) {
            if let existing=env.story.messages[i].requestJSON {return existing}
            if let proposed {env.story.messages[i].requestJSON=proposed;try saveEnvelope(env)}
        } else {throw StoryEditError.notFound}
        return proposed
    }
    public func completeStoryQuestion(_ id:UUID,text:String,citations:[String],evidence:[StoryEvidence]) throws {
        var env=try loadEnvelope()
        guard let i=env.story.messages.firstIndex(where:{$0.id==id && $0.role=="user"}), Set(citations).isSubset(of:Set(evidence.map(\.id))) else {throw StoryEditError.invalidMutation}
        guard env.story.messages[i].state == "queued" else {return}
        var reply=StoryMessage(role:"assistant",text:text,citationIDs:citations)
        reply.id=IncrementalRecordUpdate.stableID("story-answer:"+id.uuidString);reply.evidence=evidence.filter{citations.contains($0.id)}
        env.story.messages.append(reply);env.story.messages[i].state="completed";try saveEnvelope(env)
    }
    public func cancelStoryOperation(_ id:UUID) throws {
        var env=try loadEnvelope()
        if let i=env.story.edits.firstIndex(where:{$0.id==id}) {env.story.edits[i].state="cancelled"}
        if let i=env.story.messages.firstIndex(where:{$0.id==id}) {env.story.messages[i].state="cancelled"}
        try saveEnvelope(env)
    }
    public func storyEvidence(query:String, limit:Int = 24) throws -> [StoryEvidence] {
        let env = try loadEnvelope();var facts = HealthMemoryProjection.facts(in:try healthSnapshot())
        if query.lowercased().contains("all"),query.lowercased().contains("medicat") {facts=facts.filter{$0.category == .medications}}
        let terms = query.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber}).map(String.init).filter{$0.count > 2}
        var evidence = facts.map {StoryEvidence(id:$0.id,text:([$0.displayEntry.title,$0.displayEntry.details,"Status: "+($0.hasKnownStatus ? $0.statusTitle:"Unknown")]+$0.displayEntry.fields.map{$0.label+": "+$0.value}).joined(separator:"\n"),recordID:$0.latest.sourceSessionID,title:$0.displayEntry.title)}
        let matchedSources = try matchingStorySourceIDs(query:query)
        for source in env.story.sources where env.story.sources.last(where:{$0.recordID == source.recordID})?.id == source.id && (matchedSources?.contains(source.id.uuidString) ?? true) {
            // Stable revision-scoped passages retain exact text; never cite a mutable offset alone.
            for (index,paragraph) in source.text.components(separatedBy:"\n").enumerated() where !paragraph.isEmpty {
                evidence.append(StoryEvidence(id:source.id.uuidString+":"+String(index),text:paragraph,recordID:source.recordID,sourceRevisionID:source.id,title:env.sessions.first(where:{$0.id == source.recordID})?.displayTitle ?? "Record"))
            }
        }
        return evidence.sorted {a,b in
            let sa=terms.filter{a.text.lowercased().contains($0)}.count,sb=terms.filter{b.text.lowercased().contains($0)}.count
            return sa == sb ? a.id < b.id : sa > sb
        }.prefix(max(1,min(limit,200))).map{$0}
    }
}
