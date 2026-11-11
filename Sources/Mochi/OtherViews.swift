import MochiKit
import ServiceManagement
import SwiftUI

struct UpcomingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.calendar.authorized {
                ContentUnavailableView {
                    Label("Calendar access is off", systemImage: "calendar")
                } description: {
                    Text("Mochi reads your macOS Calendar to list meetings and name recordings. It never writes to it.")
                } actions: {
                    Button("Allow Calendar Access") {
                        Task {
                            await model.calendar.requestAccess()
                            if !model.calendar.authorized { CapturePermission.openSettings("Privacy_Calendars") }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if model.calendar.meetings.isEmpty {
                ContentUnavailableView("Nothing scheduled", systemImage: "calendar",
                                       description: Text("Meetings with a call link in the next 7 days appear here."))
            } else {
                List {
                    ForEach(days, id: \.0) { day in
                        SwiftUI.Section(day.0) {
                            ForEach(day.1) { MeetingRow(meeting: $0, showCalendar: true) }
                        }
                    }
                    Text("From the Calendar app on this Mac (\(model.calendar.sourceSummary)): meetings with a Zoom, Meet, FaceTime or Teams link, or \"call\" in the title, for the next 7 days. Mochi records only when you press Record or accept the prompt.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
        }
        .navigationTitle("Upcoming")
        .navigationSubtitle("Next 7 days, from the Calendar app")
        .onAppear { model.calendar.refresh() }
    }

    private var days: [(String, [Meeting])] {
        var out: [(String, [Meeting])] = []
        for m in model.calendar.meetings {
            let key = m.start.dayHeader
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(m) } else { out.append((key, [m])) }
        }
        return out
    }
}

struct ProjectView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var state = TaskEditState()

    var body: some View {
        List(selection: $state.selection) {
            SwiftUI.Section("Calls") {
                let calls = model.calls.filter { $0.projectID == project.id }
                if calls.isEmpty { Text("No calls tagged \(project.name) yet.").foregroundStyle(.tertiary) }
                ForEach(calls) { call in
                    CallRow(call: call)
                        .contentShape(.rect)
                        .onTapGesture { model.selectedCallID = call.id; model.section = .calls }
                }
            }
            let review = model.pendingSuggestions.filter { $0.suggestion.projectID == project.id }
            if !review.isEmpty {
                SwiftUI.Section("To Review") {
                    ForEach(review) { SuggestionRow(callID: $0.callID, suggestion: $0.suggestion) }
                }
            }
            SwiftUI.Section("Tasks") {
                let tasks = model.tasks.filter { $0.projectID == project.id && !$0.done }
                if tasks.isEmpty { Text("No open tasks.").foregroundStyle(.tertiary) }
                ForEach(tasks) { TaskListRow(task: $0, state: $state) }
            }
        }
        .listStyle(.inset)
        .taskListActions($state)
        .navigationTitle(project.name)
        .navigationSubtitle("Project")
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let session = model.session {
            Text("Recording · \(TranscriptText.clock(session.savedSeconds))")
            Text(session.call.title)
            Divider()
            Button(session.paused ? "Resume" : "Pause") { model.togglePause() }
                .keyboardShortcut("p", modifiers: [.control, .option])
            Button("Stop Recording") { model.stopRecording() }
                .keyboardShortcut("r", modifiers: [.control, .option])
            Button("Copy Transcript So Far") { model.copyTranscript(session.call.id) }
        } else {
            if let app = model.detectedApp {
                Button("Record \(app.name) Call") { model.startRecording(app: app) }
                Divider()
            }
            Button("Start Recording") { model.startRecording() }
                .keyboardShortcut("r", modifiers: [.control, .option])
            if Updater.shared.available != nil {
                Button("Install Mochi Update") { Updater.shared.install() }
            }
            if model.calendar.authorized, !model.calendar.meetings.isEmpty {
                Divider()
                Text("Upcoming")
                ForEach(model.calendar.meetings.prefix(3)) { m in
                    Button("\(m.start.formatted(.dateTime.hour().minute()))  \(m.title)") { model.startRecording(event: m) }
                }
            }
        }
        Divider()
        Button("Open Mochi") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        SettingsLink { Text("Settings…") }.keyboardShortcut(",")
        Button("Quit Mochi") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("showPill") private var showPill = true
    @AppStorage("language") private var language = "auto"
    @AppStorage("summaries") private var summaries = "claude"
    @AppStorage("cloudSync") private var cloudSync = true
    @AppStorage("remindBefore") private var remindBefore = 1
    @AppStorage("recordOnJoin") private var recordOnJoin = true
    @AppStorage("ownerName") private var ownerName = ""
    @State private var setupCode = ""
    @State private var hasKey = Summarizer.apiKey() != nil
    @State private var newKey = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var refresh = 0

    var body: some View {
        // Reading `refresh` re-evaluates the form (permissions, keys) without rebuilding it: an
        // .id(refresh) here threw the scroll position back to the top on every calendar switch.
        let _ = refresh
        Form {
            if MochiConfig.cloudConfigured { AccountSection() }
            SwiftUI.Section("Permissions") {
                permissionRow("Microphone", hint: "Your side of the call", granted: CapturePermission.microphoneGranted,
                              pane: "Privacy_Microphone")
                permissionRow("System Audio Recording", hint: "The other side, from the call app only. No screen recording.",
                              granted: nil, pane: "Privacy_AudioCapture")
                permissionRow("Calendar", hint: "Upcoming meetings and call names", granted: model.calendar.authorized,
                              pane: "Privacy_Calendars")
            }
            if model.calendar.authorized {
                SwiftUI.Section {
                    ForEach(model.calendar.choices) { c in
                        Toggle(isOn: Binding(get: { c.included }, set: { model.calendar.setIncluded(c.id, $0); refresh += 1 })) {
                            Text(c.title)
                            Text(c.account).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Calendars")
                } footer: {
                    Text("Mochi lists meetings only from the calendars switched on. Subscribed and other people's calendars start off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.calendar.authorized {
                SwiftUI.Section {
                    Picker("Remind me", selection: $remindBefore) {
                        Text("Off").tag(-1)
                        Text("When it starts").tag(0)
                        Text("1 minute before").tag(1)
                        Text("2 minutes before").tag(2)
                        Text("5 minutes before").tag(5)
                        Text("10 minutes before").tag(10)
                    }
                    Toggle(isOn: $recordOnJoin) {
                        Text("Record when I join")
                        Text("Join on the reminder opens the call and starts recording.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .disabled(remindBefore < 0)
                } header: {
                    Text("Meeting Reminders")
                } footer: {
                    Text("A card at the top right for meetings with a call link, with Join, Start Recording and Snooze.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SwiftUI.Section("Transcription") {
                Picker("Language", selection: $language) {
                    Text("Automatic (English, Dutch)").tag("auto")
                    Text("English").tag("en")
                    Text("Dutch").tag("nl")
                }
                LabeledContent("Engine") {
                    Text("Parakeet, on this Mac").foregroundStyle(.secondary)
                }
                Picker(selection: $summaries) {
                    Text("Claude").tag("claude")
                    Text("Off").tag("off")
                } label: {
                    Text("Summaries")
                    Text("After each call, the transcript is sent to Claude for a summary and suggested tasks, with your project names and notes and your open tasks so the suggestions fit. Nothing is added until you review it. Recordings stay on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if summaries == "claude" {
                    LabeledContent {
                        TextField("Me", text: $ownerName).frame(width: 200)
                    } label: {
                        Text("Your name")
                        Text("How summaries name you in action items, and how Mochi tells your tasks from other people's.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Claude API key") {
                        if hasKey {
                            Label("Saved in Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            SecureField("sk-ant-…", text: $newKey)
                                .frame(width: 200)
                                .onSubmit { Summarizer.saveKey(newKey); newKey = ""; hasKey = Summarizer.apiKey() != nil }
                        }
                    }
                }
            }
            VoicesSection()
            SwiftUI.Section("General") {
                LabeledContent("Start or stop recording") { Text("⌃⌥R").foregroundStyle(.secondary) }
                Toggle("Show in menu bar", isOn: $showMenuBar)
                Toggle("Show the recording pill", isOn: $showPill)
                if MochiConfig.cloudConfigured {
                Toggle(isOn: $cloudSync) {
                    Text("Sync to Supabase")
                    Text("A text copy of calls, summaries and tasks for the Claude connector. Audio stays on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if cloudSync {
                    if CloudSync.token() != nil {
                        LabeledContent {
                            CopyButton(title: "Copy Setup Code", prominent: false) {
                                if let code = CloudSync.setupCode() {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(code, forType: .string)
                                }
                            }
                        } label: {
                            Text("Another Mac")
                            Text("Paste this code in Mochi's Settings on your other Mac: it connects the sync and brings the Claude key along.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        LabeledContent {
                            SecureField("mochi-setup:…", text: $setupCode)
                                .frame(width: 200)
                                .onSubmit {
                                    if CloudSync.apply(setupCode: setupCode) {
                                        setupCode = ""
                                        refresh += 1
                                        CloudSync.shared.start()
                                    }
                                }
                        } label: {
                            Text("Setup code")
                            Text("From Mochi's Settings on your other Mac: Copy Setup Code.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent {
                        HStack {
                            CopyButton(title: "Copy URL", prominent: false) {
                                NSPasteboard.general.clearContents()
                                if let url = CloudSync.connectorURL { NSPasteboard.general.setString(url, forType: .string) }
                            }
                            CopyButton(title: "Copy Key", prominent: false) {
                                if let value = CloudSync.connectorHeaderValue() {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(value, forType: .string)
                                }
                            }
                        }
                    } label: {
                        Text("Claude connector")
                        Text("In claude.ai: Settings, Connectors, Add custom connector. Paste the URL, choose No sign-in, and add a request header named x-api-key with the key as its value.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                }
                LabeledContent("Version") {
                    Text("\(Updater.shared.currentVersion) (build \(Updater.shared.currentBuild))").foregroundStyle(.secondary)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.open(model.storage.root) }
                } label: {
                    Text("Recordings")
                    Text(model.storage.root.path(percentEncoded: false)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // The grouped form scrolls on its own; the window resizes, and opens tall enough for most of it.
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 800, minHeight: 360, idealHeight: 640)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            hasKey = Summarizer.apiKey() != nil
            launchAtLogin = SMAppService.mainApp.status == .enabled
            refresh += 1
        }
    }

    /// `granted` nil: macOS has no API to read the audio capture permission; the first recording asks.
    private func permissionRow(_ title: String, hint: String, granted: Bool?, pane: String) -> some View {
        LabeledContent {
            if granted == true {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button("Open System Settings") { CapturePermission.openSettings(pane) }
            }
        } label: {
            Text(title)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mic = CapturePermission.microphoneGranted

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Mochi needs two permissions").font(.title.bold())
            Text("Both sides of a call are recorded on this Mac, and the audio never leaves it.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            GroupBox {
                VStack(spacing: 10) {
                    HStack {
                        Image(systemName: "mic").frame(width: 22)
                        VStack(alignment: .leading) {
                            Text("Microphone")
                            Text("Your side of the call").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mic {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Allow") { Task { mic = await CapturePermission.requestMicrophone() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    Divider()
                    HStack {
                        Image(systemName: "speaker.wave.2").frame(width: 22)
                        VStack(alignment: .leading) {
                            Text("System Audio Recording")
                            Text("The other side, from the call app only. macOS asks on your first recording.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .padding(6)
            }
            Text("Not needed: Screen Recording, Accessibility.").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            HStack {
                Spacer()
                Button("Continue") {
                    UserDefaults.standard.set(true, forKey: "didFinishWelcome")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!mic)
            }
        }
        .padding(24)
        .frame(width: 520, height: 460)
    }
}

/// Sign in with a link emailed to you. One account across your Macs and iPhone.
struct AccountSection: View {
    @State private var email: String?
    @State private var typed = ""
    @State private var state: String?
    @State private var sending = false

    var body: some View {
        SwiftUI.Section("Account") {
            if let email {
                LabeledContent {
                    Button("Sign Out") {
                        Task {
                            await Account.shared.signOut()
                            await CloudSync.shared.refreshAccount()
                            self.email = nil
                        }
                    }
                } label: {
                    Text("Signed in as \(email)")
                    Text("Calls, transcripts, summaries and tasks sync with your other devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                LabeledContent {
                    HStack {
                        TextField("Email", text: $typed).frame(width: 200)
                        Button(sending ? "Sending…" : "Send Sign-in Link") {
                            sending = true
                            Task {
                                do {
                                    try await Account.shared.sendLink(to: typed)
                                    state = "Check your email and click the link on this Mac."
                                } catch {
                                    state = error.localizedDescription
                                }
                                sending = false
                            }
                        }
                        .disabled(sending || !typed.contains("@"))
                    }
                } label: {
                    Text("Sign in")
                    Text(state ?? "One account for your Macs and iPhone. No password: Mochi emails you a link.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { email = await Account.shared.email() }
        .onReceive(NotificationCenter.default.publisher(for: .accountChanged)) { _ in
            Task { email = await Account.shared.email() }
        }
    }
}

/// The people Mochi knows by voice, with a way to forget one.
struct VoicesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let voices = model.knownVoices().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        SwiftUI.Section {
            if voices.isEmpty {
                Text("None yet. Click a speaker's label in a transcript to name them.")
                    .foregroundStyle(.secondary)
            }
            ForEach(voices) { voice in
                LabeledContent {
                    Button("Forget", role: .destructive) { model.forgetVoice(voice.id) }
                        .buttonStyle(.borderless)
                } label: {
                    Text(voice.name)
                    Text(voice.prints.isEmpty ? "Name only" : (voice.prints.count == 1 ? "From 1 call" : "From \(voice.prints.count) calls"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Voices")
        } footer: {
            Text("Mochi recognises these people on later calls and labels their lines. Voiceprints stay on this Mac and are never synced; only the names in transcripts are.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
