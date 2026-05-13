import SwiftUI
import SpeechSessionPersistence

// MARK: - Shared summary card components
// Used by SessionDetailView (per-entry) and ScopedHealthSummaryView (cross-entry).

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

/// A single Apple Health–style card: colored icon + uppercase label + collapsible content.
/// Category titles use subheadline **bold** + `foregroundStyle(.primary)` so they read as WCAG **large text**
/// (≥14pt bold at default content size) with **≥4.5:1** contrast on grouped backgrounds (typical AAA for large text).
/// Dynamic Type scales the title with user text size settings.
struct SummaryCategoryCard: View {
    let title: String
    let content: String

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tappable header row
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
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
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                        .kerning(0.5)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) section")
            .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")

            // Collapsible content
            if isExpanded {
                Divider()
                    .padding(.horizontal, 16)

                Group {
                    if hasBullets {
                        dividedSummaryItemList(items: displayBulletItems)
                    } else {
                        freeformDividedContent(Self.strippingMarkdownBoldAsterisks(from: content))
                    }
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .summaryGlassCard(cornerRadius: 14)
    }

    // MARK: Bullet helpers

    private var hasBullets: Bool {
        content.components(separatedBy: "\n")
            .contains { $0.hasPrefix("- ") || $0.hasPrefix("• ") || $0.hasPrefix("* ") }
    }

    /// List-style rows separated by dividers; primary segment bold when line contains ` — ` / ` – ` / ` - `.
    @ViewBuilder
    private func dividedSummaryItemList(items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                summaryPrimarySecondaryLine(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                if index < items.count - 1 {
                    Divider()
                }
            }
        }
    }

    /// Bold primary label + secondary details when the line uses a recognized separator (model bullet style).
    @ViewBuilder
    private func summaryPrimarySecondaryLine(_ item: String) -> some View {
        if let (primary, detail) = Self.splitPrimaryAndDetail(from: item) {
            if let detail, !detail.isEmpty {
                (Text(primary)
                    .font(.body)
                    .fontWeight(.semibold)
                    + Text(" — ")
                    .font(.body)
                    .foregroundStyle(.primary)
                    + Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(primary)
                    .font(.body)
                    .fontWeight(.semibold)
            }
        } else {
            Text(item)
                .font(.body)
        }
    }

    /// Non-bulleted body: one row per non-empty line (dividers when multiple lines); single line keeps optional primary/detail styling.
    @ViewBuilder
    private func freeformDividedContent(_ text: String) -> some View {
        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.isEmpty {
            Text(text).font(.body)
        } else {
            dividedSummaryItemList(items: lines)
        }
    }

    /// First matching separator wins (matches longitudinal / visit summary list lines).
    private static func splitPrimaryAndDetail(from line: String) -> (String, String?)? {
        let separators = [" — ", " – ", " - "]
        for sep in separators {
            guard let range = line.range(of: sep) else { continue }
            let primary = line[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !primary.isEmpty else { continue }
            return (primary, detail.isEmpty ? nil : detail)
        }
        return nil
    }

    private var displayBulletItems: [String] {
        bulletItems.map { Self.strippingMarkdownBoldAsterisks(from: $0) }
    }

    private static func strippingMarkdownBoldAsterisks(from text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
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
        if l.contains("finding")                                 { return "cross.case.fill" }
        if l.contains("diagnos") || l.contains("condition")     { return "cross.case.fill" }
        if l.contains("medication")                              { return "pills.fill" }
        if l.contains("care plan") || l.contains("treatment")   { return "heart.text.square.fill" }
        if l.contains("vaccination")                             { return "syringe.fill" }
        if l.contains("allerg")                                  { return "exclamationmark.shield.fill" }
        if l.contains("test") || l.contains("lab")              { return "doc.text.magnifyingglass" }
        if l.contains("follow")                                  { return "calendar.badge.clock" }
        if l.contains("other notes") || l.contains("misc")      { return "square.and.pencil" }
        if l.contains("biopsychosocial") || l.contains("psychosocial") || l.contains("context") {
            return "brain.head.profile"
        }
        return "doc.text.fill"
    }

    var categoryColor: Color {
        let l = title.lowercased()
        if l.contains("chief") || l.contains("complaint")       { return .blue }
        if l.contains("symptom")                                 { return .orange }
        if l.contains("finding")                                 { return .red }
        if l.contains("diagnos") || l.contains("condition")     { return .red }
        if l.contains("medication")                              { return .purple }
        if l.contains("care plan") || l.contains("treatment")   { return .green }
        if l.contains("vaccination")                             { return .teal }
        if l.contains("allerg")                                  { return .yellow }
        if l.contains("test") || l.contains("lab")              { return .indigo }
        if l.contains("follow")                                  { return .cyan }
        if l.contains("other notes") || l.contains("misc")      { return .gray }
        if l.contains("biopsychosocial") || l.contains("psychosocial") || l.contains("context") {
            return .pink
        }
        return .gray
    }
}

// MARK: - CareTimelineCard

/// Collapsible chronological list of entries (shared by global and folder summaries).
struct CareTimelineCard: View {
    let sessions: [Session]

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 34, height: 34)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    Text("CARE TIMELINE")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                        .kerning(0.5)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Care timeline section")
            .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")

            if isExpanded {
                Divider()
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 9, height: 9)
                                    .padding(.top, 4)
                                if index < sessions.count - 1 {
                                    Rectangle()
                                        .fill(Color.blue.opacity(0.2))
                                        .frame(width: 2)
                                        .frame(minHeight: 28)
                                }
                            }
                            .frame(width: 9)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let title = session.title {
                                    Text(title)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                } else if !session.transcript.isEmpty {
                                    Text(session.transcript)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("Untitled entry")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .italic()
                                }
                            }
                            .padding(.bottom, index < sessions.count - 1 ? 14 : 0)
                        }
                    }
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .summaryGlassCard(cornerRadius: 14)
    }
}
