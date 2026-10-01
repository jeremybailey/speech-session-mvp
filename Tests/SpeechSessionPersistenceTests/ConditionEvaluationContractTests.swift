import XCTest
@testable import SpeechSessionPersistence

final class ConditionEvaluationContractTests: XCTestCase {
    /// Opt-in artifact export uses the compiled app constants, never retyped prompts.
    func testExportProductionContractsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["CONDITION_EVALUATION_CONTRACT_OUTPUT"] else { return }
        let payload: [String: Any] = [
            "mapping": ["instructions": ConditionSynthesis.incrementalInstruction,
                        "response_format": ClinicalResponseFormat.forStage("condition-synthesis")],
            "verification": ["instructions": ConditionSynthesis.incrementalVerificationInstruction,
                             "response_format": ClinicalResponseFormat.forStage("condition-verification")]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        XCTAssertFalse(data.isEmpty)
    }
}
