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
        maxEntriesPerBatch: 2,
        maxCharsPerBatch: 16_000,
        maxEntryBodyCharacters: 10_000,
        entryHeadCharacters: 6_500,
        entryTailCharacters: 3_000
    )

    /// Tight limits: one entry per map call so session instructions + user prompt fit the on-device window.
    static let onDevice = RollupMapLimits(
        maxEntriesPerBatch: 1,
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

    /// Raw transcript when present, else cached summary — clipped for rollup prompts.
    static func clippedEntryBody(transcript: String, summary: String?, limits: RollupMapLimits) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? (summary ?? "") : trimmed
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
        let transcript = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = clippedEntryBody(transcript: transcript, summary: session.summary, limits: limits)
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
    /// Category rules + JSON field list (matches prior `systemPromptForOpenAI` body).
    static let categoryRulesAndJSONSchema = """
    LONGITUDINAL CATEGORY RULES:
    - carePlans: Consolidate ALL clinician-directed treatment and planning (medication changes/initiation, \
    referrals, procedures, therapies, devices, clinical lifestyle/diet instructions from the care team, patient \
    education, care coordination). Prefer carePlans over biopsychosocialContext for any actionable clinical plan.
    - followUp: Scheduling and return logistics only (when to return, call-backs)—not the substantive treatment plan.
    - biopsychosocialContext: ONLY non-clinical psychosocial / life context (stress, bereavement, housing, finances, \
    support systems, broad mental health themes). Never place referrals, medication plans, procedures, or clinician \
    orders here; those belong in carePlans, medications, or testsAndLabs.
    - practitionerContacts: one contact per line or array item. Include a person/organization name plus role, phone, fax, email, URL, \
    or address ONLY when that detail is explicitly tied to the same printed/source block. Do not attach contact text from one printed block \
    to a person or org named in another entry or section (e.g. never pair a **psychologist** named in therapy content with a **pharmacy address** from an Rx in a different entry). \
    Omit first-name-only dialogue mentions and missing details.

    Return a JSON object with only the fields that have content:
    - "overview": ONE short plain-English paragraph (about 2–4 sentences) that sets clinical context for this patient— \
    who they are in care terms and the main ongoing themes. Not a category dump, not bullet lists, not first-person spoken script. \
    Facts only from the entries. Details belong in the other fields.
    - "chiefComplaint": presenting concerns grouped by body system. Use `###` headings from \
    \(BodySystem.promptAllowedList), then one bullet per distinct complaint. Prefer short stable titles \
    (e.g. "Migraine") with severity, triggers, course, or treatment response after an em dash. No narrative paragraph.
    - "symptoms": consolidated current and historical symptoms across all visits. Prefer short stable titles \
    with detail after an em dash (severity, triggers, course) so the same symptom can be compared across visits.
    - "diagnoses": findings from diagnosed conditions, confirmed medical history, and clinically relevant observations. Prefer short stable titles with detail after an em dash.
    - "medications": current medication list (prioritise most recent entry data). Prefer drug name as the title; dose/frequency/notes after an em dash or in structured objects.
    - "carePlans": ongoing treatment and care plans mentioned across visits (see rules above). Prefer short stable plan titles with detail after an em dash.
    - "practitionerContacts": one contact per line or array item. Preserve explicitly tied contact fields from the same source block; do not invent missing fields.
    - "vaccinations": vaccination history explicitly mentioned
    - "allergies": known allergies and adverse reactions
    - "testsAndLabs": ordered, pending, or completed tests and labs. Prefer short stable test names with detail after an em dash.
    - "followUp": scheduling/return actions (see rules above)
    - "biopsychosocialContext": ONLY psychosocial life context (see rules above)
    - "otherNotes": important details that never fit the categories above (omit if empty; do not duplicate other fields)

    Format each string field as one item per distinct source, event, provider, medication, or care-plan entry. Use markdown bullets. \
    For "overview", keep a single continuous paragraph. For "chiefComplaint", bullets must sit under body-system headings. \
    Prefer short repeatable titles across visits so identical facts can stack.
    For "medications", prefer a JSON array of objects with keys name (required), strength, frequency, route, duration, instructions, classOrCategory—use classOrCategory only when explicitly stated for that drug in the entries.
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
