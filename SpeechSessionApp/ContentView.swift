import SwiftUI
import SpeechSessionPersistence

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var appModel: AppModel

    private enum AppTab: Hashable {
        case events
        case summary
    }

    /// Per-tab navigation path for the Entries stack.
    @State private var selectedTab: AppTab = .events
    @State private var navPath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $navPath) {
                HomeView(
                    home: appModel.home,
                    recording: appModel.recording,
                    store: appModel.store,
                    pendingSharedImportURL: $appModel.pendingSharedImportURL,
                    advanceSharedImportQueue: appModel.enqueuePendingSharedImportIfAvailable
                )
                .navigationDestination(for: Session.self) { session in
                    SessionDetailView(session: session, store: appModel.store)
                }
            }
            .tabItem {
                Label("Entries", systemImage: "waveform.circle.fill")
            }
            .tag(AppTab.events)

            GlobalHealthSummaryView(home: appModel.home, store: appModel.store)
                .tabItem {
                    Label("Summary", systemImage: "heart.text.square.fill")
                }
                .tag(AppTab.summary)
        }
        .onChange(of: appModel.pendingSharedImportURL) { _, newValue in
            guard newValue != nil else { return }
            selectedTab = .events
            navPath = NavigationPath()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            appModel.enqueuePendingSharedImportIfAvailable()
        }
    }
}
