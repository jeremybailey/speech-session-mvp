import XCTest
@testable import SpeechSessionPersistence
final class StoryWorkspaceTests:XCTestCase {
    func testRecordChatIsolatesEvidenceAndSavedAnswers() async throws {
        let store = try store()
        let record = Session(transcript: "The appointment was on Tuesday.")
        let other = Session(transcript: "The appointment was on Friday.")
        try await store.save([record, other])
        let evidence = try await store.storyRecordEvidence(recordID: record.id, query: "appointment")
        XCTAssertEqual(evidence.map(\.text), [record.transcript])
        let question = StoryMessage.queuedQuestion("When?", recordID: record.id)
        try await store.addStoryMessage(question)
        let wrong = try await store.storyRecordEvidence(recordID: other.id, query: "appointment")
        do {
            try await store.completeStoryQuestion(question.id, text: "Friday", citations: ["E1"], evidence: wrong)
            XCTFail("Accepted evidence from another record")
        } catch StoryEditError.invalidMutation {}
        try await store.completeStoryQuestion(question.id, text: "Tuesday", citations: ["E1"], evidence: evidence)
        let workspace = try await store.storyWorkspace()
        XCTAssertEqual(workspace.messages.map(\.scopeRecordID), [record.id, record.id])
    }
    func testOverviewCanCiteASingleLongUnprocessedTranscript() async throws {
        let store = try store()
        let sentence = "This is a complete synthetic observation. "
        let record = Session(transcript:String(repeating:sentence,count:500))
        try await store.save([record])
        let evidence = try await store.storyOverviewEvidence()
        XCTAssertFalse(evidence.isEmpty)
        XCTAssertLessThanOrEqual(evidence.count,72)
        XCTAssertEqual(Set(evidence.map(\.id)).count,evidence.count)
        XCTAssertTrue(evidence.allSatisfy { $0.recordID == record.id && record.transcript.contains($0.text) })
    }
    func testNarrativeUsesSavedOverviewAndLocalEditsDoNotChangeFacts() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(storageDirectory:root)
        var env=try await store.loadEnvelope()
        env.wholeHistoryOverview="A saved, connected account of the patient's history."
        try await store.saveEnvelope(env)
        let seeded=try await store.storyNarrativeText()
        XCTAssertEqual(seeded,env.wholeHistoryOverview)
        try await store.saveStoryNarrativeText("My own account of what matters.")
        try await store.synchronizeStory()
        let written=try await store.storyNarrativeText(), workspace=try await store.storyWorkspace()
        XCTAssertEqual(written,"My own account of what matters.")
        XCTAssertTrue(workspace.edits.isEmpty)
        let records=try await store.loadAll();XCTAssertTrue(records.isEmpty)
        do {try await store.publishStoryNarrative("Late generation",revision:0,evidence:[]);XCTFail("Overwrote newer writing")} catch StoryEditError.staleRevision {}
    }
    func store() throws -> SessionStore {try SessionStore(storageDirectory:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),sqliteEnabled:true)}
    func seed(_ store:SessionStore) async throws {
        let record=Session(transcript:"I have neck pain.",summaryEntries:[SummaryEntry(category:.symptoms,title:"I have neck pain.",origin:.userAdded)])
        try await store.save([record]);try await store.synchronizeStory()
    }
    func testNarrativeDeletionDoesNotDeleteFactAndUndoRestoresWriting() async throws {
        let s=try store();try await seed(s);let original=try await s.healthSnapshot();let initialWorkspace=try await s.storyWorkspace();let block=try XCTUnwrap(initialWorkspace.blocks.first)
        let optionalID=try await s.editStoryBlock(block.id,text:"");let id=try XCTUnwrap(optionalID)
        let after=try await s.healthSnapshot();XCTAssertEqual(original.sessions,after.sessions)
        let state=try await s.storyWorkspace();XCTAssertEqual(state.edits.last?.state,"presentation");XCTAssertTrue(state.blocks[0].suppressed)
        try await s.undoStoryEdit(id);let restored=try await s.storyWorkspace();XCTAssertEqual(restored.blocks[0].text,block.text)
    }
    func testTypingCoalescesOriginalBeforeAndRejectsObsoleteResult() async throws {
        let s=try store();try await seed(s);let initialWorkspace=try await s.storyWorkspace();let block=try XCTUnwrap(initialWorkspace.blocks.first)
        let firstID=try await s.editStoryBlock(block.id,text:"I have knee pain");let first=try XCTUnwrap(firstID)
        let secondID=try await s.editStoryBlock(block.id,text:"I have knee pain.");let second=try XCTUnwrap(secondID)
        try await s.applyStoryEdit(first,kind:"correction",targets:block.factIDs)
        let pending=try await s.storyWorkspace();XCTAssertEqual(pending.edits.last?.before,block.text);XCTAssertEqual(pending.edits.first?.state,"superseded")
        try await s.applyStoryEdit(second,kind:"correction",targets:block.factIDs)
        try await s.applyStoryEdit(second,kind:"correction",targets:block.factIDs)
        let records=try await s.loadAll();XCTAssertEqual(records.count,2);XCTAssertEqual(records.last?.summaryEntries?.first?.origin,.userAdded)
        try await s.undoStoryEdit(second);let undo=try await s.loadAll();XCTAssertFalse(undo[0].summaryEntries![0].isDeleted);XCTAssertTrue(undo[1].summaryEntries![0].isDeleted)
    }
    func testSourceRevisionRetiresOnlyRemovedGeneratedEvidence() async throws {
        let s=try store();let id=UUID()
        let generated=SummaryEntry(category:.otherNotes,title:"TB was to be ruled out.",sourceSessionID:id,sourceExcerpt:"Rule out TB.")
        let manual=SummaryEntry(category:.symptoms,title:"My correction",origin:.userEdited)
        try await s.save([Session(id:id,transcript:"Rule out TB. Neck pain.",summaryEntries:[generated,manual])])
        try await s.reviseStorySource(id,text:"Neck pain.")
        let record=try await s.loadAll()[0];XCTAssertTrue(record.summaryEntries![0].isDeleted);XCTAssertFalse(record.summaryEntries![1].isDeleted)
        let history=try await s.storyWorkspace().sources;XCTAssertEqual(history.map(\.text),["Rule out TB. Neck pain.","Neck pain."])
        let reopened=try SessionStore(storageDirectory:await s.storageDirectory);let saved=try await reopened.storyWorkspace();XCTAssertEqual(saved.sources.map(\.text),history.map(\.text))
    }
    func testChatSaveAndAnswerAreIdempotentAndPersisted() async throws {
        let s=try store();let id=try await s.addStoryMessage(role:"user",text:"My neck hurts again",state:"queued")
        try await s.saveStoryMessageAsRecord(id);try await s.saveStoryMessageAsRecord(id)
        try await s.completeStoryQuestion(id,text:"No prior record found.",citations:[],evidence:[])
        try await s.completeStoryQuestion(id,text:"Duplicate",citations:[],evidence:[])
        let records=try await s.loadAll(),state=try await s.storyWorkspace();XCTAssertEqual(records.count,1);XCTAssertEqual(state.messages.count,2)
        let reopened=try SessionStore(storageDirectory:await s.storageDirectory);let reloaded=try await reopened.storyWorkspace();XCTAssertEqual(reloaded.messages.count,2)
    }
    func testProgressDoesNotStopRecurringPlanAndDailyPreferenceSurvives() async throws {
        let s=try store();try await s.recordStoryCareEvent(actionID:"a",kind:"adopted",text:"Walk daily")
        try await s.recordStoryCareEvent(actionID:"a",kind:"progress",text:"Walked; felt more pain")
        try await s.setStoryCheckIn(enabled:false,day:"2026-11-07")
        let state=try await s.storyWorkspace();XCTAssertEqual(state.careEvents.last(where:{$0.kind != "progress"})?.kind,"adopted");XCTAssertFalse(state.checkInsEnabled)
        let records=try await s.loadAll();XCTAssertEqual(records.count,1);XCTAssertEqual(records[0].transcript,"Walked; felt more pain")
    }
    func testCancelledChatCannotPublishLateAnswer() async throws {
        let s=try store()
        let id=try await s.addStoryMessage(role:"user",text:"What happened?",state:"queued")
        try await s.cancelStoryOperation(id)
        try await s.completeStoryQuestion(id,text:"Late answer",citations:[],evidence:[])
        let state=try await s.storyWorkspace()
        XCTAssertEqual(state.messages.count,1)
        XCTAssertEqual(state.messages[0].state,"cancelled")
    }
    func testRecordDraftSurvivesReopenWithoutMutatingPublishedSource() async throws {
        let s=try store();try await seed(s)
        let original=try await s.loadAll()[0]
        try await s.saveStorySourceDraft(original.id,text:"An unfinished correction")
        let reopened=try SessionStore(storageDirectory:await s.storageDirectory,sqliteEnabled:true)
        let workspace=try await reopened.storyWorkspace(), records=try await reopened.loadAll()
        XCTAssertEqual(workspace.sourceDrafts?[original.id.uuidString],"An unfinished correction")
        XCTAssertEqual(records[0].transcript,original.transcript)
        try await reopened.reviseStorySource(original.id,text:"Corrected source")
        let committed=try await reopened.storyWorkspace()
        XCTAssertNil(committed.sourceDrafts?[original.id.uuidString])
        XCTAssertEqual(committed.sources.last?.text,"Corrected source")
    }
    func testPatientCorrectionCitesItsOwnRecord() async throws {
        let s=try store();try await seed(s)
        let workspace=try await s.storyWorkspace(), block=try XCTUnwrap(workspace.blocks.first)
        let pending=try await s.editStoryBlock(block.id,text:"I meant knee pain.")
        try await s.applyStoryEdit(try XCTUnwrap(pending),kind:"correction",targets:block.factIDs)
        let changed=try await s.storyWorkspace(), records=try await s.loadAll()
        XCTAssertEqual(changed.blocks[0].correctionRecordID,records.last?.id)
        XCTAssertEqual(records[0].transcript,"I have neck pain.")
        try await s.undoStoryEdit(try XCTUnwrap(pending))
        let evidence=try await s.storyEvidence(query:"knee pain",limit:200),pendingRecords=try await s.recordsNeedingIncrementalUpdate()
        XCTAssertFalse(evidence.contains(where:{$0.recordID==records.last?.id}))
        XCTAssertFalse(pendingRecords.contains(where:{$0.id==records.last?.id}))
    }

    func testRepeatedProgressSubmissionCreatesOneRecord() async throws {
        let s=try store(), id=UUID()
        try await s.recordStoryCareEvent(actionID:"daily-walk",kind:"progress",text:"Completed today's walk",eventID:id)
        try await s.recordStoryCareEvent(actionID:"daily-walk",kind:"progress",text:"Completed today's walk",eventID:id)
        let state=try await s.storyWorkspace(),records=try await s.loadAll()
        XCTAssertEqual(state.careEvents.count,1);XCTAssertEqual(records.count,1)
    }
    func testRemovingOneSourceKeepsIndependentEvidence() async throws {
        let s=try store(), first=UUID(),second=UUID()
        let text="Neck pain recorded."
        let a=SummaryEntry(category:.symptoms,title:"Neck pain",sourceSessionID:first,sourceExcerpt:text)
        let b=SummaryEntry(category:.symptoms,title:"Neck pain",sourceSessionID:second,sourceExcerpt:text)
        try await s.save([Session(id:first,transcript:text,summaryEntries:[a]),Session(id:second,transcript:text,summaryEntries:[b])])
        try await s.reviseStorySource(first,text:"Corrected unrelated note.")
        let records=try await s.loadAll()
        XCTAssertTrue(records[0].summaryEntries![0].isDeleted)
        XCTAssertFalse(records[1].summaryEntries![0].isDeleted)
    }
    func testCarePlanQueryDoesNotAssumeAdoption() async throws {
        let s=try store()
        try await s.save([Session(transcript:"Recorded recommendation",summaryEntries:[SummaryEntry(category:.carePlan,title:"Synthetic recorded recommendation",origin:.userAdded)])])
        let info=try await s.storyRetrievalMetadata(query:"What is my current plan?",limit:100)
        let evidence=try await s.storyEvidence(query:"What is my current plan?",limit:100)
        XCTAssertEqual(info["scope"],"current_plan");XCTAssertEqual(info["complete"],"true");XCTAssertTrue(evidence.isEmpty)
    }

    func testExplicitPlanAdoptionAndUndoPreserveRecommendation() async throws {
        let s=try store()
        try await s.save([Session(transcript:"Synthetic recommendation",summaryEntries:[SummaryEntry(category:.carePlan,title:"Synthetic recommendation",origin:.userAdded)])])
        try await s.synchronizeStory()
        let workspace=try await s.storyWorkspace(),block=try XCTUnwrap(workspace.blocks.first),factID=try XCTUnwrap(block.factIDs.first)
        let optionalID=try await s.editStoryBlock(block.id,text:"I am following this recommendation.")
        let id=try XCTUnwrap(optionalID)
        try await s.applyStoryEdit(id,kind:"correction",targets:[],actionUpdates:[factID:"current"])
        let updated=try await s.healthSnapshot(),records=try await s.loadAll()
        XCTAssertEqual(updated.preferences.first(where:{$0.id==factID})?.actionStatus,.current)
        XCTAssertFalse(records[0].summaryEntries![0].isDeleted)
        try await s.undoStoryEdit(id)
        let undone=try await s.healthSnapshot(),history=try await s.storyWorkspace()
        XCTAssertNotEqual(undone.preferences.first(where:{$0.id==factID})?.actionStatus,.current)
        XCTAssertEqual(history.careEvents.count,2)
    }

}
