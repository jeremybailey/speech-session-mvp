import Foundation
import CryptoKit

public struct WholeHistoryDecodedFact: Identifiable {
    public let id: String, text: String, category: String, status: String, by: String, event: String
    public let groups: [String], quotes: [String]
    public let plan: [String: String]?
    public var medication: StructuredMedication?
    public var fields: [SummaryEntryField]?
}
public struct WholeHistoryDecodedConcern: Identifiable {
    public let id: String, name: String
    public let systems: [String]
}
public struct WholeHistoryDecodedResult {
    public let facts: [WholeHistoryDecodedFact]
    public let concerns: [WholeHistoryDecodedConcern]
    public let overview: [String]
}

/// The app entry point and parity tests use this same source-validation decoder.
public enum WholeHistoryResponseContract {
    public struct Failure: LocalizedError {
        public let code: String
        public var errorDescription: String? {
            "We couldn’t use this update. Your saved details are available. Start a new update to try again."
        }
    }
    public static func decode(_ raw: String, locators: [String: [String: Any]]?,
                              originals: [[String: Any]]?, version: String?) throws -> WholeHistoryDecodedResult {
        func fail(_ line: Int = #line) -> Failure { Failure(code: "details_validation_\(line)") }
        guard let data = raw.data(using: .utf8), let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw fail() }
        let result = parsed
        guard Set(result.keys) == ["concerns", "overview", "passages"],
              let locators, let originals,
              let groups = result["concerns"] as? [[String: Any]], groups.count <= 256,
              let passages = result["passages"] as? [String: Any], Set(passages.keys) == Set(locators.keys),
              let paragraphs = result["overview"] as? [[String: Any]], (1...6).contains(paragraphs.count) else { throw fail() }
        guard Set(originals.compactMap { $0["id"] as? String }).count == originals.count else { throw fail() }
        if version == "compact-actions-short-overview-v1" {
            guard paragraphs.count == 1, let text = paragraphs[0]["text"] as? String,
                  text.unicodeScalars.count <= 1000, !text.contains("\n"), !text.contains("\r") else { throw fail() }
        }
        let sourceRecords = Dictionary(uniqueKeysWithValues: originals.compactMap { r -> (String, [String: Any])? in guard let id = r["id"] as? String else { return nil }; return (id,r) })
        for locator in locators.values {
            guard let id = locator["recordID"] as? String, let record = sourceRecords[id], let text = record["text"] as? String, let quote = locator["quote"] as? String,
                  let start = locator["start"] as? Int, let end = locator["end"] as? Int, start >= 0, end >= start else { throw fail() }
            let chars = Array(text.unicodeScalars)
            guard end <= chars.count, String(String.UnicodeScalarView(chars[start..<end])) == quote,
                  locator["sourceSHA256"] as? String == SHA256.hash(data: Data(text.utf8)).map({ String(format: "%02x", $0) }).joined() else { throw fail() }
        }
        let categories = Set(SummaryEntryCategory.allCases.map(\.rawValue))
        let systems = Set(["musculoskeletal","eye","neurological","cardiovascular","respiratory","digestive","endocrine","reproductive","urinary","mental","skin","immune","ear","unknown"])
        var groupIDs = Set<String>(); var decodedGroups: [WholeHistoryDecodedConcern] = []
        for g in groups {
            guard Set(g.keys) == ["id","name","systems","evidence"], let id = g["id"] as? String, id.range(of: #"^c[1-9]\d*$"#, options: .regularExpression) != nil, let index = Int(id.dropFirst()), (1...256).contains(index), groupIDs.insert(id).inserted,
                  let name = g["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.unicodeScalars.count <= 1000,
                  let codes = g["systems"] as? [String], codes.allSatisfy({ systems.contains($0) }),
                  let evidence = g["evidence"] as? [String], !evidence.isEmpty, evidence.allSatisfy({ locators[$0] != nil }) else { throw fail() }
            decodedGroups.append(WholeHistoryDecodedConcern(id: id, name: name, systems: codes))
        }
        // Mirror the server's unique reciprocal source-edge completion.
        let assigned=Set(passages.values.compactMap{$0 as? [[String:Any]]}.flatMap{$0}.flatMap{$0["g"] as? [String] ?? []})
        let reciprocalCategories:Set<String>=["chiefComplaint","symptoms","findings","allergies"]
        let careStates = Set(["recommended","conditional","planned","prescribed","declined","performed","historical","reported","unclear"])
        let allStates = careStates.union(["negative","observed","resolved"])
        var decoded: [WholeHistoryDecodedFact] = []; var clinical = Set<String>()
        for pid in passages.keys.sorted() {
            if let exclusion = passages[pid] as? String { guard ["nonclinical","other_person","unintelligible"].contains(exclusion) else { throw fail() }; continue }
            guard let rows = passages[pid] as? [[String: Any]], !rows.isEmpty, let locator = locators[pid], let rid = locator["recordID"] as? String else { throw fail() }
            clinical.insert(pid)
            for (index, row) in rows.enumerated() {
                guard (Set(row.keys) == ["k","s","v","c","p","g"] || Set(row.keys) == ["k","s","v","c","p","g","m"] || Set(row.keys) == ["k","s","v","c","p","g","m","f"]), let k = row["k"] as? String, categories.contains(k), let status = row["s"] as? String, allStates.contains(status),
                      let v = row["v"] as? [String], v.count == 3, v.allSatisfy({ $0.unicodeScalars.count <= 1000 }), !v[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, v[0].unicodeScalars.count <= 360,
                      let c = row["c"] as? [String], c.count <= 2, c.allSatisfy({ locators[$0]?["recordID"] as? String == rid }),
                      let g = row["g"] as? [String], Set(g).count == g.count, g.allSatisfy({ groupIDs.contains($0) }) else { throw fail() }
                let plan = row["p"] as? [String: String]
                var category = k
                if let plan {
                    guard plan.values.allSatisfy({ $0.unicodeScalars.count <= 1000 }), (Set(plan.keys) == ["a","t","q"] || (Set(plan.keys) == ["a","t","q","i","h"] && ["carePlan","followUp"].contains(k) && (plan["i"] ?? "").range(of:#"^p[1-9]\d{0,3}$"#,options:.regularExpression) != nil && (plan["h"] ?? "").unicodeScalars.count<=80 && v[0].unicodeScalars.count<=160)), (plan["a"] ?? "").range(of: #"^r\d+\.p\d+(\.\d+)?$"#, options: .regularExpression) == nil else { throw fail() }
                    if ["planned","recommended","conditional","prescribed"].contains(status) {
                        if k == "testsAndLabs" { category = "carePlan" }
                        if k == "practitionerContact" { category = "followUp" }
                    }
                    // Source instructions may accompany a historical or reported medication.
                    // The recorded status still determines whether the event is past/current.
                    guard ["carePlan","followUp","vaccinations","medications"].contains(category) else { throw fail() }
                } else if !(row["p"] is NSNull) { throw fail() }
                if ["carePlan","followUp"].contains(category) { guard plan != nil, careStates.contains(status) else { throw fail() } }
                let refs = Array(Set([pid] + c)).sorted()
                var medication: StructuredMedication?
                if let fields = row["m"] as? [String: Any] {
                    guard k == "medications", Set(fields.keys) == Set(StructuredMedication.keys), fields.values.allSatisfy({ ($0 is NSNull) || (($0 as? String).map { $0.unicodeScalars.count <= 360 } ?? false) }) else { throw fail() }
                    medication = StructuredMedication.grounded(fields.compactMapValues { $0 as? String }, in: refs.compactMap { locators[$0]?["quote"] as? String })
                } else if let value = row["m"], (!(value is NSNull) || k == "medications") { throw fail() }
                var artifactFields: [SummaryEntryField]?
                var decodedFields=row["f"] as? [[String]]
                if let objects=row["f"] as? [[String:Any]], !objects.isEmpty {
                    guard objects.allSatisfy({Set($0.keys)==["key","value"] && $0["key"] is String && $0["value"] is String}) else {throw fail()}
                    decodedFields=objects.map{[$0["key"] as! String,$0["value"] as! String]}
                }
                if let object=row["f"] as? [String:Any] {
                    guard let kind=SummaryEntryCategory(rawValue:k),let pairs=StructuredArtifact.pairsFromObject(object,category:kind) else {throw fail()}
                    decodedFields=pairs
                }
                if let values = decodedFields {
                    guard let kind=SummaryEntryCategory(rawValue:k), let allowed=StructuredArtifact.keys[kind], values.count<=12,
                          values.allSatisfy({$0.count==2 && allowed.contains($0[0]) && !$0[1].trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0[1].unicodeScalars.count<=360}),
                          StructuredArtifact.hasValidMultiplicity(values,category:kind) else { throw fail() }
                    artifactFields=StructuredArtifact.grounded(values,category:kind,sources:refs.compactMap {locators[$0]?["quote"] as? String})
                } else if let value=row["f"], (!(value is NSNull) || StructuredArtifact.keys[SummaryEntryCategory(rawValue:k)!] != nil) { throw fail() }
                let reciprocal: [String] = rows.count == 1 && (g.isEmpty || (k == "allergies" && g.allSatisfy{id in groups.contains{($0["id"] as? String)==id && ($0["evidence"] as? [String] ?? []).contains(pid)}})) && row["p"] is NSNull && reciprocalCategories.contains(k)
                    ? groups.filter{ group in
                        guard let id=group["id"] as? String,let evidence=group["evidence"] as? [String] else{return false}
                        return !assigned.contains(id) && evidence == [pid]
                    }.compactMap{$0["id"] as? String} : []
                decoded.append(WholeHistoryDecodedFact(id: "\(pid).\(index+1)", text: v[0], category: category, status: status, by: v[1], event: v[2], groups: g + reciprocal,
                    quotes: refs.compactMap { ref in guard let quote = locators[ref]?["quote"] as? String else { return nil }; return ref + "\n" + quote }, plan: plan, medication: medication, fields: artifactFields))
            }
        }
        guard decodedGroups.allSatisfy({ group in decoded.contains { $0.groups.contains(group.id) } }) else { throw fail() }
        var texts: [String] = []
        for p in paragraphs {
            guard let text = p["text"] as? String, !text.isEmpty, let refs = p["cite"] as? [String], !refs.isEmpty, refs.allSatisfy({ locators[$0] != nil }), refs.contains(where: { clinical.contains($0) }) else { throw fail() }
            texts.append(text)
        }

        return WholeHistoryDecodedResult(facts: decoded, concerns: decodedGroups, overview: texts)
    }
}
