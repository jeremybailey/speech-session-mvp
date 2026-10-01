import Foundation

/// Navigation only: sharing an area never establishes a clinical relationship.
public enum HealthAreaKind: String, CaseIterable, Sendable {
    case movement, eye, neurological, cardiovascular, respiratory, digestive, endocrine
    case reproductive, pregnancy, urinary, mental, skin, immune, ear, other

    public var title: String {
        switch self {
        case .movement: return "Pain & movement"
        case .eye: return "Eyes & vision"
        case .neurological: return "Brain & nerves"
        case .cardiovascular: return "Heart & circulation"
        case .respiratory: return "Breathing"
        case .digestive: return "Digestion"
        case .endocrine: return "Hormones & metabolism"
        case .reproductive: return "Reproductive health"
        case .pregnancy: return "Pregnancy & related care"
        case .urinary: return "Bladder & urinary health"
        case .mental: return "Emotional wellbeing"
        case .skin: return "Skin"
        case .immune: return "Immune health"
        case .ear: return "Ears & hearing"
        case .other: return "Other health concerns"
        }
    }

    public var symbol: String {
        switch self {
        case .movement: return "figure.walk"
        case .eye: return "eye"
        case .neurological, .mental: return "brain.head.profile"
        case .cardiovascular: return "heart.fill"
        case .respiratory: return "lungs.fill"
        case .digestive: return "stomach"
        case .endocrine: return "waveform.path.ecg"
        case .reproductive, .pregnancy: return "figure.and.child.holdinghands"
        case .urinary: return "drop"
        case .skin: return "hand.raised"
        case .immune: return "shield"
        case .ear: return "ear"
        case .other: return "figure.stand"
        }
    }

    public static func classify(_ condition: ConditionSummary) -> Self {
        let words = Set(ConditionSummaryProjection.normalized(condition.name).split(separator: " "))
        if words.contains("pregnancy") || words.contains("pregnant") { return .pregnancy }
        switch ConditionSummaryProjection.normalized(condition.bodySystem) {
        case "musculoskeletal": return .movement
        case "eye": return .eye
        case "neurological": return .neurological
        case "cardiovascular": return .cardiovascular
        case "respiratory": return .respiratory
        case "digestive": return .digestive
        case "endocrine": return .endocrine
        case "reproductive": return .reproductive
        case "urinary": return .urinary
        case "mental": return .mental
        case "skin": return .skin
        case "immune": return .immune
        case "ear": return .ear
        default: return .other
        }
    }
}

public struct HealthArea: Identifiable, Sendable {
    public let id: HealthAreaKind
    public var conditions: [ConditionSummary]
    public var preview: String { conditions.map(\.name).joined(separator: " · ") }
}

public enum HealthAreaProjection {
    /// Retain the input's priority order, identities and facts; never sort by volume or merge concerns.
    public static func groups(_ conditions: [ConditionSummary]) -> [HealthArea] {
        var areas: [HealthArea] = []
        for condition in conditions where !condition.isUncategorized && !condition.facts.isEmpty {
            let kind = HealthAreaKind.classify(condition)
            if let index = areas.firstIndex(where: { $0.id == kind }) {
                areas[index].conditions.append(condition)
            } else {
                areas.append(HealthArea(id: kind, conditions: [condition]))
            }
        }
        return areas
    }
}
