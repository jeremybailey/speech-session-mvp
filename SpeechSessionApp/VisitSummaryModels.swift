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

/// One prompted visit fact (object form) before it becomes a `SummaryEntry` card.
struct VisitSummaryFact {
    var title: String
    var details: String
    var bodySystem: BodySystem?
    var clinicalStatus: SummaryEntryClinicalStatus?
    var factKey: String?
    var evidence: ClinicalEvidence? = nil
    /// Source claims shown on the card and checked like any other populated field.
    var contextFields: [SummaryEntryField] = []

    var markdownLine: String {
        if details.isEmpty { return "- \(title)" }
        return "- \(title) — \(details)"
    }
}

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
    /// Object-form facts (clinicalStatus + factKey) when the model returned structured items.
    var biopsychosocialContext: String? = nil
    var factsByCategory: [SummaryEntryCategory: [VisitSummaryFact]] = [:]

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
        ("Biopsychosocial Context", \.biopsychosocialContext),
    ]

    /// Markdown with only non-empty sections; no extra ## headers.
    func markdownFromStructuredSections() -> String {
        Self.sectionSpecs.compactMap { spec -> String? in
            let fromFacts = factsByCategory[Self.category(forSectionHeading: spec.heading)].flatMap { facts -> String? in
                let joined = facts.map(\.markdownLine).joined(separator: "\n")
                return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
            }
            let raw = fromFacts ?? self[keyPath: spec.keyPath]?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "## \(spec.heading)\n\(raw)"
        }.joined(separator: "\n\n")
    }

    private static func category(forSectionHeading heading: String) -> SummaryEntryCategory {
        switch heading {
        case "Chief Complaint": return .chiefComplaint
        case "Symptoms": return .symptoms
        case "Findings": return .findings
        case "Biopsychosocial Context": return .biopsychosocialContext
        case "Medications": return .medications
        case "Treatment Plan": return .carePlan
        case "Care team & contacts": return .practitionerContact
        case "Vaccinations": return .vaccinations
        case "Allergies": return .allergies
        case "Tests & Labs Ordered": return .testsAndLabs
        case "Follow-up": return .followUp
        default: return .otherNotes
        }
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
            (.biopsychosocialContext, fields.biopsychosocialContext),
        ]

        return specs.flatMap { spec in
            if let facts = fields.factsByCategory[spec.category] {
                return facts.map { fact in
                    makeEntry(
                        category: spec.category,
                        line: fact.markdownLine.hasPrefix("- ")
                            ? String(fact.markdownLine.dropFirst(2))
                            : fact.title,
                        titleOverride: fact.title,
                        detailsOverride: fact.details,
                        bodySystem: fact.bodySystem,
                        clinicalStatus: fact.clinicalStatus,
                        factKey: fact.factKey,
                        session: session,
                        origin: origin,
                        evidence: fact.evidence,
                        contextFields: fact.contextFields
                    )
                }
            }
            return entries(
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
        titleOverride: String? = nil,
        detailsOverride: String? = nil,
        bodySystem: BodySystem?,
        clinicalStatus: SummaryEntryClinicalStatus? = nil,
        factKey: String? = nil,
        session: Session,
        origin: SummaryEntryOrigin,
        evidence: ClinicalEvidence? = nil,
        contextFields: [SummaryEntryField] = []
    ) -> SummaryEntry {
        let split = splitPrimaryAndDetail(from: line)
        let overrideTitle = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (overrideTitle?.isEmpty == false ? overrideTitle : nil) ?? split.primary
        let details = detailsOverride ?? split.detail ?? ""
        let contactFields = category == .practitionerContact
            ? (evidence?.contactFields ?? PractitionerContactsFormatting.editableFields(from: line))
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
        let fieldsNeedReview = baseFields.contains(where: { $0.needsReview || $0.isMissing })

        var validated = evidence
        validated?.excerpt = EvidenceValidation.matchingExcerpt(evidence?.excerpt, in: session.transcript)
        let exactDate = EvidenceValidation.exactDate(validated?.eventDate)
        let attributedFields: [(String, String?)] = [
            ("Practitioner", validated?.practitioner), ("Assessment method", validated?.assessmentMethod),
            ("Dose", validated?.dose), ("Frequency", validated?.frequency),
            ("Reason started", validated?.reasonStarted), ("Reason stopped", validated?.reasonStopped)
        ]
        for (label, value) in attributedFields {
            guard let value, !value.isEmpty else { continue }
            if let index = baseFields.firstIndex(where: { $0.label.localizedCaseInsensitiveCompare(label) == .orderedSame }) {
                baseFields[index] = SummaryEntryField(label: label, value: value)
            } else { baseFields.append(SummaryEntryField(label: label, value: value)) }
        }
        baseFields += contextFields
        var result = SummaryEntry(
            category: category,
            title: title,
            details: details,
            fields: baseFields,
            relevantDate: exactDate,
            dateNeedsReview: validated?.eventDate == nil,
            sourceSessionID: session.id,
            sourceTitle: session.title,
            sourceDate: session.date,
            sourceExcerpt: validated?.excerpt ?? sourceExcerpt(for: line, in: session.transcript),
            provenance: provenanceLabel(for: session),
            needsReview: fieldsNeedReview || validated?.excerpt == nil,
            reviewReason: fieldsNeedReview ? "Add missing details for this card." : nil,
            origin: origin,
            clinicalStatus: clinicalStatus,
            factKey: factKey ?? SummaryEntry.normalizedFactKey(title)
        )
        result.evidence = validated
        return result
    }

    fileprivate static func normalizedLines(from raw: String?) -> [String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
        let split = SummaryEntityStructure.lines(raw)
            .map(stripLeadingListMarker)
            .filter { !$0.isEmpty }
        return split.isEmpty ? [raw] : split
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

    fileprivate static func splitPrimaryAndDetail(from line: String) -> (primary: String, detail: String?) {
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
        return nil
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
        guard var data = proseStripped.data(using: .utf8), !proseStripped.isEmpty else { return nil }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["facts"] != nil {
            guard let sections = try? ClinicalDraftFormat.sections(from: object),
                  let normalized = try? JSONSerialization.data(withJSONObject: sections) else { return nil }
            data = normalized
        }

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        var fields: VisitSummaryFields?
        if let typed = try? dec.decode(VisitSummaryOpenAIResponse.self, from: data) {
            fields = mergeAlternateMedicationKeys(into: typed.fields, rawObjectData: data)
        } else if let merged = flexibleFields(fromJSONObjectData: data) {
            fields = mergeAlternateMedicationKeys(into: merged, rawObjectData: data)
        }
        guard var fields else { return nil }
        ingestFacts(into: &fields, rawObjectData: data)
        return fields
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
        let treatmentPlan = str(["treatmentplan", "treatment_plan", "plan_of_care", "care_plan", "carePlan", "carePlans"])
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
            ("Reason started", ["reasonStarted", "reason_started"]),
            ("Reason stopped", ["reasonStopped", "reason_stopped"]),
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
            // These remain in ClinicalEvidence; serializing them into clinical
            // prose contaminates display and adds redundant checker fields.
            guard !HealthStoryText.isInternalField(rawKey),
                  !["practitioner", "assessmentmethod", "reportedby", "statementtype", "statementstatus",
                    "title", "details", "detail", "description", "notes"].contains(nk) else { continue }
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

    private static let factSectionKeys: [(category: SummaryEntryCategory, synonyms: Set<String>)] = [
        (.chiefComplaint, ["chiefcomplaint", "chief_complaint", "reason_for_visit"]),
        (.symptoms, ["symptoms", "symptom"]),
        (.findings, ["findings", "diagnoses", "diagnosis"]),
        (.medications, [
            "medications", "medication", "medicationitems", "medication_items",
            "medicationlist", "med_list", "meds", "drugs", "prescriptions", "rx",
        ]),
        (.carePlan, ["treatmentplan", "treatment_plan", "plan_of_care", "care_plan", "carePlan", "carePlans"]),
        (.practitionerContact, [
            "practitionercontacts", "practitioner_contacts", "careteamcontacts",
            "providercontacts", "cliniciancontacts",
        ]),
        (.vaccinations, ["vaccinations", "vaccination"]),
        (.allergies, ["allergies", "allergy"]),
        (.testsAndLabs, ["testsandlabs", "tests_and_labs", "labs", "tests", "imaging"]),
        (.followUp, ["followup", "follow_up", "follow-up"]),
        (.otherNotes, ["othernotes", "other_notes", "additionalnotes", "misc"]),
        (.biopsychosocialContext, ["biopsychosocialContext", "biopsychosocial_context", "lifeContext"]),
    ]

    /// Pull object-form facts (`title`/`clinicalStatus`/`factKey`) out of the raw JSON object.
    private static func ingestFacts(into fields: inout VisitSummaryFields, rawObjectData data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var bucket: [SummaryEntryCategory: [VisitSummaryFact]] = fields.factsByCategory
        for spec in factSectionKeys {
            let value = obj.first { factSectionKeysMatch($0.key, spec.synonyms) }?.value
            guard let value else { continue }
            let facts = parseFacts(from: value)
            bucket[spec.category] = facts
            let markdown = facts.map(\.markdownLine).joined(separator: "\n")
            switch spec.category {
            case .chiefComplaint: fields.chiefComplaint = markdown
            case .symptoms: fields.symptoms = markdown
            case .findings: fields.findings = markdown
            case .medications: fields.medications = markdown
            case .carePlan: fields.treatmentPlan = markdown
            case .practitionerContact: fields.practitionerContacts = markdown
            case .vaccinations: fields.vaccinations = markdown
            case .allergies: fields.allergies = markdown
            case .testsAndLabs: fields.testsAndLabs = markdown
            case .followUp: fields.followUp = markdown
            case .otherNotes: fields.otherNotes = markdown
            case .biopsychosocialContext: fields.biopsychosocialContext = markdown
            }
        }
        fields.factsByCategory = bucket
    }

    private static func factSectionKeysMatch(_ key: String, _ synonyms: Set<String>) -> Bool {
        let n = normalizeJSONKey(key)
        return synonyms.contains(where: { normalizeJSONKey($0) == n })
    }

    private static func parseFacts(from value: Any?) -> [VisitSummaryFact] {
        guard let value else { return [] }
        if let dict = value as? [String: Any], let fact = parseFact(from: dict) {
            return [fact]
        }
        if let arr = value as? [Any] {
            return arr.compactMap { el -> VisitSummaryFact? in
                if let dict = el as? [String: Any] {
                    return parseFact(from: dict)
                }
                if let s = el as? String {
                    return parseFact(fromLine: s)
                }
                return nil
            }
        }
        if let s = value as? String {
            return SummaryEntryFactory.normalizedLines(from: s).compactMap { parseFact(fromLine: $0) }
        }
        return []
    }

    private static func parseFact(fromLine line: String) -> VisitSummaryFact? {
        let trimmed = SummaryEntryFactory.stripLeadingListMarker(line)
        guard !trimmed.isEmpty else { return nil }
        let split = SummaryEntryFactory.splitPrimaryAndDetail(from: trimmed)
        return VisitSummaryFact(
            title: split.primary,
            details: split.detail ?? "",
            bodySystem: nil,
            clinicalStatus: SummaryEntry.inferredStatus(title: split.primary, details: split.detail ?? ""),
            factKey: SummaryEntry.normalizedFactKey(split.primary)
        )
    }

    private static func parseFact(from dict: [String: Any]) -> VisitSummaryFact? {
        func string(for keys: [String]) -> String? {
            // Canonical clinical details must win over an instruction used only
            // as a legacy fallback, regardless of dictionary iteration order.
            for key in keys {
                for (rawKey, rawVal) in dict where normalizeJSONKey(rawKey) == normalizeJSONKey(key) {
                    if let s = coerceOpenAIJSONValue(rawVal)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                        return s
                    }
                }
            }
            return nil
        }

        let title = string(for: ["title", "name", "drug", "medication", "med", "drug_name"])
            ?? string(for: ["heading", "label", "instruction", "action", "details"])
        guard let title, !title.isEmpty else { return nil }

        var details = string(for: ["details", "detail", "description", "notes", "instruction"]) ?? ""
        if looksLikeMedicationItem(dict), let medicationDetails = medicationDetailString(from: dict, excludingTitle: title),
           !medicationDetails.isEmpty, !details.localizedCaseInsensitiveContains(medicationDetails) {
            // A narrative detail must not suppress separately supplied dosing,
            // adherence or instructions. Metadata stays in structured fields.
            details = [details, medicationDetails].filter { !$0.isEmpty }.joined(separator: "; ")
        }

        let status = SummaryEntryClinicalStatus.parse(
            string(for: ["clinicalStatus", "clinical_status", "status"])
        )
        let factKey = SummaryEntry.normalizedFactKey(
            string(for: ["factKey", "fact_key", "key"])
        ) ?? SummaryEntry.normalizedFactKey(title)
        let bodySystem = BodySystem.parse(string(for: ["bodySystem", "body_system", "system"]))
        var evidence = ClinicalEvidence()
        let contactKeys = [("name", "Name"), ("role", "Role or specialty"), ("org", "Organization"),
                           ("phone", "Phone"), ("email", "Email"), ("address", "Address")]
        let contactFields = contactKeys.compactMap { key, label -> SummaryEntryField? in
            guard let value = string(for: [key, key == "org" ? "organization" : key]), !value.isEmpty else { return nil }
            return SummaryEntryField(label: label, value: value)
        }
        if !contactFields.isEmpty { evidence.contactFields = contactFields }
        evidence.eventDate = string(for: ["eventDate"])
        evidence.excerpt = string(for: ["sourceExcerpt"])
        evidence.page = dict["sourcePage"] as? Int
        evidence.practitioner = string(for: ["practitioner"])
        evidence.assessmentMethod = string(for: ["assessmentMethod"])
        evidence.topicNames = dict["topicNames"] as? [String]
        evidence.bodySystem = string(for: ["bodySystem"])
        evidence.dose = string(for: ["dose", "strength"])
        evidence.frequency = string(for: ["frequency"])
        if let instruction = string(for: ["instruction"]) {
            evidence.careInstruction = CareInstruction(instruction: instruction, directions: string(for: ["additionalDirections"]),
                goal: string(for: ["goal"]), schedule: string(for: ["schedule"]), reviewTiming: string(for: ["reviewTiming"]),
                isRecurring: dict["isRecurring"] as? Bool)
        }
        evidence.reasonStarted = string(for: ["reasonStarted"])
        evidence.reasonStopped = string(for: ["reasonStopped"])
        evidence.actionKind = string(for: ["actionKind"])
        evidence.statusExplicit = dict["statusExplicit"] as? Bool
        evidence.reviewReason = string(for: ["reviewReason"])

        return VisitSummaryFact(
            title: title,
            details: details,
            bodySystem: bodySystem,
            clinicalStatus: status,
            factKey: factKey,
            evidence: evidence,
            contextFields: [("reportedBy", "Reported by"), ("statementType", "Statement type"),
                            ("statementStatus", "Statement status")].compactMap { key, label in
                guard let value = string(for: [key]) else { return nil }
                return SummaryEntryField(label: label, value: value)
            }
        )
    }

    private static func medicationDetailString(from dict: [String: Any], excludingTitle title: String) -> String? {
        guard let line = coerceMedicationItemDict(dict) else { return nil }
        let unmarked = SummaryEntryFactory.stripLeadingListMarker(line)
        let split = SummaryEntryFactory.splitPrimaryAndDetail(from: unmarked)
        if split.primary.caseInsensitiveCompare(title) == .orderedSame {
            return split.detail
        }
        return split.detail ?? unmarked
    }
}

// MARK: - Prompt text (shared wording for visit-level instructions)

enum VisitSummaryPromptGuidance {
    /// Routing rules appended to visit-level system instructions (OpenAI + on-device).
    static let categoryRoutingRules = """
    CATEGORY RULES (apply strictly):
    - For each detail, use topicNames only for explicitly linked conditions, symptoms or reasons for care (such as a named test indication). A condition need not be a diagnosis. Use one concise, consistent topic name for equivalent descriptions of the same concern (for example pain in the back / back pain), while retaining original wording in the detail. Preserve laterality, anatomical level, distinct diagnoses, and uncertainty. Reuse the same topic across categories only when the source explicitly connects those details; never group merely because they involve the same body system. Record bodySystem only as internal metadata. Include the relationship wording in the source excerpt. Never infer a condition from a drug, test value, body system, provider specialty, or mere proximity in a document. If the relationship is unclear, leave topicNames empty. Preserve historical versus current status only when explicit; old dispensing dates do not establish ongoing use.
    - Preserve patient vs practitioner attribution and negation. A patient-reported diagnosis is not a verified diagnosis.
    - Retain the source's explicit concerns, symptom course, medication adherence, patient preferences and undecided choices, clinician instructions, conditional next steps and return timing. Before finishing, check that none of these were lost in compression. Split independent actions, while keeping each action's dose, timing, conditions and precautions together. Retain an ongoing symptom separately from an earlier resolved episode when the source distinguishes them. Do not invent a symptom's cause or resolve ambiguous spoken names or measurements.
    - Preventive treatment does not establish the disease being prevented. Link to an explicitly established care context when supported, and retain the preventive purpose in the medication or plan details. A planned test is a care instruction, not a test result. Preserve offered versus accepted versus completed actions.
    - Chief Complaint is the reason for seeking care, not every symptom. Routine checkups and administrative visits are not conditions.
    - Tests & Labs holds reported test results even outside an appointment. Do not put results under Chief Complaint or Findings. Numeric lab values, reference ranges and high/low flags belong only in Tests & Labs. Findings is for separately stated patient-specific diagnoses or clinical impressions, not a second copy of test results.
    - Biopsychosocial Context retains explicitly stated mental health, life events, caregiving, work, social circumstances, diet and lifestyle. Never infer causal relationships.
    - A prescription is not evidence that medication was administered. OCR of forms can lose circled selections and handwritten overrides: never choose a dose, concentration, eye, frequency or repeat count from a list of printed alternatives. Keep the medicine name and omit uncertain values. Do not infer a prescriber from a multi-provider clinic header. Ambiguous numeric dates stay unknown.
    - Medications includes supplements. Keep missing dose, indication and stop reason unknown; never fill them from general knowledge.
    - Homecare classification is functional: does the statement ask the patient to do something outside the visit? Include HEP, education, self-care, lifestyle instructions and referrals even without a matching keyword.
    - Use actionKind=treatment_received ONLY for a treatment explicitly already performed or taken, never for a recommendation, offer or future instruction. Use homecare for an explicit instruction outside the visit and follow_up for return logistics. An earlier dose does not turn a separate future dosing instruction into treatment_received. Do not turn an offered option into an accepted plan. Ambiguous instructions use actionKind=uncertain and reviewReason.

    - Treatment Plan: Put ALL clinician-directed plans and actions here: medication changes or new prescriptions \
    discussed as today’s plan, referrals, procedures, imaging/therapy orders, device or equipment instructions, \
    lifestyle or diet recommendations from the clinician, patient education, home exercises, care coordination, \
    and any “we will / you should / start / continue / taper” clinical instructions. \
    Do not bury those items only under Symptoms or Findings unless they are purely diagnostic labels with \
    no plan attached.
    - Care team & contacts (practitionerContacts): Each line is one contact card from one source block: person or organization name, \
    role/specialty, phone, email, address, and notes ONLY when explicitly present together in that same source block. \
    **Never** pair a provider or org named in one part of the source with contact/lab/Rx text from another section or entry. \
    **Omit** first-name-only dialogue. Use contact objects; omit unavailable fields rather than inventing placeholders. \
    Clinical plan prose stays under **Treatment Plan**.
    - Follow-up: Use ONLY for scheduling and return logistics (when to return, phone follow-up timing, booking \
    the next appointment, “see you in 6 weeks”). Do not place the substantive treatment plan solely in Follow-up; \
    duplicate a brief scheduling line here if needed, but the clinical plan stays in Treatment Plan.
    - Findings: Only patient-specific stated diagnoses, impressions or actual examination results. Test names, billed services, exam scope (such as Partial Exam), headings and general educational statements are not findings.
    - Medications: List drug names/doses/adherence explicitly mentioned; if a NEW medication is STARTED as part \
    of today’s plan, summarize it briefly in Medications AND keep the clinician’s prescribing intent under Treatment Plan.
    - Chief Complaint: Use one object per distinct presenting concern, with bodySystem from \
    this set: \(BodySystem.promptAllowedList). Prefer a short stable title (e.g. "Migraine"). \
    Put severity, triggers, course and treatment response in details, with a supporting sourceExcerpt.
    - Symptoms: One object per distinct symptom. Prefer a short stable title ("Nausea", "Low back pain") \
    and put severity, triggers, course, and response-to-treatment in details so \
    the same symptom can be compared across visits. Do not invent facts.
    """

    /// Exact JSON key contract per routed `contentKind` (OpenAI `json_object`). `otherNotes` catches important residue only.
    static func structuredJSONSpec(for contentKind: SummaryContentKind) -> String {
        let commonRules = """
        Immunization/vaccination history belongs in vaccinations, including vaccine product names.
        Distinguish a vaccine prescription/dispensing record from an administered vaccination: preserve
        the event wording and never infer administration from a pharmacy fill. Do not omit vaccinations.
        Identify the chief complaint: the primary symptom, problem or condition explicitly described
        as motivating this encounter or request for care. Synthesize it as a concise problem statement
        in chiefComplaint with supporting sourceExcerpt; keep other symptoms in symptoms. Do not use
        appointment type, procedure name or a list of lab results as the chief complaint. Do not infer
        a primary complaint from prescription names or symptom frequency. If none is established, omit it.
        Classify source entities before formatting. Each array element is one named entity, never an attribute.
        Keep strength, dose, frequency, route, dates and results inside their parent object. A medication
        requires a product name, not complete dosing metadata. Never emit "strength: 0.1%" or a bare
        phone number as an entry. If a field's parent is unclear, leave it in the original rather than
        inventing an association. Lab results belong to Tests & Labs, not Findings; findings require
        a patient-specific clinical observation or impression. Preserve source context and relationships.
        Output format: Respond with JSON ONLY. Include "title" (3–6 words).
        Always include the key "otherNotes" when there is substantive information that does not fit any other allowed field; \
        otherwise omit "otherNotes" entirely. Never duplicate the same fact in otherNotes and another field. \
        Do not invent clinical facts. Copy strengths and doses verbatim from the source when given.
        Emit each populated section as a JSON array of objects with keys: \
        title (required; short stable name), details (optional), \
        clinicalStatus ("current" or "past"), \
        factKey (lowercase hyphenated slug that stays stable across visits, e.g. "migraine" or "metformin"). \
        For chiefComplaint objects also include bodySystem from (\(BodySystem.promptAllowedList)). \
        Include these common evidence properties on EVERY fact object when supported:
        reportedBy (Patient, Clinician, or the source-established clinical role; do not guess a name or role),
        statementType (Patient report, Clinician finding, Care instruction, Medication, Follow-up, or Education),
        statementStatus (Current, Historical, Planned, or Uncertain, according to the assertion rather than the encounter date),
        sourceExcerpt (short verbatim passage supporting this fact, including negation/qualifiers), sourcePage (original page number if supplied),
        eventDate (explicit YYYY-MM-DD, YYYY-MM or YYYY; never the import date), practitioner, assessmentMethod,
        topicNames (array of condition/health-topic names ONLY explicitly associated with this fact in this source), bodySystem,
        dose, frequency, reasonStarted, reasonStopped, actionKind (homecare/follow_up/treatment_received/self_directed/uncertain),
        statusExplicit (true only if current/past status is explicitly supported), reviewReason (missing or ambiguous information).
        For care plans and follow-up, emit ONE object per distinct instruction, never separate title and description objects.
        Include instruction (complete action sentence), additionalDirections (only extra information), goal, schedule,
        reviewTiming and isRecurring ONLY when supported by the source. Do not invent missing goals or schedules.
        The title should contain the instruction; details must not repeat it. Preserve negation, laterality and timing exactly.
        Preserve laterality and suspected vs confirmed wording in factKey; do not collapse distinct clinical assertions.
        Use consistent titles and factKey values for synonymous wording across every category. Emit one object per distinct fact, with expanded wording in details rather than a second object. Never equate headache with migraine or omit negation, body side, dose, result, or event timing to force a match.
        Use the same concise topic name for a chief complaint and every fact explicitly linked to it. Include multiple topicNames when the source explicitly links a fact to multiple concerns. Never infer a diagnosis or causal relationship from symptoms alone. If no condition relationship is explicitly supported, omit topicNames; general health is valid.
        clinicalStatus may be omitted when unknown; statusExplicit must then be false.
        clinicalStatus is only the current/past axis. For a planned or undecided assertion use statementStatus=Planned
        or Uncertain, omit clinicalStatus and use statusExplicit=false; do not mislabel it as current treatment.
        reportedBy, statementType and statementStatus are visible clinical claims, not bookkeeping. Omit a value
        when the source does not establish it. A first-person remark is not automatically the patient's remark:
        use the surrounding exchange to distinguish patient, clinician and other people; omit uncertain attribution.
        Put attribution and meaningful uncertainty in the readable details too (for example, Patient reports...,
        Clinician offers..., Patient is considering...); do not hide qualifiers only in sourceExcerpt or reviewReason.
        Preserve each distinct patient concern and instruction as its own fact. Do not merge a current observation,
        a historical finding and social context into a single long note. Preserve exact durations, relative timing,
        improvement or worsening, adherence, decision/booking status and all conditions attached to an action.
        Omit isRecurring unless the source establishes repetition or one-time use; absence of repetition is not false.
        Preserve optionality: describing an available test or treatment is not an instruction to undergo it.
        Do not add a pharmacological assessment method, urgency, goal, body system or other filler to complete an object.
        Before returning, compare the draft inventory against the source for omitted reports, preferences and actions.
        A named condition being prevented is not a diagnosis. Uncertain spoken drug names remain uncertain in the
        title/details; do not silently resolve them using medical knowledge. Keep every qualifying phrase in the
        same object as the claim it qualifies. Copy excerpts exactly, including the original punctuation and wording.
        Do not flatten evidence properties into details or emit bare strings for clinical facts: each fact needs its own sourceExcerpt and any supported qualifiers. \
        Every item must describe one distinct source, event, provider, medication, or care-plan entry. \
        Include dates only when explicitly stated in the source; otherwise omit eventDate. Relative timing remains verbatim in details or reviewTiming; never invent an absolute year or calendar date from it. \
        For practitionerContacts: use objects with separate name, org, role, phone, email, address string properties; never serialize labelled contact fields into details; include name, org, role, phone, email, and address only when explicitly tied to that contact in the same source block. \
        Never merge names with contact details from a different document or section.
        """

        switch contentKind {
        case .visitEncounter:
            return """
            \(commonRules)

            Allowed optional keys for visit dialogue/encounters (omit when empty): \
            chiefComplaint, symptoms, findings, medications, treatmentPlan, practitionerContacts, vaccinations, allergies, testsAndLabs, followUp, biopsychosocialContext, otherNotes.
            For medications use an array of objects (name required; optional strength, frequency, route, duration, instructions, classOrCategory, clinicalStatus, factKey, and the common evidence properties); \
            each object must stay tied to the drug it describes (no shared trailing class for unrelated drugs).
            """

        case .carePlanEducation:
            return """
            \(commonRules)

            Allowed optional keys for care plans & education documents (omit when empty): \
            chiefComplaint, symptoms, findings, medications, treatmentPlan, practitionerContacts, vaccinations, allergies, testsAndLabs, followUp, biopsychosocialContext, otherNotes.
            Prefer treatmentPlan for patient education, self-management, lifestyle, warning signs, and clinician-directed steps stated in the document.
            For medications use an array of medication objects with the common evidence properties (see medication_reference spec for object shape).
            """

        case .medicationReference:
            return """
            \(commonRules)

            Required: "title" (3–6 words summarizing the list or document).
            Required when any drug appears: "medications" as a JSON array of objects—one object per drug—with ONLY these properties on each object \
            (omit a property rather than guessing): \
            name (required), strength, frequency, route, duration, instructions, classOrCategory, \
            clinicalStatus ("current" or "past"), factKey (lowercase hyphenated slug, usually the drug name), and the common evidence properties.
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
            chiefComplaint, symptoms, findings, medications, treatmentPlan, practitionerContacts, vaccinations, allergies, testsAndLabs, followUp, biopsychosocialContext, otherNotes.
            Omit app-directed remarks about recording or including content; extract the actual health information they refer to instead. Include a short verbatim source excerpt for each clinical assertion and explicitly write Patient reports when summarizing the patient’s account. Preserve ruled-out conditions as negative history, never active diagnoses. Do not resolve uncertain transcribed clinician names by guessing. Patient narration is source evidence of what the patient reports, including their condition and priorities. Extract their explicitly stated main health problem into chiefComplaint, sensations into symptoms, and reported diagnoses into findings with patient-reported attribution. Use a shared topicNames concern label for explicitly related details. Do not demand clinician corroboration to preserve a patient-reported concern, and never imply clinical confirmation. Present daily-life context in biopsychosocialContext and genuinely reflective commentary in otherNotes; do not place the patient's main health problem in otherNotes merely because this is a journal.
            Do not create findings or a chiefComplaint unless explicitly described. Waiting for symptoms to pass is not a care plan.
            treatmentPlan includes only explicit concrete self-care intentions; mark actionKind=self_directed. Never invent professional recommendations.
            """

        case .mixedOther:
            return """
            \(commonRules)

            Allowed optional keys when the text blends formats (omit when empty): \
            chiefComplaint, symptoms, findings, medications, treatmentPlan, practitionerContacts, vaccinations, allergies, testsAndLabs, followUp, biopsychosocialContext, otherNotes.
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
