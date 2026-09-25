import Foundation

public enum HealthCombinationUndo: Sendable {
    case care(CareCombinationUndo)
    case facts(FactCombinationUndo)
    case contacts(ContactCombinationUndo)
}

public struct FactCombinationUndo: Sendable {
    struct Identity: Sendable {
        let key: String
        let factIdentity: String?
        let primary: Bool?
    }
    let identities: [UUID: Identity]
    let combinedID: String
}

public struct ContactCombinationUndo: Sendable {
    let members: [CareTeamMember]
    let combinedID: UUID
}

public enum HealthFactConsolidation {
    public static func preferencesAgree(_ a: HealthFact, _ b: HealthFact, savedIDs: Set<String>) -> Bool {
        // An untouched occurrence can adopt the patient's existing choice, including a removal.
        guard savedIDs.contains(a.id), savedIDs.contains(b.id) else { return true }
        return a.clinicalStatus == b.clinicalStatus && a.actionStatus == b.actionStatus
            && a.preference.hidden == b.preference.hidden
            && a.preference.dueDate == b.preference.dueDate
            && !b.preference.reminderEnabled
            && Set(a.topicIDs) == Set(b.topicIDs)
    }
}
