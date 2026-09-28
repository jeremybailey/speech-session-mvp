import Foundation

/// The writer and checker use separate, enforced wire contracts.
public enum OverviewResponseContract: Sendable {
    case narrative, support, prose

    public var responseFormat: [String: Any] {
        let schema: [String: Any]
        switch self {
        case .prose:
            schema = Self.object(["text": ["type": "string"]])
        case .narrative:
            schema = Self.object(["sentences": [
                "type": "array",
                "items": Self.object([
                    "text": ["type": "string"],
                    "factIDs": ["type": "array", "items": ["type": "string"]]
                ])
            ]])
        case .support:
            schema = Self.object(["supported": ["type": "boolean"], "reason": ["type": "string"]])
        }
        return ["type": "json_schema", "json_schema": [
            "name": self == .narrative ? "health_story_overview" : self == .prose ? "health_story_prose" : "health_story_support",
            "strict": true, "schema": schema
        ]]
    }

    /// Bound references to the current request, including each condensation batch.
    public func responseFormat(allowedFactIDs: [String]) -> [String: Any] {
        guard self == .narrative, !allowedFactIDs.isEmpty else { return responseFormat }
        let schema = Self.object(["sentences": ["type": "array", "minItems": 1, "maxItems": 10,
            "items": Self.object(["text": ["type": "string"],
                "factIDs": ["type": "array", "minItems": 1,
                    "items": ["type": "string", "enum": Array(Set(allowedFactIDs)).sorted()]]])]])
        return ["type": "json_schema", "json_schema": ["name": "health_story_overview", "strict": true, "schema": schema]]
    }

    public static func decodeProse(_ raw: String) throws -> String {
        struct Prose: Decodable { let text: String }
        guard let result = try? JSONDecoder().decode(Prose.self, from: jsonData(raw)),
              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OverviewFailure.invalidFormat }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties,
         "required": properties.keys.sorted(), "additionalProperties": false]
    }

    public static func decodeNarrative(_ raw: String) throws -> StoryOverview {
        do { return try JSONDecoder().decode(StoryOverview.self, from: jsonData(raw)) }
        catch { throw OverviewFailure.invalidFormat }
    }

    public static func decodeSupport(_ raw: String) throws -> Bool {
        struct Decision: Decodable { let supported: Bool }
        do { return try JSONDecoder().decode(Decision.self, from: jsonData(raw)).supported }
        catch { throw OverviewFailure.invalidCheckFormat }
    }

    public struct SupportDecision: Decodable, Sendable {
        public let supported: Bool
        public let reason: String
    }

    public static func decodeSupportDecision(_ raw: String) throws -> SupportDecision {
        do { return try JSONDecoder().decode(SupportDecision.self, from: jsonData(raw)) }
        catch { throw OverviewFailure.invalidCheckFormat }
    }

    // Accept a complete fenced JSON document, never extract arbitrary prose or repair truncation.
    private static func jsonData(_ raw: String) -> Data {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```json\n") && value.hasSuffix("```") {
            value = String(value.dropFirst(8).dropLast(3))
        } else if value.hasPrefix("```\n") && value.hasSuffix("```") {
            value = String(value.dropFirst(4).dropLast(3))
        }
        return Data(value.utf8)
    }
}
