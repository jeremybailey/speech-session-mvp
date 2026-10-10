import XCTest
@testable import SpeechSessionPersistence

final class HealthAreaTests: XCTestCase {
    private func condition(_ name: String, _ system: String, id: String? = nil) -> ConditionSummary {
        var entry = SummaryEntry(category: .symptoms, title: name)
        entry.sourceSessionID = UUID()
        let fact = HealthFact(id: entry.id.uuidString, occurrences: [entry],
                              preference: .init(id: entry.id.uuidString), topicIDs: [])
        return ConditionSummary(id: id ?? name, name: name, bodySystem: system, facts: [fact])
    }

    func testLargeHistoryPreservesConditionsSourcesAndPriorityOrder() {
        let input = [condition("Pregnancy", "reproductive"),
                     condition("Low mood stress and overwhelm", "mental"),
                     condition("Reported migraine", "neurological"),
                     condition("Left shoulder discomfort", "musculoskeletal"),
                     condition("Elevated urinary estrogens", "endocrine"),
                     condition("Estradiol above report range", "endocrine"),
                     condition("Reported fatigue", "unknown"),
                     condition("Reported symptoms attributed to androgen deficiency", "endocrine"),
                     condition("Ankle and foot stiffness", "musculoskeletal"),
                     condition("Hip pain, side unspecified", "musculoskeletal"),
                     condition("Left hip pain", "musculoskeletal"),
                     condition("Right hip pain with running", "musculoskeletal"),
                     condition("Right Achilles tendinosis", "musculoskeletal"),
                     condition("Frequent morning bowel movements", "digestive"),
                     condition("Lateral knee pain", "musculoskeletal"),
                     condition("Nighttime cough", "respiratory"),
                     condition("Pelvic pain during pregnancy", "musculoskeletal"),
                     condition("Reported reflux during pregnancy", "digestive")]
        let areas = HealthAreaProjection.groups(input)
        XCTAssertEqual(areas.map(\.id), [.pregnancy, .mental, .neurological, .movement,
                                         .endocrine, .other, .digestive, .respiratory])
        XCTAssertEqual(areas.flatMap(\.conditions).count, input.count)
        XCTAssertEqual(Set(areas.flatMap(\.conditions).map(\.id)), Set(input.map(\.id)))
        for area in areas {
            XCTAssertEqual(area.conditions.map(\.id), input.filter { HealthAreaKind.classify($0) == area.id }.map(\.id))
            for result in area.conditions {
                let original = input.first { $0.id == result.id }!
                XCTAssertEqual(result.name, original.name)
                XCTAssertEqual(result.facts.map(\.id), original.facts.map(\.id))
                XCTAssertEqual(result.facts.flatMap(\.occurrences).map(\.sourceSessionID),
                               original.facts.flatMap(\.occurrences).map(\.sourceSessionID))
            }
        }
        XCTAssertEqual(areas.first { $0.id == .movement }?.conditions.filter { $0.name.contains("hip") || $0.name.contains("Hip") }.count, 3)
        XCTAssertEqual(HealthAreaProjection.groups(input).map(\.preview), areas.map(\.preview))
    }

    func testPregnancyContextDoesNotOverrideSpecificBodySystem() {
        XCTAssertEqual(HealthAreaKind.classify(condition("Reflux during pregnancy", "digestive")), .digestive)
        XCTAssertEqual(HealthAreaKind.classify(condition("Stress and overwhelm during pregnancy", "mental")), .mental)
        XCTAssertEqual(HealthAreaKind.classify(condition("Pelvic pain during pregnancy", "musculoskeletal")), .movement)
        XCTAssertEqual(HealthAreaKind.classify(condition("Pregnancy-related care", "reproductive")), .pregnancy)
        XCTAssertEqual(HealthAreaKind.classify(condition("Currently pregnant", "unknown")), .pregnancy)
        XCTAssertEqual(HealthAreaKind.classify(condition("Reflux", "digestive")), .digestive)
        XCTAssertEqual(HealthAreaKind.classify(condition("Fatigue", "unknown")), .other)
        XCTAssertEqual(HealthAreaKind.classify(condition("Pregnancytest marker", "endocrine")), .endocrine)
    }

    func testSystemMappingAndUnknownFallback() {
        let systems = ["musculoskeletal", "eye", "neurological", "cardiovascular", "respiratory",
                       "digestive", "endocrine", "reproductive", "urinary", "mental", "skin", "immune", "ear", "unknown", "", "unrecognized"]
        let expected: [HealthAreaKind] = [.movement, .eye, .neurological, .cardiovascular, .respiratory,
                                        .digestive, .endocrine, .reproductive, .urinary, .mental, .skin, .immune, .ear, .other, .other, .other]
        XCTAssertEqual(systems.map { HealthAreaKind.classify(condition("Concern", $0)) }, expected)
        XCTAssertEqual(HealthAreaKind.classify(condition("Concern", " EYE ")), .eye)
    }

    func testUnassignedAndEmptyAreOmittedAndSingleConditionRetainsCategories() {
        let eye = condition("Corneal injury", "eye")
        let empty = ConditionSummary(id: "empty", name: "Empty", bodySystem: "eye", facts: [])
        let areas = HealthAreaProjection.groups([condition("Unassigned", "unknown", id: "uncategorized"), eye, empty])
        XCTAssertEqual(areas.count, 1)
        XCTAssertEqual(areas[0].conditions.count, 1)
        XCTAssertEqual(areas[0].conditions[0].facts.map(\.category), eye.facts.map(\.category))
        XCTAssertEqual(areas[0].preview, eye.name)
        XCTAssertTrue(HealthAreaProjection.groups([]).isEmpty)
    }

    func testReprojectionReflectsReassignmentAndRemoval() {
        let original = condition("Eye concern", "unknown", id: "stable")
        let updated = ConditionSummary(id: original.id, name: original.name, bodySystem: "eye", facts: original.facts)
        XCTAssertEqual(HealthAreaProjection.groups([original]).map(\.id), [.other])
        XCTAssertEqual(HealthAreaProjection.groups([updated]).map(\.id), [.eye])
        XCTAssertTrue(HealthAreaProjection.groups([]).isEmpty)
    }
}
