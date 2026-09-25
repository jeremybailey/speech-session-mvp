import Foundation

/// Source-derived presentation. Changing status or hiding a fact updates the overview immediately,
/// without sending health data to a model or displaying a stale generated paragraph.
public enum HealthSummaryPresentation {
    public static func overview(facts: [HealthFact]) -> String? {
        guard !facts.isEmpty else { return nil }
        let recent = facts.sorted {
            let left = $0.latest.relevantDate ?? .distantPast
            let right = $1.latest.relevantDate ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
        let concerns = recent.filter {
            ($0.category == .chiefComplaint || $0.category == .symptoms) &&
                (!$0.hasKnownStatus || $0.clinicalStatus == .current)
        }
        let prioritizedConcerns = concerns.filter { $0.category == .chiefComplaint } + concerns.filter { $0.category == .symptoms }
        var sentences: [String] = []
        if !prioritizedConcerns.isEmpty {
            sentences.append("Concerns include \(titles(prioritizedConcerns)).")
        }
        // Local fallback: clinical dates only, never edit/import timestamps. Prefer a cross-category
        // history over a list dominated by repeated dispensing events or individual lab values.
        let historyCategories: [SummaryEntryCategory] = [.chiefComplaint, .symptoms, .findings, .medications, .testsAndLabs, .biopsychosocialContext]
        var milestones: [(String, String)] = []
        for category in historyCategories {
            var dated: [(String, String)] = []
            for fact in facts where fact.category == category {
                for entry in fact.occurrences {
                    guard let date = entry.evidence?.eventDate,
                          date.range(of: #"^\d{4}(-\d{2})?(-\d{2})?$"#, options: .regularExpression) != nil else { continue }
                    dated.append((date, phrase(HealthStoryText.clean(entry.title), limit: 90)))
                }
            }
            dated.sort { left, right in
                if left.0 != right.0 { return left.0 < right.0 }
                return left.1 < right.1
            }
            if let first = dated.first { milestones.append(first) }
        }
        if !milestones.isEmpty {
            let clauses = milestones.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
                .map { "\($0.0): \($0.1)" }
            sentences.append("The documented history includes " + clauses.joined(separator: "; ") + ".")
        }

        let steps = recent.filter(\.canShowAsNextStep)
        if !steps.isEmpty { sentences.append("Current care steps include \(titles(steps)).") }
        let context = recent.filter { $0.category == .biopsychosocialContext && (!$0.hasKnownStatus || $0.clinicalStatus == .current) }
        if let context = context.first {
            sentences.append("Life context recorded: \(phrase(HealthStoryText.clean(context.latest.details.isEmpty ? context.title : context.latest.details), limit: 180)).")
        }
        if sentences.isEmpty {
            sentences.append("Your saved health details include \(titles(recent)).")
        }
        return sentences.joined(separator: " ")
    }

    private static func titles(_ facts: [HealthFact]) -> String {
        var seen = Set<String>()
        let titles = facts.compactMap { fact -> String? in
            let title = phrase(CareInstructionPresentation.applies(fact.latest) ? CareInstructionPresentation.instruction(fact.latest) : HealthStoryText.clean(fact.title), limit: 90)
            return seen.insert(title.lowercased()).inserted ? title : nil
        }
        return Array(titles.prefix(2)).joined(separator: "; ")
    }

    private static func phrase(_ text: String, limit: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        var result = ""
        for word in words {
            let next = result.isEmpty ? String(word) : result + " " + word
            if next.count > limit { return result.isEmpty ? String(word) : result + "…" }
            result = next
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: ".!?; "))
    }
}
