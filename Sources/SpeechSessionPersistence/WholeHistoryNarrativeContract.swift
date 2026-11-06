import Foundation

/// The app and audit invoke the same overview source, number and coverage checks.
public enum WholeHistoryNarrativeContract {
    public struct Failure: Error {public let reason:String}
    public struct Result {public let text:String;public let coverage:[String:String]}
    public static func decode(_ raw:String,facts:[WholeHistoryDecodedFact],concerns:[WholeHistoryDecodedConcern],writerVersion:String?,focusIDs:[String]=[]) throws -> Result {
        func fail(_ reason:String="format_or_reference") -> Failure {Failure(reason:reason)}
        let facts = writerVersion == "b-narrative-visible-v8" ? facts.filter { $0.category != "medications" || HealthStoryEligibility.usableMedicationName($0.medication?["name"]) } : facts
        let concerns = writerVersion == "b-narrative-visible-v8" ? concerns.filter { concern in facts.contains { $0.groups.contains(concern.id) } } : concerns
        let compact = ["b-narrative-visible-v8","b-narrative-compact-v6","b-narrative-brief-v7"].contains(writerVersion ?? "")
        let balanced = ["b-narrative-visible-v8","b-narrative-balanced-v3", "b-narrative-balanced-luna-v4", "b-narrative-balanced-v5", "b-narrative-compact-v6", "b-narrative-brief-v7"].contains(writerVersion ?? "")
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8)) } catch { throw fail() }
        guard let obj = parsed as? [String: Any], Set(obj.keys) == (balanced ? ["sentences", "coverage"] : ["sentences"]),
              let sentences = obj["sentences"] as? [[String: Any]], (1...(balanced ? 8 : 6)).contains(sentences.count) else { throw fail() }
        let byID = Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
        func numbers(_ text: String) -> Set<String> {
            let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z])\d+(?:[.,]\d+)?(?:%|mg|mcg|ml|weeks?|days?|years?)?"#, options: [.caseInsensitive])
            return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]).lowercased().replacingOccurrences(of: ",", with: "") } })
        }
        var texts: [String] = []; var cited = Set<String>()
        for sentence in sentences {
            guard Set(sentence.keys) == ["text", "factIDs"], let text = sentence["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= (balanced ? 1200 : 1000),
                  !text.contains("\n"), !text.contains("\r"),
                  text.range(of: #"r\d+\.p\d+\.\d+"#, options: .regularExpression) == nil,
                  let refs = sentence["factIDs"] as? [String], !refs.isEmpty, refs.allSatisfy({ byID[$0] != nil }) else { throw fail() }
            let evidence = refs.compactMap { byID[$0] }.map { fact in
                ([fact.text, fact.by, fact.event] + (["a","t","q","h"].compactMap {fact.plan?[$0]}) + (fact.fields?.map(\.value) ?? [])).joined(separator: " ")
            }.joined(separator: " ")
            guard numbers(text).isSubset(of: numbers(evidence)) else { throw fail("numbers") }
            cited.formUnion(refs); texts.append(text)
        }
        if writerVersion == "b-narrative-focus-v2" {
            for group in focusIDs {
                guard facts.contains(where: { $0.groups.contains(group) && cited.contains($0.id) }) else { throw fail() }
            }
        }
        var coverage: [String: String] = [:]
        if balanced {
            let codes: Set<String> = ["included_major", "included_secondary", "omitted_minor", "omitted_routine", "omitted_duplicate", "omitted_resolved_without_ongoing_impact", "omitted_uncertain_peripheral", "omitted_not_summarized"]
            guard let decisions = obj["coverage"] as? [String: String], Set(decisions.keys) == Set(concerns.map(\.id)),
                  decisions.values.allSatisfy({ codes.contains($0) }), (concerns.isEmpty || decisions.values.contains(where: { $0.hasPrefix("included_") })) else { throw fail("coverage") }
            var groundedDecisions=decisions
            for (group, decision) in decisions where decision.hasPrefix("included_") {
                let supported=facts.contains { $0.groups.contains(group) && cited.contains($0.id) }
                if !supported {
                    // Coverage is writer bookkeeping, not clinical evidence. An uncited
                    // secondary topic was not summarized; do not invent supporting refs.
                    guard decision == "included_secondary" else { throw fail("major_coverage") }
                    groundedDecisions[group]="omitted_not_summarized"
                }
            }
            guard concerns.isEmpty || groundedDecisions.values.contains(where:{$0.hasPrefix("included_")}) else {throw fail("coverage")}
            if compact || writerVersion == "b-narrative-balanced-v5" {
                let included = Set(groundedDecisions.filter { $0.value.hasPrefix("included_") }.keys)
                guard sentences.count <= (compact ? 5 : 6), sentences.allSatisfy({ (($0["text"] as? String)?.count ?? 321) <= (compact ? 260 : 320) }) else { throw fail("sentence_length") }
                for id in cited {
                    guard let fact = byID[id], fact.groups.isEmpty || !Set(fact.groups).isDisjoint(with: included) else { throw fail() }
                }
            }
            coverage = groundedDecisions
        }
        let joined = texts.joined(separator: " ")
        guard WholeHistoryOverviewDisplay.withinCharacterLimit(joined, compact: compact, balanced: balanced) else { throw fail("character_limit") }
        guard WholeHistoryOverviewDisplay.withinWordLimit(joined, compact: compact, balanced: balanced) else { throw fail("word_limit") }
        return Result(text:joined,coverage:coverage)
    }
}
