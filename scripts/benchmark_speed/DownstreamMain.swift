import Foundation
import SpeechSessionPersistence

/// Replays the current app's finalization and condition pipeline from saved details.
/// It never runs extraction and is reported separately from cold details processing.
@main struct DownstreamRun {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("Usage: downstream-replay root run saved-store") }
        let root = URL(fileURLWithPath: args[1]), run = args[2], out = root.appendingPathComponent(run)
        guard !FileManager.default.fileExists(atPath: out.path) else { fatalError("Fresh downstream run required") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: args[3]), to: out.appendingPathComponent("store"))
        let store = try SessionStore(storageDirectory: out.appendingPathComponent("store"))
        let initial = try await store.healthSnapshot()
        let bridge = try BenchmarkBridge(root: root, run: run, trace: out.appendingPathComponent("trace"))
        let transport = OpenAIChatTransport(bridge: bridge), processor = RecordSummaryProcessor()
        let started = ProcessInfo.processInfo.systemUptime
        var phases: [[String: Any]] = [], failure: String?
        func phase(_ name: String, _ work: () async throws -> Void) async throws {
            let begin = ProcessInfo.processInfo.systemUptime
            do {
                try await work()
                phases.append(["phase": name, "seconds": ProcessInfo.processInfo.systemUptime - begin, "completed": true])
            } catch {
                phases.append(["phase": name, "seconds": ProcessInfo.processInfo.systemUptime - begin, "completed": false])
                throw error
            }
        }
        do {
            try await phase("contact-reconciliation") {
                try await processor.reconcileContacts(store: store, transport: transport, onDevice: false) { _ in }
            }
            try await phase("symptom-reconciliation") {
                try await processor.reconcileSymptoms(store: store, transport: transport, onDevice: false, force: true)
            }
            try await phase("conditions") {
                let snapshot = try await store.healthSnapshot()
                let facts = HealthMemoryProjection.facts(in: snapshot, verifiedOnly: true)
                let synthesis = try await processor.synthesizeConditions(facts: facts, transport: transport, store: store) { _ in }
                try await store.saveConditionSynthesis(synthesis, expected: facts)
                guard await store.conditionSynthesis(for: facts) != nil else { throw SummaryResponseError.invalidFormat }
            }
        } catch { failure = String(describing: error) }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let snapshot = try await store.healthSnapshot()
        let originalIDs = Set(initial.sessions.flatMap { $0.summaryEntries ?? [] }.map(\.id))
        let finalIDs = Set(snapshot.sessions.flatMap { $0.summaryEntries ?? [] }.map(\.id))
        let preserved = originalIDs == finalIDs && initial.sessions.allSatisfy { old in
            snapshot.sessions.contains { $0.id == old.id && $0.transcript == old.transcript }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot.sessions).write(to: out.appendingPathComponent("sessions.json"))
        let report: [String: Any] = ["run": run, "completed": failure == nil && preserved,
            "failure": failure as Any? ?? NSNull(), "elapsedSeconds": elapsed, "phases": phases,
            "sourceOccurrencesPreserved": preserved, "cold": false,
            "scope": "Current contact/symptom reconciliation and conditions from saved details; no extraction or overview. Includes diagnostic transport overhead."]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: out.appendingPathComponent("run.json"))
        if let ledger = try? await bridge.send(["action": "status"]) {
            try JSONSerialization.data(withJSONObject: ledger).write(to: out.appendingPathComponent("ledger.json"))
        }
        print("Downstream replay completed=\(failure == nil && preserved), seconds=\(Int(elapsed)). See private report.")
    }
}
