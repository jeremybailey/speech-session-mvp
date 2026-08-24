import SwiftUI
import SpeechSessionFeatures
import SpeechSessionPersistence

struct SessionDetailView: View {
    let store: SessionStore
    @ObservedObject var home: HomeViewModel

    /// Mutable local copy so we can persist the generated title and summary back to the store.
    @State private var localSession: Session

    @EnvironmentObject private var kindeAuth: KindeAuthManager
    @AppStorage("speechSession.openaiAPIKey") private var openAIAPIKey = ""
    @AppStorage("speechSession.summaryBackend") private var summaryBackendRaw = "openai"

    @State private var selectedTab: DetailTab = .summary
    @State private var summaryState: SummaryState = .idle
    @State private var storageDirectory: URL?
    @State private var sourceHighlightExcerpt: String?
    @State private var sourceShareableURL: URL?

    init(session: Session, store: SessionStore, home: HomeViewModel) {
        self.store = store
        self.home = home
        _localSession = State(initialValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                Text("Summary").tag(DetailTab.summary)
                Text("Source").tag(DetailTab.source)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            switch selectedTab {
            case .summary:
                summaryTab
            case .source:
                sourceTab
            }
        }
        .background(BrandPalette.canvas.ignoresSafeArea())
        .navigationTitle(localSession.title ?? localSession.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Section("Move to folder") {
                        Button("Unfiled") {
                            Task { await moveSession(to: nil) }
                        }
                        .disabled(localSession.folderID == nil)
                        ForEach(home.folders) { folder in
                            Button(folder.name) {
                                Task { await moveSession(to: folder.id) }
                            }
                            .disabled(localSession.folderID == folder.id)
                        }
                    }
                } label: {
                    Image(systemName: "folder")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if selectedTab == .summary, let item = sharePDFItem {
                    ShareLink(
                        item: item,
                        preview: SharePreview(sharePreviewTitle, image: Image(systemName: "doc.richtext"))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                } else if selectedTab == .source, let url = sourceShareableURL {
                    ShareLink(
                        item: url,
                        preview: SharePreview(url.lastPathComponent, image: Image(systemName: "doc"))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                } else if let payload = textSharePayload {
                    ShareLink(item: payload.text, subject: Text(payload.subject)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        // Start generating the summary immediately in the background when this view appears.
        // If a cached summary exists it returns instantly; otherwise it runs silently while
        // the user reads the transcript so there's no wait when they switch to the Summary tab.
        .task {
            storageDirectory = await store.storageDirectory
            if let cached = localSession.summary {
                await ensureAtomicEntriesFromLegacyIfNeeded(markdown: cached)
                summaryState = .loaded(cached)
            } else {
                await loadSummary()
            }
        }
        // When the user switches to the summary tab, surface whatever state we're in.
        .task(id: selectedTab) {
            guard selectedTab == .summary else { return }
            if let cached = localSession.summary, case .idle = summaryState {
                summaryState = .loaded(cached)
            }
            // If already loading or loaded, the existing summaryState drives the UI — no action needed.
        }
    }

    // MARK: - Source Tab

    @ViewBuilder
    private var sourceTab: some View {
        if let storageDirectory {
            SessionSourceView(
                session: localSession,
                storageDirectory: storageDirectory,
                highlightedExcerpt: sourceHighlightExcerpt,
                shareableFileURL: $sourceShareableURL
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Summary Tab

    @ViewBuilder
    private var summaryTab: some View {
        switch summaryState {
        case .idle:
            Color.clear
        case .loading:
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Generating medical summary…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .frame(maxWidth: .infinity)
                .liquidGlassCard(cornerRadius: 16)
                .padding(.horizontal, 20)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .loaded(let text):
            ScrollView {
                Group {
                    if !activeSummaryEntries.isEmpty {
                        AtomicSummaryCardsView(
                            entries: activeSummaryEntries,
                            onSave: { entry in Task { await saveSummaryEntry(entry) } },
                            onDelete: { entry in Task { await deleteSummaryEntry(entry) } },
                            onAdd: { category in Task { await addSummaryEntry(category: category) } },
                            onViewSource: { entry in
                                sourceHighlightExcerpt = entry.sourceExcerpt
                                selectedTab = .source
                            }
                        )
                        .padding(.vertical)
                    } else {
                        SummaryCardsView(text: text)
                            .padding(.vertical)
                    }
                }
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        case .failed(let message):
            VStack {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        summaryState = .idle
                        Task { await loadSummary() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(28)
                .frame(maxWidth: .infinity)
                .liquidGlassCard(cornerRadius: 16)
                .padding(.horizontal, 20)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func moveSession(to folderID: UUID?) async {
        localSession.folderID = folderID
        try? await store.upsert(localSession)
        await home.loadSessions()
    }

    private var activeSummaryEntries: [SummaryEntry] {
        (localSession.summaryEntries ?? []).filter { !$0.isDeleted }
    }

    private func ensureAtomicEntriesFromLegacyIfNeeded(markdown: String) async {
        guard (localSession.summaryEntries ?? []).isEmpty else { return }
        let imported = SummaryEntryFactory.legacyEntries(from: markdown, session: localSession)
        guard !imported.isEmpty else { return }
        localSession.summaryEntries = imported
        try? await store.upsert(localSession)
        await home.loadSessions()
    }

    private func saveSummaryEntry(_ entry: SummaryEntry) async {
        var entries = localSession.summaryEntries ?? []
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        localSession.summaryEntries = entries
        try? await store.upsert(localSession)
        await home.loadSessions()
    }

    private func deleteSummaryEntry(_ entry: SummaryEntry) async {
        var entries = localSession.summaryEntries ?? []
        if let index = entries.firstIndex(where: { $0.id == entry.id })
            ?? entries.firstIndex(where: {
                !$0.isDeleted
                    && $0.category == entry.category
                    && $0.title == entry.title
                    && $0.details == entry.details
            }) {
            entries[index].isDeleted = true
            entries[index].updatedAt = Date()
            entries[index].origin = .userEdited
        } else {
            var deleted = entry
            deleted.isDeleted = true
            deleted.updatedAt = Date()
            deleted.origin = .userEdited
            entries.append(deleted)
        }
        localSession.summaryEntries = entries
        try? await store.upsert(localSession)
        await home.loadSessions()
    }

    private func addSummaryEntry(category: SummaryEntryCategory) async {
        let now = Date()
        let entry = SummaryEntry(
            category: category,
            title: "",
            details: "",
            fields: SummaryEntryFactory.fieldsForNewUserEntry(category: category),
            relevantDate: nil,
            dateNeedsReview: true,
            sourceSessionID: localSession.id,
            sourceTitle: localSession.title,
            sourceDate: localSession.date,
            provenance: "User-added detail",
            needsReview: true,
            reviewReason: "Add missing details and the actual relevant date.",
            origin: .userAdded,
            createdAt: now,
            updatedAt: now
        )
        var entries = localSession.summaryEntries ?? []
        entries.append(entry)
        localSession.summaryEntries = entries
        try? await store.upsert(localSession)
        await home.loadSessions()
    }

    // MARK: - Share

    /// Plain-text export kept for fallback — summary tab shares PDF via ``sharePDFItem``.
    private var textSharePayload: (text: String, subject: String)? {
        let dateLabel = localSession.date.formatted(date: .abbreviated, time: .shortened)
        let sessionLabel = localSession.title ?? dateLabel

        switch selectedTab {
        case .source:
            let transcript = localSession.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return nil }
            return (text: transcript, subject: "\(sessionLabel) — Source Text")

        case .summary:
            guard case .loaded(let text) = summaryState else { return nil }
            let atomicText = atomicShareText().trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = atomicText.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : atomicText
            guard !summary.isEmpty else { return nil }
            return (text: summary, subject: "\(sessionLabel) — Medical Summary")
        }
    }

    private var sharePreviewTitle: String {
        let dateLabel = localSession.date.formatted(date: .abbreviated, time: .shortened)
        let sessionLabel = localSession.title ?? dateLabel
        return "\(sessionLabel) — Medical Summary"
    }

    private var sharePDFItem: SummaryPDFShareItem? {
        guard selectedTab == .summary else { return nil }
        guard case .loaded = summaryState else { return nil }

        let entries = activeSummaryEntries
        var legacy: [(title: String, content: String)] = []
        if entries.isEmpty, case .loaded(let markdown) = summaryState {
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                legacy = [("Summary", trimmed)]
            }
        }

        let dateLabel = localSession.date.formatted(date: .abbreviated, time: .shortened)
        let sessionLabel = localSession.title ?? dateLabel

        guard let document = SummaryPDFDocumentBuilder.build(
            title: sessionLabel,
            subtitle: "Medical Summary · \(dateLabel)",
            overview: nil,
            entries: entries,
            legacySections: legacy,
            timelineSessions: [localSession]
        ) else { return nil }

        return SummaryPDFShareItem(document: document)
    }

    private func atomicShareText() -> String {
        let entries = activeSummaryEntries
        guard !entries.isEmpty else { return "" }
        var parts: [String] = []
        for category in SummaryEntryCategory.allCases {
            let matches = entries.filter { $0.category == category }
            guard !matches.isEmpty else { continue }
            parts.append(category.displayTitle.uppercased())
            for entry in matches {
                let date = entry.relevantDate?.formatted(date: .abbreviated, time: .omitted) ?? "Date missing"
                let line = [entry.title, entry.details].filter { !$0.isEmpty }.joined(separator: " — ")
                parts.append("• \(date): \(line)")
                if !entry.provenance.isEmpty {
                    parts.append("  Source: \(entry.provenance)")
                }
            }
            parts.append("")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Summary Generation

    /// Minimum word count before we'll attempt summarization.
    /// Below this the model has too little context and will hallucinate structure.
    private static let minimumWordCount = 30

    private func loadSummary() async {
        guard case .idle = summaryState else { return }

        let transcript = localSession.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = transcript.split(separator: " ").count

        guard !transcript.isEmpty else {
            summaryState = .failed("No transcript was recorded.")
            return
        }
        guard wordCount >= Self.minimumWordCount else {
            let tail = localSession.entryIntent == .personalJournal
                ? "Speak or type more detail and try again."
                : "Record a full appointment and try again."
            summaryState = .failed(
                "The recording is too short to summarize reliably (\(wordCount) word\(wordCount == 1 ? "" : "s") captured). "
                    + tail
            )
            return
        }

        summaryState = .loading

        // Route to the selected backend.
        if summaryBackendRaw == "onDevice" {
            if isOnDeviceSummaryAvailable {
                await loadSummaryOnDevice()
            } else {
                summaryBackendRaw = "openai"
                await loadSummaryOpenAI()
            }
            return
        }
        await loadSummaryOpenAI()
    }

    // MARK: On-device summary (Apple Intelligence, iOS 26.0+)

    private func loadSummaryOnDevice() async {
        guard #available(iOS 26.0, *) else {
            summaryState = .failed("On-device summaries require iOS 26.0 or later.")
            return
        }
        guard OnDeviceSummaryService.isAvailable else {
            summaryState = .failed(OnDeviceSummaryService.unavailabilityReason)
            return
        }
        do {
            let service = OnDeviceSummaryService()
        let contentKind: SummaryContentKind
        if localSession.entryIntent == .personalJournal {
            contentKind = .personalJournal
        } else if localSession.inputType == .audio {
            contentKind = .visitEncounter
        } else {
            do {
                contentKind = try await service.classifyTranscript(localSession.transcript)
            } catch {
                contentKind = .mixedOther
            }
        }
            let (title, summary) = try await service.generate(
                transcript: localSession.transcript,
                contentKind: contentKind
            )
            guard !summary.isEmpty else {
                summaryState = .failed("The model returned an empty summary. Try again.")
                return
            }
            localSession.summary = summary
            if !title.isEmpty { localSession.title = title }
            localSession.summaryEntries = SummaryEntryFactory.legacyEntries(from: summary, session: localSession)
            let sessionToSave = localSession
            try? await store.upsert(sessionToSave)
            await home.loadSessions()
            summaryState = .loaded(summary)
        } catch {
            summaryState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }

    private var isOnDeviceSummaryAvailable: Bool {
        if #available(iOS 26.0, *) {
            return OnDeviceSummaryService.isAvailable
        }
        return false
    }

    // MARK: OpenAI summary

    private static var cloudOpenAINotConfiguredMessage: String {
        var s = """
        Sign in under Settings → Account to use cloud summaries. Your organization must configure the API endpoint. \
        Session data stays on this device; only the transcript is sent for summarization.
        """
        #if DEBUG
        s += " In debug builds you can paste an OpenAI API key in Settings."
        #endif
        return s
    }

    private func loadSummaryOpenAI() async {
        guard let transport = await kindeAuth.openAIChatTransport(byokFallback: openAIAPIKey) else {
            summaryState = .failed(Self.cloudOpenAINotConfiguredMessage)
            return
        }

        let contentKind: SummaryContentKind
        if localSession.entryIntent == .personalJournal {
            contentKind = .personalJournal
        } else if localSession.inputType == .audio {
            contentKind = .visitEncounter
        } else {
            do {
                contentKind = try await OpenAISummaryContentClassifier.classify(
                    transcript: localSession.transcript,
                    transport: transport
                )
            } catch {
                contentKind = .mixedOther
            }
        }

        let (systemPrompt, userPrefix) = SummaryPromptAssembly.openAISummaryPrompts(contentKind: contentKind)
        let userPrompt = userPrefix + localSession.transcript

        struct Msg: Encodable { let role: String; let content: String }
        struct ResponseFormat: Encodable { let type: String }
        struct ChatRequest: Encodable {
            let model: String
            let messages: [Msg]
            let response_format: ResponseFormat
            let max_tokens: Int
            let temperature: Double
        }
        struct RespMsg: Decodable { let content: String? }
        struct Choice: Decodable { let message: RespMsg }
        struct ChatResponse: Decodable { let choices: [Choice] }
        struct APIErr: Decodable { struct Err: Decodable { let message: String? }; let error: Err? }

        var req = URLRequest(url: transport.chatCompletionsURL)
        req.httpMethod = "POST"
        do {
            req.setValue(try await transport.makeAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        } catch {
            summaryState = .failed(error.localizedDescription)
            return
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        let body = ChatRequest(
            model: "gpt-4o-mini",
            messages: [
                Msg(role: "system", content: systemPrompt),
                Msg(role: "user", content: userPrompt)
            ],
            response_format: ResponseFormat(type: "json_object"),
            max_tokens: 2200,
            temperature: 0
        )

        do {
            req.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: req)

            guard let http = response as? HTTPURLResponse else {
                summaryState = .failed("Invalid server response.")
                return
            }
            guard (200...299).contains(http.statusCode) else {
                let msg = (try? JSONDecoder().decode(APIErr.self, from: data))?.error?.message
                summaryState = .failed(msg ?? "Server error (\(http.statusCode)). Try signing in again under Settings.")
                return
            }

            guard
                let chatResponse = try? JSONDecoder().decode(ChatResponse.self, from: data),
                let content = chatResponse.choices.first?.message.content
            else {
                summaryState = .failed("Could not parse summary response. Try again.")
                return
            }

            let defaultTitle = localSession.date.formatted(date: .abbreviated, time: .shortened)
            guard let fields = VisitSummaryJSONParser.fields(fromAssistantContent: content) else {
                summaryState = .failed("Could not parse summary JSON. Try again.")
                return
            }
            guard let (titleText, summaryText) = fields.resolved(defaultTitle: defaultTitle) else {
                summaryState = .failed("The model returned an empty summary. Try again.")
                return
            }

            // Persist title and summary so they never need to be regenerated.
            localSession.summary = summaryText
            if !titleText.isEmpty { localSession.title = titleText }
            localSession.summaryEntries = SummaryEntryFactory.entries(from: fields, session: localSession)
            let sessionToSave = localSession
            try? await store.upsert(sessionToSave)
            await home.loadSessions()

            summaryState = .loaded(summaryText)

        } catch {
            summaryState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }
}

// MARK: - Supporting Types

private enum DetailTab: Hashable {
    case source, summary
}

private enum SummaryState {
    case idle
    case loading
    case loaded(String)
    case failed(String)
}

// SummaryCardsView and SummaryCategoryCard now live in SummaryCardView.swift
