import Foundation

public enum ContactHistoryPresentation {
    private static func field(_ entry: SummaryEntry, _ labels: [String]) -> String {
        entry.fields.first { labels.contains($0.label.lowercased()) }?.value ?? ""
    }
    public static func group(_ facts: [HealthFact]) -> [HealthFact] {
        let groups = Dictionary(grouping: facts.filter { $0.category == .practitionerContact }) { fact in
            let e = fact.latest
            let phone = field(e, ["phone"]).filter(\.isNumber)
            let email = field(e, ["email"]).lowercased()
            let organization = HealthFactMatching.canonical(field(e, ["organization", "clinic", "org"]))
            // Same name alone is insufficient. Shared clinic phone plus affiliation provides identity.
            guard !phone.isEmpty || !email.isEmpty else { return fact.id }
            return HealthFactMatching.canonical(e.title) + "|" + phone + "|" + email + "|" + organization
        }
        return facts.filter { $0.category != .practitionerContact } + groups.values.flatMap { MedicationHistoryPresentation.combine($0) }
    }

    /// An enriched display copy only. Editing still targets an original occurrence.
    public static func display(_ fact: HealthFact) -> SummaryEntry {
        var result = fact.latest
        guard fact.category == .practitionerContact else { return MedicationHistoryPresentation.display(fact) }
        let aliases = ["org": "Organization", "clinic": "Organization", "organization": "Organization",
                       "role": "Role or specialty", "specialty": "Role or specialty", "role or specialty": "Role or specialty",
                       "address": "Address", "phone": "Phone", "email": "Email", "name": "Name"]
        var selected: [String: SummaryEntryField] = [:]
        for entry in fact.occurrences {
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
