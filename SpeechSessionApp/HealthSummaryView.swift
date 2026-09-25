import SwiftUI
import SpeechSessionFeatures
import SpeechSessionPersistence

/// One home list. Categories expand in place; sheets are reserved for a specific task.
struct HealthSummaryView: View {
    @ObservedObject var model: HealthSummaryModel
    @ObservedObject var home: HomeViewModel
    let store: SessionStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var auth: KindeAuthManager
    @AppStorage("speechSession.summaryBackend") private var backend = "openai"
    @AppStorage("speechSession.openaiAPIKey") private var apiKey = ""
    @AppStorage("collectivecare.cloudSummaryConsent") private var cloudConsent = false
    @State private var allExpanded = false
    @State private var expandedConditions = Set<String>()
    @State private var expanded: Set<String> = []
    #if DEBUG
    @State private var didOpenCareQA = false
    #endif
    @State private var recordsExpanded = false
    @State private var pendingDeletion: Session?
    @State private var taskSheet: HealthSheet?
    @State private var showProcessingConsent = false
    @State private var regenerateAll = false
    @State private var resumeAfterConsent = false
    @State private var attemptedRepair: Set<String> = []
    @State private var preparationTask: Task<Void, Never>?
    @State private var isLaunchingPreparation = false

    private var pendingCount: Int {
        model.snapshot.sessions.filter(\.needsSummaryVerification).count
    }
    // A linked contact appears once, even if it was mentioned in several records.
    private var unlinkedFacts: [HealthFact] {
        let linked = Set(model.snapshot.careTeam.flatMap(\.sourceEntryIDs))
        return model.facts.filter { fact in
            fact.category != .practitionerContact || !fact.occurrences.contains { linked.contains($0.id) }
        }
    }

    var body: some View {
        let categoryFacts = Dictionary(grouping: unlinkedFacts, by: \.category)
        let categories = SummaryEntryCategory.allCases
        ScrollViewReader { proxy in
        List {
            if model.snapshot.sessions.isEmpty && model.snapshot.careTeam.isEmpty {
                Section {
                    Text("Your health, in one place").font(.headline)
                    Text("Add a recording or document, or choose a category below to add a detail yourself.")
                        .foregroundStyle(.secondary)
                }
            }
            if model.undoCombination != nil {
                Section { Button("Undo combination", systemImage: "arrow.uturn.backward") { Task { await model.undoCombine() } } }
            }
            if model.undoRemoval != nil {
                Section { Button("Undo removal", systemImage: "arrow.uturn.backward") { Task { await model.restoreRemovedDetail() } } }
            }
            if model.isProcessing || isLaunchingPreparation {
                Section {
                    HStack { ProgressView(); Text(model.progress.isEmpty ? "Starting summary…" : model.progress) }
                    Button("Stop preparing summary") { preparationTask?.cancel() }
                }
            } else if let issue = model.processingIssue {
                Section {
                    SummaryProcessingIssueView(issue: issue, retry: { prepare(retryUnfinished: true) })
                    if let id = issue.recordID, let record = model.snapshot.sessions.first(where: { $0.id == id }) {
                        Button("Open original record", systemImage: "doc.text") { taskSheet = .record(record) }
                    }
                }
            } else if pendingCount > 0 {
                Section {
                    Button("Update summary from records", systemImage: "arrow.clockwise") {
                        if backend == "onDevice" || cloudConsent { prepare() }
                        else { showProcessingConsent = true }
                    }
                }
            }
            if let overview = model.overview {
                Section("Overview") {
                    Text(overview).textSelection(.enabled)
                }
            } else if !model.facts.isEmpty && !model.isProcessing {
                Section("Overview") {
                    Text(model.overviewNotice ?? "Your health details are ready. Create a readable introduction to your health story.")
                        .foregroundStyle(.secondary)
                    if let explanation = model.overviewCheckerExplanation {
                        DisclosureGroup("Why it stopped") {
                            Text("Automatic checker feedback — this may itself be mistaken.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: explanation).textSelection(.enabled)
                        }
                    }
                    Button("Create overview", systemImage: "text.bubble") {
                        guard !isLaunchingPreparation else { return }
                        overviewOnlyRequest = true
                        prepare()
                    }
                }
            }
            conditionSections
            if !categories.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $allExpanded) {
                    ForEach(categories, id: \.self) { category in
                        let facts = categoryFacts[category] ?? []
                        let members = category == .practitionerContact ? model.snapshot.careTeam : []
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded.contains(category.rawValue) },
                            set: { if $0 { expanded.insert(category.rawValue) } else { expanded.remove(category.rawValue) } }
                        )) {
                            ForEach(facts) { fact in factRow(fact) }
                            ForEach(members) { member in
                                contactRow(member)
                            }
                            if facts.isEmpty && members.isEmpty {
                                Text("No details yet").foregroundStyle(.secondary)
                            }
                            Button(category == .practitionerContact ? "Add contact" : "Add detail", systemImage: "plus") {
                                taskSheet = category == .practitionerContact ? .contact(.init()) : .add(category)
                            }.frame(minHeight: 44)
                        } label: {
                            categoryLabel(category.displayTitle, count: facts.count + members.count)
                        }.id(category.rawValue)
                    }
                    } label: {
                        Label("All", systemImage: "square.grid.2x2.fill")
                            .font(.headline).foregroundStyle(.primary).padding(.vertical, 8)
                    }
                }
            }
            Section {
                DisclosureGroup(isExpanded: $recordsExpanded) {
                    if model.snapshot.sessions.isEmpty {
                        Text("No records added yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.snapshot.sessions.sorted { $0.date > $1.date }) { session in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 8) {
                                Text(session.displayTitle).font(.headline).foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                                Menu {
                                    Button("Open original", systemImage: "doc.text") { taskSheet = .record(session) }
                                    Button("Delete record", role: .destructive) { pendingDeletion = session }
                                } label: { RecordActionsIcon() }.accessibilityLabel("Actions for \(session.displayTitle)")
                            }
                            RecordFieldLine(label: "Added", value: session.date.formatted(date: .abbreviated, time: .omitted), secondary: true)
                            if session.processingError != nil { RecordStatusTag(text: "Needs another try", review: true).padding(.top, 4) }
                        }.padding(.vertical, 8)
                        .background {
                            Button { taskSheet = .record(session) } label: {
                                Color.clear.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Open \(session.displayTitle)")
                                .accessibilityHint("Opens the original and its text")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", role: .destructive) { pendingDeletion = session }
                        }
                    }
                } label: {
                    categoryLabel("Original records", count: model.snapshot.sessions.count)
                }
            } header: {
                Text("Sources for your health story")
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Regenerate summary", systemImage: "arrow.clockwise") {
                        regenerateAll = true
                        if backend == "onDevice" || cloudConsent { prepare() }
                        else { showProcessingConsent = true }
                    }.disabled(model.isProcessing || model.snapshot.sessions.isEmpty)
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Health story actions")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Share", systemImage: "square.and.arrow.up") { taskSheet = .share }
                    .labelStyle(.iconOnly)
                    .disabled(model.facts.isEmpty)
            }
        }
        .task(id: home.revision) {
            await model.refresh()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--condition-qa") {
                expandedConditions = ["migraine|"]
            }
            if ProcessInfo.processInfo.arguments.contains("--summary-error-qa") {
                model.showProcessingFailureForQA()
                return
            }
            #endif
            let repairKey = model.snapshot.sessions.map { $0.id.uuidString + SummaryVerification.hash($0.transcript) }.sorted().joined()
            if model.processingIssue == nil, pendingCount > 0, backend == "onDevice" || cloudConsent, attemptedRepair.insert(repairKey).inserted { prepare() }
            #if DEBUG
            if !didOpenCareQA, ProcessInfo.processInfo.arguments.contains("--care-qa"),
               let fact = model.facts.first(where: { $0.category == .carePlan }) {
                didOpenCareQA = true
                expanded.insert(SummaryEntryCategory.carePlan.rawValue)
                if ProcessInfo.processInfo.arguments.contains("--info-qa") {
                    expanded = Set(SummaryEntryCategory.allCases.map(\.rawValue))
                    if ProcessInfo.processInfo.arguments.contains("--info-qa-contact") {
                        try? await Task.sleep(for: .milliseconds(150))
                        proxy.scrollTo(SummaryEntryCategory.practitionerContact.rawValue, anchor: .top)
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--care-qa-editor") { taskSheet = .fact(fact.id) }
                if ProcessInfo.processInfo.arguments.contains("--care-qa-combine") { taskSheet = .combine(fact.id) }
                if ProcessInfo.processInfo.arguments.contains("--care-qa-pdf") { taskSheet = .share }
                if ProcessInfo.processInfo.arguments.contains("--verification-qa-record"), let session = model.snapshot.sessions.first { taskSheet = .record(session) }
            }
            #endif
        }
        .sheet(item: $taskSheet) { sheet in
            switch sheet {
            case .fact(let id):
                NavigationStack { HealthFactDetailView(factID: id, model: model, home: home, store: store) }
            case .record(let session):
                NavigationStack {
                    SessionDetailView(session: session, store: store, home: home, initialTab: ProcessInfo.processInfo.arguments.contains("--verification-qa-record") ? .summary : .source)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { taskSheet = nil } } }
                }
            case .add(let category):
                HealthManualEntryView(model: model, home: home, store: store, topicID: nil, initialCategory: category)
            case .contact(let member): CareTeamEditor(member: member, model: model)
            case .share: HealthShareView(model: model)
            case .condition(let id): ConditionAssignmentSheet(factID: id, model: model)
            case .combine(let id): FactDuplicateSheet(factID: id, model: model)
            case .combineContact(let id): ContactDuplicateSheet(memberID: id, model: model)
            }
        }
        .confirmationDialog("Delete this record and its original files?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Delete record", role: .destructive) {
                guard let session = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await home.delete(session: session); await model.refresh() }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { Text("This removes the original file and the summary details created from it.") }
        .confirmationDialog("Prepare your summary", isPresented: $showProcessingConsent, titleVisibility: .visible) {
            Button("Use cloud processing") { cloudConsent = true; prepare() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Text from your records will be sent through CollectiveCare’s service to OpenAI to prepare summaries. Original files stay on this iPhone. You can change processing options in Settings.")
        }
        }
    }

    @ViewBuilder private var conditionSections: some View {
        let conditions = ConditionSummaryProjection.groups(facts: model.facts, topics: model.snapshot.topics)
        if conditions.isEmpty {
            Section { Text("Add records to start organizing your health story by condition.").foregroundStyle(.secondary) }
        }
        Section {
        ForEach(conditions.filter { !$0.isUncategorized }) { condition in
            let visible = condition.facts
            if !visible.isEmpty {
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedConditions.contains(condition.id) },
                        set: { if $0 { expandedConditions.insert(condition.id) } else { expandedConditions.remove(condition.id) } }
                    )) {
                        // Recommendations lead; category headings are inline, not another navigation level.
                        let order: [SummaryEntryCategory] = [.carePlan, .followUp, .symptoms, .findings, .medications,
                            .testsAndLabs, .vaccinations, .allergies, .biopsychosocialContext, .practitionerContact, .otherNotes]
                        ForEach(order, id: \.self) { category in
                            let rows = visible.filter { $0.category == category || (category == .symptoms && $0.category == .chiefComplaint) }
                            if !rows.isEmpty {
                                DisclosureGroup {
                                if category == .symptoms {
                                    // Same concern gets one heading, with individual mentions available beneath it.
                                    let names = Dictionary(grouping: rows, by: { ConditionSummaryProjection.normalized($0.title) })
                                    ForEach(names.keys.sorted(), id: \.self) { name in
                                        let mentions = names[name] ?? []
                                        if mentions.count > 1 {
                                            DisclosureGroup("\(name.capitalized) · \(mentions.count) source details") {
                                                ForEach(mentions) { fact in conditionFactRow(fact) }
                                            }
                                        } else {
                                            ForEach(mentions) { fact in conditionFactRow(fact) }
                                        }
                                    }
                                } else {
                                    ForEach(rows) { fact in conditionFactRow(fact) }
                                }
                                } label: {
                                    categoryLabel(category.displayTitle, count: rows.count)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: bodySystemIcon(condition.bodySystem))
                                .font(.title2).foregroundStyle(.blue)
                                .frame(width: 40, height: 40)
                                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(condition.name).font(.headline).foregroundStyle(.primary)
                            Text("\(visible.count) \(visible.count == 1 ? "detail" : "details")").font(.caption).foregroundStyle(.secondary)
                        }
                        }.padding(.vertical, 2)
                    }
            }
        }
        }

    }

    private func bodySystemIcon(_ system: String) -> String {
        let value = system.lowercased()
        let symbols: [(String, String)] = [
            ("neuro", "brain.head.profile"), ("mental", "brain.head.profile"),
            ("eye", "eye"), ("ophthalm", "eye"), ("vision", "eye"),
            ("card", "heart.fill"), ("circul", "heart.fill"),
            ("resp", "lungs.fill"), ("pulmon", "lungs.fill"),
            ("musculo", "figure.walk"), ("orthop", "figure.walk"),
            ("endocr", "waveform.path.ecg"), ("hormon", "waveform.path.ecg"),
            ("repro", "figure.and.child.holdinghands"), ("pregnan", "figure.and.child.holdinghands"),
            ("digest", "stomach"), ("gastro", "stomach"),
            ("ear", "ear"), ("audit", "ear"), ("immun", "shield"),
            ("skin", "hand.raised"), ("dermat", "hand.raised")
        ]
        return symbols.first { value.contains($0.0) }?.1 ?? "figure.stand"
    }

    private func conditionFactRow(_ fact: HealthFact) -> some View {
        let status = ConditionSummaryProjection.status(of: fact)
        let statusTitle = status == .unknown ? "Status unknown" : (status == .current ? "Current" : "Not current")
        return VStack(alignment: .leading, spacing: 6) {
            HealthFactRow(fact: fact, actions: AnyView(factActions(fact)), open: { open(fact) },
                          statusOverride: statusTitle, showBodySystem: false)
            if fact.isAction {
                if fact.latest.evidence?.practitioner?.isEmpty != false {
                    Text("Provider not recorded").font(.caption).foregroundStyle(.secondary)
                }
                if fact.latest.evidence?.eventDate?.isEmpty != false && fact.latest.relevantDate == nil {
                    Text("Clinical date not recorded").font(.caption).foregroundStyle(.secondary)
                }

            }
        }.padding(.vertical, 8)
    }

    private func factRow(_ fact: HealthFact) -> some View {
        HealthFactRow(fact: fact, actions: AnyView(factActions(fact)), open: { open(fact) })
            .padding(.vertical, 8)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.removeFromSummary(fact) } }
            }
    }

    private func factActions(_ fact: HealthFact) -> some View {
            Menu {
                Button("Edit", systemImage: "pencil") { open(fact) }
                Button("Assign condition", systemImage: "tag") { taskSheet = .condition(fact.id) }
                if !fact.isReviewed {
                    Button("Mark as verified", systemImage: "checkmark.seal") {
                        Task {
                            guard let current = model.facts.first(where: { $0.id == fact.id }) else { return }
                            var preference = current.preference
                            preference.reviewedRevision = current.revision
                            _ = await model.save(preference)
                        }
                    }
                }
                Button("Combine duplicate", systemImage: "rectangle.on.rectangle") { taskSheet = .combine(fact.id) }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.removeFromSummary(fact) } }
            } label: { RecordActionsIcon() }
            .accessibilityLabel("Actions for \(HealthStoryText.clean(fact.title))")
    }

    private func open(_ fact: HealthFact) {
        taskSheet = fact.category == .practitionerContact ? .contact(contact(from: fact)) : .fact(fact.id)
    }

    @ViewBuilder
    private func categoryLabel(_ title: String, count: Int) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    SummaryCategoryIcon(title: title).accessibilityHidden(true)
                    Text("\(count) \(count == 1 ? "detail" : "details")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 6)
        } else {
            HStack(spacing: 12) {
                SummaryCategoryIcon(title: title).accessibilityHidden(true)
                Text(title).font(.headline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Spacer(minLength: 4)
                Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel("\(count) details")
            }.frame(minHeight: 48)
        }
    }

    private func contact(from fact: HealthFact) -> CareTeamMember {
        func field(_ labels: [String]) -> String {
            fact.latest.fields.first { field in labels.contains { field.label.localizedCaseInsensitiveContains($0) } }?.value ?? ""
        }
        return CareTeamMember(name: field(["name"]).isEmpty ? fact.title : field(["name"]),
            role: field(["role", "specialty"]), organization: field(["organization", "clinic"]),
            email: field(["email"]), phone: field(["phone"]), address: field(["address"]), sourceEntryIDs: fact.occurrences.map(\.id))
    }

    private func contactRow(_ member: CareTeamMember) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(member.name).font(.headline).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                Menu {
                    Button("Edit", systemImage: "pencil") { taskSheet = .contact(member) }
                    Button("Combine duplicate", systemImage: "rectangle.on.rectangle") { taskSheet = .combineContact(member.id) }
                    if let url = CareTeamMail.url(email: member.email) { Link("Email", destination: url) }
                    if let url = RecordFieldLine.link(label: "Phone", value: member.phone) { Link("Call", destination: url) }
                } label: { RecordActionsIcon() }.accessibilityLabel("Actions for \(member.name)")
            }
            if !member.role.isEmpty { RecordFieldLine(label: "Role", value: member.role) }
            if !member.organization.isEmpty { RecordFieldLine(label: "Clinic", value: member.organization) }
            if !member.phone.isEmpty { RecordFieldLine(label: "Phone", value: member.phone) }
            if !member.email.isEmpty { RecordFieldLine(label: "Email", value: member.email) }
            if let address = member.address, !address.isEmpty { RecordFieldLine(label: "Address", value: address) }
        }.padding(.vertical, 8)
            .background {
                Button { taskSheet = .contact(member) } label: {
                    Color.clear.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("Edit \(member.name)")
            }
    }

    @State private var overviewOnlyRequest = false

    private func prepare(retryUnfinished: Bool = false) {
        guard !isLaunchingPreparation && !model.isProcessing else { return }
        let resume = retryUnfinished || resumeAfterConsent
        if backend != "onDevice" && !cloudConsent {
            resumeAfterConsent = resume
            showProcessingConsent = true
            return
        }
        resumeAfterConsent = false
        let overviewOnly = overviewOnlyRequest
        overviewOnlyRequest = false
        let forceAll = regenerateAll
        regenerateAll = false
        isLaunchingPreparation = true
        preparationTask = Task {
            defer { isLaunchingPreparation = false; preparationTask = nil }
            let transport = backend == "onDevice" ? nil : await auth.openAIChatTransport(byokFallback: apiKey)
            if overviewOnly {
                await model.createOverview(transport: transport, onDevice: backend == "onDevice")
            } else {
                await model.prepareSummaries(transport: transport, onDevice: backend == "onDevice", forceAll: forceAll, retryUnfinished: resume)
                await home.loadSessions()
            }
        }
    }
}

private enum HealthSheet: Identifiable {
    case condition(String), fact(String), record(Session), add(SummaryEntryCategory), contact(CareTeamMember), combine(String), combineContact(UUID), share
    var id: String {
        switch self {
        case .condition(let id): "condition-\(id)"
        case .fact(let id): "fact-\(id)"
        case .record(let session): "record-\(session.id)"
        case .add(let category): "add-\(category.rawValue)"
        case .contact(let member): "contact-\(member.id)"
        case .share: "share"
        case .combine(let id): "combine-\(id)"
        case .combineContact(let id): "combine-contact-\(id)"
        }
    }
}

/// Shared hierarchy: primary information, fields, provenance, then compact status metadata.
struct HealthFactRow: View {
    let fact: HealthFact
    var actions: AnyView? = nil
    var open: (() -> Void)? = nil
    var statusOverride: String? = nil
    var showBodySystem = true
    private var isCare: Bool { CareInstructionPresentation.applies(fact.latest) }
    private var title: String {
        if fact.category == .practitionerContact { return PractitionerContactsFormatting.namesOnly(fact.title) ?? HealthStoryText.clean(fact.title) }
        return isCare ? CareInstructionPresentation.instruction(fact.latest) : HealthStoryText.clean(fact.title)
    }
    private var fields: [SummaryEntryField] {
        HealthDetailPresentation.fields(fact.displayEntry).filter {
            showBodySystem || !["body system", "bodysystem", "body area"].contains($0.label.lowercased())
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: actions == nil ? 0 : 44, alignment: .topLeading)
                if let actions { actions }
            }
            if isCare {
                if !fact.isAction { RecordFieldLine(label: "Type", value: "Treatment received") }
                ForEach(CareInstructionPresentation.supportingText(fact.latest), id: \.self) { line in
                    RecordFieldLine(text: line)
                }
                if fact.latest.evidence?.actionKind == "self_directed" {
                    Text("Personal activity · discuss with your care team").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                ForEach(HealthDetailPresentation.remainingDetails(fact.displayEntry), id: \.self) { RecordFieldLine(text: $0) }
                ForEach(fields) { field in RecordFieldLine(label: field.label, value: field.value) }
            }
            if showBodySystem, let body = fact.latest.evidence?.bodySystem ?? fact.latest.fields.first(where: { $0.label.lowercased().contains("body system") })?.value,
               !body.isEmpty, !fields.contains(where: { $0.value == body }) { RecordFieldLine(label: "Body area", value: body, secondary: true) }
            if let practitioner = fact.latest.evidence?.practitioner, !practitioner.isEmpty,
               !fields.contains(where: { $0.value == practitioner }) {
                RecordFieldLine(label: "Practitioner", value: practitioner, secondary: true)
            }
            if let date = fact.latest.evidence?.eventDate, !fields.contains(where: { $0.value == date }) { RecordFieldLine(label: "Date", value: date, secondary: true) }
            if fact.occurrences.count > 1 {
                RecordFieldLine(label: "Sources", value: "\(fact.occurrences.count) entries", secondary: true)
            }
            if let due = fact.preference.dueDate, fact.isAction, fact.actionStatus == .current {
                RecordFieldLine(label: "Reminder", value: due.formatted(date: .abbreviated, time: .shortened))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { statusTags }
                VStack(alignment: .leading, spacing: 4) { statusTags }
            }.padding(.top, 4)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                if let open {
                    Button(action: open) { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit \(title)")
                        .accessibilityHint("Opens this detail and its sources")
                }
            }
    }
    @ViewBuilder private var statusTags: some View {
        if fact.category != .practitionerContact {
            RecordStatusTag(text: statusOverride ?? CareInstructionPresentation.status(fact))
        }
        if fact.isReviewed { RecordStatusTag(text: "Verified") }
        else {
            RecordStatusTag(text: "Unverified", review: true)
                .accessibilityHint("Not yet checked by you. " + (isCare ? CareInstructionPresentation.reviewIndicator(fact) ?? "Open to review the original source." : fact.reviewReasons.joined(separator: " ")))
        }
    }
}

private struct RecordActionsIcon: View {
    var body: some View {
        Image(systemName: "ellipsis").font(.body.weight(.semibold))
            .frame(width: 44, height: 44, alignment: .top).contentShape(Rectangle())
    }
}

private struct RecordStatusTag: View {
    let text: String
    var review = false
    @Environment(\.colorScheme) private var colorScheme
    private var tint: Color {
        switch text {
        case "Verified", "Completed": return colorScheme == .dark ? .green : Color(red: 0.10, green: 0.39, blue: 0.20)
        case "Unverified", "Paused": return colorScheme == .dark ? .orange : Color(red: 0.58, green: 0.28, blue: 0.02)
        case "Needs another try": return .red
        case "Current": return .blue
        default: return .secondary
        }
    }
    var body: some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(review ? text : "Status: " + text)
    }
}

private struct RecordFieldLine: View {
    @Environment(\.openURL) private var openURL
    let label: String
    let value: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var secondary = false
    init(label: String, value: String, secondary: Bool = false) {
        self.label = label; self.value = value.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression); self.secondary = secondary
    }
    init(text: String) {
        if let colon = text.firstIndex(of: ":"),
           ["phone", "tel", "email", "address", "clinic", "organization", "role", "specialty", "dose", "frequency", "when", "goal", "review", "duration", "reason", "practitioner", "date", "notes"].contains(String(text[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)) {
            label = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else { label = ""; value = text }
    }
    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"[;|]\s*(?=(?i:phone|email|address|clinic|organization|role|specialty|dose|frequency|notes):)"#, with: "\n", options: .regularExpression)
            .components(separatedBy: .newlines)
    }
    static func link(label: String, value: String) -> URL? {
        if label.lowercased().contains("email") { return CareTeamMail.url(email: value) }
        return ContactActionURL.make(label: label, value: value)
    }

    var body: some View {
        Group {
            if let url = Self.link(label: label, value: value) {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                layout {
                    Text(label + ":").fontWeight(.semibold).foregroundStyle(.primary)
                    Button { openURL(url) } label: {
                        Text(value)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.borderless)
                    .accessibilityHint(label.lowercased().contains("address") ? "Open in Apple Maps" : "Open contact action")
                }
            } else {
                (Text(label.isEmpty ? "" : label + ": ").fontWeight(.semibold) + Text(value))
                    .foregroundStyle(secondary ? .secondary : .primary)
            }
        }.font(.subheadline).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A focused task sheet; no additional navigation hierarchy in the health story.
private struct FactDuplicateSheet: View {
    let factID: String
    @ObservedObject var model: HealthSummaryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                if let root = model.facts.first(where: { $0.id == factID }) {
                    Section("Keep this detail") { HealthFactRow(fact: root) }
                    let candidates = model.facts.filter { $0.id != root.id && $0.category == root.category && $0.isAction == root.isAction }
                    Section("Choose the duplicate") {
                        if candidates.isEmpty { Text("No other details to combine.") }
                        ForEach(candidates) { candidate in
                            Button { selectedID = candidate.id } label: {
                                HStack(alignment: .top) {
                                    HealthFactRow(fact: candidate)
                                    if selectedID == candidate.id { Image(systemName: "checkmark") }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    if let selected = candidates.first(where: { $0.id == selectedID }) {
                        Section("After combining") {
                            Text(CareInstructionPresentation.applies(root.latest) ? CareInstructionPresentation.instruction(root.latest) : HealthStoryText.clean(root.title)).font(.headline)
                            Text("One detail, with \(root.occurrences.count + selected.occurrences.count) source entries. The detail above and its settings are kept. Both originals remain available. Verification must be checked again.")
                            Text("Only combine if these details mean the same thing, including location, dose, timing, and any conditions.")
                            Button("Combine duplicate") {
                                saving = true
                                Task { model.error = nil; await model.combine(root, with: selected); saving = false; if model.error == nil { dismiss() } }
                            }.disabled(saving)
                        }
                    }
                }
            }
            .navigationTitle("Combine duplicate")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Could not combine", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}

private struct ContactDuplicateSheet: View {
    let memberID: UUID
    @ObservedObject var model: HealthSummaryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                if let root = model.snapshot.careTeam.first(where: { $0.id == memberID }) {
                    Section("Keep this contact") { contact(root) }
                    Section("Choose the duplicate") {
                        let candidates = model.snapshot.careTeam.filter { $0.id != memberID }
                        if candidates.isEmpty { Text("No other contacts to combine.") }
                        ForEach(candidates) { candidate in
                            Button { selectedID = candidate.id } label: {
                                HStack {
                                    contact(candidate)
                                    if selectedID == candidate.id { Image(systemName: "checkmark") }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    if let other = model.snapshot.careTeam.first(where: { $0.id == selectedID }) {
                        Section("After combining") {
                            Text("One contact named \(root.name), keeping the contact information and links to both sets of sources. You can undo this combination.")
                            Button("Combine duplicate") {
                                saving = true
                                Task {
                                    model.error = nil
                                    await model.combineContact(root, with: other)
                                    saving = false
                                    if model.error == nil { dismiss() }
                                }
                            }.disabled(saving)
                        }
                    }
                }
            }
            .navigationTitle("Combine duplicate")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Could not combine", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }

    private func contact(_ member: CareTeamMember) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(member.name).font(.headline)
            if !member.organization.isEmpty { Text(member.organization) }
            if !member.email.isEmpty { Text(member.email) }
            if !member.phone.isEmpty { Text(member.phone) }
            if let address = member.address, !address.isEmpty { Text(address) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// The failure remains readable after processing stops; recovery does not require dismissing an alert.
struct SummaryProcessingIssueView: View {
    let issue: SummaryProcessingIssue
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(issue.title, systemImage: "exclamationmark.circle").font(.headline)
            Text(issue.message).font(.subheadline).textSelection(.enabled)
            Button("Retry unfinished work", systemImage: "arrow.clockwise", action: retry)
                .frame(minHeight: 44)
        }.padding(.vertical, 4)
    }
}

/// Patient correction of condition links; uses existing topic preferences, never folders or source edits.
private struct ConditionAssignmentSheet: View {
    let factID: String
    @ObservedObject var model: HealthSummaryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var newName = ""
    @State private var saving = false
    @State private var error: String?
    private var conditions: [ConditionSummary] {
        ConditionSummaryProjection.groups(facts: model.facts, topics: model.snapshot.topics).filter { !$0.isUncategorized }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose only conditions this detail relates to. Leaving all choices off keeps it Uncategorized.")
                    ForEach(conditions) { condition in
                        Toggle(condition.name, isOn: Binding(get: { selected.contains(condition.id) }, set: {
                            if $0 { selected.insert(condition.id) } else { selected.remove(condition.id) }
                        }))
                    }
                    TextField("Another condition or concern", text: $newName)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Assign condition")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                }
            }
            .task { selected = Set(conditions.filter { $0.facts.contains { $0.id == factID } }.map(\.id)) }
        }
    }
    private func save() async {
        guard let fact = model.facts.first(where: { $0.id == factID }) else { return }
        saving = true
        defer { saving = false }
        var links: [UUID] = []
        var choices = conditions.filter { selected.contains($0.id) }.map { ($0.name, $0.bodySystem) }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { choices.append((name, "")) }
        for (name, system) in choices {
            let topic = model.snapshot.topics.first {
                ConditionSummaryProjection.normalized($0.name) == ConditionSummaryProjection.normalized(name) &&
                ConditionSummaryProjection.normalized($0.bodySystem) == ConditionSummaryProjection.normalized(system)
            } ?? HealthTopic(name: name, bodySystem: system)
            guard await model.save(topic) else { error = "The condition could not be saved. Please try again."; return }
            links.append(topic.id)
        }
        var preference = fact.preference
        preference.topicIDs = Array(Set(links))
        if await model.save(preference) { dismiss() }
        else { error = "The condition link could not be saved. Please try again." }
    }
}
