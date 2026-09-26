import XCTest
@testable import SpeechSessionPersistence

/// Exercises the production batching, recovery, reconciliation, and final validation path.
final class ConditionStressTests: XCTestCase {
    private func history(count: Int) -> [HealthFact] {
        (0..<count).map { index in
            let concern = ["Migraine", "Right knee pain", "Left knee injury", "Hormone testing"][index % 4]
            var entry = SummaryEntry(category: index % 4 == 3 ? .testsAndLabs : .symptoms,
                title: concern, details: "Synthetic longitudinal record. \(concern) discussed with Provider \(index % 5). " + String(repeating: "No causal relationship to other concerns is documented. ", count: 35), origin: .userAdded)
            entry.evidence = ClinicalEvidence()
            entry.evidence?.eventDate = "2024-06-15"
            return HealthFact(id: entry.id.uuidString, occurrences: [entry], preference: .init(id: entry.id.uuidString), topicIDs: [])
        }
    }

    private actor Meter {
        var requests = 0
        var bytes = 0
        func record(_ size: Int) -> Int { requests += 1; bytes += size; return requests }
        func totals() -> (Int, Int) { (requests, bytes) }
    }

    func testRepeatedLargeHistoriesWithInjectedResponseDefects() async throws {
        for mode in 0..<4 {
            let facts = history(count: 320)
            XCTAssertThrowsError(try ConditionSynthesis.input(facts))
            let meter = Meter()
            let result = try await ConditionSynthesis.organize(facts: facts) { input in
                let call = await meter.record(input.utf8.count)
                let payload = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
                let entries = payload["entries"] as! [[String: Any]]
                var groups = Dictionary(grouping: entries, by: { $0["title"] as! String }).map { name, rows in
                    ConditionSynthesis.Group(name: name, bodySystem: "unknown", isPrimary: false,
                        reason: "Explicit repeated concern", entryIDs: rows.map { UUID(uuidString: $0["id"] as! String)! })
                }
                if mode == 1 { // Duplicate references and unknown IDs must not sink the run.
                    groups[0].entryIDs += [groups[0].entryIDs[0], UUID()]
                }
                if mode == 2 && call % 2 == 1 && groups[0].entryIDs.count > 1 {
                    groups[0].entryIDs.removeLast() // Targeted retry recovers omissions.
                }
                if mode == 3 && call % 2 == 1 { return "not JSON" } // Whole-batch retry.
                return String(decoding: try JSONEncoder().encode(ConditionSynthesis(groups: groups, unassigned: [])), as: UTF8.self)
            }
            try result.validate(facts)
            XCTAssertEqual(result.groups.count, 4)
            XCTAssertTrue(result.unassigned.isEmpty)
            let totals = await meter.totals()
            XCTAssertLessThan(totals.0, 100, "Retry count must remain bounded")
            print("STRESS offline mode=\(mode) entries=320 requests=\(totals.0) inputBytes=\(totals.1) PASS")
        }
    }

    func testLiveRepeatedLargeHistory() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CONDITION_STRESS_LIVE"] == "1" else {
            throw XCTSkip("Live stress test is opt-in; set CONDITION_STRESS_LIVE=1 and a test credential.")
        }
        guard let token = env["CONDITION_STRESS_TOKEN"] ?? env["OPENAI_API_KEY"], !token.isEmpty else {
            throw XCTSkip("No live credential available; no requests sent.")
        }
        let endpoint = env["CONDITION_STRESS_URL"] ?? "https://api.openai.com/v1/chat/completions"
        let url = try XCTUnwrap(URL(string: endpoint))
        guard url.scheme == "https" else { throw ConditionSynthesis.SynthesisError.invalid }
        var reports: [[String: Any]] = []
        var failed = 0
        for run in 1...3 {
            let facts = history(count: 240)
            let meter = Meter()
            let start = Date()
            do {
                let result = try await ConditionSynthesis.organize(facts: facts) { input in
                    _ = await meter.record(input.utf8.count)
                    let payload: [String: Any] = ["model": ConditionSynthesis.model,
                        "reasoning_effort": "low", "max_completion_tokens": 16000,
                        "response_format": ["type": "json_object"],
                        "messages": [["role": "system", "content": ConditionSynthesis.instruction], ["role": "user", "content": input]]]
                    var request = URLRequest(url: url, timeoutInterval: 120)
                    request.httpMethod = "POST"
                    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw NSError(domain: "StressHTTP", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
                    }
                    let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let choice = (body?["choices"] as? [[String: Any]])?.first
                    guard choice?["finish_reason"] as? String == "stop",
                          let message = choice?["message"] as? [String: Any], let content = message["content"] as? String else {
                        throw ConditionSynthesis.SynthesisError.invalid
                    }
                    return content
                }
                try result.validate(facts)
                let titles = Dictionary(uniqueKeysWithValues: facts.map { ($0.latest.id, $0.title) })
                let mixed = result.groups.contains { Set($0.entryIDs.compactMap { titles[$0] }).count > 1 }
                let pass = !mixed && result.unassigned.isEmpty && result.groups.count == 4
                if !pass { failed += 1 }
                let totals = await meter.totals()
                reports.append(["run": run, "pass": pass, "seconds": Date().timeIntervalSince(start), "requests": totals.0,
                    "inputBytes": totals.1, "groups": result.groups.count, "unassigned": result.unassigned.count, "mixedConcerns": mixed])
            } catch {
                failed += 1
                let totals = await meter.totals()
                reports.append(["run": run, "pass": false, "seconds": Date().timeIntervalSince(start), "requests": totals.0,
                    "errorType": String(describing: type(of: error))])
            }
            // Persist each completed trial; never write credentials or patient data.
            let destination = URL(fileURLWithPath: env["CONDITION_STRESS_REPORT"] ?? "/tmp/condition-stress-live.json")
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
            print("STRESS live completed run \(run)/3")
        }
        XCTAssertEqual(failed, 0, "Inspect /tmp/condition-stress-live.json for results; live semantic checks are intentionally strict.")
    }
}
