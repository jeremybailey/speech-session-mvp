import SwiftUI
import SpeechSessionFeatures
import SpeechSessionPersistence

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var appModel: AppModel
    var body: some View {
        NavigationStack {
            HomeView(home: appModel.home, recording: appModel.recording, store: appModel.store,
                     pendingSharedImportURL: $appModel.pendingSharedImportURL,
                     advanceSharedImportQueue: appModel.enqueuePendingSharedImportIfAvailable)
        }
        .environmentObject(appModel.health)
        .onChange(of: scenePhase) { _, phase in
            appModel.recording.setAppInBackground(phase != .active)
            if phase == .active { appModel.enqueuePendingSharedImportIfAvailable() }
        }
        .modifier(HealthErrorPresentation(model: appModel.health, home: appModel.home))
    }
}

private struct HealthErrorPresentation: ViewModifier {
    @ObservedObject var model: HealthSummaryModel
    @ObservedObject var home: HomeViewModel
    func body(content: Content) -> some View {
        content.alert("Please try again", isPresented: Binding(
            get: { model.error != nil || home.errorMessage != nil },
            set: { if !$0 { model.error = nil; home.errorMessage = nil } }
        )) {
            Button("OK") { model.error = nil; home.errorMessage = nil }
        } message: { Text(model.error ?? home.errorMessage ?? "") }
    }
}
