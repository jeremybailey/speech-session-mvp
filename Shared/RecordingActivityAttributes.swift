import Foundation

/// Cross-process flags for Live Activity buttons (App Group + Darwin notify).
enum RecordingLiveActivityBridge {
    static let appGroupID = "group.com.CollectiveCare.pilot"
    private static let stopRequestedKey = "recordingLiveActivity.stopRequested"
    private static let startRequestedKey = "recordingLiveActivity.startRequested"

    static let stopNotificationName = "com.CollectiveCare.pilot.recording.stop" as CFString
    static let startNotificationName = "com.CollectiveCare.pilot.recording.start" as CFString

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func requestStop() {
        defaults?.set(Date().timeIntervalSince1970, forKey: stopRequestedKey)
        defaults?.synchronize()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(stopNotificationName),
            nil,
            nil,
            true
        )
    }

    static func requestStart() {
        defaults?.set(true, forKey: startRequestedKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(startNotificationName),
            nil,
            nil,
            true
        )
    }

    static func consumeStopRequest() -> Bool {
        guard let defaults else { return false }
        let token = defaults.double(forKey: stopRequestedKey)
        guard token > 0 else { return false }
        defaults.set(0, forKey: stopRequestedKey)
        defaults.synchronize()
        return true
    }

    static func clearPendingCommands() {
        defaults?.set(0, forKey: stopRequestedKey)
        defaults?.set(false, forKey: startRequestedKey)
        defaults?.synchronize()
    }

    static func consumeStartRequest() -> Bool {
        guard defaults?.bool(forKey: startRequestedKey) == true else { return false }
        defaults?.set(false, forKey: startRequestedKey)
        return true
    }
}

#if canImport(ActivityKit)
import ActivityKit

enum RecordingLiveActivityPhase: String, Codable, Hashable, Sendable {
    case recording
    case paused
    case transcribing
}

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var phase: RecordingLiveActivityPhase
        /// Anchor for `Text(_:, style: .timer)` while actively recording.
        var timerAnchor: Date
        /// Frozen elapsed seconds when paused or transcribing.
        var frozenElapsedSeconds: Int
    }

    var sessionTitle: String
}
#endif
