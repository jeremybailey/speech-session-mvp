import XCTest
import AVFoundation
@testable import SpeechSessionTranscription

final class SavedAudioTranscriptionCaptureTests: XCTestCase {
    func testCaptureEndsWithoutStartingModelOrEmittingTranscript() async throws {
        let capture = SavedAudioTranscriptionCapture()
        try capture.beginStreaming(locale: Locale(identifier: "en_US"))
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        capture.appendBuffer(buffer)
        capture.endStreaming()
        var count = 0
        for await _ in capture.events { count += 1 }
        XCTAssertEqual(count, 0, "Only the saved-file pass may produce a final transcript")
    }
}

private actor PreparationCounter {
    var count = 0
    func increment() { count += 1 }
}

extension SavedAudioTranscriptionCaptureTests {
    func testConcurrentPreparationSharesFailureAndAllowsRetryWithoutLeakingPaths() async {
        let counter = PreparationCounter()
        let loader = SharedWhisperKitModel { _ in
            await counter.increment()
            try await Task.sleep(nanoseconds: 100_000_000)
            throw NSError(domain: NSCocoaErrorDomain, code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "/private/patient/model.incomplete"])
        }
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do { _ = try await loader.load("test-model"); return "unexpected success" }
                    catch { return error.localizedDescription }
                }
            }
            for await message in group {
                XCTAssertTrue(message.contains("Settings"))
                XCTAssertFalse(message.contains("/private"))
                XCTAssertFalse(message.contains("incomplete"))
            }
        }
        let firstCount = await counter.count
        XCTAssertEqual(firstCount, 1)
        do { _ = try await loader.load("test-model"); XCTFail("Expected failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("/private")) }
        let retryCount = await counter.count
        XCTAssertEqual(retryCount, 2, "A failed preparation must not poison retries")
    }
}
