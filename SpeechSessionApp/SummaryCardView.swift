import SwiftUI

// MARK: - Shared summary card components
// Used by both SessionDetailView (per-session) and GlobalHealthSummaryView (cross-session).

// MARK: SummaryCardsView

/// Parses a markdown-formatted summary string (## headers + body text) and renders
/// each section as an Apple Health–style category card.
struct SummaryCardsView: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                SummaryCategoryCard(title: section.title, content: section.content)
            }
        }
        .padding(.horizontal)
    }

    struct SummarySection {
        let title: String
        let content: String
    }

    var sections: [SummarySection] {
        var result: [SummarySection] = []
        var currentTitle: String? = nil
        var currentLines: [String] = []

        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") || t.hasPrefix("# ") {
                if let title = currentTitle {
                    result.append(SummarySection(title: title, content: currentLines.joined(separator: "\n")))
                }
                currentTitle = t.hasPrefix("## ") ? String(t.dropFirst(3)) : String(t.dropFirst(2))
                currentLines = []
            } else if !t.isEmpty {
                currentLines.append(t)
            }
        }

        if let title = currentTitle {
            result.append(SummarySection(title: title, content: currentLines.joined(separator: "\n")))
        }

        return result
    }
}

// MARK: SummaryCategoryCard

/// A single Apple Health–style card: colored icon + uppercase label + content.
struct SummaryCategoryCard: View {
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(categoryColor.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Image(systemName: categoryIcon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(categoryColor)
                }
                Text(title.uppercased())
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
            }

            // Content — bullet list or plain paragraph
            if hasBullets {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(bulletItems, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(Color.primary.opacity(0.35))
                                .frame(width: 5, height: 5)
                                .padding(.top, 7)
                            Text(item)
                                .font(.body)
                        }
                    }
                }
            } else {
                Text(content)
                    .font(.body)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Bullet helpers

    private var hasBullets: Bool {
        content.components(separatedBy: "\n")
            .contains { $0.hasPrefix("- ") || $0.hasPrefix("• ") || $0.hasPrefix("* ") }
    }

    private var bulletItems: [String] {
        content.components(separatedBy: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") { return String(t.dropFirst(2)) }
            if t.hasPrefix("• ") { return String(t.dropFirst(2)) }
            if t.hasPrefix("* ") { return String(t.dropFirst(2)) }
            if t.isEmpty { return nil }
            return t
        }
    }

    // MARK: Icon + colour mapping

    var categoryIcon: String {
        let l = title.lowercased()
        if l.contains("chief") || l.contains("complaint")       { return "stethoscope" }
        if l.contains("symptom")                                 { return "waveform.path.ecg" }
        if l.contains("diagnos") || l.contains("condition")     { return "cross.case.fill" }
        if l.contains("medication")                              { return "pills.fill" }
        if l.contains("care plan") || l.contains("treatment")   { return "heart.text.square.fill" }
        if l.contains("vaccination")                             { return "syringe.fill" }
        if l.contains("allerg")                                  { return "exclamationmark.shield.fill" }
        if l.contains("test") || l.contains("lab")              { return "doc.text.magnifyingglass" }
        if l.contains("follow")                                  { return "calendar.badge.clock" }
        if l.contains("biopsychosocial") || l.contains("psychosocial") || l.contains("context") {
            return "brain.head.profile"
        }
        return "doc.text.fill"
    }

    var categoryColor: Color {
        let l = title.lowercased()
        if l.contains("chief") || l.contains("complaint")       { return .blue }
        if l.contains("symptom")                                 { return .orange }
        if l.contains("diagnos") || l.contains("condition")     { return .red }
        if l.contains("medication")                              { return .purple }
        if l.contains("care plan") || l.contains("treatment")   { return .green }
        if l.contains("vaccination")                             { return .teal }
        if l.contains("allerg")                                  { return .yellow }
        if l.contains("test") || l.contains("lab")              { return .indigo }
        if l.contains("follow")                                  { return .cyan }
        if l.contains("biopsychosocial") || l.contains("psychosocial") || l.contains("context") {
            return .pink
        }
        return .gray
    }
}
