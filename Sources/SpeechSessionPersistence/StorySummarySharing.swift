import Foundation

/// Export-only policy. Never mutates the saved summary or its source records.
/// Remove a whole point/row rather than rewriting a clinical assertion out of context.
public enum StorySummarySharing {
    private static let patterns = [
        #"\b(?:safety(?: screening| assessment| risk)?|suicid\w*|self[\s-]*harm\w*|self[\s-]*injur\w*|homicid\w*)\b"#,
        #"\b(?:harm|hurt|kill)(?:ing)?\s+(?:(?:to|towards?)\s+)?(?:(?:my|her|his|their|our|the)\s+(?:own\s+)?)?(?:self|myself|herself|himself|themselves|others|someone|baby|infant|child(?:ren)?)\b"#,
        #"\b(?:harm (?:thoughts|visions|ideation)|thoughts of (?:death|dying)|end (?:my|her|his|their) life)\b"#,
        #"\b(?:sexual\w*|intercourse|dyspareunia|libido|orgasm\w*|intimacy|erectile|penetration|vaginismus)\b"#,
        #"\b(?:genital\w*|perine\w*|vulv\w*|vagina|clitor\w*|penis|penile|scrot\w*|testicul\w*|labia\w*|saddle (?:sens\w*|numb\w*|anaesth\w*|anesth\w*))\b"#,
        #"\bvaginal\s+(?:pain|sens\w*|numb\w*|dry\w*|discharge|itch\w*|varicos\w*|finding\w*)\b"#,
        #"\b(?:groin|pelvic)\b.{0,80}\b(?:varicos\w*|sensat\w*|sensory|numb\w*)\b"#,
        #"\b(?:varicos\w*|sensat\w*|sensory|numb\w*)\b.{0,80}\b(?:groin|pelvic)\b"#
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    public static func isSensitive(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    public static func excludingSensitiveDetails(_ blocks: [StorySummaryBlock]) -> [StorySummaryBlock] {
        var filtered: [StorySummaryBlock] = []
        var excludedHeadingLevel: Int?
        for block in blocks {
            if case let .heading(title, level) = block {
                if let excluded = excludedHeadingLevel, level <= excluded { excludedHeadingLevel = nil }
                if excludedHeadingLevel != nil { continue }
                if isSensitive(title) { excludedHeadingLevel = level; continue }
                filtered.append(block)
                continue
            }
            guard excludedHeadingLevel == nil else { continue }
            switch block {
            case let .bullet(text), let .paragraph(text):
                if !isSensitive(text) { filtered.append(block) }
            case let .table(headers, rows):
                guard !headers.contains(where: isSensitive) else { continue }
                // Carry topic labels into continuation rows before filtering.
                var topic = ""
                let kept = rows.filter { row in
                    if let first = row.first, !first.trimmingCharacters(in: .whitespaces).isEmpty { topic = first }
                    return !isSensitive(([topic] + row).joined(separator: " "))
                }
                if !kept.isEmpty { filtered.append(.table(headers: headers, rows: kept)) }
            case .heading: break
            }
        }
        // Remove empty headings, including parents whose children were all removed.
        var result: [StorySummaryBlock] = []
        var pending: [StorySummaryBlock] = []
        for block in filtered {
            if case let .heading(_, level) = block {
                while let last = pending.last, case let .heading(_, previousLevel) = last, previousLevel >= level { pending.removeLast() }
                pending.append(block)
            } else {
                result.append(contentsOf: pending); pending.removeAll()
                result.append(block)
            }
        }
        return result
    }
}
