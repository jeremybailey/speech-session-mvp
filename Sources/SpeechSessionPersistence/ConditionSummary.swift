import Foundation

/// Non-destructive view of longitudinal facts. Conditions are concerns, not necessarily diagnoses.
public struct ConditionSummary: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bodySystem: String
    public let facts: [HealthFact]
    public var isUncategorized: Bool { id == "uncategorized" }
}

public enum ConditionSummaryProjection {
    public enum Status: String, CaseIterable, Sendable { case all, current, notCurrent, unknown }

    /// Narrow normalization: formatting/plurals and explicit aliases, never symptom-to-diagnosis inference.
    public static func normalized(_ name: String) -> String {
        let words = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let aliases = ["migraines": "migraine", "headaches": "headache", "knapsack": "backpack"]
        return words.map { aliases[$0] ?? $0 }.joined(separator: " ")
    }

    /// Equivalent symptom phrasing shares a heading; anatomical qualifiers remain significant.
    public static func conditionKey(_ name: String) -> String {
        var value = normalized(name)
        let aliases = ["backache": "back pain", "back ache": "back pain",
                       "low back": "lower back", "pins and needles": "tingling"]
        for (alias, canonical) in aliases.sorted(by: { $0.key.count > $1.key.count }) {
            value = value.replacingOccurrences(of: "\\b" + alias + "\\b", with: canonical,
                                               options: .regularExpression)
        }
        // Applies across body sites, not just the examples seen in one patient's history.
        let pattern = "^(pain|tingling|numbness|stiffness|swelling) (?:in|of|at) (?:the )?(.+)$"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let symptom = Range(match.range(at: 1), in: value),
           let location = Range(match.range(at: 2), in: value) {
            value = String(value[location]) + " " + String(value[symptom])
        }
        return value
    }

    /// Report sections describe observations, not the patient's reason for care.
    public static func isConcernName(_ name: String) -> Bool {
        let value = normalized(name)
        guard !value.isEmpty else { return false }
        let words = value.split(separator: " ")
        if ["finding", "findings", "result", "results", "structure", "structures"].contains(String(words.last ?? "")) { return false }
        return !["heart", "lungs", "lung", "bones", "mediastinum", "lung volume", "heart size", "normal", "normal examination", "unremarkable"].contains(value)
    }

    private struct Candidate: Hashable {
        let name: String
        let system: String
        var key: String { ConditionSummaryProjection.conditionKey(name) }
    }

    public static func status(of fact: HealthFact) -> Status {
        if fact.preference.clinicalStatus != nil || fact.preference.actionStatus != nil {
            return fact.isCurrent ? .current : .notCurrent
        }
        let explicit = fact.occurrences.filter { $0.origin == .userAdded || $0.evidence?.statusExplicit == true }
        // A historic dispensing date alone does not establish current use or discontinuation.
        guard !explicit.isEmpty else { return .unknown }
        let states = Set(explicit.map { $0.clinicalStatus })
        guard states.count == 1 else { return .unknown }
        return explicit[0].clinicalStatus == .current ? .current : .notCurrent
    }

    public static func matches(_ fact: HealthFact, status filter: Status) -> Bool {
        filter == .all || status(of: fact) == filter
    }

    public static func date(of entry: SummaryEntry) -> Date? {
        if let value = entry.evidence?.eventDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            for format in ["yyyy-MM-dd", "MMM d, yyyy", "MMMM d, yyyy"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: value) { return date }
            }
        }
        return entry.relevantDate // Never substitute import/update time for clinical time.
    }

    public static func sorted(_ facts: [HealthFact]) -> [HealthFact] {
        facts.sorted {
            let a = $0.occurrences.compactMap(date).max() ?? .distantPast
            let b = $1.occurrences.compactMap(date).max() ?? .distantPast
            return a == b ? $0.id < $1.id : a > b
        }
    }

    public static func groups(facts: [HealthFact], topics: [HealthTopic]) -> [ConditionSummary] {
        let topicMap = Dictionary(topics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Assign each occurrence independently: a grouped product can have more than one indication.
        var assignments: [(HealthFact, SummaryEntry, [Candidate])] = []
        for fact in facts {
            for entry in fact.occurrences {
                let candidates: [Candidate]
                if let ids = fact.preference.topicIDs {
                    // An explicit empty array is the patient's choice to leave this unassigned.
                    candidates = ids.compactMap { topicMap[$0] }.map { Candidate(name: $0.name, system: normalized($0.bodySystem)) }
                } else if entry.evidence?.conditionSynthesisUnassigned == true {
                    candidates = []
                } else if let group = entry.evidence?.conditionGroup, !normalized(group).isEmpty,
                          entry.evidence?.conditionGroupReason?.isEmpty == false {
                    candidates = [Candidate(name: group, system: normalized(entry.evidence?.bodySystem ?? ""))]
                } else {
                    let source = normalized(entry.supportingExcerpt ?? "")
                    let explicit = (entry.evidence?.topicNames ?? []).filter {
                        let name = normalized($0)
                        guard !name.isEmpty else { return false }
                        // Co-occurrence alone is not an indication. Require the title itself or
                        // explicit relationship wording within this detail's own source excerpt.
                        let ownConcern = [.chiefComplaint, .symptoms, .findings].contains(entry.category) && conditionKey(entry.title) == conditionKey($0)
                        let linked = ["for " + name, "because of " + name, "related to " + name,
                                      "due to " + name, "indication " + name].contains {
                            (" " + source + " ").contains(" " + $0 + " ")
                        }
                        return ownConcern || linked
                    }
                    if !explicit.isEmpty {
                        candidates = explicit.map { Candidate(name: $0, system: normalized(entry.evidence?.bodySystem ?? "")) }
                    } else if [.chiefComplaint, .symptoms].contains(entry.category) {
                        // A symptom is a valid concern heading without being promoted to a diagnosis.
                        candidates = [Candidate(name: entry.title, system: normalized(entry.evidence?.bodySystem ?? ""))]
                    } else {
                        candidates = []
                    }
                }
                assignments.append((fact, entry, candidates.filter { fact.preference.topicIDs != nil || isConcernName($0.name) }))
            }
        }
        // Unknown body systems join a name only when there is at most one explicit system.
        var systems: [String: Set<String>] = [:]
        for (_, _, candidates) in assignments {
            for candidate in candidates where !["", "other", "unknown", "unspecified"].contains(candidate.system) {
                systems[candidate.key, default: []].insert(candidate.system)
            }
        }
        var names: [String: String] = [:]
        var bodies: [String: String] = [:]
        var members: [String: [String: [SummaryEntry]]] = [:]
        var original: [String: HealthFact] = [:]
        for (fact, entry, candidates) in assignments {
            original[fact.id] = fact
            var destinations = Set<String>()
            for candidate in candidates {
                let known = systems[candidate.key] ?? []
                let specified = !["", "other", "unknown", "unspecified"].contains(candidate.system)
                if !specified && known.count > 1 { continue }
                let system = specified ? candidate.system : (known.first ?? "")
                let id = candidate.key + "|" + system
                destinations.insert(id)
                // Stable display label regardless of source order or casing.
                names[id] = candidate.key.prefix(1).uppercased() + candidate.key.dropFirst()
                bodies[id] = system
            }
            if destinations.isEmpty { destinations.insert("uncategorized") }
            for id in destinations { members[id, default: [:]][fact.id, default: []].append(entry) }
        }
        return members.map { id, items in
            let projected = items.compactMap { factID, entries -> HealthFact? in
                guard let fact = original[factID] else { return nil }
                let entries = entries.sorted {
                    let a = date(of: $0) ?? .distantPast, b = date(of: $1) ?? .distantPast
                    return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
                }
                return HealthFact(id: factID, occurrences: entries, preference: fact.preference, topicIDs: fact.topicIDs)
            }
            return ConditionSummary(id: id, name: names[id] ?? "Uncategorized", bodySystem: bodies[id] ?? "", facts: sorted(projected))
        }.sorted {
            if $0.isUncategorized != $1.isUncategorized { return !$0.isUncategorized }
            let primaryA = $0.facts.flatMap(\.occurrences).contains { $0.evidence?.conditionIsPrimary == true }
            let primaryB = $1.facts.flatMap(\.occurrences).contains { $0.evidence?.conditionIsPrimary == true }
            if primaryA != primaryB { return primaryA }
            let a = $0.facts.flatMap(\.occurrences).compactMap(date).max() ?? .distantPast
            let b = $1.facts.flatMap(\.occurrences).compactMap(date).max() ?? .distantPast
            return a == b ? $0.name < $1.name : a > b
        }
    }
}
