import SwiftUI
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
    @State private var retrying = false
    @State private var confirmDelete = false
    @State private var localError: String?
    @State private var selectedTab: DetailTab
    @State private var expandedCategories: Set<SummaryEntryCategory> = []
    @State private var editingFact: RecordFactSelection?
    let sourceHighlightExcerpt: String?

    init(session: Session, store: SessionStore, home: HomeViewModel, initialTab: DetailTab = .summary, sourceHighlightExcerpt: String? = nil) {
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
            Picker("Record view", selection: $selectedTab) {
                Text("Summary").tag(DetailTab.summary)
                Text("Original").tag(DetailTab.source)
                Text(session.inputType == .audio ? "Transcript" : "Text").tag(DetailTab.transcript)
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
                                      highlightedExcerpt: sourceHighlightExcerpt, shareableFileURL: $shareableURL)
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            case .transcript:
                ScrollView {
                    Text(session.transcript.isEmpty ? "No text available yet." : session.transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if retrying {
                HStack { ProgressView(); Text("Reading your original…") }.padding().background(.regularMaterial)
            } else if session.processingError != nil || session.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.processingError ?? "Your original is saved. Its text is not ready yet.")
                        .font(.subheadline)
                    Button("Read original again") { requestTranscription() }
                        .buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity).padding().background(.regularMaterial)
            }
        }
        .navigationTitle(session.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let shareableURL {
                    ShareLink(item: shareableURL) { Label("Share original", systemImage: "square.and.arrow.up") }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Reprocess record", systemImage: "arrow.clockwise") {
                        if summaryBackend == "onDevice" || cloudSummaryConsent { regenerate() }
                        else { summaryConsent = true }
                    }.disabled(health.isProcessing || session.transcript.isEmpty)
                    if health.isProcessing { Button("Cancel regeneration") { summaryTask?.cancel() } }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Record actions")
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Delete record", role: .destructive) { confirmDelete = true }
                    .disabled(retrying)
            }
        }
        .confirmationDialog("Check your summary using cloud processing?", isPresented: $summaryConsent, titleVisibility: .visible) {
            Button("Use cloud processing") { cloudSummaryConsent = true; regenerate() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Text from this record will be sent through CollectiveCare’s service to OpenAI for summarization and verification.") }
        .task { directory = await store.storageDirectory; await health.refresh() }
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

    private var recordSummary: some View {
        let grouped = Dictionary(grouping: recordFacts, by: \.category)
        let categories = SummaryEntryCategory.allCases.filter { grouped[$0]?.isEmpty == false }
        return List {
            if health.isProcessing { HStack { ProgressView(); Text(health.progress) } }
            if !health.isProcessing, let issue = health.processingIssue {
                SummaryProcessingIssueView(issue: issue, retry: { regenerate(retryUnfinished: true) })
            }
            if let error = health.error { Text(error).foregroundStyle(.secondary) }
            let excluded = (session.summaryEntries ?? []).filter { !$0.isDeleted && !SummaryVerification.isVisible($0, source: session.transcript) }
            if !excluded.isEmpty {
                DisclosureGroup("Details kept in original (\(excluded.count))") {
                    Text(health.isProcessing ? "These are results from the previous check. They will update when processing finishes." : "These details have not passed source checking. They are not included in your health story or shared summary.").font(.subheadline)
                    ForEach(excluded) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.title).font(.headline)
                            Text(SummaryVerification.exclusionReason(entry, source: session.transcript)).font(.caption).foregroundStyle(.secondary)
                            Button("Edit and add to health story") {
                                editingFact = RecordFactSelection(factID: HealthMemoryProjection.key(for: entry), entryID: entry.id, sourceOnlyEntry: entry)
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
                            editingFact = RecordFactSelection(factID: fact.id, entryID: fact.latest.id)
                        })
                        .padding(.vertical, 8)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SummaryCategoryIcon(title: category.displayTitle).accessibilityHidden(true)
                        Text(category.displayTitle).font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(facts.count.formatted()).foregroundStyle(.secondary)
                            .accessibilityLabel("\(facts.count) details")
                    }.frame(minHeight: 48)
                }
            }
        }.listStyle(.insetGrouped)
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
