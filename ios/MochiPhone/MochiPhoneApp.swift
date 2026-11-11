import MochiKit
import MochiTranscribe
import SwiftUI

@main
struct MochiPhoneApp: App {
    @State private var model = PhoneModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Root()
                .environment(model)
                .onOpenURL { url in
                    Task {
                        try? await Account.shared.handle(url)
                        await model.refreshAccount()
                        await model.sync()
                    }
                }
                .task {
                    #if DEBUG
                    // Simulator tests: `simctl launch ... -signInURL <link>` signs in without the
                    // "Open in Mochi?" prompt a tapped link brings up.
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "-signInURL"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
                        try? await Account.shared.handle(url)
                    }
                    #endif
                    await model.refreshAccount()
                    model.resumeTranscriptions()
                    await model.sync()
                    // Fetch the speech model ahead of the first recording, so a transcript is quick.
                    Task.detached(priority: .background) { try? await Transcriber.shared.prepare() }
                }
                .onChange(of: phase) { _, now in
                    if now == .active { Task { await model.sync() } }
                }
        }
    }
}

struct Root: View {
    @Environment(PhoneModel.self) private var model
    @State private var tab = Root.debugArg("-tab").flatMap(Int.init) ?? 0
    @State private var recording = Root.debugArg("-record") != nil
    @State private var settings = false
    @State private var recorder = Recorder.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Simulator screenshots only: `-tab 1`, `-call <id>`, `-record 1`, `-detailTab 1`.
    static func debugArg(_ name: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }

    var body: some View {
        if !model.signedIn {
            SignInView()
        } else if sizeClass == .regular {
            // The Duo unfolded: one sidebar beside the content, the way the Claude app does it.
            WideShell(recording: $recording, settings: $settings)
                .fullScreenCover(isPresented: $recording) { RecordView() }
                .sheet(isPresented: $settings) { SettingsSheet() }
        } else {
            TabView(selection: $tab) {
                Tab("Calls", systemImage: "phone", value: 0) { CallsTab(settings: $settings) }
                Tab("Tasks", systemImage: "checklist", value: 1) { TasksTab() }
                    .badge(model.openTaskCount)
                Tab("Upcoming", systemImage: "calendar", value: 2) { UpcomingTab(recording: $recording) }
            }
            // Record lives above the tab bar on every tab (the way Music keeps Now Playing), and
            // turns into the live status while a recording runs.
            .tabViewBottomAccessory { RecordAccessory(open: $recording) }
            .tabBarMinimizeBehavior(.onScrollDown)
            .fullScreenCover(isPresented: $recording) { RecordView() }
            .sheet(isPresented: $settings) { SettingsSheet() }
        }
    }
}

/// Regular width (the Duo's inner display): Record, Tasks and Upcoming at the top of one sidebar,
/// recent calls below them, and whatever is picked fills the rest. Folding the Duo hands back to
/// the tab layout, so nothing is lost either way.
struct WideShell: View {
    @Environment(PhoneModel.self) private var model
    @Binding var recording: Bool
    @Binding var settings: Bool
    @State private var pane: Pane?
    @State private var search = ""

    enum Pane: Hashable { case call(String), tasks, upcoming }

    private var groups: [(String, [Call])] {
        var out: [(String, [Call])] = []
        for call in model.calls where search.isEmpty || call.title.localizedCaseInsensitiveContains(search) {
            let key = call.startedAt.dayHeader
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(call) } else { out.append((key, [call])) }
        }
        return out
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    RecordAccessory(open: $recording)
                        .padding(.vertical, 6)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    NavigationLink(value: Pane.tasks) { Label("Tasks", systemImage: "checklist") }
                        .badge(model.openTaskCount)
                    NavigationLink(value: Pane.upcoming) { Label("Upcoming", systemImage: "calendar") }
                }
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { call in
                            NavigationLink(value: Pane.call(call.id)) { CallRow(call: call) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $search, prompt: "Search calls")
            .refreshable { await model.sync() }
            .navigationTitle("Mochi")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { settings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .onChange(of: model.calls.map(\.id), initial: true) { _, ids in
                if case .call(let id) = pane, !ids.contains(id) { pane = nil }
                if pane == nil, let first = ids.first { pane = .call(first) }
            }
        } detail: {
            switch pane {
            case .call(let id): CallDetail(id: id).id(id)
            case .tasks: TasksTab()
            case .upcoming: UpcomingTab(recording: $recording)
            case nil:
                ContentUnavailableView("No calls yet", systemImage: "phone",
                    description: Text("Calls you record on your Mac show up here. Tap Record for a meeting in the room."))
            }
        }
    }
}

struct RecordAccessory: View {
    @Binding var open: Bool
    private var recorder: Recorder { Recorder.shared }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 10) {
                if recorder.state == .idle {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text("Record a meeting").font(.body.weight(.medium))
                    Spacer()
                } else {
                    Waveform(levels: Array(recorder.levels.suffix(12)), tint: recorder.state == .paused ? .secondary : .red, height: 20)
                        .frame(width: 60)
                    Text(TranscriptText.clock(recorder.elapsed)).font(.body.weight(.semibold)).monospacedDigit()
                    Text(recorder.state == .paused ? "Paused" : "Recording").foregroundStyle(.secondary)
                    Spacer()
                    Button { recorder.stop() } label: { Image(systemName: "stop.fill").foregroundStyle(.red) }
                        .accessibilityLabel("Stop and save")
                }
            }
            .padding(.horizontal, 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.state == .idle ? "Record a meeting" : "Recording, \(TranscriptText.clock(recorder.elapsed))")
    }
}

/// One email, a link, no password.
struct SignInView: View {
    @Environment(PhoneModel.self) private var model
    @State private var email = ""
    @State private var sent = false
    @State private var error: String?
    @State private var sending = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("MochiIcon", bundle: nil)
                .resizable().frame(width: 96, height: 96).clipShape(.rect(cornerRadius: 22))
                .accessibilityHidden(true)
            Text("Mochi").font(.largeTitle.bold())
            Text("Your calls, transcripts, summaries and tasks, the same on your Macs and this iPhone.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if sent {
                VStack(spacing: 8) {
                    Image(systemName: "envelope.badge").font(.largeTitle).foregroundStyle(Color.accentColor)
                    Text("Check your email").font(.headline)
                    Text("Open the link from Mochi on this iPhone to sign in.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Use a different email") { sent = false }.font(.subheadline)
                }
                .padding(.top, 12)
            } else {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    .padding(12).background(.quaternary, in: .rect(cornerRadius: 12))
                Button {
                    sending = true
                    Task {
                        do { try await Account.shared.sendLink(to: email); sent = true; error = nil }
                        catch { self.error = error.localizedDescription }
                        sending = false
                    }
                } label: {
                    Text(sending ? "Sending…" : "Email Me a Sign-in Link").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending || !email.contains("@"))
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center) }
            Spacer()
            Text("No password. Only your account can sign in.").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(28)
    }
}
