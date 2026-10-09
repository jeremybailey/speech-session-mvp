import Foundation

/// Display projection only: structured values take precedence over repeated prose.
public enum HealthDetailPresentation {
    public static func fields(_ entry: SummaryEntry) -> [SummaryEntryField] {
        var seen = Set<String>()
        return entry.fields.filter {
            !["name", "details"].contains($0.label.lowercased()) && !HealthStoryText.isInternalField($0.label)
                && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && normalize($0.value) != normalize(entry.title)
                && seen.insert(normalize($0.label) + "|" + normalize($0.value)).inserted
        }
    }
    public static func remainingDetails(_ entry: SummaryEntry) -> [String] {
        let structured = fields(entry)
        let values = structured.map { normalize($0.value) }
        let text = HealthStoryText.cleanForDisplay(entry.details).replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"[;|]\s*(?=(?i:phone|email|address|clinic|organization|role|specialty|dose|frequency|notes):)"#, with: "\n", options: .regularExpression)
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line
            if entry.category == .practitionerContact,
               let colon = line.firstIndex(of: ":") {
                let label = normalize(String(line[..<colon]))
                let aliases = ["org": "organization", "clinic": "organization", "role": "role or specialty", "specialty": "role or specialty"]
                if structured.contains(where: { normalize($0.label) == (aliases[label] ?? label) }) { return nil }
            }
            if let colon = line.firstIndex(of: ":"), structured.contains(where: { normalize($0.label) == normalize(String(line[..<colon])) }) {
                value = String(line[line.index(after: colon)...])
            }
            let normalized = normalize(value)
            guard !normalized.isEmpty, normalized != normalize(entry.title), seen.insert(normalized).inserted else { return nil }
            if values.contains(normalized) { return nil }
            // An address may be repeated as several prose lines beneath a single structured address.
            if entry.category == .practitionerContact,
               structured.contains(where: { ["address", "phone", "email"].contains($0.label.lowercased()) && (" " + normalize($0.value) + " ").contains(" " + normalized + " ") }) { return nil }
            return line
        }
    }
    private static func normalize(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}
