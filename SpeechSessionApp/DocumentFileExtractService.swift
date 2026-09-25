import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Reads plain-text files and extracts text from PDFs (embedded text plus Vision OCR fallback for image-only pages).
struct DocumentFileExtractService {

    private let ocr = DocumentScanService()

    func extractText(from url: URL) async throws -> String {
        let ext = url.pathExtension.lowercased()
        let isPDF = ext == "pdf" || UTType(filenameExtension: ext)?.conforms(to: .pdf) == true
        if isPDF {
            return try await extractFromPDF(at: url)
        }
        return try extractPlainText(from: url)
    }

    // MARK: - Plain text

    private func extractPlainText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DocumentFileExtractError.emptyContent
        }
        return text
    }

    // MARK: - PDF

    private func extractFromPDF(at url: URL) async throws -> String {
        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else {
            throw DocumentFileExtractError.unreadablePDF
        }

        var segments: [String] = []
        var readablePages = 0
        for pageIndex in 0..<pdf.pageCount {
            try Task.checkCancellation()
            let heading = "--- Page \(pageIndex + 1) ---"
            guard let page = pdf.page(at: pageIndex) else {
                segments.append("\(heading)\n[Text unavailable for this page]")
                continue
            }
            let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !layer.isEmpty {
                segments.append("\(heading)\n\(layer)")
                readablePages += 1
            } else if let image = Self.renderPDFPage(page), let text = try? await ocr.transcribe(images: [image]), !text.isEmpty {
                // Remove the single-image wrapper; preserve the original PDF page number.
                let body = text.replacingOccurrences(of: "--- Page 1 ---\n", with: "")
                segments.append("\(heading)\n\(body)")
                readablePages += 1
            } else { segments.append("\(heading)\n[Text unavailable for this page]") }
        }
        guard readablePages > 0 else { throw DocumentFileExtractError.emptyContent }
        return segments.joined(separator: "\n\n")
    }

    /// Renders a PDF page into a bitmap for Vision OCR — scale balances legibility vs memory use.
    private static func renderPDFPage(_ page: PDFPage, scale: CGFloat = 2) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0.5, bounds.height > 0.5 else { return nil }
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
    }
}

enum DocumentFileExtractError: LocalizedError {
    case unreadablePDF
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .unreadablePDF:
            return "Could not open the PDF."
        case .emptyContent:
            return "No readable text was found in the document."
        }
    }
}
