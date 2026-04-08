import AVFoundation
import Foundation
import WhisperKit

/// On-device transcription using WhisperKit (Core ML / Apple Neural Engine).
/// Records all audio then runs a single transcription pass when `endStreaming()` is called —
/// identical batch pattern to `WhisperTranscriptionService` but fully private/offline.
public final class WhisperKitTranscriptionService: @unchecked Sendable, TranscriptionStreaming {
    public let events: AsyncStream<TranscriptionEvent>
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation

    private let modelName: String
    private var whisperKit: WhisperKit?
    private var isStreaming = false

    // Accumulated 16 kHz mono PCM-16 audio (same conversion path as WhisperTranscriptionService)
    private var pcmData = Data()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private let lock = NSLock()

    public init(modelName: String = "openai_whisper-base.en") {
        self.modelName = modelName
        var cont: AsyncStream<TranscriptionEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    // MARK: - TranscriptionStreaming

    public func beginStreaming(locale: Locale) throws {
        lock.withLock {
            pcmData = Data()
            converter = nil
            isStreaming = true
        }
        // Load the model using WhisperKit's default init (handles cache + incremental downloads).
        Task {
            do {
                let wk = try await WhisperKit(model: modelName)
                lock.withLock { self.whisperKit = wk }
            } catch {
                continuation.yield(.error(
                    "WhisperKit failed to load: \(error.localizedDescription). " +
                    "Try downloading the model again in Settings."
                ))
                continuation.finish()
            }
        }
    }

    // MARK: - Model management (call from Settings before recording)

    /// Downloads and fully loads the model so subsequent recordings need no network access.
    /// Safe to call multiple times — returns immediately if already cached and loaded.
    public static func downloadModel(_ modelName: String) async throws {
        // prewarm: false avoids the extra GPU warm-up; load: true ensures all files are fetched
        // and compiled so beginStreaming can load instantly from the local cache.
        _ = try await WhisperKit(model: modelName, prewarm: false, load: true, download: true)
    }

    /// Returns `true` if the model folder exists in WhisperKit's local cache.
    public static func isModelCached(_ modelName: String) async -> Bool {
        // Check the HuggingFace hub cache directory that WhisperKit uses.
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let modelDir = docs
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(modelName)
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    public func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard isStreaming else { return }
            convertAndAccumulate(buffer)
        }
    }

    public func endStreaming() {
        let data: Data = lock.withLock {
            isStreaming = false
            return pcmData
        }

        Task {
            // Wait for model to finish loading (it started in beginStreaming).
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                let loaded = lock.withLock { self.whisperKit != nil }
                if loaded { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            guard let wk = lock.withLock({ self.whisperKit }) else {
                continuation.yield(.error("WhisperKit model did not load in time."))
                continuation.finish()
                return
            }

            guard data.count > 3_200 else { // < ~0.1 s of audio at 16 kHz
                continuation.yield(.error("Recording was too short to transcribe."))
                continuation.finish()
                return
            }

            // Write to a temp WAV so WhisperKit can read and resample internally.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".wav")
            let wav = buildWAV(pcm16Mono: data, sampleRate: 16_000)
            do {
                try wav.write(to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }

                let results = try await wk.transcribe(audioPath: tempURL.path)
                let text = results
                    .map { $0.text }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    continuation.yield(.chunkFinalized(text))
                } else {
                    continuation.yield(.error("WhisperKit returned no speech. Check microphone level and try again."))
                }
            } catch {
                continuation.yield(.error("WhisperKit transcription failed: \(error.localizedDescription)"))
            }
            continuation.finish()
        }
    }

    // MARK: - Audio conversion (mirrors WhisperTranscriptionService)

    private func convertAndAccumulate(_ buffer: AVAudioPCMBuffer) {
        let inputFormat = buffer.format
        if converter == nil || converter!.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        }
        guard let cv = converter else { return }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }

        var inputConsumed = false
        let status = cv.convert(to: outBuf, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let ch0 = outBuf.int16ChannelData else { return }
        let n = Int(outBuf.frameLength) * MemoryLayout<Int16>.size
        pcmData.append(Data(bytes: ch0.pointee, count: n))
    }

    // MARK: - WAV builder (mirrors WhisperTranscriptionService)

    private func buildWAV(pcm16Mono data: Data, sampleRate: UInt32) -> Data {
        let byteRate = sampleRate * 2
        var wav = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: "RIFF".utf8); le32(UInt32(36 + data.count))
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8); le32(16); le16(1); le16(1)
        le32(sampleRate); le32(byteRate); le16(2); le16(16)
        wav.append(contentsOf: "data".utf8); le32(UInt32(data.count))
        wav.append(data)
        return wav
    }
}
