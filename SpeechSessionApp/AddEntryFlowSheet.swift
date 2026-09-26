import SwiftUI
import SpeechSessionPersistence

/// Every capture action is available in one sheet, without a drill-down menu.
struct AddEntryFlowSheet: View {
    @Binding var isPresented: Bool
    @State private var recordingIntent: SessionEntryIntent?
    @State private var importingAudio = false
    @State private var audioIntent: SessionEntryIntent = .clinicalVisit
    let onAudioRecord: (SessionEntryIntent) -> Void
    let onAudioImport: (SessionEntryIntent) -> Void
    let onPhotoCapture: () -> Void
    let onPhotoLibrary: () -> Void
    let onDocumentScan: () -> Void
    let onDocumentImport: () -> Void
    let onWriteDetail: () -> Void
    let onAddContact: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Record or add audio") {
                    Picker("Recording type", selection: $audioIntent) {
                        Text("Appointment").tag(SessionEntryIntent.clinicalVisit)
                        Text("Journal").tag(SessionEntryIntent.personalJournal)
                    }.pickerStyle(.segmented)
                    choice("Record and transcribe", icon: "mic.fill") { recordingIntent = audioIntent }
                    choice("Choose an audio file", icon: "waveform.badge.plus") { importingAudio = true }
                }
                Section("Add a document or photo") {
                    choice("Scan papers", icon: "doc.viewfinder") { dismissThen(onDocumentScan) }
                    choice("Choose a file", icon: "folder") { dismissThen(onDocumentImport) }
                    choice("Take a photo", icon: "camera") { dismissThen(onPhotoCapture) }
                    choice("Choose photos", icon: "photo") { dismissThen(onPhotoLibrary) }
                }
                Section("Add details yourself") {
                    choice("Write a health detail", icon: "square.and.pencil") { dismissThen(onWriteDetail) }
                    choice("Add a care team contact", icon: "person.badge.plus") { dismissThen(onAddContact) }
                }

            }
            .navigationTitle("Add record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { isPresented = false } }
            }
            .confirmationDialog("Before recording", isPresented: Binding(
                get: { recordingIntent != nil }, set: { if !$0 { recordingIntent = nil } }
            ), titleVisibility: .visible) {
                Button(recordingIntent == .clinicalVisit ? "Everyone present has agreed — record" : "Start my journal") {
                    let intent = recordingIntent ?? .personalJournal
                    recordingIntent = nil
                    dismissThen { onAudioRecord(intent) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your audio will be saved and turned into text. Ask everyone present before recording an appointment.") }
            .confirmationDialog("Transcribe this recording", isPresented: $importingAudio, titleVisibility: .visible) {
                Button("I have permission — choose audio") { dismissThen { onAudioImport(audioIntent) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Choose a recording you have permission to save and turn into text.") }
        }
    }

    private func choice(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
        }
    }

    private func dismissThen(_ action: @escaping () -> Void) {
        isPresented = false
        DispatchQueue.main.async(execute: action)
    }
}
