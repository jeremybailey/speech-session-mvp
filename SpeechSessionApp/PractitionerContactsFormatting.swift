import Foundation
import SpeechSessionPersistence

/// Post-processing and shared policy helper for care-team contact cards.
enum PractitionerContactsFormatting {

    /// Extracts editable contact-card fields from one generated/source line. Unknown contact details are shown as placeholders for review.
    static func editableFields(from rawLine: String) -> [SummaryEntryField] {
        let original = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = sanitizeLine(original) ?? original
        let email = firstMatch(in: original, pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#)
        let phone = firstMatch(in: original, pattern: #"(?:(?:\+?1[\s.\-]?)?(?:\(\s*\d{3}\s*\)|\d{3})[\s.\-]?\d{3}[\s.\-]?\d{4})(?:\s*(?:ext\.?|x)\s*\d+)?"#)
        let address = addressFragment(in: original)

        return [
            SummaryEntryField(label: "Name", value: name, isMissing: name.isEmpty, needsReview: name.isEmpty),
            SummaryEntryField(label: "Role or specialty", value: "", isMissing: true, needsReview: true),
            SummaryEntryField(label: "Organization", value: "", isMissing: true, needsReview: true),
            SummaryEntryField(label: "Phone", value: phone ?? "", isMissing: phone == nil, needsReview: phone == nil),
            SummaryEntryField(label: "Email", value: email ?? "", isMissing: email == nil, needsReview: email == nil),
            SummaryEntryField(label: "Address", value: address ?? "", isMissing: address == nil, needsReview: address == nil),
        ]
    }

    /// Returns one **person or organization name** per non-empty line; strips numbers, phones, emails, and text after detail separators when that tail looks like contact/address data.
    static func namesOnly(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lines = raw.components(separatedBy: .newlines)
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            guard let cleaned = sanitizeLine(line) else { continue }
            if out.last?.caseInsensitiveCompare(cleaned) != .orderedSame {
                out.append(cleaned)
            }
        }
        guard !out.isEmpty else { return nil }
        return out.joined(separator: "\n")
    }

    private static func sanitizeLine(_ line: String) -> String? {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("- ") { s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if s.hasPrefix("• ") { s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if s.hasPrefix("* ") { s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let r = s.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            s.removeSubrange(r)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        s = s.replacingOccurrences(of: "**", with: "")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let lower = s.lowercased()
        if lower.hasPrefix("printed contact") {
            if let colon = s.firstIndex(of: ":") {
                s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !s.isEmpty else { return nil }

        if let r = s.range(of: " — ") {
            let after = String(s[r.upperBound...])
            if after.contains(where: \.isNumber) || addressHint(in: after) || after.contains("@") || phoneFragment(in: after) {
                s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let r = s.range(of: " – ") {
            let after = String(s[r.upperBound...])
            if after.contains(where: \.isNumber) || addressHint(in: after) || after.contains("@") || phoneFragment(in: after) {
                s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let r = s.range(of: " - ") {
            let after = s[r.upperBound...]
            if after.contains(where: \.isNumber) || addressHint(in: String(after)) {
                s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let comma = s.firstIndex(of: ",") {
            let tail = s[s.index(after: comma)...]
            if tail.contains(where: \.isNumber) || addressHint(in: String(tail)) {
                s = String(s[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let at = s.firstIndex(of: "@") {
            s = String(s[..<at]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        s = stripPhonePatterns(s)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;—–-"))

        guard !s.isEmpty, containsLetters(s) else { return nil }
        guard !isMostlyDigits(s) else { return nil }
        return s
    }

    private static func containsLetters(_ s: String) -> Bool {
        s.contains { $0.isLetter }
    }

    private static func isMostlyDigits(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber).count
        let letters = s.filter(\.isLetter).count
        return digits >= 5 && digits > letters
    }

    private static func phoneFragment(in fragment: String) -> Bool {
        fragment.range(of: #"\d{3}[\s.\-]?\d{3}[\s.\-]?\d{4}"#, options: .regularExpression) != nil
    }

    private static func addressHint(in fragment: String) -> Bool {
        let f = fragment.lowercased()
        let hints = [
            "street", "st.", "st ", "avenue", "ave ", "ave.", "road", "rd.", "rd ", "blvd", "boulevard",
            "suite", "ste ", "ste.", "unit ", "floor", "zip", "po box", "p.o. box", "box ",
            "highway", "hwy", "ln ", "lane", "court", "ct.",
        ]
        return hints.contains { f.contains($0) }
    }

    private static func stripPhonePatterns(_ s: String) -> String {
        let patterns = [
            #"(?:(?:\+?1[\s.\-]?)?(?:\(\s*\d{3}\s*\)|\d{3})[\s.\-]?\d{3}[\s.\-]?\d{4})(?:\s*(?:ext\.?|x)\s*\d+)?"#,
            #"\b\d{3}[\s.\-]?\d{3}[\s.\-]?\d{4}\b"#,
        ]
        var r = s
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: .caseInsensitive) else { continue }
            let range = NSRange(r.startIndex..., in: r)
            r = regex.stringByReplacingMatches(in: r, range: range, withTemplate: " ")
        }
        while r.contains("  ") {
            r = r.replacingOccurrences(of: "  ", with: " ")
        }
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range, in: text) else { return nil }
        let value = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func addressFragment(in text: String) -> String? {
        // Only an explicit address field can establish its boundaries. Never treat a numeric tail as an address.
        let pattern = #"(?i)\baddress\s*:\s*(.*?)(?=;\s*(?:org|organization|clinic|phone|email|role|specialty)\s*:|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.range(of: #"(?i)\b(org|phone|email|role)\s*:"#, options: .regularExpression) == nil else { return nil }
        return value
    }
}
