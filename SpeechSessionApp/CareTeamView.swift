import SwiftUI
import SpeechSessionPersistence

struct CareTeamEditor: View {
    @State var member: CareTeamMember
    @ObservedObject var model: HealthSummaryModel
    var onSaved: ((CareTeamMember) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var requestRecords = false
    @State private var remove = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Person") {
                    TextField("Name", text: $member.name).textContentType(.name)
                    TextField("Role or specialty", text: $member.role)
                    TextField("Clinic or organization", text: $member.organization).textContentType(.organizationName)
                }
                Section("Contact") {
                    TextField("Email", text: $member.email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Phone", text: $member.phone).textContentType(.telephoneNumber).keyboardType(.phonePad)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Address").font(.subheadline).bold()
                        TextField("Not recorded", text: Binding(get: { member.address ?? "" }, set: { member.address = $0 }), axis: .vertical)
                            .textContentType(.fullStreetAddress)
                    }
                }
                Section {
                    if let url = CareTeamMail.url(email: member.email) { Link("Email", destination: url) }
                    if !member.phone.isEmpty, let url = URL(string: "tel:" + member.phone.filter { $0.isNumber || $0 == "+" }) {
                        Link("Call", destination: url)
                    }
                    Button("Request my records") { requestRecords = true }
                } footer: { Text("Saving a contact does not give them access to your records.") }
                if model.snapshot.careTeam.contains(where: { $0.id == member.id }) {
                    Section { Button("Remove contact", role: .destructive) { remove = true } }
                }
                Section("Notes") { TextField("Anything you want to remember", text: $member.notes, axis: .vertical) }
                if !model.snapshot.careTeam.isEmpty && !member.sourceEntryIDs.isEmpty {
                    Section("Already in your care team?") {
                        ForEach(model.snapshot.careTeam.filter { $0.id != member.id }) { existing in
                            Button("Link to \(existing.name)") {
                                var linked = existing
                                linked.sourceEntryIDs = Array(Set(existing.sourceEntryIDs + member.sourceEntryIDs))
                                Task { if await model.save(linked) { onSaved?(linked); dismiss() } }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Care team details")
            .sheet(isPresented: $requestRecords) { RequestRecordsView(member: member) }
            .confirmationDialog("Remove this contact?", isPresented: $remove, titleVisibility: .visible) {
                Button("Remove contact", role: .destructive) {
                    Task { await model.deleteMember(member.id); if model.error == nil { dismiss() } }
                }
            } message: { Text("Your original records will be kept.") }
            .alert("Could not save", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        member.name = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { if await model.save(member) { onSaved?(member); dismiss() }; saving = false }
                    }.disabled(saving || member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

enum CareTeamMail {
    static func url(email: String, subject: String? = nil, body: String? = nil) -> URL? {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !email.contains(where: { $0.isWhitespace }), !email.contains("?") else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"; components.path = email
        var items: [URLQueryItem] = []
        if let subject { items.append(URLQueryItem(name: "subject", value: subject)) }
        if let body { items.append(URLQueryItem(name: "body", value: body)) }
        if !items.isEmpty { components.queryItems = items }
        return components.url
    }
}

struct RequestRecordsView: View {
    let member: CareTeamMember
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var years = 5
    @State private var copied = false
    @State private var mailUnavailable = false
    private var bodyText: String {
        "Hello \(member.name),\n\nI am organizing my health records so I can share appropriate context with my care team. Could you please let me know how to request a copy of my records from the past \(years) years?\n\nPlease let me know what identification or authorization you need and how the records can be provided securely.\n\nThank you."
    }
    var body: some View {
        NavigationStack {
            Form {
                Stepper("Past \(years) years", value: $years, in: 1...50)
                Section("Email draft") { Text(bodyText).textSelection(.enabled) }
                if let url = CareTeamMail.url(email: member.email, subject: "Request for my health records", body: bodyText) {
                    Button("Open email draft") { openURL(url) { accepted in mailUnavailable = !accepted } }
                }
                Button(copied ? "Draft copied" : "Copy draft") { UIPasteboard.general.string = bodyText; copied = true }
                if mailUnavailable || member.email.isEmpty { Text("You can copy this draft into your email app or your provider’s patient portal.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Request records")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Reuses contact identities; source-only contacts become saved contacts when selected.
struct PractitionerPicker: View {
    @ObservedObject var model: HealthSummaryModel
    let onSelect: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var editor: CareTeamMember?
    @State private var saving = false

    private var contacts: [CareTeamMember] {
        let linked = Set(model.snapshot.careTeam.flatMap(\.sourceEntryIDs))
        let extracted = model.facts.filter { $0.category == .practitionerContact && !$0.occurrences.contains(where: { linked.contains($0.id) }) }.map { fact in
            func field(_ labels: [String]) -> String {
                fact.displayEntry.fields.first { field in labels.contains { field.label.localizedCaseInsensitiveContains($0) } }?.value ?? ""
            }
            return CareTeamMember(id: fact.latest.id, name: field(["name"]).isEmpty ? fact.title : field(["name"]),
                role: field(["role", "specialty"]), organization: field(["organization", "clinic"]),
                email: field(["email"]), phone: field(["phone"]), address: field(["address"]),
                sourceEntryIDs: fact.occurrences.map(\.id))
        }
        return (model.snapshot.careTeam + extracted).filter {
            search.isEmpty || "\($0.name) \($0.role) \($0.organization)".localizedCaseInsensitiveContains(search)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Add practitioner", systemImage: "plus") { editor = CareTeamMember() }
                    Button("No linked practitioner") { onSelect(nil); dismiss() }
                }
                Section("Contacts") {
                    ForEach(contacts) { member in
                        Button {
                            saving = true
                            Task {
                                let saved = model.snapshot.careTeam.contains(where: { $0.id == member.id }) ? true : await model.save(member)
                                if saved {
                                    onSelect(member.id); dismiss()
                                }
                                saving = false
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(member.name).foregroundStyle(.primary)
                                Text([member.role, member.organization].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .disabled(saving)
            .searchable(text: $search, prompt: "Name, specialty or clinic")
            .navigationTitle("Choose practitioner")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $editor) { member in
                CareTeamEditor(member: member, model: model) { saved in onSelect(saved.id); dismiss() }
            }
            .alert("Could not save", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
}
