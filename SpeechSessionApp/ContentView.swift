import SwiftUI
import SpeechSessionPersistence

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var appModel: AppModel

    private enum AppTab: Hashable {
        case sessions
        case summary
    }

    /// Per-tab navigation path for the Sessions stack.
    @State private var selectedTab: AppTab = .sessions
    @State private var navPath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            // MARK: Sessions tab
            Tab("Sessions", systemImage: "waveform.circle.fill", value: .sessions) {
                NavigationStack(path: $navPath) {
                    HomeView(
                        home: appModel.home,
                        recording: appModel.recording,
                        store: appModel.store,
                        pendingSharedAudioURL: $appModel.pendingSharedAudioURL
                    )
                    .navigationDestination(for: Session.self) { session in
                        SessionDetailView(session: session, store: appModel.store)
                    }
                }
            }

            // MARK: Health Summary tab
            Tab("Summary", systemImage: "heart.text.square.fill", value: .summary) {
                GlobalHealthSummaryView(home: appModel.home, store: appModel.store)
            }
        }
        .onChange(of: appModel.pendingSharedAudioURL) { _, newValue in
            guard newValue != nil else { return }
            selectedTab = .sessions
            navPath = NavigationPath()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            appModel.enqueuePendingSharedImportIfAvailable()
        }
    }
}
