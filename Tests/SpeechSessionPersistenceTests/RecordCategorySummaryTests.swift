import XCTest
@testable import SpeechSessionPersistence

final class RecordCategorySummaryTests: XCTestCase {
    func testPatientCenteredWordingKeepsQualifiersAndOtherPeople() {
        XCTAssertEqual(RecordBullet.patientCenteredText("The patient reports back pain."), "Reported back pain.")
        XCTAssertEqual(RecordBullet.patientCenteredText("The patient might reconsider next week."), "Might reconsider next week.")
        XCTAssertEqual(RecordBullet.patientCenteredText("The patient's mother reports back pain."), "The patient's mother reports back pain.")
        XCTAssertEqual(RecordBullet.patientCenteredText("The clinician reports improvement."), "The clinician reports improvement.")
        XCTAssertEqual(RecordBullet.patientCenteredText("“The patient reports back pain.”"), "“The patient reports back pain.”")
    }

    func testManualDetailRemainsOnChosenBulletAfterReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        var record = Session(transcript: "We discussed the options.")
        var first = RecordBullet(heading: "Care Plans", text: "Options discussed", passages: [1])
        first.bulletID = UUID()
        var second = first
        second.bulletID = UUID()
        record.recordBullets = [first, second]
        try await store.upsert(record)
        var entry = SummaryEntry(category: .otherNotes, title: "My detail", sourceSessionID: record.id, origin: .userAdded)
        entry.linkedSummaryBlockKey = second.editKey
        try await store.saveSummaryEntry(entry)
        let reopened = try SessionStore(storageDirectory: directory)
        let records = try await reopened.loadAll()
        XCTAssertEqual(records.count, 1)
        let saved = try XCTUnwrap(records.first?.summaryEntries?.first)
        XCTAssertTrue(second.supports(saved))
        XCTAssertFalse(first.supports(saved))
    }

    func testTemplateSelectionForVisitsAndStandaloneRecords() {
        let visit = Session(transcript: "Any questions for me today? I think we’re okay with vitamin K.", inputType: .documentFile)
        let prescription = Session(transcript: "Prescription. Use in both eyes three times weekly.", inputType: .documentImage)
        let journal = Session(transcript: "At my visit we discussed the next appointment.", entryIntent: .personalJournal)
        XCTAssertEqual(RecordTemplateSelection.auto.resolved(for: visit), .visit)
        XCTAssertEqual(RecordTemplateSelection.auto.resolved(for: prescription), .categories)
        XCTAssertEqual(RecordTemplateSelection.auto.resolved(for: journal), .categories)
        XCTAssertEqual(RecordTemplateSelection.categories.resolved(for: visit), .categories)
        XCTAssertEqual(RecordTemplateSelection.visit.resolved(for: journal), .visit)
    }

    func testMedicationRepliesWithPDFLineBreaksAndPronouns() {
        let passage = "Castor oil is definitely your home version of inducting. I don't want to do it, no. In terms of the vitamin K shot, no one had followed up with me about that. I talked about oral with somebody, and but anyway, I\nthink that we're okay to do it."
        let replies = RecordBullet.explicitMedicationReplies(passages: [passage, passage], names: ["vitamin K", "castor oil"])
        XCTAssertEqual(replies.map(\.medicationTopic), ["castor oil", "vitamin K"])
        XCTAssertEqual(replies.map { $0.choice?.stance }, ["declined", "tentative preference"])
        XCTAssertTrue(replies.allSatisfy { point in (point.evidenceQuotes ?? []).allSatisfy(passage.contains) })
        XCTAssertEqual(replies.map(\.resolvedVisitSection), [.decided, .discussed])
        let unrelated = "We discussed castor oil. What about an examination? I don't want to do it, no."
        XCTAssertTrue(RecordBullet.explicitMedicationReplies(passages: [unrelated], names: ["castor oil"]).isEmpty)
    }

    func testMedicationReviewReplacesConflictingDraftsAndKeepsDistinctSubstances() throws {
        let vitamin = "Yet, in terms of the vitamin K shot, no one had followed up with me about that."
        let answer = "But I think we're OK to do it."
        func point(_ topic: String, _ subject: String, _ response: String, _ stance: String) -> RecordBullet {
            var item = RecordBullet(heading: "Medications", text: topic + " " + response, passages: [1])
            item.choice = RecordChoice(topic: topic, recipient: "unspecified", stance: stance,
                subjectQuote: subject, responseQuote: response)
            item.quote = subject
            item.evidenceQuotes = [subject, response]
            return item
        }
        let oil = point("castor oil", "But I did the castor oil thing.", "I don't want to do it, no.", "declined")
        let shot = point("vitamin K shot", vitamin, answer, "agreed")
        let draft = ["Vitamin K shot will be administered after birth.", "The patient discussed the vitamin K shot for the newborn."].map {
            RecordBullet(heading: "Medications", text: $0, passages: [1])
        }
        let result = RecordBullet.applyingChoiceReview([oil, shot], to: draft)
        XCTAssertEqual(result.map(\.medicationTopic), ["castor oil", "vitamin K shot"])
        XCTAssertEqual(result.map { $0.choice?.stance }, ["declined", "tentative preference"])
        XCTAssertFalse(result.contains { $0.text.contains("will be administered") })
        XCTAssertFalse(result.contains { $0.text.localizedCaseInsensitiveContains("the patient") })
        XCTAssertTrue(result.contains { $0.text.contains(answer) })
        let unrelated = SummaryEntry(category: .carePlan, title: "Care Plans", details: shot.text, sourceExcerpt: answer)
        XCTAssertFalse(shot.supports(unrelated))
    }

    func testPatientCategoryCorrectionSurvivesReloadAndRegeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let quote = "I don't want to do a sweep today."
        var record = Session(transcript: quote)
        var sweep = SummaryEntry(category: .medications, title: "Sweep", sourceSessionID: record.id,
                                 sourceExcerpt: quote, provenance: "Record choice review")
        record.summaryEntries = [sweep]
        var bullet = RecordBullet(heading: "Medications", text: "Declined a sweep today.", passages: [1])
        bullet.bulletID = UUID()
        bullet.quote = quote
        bullet.evidenceQuotes = [quote]
        bullet.detailEntryIDs = [sweep.id]
        record.recordBullets = [bullet]
        record.summaryParagraphEdits = [bullet.editKey: "I declined today."]
        try await store.upsert(record)
        sweep.category = .carePlan
        try await store.saveSummaryEntry(sweep)
        let reopened = try SessionStore(storageDirectory: directory)
        let records = try await reopened.loadAll()
        let edited = try XCTUnwrap(records.first)
        XCTAssertEqual(edited.recordBullets?.first?.heading, "Care Plans")
        var work = RecordSummaryWork(source: "updated")
        work.selection = .visit
        work.bullets = [bullet]
        try await reopened.checkpointRecordBullets(edited, work: work, previous: nil, complete: true)
        let refreshed = try await reopened.loadAll()
        let saved = try XCTUnwrap(refreshed.first)
        XCTAssertEqual(saved.recordTemplateSelection, .visit)
        XCTAssertEqual(saved.appliedRecordTemplate, .visit)
        XCTAssertEqual(saved.summaryEntries?.map(\.category), [.carePlan])
        XCTAssertEqual(saved.recordBullets?.first?.heading, "Care Plans")
        XCTAssertEqual(saved.recordBullets?.first?.detailEntryIDs, [sweep.id])
        XCTAssertEqual(saved.summaryParagraphEdits?[bullet.editKey], "I declined today.")
        let replacement = SummaryEntry(category: .medications, title: "Sweep", sourceSessionID: record.id, sourceExcerpt: quote)
        let merged = SummaryEntryMerge.merging(generated: [replacement], existing: saved.summaryEntries)
        XCTAssertEqual(merged.map(\.id), [sweep.id])
        XCTAssertEqual(merged.first?.category, .carePlan)
    }

    func testBookingAndContactRemainSeparateLinkedDetails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory, sqliteEnabled: true)
        let quotes = ["We do have another appointment for you.", "I think it's booked for the 19th.", "It looks like it's 10 in the morning.", "Yeah, with Nicole."]
        var record = Session(transcript: quotes.joined(separator: " "))
        let contact = SummaryEntry(category: .practitionerContact, title: "Care team contact — check original",
            details: "The patient says the appointment is with Nicole.", sourceSessionID: record.id, sourceExcerpt: quotes[3])
        record.summaryEntries = [contact]
        var bullet = RecordBullet(heading: "Care Plans", text: "Follow-up appointment with Nicole on the 19th at 10 a.m.", passages: [1])
        bullet.bulletID = UUID()
        bullet.quote = quotes[0]
        bullet.evidenceQuotes = quotes
        bullet.choice = RecordChoice(topic: "appointment", recipient: "patient", stance: "booked", subjectQuote: quotes[0], responseQuote: quotes[1])
        XCTAssertEqual(bullet.resolvedVisitSection, .nextSteps)
        XCTAssertEqual(contact.citedAppointmentContact, "Nicole")
        XCTAssertFalse(RecordChoice(topic: "appointment", recipient: "patient", stance: "booked",
                                   subjectQuote: quotes[0], responseQuote: "It is not booked yet.").isGrounded)
        try await store.upsert(record)
        var work = RecordSummaryWork(source: "revision")
        work.bullets = [bullet]
        try await store.checkpointRecordBullets(record, work: work, previous: nil, complete: true)
        let saved = try await store.healthSnapshot()
        let appointment = try XCTUnwrap(saved.sessions.first?.summaryEntries?.first { $0.category == .carePlan })
        XCTAssertEqual(appointment.title, "Appointment")
        XCTAssertTrue(HealthMemoryProjection.facts(in: saved).contains { $0.occurrences.contains { $0.id == appointment.id } })
        XCTAssertEqual(appointment.sourceExcerpt, quotes[1])
        XCTAssertEqual(saved.sessions.first?.recordBullets?.first?.detailEntryIDs, [appointment.id, contact.id])
    }

    func testNewbornPreferenceLinksAcrossTwoCitationsWithoutRecordingAdministration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory)
        let question = "Yet, in terms of the vitamin K shot, no one had followed up with me about that."
        let answer = "But I think we're OK to do it."
        var record = Session(transcript: question + " " + answer)
        let castor = SummaryEntry(category: .otherNotes, title: "Castor oil", sourceSessionID: record.id, sourceExcerpt: "I don't want to do it, no.")
        record.summaryEntries = [castor]
        var bullet = RecordBullet(heading: "Medications", text: "Leaning toward the newborn vitamin K shot.", passages: [1])
        bullet.bulletID = UUID()
        bullet.quote = question
        bullet.evidenceQuotes = [question, answer]
        bullet.choice = RecordChoice(topic: "vitamin K", recipient: "newborn", stance: "tentative preference", subjectQuote: question, responseQuote: answer)
        try await store.upsert(record)
        var work = RecordSummaryWork(source: "revision")
        work.bullets = [bullet]
        try await store.checkpointRecordBullets(record, work: work, previous: nil, complete: true)
        let snapshot = try await store.healthSnapshot()
        let saved = try XCTUnwrap(snapshot.sessions.first)
        let preference = try XCTUnwrap(saved.summaryEntries?.first { $0.id == bullet.bulletID })
        XCTAssertEqual(preference.category, .medications)
        let extractedAgain = SummaryEntryMerge.merging(generated: [], existing: [preference], supersedeUnmatchedGenerated: true)
        XCTAssertEqual(extractedAgain, [preference])
        XCTAssertEqual(preference.sourceExcerpt, answer)
        XCTAssertEqual(preference.fields.map(\.value), ["tentative preference", "newborn", question])
        XCTAssertEqual(saved.recordBullets?.first?.detailEntryIDs, [preference.id])
        XCTAssertFalse(bullet.supports(castor))
        try await store.checkpointRecordBullets(saved, work: work, previous: nil, complete: true)
        let repeated = try await store.healthSnapshot()
        XCTAssertEqual(repeated.sessions.first?.summaryEntries?.map(\.id), [castor.id, preference.id])
    }

    func testScopedRemovalAndUndoSurviveReloadAndRegeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(storageDirectory: directory, sqliteEnabled: true)
        let quote = "The appointment with Nicole is on the 19th."
        var record = Session(transcript: quote)
        let detail = SummaryEntry(category: .followUp, title: "Appointment with Nicole", sourceSessionID: record.id, sourceExcerpt: quote)
        let unrelated = SummaryEntry(category: .followUp, title: "Dental review", sourceSessionID: record.id, sourceExcerpt: "Dental review on Tuesday")
        record.summaryEntries = [detail, unrelated]
        var bullet = RecordBullet(heading: "Care Plans", text: "Appointment with Nicole on the 19th.", passages: [1])
        bullet.bulletID = UUID()
        bullet.quote = quote
        record.summaryParagraphEdits = [bullet.editKey: "My appointment with Nicole."]
        var other = Session(transcript: quote)
        let otherDetail = SummaryEntry(category: .followUp, title: detail.title, sourceSessionID: other.id, sourceExcerpt: quote)
        other.summaryEntries = [otherDetail]
        try await store.upsert(record)
        try await store.upsert(other)
        var work = RecordSummaryWork(source: "revision")
        work.bullets = [bullet]
        try await store.checkpointRecordBullets(record, work: work, previous: nil, complete: true)
        let keys = Session.removalKeys(detail)
        try await store.changeRecordDetailVisibility(record.id, keys: keys, hide: true)
        let reopened = try SessionStore(storageDirectory: directory, sqliteEnabled: true)
        let records = try await reopened.healthSnapshot().sessions
        let hidden = try XCTUnwrap(records.first { $0.id == record.id })
        let openingSnapshot = try await reopened.healthSnapshot(recordID: record.id)
        XCTAssertEqual(openingSnapshot.sessions.map(\.id), [record.id])
        XCTAssertEqual(openingSnapshot.sessions.first?.summaryEntries, hidden.summaryEntries)
        XCTAssertEqual(hidden.summaryEntries?.map(\.id), [unrelated.id])
        XCTAssertEqual(hidden.recordBullets?.first?.detailEntryIDs, [detail.id])
        XCTAssertEqual(hidden.summaryParagraphEdits?[bullet.editKey], "My appointment with Nicole.")
        XCTAssertEqual(hidden.transcript, quote)
        XCTAssertEqual(records.first { $0.id == other.id }?.summaryEntries?.first?.id, otherDetail.id)
        let regenerated = SummaryEntry(category: .followUp, title: detail.title, sourceSessionID: record.id, sourceExcerpt: quote)
        var updated = hidden
        updated.summaryEntries = [unrelated, regenerated]
        try await reopened.upsert(updated)
        let after = try await reopened.healthSnapshot().sessions
        XCTAssertEqual(after.first { $0.id == record.id }?.summaryEntries?.map(\.id), [unrelated.id])
        try await reopened.changeRecordDetailVisibility(record.id, keys: keys, hide: false)
        let restored = try await reopened.healthSnapshot().sessions
        XCTAssertTrue(restored.first { $0.id == record.id }?.summaryEntries?.contains(where: { $0.id == regenerated.id }) == true)
    }
}
