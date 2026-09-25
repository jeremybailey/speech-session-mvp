import Foundation

/// The clinical taxonomy stays on SummaryEntryCategory. Topics are optional, many-to-many links.
public struct HealthTopic: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bodySystem: String
    public init(id: UUID = UUID(), name: String, bodySystem: String = "") {
        self.id = id; self.name = name; self.bodySystem = bodySystem
    }
}

public struct CareTeamMember: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var role: String
    public var organization: String
    public var email: String
    public var phone: String
    public var address: String?
    public var notes: String
    public var sourceEntryIDs: [UUID]
    public var duplicateOf: UUID?
    public var combinationExcluded: Bool?
    public init(id: UUID = UUID(), name: String = "", role: String = "", organization: String = "", email: String = "", phone: String = "", address: String? = nil, notes: String = "", sourceEntryIDs: [UUID] = []) {
        self.id = id; self.name = name; self.role = role; self.organization = organization
        self.email = email; self.phone = phone; self.address = address; self.notes = notes; self.sourceEntryIDs = sourceEntryIDs
    }
}

public enum CareActionStatus: String, Codable, CaseIterable, Sendable {
    case current, completed, paused, past
    public var title: String { rawValue.capitalized }
}

/// Structured provenance. Dates remain source text so a year is never silently converted to a day.
public struct ClinicalEvidence: Codable, Equatable, Hashable, Sendable {
    public var omittedFields: [String]?
    public var assessment: SummaryAssessment?
    public var contactFields: [SummaryEntryField]?
    public var eventDate: String?
    public var excerpt: String?
    public var page: Int?
    public var practitioner: String?
    public var assessmentMethod: String?
    public var topicNames: [String]?
    public var bodySystem: String?
    public var dose: String?
    public var frequency: String?
    public var reasonStarted: String?
    public var reasonStopped: String?
    /// homecare, follow_up, treatment_received, self_directed, or uncertain.
    public var actionKind: String?
    public var careInstruction: CareInstruction?
    public var instructionIdentity: String?
    public var factIdentity: String?
    public var combinationExcluded: Bool?
    public var combinationPrimary: Bool?
    public var statusExplicit: Bool?
    public var reviewReason: String?
    public init() {}
}

/// A patient's decisions about a fact, independent of any one source occurrence.
public struct HealthFactPreference: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var topicIDs: [UUID]?
    public var clinicalStatus: SummaryEntryClinicalStatus?
    public var actionStatus: CareActionStatus?
    public var dueDate: Date?
    public var reminderEnabled: Bool
    public var reviewedRevision: String?
    public var hidden: Bool
    public var updatedAt: Date
    public init(id: String) {
        self.id = id; reminderEnabled = false; hidden = false; updatedAt = Date()
    }
}

public struct PatientProfile: Codable, Equatable, Sendable {
    public var personalHealthNumber: String = ""
    public var completedIntroduction: Bool = false
    public init() {}
}

public struct HealthMemorySnapshot: Sendable {
    public var sessions: [Session]
    public var folders: [SessionFolder]
    public var topics: [HealthTopic]
    public var careTeam: [CareTeamMember]
    public var preferences: [HealthFactPreference]
    public var profile: PatientProfile
    public init(sessions: [Session] = [], folders: [SessionFolder] = [], topics: [HealthTopic] = [], careTeam: [CareTeamMember] = [], preferences: [HealthFactPreference] = [], profile: PatientProfile = .init()) {
        self.sessions = sessions; self.folders = folders; self.topics = topics
        self.careTeam = careTeam; self.preferences = preferences; self.profile = profile
    }
}

public struct HealthFact: Identifiable, Sendable {
    public let id: String
    public var occurrences: [SummaryEntry]
    public var preference: HealthFactPreference
    public var topicIDs: [UUID]
    public var latest: SummaryEntry { occurrences[0] }
    public var displayEntry: SummaryEntry { ContactHistoryPresentation.display(self) }
    public var category: SummaryEntryCategory { latest.category }
    public var title: String { latest.title }
    public var revision: String {
        occurrences.sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: "|")
    }
    public var isReviewed: Bool { preference.reviewedRevision == revision }
    public var clinicalStatus: SummaryEntryClinicalStatus {
        if let status = preference.clinicalStatus { return status }
        return occurrences.first(where: { $0.origin == .userAdded || $0.evidence?.statusExplicit == true })?.clinicalStatus ?? .current
    }
    public var hasKnownStatus: Bool {
        preference.clinicalStatus != nil || occurrences.contains { $0.origin == .userAdded || $0.evidence?.statusExplicit == true }
    }
    public var statusTitle: String { clinicalStatus == .current ? "Current" : "Non-current" }
    public var isCurrent: Bool { isAction ? actionStatus == .current : clinicalStatus == .current }
    public var actionStatus: CareActionStatus {
        preference.actionStatus ?? (clinicalStatus == .past ? .past : .current)
    }
    public var isAction: Bool {
        guard category == .carePlan || category == .followUp else { return false }
        return latest.evidence?.actionKind != "treatment_received"
    }
    public var reviewReasons: [String] {
        guard !isReviewed else { return [] }
        var reasons: [String] = []
        if let reason = latest.evidence?.reviewReason, !reason.isEmpty { reasons.append(reason) }
        if latest.supportingExcerpt == nil && latest.origin != .userAdded { reasons.append("Check this detail against the original record.") }
        if latest.dateNeedsReview { reasons.append("Confirm when this happened, or leave the date unknown.") }
        if latest.fields.contains(where: { $0.isMissing || $0.needsReview }) {
            reasons.append("Some details are missing. Add only what you know.")
        }
        if latest.evidence?.actionKind == "uncertain" { reasons.append("Check whether this is something to do at home or treatment already received.") }
        let dated = occurrences.filter { $0.evidence?.statusExplicit == true }
        if let first = dated.first, dated.contains(where: { $0.relevantDate == first.relevantDate && $0.clinicalStatus != first.clinicalStatus }) {
            reasons.append("Sources disagree about the current status.")
        }
        return Array(Set(reasons)).sorted()
    }
    public var needsReview: Bool { !reviewReasons.isEmpty }
    public var canShowAsNextStep: Bool {
        isAction && actionStatus == .current
            && (["homecare", "follow_up"].contains(latest.evidence?.actionKind ?? "") || (latest.evidence?.actionKind == "self_directed" && isReviewed))
    }

    /// Keep the shared identity and patient preferences while presenting this record's wording first.
    public func presentedFromRecord(_ sessionID: UUID) -> HealthFact? {
        let local = occurrences.filter { $0.sourceSessionID == sessionID }
        guard !local.isEmpty else { return nil }
        let other = occurrences.filter { $0.sourceSessionID != sessionID }
        return HealthFact(id: id, occurrences: local + other, preference: preference, topicIDs: topicIDs)
    }
}

/// Pure projection, computed outside view rendering. No fuzzy merging or inferred condition relationships.
public enum HealthMemoryProjection {
    public static func key(for entry: SummaryEntry) -> String {
        if CareInstructionPresentation.applies(entry), let identity = entry.evidence?.instructionIdentity { return identity }
        if let identity = entry.evidence?.factIdentity { return identity }
        if !CareInstructionPresentation.applies(entry) { return HealthFactMatching.key(entry) }
        return legacyKey(for: entry)
    }

    public static func legacyKey(for entry: SummaryEntry) -> String {
        let name = SummaryEntry.normalizedFactKey(entry.factKey ?? entry.title) ?? entry.id.uuidString
        var key = "\(entry.category.rawValue)|\(name)"
        // Instructions from different sources remain separate recommendations, even with the same title.
        if entry.category == .carePlan || entry.category == .followUp {
            key += "|\(entry.sourceSessionID?.uuidString ?? entry.id.uuidString)|\(entry.id.uuidString)"
        }
        return key
    }

    public static func facts(in snapshot: HealthMemorySnapshot, includingHidden: Bool = false, verifiedOnly: Bool = true, groupHistoryForDisplay: Bool = true) -> [HealthFact] {
        let preferences = Dictionary(snapshot.preferences.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let entries = snapshot.sessions.flatMap { session in
            let sourceHash = verifiedOnly ? SummaryVerification.hash(session.transcript) : ""
            return (session.summaryEntries ?? []).filter { !$0.isDeleted && (!verifiedOnly || SummaryVerification.isVisible($0, sourceHash: sourceHash)) }
        }
        var keys = HealthFactKeyCache()
        let facts = Dictionary(grouping: entries, by: { keys.key($0) }).compactMap { key, entries -> HealthFact? in
            let preference = preferences[key] ?? HealthFactPreference(id: key)

            let sorted = entries.sorted {
                if ($0.evidence?.combinationPrimary == true) != ($1.evidence?.combinationPrimary == true) {
                    return $0.evidence?.combinationPrimary == true
                }
                // A combined instruction keeps the chosen primary entry's presentation and edits.
                let leftPrimary = key.hasSuffix($0.id.uuidString)
                let rightPrimary = key.hasSuffix($1.id.uuidString)
                if leftPrimary != rightPrimary { return leftPrimary }
                let left = $0.relevantDate ?? .distantPast
                let right = $1.relevantDate ?? .distantPast
                if left != right { return left > right }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            let topicNames = Set(entries.flatMap { $0.evidence?.topicNames ?? [] }.map(normalize))
            let topicIDs = preference.topicIDs ?? snapshot.topics.filter { topicNames.contains(normalize($0.name)) }.map(\.id)
            return HealthFact(id: key, occurrences: sorted, preference: preference, topicIDs: topicIDs)
        }
        let presented = groupHistoryForDisplay ? ContactHistoryPresentation.group(MedicationHistoryPresentation.group(facts)) : facts
        return presented.filter { includingHidden || !$0.preference.hidden }.sorted {
            if $0.clinicalStatus != $1.clinicalStatus { return $0.clinicalStatus == .current }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    public static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public enum RecordProcessingState: String, Codable, Sendable {
    case saved, transcribing, ready, failed
}

public enum EvidenceValidation {
    public static func matchingExcerpt(_ excerpt: String?, in transcript: String) -> String? {
        guard let excerpt = excerpt?.trimmingCharacters(in: .whitespacesAndNewlines), !excerpt.isEmpty else { return nil }
        return transcript.range(of: excerpt, options: [.caseInsensitive, .diacriticInsensitive]) == nil ? nil : excerpt
    }

    /// Only an explicit complete calendar date becomes Date; partial dates remain display text.
    public static func exactDate(_ value: String?) -> Date? {
        guard let value, value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }
}
