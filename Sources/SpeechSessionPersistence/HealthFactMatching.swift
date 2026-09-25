import Foundation

/// Local equivalence only: model-generated keys never establish clinical equivalence.
public enum HealthFactMatching {
    private static let replacements: [(NSRegularExpression, String)] = [
        (#"(?<=\p{L})-(?=\p{L})"#, " "),
        (#"\bheadaches\b"#, "headache"),
        (#"\b(pain in (the )?(lower|low) back|lower back ache|low back pain)\b"#, "lower back pain"),
        (#"\bpain in (?:the )?((?:(?:left|right|both|bilateral|upper|lower) )?(?:knee|knees|shoulder|shoulders|hip|hips|neck|back|arm|arms|leg|legs|wrist|wrists|ankle|ankles|foot|feet))\b"#, "$1 pain"),
        (#"\b(shortness of breath|breathlessness)\b"#, "shortness of breath"),
        (#"\b(trouble sleeping|difficulty sleeping)\b"#, "difficulty sleeping"),
        (#"\bknapsack\b"#, "backpack"),
        (#"^(the patient reports|patient reports|reports|reported)\s+"#, ""),
        (#"[^\p{L}\p{N}.+<>/=\-%°^:≤≥±]+"#, " ")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func canonical(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        var text = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        for (expression, replacement) in replacements {
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// Broad candidate discovery only; an independent original-source comparison decides equivalence.
    public static func symptomComparisonKey(_ entry: SummaryEntry) -> String {
        let words = canonical(entry.title).split(separator: " ").filter { !["in", "the", "of", "a"].contains(String($0)) }
        return entry.category.rawValue + "|" + words.prefix(1).joined(separator: " ")
    }

    public static func candidateKey(_ entry: SummaryEntry) -> String {
        let title = CareInstructionPresentation.applies(entry)
            ? CareInstructionPresentation.canonical(CareInstructionPresentation.instruction(entry)) : canonical(entry.title)
        return entry.category.rawValue + "|" + title
    }

    public static func signature(_ entry: SummaryEntry) -> String {
        let title = canonical(entry.title)
        let details = canonical(HealthStoryText.clean(entry.details))
        let fields = entry.fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { canonical($0.label) + "=" + canonical($0.value) }.sorted()
        let e = entry.evidence
        var parts = [title, details == title ? "" : details] + fields
        parts += [e?.bodySystem, e?.dose, e?.frequency, e?.reasonStarted, e?.reasonStopped, e?.assessmentMethod].map { canonical($0 ?? "") }
        switch entry.category {
        case .symptoms, .chiefComplaint, .medications, .allergies, .practitionerContact:
            break // Repeated visits are occurrences of the same symptom, with their dates retained.
        default:
            parts += [canonical(e?.practitioner ?? ""), canonical(e?.eventDate ?? "")]
            if e?.eventDate == nil, let date = entry.relevantDate { parts.append(String(date.timeIntervalSince1970)) }
            // Undated procedures/results must not collapse distinct events from different records.
            if [.testsAndLabs, .vaccinations, .findings].contains(entry.category), e?.eventDate == nil, entry.relevantDate == nil {
                parts.append(entry.sourceSessionID?.uuidString ?? entry.id.uuidString)
            }
        }
        return parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    public static func equivalent(_ a: SummaryEntry, _ b: SummaryEntry) -> Bool {
        guard a.category == b.category, !a.isDeleted, !b.isDeleted,
              a.evidence?.combinationExcluded != true, b.evidence?.combinationExcluded != true else { return false }
        if CareInstructionPresentation.applies(a) { return CareInstructionPresentation.equivalent(a, b) }
        if a.category == .practitionerContact {
            guard contactsMatch(contact(a), contact(b)) else { return false }
        }
        return !canonical(a.title).isEmpty && signature(a) == signature(b)
    }

    /// Reprocessing may expand wording, but must not transfer an identity to a different clinical assertion.
    public static func conflicts(_ a: SummaryEntry, _ b: SummaryEntry) -> Bool {
        func qualifiers(_ entry: SummaryEntry) -> Set<String> {
            let tokens = canonical(entry.title + " " + entry.details).split(separator: " ").map(String.init)
            let protected: Set<String> = ["left", "right", "bilateral", "no", "not", "without", "suspected", "confirmed", "negative", "positive", "daily", "weekly", "monthly"]
            return Set(tokens.filter { protected.contains($0) || $0.contains(where: \.isNumber) })
        }
        if qualifiers(a) != qualifiers(b) { return true }
        for (left, right) in [(a.evidence?.dose,b.evidence?.dose),(a.evidence?.frequency,b.evidence?.frequency),
                              (a.evidence?.bodySystem,b.evidence?.bodySystem),(a.evidence?.actionKind,b.evidence?.actionKind)] {
            if let left, let right, canonical(left) != canonical(right) { return true }
        }
        for field in a.fields {
            if let other = b.fields.first(where: { canonical($0.label) == canonical(field.label) }),
               !field.value.isEmpty, !other.value.isEmpty, canonical(field.value) != canonical(other.value) { return true }
        }
        if [.findings,.testsAndLabs,.vaccinations,.carePlan,.followUp].contains(a.category),
           let left = a.evidence?.eventDate, let right = b.evidence?.eventDate, left != right { return true }
        return false
    }

    public static func key(_ entry: SummaryEntry) -> String {
        let base = entry.category.rawValue + "|" + digest(signature(entry))
        if canonical(entry.title).isEmpty || entry.evidence?.combinationExcluded == true { return base + "|" + entry.id.uuidString }
        if entry.category == .practitionerContact {
            let c = contact(entry)
            if c.phone.isEmpty && c.email.isEmpty { return base + "|" + entry.id.uuidString }
        }
        return base
    }

    private static func digest(_ value: String) -> String {
        // Stable across launches and OS versions; this is an identity fingerprint, not cryptography.
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }

    public static func contact(_ entry: SummaryEntry) -> CareTeamMember {
        func field(_ label: String) -> String { entry.fields.first { canonical($0.label) == label }?.value ?? "" }
        return CareTeamMember(name: field("name").isEmpty ? entry.title : field("name"), role: field("role"),
                              organization: field("clinic"), email: field("email"), phone: field("phone"),
                              address: field("address"), sourceEntryIDs: [entry.id])
    }

    public static func contactsMatch(_ a: CareTeamMember, _ b: CareTeamMember) -> Bool {
        func phone(_ value: String) -> String { value.filter(\.isNumber) }
        let sameSource = !Set(a.sourceEntryIDs).isDisjoint(with: b.sourceEntryIDs)
        let sameEmail = !a.email.isEmpty && canonical(a.email) == canonical(b.email)
        let samePhone = !phone(a.phone).isEmpty && phone(a.phone) == phone(b.phone)
        guard canonical(a.name) == canonical(b.name), sameSource || sameEmail || samePhone else { return false }
        return contactsCompatible(a, b)
    }

    public static func contactsCompatible(_ a: CareTeamMember, _ b: CareTeamMember) -> Bool {
        func phone(_ value: String) -> String { value.filter(\.isNumber) }
        for (left, right) in [(a.role,b.role),(a.organization,b.organization),(a.email,b.email),(a.address ?? "",b.address ?? ""),(a.notes,b.notes)] {
            if !left.isEmpty && !right.isEmpty && canonical(left) != canonical(right) { return false }
        }
        return a.phone.isEmpty || b.phone.isEmpty || phone(a.phone) == phone(b.phone)
    }

    public static func displayContacts(_ members: [CareTeamMember]) -> [CareTeamMember] {
        members.filter { $0.duplicateOf == nil }.map { root in
            var result = root
            for other in members where other.duplicateOf == root.id {
                if result.role.isEmpty { result.role = other.role }
                if result.organization.isEmpty { result.organization = other.organization }
                if result.email.isEmpty { result.email = other.email }
                if result.phone.isEmpty { result.phone = other.phone }
                if result.address?.isEmpty != false { result.address = other.address }
                if result.notes.isEmpty { result.notes = other.notes }
                result.sourceEntryIDs = Array(Set(result.sourceEntryIDs + other.sourceEntryIDs)).sorted { $0.uuidString < $1.uuidString }
            }
            return result
        }
    }
}

/// Per-operation cache only; patient text is never retained in a global cache.
struct HealthFactKeyCache {
    private var values: [[String]: String] = [:]
    mutating func key(_ entry: SummaryEntry) -> String {
        if entry.evidence?.factIdentity != nil || entry.evidence?.instructionIdentity != nil ||
            entry.evidence?.combinationExcluded == true || CareInstructionPresentation.applies(entry) ||
            entry.category == .practitionerContact || entry.title.isEmpty {
            return HealthMemoryProjection.key(for: entry)
        }
        let e = entry.evidence
        var parts = [entry.category.rawValue, entry.title, entry.details]
        parts += entry.fields.flatMap { [$0.label, $0.value] }
        parts += [e?.bodySystem,e?.dose,e?.frequency,e?.reasonStarted,e?.reasonStopped,e?.assessmentMethod].map { $0 ?? "" }
        if ![.symptoms,.chiefComplaint,.medications,.allergies,.practitionerContact].contains(entry.category) {
            parts += [e?.practitioner ?? "", e?.eventDate ?? "", e?.eventDate == nil ? entry.relevantDate.map { String($0.timeIntervalSince1970) } ?? "" : ""]
            if [.testsAndLabs,.vaccinations,.findings].contains(entry.category), e?.eventDate == nil, entry.relevantDate == nil {
                parts.append(entry.sourceSessionID?.uuidString ?? entry.id.uuidString)
            }
        }
        if let key = values[parts] { return key }
        let key = HealthMemoryProjection.key(for: entry)
        values[parts] = key
        return key
    }
}
