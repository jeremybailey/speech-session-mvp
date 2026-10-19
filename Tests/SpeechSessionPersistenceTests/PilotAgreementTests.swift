import XCTest
import CryptoKit
@testable import SpeechSessionPersistence

final class PilotAgreementTests: XCTestCase {
    private func fixture() -> [String: Any] {
        let intro = "Introduction"
        let paragraphs = ["Approved terms"]
        let action = "I agree and continue"
        let hash = SHA256.hash(data: Data(([intro] + paragraphs + [action]).joined(separator: "\n\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return ["agreement": ["version": PilotAgreementDocument.supportedVersion, "introduction": intro,
                               "paragraphs": paragraphs, "action": action, "sha256": hash],
                "receipt": ["id": UUID().uuidString, "owner": "account-a", "version": PilotAgreementDocument.supportedVersion,
                            "sha256": hash, "accepted_at": "2026-10-19T18:10:00.123Z"]]
    }
    private func decode(_ value: [String: Any]) throws -> PilotAgreementEnvelope {
        try JSONDecoder().decode(PilotAgreementEnvelope.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testReceiptSurvivesOfflineRoundTripAndRemainsAccountScoped() throws {
        let envelope = try decode(fixture())
        let restored = try JSONDecoder().decode(PilotAgreementEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertTrue(restored.accepted(by: "account-a"))
        XCTAssertFalse(restored.accepted(by: "account-b"))
        XCTAssertFalse(restored.accepted(by: ""))
    }
    func testMissingReceiptAndLegacyBooleanNeverGrantAcceptance() throws {
        var value = fixture(); value["receipt"] = NSNull()
        XCTAssertFalse(try decode(value).accepted(by: "account-a"))
        XCTAssertThrowsError(try decode(["introAgreementAccepted": true]))
    }
    func testStaleOrMalformedReceiptsFailClosed() throws {
        for (field, bad) in [("id", "invalid"), ("owner", "account-b"), ("version", "old"), ("sha256", "wrong"), ("accepted_at", "yesterday")] {
            var value = fixture(); var receipt = value["receipt"] as! [String: String]
            receipt[field] = bad; value["receipt"] = receipt
            XCTAssertFalse(try decode(value).accepted(by: "account-a"), field)
        }
    }
    func testModifiedTextAndUnsupportedVersionFailClosed() throws {
        for (field, bad) in [("introduction", "Changed"), ("version", "future"), ("action", "Dismiss")] {
            var value = fixture(); var document = value["agreement"] as! [String: Any]
            document[field] = bad; value["agreement"] = document
            XCTAssertFalse(try decode(value).accepted(by: "account-a"), field)
        }
    }
}
