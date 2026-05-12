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
    /// Information that matters but does not fit any other section; do not duplicate structured fields.
    var otherNotes: String?

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
        ("Other Notes", \.otherNotes),
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
    var otherNotes: String?

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
            followUp: followUp,
            otherNotes: otherNotes
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
            return mergeAlternateMedicationKeys(into: typed.fields, rawObjectData: data)
        }
        guard let merged = flexibleFields(fromJSONObjectData: data) else { return nil }
        return mergeAlternateMedicationKeys(into: merged, rawObjectData: data)
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

    private static func mergeAlternateMedicationKeys(into fields: VisitSummaryFields, rawObjectData data: Data) -> VisitSummaryFields {
        var f = fields
        let medsEmpty = f.medications?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        guard medsEmpty, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return f
        }
        if let s = coercedMedicationsString(fromTopLevelJSONObject: obj) {
            f.medications = s
        }
        return f
    }

    /// Walks common medication key spellings; coerces arrays/objects to markdown lines.
    static func coercedMedicationsString(fromTopLevelJSONObject obj: [String: Any]) -> String? {
        let orderedKeys = [
            "medications", "medication", "medicationItems", "medication_items",
            "medicationList", "med_list", "meds", "drugs", "prescription", "prescriptions",
            "rx", "medicine", "medicines",
        ]
        for want in orderedKeys {
            let nw = normalizeJSONKey(want)
            for (dictKey, val) in obj where normalizeJSONKey(dictKey) == nw {
                if let s = coerceOpenAIJSONValue(val), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return s
                }
            }
        }
        return nil
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
            "medicationitems",
            "medication_items",
            "medicationlist",
            "med_list",
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
        let otherNotes = str(["othernotes", "other_notes", "additionalnotes", "additional_notes", "misc"])

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
            followUp: followUp,
            otherNotes: otherNotes
        )
    }

    private static func normalizeJSONKey(_ key: String) -> String {
        key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
    }

    private static let medicationItemNameKeys: Set<String> = ["name", "drug", "medication", "med", "drugname"]

    private static func looksLikeMedicationItem(_ dict: [String: Any]) -> Bool {
        for key in dict.keys {
            if medicationItemNameKeys.contains(normalizeJSONKey(key)) { return true }
        }
        return false
    }

    /// Prefer one bullet per drug with stable field order so classes are not visually merged across drugs.
    private static func coerceMedicationItemDict(_ dict: [String: Any]) -> String? {
        func norm(_ key: String) -> String { normalizeJSONKey(key) }

        func stringForCanonical(_ canonicalKeys: [String]) -> String? {
            for (rawKey, rawVal) in dict {
                let nk = norm(rawKey)
                guard canonicalKeys.contains(where: { norm($0) == nk }) else { continue }
                guard let s = coerceOpenAIJSONValue(rawVal)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !s.isEmpty else { continue }
                return s
            }
            return nil
        }

        let nameKeys = ["name", "drug", "medication", "med", "drug_name"]
        guard let name = stringForCanonical(nameKeys) else { return nil }

        let orderedPairs: [(label: String, keys: [String])] = [
            ("", ["strength", "dose", "dosage", "sig", "sig_or_dose", "amount"]),
            ("", ["frequency", "scheduling", "how_often"]),
            ("", ["route"]),
            ("", ["duration"]),
            ("", ["instructions", "directions", "patient_instructions", "prescriber_instructions", "changes"]),
            ("Class (source)", ["class_or_category", "class", "category", "drug_class", "pharmacologic_class"]),
        ]

        var fragments: [String] = []
        for spec in orderedPairs {
            if let v = stringForCanonical(spec.keys) {
                if spec.label.isEmpty {
                    fragments.append(v)
                } else {
                    fragments.append("\(spec.label): \(v)")
                }
            }
        }

        let consumedNorm = Set(
            nameKeys.map { norm($0) }
                + orderedPairs.flatMap { $0.keys }.map { norm($0) }
        )
        for rawKey in dict.keys.sorted() {
            let nk = norm(rawKey)
            guard !consumedNorm.contains(nk) else { continue }
            guard let v = coerceOpenAIJSONValue(dict[rawKey]), !v.isEmpty else { continue }
            fragments.append("\(rawKey): \(v)")
        }

        let tail = fragments.filter { !$0.isEmpty }.joined(separator: "; ")
        if tail.isEmpty { return "- **\(name)**" }
        return "- **\(name)** — \(tail)"
    }

    /// Turn arbitrary JSON fragment into scribe text (strings, arrays of strings/objects, single objects).
    private static func coerceOpenAIJSONValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let arr = value as? [Any] {
            let lines = arr.compactMap { el -> String? in
                if let dict = el as? [String: Any], looksLikeMedicationItem(dict) {
                    return coerceMedicationItemDict(dict)
                }
                return coerceOpenAIJSONValue(el)
            }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { return nil }
            return lines.count == 1
                ? lines[0]
                : lines.map { $0.hasPrefix("- ") ? $0 : "- \($0)" }.joined(separator: "\n")
        }
        if let dict = value as? [String: Any] {
            if looksLikeMedicationItem(dict) { return coerceMedicationItemDict(dict) }
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

    /// Exact JSON key contract per routed `contentKind` (OpenAI `json_object`). `otherNotes` catches important residue only.
    static func structuredJSONSpec(for contentKind: SummaryContentKind) -> String {
        let commonRules = """
        Output format: Respond with JSON ONLY. Include "title" (3–6 words).
        Always include the key "otherNotes" when there is substantive information that does not fit any other allowed field; \
        otherwise omit "otherNotes" entirely. Never duplicate the same fact in otherNotes and another field. \
        Do not invent clinical facts. Copy strengths and doses verbatim from the source when given.
        Each value MUST be a JSON string OR a JSON array of strings unless this spec says otherwise for a specific key.
        A legacy "summary" markdown field is acceptable ONLY when every other section key would be empty.
        """

        switch contentKind {
        case .visitEncounter:
            return """
            \(commonRules)

            Allowed optional keys for visit dialogue/encounters (omit when empty): \
            chiefComplaint, symptoms, findings, medications, treatmentPlan, vaccinations, allergies, testsAndLabs, followUp, otherNotes.
            For medications use a string or array of strings; each line must stay tied to the drug it describes (no shared trailing class for unrelated drugs).
            """

        case .carePlanEducation:
            return """
            \(commonRules)

            Allowed optional keys for care plans & education documents (omit when empty): \
            chiefComplaint, symptoms, findings, medications, treatmentPlan, vaccinations, allergies, testsAndLabs, followUp, otherNotes.
            Prefer treatmentPlan for patient education, self-management, lifestyle, warning signs, and clinician-directed steps stated in the document.
            For medications use a string or array of strings, or an array of medication objects (see medication_reference spec for object shape).
            """

        case .medicationReference:
            return """
            \(commonRules)

            Required: "title" (3–6 words summarizing the list or document).
            Required when any drug appears: "medications" as a JSON array of objects—one object per drug—with ONLY these properties on each object \
            (omit a property rather than guessing): \
            name (required), strength, frequency, route, duration, instructions, classOrCategory.
            For classOrCategory: include ONLY if the source explicitly states a class, category, or indication for THAT same drug line. \
            Never infer pharmacologic class from the drug name (e.g. do not label drugs by textbook classification unless written in the source).
            Allowed optional top-level keys (omit when empty): allergies, treatmentPlan, testsAndLabs, vaccinations, followUp, chiefComplaint, symptoms, findings, otherNotes.
            Do not stuff free-text medication lines into otherNotes when they belong in medications[].
            Always use the exact top-level JSON key "medications" for the drug list (never medicationItems or medication_list).
            """

        case .personalJournal:
            return """
            \(commonRules)

            Allowed optional keys for personal journaling (omit when empty): \
            chiefComplaint, symptoms, findings, medications, treatmentPlan, vaccinations, allergies, testsAndLabs, followUp, otherNotes.
            treatmentPlan captures self-care intentions the author stated, not a fictional clinic visit plan.
            """

        case .mixedOther:
            return """
            \(commonRules)

            Allowed optional keys when the text blends formats (omit when empty): \
            chiefComplaint, symptoms, findings, medications, treatmentPlan, vaccinations, allergies, testsAndLabs, followUp, otherNotes.
            Use otherNotes for important details that have no natural home after applying category rules; keep otherNotes concise.
            For medications, prefer an array of per-drug objects (see medication_reference) when listing multiple drugs.
            """
        }
    }
}

// MARK: - Global summary medication hydration

extension GlobalSummaryPayload {
    /// `GlobalSummaryPayload` decodes `medications` only as `String` or `[String]`; recover object/array JSON and keys like `medicationItems`.
    mutating func hydrateMedicationsIfNeeded(from rawResponseJSONData: Data) {
        let empty = medications?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        guard empty,
              let obj = try? JSONSerialization.jsonObject(with: rawResponseJSONData) as? [String: Any],
              let s = VisitSummaryJSONParser.coercedMedicationsString(fromTopLevelJSONObject: obj) else { return }
        medications = s
    }
}
