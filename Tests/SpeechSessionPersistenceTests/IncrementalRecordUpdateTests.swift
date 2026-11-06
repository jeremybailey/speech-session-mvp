import XCTest
@testable import SpeechSessionPersistence
final class IncrementalRecordUpdateTests: XCTestCase {
    private func fact(_ session:Session,text:String="Example recorded",category:String="medications") throws -> IncrementalRecordFact {
        let value:[String:Any]=["id":"f1","occurrenceID":"source-occurrence","category":category,"text":text,"quote":session.transcript,"name":"Example","fields":[],"status":"reported","attribution":"","date":"","conditions":[],"sourceHash":IncrementalRecordUpdate.sourceHash(session.transcript),"recordID":session.id.uuidString.lowercased(),"unitKey":"unit-1","start":0]
        return try JSONDecoder().decode(IncrementalRecordFact.self,from:JSONSerialization.data(withJSONObject:value))
    }
    func testPublicationIsIdempotentAndPreservesPatientEdits() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(storageDirectory:root,sqliteEnabled:true)
        let session=Session(date:Date(timeIntervalSince1970:1000),transcript:"Example tablet")
        try await store.save([session])
        let receipt=RecordUpdateReceipt(sources:[session.id.uuidString:IncrementalRecordUpdate.sourceHash(session.transcript)])
        try await store.saveRecordUpdateReceipt(receipt)
        let candidate=try fact(session)
        for _ in 0..<2 {try await store.publishRecordUnit([candidate],recordID:session.id,sourceHash:candidate.sourceHash,unitKey:candidate.unitKey,updateID:receipt.id)}
        var saved=try await store.loadAll()[0]
        XCTAssertEqual(saved.summaryRevisions?.count,1)
        XCTAssertEqual(saved.summaryEntries?.count,1)
        saved.summaryEntries![0].origin = .userEdited;saved.summaryEntries![0].title="My edited medication"
        try await store.upsert(saved)
        let second=RecordUpdateReceipt(sources:receipt.sources);try await store.saveRecordUpdateReceipt(second)
        try await store.publishRecordUnit([fact(session,text:"Different wording")],recordID:session.id,sourceHash:candidate.sourceHash,unitKey:"unit-2",updateID:second.id)
        let final=try await store.loadAll()[0]
        XCTAssertEqual(final.summaryEntries?.count,1)
        XCTAssertEqual(final.summaryEntries?.first?.title,"My edited medication")
        try await store.finishRecordUpdate(second.id,state:"completed")
        let pending=try await store.recordsNeedingIncrementalUpdate();XCTAssertTrue(pending.isEmpty)
    }
    func testChangedSourceAndCancelledUpdateCannotPublish() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(storageDirectory:root)
        let session=Session(transcript:"Example tablet");try await store.save([session])
        let candidate=try fact(session)
        let receipt=RecordUpdateReceipt(sources:[session.id.uuidString:candidate.sourceHash],state:"cancelled")
        try await store.saveRecordUpdateReceipt(receipt)
        do {try await store.publishRecordUnit([candidate],recordID:session.id,sourceHash:candidate.sourceHash,unitKey:"unit",updateID:receipt.id);XCTFail("Cancelled publication") }catch{}
        var changed=session;changed.transcript="Changed original";try await store.upsert(changed)
        XCTAssertThrowsError(try IncrementalRecordUpdate.entries([candidate],session:changed))
        let saved=try await store.loadAll();XCTAssertNil(saved[0].summaryEntries)
    }
    func testRecategorizationUsesSameOccurrenceIdentity() throws {
        let session=Session(transcript:"Example tablet")
        let a=try IncrementalRecordUpdate.entries([fact(session)],session:session)
        let b=try IncrementalRecordUpdate.entries([fact(session,text:"Updated wording",category:"otherNotes")],session:session)
        XCTAssertEqual(a[0].id,b[0].id)
    }
    func testShiftedSourceKeepsPatientOverrideAndProductIdentity() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(storageDirectory:root,sqliteEnabled:true)
        var session=Session(transcript:"Example tablet");try await store.save([session])
        let initial=try fact(session),receipt=RecordUpdateReceipt(sources:[session.id.uuidString:initial.sourceHash])
        try await store.saveRecordUpdateReceipt(receipt)
        try await store.publishRecordUnit([initial],recordID:session.id,sourceHash:initial.sourceHash,unitKey:"first",updateID:receipt.id)
        session=try await store.loadAll()[0]
        let occurrence=session.summaryEntries![0].id,product=session.summaryEntries![0].evidence?.medicationProductID
        XCTAssertNotNil(product)
        session.summaryEntries![0].origin = .userEdited
        session.summaryEntries![0].title="My saved name"
        session.summaryEntries![0].fields=[.init(label:"note",value:"My correction")]
        session.transcript="Header\nExample tablet";try await store.upsert(session)
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(initial)) as! [String:Any]
        object["sourceHash"]=IncrementalRecordUpdate.sourceHash(session.transcript)
        object["start"]=7;object["occurrenceID"]="moved-source-occurrence"
        let moved=try JSONDecoder().decode(IncrementalRecordFact.self,from:JSONSerialization.data(withJSONObject:object))
        let update=RecordUpdateReceipt(sources:[session.id.uuidString:moved.sourceHash]);try await store.saveRecordUpdateReceipt(update)
        try await store.publishRecordUnit([moved],recordID:session.id,sourceHash:moved.sourceHash,unitKey:"shifted",updateID:update.id)
        let saved=try await store.loadAll()[0]
        XCTAssertEqual(saved.summaryEntries?.count,1)
        XCTAssertEqual(saved.summaryEntries?[0].id,occurrence)
        XCTAssertEqual(saved.summaryEntries?[0].title,"My saved name")
        XCTAssertEqual(saved.summaryEntries?[0].evidence?.medicationProductID,product)
    }
    func testAmbiguousOccurrencesAndDifferentRegimensAreNotCollapsed() throws {
        let session=Session(transcript:"Example tablet")
        let entry=try IncrementalRecordUpdate.entries([fact(session)],session:session)[0]
        var a=entry,b=entry,candidate=entry
        a.id=UUID();b.id=UUID();candidate.id=UUID()
        a.evidence?.factIdentity="a";b.evidence?.factIdentity="b";candidate.evidence?.factIdentity="c"
        XCTAssertNil(AssertionReconciler.match(candidate,in:[a,b]))
        candidate.evidence?.sourceAssertion?.signature="different regimen"
        XCTAssertNil(AssertionReconciler.match(candidate,in:[a]))
    }

    func testProductsKeepStrengthsSeparateAndEventsDistinct() throws {
        let session=Session(transcript:"Example 5mg and Example 10mg")
        func make(_ strength:String,_ status:String,_ occurrence:String) throws -> SummaryEntry {
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(fact(session))) as! [String:Any]
            object["fields"]=[["key":"strength","value":strength]];object["status"]=status;object["occurrenceID"]=occurrence
            let row=try JSONDecoder().decode(IncrementalRecordFact.self,from:JSONSerialization.data(withJSONObject:object))
            return try IncrementalRecordUpdate.entries([row],session:session)[0]
        }
        let prescription=try make("5mg","prescribed","rx")
        let fill=try make("5mg","dispensed","fill")
        let otherStrength=try make("10mg","prescribed","other")
        XCTAssertEqual(prescription.evidence?.medicationProductID,fill.evidence?.medicationProductID)
        XCTAssertNotEqual(prescription.id,fill.id)
        XCTAssertNotEqual(prescription.evidence?.medicationProductID,otherStrength.evidence?.medicationProductID)
        XCTAssertEqual(prescription.evidence?.medicationEventKind,"prescription")
        XCTAssertEqual(fill.evidence?.medicationEventKind,"dispensing")
        XCTAssertEqual(fill.evidence?.statusExplicit,false)
    }

    func testCheckedConditionSystemPublishesAndUpgradesOnlyUnknownTopic() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try SessionStore(storageDirectory:root)
        let session=Session(transcript:"Example tablet");try await store.save([session])
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(fact(session))) as! [String:Any]
        object["conditions"]=["Eye concern"]
        let legacy=try JSONDecoder().decode(IncrementalRecordFact.self,from:JSONSerialization.data(withJSONObject:object))
        let receipt=RecordUpdateReceipt(sources:[session.id.uuidString:legacy.sourceHash]);try await store.saveRecordUpdateReceipt(receipt)
        try await store.publishRecordUnit([legacy],recordID:session.id,sourceHash:legacy.sourceHash,unitKey:"old",updateID:receipt.id)
        object["conditionSystems"]=[["name":"Eye concern","system":"eye"]]
        let checked=try JSONDecoder().decode(IncrementalRecordFact.self,from:JSONSerialization.data(withJSONObject:object))
        try await store.publishRecordUnit([checked],recordID:session.id,sourceHash:checked.sourceHash,unitKey:"checked",updateID:receipt.id)
        let snapshot=try await store.healthSnapshot()
        XCTAssertEqual(snapshot.topics.count,1);XCTAssertEqual(snapshot.topics[0].bodySystem,"eye")
        let groups=ConditionSummaryProjection.groups(facts:HealthMemoryProjection.facts(in:snapshot),topics:snapshot.topics)
        XCTAssertEqual(HealthAreaProjection.groups(groups).map(\.id),[.eye])
    }

}
