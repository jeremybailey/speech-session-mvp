import SwiftUI
import QuickLook
import QuickLookThumbnailing
import NaturalLanguage
import SpeechSessionFeatures
import SpeechSessionPersistence
import SpeechSessionTranscription

private struct RecordTagLayout: Layout {

    private func arrange(_ subviews: Subviews, width: CGFloat,
                         place: (LayoutSubview, CGPoint, CGSize) -> Void) -> CGSize {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for tag in subviews {
            let ideal = tag.sizeThatFits(.unspecified)
            let size = ideal.width > width
                ? tag.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + 2
                rowHeight = 0
            }
            place(tag, CGPoint(x: x, y: y), size)
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width
        }
        return CGSize(width: width.isFinite ? width : usedWidth, height: y + rowHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity) { _, _, _ in }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        _ = arrange(subviews, width: bounds.width) { tag, offset, size in
            tag.place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                      anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}

struct SessionDetailView: View {
    let initialSession: Session
    let store: SessionStore
    @ObservedObject var home: HomeViewModel
    @EnvironmentObject private var health: HealthSummaryModel
    @EnvironmentObject private var auth: KindeAuthManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("speechSession.transcriptionBackend") private var transcriptionBackend = TranscriptionBackend.onDeviceWhisperKit.rawValue
    @AppStorage("speechSession.whisperKitModel") private var whisperModel = DeviceCapabilityProfile.tinyWhisperKitModel
    @AppStorage("speechSession.openaiAPIKey") private var apiKey = ""
    @AppStorage("speechSession.summaryBackend") private var summaryBackend = "openai"
    @AppStorage("collectivecare.cloudSummaryConsent") private var cloudSummaryConsent = false
    @State private var summaryConsent = false
    @State private var resumeAfterConsent = false
    @State private var summaryTask: Task<Void, Never>?
    private var directory: URL { store.storageDirectory }
    @State private var shareableURL: URL?
    @State private var transcriptionConsent = false
    @ObservedObject private var captureWorker = CaptureProcessing.shared
    @State private var retrying = false
    @State private var confirmDelete = false
    @State private var localError: String?
    @State private var selectedTab: DetailTab
    @State private var retrySummary = false
    @State private var regeneratingRecord = false
    @State private var didRegenerateSummary = false
    @State private var summaryCopied = false
    @State private var expandedTagGroups: Set<String> = []
    @State private var lastRemoval: Set<String>?
    @State private var failedDetailChange: (Set<String>, Bool)?
    @State private var expandedCategories: Set<SummaryEntryCategory> = []
    @Environment(\.askAboutRecord) private var askAboutRecord
    @Environment(\.storyRouter) private var storyRouter
    @State private var routedExcerpt: String?
    @State private var pickingFolders = false
    @State private var openingRecordFacts: (id: UUID, facts: [HealthFact])?
    @State private var newDetail: RecordDetailDraft?
    @State private var editingFact: RecordFactSelection?
    @State private var edit: RecordEdit?
    @State private var previewOriginal = false
    @State private var previewAsset: URL?
    private enum RecordEdit: String, Identifiable {
        case title, text, time, team
        var id: Self { self }
    }
    private enum NoteFocus: Hashable { case title, block(Int) }
    @FocusState private var noteFocus: NoteFocus?
    @State private var editingNote = false
    @State private var savingNote = false
    @State private var requestedTemplate: RecordTemplateSelection?
    @State private var draftTitle = ""
    @State private var originalTitle = ""
    @State private var baselineEdits: [String: String] = [:]
    @State private var rawDrawer = false
    @State private var draftBlocks: [NoteBlock] = []
    @State private var canvasCache = RecordCanvasCache()
    private var storyLab: Bool { Bundle.main.bundleIdentifier == "com.CollectiveCare.pilot" }
    let sourceHighlightExcerpt: String?

    init(session: Session, store: SessionStore, home: HomeViewModel, initialTab: DetailTab = .transcript, sourceHighlightExcerpt: String? = nil) {
        self.initialSession = session; self.store = store; self.home = home
        self.sourceHighlightExcerpt = sourceHighlightExcerpt
        _selectedTab = State(initialValue: initialTab)
    }

    private var session: Session {
        health.snapshot.sessions.first { $0.id == initialSession.id } ?? home.sessions.first { $0.id == initialSession.id } ?? initialSession
    }
    private var recordFacts: [HealthFact] {
        let id = initialSession.id
        return health.facts.compactMap { $0.presentedFromRecord(id) }
    }
    var body: some View {
        VStack(spacing: 0) {
            if storyLab && selectedTab == .transcript {
                noteCanvas.disabled(savingNote)
            } else if storyLab && selectedTab == .summary {
                recordSummary
            } else {
            Picker("Record view", selection: $selectedTab) {

                Text(session.inputType == .audio ? "Transcript" : "Extracted text").tag(DetailTab.transcript)
                Text("Details").tag(DetailTab.summary)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()
            switch selectedTab {
            case .summary: recordSummary
            case .source:
                SessionSourceView(session: session, storageDirectory: directory,
                                      highlightedExcerpt: routedExcerpt ?? sourceHighlightExcerpt, shareableFileURL: $shareableURL)

            case .transcript:
                ScrollView {
                    let pages = RecordTextPage.sections(in: session.transcript)
                    LazyVStack(alignment: .leading, spacing: 24) {
                        Button("Edit text", systemImage: "pencil") { edit = .text }
                        if pages.isEmpty && session.capture?.pending == true { Text(session.capture?.notes ?? "").textSelection(.enabled) }
                        ForEach(Array(pages.indices), id: \.self) { index in
                            let page = pages[index]
                            VStack(alignment: .leading, spacing: 8) {
                                if let title = page.title {
                                    StorySectionHeading(title: title)
                                }
                                if !page.body.isEmpty {
                                    Text(verbatim: readableText(page.body))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        if let assets = session.sourceAssets, !assets.isEmpty {
                            StorySectionHeading(title: "Attachments")
                            ForEach(assets) { asset in
                                Button {
                                    previewAsset = SessionSourceStore(storageDirectory: directory).url(for: asset, sessionID: session.id)
                                } label: {
                                    Label(asset.displayName, systemImage: asset.kind == .audio ? "waveform" : asset.kind == .image ? "photo" : "doc")
                                }.frame(minHeight: 44)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
        }
            if !(storyLab && selectedTab == .transcript) && !editingNote && captureWorker.active.contains(session.id) {
                StoryThinkingStatus("Preparing summary…")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editingNote { EmptyView() }
            else if session.recordSummaryWork != nil && !preparingCaptureSummary && session.capture?.pending != true {
                Button("Retry unfinished summary") { regenerate(retryUnfinished: true) }.padding(8)
            } else if let capture = session.capture {
                if preparingCaptureSummary { EmptyView() }
                else if !capture.failedAssets.isEmpty || captureWorker.errors[session.id] != nil || capture.pending || capture.needsRecordSummary == true {
                    VStack(spacing: 8) {
                        if let reason = captureWorker.errors[session.id] {
                            Text(reason)
                                .font(StoryDesignTokens.caption)
                                .foregroundStyle(StoryDesignTokens.secondaryInk)
                                .multilineTextAlignment(.center)
                        }
                        Button("Retry unfinished processing") {
                            if capture.pending || !capture.failedAssets.isEmpty || captureWorker.errors[session.id] != nil { processCapture() }
                            else { regenerate(retryUnfinished: true) }
                        }
                    }.padding(8)
                }
            } else if retrying {
                HStack { ProgressView(); Text("Reading your original…") }.padding().background(.regularMaterial)
            } else if session.processingError != nil || session.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.processingError ?? "Your original is saved. Its text is not ready yet.")
                        .font(StoryDesignTokens.font(.subheadline))
                    Button("Read original again") { requestTranscription() }
                        .buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity).padding().background(.regularMaterial)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if storyLab && !editingNote && selectedTab == .transcript, let askAboutRecord {
                Button { askAboutRecord(session) } label: {
                    Label("Ask anything", systemImage: "bubble.left")
                        .font(StoryDesignTokens.label)
                        .frame(maxWidth: .infinity, minHeight: StoryDesignTokens.controlHeight)
                }
                .buttonBorderShape(.capsule)
                .storyControlStyle()
                .padding(.horizontal)
                .padding(.vertical, 6)
                .accessibilityHint("Ask about this record")
            }
        }
        .background {
            if storyLab && selectedTab == .transcript {
                StoryDesignTokens.canvas.ignoresSafeArea()
            }
        }
        .navigationTitle(storyLab && selectedTab == .summary ? "Details" : "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editingNote || (storyLab && selectedTab == .summary))
        .toolbar {
            if storyLab && selectedTab == .summary {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back to record", systemImage: "chevron.backward") { selectedTab = .transcript }
                }
            } else if savingNote {
                ToolbarItem(placement: .confirmationAction) {
                    ProgressView().accessibilityLabel("Saving record")
                }
            } else if editingNote {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { endNoteEdit() }.disabled(savingNote)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save edits", systemImage: "checkmark") { saveNote() }
                        .disabled(savingNote || draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
            ToolbarItem(placement: .topBarTrailing) {
                if let shareableURL {
                    ShareLink(item: shareableURL) { Label("Share original", systemImage: "square.and.arrow.up") }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if storyLab {
                        Button("Copy summary", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = copyableSummary
                            summaryCopied = true
                            UIAccessibility.post(notification: .announcement, argument: "Summary copied")
                        }
                        .disabled(copyableSummary.isEmpty)
                        Button("Edit record", systemImage: "pencil") { selectedTab = .transcript; beginNoteEdit(.title) }
                        Button("View extracted data", systemImage: "doc.text.magnifyingglass") { rawDrawer = true }
                        Button("View details", systemImage: "list.bullet") {
                            selectedTab = .summary
                        }
                        Divider()
                    }
                    if !storyLab {
                    Button("Regenerate summary", systemImage: "arrow.clockwise") {
                        if summaryBackend == "onDevice" || cloudSummaryConsent { regenerate() }
                        else { summaryConsent = true }
                    }.disabled(regeneratingRecord || (!storyLab && health.isProcessing) || session.transcript.isEmpty)
                    }
                    if health.isProcessing { Button("Cancel regeneration") { summaryTask?.cancel() } }
                    Divider()
                    Button("Delete record", systemImage: "trash", role: .destructive) { confirmDelete = true }.disabled(retrying)
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Record actions")
            }
            }
        }
        .confirmationDialog("Check your summary using cloud processing?", isPresented: $summaryConsent, titleVisibility: .visible) {
            Button("Use cloud processing") { cloudSummaryConsent = true; regenerate() }
            Button("Cancel", role: .cancel) { requestedTemplate = nil }
        } message: { Text("Text from this record will be sent through CollectiveCare’s service to OpenAI for summarization and verification. Temporary processing content has a seven-day expiry and cleanup policy; usage metadata is retained separately.") }
        .storyLoadIn()
        .task(id: initialSession.id) {
            if storyLab && !health.snapshot.sessions.contains(where: { $0.id == initialSession.id }),
               let snapshot = try? await store.healthSnapshot(recordID: initialSession.id),
               snapshot.sessions.contains(where: { $0.id == initialSession.id }) {
                let facts = await Task.detached(priority: .userInitiated) { HealthMemoryProjection.facts(in: snapshot) }.value
                guard !Task.isCancelled else { return }
                openingRecordFacts = (initialSession.id, facts)
            }
            await health.loadForNavigation()
            guard !Task.isCancelled else { return }
            if session.capture?.pending == true ||
                ((session.capture?.needsRecordSummary == true || (session.capture != nil && session.needsSummaryVerification && health.shouldAutomaticallyUpdate(onDevice: summaryBackend == "onDevice", consent: cloudSummaryConsent))) &&
                 (cloudSummaryConsent || summaryBackend == "onDevice") && !health.isExplicitlyPaused && captureWorker.errors[session.id] == nil) {
                processCapture()
            }
        }
        .onChange(of: session.capture?.pending) { old, new in
            if old == true, new == false, !session.transcript.isEmpty,
               summaryBackend != "onDevice", !cloudSummaryConsent, auth.isSignedIn {
                summaryConsent = true
            }
        }
        .onAppear {
            if selectedTab == .source { selectedTab = .transcript; previewOriginal = true }
            if let target = storyRouter?.captureExcerpt, target.id == session.id {
                previewOriginal = true
                routedExcerpt = target.quote
                storyRouter?.captureExcerpt = nil
            }
            if storyRouter?.requestedOriginal == session.id {
                selectedTab = .transcript
                previewOriginal = true
                storyRouter?.requestedOriginal = nil
            }
        }
        .quickLookPreview($previewAsset)
        .sheet(isPresented: $previewOriginal) {
            NavigationStack {
                SessionSourceView(session: session, storageDirectory: directory, highlightedExcerpt: routedExcerpt ?? sourceHighlightExcerpt, shareableFileURL: $shareableURL)
                    .storyLoadIn().navigationTitle("Source").toolbar { Button("Close") { previewOriginal = false } }
            }
        }
        .sheet(isPresented: $rawDrawer) {
            RawRecordSheet(record: session, directory: directory, store: store) {
                await home.loadSessions()
                await health.refresh()
                if !health.isProcessing && session.capture?.pending != true { regenerate() }
            }
        }
        .sheet(item: $edit) { kind in
            RecordAttributeEditor(kind: kind.rawValue, record: session, store: store, health: health) { textChanged in
                await home.loadSessions()
                await health.refresh()
                if textChanged && !health.isProcessing && session.capture?.pending != true { regenerate() }
            }
        }
        .sheet(isPresented: $pickingFolders) { RecordFolderPicker(recordID: session.id, store: store) }
        .sheet(item: $newDetail) { draft in
            HealthManualEntryView(model: health, home: home, store: store, topicID: nil, recordDraft: draft)
        }
        .sheet(item: $editingFact) { selection in
            NavigationStack {
                if selection.removalKeys != nil && !health.snapshotReadFailed && !health.snapshot.sessions.contains(where: { $0.id == initialSession.id }) && !health.hasLoaded && openingRecordFacts?.id == initialSession.id && openingRecordFacts?.facts.isEmpty == false {
                    ProgressView("Opening detail…")
                } else {
                    HealthFactDetailView(factID: selection.factID, preferredEntryID: selection.entryID, sourceOnlyEntry: selection.sourceOnlyEntry,
                                         model: health, home: home, store: store, removeFromRecord: selection.removalKeys.map { keys in
                                             { try await changeVisibility(keys, hide: true) }
                                         })
                }
            }
        }
        .confirmationDialog("Transcribe this audio", isPresented: $transcriptionConsent, titleVisibility: .visible) {
            Button("Use cloud transcription") { Task { await retrySource() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The saved audio will be sent through CollectiveCare’s service to OpenAI for transcription.") }
        .confirmationDialog("Delete this record and its original files?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete record", role: .destructive) {
                Task {
                    await home.delete(session: session)
                    if home.errorMessage == nil { await health.refresh(); dismiss() }
                }
            }
        } message: { Text("This removes the recording or document and the summary details created from it.") }
        .overlay(alignment: .top) {
            if summaryCopied {
                Label("Summary copied", systemImage: "checkmark")
                    .font(.callout)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .task(id: summaryCopied) {
            guard summaryCopied else { return }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
            summaryCopied = false
        }
        .alert("Record processing", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            if let (keys, hide) = failedDetailChange {
                Button("Retry") { performVisibilityChange(keys, hide: hide) }
            }
            if retrySummary { Button("Retry summary") { regenerate(retryUnfinished: true) } }
            Button("OK") { localError = nil; failedDetailChange = nil; retrySummary = false }
        } message: { Text(localError ?? "") }
    }

    private func blocks() -> [NoteBlock] {
        let edits = session.summaryParagraphEdits ?? [:]
        var result: [NoteBlock] = []
        if let bullets = session.recordBullets {
            let visit = session.appliedRecordTemplate == .visit
            let ordered = visit ? RecordVisitSection.allCases.flatMap { section in bullets.filter { $0.resolvedVisitSection == section } } : bullets
            for bullet in ordered {
                let key = bullet.editKey
                guard !result.contains(where: { $0.key == key }) else { continue }
                let text = edits[key] ?? (session.entryIntent == .personalJournal ? bullet.text : RecordBullet.patientCenteredText(bullet.text))
                let plainJournal = session.entryIntent == .personalJournal && bullet.bulletID != nil &&
                    bullets.allSatisfy { $0.heading == bullet.heading } && session.transcript.count <= 1200
                result.append(NoteBlock(key: key, initial: text, text: text, heading: visit ? bullet.resolvedVisitSection.rawValue : (plainJournal ? nil : bullet.heading), bullet: bullet))
            }
            for key in edits.keys.sorted() where !result.contains(where: { $0.key == key }) {
                if let text = edits[key], !text.isEmpty {
                    result.append(NoteBlock(key: key, initial: text, text: text, heading: "Your edits"))
                }
            }
            return result
        }
        let grouped = Dictionary(grouping: recordFacts.filter { $0.displayEntry.linkedSummaryBlockKey == nil }, by: \.category)
        for fact in SummaryEntryCategory.allCases.flatMap({ grouped[$0] ?? [] }) {
            let entry = fact.displayEntry
            var generated = entry.title
            if !entry.details.isEmpty && entry.details != generated {
                generated += (generated.isEmpty ? "" : "\n") + entry.details
            }
            for field in entry.fields where !field.isMissing && !field.needsReview {
                let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !generated.localizedCaseInsensitiveContains(value),
                      field.label.caseInsensitiveCompare(BodySystem.fieldLabel) != .orderedSame else { continue }
                generated += "\n" + field.label + ": " + value
            }
            let text = edits[fact.id] ?? (entry.origin == .generated ? RecordBullet.patientCenteredText(generated) : generated)
            result.append(NoteBlock(key: fact.id, initial: text, text: text, fact: fact))
        }
        // Keep patient writing even when an underlying detail is later retired.
        let keys = Set(result.map(\.key))
        for key in edits.keys.sorted() where !keys.contains(key) {
            let text = edits[key] ?? ""
            result.append(NoteBlock(key: key, initial: text, text: text))
        }
        if result.isEmpty {
            let text = session.summary ?? ""
            result.append(NoteBlock(key: "note", initial: text, text: text))
        }
        return result
    }

    /// Copy the saved text in the same order and with the same edits as the canvas.
    private var copyableSummary: String {
        let content = blocks().filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !content.isEmpty else { return "" }
        var lines = [session.displayTitle]
        var previousHeading: String?
        for block in content {
            let heading = block.heading ?? block.fact?.category.displayTitle
            if let heading, heading != previousHeading {
                lines += ["", heading]
            }
            if heading == nil && previousHeading == nil && lines.count == 1 { lines.append("") }
            lines.append(block.key == "note" ? block.text : "• " + block.text)
            previousHeading = heading
        }
        return lines.joined(separator: "\n")
    }

    private func beginNoteEdit(_ focus: NoteFocus) {
        if !editingNote {
            originalTitle = session.displayTitle; draftTitle = originalTitle
            baselineEdits = session.summaryParagraphEdits ?? [:]; draftBlocks = blocks()
            editingNote = true
        }
        noteFocus = focus
    }

    private func endNoteEdit() { noteFocus = nil; editingNote = false; draftBlocks = [] }

    private func saveNote() {
        guard !savingNote else { return }
        savingNote = true
        noteFocus = nil
        let changes = Dictionary(uniqueKeysWithValues: draftBlocks.filter { $0.text != $0.initial }.map { ($0.key, $0.text) })
        let title = originalTitle == draftTitle ? nil : draftTitle
        Task {
          defer { savingNote = false }
          do {
            try await store.saveRecordSummary(session.id, changes: changes, baseline: baselineEdits, title: title)
            await home.loadSessions(); await health.refresh(); endNoteEdit()
        } catch StoryEditError.staleRevision {
            localError = "More text arrived while you were editing. Your edits are still here. Copy them before cancelling to view the updated note."
        } catch { localError = error.localizedDescription }
        }
    }

    private var preparingCaptureSummary: Bool {
        regeneratingRecord || captureWorker.active.contains(session.id) ||
            (session.capture?.pending == true && captureWorker.errors[session.id] == nil)
    }

    private var templateControls: some View {
        let selection = session.recordSummaryWork?.selection ?? session.recordTemplateSelection ?? .auto
        let resolved = session.recordSummaryWork == nil ? session.appliedRecordTemplate : nil
        return Menu {
            Picker("Summary template", selection: Binding(get: { selection }, set: { option in
                requestedTemplate = option
                regenerate()
            })) {
                ForEach(RecordTemplateSelection.allCases, id: \.self) { option in
                    Label(option.menuTitle, systemImage: option.menuIcon).tag(option)
                }
            }
            .pickerStyle(.inline)
            Divider()
            if session.recordSummaryWork != nil {
                Button("Retry unfinished summary", systemImage: "arrow.clockwise") { regenerate(retryUnfinished: true) }
            } else {
                Button("Regenerate summary", systemImage: "arrow.clockwise") { regenerate() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selection.menuIcon)
                Text(selection.menuTitle)
            }
            .fixedSize().frame(minHeight: 44)
        }
        .font(StoryDesignTokens.font(.subheadline))
        .foregroundStyle(StoryDesignTokens.secondaryInk)
        .accessibilityLabel("Summary template, " + selection.menuTitle)
        .accessibilityValue(selection == .auto ? (resolved ?? selection.resolved(for: session)).menuTitle : "")
        .disabled(preparingCaptureSummary || session.transcript.isEmpty)
    }

    private var noteCanvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    if savingNote { Text(verbatim: draftTitle) }
                    else if editingNote {
                        TextField("Untitled record", text: $draftTitle, axis: .vertical)
                            .focused($noteFocus, equals: .title).accessibilityLabel("Record title")
                    } else {
                        Button { beginNoteEdit(.title) } label: { Text(verbatim: session.displayTitle) }
                            .accessibilityHint("Edit record title")
                    }
                }.font(StoryDesignTokens.pageTitle).foregroundStyle(StoryDesignTokens.ink)
                    .multilineTextAlignment(.leading)
                noteMetadata.disabled(editingNote)
                let projection = cachedCanvas()
                let content = editingNote ? draftBlocks : projection.blocks
                let loadedTags = projection.tags
                let tags = loadedTags ?? []
                let links = content.map { projection.links[$0.key] ?? [] }
                let linked = Set(links.flatMap { $0.map(\.id) })
                if let keys = lastRemoval {
                    Button("Detail removed · Undo") { performVisibilityChange(keys, hide: false) }
                }
                if captureWorker.extractingDetails.contains(session.id) {
                    StoryThinkingStatus("Extracting details…")
                } else if preparingCaptureSummary {
                    StoryThinkingStatus(content.allSatisfy({ $0.text.isEmpty }) ? "Preparing summary…" : "Updating summary…")
                } else if session.recordSummaryWork != nil {
                    Label("Summary paused — retry to continue", systemImage: "pause.circle")
                        .font(StoryDesignTokens.caption)
                } else if didRegenerateSummary {
                    Label("Summary updated", systemImage: "checkmark.circle")
                        .font(StoryDesignTokens.caption)
                }
                if preparingCaptureSummary && !editingNote && content.allSatisfy({ $0.text.isEmpty }) {
                    StoryLoadingPlaceholder(label: "Preparing summary", rows: 2, layout: .summary)
                        .accessibilityHidden(true) // The processing status above announces this work.
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(content.enumerated()), id: \.element.key) { i, block in
                            if let heading = block.heading ?? block.fact?.category.displayTitle,
                               i == 0 || (content[i - 1].heading ?? content[i - 1].fact?.category.displayTitle) != heading {
                                Text(heading)
                                    .font(StoryDesignTokens.sectionHeading)
                                    .foregroundStyle(StoryDesignTokens.ink)
                                    .accessibilityAddTraits(.isHeader)
                                    .padding(.top, i == 0 ? 0 : 24)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if !block.text.isEmpty {
                                    bulletMarker(block, tags: links[i], detailsLoaded: loadedTags != nil && !preparingCaptureSummary && session.recordSummaryWork == nil, detailsPending: captureWorker.active.contains(session.id) || regeneratingRecord)
                                        .alignmentGuide(.firstTextBaseline) { dimensions in
                                            dimensions[VerticalAlignment.center] + bodyHalfCapHeight
                                        }
                                        .disabled(editingNote || savingNote)
                                }
                                if savingNote { Text(verbatim: block.text) }
                                else if editingNote {
                                    TextField("Write a summary…", text: Binding(get: {
                                        draftBlocks.indices.contains(i) ? draftBlocks[i].text : ""
                                    }, set: { if draftBlocks.indices.contains(i) { draftBlocks[i].text = $0 } }), axis: .vertical)
                                        .focused($noteFocus, equals: .block(i)).accessibilityLabel("Note paragraph \(i + 1)")
                                } else {
                                    Button { beginNoteEdit(.block(i)) } label: {
                                        Text(verbatim: block.text.isEmpty ? "Write a summary…" : block.text)
                                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.accessibilityHint("Edit record text")
                                }
                            }.font(StoryDesignTokens.body)
                                .lineSpacing(4).padding(.top, 10)
                        }
                    }
                }
                let remaining = tags.filter { !linked.contains($0.id) }
                if !remaining.isEmpty {
                    StorySectionHeading(title: content.contains { $0.bullet?.bulletID != nil } ? "Other extracted details" : "Extracted details")
                    detailTags(remaining, group: "unlinked")
                }
                if let assets = session.sourceAssets, !assets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Attachments").font(StoryDesignTokens.caption).foregroundStyle(StoryDesignTokens.secondaryInk)
                            .accessibilityAddTraits(.isHeader)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 8) {
                                ForEach(assets) { asset in
                                    let url = SessionSourceStore(storageDirectory: directory).url(for: asset, sessionID: session.id)
                                    Button {
                                        noteFocus = nil
                                        previewAsset = url
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            RawAssetThumbnail(url: url, kind: asset.kind,
                                                              size: CGSize(width: 88, height: 70))
                                            if asset.kind != .image {
                                                Text(asset.displayName).font(StoryDesignTokens.font(.caption)).lineLimit(2)
                                                    .frame(width: 88, alignment: .leading)
                                            }
                                        }
                                    }.accessibilityLabel("Open " + asset.displayName)
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }.padding(.top, 6)
                }
            }.buttonStyle(.plain).textFieldStyle(.plain).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.scrollDismissesKeyboard(.interactively)
    }

    private var noteMetadata: some View {
        RecordMetadataRow(session: session, health: health, editTime: { edit = .time },
                          editTeam: { edit = .team }, editConditions: { pickingFolders = true },
                          dateOnly: true) {
            if !editingNote { templateControls }
        }
    }

    // Older records have no timestamps. Break long prose at sentence boundaries
    // for display, keeping existing document lines and the saved evidence intact.
    private func readableText(_ text: String) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        return text.components(separatedBy: "\n").map { line in
            let longLine = line.count > 240
            let doubleSpace = #/[ \u{00A0}]{2,}/#
            guard longLine || line.contains(doubleSpace) else { return line }
            tokenizer.string = line
            var paragraphs: [String] = []
            var start = line.startIndex
            var previousEnd = start
            tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                let sentence = line[range].drop(while: { $0.isWhitespace })
                let gap = line[previousEnd..<sentence.startIndex]
                if previousEnd > start,
                   gap.wholeMatch(of: doubleSpace) != nil ||
                    (longLine && line.distance(from: start, to: previousEnd) >= 200) {
                    paragraphs.append(String(line[start..<previousEnd]))
                    start = sentence.startIndex
                }
                previousEnd = sentence.lastIndex(where: { !$0.isWhitespace })
                    .map { line.index(after: $0) } ?? range.upperBound
                return true
            }
            guard !paragraphs.isEmpty else { return line }
            paragraphs.append(String(line[start...]))
            return paragraphs.joined(separator: "\n\n")
        }.joined(separator: "\n")
    }

    private var recordSummary: some View {
        let grouped = Dictionary(grouping: recordFacts, by: \.category)
        let categories = SummaryEntryCategory.allCases.filter { grouped[$0]?.isEmpty == false }
        return List {
            if health.isProcessing { StoryThinkingStatus(health.progress).frame(maxWidth:.infinity,alignment:.leading) }
            if !health.isProcessing, let issue = health.processingIssue {
                SummaryProcessingIssueView(issue: issue, retry: { regenerate(retryUnfinished: true) })
            }
            if let error = health.error { Text(error).foregroundStyle(StoryDesignTokens.secondaryInk) }
            let excluded = (session.summaryEntries ?? []).filter { !$0.isDeleted && !SummaryVerification.isVisible($0, source: session.transcript) }
            if !excluded.isEmpty {
                DisclosureGroup("Details kept in original (\(excluded.count))") {
                    Text(health.isProcessing ? "These are results from the previous check. They will update when processing finishes." : "These details have not passed source checking. They are not included in your health story or shared summary.").font(StoryDesignTokens.font(.subheadline))
                    ForEach(excluded) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.title).font(StoryDesignTokens.font(.headline, weight: .semibold))
                            Text(SummaryVerification.exclusionReason(entry, source: session.transcript)).font(StoryDesignTokens.font(.caption)).foregroundStyle(StoryDesignTokens.secondaryInk)
                            Button("Edit and add to health story") {
                                openFact(RecordFactSelection(factID: HealthMemoryProjection.key(for: entry), entryID: entry.id, sourceOnlyEntry: entry))
                            }
                        }
                    }
                }
            }
            if categories.isEmpty {
                ContentUnavailableView("No health details yet", systemImage: "heart.text.square",
                    description: Text("This record has no summary details to show."))
            }
            ForEach(categories, id: \.self) { category in
                let facts = grouped[category] ?? []
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedCategories.contains(category) },
                    set: { if $0 { expandedCategories.insert(category) } else { expandedCategories.remove(category) } }
                )) {
                    ForEach(facts) { fact in
                        HealthFactRow(fact: fact, open: {
                            openFact(RecordFactSelection(factID: fact.id, entryID: fact.latest.id))
                        })
                        .padding(.vertical, 8)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SummaryCategoryIcon(title: category.displayTitle).accessibilityHidden(true)
                        Text(category.displayTitle).font(StoryDesignTokens.font(.headline, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(facts.count.formatted()).foregroundStyle(StoryDesignTokens.secondaryInk)
                            .accessibilityLabel("\(facts.count) details")
                    }.frame(minHeight: 48)
                }
            }
        }
        .storyListCanvas().listStyle(.insetGrouped)
    }

    private struct RecordTag: Identifiable {
        let factID: String
        let entry: SummaryEntry
        let heading: String
        var id: UUID { entry.id }
    }

    private var recordTags: [RecordTag]? {
        let recordID = session.id
        var seen = Set<UUID>()
        let available: [HealthFact]
        if health.snapshot.sessions.contains(where: { $0.id == recordID }) {
            available = recordFacts
        } else if let openingRecordFacts, openingRecordFacts.id == recordID {
            available = openingRecordFacts.facts
        } else {
            return nil
        }
        return available.flatMap { fact in
            fact.occurrences.compactMap { entry -> RecordTag? in
                guard entry.sourceSessionID == recordID, seen.insert(entry.id).inserted else { return nil }
                return RecordTag(factID: fact.id, entry: entry, heading: entry.recordDetailHeading)
            }
        }
    }

    // Text normalization, detail headings and evidence matching are content work,
    // not layout work. Scrolling/focus/progress must not repeat the full matching pass.
    private final class RecordCanvasCache {
        var session: Session?
        var factsRevision: UInt64 = .max
        var hasOpeningFacts = false
        var blocks: [NoteBlock] = []
        var tags: [RecordTag]?
        var links: [String: [RecordTag]] = [:]
    }

    private func cachedCanvas() -> RecordCanvasCache {
        let current = session
        let opening = openingRecordFacts?.id == current.id
        guard canvasCache.session != current || canvasCache.factsRevision != health.factsRevision || canvasCache.hasOpeningFacts != opening else { return canvasCache }
        let content = blocks()
        let tags = recordTags
        var links: [String: [RecordTag]] = [:]
        for block in content {
            links[block.key] = (tags ?? []).filter { tag in
                if let key = tag.entry.linkedSummaryBlockKey { return key == block.key }
                if block.fact?.id == tag.factID { return true }
                guard let bullet = block.bullet else { return false }
                if bullet.heading == SummaryEntryCategory.medications.displayTitle && tag.entry.category != .medications { return false }
                return bullet.detailEntryIDs?.contains(tag.entry.id) == true || bullet.supports(tag.entry)
            }
        }
        canvasCache.session = current
        canvasCache.factsRevision = health.factsRevision
        canvasCache.hasOpeningFacts = opening
        canvasCache.blocks = content
        canvasCache.tags = tags
        canvasCache.links = links
        return canvasCache
    }

    @ScaledMetric(relativeTo: .body) private var bodyHalfCapHeight = StoryDesignTokens.readingFont(size: StoryDesignTokens.bodyBaseSize).capHeight / 2
    @ScaledMetric(relativeTo: .footnote) private var detailIconDiameter: CGFloat = 26

    private func markerIcon(_ symbol: String, fill: Color = StoryDesignTokens.softSurface) -> some View {
        Image(systemName: symbol)
            .font(StoryDesignTokens.font(.footnote, weight: .medium))
            .foregroundStyle(StoryDesignTokens.action)
            .frame(width: detailIconDiameter, height: detailIconDiameter)
            .background(fill, in: Circle())
            .contentShape(Rectangle())
    }

    @ViewBuilder private func bulletMarker(_ block: NoteBlock, tags: [RecordTag], detailsLoaded: Bool, detailsPending: Bool) -> some View {
        if let first = tags.first {
            let icon = markerIcon(SummaryCategoryIcon(title: first.entry.category.displayTitle).icon)
            if tags.count == 1 {
                Button { openTag(first) } label: { icon }
                    .accessibilityLabel(first.entry.category.displayTitle + ", " + first.entry.title)
                    .contextMenu {
                        Button("Remove from this record", role: .destructive) {
                            performVisibilityChange(Session.removalKeys(first.entry), hide: true)
                        }
                    }
            } else {
                Menu {
                    ForEach(tags) { tag in
                        Button(tag.entry.title, systemImage: SummaryCategoryIcon(title: tag.entry.category.displayTitle).icon) { openTag(tag) }
                    }
                } label: { icon }
                .accessibilityLabel("Choose from " + String(tags.count) + " linked details")
            }
        } else if detailsPending {
            ProgressView()
                .controlSize(.small)
                .tint(StoryDesignTokens.secondaryInk)
                .frame(width: detailIconDiameter, height: detailIconDiameter)
                .accessibilityLabel("Extracting details")
        } else if detailsLoaded {
            Button {
                let category = SummaryEntryCategory.allCases.first { $0.displayTitle == block.bullet?.heading } ?? block.fact?.category ?? .otherNotes
                newDetail = RecordDetailDraft(recordID: session.id, id: block.key, text: block.text, quote: block.bullet?.quote, category: category)
            } label: { markerIcon("plus", fill: .clear) }
            .accessibilityLabel("Add new detail")
        } else {
            Color.clear.frame(width: detailIconDiameter, height: detailIconDiameter)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    @ViewBuilder private func detailTags(_ tags: [RecordTag], group: String) -> some View {
        let expanded = expandedTagGroups.contains(group)
        let groups = Dictionary(grouping: tags) { tag in
            tag.entry.category.rawValue + "|" + tag.heading.lowercased()
        }
        let ordered = tags.compactMap { tag -> [RecordTag]? in
            let key = tag.entry.category.rawValue + "|" + tag.heading.lowercased()
            guard let group = groups[key], group.first?.id == tag.id else { return nil }
            return group
        }
        RecordTagLayout() {
            ForEach(Array(ordered.prefix(expanded ? ordered.count : 3)), id: \.first!.id) { group in
                let tag = group[0]
                let label = markerIcon(SummaryCategoryIcon(title: tag.entry.category.displayTitle).icon)
                    .padding(3)
                if group.count == 1 {
                    Button { openTag(tag) } label: { label }
                        .accessibilityLabel(tag.entry.category.displayTitle + ", " + tag.entry.title)
                        .disabled(editingNote)
                        .contextMenu {
                            Button("Remove from this record", role: .destructive) {
                                performVisibilityChange(Session.removalKeys(tag.entry), hide: true)
                            }
                        }
                } else {
                    Menu {
                        ForEach(group) { member in
                            Button(member.entry.details.isEmpty ? member.entry.title : member.entry.details) { openTag(member) }
                        }
                    } label: { label }
                    .disabled(editingNote)
                    .accessibilityLabel(tag.heading + ", " + String(group.count) + " details")
                }
            }
        }
        if ordered.count > 3 {
            Button(expanded ? "Show fewer" : "Show \(ordered.count - 3) more") {
                if expanded { expandedTagGroups.remove(group) } else { expandedTagGroups.insert(group) }
            }
        }
    }

    private func openTag(_ tag: RecordTag) {
        editingFact = RecordFactSelection(factID: tag.factID, entryID: tag.id, removalKeys: Session.removalKeys(tag.entry))
    }

    private func changeVisibility(_ keys: Set<String>, hide: Bool) async throws {
        try await store.changeRecordDetailVisibility(session.id, keys: keys, hide: hide)
        lastRemoval = hide ? keys : nil
        failedDetailChange = nil
        await health.refresh()
    }

    private func performVisibilityChange(_ keys: Set<String>, hide: Bool) {
        Task {
            do { try await changeVisibility(keys, hide: hide) }
            catch {
                failedDetailChange = (keys, hide)
                localError = error.localizedDescription
            }
        }
    }

    private func openFact(_ selection: RecordFactSelection) {
        if let storyRouter { storyRouter.open(.fact(selection.factID, selection.entryID, selection.sourceOnlyEntry)) }
        else { editingFact = selection }
    }

    private func regenerate(retryUnfinished: Bool = false) {
        let resume = retryUnfinished || resumeAfterConsent
        if summaryBackend != "onDevice" && !cloudSummaryConsent {
            resumeAfterConsent = resume
            summaryConsent = true
            return
        }
        guard !regeneratingRecord else { return }
        retrySummary = false
        didRegenerateSummary = false
        regeneratingRecord = true
        resumeAfterConsent = false
        let selection = requestedTemplate
        requestedTemplate = nil
        summaryTask = Task {
            defer { if !storyLab { regeneratingRecord = false } }
            let transport = summaryBackend == "onDevice" ? nil : await auth.openAIChatTransport(byokFallback: apiKey)
            if storyLab {
                do {
                    try await RecordBulletWriter.run(session, store: store, transport: transport, local: summaryBackend == "onDevice", force: !resume, selection: selection, retryRequested: resume)
                    await home.loadSessions()
                    await health.refresh()
                    regeneratingRecord = false
                    didRegenerateSummary = true
                } catch StoryEditError.staleRevision {
                    regeneratingRecord = false
                    await home.loadSessions(); await health.refresh()
                    localError = "The record changed during processing. Your writing is saved. Retry to summarize the latest version."
                    return
                } catch {
                    regeneratingRecord = false
                    let reason = (error as NSError).userInfo["workflowReason"] as? String
                    retrySummary = !["expired", "cancelled", "superseded", "workflow_limit", "budget_exhausted"].contains(reason ?? "")
                    localError = error.localizedDescription
                    await home.loadSessions(); await health.loadForNavigation()
                    return
                }
            }
            await health.prepareSummaries(transport: transport, onDevice: summaryBackend == "onDevice", forceSessionID: session.id, retryUnfinished: resume)
            await home.loadSessions()
        }
    }

    private func processCapture() {
        captureWorker.start(session, store: store, home: home, health: health, auth: auth)
    }

    private func requestTranscription() {
        if session.inputType == .audio && transcriptionBackend == TranscriptionBackend.openAIWhisper.rawValue {
            transcriptionConsent = true
        } else { Task { await retrySource() } }
    }
    private func retrySource() async {
        guard !retrying else { return }
        retrying = true
        defer { retrying = false }
        do {
            let source = SessionSourceStore(storageDirectory: directory)
            let assets = session.sourceAssets ?? []
            guard !assets.isEmpty else { throw SummaryProcessingError.unavailable("This older record has no saved original file.") }
            let text: String
            if session.inputType == .audio {
                let url = source.url(for: assets[0], sessionID: session.id)
                switch TranscriptionBackend(rawValue: transcriptionBackend) ?? .onDeviceApple {
                case .onDeviceApple: text = try await AudioFileTranscriptionService.transcribeWithAppleSpeech(fileURL: url)
                case .onDeviceWhisperKit: text = try await AudioFileTranscriptionService.transcribeWithWhisperKit(fileURL: url, modelName: whisperModel)
                case .openAIWhisper:
                    guard let credentials = await auth.openAIWhisperCredentials(byokKey: apiKey) else { throw SummaryProcessingError.unavailable("Sign in in Settings to transcribe with OpenAI.") }
                    text = try await AudioFileTranscriptionService.transcribeWithOpenAIWhisper(fileURL: url, credentials: credentials)
                }
            } else if assets[0].kind == .pdf || assets[0].kind == .plainText {
                text = try await DocumentFileExtractService().extractText(from: source.url(for: assets[0], sessionID: session.id))
            } else {
                let urls = assets.sorted { ($0.pageIndex ?? 0) < ($1.pageIndex ?? 0) }.map { source.url(for: $0, sessionID: session.id) }
                let images = urls.compactMap { UIImage(contentsOfFile: $0.path) }
                text = try await DocumentScanService().transcribe(images: images)
            }
            try await store.updateTranscript(sessionID: session.id, transcript: text, error: nil)
            await home.loadSessions(); await health.refresh()
        } catch {
            localError = error.localizedDescription
            if let partial = error as? PartialAudioTranscriptionError, !partial.transcript.isEmpty {
                do {
                    try await store.updateTranscript(sessionID: session.id, transcript: partial.transcript, error: partial.localizedDescription)
                    await home.loadSessions(); await health.refresh()
                } catch { localError = "The partial transcription could not be saved. Your original audio is unchanged." }
            }
        }
    }
}

enum DetailTab: Hashable { case summary, source, transcript }

private struct RecordFactSelection: Identifiable {
    let factID: String
    let entryID: UUID
    var sourceOnlyEntry: SummaryEntry? = nil
    var removalKeys: Set<String>?
    var id: String { "\(factID)|\(entryID)" }
}

private struct NoteBlock {
    let key: String
    let initial: String
    var text: String
    var fact: HealthFact?
    var heading: String?
    var bullet: RecordBullet?
}

private struct RecordTextPage {
    let title: String?
    let body: String

    static func sections(in text: String) -> [Self] {
        let marker = #/^[\t ]*[-–—]+[\t ]*(?i:page)[\t ]+([0-9]+)(?:[\t ]+(?i:of)[\t ]+([0-9]+))?[\t ]*[-–—]+[\t ]*$/#
        var pages: [Self] = []
        var title: String?
        var lines: [Substring] = []

        func finishPage() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if title != nil || !body.isEmpty { pages.append(Self(title: title, body: body)) }
            lines.removeAll(keepingCapacity: true)
        }

        let displayText = text.replacing(#/(?i:<br[ \t]*\/?[ \t]*>)/#, with: "\n")
        for line in displayText.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            if let match = line.wholeMatch(of: marker) {
                finishPage()
                title = "Page \(match.1)" + (match.2.map { " of \($0)" } ?? "")
            } else {
                lines.append(line)
            }
        }
        finishPage()
        return pages
    }
}

private extension RecordTemplateSelection {
    var menuTitle: String { self == .categories ? "Detailed" : rawValue }

    var menuIcon: String {
        switch self {
        case .auto: return "sparkles"
        case .visit: return "stethoscope"
        case .categories: return "list.bullet.rectangle"
        }
    }
}

struct RecordMetadataRow<TemplateControl: View>: View {
    let session: Session
    @ObservedObject var health: HealthSummaryModel
    let editTime: () -> Void
    let editTeam: () -> Void
    let editConditions: () -> Void
    let dateOnly: Bool
    let templateControl: TemplateControl

    init(session: Session, health: HealthSummaryModel, editTime: @escaping () -> Void,
         editTeam: @escaping () -> Void, editConditions: @escaping () -> Void, dateOnly: Bool = false,
         @ViewBuilder templateControl: () -> TemplateControl = { EmptyView() }) {
        self.session = session
        self.health = health
        self.editTime = editTime
        self.editTeam = editTeam
        self.editConditions = editConditions
        self.dateOnly = dateOnly
        self.templateControl = templateControl()
    }

    var body: some View {
        let ids = health.recordFolders.memberships[session.id] ?? []
        let names = health.recordFolders.folders.filter { ids.contains($0.id) }.map(\.name)
        return ScrollView(.horizontal) {
            HStack(spacing: 16) {
                Button((session.visitTime ?? session.date).formatted(date: .abbreviated, time: dateOnly ? .omitted : .shortened), systemImage: "calendar") { editTime() }
                templateControl
                Button { editTeam() } label: {
                    HStack(spacing: 4) { Image(systemName: "person.2"); if let n = session.linkedMemberIDs?.count, n > 0 { Text("\(n)") } }
                }.frame(minWidth: 44, minHeight: 44).accessibilityLabel(teamLabel)
                Button { editConditions() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: names.isEmpty ? "folder.badge.plus" : "folder")
                        if let name = names.first { Text(verbatim: name); if names.count > 1 { Text("+\(names.count - 1)") } }
                    }
                }.frame(minWidth: 44, minHeight: 44).accessibilityLabel(names.isEmpty ? "Add to condition" : "Conditions: " + names.joined(separator: ", "))
            }.font(StoryDesignTokens.font(.subheadline)).foregroundStyle(StoryDesignTokens.secondaryInk)
                .buttonStyle(.plain).controlSize(.regular)
        }.scrollIndicators(.hidden)
    }

    private var teamLabel: String {
        let names = health.snapshot.careTeam.filter { session.linkedMemberIDs?.contains($0.id) == true }.map(\.name)
        return names.isEmpty ? "Care team" : names.joined(separator: ", ")
    }

}

struct RecordAttributeEditor: View {
    let kind: String
    let record: Session
    let store: SessionStore
    @ObservedObject var health: HealthSummaryModel
    let refreshed: (Bool) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var date: Date
    @State private var ids: Set<UUID>
    @State private var member: CareTeamMember?
    @State private var saving = false
    @State private var issue: String?
    private let saveDraftMetadata: ((Date?, Set<UUID>?) async throws -> Void)?
    init(kind: String, record: Session, store: SessionStore, health: HealthSummaryModel,
         saveDraftMetadata: ((Date?, Set<UUID>?) async throws -> Void)? = nil, refreshed: @escaping (Bool) async -> Void) {
        self.saveDraftMetadata = saveDraftMetadata
        self.kind = kind; self.record = record; self.store = store; self.health = health; self.refreshed = refreshed
        _value = State(initialValue: kind == "title" ? record.displayTitle : record.transcript.isEmpty && record.capture?.pending == true ? record.capture?.notes ?? "" : record.transcript)
        _date = State(initialValue: record.visitTime ?? record.date)
        _ids = State(initialValue: record.linkedMemberIDs ?? [])
        _base = State(initialValue: record.transcript)
    }
    @State private var base: String
    var body: some View {
        NavigationStack {
            Group {
                switch kind {
                case "team":
                    List {
                        ForEach(health.snapshot.careTeam) { person in
                            Button {
                                if !ids.insert(person.id).inserted { ids.remove(person.id) }
                            } label: {
                                HStack { Text(person.name).foregroundStyle(StoryDesignTokens.ink); Spacer()
                                    if ids.contains(person.id) { Image(systemName: "checkmark") }
                                }
                            }.accessibilityValue(ids.contains(person.id) ? "Selected" : "Not selected")
                        }
                        Button("Add care team member", systemImage: "person.badge.plus") { member = CareTeamMember() }
                    }
                    .storyListCanvas()
                case "time":
                    Form { DatePicker("Record date and time", selection: $date) }.storyListCanvas()
                case "title":
                    Form { TextField("Record title", text: $value, axis: .vertical) }.storyListCanvas()
                default:
                    TextEditor(text: $value).font(StoryDesignTokens.body).padding().accessibilityLabel("Extracted text")
                }
            }
            .navigationTitle(kind == "team" ? "Care team" : kind == "time" ? "Record time" : kind == "title" ? "Record title" : "Edit text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving || (kind == "title" && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .interactiveDismissDisabled(saving)
            .sheet(item: $member) { person in CareTeamEditor(member: person, model: health) { ids.insert($0.id) } }
            .alert("Couldn’t save", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
                Button("OK") {}
            } message: { Text(issue ?? "") }
        }
    }
    private func save() async {
        guard !saving else { return }; saving = true
        defer { saving = false }
        do {
            switch kind {
            case "team":
                if let saveDraftMetadata { try await saveDraftMetadata(nil, ids) }
                else { try await store.editRecordMetadata(id: record.id, members: ids) }
            case "title": try await store.editRecordMetadata(id: record.id, title: value)
            case "time":
                if let saveDraftMetadata { try await saveDraftMetadata(date, nil) }
                else { try await store.editRecordMetadata(id: record.id, time: date) }
            default: try await store.reviseStorySource(record.id, text: value, expectedTranscript: base)
            }
            dismiss(); await refreshed(kind == "text" && value != base)
        } catch StoryEditError.staleRevision {
            issue = "New text arrived while you were editing. Copy your changes, then reopen the editor to see the updated record."
        } catch { issue = error.localizedDescription }
    }
}

private struct RawRecordSheet: View {
    let record: Session
    let directory: URL?
    let store: SessionStore
    let saved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var base: Session
    @State private var notes: String
    @State private var combined: String
    @State private var passages: [UUID: String]
    @State private var editing = false
    @State private var saving = false
    @State private var error: String?
    @State private var preview: URL?

    init(record: Session, directory: URL?, store: SessionStore, saved: @escaping () async -> Void) {
        self.record = record
        self.directory = directory
        self.store = store
        self.saved = saved
        _base = State(initialValue: record)
        _notes = State(initialValue: record.capture?.notes ?? "")
        _combined = State(initialValue: record.transcript)
        _passages = State(initialValue: record.capture?.textByAsset ?? [:])
    }

    private func assembled(_ capture: RecordCapture) -> String {
        var parts: [String] = []
        if !capture.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Patient notes\n" + capture.notes)
        }
        for asset in base.sourceAssets ?? [] {
            if let text = capture.textByAsset[asset.id] { parts.append(asset.displayName + "\n" + text) }
        }
        return parts.joined(separator: "\n\n")
    }

    private var usesSeparatePassages: Bool {
        guard let capture = base.capture else { return false }
        return base.transcript == assembled(capture) || capture.pending && base.transcript.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if usesSeparatePassages && base.capture?.notes.isEmpty == false {
                        section("Patient notes", text: $notes)
                    }
                    let assets = base.sourceAssets ?? []
                    ForEach(assets) { asset in
                        VStack(alignment: .leading, spacing: 8) {
                            if let directory {
                                let url = SessionSourceStore(storageDirectory: directory).url(for: asset, sessionID: base.id)
                                Button { preview = url } label: {
                                    HStack {
                                        RawAssetThumbnail(url: url, kind: asset.kind)
                                        Text(asset.displayName).font(StoryDesignTokens.label)
                                        Image(systemName: "chevron.forward").font(.caption)
                                    }
                                }
                            } else { Text(asset.displayName).font(StoryDesignTokens.label) }
                            if usesSeparatePassages {
                                passage(Binding(get: { passages[asset.id] ?? "" }, set: { passages[asset.id] = $0 }))
                            } else if assets.count == 1 && base.capture == nil {
                                passage($combined)
                            } else if let captured = base.capture?.textByAsset[asset.id] {
                                Text(verbatim: captured).textSelection(.enabled)
                            }
                        }
                    }
                    if !usesSeparatePassages && (assets.count != 1 || base.capture != nil) {
                        section("Record text", text: $combined)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .storyLoadIn().navigationTitle("Extracted data").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editing ? "Discard edits" : "Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing ? "Save" : "Edit") {
                        if editing { save() } else { editing = true }
                    }.disabled(base.capture?.pending == true)
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(editing)
            .quickLookPreview($preview)
            .onChange(of: record) { _, latest in
                guard !editing else { return }
                base = latest; notes = latest.capture?.notes ?? ""
                combined = latest.transcript; passages = latest.capture?.textByAsset ?? [:]
            }
            .alert("Couldn’t save edits", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func section(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(StoryDesignTokens.section); passage(text) }
    }

    @ViewBuilder private func passage(_ text: Binding<String>) -> some View {
        if editing {
            TextField("Extracted text", text: text, axis: .vertical).textFieldStyle(.plain)
        } else if text.wrappedValue.isEmpty {
            Text("No extracted text yet").foregroundStyle(StoryDesignTokens.secondaryInk)
        } else {
            Text(verbatim: text.wrappedValue).textSelection(.enabled)
        }
    }

    private func save() {
        guard !saving else { return }
        var capture = usesSeparatePassages ? base.capture : nil
        capture?.notes = notes
        capture?.textByAsset = passages
        let text = capture.map(assembled) ?? combined
        guard text != base.transcript || (capture != nil && capture != base.capture) else { dismiss(); return }
        saving = true
        Task {
            do {
                try await store.reviseStorySource(base.id, text: text, expectedTranscript: base.transcript,
                                                  revisedCapture: capture, expectedCapture: base.capture)
                dismiss()
                await saved()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

private struct RawAssetThumbnail: View {
    let url: URL
    let kind: SessionSourceKind
    var size = CGSize(width: 56, height: 56)
    @State private var thumbnail: UIImage?
    var body: some View {
        Group {
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
            else { Image(systemName: kind == .audio ? "waveform" : kind == .image ? "photo" : "doc") }
        }.frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 8)).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
            .task(id: url) {
                thumbnail = nil
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96),
                                                            scale: 2, representationTypes: .all)
                thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
            }
    }
}


extension EnvironmentValues {
    @Entry var askAboutRecord: ((Session) -> Void)? = nil
}
