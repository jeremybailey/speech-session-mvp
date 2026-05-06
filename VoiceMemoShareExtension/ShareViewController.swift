import AVFoundation
import CoreMedia
import UIKit
import UniformTypeIdentifiers

/// Voice Memos → App Group (“export”). User opens CollectiveCare to “import”; the host app scans `SharedAudioImports` on foreground.
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
        suppliedURL: URL
    ) throws -> URL {
        let ext = suppliedURL.pathExtension.isEmpty ? "m4a" : suppliedURL.pathExtension
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: owned.path) {
            try FileManager.default.removeItem(at: owned)
        }
        try FileManager.default.copyItem(at: suppliedURL, to: owned)
        return owned
    }

    private func loadOwnedCopy(of provider: NSItemProvider, typeIdentifier: String) async throws -> URL {
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
                    let copied = try self.copySuppliedRepresentationToTemporaryFile(suppliedURL: suppliedURL)
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

    private func copyToSharedContainer(_ sourceURL: URL) throws -> URL {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let importsURL = containerURL.appendingPathComponent("SharedAudioImports", isDirectory: true)
        try FileManager.default.createDirectory(at: importsURL, withIntermediateDirectories: true)

        let fileExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
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
                    let owned = try await loadOwnedCopy(of: provider, typeIdentifier: typeIdentifier)
                    defer { try? FileManager.default.removeItem(at: owned) }

                    guard isPlausibleTranscribeableAudio(at: owned) else { continue }

                    _ = try copyToSharedContainer(owned)

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
            self.statusLabel.text = "Couldn’t read this audio."
            let alert = UIAlertController(
                title: "Import failed",
                message: "Export the memo from Voice Memos to Files, then use Upload in CollectiveCare.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
            self.present(alert, animated: true)
        }
    }
}
