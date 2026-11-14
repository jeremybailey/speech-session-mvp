import SwiftUI
import QuickLook
import QuickLookThumbnailing
import NaturalLanguage
import SpeechSessionFeatures
import SpeechSessionPersistence
import SpeechSessionTranscription

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
    @State private var directory: URL?
    @State private var shareableURL: URL?
    @State private var transcriptionConsent = false
    @ObservedObject private var captureWorker = CaptureProcessing.shared
    @State private var retrying = false
    @State private var confirmDelete = false
    @State private var localError: String?
    @State private var selectedTab: DetailTab
    @State private var expandedCategories: Set<SummaryEntryCategory> = []
    @Environment(\.askAboutRecord) private var askAboutRecord
    @Environment(\.storyRouter) private var storyRouter
    @State private var routedExcerpt: String?
    @State private var pickingFolders = false
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
    @State private var draftTitle = ""
    @State private var originalTitle = ""
    @State private var baselineEdits: [String: String] = [:]
    @State private var rawDrawer = false
    @State private var draftBlocks: [NoteBlock] = []
    private var storyLab: Bool { Bundle.main.bundleIdentifier == "com.CollectiveCare.storylab" }
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
        health.facts.compactMap { $0.presentedFromRecord(session.id) }
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
                if let directory {
                    SessionSourceView(session: session, storageDirectory: directory,
                                      highlightedExcerpt: routedExcerpt ?? sourceHighlightExcerpt, shareableFileURL: $shareableURL)
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
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
                        if let directory, let assets = session.sourceAssets, !assets.isEmpty {
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
            if !editingNote && session.capture != nil && captureWorker.active.contains(session.id) {
                StoryThinkingStatus("Preparing details…")
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
            else if let capture = session.capture {
                if captureWorker.active.contains(session.id) { EmptyView() }
                else if !capture.failedAssets.isEmpty || captureWorker.errors[session.id] != nil || capture.pending {
                    Button("Retry unfinished processing") { processCapture() }.padding(8)
                } else if !session.transcript.isEmpty && recordFacts.isEmpty {
                    Button("Prepare details") { regenerate() }.padding(8)
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
                        Button("Edit record", systemImage: "pencil") { selectedTab = .transcript; beginNoteEdit(.title) }
                        Button("View extracted data", systemImage: "doc.text.magnifyingglass") { rawDrawer = true }
                        Button("View details", systemImage: "list.bullet") {
                            selectedTab = .summary
                        }
                        Divider()
                    }
                    Button("Reprocess record", systemImage: "arrow.clockwise") {
                        if summaryBackend == "onDevice" || cloudSummaryConsent { regenerate() }
                        else { summaryConsent = true }
                    }.disabled(health.isProcessing || session.transcript.isEmpty)
                    if health.isProcessing { Button("Cancel regeneration") { summaryTask?.cancel() } }
                    Divider()
                    Button("Delete record", systemImage: "trash", role: .destructive) { confirmDelete = true }.disabled(retrying)
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Record actions")
            }
            }
        }
        .confirmationDialog("Check your summary using cloud processing?", isPresented: $summaryConsent, titleVisibility: .visible) {
            Button("Use cloud processing") { cloudSummaryConsent = true; regenerate() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Text from this record will be sent through CollectiveCare’s service to OpenAI for summarization and verification. Temporary processing content has a seven-day expiry and cleanup policy; usage metadata is retained separately.") }
        .task { directory = await store.storageDirectory; await health.refresh(); if session.capture?.pending == true { processCapture() } }
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
                if let directory {
                    SessionSourceView(session: session, storageDirectory: directory, highlightedExcerpt: routedExcerpt ?? sourceHighlightExcerpt, shareableFileURL: $shareableURL)
                        .navigationTitle("Source").toolbar { Button("Close") { previewOriginal = false } }
                }
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
        .sheet(item: $editingFact) { selection in
            NavigationStack {
                HealthFactDetailView(factID: selection.factID, preferredEntryID: selection.entryID, sourceOnlyEntry: selection.sourceOnlyEntry,
                                     model: health, home: home, store: store)
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
        .alert("Record processing", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button("OK") { localError = nil }
        } message: { Text(localError ?? "") }
    }

    private func blocks() -> [NoteBlock] {
        let edits = session.summaryParagraphEdits ?? [:]
        var result: [NoteBlock] = []
        let grouped = Dictionary(grouping: recordFacts, by: \.category)
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
            let text = edits[fact.id] ?? generated
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
                }.font(StoryDesignTokens.heading(.largeTitle)).foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                noteMetadata.disabled(editingNote)
                let content = editingNote ? draftBlocks : blocks()
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(content.indices, id: \.self) { i in
                        let block = content[i]
                        if let category = block.fact?.category,
                           i == 0 || content[i - 1].fact?.category != category {
                            Text(category.displayTitle)
                                .font(StoryDesignTokens.font(.title2, weight: .bold))
                                .foregroundStyle(.primary)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.top, i == 0 ? 0 : 24)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if block.fact != nil { Text("•").accessibilityHidden(true) }
                            VStack(alignment: .leading, spacing: 2) {
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
                                if let fact = block.fact {
                                    Button {
                                        openFact(RecordFactSelection(factID: fact.id, entryID: fact.latest.id))
                                    } label: {
                                        StorySourceTag(title: fact.category.displayTitle,
                                                       systemImage: SummaryCategoryIcon(title: fact.category.displayTitle).icon)
                                    }
                                    .disabled(editingNote)
                                    .accessibilityLabel("Open detail: \(fact.title)")
                                }
                            }
                        }.font(StoryDesignTokens.body)
                            .lineSpacing(4).padding(.top, 8)
                    }
                }
                if let directory, let assets = session.sourceAssets, !assets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Attached").font(.subheadline).foregroundStyle(.secondary)
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
                                                Text(asset.displayName).font(.caption).lineLimit(2)
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
                          editTeam: { edit = .team }, editConditions: { pickingFolders = true })
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
            if let error = health.error { Text(error).foregroundStyle(.secondary) }
            let excluded = (session.summaryEntries ?? []).filter { !$0.isDeleted && !SummaryVerification.isVisible($0, source: session.transcript) }
            if !excluded.isEmpty {
                DisclosureGroup("Details kept in original (\(excluded.count))") {
                    Text(health.isProcessing ? "These are results from the previous check. They will update when processing finishes." : "These details have not passed source checking. They are not included in your health story or shared summary.").font(StoryDesignTokens.font(.subheadline))
                    ForEach(excluded) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.title).font(StoryDesignTokens.font(.headline, weight: .semibold))
                            Text(SummaryVerification.exclusionReason(entry, source: session.transcript)).font(StoryDesignTokens.font(.caption)).foregroundStyle(.secondary)
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
                        Text(facts.count.formatted()).foregroundStyle(.secondary)
                            .accessibilityLabel("\(facts.count) details")
                    }.frame(minHeight: 48)
                }
            }
        }.listStyle(.insetGrouped)
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
        resumeAfterConsent = false
        summaryTask = Task {
            let transport = summaryBackend == "onDevice" ? nil : await auth.openAIChatTransport(byokFallback: apiKey)
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
        guard !retrying, let directory else { return }
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
    var id: String { "\(factID)|\(entryID)" }
}

private struct NoteBlock {
    let key: String
    let initial: String
    var text: String
    var fact: HealthFact?
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

struct RecordMetadataRow: View {
    let session: Session
    @ObservedObject var health: HealthSummaryModel
    let editTime: () -> Void
    let editTeam: () -> Void
    let editConditions: () -> Void

    var body: some View {
        let ids = health.recordFolders.memberships[session.id] ?? []
        let names = health.recordFolders.folders.filter { ids.contains($0.id) }.map(\.name)
        return ScrollView(.horizontal) {
            HStack(spacing: 16) {
                Button((session.visitTime ?? session.date).formatted(date: .abbreviated, time: .shortened), systemImage: "calendar") { editTime() }
                Button { editTeam() } label: {
                    HStack(spacing: 4) { Image(systemName: "person.2"); if let n = session.linkedMemberIDs?.count, n > 0 { Text("\(n)") } }
                }.frame(minWidth: 44, minHeight: 44).accessibilityLabel(teamLabel)
                Button { editConditions() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: names.isEmpty ? "folder.badge.plus" : "folder")
                        if let name = names.first { Text(verbatim: name); if names.count > 1 { Text("+\(names.count - 1)") } }
                    }
                }.frame(minWidth: 44, minHeight: 44).accessibilityLabel(names.isEmpty ? "Add to condition" : "Conditions: " + names.joined(separator: ", "))
            }.font(StoryDesignTokens.font(.subheadline)).foregroundStyle(.secondary)
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
                                HStack { Text(person.name).foregroundStyle(.primary); Spacer()
                                    if ids.contains(person.id) { Image(systemName: "checkmark") }
                                }
                            }.accessibilityValue(ids.contains(person.id) ? "Selected" : "Not selected")
                        }
                        Button("Add care team member", systemImage: "person.badge.plus") { member = CareTeamMember() }
                    }
                case "time":
                    Form { DatePicker("Record date and time", selection: $date) }
                case "title":
                    Form { TextField("Record title", text: $value, axis: .vertical) }
                default:
                    TextEditor(text: $value).font(StoryDesignTokens.body).padding().accessibilityLabel("Extracted text")
                }
            }
            .navigationTitle(kind == "team" ? "Care team" : kind == "time" ? "Record time" : kind == "title" ? "Record title" : "Edit text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
                                        Text(asset.displayName).font(.headline)
                                        Image(systemName: "chevron.forward").font(.caption)
                                    }
                                }
                            } else { Text(asset.displayName).font(.headline) }
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
            .navigationTitle("Extracted data").navigationBarTitleDisplayMode(.inline)
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
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.headline); passage(text) }
    }

    @ViewBuilder private func passage(_ text: Binding<String>) -> some View {
        if editing {
            TextField("Extracted text", text: text, axis: .vertical).textFieldStyle(.plain)
        } else if text.wrappedValue.isEmpty {
            Text("No extracted text yet").foregroundStyle(.secondary)
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
