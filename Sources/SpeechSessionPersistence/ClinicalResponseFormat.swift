import Foundation

/// Strict transport contracts; checker identities are bounded to the submitted batch.
public enum ClinicalResponseFormat {
    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties,
         "required": properties.keys.sorted(), "additionalProperties": false]
    }
    private static func strict(_ name: String, _ schema: [String: Any]) -> [String: Any] {
        ["type": "json_schema", "json_schema": ["name": name, "strict": true, "schema": schema]]
    }
    public static func forStage(_ stage: String, expectedCheckIDs: [UUID] = []) -> [String: Any] {
        switch stage {
        case "classification":
            let category: [String: Any] = ["anyOf": [
                ["type": "string", "enum": SummaryEntryCategory.allCases.map(\.rawValue)],
                ["type": "null"]
            ]]
            return strict("health_category_classification", object(["decisions": ["type": "array", "items": object([
                "id": ["type": "integer"], "category": category
            ])]]))
        case "duplicates":
            return strict("health_duplicate_decision", object(["equivalent": ["type": "boolean"]]))
        case "condition-synthesis":
            let group = object(["name": ["type": "string"], "bodySystem": ["type": "string"],
                                "isPrimary": ["type": "boolean"], "reason": ["type": "string"],
                                "entryIDs": ["type": "array", "items": ["type": "string"]]])
            return strict("health_condition_organization", object([
                "groups": ["type": "array", "items": group],
                "unassigned": ["type": "array", "items": ["type": "string"]]
            ]))
        case "condition-verification":
            let decision = object(["name": ["type": "string"], "bodySystem": ["type": "string"],
                                   "nameSupported": ["type": "boolean"],
                                   "supportedEntryIDs": ["type": "array", "items": ["type": "string"]],
                                   "reason": ["type": "string"]])
            return strict("health_condition_verification", object(["decisions": ["type": "array", "items": decision]]))
        case "checking":
            let citation = object(["field": ["type": "string"], "excerpt": ["type": "string"]])
            let exclusion: [String: Any] = ["anyOf": [
                ["type": "string", "enum": ["wrong_patient", "contradicted", "not_patient_information", "unreadable"]],
                ["type": "null"]
            ]]
            var identifier: [String: Any] = ["type": "string"]
            if !expectedCheckIDs.isEmpty { identifier["enum"] = expectedCheckIDs.map(\.uuidString) }
            let decision = object(["id": identifier, "supported": ["type": "boolean"],
                                   "coreSupported": ["type": "boolean"], "reason": ["type": "string"],
                                   "citations": ["type": "array", "items": citation], "exclusion": exclusion,
                                   "uncertainFields": ["type": "array", "items": ["type": "string"]]])
            if !expectedCheckIDs.isEmpty {
                var keyed: [String: Any] = [:]
                for id in expectedCheckIDs {
                    var properties = decision["properties"] as! [String: Any]
                    properties["id"] = ["type": "string", "enum": [id.uuidString]]
                    keyed[id.uuidString] = object(properties)
                }
                return strict("health_source_verification", object(["decisions": object(keyed)]))
            }
            return strict("health_source_verification", object(["decisions": ["type": "array", "items": decision]]))
        default:
            return ["type": "json_object"]
        }
    }
}
