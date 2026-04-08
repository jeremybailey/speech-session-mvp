import AVFoundation
import Foundation

/// Buffers the **full** recording as 16 kHz mono PCM16, then uploads **one** WAV to OpenAI Whisper when streaming ends.
///
/// **Why one shot:** Short periodic clips often start/stop mid-word and confuse Whisper (gibberish, “AAA…”, canned hallucinations).
/// On-device `SFSpeechRecognizer` is still better for **live** text; Whisper here is for a **whole-session** comparison transcript.
public final class WhisperTranscriptionService: @unchecked Sendable, TranscriptionStreaming {
    private let queue = DispatchQueue(label: "SpeechSessionTranscription.whisper")
    private let apiKey: String
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation
    public let events: AsyncStream<TranscriptionEvent>

    private var isStreaming = false
    private var pcmData = Data()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var capturedLocale = Locale.current
    private let session: URLSession

    /// One upload at a time (single file on stop; keeps `nw_connection` churn down).
    private let uploadLock = NSLock()
    private var uploadChain: Task<Void, Never>?

    /// OpenAI audio limit is 25 MB; 16 kHz mono Int16 ≈ 32 KB/s → leave headroom.
    private let maxPCMBytes = 24 * 1024 * 1024

    public init(apiKey: String) {
        self.apiKey = apiKey
        let (stream, cont) = AsyncStream<TranscriptionEvent>.makeStream()
        self.events = stream
        self.continuation = cont
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 1
        self.session = URLSession(configuration: config)
    }

    deinit {
        uploadLock.lock()
        uploadChain?.cancel()
        uploadChain = nil
        uploadLock.unlock()
        continuation.finish()
    }

    public func beginStreaming(locale: Locale) throws {
        try queue.sync {
            guard !isStreaming else {
                throw TranscriptionServiceError.alreadyStreaming
            }
            capturedLocale = locale
            isStreaming = true
            pcmData.removeAll(keepingCapacity: true)
            converter = nil
            inputFormat = nil
        }
    }

    public func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        queue.sync {
            guard isStreaming else { return }
            let chunk = convertToPCM16Mono16k(buffer) ?? convertFloatPCMToPCM16Mono16k(buffer)
            guard let chunk, !chunk.isEmpty else { return }
            if pcmData.count < maxPCMBytes {
                let take = min(chunk.count, maxPCMBytes - pcmData.count)
                pcmData.append(chunk.prefix(take))
            }
        }
    }

    public func endStreaming() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStreaming = false
            let rest = self.pcmData
            self.pcmData.removeAll(keepingCapacity: false)
            guard !rest.isEmpty else {
                self.yieldToMain(.error("Whisper: no audio was captured. Try on-device mode if this keeps happening."))
                return
            }
            self.enqueueUpload(pcm: rest)
        }
    }

    private func enqueueUpload(pcm: Data) {
        uploadLock.lock()
        let previous = uploadChain
        // Strong `self` through the upload so `weak` never drops the request silently (that caused endless “Transcribing…”).
        uploadChain = Task { [self] in
            if let previous {
                await previous.value
            }
            await performUpload(pcm: pcm)
        }
        uploadLock.unlock()
    }

    private func yieldToMain(_ event: TranscriptionEvent) {
        Task { @MainActor in
            continuation.yield(event)
        }
    }

    // MARK: - Audio conversion

    private func outputFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )
    }

    private func ensureConverter(for input: AVAudioFormat) -> AVAudioConverter? {
        if let c = converter, let inf = inputFormat, inf.isEqual(input) {
            return c
        }
        guard let out = outputFormat() else { return nil }
        guard let conv = AVAudioConverter(from: input, to: out) else { return nil }
        conv.sampleRateConverterQuality = .max
        inputFormat = input
        converter = conv
        return conv
    }

    private func convertToPCM16Mono16k(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let conv = ensureConverter(for: buffer.format) else { return nil }
        let outFormat = conv.outputFormat
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = max(
            AVAudioFrameCount(1024),
            AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 64)
        )

        var outAccum = Data()
        var inputDelivered = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputDelivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputDelivered = true
            outStatus.pointee = .haveData
            return buffer
        }

        var iterations = 0
        while iterations < 256 {
            iterations += 1
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
                return outAccum.isEmpty ? nil : outAccum
            }
            var error: NSError?
            let status = conv.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
            if error != nil {
                return outAccum.isEmpty ? nil : outAccum
            }
            if outBuf.frameLength > 0, let ch0 = outBuf.int16ChannelData {
                let n = Int(outBuf.frameLength) * MemoryLayout<Int16>.size
                outAccum.append(Data(bytes: ch0.pointee, count: n))
            }
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return outAccum.isEmpty ? nil : outAccum
            case .error:
                return outAccum.isEmpty ? nil : outAccum
            @unknown default:
                return outAccum.isEmpty ? nil : outAccum
            }
        }
        return outAccum.isEmpty ? nil : outAccum
    }

    /// Float tap fallback: linear interpolation resample + mono downmix. Nearest-neighbor badly aliases speech.
    private func convertFloatPCMToPCM16Mono16k(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return nil }
        guard let ch = buffer.floatChannelData else { return nil }
        let nch = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard frames > 0, nch >= 1 else { return nil }

        let srcRate = buffer.format.sampleRate
        let dstRate = 16_000.0
        let ratio = srcRate / dstRate
        let outFrames = max(1, Int(floor(Double(frames) / ratio)))
        var samples = [Int16](repeating: 0, count: outFrames)

        func lerp(_ c: Int, _ pos: Double) -> Float {
            let j = min(max(pos, 0), Double(frames - 1))
            let j0 = Int(floor(j))
            let j1 = min(j0 + 1, frames - 1)
            let frac = Float(j - Double(j0))
            return ch[c][j0] + frac * (ch[c][j1] - ch[c][j0])
        }

        for i in 0..<outFrames {
            let srcPos = Double(i) * ratio
            var sum: Float = 0
            for c in 0..<nch {
                sum += lerp(c, srcPos)
            }
            let avg = sum / Float(nch)
            let clipped = max(-1, min(1, avg))
            samples[i] = Int16((clipped * 32_767).rounded())
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    // MARK: - Networking

    private func performUpload(pcm: Data) async {
        let prepared = Self.normalizePCM16ForSpeech(pcm)
        let wav = Self.buildWAV(pcm16Mono: prepared, sampleRate: 16_000)
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!
        )
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)
        // Omit `language` so Whisper auto-detects; a wrong forced code often yields gibberish.
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            yieldToMain(.error("Whisper: invalid API URL."))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                yieldToMain(.error("Whisper: invalid response"))
                return
            }
            guard (200 ... 299).contains(http.statusCode) else {
                let msg = Self.parseOpenAIError(data: data) ?? "Whisper HTTP \(http.statusCode)"
                yieldToMain(.error(msg))
                return
            }
            guard let decoded = try? JSONDecoder().decode(WhisperPlainJSONResponse.self, from: data) else {
                yieldToMain(.error("Whisper: could not parse transcription response"))
                return
            }
            let trimmed = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                yieldToMain(.error("Whisper returned empty text."))
                return
            }
            guard !Self.isSpammyOrHallucinatedTranscript(trimmed) else {
                yieldToMain(.error("Whisper output looked like noise and was skipped. Try on-device mode."))
                return
            }
            yieldToMain(.chunkFinalized(trimmed))
        } catch {
            yieldToMain(.error(error.localizedDescription))
        }
    }

    private struct WhisperPlainJSONResponse: Decodable {
        let text: String
    }

    private static func isSpammyOrHallucinatedTranscript(_ text: String) -> Bool {
        let collapsed = text.filter { !$0.isWhitespace && !$0.isNewline }
        guard collapsed.count >= 5 else { return false }
        if Set(collapsed).count == 1 { return true }
        if collapsed.count >= 10 {
            let uniqueRatio = Double(Set(collapsed).count) / Double(collapsed.count)
            if uniqueRatio < 0.06 { return true }
        }
        var run = 0
        var last: Character?
        var maxRun = 0
        for c in collapsed {
            if c == last {
                run += 1
            } else {
                maxRun = max(maxRun, run)
                run = 1
                last = c
            }
        }
        maxRun = max(maxRun, run)
        if maxRun >= 7, Double(maxRun) / Double(collapsed.count) >= 0.65 { return true }
        return false
    }

    private static func parseOpenAIError(data: Data) -> String? {
        struct Body: Decodable {
            struct Err: Decodable { let message: String? }
            let error: Err?
        }
        guard let b = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        return b.error?.message
    }

    /// Boosts quiet iOS mic captures toward a stable peak so Whisper isn’t decoding near-silence noise.
    private static func normalizePCM16ForSpeech(_ pcm: Data) -> Data {
        guard pcm.count >= MemoryLayout<Int16>.size else { return pcm }
        let n = pcm.count / MemoryLayout<Int16>.size
        var peak: Int16 = 0
        pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                let a = abs(p[i])
                if a > peak { peak = a }
            }
        }
        guard peak > 0 else { return pcm }
        let target: Double = 26_000
        var gain = target / Double(peak)
        gain = min(gain, 5.0)
        if gain <= 1.02 { return pcm }
        var out = Data(count: pcm.count)
        out.withUnsafeMutableBytes { rawOut in
            let dst = rawOut.bindMemory(to: Int16.self)
            pcm.withUnsafeBytes { rawIn in
                let src = rawIn.bindMemory(to: Int16.self)
                for i in 0..<n {
                    let v = Double(src[i]) * gain
                    dst[i] = Int16(max(-32_768, min(32_767, v.rounded())))
                }
            }
        }
        return out
    }

    private static func buildWAV(pcm16Mono: Data, sampleRate: UInt32) -> Data {
        let dataSize = UInt32(pcm16Mono.count)
        let riffPayload = UInt32(36) + dataSize
        var d = Data()
        d.append(contentsOf: "RIFF".utf8)
        d.append(riffPayload.littleEndianData)
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        d.append(UInt32(16).littleEndianData)
        d.append(UInt16(1).littleEndianData)
        d.append(UInt16(1).littleEndianData)
        d.append(sampleRate.littleEndianData)
        let byteRate = sampleRate * 2
        d.append(byteRate.littleEndianData)
        d.append(UInt16(2).littleEndianData)
        d.append(UInt16(16).littleEndianData)
        d.append(contentsOf: "data".utf8)
        d.append(dataSize.littleEndianData)
        d.append(pcm16Mono)
        return d
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var v = self.littleEndian
        return Swift.withUnsafeBytes(of: &v) { Data($0) }
    }
}
