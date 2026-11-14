import Foundation

/// Display a medication once while preserving the original, independently editable occurrences.
/// This does not claim that separate prescriptions are equivalent clinical events.
public enum MedicationHistoryPresentation {
    public static func group(_ facts: [HealthFact]) -> [HealthFact] {
        let medications = facts.filter { $0.category == .medications }
        let groups = Dictionary(grouping: medications) { fact in
            displayGroupKey(fact.latest)
        }
        var result = facts.filter { $0.category != .medications }
        for group in groups.values {
            let separated = group.filter { $0.occurrences.contains { $0.evidence?.combinationExcluded == true } }
            let eligible = group.filter { !$0.occurrences.contains { $0.evidence?.combinationExcluded == true } }
            // A removal belongs to its saved fact identity, not every matching product.
            // Never let a hidden root suppress previously visible refill histories.
            let visible = eligible.filter { !$0.preference.hidden }
            let hidden = eligible.filter { $0.preference.hidden }
            result += separated + combine(visible) + combine(hidden)
        }
        return result
    }

    /// Older rows can carry the form in the name alone, while structured rows
    /// also carry a form field. Match an explicit product name and form across those representations.
    private static func displayGroupKey(_ entry: SummaryEntry) -> String {
        let original = MedicationIdentity.key(entry)
        let structured = BClinicalPresentation.medication(entry)
        let title = MedicationIdentity.productTitle(entry).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let suffixes = ["gel eye drops", "eye ointment", "eye drops", "eye drop", "tablets", "tablet",
                        "capsules", "capsule", "solution", "cream", "ointment", "injection"]
        guard let suffix = suffixes.first(where: { title.hasSuffix(" " + $0) }),
              !original.contains("|uncertain|"),
              !original.contains("|conflict|"), structured["uncertainty"] == nil,
              !["name", "strength", "form"].contains(where: { structured.rejectedValues?[$0] != nil }),
              !["unknown", "unclear", "unspecified", "steroid", "medication"].contains(where: { title.split(separator: " ").contains(Substring($0)) })
        else { return original }
        let forms = entry.fields.filter { $0.label.lowercased() == "form" }.map(\.value)
            + [structured["form"]].compactMap { $0 }
        let form = BClinicalPresentation.displayForm(suffix).lowercased()
        guard forms.allSatisfy({ BClinicalPresentation.displayForm($0).lowercased() == form }),
              !entry.fields.contains(where: { ["concentration", "strength"].contains($0.label.lowercased()) && !$0.value.isEmpty }),
              structured["strength"] == nil,
              [ "medication|" + title + "|", "medication|" + title + "||",
                "medication|" + title + "|" + form + "|" ].contains(original)
        else { return original }
        return "display|named form|" + String(title.dropLast(suffix.count)) + "|" + form
    }

    static func combine(_ group: [HealthFact]) -> [HealthFact] {
            guard group.count > 1, !group.contains(where: { $0.occurrences.contains { $0.evidence?.combinationExcluded == true } }) else {
                return group
            }
            let chosen = group.filter { fact in
                let p = fact.preference
                return p.hidden || p.clinicalStatus != nil || p.actionStatus != nil || p.dueDate != nil || p.reminderEnabled || p.reviewedRevision != nil || p.topicIDs != nil
            }
            // Do not erase conflicting patient decisions. Original identities/preferences stay persisted.
            // Regeneration can copy the same patient choice to several event identities.
            // Multiple choices are not a conflict unless their values actually disagree.
            if let first = chosen.first {
                guard chosen.dropFirst().allSatisfy({ compatible(first.preference, $0.preference) }) else { return group }
            }
            let occurrences = group.flatMap(\.occurrences).sorted {
                let left = eventDate($0), right = eventDate($1)
                if left != right { return left > right }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            let root = chosen.sorted { $0.id < $1.id }.first ?? group.sorted { $0.id < $1.id }.first!
            return [HealthFact(id: root.id, occurrences: occurrences, preference: root.preference,
                                     topicIDs: Array(Set(group.flatMap(\.topicIDs))))]
    }

    private static func compatible(_ a: HealthFactPreference, _ b: HealthFactPreference) -> Bool {
        a.hidden == b.hidden && a.clinicalStatus == b.clinicalStatus &&
        a.actionStatus == b.actionStatus && a.dueDate == b.dueDate &&
        a.reminderEnabled == b.reminderEnabled &&
        a.topicIDs.map { Set($0) } == b.topicIDs.map { Set($0) }
        // Review markers refer to individual revisions. The combined revision remains unreviewed.
    }

    public static func display(_ fact: HealthFact) -> SummaryEntry {
        var result = fact.latest
        guard fact.category == .medications else { return result }
        if BClinicalPresentation.applies(result) {
            var displayed = BClinicalPresentation.medicationDisplay(result)
            let records = fact.occurrences.filter { BClinicalPresentation.applies($0) }.map(BClinicalPresentation.medication)
            // A fill's lack of directions does not erase a source prescription.
            // Conflicting regimens stay explicit; never choose a current regimen.
            let labels = [("dose","Recorded dose"),("frequency","Recorded frequency"),("route","Route"),
                          ("duration","Duration"),("instructions","Recorded instructions")]
            for (key,label) in labels {
                let values = records.compactMap { $0[key] }
                let distinct = Dictionary(grouping: values, by: { $0.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") })
                guard !distinct.isEmpty else { continue }
                displayed.fields.removeAll { $0.label == label }
                displayed.fields.append(.init(label: label, value: distinct.count == 1 ? values[0] : "Varies across records — see history."))
            }
            let clinicians = Set(records.compactMap { BClinicalPresentation.namedPractitioner($0["clinician"]) })
            displayed.evidence?.practitioner = clinicians.count == 1 ? clinicians.first : nil
            return displayed
        }
        let startLabels = ["start date", "date started", "started", "started on"]
        if let start = fact.occurrences.reversed().compactMap({ entry in
            entry.fields.first { startLabels.contains($0.label.lowercased()) && !$0.value.isEmpty }
        }).first {
            result.fields.removeAll { startLabels.contains($0.label.lowercased()) }
            result.fields.append(.init(label: "First recorded start", value: start.value))
        }
        // Current is a patient state, never inferred from the last dispensing date.
        if fact.hasKnownStatus && fact.isCurrent {
            result.fields.removeAll { ["end date", "date stopped", "stopped on"].contains($0.label.lowercased()) }
        }
        return result
    }

    private static func eventDate(_ entry: SummaryEntry) -> Date {
        if let text = entry.evidence?.eventDate {
            for format in ["yyyy-MM-dd", "MMM d, yyyy", "MMMM d, yyyy"] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                if let date = formatter.date(from: text) { return date }
            }
        }
        return entry.relevantDate ?? .distantPast
    }
}
