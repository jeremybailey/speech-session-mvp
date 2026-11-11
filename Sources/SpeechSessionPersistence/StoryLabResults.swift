import Foundation
import SwiftUI
import Charts

public struct StoryLabReading: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let recordID: UUID?
    public let name: String
    public let result: String
    public let unit: String
    public let specimen: String
    public let context: String
    public let interval: String
    public let interpretation: String
    public let date: Date?
    public let dateLabel: String

    init?(_ entry: SummaryEntry) {
        guard entry.category == .testsAndLabs, !entry.isDeleted else { return nil }
        func field(_ labels: String...) -> String {
            entry.fields.first { field in labels.contains { $0.caseInsensitiveCompare(field.label) == .orderedSame } }?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let test = field("Name", "Test", "Test name", "Analyte")
        name = test.isEmpty ? (entry.evidence?.sourceAssertion?.name ?? entry.title) : test
        var value = field("Result", "Value", "Test result")
        guard !name.isEmpty, !value.isEmpty else { return nil }
        var units = field("Units", "Unit")
        // Some saved lab imports keep the value and unit together.
        let parts = value.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.count == 2, parts[0].range(of: #"^[<>≤≥]?[+-]?(?:\d+(?:\.\d+)?|\.\d+)$"#, options: .regularExpression) != nil,
           parts[1].range(of: #"^[\p{L}%µμ][\p{L}\d/%µμ^.*-]*$"#, options: .regularExpression) != nil,
           units == parts[1] || (units.isEmpty && (parts[1].contains("/") || ["%", "IU", "U", "s", "mm", "mg", "g"].contains(parts[1]))) {
            value = parts[0]
            units = parts[1]
        }
        id = entry.id
        recordID = entry.sourceSessionID
        result = value
        unit = units
        specimen = field("Specimen")
        context = field("Context")
        interval = field("Reference range", "referenceRange")
        interpretation = field("Interpretation", "Abnormality")
        let recorded = entry.evidence?.eventDate ?? ""
        date = entry.dateNeedsReview ? nil : (Self.day(recorded) ?? (recorded.isEmpty ? entry.relevantDate : nil))
        dateLabel = recorded.isEmpty ? (date.map(Self.label) ?? "Date unknown") : recorded
    }

    static func savedReadings(_ entry: SummaryEntry) -> [Self] {
        if let raw = Self(entry) { return [raw] }
        let display = BArtifactPresentation.display(entry)
        if let reading = Self(display) { return [reading] }
        // Older panels use a named field per measurement, with an explicit reference boundary.
        return display.fields.enumerated().compactMap { index, field in
            guard let boundary = field.value.range(of: " (ref. "), field.value.hasSuffix(")") else { return nil }
            var measurement = display
            measurement.id = IncrementalRecordUpdate.stableID("lab-panel-" + entry.id.uuidString + "-" + String(index))
            measurement.fields = [
                .init(label: "Name", value: field.label),
                .init(label: "Result", value: String(field.value[..<boundary.lowerBound])),
                .init(label: "Reference range", value: String(field.value[boundary.upperBound...].dropLast()))
            ]
            return Self(measurement)
        }
    }

    private static func day(_ string: String) -> Date? {
        for pattern in ["yyyy-MM-dd", "MMM d, yyyy", "MMMM d, yyyy", "d MMM yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = pattern
            if let date = formatter.date(from: string), formatter.string(from: date).caseInsensitiveCompare(string) == .orderedSame { return date }
        }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func label(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }

    public var valueLabel: String { [result, unit].filter { !$0.isEmpty }.joined(separator: " ") }
    public var number: Double? {
        guard !unit.isEmpty, result.range(of: #"^[+-]?(?:\d+(?:\.\d+)?|\.\d+)$"#, options: .regularExpression) != nil,
              let number = Double(result), number.isFinite else { return nil }
        return number
    }
}

public struct StoryLabSeries: Identifiable, Sendable {
    public let readings: [StoryLabReading]
    public var latest: StoryLabReading { readings[0] }
    public var id: UUID { latest.id }
    public var title: String { [latest.name, latest.specimen, latest.context].filter { !$0.isEmpty }.joined(separator: " · ") }

    public static func grouped(_ readings: [StoryLabReading]) -> [Self] {
        let groups = Dictionary(grouping: readings) { reading in
            [reading.name.lowercased(), reading.unit, reading.specimen.lowercased(), reading.context.lowercased()]
        }
        return groups.values.flatMap { group -> [Self] in
            let dated = group.filter { $0.date != nil }.sorted {
                ($0.date!, $0.id.uuidString) > ($1.date!, $1.id.uuidString)
            }
            // Simultaneous differing values have no single latest value.
            let conflicts = Dictionary(grouping: dated, by: { $0.date! }).values.contains { Set($0.map(\.result)).count > 1 }
            var series = conflicts ? dated.map { Self(readings: [$0]) } : (dated.isEmpty ? [] : [Self(readings: dated)])
            series += group.filter { $0.date == nil }.map { Self(readings: [$0]) }
            return series
        }.sorted { first, second in
            if first.title != second.title { return first.title < second.title }
            if first.latest.unit != second.latest.unit { return first.latest.unit < second.latest.unit }
            if first.latest.date != second.latest.date { return (first.latest.date ?? .distantPast) > (second.latest.date ?? .distantPast) }
            return first.id.uuidString < second.id.uuidString
        }
    }

    public var points: [StoryLabReading] {
        guard readings.allSatisfy({ $0.number != nil && $0.date != nil }) else { return [] }
        var seen = Set<Date>()
        let ordered = readings.reversed().filter { seen.insert($0.date!).inserted }
        return ordered.count >= 2 ? ordered : []
    }
}

public struct StoryLabSparkline: View {
    let series: StoryLabSeries
    public init(_ series: StoryLabSeries) { self.series = series }
    public var body: some View {
        Chart(series.points) { point in
            if let date = point.date, let number = point.number {
                LineMark(x: .value("Date", date), y: .value("Result", number))
                PointMark(x: .value("Date", date), y: .value("Result", number)).symbolSize(14)
            }
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartXScale(range: .plotDimension(padding: 4))
        .chartYScale(range: .plotDimension(padding: 4))
        .foregroundStyle(Color(red: 0.13, green: 0.43, blue: 0.35))
        .accessibilityLabel(series.title)
    }
}

public struct StorySummarySnapshot: Codable, Sendable {
    public let evidence: [StoryEvidence]
    public let labs: [StoryLabReading]
}

extension SessionStore {
    public func storySummarySnapshot() throws -> StorySummarySnapshot {
        let facts = HealthMemoryProjection.facts(in: try healthSnapshot())
        let readings = facts.filter { $0.category == .testsAndLabs && !$0.preference.hidden }
            .flatMap(\.occurrences).filter { HealthStoryEligibility.includes($0) }
            .flatMap(StoryLabReading.savedReadings)
        return StorySummarySnapshot(evidence: try storySummaryEvidence(), labs: readings)
    }
}


extension SessionStore {
    /// Reattach readings only when the full input of the published document can be reproduced.
    public func recoveredStorySharedSummary() throws -> StorySharedSummary? {
        let workspace = try storyWorkspace()
        guard var summary = workspace.sharedSummary, summary.labReadings?.isEmpty != false else { return workspace.sharedSummary }
        let parents = Set(workspace.messages.compactMap { stage -> UUID? in
            guard stage.role == "system", stage.state == "completed",
                  StorySummaryDocument.body(stage.text) == summary.text else { return nil }
            return stage.summaryParentID
        })
        guard parents.count == 1, let parent = workspace.messages.first(where: { parents.contains($0.id) }),
              let json = parent.requestJSON else { return summary }
        let data = Data(json.utf8)
        let frozen = (try? JSONDecoder().decode(StorySummarySnapshot.self, from: data))?.evidence
            ?? (try? JSONDecoder().decode([StoryEvidence].self, from: data))
        guard let frozen else { return summary }
        let current = try storySummarySnapshot()
        guard !current.labs.isEmpty else { return summary }
        if current.evidence != frozen {
            guard try storySummaryEvidence(legacyDates: true) == frozen else { return summary }
        }
        summary.labReadings = current.labs
        return summary
    }
}
