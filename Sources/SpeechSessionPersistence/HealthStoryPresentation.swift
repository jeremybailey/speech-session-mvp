import Foundation

public struct HealthStoryGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let facts: [HealthFact]
    public var overview: String? { HealthSummaryPresentation.overview(facts: facts) }
}

/// Relationships come from source metadata or a patient's explicit selection, never a guessed diagnosis.
public enum HealthStoryPresentation {
    public static func groups(facts: [HealthFact], topics: [HealthTopic]) -> [HealthStoryGroup] {
        var names: [String: String] = [:]
        var buckets: [String: [HealthFact]] = [:]
        for fact in facts {
            var labels: [String]
            if let selected = fact.preference.topicIDs {
                labels = topics.filter { selected.contains($0.id) }.map(\.name)
            } else {
                labels = topics.filter { fact.topicIDs.contains($0.id) }.map(\.name)
                labels += fact.occurrences.flatMap { $0.evidence?.topicNames ?? [] }
                if labels.isEmpty && fact.category == .chiefComplaint { labels = [HealthStoryText.clean(fact.title)] }
                if labels.isEmpty, let body = fact.latest.evidence?.bodySystem,
                   !["general", "other", "unknown", "unspecified"].contains(body.lowercased()) { labels = [body] }
            }
            labels = labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if labels.isEmpty { labels = ["General health"] }
            var added = Set<String>()
            for label in labels {
                let key = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard added.insert(key).inserted else { continue }
                names[key] = names[key] ?? label
                buckets[key, default: []].append(fact)
            }
        }
        return buckets.map { HealthStoryGroup(id: $0.key, name: names[$0.key]!, facts: $0.value) }.sorted {
            if ($0.id == "general health") != ($1.id == "general health") { return $1.id == "general health" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func careHeading(_ fact: HealthFact) -> String {
        if fact.isAction && [.completed, .past, .paused].contains(fact.actionStatus) { return fact.actionStatus.title }
        if fact.latest.evidence?.actionKind == "treatment_received" { return "Treatment received" }
        return fact.canShowAsNextStep ? "Care step" : "Check with your care team"
    }
}

/// Repairs display of old flattened extraction objects; the saved source is left intact.
public enum HealthStoryText {
    public static func isInternalField(_ label: String) -> Bool {
        let key = label.lowercased().filter(\.isLetter)
        return ["actionkind", "factkey", "clinicalstatus", "statusexplicit", "topicnames", "bodysystem", "eventdate", "reviewreason", "sourceexcerpt", "sourcepage"].contains(key)
    }

    /// Display-only cleanup: `clean` also participates in persistent fact identity.
    /// Changing that normalization would invalidate saved condition associations.
    public static func cleanForDisplay(_ text: String) -> String {
        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return clean(text) }
        let filtered = text.components(separatedBy: .newlines).map { line in
            line.components(separatedBy: ";").filter { segment in
                guard let colon = segment.firstIndex(of: ":") else { return true }
                return !isInternalField(String(segment[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines))
            }.joined(separator: ";")
        }.joined(separator: "\n")
        return clean(filtered)
    }

    public static func clean(_ text: String) -> String {
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return ["title", "name", "instruction", "details", "description", "notes"].compactMap { object[$0] as? String }.joined(separator: "\n")
        }
        return text.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else { return trimmed }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: " -\""))
            if isInternalField(key) { return nil }
            if ["title", "details", "instruction", "description", "notes"].contains(key.lowercased()) {
                return String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
