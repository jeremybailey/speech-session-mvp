import Foundation

public struct StoryOverview: Codable, Sendable {
    public struct Sentence: Codable, Sendable {
        public var text: String
        public var factIDs: [String]
    }
    public var conditionContext: String?
    public static func conditionContext(facts: [HealthFact], topics: [HealthTopic]) -> String {
        let groups = ConditionSummaryProjection.groups(facts: facts, topics: topics).filter { !$0.isUncategorized }
        return groups.enumerated().map { index, group in
            "Priority \(index + 1): \(group.name). Supporting entries: " + group.facts.sorted { $0.id < $1.id }.map { "[\($0.id)] \($0.displayEntry.title)" }.joined(separator: "; ")
        }.joined(separator: "\n")
    }
    public var sentences: [Sentence]
    public var text: String { sentences.map(\.text).joined(separator: " ") }
    /// The narrative is derived from the accepted snapshot as a whole. These are
    /// input references, not model-generated sentence-level factual attestations.
    public init(text: String, facts: [HealthFact]) {
        sentences = [Sentence(text: text, factIDs: facts.map(\.id))]
    }
    public init(sentences: [Sentence]) { self.sentences = sentences }
    /// Converts short, request-only reference codes back to durable fact identities.
    /// Unknown codes deliberately remain invalid so they can never be published.
    public func replacingFactIDs(using references: [String: String]) -> StoryOverview {
        var translated = StoryOverview(sentences: sentences.map { sentence in
            Sentence(text: sentence.text,
                     factIDs: sentence.factIDs.map { references[$0] ?? $0 })
        })
        translated.conditionContext = conditionContext
        return translated
    }
    public func hasValidReferences(in facts: [HealthFact]) -> Bool {
        let ids = Set(facts.map(\.id))
        return !sentences.isEmpty && sentences.count <= 10 && text.count <= 3500 && sentences.allSatisfy {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.factIDs.isEmpty && Set($0.factIDs).isSubset(of: ids)
        }
    }
    /// Some writers repeat opaque citation identifiers in prose as well as factIDs.
    /// Remove only exact, known, sentence-cited identifiers; clinical values and
    /// unknown identifiers still pass through the normal validation unchanged.
    public func removingInlineReferenceIDs(in facts: [HealthFact]) -> StoryOverview {
        let known = Set(facts.map(\.id))
        var result = self
        for index in result.sentences.indices {
            var text = result.sentences[index].text
            for id in Set(result.sentences[index].factIDs).intersection(known) where id.count >= 16 {
                let escaped = NSRegularExpression.escapedPattern(for: id)
                text = text.replacingOccurrences(of: #"(?<![A-Za-z0-9_-])"# + escaped + #"(?![A-Za-z0-9_-])"#,
                                                with: "", options: .regularExpression)
            }
            // Remove now-empty citation wrappers, not arbitrary parenthetical prose.
            text = text.replacingOccurrences(of: #"\[[\s,;]*\]|\([\s,;]*\)"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            text = text.replacingOccurrences(of: #" +([.,;:!?])"#, with: "$1", options: .regularExpression)
            result.sentences[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
    /// IDs provide provenance; this additional guard prevents unsupported dates,
    /// quantities, percentages, and doses from being introduced in presentation prose.
    public func hasGroundedNumbers(in facts: [HealthFact]) -> Bool {
        ungroundedNumbers(in: facts).isEmpty
    }
    public func ungroundedNumbers(in facts: [HealthFact]) -> [String] {
        let factsByID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        func numbers(_ text: String) -> Set<String> {
            guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z])\d+(?:[.,]\d+)?(?:%|mg|mcg|ml|weeks?|days?|years?)?"#, options: [.caseInsensitive]) else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            return Set(regex.matches(in: text, range: range).compactMap { match in
                Range(match.range, in: text).map { String(text[$0]).lowercased().replacingOccurrences(of: ",", with: "") }
            })
        }
        return sentences.flatMap { sentence in
            let evidence = sentence.factIDs.compactMap { factsByID[$0] }.flatMap(\.occurrences).map { entry in
                ([entry.title, entry.details, entry.supportingExcerpt ?? "", entry.evidence?.eventDate ?? ""] + entry.fields.flatMap { [$0.label, $0.value] }).joined(separator: " ")
            }.joined(separator: " ")
            return numbers(sentence.text).subtracting(numbers(evidence)).sorted()
        }
    }
    public static func fingerprint(_ facts: [HealthFact]) -> String {
        SummaryVerification.hash("patient-story-v5-source-linked|" + facts.sorted { $0.id < $1.id }.map { fact in
            // Session storage uses whole-second ISO dates. In-memory revision timestamps
            // retain fractions, so using revision here invalidated unchanged saved stories.
            // Content hashes also catch edits made within the same second.
            let content = fact.occurrences.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                "\($0.id.uuidString):\(SummaryVerification.contentHash($0))"
            }.joined(separator: "|")
            return "\(fact.id)|\(content)|\(fact.clinicalStatus)|\(fact.actionStatus)|\(fact.preference.reviewedRevision ?? "")|\(fact.preference.hidden)"
        }.joined(separator: "\n"))
    }
}

private struct StoredStoryOverview: Codable {
    var fingerprint: String
    var overview: StoryOverview
}

extension SessionStore {
    public func storyOverview(for facts: [HealthFact]) -> StoryOverview? {
        let url = storageDirectory.appendingPathComponent("story-overview.json")
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(StoredStoryOverview.self, from: data),
              saved.fingerprint == StoryOverview.fingerprint(facts), saved.overview.hasValidReferences(in: facts),
              saved.overview.conditionContext == currentOverviewConditionContext(facts) else { return nil }
        return saved.overview
    }
    public func currentOverviewConditionContext(_ facts: [HealthFact]) -> String {
        StoryOverview.conditionContext(facts: displayedConditionFacts(for: facts), topics: (try? healthSnapshot().topics) ?? [])
    }
    public func saveStoryOverview(_ overview: StoryOverview, expected: [HealthFact]) throws {
        try Task.checkCancellation()
        let current = HealthMemoryProjection.facts(in: try healthSnapshot())
        guard StoryOverview.fingerprint(current) == StoryOverview.fingerprint(expected), overview.hasValidReferences(in: current),
              overview.conditionContext == currentOverviewConditionContext(current) else {
            throw SummaryCommitError.patientChanged
        }
        let data = try JSONEncoder().encode(StoredStoryOverview(fingerprint: StoryOverview.fingerprint(current), overview: overview))
        try data.write(to: storageDirectory.appendingPathComponent("story-overview.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
