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

/// Whether a clinical fact is ongoing, inactive, or resolved.
public enum SummaryEntryClinicalStatus: String, Hashable, Sendable, CaseIterable {
    case active
    case inactive
    case resolved

    public var displayTitle: String {
        switch self {
        case .active: return "Active"
        case .inactive: return "Inactive"
        case .resolved: return "Resolved"
        }
    }

    /// Section order for summary lists (active → resolved → inactive).
    public static let summarySectionOrder: [SummaryEntryClinicalStatus] = [.active, .resolved, .inactive]

    /// Most current status wins when stacking multiple sources (active → inactive → resolved).
    public static func dominant(in statuses: some Sequence<SummaryEntryClinicalStatus>) -> SummaryEntryClinicalStatus {
        let set = Set(statuses)
        if set.contains(.active) { return .active }
        if set.contains(.inactive) { return .inactive }
        return .resolved
    }
}

extension SummaryEntryClinicalStatus: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "active":
            self = .active
        case "inactive":
            self = .inactive
        case "resolved":
            self = .resolved
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown clinical status: \(raw)"
            )
        }
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
    public var title: String
    public var details: String
    public var fields: [SummaryEntryField]
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
    /// Active, inactive, or resolved problem/item status. Defaults to `.active` for legacy entries.
    public var clinicalStatus: SummaryEntryClinicalStatus
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, category, title, details, fields
        case relevantDate, dateNeedsReview
        case sourceSessionID, sourceTitle, sourceDate, sourceExcerpt
        case provenance, needsReview, reviewReason, isDeleted, origin
        case clinicalStatus, createdAt, updatedAt
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
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.details = details
        self.fields = fields
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        category = try c.decode(SummaryEntryCategory.self, forKey: .category)
        title = try c.decode(String.self, forKey: .title)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        fields = try c.decodeIfPresent([SummaryEntryField].self, forKey: .fields) ?? []
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
    }

    /// Infer status from wording when the model or user did not set one explicitly.
    public static func inferredStatus(title: String, details: String) -> SummaryEntryClinicalStatus {
        let hay = "\(title) \(details)".lowercased()
        let resolvedHints = [
            "resolved", "resolution", "cleared", "gone", "healed", "in remission",
            "has resolved", "was resolved", "fully resolved", "symptom-free", "symptom free",
            "no longer present", "completed course",
        ]
        if resolvedHints.contains(where: { hay.contains($0) }) {
            return .resolved
        }
        let inactiveHints = [
            "inactive", "discontinued", "stopped taking", "no longer taking", "not currently",
            "on hold", "paused", "held", "withdrawn", "off medication", "no longer on",
        ]
        if inactiveHints.contains(where: { hay.contains($0) }) {
            return .inactive
        }
        return .active
    }
}

/// A persisted recording session: metadata, full transcript, and optional AI-generated fields.
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
    public var folderID: UUID?
    /// Original uploaded or recorded files; `nil`/empty for legacy transcript-only sessions.
    public var sourceAssets: [SessionSourceAsset]?

    enum CodingKeys: String, CodingKey {
        case id, date, transcript, title, summary, summaryEntries, inputType, entryIntent, folderID, sourceAssets
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
    }

    // Custom decoder so existing persisted sessions (without inputType) default to .audio.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self,   forKey: .id)
        date      = try c.decode(Date.self,   forKey: .date)
        transcript = try c.decode(String.self, forKey: .transcript)
        title     = try c.decodeIfPresent(String.self, forKey: .title)
        summary   = try c.decodeIfPresent(String.self, forKey: .summary)
        summaryEntries = try c.decodeIfPresent([SummaryEntry].self, forKey: .summaryEntries)
        inputType = try c.decodeIfPresent(SessionInputType.self, forKey: .inputType) ?? .audio
        entryIntent = try c.decodeIfPresent(SessionEntryIntent.self, forKey: .entryIntent) ?? .clinicalVisit
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        sourceAssets = try c.decodeIfPresent([SessionSourceAsset].self, forKey: .sourceAssets)
    }
}
