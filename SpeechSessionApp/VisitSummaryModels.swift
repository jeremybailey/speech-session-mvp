import Foundation
import SpeechSessionPersistence

// MARK: - Body systems (chief complaints)

/// Organ systems used to group chief complaints. Names match the labels we ask the model to emit.
enum BodySystem: String, CaseIterable, Hashable, Identifiable, Sendable {
    case neurological
    case nervous
    case digestive
    case immune
    case lymphatic
    case urinary
    case musculoskeletal
    case cardiovascular
    case respiratory
    case endocrine
    case integumentary
    case reproductive
    case mentalHealth
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neurological: return "Neurological"
        case .nervous: return "Nervous"
        case .digestive: return "Digestive"
        case .immune: return "Immune"
        case .lymphatic: return "Lymphatic"
        case .urinary: return "Urinary"
        case .musculoskeletal: return "Musculoskeletal"
        case .cardiovascular: return "Cardiovascular"
        case .respiratory: return "Respiratory"
        case .endocrine: return "Endocrine"
        case .integumentary: return "Integumentary"
        case .reproductive: return "Reproductive"
        case .mentalHealth: return "Mental health"
        case .other: return "Other"
        }
    }

    static let fieldLabel = "Body system"

    static var promptAllowedList: String {
        allCases.filter { $0 != .other }.map(\.displayName).joined(separator: ", ") + ", Other"
    }

    static func parse(_ raw: String?) -> BodySystem? {
        guard let raw else { return nil }
        let n = normalizeLabel(raw)
        guard !n.isEmpty else { return nil }
        switch n {
        case "neurological", "neurologic", "neuro", "cns", "central nervous":
            return .neurological
        case "nervous", "peripheral nervous", "pns":
            return .nervous
        case "digestive", "gastrointestinal", "gi", "gastro":
            return .digestive
        case "immune", "immunologic", "immunological":
            return .immune
        case "lymphatic", "lymph":
            return .lymphatic
        case "urinary", "renal", "genitourinary", "gu", "kidney", "urologic":
            return .urinary
        case "musculoskeletal", "musculo skeletal", "msk", "ortho", "orthopedic":
            return .musculoskeletal
        case "cardiovascular", "cardiac", "heart", "cv":
            return .cardiovascular
        case "respiratory", "pulmonary", "lung":
            return .respiratory
        case "endocrine", "hormonal":
            return .endocrine
        case "integumentary", "skin", "dermatologic", "dermatological":
            return .integumentary
        case "reproductive", "gynecologic", "gynaecologic", "obgyn":
            return .reproductive
        case "mental health", "psychiatric", "psych", "behavioral":
            return .mentalHealth
        case "other", "unspecified", "general":
            return .other
        default:
            return allCases.first { normalizeLabel($0.displayName) == n }
        }
    }

    /// Group raw chief-complaint markdown/lines under body systems.
    static func groupedLines(from raw: String) -> [(system: BodySystem, lines: [String])] {
        var current: BodySystem?
        var buckets: [BodySystem: [String]] = [:]

        for original in raw.components(separatedBy: "\n") {
            let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let heading = markdownHeading(from: trimmed) {
                current = parse(heading) ?? .other
                continue
            }
            let unmarked = stripLeadingListMarker(trimmed)
            guard !unmarked.isEmpty else { continue }
            if let labeled = splitLabeledLine(unmarked) {
                buckets[labeled.system, default: []].append(labeled.text)
                continue
            }
            let system = current ?? classify(unmarked)
            buckets[system, default: []].append(unmarked)
        }

        return allCases.compactMap { system in
            guard let lines = buckets[system], !lines.isEmpty else { return nil }
            return (system, lines)
        }
    }

    static func resolved(for entry: SummaryEntry) -> BodySystem {
        if let field = entry.fields.first(where: { $0.label.caseInsensitiveCompare(fieldLabel) == .orderedSame }) {
            if let parsed = parse(field.value) { return parsed }
        }
        let haystack = [entry.title, entry.details].joined(separator: " ")
        if let labeled = splitLabeledLine(haystack) { return labeled.system }
        return classify(haystack)
    }

    static func classify(_ text: String) -> BodySystem {
        let l = text.lowercased()

        let lymphatic = ["lymph", "lymphedema", "lymphoma", "swollen gland", "adenopathy"]
        if lymphatic.contains(where: { l.contains($0) }) { return .lymphatic }

        let immune = ["autoimmune", "immunodeficienc", "lupus", "hashimoto", "celiac", "guillain", "anaphylaxis"]
        if immune.contains(where: { l.contains($0) }) { return .immune }

        let urinary = ["urin", "bladder", "kidney", "renal", "uti", "incontinen", "prostat", "dysuria", "hematuria"]
        if urinary.contains(where: { l.contains($0) }) { return .urinary }

        let digestive = [
            "digest", "stomach", "abdom", "nause", "vomit", "diarrhea", "constipat", "gerd", "reflux",
            "heartburn", "ibs", "bowel", "intestin", "liver", "hepatic", "pancrea", "gallbladder",
            "gi ", "indigest", "crohn", "colitis", "appetite",
        ]
        if digestive.contains(where: { l.contains($0) }) { return .digestive }

        let musculoskeletal = [
            "musculo", "back pain", "low back", "joint", "arthritis", "osteo", "knee", "hip", "shoulder",
            "spine", "spinal", "fracture", "muscle", "bone", "tendon", "ligament", "fibromyalgia",
            "sciatica", "neck pain", "orthop", "sprain", "strain",
        ]
        if musculoskeletal.contains(where: { l.contains($0) }) { return .musculoskeletal }

        let nervous = ["neuropath", "nerve pain", "neuralgia", "numbness", "tingling", "paresthesia", "carpal tunnel"]
        if nervous.contains(where: { l.contains($0) }) { return .nervous }

        let neurological = [
            "neurolog", "headache", "migraine", "seizure", "stroke", "tbi", "concussion", "dizziness",
            "vertigo", "memory", "dementia", "parkinson", "multiple sclerosis", "ms ", "tremor",
            "faint", "syncope", "cognitive", "brain",
        ]
        if neurological.contains(where: { l.contains($0) }) { return .neurological }

        let cardiovascular = [
            "heart", "cardiac", "chest pain", "hypertension", "blood pressure", "palpitation",
            "afib", "arrhythm", "cholesterol", "coronary", "angina",
        ]
        if cardiovascular.contains(where: { l.contains($0) }) { return .cardiovascular }

        let respiratory = ["asthma", "cough", "lung", "shortness of breath", "dyspnea", "copd", "pneumonia", "wheez", "sinus"]
        if respiratory.contains(where: { l.contains($0) }) { return .respiratory }

        let endocrine = ["diabet", "thyroid", "hormon", "adrenal", "a1c", "insulin", "endocrin"]
        if endocrine.contains(where: { l.contains($0) }) { return .endocrine }

        let integumentary = ["skin", "rash", "eczema", "psoriasis", "lesion", "dermat", "wound", "itch"]
        if integumentary.contains(where: { l.contains($0) }) { return .integumentary }

        let reproductive = ["pregnan", "menstrual", "menopaus", "pelvic", "ovary", "uter", "gynec", "prostate cancer"]
        if reproductive.contains(where: { l.contains($0) }) { return .reproductive }

        let mental = ["depress", "anxi", "ptsd", "bipolar", "insomnia", "panic", "adhd", "mental health", "psychiatr"]
        if mental.contains(where: { l.contains($0) }) { return .mentalHealth }

        return .other
    }

    fileprivate static func normalizeLabel(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "–", with: " ")
            .replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func markdownHeading(from line: String) -> String? {
        var s = line
        if s.hasPrefix("### ") { s = String(s.dropFirst(4)) }
        else if s.hasPrefix("## ") { s = String(s.dropFirst(3)) }
        else if s.hasPrefix("# ") { s = String(s.dropFirst(2)) }
        else { return nil }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "#* ")).trimmingCharacters(in: .whitespaces)
    }

    fileprivate static func splitLabeledLine(_ line: String) -> (system: BodySystem, text: String)? {
        for sep in [": ", " — ", " – ", " - "] {
            guard let range = line.range(of: sep) else { continue }
            let label = String(line[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            guard let system = parse(label) else { continue }
            let text = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (system, text)
        }
        return nil
    }

    fileprivate static func stripLeadingListMarker(_ line: String) -> String {
        var s = line.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("- ") || s.hasPrefix("• ") || s.hasPrefix("* ") {
            s = String(s.dropFirst(2))
        } else if let range = s.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

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
    /// Person **full names** or printed org names **only** (no address/phone); sanitized after generation.
    var practitionerContacts: String?
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
        ("Care team & contacts", \.practitionerContacts),
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

// MARK: - Atomic summary entry conversion

enum SummaryEntryFactory {
    static func entries(
        from fields: VisitSummaryFields,
        session: Session,
        origin: SummaryEntryOrigin = .generated
    ) -> [SummaryEntry] {
        let specs: [(category: SummaryEntryCategory, content: String?)] = [
            (.chiefComplaint, fields.chiefComplaint),
            (.symptoms, fields.symptoms),
            (.findings, fields.findings),
            (.medications, fields.medications),
            (.carePlan, fields.treatmentPlan),
            (.practitionerContact, fields.practitionerContacts),
            (.vaccinations, fields.vaccinations),
            (.allergies, fields.allergies),
            (.testsAndLabs, fields.testsAndLabs),
            (.followUp, fields.followUp),
            (.otherNotes, fields.otherNotes),
        ]

        return specs.flatMap { spec in
            entries(
                category: spec.category,
                rawContent: spec.content,
                session: session,
                origin: origin
            )
        }
    }

    static func legacyEntries(from markdown: String, session: Session) -> [SummaryEntry] {
        var result: [SummaryEntry] = []
        var currentTitle: String?
        var currentLines: [String] = []

        func flush() {
            guard let currentTitle else { return }
            let category = category(forHeading: currentTitle)
            let raw = currentLines.joined(separator: "\n")
            result.append(contentsOf: entries(category: category, rawContent: raw, session: session, origin: .legacyImported))
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") {
                flush()
                currentTitle = trimmed.hasPrefix("## ") ? String(trimmed.dropFirst(3)) : String(trimmed.dropFirst(2))
                currentLines = []
            } else if !trimmed.isEmpty {
                currentLines.append(trimmed)
            }
        }
        flush()
        return result
    }

    static func entries(
        category: SummaryEntryCategory,
        rawContent: String?,
        session: Session,
        origin: SummaryEntryOrigin = .generated
    ) -> [SummaryEntry] {
        let lines = normalizedLines(from: rawContent)
        guard !lines.isEmpty else { return [] }

        if category == .chiefComplaint {
            return BodySystem.groupedLines(from: rawContent ?? "").flatMap { group in
                group.lines.map { line in
                    makeEntry(
                        category: category,
                        line: line,
                        bodySystem: group.system,
                        session: session,
                        origin: origin
                    )
                }
            }
        }

        return lines.map { line in
            makeEntry(
                category: category,
                line: line,
                bodySystem: nil,
                session: session,
                origin: origin
            )
        }
    }

    private static func makeEntry(
        category: SummaryEntryCategory,
        line: String,
        bodySystem: BodySystem?,
        session: Session,
        origin: SummaryEntryOrigin
    ) -> SummaryEntry {
        let split = splitPrimaryAndDetail(from: line)
        let title = split.primary
        let details = split.detail ?? ""
        let contactFields = category == .practitionerContact
            ? PractitionerContactsFormatting.editableFields(from: line)
            : []
        var baseFields = contactFields.isEmpty
            ? defaultFields(for: category, title: title, details: details, bodySystem: bodySystem)
            : contactFields
        if category == .chiefComplaint, !baseFields.contains(where: { $0.label.caseInsensitiveCompare(BodySystem.fieldLabel) == .orderedSame }) {
            let system = bodySystem ?? BodySystem.classify(line)
            baseFields.insert(
                SummaryEntryField(label: BodySystem.fieldLabel, value: system.displayName, isMissing: false, needsReview: false),
                at: 0
            )
        }
        let needsDateReview = true
        let reviewReason = needsDateReview
            ? "Confirm the actual relevant date for this information."
            : nil

        return SummaryEntry(
            category: category,
            title: title,
            details: details,
            fields: baseFields,
            relevantDate: session.date,
            dateNeedsReview: needsDateReview,
            sourceSessionID: session.id,
            sourceTitle: session.title,
            sourceDate: session.date,
            sourceExcerpt: sourceExcerpt(for: line, in: session.transcript),
            provenance: provenanceLabel(for: session),
            needsReview: needsDateReview || baseFields.contains(where: { $0.needsReview || $0.isMissing }),
            reviewReason: reviewReason,
            origin: origin
        )
    }

    private static func normalizedLines(from raw: String?) -> [String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        let split = raw.components(separatedBy: "\n")
            .map(stripLeadingListMarker)
            .filter { !$0.isEmpty }
        return split.isEmpty ? [raw] : split
    }

    private static func stripLeadingListMarker(_ line: String) -> String {
        var s = line.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("- ") || s.hasPrefix("• ") || s.hasPrefix("* ") {
            s = String(s.dropFirst(2))
        } else if let range = s.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitPrimaryAndDetail(from line: String) -> (primary: String, detail: String?) {
        for sep in [" — ", " – ", " - "] {
            if let range = line.range(of: sep) {
                let primary = line[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !primary.isEmpty {
                    return (primary, detail.isEmpty ? nil : detail)
                }
            }
        }
        return (line, nil)
    }

    private static func defaultFields(
        for category: SummaryEntryCategory,
        title: String,
        details: String,
        bodySystem: BodySystem? = nil
    ) -> [SummaryEntryField] {
        var fields: [SummaryEntryField] = []
        switch category {
        case .practitionerContact:
            return []
        case .chiefComplaint:
            let system = bodySystem ?? BodySystem.classify([title, details].joined(separator: " "))
            fields.append(
                SummaryEntryField(label: BodySystem.fieldLabel, value: system.displayName, isMissing: false, needsReview: false)
            )
        case .medications:
            if !details.isEmpty {
                fields.append(
                    SummaryEntryField(label: "Details", value: details, isMissing: false, needsReview: false)
                )
            }
        default:
            break
        }
        fields.append(
            SummaryEntryField(label: "Practitioner", value: "", isMissing: true, needsReview: true)
        )
        return fields
    }

    /// Fields for a blank user-created card (summary list hides label echoes).
    static func fieldsForNewUserEntry(category: SummaryEntryCategory) -> [SummaryEntryField] {
        switch category {
        case .practitionerContact:
            return PractitionerContactsFormatting.editableFields(from: "")
        case .chiefComplaint:
            return [
                SummaryEntryField(label: BodySystem.fieldLabel, value: BodySystem.other.displayName, isMissing: false, needsReview: true),
                SummaryEntryField(label: "Practitioner", value: "", isMissing: true, needsReview: true),
            ]
        default:
            return [
                SummaryEntryField(label: "Practitioner", value: "", isMissing: true, needsReview: true),
            ]
        }
    }

    private static func sourceExcerpt(for line: String, in transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.localizedCaseInsensitiveContains(line) {
            return line
        }
        return String(trimmed.prefix(240))
    }

    private static func provenanceLabel(for session: Session) -> String {
        let date = session.date.formatted(date: .abbreviated, time: .shortened)
        if let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return "\(title) - \(date)"
        }
        return "Source entry - \(date)"
    }

    private static func category(forHeading heading: String) -> SummaryEntryCategory {
        let l = heading.lowercased()
        if l.contains("chief") || l.contains("complaint") { return .chiefComplaint }
        if l.contains("symptom") { return .symptoms }
        if l.contains("finding") || l.contains("diagnos") { return .findings }
        if l.contains("medication") { return .medications }
        if l.contains("care plan") || l.contains("treatment") { return .carePlan }
        if l.contains("care team") || l.contains("contact") || l.contains("practitioner") { return .practitionerContact }
        if l.contains("vaccination") { return .vaccinations }
        if l.contains("allerg") { return .allergies }
        if l.contains("test") || l.contains("lab") { return .testsAndLabs }
        if l.contains("follow") { return .followUp }
        if l.contains("biopsychosocial") || l.contains("psychosocial") { return .biopsychosocialContext }
        return .otherNotes
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
    var practitionerContacts: String?
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
            practitionerContacts: practitionerContacts,
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
        let practitionerContacts = str([
            "practitionercontacts",
            "practitioner_contacts",
            "careteamcontacts",
            "care_team_contacts",
            "providercontacts",
            "provider_contacts",
            "cliniciancontacts",
            "clinician_contacts",
        ])
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
            practitionerContacts: practitionerContacts,
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
        if tail.isEmpty { return "- \(name)" }
        return "- \(name) — \(tail)"
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
    - Care team & contacts (practitionerContacts): Each line is one contact card from one source block: person or organization name, \
    role/specialty, phone, email, address, and notes ONLY when explicitly present together in that same source block. \
    **Never** pair a provider or org named in one part of the source with contact/lab/Rx text from another section or entry. \
    **Omit** first-name-only dialogue. Plain lines; omit unavailable fields rather than inventing placeholders. \
    Clinical plan prose stays under **Treatment Plan**.
    - Follow-up: Use ONLY for scheduling and return logistics (when to return, phone follow-up timing, booking \
    the next appointment, “see you in 6 weeks”). Do not place the substantive treatment plan solely in Follow-up; \
    duplicate a brief scheduling line here if needed, but the clinical plan stays in Treatment Plan.
    - Findings: Use for stated diagnoses, impressions, examination results—not for the ordered plan \
    unless the transcript only states an isolated label with no actionable plan elsewhere.
    - Medications: List drug names/doses/adherence explicitly mentioned; if a NEW medication is STARTED as part \
    of today’s plan, summarize it briefly in Medications AND keep the clinician’s prescribing intent under Treatment Plan.
    - Chief Complaint: Organize each presenting concern by body system. Use markdown `###` headings \
    (or a system label before the bullet) from this set: \(BodySystem.promptAllowedList). \
    One bullet per distinct complaint. Prefer a short stable title (e.g. "Migraine") with severity, \
    triggers, course, and treatment response after an em dash or on the detail side of the line \
    (e.g. "- Migraine — photophobia, 2-day duration"). Do not write a narrative paragraph.
    - Symptoms: One bullet per distinct symptom. Prefer a short stable title ("Nausea", "Low back pain") \
    and put severity, triggers, course, and response-to-treatment in the detail after an em dash so \
    the same symptom can be compared across visits. Do not invent facts.
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
        Every item in each field must describe one distinct source, event, provider, medication, or care-plan entry. \
        Include dates only when explicitly stated; otherwise do not invent dates. \
        For chiefComplaint, group bullets under body-system headings (\(BodySystem.promptAllowedList)); omit empty systems. \
        For chiefComplaint and symptoms, prefer short stable titles (e.g. "Migraine") with severity/triggers/course after an em dash. \
        For practitionerContacts: one contact per line or array item; include name, org, role, phone, email, and address only when explicitly tied to that contact in the same source block. \
        Never merge names with contact details from a different document or section.
        """

        switch contentKind {
        case .visitEncounter:
            return """
            \(commonRules)

            Allowed optional keys for visit dialogue/encounters (omit when empty): \
            chiefComplaint, symptoms, findings, medications, treatmentPlan, practitionerContacts, vaccinations, allergies, testsAndLabs, followUp, otherNotes.
            For medications use a string or array of strings; each line must stay tied to the drug it describes (no shared trailing class for unrelated drugs).
            """

        case .carePlanEducation:
            return """
            \(commonRules)

            Allowed optional keys for care plans & education documents (omit when empty): \
            chiefComplaint, symptoms, findings, medications, treatmentPlan, practitionerContacts, vaccinations, allergies, testsAndLabs, followUp, otherNotes.
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
            Allowed optional top-level keys (omit when empty): allergies, treatmentPlan, practitionerContacts, testsAndLabs, vaccinations, followUp, chiefComplaint, symptoms, findings, otherNotes.
            Do not stuff free-text medication lines into otherNotes when they belong in medications[].
            Always use the exact top-level JSON key "medications" for the drug list (never medicationItems or medication_list).
            """

        case .personalJournal:
            return """
            \(commonRules)

            Allowed optional keys for personal journaling (omit when empty): \
            chiefComplaint, symptoms, findings, medications, treatmentPlan, practitionerContacts, vaccinations, allergies, testsAndLabs, followUp, otherNotes.
            treatmentPlan captures self-care intentions the author stated, not a fictional clinic visit plan.
            """

        case .mixedOther:
            return """
            \(commonRules)

            Allowed optional keys when the text blends formats (omit when empty): \
            chiefComplaint, symptoms, findings, medications, treatmentPlan, practitionerContacts, vaccinations, allergies, testsAndLabs, followUp, otherNotes.
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
