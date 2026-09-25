import Foundation

extension Session {
    /// Use accepted summary details for untitled imports; never replace a meaningful saved title.
    public var displayTitle: String {
        let existing = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let placeholders = ["", "health record", "audio record", "recording", "appointment", "journal", "photo", "document", "scanned document"]
        guard placeholders.contains(existing.lowercased()) else { return existing }
        let visible = (summaryEntries ?? []).filter {
            !$0.isDeleted && SummaryVerification.isVisible($0, source: transcript)
                && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let priorities: [SummaryEntryCategory] = [.chiefComplaint, .symptoms, .testsAndLabs, .findings,
                                                 .medications, .carePlan, .vaccinations, .practitionerContact]
        for category in priorities {
            let rows = visible.filter { $0.category == category }
            guard let first = rows.first else { continue }
            let subject = first.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let label: String
            switch category {
            case .testsAndLabs: label = rows.count > 1 ? "Lab results: \(subject) and more" : "Lab result: \(subject)"
            case .medications: label = "Medication: \(subject)"
            case .practitionerContact: label = "Care team: \(subject)"
            default: label = subject
            }
            return label.count > 80 ? String(label.prefix(77)) + "…" : label
        }
        return existing.isEmpty ? "Health record" : existing
    }
}
