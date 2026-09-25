import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLiveActivityLockView(context: context)
                .activityBackgroundTint(LiveActivityBrand.plumBackground)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Image(systemName: "heart.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LiveActivityBrand.plumAccent)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Transcribing…")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(LiveActivityBrand.plumAccent)
                            timerText(for: context.state)
                                .font(.subheadline.monospacedDigit().weight(.medium))
                                .foregroundStyle(.white)
                        }

                        Spacer(minLength: 0)

                        liveActivityControl(for: context.state.phase)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                Image(systemName: "heart.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LiveActivityBrand.plumAccent)
            } compactTrailing: {
                timerText(for: context.state)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LiveActivityBrand.plumAccent)
                    .frame(maxWidth: 42, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } minimal: {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(LiveActivityBrand.plumAccent)
            }
        }
    }

    @ViewBuilder
    private func liveActivityControl(for phase: RecordingLiveActivityPhase) -> some View {
        switch phase {
        case .recording:
            Button(intent: StopRecordingLiveActivityIntent()) {
                Image(systemName: "stop.fill")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.borderless)
            .tint(LiveActivityBrand.copper)
        case .paused:
            Button(intent: StartRecordingLiveActivityIntent()) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .tint(LiveActivityBrand.plumAccentMuted)
        case .transcribing:
            ProgressView()
                .controlSize(.mini)
                .tint(LiveActivityBrand.plumAccent)
        }
    }

    @ViewBuilder
    private func timerText(for state: RecordingActivityAttributes.ContentState) -> some View {
        switch state.phase {
        case .recording:
            Text(state.timerAnchor, style: .timer)
        case .paused, .transcribing:
            Text(formattedElapsed(state.frozenElapsedSeconds))
        }
    }

    private func formattedElapsed(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct RecordingLiveActivityLockView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(LiveActivityBrand.plumAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Transcribing…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LiveActivityBrand.plumAccent)
                timerLine
                    .font(.title3.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white)
            }

            Spacer(minLength: 8)

            controlButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var timerLine: some View {
        switch context.state.phase {
        case .recording:
            Text(context.state.timerAnchor, style: .timer)
        case .paused, .transcribing:
            Text(formattedElapsed(context.state.frozenElapsedSeconds))
        }
    }

    @ViewBuilder
    private var controlButton: some View {
        switch context.state.phase {
        case .recording:
            Button(intent: StopRecordingLiveActivityIntent()) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(LiveActivityBrand.copper)
            .foregroundStyle(LiveActivityBrand.plumAccent)
        case .paused:
            Button(intent: StartRecordingLiveActivityIntent()) {
                Label("Open", systemImage: "arrow.up.forward.app")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(LiveActivityBrand.plumAccent)
        case .transcribing:
            ProgressView()
                .tint(LiveActivityBrand.plumAccent)
        }
    }

    private func formattedElapsed(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
