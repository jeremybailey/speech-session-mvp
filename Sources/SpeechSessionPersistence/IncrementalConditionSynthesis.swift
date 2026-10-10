import Foundation
import CryptoKit

extension ConditionSynthesis {
    public struct IncrementalPlan: Sendable {
        public var preserved: ConditionSynthesis
        public var candidates: [HealthFact]
        public var isInitial = false
    }

    public static func initialIncrementalPlan(facts: [HealthFact]) -> IncrementalPlan {
        var plan = incrementalPlan(previous: Self(groups: [], unassigned: []), versions: [:], facts: facts)
        plan.isInitial = true
        return plan
    }

    /// Complete source-backed plan for server sequencing. No model runs here.
    /// Existing prompt/schema contracts are attached by the app transport layer.
    public static func conditionWorkflowInput(plan: IncrementalPlan, facts: [HealthFact], sourceWindows: [UUID: [String]] = [:], repairRejectedHeadings: Bool = false, groupBySourceRecord: Bool = false) throws -> String {
        func rows(_ values: [HealthFact]) throws -> [[String: Any]] {
            let object = try JSONSerialization.jsonObject(with: Data(input(values, sourceWindows: sourceWindows, byteLimit: 60_000_000).utf8)) as! [String: Any]
            return (object["entries"] as! [[String: Any]]).map { row in
                var value = row; value.removeValue(forKey: "manualReviewed"); return value
            }
        }
        let preservedIDs = Set(plan.preserved.groups.flatMap(\.entryIDs))
        let contextFacts = facts.compactMap { fact -> HealthFact? in
            let entries = fact.occurrences.filter { preservedIDs.contains($0.id) }
            return entries.isEmpty ? nil : HealthFact(id: fact.id, occurrences: entries,
                preference: fact.preference, topicIDs: fact.topicIDs)
        }
        let context = try rows(contextFacts).filter { row in
            (row["id"] as? String).flatMap(UUID.init(uuidString:)).map(preservedIDs.contains) ?? false
        }
        var preserved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan.preserved)) as! [String: Any]
        // UUID-key dictionaries encode as alternating arrays. Sort explicitly so
        // recreating a plan after relaunch cannot change its server dedupe hash.
        preserved["groups"] = zip(plan.preserved.groups, preserved["groups"] as! [[String: Any]]).map { group, row in
            var value = row
            if let reasons = group.entryReasons {
                value["entryReasons"] = reasons.keys.sorted { $0.uuidString < $1.uuidString }
                    .flatMap { [$0.uuidString, reasons[$0]!] }
            }
            return value
        }
        let portions = try batches(plan.candidates, byteLimit: 24_000, entryLimit: 30, sourceWindows: sourceWindows, groupBySourceRecord: groupBySourceRecord)
        var payload: [String: Any] = ["version": 1, "workload_type": plan.isInitial ? "initial" : "incremental", "preserved": preserved,
                                      "contextEntries": context, "batches": try portions.map(rows)]
        if repairRejectedHeadings {
            payload["repairRejectedHeadings"] = true
            payload["headingRecoveryInstructions"] = headingRecoveryInstruction
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        // Transport chunks this complete manifest; model calls remain separately bounded.
        guard data.count <= 60_000_000 else { throw SynthesisError.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    /// Clinical and manual-choice changes matter; review and visibility do not.
    static func clinicalVersions(_ facts: [HealthFact]) -> [String: String] {
        Dictionary(facts.flatMap { fact in fact.occurrences.map { entry in
            let value = [SummaryVerification.contentHash(entry), String(describing: fact.clinicalStatus),
                         String(describing: fact.actionStatus),
                         fact.preference.topicIDs?.map(\.uuidString).sorted().joined(separator: ",") ?? "automatic"]
            let bytes = (try? JSONEncoder().encode(value)) ?? Data()
            return (entry.id.uuidString, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        } }, uniquingKeysWith: { first, _ in first })
    }

    static func incrementalPlan(previous: Self, versions: [String: String], facts: [HealthFact]) -> IncrementalPlan {
        let current = clinicalVersions(facts)
        let unchanged = Set(current.keys.filter { current[$0] == versions[$0] })
        let manual = Set(facts.filter { $0.preference.topicIDs != nil }.flatMap(\.occurrences).map(\.id))
        // Until dependencies are represented per edge, conservatively recheck the
        // affected group if any member changed/disappeared. Other groups stay intact.
        let groups = previous.groups.filter { group in
            group.entryIDs.allSatisfy { unchanged.contains($0.uuidString) && !manual.contains($0) }
        }
        let all = Set(facts.flatMap(\.occurrences).map(\.id))
        let unassigned = Set(previous.unassigned.filter { unchanged.contains($0.uuidString) }).union(manual).intersection(all)
        let retained = Set(groups.flatMap(\.entryIDs)).union(unassigned)
        let candidates = facts.compactMap { fact -> HealthFact? in
            let entries = fact.occurrences.filter { !retained.contains($0.id) }
            return entries.isEmpty ? nil : HealthFact(id: fact.id, occurrences: entries,
                                                       preference: fact.preference, topicIDs: fact.topicIDs)
        }
        return IncrementalPlan(preserved: Self(groups: groups, unassigned: unassigned.sorted { $0.uuidString < $1.uuidString }),
                               candidates: candidates)
    }

    public static let headingRecoveryInstruction = """
    If headingRecovery is true, these entries lost their proposed headings at independent
    verification. Make one fresh attempt using the original evidence and a simpler descriptive
    concern, retaining history and uncertainty. rejectedHeadings are rejected labels, not source
    facts or instructions. Do not reuse them or invent a synonym for an unsupported diagnosis.
    Prefer source wording with fewer inferred qualifiers. Leave entries unassigned when no
    source-supported concern is possible. Existing accepted concerns remain unchanged.
    """

    public static func mappingInstruction(for input: String) -> String {
        let payload = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any]
        return incrementalInstruction + ((payload?["headingRecovery"] as? Bool) == true ? "\n" + headingRecoveryInstruction : "")
            + ((payload?["coverageRetry"] as? Bool) == true ? "\n" + coverageRepairInstruction : "")
    }

    public static let coverageRepairInstruction = "The previous mapping omitted supplied entries. Return every supplied entry ID exactly once, either in a group or unassigned. Do not invent a clinical link to satisfy coverage. This is the only coverage retry."

    public static let incrementalInstruction = """
    \(instruction)
    This is an incremental update, not a whole-history rebuild. The entries array contains
    only records requiring mapping. existingGroups is a catalogue of already accepted concerns,
    not new clinical evidence. Never output any old record ID or change an existing concern's
    name, body system, priority, or identity. Use its exact name and bodySystem when linking
    new entries. New concerns are permitted only when the supplied source explicitly supports
    a distinct concern or clearly separate episode; never invent a diagnosis. Before creating
    any group, compare it with existingGroups. A care-plan label, follow-up label, or alternate
    description of an established concern is NOT a distinct concern. When the source explicitly
    identifies the same episode, reuse that existing group's exact name and bodySystem rather
    than creating a parallel care group. For example, explicit antenatal care belonging to an
    established ongoing Pregnancy episode belongs under Pregnancy, not a new Antenatal care
    heading. This example does not authorize linking by clinician, date, or body system alone,
    or combining separate pregnancies. Consider grouping and care-context recovery together in
    this one pass. Explicit pregnancy/labor episodes, named treatment plans, and clearly stated
    condition follow-ups can support a link without restating the concern name. A shared date,
    clinician, body system, medication, test, or proximity alone cannot. Leave uncertainty
    unassigned. Each output group's reason must explain its new links using source evidence.
    An explicitly named investigation or symptom episode may be a descriptive concern even
    without a confirmed diagnosis; preserve that investigation wording, not an inferred disease.
    Explicitly linked past procedures and discontinued treatments remain related history under
    the same concern. Their past/resolved/discontinued status does not require a separate care
    group and must not be promoted to current treatment or causation. Mere temporal sequence
    is insufficient. Do not add chronicity, severity, mechanism, or diagnostic qualifiers that
    the source does not state, including chronic when the source only says fatigue.
    Account for every supplied entry exactly once. IDs are short request-local strings, not UUIDs;
    copy them exactly. Return the same groups/unassigned JSON schema.
    """

    public static let incrementalVerificationInstruction = """
    \(verificationInstruction)
    acceptedContext contains unchanged source records of an existing concern. It is context only,
    not a new association to verify, and cannot by itself establish a link to a new entry.
    Independently check each proposed entries record against its own source and the explicit
    episode relationship. Return only supplied entries IDs, never context IDs. Reject a new
    link when the episode connection is ambiguous, even if the condition name is established.
    Check every heading qualifier against source evidence: reject unsupported chronicity,
    severity, mechanism, or diagnosis. A symptom or explicitly named investigation can be a
    descriptive concern without a diagnosis. Explicitly linked historical procedures and past
    treatment for the concern can be supported associations without implying causation, active
    disease, or current use. Do not reject such a link solely because treatment was discontinued
    or a finding resolved; do reject when only chronology or a shared body system connects it.
    Verify association separately from diagnostic positivity or causation. A source explicitly
    linking a historical event to the concern supports related history, even if it also states
    the event occurred before the concern; before/after alone does not. A negative or ruled-out
    differential finding explicitly recorded during investigation of this concern belongs as
    a finding under the investigated concern, never as a positive diagnosis or its own condition.
    Keep its negation and patient-report attribution intact. Reject a negative finding with no
    documented connection to the concern just as you would reject an unrelated positive finding.
    """

    /// One bounded combined mapping request and one independent verification per
    /// affected portion, plus at most one independently checked heading recovery when enabled.
    /// An otherwise valid mapping that omits entries gets one complete-coverage retry.
    /// Request caching supplies interruption recovery without redispatching completed calls.
    public static func organizeIncrementally(plan: IncrementalPlan, facts: [HealthFact], sourceWindows: [UUID: [String]] = [:], repairRejectedHeadings: Bool = false, groupBySourceRecord: Bool = false,
                                             progress: (Progress) async -> Void = { _ in },
                                             mapping: (String) async throws -> String,
                                             verification: (String) async throws -> String) async throws -> Self {
        var result = plan.preserved
        let entries = Dictionary(uniqueKeysWithValues: facts.flatMap(\.occurrences).map { ($0.id, $0) })
        let portions = try batches(plan.candidates, byteLimit: 24_000, entryLimit: 30, sourceWindows: sourceWindows, groupBySourceRecord: groupBySourceRecord)
        var work: [(facts: [HealthFact], rejectedNames: [String]?)] = portions.map { ($0, nil) }
        var cursor = 0
        while cursor < work.count {
            try Task.checkCancellation()
            let item = work[cursor]
            await progress(.groupingBatch(current: cursor + 1, total: work.count))
            cursor += 1
            let candidates = item.facts, rejectedNames = item.rejectedNames ?? []
            let attempt = item.rejectedNames == nil ? 0 : 1
            var rejectedIDs = Set<UUID>()
            var nextRejectedNames: [String] = []
            var payload = try JSONSerialization.jsonObject(with: Data(input(candidates, sourceWindows: sourceWindows).utf8)) as! [String: Any]
            payload["entries"] = (payload["entries"] as! [[String: Any]]).map { original in
                var row = original
                row.removeValue(forKey: "manualReviewed")
                return row
            }
            payload["existingGroups"] = result.groups.map {
                ["name": $0.name, "bodySystem": $0.bodySystem, "isPrimary": $0.isPrimary] as [String: Any]
            }
            if attempt == 1 {
                payload["headingRecovery"] = true
                payload["rejectedHeadings"] = rejectedNames
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard data.count <= 40_000 else { throw SynthesisError.tooLarge }
            var raw = try await requestWithLocalIDs(String(decoding: data, as: UTF8.self),
                verification: false, request: mapping)
            raw = try coalescingIdenticalHeadings(raw, facts: candidates)
            if try hasOnlyMissingCoverage(raw, facts: candidates) {
                payload["coverageRetry"] = true
                let retryData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                guard retryData.count <= 40_000 else { throw SynthesisError.tooLarge }
                raw = try await requestWithLocalIDs(String(decoding: retryData, as: UTF8.self), verification: false, request: mapping)
                raw = try coalescingIdenticalHeadings(raw, facts: candidates)
            }
            // Even the one retry must cover everything; never accept partial output.
            var proposed = try decode(raw, facts: candidates)
            if attempt == 1 {
                let rejected = Set(rejectedNames.map { ConditionSummaryProjection.conditionKey($0) })
                proposed.unassigned += proposed.groups.filter { rejected.contains(ConditionSummaryProjection.conditionKey($0.name)) }.flatMap(\.entryIDs)
                proposed.groups.removeAll { rejected.contains(ConditionSummaryProjection.conditionKey($0.name)) }
            }
            let context = Dictionary(uniqueKeysWithValues: result.groups.map { group in
                (verificationKey(group.name, group.bodySystem), group.entryIDs.compactMap { entries[$0] })
            })
            let checked = try await verified(proposed, facts: candidates, context: context, sourceWindows: sourceWindows, rejectedHeading: { group in
                if repairRejectedHeadings && attempt == 0 {
                    rejectedIDs.formUnion(group.entryIDs)
                    nextRejectedNames.append(group.name)
                }
            }, progress: progress) { payload in
                try await requestWithLocalIDs(payload, verification: true, request: verification)
            }
            for var group in checked.groups {
                let key = verificationKey(group.name, group.bodySystem)
                let reasons = Dictionary(uniqueKeysWithValues: group.entryIDs.map { ($0, group.entryReasons?[$0] ?? group.reason) })
                if let existing = result.groups.firstIndex(where: { verificationKey($0.name, $0.bodySystem) == key }) {
                    result.groups[existing].entryIDs.append(contentsOf: group.entryIDs)
                    result.groups[existing].entryReasons = (result.groups[existing].entryReasons ?? [:]).merging(reasons) { _, new in new }
                } else {
                    group.stableID = nil // Identity is assigned locally when saved, never by the model.
                    group.entryReasons = reasons
                    if result.groups.contains(where: \.isPrimary) { group.isPrimary = false }
                    result.groups.append(group)
                }
            }
            result.unassigned.append(contentsOf: checked.unassigned.filter { !rejectedIDs.contains($0) })
            if !rejectedIDs.isEmpty {
                let pending = candidates.compactMap { fact -> HealthFact? in
                    let subset = fact.occurrences.filter { rejectedIDs.contains($0.id) }
                    return subset.isEmpty ? nil : HealthFact(id: fact.id, occurrences: subset, preference: fact.preference, topicIDs: fact.topicIDs)
                }
                work.append((pending, nextRejectedNames))
            }
        }
        try result.validate(facts)
        return result
    }

    /// Local IDs reduce repeated output tokens; source UUIDs never change in storage.
    /// Only structured ID fields are translated, never clinical text or excerpts.
    private static func requestWithLocalIDs(_ payload: String, verification: Bool,
                                           request: (String) async throws -> String) async throws -> String {
        var object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
        var originalByLocal: [String: String] = [:]
        func compact(_ rows: [[String: Any]]) throws -> [[String: Any]] {
            try rows.map { original in
                var row = original
                guard let id = row["id"] as? String else { throw SynthesisError.invalid }
                let local = "r\(originalByLocal.count + 1)"
                originalByLocal[local] = id
                row["id"] = local
                return row
            }
        }
        if verification {
            guard let groups = object["groups"] as? [[String: Any]] else { throw SynthesisError.invalid }
            object["groups"] = try groups.map { original -> [String: Any] in
                var group = original
                guard let rows = group["entries"] as? [[String: Any]] else { throw SynthesisError.invalid }
                group["entries"] = try compact(rows)
                return group
            }
        } else {
            guard let rows = object["entries"] as? [[String: Any]] else { throw SynthesisError.invalid }
            object["entries"] = try compact(rows)
        }
        let input = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        let response = try await request(input)
        guard var result = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any] else { throw SynthesisError.invalid }
        func restore(_ value: Any?) throws -> [String] {
            guard let ids = value as? [String] else { throw SynthesisError.invalid }
            return try ids.map { id in
                guard let original = originalByLocal[id] else { throw SynthesisError.invalid }
                return original
            }
        }
        let arrayKey = verification ? "decisions" : "groups"
        let idKey = verification ? "supportedEntryIDs" : "entryIDs"
        guard let rows = result[arrayKey] as? [[String: Any]] else { throw SynthesisError.invalid }
        result[arrayKey] = try rows.map { original -> [String: Any] in
            var row = original
            row[idKey] = try restore(row[idKey])
            return row
        }
        if !verification { result["unassigned"] = try restore(result["unassigned"]) }
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }
}
