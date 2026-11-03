import Foundation

/// Display-only grouping of repeated B statements. Source facts and patient
/// decisions remain independently saved and editable; there is no semantic merge.
public enum BFactHistoryPresentation {
    public static func group(_ facts: [HealthFact]) -> [HealthFact] {
        var unchanged: [HealthFact] = []
        var groups: [String: [HealthFact]] = [:]
        for fact in facts {
            guard fact.category != .medications, fact.category != .practitionerContact,
                  !CareInstructionPresentation.applies(fact.latest),
                  fact.occurrences.allSatisfy({ $0.origin == .generated && $0.evidence?.assessmentMethod == WholeHistoryPublication.version }) else {
                unchanged.append(fact); continue
            }
            var entry = fact.latest
            // Per-source attribution and timestamps describe the occurrences,
            // not separate identities for an otherwise identical statement.
            if [.symptoms, .chiefComplaint, .allergies, .biopsychosocialContext, .otherNotes].contains(entry.category) {
                entry.details = entry.details.components(separatedBy: "\n").filter {
                    !$0.hasPrefix("Attribution: ") && !$0.hasPrefix("Recorded date: ")
                }.joined(separator: "\n")
            }
            // This signature retains negation, laterality, qualifiers, values,
            // clinical dates for events, and every populated clinical field.
            groups[entry.category.rawValue + "|" + HealthFactMatching.signature(entry), default: []].append(fact)
        }
        return unchanged + groups.values.flatMap { MedicationHistoryPresentation.combine($0) }
    }
}
