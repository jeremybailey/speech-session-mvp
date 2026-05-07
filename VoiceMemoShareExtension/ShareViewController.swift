import AVFoundation
import CoreMedia
import PDFKit
import UniformTypeIdentifiers
import UIKit

/// Share extension → App Group handoff for audio (Voice Memos), images (Photos), or PDF/text files.
final class ShareViewController: UIViewController {
    private let appGroupID = "group.com.CollectiveCare.pilot"

    /// Voice Memos often registers multiple audio UTIs; prefer AAC/MPEG-4 audio before generic/movie wrappers.
    private static let preferredAudioTypeIdentifiers: [String] = [
        "public.mpeg-4-audio",
        "com.apple.protected-mpeg-4-audio",
        "com.apple.m4a-audio",
        "public.aac-audio",
        "public.mp3",
        "com.apple.coreaudio-format",
        "public.wav",
        "public.aifc-audio",
        "public.aiff-audio",
        "public.audio",
        "public.mpeg-4",
        "com.apple.quicktime-movie",
    ]

    private static let preferredImageTypeIdentifiers: [String] = [
        UTType.heic.identifier,
        "public.heic",
        UTType.heif.identifier,
        UTType.jpeg.identifier,
        UTType.png.identifier,
        UTType.gif.identifier,
        UTType.livePhoto.identifier,
        UTType.image.identifier,
    ]

    private static let preferredDocumentTypeIdentifiers: [String] = [
        UTType.pdf.identifier,
        "com.adobe.pdf",
        UTType.plainText.identifier,
        UTType.utf8PlainText.identifier,
    ]

    private var didStartImport = false
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemGroupedBackground

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "Saving to CollectiveCare…"

        view.addSubview(spinner)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStartImport else { return }
        didStartImport = true
        Task { await runExportAndDismiss() }
    }

    private func copySuppliedRepresentationToTemporaryFile(
        suppliedURL: URL,
        preferredExtension fallbackExt: String
    ) throws -> URL {
        let ext = suppliedURL.pathExtension.isEmpty ? fallbackExt : suppliedURL.pathExtension
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: owned.path) {
            try FileManager.default.removeItem(at: owned)
        }
        try FileManager.default.copyItem(at: suppliedURL, to: owned)
        return owned
    }

    private func loadOwnedCopy(of provider: NSItemProvider, typeIdentifier: String, fallbackExtension: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { suppliedURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let suppliedURL else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    let copied = try self.copySuppliedRepresentationToTemporaryFile(
                        suppliedURL: suppliedURL,
                        preferredExtension: fallbackExtension
                    )
                    continuation.resume(returning: copied)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fileByteSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func isPlausibleTranscribeableAudio(at url: URL) -> Bool {
        let bytes = fileByteSize(at: url)
        guard bytes >= 2048 else { return false }

        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds >= 0.08 else { return false }

        guard !asset.tracks(withMediaType: .audio).isEmpty else { return false }
        return true
    }

    private func documentFallbackExtension(for typeIdentifier: String) -> String {
        if UTType(typeIdentifier)?.conforms(to: .pdf) == true { return "pdf" }
        if UTType(typeIdentifier)?.conforms(to: .plainText) == true
            || UTType(typeIdentifier)?.conforms(to: .utf8PlainText) == true
        {
            return "txt"
        }
        return "txt"
    }

    private func fallbackExtension(for typeIdentifier: String) -> String {
        if UTType(typeIdentifier)?.conforms(to: .jpeg) == true { return "jpg" }
        if UTType(typeIdentifier)?.conforms(to: .png) == true { return "png" }
        if UTType(typeIdentifier)?.conforms(to: .heic) == true || typeIdentifier.lowercased().contains("heic") { return "heic" }
        if UTType(typeIdentifier)?.conforms(to: .heif) == true { return "heif" }
        if UTType(typeIdentifier)?.conforms(to: .gif) == true { return "gif" }
        if UTType(typeIdentifier)?.conforms(to: .image) == true { return "heic" }
        return "jpg"
    }

    private func isPlausiblePhoto(at url: URL) -> Bool {
        guard fileByteSize(at: url) >= 512 else { return false }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else {
            return false
        }

        guard data.count <= 52_428_800 else { return false }

        guard UIImage(contentsOfFile: url.path) != nil || UIImage(data: data) != nil else {
            return false
        }
        return true
    }

    private func copyToSharedPhotoContainer(_ sourceURL: URL) throws -> URL {
        try copyToRelativeSharedContainer(sourceURL: sourceURL, subfolder: "SharedPhotoImports") { ext in
            if ext.lowercased() == "" { return "jpg" }
            return ext.lowercased()
        }
    }

    private func copyToSharedAudioContainer(_ sourceURL: URL) throws -> URL {
        try copyToRelativeSharedContainer(sourceURL: sourceURL, subfolder: "SharedAudioImports") { ext in
            ext.isEmpty ? "m4a" : ext
        }
    }

    private func copyToSharedDocumentContainer(_ sourceURL: URL, typeIdentifier: String) throws -> URL {
        let isPDF = UTType(typeIdentifier)?.conforms(to: .pdf) == true
        let allowedTextSuffixes: Set<String> = ["txt", "text", "md"]
        return try copyToRelativeSharedContainer(sourceURL: sourceURL, subfolder: "SharedDocumentImports") { ext in
            let lowered = ext.lowercased()
            if isPDF || lowered == "pdf" {
                return "pdf"
            }
            if lowered.isEmpty { return "txt" }
            return allowedTextSuffixes.contains(lowered) ? lowered : "txt"
        }
    }

    /// Copies imported bytes into Apps Group `{subfolder}/<uuid>.<ext>`.
    private func copyToRelativeSharedContainer(
        sourceURL: URL,
        subfolder: String,
        normalizedExtension: (String) -> String
    ) throws -> URL {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let importsURL = containerURL.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: importsURL, withIntermediateDirectories: true)

        let rawExtension = sourceURL.pathExtension.lowercased()
        let fileExtension = normalizedExtension(rawExtension)
        let destinationURL = importsURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func runExportAndDismiss() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        // Prefer images (Photos), then PDF/text files, then audio (Voice Memos).
        let imageOrdered = preferredImageIdentifiersForScanning(providers)

        if await tryExportImage(from: providers, orderedTypes: imageOrdered) {
            return
        }

        if await tryExportDocument(from: providers) {
            return
        }

        for provider in providers {
            let preferredMatches = Self.preferredAudioTypeIdentifiers.filter {
                provider.hasItemConformingToTypeIdentifier($0)
            }
            let typesForProvider: [String] = {
                if !preferredMatches.isEmpty { return preferredMatches }
                return provider.registeredTypeIdentifiers.filter { id in
                    UTType(id)?.conforms(to: .audio) == true
                }
            }()

            guard !typesForProvider.isEmpty else { continue }

            for typeIdentifier in typesForProvider {
                do {
                    let owned = try await loadOwnedCopy(
                        of: provider,
                        typeIdentifier: typeIdentifier,
                        fallbackExtension: "m4a"
                    )
                    defer { try? FileManager.default.removeItem(at: owned) }

                    guard isPlausibleTranscribeableAudio(at: owned) else { continue }

                    _ = try copyToSharedAudioContainer(owned)

                    await MainActor.run {
                        self.spinner.stopAnimating()
                        self.statusLabel.textAlignment = .center
                        self.statusLabel.text = "Saved.\nOpen CollectiveCare to transcribe."
                    }
                    try? await Task.sleep(for: .milliseconds(550))
                    await MainActor.run {
                        self.extensionContext?.completeRequest(returningItems: nil)
                    }
                    return
                } catch {}
            }
        }

        await MainActor.run {
            self.spinner.stopAnimating()
            self.statusLabel.text = "Couldn’t save this shared item."
            let alert = UIAlertController(
                title: "Import failed",
                message: "Share supports photos, PDFs/text, and Voice Memos audio.\nOr import from CollectiveCare.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
            self.present(alert, animated: true)
        }
    }

    private func preferredDocumentIdentifiersForScanning(_ providers: [NSItemProvider]) -> [String] {
        let seenMatches = Self.preferredDocumentTypeIdentifiers.filter { typeId in
            providers.contains { $0.hasItemConformingToTypeIdentifier(typeId) }
        }
        guard !seenMatches.isEmpty else { return [] }

        var appended: [String] = []
        for provider in providers {
            let dynamic = provider.registeredTypeIdentifiers.filter { id in
                guard !seenMatches.contains(id) else { return false }
                let t = UTType(id)
                guard t?.conforms(to: .pdf) == true
                    || t?.conforms(to: .plainText) == true
                    || t?.conforms(to: .utf8PlainText) == true else { return false }
                return true
            }
            appended.append(contentsOf: dynamic)
        }
        return Array(OrderedUniqueStrings(seenMatches + appended).values)
    }

    private static let maxDocumentHandoffBytes: Int64 = 52_428_800

    private func isPlausibleDocumentHandoff(at url: URL, typeIdentifier: String) -> Bool {
        let bytes = fileByteSize(at: url)
        guard bytes >= 1, bytes <= Self.maxDocumentHandoffBytes else { return false }

        if UTType(typeIdentifier)?.conforms(to: .pdf) == true {
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return false }
            return true
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else {
            return false
        }
        let sample = data.prefix(min(data.count, 65_536))
        let decoded = String(decoding: sample, as: UTF8.self)
        return !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func tryExportDocument(from providers: [NSItemProvider]) async -> Bool {
        let orderedTypes = preferredDocumentIdentifiersForScanning(providers)
        guard !orderedTypes.isEmpty else { return false }

        for provider in providers {
            let typesForProvider = orderedTypes.filter { provider.hasItemConformingToTypeIdentifier($0) }
            for typeIdentifier in typesForProvider {
                do {
                    let fallbackExt = documentFallbackExtension(for: typeIdentifier)
                    let owned = try await loadOwnedCopy(
                        of: provider,
                        typeIdentifier: typeIdentifier,
                        fallbackExtension: fallbackExt
                    )
                    defer { try? FileManager.default.removeItem(at: owned) }

                    guard isPlausibleDocumentHandoff(at: owned, typeIdentifier: typeIdentifier) else {
                        continue
                    }

                    _ = try copyToSharedDocumentContainer(owned, typeIdentifier: typeIdentifier)

                    await MainActor.run {
                        self.spinner.stopAnimating()
                        self.statusLabel.textAlignment = .center
                        self.statusLabel.text = "Saved.\nOpen CollectiveCare to extract text."
                    }
                    try? await Task.sleep(for: .milliseconds(550))
                    await MainActor.run {
                        self.extensionContext?.completeRequest(returningItems: nil)
                    }
                    return true
                } catch {}
            }
        }

        return false
    }

    /// De-duplicates image type identifiers in a stable order suitable for iterating every provider once per type bucket.
    private func preferredImageIdentifiersForScanning(_ providers: [NSItemProvider]) -> [String] {
        let seenMatches = Self.preferredImageTypeIdentifiers.filter { typeId in
            providers.contains { $0.hasItemConformingToTypeIdentifier(typeId) }
        }

        guard !seenMatches.isEmpty else { return [] }

        var appended: [String] = []
        for provider in providers {
            let dynamic = provider.registeredTypeIdentifiers.filter { id in
                UTType(id)?.conforms(to: .image) == true && !seenMatches.contains(id)
            }
            appended.append(contentsOf: dynamic)
        }

        let unique = OrderedUniqueStrings(seenMatches + appended)
        return Array(unique.values)
    }

    private func tryExportImage(from providers: [NSItemProvider], orderedTypes: [String]) async -> Bool {
        guard !orderedTypes.isEmpty else { return false }

        for provider in providers {
            let typesForProvider = orderedTypes.filter { provider.hasItemConformingToTypeIdentifier($0) }
            for typeIdentifier in typesForProvider {
                do {
                    let fallbackExt = fallbackExtension(for: typeIdentifier)
                    let owned = try await loadOwnedCopy(
                        of: provider,
                        typeIdentifier: typeIdentifier,
                        fallbackExtension: fallbackExt
                    )
                    defer { try? FileManager.default.removeItem(at: owned) }

                    guard isPlausiblePhoto(at: owned) else { continue }

                    _ = try copyToSharedPhotoContainer(owned)

                    await MainActor.run {
                        self.spinner.stopAnimating()
                        self.statusLabel.textAlignment = .center
                        self.statusLabel.text = "Saved.\nOpen CollectiveCare to extract text."
                    }
                    try? await Task.sleep(for: .milliseconds(550))
                    await MainActor.run {
                        self.extensionContext?.completeRequest(returningItems: nil)
                    }
                    return true
                } catch {}
            }
        }

        return false
    }
}

/// Small helper to preserve insertion order while de-duplicating.
private struct OrderedUniqueStrings: Sequence {
    private(set) var values: [String] = []
    init(_ items: some Sequence<String>) {
        var seen = Set<String>()
        for item in items where !seen.contains(item) {
            seen.insert(item)
            values.append(item)
        }
    }
    func makeIterator() -> Array<String>.Iterator { values.makeIterator() }
}
