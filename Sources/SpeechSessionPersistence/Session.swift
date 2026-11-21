import Foundation

/// Whether the user framed the entry as a clinical visit note or personal journaling (drives summarization).
public enum SessionEntryIntent: String, Codable, Sendable, Hashable {
    /// Appointment, clinical encounter, or note intended as a medical visit summary.
    case clinicalVisit
    /// Personal reflection or journal the user recorded for themselves.
    case personalJournal
}

/// Kind of persisted source file attached to a session.
public enum SessionSourceKind: String, Codable, Sendable, Hashable {
    case audio
    case pdf
    case image
    case plainText
    case multiPageScan
}

/// One original file practitioners can open to verify extracted summary facts.
public struct SessionSourceAsset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: SessionSourceKind
    /// Path relative to `sources/{sessionID}/`.
    public var relativePath: String
    public var displayName: String
    public var pageIndex: Int?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: SessionSourceKind,
        relativePath: String,
        displayName: String,
        pageIndex: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.displayName = displayName
        self.pageIndex = pageIndex
        self.createdAt = createdAt
    }
}

/// How the session transcript was captured.
public enum SessionInputType: String, Codable, Sendable {
    case audio
    /// Legacy OCR/scan/photo uploads before PDF/text was distinguished (`documentImage` / `documentFile`).
    case document
    /// VisionKit “scan papers” (multi-page document camera).
    case documentScan
    /// Device camera, photo library, or shared image → OCR text (Photos add path).
    case documentImage
    /// Imported `.pdf` / plain-text file content.
    case documentFile
}

/// Canonical categories shown in summary cards.
public enum SummaryEntryCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case chiefComplaint
    case symptoms
    case findings
    case medications
    case carePlan
    case practitionerContact
    case vaccinations
    case allergies
    case testsAndLabs
    case followUp
    case biopsychosocialContext
    case otherNotes

    public var displayTitle: String {
        switch self {
        case .chiefComplaint: return "Chief Complaint"
        case .symptoms: return "Symptoms"
        case .findings: return "Findings"
        case .medications: return "Medications"
        case .carePlan: return "Care Plans"
        case .practitionerContact: return "Care team & contacts"
        case .vaccinations: return "Vaccinations"
        case .allergies: return "Allergies"
        case .testsAndLabs: return "Tests & Labs"
        case .followUp: return "Follow-up"
        case .biopsychosocialContext: return "Biopsychosocial Context"
        case .otherNotes: return "Other Notes"
        }
    }
}

/// Where a summary card came from.
public enum SummaryEntryOrigin: String, Codable, Hashable, Sendable {
    case generated
    case userAdded
    case userEdited
    case legacyImported
}

/// Editable field inside an atomic summary card.
public struct SummaryEntryField: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var value: String
    public var isMissing: Bool
    public var needsReview: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        value: String = "",
        isMissing: Bool = false,
        needsReview: Bool = false
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.isMissing = isMissing
        self.needsReview = needsReview
    }
}

/// Whether a summary fact is ongoing or historical.
public enum SummaryEntryClinicalStatus: String, Hashable, Sendable, CaseIterable {
    case current
    case past

    public var displayTitle: String {
        switch self {
        case .current: return "Current"
        case .past: return "Past"
        }
    }

    /// Section order for summary lists (current first, then past).
    public static let summarySectionOrder: [SummaryEntryClinicalStatus] = [.current, .past]

    /// Current wins when stacking multiple sources.
    public static func dominant(in statuses: some Sequence<SummaryEntryClinicalStatus>) -> SummaryEntryClinicalStatus {
        statuses.contains(.current) ? .current : .past
    }

    /// Maps persisted values, including legacy active/inactive/resolved.
    static func fromStored(_ raw: String) -> SummaryEntryClinicalStatus? {
        switch raw {
        case "current", "active":
            return .current
        case "past", "inactive", "resolved":
            return .past
        default:
            return nil
        }
    }

    /// Parse model or UI wording (`current`/`past`, plus legacy active/resolved).
    public static func parse(_ raw: String?) -> SummaryEntryClinicalStatus? {
        guard let raw else { return nil }
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return fromStored(n)
    }
}

extension SummaryEntryClinicalStatus: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let status = Self.fromStored(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown clinical status: \(raw)"
            )
        }
        self = status
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One durable, editable summary fact. Each entry should map to one source, event, provider, or care-plan item.
public struct SummaryEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var category: SummaryEntryCategory
    public var linkedSummaryBlockKey: String?
    public var originalCategory: SummaryEntryCategory?
    public var title: String
    public var details: String
    public var fields: [SummaryEntryField]
    public var evidence: ClinicalEvidence?
    public var relevantDate: Date?
    public var dateNeedsReview: Bool
    public var sourceSessionID: UUID?
    public var sourceTitle: String?
    public var sourceDate: Date?
    public var sourceExcerpt: String?
    public var provenance: String
    public var needsReview: Bool
    public var reviewReason: String?
    public var isDeleted: Bool
    public var origin: SummaryEntryOrigin
    /// Current or past item status. Defaults to inferred value for legacy entries.
    public var clinicalStatus: SummaryEntryClinicalStatus
    /// Stable slug for stacking the same clinical fact across visits (e.g. `migraine`).
    public var factKey: String?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, category, linkedSummaryBlockKey, originalCategory, title, details, fields
        case evidence, relevantDate, dateNeedsReview
        case sourceSessionID, sourceTitle, sourceDate, sourceExcerpt
        case provenance, needsReview, reviewReason, isDeleted, origin
        case clinicalStatus, factKey, createdAt, updatedAt
    }

    public init(
        id: UUID = UUID(),
        category: SummaryEntryCategory,
        title: String,
        details: String = "",
        fields: [SummaryEntryField] = [],
        relevantDate: Date? = nil,
        dateNeedsReview: Bool = false,
        sourceSessionID: UUID? = nil,
        sourceTitle: String? = nil,
        sourceDate: Date? = nil,
        sourceExcerpt: String? = nil,
        provenance: String = "",
        needsReview: Bool = false,
        reviewReason: String? = nil,
        isDeleted: Bool = false,
        origin: SummaryEntryOrigin = .generated,
        clinicalStatus: SummaryEntryClinicalStatus? = nil,
        factKey: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.details = details
        self.fields = fields
        self.evidence = nil
        self.relevantDate = relevantDate
        self.dateNeedsReview = dateNeedsReview
        self.sourceSessionID = sourceSessionID
        self.sourceTitle = sourceTitle
        self.sourceDate = sourceDate
        self.sourceExcerpt = sourceExcerpt
        self.provenance = provenance
        self.needsReview = needsReview
        self.reviewReason = reviewReason
        self.isDeleted = isDeleted
        self.origin = origin
        self.clinicalStatus = clinicalStatus ?? Self.inferredStatus(title: title, details: details)
        self.factKey = Self.normalizedFactKey(factKey)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        category = try c.decode(SummaryEntryCategory.self, forKey: .category)
        linkedSummaryBlockKey = try c.decodeIfPresent(String.self, forKey: .linkedSummaryBlockKey)
        originalCategory = try c.decodeIfPresent(SummaryEntryCategory.self, forKey: .originalCategory)
        title = try c.decode(String.self, forKey: .title)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        fields = try c.decodeIfPresent([SummaryEntryField].self, forKey: .fields) ?? []
        evidence = try c.decodeIfPresent(ClinicalEvidence.self, forKey: .evidence)
        relevantDate = try c.decodeIfPresent(Date.self, forKey: .relevantDate)
        dateNeedsReview = try c.decodeIfPresent(Bool.self, forKey: .dateNeedsReview) ?? false
        sourceSessionID = try c.decodeIfPresent(UUID.self, forKey: .sourceSessionID)
        sourceTitle = try c.decodeIfPresent(String.self, forKey: .sourceTitle)
        sourceDate = try c.decodeIfPresent(Date.self, forKey: .sourceDate)
        sourceExcerpt = try c.decodeIfPresent(String.self, forKey: .sourceExcerpt)
        provenance = try c.decodeIfPresent(String.self, forKey: .provenance) ?? ""
        needsReview = try c.decodeIfPresent(Bool.self, forKey: .needsReview) ?? false
        reviewReason = try c.decodeIfPresent(String.self, forKey: .reviewReason)
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        origin = try c.decodeIfPresent(SummaryEntryOrigin.self, forKey: .origin) ?? .generated
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        if let status = try c.decodeIfPresent(SummaryEntryClinicalStatus.self, forKey: .clinicalStatus) {
            clinicalStatus = status
        } else {
            clinicalStatus = Self.inferredStatus(title: title, details: details)
        }
        factKey = Self.normalizedFactKey(try c.decodeIfPresent(String.self, forKey: .factKey))
    }

    /// Lowercase hyphenated slug used to stack the same fact across visits.
    public static func normalizedFactKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\s_]+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Infer status from wording when the model or user did not set one explicitly.
    public static func inferredStatus(title: String, details: String) -> SummaryEntryClinicalStatus {
        let hay = "\(title) \(details)".lowercased()
        let pastHints = [
            "resolved", "resolution", "cleared", "gone", "healed", "in remission",
            "has resolved", "was resolved", "fully resolved", "symptom-free", "symptom free",
            "no longer present", "completed course",
            "inactive", "discontinued", "stopped taking", "no longer taking", "not currently",
            "on hold", "paused", "held", "withdrawn", "off medication", "no longer on", "former",
        ]
        if pastHints.contains(where: { hay.contains($0) }) {
            return .past
        }
        return .current
    }
}

/// Patient writing and per-original extraction checkpoints for a mixed-media record.
public struct RecordCapture: Codable, Hashable, Sendable {
    public var patientTitle = ""
    public var notes = ""
    public var isDraft = true
    public var needsRecordSummary: Bool?
    public var pending = false
    public var textByAsset: [UUID: String] = [:]
    public var failedAssets: Set<UUID> = []
    public var duration: TimeInterval = 0
    public init() {}
}

/// A persisted recording session: metadata, full transcript, and optional AI-generated fields.
public struct RecordChoice: Codable, Hashable, Sendable {
    public let topic: String
    public let recipient: String
    public let stance: String
    public let subjectQuote: String
    public let responseQuote: String

    public init(topic: String, recipient: String, stance: String, subjectQuote: String, responseQuote: String) {
        self.topic = topic
        self.recipient = recipient
        self.stance = stance
        self.subjectQuote = subjectQuote
        self.responseQuote = responseQuote
    }

    public var isGrounded: Bool {
        (stance == "booked" ? confirmsBooking : ["question", "tentative preference", "declined", "deferred", "agreed"].contains(stance)) &&
        !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !responseQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !["it", "that", "this", "shot", "decision"].contains(topic.lowercased()) &&
        namesTopic(in: subjectQuote)
    }

    private var confirmsBooking: Bool {
        let quote = responseQuote.lowercased()
        return quote.range(of: #"\b(booked|scheduled|confirmed)\b"#, options: .regularExpression) != nil &&
            quote.range(of: #"\b(not|never|wasn't|isn't|isn’t|wasn’t|if|could|might|cancelled|canceled)\b"#, options: .regularExpression) == nil &&
            !quote.contains("?")
    }

    public func namesTopic(in text: String) -> Bool {
        let words = RecordBullet.words(text).joined(separator: " ")
        let name = RecordBullet.words(topic).joined(separator: " ")
        return !name.isEmpty && (" " + words + " ").contains(" " + name + " ")
    }
}

public extension SummaryEntry {
    var recordDetailHeading: String {
        if category == .medications, provenance == "Record choice review", (1...3).contains(title.split(separator: " ").count) { return title }
        if let name = citedAppointmentContact { return name }
        let sourceName = evidence?.medication?["name"] ?? title
        let label = RecordDetailTagLabel.make(sourceName, factKey: factKey)
        if label != "…" { return label }
        return category.displayTitle
    }

    var citedAppointmentContact: String? {
        guard category == .practitionerContact, let excerpt = supportingExcerpt,
              let match = excerpt.firstMatch(of: #/\b(?i:with)\s+((?:Dr\.?\s+)?\p{Lu}[\p{L}’'-]*(?:\s+\p{Lu}[\p{L}’'-]*){0,2})/#),
              (title + " " + details).localizedStandardContains(String(match.1)) else { return nil }
        return String(match.1)
    }
}

public enum RecordTemplateSelection: String, Codable, CaseIterable, Sendable {
    case auto = "Auto", categories = "Health categories", visit = "Visit"

    public func resolved(for record: Session) -> Self {
        guard self == .auto else { return self }
        guard record.entryIntent != .personalJournal else { return .categories }
        let text = record.transcript.lowercased()
        func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        let encounter = matches(#"\b(?:at (?:my|our|today’s|today's) (?:visit|appointment)|we discussed|seen today for|history of present illness|reason for (?:visit|encounter)|visit summary|after.visit summary)\b"#)
        let dialogue = matches(#"(?m)^\s*(?:clinician|midwife|doctor|provider|dr\.? [\p{L}-]+):"#) && matches(#"(?m)^\s*patient:"#)
        let conversationalVisit = matches(#"\b(?:any questions for me|how are you (?:feeling|doing)|what brings you in)\b"#) && text.contains("?")
        if encounter || dialogue || conversationalVisit { return .visit }
        if matches(#"\b(?:prescription|rx|refills?|lab report|reference range)\b"#) { return .categories }
        let title = [record.editedRecordTitle, record.capture?.patientTitle, record.title].compactMap { $0 }.first { !$0.isEmpty }?.lowercased() ?? ""
        if title.range(of: #"\b(?:appointment|appt|consultation|visit)\b"#, options: .regularExpression) != nil { return .visit }
        return record.inputType == .audio || record.sourceAssets?.contains(where: { $0.kind == .audio }) == true ? .visit : .categories
    }
}

public enum RecordVisitSection: String, Codable, CaseIterable, Sendable {
    case discussed = "Discussed", decided = "Decided", nextSteps = "Next steps"
}

public struct RecordBullet: Codable, Hashable, Sendable {
    /// Adjust generated prose only. Quotes and explicit references to other people stay verbatim.
    public static func patientCenteredText(_ text: String) -> String {
        var quoted = false
        return text.components(separatedBy: "\n").map { line in
            let containsQuote = line.contains("“") || line.contains("”") || line.contains("\"")
            defer {
                for character in line {
                    if character == "“" { quoted = true }
                    if character == "”" { quoted = false }
                    if character == "\"" { quoted.toggle() }
                }
            }
            guard !quoted, !containsQuote else { return line }
            return line.replacingOccurrences(
                of: #"(?i)(^|[.!?]\s+)(?:the patient|patient)\s+(reports|reported|describes|described|declined|agreed|prefers|preferred|may|might|thinks|is|has|feels|wants|wanted|plans|asked|denies|denied)\b"#,
                with: "$1$2", options: .regularExpression
            ).replacingOccurrences(of: #"(?i)(^|[.!?]\s+)reports\s+(?!that\b)"#, with: "$1Reported ", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)(^|[.!?]\s+)is considering\b"#, with: "$1Considering", options: .regularExpression)
                .split(separator: "\n", omittingEmptySubsequences: false).map { value in
                    guard let first = value.first else { return "" }
                    return first.uppercased() + value.dropFirst()
                }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    public var heading: String
    public var text: String
    public var passages: [Int]
    public var detailEntryIDs: [UUID]?
    public var bulletID: UUID?
    public var visitSection: RecordVisitSection?
    public var resolvedVisitSection: RecordVisitSection {
        switch choice?.stance {
        case "booked": return .nextSteps
        case "declined", "deferred": return .decided
        case "question", "tentative preference": return .discussed
        case "agreed": return visitSection == .nextSteps ? .nextSteps : .decided
        default: return visitSection ?? .discussed
        }
    }
    public var medicationTopic: String?
    public var choice: RecordChoice?
    public var evidenceQuotes: [String]?
    public var quote: String?
    public var editKey: String { bulletID?.uuidString ?? "bullet|" + heading + "|" + text }

    static func groupedByCategory(_ bullets: [RecordBullet]) -> [RecordBullet] {
        let positions = Dictionary(uniqueKeysWithValues: SummaryEntryCategory.allCases.enumerated().map { ($0.element.displayTitle, $0.offset) })
        return bullets.sorted { (positions[$0.heading] ?? Int.max) < (positions[$1.heading] ?? Int.max) }
    }

    /// Recognize directly adjacent replies to named medication discussions. Keep the
    /// literal PDF text for citations even when the extractor inserts line breaks.
    public static func explicitMedicationReplies(passages: [String], names: [String]) -> [RecordBullet] {
        var points: [RecordBullet] = []
        var seen = Set<String>()
        for (index, passage) in passages.enumerated() {
            for name in Set(names).sorted() where !name.isEmpty {
                let literal = name.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
                // Restrict pronoun resolution to a named option or a question about
                // that medication immediately followed by a personal response.
                let option = #"\s+is\s+(?:definitely\s+)?(?:your|an?|the)\s+(?:[\w-]+\s+){0,2}(?:option|method|version)(?:\s+(?:of|for)\s+[\w-]+)?"#
                let inquiry = #",\s+(?:no one|nobody)\s+(?:had\s+)?(?:followed\s+up|got\s+back)(?:\s+(?:with|to)\s+me)?(?:\s+about\s+(?:that|it))?"#
                let subject = #"\b("# + literal + #"(?:\s+(?:shot|injection))?(?:"# + option + "|" + inquiry + #")[.?!])"#
                let reply = #"\s+(?:(?:I\s+(?:talked|spoke)\s+about\s+(?:oral|injections?)\s+with\s+\w+[, ]+(?:and\s+)?(?:but\s+)?(?:anyway,)?|But)\s+)?(I\s+(?:don['’]t want to do it(?:, no)?|think\s+(?:that\s+)?we['’]re\s+ok(?:ay)? to do it))[.!]"#
                guard let re = try? NSRegularExpression(pattern: subject + reply, options: [.caseInsensitive]) else { continue }
                for match in re.matches(in: passage, range: NSRange(passage.startIndex..., in: passage)) {
                    guard let sr = Range(match.range(at: 1), in: passage), let rr = Range(match.range(at: 2), in: passage) else { continue }
                    let subjectText = String(passage[sr]), answer = String(passage[rr])
                    guard seen.insert(name.lowercased() + "|" + answer.lowercased()).inserted else { continue }
                    let hesitant = answer.localizedCaseInsensitiveContains("think")
                    let choice = RecordChoice(topic: name, recipient: "unspecified", stance: hesitant ? "tentative preference" : "declined",
                        subjectQuote: subjectText, responseQuote: answer)
                    let replyText = answer.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    var point = RecordBullet(heading: SummaryEntryCategory.medications.displayTitle,
                        text: hesitant ? "Discussed \(name). “\(replyText).”" : "Declined \(name) this time.",
                        passages: [index + 1])
                    point.quote = subjectText
                    point.evidenceQuotes = [subjectText, answer]
                    point.choice = choice
                    point.medicationTopic = name
                    points.append(point)
                }
            }
        }
        return points
    }

    public static func applyingChoiceReview(_ reviewed: [RecordBullet], to draft: [RecordBullet]) -> [RecordBullet] {
        var merged = draft
        for var point in reviewed {
            guard let choice = point.choice, choice.isGrounded else { continue }
            let medication = point.heading == SummaryEntryCategory.medications.displayTitle
            if medication {
                point.medicationTopic = choice.topic
                let response = choice.responseQuote
                if response.range(of: #"(?i)\bI think (?:we|I)(?:['’]re| are| am)? (?:ok(?:ay)?|fine) to (?:do it|proceed)\b"#, options: .regularExpression) != nil {
                    let recipient = choice.recipient.trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = ["", "unspecified", "unknown", "patient", "the patient", "self"].contains(recipient.lowercased()) ? "" : " (\(recipient))"
                    let reply = response.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    point.text = "Discussed \(choice.topic)\(suffix). “\(reply)”"
                    point.choice = RecordChoice(topic: choice.topic, recipient: choice.recipient, stance: "tentative preference",
                        subjectQuote: choice.subjectQuote, responseQuote: response)
                }
            }
            merged.removeAll { prior in
                guard prior.heading == point.heading else { return false }
                if medication {
                    let qualifiers = ["shot", "injection", "option", "induction"]
                    var words = Self.words(choice.topic)
                    while words.count > 1 && qualifiers.contains(words.last!) { words.removeLast() }
                    let topic = " " + words.joined(separator: " ") + " "
                    guard (" " + Self.words(prior.text).joined(separator: " ") + " ").contains(topic) else { return false }
                    // Keep separately documented prescriptions or administrations.
                    let overlaps = !Set(prior.evidenceQuotes ?? []).isDisjoint(with: point.evidenceQuotes ?? [])
                    let decision = prior.text.range(of: #"(?i)\b(patient|agreed|declined|prefers?|discussed|proceed|will receive|will be administered)\b"#, options: .regularExpression) != nil
                    let sameStance = prior.choice?.stance == point.choice?.stance
                    return overlaps || (decision && (prior.choice == nil || sameStance || prior.choice?.responseQuote == choice.responseQuote))
                }
                return !Set(prior.evidenceQuotes ?? []).isDisjoint(with: point.evidenceQuotes ?? [])
            }
            merged.append(point)
        }
        return merged
    }

    public func supports(_ entry: SummaryEntry) -> Bool {
        if let key = entry.linkedSummaryBlockKey { return key == editKey }
        guard let quote, let excerpt = entry.supportingExcerpt else { return false }
        if heading == SummaryEntryCategory.medications.displayTitle && entry.category != .medications { return false }
        if entry.category == .practitionerContact,
           let name = entry.citedAppointmentContact,
           text.localizedStandardContains("with " + name),
           (evidenceQuotes ?? [quote]).contains(where: { $0.localizedStandardContains(excerpt) }) {
            return true
        }
        if entry.category == .medications, let topic = medicationTopic ?? choice?.topic,
           entry.title.localizedStandardContains(topic),
           (evidenceQuotes ?? [quote]).contains(where: { $0.localizedStandardContains(excerpt) }) {
            return true
        }
        if let choice {
            let plan = choice.stance == "booked" && (entry.category == .carePlan || entry.category == .followUp)
            guard plan || choice.namesTopic(in: entry.title + " " + entry.details) else { return false }
            // Match the cited response as well as the topic. Two people can discuss
            // the same intervention with different intentions.
            let response = Self.words(choice.responseQuote)
            let source = Self.words(excerpt)
            guard !response.isEmpty, !source.isEmpty else { return false }
            return (" " + source.joined(separator: " ") + " ").contains(" " + response.joined(separator: " ") + " ")
        }
        return (evidenceQuotes ?? [quote]).contains { evidence in
            matches(entry, evidence: evidence, excerpt: excerpt)
        }
    }
    private func matches(_ entry: SummaryEntry, evidence: String, excerpt: String) -> Bool {
        let a = Self.words(evidence), b = Self.words(excerpt)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let left = " " + a.joined(separator: " ") + " "
        let right = " " + b.joined(separator: " ") + " "
        guard left.contains(right) || right.contains(left) else { return false }
        let subject = Set(Self.words(entry.title)).subtracting(["the","and","with","patient","plan","visit","for","follow","up","care"])
        return !subject.isDisjoint(with: Self.words(text))
    }

    static func words(_ value: String) -> [String] {
        value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    public init(heading: String, text: String, passages: [Int]) {
        self.heading = heading
        self.text = text
        self.passages = passages
    }
}

public struct RecordSummaryWork: Codable, Hashable, Sendable {
    public var serviceWorkflowVersion: String? = nil
    public let id: UUID
    public let source: String
    public var selection: RecordTemplateSelection?
    public var nextPass: Int
    public var bullets: [RecordBullet]
    public init(source: String) {
        id = UUID()
        self.source = source
        nextPass = 0
        bullets = []
    }
}

public struct Session: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var date: Date
    public var transcript: String
    /// Short appointment title generated by the AI summary (e.g. "Back pain follow-up").
    /// `nil` until a summary has been requested for this session.
    public var title: String?
    /// Full medical summary in markdown, generated on demand and cached here.
    /// `nil` until a summary has been requested for this session.
    public var summary: String?
    /// Structured, editable cards generated from the source transcript or imported from legacy markdown.
    public var summaryEntries: [SummaryEntry]?
    /// How the transcript was captured. Defaults to `.audio` for legacy sessions.
    public var inputType: SessionInputType
    /// User-selected intent for audio (and audio file) entries; defaults to clinical visit for legacy data.
    public var entryIntent: SessionEntryIntent
    /// Optional folder assignment; `nil` means the entry is only listed under “All entries.”
    /// nil follows automatic filing. An empty set is an explicit patient choice.
    public var selectedFolderIDs: Set<UUID>?
    public var folderID: UUID?
    /// Original uploaded or recorded files; `nil`/empty for legacy transcript-only sessions.
    public var sourceAssets: [SessionSourceAsset]?
    public var processingState: RecordProcessingState?
    public var processingError: String?
    public var extractionVersion: Int?
    public var visitTime: Date?
    public var linkedMemberIDs: Set<UUID>?
    public var editedRecordTitle: String?
    public var removedRecordDetails: Set<String>?
    public static func removalKeys(_ entry: SummaryEntry) -> Set<String> {
        var keys: Set<String> = [entry.id.uuidString]
        if let quote = entry.supportingExcerpt {
            let normalized = RecordBullet.words(quote).joined(separator: " ")
            keys.insert(entry.category.rawValue + "|" + RecordBullet.words(entry.title).joined(separator: " ") + "|" + normalized)
            keys.insert(HealthMemoryProjection.key(for: entry) + "|" + normalized)
        }
        return keys
    }
    public var recordBullets: [RecordBullet]?
    public var recordTemplateSelection: RecordTemplateSelection?
    public var appliedRecordTemplate: RecordTemplateSelection?
    public var recordSummarySource: String?
    public var recordSummaryWork: RecordSummaryWork?
    public var summaryParagraphEdits: [String: String]?
    public var capture: RecordCapture?
    public var summaryRun: SummaryRun?
    public var summaryDrafts: [SummaryEntry]?
    public var summaryRevisions: [SummaryRevision]?

    enum CodingKeys: String, CodingKey {
        case recordTemplateSelection, appliedRecordTemplate, removedRecordDetails, recordBullets, recordSummarySource, recordSummaryWork, summaryParagraphEdits, visitTime, linkedMemberIDs, editedRecordTitle, capture, id, date, transcript, title, summary, summaryEntries, inputType, entryIntent, folderID, selectedFolderIDs, sourceAssets, processingState, processingError, extractionVersion, summaryRun, summaryRevisions, summaryDrafts
    }

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        transcript: String,
        title: String? = nil,
        summary: String? = nil,
        summaryEntries: [SummaryEntry]? = nil,
        inputType: SessionInputType = .audio,
        entryIntent: SessionEntryIntent = .clinicalVisit,
        folderID: UUID? = nil,
        sourceAssets: [SessionSourceAsset]? = nil
    ) {
        self.id = id
        self.date = date
        self.transcript = transcript
        self.title = title
        self.summary = summary
        self.summaryEntries = summaryEntries
        self.inputType = inputType
        self.entryIntent = entryIntent
        self.folderID = folderID
        self.sourceAssets = sourceAssets
        self.processingState = nil
        self.processingError = nil
        self.extractionVersion = nil
    }

    // Custom decoder so existing persisted sessions (without inputType) default to .audio.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self,   forKey: .id)
        date      = try c.decode(Date.self,   forKey: .date)
        visitTime = try c.decodeIfPresent(Date.self, forKey: .visitTime)
        linkedMemberIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .linkedMemberIDs)
        editedRecordTitle = try c.decodeIfPresent(String.self, forKey: .editedRecordTitle)
        summaryParagraphEdits = try c.decodeIfPresent([String: String].self, forKey: .summaryParagraphEdits)
        removedRecordDetails = try c.decodeIfPresent(Set<String>.self, forKey: .removedRecordDetails)
        recordBullets = try c.decodeIfPresent([RecordBullet].self, forKey: .recordBullets)
        recordTemplateSelection = try c.decodeIfPresent(RecordTemplateSelection.self, forKey: .recordTemplateSelection)
        appliedRecordTemplate = try c.decodeIfPresent(RecordTemplateSelection.self, forKey: .appliedRecordTemplate)
        recordSummarySource = try c.decodeIfPresent(String.self, forKey: .recordSummarySource)
        recordSummaryWork = try c.decodeIfPresent(RecordSummaryWork.self, forKey: .recordSummaryWork)
        capture = try c.decodeIfPresent(RecordCapture.self, forKey: .capture)
        transcript = try c.decode(String.self, forKey: .transcript)
        title     = try c.decodeIfPresent(String.self, forKey: .title)
        summary   = try c.decodeIfPresent(String.self, forKey: .summary)
        summaryEntries = try c.decodeIfPresent([SummaryEntry].self, forKey: .summaryEntries)
        inputType = try c.decodeIfPresent(SessionInputType.self, forKey: .inputType) ?? .audio
        entryIntent = try c.decodeIfPresent(SessionEntryIntent.self, forKey: .entryIntent) ?? .clinicalVisit
        selectedFolderIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .selectedFolderIDs)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        sourceAssets = try c.decodeIfPresent([SessionSourceAsset].self, forKey: .sourceAssets)
        processingState = try c.decodeIfPresent(RecordProcessingState.self, forKey: .processingState)
        processingError = try c.decodeIfPresent(String.self, forKey: .processingError)
        extractionVersion = try c.decodeIfPresent(Int.self, forKey: .extractionVersion)
        summaryRun = try c.decodeIfPresent(SummaryRun.self, forKey: .summaryRun)
        summaryDrafts = try c.decodeIfPresent([SummaryEntry].self, forKey: .summaryDrafts)
        summaryRevisions = try c.decodeIfPresent([SummaryRevision].self, forKey: .summaryRevisions)
    }
}
