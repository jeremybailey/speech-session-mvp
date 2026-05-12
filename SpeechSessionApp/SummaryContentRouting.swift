import Foundation

// MARK: - Kind

/// High-level classification for how to frame single-entry summarization (visit vs document-derived text).
enum SummaryContentKind: String, Codable, Sendable, CaseIterable {
    case visitEncounter = "visit_encounter"
    case carePlanEducation = "care_plan_education"
    case medicationReference = "medication_reference"
    case personalJournal = "personal_journal"
    case mixedOther = "mixed_other"

    init(rawUnstable string: String) {
        let key = string
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        if let k = SummaryContentKind(rawValue: key) {
            self = k
            return
        }
        if key.contains("journal") || key.contains("diary") || key.contains("personal_journal") {
            self = .personalJournal
            return
        }
        if key.contains("visit") || key.contains("encounter") || key.contains("conversation") {
            self = .visitEncounter
            return
        }
        if key.contains("care") || key.contains("education") || key.contains("handout") || key.contains("plan") {
            self = .carePlanEducation
            return
        }
        if key.contains("med") || key.contains("prescription") || key.contains("pharmacy") || key.contains("drug") {
            self = .medicationReference
            return
        }
        self = .mixedOther
    }
}

// MARK: - OpenAI classification

enum OpenAISummaryContentClassifier {
    private static let maxSnippetChars = 14_000

    static func classificationSnippet(from transcript: String) -> String {
        if transcript.count <= maxSnippetChars { return transcript }
        return String(transcript.prefix(maxSnippetChars)) + "\n\n[… remainder omitted for classification …]"
    }

    /// Lightweight JSON classification call (`gpt-4o-mini`).
    static func classify(transcript: String, transport: OpenAIChatTransport) async throws -> SummaryContentKind {
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
        struct KindPayload: Decodable {
            let contentKind: String

            enum CodingKeys: String, CodingKey {
                case contentKind = "content_kind"
            }
        }

        let systemPrompt = """
        You classify health-related source text before it is summarized. \
        Respond with JSON ONLY using this shape: {"content_kind":"<label>"}. \
        Allowed labels (exactly one):
        - visit_encounter — dialogue, visit note, clinical conversation, or prose clearly from a single encounter.
        - care_plan_education — care plans, discharge/education handouts, disease information sheets, long-term planning documents.
        - medication_reference — primarily medication or prescription lists with little other narrative.
        - personal_journal — first-person reflection, diary-style health journaling, not a clinical encounter note.
        - mixed_other — blends types, administrative text, or cannot decide confidently.

        Pick the single best label from the text alone. If unclear, use mixed_other.
        """

        let body = transcript.count > maxSnippetChars
            ? classificationSnippet(from: transcript)
            : transcript

        let userPrompt = "Classify this health-related text:\n\n\(body)"

        var req = URLRequest(url: transport.chatCompletionsURL)
        req.httpMethod = "POST"
        req.setValue(try await transport.makeAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 45

        let chatBody = ChatRequest(
            model: "gpt-4o-mini",
            messages: [
                Msg(role: "system", content: systemPrompt),
                Msg(role: "user", content: userPrompt),
            ],
            response_format: ResponseFormat(type: "json_object"),
            max_tokens: 80,
            temperature: 0
        )
        req.httpBody = try JSONEncoder().encode(chatBody)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClassifierError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw ClassifierError.http(http.statusCode) }

        guard
            let chatResponse = try? JSONDecoder().decode(ChatResponse.self, from: data),
            let content = chatResponse.choices.first?.message.content,
            let payloadData = extractJSONObjectData(from: content),
            let payload = try? JSONDecoder().decode(KindPayload.self, from: payloadData)
        else {
            return .mixedOther
        }
        return SummaryContentKind(rawUnstable: payload.contentKind)
    }

    private static func extractJSONObjectData(from raw: String) -> Data? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = t.data(using: .utf8), d.first == "{".utf8.first { return d }
        guard let lo = t.firstIndex(of: "{"), let hi = t.lastIndex(of: "}") else { return nil }
        return String(t[lo...hi]).data(using: .utf8)
    }

    enum ClassifierError: Error {
        case badResponse
        case http(Int)
    }
}

// MARK: - Prompt bundles (OpenAI + shared wording for on-device)

enum SummaryPromptAssembly {
    /// System prompt and user **prefix**; caller must append the full source text.
    static func openAISummaryPrompts(contentKind: SummaryContentKind) -> (system: String, userPrefix: String) {
        let systemBody = baseSystemInstruction(contentKind: contentKind)
            + "\n\n"
            + VisitSummaryPromptGuidance.structuredJSONSpec(for: contentKind)
            + "\n"
            + categoryRules(for: contentKind)

        let userPrefix = userPromptLead(contentKind: contentKind)
        return (systemBody, userPrefix)
    }

    /// Instructions for on-device structured visit summary (full transcript appended by caller).
    static func onDeviceSessionInstructions(contentKind: SummaryContentKind) -> String {
        let base = baseSystemInstruction(contentKind: contentKind)
        let rules = categoryRules(for: contentKind)
        return """
        \(base)

        \(VisitSummaryPromptGuidance.structuredJSONSpec(for: contentKind))

        Populate ONLY the structured fields your run mode provides; leave a field absent/empty instead of hallucinating filler.

        \(rules)
        """
    }

    static func onDeviceUserPromptLead(contentKind: SummaryContentKind) -> String {
        userPromptLead(contentKind: contentKind)
    }

    private static func userPromptLead(contentKind: SummaryContentKind) -> String {
        switch contentKind {
        case .visitEncounter:
            return "Summarize this medical appointment transcript:\n\n"
        case .carePlanEducation:
            return "Summarize this health document (care plan, education, or reference material). Source text:\n\n"
        case .medicationReference:
            return "Summarize this medication or prescription-related document. Source text:\n\n"
        case .personalJournal:
            return "Summarize this personal health journal entry for the author’s own records. Source text:\n\n"
        case .mixedOther:
            return "Summarize this health-related text (may mix topics or be unclear). Source text:\n\n"
        }
    }

    private static func baseSystemInstruction(contentKind: SummaryContentKind) -> String {
        switch contentKind {
        case .visitEncounter:
            return """
            You are a medical scribe reviewing an appointment transcript. \
            Extract only clinically relevant information. \
            Ignore all greetings, small talk, and scheduling chatter unless it belongs under followUp as explicit return/callback logistics. \
            Only include details explicitly stated — do not infer, assume, or invent clinical facts. \
            Omit any JSON keys where there is no relevant transcript content.
            """
        case .carePlanEducation:
            return """
            You are a medical scribe summarizing health-related DOCUMENT text (care plan, patient education handout, \
            disease or treatment information, discharge instructions, or similar). \
            This is NOT assumed to be live dialogue from a single in-person visit unless the text clearly is. \
            Extract only clinically relevant information explicitly stated in the source. \
            Do not invent a visit narrative, a chief complaint, or symptoms that are not clearly supported by the text. \
            Omit any JSON keys where there is no relevant content.
            """
        case .medicationReference:
            return """
            You are summarizing text that is primarily a MEDICATION list, prescription printout, or pharmacy-related document. \
            Prioritize medications (names, strengths, directions, changes), allergies if listed, and prescriber instructions. \
            Use other section keys only when the source clearly supports them. \
            Do not invent clinical visits, chief complaints, or findings not stated. \
            Omit any JSON keys where there is no relevant content.
            """
        case .personalJournal:
            return """
            You are organizing a PERSONAL health journal entry someone recorded for themselves. \
            It is not a clinical visit note and not professional documentation. \
            Respect their own words: capture themes and concrete health-related details they mention without inventing an office visit, \
            provider exam, or billing-style structure. \
            Do not infer clinical facts they did not say. Omit any JSON keys where there is no supporting content.
            """
        case .mixedOther:
            return """
            You are summarizing health-related text that may combine multiple formats (education, lists, narrative notes, \
            administrative wording) or where the document type is unclear. \
            Extract only information explicitly stated; do not assume this was a single office visit. \
            Prefer leaving chiefComplaint, symptoms, or followUp empty unless the source clearly supports those headings. \
            Omit any JSON keys where there is no relevant content.
            """
        }
    }

    private static func categoryRules(for contentKind: SummaryContentKind) -> String {
        switch contentKind {
        case .visitEncounter:
            return """
            CATEGORY RULES (apply strictly):
            \(VisitSummaryPromptGuidance.categoryRoutingRules)
            """
        case .personalJournal:
            return """
            CATEGORY RULES (personal journal — not a clinical encounter):
            - Chief Complaint: Use only if the author clearly names a main worry, focus, or problem in their narrative.
            - Symptoms: Feelings, symptoms, side effects, or concerns they describe about themselves in first person.
            - Findings: Sparingly—conditions, diagnoses, or test results they state as facts about themselves (not your interpretation).
            - Medications: Drugs, doses, or changes they mention.
            - Treatment Plan: Self-care, habits, goals, reminders, or instructions they recall or plan—not a “visit plan” unless they said so.
            - Follow-up: Only appointments, calls, or dates they explicitly mention.
            - Allergies / Vaccinations / Tests & Labs: Only when explicitly stated.
            """
        case .carePlanEducation, .mixedOther:
            return """
            CATEGORY RULES (health document — not assumed to be a single visit):
            - Treatment Plan: Patient education, self-management, lifestyle/diet/activity instructions, goals, warning signs, \
            care steps, and clinician-directed actions described in the document. Prefer this over stretching content into Symptoms.
            - Findings: Stated diagnoses, conditions, problem lists, or examination/impression lines given as facts in the source.
            - Medications: Drugs, doses, changes—only what the document lists.
            - Chief Complaint / Symptoms: Include only when clearly stated as patient concerns—not from brochure titles alone.
            - Allergies / Tests & Labs / Vaccinations: Populate only when explicitly present.
            - Follow-up: ONLY explicit scheduling, return visits, call timing, or deadlines mentioned in the document—not generic advice.
            """
        case .medicationReference:
            return """
            CATEGORY RULES (medication-focused document):
            - Medications: Highest priority—output one row per drug in structured form when using on-device generation; \
            for cloud JSON, use a medications array of objects (name required; optional strength, frequency, route, duration, instructions, classOrCategory). \
            Put classOrCategory ONLY when the source explicitly states it for that same drug—never infer from the drug name.
            - Allergies: Include if present.
            - Treatment Plan: Use for prescriber/pharmacist directions that are narrative (tapers, monitoring, indication) when written \
            beyond bullets; do not duplicate the entire med table.
            - Findings / Chief Complaint / Symptoms: Omit unless the source explicitly ties indications or diagnoses to the list.
            - Follow-up: Only when the document states refill, lab, or return-plan logistics.
            - Tests & Labs / Vaccinations: Only when explicitly tied to the medication context in the source.
            - otherNotes: Only for details that do not fit the fields above; no duplication.
            """
        }
    }
}
