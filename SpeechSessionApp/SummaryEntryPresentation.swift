import Foundation
import SpeechSessionPersistence

/// Shared sentence / metadata formatting for summary cards and PDF export.
enum SummaryEntryPresentation {
    static func displayTitle(for entry: SummaryEntry) -> String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled detail" : trimmed
    }

    static func uniqueDetails(for entry: SummaryEntry) -> String? {
        let details = entry.details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !details.isEmpty else { return nil }
        let title = displayTitle(for: entry)
        if details.caseInsensitiveCompare(title) == .orderedSame { return nil }
        for sep in [" — ", " – ", " - "] {
            if details.hasPrefix(title + sep) {
                let rest = String(details.dropFirst(title.count + sep.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.isEmpty || rest.caseInsensitiveCompare(title) == .orderedSame {
                    return nil
                }
            }
        }
        return details
    }

    static func sentenceSummary(for entry: SummaryEntry) -> String {
        SummaryEntrySentence.make(
            title: displayTitle(for: entry),
            details: uniqueDetails(for: entry) ?? entry.details
        )
    }

    static func dateLineText(for entry: SummaryEntry) -> String {
        guard let date = entry.relevantDate else {
            return addLinkTitle("date")
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Print-friendly date label (no interactive “Add …” copy).
    static func exportDateLine(for entry: SummaryEntry) -> String {
        guard let date = entry.relevantDate else { return "Date not set" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func practitionerLineText(for entry: SummaryEntry) -> String {
        if entry.category == .practitionerContact {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
            if let name = entry.fields.first(where: { $0.label.localizedCaseInsensitiveContains("name") })?.value
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
            return addLinkTitle("practitioner")
        }
        guard let field = practitionerField(for: entry) else {
            return addLinkTitle("practitioner")
        }
        let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || field.isMissing || field.needsReview {
            return addLinkTitle("practitioner")
        }
        return value
    }

    static func exportPractitionerLine(for entry: SummaryEntry) -> String {
        let line = practitionerLineText(for: entry)
        if line.hasPrefix("Add ") { return "Practitioner not listed" }
        return line
    }

    static func practitionerNeedsAttention(for entry: SummaryEntry) -> Bool {
        if entry.category == .practitionerContact { return false }
        guard let field = practitionerField(for: entry) else { return true }
        let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || field.isMissing || field.needsReview
    }

    static func practitionerLineText(for cluster: SummaryEntryCluster) -> String {
        guard let newest = cluster.entriesNewestFirst.first else {
            return addLinkTitle("practitioner")
        }
        return practitionerLineText(for: newest)
    }

    static func exportPractitionerLine(for cluster: SummaryEntryCluster) -> String {
        guard let newest = cluster.entriesNewestFirst.first else {
            return "Practitioner not listed"
        }
        return exportPractitionerLine(for: newest)
    }

    static func practitionerNeedsAttention(for cluster: SummaryEntryCluster) -> Bool {
        guard let newest = cluster.entriesNewestFirst.first else { return true }
        return practitionerNeedsAttention(for: newest)
    }

    static func addLinkTitle(_ phrase: String) -> String {
        let titled = phrase
            .split(whereSeparator: { $0.isWhitespace })
            .map { word -> String in
                guard let first = word.first else { return "" }
                return String(first).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
        return "Add \(titled)"
    }

    /// Short label for the source entry a summary fact came from.
    static func sourceCitationLabel(for entry: SummaryEntry) -> String? {
        if let title = entry.sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let provenance = entry.provenance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !provenance.isEmpty {
            return provenance
        }
        if entry.sourceSessionID != nil {
            if let date = entry.sourceDate {
                return date.formatted(date: .abbreviated, time: .shortened)
            }
            return "Source entry"
        }
        return nil
    }

    static func entryEnsuringPractitionerField(_ entry: SummaryEntry) -> SummaryEntry {
        guard entry.category != .practitionerContact else { return entry }
        let isPractitionerField = { (field: SummaryEntryField) -> Bool in
            let label = field.label.lowercased()
            return label.contains("practitioner")
                || label.contains("provider")
                || label.contains("clinician")
                || label.contains("session")
        }
        if entry.fields.contains(where: isPractitionerField) {
            return entry
        }
        var updated = entry
        updated.fields.append(
            SummaryEntryField(label: "Practitioner", value: "", isMissing: true, needsReview: true)
        )
        return updated
    }

    private static func practitionerField(for entry: SummaryEntry) -> SummaryEntryField? {
        entry.fields.first { field in
            let label = field.label.lowercased()
            return label.contains("practitioner")
                || label.contains("provider")
                || label.contains("clinician")
        }
    }
}
