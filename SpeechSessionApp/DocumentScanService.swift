import Foundation
import UIKit
import Vision
import VisionKit

/// Converts a `VNDocumentCameraScan` into a plain-text transcript using on-device OCR.
struct DocumentScanService {

    /// Recognizes text in every page of `scan` and returns a single joined string.
    /// Pages are separated by a horizontal rule so the AI can distinguish them.
    func transcribe(scan: VNDocumentCameraScan) async throws -> String {
        var pages: [String] = []

        for i in 0..<scan.pageCount {
            let image = scan.imageOfPage(at: i)
            let pageText = try await recognizeText(in: image)
            if !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(pageText)
            }
        }

        guard !pages.isEmpty else {
            throw DocumentScanError.noTextFound
        }

        // Join pages; single-page scans produce no separator.
        return pages.enumerated().map { i, text in
            pages.count > 1 ? "--- Page \(i + 1) ---\n\(text)" : text
        }.joined(separator: "\n\n")
    }

    // MARK: - Per-page OCR

    private func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { return "" }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Errors

enum DocumentScanError: LocalizedError {
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .noTextFound:
            return "No readable text was found in the scanned document."
        }
    }
}
