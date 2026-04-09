import SwiftUI
import SpeechSessionFeatures
import SpeechSessionPersistence

// MARK: - GlobalHealthSummaryView

struct GlobalHealthSummaryView: View {
    @ObservedObject var home: HomeViewModel
    let store: SessionStore

    @AppStorage("speechSession.openaiAPIKey") private var openAIAPIKey = ""
    /// Cached JSON string of the last successful GlobalSummaryPayload.
    @AppStorage("speechSession.globalSummaryJSON") private var cachedJSON = ""

    @State private var summaryState: GlobalSummaryState = .idle

    var body: some View {
        NavigationStack {
            Group {
                if home.sessions.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("Health Summary")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        cachedJSON = ""
                        summaryState = .idle
                        Task { await generateSummary() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading || home.sessions.isEmpty)
                }
            }
        }
        .task {
            await home.loadSessions()
            // Restore from cache, or kick off generation.
            if !cachedJSON.isEmpty,
               let data = cachedJSON.data(using: .utf8),
               let cached = try? JSONDecoder().decode(GlobalSummaryPayload.self, from: data) {
                summaryState = .loaded(cached)
            } else {
                await generateSummary()
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Care Timeline — always built from session data, no API call needed.
                CareTimelineCard(sessions: home.sessions)

                // AI-generated cross-session cards.
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
            }
            .padding(.vertical)
            .padding(.horizontal)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: State views

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("No sessions yet")
                .font(.headline)
            Text("Record your first appointment to start building your health summary.")
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
            Text("Building health summary across \(home.sessions.count) session\(home.sessions.count == 1 ? "" : "s")…")
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
        let entries: [(title: String, content: String?)] = [
            ("Symptoms",                  payload.symptoms),
            ("Diagnoses / Conditions",    payload.diagnoses),
            ("Medications",               payload.medications),
            ("Care Plans",                payload.carePlans),
            ("Vaccinations",              payload.vaccinations),
            ("Allergies",                 payload.allergies),
            ("Tests & Labs",              payload.testsAndLabs),
            ("Follow-up",                 payload.followUp),
            ("Biopsychosocial Context",   payload.biopsychosocialContext),
        ]
        ForEach(entries.filter { !($0.content ?? "").isEmpty }, id: \.title) { entry in
            SummaryCategoryCard(title: entry.title, content: entry.content!)
        }
    }

    // MARK: - Helpers

    private var isLoading: Bool {
        if case .loading = summaryState { return true }
        return false
    }

    // MARK: - Summary Generation

    private static let minimumTotalWords = 30

    private func generateSummary() async {
        guard case .idle = summaryState else { return }
        guard !home.sessions.isEmpty else { return }

        let totalWords = home.sessions.reduce(0) { $0 + $1.transcript.split(separator: " ").count }
        guard totalWords >= Self.minimumTotalWords else {
            summaryState = .failed("Sessions are too short to summarize. Record more appointment content and try again.")
            return
        }

        let key = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            summaryState = .failed("Add an OpenAI API key in Settings to generate your health summary.")
            return
        }

        summaryState = .loading

        // Build session context — prefer the generated summary, fall back to raw transcript.
        let sessionBlocks = home.sessions.enumerated().map { i, session -> String in
            let dateLabel = session.date.formatted(date: .abbreviated, time: .shortened)
            let heading = session.title.map { "\($0) — \(dateLabel)" } ?? dateLabel
            let body = session.summary ?? session.transcript
            return "=== Session \(i + 1): \(heading) ===\n\(body)"
        }.joined(separator: "\n\n")

        let systemPrompt = """
        You are a medical scribe synthesizing a longitudinal health profile across \
        \(home.sessions.count) appointment\(home.sessions.count == 1 ? "" : "s").
        Review all provided session data and create a comprehensive cross-visit health overview.
        Only include information explicitly stated — do not infer or invent clinical details.
        Omit any JSON field where there is no relevant information across the sessions.

        Return a JSON object with only the fields that have content:
        - "symptoms": consolidated current and historical symptoms across all visits
        - "diagnoses": all diagnosed conditions and confirmed medical history
        - "medications": current medication list (prioritise most recent session data)
        - "carePlans": ongoing treatment and care plans mentioned across visits
        - "vaccinations": vaccination history explicitly mentioned
        - "allergies": known allergies and adverse reactions
        - "testsAndLabs": ordered, pending, or completed tests and labs
        - "followUp": upcoming or recommended follow-up actions
        - "biopsychosocialContext": psychosocial and life-context factors mentioned \
        across sessions (e.g. work stress, bereavement, family changes, housing, \
        social support, financial pressures, mental health themes)

        Format each field as a markdown bulleted list (- item) when multiple items exist, \
        or a single sentence when there is only one item.
        """

        let userPrompt = "Synthesise a health summary from these appointments:\n\n\(sessionBlocks)"

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

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
                let chat = try? JSONDecoder().decode(ChatResponse.self, from: data),
                let content = chat.choices.first?.message.content,
                let contentData = content.data(using: .utf8)
            else {
                summaryState = .failed("Could not read the API response. Try again.")
                return
            }

            // Accept both camelCase and snake_case keys from the model.
            let payloadDecoder = JSONDecoder()
            payloadDecoder.keyDecodingStrategy = .convertFromSnakeCase

            guard let payload = try? payloadDecoder.decode(GlobalSummaryPayload.self, from: contentData) else {
                let preview = String(content.prefix(300))
                summaryState = .failed("Could not parse the summary JSON. Raw response:\n\n\(preview)")
                return
            }

            // Persist to cache.
            if let encoded = try? JSONEncoder().encode(payload),
               let json = String(data: encoded, encoding: .utf8) {
                cachedJSON = json
            }
            summaryState = .loaded(payload)

        } catch {
            summaryState = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }
}

// MARK: - GlobalSummaryPayload

/// The model sometimes returns a plain string, sometimes a JSON array of strings.
/// This struct handles both by normalising arrays into "- item" bullet strings.
struct GlobalSummaryPayload: Codable {
    var symptoms: String?
    var diagnoses: String?
    var medications: String?
    var carePlans: String?
    var vaccinations: String?
    var allergies: String?
    var testsAndLabs: String?
    var followUp: String?
    var biopsychosocialContext: String?

    enum CodingKeys: String, CodingKey {
        case symptoms, diagnoses, medications, carePlans, vaccinations
        case allergies, testsAndLabs, followUp, biopsychosocialContext
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symptoms               = c.decodeFlexible(.symptoms)
        diagnoses              = c.decodeFlexible(.diagnoses)
        medications            = c.decodeFlexible(.medications)
        carePlans              = c.decodeFlexible(.carePlans)
        vaccinations           = c.decodeFlexible(.vaccinations)
        allergies              = c.decodeFlexible(.allergies)
        testsAndLabs           = c.decodeFlexible(.testsAndLabs)
        followUp               = c.decodeFlexible(.followUp)
        biopsychosocialContext = c.decodeFlexible(.biopsychosocialContext)
    }
}

private extension KeyedDecodingContainer {
    /// Decodes a key that may arrive as a `String` or `[String]`.
    /// Arrays are joined as "- item\n- item" bullet lines.
    func decodeFlexible(_ key: Key) -> String? {
        if let str = try? decode(String.self, forKey: key), !str.isEmpty { return str }
        if let arr = try? decode([String].self, forKey: key), !arr.isEmpty {
            return arr.map { "- \($0)" }.joined(separator: "\n")
        }
        return nil
    }
}

// MARK: - GlobalSummaryState

private enum GlobalSummaryState {
    case idle
    case loading
    case loaded(GlobalSummaryPayload)
    case failed(String)
}

// MARK: - CareTimelineCard

private struct CareTimelineCard: View {
    let sessions: [Session]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                Text("CARE TIMELINE")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
            }

            // Timeline entries
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    HStack(alignment: .top, spacing: 14) {
                        // Dot + connecting line
                        VStack(spacing: 0) {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 9, height: 9)
                                .padding(.top, 4)
                            if index < sessions.count - 1 {
                                Rectangle()
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: 2)
                                    .frame(minHeight: 28)
                            }
                        }
                        .frame(width: 9)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let title = session.title {
                                Text(title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            } else if !session.transcript.isEmpty {
                                Text(session.transcript)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text("Untitled session")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .italic()
                            }
                        }
                        .padding(.bottom, index < sessions.count - 1 ? 14 : 0)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
