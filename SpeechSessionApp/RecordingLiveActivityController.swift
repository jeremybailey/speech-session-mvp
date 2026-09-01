import ActivityKit
import Foundation
import SpeechSessionFeatures

@MainActor
final class RecordingLiveActivityController {
    static let shared = RecordingLiveActivityController()

    private var activity: Activity<RecordingActivityAttributes>?

    private init() {}

    func sync(with recording: RecordingViewModel) async {
        let snapshot = recording.liveActivitySnapshot
        guard snapshot.isActive else {
            await endActivity()
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let content = contentState(from: snapshot)

        if let activity {
            await activity.update(ActivityContent(state: content, staleDate: nil))
            return
        }

        let attributes = RecordingActivityAttributes(sessionTitle: "Transcribing…")
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: content, staleDate: nil),
                pushType: nil
            )
        } catch {
            // Live Activities may be disabled in Settings.
        }
    }

    func endActivity() async {
        guard let activity else { return }
        let finalState = activity.content.state
        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .immediate
        )
        self.activity = nil
    }

    private func contentState(from snapshot: RecordingLiveActivitySnapshot) -> RecordingActivityAttributes.ContentState {
        let frozen = Int(snapshot.displayElapsed.rounded(.down))
        let anchor = snapshot.startedAt?.addingTimeInterval(snapshot.accumulatedPausedSeconds) ?? Date()

        return RecordingActivityAttributes.ContentState(
            phase: mapPhase(snapshot.phase),
            timerAnchor: anchor,
            frozenElapsedSeconds: frozen
        )
    }

    private func mapPhase(_ phase: RecordingLiveActivitySnapshot.Phase) -> RecordingLiveActivityPhase {
        switch phase {
        case .recording: return .recording
        case .paused: return .paused
        case .transcribing: return .transcribing
        }
    }
}
