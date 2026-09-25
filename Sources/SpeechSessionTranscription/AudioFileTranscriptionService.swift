import Foundation
import Speech
import AVFoundation
import WhisperKit

public enum AudioFileTranscriptionError: LocalizedError, Sendable {
    case noRecognizer
    case onDeviceNotSupported
    case emptyTranscript
    case fileTooLarge
    case invalidOpenAIURL
    case invalidServerResponse
    case openAIError(String)
    case responseParsingFailed

    public var errorDescription: String? {
        switch self {
        case .noRecognizer:
            return "Speech recognizer is not available for this language."
        case .onDeviceNotSupported:
            return "On-device speech recognition is not supported for this audio file."
        case .emptyTranscript:
            return "No speech was detected in the selected audio file."
        case .fileTooLarge:
            return "The selected audio file is too large for OpenAI Whisper. Choose a file under 25 MB."
        case .invalidOpenAIURL:
            return "Whisper: invalid API URL."
        case .invalidServerResponse:
            return "Whisper: invalid response."
        case .openAIError(let message):
            return message
        case .responseParsingFailed:
            return "Whisper: could not parse transcription response."
        }
    }
}

/// Successful sections remain available even when another section cannot be recognized.
public struct PartialAudioTranscriptionError: LocalizedError, Sendable {
    public let transcript: String
    public let reason: String
    public var errorDescription: String? { reason }
}

public enum AudioFileTranscriptionService {
    /// File-first, on-device-only recognition in short segments. The original file is never modified.
    public static func transcribeWithAppleSpeech(fileURL: URL, locale: Locale = .current) async throws -> String {
        try await transcribeSegments(fileURL: fileURL, maximumDuration: 45) { url in
            try await transcribeAppleSpeechFromFileOnce(fileURL: url, locale: locale, requiresOnDeviceRecognition: true)
        }
    }

    private static func transcribeSegments(
        fileURL: URL, maximumDuration: Double, operation: (URL) async throws -> String
    ) async throws -> String {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw AudioFileTranscriptionError.emptyTranscript }
        // Compress even short recordings: uncompressed CAF can exceed request size limits.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Transcription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var start: Double = 0
        var segments: [String] = []
        var failures: [String] = []
        do {
            while start < duration {
                try Task.checkCancellation()
                let end = min(start + maximumDuration, duration)
                let url = directory.appendingPathComponent("segment-\(segments.count).m4a")
                guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw AudioFileTranscriptionError.openAIError("The saved audio could not be prepared for transcription.")
                }
                exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                                 duration: CMTime(seconds: end - start, preferredTimescale: 600))
                if #available(iOS 18.0, macOS 15.0, *) {
                    try await exporter.export(to: url, as: .m4a)
                } else {
                    exporter.outputURL = url; exporter.outputFileType = .m4a
                    await exporter.export()
                    guard exporter.status == .completed else { throw exporter.error ?? AudioFileTranscriptionError.invalidServerResponse }
                }
                // Retry only this section; do not repeat sections already recognized.
                var lastError: Error?
                for attempt in 0..<2 {
                    do {
                        try Task.checkCancellation()
                        let text = try await operation(url)
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw AudioFileTranscriptionError.emptyTranscript
                        }
                        segments.append("--- Audio \(Int(start))–\(Int(end)) seconds ---\n\(text)")
                        lastError = nil
                        break
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        lastError = error
                        if attempt == 0 { try await Task.sleep(nanoseconds: 300_000_000) }
                    }
                }
                if let lastError {
                    failures.append("\(Int(start))–\(Int(end)) seconds: \(lastError.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: url)
                if end >= duration { break }
                start = end - 2 // Preserve words spanning an export boundary.
            }
        } catch {
            throw PartialAudioTranscriptionError(transcript: segments.joined(separator: "\n\n"),
                                                 reason: error.localizedDescription)
        }
        let transcript = segments.joined(separator: "\n\n")
        if !failures.isEmpty {
            throw PartialAudioTranscriptionError(transcript: transcript,
                reason: "Some audio sections could not be transcribed after retrying: " + failures.joined(separator: "; "))
        }
        return transcript
    }

    private static func transcribeAppleSpeechFromFileOnce(
        fileURL: URL,
        locale: Locale,
        requiresOnDeviceRecognition: Bool
    ) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AudioFileTranscriptionError.noRecognizer
        }
        if requiresOnDeviceRecognition {
            guard recognizer.supportsOnDeviceRecognition else {
                throw AudioFileTranscriptionError.onDeviceNotSupported
            }
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var didResume = false
            var task: SFSpeechRecognitionTask?

            func resumeOnce(_ result: Result<String, Error>) {
                guard !didResume else { return }
                didResume = true
                task?.cancel()
                continuation.resume(with: result)
            }

            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    resumeOnce(.failure(error))
                    return
                }

                guard let result else { return }
                guard result.isFinal else { return }

                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    resumeOnce(.failure(AudioFileTranscriptionError.emptyTranscript))
                } else {
                    resumeOnce(.success(text))
                }
            }
        }
    }

    public static func transcribeWithOpenAIWhisper(
        fileURL: URL,
        apiKey: String
    ) async throws -> String {
        try await transcribeWithOpenAIWhisper(fileURL: fileURL, credentials: .openAI(apiKey: apiKey))
    }

    public static func transcribeWithOpenAIWhisper(
        fileURL: URL,
        credentials: OpenAIWhisperHTTPCredentials
    ) async throws -> String {
        try await transcribeSegments(fileURL: fileURL, maximumDuration: 300) { url in
            try await transcribeOpenAIFileOnce(fileURL: url, credentials: credentials)
        }
    }

    private static func transcribeOpenAIFileOnce(fileURL: URL, credentials: OpenAIWhisperHTTPCredentials) async throws -> String {
        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize < 25 * 1024 * 1024 else {
            throw AudioFileTranscriptionError.fileTooLarge
        }
        let audio = try Data(contentsOf: fileURL)

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(contentType(for: fileURL))\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let auth = try await credentials.makeAuthorizationHeader()
        var request = URLRequest(url: credentials.endpointURL)
        request.httpMethod = "POST"
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 120
        let (data, response) = try await URLSession(configuration: config).data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AudioFileTranscriptionError.invalidServerResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let message = parseOpenAIError(data: data) ?? "Whisper HTTP \(http.statusCode)"
            throw AudioFileTranscriptionError.openAIError(message)
        }
        guard let decoded = try? JSONDecoder().decode(WhisperPlainJSONResponse.self, from: data) else {
            throw AudioFileTranscriptionError.responseParsingFailed
        }
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AudioFileTranscriptionError.emptyTranscript
        }
        return text
    }

    public static func transcribeWithWhisperKit(
        fileURL: URL,
        modelName: String
    ) async throws -> String {
        let whisperKit = try await WhisperKit(model: modelName)
        let results = try await whisperKit.transcribe(audioPath: fileURL.path)
        let text = results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AudioFileTranscriptionError.emptyTranscript
        }
        return text
    }

    private struct WhisperPlainJSONResponse: Decodable {
        let text: String
    }

    private static func parseOpenAIError(data: Data) -> String? {
        struct Body: Decodable {
            struct Err: Decodable { let message: String? }
            let error: Err?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        return body.error?.message
    }

    private static func contentType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "aac":
            return "audio/aac"
        case "aiff", "aif":
            return "audio/aiff"
        case "caf":
            return "audio/x-caf"
        case "m4a", "mp4":
            return "audio/mp4"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        default:
            return "application/octet-stream"
        }
    }
}
