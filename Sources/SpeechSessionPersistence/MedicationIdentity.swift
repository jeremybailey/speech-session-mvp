import Foundation

/// Product identity for presentation, independent of dispensing events and repeated metadata.
/// Does not infer brand/generic equivalence or convert clinical units.
public enum MedicationIdentity {
    private static let strength = try! NSRegularExpression(pattern:
        #"(?i)(?<![\p{L}\d.])(?:\d+(?:\.\d+)?|\.\d+)\s*(?:mcg|µg|μg|ug|mg|g|ml|iu|units?|%)(?:\s*/\s*(?:(?:\d+(?:\.\d+)?|\.\d+)\s*)?(?:ml|g|l))?(?!\p{L})"#)
    private static let number = try! NSRegularExpression(pattern: #"\d*\.\d+|\d+"#)

    public static func key(_ entry: SummaryEntry) -> String {
        let title = normalized(entry.title)
        let titleStrengths = strengths(title)
        let name = strength.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !name.isEmpty else { return "medication|" + entry.id.uuidString }
        let explicit = entry.fields.filter { ["strength", "concentration"].contains($0.label.lowercased()) }
            .flatMap { strengths(normalized($0.value)) }
        if !titleStrengths.isEmpty, !explicit.isEmpty, Set(titleStrengths) != Set(explicit) {
            return "medication|conflict|" + entry.id.uuidString
        }
        let values: [String]
        if !titleStrengths.isEmpty { values = titleStrengths }
        else if !explicit.isEmpty { values = explicit }
        else {
            // Legacy strength may live in Dose/details. Once named, a product must not split
            // because another occurrence repeats strength or mentions a dispensed volume.
            let dose = ([entry.evidence?.dose ?? ""] + entry.fields.filter { $0.label.lowercased() == "dose" }.map(\.value)).joined(separator: " ")
            let doses = strengths(normalized(dose))
            values = doses.isEmpty ? strengths(normalized(entry.details)) : doses
        }
        return "medication|" + name + "|" + Set(values).sorted().joined(separator: ",")
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "µg", with: "mcg").replacingOccurrences(of: "μg", with: "mcg")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func strengths(_ text: String) -> [String] {
        strength.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            var value = String(text[range]).replacingOccurrences(of: " ", with: "")
            for match in number.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range, in: value) else { continue }
                let decimal = NSDecimalNumber(string: String(value[range]), locale: Locale(identifier: "en_US_POSIX"))
                value.replaceSubrange(range, with: decimal.stringValue)
            }
            return value
        }
    }
}
