import Foundation
import NaturalLanguage

public enum RecordDetailTagLabel {
    public static func make(_ title: String, factKey: String? = nil) -> String {
        let original = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,:;!?"))
        guard !original.isEmpty else { return "…" }
        let clean = topic(in: original)
        if let factKey, let name = matchingName(factKey, in: clean) { return name }
        if clean.range(of: #"(?i)^(dr\.? )\p{L}+(?: [\p{L}’'-]+)?$"#, options: .regularExpression) != nil { return clean }
        if clean.range(of: #"(?i)\b(?:follow[- ]up|next) (?:appointment|visit)\b"#, options: .regularExpression) != nil { return "Follow-up visit" }
        if let pain = clean.firstMatch(of: #/(?i)\b((?:lower |upper |intermittent |spasmodic )?(?:back|neck|pelvic|joint|abdominal|chest) pain)\b/#) {
            let label = String(pain.1)
            return label.prefix(1).uppercased() + label.dropFirst()
        }
        if clean.range(of: #"(?i)\bappointment\b"#, options: .regularExpression) != nil { return "Appointment" }

        // Preserve both the person and the timing of a support person's arrival.
        if let match = clean.firstMatch(of: #/(?i)\b(mother|father|partner|husband|wife|sister|brother|friend)\b (?:is (?:expected|planning) to arrive|will arrive|arrives|is arriving) (?:on )?(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|tomorrow|today)\b/#) {
            return String(match.1).capitalized + " · " + String(match.2)
        }

        // A named object after an action verb is usable even when lexical tags
        // are unavailable. Strip timing qualifiers from the compact label.
        if let match = clean.firstMatch(of: #/(?i)\b(?:use|using|taking|take|declined)\s+(?:the\s+|a\s+|an\s+)?(.+?)(?:\s+(?:now|today|again|at this visit|for now)\b.*|$)/#) {
            let subject = String(match.1)
            let words = subject.lowercased().split(separator: " ")
            let vague: Set<Substring> = ["it","this","that","them","anything","something","to","any"]
            if (1...3).contains(words.count), words.allSatisfy({ !vague.contains($0) }) {
                return subject.prefix(1).uppercased() + subject.dropFirst()
            }
        }

        // Prefer the detail's subject over introductory narrative or a partial sentence.
        let generic: Set<String> = ["there", "it", "that", "this", "patient", "patient’s", "patient's", "clinician", "doctor", "person", "people", "something", "anything", "things", "time", "use", "plan", "option"]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = clean
        tagger.setLanguage(.english, range: clean.startIndex..<clean.endIndex)
        var phrase: [String] = []
        var best: [String] = []
        var hasNoun = false
        func finish() {
            if hasNoun && phrase.count > best.count { best = Array(phrase.suffix(3)) }
            phrase.removeAll()
            hasNoun = false
        }
        tagger.enumerateTags(in: clean.startIndex..<clean.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace]) { tag, range in
            let word = String(clean[range])
            if (tag == .noun || tag == .adjective) && !generic.contains(word.lowercased()) {
                phrase.append(word)
                if tag == .noun { hasNoun = true }
            } else { finish() }
            return true
        }
        finish()
        guard !best.isEmpty else { return "…" }
        let label = best.joined(separator: " ")
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    private static func topic(in title: String) -> String {
        // Identify the reporting clause before choosing a label. A person mentioned
        // inside the reported detail can still be the subject of the tag.
        let attribution = #/^(?:(?i:(?:the |my |our )?(?:[\w’-]+ ){0,2}(?:patient|clinician|doctor|provider|midwife|nurse|therapist|pharmacist|specialist|parent|caregiver))|(?:Dr\.? )?\p{Lu}[\p{L}’'-]*(?: \p{Lu}[\p{L}’'-]*){0,2})\s+(?i:(?:reports?|reported|describes?|described|mentions?|mentioned|says|said|states?|stated|notes?|noted|explains?|explained|discusses|discussed|asks? about|asked about|recalls?|recalled)\s+(?:that\s+)?)/#
        var text = title[...]
        if let match = title.prefixMatch(of: attribution) {
            text = title[match.range.upperBound...]
            if let lead = text.prefixMatch(of: #/^(?i:she|he|they|I|the|a|an)\s+/#) {
                text = text[lead.range.upperBound...]
            }
        } else if let lead = text.prefixMatch(of: #/^(?i:(?:the )?patient(?:['’]s)?)\s+/#) {
            text = text[lead.range.upperBound...]
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func matchingName(_ key: String, in text: String) -> String? {
        let parts = key.split(separator: "-")
        guard (1...3).contains(parts.count) else { return nil }
        let name = parts.joined(separator: " ")
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let match = text[range]
        return match.prefix(1).uppercased() + match.dropFirst()
    }
}
