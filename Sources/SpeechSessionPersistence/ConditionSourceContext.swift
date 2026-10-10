import Foundation

/// Original-source context for organizing an already accepted assertion. Never
/// creates a claim or borrows context from another record with similar wording.
public enum ConditionSourceContext {
    public static func windows(facts: [HealthFact], sessions: [Session], includeRecordOpening: Bool = false) -> [UUID: [String]] {
        let sources = Dictionary(sessions.map { ($0.id, $0.transcript) }, uniquingKeysWith: { first, _ in first })
        var result: [UUID: [String]] = [:]
        for entry in facts.flatMap(\.occurrences) {
            guard let sourceID = entry.sourceSessionID, let source = sources[sourceID] else { continue }
            let citations = entry.evidence?.assessment?.citations ?? []
            // Relationship-bearing quotations precede title-only anchors. Stable
            // ordering makes request identities independent of citation order.
            func priority(_ field: String) -> Int {
                ["details", "careInstruction", "topicNames", "title"].firstIndex(of: field) ?? 4
            }
            let ordered = citations.sorted {
                if priority($0.field) != priority($1.field) { return priority($0.field) < priority($1.field) }
                return $0.excerpt < $1.excerpt
            }.map(\.excerpt) + [entry.evidence?.excerpt, entry.sourceExcerpt].compactMap { $0 }
            var ranges: [Range<String.Index>] = []
            for quote in ordered {
                let words = quote.split(whereSeparator: \.isWhitespace)
                guard quote.count >= 16, quote.count <= 600, words.count >= 3 else { continue }
                let pattern = words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
                // Repeated generic quotations cannot identify the right episode.
                guard matches.count == 1, let anchor = Range(matches[0].range, in: source) else { continue }
                if ranges.contains(where: { $0.lowerBound <= anchor.lowerBound && $0.upperBound >= anchor.upperBound }) { continue }
                let start = source.index(anchor.lowerBound, offsetBy: -240, limitedBy: source.startIndex) ?? source.startIndex
                let end = source.index(anchor.upperBound, offsetBy: 240, limitedBy: source.endIndex) ?? source.endIndex
                ranges.append(start..<end)
                if ranges.count == 3 { break }
            }
            if includeRecordOpening, !ranges.isEmpty {
                // A later plan may refer back to a documented referral or care episode.
                // Supply only the same original record's bounded opening, never a
                // generated summary or another encounter with a similar concern.
                let end = source.index(source.startIndex, offsetBy: 1_800, limitedBy: source.endIndex) ?? source.endIndex
                let opening = source.startIndex..<end
                if !ranges.contains(where: { $0.lowerBound == source.startIndex && $0.upperBound >= end }) {
                    ranges.removeAll { $0.lowerBound >= opening.lowerBound && $0.upperBound <= opening.upperBound }
                    ranges.append(opening)
                }
            }
            let windows = ranges.sorted { $0.lowerBound < $1.lowerBound }.map { String(source[$0]) }
            if !windows.isEmpty { result[entry.id] = windows }
        }
        return result
    }
}
