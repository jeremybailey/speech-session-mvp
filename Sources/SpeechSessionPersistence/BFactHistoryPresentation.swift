import Foundation

/// Display-only grouping of repeated B statements. Source facts and patient
/// decisions remain independently saved and editable; there is no semantic merge.
public enum BFactHistoryPresentation {
    public static func group(_ facts: [HealthFact]) -> [HealthFact] {
        var unchanged: [HealthFact] = []
        var groups: [String: [HealthFact]] = [:]
        for fact in facts {
            let symptom = fact.category == .symptoms || fact.category == .chiefComplaint
            guard fact.category != .medications, fact.category != .practitionerContact,
                  !CareInstructionPresentation.applies(fact.latest),
                  fact.occurrences.allSatisfy({ entry in
                      entry.origin == .generated && (symptom || BClinicalPresentation.applies(entry))
                        || symptom && entry.origin == .legacyImported
                  }) else {
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
            if symptom && entry.evidence?.assessmentMethod == WholeHistoryPublication.version {
                entry.evidence?.assessmentMethod = nil
            }
            let key = [entry.category.rawValue, HealthFactMatching.signature(entry),
                       entry.clinicalStatus.rawValue, entry.evidence?.sourceAssertion?.status ?? "",
                       String(entry.evidence?.statusExplicit == true), String(fact.preference.hidden)]
            groups[key.joined(separator: "|"), default: []].append(fact)
        }
        return unchanged + groups.values.flatMap { MedicationHistoryPresentation.combine($0) }
    }
}
