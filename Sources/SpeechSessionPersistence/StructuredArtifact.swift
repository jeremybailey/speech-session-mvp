import Foundation

/// Sparse typed values selected from original passages in B's existing request.
public enum StructuredArtifact {
    public static let version = "structured-artifacts-v3"
    public static let keys: [SummaryEntryCategory: [String]] = [
        .practitionerContact:["name","organization","role","phone","email","address","context"],
        .chiefComplaint:["name","location","onset","duration","severity","frequency","context"],
        .symptoms:["name","location","onset","duration","severity","frequency","context"],
        .findings:["name","result","location","interpretation","context"],
        .testsAndLabs:["name","result","units","referenceRange","specimen","interpretation","context"],
        .allergies:["name","reaction","severity","recordStatus","context"],
        .vaccinations:["name","dose","route","site","lot","recordStatus","context"],
        .biopsychosocialContext:["name","context"], .otherNotes:["name","context"]]
    /// Decode the v7 category-scoped wire object; null fields mean absent.
    public static func pairsFromObject(_ object:[String:Any], category:SummaryEntryCategory) -> [[String]]? {
        guard let allowed=keys[category],Set(object.keys)==Set(allowed),
              object.values.allSatisfy({$0 is String || $0 is NSNull}) else {return nil}
        let pairs=allowed.compactMap {key in (object[key] as? String).map{[key,$0]}}
        guard pairs.allSatisfy({!$0[1].trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0[1].unicodeScalars.count<=360}) else {return nil}
        return pairs
    }
    public static func label(_ key: String, category: SummaryEntryCategory) -> String {
        if key == "name" { return "Name" }
        return ["organization":"Organization","role":"Role or specialty","phone":"Phone","email":"Email","address":"Address",
                "context":"Context","location":"Location","onset":"Onset","duration":"Duration","severity":"Severity","frequency":"Frequency",
                "result":"Result","interpretation":"Interpretation","units":"Units","referenceRange":"Reference range","specimen":"Specimen",
                "reaction":"Reaction","recordStatus":"Recorded status","dose":"Dose","route":"Route","site":"Site","lot":"Lot"][key] ?? key
    }
    public static func grounded(_ pairs: [[String]], category: SummaryEntryCategory, sources: [String]) -> [SummaryEntryField] {
        func normalize(_ s:String) -> String { s.precomposedStringWithCompatibilityMapping.lowercased().split(whereSeparator:\.isWhitespace).joined(separator:" ") }
        let quotes=sources.map(normalize)
        return pairs.compactMap { pair in
            guard pair.count==2, keys[category]?.contains(pair[0])==true, !pair[1].trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  quotes.contains(where:{$0.contains(normalize(pair[1]))}) else { return nil }
            return .init(label:label(pair[0],category:category),value:pair[1])
        }
    }
    public static func display(_ entry: SummaryEntry) -> SummaryEntry {
        var result=entry
        if let name=entry.fields.first(where:{$0.label=="Name" && !$0.value.isEmpty}) { result.title=name.value }
        // The statement carries qualifiers/negation not expressed by a source value.
        // Only identical names and values are removed; never discard a qualifier.
        result.details=entry.title == result.title ? entry.details : ([entry.title,entry.details].filter{!$0.isEmpty}.joined(separator:"\n"))
        result.fields=entry.fields.filter{!$0.value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
        return result
    }
}
