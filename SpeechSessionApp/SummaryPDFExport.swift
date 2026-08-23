import SwiftUI
import CoreGraphics
import Foundation
import SpeechSessionPersistence
import UIKit
import UniformTypeIdentifiers

// MARK: - Document model

struct SummaryPDFDocument: Sendable {
    var title: String
    var subtitle: String?
    var generatedAt: Date
    var overview: String?
    var categorySections: [SummaryPDFCategorySection]
    var legacySections: [SummaryPDFLegacySection]
    var timeline: [SummaryPDFTimelineEntry]

    var hasContent: Bool {
        overview != nil
            || !categorySections.isEmpty
            || !legacySections.isEmpty
            || !timeline.isEmpty
    }

    var suggestedFileName: String {
        title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SummaryPDFCategorySection: Sendable {
    var title: String
    var entryCount: Int
    var statusGroups: [SummaryPDFStatusGroup]
}

struct SummaryPDFStatusGroup: Sendable {
    var title: String
    var rows: [SummaryPDFEntryRow]
}

struct SummaryPDFEntryRow: Sendable {
    var sentence: String
    var dateText: String
    var practitionerText: String
    var sourceCaption: String?
    var nestedSources: [SummaryPDFEntryRow]
}

struct SummaryPDFLegacySection: Sendable {
    var title: String
    var body: String
}

struct SummaryPDFTimelineEntry: Sendable {
    var dateText: String
    var title: String
}

// MARK: - Builder

enum SummaryPDFDocumentBuilder {
    static func build(
        title: String,
        subtitle: String?,
        overview: String?,
        entries: [SummaryEntry],
        legacySections: [(title: String, content: String)] = [],
        timelineSessions: [Session] = []
    ) -> SummaryPDFDocument? {
        let categorySections = categorySections(from: entries)
        let legacy = legacySections.map {
            SummaryPDFLegacySection(title: $0.title, body: $0.content)
        }
        let timeline = timelineSessions.map { session in
            SummaryPDFTimelineEntry(
                dateText: session.date.formatted(date: .abbreviated, time: .shortened),
                title: sessionDisplayTitle(session)
            )
        }

        let document = SummaryPDFDocument(
            title: title,
            subtitle: subtitle,
            generatedAt: Date(),
            overview: overview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            categorySections: categorySections,
            legacySections: legacy,
            timeline: timeline
        )
        return document.hasContent ? document : nil
    }

    private static func categorySections(from entries: [SummaryEntry]) -> [SummaryPDFCategorySection] {
        SummaryEntryCategory.allCases.compactMap { category in
            let matches = entries.filter { $0.category == category && !$0.isDeleted }
            guard !matches.isEmpty else { return nil }

            let clusters = SummaryEntryClusterBuilder.clusters(from: matches, category: category)
            let statusGroups = SummaryEntryClusterOrdering.statusSections(from: clusters).map { section in
                SummaryPDFStatusGroup(
                    title: section.status.displayTitle,
                    rows: section.clusters.map { pdfRow(from: $0) }
                )
            }

            return SummaryPDFCategorySection(
                title: category.displayTitle,
                entryCount: matches.count,
                statusGroups: statusGroups
            )
        }
    }

    private static func pdfRow(from cluster: SummaryEntryCluster) -> SummaryPDFEntryRow {
        if cluster.isStack {
            let nested = cluster.entriesNewestFirst.map { pdfRow(from: $0) }
            return SummaryPDFEntryRow(
                sentence: cluster.sentenceSummary,
                dateText: cluster.dateRangeText ?? "Date not set",
                practitionerText: SummaryEntryPresentation.exportPractitionerLine(for: cluster),
                sourceCaption: "\(cluster.entries.count) sources",
                nestedSources: nested
            )
        }
        guard let entry = cluster.entries.first else {
            return SummaryPDFEntryRow(
                sentence: "Untitled detail",
                dateText: "Date not set",
                practitionerText: "Practitioner not listed",
                sourceCaption: nil,
                nestedSources: []
            )
        }
        return pdfRow(from: entry)
    }

    private static func pdfRow(from entry: SummaryEntry) -> SummaryPDFEntryRow {
        SummaryPDFEntryRow(
            sentence: SummaryEntryPresentation.sentenceSummary(for: entry),
            dateText: SummaryEntryPresentation.exportDateLine(for: entry),
            practitionerText: SummaryEntryPresentation.exportPractitionerLine(for: entry),
            sourceCaption: nil,
            nestedSources: []
        )
    }

    private static func sessionDisplayTitle(_ session: Session) -> String {
        if let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let transcript = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
            let snippet = transcript
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? String(transcript.prefix(120))
            return snippet
        }
        return "Untitled entry"
    }
}

// MARK: - Renderer

enum SummaryPDFRenderer {
    static func render(document: SummaryPDFDocument) throws -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            var layout = SummaryPDFLayout(pageRect: pageRect, context: context)
            layout.beginFirstPage()
            layout.drawHeader(title: document.title, subtitle: document.subtitle, generatedAt: document.generatedAt)

            if let overview = document.overview {
                layout.drawOverview(overview)
            }

            for section in document.categorySections {
                layout.drawCategorySection(section)
            }

            for section in document.legacySections {
                layout.drawLegacySection(section)
            }

            if !document.timeline.isEmpty {
                layout.drawTimeline(document.timeline)
            }

            layout.drawFooter(final: true)
        }
    }
}

// MARK: - Typography

private enum SummaryPDFHeadingLevel {
    case h1
    case h2
    case h3
    case body
    case caption

    var font: UIFont {
        switch self {
        case .h1: return UIFont.systemFont(ofSize: 22, weight: .bold)
        case .h2: return UIFont.systemFont(ofSize: 16, weight: .semibold)
        case .h3: return UIFont.systemFont(ofSize: 13, weight: .semibold)
        case .body: return UIFont.systemFont(ofSize: 11, weight: .regular)
        case .caption: return UIFont.systemFont(ofSize: 9, weight: .regular)
        }
    }

    var color: UIColor {
        switch self {
        case .h1, .h2, .h3, .body: return SummaryPDFStyle.primaryText
        case .caption: return SummaryPDFStyle.secondaryText
        }
    }

    var spaceBefore: CGFloat {
        switch self {
        case .h1: return 0
        case .h2: return 22
        case .h3: return 14
        case .body: return 0
        case .caption: return 0
        }
    }

    var spaceAfter: CGFloat {
        switch self {
        case .h1: return 10
        case .h2: return 8
        case .h3: return 6
        case .body: return 3
        case .caption: return 10
        }
    }
}

// MARK: - Layout engine

private struct SummaryPDFLayout {
    let pageRect: CGRect
    let context: UIGraphicsPDFRendererContext
    let margin: CGFloat = 54
    var y: CGFloat = 0
    var pageNumber = 1

    var contentWidth: CGFloat { pageRect.width - margin * 2 }

    mutating func beginFirstPage() {
        context.beginPage()
        y = margin
        fillWhiteBackground()
    }

    mutating func ensureSpace(_ requiredHeight: CGFloat) {
        let bottomLimit = pageRect.height - margin - 20
        guard y + requiredHeight > bottomLimit else { return }
        drawFooter(final: false)
        context.beginPage()
        pageNumber += 1
        y = margin
        fillWhiteBackground()
    }

    mutating func drawHeader(title: String, subtitle: String?, generatedAt: Date) {
        drawHeading(title, level: .h1)

        if let subtitle, !subtitle.isEmpty {
            drawText(subtitle, level: .caption, spaceBefore: 0, spaceAfter: 4)
        }

        let generated = "Generated \(generatedAt.formatted(date: .abbreviated, time: .shortened))"
        drawText(generated, level: .caption, spaceBefore: 0, spaceAfter: 20)
    }

    mutating func drawOverview(_ paragraph: String) {
        drawHeading("Overview", level: .h2)
        drawText(paragraph, level: .body, spaceBefore: 0, spaceAfter: 0)
        y += 6
    }

    mutating func drawCategorySection(_ section: SummaryPDFCategorySection) {
        let heading = section.entryCount == 1
            ? section.title
            : "\(section.title) (\(section.entryCount))"
        drawHeading(heading, level: .h2)

        for group in section.statusGroups {
            drawStatusGroup(group)
        }
    }

    mutating func drawStatusGroup(_ group: SummaryPDFStatusGroup) {
        drawHeading(group.title, level: .h3)

        for row in group.rows {
            drawEntryRow(row, indent: 0)
            for nested in row.nestedSources {
                drawEntryRow(nested, indent: 18)
            }
        }
    }

    mutating func drawEntryRow(_ row: SummaryPDFEntryRow, indent: CGFloat) {
        let insetX = margin + indent
        let rowWidth = contentWidth - indent
        let bulletPrefix = "• "
        let sentence = "\(bulletPrefix)\(row.sentence)"
        let bulletIndent = textWidth(bulletPrefix, font: SummaryPDFHeadingLevel.body.font)

        drawText(sentence, level: .body, at: insetX, width: rowWidth, spaceBefore: 0, spaceAfter: 2)

        var meta = "\(row.dateText) · \(row.practitionerText)"
        if let sourceCaption = row.sourceCaption {
            meta += " · \(sourceCaption)"
        }
        drawText(
            meta,
            level: .caption,
            at: insetX + bulletIndent,
            width: rowWidth - bulletIndent,
            spaceBefore: 0,
            spaceAfter: 0
        )
        y += 4
    }

    mutating func drawLegacySection(_ section: SummaryPDFLegacySection) {
        drawHeading(section.title, level: .h2)
        drawText(section.body, level: .body, spaceBefore: 0, spaceAfter: 0)
        y += 6
    }

    mutating func drawTimeline(_ entries: [SummaryPDFTimelineEntry]) {
        drawHeading("Care Timeline", level: .h2)

        for entry in entries {
            let line = "\(entry.dateText) — \(entry.title)"
            drawText(line, level: .body, spaceBefore: 0, spaceAfter: 4)
        }
        y += 4
    }

    mutating func drawFooter(final: Bool) {
        let footer = "CollectiveCare Health Summary · Page \(pageNumber)"
        let footerY = pageRect.height - margin + 6
        drawText(
            footer,
            level: .caption,
            at: margin,
            width: contentWidth,
            topY: footerY,
            spaceBefore: 0,
            spaceAfter: 0
        )
        _ = final
    }

    mutating func drawHeading(_ text: String, level: SummaryPDFHeadingLevel) {
        drawText(text, level: level, spaceBefore: level.spaceBefore, spaceAfter: level.spaceAfter)
    }

    @discardableResult
    mutating func drawText(
        _ text: String,
        level: SummaryPDFHeadingLevel,
        at x: CGFloat? = nil,
        width: CGFloat? = nil,
        topY: CGFloat? = nil,
        spaceBefore: CGFloat? = nil,
        spaceAfter: CGFloat? = nil
    ) -> CGFloat {
        let drawX = x ?? margin
        let drawWidth = width ?? contentWidth
        let before = spaceBefore ?? 0
        let after = spaceAfter ?? level.spaceAfter
        let textHeight = height(for: text, font: level.font, width: drawWidth)

        if topY == nil {
            ensureSpace(before + textHeight + after)
            y += before
        }

        let drawY = topY ?? y
        draw(
            text: text,
            font: level.font,
            color: level.color,
            at: drawX,
            width: drawWidth,
            topY: drawY
        )

        if topY == nil {
            y += textHeight + after
        }
        return textHeight
    }

    private mutating func fillWhiteBackground() {
        context.cgContext.setFillColor(SummaryPDFStyle.pageBackground.cgColor)
        context.cgContext.fill(pageRect)
    }

    private func height(for text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return ceil(rect.height)
    }

    private func textWidth(_ text: String, font: UIFont) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }

    @discardableResult
    private mutating func draw(
        text: String,
        font: UIFont,
        color: UIColor,
        at x: CGFloat,
        width: CGFloat,
        topY: CGFloat? = nil
    ) -> CGFloat {
        let drawY = topY ?? y
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let rect = CGRect(x: x, y: drawY, width: width, height: .greatestFiniteMagnitude)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
        let textHeight = height(for: text, font: font, width: width)
        if topY == nil {
            y += textHeight
        }
        return textHeight
    }
}

// MARK: - Visual style (print-ready white document)

private enum SummaryPDFStyle {
    static let pageBackground = UIColor.white
    static let primaryText = UIColor.black
    static let secondaryText = UIColor(white: 0.38, alpha: 1)
}

// MARK: - Share sheet item

struct SummaryPDFShareItem: Transferable, Sendable {
    let document: SummaryPDFDocument

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { item in
            let data = try SummaryPDFRenderer.render(document: item.document)
            let base = item.document.suggestedFileName.isEmpty ? "Health Summary" : item.document.suggestedFileName
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(base, isDirectory: false)
                .appendingPathExtension("pdf")
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
