import Foundation

/// One labeled group of bullets shown in the Overview card.
struct OverviewBulletSection: Equatable, Identifiable {
    var title: String
    var bullets: [String]

    var id: String { title }
}

/// The model sometimes returns a plain string, sometimes a JSON array of strings.
/// This struct handles both by normalising arrays into "- item" bullet strings.
struct GlobalSummaryPayload: Codable {
    /// Categorized markdown digest (headings + bullets). Legacy caches may still store a spoken paragraph.
    var overview: String?
    var chiefComplaint: String?
    var symptoms: String?
    var diagnoses: String?
    var medications: String?
    var carePlans: String?
    /// Care-team contacts; generated entries preserve only details explicitly tied to the same source block.
    var practitionerContacts: String?
    var vaccinations: String?
    var allergies: String?
    var testsAndLabs: String?
    var followUp: String?
    var biopsychosocialContext: String?
    /// Important details that do not fit other longitudinal fields; avoid duplicating structured sections.
    var otherNotes: String?

    enum CodingKeys: String, CodingKey {
        case overview
        case chiefComplaint
        case symptoms, diagnoses, medications, carePlans, practitionerContacts, vaccinations
        case allergies, testsAndLabs, followUp, biopsychosocialContext, otherNotes
    }

    init(
        overview: String? = nil,
        chiefComplaint: String? = nil,
        symptoms: String? = nil,
        diagnoses: String? = nil,
        medications: String? = nil,
        carePlans: String? = nil,
        practitionerContacts: String? = nil,
        vaccinations: String? = nil,
        allergies: String? = nil,
        testsAndLabs: String? = nil,
        followUp: String? = nil,
        biopsychosocialContext: String? = nil,
        otherNotes: String? = nil
    ) {
        self.overview = overview
        self.chiefComplaint = chiefComplaint
        self.symptoms = symptoms
        self.diagnoses = diagnoses
        self.medications = medications
        self.carePlans = carePlans
        self.practitionerContacts = practitionerContacts
        self.vaccinations = vaccinations
        self.allergies = allergies
        self.testsAndLabs = testsAndLabs
        self.followUp = followUp
        self.biopsychosocialContext = biopsychosocialContext
        self.otherNotes = otherNotes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overview = c.decodeFlexible(.overview)
        chiefComplaint = c.decodeFlexible(.chiefComplaint)
        symptoms = c.decodeFlexible(.symptoms)
        diagnoses = c.decodeFlexible(.diagnoses)
        medications = c.decodeFlexible(.medications)
        carePlans = c.decodeFlexible(.carePlans)
        practitionerContacts = c.decodeFlexible(.practitionerContacts)
        vaccinations = c.decodeFlexible(.vaccinations)
        allergies = c.decodeFlexible(.allergies)
        testsAndLabs = c.decodeFlexible(.testsAndLabs)
        followUp = c.decodeFlexible(.followUp)
        biopsychosocialContext = c.decodeFlexible(.biopsychosocialContext)
        otherNotes = c.decodeFlexible(.otherNotes)
    }

    /// Category rows that have content — shared by global and folder-scoped summaries.
    var nonemptyDisplaySections: [(title: String, content: String)] {
        let entries: [(title: String, content: String?)] = [
            ("Chief Complaint", chiefComplaint),
            ("Symptoms", symptoms),
            ("Findings", diagnoses),
            ("Medications", medications),
            ("Care Plans", carePlans),
            ("Care team & contacts", practitionerContacts),
            ("Vaccinations", vaccinations),
            ("Allergies", allergies),
            ("Tests & Labs", testsAndLabs),
            ("Follow-up", followUp),
            ("Biopsychosocial Context", biopsychosocialContext),
            ("Other Notes", otherNotes),
        ]
        return entries.compactMap { title, content in
            guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (title, content)
        }
    }

    /// Overview card content: categorized bullets, never a spoken paragraph.
    func overviewBulletSections() -> [OverviewBulletSection] {
        if let fromOverview = CategorizedBulletParser.sections(from: overview),
           CategorizedBulletParser.looksCategorized(fromOverview) {
            return fromOverview
        }

        var sections: [OverviewBulletSection] = []
        if let cc = chiefComplaint?.trimmingCharacters(in: .whitespacesAndNewlines), !cc.isEmpty {
            for group in BodySystem.groupedLines(from: cc) {
                sections.append(OverviewBulletSection(title: group.system.displayName, bullets: group.lines))
            }
        }
        for row in nonemptyDisplaySections where row.title != "Chief Complaint" {
            let bullets = CategorizedBulletParser.lines(from: row.content)
            if !bullets.isEmpty {
                sections.append(OverviewBulletSection(title: row.title, bullets: bullets))
            }
        }
        if sections.isEmpty, let bullets = CategorizedBulletParser.proseFallbackBullets(from: overview), !bullets.isEmpty {
            sections.append(OverviewBulletSection(title: "Summary", bullets: bullets))
        }
        return sections
    }
}

/// Turn markdown or prose blobs into labeled bullet groups.
enum CategorizedBulletParser {
    static func sections(from raw: String?) -> [OverviewBulletSection]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var currentTitle: String?
        var currentBullets: [String] = []
        var result: [OverviewBulletSection] = []

        func flush() {
            guard let title = currentTitle else { return }
            let bullets = currentBullets.filter { !$0.isEmpty }
            if !bullets.isEmpty {
                result.append(OverviewBulletSection(title: title, bullets: bullets))
            }
            currentBullets = []
        }

        for original in raw.components(separatedBy: "\n") {
            let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let heading = headingText(from: trimmed) {
                flush()
                currentTitle = heading
                continue
            }
            currentBullets.append(stripListMarker(trimmed))
        }
        flush()
        return result.isEmpty ? nil : result
    }

    static func looksCategorized(_ sections: [OverviewBulletSection]) -> Bool {
        if sections.count >= 2 { return true }
        guard let only = sections.first else { return false }
        let title = only.title.lowercased()
        if TitleHints.contains(where: { title.contains($0) }) { return true }
        return only.bullets.count >= 2 && only.bullets.allSatisfy { $0.count < 160 }
    }

    static func lines(from raw: String) -> [String] {
        raw.components(separatedBy: "\n")
            .map { stripListMarker($0) }
            .filter { !$0.isEmpty }
    }

    static func proseFallbackBullets(from raw: String?) -> [String]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let fromLines = lines(from: raw)
        if fromLines.count >= 2 { return fromLines }
        let sentences = raw
            .replacingOccurrences(of: #"[.!?]\s+"#, with: "\n", options: .regularExpression)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }
            .filter { $0.count > 8 }
        return sentences.isEmpty ? fromLines : sentences
    }

    private static let TitleHints = [
        "neurolog", "nervous", "digest", "immune", "lymph", "urin", "musculo",
        "cardio", "respir", "endocrin", "skin", "mental", "medication", "care plan",
        "allerg", "finding", "symptom", "complaint", "vaccin", "test", "follow",
    ]

    private static func headingText(from line: String) -> String? {
        var s = line
        if s.hasPrefix("### ") { s = String(s.dropFirst(4)) }
        else if s.hasPrefix("## ") { s = String(s.dropFirst(3)) }
        else if s.hasPrefix("# ") { s = String(s.dropFirst(2)) }
        else { return nil }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "*# ")).trimmingCharacters(in: .whitespaces)
    }

    private static func stripListMarker(_ line: String) -> String {
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

extension KeyedDecodingContainer {
    /// Decodes a key that may arrive as a `String` or `[String]`.
    func decodeFlexible(_ key: Key) -> String? {
        if let str = try? decode(String.self, forKey: key), !str.isEmpty { return str }
        if let arr = try? decode([String].self, forKey: key), !arr.isEmpty {
            return arr.map { "- \($0)" }.joined(separator: "\n")
        }
        return nil
    }
}
