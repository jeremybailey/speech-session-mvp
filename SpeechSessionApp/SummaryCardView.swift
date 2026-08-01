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

    @State private var isExpanded = true

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
                VStack(spacing: 10) {
                    ForEach(entries) { entry in
                        AtomicSummaryEntryCard(
                            entry: entry,
                            knownPractitioners: knownPractitioners,
                            onSave: onSave,
                            onDelete: onDelete
                        )
                    }
                    Button {
                        onAdd(category)
                    } label: {
                        Label("Add Entry", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .summaryGlassCard(cornerRadius: 14)
    }
}

private struct AtomicSummaryEntryCard: View {
    let entry: SummaryEntry
    let knownPractitioners: [String]
    let onSave: (SummaryEntry) -> Void
    let onDelete: (SummaryEntry) -> Void

    @State private var editingEntry: SummaryEntry?
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    dragOffset = 0
                }
                onDelete(entry)
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.caption)
                    .labelStyle(.iconOnly)
                    .frame(width: 76)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandPalette.systemRed)
            .opacity(dragOffset < -8 ? 1 : 0)

            entryContent
                .offset(x: dragOffset)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture {
                    editingEntry = entry
                }
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            dragOffset = min(0, max(-88, value.translation.width))
                        }
                        .onEnded { value in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                dragOffset = value.translation.width < -44 ? -88 : 0
                            }
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(item: $editingEntry) { entry in
            SummaryEntryEditor(entry: entry, knownPractitioners: knownPractitioners) { updated in
                editingEntry = nil
                dragOffset = 0
                onSave(updated)
            } onCancel: {
                editingEntry = nil
            }
        }
    }

    private var entryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title.isEmpty ? "Untitled detail" : entry.title)
                        .font(.body)
                        .fontWeight(.semibold)
                    Text(dateLabel)
                        .font(.caption)
                        .foregroundStyle(entry.dateNeedsReview || entry.relevantDate == nil ? BrandPalette.systemOrange : .secondary)
                    if !entry.provenance.isEmpty {
                        Label(entry.provenance, systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            if !entry.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(entry.details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !entry.fields.isEmpty {
                VStack(spacing: 6) {
                    ForEach(entry.fields) { field in
                        HStack(alignment: .top) {
                            Text(field.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 118, alignment: .leading)
                            Text(field.value.isEmpty ? "Add \(field.label.lowercased())" : field.value)
                                .font(.caption)
                                .foregroundStyle(field.isMissing || field.needsReview ? BrandPalette.systemOrange : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var dateLabel: String {
        guard let date = entry.relevantDate else {
            return "Add the relevant date"
        }
        let formatted = date.formatted(date: .abbreviated, time: .omitted)
        return entry.dateNeedsReview ? "Confirm relevant date: \(formatted)" : formatted
    }

    private var iconName: String {
        entry.category == .practitionerContact ? "person.crop.circle.fill" : "doc.text.fill"
    }

    private var color: Color {
        entry.category == .practitionerContact ? BrandPalette.systemIndigo : BrandPalette.systemBlue
    }
}

private struct SummaryEntryEditor: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (SummaryEntry) -> Void
    let onCancel: () -> Void
    let knownPractitioners: [String]

    @State private var entry: SummaryEntry
    @State private var editableDate: Date

    init(
        entry: SummaryEntry,
        knownPractitioners: [String],
        onSave: @escaping (SummaryEntry) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        self.knownPractitioners = knownPractitioners
        _entry = State(initialValue: entry)
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
                            } else {
                                TextField("Add \(field.label.lowercased())", text: $field.value, axis: .vertical)
                            }
                        }
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
                            let value = entry.fields[index].value.trimmingCharacters(in: .whitespacesAndNewlines)
                            entry.fields[index].value = value
                            entry.fields[index].isMissing = value.isEmpty
                            entry.fields[index].needsReview = value.isEmpty
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
