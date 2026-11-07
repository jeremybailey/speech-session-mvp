import SwiftUI
import SpeechSessionPersistence
import SpeechSessionFeatures

@MainActor final class StoryLabModel: ObservableObject {
    @Published var workspace = StoryWorkspace()
    @Published var records: [Session] = []
    @Published var error: String?
    @Published var busy = false
    @Published var evidence: [StoryEvidence] = []
    let store: SessionStore
    private var edits: [UUID:Task<Void,Never>] = [:]
    init(store:SessionStore) {self.store = store}
    func reload() async {
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--storylab-fixture"),try await store.loadAll().isEmpty {
                let id=UUID()
                var care=SummaryEntry(category:.carePlan,title:"Walk for ten minutes if comfortable",sourceSessionID:id,sourceExcerpt:"Walk for ten minutes if comfortable",origin:.userAdded)
                var evidence=ClinicalEvidence();evidence.careInstruction=CareInstruction(instruction:care.title,schedule:"Daily",isRecurring:true);care.evidence=evidence
                try await store.save([Session(id:id,transcript:"I have neck discomfort after sitting. My clinician recommended walking for ten minutes if comfortable.",title:"Synthetic visit",summaryEntries:[SummaryEntry(category:.symptoms,title:"I have neck discomfort after sitting.",sourceSessionID:id,sourceExcerpt:"I have neck discomfort after sitting.",origin:.userAdded),care])])
            }
            #endif
            try await store.synchronizeStory();workspace = try await store.storyWorkspace();records = try await store.loadAll()}
        catch {self.error = error.localizedDescription}
    }
    func edit(_ block:StoryBlock,text:String,auth:KindeAuthManager) {
        if let i=workspace.blocks.firstIndex(where:{$0.id == block.id}) {workspace.blocks[i].text=text}
        edits[block.id]?.cancel()
        edits[block.id]=Task {
            do {
                guard !Task.isCancelled else {return}
                _ = try await store.editStoryBlock(block.id,text:text)
                try await Task.sleep(nanoseconds:2_000_000_000)
                try Task.checkCancellation()
                await reconcile(auth:auth)
            } catch is CancellationError {} catch {self.error=error.localizedDescription}
        }
    }
    func request(id:UUID,kind:String,revision:Int,before:String,after:String,targets:[String],auth:KindeAuthManager) async throws -> [String:Any] {
        let sources = try await store.storyEvidence(query:after,limit:100)
        let allFacts = try await store.storyEvidence(query:"",limit:200)
        let selected = Dictionary((sources+allFacts.filter{targets.contains($0.id)}).map{($0.id,$0)},uniquingKeysWith: {a,_ in a}).values.sorted{$0.id<$1.id}
        let endpoint = URL(string:(Bundle.main.object(forInfoDictionaryKey:"CloudOpenAIBaseURL") as? String ?? "")+"/v1/health-processing/story-operations")!
        var payload:[String:Any] = ["id":id.uuidString.lowercased(),"version":"story-v1","kind":kind,"baseRevision":revision,"before":before,"after":after,"targetIDs":targets,"evidence":try JSONSerialization.jsonObject(with:JSONEncoder().encode(Array(selected)))]
        let encoded=String(decoding:try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys),as:UTF8.self)
        if let saved=try await store.storyRequestBody(id,proposed:encoded),let value=try JSONSerialization.jsonObject(with:Data(saved.utf8)) as? [String:Any] {payload=value}
        let savedEvidence=try JSONDecoder().decode([StoryEvidence].self,from:JSONSerialization.data(withJSONObject:payload["evidence"] ?? []))
        var first=true
        for _ in 0..<100 {
            try Task.checkCancellation()
            let current = try await store.storyWorkspace()
            if current.edits.contains(where: {$0.id == id && ["cancelled","undone","superseded"].contains($0.state)}) || current.messages.contains(where: {$0.id == id && $0.state == "cancelled"}) {throw CancellationError()}
            var req=URLRequest(url:first ? endpoint:URL(string:endpoint.absoluteString+"?id="+id.uuidString.lowercased())!)
            req.httpMethod=first ? "POST":"GET";req.timeoutInterval=30
            req.setValue("Bearer "+(try await auth.freshAccessToken()),forHTTPHeaderField:"Authorization")
            if first {req.setValue("application/json",forHTTPHeaderField:"Content-Type");req.httpBody=try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys)}
            let (data,response)=try await URLSession.shared.data(for:req)
            guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {throw URLError(.badServerResponse)}
            let result=try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
            if result["state"] as? String == "completed", let output=result["result"] as? [String:Any] {self.evidence=savedEvidence;return output}
            if ["blocked","cancelled","failed","invalid_result","budget_exhausted"].contains(result["state"] as? String ?? "") {throw URLError(.cannotParseResponse)}
            first=false;try await Task.sleep(nanoseconds:3_000_000_000)
        }
        throw URLError(.timedOut)
    }
    func reconcile(auth:KindeAuthManager) async {
        guard !busy else {return};busy=true;defer{busy=false}
        do {
            let pending=try await store.storyWorkspace().edits.filter{$0.state == "queued"}
            for edit in pending {
                let value=try await request(id:edit.id,kind:"edit",revision:edit.revision,before:edit.before,after:edit.after,targets:edit.factIDs,auth:auth)
                try await store.applyStoryEdit(edit.id,kind:value["kind"] as? String ?? "clarification",targets:value["targetIDs"] as? [String] ?? [],question:value["question"] as? String)
            }
            let questions=try await store.storyWorkspace().messages.filter{$0.role=="user" && $0.state=="queued"}
            for question in questions {try await answer(question.id,text:question.text,auth:auth)}
            await reload()
        } catch {self.error="Your writing is saved. Updating your health details is pending."}
    }
    func ask(_ text:String,auth:KindeAuthManager) async {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!busy else {return}
        busy=true;defer{busy=false}
        do {
            let id=try await store.addStoryMessage(role:"user",text:text,state:"queued");await reload()
            try await answer(id,text:text,auth:auth)
            await reload()
        } catch {self.error="Your question is saved. The answer couldn’t be loaded yet."}
    }
    private func answer(_ id:UUID,text:String,auth:KindeAuthManager) async throws {
        let value=try await request(id:id,kind:"chat",revision:0,before:"",after:text,targets:[],auth:auth)
        let response=value["kind"] as? String == "clarification" ? value["question"] as? String:value["text"] as? String
        try await store.completeStoryQuestion(id,text:response ?? "I couldn’t find an answer in these records.",citations:value["citationIDs"] as? [String] ?? [],evidence:evidence)
    }
    func action(_ work:() async throws -> Void) async {do {try await work();await reload()} catch {self.error=error.localizedDescription}}
}

struct StoryLabView: View {
    @ObservedObject var appModel:AppModel
    @StateObject private var model:StoryLabModel
    @EnvironmentObject private var auth:KindeAuthManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("storylab.tab") private var tab=0
    @State private var message=""
    @State private var showConversation=false
    @State private var showCheckIn=false
    @State private var selectedSource:StoryEvidence?
    @State private var logAction:HealthCarePlan.Action?
    @State private var progressText=""
    init(appModel:AppModel){self.appModel=appModel;_model=StateObject(wrappedValue:StoryLabModel(store:appModel.store))}
    private var day:String {Calendar.current.startOfDay(for:Date()).formatted(.iso8601)}
    var body:some View {
        TabView(selection:$tab) {
            NavigationStack {overview}.tabItem{Label("Overview",systemImage:"text.book.closed")}.tag(0)
            NavigationStack {HomeView(home:appModel.home,recording:appModel.recording,store:appModel.store,storyRecords:true,pendingSharedImportURL:$appModel.pendingSharedImportURL,advanceSharedImportQueue:appModel.enqueuePendingSharedImportIfAvailable)}.tabItem{Label("Records",systemImage:"clock")}.tag(1)
            NavigationStack {HealthSummaryView(model:appModel.health,home:appModel.home,store:appModel.store,structuredOnly:true).navigationTitle("Details")}.tabItem{Label("Details",systemImage:"square.grid.2x2")}.tag(2)
        }
        .environmentObject(appModel.health)
        .task {await model.reload();await appModel.health.refresh();await prepareCheckIn()}
        .onChange(of:model.workspace.careEvents){_,_ in Task{await appModel.health.refresh();await prepareCheckIn()}}
        .onChange(of:model.workspace.edits){_,_ in Task{await appModel.health.refresh()}}
        .onChange(of:tab){_,_ in Task{await appModel.health.refresh();await model.reload()}}
        .onChange(of:scenePhase){_,phase in
            appModel.recording.setAppInBackground(phase != .active)
            if phase == .active {appModel.enqueuePendingSharedImportIfAvailable();Task{await model.reload();if auth.isSignedIn {await model.reconcile(auth:auth)}}}
        }
        .sheet(item:$selectedSource){source in NavigationStack{ScrollView{VStack(alignment:.leading,spacing:16){Text(source.title).font(.headline);Text(source.text).textSelection(.enabled);if let record=model.records.first(where:{$0.id == source.recordID}){NavigationLink("Open record and original"){SessionDetailView(session:record,store:appModel.store,home:appModel.home,initialTab:.source)}}}.padding()}.navigationTitle("Source")}}
        .sheet(item:$logAction){action in NavigationStack{Form{Text(action.text);TextEditor(text:$progressText).frame(minHeight:160);Button("Save progress"){let text=progressText;Task{await model.action{try await model.store.recordStoryCareEvent(actionID:action.id,kind:"progress",text:text)};progressText="";logAction=nil;await appModel.health.refresh()}}.disabled(progressText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}.navigationTitle("How is it going?")}}
        .alert("Saved writing",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})){Button("OK"){model.error=nil}} message:{Text(model.error ?? "")}
    }
    private var overview:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Text("My health story").font(.largeTitle.bold())
                if model.workspace.blocks.isEmpty {Text("Add a record or start writing your story.").foregroundStyle(.secondary)}
                ForEach(model.workspace.blocks){block in
                    if !block.suppressed {
                        VStack(alignment:.leading) {
                            TextEditor(text:Binding(get:{model.workspace.blocks.first(where:{$0.id == block.id})?.text ?? block.text},set:{model.edit(block,text:$0,auth:auth)})).frame(minHeight:90).scrollContentBackground(.hidden).accessibilityLabel("Edit story paragraph")
                            HStack {
                                Button("Sources"){Task{let all=try? await model.store.storyEvidence(query:block.text,limit:200);selectedSource=all?.first(where:{block.factIDs.contains($0.id) || (block.correctionRecordID != nil && $0.recordID == block.correctionRecordID)})}}.disabled(block.factIDs.isEmpty && block.correctionRecordID == nil)
                                if block.patientWritten {Text("Your words").font(.caption).foregroundStyle(.secondary)}
                                if block.evidenceChanged {Text("Sources changed").font(.caption)}
                            }
                        }
                    }
                }
                Button("Add a paragraph",systemImage:"plus"){Task{await model.action{_ = try await model.store.addStoryBlock()}}}
                if let edit=model.workspace.edits.last,edit.state != "undone" {
                    HStack {Text(edit.state == "queued" ? "Writing saved · Updating details…":"Writing saved").font(.caption);Button("Retry pending updates"){Task{await model.reconcile(auth:auth)}}.disabled(model.busy)
                        Button("Undo"){Task{await model.action{try await model.store.undoStoryEdit(edit.id)};await appModel.health.refresh()}}}
                    if let question=edit.question {Text(question);Text("Edit the paragraph to clarify your meaning.").font(.caption)}
                }
                currentPlan
                Text("How it’s going").font(.title2.bold())
                ForEach(model.workspace.careEvents.filter{$0.kind == "progress"}.reversed()){event in VStack(alignment:.leading){Text(event.text);Text(event.date.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)}}
                if showCheckIn,let action=adoptedActions.first {
                    VStack(alignment:.leading){Text("How is your current plan going?").font(.headline);Button("Log a check-in"){logAction=action;showCheckIn=false;Task{await model.action{try await model.store.setStoryCheckIn(enabled:true,day:day)}}};Button("Not today"){showCheckIn=false;Task{await model.action{try await model.store.setStoryCheckIn(enabled:true,day:day)}}};Button("Turn off check-ins"){showCheckIn=false;Task{await model.action{try await model.store.setStoryCheckIn(enabled:false)}}}}
                }
                if showConversation {
                    Divider()
                    ForEach(model.workspace.messages){item in VStack(alignment:.leading,spacing:8){Text(item.role == "user" ? "You":"From your records").font(.caption.bold());Text(item.text).textSelection(.enabled)
                        if item.role == "user", item.savedRecordID == nil {Button("Save to my records"){Task{await model.action{try await model.store.saveStoryMessageAsRecord(item.id)};await appModel.health.refresh()}}}
                        ForEach(item.citationIDs,id:\.self){id in Button("Source"){selectedSource=item.evidence?.first{$0.id==id}}}
                    }.padding(.vertical,8)}
                }
            }.padding()
        }
        .safeAreaInset(edge:.bottom){HStack(alignment:.bottom){Button{tab=1;Task{try? await Task.sleep(nanoseconds:250_000_000);NotificationCenter.default.post(name:Notification.Name("StoryLabAddRecord"),object:nil)}}label:{Image(systemName:"plus.circle.fill").font(.title)}.accessibilityLabel("Add a recording or attachment")
            TextField("Ask about your records or share an update",text:$message,axis:.vertical).lineLimit(1...4)
            Button{let text=message;message="";showConversation=true;Task{await model.ask(text,auth:auth)}}label:{Image(systemName:"arrow.up.circle.fill").font(.title)}.disabled(model.busy || message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityLabel("Send")
        }.padding().background(.regularMaterial)}
        .toolbar{ToolbarItem(placement:.topBarTrailing){Button(showConversation ? "Hide chat":"Conversation"){showConversation.toggle()}}}
    }
    private func prepareCheckIn() async {
        guard model.workspace.checkInsEnabled,model.workspace.lastCheckInDay != day,!adoptedActions.isEmpty else {return}
        showCheckIn=true
        await model.action{try await model.store.setStoryCheckIn(enabled:true,day:day)}
    }
    private var actions:[HealthCarePlan.Action]{appModel.health.carePlans.flatMap(\.actions)}
    private func adopted(_ action:HealthCarePlan.Action)->Bool {
        if let event=model.workspace.careEvents.last(where:{$0.actionID == action.id && $0.kind != "progress"}) {return event.kind == "adopted"}
        return appModel.health.facts.contains{action.factIDs.contains($0.id) && $0.preference.actionStatus == .current}
    }
    private var adoptedActions:[HealthCarePlan.Action]{actions.filter{adopted($0)}}
    private var currentPlan:some View {
        VStack(alignment:.leading,spacing:16){Text("My current plan").font(.title2.bold())
            if adoptedActions.isEmpty {Text("Choose which recorded recommendations you’re following. Nothing is assumed to be current.").foregroundStyle(.secondary)}
            ForEach(adoptedActions){action in careRow(action,following:true)}
            DisclosureGroup("Recorded recommendations"){ForEach(actions.filter{!adopted($0)}){action in careRow(action,following:false)}}
        }
    }
    private func careRow(_ action:HealthCarePlan.Action,following:Bool)->some View {
        VStack(alignment:.leading,spacing:8){Text(action.text);ForEach(action.metadata,id:\.self){Text($0).font(.caption)}
            Button("Source"){Task{let all=try? await model.store.storyEvidence(query:action.text,limit:200);selectedSource=all?.first{action.factIDs.contains($0.id)}}}
            if following {
                HStack{Button("Log progress"){logAction=action};Menu("Update status"){
                    Button("Did this today"){Task{await model.action{try await model.store.recordStoryCareEvent(actionID:action.id,kind:"progress",text:"I did this today: "+action.text)}}}
                    Button("Pause"){Task{await model.action{try await model.store.recordStoryCareEvent(actionID:action.id,kind:"paused",text:action.text,factIDs:action.factIDs)}}}
                    Button("Stop following"){Task{await model.action{try await model.store.recordStoryCareEvent(actionID:action.id,kind:"stopped",text:action.text,factIDs:action.factIDs)}}}
                }}
            } else {Button("I’m following this"){Task{await model.action{try await model.store.recordStoryCareEvent(actionID:action.id,kind:"adopted",text:action.text,factIDs:action.factIDs)}}}}
        }.padding(.vertical,8)
    }
}
struct StoryRecordsList:View {
    let store:SessionStore
    @ObservedObject var home:HomeViewModel
    @State private var records:[Session]=[]
    var body:some View {List{ForEach(records.sorted{$0.date>$1.date}){record in NavigationLink{StoryRecordEditor(record:record,store:store,home:home)}label:{VStack(alignment:.leading){Text(record.displayTitle).font(.headline);Text("Added "+record.date.formatted(date:.abbreviated,time:.shortened)).font(.caption);Text(record.transcript).lineLimit(2).foregroundStyle(.secondary)}}}}.task{records=(try? await store.loadAll()) ?? []}.onChange(of:home.revision){_,_ in Task{records=(try? await store.loadAll()) ?? []}}}
}
struct StoryRecordEditor:View {
    let record:Session;let store:SessionStore
    @ObservedObject var home:HomeViewModel
    @EnvironmentObject private var health:HealthSummaryModel
    @EnvironmentObject private var auth:KindeAuthManager
    @State private var loaded=false
    @State private var text="";@State private var revisions:[StorySourceRevision]=[];@State private var error:String?;@State private var saved=false
    var body:some View {ScrollView{VStack(alignment:.leading,spacing:16){TextEditor(text:$text).frame(minHeight:350).accessibilityLabel("Record text")
            .onChange(of:text){_,value in guard loaded else {return}; saved=false; Task{do{try await store.saveStorySourceDraft(record.id,text:value)}catch{self.error=error.localizedDescription}}}
        Text("Writing saves automatically on this device. Save corrected text to update your health details.").font(.caption).foregroundStyle(.secondary)
        Button("Save corrected text"){Task{do{try await store.reviseStorySource(record.id,text:text);saved=true;await health.refresh();let transport=await auth.openAIChatTransport(byokFallback:"");await health.updateHealthStory(transport:transport,onDevice:false,explicitlyRequested:true)}catch{self.error=error.localizedDescription}}}
        if saved {Text("Correction saved. Your original is preserved.")}
        NavigationLink("Open original and attachments"){SessionDetailView(session:record,store:store,home:home,initialTab:.source)}
        DisclosureGroup("Text history"){ForEach(revisions.reversed()){revision in VStack(alignment:.leading){Text(revision.createdAt.formatted()).font(.caption);Text(revision.patientEdited ? "Patient-corrected text":"Original text").font(.caption.bold());Text(revision.text).textSelection(.enabled);Button("Restore this text"){text=revision.text}}}}
        if let error {Text(error).foregroundStyle(.red)}
    }.padding()}.navigationTitle(record.displayTitle).task{let workspace=try? await store.storyWorkspace();text=workspace?.sourceDrafts?[record.id.uuidString] ?? record.transcript;revisions=workspace?.sources.filter{$0.recordID==record.id} ?? [];loaded=true}}
}
