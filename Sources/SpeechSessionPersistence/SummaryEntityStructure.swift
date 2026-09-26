import Foundation

/// Structural validity is independent of clinical completeness and source verification.
public enum SummaryEntityStructure {
    private static let attributes: Set<String> = ["strength", "dose", "dosage", "frequency", "route", "duration", "instructions", "concentration", "date", "eventdate", "phone", "email", "address", "org", "organization", "role", "specialty", "result", "value", "units", "reference range", "practitioner", "status", "sourceexcerpt", "sourcepage", "pharmacyname", "pharmacy", "dayssupply", "datefilled", "datestarted", "datestopped", "prescriptionnumber", "quantity", "refills", "din", "form", "dosageform"]
    public static func isAttribute(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? trimmed
        let key = label.lowercased().filter { $0.isLetter || $0.isNumber }
        let machineField = trimmed.contains(":") && (label.contains("_") || label.range(of: #"[a-z][A-Z][a-z]"#, options: .regularExpression) != nil)
        return machineField || attributes.contains { $0.filter { $0.isLetter || $0.isNumber } == key }
    }
    public static func exclusion(_ entry: SummaryEntry) -> String? {
        let title = entry.title.lowercased()
        if entry.category == .otherNotes,
           ["make sure this makes it into", "include this in my health story", "add this to my health story"].contains(where: title.contains) {
            return "This is a request about organizing the record, not a separate health detail."
        }
        if isAttribute(entry.title) {
            return "This is a field belonging to another detail, not a separate health entry. It remains in the original record."
        }
        if entry.category == .medications {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || title.range(of: #"(?i)^(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\s*(?:mcg|mg|ml|g|iu|units|%)(?:\s*/\s*(?:[0-9.]+\s*)?(?:ml|g|l))?$"#, options: .regularExpression) != nil {
                return "No medication name was attached to this strength or dose. It remains in the original record."
            }
        }
        return nil
    }

    /// Indented attributes belong to the preceding item; unbound lines stay separate for rejection.
    /// Never attach attributes across a blank line or an independently bulleted item.
    public static func lines(_ raw: String) -> [String] {
        var result: [String] = []
        var parent: Int?
        for line in raw.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { parent = nil; continue }
            let unmarked = text.hasPrefix("- ") ? String(text.dropFirst(2)) : text
            let indented = line.first?.isWhitespace == true
            if indented, isAttribute(unmarked), let index = parent {
                result[index] += result[index].contains(" — ") ? "; " + unmarked : " — " + unmarked
            } else {
                result.append(unmarked)
                parent = isAttribute(unmarked) ? nil : result.count - 1
            }
        }
        return result
    }
}
