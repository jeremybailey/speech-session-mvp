import Foundation
import WhisperKit

/// Share in-flight preparation between Settings, imports and recordings. Concurrent
/// Hub downloads otherwise race to move the same `.incomplete` weights file.
actor SharedWhisperKitModel {
    static let shared = SharedWhisperKitModel()
    private var preparations: [String: Task<WhisperKit, Error>] = [:]
    private let prepare: @Sendable (String) async throws -> WhisperKit

    init(prepare: @escaping @Sendable (String) async throws -> WhisperKit = {
        try await WhisperKit(model: $0, prewarm: false, load: true, download: true)
    }) {
        self.prepare = prepare
    }

    func load(_ name: String) async throws -> WhisperKit {
        if let existing = preparations[name] {
            do { return try await existing.value }
            catch { throw ModelPreparationError.unavailable }
        }
        let prepare = self.prepare
        let task = Task { try await prepare(name) }
        preparations[name] = task
        do {
            let model = try await task.value
            preparations[name] = nil
            return model
        } catch {
            preparations[name] = nil
            throw ModelPreparationError.unavailable
        }
    }

    private enum ModelPreparationError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "The on-device transcription model could not be prepared. Check your connection and available storage, then download the model again in Settings."
        }
    }
}
