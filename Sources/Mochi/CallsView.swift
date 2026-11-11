import MochiKit
import SwiftUI

struct CallsView: View {
    @Environment(AppModel.self) private var model
    let project: Project?
    @State private var search = ""

    private var calls: [Call] {
        model.calls.filter { call in
            (project == nil || call.projectID == project?.id) &&
            (search.isEmpty || call.title.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            List(selection: $model.selectedCallID) {
                ForEach(groups, id: \.0) { group in
                    SwiftUI.Section(group.0) {
                        ForEach(group.1) { call in CallRow(call: call).tag(call.id) }
                    }
                }
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .top, spacing: 0) {
                TextField("Search Calls", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(width: 290)
            .overlay {
                if model.calls.isEmpty {
                    Text("No calls yet").foregroundStyle(.tertiary)
                }
            }
            Divider().ignoresSafeArea()
            Group {
            if let call = model.call(model.selectedCallID) {
                CallDetail(call: call).id(call.id)
            } else if model.calls.isEmpty {
                ContentUnavailableView("No calls yet", systemImage: "phone",
                    description: Text("Press Start Recording on Today, or accept the prompt when a call app starts using your mic."))
            } else {
                ContentUnavailableView("Select a call", systemImage: "phone")
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(project?.name ?? "Calls")
        .navigationSubtitle("\(calls.count) recorded")
    }

    private var groups: [(String, [Call])] {
        var out: [(String, [Call])] = []
        for call in calls {
            let key = call.startedAt.dayGroup
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(call) } else { out.append((key, [call])) }
        }
        return out
    }
}

struct CallRow: View {
    @Environment(AppModel.self) private var model
    let call: Call

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                ProjectDot(project: model.project(call.projectID))
                Text(call.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                // The group header already says the day; the row says the time.
                Text(call.startedAt.formatted(.dateTime.hour().minute()))
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(secondLine).font(.subheadline).foregroundStyle(.secondary).padding(.leading, 16).lineLimit(1)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Rename") { model.selectedCallID = call.id; model.renamingCallID = call.id }
            Button("Copy Transcript") { model.copyTranscript(call.id) }
            Menu("Set Project") {
                ForEach(model.projects) { p in Button(p.name) { model.setProject(call.id, p) } }
                Divider()
                Button("None") { model.setProject(call.id, nil) }
            }
            Button("Show Recording in Finder") { model.showInFinder(call.id) }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete() }
        }
    }

    private var secondLine: String {
        switch call.status {
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .failed: return "Transcript failed"
        case .ready:
            var parts = [TranscriptText.duration(call.duration)]
            if let app = call.appName { parts.append(app) }
            if call.micOnly { parts.append("Mic only") }
            return parts.joined(separator: " · ")
        }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete this call?"
        alert.informativeText = "The recording, transcript and notes move to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.delete(call.id) }
    }
}

struct CallDetail: View {
    @Environment(AppModel.self) private var model
    let call: Call
    @State private var tab = ProcessInfo.processInfo.environment["MOCHI_TAB"] == "summary" ? 1 : 0
    @State private var title = ""
    @State private var editingTitle = ProcessInfo.processInfo.environment["MOCHI_RENAME_CALL"] != nil
    @State private var hoveringTitle = false
    @FocusState private var titleFocused: Bool
    @State private var notes = ""
    /// The notes as they are on disk, so typing does not re-read the file on every key.
    @State private var savedNotes = ""
    /// Stamps the call (and queues its sync) once typing pauses, not on every key.
    @State private var touchLater: Task<Void, Never>?
    @FocusState private var notesFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                // Click the title to rename it, like a Finder name: Return or clicking away
                // saves (and syncs), Esc cancels.
                if editingTitle {
                    TextField("Title", text: $title, axis: .vertical)
                        .font(.title.bold())
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .focused($titleFocused)
                        .onSubmit { commitTitle() }
                        .onExitCommand { editingTitle = false }   // Esc cancels the rename
                        .onChange(of: titleFocused) { old, new in if old && !new && editingTitle { commitTitle() } }
                        .task {
                            // Focus once the field is on screen: setting it in the same tick is ignored.
                            if title.isEmpty { title = call.title }
                            try? await Task.sleep(for: .milliseconds(60))
                            titleFocused = true
                        }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(call.title).font(.title.bold())
                        Image(systemName: "pencil")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .opacity(hoveringTitle ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .onHover { hoveringTitle = $0 }
                    .onTapGesture { startRename() }
                    .help("Click to rename")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Renames the call")
                }
                HStack(spacing: 10) {
                    Text(call.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                        .lineLimit(1)
                    Text(TranscriptText.duration(call.duration))
                    if let app = call.appName { Text(app) }
                    if model.isRemote(call), let device = call.device {
                        Label("Recorded on \(device)", systemImage: "laptopcomputer").labelStyle(.titleAndIcon)
                    }
                    ProjectTag(project: model.project(call.projectID)) { model.setProject(call.id, $0) }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                Divider().padding(.vertical, 12)

                if tab == 0 { transcriptTab } else { notesTab }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    Text("Transcript").tag(0)
                    Text("Summary").tag(1)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename") { startRename() }
                    Button("Show Recording in Finder") { model.showInFinder(call.id) }
                        .disabled(model.isRemote(call))
                    Button("Transcribe Again") { model.finishTranscript(call.id, offset: 0) }
                        .disabled(model.isRemote(call))
                } label: { Label("More Actions", systemImage: "ellipsis") }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                CopyButton(title: "Copy Transcript") { model.copyTranscript(call.id) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        .onAppear { loadNotes(); renameIfAsked() }
        .onChange(of: model.renamingCallID) { _, _ in renameIfAsked() }
        .onDisappear {
            if touchLater != nil { touchLater?.cancel(); touchLater = nil; model.touch(call.id) }
        }
        // Notes edited on the other Mac arrive by sync: take them in unless you are typing here.
        .onChange(of: call.updatedAt) { _, _ in
            if !notesFocused && touchLater == nil { loadNotes() }
        }
    }

    /// "Rename" from the list's right-click menu.
    private func renameIfAsked() {
        guard model.renamingCallID == call.id else { return }
        model.renamingCallID = nil
        startRename()
    }

    private func startRename() {
        title = call.title
        editingTitle = true
    }

    private func commitTitle() {
        let t = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, t != call.title { model.rename(call.id, to: t) }
        editingTitle = false
    }

    private func loadNotes() {
        savedNotes = model.storage.notes(for: call.id)
        notes = savedNotes
    }

    @ViewBuilder private var transcriptTab: some View {
        let _ = model.transcriptVersion
        let segments = model.transcript(call.id)
        if model.refining.contains(call.id) && !segments.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Polishing the transcript. You can copy it already.").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 4)
        } else if model.refining.contains(call.id) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing the transcript.").foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
        }
        if call.status == .failed {
            Banner(text: "The transcript could not be finished: \(call.failure ?? "unknown error"). The recording is saved.",
                   actionTitle: "Try Again") { model.finishTranscript(call.id, offset: 0) }
        }
        if segments.isEmpty && call.status == .ready && !model.refining.contains(call.id) {
            Text("No speech was heard in this recording.").foregroundStyle(.secondary)
        }
        voicesRow(segments)
        TranscriptView(segments: segments, call: call) { model.setThemName(call.id, $0) }
    }

    /// Calls from before Mochi told voices apart: offer to do it now (needs the audio on this Mac).
    @ViewBuilder private func voicesRow(_ segments: [Segment]) -> some View {
        let _ = model.voicesVersion
        if model.findingSpeakers.contains(call.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Telling the voices apart.").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 4)
        } else if call.status == .ready, !call.micOnly, !model.refining.contains(call.id), !TranscriptText.isInPerson(call),
                  model.speakers(call.id) == nil, segments.contains(where: { $0.speaker == .them }),
                  model.storage.track("them", of: call.id) != nil {
            Button {
                model.findSpeakers(call.id)
            } label: {
                Label("Tell the Voices Apart", systemImage: "person.2.wave.2")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Give each person on the other side their own label. Takes a few seconds.")
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder private var notesTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            SummarySection(call: call)
            notesEditor
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    @ViewBuilder private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(.headline).foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .focused($notesFocused)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 300)
                .onChange(of: notes) { _, text in
                    // Loading the notes on appear is not an edit: no save, no newer timestamp.
                    guard text != savedNotes else { return }
                    savedNotes = text
                    try? model.storage.saveNotes(text, for: call.id)
                    touchLater?.cancel()
                    let id = call.id
                    touchLater = Task {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        touchLater = nil
                        model.touch(id)
                    }
                }
            Text("Notes sync to your other Mac with the call.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// Summary, decisions and suggested tasks. Ticking a task adds it to Tasks.
struct SummarySection: View {
    @Environment(AppModel.self) private var model
    let call: Call

    var body: some View {
        let _ = model.summaryVersion
        VStack(alignment: .leading, spacing: 18) {
            if let summary = model.summary(call.id) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Summary").font(.headline).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(summary.provider) · \(summary.writtenAt.formatted(.dateTime.hour().minute()))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(summary.text).font(.system(size: 15, weight: .medium)).lineSpacing(4).textSelection(.enabled)
                }
                if !summary.topics.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Key Points").font(.title3.weight(.semibold))
                        ForEach(summary.topics, id: \.self) { topic in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(topic.title).font(.headline)
                                Text(topic.lead).font(.system(size: 14)).foregroundStyle(.secondary)
                                ForEach(topic.points, id: \.self) { point in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("•").foregroundStyle(.tertiary)
                                        Text(point).font(.system(size: 14)).lineSpacing(3)
                                    }
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
                if let suggestions = summary.suggestions {
                    SuggestedTasksCard(callID: call.id, suggestions: suggestions)
                    // Your own items are the suggested tasks above; other people's stay as notes.
                    let others = summary.actionItems.filter { !Summary.ownNames.contains($0.name) }
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Others' Action Items").font(.title3.weight(.semibold))
                            ForEach(others, id: \.self) { owner in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(owner.name).font(.headline)
                                    ForEach(owner.items, id: \.self) { item in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text("•").foregroundStyle(.tertiary)
                                            Text(item).font(.system(size: 14))
                                        }
                                    }
                                }
                            }
                        }
                        .textSelection(.enabled)
                    }
                } else if !summary.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Action Items").font(.title3.weight(.semibold))
                        ForEach(summary.actionItems, id: \.self) { owner in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(owner.name).font(.headline)
                                ForEach(owner.items, id: \.self) { item in
                                    let line = Summary.ownNames.contains(owner.name) ? item : "\(item) (\(owner.name))"
                                    let added = model.tasks.contains { $0.callID == call.id && $0.text == line }
                                    Button {
                                        if !added { model.addSuggestedTask(line, callID: call.id) }
                                    } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                                                .foregroundStyle(added ? Color.green : Color.accentColor)
                                            Text(item).font(.system(size: 14))
                                                .foregroundStyle(added ? .secondary : .primary)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .help(added ? "In Tasks" : "Add to Tasks")
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 14) {
                    Button("Copy Summary") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary.markdown, forType: .string)
                    }
                    .buttonStyle(.link).font(.caption)
                    Button("Summarise Again") { model.summarize(call.id) }
                        .buttonStyle(.link).font(.caption)
                }
            } else if model.summarizing.contains(call.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing the summary…").foregroundStyle(.secondary)
                }
            } else if let error = model.summaryErrors[call.id] {
                Banner(text: "The summary could not be written: \(error)", actionTitle: "Try Again") { model.summarize(call.id) }
            } else if call.status == .transcribing {
                Text("The summary is written once the transcript is finished.").foregroundStyle(.secondary)
            } else if !model.summariesOn {
                Text("Summaries are off. Turn them on in Settings.").foregroundStyle(.secondary)
            } else {
                Button { model.summarize(call.id) } label: { Label("Write Summary", systemImage: "sparkles") }
                    .buttonStyle(.bordered)
            }
        }
    }
}
