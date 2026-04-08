import Foundation
import SpeechSessionTranscription

/// Thin public wrapper around `WhisperKitTranscriptionService` model-management APIs.
/// Exposed here so app-layer views only need to import `SpeechSessionFeatures`.
public enum WhisperKitModelSetup {
    /// Downloads and caches the model from HuggingFace. Safe to call multiple times;
    /// returns immediately if the model is already cached on-device.
    public static func downloadModel(_ modelName: String) async throws {
        try await WhisperKitTranscriptionService.downloadModel(modelName)
    }

    /// Returns `true` if the model is already cached on-device (no network needed).
    public static func isModelCached(_ modelName: String) async -> Bool {
        await WhisperKitTranscriptionService.isModelCached(modelName)
    }
}
