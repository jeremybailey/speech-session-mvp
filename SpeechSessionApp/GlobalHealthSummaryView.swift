import SwiftUI
import SpeechSessionFeatures
import SpeechSessionPersistence

private enum OnDeviceSummaryMergeError: Error {
    case emptyLayer
}

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandPalette.canvas)
        .navigationTitle("Summary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandPalette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
        .background(BrandPalette.canvas)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            VStack(spacing: 14) {
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
                    .padding(.horizontal, 12)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .liquidGlassCard(cornerRadius: 18)
            .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .summaryGlassCard(cornerRadius: 14)
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(BrandPalette.systemRed.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(BrandPalette.systemRed)
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
        .summaryGlassCard(cornerRadius: 14)
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

    private func rollupScopeIntro(totalAppointments: Int) -> String {
        switch scope {
        case .all:
            return "You are a medical scribe synthesizing a longitudinal health profile across \(totalAppointments) appointment\(totalAppointments == 1 ? "" : "s")."
        case .folder:
            let name = folderRecord?.name ?? "this folder"
            return "You are a medical scribe synthesizing a longitudinal health profile for the folder \"\(name)\" across \(totalAppointments) appointment\(totalAppointments == 1 ? "" : "s")."
        }
    }

    private func openAIMapSystemPrompt(batchIndex: Int, totalBatches: Int, totalAppointments: Int) -> String {
        let intro = rollupScopeIntro(totalAppointments: totalAppointments)
        if totalBatches == 1 {
            return """
            \(intro)
            Review all provided entry data and create a comprehensive cross-visit health overview.
            Only include information explicitly stated — do not infer or invent clinical details.
            Omit any JSON field where there is no relevant information across the entries.

            \(GlobalSummaryLongitudinalPrompts.categoryRulesAndJSONSchema)
            """
        }
        return """
        \(intro)
        You are working on time-window batch \(batchIndex) of \(totalBatches) (entries are ordered oldest to newest across the full record). \
        Only include facts explicitly stated in the entry data in this message—not from other batches. \
        Produce a partial longitudinal JSON summary for ONLY these visits, using the same schema as the final merged summary. \
        Omit JSON keys with no relevant content in this batch.

        \(GlobalSummaryLongitudinalPrompts.categoryRulesAndJSONSchema)
        """
    }

    private func openAIReduceSystemPrompt(totalBatches: Int, totalAppointments: Int) -> String {
        let intro = rollupScopeIntro(totalAppointments: totalAppointments)
        return """
        \(intro)
        You are merging \(totalBatches) partial JSON summar\(totalBatches == 1 ? "y" : "ies") into ONE consolidated longitudinal health overview. Each input is valid JSON with the same schema you must output. \
        Inputs are given in time order (oldest partial first). Merge them: deduplicate overlapping facts; when timelines conflict, prefer the most recent clinical information. \
        Only include information present in the partials—do not invent details. Omit empty JSON fields.

        \(GlobalSummaryLongitudinalPrompts.categoryRulesAndJSONSchema)
        """
    }

    /// Pairwise tree reduce so each API call only merges two (or one orphan) partials—stays within context limits.
    private func openAIReducePartialJSONsPairwise(
        transport: OpenAIChatTransport,
        partials: [String],
        totalAppointments: Int
    ) async throws -> String {
        var layer = partials
        while layer.count > 1 {
            try Task.checkCancellation()
            var next: [String] = []
            var i = 0
            while i < layer.count {
                if i + 1 < layer.count {
                    let merged = try await openAIReduceOneGroup(
                        transport: transport,
                        partialJSONs: [layer[i], layer[i + 1]],
                        totalAppointments: totalAppointments
                    )
                    next.append(merged)
                    i += 2
                } else {
                    next.append(layer[i])
                    i += 1
                }
            }
            layer = next
        }
        guard let single = layer.first else {
            throw GlobalSummaryOpenAIClient.ClientError.noAssistantContent
        }
        return single
    }

    private func openAIReduceOneGroup(
        transport: OpenAIChatTransport,
        partialJSONs: [String],
        totalAppointments: Int
    ) async throws -> String {
        let reduceSys = openAIReduceSystemPrompt(
            totalBatches: partialJSONs.count,
            totalAppointments: totalAppointments
        )
        let reduceUser = partialJSONs.enumerated().map { i, json in
            "Partial summary \(i + 1) of \(partialJSONs.count) (consecutive time windows, oldest first):\n\(json)"
        }.joined(separator: "\n\n---\n\n")
        return try await GlobalSummaryOpenAIClient.requestJSONObject(
            transport: transport,
            system: reduceSys,
            user: reduceUser,
            maxTokens: 3500
        )
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

        let mapLimits = RollupMapLimits.openAI
        let ordered = GlobalSummaryRollupBatching.chronologicalSessions(scopedSessions)
        let batches = GlobalSummaryRollupBatching.batches(for: ordered, limits: mapLimits)
        let total = scopedSessions.count

        do {
            var partialJSONStrings: [String] = []
            var globalIndex = 1
            for (bIdx, batch) in batches.enumerated() {
                try Task.checkCancellation()
                let blocks = GlobalSummaryRollupBatching.entryBlocks(for: batch, globalStartingIndex: globalIndex, limits: mapLimits)
                globalIndex += batch.count
                let sys = openAIMapSystemPrompt(
                    batchIndex: bIdx + 1,
                    totalBatches: batches.count,
                    totalAppointments: total
                )
                let user = """
                Synthesize a health summary from these appointment entries (batch \(bIdx + 1) of \(batches.count)):

                \(blocks)
                """
                let content = try await GlobalSummaryOpenAIClient.requestJSONObject(
                    transport: transport,
                    system: sys,
                    user: user,
                    maxTokens: 2000
                )
                partialJSONStrings.append(content)
            }

            let finalContent: String
            if partialJSONStrings.count == 1 {
                finalContent = partialJSONStrings[0]
            } else {
                try Task.checkCancellation()
                finalContent = try await openAIReducePartialJSONsPairwise(
                    transport: transport,
                    partials: partialJSONStrings,
                    totalAppointments: total
                )
            }

            try Task.checkCancellation()
            guard let contentData = finalContent.data(using: .utf8) else {
                summaryState = .failed("Could not read the API response. Try again.")
                return
            }
            let payloadDecoder = JSONDecoder()
            payloadDecoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let payload = try? payloadDecoder.decode(GlobalSummaryPayload.self, from: contentData) else {
                let preview = String(finalContent.prefix(300))
                summaryState = .failed("Could not parse the summary JSON. Raw response:\n\n\(preview)")
                return
            }
            var hydrated = payload
            hydrated.hydrateMedicationsIfNeeded(from: contentData)

            await persistCache(hydrated)
            summaryState = .loaded(hydrated)

        } catch is CancellationError {
            summaryState = .idle
        } catch let clientError as GlobalSummaryOpenAIClient.ClientError {
            summaryState = .failed(clientError.localizedDescription)
        } catch {
            summaryState = .failed(error.localizedDescription)
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
        let baseScopeLine: String
        switch scope {
        case .all:
            baseScopeLine = "Create a longitudinal health summary across \(count) appointment\(count == 1 ? "" : "s")."
        case .folder:
            let name = folderRecord?.name ?? "this folder"
            baseScopeLine = "Create a longitudinal health summary for folder \"\(name)\" across \(count) appointment\(count == 1 ? "" : "s")."
        }

        let mapLimits = RollupMapLimits.onDevice
        let ordered = GlobalSummaryRollupBatching.chronologicalSessions(scopedSessions)
        let batches = GlobalSummaryRollupBatching.batches(for: ordered, limits: mapLimits)

        do {
            var partials: [GlobalSummaryPayload] = []
            var globalIndex = 1
            for (bIdx, batch) in batches.enumerated() {
                try Task.checkCancellation()
                let blocks = GlobalSummaryRollupBatching.entryBlocks(for: batch, globalStartingIndex: globalIndex, limits: mapLimits)
                globalIndex += batch.count

                let scopeLine: String
                if batches.count == 1 {
                    scopeLine = baseScopeLine
                } else {
                    scopeLine = "\(baseScopeLine) Batch \(bIdx + 1) of \(batches.count), oldest first; facts from entry data only."
                }

                // Category rules and output shape live in `LanguageModelSession` instructions / `GlobalSummaryOutput`; keep user prompt tight for on-device context limits.
                let prompt = """
                \(scopeLine)

                \(blocks)
                """

                let partial = try await OnDeviceSummaryService().generateGlobalSummary(prompt: prompt)
                partials.append(partial)
            }

            let finalPayload: GlobalSummaryPayload
            if partials.count == 1 {
                finalPayload = partials[0]
            } else {
                try Task.checkCancellation()
                finalPayload = try await onDeviceMergePayloadsPairwise(partials)
            }

            await persistCache(finalPayload)
            summaryState = .loaded(finalPayload)
        } catch is CancellationError {
            summaryState = .idle
        } catch {
            summaryState = .failed(error.localizedDescription)
        }
    }

    /// Tree-shaped merges (pairs) so each on-device call stays within context limits.
    @available(iOS 26.0, *)
    private func onDeviceMergePayloadsPairwise(_ payloads: [GlobalSummaryPayload]) async throws -> GlobalSummaryPayload {
        var layer = payloads
        while layer.count > 1 {
            try Task.checkCancellation()
            var next: [GlobalSummaryPayload] = []
            var i = 0
            while i < layer.count {
                if i + 1 < layer.count {
                    let merged = try await onDeviceMergePayloadPair(older: layer[i], newer: layer[i + 1])
                    next.append(merged)
                    i += 2
                } else {
                    next.append(layer[i])
                    i += 1
                }
            }
            layer = next
        }
        guard let single = layer.first else {
            throw OnDeviceSummaryMergeError.emptyLayer
        }
        return single
    }

    @available(iOS 26.0, *)
    private func onDeviceMergePayloadPair(
        older: GlobalSummaryPayload,
        newer: GlobalSummaryPayload
    ) async throws -> GlobalSummaryPayload {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let olderData = try encoder.encode(older)
        let newerData = try encoder.encode(newer)
        let olderJSON = String(data: olderData, encoding: .utf8) ?? "{}"
        let newerJSON = String(data: newerData, encoding: .utf8) ?? "{}"

        let reducePrompt = """
        Merge two partial JSON longitudinal summaries into ONE profile. Partial 1 is the older time window; Partial 2 is newer. \
        Deduplicate overlapping items. When timelines conflict, prefer Partial 2. Only use facts present in the JSON below.

        Partial 1 (older):
        \(olderJSON)

        Partial 2 (newer):
        \(newerJSON)
        """

        return try await OnDeviceSummaryService().generateGlobalSummary(prompt: reducePrompt)
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
