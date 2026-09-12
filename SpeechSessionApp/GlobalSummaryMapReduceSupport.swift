import Foundation
import SpeechSessionPersistence

// MARK: - Map-phase sizing (OpenAI vs Apple on-device)

/// Input budgets for longitudinal **map** steps. On-device Foundation Models use a much smaller context than cloud chat models.
struct RollupMapLimits: Sendable {
    let maxEntriesPerBatch: Int
    let maxCharsPerBatch: Int
    let maxEntryBodyCharacters: Int
    let entryHeadCharacters: Int
    let entryTailCharacters: Int

    static let openAI = RollupMapLimits(
        maxEntriesPerBatch: 6,
        maxCharsPerBatch: 16_000,
        maxEntryBodyCharacters: 10_000,
        entryHeadCharacters: 6_500,
        entryTailCharacters: 3_000
    )

    /// Tight limits: few card digests per map call so session instructions + user prompt fit the on-device window.
    static let onDevice = RollupMapLimits(
        maxEntriesPerBatch: 3,
        maxCharsPerBatch: 4_800,
        maxEntryBodyCharacters: 3_200,
        entryHeadCharacters: 2_200,
        entryTailCharacters: 800
    )
}

// MARK: - Chronological batching (map phase input sizing)

enum GlobalSummaryRollupBatching {
    static func chronologicalSessions(_ sessions: [Session]) -> [Session] {
        sessions.sorted { $0.date < $1.date }
    }

    /// Prefer visit cards (user-corrected), then cached visit markdown, then transcript — clipped for rollup prompts.
    static func clippedEntryBody(transcript: String, summary: String?, limits: RollupMapLimits) -> String {
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmedSummary.isEmpty ? trimmedTranscript : trimmedSummary
        return clip(raw, limits: limits)
    }

    /// Compact Health Summary map input: stacked visit cards when present, else summary/transcript.
    static func overviewSourceBody(session: Session, limits: RollupMapLimits) -> String {
        let liveCards = (session.summaryEntries ?? []).filter { !$0.isDeleted }
        if !liveCards.isEmpty {
            let digest = liveCards.map { entry in
                let line = [entry.title, entry.details].filter { !$0.isEmpty }.joined(separator: " — ")
                return "- [\(entry.category.displayTitle)] \(line) (\(entry.clinicalStatus.rawValue))"
            }.joined(separator: "\n")
            return clip(digest, limits: limits)
        }
        return clippedEntryBody(transcript: session.transcript, summary: session.summary, limits: limits)
    }

    private static func clip(_ raw: String, limits: RollupMapLimits) -> String {
        let maxBody = limits.maxEntryBodyCharacters
        let headN = limits.entryHeadCharacters
        let tailN = limits.entryTailCharacters
        guard raw.count > maxBody else { return raw }

        guard raw.count > headN + tailN else {
            return String(raw.prefix(maxBody)) + "\n\n[… remainder truncated for length …]"
        }

        let head = String(raw.prefix(headN))
        let tail = String(raw.suffix(tailN))
        let omitted = raw.count - headN - tailN
        return "\(head)\n\n[… \(omitted) characters omitted …]\n\n\(tail)"
    }

    /// One `=== Entry n: … ===` block; `displayIndex` is 1-based in the overall rollup.
    static func entryBlock(session: Session, displayIndex: Int, limits: RollupMapLimits) -> String {
        let dateLabel = session.date.formatted(date: .abbreviated, time: .shortened)
        let heading = session.title.map { "\($0) — \(dateLabel)" } ?? dateLabel
        let body = overviewSourceBody(session: session, limits: limits)
        return "=== Entry \(displayIndex): \(heading) ===\n\(body)"
    }

    static func entryBlocks(for batch: [Session], globalStartingIndex: Int, limits: RollupMapLimits) -> String {
        batch.enumerated().map { offset, session in
            entryBlock(session: session, displayIndex: globalStartingIndex + offset, limits: limits)
        }.joined(separator: "\n\n")
    }

    /// Greedy batches: chronological order, then pack by entry cap and character budget.
    static func batches(for sessionsChronological: [Session], limits: RollupMapLimits) -> [[Session]] {
        guard !sessionsChronological.isEmpty else { return [] }
        var result: [[Session]] = []
        var current: [Session] = []
        var currentCharCount = 0

        for session in sessionsChronological {
            let probeIndex = 1
            let block = entryBlock(session: session, displayIndex: probeIndex, limits: limits)
            let delta = block.utf8.count + 2

            let wouldExceedEntries = !current.isEmpty && current.count >= limits.maxEntriesPerBatch
            let wouldExceedChars = !current.isEmpty && currentCharCount + delta > limits.maxCharsPerBatch

            if wouldExceedEntries || wouldExceedChars {
                result.append(current)
                current = []
                currentCharCount = 0
            }
            current.append(session)
            currentCharCount += delta
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}

// MARK: - Shared prompt fragments (OpenAI + human-readable reduce input)

enum GlobalSummaryLongitudinalPrompts {
    /// Overview-only JSON (Health Summary cards stay visit-stacked; this payload is the paragraph).
    static let categoryRulesAndJSONSchema = """
    Return a JSON object with a single field:
    - "overview": ONE short plain-English paragraph (about 2–4 sentences) that sets clinical context for this patient— \
    who they are in care terms and the main ongoing themes. Not a category dump, not bullet lists, not first-person spoken script. \
    Facts only from the entries. Do not invent clinical details. Do not repeat every card; synthesize.

    Omit any other keys. Prefer current/ongoing themes; mention resolved items only when they still shape care.
    """
}

// MARK: - OpenAI chat (JSON object response)

enum GlobalSummaryOpenAIClient {
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

    enum ClientError: LocalizedError {
        case invalidResponse
        case httpStatus(Int, String?)
        case noAssistantContent

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid server response."
            case .httpStatus(let code, let message):
                return message ?? "Server error (\(code)). Try signing in again under Settings."
            case .noAssistantContent:
                return "Could not read the API response. Try again."
            }
        }
    }

    private static let model = "gpt-4o-mini"

    static func requestJSONObject(
        transport: OpenAIChatTransport,
        system: String,
        user: String,
        maxTokens: Int,
        timeout: TimeInterval = 120
    ) async throws -> String {
        var req = URLRequest(url: transport.chatCompletionsURL)
        req.httpMethod = "POST"
        req.setValue(try await transport.makeAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout

        let body = ChatRequest(
            model: model,
            messages: [
                Msg(role: "system", content: system),
                Msg(role: "user", content: user),
            ],
            response_format: ResponseFormat(type: "json_object"),
            max_tokens: maxTokens,
            temperature: 0
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode(APIErr.self, from: data))?.error?.message
            throw ClientError.httpStatus(http.statusCode, msg)
        }

        guard
            let chat = try? JSONDecoder().decode(ChatResponse.self, from: data),
            let content = chat.choices.first?.message.content,
            !content.isEmpty
        else { throw ClientError.noAssistantContent }

        return content
    }
}
