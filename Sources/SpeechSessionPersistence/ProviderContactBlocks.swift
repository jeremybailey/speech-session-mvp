import Foundation

/// High precision candidates from explicit provider headings and signed-report lines.
/// Detection is not approval: every candidate must pass independent source verification.
public struct ProviderContactBlock: Equatable, Sendable {
    public let name: String
    public let source: String
}

public enum ProviderContactBlocks {
    public static func nameKey(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"^dr\.?\s+"#, with: "", options: .regularExpression)
            .split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
    }

    public static func candidates(in source: String) -> [ProviderContactBlock] {
        let lines = source.components(separatedBy: .newlines)
        let heading = try! NSRegularExpression(pattern: #"(?i)^\s*(Dr\.?\s+[\p{L}'’-]+(?:\s+[\p{L}'’-]+){1,3})(?:\s*,.*)?\s*$"#)
        let signed = try! NSRegularExpression(pattern: #"(?i)([\p{L}'’-]+(?:\s+[\p{L}'’-]+){1,3})\s+MD\b"#)
        func match(_ regex: NSRegularExpression, _ line: String) -> String? {
            guard let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r = Range(m.range(at: 1), in: line) else { return nil }
            return String(line[r]).trimmingCharacters(in: .whitespaces)
        }
        func boundary(_ line: String) -> Bool {
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.range(of: #"(?i)^(patient|MRN\b|PHN\b|DOB\b|exam\b|clinical\b|findings\b|impression\b|reported\b|electronically\b|date\s*:|---\s*page)|^[MF]\s+\d+\s+yrs"#, options: .regularExpression) != nil
                || text.range(of: #"^[A-Z'’-]+,\s*[A-Z'’-]+\s*$"#, options: .regularExpression) != nil
                || text.range(of: #"^[A-Z][a-z'’-]+,\s*[A-Z][a-z'’-]+\s*$"#, options: .regularExpression) != nil
        }
        var result: [ProviderContactBlock] = []
        for (index, line) in lines.enumerated() {
            if let name = match(heading, line) {
                var block = [line]
                for next in lines.dropFirst(index + 1).prefix(10) {
                    if boundary(next) || match(heading, next) != nil || match(signed, next) != nil { break }
                    block.append(next)
                }
                result.append(.init(name: name, source: block.joined(separator: "\n")))
            } else if line.range(of: #"(?i)(reported|signed|MD\b)"#, options: .regularExpression) != nil,
                      let name = match(signed, line) {
                // Never attach the next block's phone/address to a signatory.
                result.append(.init(name: name, source: line))
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert(nameKey($0.name) + "|" + $0.source).inserted }
    }

    /// Full page context retains letterhead/footer relationships lost by OCR reading order.
    /// This is evidence for verification, not permission to attach every contact on the page.
    public static func evidenceContext(for block: ProviderContactBlock, in source: String) -> String {
        let pages = source.components(separatedBy: "--- Page ")
        return pages.first(where: { $0.contains(block.source) }) ?? block.source
    }

    public static func draft(for block: ProviderContactBlock, session: Session) -> SummaryEntry {
        SummaryEntry(category: .practitionerContact, title: block.name,
                     fields: [.init(label: "Name", value: block.name)],
                     sourceSessionID: session.id, sourceTitle: session.title, sourceDate: session.date,
                     sourceExcerpt: block.source, provenance: "Provider contact block", needsReview: true)
    }
}
