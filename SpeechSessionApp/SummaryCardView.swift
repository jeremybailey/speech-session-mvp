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

// MARK: OverviewSummaryCard

/// Short contextual paragraph that sets the scene for the patient's health story.
struct OverviewSummaryCard: View {
    let paragraph: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(BrandPalette.systemBlue.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(BrandPalette.systemBlue)
                }
                Text("OVERVIEW")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .kerning(0.5)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }

            Text(paragraph)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .summaryGlassCard(cornerRadius: 14)
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
                    let lines = Self.normalizedSummaryLines(from: content)
                    if lines.isEmpty {
                        Text(content).font(.body)
                    } else {
                        dividedSummaryItemList(items: lines)
                    }
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .summaryGlassCard(cornerRadius: 14)
    }

    // MARK: Line normalization (dividers between rows; strip list markers legacy models may emit)

    /// One row per non-empty line; strips a single leading `- ` / `• ` / `* ` / `1. `-style marker so contact sections match other cards.
    private static func normalizedSummaryLines(from raw: String) -> [String] {
        raw
            .components(separatedBy: "\n")
            .map { line in
                let noBold = strippingMarkdownBoldAsterisks(from: line)
                return stripLeadingListMarker(from: noBold)
            }
            .filter { !$0.isEmpty }
    }

    private static func stripLeadingListMarker(from line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("- ") {
            s = String(s.dropFirst(2))
        } else if s.hasPrefix("• ") {
            s = String(s.dropFirst(2))
        } else if s.hasPrefix("* ") {
            s = String(s.dropFirst(2))
        } else if let range = s.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func strippingMarkdownBoldAsterisks(from text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
    }

    // MARK: Icon + colour mapping

    var categoryIcon: String {
        let l = title.lowercased()
        if l.contains("care team") || l.contains("practitioner") || (l.contains("provider") && l.contains("contact")) {
            return "person.2.fill"
        }
        if l.contains("chief") || l.contains("complaint") { return "stethoscope" }
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
        if l.contains("care team") || l.contains("practitioner") || (l.contains("provider") && l.contains("contact")) {
            return BrandPalette.systemIndigo
        }
        if l.contains("chief") || l.contains("complaint") { return BrandPalette.systemBlue }
        if l.contains("symptom") { return BrandPalette.systemOrange }
        if l.contains("finding") { return BrandPalette.systemRed }
        if l.contains("diagnos") || l.contains("condition") { return BrandPalette.systemRed }
        if l.contains("medication") { return BrandPalette.systemPurple }
        if l.contains("care plan") || l.contains("treatment") { return BrandPalette.systemGreen }
        if l.contains("vaccination") { return BrandPalette.systemTeal }
        if l.contains("allerg") { return BrandPalette.systemYellow }
        if l.contains("test") || l.contains("lab") { return BrandPalette.systemIndigo }
        if l.contains("follow") { return BrandPalette.systemCyan }
        if l.contains("other notes") || l.contains("misc") { return BrandPalette.systemGray }
        if l.contains("biopsychosocial") || l.contains("psychosocial") || l.contains("context") {
            return BrandPalette.systemPink
        }
        return BrandPalette.systemGray
    }
}

// MARK: AtomicSummaryCardsView

struct AtomicSummaryCardsView: View {
    let entries: [SummaryEntry]
    let onSave: (SummaryEntry) -> Void
    let onDelete: (SummaryEntry) -> Void
    let onAdd: (SummaryEntryCategory) -> Void

    private var groupedEntries: [(category: SummaryEntryCategory, entries: [SummaryEntry])] {
        SummaryEntryCategory.allCases.compactMap { category in
            let matches = entries
                .filter { $0.category == category && !$0.isDeleted }
                .sorted(by: sortEntriesForDisplay)
            return matches.isEmpty ? nil : (category, matches)
        }
    }

    private func sortEntriesForDisplay(_ lhs: SummaryEntry, _ rhs: SummaryEntry) -> Bool {
        if lhs.origin == .userAdded, rhs.origin != .userAdded { return false }
        if lhs.origin != .userAdded, rhs.origin == .userAdded { return true }
        if lhs.origin == .userAdded, rhs.origin == .userAdded {
            return lhs.createdAt < rhs.createdAt
        }
        return (lhs.relevantDate ?? lhs.sourceDate ?? lhs.createdAt) > (rhs.relevantDate ?? rhs.sourceDate ?? rhs.createdAt)
    }

    private var knownPractitioners: [String] {
        let names = entries
            .filter { $0.category == .practitionerContact && !$0.isDeleted }
            .compactMap { entry -> String? in
                let fieldName = entry.fields.first {
                    $0.label.localizedCaseInsensitiveContains("name")
                }?.value
                let candidate = (fieldName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? fieldName ?? "" : entry.title)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return candidate.isEmpty ? nil : candidate
            }
        return Array(Set(names)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(groupedEntries, id: \.category) { group in
                AtomicSummaryCategorySection(
                    category: group.category,
                    entries: group.entries,
                    knownPractitioners: knownPractitioners,
                    onSave: onSave,
                    onDelete: onDelete,
                    onAdd: onAdd
                )
            }
        }
        .padding(.horizontal)
    }
}

private struct AtomicSummaryCategorySection: View {
    let category: SummaryEntryCategory
    let entries: [SummaryEntry]
    let knownPractitioners: [String]
    let onSave: (SummaryEntry) -> Void
    let onDelete: (SummaryEntry) -> Void
    let onAdd: (SummaryEntryCategory) -> Void

    @State private var isExpanded = false
    @State private var expandedStackIDs: Set<String> = []
    @State private var editingEntry: SummaryEntry?

    private var entriesByBodySystem: [(system: BodySystem, entries: [SummaryEntry])] {
        var buckets: [BodySystem: [SummaryEntry]] = [:]
        for entry in entries {
            buckets[BodySystem.resolved(for: entry), default: []].append(entry)
        }
        return BodySystem.allCases.compactMap { system in
            guard let list = buckets[system], !list.isEmpty else { return nil }
            return (system, list)
        }
    }

    private var categoryClusters: [SummaryEntryCluster] {
        SummaryEntryClusterBuilder.clusters(from: entries, category: category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    SummaryCategoryIcon(title: category.displayTitle)
                    Text(category.displayTitle.uppercased())
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                        .kerning(0.5)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("\(entries.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 16)

                summaryEntryList
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .summaryGlassCard(cornerRadius: 14)
        .sheet(item: $editingEntry) { entry in
            SummaryEntryEditor(entry: entry, knownPractitioners: knownPractitioners) { updated in
                editingEntry = nil
                onSave(updated)
            } onCancel: {
                editingEntry = nil
            } onDelete: {
                editingEntry = nil
                withAnimation(.snappy) {
                    onDelete(entry)
                }
            }
        }
    }

    private var summaryEntryList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if category == .chiefComplaint {
                ForEach(entriesByBodySystem, id: \.system) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.system.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .kerning(0.4)
                        clusterRowsView(
                            SummaryEntryClusterBuilder.clusters(from: group.entries, category: category)
                        )
                    }
                }
            } else {
                clusterRowsView(categoryClusters)
            }

            Button {
                onAdd(category)
            } label: {
                Label("Add Entry", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .summarySecondaryButtonStyle()
        }
    }

    @ViewBuilder
    private func clusterRowsView(_ clusters: [SummaryEntryCluster]) -> some View {
        ForEach(clusters) { cluster in
            if cluster.isStack {
                stackRowsView(for: cluster)
            } else if let entry = cluster.entries.first {
                entryRowView(entry)
            }
        }
    }

    @ViewBuilder
    private func stackRowsView(for cluster: SummaryEntryCluster) -> some View {
        let isStackExpanded = expandedStackIDs.contains(cluster.id)

        Button {
            withAnimation(.snappy) {
                if isStackExpanded {
                    expandedStackIDs.remove(cluster.id)
                } else {
                    expandedStackIDs.insert(cluster.id)
                }
            }
        } label: {
            SummaryEntryStackRowContent(
                cluster: cluster,
                isExpanded: isStackExpanded
            )
        }
        .buttonStyle(.plain)

        if isStackExpanded {
            ForEach(cluster.entries) { entry in
                entryRowView(entry, nested: true)
            }
        }
    }

    private func entryRowView(_ entry: SummaryEntry, nested: Bool = false) -> some View {
        SummaryEntryRowContent(entry: entry)
            .padding(.leading, nested ? 12 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                editingEntry = SummaryEntryDisplay.entryEnsuringPractitionerField(entry)
            }
            .contextMenu {
                Button(role: .destructive) {
                    withAnimation(.snappy) {
                        onDelete(entry)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }
}

// MARK: - Entry row display

private enum SummaryEntryDisplay {
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
}

private struct SummaryEntryRowContent: View {
    let entry: SummaryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(SummaryEntryDisplay.sentenceSummary(for: entry))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(SummaryEntryDisplay.dateLineText(for: entry))
                        .font(.caption)
                        .foregroundStyle(entry.relevantDate == nil ? BrandPalette.systemBlue : .secondary)
                    ClinicalStatusBadge(status: entry.clinicalStatus)
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .summaryEntryRowSurface(cornerRadius: 12)
    }
}

private struct SummaryEntryStackRowContent: View {
    let cluster: SummaryEntryCluster
    let isExpanded: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(cluster.sentenceSummary)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let range = cluster.dateRangeText {
                        Text(range)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ClinicalStatusBadge(status: cluster.clinicalStatus)
                    Text("\(cluster.entries.count) sources")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .summaryEntryRowSurface(cornerRadius: 12)
        .accessibilityLabel(
            "\(cluster.sentenceSummary), \(cluster.clinicalStatus.displayTitle), \(cluster.entries.count) sources"
        )
        .accessibilityHint(isExpanded ? "Collapses source list" : "Expands source list")
    }
}

private struct ClinicalStatusBadge: View {
    let status: SummaryEntryClinicalStatus

    var body: some View {
        Text(status.displayTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(backgroundColor))
            .accessibilityLabel(status.displayTitle)
    }

    private var foregroundColor: Color {
        switch status {
        case .active: return BrandPalette.systemGreen
        case .inactive: return BrandPalette.systemOrange
        case .resolved: return .secondary
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .active: return BrandPalette.systemGreen.opacity(0.14)
        case .inactive: return BrandPalette.systemOrange.opacity(0.14)
        case .resolved: return Color.secondary.opacity(0.12)
        }
    }
}

private struct SummaryEntryEditor: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (SummaryEntry) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let knownPractitioners: [String]

    @State private var entry: SummaryEntry
    @State private var editableDate: Date

    init(
        entry: SummaryEntry,
        knownPractitioners: [String],
        onSave: @escaping (SummaryEntry) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        self.knownPractitioners = knownPractitioners
        var initial = entry
        if initial.category == .chiefComplaint,
           !initial.fields.contains(where: { $0.label.caseInsensitiveCompare(BodySystem.fieldLabel) == .orderedSame }) {
            let system = BodySystem.resolved(for: initial)
            initial.fields.insert(
                SummaryEntryField(label: BodySystem.fieldLabel, value: system.displayName, isMissing: false, needsReview: false),
                at: 0
            )
        }
        _entry = State(initialValue: initial)
        _editableDate = State(initialValue: entry.relevantDate ?? entry.sourceDate ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Card") {
                    TextField("Title", text: $entry.title)
                    TextField("Details", text: $entry.details, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section("Status") {
                    Picker("Status", selection: $entry.clinicalStatus) {
                        ForEach(SummaryEntryClinicalStatus.allCases, id: \.self) { status in
                            Text(status.displayTitle).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Relevant date") {
                    DatePicker("Date", selection: $editableDate, displayedComponents: .date)
                    Text("Use the actual date this information happened or became relevant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Fields") {
                    ForEach($entry.fields) { $field in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(field.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if isPractitionerField(field) {
                                practitionerPicker(for: $field)
                            } else if isBodySystemField(field) {
                                bodySystemPicker(for: $field)
                            } else {
                                TextField("Add \(field.label.lowercased())", text: $field.value, axis: .vertical)
                            }
                        }
                    }
                }

                Section {
                    Button("Delete card", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }

                if !entry.provenance.isEmpty || entry.sourceExcerpt != nil {
                    Section("Provenance") {
                        if !entry.provenance.isEmpty {
                            Text(entry.provenance)
                        }
                        if let excerpt = entry.sourceExcerpt {
                            Text(excerpt)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edit Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        entry.relevantDate = editableDate
                        entry.dateNeedsReview = false
                        for index in entry.fields.indices {
                            let isBodySystem = entry.fields[index].label.caseInsensitiveCompare(BodySystem.fieldLabel) == .orderedSame
                            let value = entry.fields[index].value.trimmingCharacters(in: .whitespacesAndNewlines)
                            entry.fields[index].value = value
                            if isBodySystem {
                                let system = BodySystem.parse(value) ?? BodySystem.classify([entry.title, entry.details].joined(separator: " "))
                                entry.fields[index].value = system.displayName
                                entry.fields[index].isMissing = false
                                entry.fields[index].needsReview = false
                            } else {
                                entry.fields[index].isMissing = value.isEmpty
                                entry.fields[index].needsReview = value.isEmpty
                            }
                        }
                        entry.updatedAt = Date()
                        entry.origin = entry.origin == .userAdded ? .userAdded : .userEdited
                        entry.needsReview = entry.dateNeedsReview || entry.fields.contains { $0.needsReview || $0.isMissing }
                        entry.reviewReason = entry.needsReview ? reviewReason(for: entry) : nil
                        onSave(entry)
                        dismiss()
                    }
                }
            }
        }
    }

    private func reviewReason(for entry: SummaryEntry) -> String {
        if entry.relevantDate == nil || entry.dateNeedsReview {
            return "Add the actual relevant date for this information."
        }
        let missingLabels = entry.fields
            .filter { $0.isMissing || $0.needsReview }
            .map(\.label)
        if let first = missingLabels.first {
            return "Add \(first.lowercased()) to complete this card."
        }
        return "Review this card for missing or ambiguous information."
    }

    @ViewBuilder
    private func practitionerPicker(for field: Binding<SummaryEntryField>) -> some View {
        let addNew = "__add_new_practitioner__"
        Picker("Practitioner", selection: Binding(
            get: {
                knownPractitioners.contains(field.wrappedValue.value) ? field.wrappedValue.value : addNew
            },
            set: { selected in
                if selected == addNew {
                    if knownPractitioners.contains(field.wrappedValue.value) {
                        field.wrappedValue.value = ""
                    }
                } else {
                    field.wrappedValue.value = selected
                }
            }
        )) {
            ForEach(knownPractitioners, id: \.self) { practitioner in
                Text(practitioner).tag(practitioner)
            }
            Text("Add new").tag(addNew)
        }

        if !knownPractitioners.contains(field.wrappedValue.value) {
            TextField("Add practitioner", text: field.value, axis: .vertical)
        }
    }

    private func isPractitionerField(_ field: SummaryEntryField) -> Bool {
        let label = field.label.lowercased()
        return label.contains("practitioner") || label.contains("provider") || label.contains("clinician")
    }

    private func isBodySystemField(_ field: SummaryEntryField) -> Bool {
        field.label.caseInsensitiveCompare(BodySystem.fieldLabel) == .orderedSame
    }

    @ViewBuilder
    private func bodySystemPicker(for field: Binding<SummaryEntryField>) -> some View {
        Picker("Body system", selection: Binding(
            get: { BodySystem.parse(field.wrappedValue.value) ?? .other },
            set: { selected in
                field.wrappedValue.value = selected.displayName
                field.wrappedValue.isMissing = false
                field.wrappedValue.needsReview = false
            }
        )) {
            ForEach(BodySystem.allCases) { system in
                Text(system.displayName).tag(system)
            }
        }
    }
}

private struct SummaryCategoryIcon: View {
    let title: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.18))
                .frame(width: 34, height: 34)
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    private var icon: String {
        let l = title.lowercased()
        if l.contains("care team") || l.contains("practitioner") || (l.contains("provider") && l.contains("contact")) {
            return "person.2.fill"
        }
        if l.contains("chief") || l.contains("complaint") { return "stethoscope" }
        if l.contains("symptom") { return "waveform.path.ecg" }
        if l.contains("finding") || l.contains("diagnos") || l.contains("condition") { return "cross.case.fill" }
        if l.contains("medication") { return "pills.fill" }
        if l.contains("care plan") || l.contains("treatment") { return "heart.text.square.fill" }
        if l.contains("vaccination") { return "syringe.fill" }
        if l.contains("allerg") { return "exclamationmark.shield.fill" }
        if l.contains("test") || l.contains("lab") { return "doc.text.magnifyingglass" }
        if l.contains("follow") { return "calendar.badge.clock" }
        if l.contains("biopsychosocial") || l.contains("psychosocial") || l.contains("context") { return "brain.head.profile" }
        return "doc.text.fill"
    }

    private var color: Color {
        let l = title.lowercased()
        if l.contains("care team") || l.contains("practitioner") || (l.contains("provider") && l.contains("contact")) {
            return BrandPalette.systemIndigo
        }
        if l.contains("chief") || l.contains("complaint") { return BrandPalette.systemBlue }
        if l.contains("symptom") { return BrandPalette.systemOrange }
        if l.contains("finding") || l.contains("diagnos") || l.contains("condition") { return BrandPalette.systemRed }
        if l.contains("medication") { return BrandPalette.systemPurple }
        if l.contains("care plan") || l.contains("treatment") { return BrandPalette.systemGreen }
        if l.contains("vaccination") { return BrandPalette.systemTeal }
        if l.contains("allerg") { return BrandPalette.systemYellow }
        if l.contains("test") || l.contains("lab") { return BrandPalette.systemIndigo }
        if l.contains("follow") { return BrandPalette.systemCyan }
        if l.contains("biopsychosocial") || l.contains("psychosocial") || l.contains("context") { return BrandPalette.systemPink }
        return BrandPalette.systemGray
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
                            .fill(BrandPalette.systemBlue.opacity(0.15))
                            .frame(width: 34, height: 34)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(BrandPalette.systemBlue)
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
                                    .fill(BrandPalette.systemBlue)
                                    .frame(width: 9, height: 9)
                                    .padding(.top, 4)
                                if index < sessions.count - 1 {
                                    Rectangle()
                                        .fill(BrandPalette.systemBlue.opacity(0.2))
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
