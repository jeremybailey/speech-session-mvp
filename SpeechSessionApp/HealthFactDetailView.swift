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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let sourceOnlyEntry, let fact = HealthMemoryProjection.facts(in: HealthMemorySnapshot(
                sessions: [Session(transcript: "", summaryEntries: [sourceOnlyEntry])], preferences: model.snapshot.preferences), verifiedOnly: false).first {
                HealthFactEditor(fact: fact, preferredEntryID: sourceOnlyEntry.id, model: model, home: home, store: store, addingFromSource: true)
            } else if let fact = model.facts.first(where: { $0.id == factID }) {
                HealthFactEditor(fact: fact, preferredEntryID: preferredEntryID, model: model, home: home, store: store)
            } else {
                ContentUnavailableView("Detail unavailable", systemImage: "doc")
                    .toolbar { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct HealthFactEditor: View {
    let fact: HealthFact
    let originalEntry: SummaryEntry
    var addingFromSource: Bool = false
    @ObservedObject var model: HealthSummaryModel
    @ObservedObject var home: HomeViewModel
    let store: SessionStore
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
    @State private var source: Session?
    @State private var remove = false

    init(fact: HealthFact, preferredEntryID: UUID?, model: HealthSummaryModel, home: HomeViewModel, store: SessionStore, addingFromSource: Bool = false) {
        self.addingFromSource = addingFromSource
        self.fact = fact; self.model = model; self.home = home; self.store = store
        let sourceEntry = preferredEntryID.flatMap { id in fact.occurrences.first { $0.id == id } } ?? fact.latest
        self.originalEntry = sourceEntry
        var displayEntry = sourceEntry
        displayEntry.title = HealthStoryText.clean(displayEntry.title)
        displayEntry.details = HealthStoryText.clean(displayEntry.details)
        if CareInstructionPresentation.applies(displayEntry) {
            displayEntry.title = CareInstructionPresentation.instruction(sourceEntry)
            let directions = sourceEntry.evidence?.careInstruction?.directions ?? HealthStoryText.clean(sourceEntry.details)
            displayEntry.details = CareInstructionPresentation.canonical(directions) == CareInstructionPresentation.canonical(displayEntry.title) ? "" : directions
        }
        _careGoal = State(initialValue: sourceEntry.evidence?.careInstruction?.goal ?? "")
        _careSchedule = State(initialValue: sourceEntry.evidence?.careInstruction?.schedule ?? "")
        _careReview = State(initialValue: sourceEntry.evidence?.careInstruction?.reviewTiming ?? "")
        _recurring = State(initialValue: sourceEntry.evidence?.careInstruction?.isRecurring)
        _entry = State(initialValue: displayEntry)
        _dateText = State(initialValue: sourceEntry.evidence?.eventDate ?? "")
        _reviewed = State(initialValue: fact.isReviewed)
        _status = State(initialValue: fact.clinicalStatus)
        _actionStatus = State(initialValue: fact.actionStatus)
        _reminder = State(initialValue: fact.preference.reminderEnabled)
        _reminderDate = State(initialValue: fact.preference.dueDate ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        Form {
            Section(fact.category.displayTitle) {
                TextField(CareInstructionPresentation.applies(entry) ? "Instruction" : "Title", text: $entry.title, axis: .vertical).font(.headline)
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
                    if !HealthStoryText.isInternalField(field.label) && !(field.label.lowercased() == "details" && originalEntry.fields.first(where: { $0.id == field.id })?.value == originalEntry.details) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label).font(.subheadline).foregroundStyle(.secondary)
                        TextField("Not recorded", text: $field.value, axis: .vertical)
                    }
                    }
                }
            }
            if fact.category != .practitionerContact {
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
            Section {
                if fact.needsReview {
                    ForEach(fact.reviewReasons, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }
                Toggle("I have checked this detail", isOn: $reviewed)
            } footer: { Text("You can leave information unknown. Checking a detail does not mean a clinician has verified it.") }
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
                            Button("Open \(record.title ?? "original record")") { source = record }
                                .frame(minHeight: 44)
                            Text("Added \(record.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            }
            Section {
                Button("Remove from summary", role: .destructive) { remove = true }
            } footer: { Text("Removing a detail keeps your original records.") }
        }
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
        .sheet(item: $source) { record in
            NavigationStack {
                SessionDetailView(session: record, store: store, home: home, initialTab: .source)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { source = nil } } }
            }
        }
        .confirmationDialog("Remove this detail from the summary?", isPresented: $remove, titleVisibility: .visible) {
            Button("Remove detail", role: .destructive) {
                Task { await model.removeFromSummary(fact); if model.error == nil { dismiss() } }
            }
        } message: { Text("The original records and history will be kept.") }
        .alert("Could not save", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func careField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Not recorded", text: text, axis: .vertical).accessibilityLabel(label)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var updated = entry
        for i in updated.fields.indices where updated.fields[i].label.lowercased() == "details" && originalEntry.fields.first(where: { $0.id == updated.fields[i].id })?.value == originalEntry.details {
            updated.fields[i].value = updated.details
        }
        if CareInstructionPresentation.applies(updated) {
            if updated.evidence == nil { updated.evidence = ClinicalEvidence() }
            updated.evidence?.careInstruction = CareInstruction(instruction: updated.title, directions: updated.details.nilIfEmpty,
                goal: careGoal.nilIfEmpty, schedule: careSchedule.nilIfEmpty, reviewTiming: careReview.nilIfEmpty, isRecurring: recurring)
        }
        if dateText != (originalEntry.evidence?.eventDate ?? "") {
            var evidence = updated.evidence ?? ClinicalEvidence()
            evidence.eventDate = dateText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            updated.evidence = evidence
            updated.relevantDate = EvidenceValidation.exactDate(evidence.eventDate)
            updated.dateNeedsReview = evidence.eventDate == nil
        }
        if updated != originalEntry || addingFromSource {
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
        guard let current = model.facts.first(where: { $0.id == fact.id }) else { return }
        var preference = current.preference
        if addingFromSource { preference.hidden = false }
        preference.clinicalStatus = status
        preference.actionStatus = actionStatus
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

struct HealthManualEntryView: View {
    @ObservedObject var model: HealthSummaryModel
    @ObservedObject var home: HomeViewModel
    let store: SessionStore
    let topicID: UUID?
    var initialCategory: SummaryEntryCategory = .otherNotes
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var category: SummaryEntryCategory = .otherNotes
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Picker("Category", selection: $category) {
                    ForEach(SummaryEntryCategory.allCases, id: \.self) { Text($0.displayTitle).tag($0) }
                }
                TextField("Title", text: $title)
                TextField("What would you like to record?", text: $details, axis: .vertical)
                Text("This will be saved as information added by you. You can add a date and other details afterwards.").foregroundStyle(.secondary)
            }
            .navigationTitle("Add health detail")
            .onAppear { category = initialCategory }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            let id = UUID()
                            var entry = SummaryEntry(category: category, title: title, details: details,
                                fields: [], relevantDate: nil, dateNeedsReview: true, sourceSessionID: id,
                                provenance: "Added by you", origin: .userAdded, clinicalStatus: .current)
                            var evidence = ClinicalEvidence(); evidence.statusExplicit = true
                            if category == .carePlan || category == .followUp { evidence.actionKind = "self_directed" }
                            entry.evidence = evidence
                            let session = Session(id: id, transcript: "\(title)\n\(details)", title: title,
                                summary: "## \(category.displayTitle)\n- \(title): \(details)", summaryEntries: [entry],
                                inputType: .documentFile, entryIntent: .personalJournal)
                            do {
                                var saved = session; saved.extractionVersion = RecordSummaryProcessor.version
                                try await store.upsert(saved)
                                await model.refresh()
                                if let fact = model.facts.first(where: { $0.latest.id == entry.id }) {
                                    var preference = fact.preference
                                    preference.topicIDs = topicID.map { [$0] } ?? []
                                    preference.reviewedRevision = fact.revision
                                    _ = await model.save(preference)
                                }
                                await home.loadSessions(); dismiss()
                            } catch { model.error = "Your detail could not be saved. Please try again." }
                            saving = false
                        }
                    }.disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
