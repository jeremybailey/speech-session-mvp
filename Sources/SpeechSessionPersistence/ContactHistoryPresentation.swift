import Foundation

public enum ContactHistoryPresentation {
    private static func field(_ entry: SummaryEntry, _ labels: [String]) -> String {
        entry.fields.first { labels.contains($0.label.lowercased()) }?.value ?? ""
    }
    public static func group(_ facts: [HealthFact]) -> [HealthFact] {
        let buckets = Dictionary(grouping: facts.filter { $0.category == .practitionerContact }) {
            HealthFactMatching.canonical(BClinicalPresentation.display($0.latest).title)
        }
        var result = facts.filter { $0.category != .practitionerContact }
        for bucket in buckets.values {
            var groups: [[HealthFact]] = []
            for fact in bucket.sorted(by: { $0.id < $1.id }) {
                if let index = groups.firstIndex(where: { group in
                    group.allSatisfy { existing in
                        existing.preference.hidden == fact.preference.hidden && existing.occurrences.allSatisfy { left in
                            fact.occurrences.allSatisfy { right in sameContact(left, right) }
                        }
                    }
                }) {
                    groups[index].append(fact)
                } else { groups.append([fact]) }
            }
            result += groups.flatMap { MedicationHistoryPresentation.combine($0) }
        }
        return result
    }

    private static func sameContact(_ a: SummaryEntry, _ b: SummaryEntry) -> Bool {
        let a = BClinicalPresentation.display(a), b = BClinicalPresentation.display(b)
        let name = HealthFactMatching.canonical(a.title)
        guard !name.isEmpty, !["Care team contact — check original","Contacts listed on record"].contains(a.title), name == HealthFactMatching.canonical(b.title),
              a.evidence?.combinationExcluded != true, b.evidence?.combinationExcluded != true else { return false }
        // Identical content can share a display card without claiming a stored
        // identity or deleting an occurrence. Compare all fields, including unknown
        // labels and review flags; a name alone is never sufficient.
        if exactContent(a, b) { return true }
        let labels = [["phone"], ["email"], ["organization", "clinic", "org"],
                      ["address"], ["role", "specialty", "role or specialty"], ["name"]]
        for aliases in labels {
            let left = normalizedField(a, aliases), right = normalizedField(b, aliases)
            guard !left.isEmpty && !right.isEmpty && left != right else { continue }
            if aliases.first == "address", left.hasSuffix(" " + right) || right.hasSuffix(" " + left) { continue }
            if aliases.first == "role", ["practitioner", "provider", "doctor"].contains(left)
                || ["practitioner", "provider", "doctor"].contains(right) { continue }
            return false
        }
        let phone = normalizedField(a, ["phone"]), email = normalizedField(a, ["email"])
        let sharedPhone = !phone.isEmpty && phone == normalizedField(b, ["phone"])
        let sharedEmail = !email.isEmpty && email == normalizedField(b, ["email"])
        // Contacts without shared channels require explicit source-backed identity
        // review. No organization-name keywords or role vocabulary establish identity.
        return sharedPhone || sharedEmail
    }

    private static func presentationText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased()
    }

    private struct ContentField: Hashable {
        let label: String
        let value: String
        let isMissing: Bool
        let needsReview: Bool
    }

    private static func exactContent(_ a: SummaryEntry, _ b: SummaryEntry) -> Bool {
        func fields(_ entry: SummaryEntry) -> Set<ContentField> {
            Set(entry.fields.map {
                ContentField(label: presentationText($0.label), value: presentationText($0.value),
                             isMissing: $0.isMissing, needsReview: $0.needsReview)
            })
        }
        let details = presentationText(a.details)
        let meaningfulFields = a.fields.contains { !presentationText($0.value).isEmpty }
        return presentationText(a.title) == presentationText(b.title)
            && (!details.isEmpty || meaningfulFields)
            && details == presentationText(b.details) && fields(a) == fields(b)
            && a.clinicalStatus == b.clinicalStatus
    }

    private static func normalizedField(_ entry: SummaryEntry, _ aliases: [String]) -> String {
        let value = field(entry, aliases)
        return aliases == ["phone"] ? value.filter(\.isNumber) : HealthFactMatching.canonical(value)
    }

    /// An enriched display copy only. Editing still targets an original occurrence.
    public static func display(_ fact: HealthFact) -> SummaryEntry {
        var result = BClinicalPresentation.display(fact.latest)
        guard fact.category == .practitionerContact else { return MedicationHistoryPresentation.display(fact) }
        let aliases = ["org": "Organization", "clinic": "Organization", "organization": "Organization",
                       "role": "Role or specialty", "specialty": "Role or specialty", "role or specialty": "Role or specialty",
                       "address": "Address", "phone": "Phone", "email": "Email", "name": "Name"]
        var selected: [String: SummaryEntryField] = [:]
        for original in fact.occurrences {
            let entry = BClinicalPresentation.display(original)
            for field in entry.fields where !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let label = aliases[field.label.lowercased()] ?? field.label
                var value = field.value
                if label == "Address", let range = value.range(of: #";\s*(?:org|phone|role|email):"#, options: [.regularExpression, .caseInsensitive]) {
                    value = String(value[..<range.lowerBound])
                }
                if let existing = selected[label] {
                    if label == "Role or specialty", ["practitioner", "provider", "doctor"].contains(existing.value.lowercased()) {
                        selected[label] = .init(label: label, value: value)
                    } else if label == "Address", value.count > existing.value.count {
                        selected[label] = .init(label: label, value: value)
                    }
                } else { selected[label] = .init(label: label, value: value) }
            }
        }
        result.fields = selected.values.sorted { $0.label < $1.label }
        return result
    }
}

/// A navigation group, not an assertion that its saved contacts are one identity.
/// Keeps differing locations, patient choices, and source histories independently
/// editable inside one heading instead of repeating the name throughout All.
public struct ContactPresentationGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let facts: [HealthFact]
    public let members: [CareTeamMember]
    public var count: Int { facts.count + members.count }

    public static func groups(facts: [HealthFact], members: [CareTeamMember]) -> [Self] {
        func nameKey(_ name: String) -> String {
            HealthMemoryProjection.normalize(name).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func factKey(_ fact: HealthFact) -> String {
            let name = nameKey(fact.title)
            // Respect explicit separation even in the navigation hierarchy.
            return name.isEmpty || fact.displayEntry.fields.contains(where:{$0.label=="Names listed"}) || fact.occurrences.contains { $0.evidence?.combinationExcluded == true }
                ? "fact:" + fact.id : "name:" + name
        }
        func memberKey(_ member: CareTeamMember) -> String {
            let name = nameKey(member.name)
            return name.isEmpty || member.combinationExcluded == true
                ? "member:" + member.id.uuidString : "name:" + name
        }
        let factGroups = Dictionary(grouping: facts.filter { $0.category == .practitionerContact && !$0.preference.hidden }, by: factKey)
        let memberGroups = Dictionary(grouping: members.filter { $0.duplicateOf == nil }, by: memberKey)
        return Set(factGroups.keys).union(memberGroups.keys).map { key in
            let rows = (factGroups[key] ?? []).sorted { $0.id < $1.id }
            let contacts = (memberGroups[key] ?? []).sorted { $0.id.uuidString < $1.id.uuidString }
            return Self(id: key, title: contacts.first?.name ?? rows.first?.title ?? "Contact",
                        facts: rows, members: contacts)
        }.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}

/// Condition contact navigation, without creating new clinical relationships or modifying sources.
public enum ConditionContacts {
    public static func groups(for condition: ConditionSummary, allFacts: [HealthFact], snapshot: HealthMemorySnapshot) -> [ContactPresentationGroup] {
        let members = snapshot.careTeam.filter { $0.duplicateOf == nil }
        let represented = Set(members.flatMap(\.sourceEntryIDs))
        let contactFacts = allFacts.filter {
            $0.category == .practitionerContact && !$0.preference.hidden &&
            !$0.occurrences.contains { represented.contains($0.id) }
        }
        var memberIDs = Set<UUID>()
        var factIDs = Set(condition.facts.filter { $0.category == .practitionerContact }.map(\.id))
        func nameKey(_ name: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        for fact in condition.facts where !fact.preference.hidden {
            if let id = fact.preference.practitionerContactID {
                memberIDs.insert(id)
                continue
            }
            // A contact fact already assigned to this condition may have become a saved contact.
            if fact.category == .practitionerContact {
                let ids = Set(fact.occurrences.map(\.id))
                members.filter { !$0.sourceEntryIDs.allSatisfy { !ids.contains($0) } }.forEach { memberIDs.insert($0.id) }
                continue
            }
            for entry in fact.occurrences {
                guard let name = entry.evidence?.practitioner, !nameKey(name).isEmpty,
                      let assessment = entry.evidence?.assessment, assessment.admission == .supported,
                      assessment.contentHash == SummaryVerification.contentHash(entry),
                      let source = snapshot.sessions.first(where: { $0.id == entry.sourceSessionID }),
                      assessment.sourceHash == SummaryVerification.hash(source.transcript),
                      assessment.citations.contains(where: {
                          $0.field == "practitioner" && !$0.excerpt.isEmpty && source.transcript.contains($0.excerpt)
                      }) else { continue }
                let matchingMembers = members.filter { nameKey($0.name) == nameKey(name) }
                let matchingFacts = contactFacts.filter { nameKey($0.title) == nameKey(name) }
                // Same-name people remain separate; ambiguous identity needs user selection.
                guard matchingMembers.count + matchingFacts.count == 1 else { continue }
                matchingMembers.forEach { memberIDs.insert($0.id) }
                matchingFacts.forEach { factIDs.insert($0.id) }
            }
        }
        return ContactPresentationGroup.groups(facts: contactFacts.filter { factIDs.contains($0.id) },
                                               members: members.filter { memberIDs.contains($0.id) })
    }
}
