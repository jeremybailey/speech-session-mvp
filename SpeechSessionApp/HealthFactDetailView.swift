import SwiftUI
import SpeechSessionFeatures
import SpeechSessionPersistence

struct HealthFactDetailView: View {
    let factID: String
    var preferredEntryID: UUID? = nil
    var sourceOnlyEntry: SummaryEntry? = nil
    @ObservedObject var model: HealthSummaryModel
    @ObservedObject var home: HomeViewModel
    let store: SessionStore
    var removeFromRecord: (() async throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private var selectedFact: HealthFact? {
        let named = model.facts.first { $0.id == factID }
        guard let preferredEntryID else { return named }
        if named?.occurrences.contains(where: { $0.id == preferredEntryID }) == true { return named }
        return model.facts.first { $0.occurrences.contains { $0.id == preferredEntryID } }
    }

    var body: some View {
        Group {
            if let sourceOnlyEntry, let fact = HealthMemoryProjection.facts(in: HealthMemorySnapshot(
                sessions: [Session(transcript: "", summaryEntries: [sourceOnlyEntry])], preferences: model.snapshot.preferences), verifiedOnly: false).first {
                HealthFactEditor(fact: fact, preferredEntryID: sourceOnlyEntry.id, model: model, home: home, store: store, addingFromSource: true)
            } else if let fact = selectedFact {
                HealthFactEditor(fact: fact, preferredEntryID: preferredEntryID, model: model, home: home, store: store, removeFromRecord: removeFromRecord)
            } else {
                ContentUnavailableView("Detail unavailable", systemImage: "doc")
                    .toolbar { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct HealthFactEditor: View {
    let fact: HealthFact
    let initialDisplayEntry: SummaryEntry
    let originalEntry: SummaryEntry
    var addingFromSource: Bool = false
    @ObservedObject var model: HealthSummaryModel
    @ObservedObject var home: HomeViewModel
    let store: SessionStore
    let removeFromRecord: (() async throws -> Void)?
    @State private var removalError: String?
    @Environment(\.dismiss) private var dismiss
    @State private var entry: SummaryEntry
    @State private var dateText: String
    @State private var reviewed: Bool
    @State private var status: SummaryEntryClinicalStatus?
    @State private var actionStatus: CareActionStatus?
    @State private var reminder: Bool
    @State private var reminderDate: Date
    @State private var careGoal: String
    @State private var careSchedule: String
    @State private var careReview: String
    @State private var recurring: Bool?
    @State private var saving = false
    @State private var practitionerID: UUID?
    @State private var choosingPractitioner = false
    @Environment(\.storyRouter) private var storyRouter
    @State private var source: Session?
    @State private var remove = false

    init(fact: HealthFact, preferredEntryID: UUID?, model: HealthSummaryModel, home: HomeViewModel, store: SessionStore, addingFromSource: Bool = false, removeFromRecord: (() async throws -> Void)? = nil) {
        self.removeFromRecord = removeFromRecord
        self.addingFromSource = addingFromSource
        self.fact = fact; self.model = model; self.home = home; self.store = store
        let sourceEntry = preferredEntryID.flatMap { id in fact.occurrences.first { $0.id == id } } ?? fact.latest
        self.originalEntry = sourceEntry
        var displayEntry = BClinicalPresentation.display(sourceEntry)
        displayEntry.title = HealthStoryText.clean(displayEntry.title)
        displayEntry.details = HealthStoryText.clean(displayEntry.details)
        if CareInstructionPresentation.applies(displayEntry) {
            displayEntry.title = CareInstructionPresentation.instruction(sourceEntry)
            let directions = sourceEntry.evidence?.careInstruction?.directions ?? HealthStoryText.clean(displayEntry.details)
            displayEntry.details = CareInstructionPresentation.canonical(directions) == CareInstructionPresentation.canonical(displayEntry.title) ? "" : directions
        }
        _careGoal = State(initialValue: sourceEntry.evidence?.careInstruction?.goal ?? "")
        _careSchedule = State(initialValue: sourceEntry.evidence?.careInstruction?.schedule ?? "")
        _careReview = State(initialValue: sourceEntry.evidence?.careInstruction?.reviewTiming ?? "")
        _recurring = State(initialValue: sourceEntry.evidence?.careInstruction?.isRecurring)
        _practitionerID = State(initialValue: fact.preference.practitionerContactID)
        initialDisplayEntry = displayEntry
        _entry = State(initialValue: displayEntry)
        _dateText = State(initialValue: displayEntry.evidence?.eventDate ?? "")
        _reviewed = State(initialValue: fact.isReviewed)
        _status = State(initialValue: fact.hasKnownStatus ? fact.clinicalStatus : nil)
        _actionStatus = State(initialValue: fact.actionStatus)
        _reminder = State(initialValue: fact.preference.reminderEnabled)
        _reminderDate = State(initialValue: fact.preference.dueDate ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        Form {
            Section {
                Picker("Category", selection: $entry.category) {
                    ForEach(SummaryEntryCategory.allCases.filter { $0 != .followUp || originalEntry.category == .followUp }, id: \.self) { category in
                        Text(category.displayTitle).tag(category)
                    }
                }
                if originalEntry.origin == .generated && originalEntry.recordDetailHeading != entry.title {
                    Text(originalEntry.recordDetailHeading).font(StoryDesignTokens.font(.headline, weight: .semibold))
                }
                TextField(CareInstructionPresentation.applies(entry) ? "Instruction" : "Title", text: $entry.title, axis: .vertical).font(StoryDesignTokens.font(.body))
                careField(CareInstructionPresentation.applies(entry) ? "Additional directions" : "Details", text: $entry.details)
                if CareInstructionPresentation.applies(entry) {
                    careField("Goal", text: $careGoal)
                    careField("Schedule", text: $careSchedule)
                    careField("Review timing", text: $careReview)
                    if fact.isAction {
                        Picker("How often", selection: $recurring) {
                            Text("Not recorded").tag(Optional<Bool>.none)
                            Text("One time").tag(Optional(false))
                            Text("Ongoing or repeated").tag(Optional(true))
                        }
                    }
                }
                LabeledContent("When") { TextField("Date or unknown", text: $dateText).multilineTextAlignment(.trailing) }
                ForEach($entry.fields) { $field in
                    if !HealthDetailPresentation.isPractitionerField(field.label) && !HealthStoryText.isInternalField(field.label) && !(field.label.lowercased() == "details" && originalEntry.fields.first(where: { $0.id == field.id })?.value == originalEntry.details) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label).font(StoryDesignTokens.font(.subheadline)).foregroundStyle(StoryDesignTokens.secondaryInk)
                        TextField("Not recorded", text: $field.value, axis: .vertical)
                    }
                    }
                }
            }
            if fact.category != .practitionerContact {
                Section("Practitioner") {
                    Button { choosingPractitioner = true } label: {
                        LabeledContent("Contact", value: model.snapshot.careTeam.first(where: { $0.id == practitionerID })?.name ?? "Choose or add")
                    }
                    let sourceNames = ([entry.evidence?.practitioner].compactMap { $0 }
                        + originalEntry.fields.filter { HealthDetailPresentation.isPractitionerField($0.label) }.map(\.value))
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    ForEach(Array(Set(sourceNames)).sorted(), id: \.self) { name in
                        Text("From source: \(name)").font(StoryDesignTokens.font(.subheadline)).foregroundStyle(StoryDesignTokens.secondaryInk)
                    }
                }
                Section("Status") {
                    if fact.isAction {
                        Picker("Status", selection: $actionStatus) {
                            Text("Unknown").tag(Optional<CareActionStatus>.none)
                            Text("Current").tag(Optional(CareActionStatus.current))
                            Text("Not current").tag(Optional(CareActionStatus.past))
                            Text("Completed").tag(Optional(CareActionStatus.completed))
                            Text("Paused").tag(Optional(CareActionStatus.paused))
                        }
                    } else {
                        Picker("Status", selection: $status) {
                            Text("Unknown").tag(Optional<SummaryEntryClinicalStatus>.none)
                            Text("Current").tag(Optional(SummaryEntryClinicalStatus.current))
                            Text("Not current").tag(Optional(SummaryEntryClinicalStatus.past))
                        }
                    }
                }
            }
            if fact.isAction && actionStatus == .current {
                Section {
                    Toggle("Remind me", isOn: $reminder)
                    if reminder { DatePicker("When", selection: $reminderDate, in: Date()...) }
                } footer: {
                    if originalEntry.evidence?.actionKind == "self_directed" {
                        Text("Added as a personal step. You can use a reminder to discuss it with your care provider.")
                    }
                }
            }
            Section("From your records") {
                ForEach(fact.occurrences) { occurrence in
                    VStack(alignment: .leading, spacing: 8) {
                        if let excerpt = occurrence.supportingExcerpt {
                            Text("“\(excerpt)”").textSelection(.enabled)
                        }
                        if occurrence.id != originalEntry.id {
                            Text(occurrence.details.isEmpty ? occurrence.title : occurrence.details)
                        }
                        if let record = model.snapshot.sessions.first(where: { $0.id == occurrence.sourceSessionID }) {
                            Button("Open \(record.title ?? "original record")") {
                                if let storyRouter {
                                    if let quote = occurrence.supportingExcerpt, record.capture != nil {
                                        storyRouter.captureExcerpt = (record.id, quote)
                                    }
                                    storyRouter.open(.record(record.id))
                                }
                                else { source = record }
                            }
                                .frame(minHeight: 44)
                            Text("Added \(record.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(StoryDesignTokens.font(.subheadline)).foregroundStyle(StoryDesignTokens.secondaryInk)
                        }
                    }.padding(.vertical, 4)
                }
            }
            Section {
                if reviewed {
                    Label("You checked this detail", systemImage: "checkmark.circle")
                    Button("Undo check") { reviewed = false }
                } else {
                    Text("Does this detail match your record?")
                        .font(StoryDesignTokens.font(.headline))
                        .accessibilityAddTraits(.isHeader)
                    Button("Yes, it matches") { reviewed = true }
                    let notes = fact.reviewReasons.filter { $0 != SummaryVerification.sourceLinkedNotice }
                    if !notes.isEmpty {
                        DisclosureGroup("Things to check") {
                            ForEach(notes, id: \.self) { Text($0) }
                        }
                    }
                }
            } footer: {
                if reviewed != fact.isReviewed {
                    Text("Tap Save to keep this change.")
                }
                if fact.isAction && originalEntry.evidence?.actionKind == "self_directed" && actionStatus == .current {
                    Text("Once you check this step, it can appear in Next steps.")
                }
            }
            Section {
                Button(removeFromRecord == nil ? "Remove from summary" : "Remove from this record", role: .destructive) { remove = true }
            } footer: { Text("Removing a detail keeps your original records.") }
        }
        .storyListCanvas()
        .navigationTitle("Health detail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(saving || entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .interactiveDismissDisabled(saving)
        .sheet(isPresented: $choosingPractitioner) {
            PractitionerPicker(model: model) { practitionerID = $0 }
        }
        .sheet(item: $source) { record in
            NavigationStack {
                SessionDetailView(session: record, store: store, home: home, initialTab: .source)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { source = nil } } }
            }
        }
        .confirmationDialog(removeFromRecord == nil ? "Remove this detail from the summary?" : "Remove this detail from this record?", isPresented: $remove, titleVisibility: .visible) {
            Button("Remove detail", role: .destructive) {
                if let removeFromRecord { removeLocal(removeFromRecord) }
                else { Task { await model.removeFromSummary(fact); if model.error == nil { dismiss() } } }
            }
        } message: { Text("The original records and history will be kept.") }
        .alert("Could not remove detail", isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })) {
            if let removeFromRecord { Button("Retry") { removeLocal(removeFromRecord) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(removalError ?? "") }
        .alert("Could not save", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func removeLocal(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action(); dismiss() }
            catch { removalError = error.localizedDescription }
        }
    }

    private func careField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(StoryDesignTokens.font(.subheadline)).foregroundStyle(StoryDesignTokens.secondaryInk).fixedSize(horizontal: false, vertical: true)
            TextField("Not recorded", text: text, axis: .vertical).accessibilityLabel(label)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var categoryOnly = initialDisplayEntry
        categoryOnly.category = entry.category
        let unchangedFields = dateText == (initialDisplayEntry.evidence?.eventDate ?? "") &&
            careGoal == (originalEntry.evidence?.careInstruction?.goal ?? "") &&
            careSchedule == (originalEntry.evidence?.careInstruction?.schedule ?? "") &&
            careReview == (originalEntry.evidence?.careInstruction?.reviewTiming ?? "") &&
            recurring == originalEntry.evidence?.careInstruction?.isRecurring
        if entry.category != originalEntry.category && entry == categoryOnly && !addingFromSource && unchangedFields &&
            practitionerID == fact.preference.practitionerContactID && reviewed == fact.isReviewed &&
            status == (fact.hasKnownStatus ? fact.clinicalStatus : nil) && actionStatus == fact.actionStatus &&
            reminder == fact.preference.reminderEnabled && (!reminder || reminderDate == fact.preference.dueDate) {
            var corrected = originalEntry
            corrected.category = entry.category
            corrected.updatedAt = Date()
            guard await model.save(corrected) else { return }
            await home.loadSessions()
            dismiss()
            return
        }
        var updated = entry
        for i in updated.fields.indices where updated.fields[i].label.lowercased() == "details" && originalEntry.fields.first(where: { $0.id == updated.fields[i].id })?.value == originalEntry.details {
            updated.fields[i].value = updated.details
        }
        if CareInstructionPresentation.applies(updated) {
            if updated.evidence == nil { updated.evidence = ClinicalEvidence() }
            let previousOrganization = updated.evidence?.careInstruction
            updated.evidence?.careInstruction = CareInstruction(instruction: updated.title, directions: updated.details.nilIfEmpty,
                goal: careGoal.nilIfEmpty, schedule: careSchedule.nilIfEmpty, reviewTiming: careReview.nilIfEmpty, isRecurring: recurring)
            updated.evidence?.careInstruction?.bucket = previousOrganization?.bucket
            updated.evidence?.careInstruction?.owner = previousOrganization?.owner
            updated.evidence?.careInstruction?.consideration = previousOrganization?.consideration

        }
        if dateText != (originalEntry.evidence?.eventDate ?? "") {
            var evidence = updated.evidence ?? ClinicalEvidence()
            evidence.eventDate = dateText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            updated.evidence = evidence
            updated.relevantDate = EvidenceValidation.exactDate(evidence.eventDate)
            updated.dateNeedsReview = evidence.eventDate == nil
        }
        if entry.category != originalEntry.category {
            if entry.title == initialDisplayEntry.title { updated.title = originalEntry.title }
            if entry.details == initialDisplayEntry.details { updated.details = originalEntry.details }
            if entry.fields == initialDisplayEntry.fields { updated.fields = originalEntry.fields }
        }
        if (entry != initialDisplayEntry || !unchangedFields) && updated != originalEntry || addingFromSource {
            // Preserve the shared fact's identity when its title is corrected.
            updated.factKey = updated.factKey ?? HealthMemoryProjection.normalize(originalEntry.title)
            updated.origin = updated.origin == .userAdded ? .userAdded : .userEdited
            updated.updatedAt = Date()
            for index in updated.fields.indices {
                updated.fields[index].isMissing = updated.fields[index].value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                updated.fields[index].needsReview = updated.fields[index].isMissing
            }
            guard await model.save(updated) else { return }
        }
        if addingFromSource {
            var restored = fact.preference
            restored.hidden = false
            guard await model.save(restored) else { return }
        }
        guard let current = model.facts.first(where: { $0.occurrences.contains { $0.id == updated.id } }) else { return }
        var preference = current.preference
        if addingFromSource { preference.hidden = false }
        preference.practitionerContactID = practitionerID
        if status != (fact.hasKnownStatus ? fact.clinicalStatus : nil) { preference.clinicalStatus = status }
        if actionStatus != fact.actionStatus { preference.actionStatus = actionStatus }
        preference.reviewedRevision = reviewed ? current.revision : nil
        guard await model.save(preference) else { return }
        if fact.isAction {
            let enabled = reminder && actionStatus == .current
            if enabled != fact.preference.reminderEnabled || (enabled && reminderDate != fact.preference.dueDate) {
                guard await model.setReminder(for: model.facts.first(where: { $0.id == fact.id }) ?? current,
                                              date: reminderDate, enabled: enabled) else { return }
            }
        }
        await home.loadSessions()
        dismiss()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct RecordDetailDraft: Identifiable {
    let recordID: UUID
    let id: String
    let text: String
    let quote: String?
    let category: SummaryEntryCategory
}

struct HealthManualEntryView: View {
    @ObservedObject var model: HealthSummaryModel
    @ObservedObject var home: HomeViewModel
    let store: SessionStore
    let topicID: UUID?
    var initialCategory: SummaryEntryCategory = .otherNotes
    var recordDraft: RecordDetailDraft?
    @State private var initialized = false
    @State private var saveFailed = false
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var category: SummaryEntryCategory = .otherNotes
    @State private var practitionerID: UUID?
    @State private var choosingPractitioner = false
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Picker("Category", selection: $category) {
                    ForEach(SummaryEntryCategory.allCases, id: \.self) { Text($0.displayTitle).tag($0) }
                }
                TextField("Title", text: $title)
                TextField("What would you like to record?", text: $details, axis: .vertical)
                if category != .practitionerContact {
                    Button { choosingPractitioner = true } label: {
                        LabeledContent("Practitioner", value: model.snapshot.careTeam.first(where: { $0.id == practitionerID })?.name ?? "Choose or add")
                    }
                }
                Text("This will be saved as information added by you. You can add a date and other details afterwards.").foregroundStyle(StoryDesignTokens.secondaryInk)
            }
            .storyListCanvas()
            .sheet(isPresented: $choosingPractitioner) {
                PractitionerPicker(model: model) { practitionerID = $0 }
            }
            .navigationTitle(recordDraft == nil ? "Add health detail" : "Add new detail")
            .onAppear {
                guard !initialized else { return }
                category = recordDraft?.category ?? initialCategory
                details = recordDraft?.text ?? ""
                initialized = true
            }
            .alert("Your detail couldn’t be saved. Please try again.", isPresented: $saveFailed) { Button("OK") {} }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            let id = recordDraft?.recordID ?? UUID()
                            var entry = SummaryEntry(category: category, title: title, details: details,
                                fields: [], relevantDate: nil, dateNeedsReview: true, sourceSessionID: id,
                                provenance: "Added by you", origin: .userAdded, clinicalStatus: .current)
                            var evidence = ClinicalEvidence(); evidence.statusExplicit = true
                            if recordDraft == nil && (category == .carePlan || category == .followUp) { evidence.actionKind = "self_directed" }
                            entry.evidence = evidence
                            do {
                                if let recordDraft {
                                    entry.linkedSummaryBlockKey = recordDraft.id
                                    entry.sourceExcerpt = recordDraft.quote
                                    try await store.saveSummaryEntry(entry)
                                } else {
                                    let session = Session(id: id, transcript: "\(title)\n\(details)", title: title,
                                        summary: "## \(category.displayTitle)\n- \(title): \(details)", summaryEntries: [entry],
                                        inputType: .documentFile, entryIntent: .personalJournal)
                                    var saved = session; saved.extractionVersion = RecordSummaryProcessor.version
                                    try await store.upsert(saved)
                                }
                                await model.refresh()
                                if let fact = model.facts.first(where: { $0.latest.id == entry.id }) {
                                    var preference = fact.preference
                                    if recordDraft == nil || practitionerID != nil { preference.practitionerContactID = practitionerID }
                                    if recordDraft == nil { preference.topicIDs = topicID.map { [$0] } ?? [] }
                                    preference.reviewedRevision = fact.revision
                                    _ = await model.save(preference)
                                }
                                await home.loadSessions(); dismiss()
                            } catch { saveFailed = true }
                            saving = false
                        }
                    }.disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
