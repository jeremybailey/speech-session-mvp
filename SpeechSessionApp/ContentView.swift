import SwiftUI
import SpeechSessionFeatures
import SpeechSessionPersistence

extension Notification.Name {
    static let storyHistoryCleared = Notification.Name("StoryLabHistoryCleared")
}

struct ContentView: View {
    @State private var storyGeneration = UUID()
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var appModel: AppModel
    var body: some View {
        StoryLabView(appModel:appModel)
        .id(storyGeneration)
        .onReceive(NotificationCenter.default.publisher(for: .storyHistoryCleared)) { _ in storyGeneration = UUID() }
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
