import Foundation

/// Source-selected medication fields, independent of a prescription/fill event.
/// A record saying active/prescribed does not establish present patient use.
public struct StructuredMedication: Codable, Hashable, Sendable {
    public static let keys = ["name", "strength", "form", "dose", "frequency", "route", "duration", "instructions", "clinician", "recordDate", "recordStatus", "uncertainty"]
    public var values: [String: String]
    /// Audit only: never render rejected values as clinical fields.
    public var rejectedValues: [String: String]? = nil
    public init(values: [String: String]) { self.values = values }
    public subscript(_ field: String) -> String? { values[field].flatMap { $0.isEmpty ? nil : $0 } }
    public static func grounded(_ values: [String: String], in sources: [String]) -> Self {
        func normalized(_ text: String) -> String {
            text.precomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let quotes = sources.map(normalized)
        let supported = values.filter { field in keys.contains(field.key) && !field.value.isEmpty && quotes.contains(where: { quote in quote.contains(normalized(field.value)) }) }
        var result = Self(values: supported)
        result.rejectedValues = values.filter { supported[$0.key] == nil }
        return result
    }
}

public enum BClinicalPresentation {
    public static func applies(_ entry: SummaryEntry) -> Bool {
        entry.origin == .generated && entry.evidence?.assessmentMethod == WholeHistoryPublication.version
    }
    public static func namedPractitioner(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let words = Set(value.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        guard words.isDisjoint(with: ["prescription","label","invoice","record","report","list","source","patient","image","unknown","unspecified"]) else { return nil }
        let namedRole = value.range(of: #"(?i)^(?:dr\.\s*|dr\s+|doctor\s+|nurse\s+|np\s+|rn\s+|physiotherapist\s+|pharmacist\s+)\p{L}"#, options: .regularExpression) != nil
        let personName = value.range(of: #"^\p{Lu}[\p{L}'’.-]+(?:\s+\p{Lu}[\p{L}'’.-]+){1,4}$"#, options: .regularExpression) != nil
        let organizationWords: Set<String> = ["pharmacy","clinic","hospital","centre","center","laboratory","department","mart"]
        return namedRole || (personName && words.isDisjoint(with: organizationWords)) ? value : nil
    }

    public static func display(_ entry: SummaryEntry) -> SummaryEntry {
        guard applies(entry) else { return entry }
        if entry.category == .medications { return medicationDisplay(entry) }
        return BArtifactPresentation.display(entry)
    }
    public static func medication(_ entry: SummaryEntry) -> StructuredMedication {
        guard applies(entry) else { return StructuredMedication(values: [:]) }
        if let structured = entry.evidence?.medication { return structured }
        return legacyMedication(entry)
    }

    public static func medicationDisplay(_ entry: SummaryEntry) -> SummaryEntry {
        guard applies(entry), entry.category == .medications else { return entry }
        let medication = medication(entry)
        var result = entry
        result.title = medication["name"] ?? "Medication — check original"
        result.details = ""
        let labels = [("strength","Strength"),("form","Form"),("dose","Recorded dose"),("frequency","Recorded frequency"),
                      ("route","Route"),("duration","Duration"),("instructions","Recorded instructions"),("recordDate","Record date")]
        result.fields = labels.compactMap { key,label in
            guard let value = medication[key] else { return nil }
            return SummaryEntryField(label: label, value: key == "form" ? displayForm(value) : value)
        }
        if medication["uncertainty"] != nil || [entry.title, entry.evidence?.careInstruction?.consideration ?? ""].contains(where: { $0.localizedCaseInsensitiveContains("unclear") || $0.localizedCaseInsensitiveContains("source spelling") }) {
            result.fields.append(.init(label: "Review", value: "Some details are unclear; check the original."))
        }
        result.evidence?.practitioner = namedPractitioner(medication["clinician"])
        result.evidence?.eventDate = medication["recordDate"]
        return result
    }
    public static func displayForm(_ value: String) -> String {
        let key = value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let forms = ["op drp":"Eye drops", "eye drops":"Eye drops", "ophthalmic drops":"Eye drops", "gel eye drops":"Eye gel drops",
                     "eye ointment":"Eye ointment", "tablet":"Tablet", "tablets":"Tablet", "capsule":"Capsule", "capsules":"Capsule",
                     "solution":"Solution", "cream":"Cream", "ointment":"Ointment"]
        return forms[key] ?? value
    }
    public static func productKey(_ entry: SummaryEntry) -> String? {
        guard applies(entry), entry.category == .medications else { return nil }
        let m = medication(entry)
        guard let name = m["name"], !["eye drops","steroid eye drops","medication","unknown medication"].contains(name.lowercased()),
              !["unknown","unspecified","unclear"].contains(where: { name.lowercased().contains($0) }) else { return "medication|uncertain|" + entry.id.uuidString }
        func fold(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        // Shared-unit combination notation is compared only within the same named
        // product and form. Do not convert ratios (mg/mL), ingredients or units.
        var strength = fold(m["strength"] ?? "").replacingOccurrences(of: " ", with: "")
        if let regex = try? NSRegularExpression(pattern: #"^(\d+(?:\.\d+)?)/(\d+(?:\.\d+)?)%$"#),
           let match = regex.firstMatch(in: strength, range: NSRange(strength.startIndex..., in: strength)),
           let a = Range(match.range(at:1),in:strength), let b = Range(match.range(at:2),in:strength) {
            strength = String(strength[a]) + "%-" + String(strength[b]) + "%"
        }
        strength = strength.replacingOccurrences(of: "µg", with: "mcg").replacingOccurrences(of: "μg", with: "mcg")
        if let numbers = try? NSRegularExpression(pattern: #"\d*\.\d+|\d+"#) {
            for match in numbers.matches(in: strength, range: NSRange(strength.startIndex..., in: strength)).reversed() {
                if let range = Range(match.range, in: strength) {
                    let decimal = NSDecimalNumber(string: String(strength[range]), locale: Locale(identifier: "en_US_POSIX"))
                    strength.replaceSubrange(range, with: decimal.stringValue)
                }
            }
        }
        return "medication|" + fold(name) + "|" + fold(displayForm(m["form"] ?? "")) + "|" + strength
    }
    /// Compatibility for cached B narratives. These are syntax boundaries, never
    /// medication-specific aliases or expansion of ambiguous prescribing shorthand.
    private static func legacyMedication(_ entry: SummaryEntry) -> StructuredMedication {
        let text = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        func capture(_ pattern: String, in value: String? = nil, group: Int = 1) -> String? {
            let source = value ?? text
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let range = Range(m.range(at: group), in: source) else { return nil }
            return String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var product = MedicationIdentity.reportProductTitle(entry)
        if product == text {
            product = capture(#"(?i)^prescription(?: image wording| label reads)?\s*:?\s*'([^']+)'"#)
                ?? capture(#"(?i)^invoice lists (.+?)(?:,\s*\$|;|$)"#)
                ?? capture(#"(?i)^(?:patient )?reports (?:taking|using|having started)\s+(.+?)(?:\s+on odd|;|,|$)"#)
                ?? capture(#"(?i)^(?:patient )?reports\s+(.+?)(?:,|;|$)"#) ?? text
        }
        var values: [String:String] = [:]
        let strengthPattern = #"(?i)(?<![\p{L}\d.])(?:(?:\d+(?:\.\d+)?|\.\d+)\s*%\s*[-/]\s*(?:\d+(?:\.\d+)?|\.\d+)\s*%|(?:\d+(?:\.\d+)?|\.\d+)(?:\s*[/\-]\s*(?:\d+(?:\.\d+)?|\.\d+))?\s*(?:mcg|µg|μg|ug|mg|g|ml|iu|units?|%)(?:\s*/\s*(?:(?:\d+(?:\.\d+)?|\.\d+)\s*)?(?:ml|g|l))?)(?!\p{L})"#
        let forms = #"(?i)(gel eye drops|eye drops|eye ointment|ophthalmic drops|op drp|tablets?|capsules?|solution|cream|ointment|injection)"#
        if let regex = try? NSRegularExpression(pattern: strengthPattern),
           let match = regex.firstMatch(in: product, range: NSRange(product.startIndex..., in: product)),
           let range = Range(match.range,in:product) {
            values["strength"] = String(product[range])
            let before = String(product[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let after = String(product[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let form = capture(forms + #"\s*$"#, in: before) {
                values["form"] = form
                values["name"] = String(before.dropLast(form.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else { values["name"] = before }
            if let form = capture("^" + forms, in: after) { values["form"] = form }
        } else if product.count <= 100, product.split(separator:" ").count <= 10 {
            values["name"] = product
            if let form = capture(forms + #"\s*$"#, in: product) { values["form"] = form }
        }
        if let name = values["name"] {
            values["name"] = name.replacingOccurrences(of: #"(?i)^prescription(?:\s+image wording)?\s*:\s*'?"#, with:"",options:.regularExpression).trimmingCharacters(in:CharacterSet(charactersIn:" '\";,."))
        }
        values["instructions"] = capture(#"(?i)(?:label direction|directions|instructions):\s*([^;]+)"#)
        values["recordDate"] = entry.evidence?.eventDate.flatMap { $0.isEmpty ? nil : $0 }
        // Preserve ambiguous numeric date wording instead of a model-selected month/day order.
        if let date = capture(#"\b(\d{1,2}[-/]\d{1,2}[-/]\d{4})\b"#) { values["recordDate"] = date }
        values["clinician"] = namedPractitioner(entry.evidence?.practitioner)
        let qualifier = entry.evidence?.careInstruction?.consideration ?? ""
        if text.localizedCaseInsensitiveContains("unclear") || text.localizedCaseInsensitiveContains("source spelling") || qualifier.localizedCaseInsensitiveContains("unclear") {
            values["uncertainty"] = "Source wording needs review"
        }
        return StructuredMedication(values: values)
    }
}

/// Shared publication projection. Withholding never deletes a source or patient edit.
public enum HealthStoryEligibility {
    public static func includes(_ entry: SummaryEntry) -> Bool {
        guard !entry.isDeleted else { return false }
        guard BClinicalPresentation.applies(entry) else { return true }
        guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard entry.category == .medications else { return true }
        return usableMedicationName(BClinicalPresentation.medication(entry)["name"])
    }

    public static func usableMedicationName(_ value: String?) -> Bool {
        guard let value else { return false }
        let name = value.precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, name.contains(where: \.isLetter) else { return false }
        let generic: Set<String> = ["medication", "medications", "medicine", "drug", "unknown", "unspecified",
            "eye drops", "steroid eye drops", "tablet", "tablets", "capsule", "capsules", "check original",
            "medication — check original"]
        return !generic.contains(name) && !["unknown", "unspecified", "unclear", "unidentified"].contains(where: name.contains)
    }
}
