import Foundation
import UIKit
import Vision
import VisionKit

/// On-device OCR for document scanner pages and imported photos — same Vision path for both.
struct DocumentScanService {

    /// Recognizes text in every page of `scan` and returns a single joined string.
    /// Pages are separated by a horizontal rule when there is more than one page.
    func transcribe(scan: VNDocumentCameraScan) async throws -> String {
        var images: [UIImage] = []
        images.reserveCapacity(scan.pageCount)
        for i in 0..<scan.pageCount {
            images.append(scan.imageOfPage(at: i))
        }
        return try await transcribe(images: images)
    }

    /// Recognizes text from one or more images (e.g. photo library picks) using the same pipeline as scans.
    func transcribe(images: [UIImage]) async throws -> String {
        guard !images.isEmpty else {
            throw DocumentScanError.noImages
        }

        var pages: [String] = []
        var readablePages = 0
        for (index, image) in images.enumerated() {
            try Task.checkCancellation()
            let pageText = (try? await recognizeText(in: image)) ?? ""
            let readable = !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if readable { readablePages += 1 }
            pages.append("--- Page \(index + 1) ---\n" + (readable ? pageText : "[Text unavailable for this page]"))
        }
        guard readablePages > 0 else { throw DocumentScanError.noTextFound }
        return pages.joined(separator: "\n\n")
    }

    // MARK: - Per-image OCR

    private func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = visionCGImage(from: image) else { return "" }
        let orientation = CGImagePropertyOrientation(imageOrientation: image.imageOrientation)

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
                try VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// UIImage from SwiftUI pickers sometimes has no `cgImage`; rasterize via the image's own draw pipeline.
    private func visionCGImage(from image: UIImage) -> CGImage? {
        if let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }
}

// MARK: - Orientation for Vision

private extension CGImagePropertyOrientation {
    init(imageOrientation orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}

// MARK: - Errors

enum DocumentScanError: LocalizedError {
    case noImages
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .noImages:
            return "No images were loaded from your selection."
        case .noTextFound:
            return "No readable text was found."
        }
    }
}
