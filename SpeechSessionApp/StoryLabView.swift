import SwiftUI
import UIKit
import PDFKit
import SpeechSessionPersistence
import SpeechSessionFeatures

@MainActor final class StoryLabModel: ObservableObject {
    @Published var workspace = StoryWorkspace()
    @Published var records: [Session] = []
    @Published var error: String?
    @Published var busy = false
    @Published var didLoadStory = false
    @Published var initialStoryLoadFailed = false
    @Published var narrative = ""
    @Published var answerDraft = ""
    @Published var answerStatus = ""
    @Published private(set) var sendingQuestion: StoryMessage?
    @Published var activeQuestionID: UUID?
    private var narrativeSave: Task<Void,Never>?
    @Published var evidence: [StoryEvidence] = []
    let store: SessionStore
    private var edits: [UUID:Task<Void,Never>] = [:]
    init(store:SessionStore) {self.store = store}
    func reload() async {
        initialStoryLoadFailed = false
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--storylab-fixture"),try await store.loadAll().isEmpty {
                let id=UUID()
                var care=SummaryEntry(category:.carePlan,title:"Walk for ten minutes if comfortable",sourceSessionID:id,sourceExcerpt:"Walk for ten minutes if comfortable",origin:.userAdded)
                var evidence=ClinicalEvidence();evidence.careInstruction=CareInstruction(instruction:care.title,schedule:"Daily",isRecurring:true);care.evidence=evidence
                try await store.save([Session(id:id,transcript:"I have neck discomfort after sitting. My clinician recommended walking for ten minutes if comfortable.",title:"Synthetic visit",summaryEntries:[SummaryEntry(category:.symptoms,title:"I have neck discomfort after sitting.",sourceSessionID:id,sourceExcerpt:"I have neck discomfort after sitting.",origin:.userAdded),care])])
            }
            #endif
            records = try await store.loadAll()
            if narrativeSave == nil { narrative = try await store.storyNarrativeText() }
            didLoadStory = true
            try await store.synchronizeStory()
            workspace = try await store.storyWorkspace()
        }
        catch {initialStoryLoadFailed = !didLoadStory; self.error = error.localizedDescription}
    }
    func saveNarrative(_ text:String) {
        narrative=text
        let previous=narrativeSave
        narrativeSave=Task {
            await previous?.value
            do {try await store.saveStoryNarrativeText(text)} catch {self.error="Your writing could not be saved. Please try again."}
        }
    }
    func refreshNarrative(auth:KindeAuthManager) async {
        guard !busy else {return};busy=true;defer{busy=false}
        do {
            await narrativeSave?.value;narrativeSave=nil
            let snapshot=try await store.storyWorkspace()
            let sources = try await store.storyOverviewEvidence()
            guard !sources.isEmpty else {
                error = "There isn’t enough saved text to write an overview yet."
                return
            }
            let revision = snapshot.narrativeRevision ?? 0
            guard let transport = await auth.openAIChatTransport(byokFallback:""), transport.durableJobsURL != nil else {
                error = "Sign in to refresh your saved overview."
                return
            }
            let draft = try await transport.durableRequest(payload: StoryOverviewRefresh.draftPayload(sources))
            let sentences = try StoryOverviewRefresh.sentences(draft, sources:sources)
            let review = try await transport.durableRequest(payload: StoryOverviewRefresh.reviewPayload(sentences, sources:sources))
            let result = try StoryOverviewRefresh.publication(review, sentences:sentences, sources:sources)
            try await store.publishStoryNarrative(result.text, revision:revision, evidence:result.evidence, expectedSources:sources)
            await reload()
        } catch StoryEditError.staleRevision {
            await reload()
            self.error = "Your overview changed during the refresh. The newer version is available."
        } catch let failure as SummaryStageFailure {
            self.error = "Your overview is saved. The refresh couldn’t finish (" + failure.state.replacingOccurrences(of:"_",with:" ") + ")."
        } catch {
            self.error = "Your overview is saved. " + error.localizedDescription
        }
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
                while busy {try await Task.sleep(nanoseconds:200_000_000);try Task.checkCancellation()}
                await reconcile(auth:auth)
            } catch is CancellationError {} catch {self.error=error.localizedDescription}
        }
    }
    func request(id:UUID,kind:String,revision:Int,before:String,after:String,targets:[String],auth:KindeAuthManager,summaryEvidence:[StoryEvidence]? = nil,recordID:UUID? = nil) async throws -> [String:Any] {
        var selected:[StoryEvidence]=[];var metadata:[String:String]=[:];var conversation:[[String:String]]=[]
        if let summaryEvidence {
            guard summaryEvidence.count<=200,summaryEvidence.reduce(0,{$0+$1.text.count})<=80000 else {throw StoryEditError.invalidMutation}
            selected=summaryEvidence
            metadata=["scope":"retrieval","availableCount":String(selected.count),"returnedCount":String(selected.count),"complete":"false"]
        } else {
        let history=try await store.storyWorkspace().messages.filter{["user","assistant"].contains($0.role) && $0.scopeRecordID == recordID && $0.id != id && ["saved","completed"].contains($0.state)}.suffix(20)
        let retrievalQuery=kind == "chat" ? history.filter{$0.role=="user"}.suffix(2).map(\.text).joined(separator:" ")+" "+after:after
        conversation=history.map{["role":$0.role,"text":String($0.text.prefix(2000))]}
        if let recordID {
            selected = try await store.storyRecordEvidence(recordID: recordID, query: retrievalQuery)
            metadata = ["scope":"retrieval","availableCount":String(selected.count),"returnedCount":String(selected.count),"complete":"false"]
        } else {
        let scope=try await store.storyRetrievalMetadata(query:summaryEvidence == nil ? after:"",limit:100)
        let sources = try await store.storyEvidence(query:scope["scope"] == "retrieval" ? retrievalQuery:after,limit:100)
        let allFacts = try await store.storyTargetEvidence(targets)
        let retrieved = Dictionary((sources+allFacts.filter{targets.contains($0.id)}).map{($0.id,$0)},uniquingKeysWith: {a,_ in a}).values.sorted{$0.id<$1.id}
        var characters=0
        for var source in retrieved {
            guard characters+source.text.count<80000 else {continue}
            if kind != "edit" {source.id="E"+String(selected.count+1)}
            characters+=source.text.count;selected.append(source)
        }
        metadata=scope
        if selected.count != sources.count {metadata["complete"]="false"}
        metadata["returnedCount"]=String(selected.count)
        }
        }
        let endpoint = URL(string:(Bundle.main.object(forInfoDictionaryKey:"CloudOpenAIBaseURL") as? String ?? "")+"/v1/health-processing/story-operations")!
        var payload:[String:Any] = ["id":id.uuidString.lowercased(),"version":"story-v1","kind":kind,"baseRevision":revision,"before":before,"after":after,"targetIDs":targets,"evidence":try JSONSerialization.jsonObject(with:JSONEncoder().encode(Array(selected)))]
        if kind == "chat",summaryEvidence == nil {payload["conversation"]=conversation}
        payload["retrieval"]=metadata
        let encoded=String(decoding:try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys),as:UTF8.self)
        if let saved=try await store.storyRequestBody(id,proposed:encoded),let value=try JSONSerialization.jsonObject(with:Data(saved.utf8)) as? [String:Any] {payload=value}
        let savedEvidence=try JSONDecoder().decode([StoryEvidence].self,from:JSONSerialization.data(withJSONObject:payload["evidence"] ?? []))
        if kind == "chat" { self.evidence = savedEvidence }
        var first=true
        var transientFailures = 0
        for _ in 0..<300 {
            try Task.checkCancellation()
            let current = try await store.storyWorkspace()
            if current.edits.contains(where: {$0.id == id && ["cancelled","undone","superseded"].contains($0.state)}) || current.messages.contains(where: {$0.id == id && $0.state == "cancelled"}) {throw CancellationError()}
            var req=URLRequest(url:first ? endpoint:URL(string:endpoint.absoluteString+"?id="+id.uuidString.lowercased())!)
            req.httpMethod=first ? "POST":"GET";req.timeoutInterval=30
            req.setValue("Bearer "+(try await auth.freshAccessToken()),forHTTPHeaderField:"Authorization")
            if first {req.setValue("application/json",forHTTPHeaderField:"Content-Type");req.httpBody=try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys)}
            let data: Data
            do {
                let (body, response) = try await URLSession.shared.data(for:req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if kind == "refresh", [429, 502, 503, 504].contains(status), transientFailures < 3 {
                    transientFailures += 1
                    try await Task.sleep(nanoseconds: UInt64(transientFailures) * 1_000_000_000)
                    continue
                }
                guard (200..<300).contains(status) else {
                    if kind == "refresh" {throw SummaryStageFailure(state:"service returned HTTP " + String(status))}
                    throw URLError(.badServerResponse)
                }
                transientFailures = 0
                data = body
            } catch let error as URLError where kind == "refresh" && transientFailures < 3 &&
                [.timedOut,.networkConnectionLost,.cannotConnectToHost].contains(error.code) {
                transientFailures += 1
                try await Task.sleep(nanoseconds: UInt64(transientFailures) * 1_000_000_000)
                continue
            }
            let result=try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
            if kind == "chat" {
                if let draft=result["draftText"] as? String {answerDraft=draft}
                answerStatus=result["phase"] as? String == "checking" ? "Checking sources…":"Reading your records…"
            }
            if result["state"] as? String == "completed", let output=result["result"] as? [String:Any] {self.evidence=savedEvidence;return output}
            if ["blocked","cancelled","failed","incomplete","uncertain","expired","not_found","invalid_result","budget_exhausted"].contains(result["state"] as? String ?? "") {if summaryEvidence != nil {throw SummaryStageFailure(state:result["state"] as? String ?? "failed")};throw URLError(.cannotParseResponse)}
            first=false;try await Task.sleep(nanoseconds:1_000_000_000)
        }
        throw URLError(.timedOut)
    }
    func reconcile(auth:KindeAuthManager) async {
        guard !busy else {return};busy=true;defer{busy=false;activeQuestionID=nil;answerDraft="";answerStatus=""}
        do {
            let workspace=try await store.storyWorkspace()
            for id in workspace.edits.filter{$0.cancellationPending==true}.map(\.id)+workspace.messages.filter{$0.cancellationPending==true}.map(\.id) {try await sendCancellation(id,auth:auth)}
            let pending:[StoryEdit]=[] // Structured editing is paused for the narrative/chat experiment.
            for edit in pending {
                let value=try await request(id:edit.id,kind:"edit",revision:edit.revision,before:edit.before,after:edit.after,targets:edit.factIDs,auth:auth)
                try await store.applyStoryEdit(edit.id,kind:value["kind"] as? String ?? "clarification",targets:value["targetIDs"] as? [String] ?? [],question:value["question"] as? String,actionUpdates:Dictionary((value["actionUpdates"] as? [[String:String]] ?? []).compactMap{a in guard let id=a["factID"],let status=a["status"] else{return nil};return (id,status)},uniquingKeysWith: {a,_ in a}))
            }
            let questions=try await store.storyWorkspace().messages.filter{$0.role=="user" && $0.state=="queued"}
            for question in questions {activeQuestionID=question.id;try await answer(question,auth:auth)}
            activeQuestionID=nil;answerDraft="";answerStatus=""
            await reload()
        } catch {self.error="Your question is saved. The answer couldn’t be loaded yet."}
    }
    func ask(_ text: String, recordID: UUID? = nil, auth: KindeAuthManager) -> UUID? {
        guard !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let question = StoryMessage.queuedQuestion(text, recordID: recordID)
        busy = true
        sendingQuestion = question
        answerDraft = ""
        Task {
            defer {
                busy = false
                sendingQuestion = nil
                activeQuestionID = nil
                answerDraft = ""
                answerStatus = ""
            }
            do {
                try await store.addStoryMessage(question)
            } catch {
                self.error = "Your question couldn’t be saved. Please try again."
                return
            }
            if !workspace.messages.contains(where: { $0.id == question.id }) {
                workspace.messages.append(question)
            }
            activeQuestionID = question.id
            do {
                try await answer(question, auth: auth)
            } catch {
                self.error = "Your question is saved. The answer couldn’t be loaded yet."
            }
            do {
                workspace = try await store.storyWorkspace()
            } catch {
                self.error = "Your chat couldn’t be loaded. Please reopen it."
            }
        }
        return question.id
    }
    private func answer(_ question:StoryMessage,auth:KindeAuthManager) async throws {
        let id = question.id
        let value=try await request(id:id,kind:"chat",revision:0,before:"",after:question.text,targets:[],auth:auth,recordID:question.scopeRecordID)
        let response=value["kind"] as? String == "clarification" ? value["question"] as? String:value["text"] as? String
        try await store.completeStoryQuestion(id,text:response ?? "I couldn’t find an answer in these records.",citations:value["citationIDs"] as? [String] ?? [],evidence:evidence)
    }
    private func sendCancellation(_ id:UUID,auth:KindeAuthManager) async throws {
        let endpoint=URL(string:(Bundle.main.object(forInfoDictionaryKey:"CloudOpenAIBaseURL") as? String ?? "")+"/v1/health-processing/story-operations?id="+id.uuidString.lowercased())!
        var request=URLRequest(url:endpoint);request.httpMethod="DELETE";request.timeoutInterval=30
        request.setValue("Bearer "+(try await auth.freshAccessToken()),forHTTPHeaderField:"Authorization")
        let (_,response)=try await URLSession.shared.data(for:request)
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode)||http.statusCode==404 else {throw URLError(.badServerResponse)}
        try await store.acknowledgeStoryCancellation(id)
    }
    func stop(_ id:UUID,auth:KindeAuthManager) async {
        do {try await store.cancelStoryOperation(id);await reload();try await sendCancellation(id,auth:auth)}
        catch {self.error="Stopped on this device. The server will receive Stop when the connection returns."}
    }
    func action(_ work:() async throws -> Void) async {do {try await work();await reload()} catch {self.error=error.localizedDescription}}
}

struct StoryLabView: View {
    @ObservedObject var appModel:AppModel
    @StateObject private var model:StoryLabModel
    @EnvironmentObject private var auth:KindeAuthManager
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo:.body) private var citationTextSize:CGFloat=StoryDesignTokens.bodyBaseSize
    @FocusState private var chatFocused:Bool
    @State private var chatRecord: Session?
    @State private var visibleChatIDs:Set<UUID>=[]
    @StateObject private var sharing:StorySummaryGeneration
    @State private var chatContentBottom:CGFloat=0
    @State private var chatViewportHeight:CGFloat=0
    @State private var chatScrollRequest=UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceChatMotion
    @State private var showChatHistory=false
    @StateObject private var chatRouter = StoryFolderRouter()
    @State private var missingChatRecord = false
    @State private var message=""
    @State private var composerAddsRecord=false
    @State private var showConversation=false
    @State private var showCheckIn=false
    @State private var selectedSource:StoryEvidence?
    @State private var sourceChoices:[StoryEvidence]=[]
    @State private var showSourceChoices=false
    @State private var logAction:HealthCarePlan.Action?
    @State private var progressText=""
    @State private var progressEventID=UUID()
    @StateObject private var folderRouter = StoryFolderRouter()
    init(appModel:AppModel){self.appModel=appModel;_sharing=StateObject(wrappedValue:StorySummaryGeneration(store:appModel.store));_model=StateObject(wrappedValue:StoryLabModel(store:appModel.store))}
    @State private var homeHasAppeared = false
    private var day:String {Calendar.current.startOfDay(for:Date()).formatted(.iso8601)}
    var body:some View {
        NavigationStack(path: $folderRouter.path) {
            HomeView(home:appModel.home,recording:appModel.recording,store:appModel.store,storyRecords:true,storyNarrative:model.didLoadStory ? model.narrative : nil,retryStoryLoad:model.initialStoryLoadFailed ? {Task {await model.reload()}} : nil,storyBusy:model.busy,summaryStatus:sharing.homeStatus,summaryDrawer:{AnyView(StoryTemplateShareView(home:appModel.home,records:model.records,store:appModel.store,job:sharing))},askStory:{openChat()},refreshStory:{Task{await model.refreshNarrative(auth:auth)}},pendingSharedImportURL:$appModel.pendingSharedImportURL,advanceSharedImportQueue:appModel.enqueuePendingSharedImportIfAvailable)
                .navigationDestination(for: StoryRoute.self) { route in
                    StoryFolderDestination(route: route, store: appModel.store, home: appModel.home) { AnyView(currentPlan) }
                        .environment(\.storyRouter, folderRouter)
                }
                .onAppear {
                    if homeHasAppeared {
                        Task { await model.reload(); await appModel.health.refresh() }
                    }
                    homeHasAppeared = true
                }
        }
        .environment(\.storyRouter, folderRouter)
        .environment(\.askAboutRecord, { record in openChat(record: record) })
        .sheet(item: $folderRouter.capture, onDismiss: {
            folderRouter.documentImportID = nil
            folderRouter.onCaptureDismiss?()
            folderRouter.onCaptureDismiss = nil
            if let id = folderRouter.finishedCapture {
                folderRouter.finishedCapture = nil
                folderRouter.open(.record(id))
            }
        }) { record in
            StoryCaptureView(record: record, store: appModel.store, home: appModel.home, importDocument: folderRouter.documentImportID == record.id) { completed in
                folderRouter.finishedCapture = completed
                folderRouter.capture = nil
            }
            .environmentObject(appModel.health)
            .environment(\.storyRouter, folderRouter)
        }
        .task(id:auth.isSignedIn){if auth.isSignedIn {await sharing.restore(auth:auth)}}
        .sheet(isPresented:$showConversation){chatDrawer.presentationDetents([.large]).presentationDragIndicator(.visible)}
        .tint(StoryDesignTokens.action)
        .environmentObject(appModel.health)
        .task {
            await model.reload()
            await appModel.health.refresh()
            for record in (try? await appModel.store.loadAll()) ?? [] where record.capture?.pending == true {
                CaptureProcessing.shared.start(record, store: appModel.store, home: appModel.home, health: appModel.health, auth: auth)
            }
        }
        .onChange(of:model.workspace.careEvents){_,_ in Task{await appModel.health.refresh();}}
        .onChange(of:model.workspace.edits){_,_ in Task{await appModel.health.refresh()}}
        .onChange(of:model.workspace.sources.map(\.id)){old,new in
            guard !new.isEmpty,!old.isEmpty,old != new,auth.isSignedIn else {return}
            Task{let transport=await auth.openAIChatTransport(byokFallback:"");await appModel.health.updateHealthStory(transport:transport,onDevice:false,explicitlyRequested:true);await model.reload()}
        }
        .onChange(of:scenePhase){_,phase in
            appModel.recording.setAppInBackground(phase != .active)
            if phase == .active {appModel.enqueuePendingSharedImportIfAvailable();Task{await model.reload()}}
        }
        .sheet(isPresented:$showSourceChoices){NavigationStack{List(sourceChoices){source in VStack(alignment:.leading,spacing:8){Text(source.title).font(StoryDesignTokens.section);Text(source.text).textSelection(.enabled);if let record=model.records.first(where:{$0.id==source.recordID}){NavigationLink("Open source record"){SessionDetailView(session:record,store:appModel.store,home:appModel.home,initialTab:.source)}}}}.navigationTitle("Supporting sources")}}
        .sheet(item:$selectedSource){source in NavigationStack{ScrollView{VStack(alignment:.leading,spacing:16){Text(source.title).font(StoryDesignTokens.section);Text(source.text).textSelection(.enabled);if let record=model.records.first(where:{$0.id == source.recordID}){NavigationLink("Open record and original"){SessionDetailView(session:record,store:appModel.store,home:appModel.home,initialTab:.source)}}}.padding()}.navigationTitle("Source")}}
        .onChange(of:logAction?.id){_,id in if id != nil {progressEventID=UUID();progressText=""}}
        .sheet(item:$logAction){action in NavigationStack{Form{Text(action.text);TextEditor(text:$progressText).frame(minHeight:160);Button("Save progress"){let text=progressText;Task{await model.action{try await model.store.recordStoryCareEvent(actionID:action.id,kind:"progress",text:text,factIDs:action.factIDs,eventID:progressEventID)};progressText="";logAction=nil;await appModel.health.refresh()}}.disabled(progressText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}.navigationTitle("How is it going?")}}
        .alert("Saved writing",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})){Button("OK"){model.error=nil}} message:{Text(model.error ?? "")}
    }
    private func openChat(record: Session? = nil) {
        if chatRecord?.id != record?.id { message = "" }
        chatRecord = record
        chatRouter.path = []
        missingChatRecord = false
        visibleChatIDs=[]
        showConversation=true
    }
    private func includeQuestion(_ id:UUID) {
        visibleChatIDs.insert(id)
        visibleChatIDs.insert(IncrementalRecordUpdate.stableID("story-answer:"+id.uuidString))
    }
    private var visibleChat:[StoryMessage] {
        var messages = model.workspace.messages.filter{["user","assistant"].contains($0.role) && visibleChatIDs.contains($0.id)}
        if let question = model.sendingQuestion, visibleChatIDs.contains(question.id),
           !messages.contains(where: { $0.id == question.id }) {
            messages.append(question)
        }
        return messages
    }
    private var showingActiveAnswer:Bool {
        (model.activeQuestionID ?? model.sendingQuestion?.id).map{visibleChatIDs.contains($0)} ?? false
    }
    private func selectHistory(_ question:StoryMessage) {
        visibleChatIDs=[]
        includeQuestion(question.id)
        showChatHistory=false
    }
    private func sourceTags(_ sources:[StoryEvidence])->some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack {
                ForEach(sources) {source in
                    Button { openChatRecord(source) } label: {
                        recordTag(source.title).fixedSize(horizontal:true,vertical:false)
                    }
                    .accessibilityLabel("Open record: "+source.title)
                }
            }
        }
    }
    private func recordTag(_ title:String)->some View {
        StorySourceTag(title: title)
    }
    private var chatHasMoreBelow:Bool {
        chatViewportHeight > 0 && chatContentBottom > chatViewportHeight+24 && (!visibleChat.isEmpty || showingActiveAnswer)
    }
    private func openChatRecord(_ source: StoryEvidence) {
        chatFocused = false
        guard let id = source.recordID else { missingChatRecord = true; return }
        if id == chatRecord?.id { showConversation = false; return }
        chatRouter.open(.record(id))
    }
    private var chatDrawer:some View {
        NavigationStack(path: $chatRouter.path) {
            ScrollViewReader {proxy in
                ScrollView {
                    VStack(alignment:.leading,spacing:24) {
                        if visibleChat.isEmpty {
                            Text("Ask anything").font(StoryDesignTokens.heading(.largeTitle)).padding(.top,32)
                            Text(chatRecord.map { "About " + $0.displayTitle } ?? "About your health story and records").font(StoryDesignTokens.body).foregroundStyle(.secondary)
                        }
                        ForEach(visibleChat){item in
                            VStack(alignment:.leading,spacing:12) {
                                if item.role == "user" {
                                    HStack(alignment:.top,spacing:0) {
                                        Spacer(minLength:32)
                                        Text(item.text)
                                            .font(StoryDesignTokens.body)
                                            .lineSpacing(citationTextSize*0.22)
                                            .foregroundStyle(StoryDesignTokens.bubbleContent)
                                            .padding(.horizontal,16).padding(.vertical,12)
                                            .background(StoryDesignTokens.bubbleFill,in:RoundedRectangle(cornerRadius:22))
                                            .fixedSize(horizontal:false,vertical:true)
                                            .textSelection(.enabled)
                                            .accessibilityLabel("You: "+item.text)
                                    }
                                } else {
                                    StoryAnswerText(text:item.text,evidence:item.evidence ?? [],fontSize:citationTextSize,isAnswer:true) {source,_,_ in
                                        openChatRecord(source)
                                    }
                                }
                                if item.role == "assistant",let evidence=item.evidence,!evidence.isEmpty {sourceTags(evidence)}
                                if item.state == "queued",!model.busy {Button("Retry answer"){Task{await model.reconcile(auth:auth)}}}
                            }.frame(maxWidth:.infinity,alignment:.leading).id(item.id)
                        }
                        if model.busy && showingActiveAnswer {
                            if !model.answerDraft.isEmpty {StoryAnswerText(text:model.answerDraft,evidence:model.evidence,fontSize:citationTextSize,isAnswer:true){source,_,_ in openChatRecord(source)};StoryThinkingStatus("Checking sources…")}
                            else {StoryThinkingStatus().frame(maxWidth:.infinity,alignment:.leading)}
                        }
                        Color.clear.frame(height:1).id("end")
                            .onGeometryChange(for:CGFloat.self) {geometry in
                                geometry.frame(in:.named("storyChatScroll")).maxY
                            } action: {chatContentBottom=$0}
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.vertical,24)
                }
                .coordinateSpace(name:"storyChatScroll")
                .onGeometryChange(for:CGFloat.self) {geometry in geometry.size.height} action: {chatViewportHeight=$0}
                .scrollDismissesKeyboard(.interactively)
                .onChange(of:model.workspace.messages.count) {_,_ in
                    if !chatHasMoreBelow {proxy.scrollTo("end",anchor:.bottom)}
                }
                .onChange(of:chatScrollRequest) {_,_ in
                    withAnimation(reduceChatMotion ? nil:.easeOut(duration:0.25)) {
                        proxy.scrollTo("end",anchor:.bottom)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading){Button {chatFocused=false;showConversation=false} label:{Image(systemName:"xmark")}.accessibilityLabel("Close chat")}
                ToolbarItem(placement:.topBarTrailing){Button {chatFocused=false;showChatHistory=true} label:{Image(systemName:"clock.arrow.circlepath")}.accessibilityLabel("Chat history")}
            }
            .safeAreaInset(edge:.bottom) {
                HStack(alignment:.center) {
                    TextField(chatRecord == nil ? "Ask anything" : "ask anything about this record",text:$message,axis:.vertical).lineLimit(1...6).font(StoryDesignTokens.body).focused($chatFocused)
                    if let id=model.activeQuestionID,model.busy,showingActiveAnswer {Button{Task{await model.stop(id,auth:auth)}}label:{Image(systemName:"stop.circle.fill").font(.title)}.accessibilityLabel("Stop answer")}
                    else {Button {
                        guard let id = model.ask(message, recordID: chatRecord?.id, auth: auth) else { return }
                        includeQuestion(id)
                        message = ""
                        chatFocused = false
                        chatScrollRequest = UUID()
                    } label:{Image(systemName:"arrow.up.circle.fill").font(.largeTitle)}.disabled(model.busy || message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityLabel("Send")}
                }.tint(StoryDesignTokens.action).padding(.horizontal,16).padding(.vertical,12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:28)).padding(.horizontal,20).padding(.vertical,12)
                .background {
                    VStack(spacing:0) {
                        LinearGradient(
                            stops:[
                                .init(color:StoryDesignTokens.surface.opacity(0),location:0),
                                .init(color:StoryDesignTokens.surface.opacity(0.55),location:0.5),
                                .init(color:StoryDesignTokens.surface,location:1)
                            ],startPoint:.top,endPoint:.bottom
                        ).frame(height:64)
                        StoryDesignTokens.surface
                    }
                    .padding(.top,-64)
                    .ignoresSafeArea(.container,edges:.bottom)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .overlay(alignment:.top) {
                    if chatHasMoreBelow {
                        Button {chatScrollRequest=UUID()} label: {
                            Image(systemName:"arrow.down").font(.title3.weight(.medium))
                                .foregroundStyle(StoryDesignTokens.ink).frame(minWidth:32,minHeight:32)
                        }
                        .buttonBorderShape(.circle).storyControlStyle()
                        .accessibilityLabel("Scroll to latest message")
                        .offset(y:-52)
                    }
                }
            }
            .navigationDestination(for: StoryRoute.self) { route in
                StoryFolderDestination(route: route, store: appModel.store, home: appModel.home) { AnyView(currentPlan) }
                    .environment(\.storyRouter, chatRouter)
            }
            .alert("No linked record", isPresented: $missingChatRecord) { Button("OK") {} }
            .sheet(isPresented:$showChatHistory) {
                NavigationStack {
                    List {
                        if !model.didLoadStory {
                            if model.initialStoryLoadFailed { Button("Retry loading history"){Task{await model.reload()}} }
                            else { StoryLoadingPlaceholder(label:"Loading chat history",rows:3) }
                        } else if !model.workspace.messages.contains(where:{$0.role=="user" && $0.scopeRecordID == chatRecord?.id}) {
                            Text("Your conversations will appear here.").foregroundStyle(Color.secondary)
                        }
                        ForEach(model.workspace.messages.filter{$0.role=="user" && $0.scopeRecordID == chatRecord?.id}.reversed()) {question in
                            Button {selectHistory(question)} label: {
                                VStack(alignment:.leading,spacing:6) {
                                    Text(question.text).font(StoryDesignTokens.body)
                                        .foregroundStyle(Color.primary).lineLimit(2)
                                    Text(question.createdAt.formatted(date:.abbreviated,time:.shortened))
                                        .font(StoryDesignTokens.body).foregroundStyle(Color.secondary)
                                }
                                .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                                .padding(.vertical,8).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .background(StoryDesignTokens.surface)
                    .navigationTitle("Chat history").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement:.topBarLeading) {
                            Button {showChatHistory=false} label:{Image(systemName:"xmark")}
                                .accessibilityLabel("Close chat history")
                        }
                    }
                }
                .presentationBackground(StoryDesignTokens.surface)
                .presentationDetents([.medium,.large]).presentationDragIndicator(.visible)
            }
        }
    }
    private func narrativeParagraphs(_ section:String)->some View {
        VStack(alignment:.leading,spacing:12) {
                ForEach(model.workspace.blocks.filter{($0.section ?? "story") == section}){block in
                    if !block.suppressed {
                        VStack(alignment:.leading) {
                            TextEditor(text:Binding(get:{model.workspace.blocks.first(where:{$0.id == block.id})?.text ?? block.text},set:{model.edit(block,text:$0,auth:auth)})).frame(minHeight:90).scrollContentBackground(.hidden).accessibilityLabel("Edit story paragraph")
                            HStack {
                                Button("Sources"){Task{sourceChoices=(try? await model.store.storySources(factIDs:block.factIDs,correctionRecordID:block.correctionRecordID)) ?? [];showSourceChoices=true}}.disabled(block.factIDs.isEmpty && block.correctionRecordID == nil)
                                if block.patientWritten {Text("Your words").font(StoryDesignTokens.font(.caption)).foregroundStyle(.secondary)}
                                if block.evidenceChanged {Text("Sources changed").font(StoryDesignTokens.font(.caption))}
                            }
                        }
                    }
                }
                Button("Add a paragraph",systemImage:"plus"){Task{await model.action{_ = try await model.store.addStoryBlock(section:section)}}}
        }
    }
    private func prepareCheckIn() async {
        guard model.workspace.checkInsEnabled,model.workspace.lastCheckInDay != day,!adoptedActions.isEmpty else {return}
        showCheckIn=true
        await model.action{try await model.store.setStoryCheckIn(enabled:true,day:day)}
    }
    private var actions:[HealthCarePlan.Action]{appModel.health.carePlans.flatMap(\.actions)}
    private func adopted(_ action:HealthCarePlan.Action)->Bool {
        if let event=model.workspace.careEvents.last(where:{($0.actionID == action.id || !Set($0.factIDs ?? []).isDisjoint(with:Set(action.factIDs))) && $0.kind != "progress"}) {return event.kind == "adopted"}
        return appModel.health.facts.contains{action.factIDs.contains($0.id) && $0.preference.actionStatus == .current}
    }
    private var adoptedActions:[HealthCarePlan.Action]{actions.filter{adopted($0)}}
    @ViewBuilder private var currentPlan:some View {
        if model.didLoadStory {
            loadedPlan
        }
        else if model.initialStoryLoadFailed {Button("Retry loading care plan"){Task{await model.reload()}}}
        else {StoryLoadingPlaceholder(label:"Loading care plan",rows:3).padding()}
    }
    private var loadedPlan: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                Text("My care plan")
                    .font(StoryDesignTokens.sectionHeading)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 12) {
                    careSectionHeading("Following now")
                    if currentCarePlans.isEmpty {
                        Text("Actions you choose to follow will appear here.")
                            .font(StoryDesignTokens.body).foregroundStyle(.secondary)
                    } else {
                        carePlanGroups(currentCarePlans, following: true)
                    }
                }

                if !recordedCarePlans.isEmpty || currentCarePlans.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        careSectionHeading("Recorded recommendations")
                        if recordedCarePlans.isEmpty {
                            Text("Upload your care plan to see what your care team recommended.")
                                .font(StoryDesignTokens.body).foregroundStyle(.secondary)
                        } else {
                            Text("Not marked as part of your current plan.")
                                .font(StoryDesignTokens.caption).foregroundStyle(.secondary)
                            carePlanGroups(recordedCarePlans, following: false)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            if currentCarePlans.isEmpty && recordedCarePlans.isEmpty {
                Button { folderRouter.newCapture(importDocument: true) } label: {
                    Label("Upload a care plan", systemImage: "paperclip")
                        .font(StoryDesignTokens.label)
                        .foregroundStyle(StoryDesignTokens.onAction)
                        .frame(maxWidth: .infinity, minHeight: StoryDesignTokens.controlHeight)
                }
                .storyControlStyle(prominent: true)
                .padding(.horizontal).padding(.vertical, 8)
            }
        }
        .foregroundStyle(StoryDesignTokens.ink)
        .background(StoryDesignTokens.canvas)
    }

    private func careSectionHeading(_ title: String) -> some View {
        Text(title).font(StoryDesignTokens.heading(.title3)).accessibilityAddTraits(.isHeader)
    }

    private func carePlanGroups(_ plans: [HealthCarePlan], following: Bool) -> some View {
        ForEach(plans) { plan in
            if plan.id != plans.first?.id { Divider() }
            carePlanGroup(plan, following: following)
        }
    }

    // Adoption comes only from saved patient status/events, never inferred from a recommendation.
    private var currentCarePlans:[HealthCarePlan] {
        appModel.health.carePlans.filter{!$0.fictional && $0.actions.contains(where:adopted)}
    }
    private var recordedCarePlans:[HealthCarePlan] {
        appModel.health.carePlans.filter{!$0.fictional && $0.actions.contains{!adopted($0)}}
    }
    private func carePlanGroup(_ plan:HealthCarePlan,following:Bool)->some View {
        VStack(alignment:.leading,spacing:20) {
            VStack(alignment:.leading,spacing:6) {
                Text(HealthStoryText.displayName(plan.title)).font(StoryDesignTokens.label).accessibilityAddTraits(.isHeader)
                if let practitioner=plan.practitioner,!practitioner.isEmpty {
                    Text(practitioner).font(StoryDesignTokens.caption).foregroundStyle(.secondary)
                }
                if !plan.conditionNames.isEmpty {
                    Text(plan.conditionNames.map{HealthStoryText.displayName($0)}.joined(separator:" · "))
                        .font(StoryDesignTokens.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(CarePlanBucket.allCases,id:\.self) {bucket in
                let grouped=plan.actions.filter{$0.bucket == bucket && adopted($0) == following}
                if !grouped.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        Text(bucket == .carePlan ? "Actions":bucket == .followUp ? "Follow-up":"Considerations")
                            .font(StoryDesignTokens.label).accessibilityAddTraits(.isHeader)
                        ForEach(Array(grouped.enumerated()),id:\.element.id) {index,action in
                            if index > 0 {Divider()}
                            careRow(action,plan:plan,following:following)
                        }
                    }
                }
            }
        }
        .frame(maxWidth:.infinity,alignment:.leading)
    }
    private func careRow(_ action:HealthCarePlan.Action,plan:HealthCarePlan,following:Bool)->some View {
        VStack(alignment:.leading,spacing:8) {
            Text(action.text).font(StoryDesignTokens.font(.body, weight: .medium)).fixedSize(horizontal:false,vertical:true)
            if let timing=action.timing,!timing.isEmpty {
                careContext("When",value:timing)
            }
            if let context=action.context,!context.isEmpty {
                careContext("Context",value:context)
            }
            if let owner=action.owner,!owner.isEmpty {
                careContext("Who",value:owner)
            }
            ForEach(action.metadata.filter{$0.hasPrefix("Reminder:")},id:\.self) {
                Text($0).font(StoryDesignTokens.caption).foregroundStyle(.secondary)
            }
            if !following,action.status != "Current" {Text(action.status).font(StoryDesignTokens.caption).foregroundStyle(.secondary)}
            if let id = plan.sourceSessionID, appModel.health.snapshot.sessions.contains(where: { $0.id == id }) {
                NavigationLink(value: StoryRoute.record(id)) {
                    StorySourceTag(title: "Recommendation")
                }
                .accessibilityLabel("Open original record for "+action.text)
                .buttonStyle(.borderless)
            }
        }.padding(.vertical,6)
    }
    private func careContext(_ label:String,value:String)->some View {
        (Text(label+": ").fontWeight(.medium)+Text(value))
            .font(StoryDesignTokens.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
    }

}
struct StoryRecordsList:View {
    @ScaledMetric(relativeTo: .body) private var overviewTextSize = StoryDesignTokens.bodyBaseSize
    @ObservedObject var home:HomeViewModel
    var narrative:String?
    var showFirstRecordGuide = false
    var retryStoryLoad:(() -> Void)?
    var summaryStatus:String? = nil
    var shareStory:()->Void = {}
    private var carePlanLabel: some View {
        HStack(spacing: 12) {
            StoryRecordIcon(symbol: "list.bullet.clipboard")
                .saturation(showFirstRecordGuide ? 0 : 1)
                .opacity(showFirstRecordGuide ? 0.65 : 1)
            Text("My care plan").font(StoryDesignTokens.label)
                .foregroundStyle(showFirstRecordGuide ? Color.secondary : StoryDesignTokens.ink)
        }
        .frame(maxWidth: .infinity, minHeight: StoryDesignTokens.controlHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    var body:some View {
        List {
            Section {
                if showFirstRecordGuide { StoryEmptyOverview() }
                else if let narrative { Text(narrative.isEmpty ? "Your overview will appear here as your records are organized.":narrative).font(StoryDesignTokens.body).lineSpacing(StoryDesignTokens.readingLineSpacing(for: overviewTextSize)).textSelection(.enabled).padding(.vertical,8).listRowSeparator(.hidden).listRowBackground(StoryDesignTokens.canvas)
                } else if let retryStoryLoad { Button("Retry loading overview",action:retryStoryLoad) }
                else {StoryLoadingPlaceholder(label:"Loading overview").listRowSeparator(.hidden)}
                NavigationLink(value: StoryRoute.carePlan) { carePlanLabel }
                    .accessibilityHint("View your current plan and recorded recommendations")
                .listRowSeparator(.hidden).listRowBackground(StoryDesignTokens.canvas)
            }
            if let summaryStatus {
                Button(action:shareStory){
                    HStack {
                        if summaryStatus == StorySummaryGeneration.preparingLabel { StoryThinkingStatus(summaryStatus) }
                        else { Label(summaryStatus,systemImage:"doc.text").font(StoryDesignTokens.label) }
                        Spacer()
                        Image(systemName:"chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }.frame(minHeight:44).contentShape(Rectangle())
                }.accessibilityHint("Open share summary")
                    .listRowBackground(StoryDesignTokens.canvas)
            }
            if home.revision == 0 {
                if home.initialLoadFailed {Button("Retry loading records"){Task{await home.loadSessions()}}}
                else {StoryLoadingPlaceholder(label:"Loading records", rows:4).listRowSeparator(.hidden)}
            }
            if showFirstRecordGuide { Section("Records") { StoryEmptyRecord() } }
            StoryTimelineSections(records: home.sessions)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(StoryDesignTokens.canvas)

    }
}
struct StoryRecordEditor:View {
    let record:Session;let store:SessionStore
    @ObservedObject var home:HomeViewModel
    @EnvironmentObject private var health:HealthSummaryModel
    @EnvironmentObject private var auth:KindeAuthManager
    @State private var loaded=false
    @State private var pendingSave:Task<Void,Never>?
    @State private var text="";@State private var revisions:[StorySourceRevision]=[];@State private var error:String?;@State private var saved=false
    var body:some View {ScrollView{VStack(alignment:.leading,spacing:16){TextEditor(text:$text).frame(minHeight:350).accessibilityLabel("Record text")
            .onChange(of:text){_,value in
                guard loaded else {return};saved=false;pendingSave?.cancel()
                pendingSave=Task{do{try await store.saveStorySourceDraft(record.id,text:value);try await Task.sleep(nanoseconds:2_000_000_000);try Task.checkCancellation();await commit(value)}catch is CancellationError {}catch{self.error=error.localizedDescription}}
            }
        Text("Writing saves on this device immediately. Health details update after you pause typing.").font(StoryDesignTokens.font(.caption)).foregroundStyle(.secondary)
        Button("Done editing"){pendingSave?.cancel();let value=text;Task{await commit(value)}}
        if saved {Text("Correction saved. Your original is preserved.")}
        NavigationLink("Open original and attachments"){SessionDetailView(session:record,store:store,home:home,initialTab:.source)}
        DisclosureGroup("Text history"){ForEach(revisions.reversed()){revision in VStack(alignment:.leading){Text(revision.createdAt.formatted()).font(StoryDesignTokens.font(.caption));Text(revision.patientEdited ? "Patient-corrected text":"Original text").font(StoryDesignTokens.font(.caption, weight: .bold));Text(revision.text).textSelection(.enabled);Button("Restore this text"){text=revision.text}}}}
        if let error {Text(error).foregroundStyle(.red)}
    }.padding()}.navigationTitle(record.displayTitle).task{let workspace=try? await store.storyWorkspace();text=workspace?.sourceDrafts?[record.id.uuidString] ?? record.transcript;revisions=workspace?.sources.filter{$0.recordID==record.id} ?? [];loaded=true}}
    private func commit(_ value:String) async {
        do {
            try await store.reviseStorySource(record.id,text:value);saved=true
            revisions=try await store.storyWorkspace().sources.filter{$0.recordID==record.id}
            await health.refresh()
            guard auth.isSignedIn else {return}
            let transport=await auth.openAIChatTransport(byokFallback:"")
            await health.updateHealthStory(transport:transport,onDevice:false,explicitlyRequested:true)
        }catch{self.error=error.localizedDescription}
    }

}

// A native text layout keeps each rounded citation attachment atomic when wrapping.
private struct StoryAnswerText:UIViewRepresentable {
    let text:String
    let evidence:[StoryEvidence]
    let fontSize:CGFloat
    let isAnswer:Bool
    let openSource:(StoryEvidence,CGRect,CGFloat)->Void
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeUIView(context:Context)->UITextView {
        let view=UITextView()
        view.isEditable=false;view.isSelectable=true;view.isScrollEnabled=false
        view.backgroundColor = .clear;view.textContainerInset = .zero;view.textContainer.lineFragmentPadding=0
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        view.delegate=context.coordinator
        return view
    }
    func updateUIView(_ view:UITextView,context:Context) {
        context.coordinator.parent=self
        let traits=UITraitCollection(userInterfaceStyle:colorScheme == .dark ? .dark:.light)
        let font=StoryDesignTokens.readingFont(size: fontSize)
        let paragraph=NSMutableParagraphStyle()
        paragraph.lineSpacing=StoryDesignTokens.readingLineSpacing(for: fontSize)
        paragraph.paragraphSpacing=fontSize*0.4
        let attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:UIColor.label.resolvedColor(with:traits),.paragraphStyle:paragraph]
        let result=NSMutableAttributedString(string:"")
        let raw=text as NSString
        let regex=try! NSRegularExpression(pattern:#"[\[【［]\s*(E\d+(?:\s*[,;]\s*E\d+)*)\s*[\]】］]"#)
        let matches=isAnswer ? regex.matches(in:text,range:NSRange(location:0,length:raw.length)):[]
        var offset=0
        var citationNumbers:[String:Int]=[:]
        for match in matches {
            result.append(NSAttributedString(string:raw.substring(with:NSRange(location:offset,length:match.range.location-offset)),attributes:attributes))
            let ids=raw.substring(with:match.range(at:1)).components(separatedBy:CharacterSet(charactersIn:",; "))
            var seen:Set<String>=[]
            for source in ids.compactMap({id in evidence.first(where:{$0.id==id})}) where seen.insert(source.id).inserted {
                if citationNumbers[source.id] == nil {citationNumbers[source.id]=citationNumbers.count+1}
                let tagFont=StoryDesignTokens.readingFont(size: max(12,fontSize*0.75))
                let label=String(citationNumbers[source.id]!) as NSString
                let labelSize=label.size(withAttributes:[.font:tagFont])
                let diameter=max(24,ceil(max(labelSize.width,labelSize.height)+8))
                let size=CGSize(width:diameter,height:diameter)
                let image=UIGraphicsImageRenderer(size:size).image {_ in
                    UIColor.tertiarySystemFill.resolvedColor(with:traits).setFill()
                    UIBezierPath(ovalIn:CGRect(origin:.zero,size:size)).fill()
                    label.draw(at:CGPoint(x:(diameter-labelSize.width)/2,y:(diameter-labelSize.height)/2),
                               withAttributes:[.font:tagFont,.foregroundColor:UIColor.label.resolvedColor(with:traits)])
                }
                let attachment=NSTextAttachment();attachment.image=image
                attachment.bounds=CGRect(x:0,y:(font.capHeight-diameter)/2,width:diameter,height:diameter)
                let tag=NSMutableAttributedString(attachment:attachment)
                tag.addAttribute(.paragraphStyle,value:paragraph,range:NSRange(location:0,length:tag.length))
                tag.addAttribute(.link,value:URL(string:"story-source://citation/"+source.id)!,range:NSRange(location:0,length:tag.length))
                result.append(NSAttributedString(string:"\u{00a0}",attributes:attributes))
                result.append(tag)
            }
            offset=NSMaxRange(match.range)
        }
        result.append(NSAttributedString(string:raw.substring(from:offset),attributes:attributes))
        if !view.attributedText.isEqual(to:result) {view.attributedText=result;view.invalidateIntrinsicContentSize()}
    }
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:UITextView,context:Context)->CGSize? {
        guard let width=proposal.width,width>0 else{return nil}
        return uiView.sizeThatFits(CGSize(width:width,height:.greatestFiniteMagnitude))
    }
    final class Coordinator:NSObject,UITextViewDelegate {
        var parent:StoryAnswerText
        init(_ parent:StoryAnswerText){self.parent=parent}
        func textView(_ textView:UITextView,shouldInteractWith URL:URL,in characterRange:NSRange,interaction:UITextItemInteraction)->Bool {
            if URL.scheme=="story-source",let source=parent.evidence.first(where:{$0.id==URL.lastPathComponent}),
               let start=textView.position(from:textView.beginningOfDocument,offset:characterRange.location),
               let end=textView.position(from:start,offset:characterRange.length),
               let range=textView.textRange(from:start,to:end) {
                let anchor=textView.firstRect(for:range)
                var available:CGFloat=300
                if let window=textView.window {
                    let position=textView.convert(anchor,to:window)
                    let above=position.minY-window.safeAreaInsets.top-64
                    let below=window.bounds.height-window.safeAreaInsets.bottom-position.maxY-100
                    available=max(120,min(360,max(above,below)-24))
                }
                parent.openSource(source,anchor,available)
            }
            return false
        }
    }
}

/// A single generated document; the share sheet is the only step that sends it elsewhere.
private struct StoryTemplateShareView:View {
    let home:HomeViewModel
    let records:[Session]
    let store:SessionStore
    @ObservedObject var job:StorySummaryGeneration
    @EnvironmentObject private var auth:KindeAuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var pdfPreview:StorySummaryPreviewItem?
    private let template=StorySummaryTemplate.practitioner
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    VStack(alignment:.leading,spacing:6) {
                        Text(template.title).font(StoryDesignTokens.title)
                        TextField("Patient name",text:Binding(get:{job.patientName},set:{job.patientName=$0;job.nameEdited=true})).font(StoryDesignTokens.heading(.title3))
                            .textContentType(.name).disabled(job.generating)
                            .onSubmit {job.savePatientName()}
                    }
                    if job.generating {
                        StoryThinkingStatus(job.generationStatus)
                        Button("Stop"){Task{await job.stop(auth:auth)}}.disabled(job.operationID == nil)
                    }
                    if let error=job.error {Text(error).foregroundStyle(.secondary).accessibilityAddTraits(.isStaticText)}
                    if let summary=job.summary {
                        ForEach(Array(StorySummaryDocument.blocks(summary.text).enumerated()),id:\.offset) {_,block in
                            switch block {
                            case let .heading(title,level):
                                Text(title).font(level==2 ? StoryDesignTokens.heading(.title3):StoryDesignTokens.section).padding(.top,level==2 ? 12:4).accessibilityAddTraits(.isHeader)
                                if level == 2, title == "Labs & Investigations", let labs = summary.labReadings {
                                    ForEach(StoryLabSeries.grouped(labs)) { series in
                                        NavigationLink {
                                            List(series.readings) { reading in
                                                VStack(alignment: .leading, spacing: 6) {
                                                    Text(reading.dateLabel).font(StoryDesignTokens.caption)
                                                    Text(reading.valueLabel).font(StoryDesignTokens.section)
                                                    if !reading.interval.isEmpty { Text("Reference range " + reading.interval) }
                                                    if !reading.interpretation.isEmpty { Text(reading.interpretation) }
                                                    if let source = records.first(where: { $0.id == reading.recordID }) {
                                                        NavigationLink("Open original record") {
                                                            SessionDetailView(session: source, store: store, home: home, initialTab: .source)
                                                        }
                                                    }
                                                }
                                            }.navigationTitle(series.latest.name)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(series.title).font(StoryDesignTokens.section)
                                                HStack {
                                                    Text(series.latest.valueLabel).bold()
                                                    Spacer()
                                                    if !series.points.isEmpty {
                                                        StoryLabSparkline(series).frame(width: 100, height: 34)
                                                    }
                                                    Image(systemName: "chevron.right").font(.caption)
                                                }
                                                Text(series.latest.dateLabel).font(StoryDesignTokens.caption)
                                                if !series.latest.interval.isEmpty {Text("Reference range " + series.latest.interval).font(StoryDesignTokens.caption)}
                                                if !series.latest.interpretation.isEmpty {Text(series.latest.interpretation).font(StoryDesignTokens.caption)}
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                        }.buttonStyle(.plain)
                                        Divider()
                                    }
                                }
                            case let .bullet(text):
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").accessibilityHidden(true)
                                    Text(text).textSelection(.enabled)
                                }.font(StoryDesignTokens.body)
                            case let .paragraph(text):
                                Text(text).font(StoryDesignTokens.body).textSelection(.enabled)
                            case let .table(headers,rows):
                                ScrollView(.horizontal) {
                                    VStack(alignment:.leading,spacing:0) {
                                        HStack(alignment:.top,spacing:0) {
                                            ForEach(headers.indices,id:\.self){column in
                                                Text(headers[column]).font(StoryDesignTokens.font(.subheadline, weight: .bold)).frame(width:160,alignment:.leading).padding(10)
                                            }
                                        }.background(StoryDesignTokens.softSurface)
                                        ForEach(rows.indices,id:\.self) {row in
                                            HStack(alignment:.top,spacing:0) {
                                                ForEach(headers.indices,id:\.self){column in
                                                    Text(rows[row][column]).font(StoryDesignTokens.body).frame(width:160,alignment:.leading).padding(10)
                                                        .accessibilityLabel(headers[column]+": "+rows[row][column])
                                                }
                                            }
                                            Divider()
                                        }
                                    }.textSelection(.enabled)
                                }.accessibilityLabel("Summary table. Scroll horizontally to see all columns.")
                            }
                        }
                    } else if !job.restored && auth.isSignedIn {
                        StoryLoadingPlaceholder(label:"Loading saved summary",rows:3)
                    } else if !job.generating {
                        Button("Generate summary") {job.start(auth:auth)}
                            .buttonStyle(.borderedProminent).disabled(!auth.isSignedIn || !job.restored)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(20)
            }
            .navigationTitle("Share summary").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) {
                    Button {dismiss()} label:{Image(systemName:"xmark")}.accessibilityLabel("Close summary")
                }
                ToolbarItem(placement:.topBarTrailing) {
                    if let summary=job.summary {
                        Menu {
                            Button("Preview PDF",systemImage:"doc.richtext"){preparePDF(summary)}
                            Button("Regenerate summary",systemImage:"arrow.clockwise"){job.start(auth:auth)}.disabled(!auth.isSignedIn || !job.restored)} label: {Image(systemName:"ellipsis")}
                            .accessibilityLabel("Summary options").disabled(job.generating)
                    }
                }
                ToolbarItem(placement:.topBarTrailing){
                    if let summary=job.summary {
                        Button {preparePDF(summary,share:true)} label:{Label("Share PDF",systemImage:"square.and.arrow.up").labelStyle(.iconOnly)}
                            .storyControlStyle(prominent:true).disabled(job.generating)
                    }
                }
            }
            .onChange(of:job.summary?.generatedAt,initial:true){_,date in if let date {job.markViewed(date)}}
            .sheet(item:$pdfPreview) {item in
                if item.share {HealthActivitySheet(urls:[item.url])} else {StorySummaryPDFPreview(item:item)}
            }
            .task {await job.reloadSavedIfIdle()}
            .onDisappear {job.savePatientName()}
        }
    }
    private func preparePDF(_ summary:StorySharedSummary,share:Bool=false) {
        do {
            let data=try StorySummaryPDF.renderSummary(summary, title: template.title, patientName: job.patientName.trimmingCharacters(in: .whitespacesAndNewlines))
            let folder=FileManager.default.temporaryDirectory.appendingPathComponent("story-summary-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let url=folder.appendingPathComponent("Practitioner Summary.pdf")
            try data.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            guard let document=PDFDocument(data:data),document.pageCount>0 else {throw StoryEditError.invalidMutation}
            job.savePatientName()
            pdfPreview=StorySummaryPreviewItem(url:url,document:document,share:share)
        } catch {job.error="The PDF couldn’t be prepared. Your summary is still saved."}
    }
}

private struct SummaryStageFailure:Error {
    let state:String
    var canRepair:Bool { ["invalid_result","failed","incomplete","expired","not_found"].contains(state) }
}

@MainActor private final class StorySummaryGeneration: ObservableObject {
    let store:SessionStore
    let runner:StoryLabModel
    let template=StorySummaryTemplate.practitioner
    @Published var summary:StorySharedSummary?
    @Published var error:String?
    @Published var patientName=""
    var nameEdited=false
    @Published var generating=false
    static let preparingLabel = "Preparing summary…"
    @Published var generationStatus="Preparing summary…"
    @Published var restored=false
    @Published var operationID:UUID?
    var stageID:UUID?
    private var restoring=false
    private static let viewedKey="storyLab.lastViewedPractitionerSummary"
    @Published private var viewedVersion=UserDefaults.standard.string(forKey:viewedKey)
    private func version(_ date:Date)->String { ISO8601DateFormatter().string(from:date) }
    func markViewed(_ date:Date) {
        let value=version(date)
        guard value != viewedVersion else{return}
        viewedVersion=value;UserDefaults.standard.set(value,forKey:Self.viewedKey)
    }
    var homeStatus:String? {
        if generating {return Self.preparingLabel}
        if error != nil {return "Summary needs attention"}
        guard let summary,version(summary.generatedAt) != viewedVersion else{return nil}
        return "Summary ready to share"
    }
    init(store:SessionStore){self.store=store;runner=StoryLabModel(store:store)}
    func restore(auth:KindeAuthManager) async {
        guard !restoring,!restored else{return}
        restoring=true;defer{restoring=false}
        summary=try? await store.recoveredStorySharedSummary()
        await loadName(for:summary)
        operationID=try? await store.storyWorkspace().messages.last(where:{$0.role=="system" && $0.text=="Share template: "+template.rawValue && $0.state=="queued"})?.id
        restored=true
        if operationID != nil {start(auth:auth)}
    }
    private func loadName(for saved:StorySharedSummary?) async {
        guard !nameEdited else{return}
        if let name=saved?.patientName {patientName=name;return}
        let inferred = saved?.patientNameEdited == true ? nil : try? await store.recordedSummaryPatientName(for:saved)
        if !nameEdited {patientName=inferred ?? ""}
    }
    func reloadSavedIfIdle() async {
        guard restored,!generating else{return}
        do {
            let latest=try await store.recoveredStorySharedSummary()
            guard !generating else{return}
            if latest?.generatedAt != summary?.generatedAt {nameEdited=false}
            summary=latest;await loadName(for:latest)
        } catch {self.error="Your saved summary couldn’t be loaded."}
    }
    func start(auth:KindeAuthManager){
        guard restored,!generating else{return}
        generating=true;error=nil
        Task {await generate(auth:auth)}
    }
    func stop(auth:KindeAuthManager) async {
        guard let id=operationID else{return}
        let child=stageID
        await runner.stop(id,auth:auth)
        if let child {await runner.stop(child,auth:auth)}
    }
    private func generate(auth:KindeAuthManager) async {
        defer{generating=false;stageID=nil}
        do {
            let snapshot=try await store.storySummarySnapshot()
            guard !snapshot.evidence.isEmpty else {error="Add and process a record before generating a summary.";return}
            let id:UUID
            if let existing=operationID {id=existing} else {
                id=try await store.addStoryMessage(role:"system",text:"Share template: "+template.rawValue,state:"queued");operationID=id
            }
            // Freeze the snapshot once. Relaunch/retry resumes the same stages and receipts.
            let encoded=String(decoding:try JSONEncoder().encode(snapshot),as:UTF8.self)
            let saved=try await store.storyRequestBody(id,proposed:encoded) ?? encoded
            let frozen = try? JSONDecoder().decode(StorySummarySnapshot.self, from: Data(saved.utf8))
            var current: [StoryEvidence]
            if let frozen { current = frozen.evidence }
            else { current = try JSONDecoder().decode([StoryEvidence].self, from: Data(saved.utf8)) }
            let labInstructions = frozen?.labs.isEmpty == false ? "\nIn Labs & Investigations, the app inserts saved structured results and dates directly below the heading. Use this section for other documented results, imaging, investigations and follow-up. Omit repetition of those structured results and omit the missing-information placeholder when there are no additional investigations." : ""
            var provenance=Dictionary(uniqueKeysWithValues:current.map{($0.id,[$0])})
            var round=0;var text="";var accepted:[StoryEvidence]=[]
            while true {
                let batches=try StorySummaryBatching.batches(current)
                var next:[StoryEvidence]=[];var nextProvenance:[String:[StoryEvidence]]=[:]
                for (index,batch) in batches.enumerated() {
                    generationStatus=batches.count>1 ? "Preparing part \(index+1) of \(batches.count)…":"Preparing and checking your summary…"
                    var stage=try await store.prepareSummaryStage(parentID:id,stage:"\(round):\(index)")
                    stageID=stage.id
                    var stageText=stage.text;var originals=stage.evidence ?? []
                    if stage.state != "completed" || template.validatedText(stageText) == nil {
                        let context=round>0 ? "\nInputs are independently checked partial summaries of one frozen history. Consolidate them; deduplicate repetition, preserve conflicts and dates. 'Not documented' in a partial summary does not mean absent from other parts. Do not claim exhaustive coverage.":""
                        var result:[String:Any]=[:]
                        do { result=try await runner.request(id:stage.id,kind:"chat",revision:0,before:"",after:template.prompt+labInstructions+context,targets:[],auth:auth,summaryEvidence:batch)
                        } catch let failure as SummaryStageFailure where failure.canRepair {
                            // A terminal receipt will never produce another result under its original ID.
                        }
                        let needsShortening = batches.count == 1 && ((result["text"] as? String).flatMap(template.validatedText)?.count ?? 0) > 3600
                        if needsShortening || result["kind"] as? String != "answer" || (result["text"] as? String).flatMap(template.validatedText) == nil || (result["citationIDs"] as? [String])?.isEmpty != false {
                            stage = try await store.prepareSummaryStage(parentID:id,stage:"\(round):\(index):compact")
                            stageID = stage.id
                            let concise = "\nProduce a shorter complete handoff of about 2500 characters including headings. Use short bullets, each on its own line starting with '- '. Omit pipe tables. Complete the last section."
                            result = try await runner.request(id:stage.id,kind:"chat",revision:0,before:"",after:template.prompt+labInstructions+context+concise,targets:[],auth:auth,summaryEvidence:batch)
                        }
                        guard result["kind"] as? String == "answer",let raw=result["text"] as? String,let valid=template.validatedText(raw),let citations=result["citationIDs"] as? [String],!citations.isEmpty,Set(citations).isSubset(of:Set(batch.map(\.id))) else {throw StoryEditError.invalidMutation}
                        stageText=valid
                        originals=citations.flatMap{provenance[$0] ?? []}
                        originals=Dictionary(originals.map{($0.id,$0)},uniquingKeysWith:{a,_ in a}).values.sorted{$0.id<$1.id}
                        if stage.state != "completed" {try await store.completeSummaryStage(stage.id,text:stageText,evidence:originals)}
                    }
                    text=stageText;accepted=originals
                    let key="E"+String(index+1)
                    next.append(StoryEvidence(id:key,text:stageText,recordID:nil,title:"Checked partial summary \(index+1)"))
                    nextProvenance[key]=originals
                }
                stageID=nil
                if batches.count==1 {break}
                current=next;provenance=nextProvenance;round+=1
            }
            let identifiedName = !nameEdited && summary?.patientNameEdited != true && patientName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? StorySummaryDocument.patientName(in:text):patientName
            var document=StorySharedSummary(templateID:template.rawValue,text:StorySummaryDocument.body(text),evidence:accepted,patientName:identifiedName)
            document.patientNameEdited = nameEdited || summary?.patientNameEdited == true
            document.labReadings = frozen?.labs
            patientName=identifiedName ?? ""
            try await store.completeStorySharedSummary(id,summary:document)
            summary=document;operationID=nil;nameEdited=false
        } catch {
            if let id=operationID,let message=try? await store.storyWorkspace().messages.first(where:{$0.id==id}),message.state=="cancelled" {
                operationID=nil;self.error="Generation stopped. Your previous summary is still available."
            } else if let failure=error as? SummaryStageFailure, failure.state == "budget_exhausted" {
                if let id=operationID {try? await store.failStorySharedSummary(id)};operationID=nil
                self.error="Summary processing has reached its spending limit."
            } else if error is StoryEditError || error is SummaryStageFailure {
                if let id=operationID {try? await store.failStorySharedSummary(id)}
                operationID=nil;self.error="The summary couldn’t be verified. Try generating it again."
            } else {self.error="The summary couldn’t be completed. Try again to resume the saved attempt."}
        }
    }
    func savePatientName() {
        guard nameEdited,summary != nil else{return}
        let name=patientName
        Task {try? await store.setSharedSummaryPatientName(name)}
    }
}


private struct StorySummaryPreviewItem:Identifiable {
    let id=UUID()
    let url:URL
    let document:PDFDocument
    let share:Bool
}
private struct StorySummaryPDFPreview:View {
    let item:StorySummaryPreviewItem
    @Environment(\.dismiss) private var dismiss
    @State private var sharing=false
    var body:some View {
        NavigationStack {
            StorySummaryPDFCanvas(document:item.document)
                .navigationTitle("PDF preview").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.topBarLeading){Button("Close"){dismiss()}}
                    ToolbarItem(placement:.topBarTrailing){Button("Share PDF",systemImage:"square.and.arrow.up"){sharing=true}}
                }
                .sheet(isPresented:$sharing){HealthActivitySheet(urls:[item.url])}
        }
    }
}
private struct StorySummaryPDFCanvas:UIViewRepresentable {
    let document:PDFDocument
    func makeUIView(context:Context)->PDFView {
        let view=PDFView();view.autoScales=true;view.displayMode = .singlePageContinuous
        view.document=document;return view
    }
    func updateUIView(_ view:PDFView,context:Context) {
        if view.document !== document {view.document=document;view.autoScales=true}
    }
}

struct StoryTimelineSections: View {
    let records: [Session]
    @Environment(\.storyRouter) private var captureRouter
    private func recordSymbol(_ record:Session)->String {
        if let kind=record.sourceAssets?.first?.kind {
            switch kind {
            case .audio:return "waveform"
            case .pdf:return "doc.richtext"
            case .image:return "photo"
            case .multiPageScan:return "doc.viewfinder"
            case .plainText:return "doc.text"
            }
        }
        switch record.inputType {
        case .audio:return "waveform"
        case .documentImage:return "photo"
        case .documentScan:return "doc.viewfinder"
        case .document,.documentFile:return "doc.text"
        }
    }
    private var months:[Date] {Array(grouped.keys).sorted(by:>)}
    private var grouped:[Date:[Session]] {
        Dictionary(grouping:records) {Calendar.current.dateInterval(of:.month,for:$0.date)?.start ?? $0.date}
    }
    var body: some View {
            ForEach(months,id:\.self) {month in
                Section {
                    ForEach((grouped[month] ?? []).sorted{$0.date == $1.date ? $0.id.uuidString < $1.id.uuidString:$0.date > $1.date}) {record in
                        Button {
                            if record.capture?.isDraft == true { captureRouter?.capture = record }
                            else { captureRouter?.open(.record(record.id)) }
                        } label: {
                            HStack(alignment:.top,spacing:14) {
                                StoryRecordIcon(symbol: recordSymbol(record))
                                VStack(alignment:.leading,spacing:5) {
                                    Text(record.displayTitle).font(StoryDesignTokens.label).foregroundStyle(.primary).fixedSize(horizontal:false,vertical:true)
                                    Text((record.capture?.isDraft == true ? "Draft · " : "Added ")+record.date.formatted(date:.abbreviated,time:.shortened)).font(StoryDesignTokens.caption).foregroundStyle(.secondary)
                                    if record.processingError != nil {Label("Needs another try",systemImage:"exclamationmark.circle").font(StoryDesignTokens.font(.caption)).foregroundStyle(.secondary)}
                                }
                            }.padding(.vertical,8)
                        }.buttonStyle(.plain).listRowSeparator(.hidden).listRowBackground(StoryDesignTokens.canvas)
                    }
                } header: {StorySectionHeading(title: month.formatted(.dateTime.month(.wide).year()))}
            }
    }
}
