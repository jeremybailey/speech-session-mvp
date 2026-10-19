import Foundation
import CryptoKit

/// Only server-confirmed, account-specific acceptance can unlock the agreement gate.
public struct PilotAgreementDocument: Codable {
    public static let supportedVersion = "2026-10-19.1"
    public let version: String
    public let introduction: String
    public let paragraphs: [String]
    public let action: String
    public let sha256: String
    public var valid: Bool {
        let text = ([introduction] + paragraphs + [action]).joined(separator: "\n\n")
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return version == Self.supportedVersion && sha256 == hash && !paragraphs.isEmpty && action == "I agree and continue"
    }
}
public struct PilotAgreementReceipt: Codable {
    public let id: String
    public let owner: String
    public let version: String
    public let sha256: String
    public let accepted_at: String
}
public struct PilotAgreementEnvelope: Codable {
    public let agreement: PilotAgreementDocument
    public let receipt: PilotAgreementReceipt?
    public func accepted(by owner: String) -> Bool {
        guard !owner.isEmpty, agreement.valid, let receipt else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalDate = formatter.date(from: receipt.accepted_at)
        formatter.formatOptions = [.withInternetDateTime]
        let validDate = fractionalDate ?? formatter.date(from: receipt.accepted_at)
        return receipt.owner == owner && receipt.version == agreement.version &&
            receipt.sha256 == agreement.sha256 && UUID(uuidString: receipt.id) != nil && validDate != nil
    }
}
