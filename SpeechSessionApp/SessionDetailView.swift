import SwiftUI
import SpeechSessionPersistence

struct SessionDetailView: View {
    let store: SessionStore

    /// Mutable local copy so we can persist the generated title and summary back to the store.
    @State private var localSession: Session

    @AppStorage("speechSession.openaiAPIKey") private var openAIAPIKey = ""
    @AppStorage("speechSession.summaryBackend") private var summaryBackendRaw = "openai"

    @State private var selectedTab: DetailTab = .transcription
    @State private var summaryState: SummaryState = .idle

    init(session: Session, store: SessionStore) {
        self.store = store
        _localSession = State(initialValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                Text("Transcription").tag(DetailTab.transcription)
                Text("Summary").tag(DetailTab.summary)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            switch selectedTab {
            case .transcription:
                transcriptionTab
            case .summary:
                summaryTab
            }
        }
        .navigationTitle(localSession.title ?? localSession.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let payload = sharePayload {
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
            if let cached = localSession.summary {
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

    // MARK: - Transcription Tab

    private var transcriptionTab: some View {
        ScrollView {
            Text(localSession.transcript.isEmpty ? "(No transcript recorded)" : localSession.transcript)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }

    // MARK: - Summary Tab

    @ViewBuilder
    private var summaryTab: some View {
        switch summaryState {
        case .idle:
            Color.clear
        case .loading:
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("Generating medical summary…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        case .loaded(let text):
            ScrollView {
                SummaryCardsView(text: text)
                    .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
        case .failed(let message):
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
                Button("Try Again") {
                    summaryState = .idle
                    Task { await loadSummary() }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Share

    /// Returns the text and subject to hand to the share sheet, or nil when there is nothing ready to share.
    private var sharePayload: (text: String, subject: String)? {
        let dateLabel = localSession.date.formatted(date: .abbreviated, time: .shortened)
        let sessionLabel = localSession.title ?? dateLabel

        switch selectedTab {
        case .transcription:
            let transcript = localSession.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return nil }
            return (text: transcript, subject: "\(sessionLabel) — Transcript")

        case .summary:
            guard case .loaded(let text) = summaryState else { return nil }
            let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return nil }
            return (text: summary, subject: "\(sessionLabel) — Medical Summary")
        }
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
            summaryState = .failed(
                "The recording is too short to summarize reliably (\(wordCount) word\(wordCount == 1 ? "" : "s") captured). " +
                "Record a full appointment and try again."
            )
            return
        }

        summaryState = .loading

        // Route to the selected backend.
        if summaryBackendRaw == "onDevice" {
            await loadSummaryOnDevice()
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
            let (title, summary) = try await service.generate(transcript: localSession.transcript)
            guard !summary.isEmpty else {
                summaryState = .failed("The model returned an empty summary. Try again.")
                return
            }
            localSession.summary = summary
            if !title.isEmpty { localSession.title = title }
            let sessionToSave = localSession
            try? await store.upsert(sessionToSave)
            summaryState = .loaded(summary)
        } catch {
            summaryState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }

    // MARK: OpenAI summary

    private func loadSummaryOpenAI() async {
        let key = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            summaryState = .failed("Add an OpenAI API key in Settings (tap the gear icon) to generate summaries.")
            return
        }

        // Ask the model to return a JSON object with a short title AND the full medical summary
        // so we can persist both in a single API call.
        let systemPrompt = """
        You are a medical scribe reviewing an appointment transcript. \
        Extract only clinically relevant information. \
        Ignore all greetings, small talk, and scheduling chatter. \
        Only include information that is explicitly stated in the transcript — do not infer, assume, or invent any clinical details. \
        If the transcript contains insufficient medical content to populate a section, omit that section entirely.

        Return a JSON object with exactly two fields:
        - "title": a 3–6 word appointment title (e.g. "Annual physical exam", "Back pain follow-up", "Diabetes management visit")
        - "summary": a markdown-formatted medical summary using ## section headers

        Only include summary sections where information was actually mentioned:
        ## Chief Complaint
        ## Symptoms
        ## Diagnoses / Conditions
        ## Medications
        ## Treatment Plan
        ## Vaccinations
        ## Allergies
        ## Tests & Labs Ordered
        ## Follow-up
        """

        let userPrompt = "Summarize this medical appointment transcript:\n\n\(localSession.transcript)"

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
        struct SummaryPayload: Decodable { let title: String; let summary: String }

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60

        let body = ChatRequest(
            model: "gpt-4o-mini",
            messages: [
                Msg(role: "system", content: systemPrompt),
                Msg(role: "user", content: userPrompt)
            ],
            response_format: ResponseFormat(type: "json_object"),
            max_tokens: 1500,
            temperature: 0.2
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
                summaryState = .failed(msg ?? "Server error (\(http.statusCode)). Check your API key in Settings.")
                return
            }

            guard
                let chatResponse = try? JSONDecoder().decode(ChatResponse.self, from: data),
                let content = chatResponse.choices.first?.message.content,
                let contentData = content.data(using: .utf8),
                let payload = try? JSONDecoder().decode(SummaryPayload.self, from: contentData)
            else {
                summaryState = .failed("Could not parse summary response. Try again.")
                return
            }

            let summaryText = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleText = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !summaryText.isEmpty else {
                summaryState = .failed("The model returned an empty summary. Try again.")
                return
            }

            // Persist title and summary so they never need to be regenerated.
            localSession.summary = summaryText
            if !titleText.isEmpty { localSession.title = titleText }
            let sessionToSave = localSession
            try? await store.upsert(sessionToSave)

            summaryState = .loaded(summaryText)

        } catch {
            summaryState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }
}

// MARK: - Supporting Types

private enum DetailTab: Hashable {
    case transcription, summary
}

private enum SummaryState {
    case idle
    case loading
    case loaded(String)
    case failed(String)
}

// MARK: - Summary Cards (Apple Health style)

private struct SummaryCardsView: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                SummaryCategoryCard(title: section.title, content: section.content)
            }
        }
        .padding(.horizontal)
    }

    private struct SummarySection {
        let title: String
        let content: String
    }

    private var sections: [SummarySection] {
        var result: [SummarySection] = []
        var currentTitle: String? = nil
        var currentLines: [String] = []

        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") || t.hasPrefix("# ") {
                if let title = currentTitle {
                    result.append(SummarySection(title: title, content: currentLines.joined(separator: "\n")))
                }
                currentTitle = t.hasPrefix("## ") ? String(t.dropFirst(3)) : String(t.dropFirst(2))
                currentLines = []
            } else if !t.isEmpty {
                currentLines.append(t)
            }
        }

        if let title = currentTitle {
            result.append(SummarySection(title: title, content: currentLines.joined(separator: "\n")))
        }

        return result
    }
}

private struct SummaryCategoryCard: View {
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row: icon + category label
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(categoryColor.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Image(systemName: categoryIcon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(categoryColor)
                }
                Text(title.uppercased())
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
            }

            // Content — bullet list or plain text
            if hasBullets {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(bulletItems, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(Color.primary.opacity(0.35))
                                .frame(width: 5, height: 5)
                                .padding(.top, 7)
                            Text(item)
                                .font(.body)
                        }
                    }
                }
            } else {
                Text(content)
                    .font(.body)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var hasBullets: Bool {
        content.components(separatedBy: "\n")
            .contains { $0.hasPrefix("- ") || $0.hasPrefix("• ") || $0.hasPrefix("* ") }
    }

    private var bulletItems: [String] {
        content.components(separatedBy: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") { return String(t.dropFirst(2)) }
            if t.hasPrefix("• ") { return String(t.dropFirst(2)) }
            if t.hasPrefix("* ") { return String(t.dropFirst(2)) }
            if t.isEmpty { return nil }
            return t
        }
    }

    private var categoryIcon: String {
        let lower = title.lowercased()
        if lower.contains("chief") || lower.contains("complaint") { return "stethoscope" }
        if lower.contains("symptom") { return "waveform.path.ecg" }
        if lower.contains("diagnos") || lower.contains("condition") { return "cross.case.fill" }
        if lower.contains("medication") { return "pills.fill" }
        if lower.contains("treatment") { return "heart.text.square.fill" }
        if lower.contains("vaccination") { return "syringe.fill" }
        if lower.contains("allerg") { return "exclamationmark.shield.fill" }
        if lower.contains("test") || lower.contains("lab") { return "doc.text.magnifyingglass" }
        if lower.contains("follow") { return "calendar.badge.clock" }
        return "doc.text.fill"
    }

    private var categoryColor: Color {
        let lower = title.lowercased()
        if lower.contains("chief") || lower.contains("complaint") { return .blue }
        if lower.contains("symptom") { return .orange }
        if lower.contains("diagnos") || lower.contains("condition") { return .red }
        if lower.contains("medication") { return .purple }
        if lower.contains("treatment") { return .green }
        if lower.contains("vaccination") { return .teal }
        if lower.contains("allerg") { return .yellow }
        if lower.contains("test") || lower.contains("lab") { return .indigo }
        if lower.contains("follow") { return .cyan }
        return .gray
    }
}
