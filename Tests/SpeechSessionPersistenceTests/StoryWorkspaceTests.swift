import XCTest
@testable import SpeechSessionPersistence
final class StoryWorkspaceTests:XCTestCase {
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
    }

}
