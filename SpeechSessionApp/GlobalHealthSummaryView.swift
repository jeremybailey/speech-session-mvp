import SwiftUI
import SpeechSessionFeatures
import SpeechSessionPersistence

// MARK: - ScopedHealthSummaryView

/// Health summary for **All entries** (App Group cache) or a **single folder** (`SessionFolder` cache).
/// Pushed from the pinned “Summary” row on `HomeView` — no separate tab.
struct ScopedHealthSummaryView: View {
    let scope: EntryListScope
    @ObservedObject var home: HomeViewModel
    let store: SessionStore

    @EnvironmentObject private var kindeAuth: KindeAuthManager
    @AppStorage("speechSession.openaiAPIKey") private var openAIAPIKey = ""
    @AppStorage("speechSession.summaryBackend") private var summaryBackendRaw = "openai"
    @AppStorage("speechSession.globalSummaryJSON") private var cachedGlobalJSON = ""
    @AppStorage("speechSession.globalSummaryBackend") private var cachedGlobalBackendRaw = ""

    @State private var summaryState: ScopedSummaryState = .idle

    private var scopedSessions: [Session] {
        switch scope {
        case .all:
            return home.sessions
        case .folder(let id):
            return home.sessions.filter { $0.folderID == id }
        }
    }

    private var folderRecord: SessionFolder? {
        guard case .folder(let id) = scope else { return nil }
        return home.folders.first { $0.id == id }
    }

    /// Drives `.task` when on-disk / AppStorage cache metadata changes.
    private var cacheIdentityToken: String {
        switch scope {
        case .all:
            return "all|\(cachedGlobalBackendRaw)|\(cachedGlobalJSON.count)"
        case .folder(let id):
            let f = home.folders.first { $0.id == id }
            return "folder|\(id.uuidString)|\(f?.cachedSummaryBackend ?? "")|\(f?.cachedSummaryJSON?.count ?? 0)"
        }
    }

    var body: some View {
        Group {
            if scopedSessions.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle("Summary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let payload = sharePayload {
                    ShareLink(item: payload.text, subject: Text(payload.subject)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await clearScopeCacheAndRegenerate() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || scopedSessions.isEmpty)
            }
        }
        .task(id: cacheIdentityToken) {
            await home.loadSessions()
            await restoreOrGenerate()
        }
        .onChange(of: selectedSummaryBackendRaw) { _, _ in
            Task { await clearScopeCacheAndRegenerate() }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch summaryState {
                case .idle:
                    EmptyView()
                case .loading:
                    loadingCard
                case .loaded(let payload):
                    summaryCards(for: payload)
                case .failed(let message):
                    errorCard(message: message)
                }

                CareTimelineCard(sessions: scopedSessions)
            }
            .padding(.vertical)
            .padding(.horizontal)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "heart.text.square")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text(scope == .all ? "No entries yet" : "No entries in this folder")
                .font(.headline)
            Text(scope == .all
                ? "Record an appointment to build a health summary."
                : "Move or create entries here, then open Summary again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().scaleEffect(0.9)
            Text("Building health summary across \(scopedSessions.count) entr\(scopedSessions.count == 1 ? "y" : "ies")…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.red)
                }
                Text("SUMMARY UNAVAILABLE")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
            }
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Try Again") {
                summaryState = .idle
                Task { await generateSummary() }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func summaryCards(for payload: GlobalSummaryPayload) -> some View {
        ForEach(payload.nonemptyDisplaySections, id: \.title) { row in
            SummaryCategoryCard(title: row.title, content: row.content)
        }
    }

    // MARK: - Share

    private var sharePayload: (text: String, subject: String)? {
        guard case .loaded(let payload) = summaryState else { return nil }
        guard !scopedSessions.isEmpty else { return nil }

        var parts: [String] = []

        let sections = payload.nonemptyDisplaySections
        if !sections.isEmpty {
            parts.append("Medical summary — \(scopeShareLabel)")
            for section in sections {
                parts.append("")
                parts.append(section.title.uppercased())
                parts.append(section.content)
            }
        }

        parts.append("")
        parts.append("Care timeline")
        for session in scopedSessions {
            let dateLabel = session.date.formatted(date: .abbreviated, time: .shortened)
            let line: String
            if let title = session.title {
                line = "• \(dateLabel) — \(title)"
            } else if !session.transcript.isEmpty {
                let snippet = session.transcript
                    .split(whereSeparator: \.isNewline)
                    .first
                    .map(String.init) ?? String(session.transcript.prefix(120))
                line = "• \(dateLabel) — \(snippet)"
            } else {
                line = "• \(dateLabel) — Untitled entry"
            }
            parts.append(line)
        }

        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let count = scopedSessions.count
        let subject = "Health Summary — \(scopeShareLabel) (\(count) entr\(count == 1 ? "y" : "ies"))"
        return (text, subject)
    }

    private var scopeShareLabel: String {
        switch scope {
        case .all:
            return "All entries"
        case .folder(let id):
            return home.folders.first { $0.id == id }?.name ?? "Folder"
        }
    }

    // MARK: - Cache + generation

    private var isLoading: Bool {
        if case .loading = summaryState { return true }
        return false
    }

    private var selectedSummaryBackendRaw: String {
        summaryBackendRaw == "onDevice" && isOnDeviceSummaryAvailable ? "onDevice" : "openai"
    }

    private var isOnDeviceSummaryAvailable: Bool {
        if #available(iOS 26.0, *) {
            return OnDeviceSummaryService.isAvailable
        }
        return false
    }

    private func clearGlobalAppStorageCache() {
        cachedGlobalJSON = ""
        cachedGlobalBackendRaw = ""
    }

    private func restoreOrGenerate() async {
        guard !scopedSessions.isEmpty else {
            summaryState = .idle
            return
        }

        switch scope {
        case .all:
            if cachedGlobalBackendRaw == selectedSummaryBackendRaw,
               !cachedGlobalJSON.isEmpty,
               let data = cachedGlobalJSON.data(using: .utf8),
               let cached = try? JSONDecoder().decode(GlobalSummaryPayload.self, from: data) {
                summaryState = .loaded(cached)
            } else {
                await generateSummary()
            }
        case .folder(let id):
            guard let folder = home.folders.first(where: { $0.id == id }),
                  let json = folder.cachedSummaryJSON, !json.isEmpty,
                  folder.cachedSummaryBackend == selectedSummaryBackendRaw,
                  let data = json.data(using: .utf8),
                  let cached = try? JSONDecoder().decode(GlobalSummaryPayload.self, from: data)
            else {
                await generateSummary()
                return
            }
            summaryState = .loaded(cached)
        }
    }

    private func clearScopeCacheAndRegenerate() async {
        switch scope {
        case .all:
            clearGlobalAppStorageCache()
        case .folder(let id):
            guard var folder = home.folders.first(where: { $0.id == id }) else { break }
            folder.cachedSummaryJSON = nil
            folder.cachedSummaryBackend = nil
            try? await store.upsertFolder(folder)
            await home.loadSessions()
        }
        summaryState = .idle
        await generateSummary()
    }

    private static let minimumTotalWords = 30

    private func tooShortMessage() -> String {
        switch scope {
        case .all:
            return "Entries are too short to summarize. Record more appointment content and try again."
        case .folder:
            return "Entries in this folder are too short to summarize yet."
        }
    }

    private func generateSummary() async {
        guard case .idle = summaryState else { return }
        guard !scopedSessions.isEmpty else { return }

        let totalWords = scopedSessions.reduce(0) { $0 + $1.transcript.split(separator: " ").count }
        guard totalWords >= Self.minimumTotalWords else {
            summaryState = .failed(tooShortMessage())
            return
        }

        summaryState = .loading

        if summaryBackendRaw == "onDevice", !isOnDeviceSummaryAvailable {
            summaryBackendRaw = "openai"
        }

        if selectedSummaryBackendRaw == "onDevice" {
            await generateSummaryOnDevice()
            return
        }

        await generateSummaryOpenAI()
    }

    private func entryBlocks() -> String {
        scopedSessions.enumerated().map { i, session -> String in
            let dateLabel = session.date.formatted(date: .abbreviated, time: .shortened)
            let heading = session.title.map { "\($0) — \(dateLabel)" } ?? dateLabel
            let transcript = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            // Prefer raw transcript so rollup summaries are not starved after a compressed per-entry summary omits details.
            let body = transcript.isEmpty ? (session.summary ?? "") : transcript
            return "=== Entry \(i + 1): \(heading) ===\n\(body)"
        }.joined(separator: "\n\n")
    }

    private func systemPromptForOpenAI() -> String {
        let count = scopedSessions.count
        let intro: String
        switch scope {
        case .all:
            intro = """
            You are a medical scribe synthesizing a longitudinal health profile across \
            \(count) appointment\(count == 1 ? "" : "s").
            """
        case .folder:
            let name = folderRecord?.name ?? "this folder"
            intro = """
            You are a medical scribe synthesizing a longitudinal health profile for the folder "\(name)" across \
            \(count) appointment\(count == 1 ? "" : "s").
            """
        }

        return """
        \(intro)
        Review all provided entry data and create a comprehensive cross-visit health overview.
        Only include information explicitly stated — do not infer or invent clinical details.
        Omit any JSON field where there is no relevant information across the entries.

        LONGITUDINAL CATEGORY RULES:
        - carePlans: Consolidate ALL clinician-directed treatment and planning (medication changes/initiation, \
        referrals, procedures, therapies, devices, clinical lifestyle/diet instructions from the care team, patient \
        education, care coordination). Prefer carePlans over biopsychosocialContext for any actionable clinical plan.
        - followUp: Scheduling and return logistics only (when to return, call-backs)—not the substantive treatment plan.
        - biopsychosocialContext: ONLY non-clinical psychosocial / life context (stress, bereavement, housing, finances, \
        support systems, broad mental health themes). Never place referrals, medication plans, procedures, or clinician \
        orders here; those belong in carePlans, medications, or testsAndLabs.

        Return a JSON object with only the fields that have content:
        - "chiefComplaint": a concise longitudinal overview of the main problems, reasons for care, and presenting concerns \
        across visits—the high-level "why" tying entries together—not a verbatim list of labels from every visit unless needed
        - "symptoms": consolidated current and historical symptoms across all visits
        - "diagnoses": findings from diagnosed conditions, confirmed medical history, and clinically relevant observations
        - "medications": current medication list (prioritise most recent entry data)
        - "carePlans": ongoing treatment and care plans mentioned across visits (see rules above)
        - "vaccinations": vaccination history explicitly mentioned
        - "allergies": known allergies and adverse reactions
        - "testsAndLabs": ordered, pending, or completed tests and labs
        - "followUp": scheduling/return actions (see rules above)
        - "biopsychosocialContext": ONLY psychosocial life context (see rules above)
        - "otherNotes": important details that never fit the categories above (omit if empty; do not duplicate other fields)

        Format each field as a markdown bulleted list (- item) when multiple items exist, \
        or a single sentence when there is only one item.
        For "medications", prefer a JSON array of objects with keys name (required), strength, frequency, route, duration, instructions, classOrCategory—use classOrCategory only when explicitly stated for that drug in the entries.
        """
    }

    private var cloudOpenAINotConfiguredMessage: String {
        var s = "Sign in under Settings → Account to use cloud summaries. Your organization must configure the proxy API URL."
        #if DEBUG
        s += " In debug builds you can paste an OpenAI API key in Settings."
        #endif
        return s
    }

    private func generateSummaryOpenAI() async {
        guard let transport = await kindeAuth.openAIChatTransport(byokFallback: openAIAPIKey) else {
            summaryState = .failed(cloudOpenAINotConfiguredMessage)
            return
        }

        let systemPrompt = systemPromptForOpenAI()
        let userPrompt = "Synthesise a health summary from these appointments:\n\n\(entryBlocks())"

        struct Msg: Encodable { let role: String; let content: String }
        struct ResponseFormat: Encodable { let type: String }
        struct ChatRequest: Encodable {
            let model: String; let messages: [Msg]
            let response_format: ResponseFormat; let max_tokens: Int; let temperature: Double
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
        req.timeoutInterval = 90

        let body = ChatRequest(
            model: "gpt-4o-mini",
            messages: [
                Msg(role: "system", content: systemPrompt),
                Msg(role: "user", content: userPrompt),
            ],
            response_format: ResponseFormat(type: "json_object"),
            max_tokens: 2000,
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
                let chat = try? JSONDecoder().decode(ChatResponse.self, from: data),
                let content = chat.choices.first?.message.content,
                let contentData = content.data(using: .utf8)
            else {
                summaryState = .failed("Could not read the API response. Try again.")
                return
            }

            let payloadDecoder = JSONDecoder()
            payloadDecoder.keyDecodingStrategy = .convertFromSnakeCase

            guard let payload = try? payloadDecoder.decode(GlobalSummaryPayload.self, from: contentData) else {
                let preview = String(content.prefix(300))
                summaryState = .failed("Could not parse the summary JSON. Raw response:\n\n\(preview)")
                return
            }
            var hydrated = payload
            hydrated.hydrateMedicationsIfNeeded(from: contentData)

            await persistCache(hydrated)
            summaryState = .loaded(hydrated)

        } catch {
            summaryState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }

    private func generateSummaryOnDevice() async {
        guard #available(iOS 26.0, *) else {
            summaryState = .failed("On-device health summaries require iOS 26.0 or later.")
            return
        }
        guard OnDeviceSummaryService.isAvailable else {
            summaryState = .failed(OnDeviceSummaryService.unavailabilityReason)
            return
        }

        let count = scopedSessions.count
        let scopeLine: String
        switch scope {
        case .all:
            scopeLine = "Create a longitudinal health summary across \(count) appointment\(count == 1 ? "" : "s")."
        case .folder:
            let name = folderRecord?.name ?? "this folder"
            scopeLine = "Create a longitudinal health summary for folder \"\(name)\" across \(count) appointment\(count == 1 ? "" : "s")."
        }

        let prompt = """
        \(scopeLine)
        Only include information explicitly stated in the provided entry data.

        LONGITUDINAL CATEGORY RULES: Put actionable clinical plans in carePlans, not biopsychosocialContext. \
        followUp is for scheduling only. biopsychosocialContext is for non-clinical life/psychosocial context only.

        Return a JSON object using only these keys when relevant:
        chiefComplaint, symptoms, diagnoses, medications, carePlans, vaccinations, allergies, testsAndLabs, followUp, biopsychosocialContext, otherNotes.
        Prefer a JSON array of medication objects (name required; optional strength, frequency, route, duration, instructions, classOrCategory) when multiple drugs appear—never infer classOrCategory from drug names alone.
        Use markdown bullet lists for fields with multiple items.

        Entry data:

        \(entryBlocks())
        """

        do {
            let payload = try await OnDeviceSummaryService().generateGlobalSummary(prompt: prompt)
            await persistCache(payload)
            summaryState = .loaded(payload)
        } catch {
            summaryState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }

    private func persistCache(_ payload: GlobalSummaryPayload) async {
        guard let encoded = try? JSONEncoder().encode(payload),
              let json = String(data: encoded, encoding: .utf8) else { return }

        switch scope {
        case .all:
            cachedGlobalJSON = json
            cachedGlobalBackendRaw = selectedSummaryBackendRaw
        case .folder(let id):
            guard var folder = home.folders.first(where: { $0.id == id }) else { return }
            folder.cachedSummaryJSON = json
            folder.cachedSummaryBackend = selectedSummaryBackendRaw
            try? await store.upsertFolder(folder)
            await home.loadSessions()
        }
    }
}

// MARK: - ScopedSummaryState

private enum ScopedSummaryState {
    case idle
    case loading
    case loaded(GlobalSummaryPayload)
    case failed(String)
}
