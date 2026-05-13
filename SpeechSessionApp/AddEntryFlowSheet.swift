import SwiftUI
import SpeechSessionPersistence

// MARK: - Medium (step 1)

enum AddEntryMedium: Hashable {
    case audio
    case photo
    case documents

    var navigationTitle: String {
        switch self {
        case .audio: "Audio"
        case .photo: "Photos"
        case .documents: "Documents"
        }
    }
}

// MARK: - Full-screen sheet (Wallet-style drill-down)

/// Two-step add flow: choose medium → choose source (and audio intent). Large controls for readability.
struct AddEntryFlowSheet: View {
    @Binding var isPresented: Bool
    @State private var path = NavigationPath()
    @State private var audioIntent: SessionEntryIntent = .clinicalVisit

    let onAudioRecord: (SessionEntryIntent) -> Void
    let onAudioImport: (SessionEntryIntent) -> Void
    let onPhotoCapture: () -> Void
    let onPhotoLibrary: () -> Void
    let onDocumentScan: () -> Void
    let onDocumentImport: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            mediumSelectionRoot
                .navigationDestination(for: AddEntryMedium.self) { medium in
                    sourceSelectionPage(for: medium)
                }
        }
        .background(BrandPalette.canvas.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: isPresented) { _, isOpen in
            if isOpen { path = NavigationPath() }
        }
    }

    private func dismissThen(_ action: @escaping () -> Void) {
        isPresented = false
        DispatchQueue.main.async(execute: action)
    }

    // MARK: Step 1

    private var mediumSelectionRoot: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 14) {
                    AddEntryBigChoiceRow(
                        title: "Audio",
                        subtitle: "Record a visit or journal entry, or import an audio file",
                        systemImage: "waveform.circle.fill",
                        tint: .blue
                    ) {
                        path.append(AddEntryMedium.audio)
                    }

                    AddEntryBigChoiceRow(
                        title: "Photos",
                        subtitle: "Use the camera or library to read text from images",
                        systemImage: "photo.circle.fill",
                        tint: .green
                    ) {
                        path.append(AddEntryMedium.photo)
                    }

                    AddEntryBigChoiceRow(
                        title: "Documents",
                        subtitle: "Scan papers or import a PDF or text file",
                        systemImage: "doc.text.image",
                        tint: .orange
                    ) {
                        path.append(AddEntryMedium.documents)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BrandPalette.canvas)
        .navigationTitle("New entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    isPresented = false
                }
                .font(.body.weight(.medium))
            }
        }
    }

    // MARK: Step 2

    @ViewBuilder
    private func sourceSelectionPage(for medium: AddEntryMedium) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if medium == .audio {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("This recording is for")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Picker("", selection: $audioIntent) {
                            Text("Medical visit").tag(SessionEntryIntent.clinicalVisit)
                            Text("Personal journal").tag(SessionEntryIntent.personalJournal)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityLabel("This recording is for a medical visit or personal journal")
                    }
                }

                Text("How do you want to add it?")
                    .font(.title2.weight(.bold))
                    .padding(.top, medium == .audio ? 4 : 0)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 14) {
                    switch medium {
                    case .audio:
                        AddEntryBigChoiceRow(
                            title: "Record",
                            subtitle: "Speak now; your words are saved as text",
                            systemImage: "mic.circle.fill",
                            tint: .red
                        ) {
                            let intent = audioIntent
                            dismissThen { onAudioRecord(intent) }
                        }

                        AddEntryBigChoiceRow(
                            title: "Import audio file",
                            subtitle: "Choose a recording from Files or iCloud",
                            systemImage: "folder.circle.fill",
                            tint: .indigo
                        ) {
                            let intent = audioIntent
                            dismissThen { onAudioImport(intent) }
                        }

                    case .photo:
                        AddEntryBigChoiceRow(
                            title: "Take photos",
                            subtitle: "Use the regular camera; text is read from the picture",
                            systemImage: "camera.circle.fill",
                            tint: .green
                        ) {
                            dismissThen(onPhotoCapture)
                        }

                        AddEntryBigChoiceRow(
                            title: "Choose photos",
                            subtitle: "Pick existing pictures from your library",
                            systemImage: "photo.stack",
                            tint: .mint
                        ) {
                            dismissThen(onPhotoLibrary)
                        }

                    case .documents:
                        AddEntryBigChoiceRow(
                            title: "Scan papers",
                            subtitle: "Use the camera to scan pages",
                            systemImage: "doc.viewfinder",
                            tint: .orange
                        ) {
                            dismissThen(onDocumentScan)
                        }

                        AddEntryBigChoiceRow(
                            title: "Import file",
                            subtitle: "PDF or plain text from Files",
                            systemImage: "doc.badge.plus",
                            tint: .brown
                        ) {
                            dismissThen(onDocumentImport)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BrandPalette.canvas)
        .navigationTitle(medium.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Large touch-target row (~64pt min height, calendar / Wallet scale)

private struct AddEntryBigChoiceRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 60, height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(tint.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .liquidGlassCard(cornerRadius: 18)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(subtitle)
    }
}
