import Foundation

public struct StoryOverview: Codable, Sendable {
    public struct Sentence: Codable, Sendable {
        public var text: String
        public var factIDs: [String]
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
        StoryOverview(sentences: sentences.map { sentence in
            Sentence(text: sentence.text,
                     factIDs: sentence.factIDs.map { references[$0] ?? $0 })
        })
    }
    public func hasValidReferences(in facts: [HealthFact]) -> Bool {
        let ids = Set(facts.map(\.id))
        return !sentences.isEmpty && sentences.count <= 10 && text.count <= 3500 && sentences.allSatisfy {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.factIDs.isEmpty && Set($0.factIDs).isSubset(of: ids)
        }
    }
    public static func fingerprint(_ facts: [HealthFact]) -> String {
        SummaryVerification.hash("patient-story-v4|" + facts.sorted { $0.id < $1.id }.map { fact in
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
              saved.fingerprint == StoryOverview.fingerprint(facts), saved.overview.hasValidReferences(in: facts) else { return nil }
        return saved.overview
    }
    public func saveStoryOverview(_ overview: StoryOverview, expected: [HealthFact]) throws {
        try Task.checkCancellation()
        let current = HealthMemoryProjection.facts(in: try healthSnapshot())
        guard StoryOverview.fingerprint(current) == StoryOverview.fingerprint(expected), overview.hasValidReferences(in: current) else {
            throw SummaryCommitError.patientChanged
        }
        let data = try JSONEncoder().encode(StoredStoryOverview(fingerprint: StoryOverview.fingerprint(current), overview: overview))
        try data.write(to: storageDirectory.appendingPathComponent("story-overview.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
