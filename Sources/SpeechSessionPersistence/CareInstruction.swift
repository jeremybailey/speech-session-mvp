import Foundation

/// Optional source-derived fields. Absence is not an invitation to invent a schedule or goal.
public struct CareInstruction: Codable, Equatable, Hashable, Sendable {
    public var bucket: CarePlanBucket?
    public var owner: String?
    public var consideration: String?
    public var instruction: String?
    public var directions: String?
    public var goal: String?
    public var schedule: String?
    public var reviewTiming: String?
    public var isRecurring: Bool?
    public init(instruction: String? = nil, directions: String? = nil, goal: String? = nil,
                schedule: String? = nil, reviewTiming: String? = nil, isRecurring: Bool? = nil) {
        self.instruction = instruction; self.directions = directions; self.goal = goal
        self.schedule = schedule; self.reviewTiming = reviewTiming; self.isRecurring = isRecurring
    }
}

public enum CarePlanBucket: String, Codable, CaseIterable, Sendable {
    case carePlan, followUp, considerations
    public var title: String {
        switch self { case .carePlan: return "Care plan"; case .followUp: return "Follow-up"; case .considerations: return "Other considerations" }
    }
}

public enum CareInstructionPresentation {
    public static func applies(_ entry: SummaryEntry) -> Bool { entry.category == .carePlan || entry.category == .followUp }
    public static func bucket(_ fact: HealthFact) -> CarePlanBucket {
        fact.latest.evidence?.careInstruction?.bucket ?? (fact.category == .followUp ? .followUp : .carePlan)
    }
    public static func sourceOrderDate(_ entry: SummaryEntry, sessions: [Session]) -> Date? {
        let session = sessions.first { $0.id == entry.sourceSessionID }
        if session?.inputType == .audio { return entry.sourceDate }
        // An uploaded document's timestamp is not the recommendation's date.
        if entry.evidence?.eventDate?.isEmpty == false { return entry.relevantDate }
        return nil
    }
    public static func dateLabel(_ entry: SummaryEntry, sessions: [Session]) -> String {
        let session = sessions.first { $0.id == entry.sourceSessionID }
        if session?.inputType == .audio, let date = entry.sourceDate {
            return "Source: " + date.formatted(date: .abbreviated, time: .omitted)
        }
        if let date = entry.evidence?.eventDate, !date.isEmpty { return "Recorded: " + date }
        if let date = entry.sourceDate { return "Source date unknown · Added " + date.formatted(date: .abbreviated, time: .omitted) }
        return "Source date unknown"
    }
    public static func sorted(_ facts: [HealthFact], sessions: [Session]) -> [HealthFact] {
        facts.sorted {
            let a = $0.occurrences.compactMap { sourceOrderDate($0, sessions: sessions) }.max() ?? .distantPast
            let b = $1.occurrences.compactMap { sourceOrderDate($0, sessions: sessions) }.max() ?? .distantPast
            return a == b ? $0.id < $1.id : a > b
        }
    }
    public static func canonical(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "knapsack", with: "backpack")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { !["the"].contains($0) }.joined(separator: " ")
    }
    public static func instruction(_ entry: SummaryEntry) -> String {
        if let text = entry.evidence?.careInstruction?.instruction, !text.isEmpty { return HealthStoryText.clean(text) }
        let title = HealthStoryText.clean(entry.title), details = HealthStoryText.clean(entry.details)
        // Legacy noun headings (e.g. Backpack Adjustment) add no instruction of their own.
        let verbs = ["adjust", "take", "do", "keep", "bring", "call", "book", "apply", "avoid", "continue", "stop", "start", "perform", "use", "walk", "stretch", "discuss", "record", "return", "see"]
        let first = canonical(details).split(separator: " ").first.map(String.init) ?? ""
        let titleFirst = canonical(title).split(separator: " ").first.map(String.init) ?? ""
        if !details.isEmpty && (title.isEmpty || (verbs.contains(first) && !verbs.contains(titleFirst))) { return details }
        return title.isEmpty ? "Instruction to check" : title
    }
    public static func supportingText(_ entry: SummaryEntry) -> [String] {
        let main = canonical(instruction(entry))
        var seen = Set([main])
        let care = entry.evidence?.careInstruction
        var texts = [care?.directions ?? HealthStoryText.clean(entry.details)]
        if let value = care?.schedule, !value.isEmpty { texts.append("When: " + value) }
        if let value = care?.goal, !value.isEmpty { texts.append("Goal: " + value) }
        if let value = care?.reviewTiming, !value.isEmpty { texts.append("Review: " + value) }
        return texts.filter { !$0.isEmpty && seen.insert(canonical($0)).inserted }
    }
    public static func recurring(_ entry: SummaryEntry) -> Bool {
        if let recurring = entry.evidence?.careInstruction?.isRecurring { return recurring }
        let text = canonical([instruction(entry), entry.details, entry.evidence?.careInstruction?.schedule ?? ""].joined(separator: " "))
        return ["daily", "weekly", "every", "per day", "per week", "as needed", "continue"].contains { text.contains($0) }
    }
    public static func status(_ fact: HealthFact) -> String {
        if fact.isAction { return fact.actionStatus == .past ? "Non-current" : fact.actionStatus.title }
        if fact.category == .medications && !fact.hasKnownStatus { return "Current use unknown" }
        return fact.hasKnownStatus ? fact.statusTitle : "Status unknown"
    }
    public static func reviewIndicator(_ fact: HealthFact) -> String? {
        if fact.latest.evidence?.actionKind == "uncertain" { return "Check what was recommended" }
        return fact.needsReview ? fact.reviewReasons.first : nil
    }
    /// Deliberately conservative. Matching titles alone never establish equivalent instructions.
    public static func equivalent(_ a: SummaryEntry, _ b: SummaryEntry, allowDifferentEvidence: Bool = false) -> Bool {
        // Never discard a heading's laterality, negation or numeric qualifier during legacy cleanup.
        let qualifiers: Set<String> = ["left", "right", "bilateral", "not", "no", "without", "avoid", "stop", "daily", "weekly"]
        for entry in [a, b] {
            let heading = canonical(entry.title).split(separator: " ").map(String.init)
            let main = Set(canonical(instruction(entry)).split(separator: " ").map(String.init))
            if heading.contains(where: { (qualifiers.contains($0) || $0.contains(where: \.isNumber)) && !main.contains($0) }) { return false }
        }
        func clinicalKey(_ value: String) -> String {
            HealthFactMatching.canonical(value).split(separator: " ").filter { $0 != "the" }.joined(separator: " ")
        }
        func extraFields(_ entry: SummaryEntry) -> [String] {
            let repeated = Set([entry.title, entry.details, instruction(entry)].map(clinicalKey))
            return entry.fields.filter { !$0.value.isEmpty && !repeated.contains(clinicalKey($0.value)) }
                .map { clinicalKey($0.label) + "=" + clinicalKey($0.value) }.sorted()
        }
        guard a.evidence?.combinationExcluded != true, b.evidence?.combinationExcluded != true, applies(a), a.category == b.category, a.sourceSessionID != nil, b.sourceSessionID != nil,
              a.origin != .userEdited, b.origin != .userEdited, a.origin != .userAdded, b.origin != .userAdded,
              clinicalKey(instruction(a)) == clinicalKey(instruction(b)),
              supportingText(a).map(clinicalKey).sorted() == supportingText(b).map(clinicalKey).sorted(),
              extraFields(a) == extraFields(b),
              let ae = a.evidence, let be = b.evidence,
              ae.practitioner == be.practitioner, ae.eventDate == be.eventDate,
              ae.bodySystem == be.bodySystem, ae.dose == be.dose, ae.actionKind == be.actionKind,
              a.clinicalStatus == b.clinicalStatus, ae.frequency == be.frequency,
              ae.careInstruction?.bucket == be.careInstruction?.bucket,
              ae.careInstruction?.owner == be.careInstruction?.owner,
              ae.careInstruction?.consideration == be.careInstruction?.consideration,
              ae.careInstruction?.isRecurring == be.careInstruction?.isRecurring else { return false }
        if !allowDifferentEvidence {
            guard a.sourceSessionID == b.sourceSessionID,
                  let ax = ae.excerpt, let bx = be.excerpt, !ax.isEmpty, clinicalKey(ax) == clinicalKey(bx) else { return false }
        } else if a.sourceSessionID != b.sourceSessionID {
            // Cross-record repetition must identify the same practitioner and clinical event.
            guard ae.practitioner?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  ae.eventDate?.isEmpty == false else { return false }
        }
        return true
    }
}

public struct CareCombinationUndo: Sendable {
    public let identities: [UUID: String]
    public let absentIdentities: Set<UUID>
}
