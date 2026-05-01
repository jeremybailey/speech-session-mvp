import Foundation
import Speech
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

public enum AudioFileTranscriptionService {
    public static func transcribeWithAppleSpeech(
        fileURL: URL,
        locale: Locale = .current
    ) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AudioFileTranscriptionError.noRecognizer
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AudioFileTranscriptionError.onDeviceNotSupported
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let transcript = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
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

        return transcript
    }

    public static func transcribeWithOpenAIWhisper(
        fileURL: URL,
        apiKey: String
    ) async throws -> String {
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

        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw AudioFileTranscriptionError.invalidOpenAIURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
