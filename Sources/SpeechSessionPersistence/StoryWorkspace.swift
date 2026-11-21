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
    public var section: String? = nil
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
    public var cancellationPending: Bool? = nil
    public var addedRecordID: UUID? = nil
    public var retiredEntryIDs: [UUID] = []
    public var priorActionPreferences: [HealthFactPreference]? = nil
    public var careEventIDs: [UUID]? = nil
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
    public static func queuedQuestion(_ text: String, recordID: UUID? = nil) -> Self {
        StoryMessage(scopeRecordID: recordID, role: "user", text: text, state: "queued")
    }

    public var scopeRecordID: UUID? = nil
    public var summaryParentID:UUID? = nil
    public var id: UUID = UUID()
    public var role: String
    public var text: String
    public var citationIDs: [String] = []
    public var state: String = "saved"
    public var requestJSON: String? = nil
    public var cancellationPending: Bool? = nil
    public var evidence: [StoryEvidence]? = nil
    public var savedRecordID: UUID? = nil
    public var createdAt: Date = Date()
}
public struct StoryWorkspace: Codable, Equatable, Sendable {
    public var sharedSummary:StorySharedSummary? = nil
    public var narrativeText: String? = nil
    public var narrativeRevision: Int? = nil
    public var narrativeEdited: Bool? = nil
    public var narrativeEvidence: [StoryEvidence]? = nil
    public var sources: [StorySourceRevision] = []
    public var sourceDrafts: [String:String]? = nil
    public var blocks: [StoryBlock] = []
    public var edits: [StoryEdit] = []
    public var careEvents: [StoryCareEvent] = []
    public var messages: [StoryMessage] = []
    public var checkInsEnabled: Bool = true
    public var lastCheckInDay: String? = nil
    public var focusActionID: String? = nil
    public init() {}
}
public struct StoryEvidence: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var recordID: UUID?
    public var sourceRevisionID: UUID?
    public var title: String
    public var timelineLabel: String? = nil
    public var detailEntryID: UUID?
    public init(id:String,text:String,recordID:UUID?,sourceRevisionID:UUID?=nil,title:String,detailEntryID:UUID?=nil) {
        self.detailEntryID = detailEntryID
        self.id=id;self.text=text;self.recordID=recordID;self.sourceRevisionID=sourceRevisionID;self.title=title
    }
    public func cites(_ entry: SummaryEntry) -> Bool {
        guard let recordID, entry.sourceSessionID == recordID, !entry.isDeleted else { return false }
        if let detailEntryID { return detailEntryID == entry.id }
        guard let excerpt = entry.supportingExcerpt, excerpt.split(whereSeparator: { $0.isWhitespace }).count >= 4 else { return false }
        return text.localizedStandardContains(excerpt)
    }

}
public enum StoryEditError: Error { case staleRevision, invalidMutation, notFound }

extension SessionStore {
    public func storyNarrativeText() throws -> String {
        let env=try loadEnvelope()
        if let text=env.story.narrativeText {return text}
        let written=env.story.blocks.filter{$0.patientWritten && !$0.suppressed}.map(\.text).joined(separator:"\n\n")
        if !written.isEmpty {return written}
        // Validation only affects which text is displayed when both versions exist.
        let previous = lastStoryOverviewForDisplay()?.text
        guard let previous else { return env.wholeHistoryOverview ?? "" }
        guard let wholeHistory = env.wholeHistoryOverview else { return previous }
        let facts = HealthMemoryProjection.facts(in: try healthSnapshot())
        return storyOverview(for: facts)?.text ?? wholeHistory
    }
    public func saveStoryNarrativeText(_ text:String) throws {
        var env=try loadEnvelope()
        guard env.story.narrativeText != text else {return}
        env.story.narrativeText=text;env.story.narrativeEdited=true
        env.story.narrativeRevision=(env.story.narrativeRevision ?? 0)+1
        // Presentation-only editing while structured mutation is deferred.
        env.story.narrativeEvidence=nil
        try saveEnvelope(env)
    }
    public func publishStoryNarrative(_ text:String,revision:Int,evidence:[StoryEvidence],expectedSources:[StoryEvidence]?=nil,serviceOperationID:UUID?=nil) throws {
        if let expectedSources, try storyOverviewEvidence() != expectedSources { throw StoryEditError.staleRevision }
        var env=try loadEnvelope()
        guard (env.story.narrativeRevision ?? 0)==revision else {throw StoryEditError.staleRevision}
        if let serviceOperationID {
            guard let index=env.story.messages.firstIndex(where:{$0.id==serviceOperationID}),env.story.messages[index].state=="queued" else {throw StoryEditError.staleRevision}
            env.story.messages[index].state="completed";env.story.messages[index].requestJSON=nil;env.story.messages[index].evidence=nil
        }
        env.story.narrativeText=text;env.story.narrativeEdited=false
        env.story.narrativeRevision=revision+1;env.story.narrativeEvidence=evidence
        try saveEnvelope(env)
    }
    public func storyWorkspace() throws -> StoryWorkspace { try loadEnvelope().story }
    public func synchronizeStory() throws {
        // A separately saved overview can change even without an envelope write.
        let hasOverview = FileManager.default.fileExists(atPath: storageDirectory.appendingPathComponent("story-overview.json").path)
        if !hasOverview, synchronizedStoryRevision == contentRevision { return }
        let snapshot = try healthSnapshot()
        var env = try loadEnvelope()
        let previousStory = env.story
        let latestSource = Dictionary(env.story.sources.map { ($0.recordID, $0.text) }, uniquingKeysWith: { _, newest in newest })
        for session in env.sessions where !session.transcript.isEmpty {
            if latestSource[session.id] != session.transcript {
                env.story.sources.append(StorySourceRevision(recordID: session.id, text: session.transcript))
            }
        }
        let facts = HealthMemoryProjection.facts(in: snapshot)
        let factIDs = Set(facts.map(\.id))
        for i in env.story.blocks.indices {
            if let sourceID=env.story.blocks[i].correctionRecordID {
                env.story.blocks[i].factIDs=facts.filter{$0.occurrences.contains(where:{$0.sourceSessionID==sourceID})}.map(\.id)
            }
        }
        let previousBlocks=env.story.blocks
        let protectedIDs=Set(previousBlocks.filter{$0.patientWritten || $0.suppressed}.flatMap(\.factIDs)+env.story.edits.filter{$0.state=="correction"}.flatMap(\.factIDs))
        if let overview=storyOverview(for:facts) {
            var available = previousBlocks.filter { !$0.patientWritten && !$0.suppressed }
            let generated=overview.sentences.filter{Set($0.factIDs).isDisjoint(with:protectedIDs)}.map {sentence -> StoryBlock in
                let citedFacts = Set(sentence.factIDs)
                let index = available.firstIndex { $0.text == sentence.text && Set($0.factIDs) == citedFacts }
                    ?? available.firstIndex { Set($0.factIDs) == citedFacts }
                let old = index.map { available.remove(at: $0) }
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
            // Retain legacy editable-block compatibility; the narrative UI never uses these labels.
            env.story.blocks=facts.prefix(5).map{StoryBlock(text:$0.displayEntry.title,factIDs:[$0.id])}
        }
        for i in env.story.blocks.indices where env.story.blocks[i].factIDs.contains(where: {!factIDs.contains($0)}) {
            env.story.blocks[i].evidenceChanged = true
        }
        if env.story != previousStory { try saveEnvelope(env) }
        synchronizedStoryRevision = hasOverview ? nil : contentRevision
    }
    @discardableResult public func addStoryBlock(section: String = "story") throws -> UUID {
        guard ["story","plan","progress"].contains(section) else {throw StoryEditError.invalidMutation}
        var env = try loadEnvelope(); var block = StoryBlock(text: "", factIDs: [], patientWritten: true)
        block.section=section
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
    public func applyStoryEdit(_ id: UUID, kind: String, targets: [String], question: String? = nil, actionUpdates: [String:String] = [:]) throws {
        var env = try loadEnvelope()
        guard let e = env.story.edits.firstIndex(where: {$0.id == id}), let b = env.story.blocks.firstIndex(where: {$0.id == env.story.edits[e].blockID}) else {throw StoryEditError.notFound}
        guard env.story.edits[e].state == "queued" else {return}
        let edit = env.story.edits[e]
        guard env.story.blocks[b].revision == edit.revision else {throw StoryEditError.staleRevision}
        guard ["presentation", "correction", "clarification"].contains(kind), Set(targets).isSubset(of:Set(edit.factIDs)) else {throw StoryEditError.invalidMutation}
        guard actionUpdates.isEmpty || (kind == "correction" && targets.isEmpty && Set(actionUpdates.keys).isSubset(of:Set(edit.factIDs))) else {throw StoryEditError.invalidMutation}
        if !actionUpdates.isEmpty {
            let currentFacts=HealthMemoryProjection.facts(in:try healthSnapshot())
            for (id,status) in actionUpdates {
                guard let fact=currentFacts.first(where:{$0.id==id && $0.category == .carePlan}),["current","paused","past","completed"].contains(status) else {throw StoryEditError.invalidMutation}
                env.story.edits[e].priorActionPreferences=(env.story.edits[e].priorActionPreferences ?? [])+[fact.preference]
                var preference=fact.preference
                preference.actionStatus = status == "current" ? .current:status == "paused" ? .paused:status == "completed" ? .completed:.past
                if let index=env.preferences.firstIndex(where:{$0.id==id}) {env.preferences[index]=preference}else{env.preferences.append(preference)}
                var event=StoryCareEvent(actionID:"fact:"+id,kind:status == "current" ? "adopted":status == "past" ? "stopped":status,text:edit.after)
                event.factIDs=[id];env.story.careEvents.append(event);env.story.edits[e].careEventIDs=(env.story.edits[e].careEventIDs ?? [])+[event.id]
            }
        }
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
        for previous in edit.priorActionPreferences ?? [] {
            guard let latest=env.story.careEvents.last(where:{$0.kind != "progress" && ($0.factIDs ?? []).contains(previous.id)}),(edit.careEventIDs ?? []).contains(latest.id) else {throw StoryEditError.staleRevision}
            if let i=env.preferences.firstIndex(where:{$0.id==previous.id}) {env.preferences[i].actionStatus=previous.actionStatus}else{env.preferences.append(previous)}
            let status=previous.actionStatus
            var restored=StoryCareEvent(actionID:"fact:"+previous.id,kind:status == .current ? "adopted":status == .paused ? "paused":status == .completed ? "completed":status == .past ? "stopped":"restored_unknown",text:"Undid a story edit.")
            restored.factIDs=[previous.id];env.story.careEvents.append(restored)
        }
        for s in env.sessions.indices {for j in env.sessions[s].summaryEntries?.indices ?? 0..<0 {
            if edit.retiredEntryIDs.contains(env.sessions[s].summaryEntries![j].id) {env.sessions[s].summaryEntries![j].isDeleted = false}
            if env.sessions[s].id == edit.addedRecordID {env.sessions[s].summaryEntries![j].isDeleted = true}
        }}
        env.story.blocks[b].correctionRecordID = nil
        env.story.blocks[b].text = edit.before;env.story.blocks[b].factIDs = edit.factIDs
        env.story.blocks[b].suppressed = edit.before.isEmpty;env.story.blocks[b].revision += 1
        if let recordID=edit.addedRecordID,let index=env.sessions.firstIndex(where:{$0.id==recordID}) {env.sessions[index].title="Story correction (undone)"}
        env.story.edits[e].state = "undone";try saveEnvelope(env)
    }
    public func saveStorySourceDraft(_ recordID: UUID, text: String) throws {
        var env = try loadEnvelope()
        guard env.sessions.contains(where: {$0.id == recordID}) else {throw StoryEditError.notFound}
        var drafts = env.story.sourceDrafts ?? [:]; drafts[recordID.uuidString] = text
        env.story.sourceDrafts = drafts; try saveEnvelope(env)
    }
    public func changeRecordDetailVisibility(_ recordID: UUID, keys: Set<String>, hide: Bool) throws {
        var env = try loadEnvelope()
        guard let i = env.sessions.firstIndex(where: { $0.id == recordID }) else { throw StoryEditError.notFound }
        var hidden = env.sessions[i].removedRecordDetails ?? []
        if hide { hidden.formUnion(keys) } else { hidden.subtract(keys) }
        env.sessions[i].removedRecordDetails = hidden
        try saveEnvelope(env)
    }

    public func checkpointRecordBullets(_ record: Session, work: RecordSummaryWork, previous: RecordSummaryWork?, complete: Bool) throws {
        var env = try loadEnvelope()
        guard let i = env.sessions.firstIndex(where: { $0.id == record.id }) else { throw StoryEditError.notFound }
        let current = env.sessions[i]
        let selection = work.selection ?? .auto
        guard selection.resolved(for: current) == selection.resolved(for: record),
              current.recordTemplateSelection == record.recordTemplateSelection,
              current.transcript == record.transcript, current.capture == record.capture,
              current.sourceAssets == record.sourceAssets, current.entryIntent == record.entryIntent,
              current.recordSummaryWork == previous, current.recordBullets == record.recordBullets,
              current.summaryParagraphEdits == record.summaryParagraphEdits else { throw StoryEditError.staleRevision }
        if complete {
            if work.serviceWorkflowVersion != nil,let message=env.story.messages.firstIndex(where:{$0.id==work.id}) {
                guard env.story.messages[message].state=="queued" else {throw StoryEditError.staleRevision}
                env.story.messages[message].state="completed";env.story.messages[message].requestJSON=nil;env.story.messages[message].evidence=nil
            }
            env.sessions[i].capture?.needsRecordSummary = false
            let choiceSource = "Record choice review"
            let original = current.summaryEntries ?? []
            let medicationSection = SummaryEntryCategory.medications.displayTitle
            var entries = original.filter {
                if current.recordSummarySource == work.source && $0.category == .medications { return true }
                return $0.provenance != choiceSource || $0.origin != .generated || $0.isDeleted
            }
            let linkedBullets = work.bullets.map { draft in
                var bullet = draft
                let corrections = entries.filter { entry in
                    guard !entry.isDeleted, let original = entry.originalCategory else { return false }
                    if let id = bullet.bulletID, current.recordBullets?.contains(where: {
                        $0.bulletID == id && $0.detailEntryIDs?.contains(entry.id) == true
                    }) == true { return true }
                    var previous = entry
                    previous.category = original
                    return bullet.supports(previous)
                }
                let correctedHeadings = Set(corrections.map { ($0.category == .followUp ? SummaryEntryCategory.carePlan : $0.category).displayTitle })
                if correctedHeadings.count == 1, let heading = correctedHeadings.first { bullet.heading = heading }
                let correctedIDs = Set(corrections.map(\.id))
                let matches = entries.filter { $0.sourceSessionID == current.id && (correctedIDs.contains($0.id) || bullet.supports($0)) }
                bullet.detailEntryIDs = matches.filter { !$0.isDeleted }.map(\.id)
                if !corrections.isEmpty { return bullet }
                let booking = bullet.choice?.stance == "booked"
                let medication = bullet.heading == medicationSection
                if medication, bullet.choice == nil, let topic = bullet.medicationTopic,
                   let quote = bullet.evidenceQuotes?.first(where: { $0.localizedStandardContains(topic) }),
                   let id = bullet.bulletID, !matches.contains(where: { $0.category == .medications }),
                   !entries.contains(where: { $0.id == id }) {
                    let prior = original.first { $0.provenance == choiceSource && $0.category == .medications &&
                        $0.title.caseInsensitiveCompare(topic) == .orderedSame && $0.sourceExcerpt == quote }
                    let entry = prior ?? SummaryEntry(id: id, category: .medications, title: topic,
                        details: bullet.text, sourceSessionID: current.id, sourceTitle: current.displayTitle,
                        sourceDate: current.date, sourceExcerpt: quote, provenance: choiceSource)
                    if !entries.contains(where: { $0.id == entry.id }) { entries.append(entry) }
                    if !entry.isDeleted { bullet.detailEntryIDs?.insert(entry.id, at: 0) }
                    return bullet
                }
                let needsDetail: Bool
                if booking { needsDetail = !matches.contains { $0.category == .carePlan || $0.category == .followUp } }
                else if medication { needsDetail = !matches.contains { $0.category == .medications } }
                else { needsDetail = matches.isEmpty }
                if needsDetail, let choice = bullet.choice, let id = bullet.bulletID,
                   let quotes = bullet.evidenceQuotes, quotes.contains(choice.subjectQuote),
                   quotes.contains(choice.responseQuote), choice.isGrounded {
                    let category: SummaryEntryCategory = (booking || bullet.heading == SummaryEntryCategory.carePlan.displayTitle) ? .carePlan : medication ? .medications : .otherNotes
                    let title = choice.topic.prefix(1).uppercased() + choice.topic.dropFirst()
                    let prior = original.first {
                        $0.provenance == choiceSource && ($0.category == category || (medication && $0.category == .otherNotes)) && $0.title.caseInsensitiveCompare(title) == .orderedSame &&
                        $0.sourceExcerpt == choice.responseQuote
                    }
                    var entry = SummaryEntry(id: prior?.id ?? id, category: category, title: title,
                        details: bullet.text, fields: [
                            SummaryEntryField(label: booking ? "Appointment status" : "Preference or decision", value: choice.stance),
                            SummaryEntryField(label: "For", value: choice.recipient),
                            SummaryEntryField(label: "Topic in source", value: choice.subjectQuote)
                        ], sourceSessionID: current.id, sourceTitle: current.displayTitle, sourceDate: current.date,
                        sourceExcerpt: choice.responseQuote, provenance: choiceSource)
                    entry = SummaryVerification.sourceLinked(entry, source: current.transcript, evidence: choice.responseQuote)
                    entry.createdAt = prior?.createdAt ?? entry.createdAt
                    if !entries.contains(where: { $0.id == entry.id }) {
                        entries.append(entry)
                        bullet.detailEntryIDs?.insert(entry.id, at: 0)
                    }
                }
                return bullet
            }
            env.sessions[i].recordBullets = RecordBullet.groupedByCategory(linkedBullets)
            if entries != original { env.sessions[i].summaryEntries = entries }
            env.sessions[i].recordTemplateSelection = selection
            env.sessions[i].appliedRecordTemplate = selection.resolved(for: record)
            env.sessions[i].recordSummarySource = work.source
        }
        env.sessions[i].recordSummaryWork = complete ? nil : work
        try saveEnvelope(env)
    }

    public func saveRecordSummary(_ id: UUID, changes: [String: String], baseline: [String: String], title: String?) throws {
        var env = try loadEnvelope()
        guard let i = env.sessions.firstIndex(where: { $0.id == id }) else { throw StoryEditError.notFound }
        var edits = env.sessions[i].summaryParagraphEdits ?? [:]
        for (key, text) in changes {
            guard edits[key] == baseline[key] else { throw StoryEditError.staleRevision }
            edits[key] = text
        }
        env.sessions[i].summaryParagraphEdits = edits
        if let title { env.sessions[i].editedRecordTitle = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        try saveEnvelope(env)
    }

    public func reviseStorySource(_ recordID: UUID, text: String, expectedTranscript: String? = nil, title: String? = nil, revisedCapture: RecordCapture? = nil, expectedCapture: RecordCapture? = nil) throws {
        var env = try loadEnvelope();guard let i = env.sessions.firstIndex(where: {$0.id == recordID}) else {throw StoryEditError.notFound}
        if let expectedTranscript, env.sessions[i].transcript != expectedTranscript { throw StoryEditError.staleRevision }
        if let revisedCapture {
            guard env.sessions[i].capture == expectedCapture else { throw StoryEditError.staleRevision }
            env.sessions[i].capture = revisedCapture
        }
        if let title { env.sessions[i].editedRecordTitle = title.trimmingCharacters(in: .whitespacesAndNewlines) }
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
    public func recordStoryCareEvent(actionID: String, kind: String, text: String, factIDs: [String] = [], eventID: UUID = UUID()) throws {
        guard ["adopted", "paused", "stopped", "completed", "progress"].contains(kind) else {throw StoryEditError.invalidMutation}
        var env = try loadEnvelope();guard !env.story.careEvents.contains(where:{$0.id==eventID}) else {return}
        var event = StoryCareEvent(actionID:actionID,kind:kind,text:text);event.id=eventID
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
    public func setStoryFocus(_ actionID:String?) throws {var env=try loadEnvelope();env.story.focusActionID=actionID;try saveEnvelope(env)}
    public func setStoryCheckIn(enabled: Bool, day: String? = nil) throws {
        var env = try loadEnvelope();env.story.checkInsEnabled = enabled
        if let day {env.story.lastCheckInDay = day};try saveEnvelope(env)
    }
    @discardableResult public func addStoryMessage(role:String,text:String,citations:[String] = [],state:String = "saved") throws -> UUID {
        try addStoryMessage(StoryMessage(role:role,text:text,citationIDs:citations,state:state))
    }
    @discardableResult public func addStoryMessage(_ message: StoryMessage) throws -> UUID {
        var env = try loadEnvelope()
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
        let scope = env.story.messages[i].scopeRecordID
        if let scope, !evidence.allSatisfy({ $0.recordID == scope }) { throw StoryEditError.invalidMutation }
        var reply=StoryMessage(scopeRecordID:scope,role:"assistant",text:text,citationIDs:citations)
        reply.id=IncrementalRecordUpdate.stableID("story-answer:"+id.uuidString);reply.evidence=evidence.filter{citations.contains($0.id)}
        env.story.messages.append(reply);env.story.messages[i].state="completed";try saveEnvelope(env)
    }
    public func cancelStoryOperation(_ id:UUID) throws {
        var env=try loadEnvelope()
        if let i=env.story.edits.firstIndex(where:{$0.id==id}) {env.story.edits[i].state="cancelled";env.story.edits[i].cancellationPending=true}
        if let i=env.story.messages.firstIndex(where:{$0.id==id}) {env.story.messages[i].state="cancelled";env.story.messages[i].cancellationPending=true}
        for i in env.story.messages.indices where env.story.messages[i].summaryParentID == id && env.story.messages[i].state == "queued" {
            env.story.messages[i].state="cancelled";env.story.messages[i].cancellationPending=true
        }
        try saveEnvelope(env)
    }
    public func acknowledgeStoryCancellation(_ id:UUID) throws {
        var env=try loadEnvelope()
        if let i=env.story.edits.firstIndex(where:{$0.id==id}) {env.story.edits[i].cancellationPending=false}
        if let i=env.story.messages.firstIndex(where:{$0.id==id}) {env.story.messages[i].cancellationPending=false}
        try saveEnvelope(env)
    }
    public func storySources(factIDs:[String],correctionRecordID:UUID? = nil) throws -> [StoryEvidence] {
        let env=try loadEnvelope(),facts=HealthMemoryProjection.facts(in:try healthSnapshot())
        if let recordID=correctionRecordID,let revision=env.story.sources.last(where:{$0.recordID==recordID}) {
            return [StoryEvidence(id:revision.id.uuidString,text:revision.text,recordID:recordID,sourceRevisionID:revision.id,title:"Your correction")]
        }
        return facts.filter{factIDs.contains($0.id)}.flatMap {fact in fact.occurrences.map {entry in
            let quote=entry.supportingExcerpt ?? entry.title
            let source=env.story.sources.last(where:{$0.recordID==entry.sourceSessionID && $0.text.contains(quote)})
            return StoryEvidence(id:fact.id+":"+entry.id.uuidString,text:quote,recordID:entry.sourceSessionID,sourceRevisionID:source?.id,title:entry.sourceTitle ?? "Saved source")
        }}
    }
    @discardableResult public func resumeFailedStorySharedSummary(_ operationID: UUID, templateID: String) throws -> Bool {
        var env = try loadEnvelope()
        guard let index = env.story.messages.lastIndex(where: { $0.role == "system" && $0.text == "Share template: " + templateID }),
              env.story.messages[index].id == operationID,
              env.story.messages[index].state == "failed",
              env.story.messages[index].requestJSON != nil else { return false }
        env.story.messages[index].state = "queued"
        try saveEnvelope(env)
        return true
    }
    public func failStorySharedSummary(_ operationID:UUID) throws {
        var env=try loadEnvelope()
        if let index=env.story.messages.firstIndex(where:{$0.id==operationID && $0.role=="system" && $0.state=="queued"}) {
            env.story.messages[index].state="failed";try saveEnvelope(env)
        }
    }
    public func recordedSummaryPatientName(for summary: StorySharedSummary?) throws -> String? {
        let env = try loadEnvelope()
        let ids = summary.map { Set($0.evidence.compactMap(\.recordID)) }
        let revisions = Dictionary(env.story.sources.map { ($0.recordID, $0.text) }, uniquingKeysWith: { _, latest in latest })
        let documents = env.sessions.filter { ids?.contains($0.id) ?? true }.map { revisions[$0.id] ?? $0.transcript }
        return StorySummaryDocument.recordedPatientName(in: documents)
    }
    public func setSharedSummaryPatientName(_ name:String) throws {
        var env=try loadEnvelope()
        guard env.story.sharedSummary != nil else{return}
        let value=name.trimmingCharacters(in:.whitespacesAndNewlines)
        env.story.sharedSummary?.patientNameEdited=true
        env.story.sharedSummary?.patientName=value.isEmpty ? nil:value
        try saveEnvelope(env)
    }
    public func completeStorySharedSummary(_ operationID:UUID,summary:StorySharedSummary,expectedSnapshot:StorySummarySnapshot? = nil) throws {
        if let expectedSnapshot {
            let current=try storySummarySnapshot(includeTimeline:expectedSnapshot.evidence.contains{$0.timelineLabel != nil},includeCareTeam:expectedSnapshot.includesCareTeam == true)
            let saved=try loadEnvelope().story.sharedSummary
            // Older requests froze the display copy with recovered labs. Recreate
            // that same copy from current saved data; real edits still differ.
            let samePublication = try (saved==expectedSnapshot.publicationSummary ||
                recoveredStorySharedSummary()==expectedSnapshot.publicationSummary)
            guard try current.hasSameSources(as:expectedSnapshot), samePublication else {throw StoryEditError.staleRevision}
        }
        guard let template=StorySummaryTemplate(rawValue:summary.templateID),template.validatedText(summary.text) != nil else {throw StoryEditError.invalidMutation}
        var env=try loadEnvelope()
        guard let index=env.story.messages.firstIndex(where:{$0.id==operationID && $0.role=="system" && $0.state=="queued"}) else {throw StoryEditError.staleRevision}
        env.story.sharedSummary=summary;env.story.messages[index].state="completed";try saveEnvelope(env)
    }
    public func prepareSummaryStage(parentID:UUID,stage:String) throws -> StoryMessage {
        var env=try loadEnvelope()
        guard env.story.messages.contains(where:{$0.id==parentID && $0.state=="queued"}) else {throw StoryEditError.staleRevision}
        let id=IncrementalRecordUpdate.stableID("summary-stage:"+parentID.uuidString+":"+stage)
        if let existing=env.story.messages.first(where:{$0.id==id}) {return existing}
        var message=StoryMessage(role:"system",text:"Summary stage",state:"queued")
        message.id=id;message.summaryParentID=parentID
        env.story.messages.append(message);try saveEnvelope(env);return message
    }
    public func completeSummaryStage(_ id:UUID,text:String,evidence:[StoryEvidence]) throws {
        var env=try loadEnvelope()
        guard let i=env.story.messages.firstIndex(where:{$0.id==id && $0.state=="queued"}),
              let parent=env.story.messages[i].summaryParentID,
              env.story.messages.contains(where:{$0.id==parent && $0.state=="queued"}),
              StorySummaryTemplate.practitioner.validatedText(text) != nil else {throw StoryEditError.staleRevision}
        env.story.messages[i].text=text;env.story.messages[i].evidence=evidence
        env.story.messages[i].state="completed";try saveEnvelope(env)
    }
    /// Full eligible structured snapshot, packed by source. No relevance ranking or silent prefix truncation.
    /// Balance a selective overview across categories; include complete assertions
    /// with their qualifiers. A very long passage cannot crowd out other records.
    public func storyOverviewEvidence() throws -> [StoryEvidence] {
        let snapshot = try healthSnapshot()
        let facts = HealthMemoryProjection.facts(in: snapshot).filter {
            !$0.preference.hidden && HealthStoryEligibility.includes($0.displayEntry)
        }
        let groups = Dictionary(grouping: ConditionSummaryProjection.sorted(facts), by: { $0.category })
        var selected: [StoryEvidence] = []
        var bytes = 0
        func append(_ text: String, title: String, record: UUID?, revision: UUID? = nil) {
            guard !text.isEmpty, text.utf8.count <= 8000, bytes + text.utf8.count <= 32000, selected.count < 72 else { return }
            bytes += text.utf8.count
            selected.append(StoryEvidence(id: "E" + String(selected.count + 1), text: text, recordID: record,
                                          sourceRevisionID: revision, title: String(title.prefix(160))))
        }
        for index in 0..<(groups.values.map { $0.count }.max() ?? 0) {
            for category in SummaryEntryCategory.allCases {
                guard let group = groups[category], index < group.count else { continue }
                let fact = group[index], entry = fact.displayEntry
                let parts = [entry.title, entry.details, entry.supportingExcerpt, entry.evidence?.eventDate,
                             entry.evidence?.sourceAttribution, "Status: " + (fact.hasKnownStatus ? fact.statusTitle : "Unknown")]
                let text = (parts.compactMap { $0 }.filter { !$0.isEmpty } + entry.fields.map { $0.label + ": " + $0.value }).joined(separator: "\n")
                append(text, title: entry.sourceTitle ?? category.displayTitle, record: entry.sourceSessionID)
            }
            if selected.count >= 72 { break }
        }
        if selected.isEmpty && snapshot.sessions.allSatisfy({ $0.summaryEntries?.isEmpty != false }) {
            for session in snapshot.sessions.sorted(by: { $0.date > $1.date }) {
                for paragraph in session.transcript.split(whereSeparator: { $0.isNewline }) {
                    if paragraph.utf8.count <= 8000 {
                        append(String(paragraph), title: session.displayTitle, record: session.id)
                    } else {
                        let passage = String(paragraph)
                        passage.enumerateSubstrings(in: passage.startIndex..<passage.endIndex, options:.bySentences) { sentence, _, _, stop in
                            if let sentence { append(sentence, title: session.displayTitle, record: session.id) }
                            stop = selected.count >= 72 || bytes >= 32000
                        }
                    }
                }
            }
        }
        return selected
    }

    public func storySummaryEvidence(legacyDates:Bool=false,includeTimeline:Bool=true,includeCareTeam:Bool=true) throws -> [StoryEvidence] {
        let snapshot=try healthSnapshot()
        let facts=HealthMemoryProjection.facts(in:snapshot).filter{!$0.preference.hidden && HealthStoryEligibility.includes($0.displayEntry)}
        let sessions=try loadAll()
        var output:[StoryEvidence]=[]
        for fact in facts.sorted(by:{($0.displayEntry.sourceSessionID?.uuidString ?? "",$0.id)<($1.displayEntry.sourceSessionID?.uuidString ?? "",$1.id)}) {
            let entry=fact.displayEntry
            var lines=[entry.title,entry.details,"Category: "+fact.category.rawValue,"Recorded status: "+(fact.hasKnownStatus ? fact.statusTitle:"Unknown"),"Patient action status: "+(fact.preference.actionStatus?.rawValue ?? "Not explicitly adopted")]
            if legacyDates {
                if let date=entry.sourceDate {lines.append("Clinical date: "+date.formatted(.iso8601))}
            } else if !entry.dateNeedsReview {
                if let recorded=entry.evidence?.eventDate {lines.append("Recorded date: "+recorded)}
                else if let date=entry.relevantDate {lines.append("Clinical date: "+date.formatted(.iso8601))}
            }
            if includeCareTeam, let contactID=fact.preference.practitionerContactID,
               let contact=snapshot.careTeam.first(where:{$0.id==contactID}) {
                lines.append("Patient-linked care provider: " + contact.name + (contact.role.isEmpty ? "" : " — " + contact.role))
            }
            lines += entry.fields.map{$0.label+": "+$0.value}
            if let evidence=entry.evidence,let data=try? JSONEncoder().encode(evidence),var fields=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
                // Keep clinical qualifiers, medications, instructions and source excerpts; omit only processing/identity metadata.
                for key in ["medicationProductID","artifactSchema","wholeHistoryTopicIDs","conditionGroupReason","conditionSynthesisUnassigned","careOrganizationVersion","instructionIdentity","factIdentity","combinationExcluded","combinationPrimary"] {fields.removeValue(forKey:key)}
                if var assertion=fields["sourceAssertion"] as? [String:Any] {
                    for key in ["start","sourceHash","signature"] {assertion.removeValue(forKey:key)}
                    fields["sourceAssertion"]=assertion
                }
                if let compact=try? JSONSerialization.data(withJSONObject:fields,options:.sortedKeys),let json=String(data:compact,encoding:.utf8) {lines.append("Clinical evidence: "+json)}
            }
            let content=lines.filter{!$0.isEmpty}.joined(separator:"\n")
            let sourceID=entry.sourceSessionID
            let title=sessions.first(where:{$0.id==sourceID})?.displayTitle ?? "Saved health details"
            let timeline: String
            if !entry.dateNeedsReview, let date=entry.evidence?.eventDate, !date.isEmpty { timeline="Date: "+date }
            else if !entry.dateNeedsReview, let date=entry.relevantDate { timeline="Date: "+date.formatted(date:.abbreviated,time:.omitted) }
            else if let date=sessions.first(where:{$0.id==sourceID})?.date { timeline="Record: "+date.formatted(date:.abbreviated,time:.omitted) }
            else { timeline="Date unknown" }
            if let index=output.indices.last,(!includeTimeline || output[index].timelineLabel==timeline),output[index].recordID==sourceID,output[index].text.count+content.count<6000 {
                output[index].text += "\n\n"+content
            } else {
                var item=StoryEvidence(id:"E"+String(output.count+1),text:content,recordID:sourceID,title:title)
                item.timelineLabel=includeTimeline ? timeline:nil;output.append(item)
            }
        }
        if includeCareTeam {
            for contact in HealthFactMatching.displayContacts(snapshot.careTeam).sorted(by:{$0.id.uuidString<$1.id.uuidString}) where !contact.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                let content=["Saved care-team contact: " + contact.name,
                             contact.role.isEmpty ? "" : "Role: " + contact.role,
                             contact.organization.isEmpty ? "" : "Organization: " + contact.organization,
                             contact.notes.isEmpty ? "" : "Patient notes: " + contact.notes,
                             "A saved contact alone does not establish current treatment, a referral, or responsibility."].filter{!$0.isEmpty}.joined(separator:"\n")
                output.append(StoryEvidence(id:"CARE-"+contact.id.uuidString,text:content,recordID:nil,title:"Saved care team"))
            }
        }
        return output
    }
    public func storyTargetEvidence(_ ids:[String]) throws -> [StoryEvidence] {
        HealthMemoryProjection.facts(in:try healthSnapshot()).filter{ids.contains($0.id)}.map{StoryEvidence(id:$0.id,text:([$0.displayEntry.title,$0.displayEntry.details,"Category: "+$0.category.rawValue,"Status: "+($0.hasKnownStatus ? $0.statusTitle:"Unknown")]+$0.displayEntry.fields.map{$0.label+": "+$0.value}).joined(separator:"\n"),recordID:$0.latest.sourceSessionID,title:$0.displayEntry.title)}
    }
    private func storyQueryScope(_ query:String) -> String {
        let text=query.lowercased()
        if text.contains("all"),text.contains("medicat") {return "all_medications"}
        if text.contains("following") || text.contains("current plan") {return "current_plan"}
        return "retrieval"
    }
    private func storyQueryFacts(_ query:String) throws -> [HealthFact] {
        let facts=HealthMemoryProjection.facts(in:try healthSnapshot()).filter{!$0.preference.hidden && HealthStoryEligibility.includes($0.displayEntry)}
        switch storyQueryScope(query) {
        case "all_medications":return facts.filter{$0.category == .medications}
        case "current_plan":return facts.filter{$0.category == .carePlan && $0.preference.actionStatus == .current}
        default:return facts
        }
    }
    public func storyRetrievalMetadata(query:String,limit:Int) throws -> [String:String] {
        let scope=storyQueryScope(query), count=try storyQueryFacts(query).count
        return ["scope":scope,"availableCount":String(count),"returnedCount":String(min(count,max(1,min(limit,200)))),"complete":scope != "retrieval" && count <= limit && count <= 200 ? "true":"false"]
    }
    public func storyRecordEvidence(recordID: UUID, query: String) throws -> [StoryEvidence] {
        let envelope = try loadEnvelope()
        guard let record = envelope.sessions.first(where: { $0.id == recordID }) else { throw StoryEditError.notFound }
        let title = String(record.displayTitle.prefix(160))
        var sources = [record.transcript]
        if record.transcript.isEmpty, let capture = record.capture {
            sources.append(capture.notes)
            sources += capture.textByAsset.sorted { $0.key.uuidString < $1.key.uuidString }.map { $0.value }
        }
        if let summary = record.summary { sources.append(summary) }
        for key in (record.summaryParagraphEdits ?? [:]).keys.sorted() {
            if let edit = record.summaryParagraphEdits?[key], !edit.isEmpty { sources.append("Patient-edited summary: " + edit) }
        }
        var passages: [String] = []
        for source in sources {
            var remaining = source[...]
            while !remaining.isEmpty {
                let window = remaining.prefix(1400)
                let end = window.endIndex == remaining.endIndex ? window.endIndex :
                    (window.lastIndex(where: { $0.isWhitespace }).map { remaining.index(after: $0) } ?? window.endIndex)
                let passage = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                if !passage.isEmpty { passages.append(passage) }
                remaining = remaining[end...]
            }
        }
        let terms = Set(query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count > 2 })
        var ranked: [(Int, Int)] = []
        for (index, text) in passages.enumerated() {
            let words = text.lowercased()
            let score = terms.filter { words.contains(String($0)) }.count
            ranked.append((index, score))
        }
        ranked.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        // Offer independently citable original quotes alongside broader passages.
        // Match by topic but send only evidence that actually occurs in the record.
        let hidden = record.removedRecordDetails ?? []
        let detailSources = (record.summaryEntries ?? []).compactMap { entry -> (SummaryEntry, String, Int)? in
            guard !entry.isDeleted, entry.sourceSessionID == recordID,
                  hidden.isDisjoint(with: Session.removalKeys(entry)),
                  let quote = entry.supportingExcerpt, !quote.isEmpty,
                  sources.contains(where: { $0.localizedStandardContains(quote) }) else { return nil }
            let words = Set(RecordBullet.words(entry.title + " " + quote))
            let score = terms.filter { words.contains(String($0)) }.count
            return score > 0 ? (entry, quote, score) : nil
        }.sorted { $0.2 == $1.2 ? $0.0.id.uuidString < $1.0.id.uuidString : $0.2 > $1.2 }
        var evidence: [StoryEvidence] = []
        var bytes = 0
        for (entry, quote, _) in detailSources.prefix(12) where bytes + quote.utf8.count <= 6000 {
            bytes += quote.utf8.count
            evidence.append(StoryEvidence(id: "E" + String(evidence.count + 1), text: quote, recordID: recordID,
                title: entry.recordDetailHeading, detailEntryID: entry.id))
        }
        var selected: [Int] = []
        for (index, _) in ranked where selected.count + evidence.count < 72 {
            let size = passages[index].utf8.count
            guard bytes + size <= 32000 else { continue }
            bytes += size
            selected.append(index)
        }
        for index in selected.sorted() {
            evidence.append(StoryEvidence(id: "E" + String(evidence.count + 1), text: passages[index], recordID: recordID, title: title))
        }
        return evidence
    }
    public func storyEvidence(query:String, limit:Int = 24) throws -> [StoryEvidence] {
        let env = try loadEnvelope();let facts = try storyQueryFacts(query)
        let terms = query.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber}).map(String.init).filter{$0.count > 2}
        var evidence = facts.map {StoryEvidence(id:$0.id,text:([$0.displayEntry.title,$0.displayEntry.details,"Category: "+$0.category.rawValue,"Status: "+($0.hasKnownStatus ? $0.statusTitle:"Unknown")]+$0.displayEntry.fields.map{$0.label+": "+$0.value}).joined(separator:"\n"),recordID:$0.latest.sourceSessionID,title:$0.displayEntry.title)}
        if storyQueryScope(query) != "retrieval" {return Array(evidence.prefix(max(1,min(limit,200))))}
        let undoneRecords=Set(env.story.edits.filter{$0.state=="undone"}.compactMap(\.addedRecordID))
        let matchedSources = try matchingStorySourceIDs(query:query)
        for source in env.story.sources where !undoneRecords.contains(source.recordID) && env.story.sources.last(where:{$0.recordID == source.recordID})?.id == source.id && (matchedSources?.contains(source.id.uuidString) ?? true) {
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

extension SessionStore {
    public func prepareServiceSummary(_ request:ServiceSummaryRequest) throws -> ServiceSummaryRequest {
        var env=try loadEnvelope()
        guard let id=UUID(uuidString:request.id) else {throw StoryEditError.invalidMutation}
        if let old=env.story.messages.first(where:{$0.id==id}) {
            guard old.state=="queued",let saved=old.requestJSON else {throw StoryEditError.staleRevision}
            return try JSONDecoder().decode(ServiceSummaryRequest.self,from:Data(saved.utf8))
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var message=StoryMessage(role:"system",text:"Service summary: "+request.kind,state:"queued")
        message.id=id;message.scopeRecordID=UUID(uuidString:request.target);message.evidence=request.evidence
        message.requestJSON=String(decoding:try encoder.encode(request),as:UTF8.self)
        env.story.messages.append(message);try saveEnvelope(env);return request
    }
    public func finishServiceSummary(_ id:UUID) throws {
        var env=try loadEnvelope()
        guard let i=env.story.messages.firstIndex(where:{$0.id==id}),env.story.messages[i].state=="queued" else {throw StoryEditError.staleRevision}
        env.story.messages[i].state="completed";env.story.messages[i].requestJSON=nil;env.story.messages[i].evidence=nil
        try saveEnvelope(env)
    }
}
