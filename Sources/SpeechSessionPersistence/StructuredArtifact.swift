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
        guard let allowed=keys[category] else {return nil}
        var fields=object
        if fields.keys.contains(where:{$0.hasPrefix("_pad")}) {
            let padding=(0..<(7-allowed.count)).map{"_pad\($0+1)"}
            guard Set(fields.keys)==Set(allowed+padding),padding.allSatisfy({fields[$0] is NSNull}) else {return nil}
            for key in padding {fields.removeValue(forKey:key)}
        }
        guard Set(fields.keys)==Set(allowed),fields.values.allSatisfy({$0 is String || $0 is NSNull}) else {return nil}
        let pairs=allowed.compactMap {key in (fields[key] as? String).map{[key,$0]}}
        guard pairs.allSatisfy({!$0[1].trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0[1].unicodeScalars.count<=360}) else {return nil}
        return pairs
    }
    public static func hasValidMultiplicity(_ pairs:[[String]],category:SummaryEntryCategory) -> Bool {
        var seen=Set<String>();var repeated=Set<[String]>()
        for pair in pairs {
            guard pair.count==2 else {return false}
            let repeatable=pair[0] == "context" || (category == .findings && pair[0] == "name")
            if seen.contains(pair[0]) && !(repeatable && !repeated.contains(pair)) {return false}
            seen.insert(pair[0]);repeated.insert(pair)
        }
        return true
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
        let names=entry.fields.filter{$0.label=="Name" && !$0.value.isEmpty}.map(\.value)
        if entry.category == .findings && names.count>1 {
            let heading=names.joined(separator:" · ")
            result.title=heading.count<=90 ? heading:"Clinical findings"
        } else if let name=names.first {result.title=name}
        // The statement carries qualifiers/negation not expressed by a source value.
        // Only identical names and values are removed; never discard a qualifier.
        result.details=entry.title == result.title ? entry.details : ([entry.title,entry.details].filter{!$0.isEmpty}.joined(separator:"\n"))
        result.fields=entry.fields.filter{!$0.value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
        return result
    }
}
