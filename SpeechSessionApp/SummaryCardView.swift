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

/// Cross-visit digest as categorized bullets (not a spoken paragraph).
struct OverviewSummaryCard: View {
    let sections: [OverviewBulletSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(BrandPalette.systemBlue.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Image(systemName: "list.bullet")
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

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text(bullet)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
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
                VStack(alignment: .leading, spacing: 10) {
                    if category == .chiefComplaint {
                        ForEach(entriesByBodySystem, id: \.system) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.system.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .kerning(0.4)
                                ForEach(group.entries) { entry in
                                    AtomicSummaryEntryCard(
                                        entry: entry,
                                        knownPractitioners: knownPractitioners,
                                        onSave: onSave,
                                        onDelete: onDelete
                                    )
                                }
                            }
                        }
                    } else {
                        ForEach(entries) { entry in
                            AtomicSummaryEntryCard(
                                entry: entry,
                                knownPractitioners: knownPractitioners,
                                onSave: onSave,
                                onDelete: onDelete
                            )
                        }
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

    private let revealWidth: CGFloat = 52

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                commitDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(BrandPalette.systemRed))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .opacity(dragOffset < -12 ? 1 : 0)
            .allowsHitTesting(dragOffset < -20)
            .accessibilityLabel("Delete")

            entryContent
                .offset(x: dragOffset)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture {
                    if dragOffset < -12 {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    } else {
                        editingEntry = entryEnsuringPractitionerField(entry)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20, coordinateSpace: .local)
                        .onChanged { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            if abs(dy) > abs(dx) + 6 {
                                if dragOffset != 0 {
                                    dragOffset = 0
                                }
                                return
                            }
                            guard abs(dx) > abs(dy) + 8 else { return }
                            dragOffset = min(0, max(-revealWidth, dx))
                        }
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            guard abs(dx) > abs(dy) + 8 else {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                    dragOffset = 0
                                }
                                return
                            }
                            if dx < -72 {
                                commitDelete()
                            } else if dx < -28 {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                    dragOffset = -revealWidth
                                }
                            } else {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
        }
        .clipped()
        .sheet(item: $editingEntry) { entry in
            SummaryEntryEditor(entry: entry, knownPractitioners: knownPractitioners) { updated in
                editingEntry = nil
                dragOffset = 0
                onSave(updated)
            } onCancel: {
                editingEntry = nil
            } onDelete: {
                editingEntry = nil
                commitDelete()
            }
        }
    }

    private func commitDelete() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            dragOffset = 0
        }
        onDelete(entry)
    }

    private var entryContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 6) {
                    Text(displayTitle)
                        .font(.body)
                        .fontWeight(.semibold)

                    Text(dateLineText)
                        .font(.caption)
                        .foregroundStyle(dateNeedsAttention ? BrandPalette.systemBlue : .secondary)

                    if showsPractitionerLine {
                        Text(practitionerLineText)
                            .font(.caption)
                            .foregroundStyle(practitionerNeedsAttention ? BrandPalette.systemBlue : .secondary)
                    }

                    if let details = uniqueDetailsText {
                        Text(details)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !entry.provenance.isEmpty {
                        Label(entry.provenance, systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !remainingDisplayFields.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(remainingDisplayFields) { field in
                                let missing = field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || field.isMissing
                                    || field.needsReview
                                Text(missing ? Self.addLinkTitle(field.label) : field.value)
                                    .font(.caption)
                                    .foregroundStyle(missing ? BrandPalette.systemBlue : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var displayTitle: String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled detail" : trimmed
    }

    /// Omit details when they repeat the title (common when models echo the same fact twice).
    private var uniqueDetailsText: String? {
        let details = entry.details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !details.isEmpty else { return nil }
        let title = displayTitle
        if details.caseInsensitiveCompare(title) == .orderedSame { return nil }
        // "Title - same detail" / "Title — same detail" style echoes
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

    private var dateNeedsAttention: Bool {
        entry.relevantDate == nil
    }

    private var dateLineText: String {
        guard let date = entry.relevantDate else {
            return Self.addLinkTitle("date")
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var practitionerField: SummaryEntryField? {
        entry.fields.first { Self.isPractitionerOrSessionField($0) }
    }

    /// Care-plan (and similar) cards get a dedicated practitioner line; contact cards already use the title as the name.
    private var showsPractitionerLine: Bool {
        // Every clinical fact should name a practitioner; contact cards use the title as the name.
        entry.category != .practitionerContact
    }

    private var practitionerNeedsAttention: Bool {
        guard let field = practitionerField else { return true }
        let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || field.isMissing || field.needsReview
    }

    private var practitionerLineText: String {
        guard let field = practitionerField else { return Self.addLinkTitle("practitioner") }
        let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || field.isMissing || field.needsReview {
            return Self.addLinkTitle("practitioner")
        }
        return value
    }

    /// Title Case CTA for missing fields, e.g. "Add Date", "Add Practitioner".
    private static func addLinkTitle(_ phrase: String) -> String {
        let titled = phrase
            .split(whereSeparator: { $0.isWhitespace })
            .map { word -> String in
                guard let first = word.first else { return "" }
                return String(first).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
        return "Add \(titled)"
    }

    /// Fields shown under the card body, excluding labels/values that duplicate title, details, or practitioner.
    private var remainingDisplayFields: [SummaryEntryField] {
        let titleNorm = Self.normalized(displayTitle)
        let detailsNorm = Self.normalized(uniqueDetailsText ?? "")
        let joinedNorm = Self.normalized(
            [displayTitle, uniqueDetailsText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
        )
        let practitionerNorm = Self.normalized(
            practitionerField?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )

        return entry.fields.filter { field in
            if Self.isPractitionerOrSessionField(field) { return false }
            if field.label.caseInsensitiveCompare(BodySystem.fieldLabel) == .orderedSame {
                return false
            }
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let valueNorm = Self.normalized(value)
            if !valueNorm.isEmpty {
                if valueNorm == titleNorm { return false }
                if !detailsNorm.isEmpty, valueNorm == detailsNorm { return false }
                if !joinedNorm.isEmpty, valueNorm == joinedNorm { return false }
                if !practitionerNorm.isEmpty, valueNorm == practitionerNorm { return false }
            }
            // Hide empty Name on contact cards — title already carries the name.
            let label = field.label.lowercased()
            if entry.category == .practitionerContact, label == "name", value.isEmpty || valueNorm == titleNorm {
                return false
            }
            // Hide Plan / category echo fields that only restate the title line.
            if label == "plan" || label == entry.category.displayTitle.lowercased() {
                if value.isEmpty || valueNorm == titleNorm || valueNorm == joinedNorm { return false }
            }
            if label == "details", value.isEmpty || valueNorm == detailsNorm || valueNorm == titleNorm {
                return false
            }
            if label == "medication", valueNorm == titleNorm { return false }
            return true
        }
    }

    private static func isPractitionerOrSessionField(_ field: SummaryEntryField) -> Bool {
        let label = field.label.lowercased()
        return label.contains("practitioner")
            || label.contains("provider")
            || label.contains("clinician")
            || label.contains("session")
    }

    private static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Ensure the editor always has a Practitioner field so it can be filled when missing.
    private func entryEnsuringPractitionerField(_ entry: SummaryEntry) -> SummaryEntry {
        guard entry.category != .practitionerContact else { return entry }
        if entry.fields.contains(where: { Self.isPractitionerOrSessionField($0) }) {
            return entry
        }
        var updated = entry
        updated.fields.append(
            SummaryEntryField(label: "Practitioner", value: "", isMissing: true, needsReview: true)
        )
        return updated
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
