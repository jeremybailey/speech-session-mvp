import AppIntents
import Foundation

/// Stops the active visit recording from the lock screen Live Activity.
struct StopRecordingLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Recording"

    func perform() async throws -> some IntentResult {
        RecordingLiveActivityBridge.requestStop()
        return .result()
    }
}

/// Opens the app to start a new recording (mic permission requires the app).
struct StartRecordingLiveActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        RecordingLiveActivityBridge.requestStart()
        return .result()
    }
}
