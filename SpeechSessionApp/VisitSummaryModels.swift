import Foundation

// MARK: - Shared field aggregation (OpenAI decode + on-device structured output → markdown)

/// Optional section fields for a single-visit summary. Used to build markdown with fixed ## headers only.
struct VisitSummaryFields {
    var title: String?
    /// Legacy API shape: single markdown blob (used if structured sections are all empty).
    var legacyMarkdownSummary: String?

    var chiefComplaint: String?
    var symptoms: String?
    var findings: String?
    var medications: String?
    var treatmentPlan: String?
    var vaccinations: String?
    var allergies: String?
    var testsAndLabs: String?
    var followUp: String?

    /// Ordered (heading, body) pairs — must match prompts and section headers in SummaryCategoryCard heuristics.
    private static let sectionSpecs: [(heading: String, keyPath: KeyPath<VisitSummaryFields, String?>)] = [
        ("Chief Complaint", \.chiefComplaint),
        ("Symptoms", \.symptoms),
        ("Findings", \.findings),
        ("Medications", \.medications),
        ("Treatment Plan", \.treatmentPlan),
        ("Vaccinations", \.vaccinations),
        ("Allergies", \.allergies),
        ("Tests & Labs Ordered", \.testsAndLabs),
        ("Follow-up", \.followUp),
    ]

    /// Markdown with only non-empty sections; no extra ## headers.
    func markdownFromStructuredSections() -> String {
        Self.sectionSpecs.compactMap { spec -> String? in
            guard let raw = self[keyPath: spec.keyPath]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return "## \(spec.heading)\n\(raw)"
        }.joined(separator: "\n\n")
    }

    /// Prefer structured sections; fall back to legacy markdown if present.
    func resolved(defaultTitle: String) -> (title: String, markdown: String)? {
        let structured = markdownFromStructuredSections()
        if !structured.isEmpty {
            let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.flatMap { $0.isEmpty ? nil : $0 } ?? defaultTitle, structured)
        }
        if let leg = legacyMarkdownSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !leg.isEmpty {
            let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.flatMap { $0.isEmpty ? nil : $0 } ?? defaultTitle, leg)
        }
        return nil
    }
}

// MARK: - OpenAI JSON decode

/// Decodes structured visit summary plus optional legacy `summary` markdown (combined blob).
/// Use `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` when decoding API responses.
struct VisitSummaryOpenAIResponse: Codable {
    var title: String?
    /// Legacy combined markdown field (used only when no structured section keys have content).
    var summary: String?
    var chiefComplaint: String?
    var symptoms: String?
    var findings: String?
    var medications: String?
    var treatmentPlan: String?
    var vaccinations: String?
    var allergies: String?
    var testsAndLabs: String?
    var followUp: String?

    var fields: VisitSummaryFields {
        VisitSummaryFields(
            title: title,
            legacyMarkdownSummary: summary,
            chiefComplaint: chiefComplaint,
            symptoms: symptoms,
            findings: findings,
            medications: medications,
            treatmentPlan: treatmentPlan,
            vaccinations: vaccinations,
            allergies: allergies,
            testsAndLabs: testsAndLabs,
            followUp: followUp
        )
    }
}

// MARK: - Resilient OpenAI response parsing

/// Chat models sometimes violate the schema (arrays/objects for medications, fenced JSON, synonym keys).
/// Prefer strict decoding, then recover via `JSONSerialization` + coercion into `VisitSummaryFields`.
enum VisitSummaryJSONParser {

    /// Parse `choices[0].message.content` from chat/completions into fields consumable by `resolved(defaultTitle:)`.
    static func fields(fromAssistantContent raw: String) -> VisitSummaryFields? {
        let fenced = sanitizeFencedJSON(raw)
        let proseStripped = extractJSONObjectFragment(fenced.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = proseStripped.data(using: .utf8), !proseStripped.isEmpty else { return nil }

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        if let typed = try? dec.decode(VisitSummaryOpenAIResponse.self, from: data) {
            return typed.fields
        }
        return flexibleFields(fromJSONObjectData: data)
    }

    /// If the model prefixed JSON with commentary, isolate `{ ... }` for parsing.
    private static func extractJSONObjectFragment(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.first == "{" { return t }
        guard let lo = t.firstIndex(of: "{"),
              let hi = t.lastIndex(of: "}") else {
            return t
        }
        return String(t[lo...hi])
    }

    private static func sanitizeFencedJSON(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        // Drop first line (``` or ```json)
        if let nl = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: nl)...])
        }
        if let range = s.range(of: "```", options: .backwards) {
            s = String(s[..<range.lowerBound])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func flexibleFields(fromJSONObjectData data: Data) -> VisitSummaryFields? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func value(matching synonyms: Set<String>) -> Any? {
            let normSyns = Set(synonyms.map { normalizeJSONKey($0) })
            for (key, val) in obj {
                if normSyns.contains(normalizeJSONKey(key)) {
                    return val
                }
            }
            return nil
        }

        func str(_ synonyms: Set<String>) -> String? {
            coerceOpenAIJSONValue(value(matching: synonyms))
        }

        let title = str(["title", "appointment_title"])
        let legacySummary = str(["summary"])
        let chiefComplaint = str(["chiefcomplaint", "chief_complaint", "reason_for_visit"])
        let symptoms = str(["symptoms", "symptom"])
        let findings = str(["findings", "diagnoses", "diagnosis"])
        let medications = str([
            "medications",
            "medication",
            "meds",
            "drugs",
            "prescription",
            "prescriptions",
            "rx",
            "medicine",
            "medicines",
        ])
        let treatmentPlan = str(["treatmentplan", "treatment_plan", "plan_of_care", "care_plan"])
        let vaccinations = str(["vaccinations", "vaccination"])
        let allergies = str(["allergies", "allergy"])
        let testsAndLabs = str(["testsandlabs", "tests_and_labs", "labs", "tests", "imaging"])
        let followUp = str(["followup", "follow_up", "follow-up"])

        return VisitSummaryFields(
            title: title,
            legacyMarkdownSummary: legacySummary,
            chiefComplaint: chiefComplaint,
            symptoms: symptoms,
            findings: findings,
            medications: medications,
            treatmentPlan: treatmentPlan,
            vaccinations: vaccinations,
            allergies: allergies,
            testsAndLabs: testsAndLabs,
            followUp: followUp
        )
    }

    private static func normalizeJSONKey(_ key: String) -> String {
        key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
    }

    /// Turn arbitrary JSON fragment into scribe text (strings, arrays of strings/objects, single objects).
    private static func coerceOpenAIJSONValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let arr = value as? [Any] {
            let lines = arr.compactMap { coerceOpenAIJSONValue($0) }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { return nil }
            return lines.count == 1
                ? lines[0]
                : lines.map { $0.hasPrefix("- ") ? $0 : "- \($0)" }.joined(separator: "\n")
        }
        if let dict = value as? [String: Any] {
            let parts = dict.keys.sorted().compactMap { key -> String? in
                guard let v = coerceOpenAIJSONValue(dict[key]), !v.isEmpty else { return nil }
                return "\(key): \(v)"
            }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: "\n")
        }
        if let n = value as? NSNumber {
            let t = n.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if value is NSNull {
            return nil
        }
        let t = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Prompt text (shared wording for visit-level instructions)

enum VisitSummaryPromptGuidance {
    /// Routing rules appended to visit-level system instructions (OpenAI + on-device).
    static let categoryRoutingRules = """
    CATEGORY RULES (apply strictly):
    - Treatment Plan: Put ALL clinician-directed plans and actions here: medication changes or new prescriptions \
    discussed as today’s plan, referrals, procedures, imaging/therapy orders, device or equipment instructions, \
    lifestyle or diet recommendations from the clinician, patient education, home exercises, care coordination, \
    and any “we will / you should / start / continue / taper” clinical instructions. \
    Do not bury those items only under Symptoms or Findings unless they are purely diagnostic labels with \
    no plan attached.
    - Follow-up: Use ONLY for scheduling and return logistics (when to return, phone follow-up timing, booking \
    the next appointment, “see you in 6 weeks”). Do not place the substantive treatment plan solely in Follow-up; \
    duplicate a brief scheduling line here if needed, but the clinical plan stays in Treatment Plan.
    - Findings: Use for stated diagnoses, impressions, examination results—not for the ordered plan \
    unless the transcript only states an isolated label with no actionable plan elsewhere.
    - Medications: List drug names/doses/adherence explicitly mentioned; if a NEW medication is STARTED as part \
    of today’s plan, summarize it briefly in Medications AND keep the clinician’s prescribing intent under Treatment Plan.
    """

    /// Forbid extra JSON keys / markdown headings on visit summaries.
    static let structuredOutputConstraint = """
    Output format: Respond with JSON ONLY. Include "title" (3–6 words). Include ONLY these optional keys \
    when relevant (omit keys with no content): chiefComplaint, symptoms, findings, medications, treatmentPlan, \
    vaccinations, allergies, testsAndLabs, followUp. Each value MUST be a JSON string OR a JSON array of strings \
    (arrays of small JSON objects are allowed for multi-line items like prescription labels). Prefer "- item" bullets \
    inside strings when possible. Use the section keys for clinical content rather than inventing new top-level keys \
    for the same information. A legacy "summary" markdown field is acceptable only when every section key would be empty.

    """
}
