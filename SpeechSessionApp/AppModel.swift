import Combine
import Foundation
import SpeechSessionFeatures
import SpeechSessionPersistence

@MainActor
final class AppModel: ObservableObject {
    let store: SessionStore
    let home: HomeViewModel
    let recording: RecordingViewModel

    init(store: SessionStore) {
        self.store = store
        self.home = HomeViewModel(store: store)
        self.recording = RecordingViewModel(store: store)
    }
}
