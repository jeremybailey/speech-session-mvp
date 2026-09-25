import SwiftUI
import QuickLook
import SpeechSessionPersistence

/// Selection is the entire export input. Never reuse an overview or timeline from unselected data.
struct HealthShareView: View {
    @ObservedObject var model: HealthSummaryModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs = Set<String>()
    @State private var selectedAssets = Set<UUID>()
    @State private var includeHealthNumber = false
    @State private var exportURLs: [URL] = []
    @State private var preview = false
    @State private var sharing = false
    @State private var preparing = false
    @State private var error: String?
    @State private var directory: URL?

    private var selectedFacts: [HealthFact] { model.facts.filter { selectedIDs.contains($0.id) } }
    private var sourceSessions: [Session] {
        let ids = Set(selectedFacts.flatMap { $0.occurrences.compactMap(\.sourceSessionID) })
        return model.snapshot.sessions.filter { ids.contains($0.id) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await prepare() }
                    } label: {
                        HStack { if preparing { ProgressView() }; Text("Preview PDF and Share") }
                    }.disabled(selectedFacts.isEmpty || preparing)
                } footer: { Text("This is a dated copy. Once shared, it cannot be recalled or updated on the recipient’s device.") }
                Section {
                    Text("Choose the information you want to share. You will review a PDF before sharing it.")
                    Button(selectedIDs.count == model.facts.count ? "Clear selection" : "Select all details") {
                        selectedIDs = selectedIDs.count == model.facts.count ? [] : Set(model.facts.map(\.id))
                    }
                }
                ForEach(SummaryEntryCategory.allCases, id: \.self) { category in
                    let facts = model.facts.filter { $0.category == category }
                    if !facts.isEmpty {
                        let categoryIDs = Set(facts.map(\.id))
                        let selectedCount = selectedIDs.intersection(categoryIDs).count
                        Section {
                            ForEach(facts) { fact in
                                Toggle(isOn: Binding(get: { selectedIDs.contains(fact.id) }, set: {
                                    if $0 { selectedIDs.insert(fact.id) } else { selectedIDs.remove(fact.id) }
                                })) { Text(CareInstructionPresentation.applies(fact.latest) ? CareInstructionPresentation.instruction(fact.latest) : HealthStoryText.clean(fact.title)) }
                            }
                        } header: {
                            Toggle(isOn: Binding(
                                get: { selectedCount > 0 },
                                set: { enabled in
                                    if enabled { selectedIDs.formUnion(categoryIDs) }
                                    else { selectedIDs.subtract(categoryIDs) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.displayTitle)
                                    Text("\(selectedCount) of \(facts.count) selected")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                            .textCase(nil)
                            .accessibilityLabel(category.displayTitle)
                            .accessibilityValue("\(selectedCount) of \(facts.count) selected")
                        }
                    }
                }
                if !sourceSessions.isEmpty {
                    Section {
                        ForEach(sourceSessions) { session in
                            ForEach(session.sourceAssets ?? []) { asset in
                                Toggle(asset.displayName, isOn: Binding(get: { selectedAssets.contains(asset.id) }, set: {
                                    if $0 { selectedAssets.insert(asset.id) } else { selectedAssets.remove(asset.id) }
                                }))
                            }
                        }
                    } header: { Text("Original files (optional)") } footer: { Text("Original files may contain more information than the selected summary details. Only attach files you want the recipient to read in full.") }
                }
                if !model.snapshot.profile.personalHealthNumber.isEmpty {
                    Section { Toggle("Include my Personal Health Number", isOn: $includeHealthNumber) }
                }

                if let error { Text(error).foregroundStyle(.red) }
            }
            #if DEBUG
            .task {
                if ProcessInfo.processInfo.arguments.contains("--care-qa-pdf") && selectedIDs.isEmpty {
                    selectedIDs = Set(model.facts.map(\.id))
                    await prepare()
                    if let pdf = exportURLs.first { try? Data(contentsOf: pdf).write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("care-qa.pdf")) }
                }
            }
            #endif
            .navigationTitle("Choose what to share")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $preview) {
                NavigationStack {
                    if let url = exportURLs.first { HealthPDFPreview(url: url) }
                    else { ProgressView() }
                }
                .overlay(alignment: .bottom) {
                    HStack {
                        Button("Back") { preview = false }
                        Spacer()
                        Button("Share PDF") { sharing = true }.buttonStyle(.borderedProminent)
                    }.padding().background(.regularMaterial)
                }
                .sheet(isPresented: $sharing) { HealthActivitySheet(urls: exportURLs) }
            }
            .onDisappear { if let directory { try? FileManager.default.removeItem(at: directory) } }
        }
    }

    private func prepare() async {
        preparing = true; error = nil
        defer { preparing = false }
        let facts = selectedFacts
        let exportOverview = selectedIDs == Set(model.facts.map(\.id)) ? model.overview : nil
        let sessions = sourceSessions
        let chosenAssets = selectedAssets
        let healthNumber = includeHealthNumber ? model.snapshot.profile.personalHealthNumber : ""
        do {
            let root = await model.storageDirectory
            let result = try await Task.detached(priority: .userInitiated) { () -> (URL, [URL]) in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CollectiveCare-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                do {
                    let indices = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($0.element.id, $0.offset + 1) })
                    let sections = SummaryEntryCategory.allCases.compactMap { category -> SummaryPDFCategorySection? in
                        let matches = facts.filter { $0.category == category }
                        guard !matches.isEmpty else { return nil }
                        let groups = ["Current", "Completed", "Paused", "Non-current"].compactMap { status -> SummaryPDFStatusGroup? in
                            let selected = matches.filter { CareInstructionPresentation.status($0) == status }
                            guard !selected.isEmpty else { return nil }
                            let rows = selected.map { fact -> SummaryPDFEntryRow in
                                let entry = fact.displayEntry
                                var sourceKeys = Set<String>()
                                let sources = fact.occurrences.compactMap { occurrence -> SummaryPDFEntryRow? in
                                    let key = [occurrence.sourceSessionID?.uuidString ?? occurrence.id.uuidString,
                                        occurrence.supportingExcerpt ?? "", occurrence.evidence?.eventDate ?? "",
                                        occurrence.evidence?.practitioner ?? "", occurrence.evidence?.page.map(String.init) ?? ""].joined(separator: "|")
                                    guard sourceKeys.insert(key).inserted else { return nil }
                                    let index = occurrence.sourceSessionID.flatMap { indices[$0] }
                                    let label = index.map { "Record \($0)" } ?? "Added by you"
                                    let page = occurrence.evidence?.page.map { ", page \($0)" } ?? ""
                                    return SummaryPDFEntryRow(sentence: occurrence.supportingExcerpt.map { "Source excerpt: “" + $0 + "”" } ?? "Original record",
                                        dateText: occurrence.evidence?.eventDate ?? occurrence.relevantDate?.formatted(date: .abbreviated, time: .omitted) ?? "Event date unknown",
                                        practitionerText: occurrence.evidence?.practitioner ?? "Practitioner not specified",
                                        sourceCaption: label + page + (occurrence.evidence?.assessment?.admission == .sourceLinked ? " · Automated check incomplete" : ""), nestedSources: [])
                                }
                                let fields = HealthDetailPresentation.fields(entry).map { "\($0.label): \($0.value)" }.joined(separator: "; ")
                                let description = CareInstructionPresentation.applies(entry)
                                    ? ([CareInstructionPresentation.instruction(entry)] + CareInstructionPresentation.supportingText(entry)).joined(separator: " — ")
                                    : ([HealthStoryText.clean(entry.title)] + HealthDetailPresentation.remainingDetails(entry) + [fields]).filter { !$0.isEmpty }.joined(separator: " — ")
                                return SummaryPDFEntryRow(sentence: description,
                                    dateText: entry.evidence?.eventDate ?? entry.relevantDate?.formatted(date: .abbreviated, time: .omitted) ?? "Event date unknown",
                                    practitionerText: entry.evidence?.practitioner ?? "Practitioner not specified",
                                    sourceCaption: (fact.occurrences.count > 1 ? "\(fact.occurrences.count) source entries · " : "") + (fact.isReviewed ? "Reviewed by patient" : "Not reviewed by patient") + (fact.isAction ? " · \(CareInstructionPresentation.status(fact))" : ""), nestedSources: sources)
                            }
                            return SummaryPDFStatusGroup(title: status, rows: rows)
                        }
                        return SummaryPDFCategorySection(title: category.displayTitle, entryCount: matches.count, statusGroups: groups)
                    }
                    var sourceIndex: [String] = []
                    var attachments: [(SessionSourceAsset, UUID, String)] = []
                    for (index, session) in sessions.enumerated() {
                        let assets = (session.sourceAssets ?? []).filter { chosenAssets.contains($0.id) }
                        sourceIndex.append("Record \(index + 1): added \(session.date.formatted(date: .abbreviated, time: .omitted)). \(assets.isEmpty ? "Original not attached." : "Selected original files attached.")")
                        for (assetIndex, asset) in assets.enumerated() {
                            let suffix = URL(fileURLWithPath: asset.relativePath).pathExtension
                            let filename = "Record-\(index + 1)-file-\(assetIndex + 1)" + (suffix.isEmpty ? "" : ".\(suffix)")
                            attachments.append((asset, session.id, filename))
                        }
                    }
                    var legacy = [SummaryPDFLegacySection(title: "Source index", body: sourceIndex.joined(separator: "\n"))]
                    if !healthNumber.isEmpty { legacy.insert(.init(title: "Personal Health Number", body: healthNumber), at: 0) }
                    let document = SummaryPDFDocument(title: "Health Summary", subtitle: "Selected information · CollectiveCare",
                        generatedAt: Date(), overview: exportOverview, categorySections: sections, legacySections: legacy, timeline: [])
                    let data = try SummaryPDFRenderer.render(document: document)
                    let pdf = directory.appendingPathComponent("Health Summary.pdf")
                    try data.write(to: pdf, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    var urls = [pdf]
                    let sources = SessionSourceStore(storageDirectory: root)
                    for (asset, sessionID, filename) in attachments {
                        let destination = directory.appendingPathComponent(filename)
                        try FileManager.default.copyItem(at: sources.url(for: asset, sessionID: sessionID), to: destination)
                        urls.append(destination)
                    }
                    return (directory, urls)
                } catch { try? FileManager.default.removeItem(at: directory); throw error }
            }.value
            if let directory { try? FileManager.default.removeItem(at: directory) }
            directory = result.0; exportURLs = result.1; preview = true
        } catch { self.error = "The PDF could not be prepared. Check that the selected original files are available and try again." }
    }
}

struct HealthPDFPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct HealthActivitySheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
