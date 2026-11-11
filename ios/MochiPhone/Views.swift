import MochiKit
import SwiftUI
import UIKit

extension Project {
    var swiftColor: Color {
        switch color {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "blue": .blue
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "brown": .brown
        default: .gray
        }
    }
}

struct Dot: View {
    let project: Project?
    var body: some View {
        Circle().fill(project?.swiftColor ?? Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
    }
}

/// "Sam’s Mac mini" reads as "Mac mini" in lists.
func shortDevice(_ name: String?) -> String? {
    guard let name else { return nil }
    for sep in ["’s ", "'s "] {
        if let r = name.range(of: sep) { return String(name[r.upperBound...]) }
    }
    return name
}

extension Date {
    var dayHeader: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if cal.isDateInTomorrow(self) { return "Tomorrow" }
        return formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

// MARK: Calls

struct CallsTab: View {
    @Environment(PhoneModel.self) private var model
    @Binding var settings: Bool
    @State private var search = ""
    @State private var deleting: Call?
    /// The open call. On the Duo's inner display (regular width) the list and the call sit side by
    /// side, like Mail or the Claude app; on the outer display the split collapses to a stack.
    @State private var selection: String? = Root.debugArg("-call")
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var groups: [(String, [Call])] {
        var out: [(String, [Call])] = []
        let list = model.calls.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        for call in list {
            let key = call.startedAt.dayHeader
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(call) } else { out.append((key, [call])) }
        }
        return out
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { call in
                            NavigationLink(value: call.id) { CallRow(call: call) }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { deleting = call } label: { Label("Delete", systemImage: "trash") }
                                }
                                .contextMenu {
                                    Button { UIPasteboard.general.string = TranscriptText.copyText(call: call, segments: model.transcript(call.id)) } label: {
                                        Label("Copy Transcript", systemImage: "doc.on.doc")
                                    }
                                    if let s = model.summary(call.id) {
                                        Button { UIPasteboard.general.string = s.markdown } label: { Label("Copy Summary", systemImage: "text.quote") }
                                    }
                                    Menu("Set Project") {
                                        ForEach(model.projects) { p in Button(p.name) { model.setProject(call.id, p) } }
                                        Button("None") { model.setProject(call.id, nil) }
                                    }
                                    Button(role: .destructive) { deleting = call } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if model.calls.isEmpty {
                    ContentUnavailableView("No calls yet", systemImage: "phone",
                        description: Text(model.syncing ? "Fetching your calls…" : "Calls you record on your Mac show up here. Tap Record for a meeting in the room."))
                }
            }
            .searchable(text: $search, prompt: "Search calls")
            .refreshable { await model.sync() }
            .navigationTitle("Calls")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { settings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .alert("Delete this call everywhere?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete", role: .destructive) { if let c = deleting { model.deleteCall(c.id) }; deleting = nil }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("The transcript, summary and notes are removed from your Mac too. Audio on the Mac is kept.")
            }
            .onChange(of: model.calls.map(\.id), initial: true) { _, ids in
                if let s = selection, !ids.contains(s) { selection = nil }
                // Open wide (Duo unfolded): show the latest call rather than an empty pane.
                if selection == nil, sizeClass == .regular { selection = ids.first }
            }
        } detail: {
            if let selection {
                CallDetail(id: selection).id(selection)
            } else {
                ContentUnavailableView("No call selected", systemImage: "phone",
                    description: Text("Pick a call to read its summary and transcript."))
            }
        }
    }
}

struct CallRow: View {
    @Environment(PhoneModel.self) private var model
    let call: Call

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Dot(project: model.project(call.projectID))
                Text(call.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                Text(call.startedAt.formatted(.dateTime.hour().minute())).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 16)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        if model.processing.contains(call.id) { return "Transcribing on this iPhone…" }
        var parts = [TranscriptText.duration(call.duration)]
        if let app = call.appName { parts.append(app) }
        if let device = shortDevice(call.device) { parts.append(device) }
        return parts.joined(separator: " · ")
    }
}

struct CallDetail: View {
    @Environment(PhoneModel.self) private var model
    let id: String
    @State private var tab = Root.debugArg("-detailTab").flatMap(Int.init) ?? 0
    @State private var notes = ""
    @State private var copied = false
    @State private var renaming: String?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var notesFocused: Bool

    private func shareText(_ call: Call) -> String {
        var text = TranscriptText.copyText(call: call, segments: model.transcript(id))
        if let s = model.summary(id) { text += "\n\nSummary\n\n" + s.markdown }
        return text
    }

    var body: some View {
        let _ = model.version
        if let call = model.call(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(call.title).font(.title2.bold())
                    Text([call.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()),
                          TranscriptText.duration(call.duration), shortDevice(call.device)].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Menu {
                        ForEach(model.projects) { p in Button(p.name) { model.setProject(id, p) } }
                        Divider()
                        Button("None") { model.setProject(id, nil) }
                    } label: {
                        HStack(spacing: 6) {
                            Dot(project: model.project(call.projectID))
                            Text(model.project(call.projectID)?.name ?? "No project")
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4).background(.quaternary, in: .capsule)
                    }
                    Picker("View", selection: $tab) {
                        Text("Transcript").tag(0)
                        Text("Summary").tag(1)
                        Text("Notes").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 6)
                    switch tab {
                    case 0: transcript(call)
                    case 1: SummaryView(call: call)
                    default:
                        TextEditor(text: $notes)
                            .focused($notesFocused)
                            .frame(minHeight: 260)
                            .scrollContentBackground(.hidden)
                            .padding(8).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                            .onChange(of: notes) { _, text in model.saveNotes(text, for: id) }
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let summary = model.summary(id)
                        UIPasteboard.general.string = tab == 1 && summary != nil ? summary!.markdown
                            : TranscriptText.copyText(call: call, segments: model.transcript(id))
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                    } label: {
                        // An explicit HStack: toolbars drop a Label's title, and the words are the point.
                        HStack(spacing: 6) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
                            Text(copied ? "Copied" : (tab == 1 && model.summary(id) != nil ? "Copy Summary" : "Copy Transcript"))
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareText(call)) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let s = model.summary(id) {
                            Button { UIPasteboard.general.string = s.markdown } label: { Label("Copy Summary", systemImage: "text.quote") }
                        }
                        Button { UIPasteboard.general.string = TranscriptText.copyText(call: call, segments: model.transcript(id)) } label: {
                            Label("Copy Transcript", systemImage: "doc.on.doc")
                        }
                        Button { renaming = call.title } label: { Label("Rename", systemImage: "pencil") }
                        Divider()
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    } label: { Label("More", systemImage: "ellipsis") }
                }
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: Binding(get: { renaming ?? "" }, set: { renaming = $0 }))
                Button("Save") {
                    if let t = renaming?.trimmingCharacters(in: .whitespaces), !t.isEmpty, var c = model.call(id) { c.title = t; model.save(c) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("Delete this call everywhere?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { model.deleteCall(id); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The transcript, summary and notes are removed from your Mac too.") }
            .onAppear { notes = model.storage.notes(for: id) }
            .onChange(of: call.updatedAt) { _, _ in if !notesFocused { notes = model.storage.notes(for: id) } }
        } else {
            ContentUnavailableView("Call not found", systemImage: "phone")
        }
    }

    @ViewBuilder private func transcript(_ call: Call) -> some View {
        let inPerson = TranscriptText.isInPerson(call)
        let turns = inPerson ? TranscriptText.paragraphs(model.transcript(id)) : TranscriptText.turns(model.transcript(id))
        if inPerson && !turns.isEmpty {
            Label("One microphone, so no speaker split. Paragraphs follow the pauses.", systemImage: "mic")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if model.processing.contains(id) {
            if let status = model.modelStatus {
                VStack(alignment: .leading, spacing: 6) {
                    Text(status.text + "…").foregroundStyle(.secondary)
                    ProgressView(value: status.fraction)
                    Text("About 500 MB. Keep Mochi open until this finishes; after that it works offline.")
                        .font(.footnote).foregroundStyle(.tertiary)
                }
            } else {
                HStack(spacing: 8) { ProgressView(); Text("Transcribing on this iPhone…").foregroundStyle(.secondary) }
            }
        } else if let error = model.transcribeErrors[id] {
            VStack(alignment: .leading, spacing: 8) {
                Label("The transcript could not be written.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("Try Again") { model.transcribe(id) }.buttonStyle(.bordered)
            }
        } else if turns.isEmpty {
            Text("No speech was heard in this recording.").foregroundStyle(.secondary)
        }
        let voices = TranscriptText.voiceCount(model.transcript(id))
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(turns) { turn in
                VStack(alignment: .leading, spacing: 3) {
                    if inPerson {
                        Text(TranscriptText.clock(turn.start)).font(.footnote.weight(.medium)).foregroundStyle(.tertiary).monospacedDigit()
                    } else {
                        Text(TranscriptText.label(turn, call: call, voices: voices))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(turn.speaker == .me ? Color.accentColor : .secondary)
                    }
                    Text(turn.text).font(.body).textSelection(.enabled)
                }
            }
        }
    }
}

struct SummaryView: View {
    @Environment(PhoneModel.self) private var model
    let call: Call

    var body: some View {
        if let s = model.summary(call.id) {
            VStack(alignment: .leading, spacing: 18) {
                Text(s.text).font(.body.weight(.medium))
                if !s.topics.isEmpty {
                    Text("Key Points").font(.title3.weight(.semibold))
                    ForEach(s.topics, id: \.self) { t in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t.title).font(.headline)
                            Text(t.lead).foregroundStyle(.secondary)
                            ForEach(t.points, id: \.self) { p in
                                HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(.tertiary); Text(p) }
                            }
                        }
                    }
                }
                if let suggestions = s.suggestions {
                    PhoneSuggestedTasks(callID: call.id, suggestions: suggestions)
                    let others = s.actionItems.filter { !Summary.ownNames.contains($0.name) }
                    if !others.isEmpty {
                        Text("Others' Action Items").font(.title3.weight(.semibold))
                        ForEach(others, id: \.self) { o in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(o.name).font(.headline)
                                ForEach(o.items, id: \.self) { item in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(.tertiary); Text(item) }
                                }
                            }
                        }
                    }
                } else if !s.actionItems.isEmpty {
                    Text("Action Items").font(.title3.weight(.semibold))
                    ForEach(s.actionItems, id: \.self) { o in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(o.name).font(.headline)
                            ForEach(o.items, id: \.self) { item in
                                let line = Summary.ownNames.contains(o.name) ? item : "\(item) (\(o.name))"
                                let added = model.tasks.contains { $0.callID == call.id && $0.text == line }
                                Button {
                                    if !added { model.addTask(line, callID: call.id, projectID: call.projectID) }
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                                            .foregroundStyle(added ? Color.green : Color.accentColor)
                                        Text(item).foregroundStyle(added ? .secondary : .primary).multilineTextAlignment(.leading)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .textSelection(.enabled)
        } else {
            Text(model.processing.contains(call.id) ? "The summary is written once the transcript is ready."
                 : "No summary yet. Your Mac writes it after the call.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Tasks

extension TaskStatus {
    var symbol: String {
        switch self {
        case .todo: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .blocked: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .todo: .secondary
        case .inProgress: .accentColor
        case .blocked: .orange
        case .done: .green
        }
    }
}

struct TasksTab: View {
    @Environment(PhoneModel.self) private var model
    @State private var newTask = ""
    @State private var editing: TaskItem?
    @FocusState private var adding: Bool
    /// "" is all projects, "none" is tasks without one.
    @AppStorage("taskProjectFilter") private var projectFilter = ""

    private func matches(_ projectID: String?) -> Bool {
        if projectFilter.isEmpty || (projectFilter != "none" && model.project(projectFilter) == nil) { return true }
        return projectFilter == "none" ? projectID == nil : projectID == projectFilter
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                        TextField("New task", text: $newTask)
                            .focused($adding)
                            .submitLabel(.done)
                            .onSubmit {
                                let t = newTask.trimmingCharacters(in: .whitespaces)
                                if !t.isEmpty { model.addTask(t, projectID: model.project(projectFilter)?.id) }
                                newTask = ""
                            }
                    }
                }
                let review = model.pendingSuggestions.filter { matches($0.suggestion.projectID) }
                if !review.isEmpty {
                    Section {
                        ForEach(review) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.callTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                PhoneSuggestionRow(callID: p.callID, suggestion: p.suggestion)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { model.dismissSuggestion(p.callID, p.id) } label: {
                                    Label("Dismiss", systemImage: "xmark")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button { model.acceptSuggestion(p.callID, p.id) } label: { Label("Add", systemImage: "plus") }
                                    .tint(.accentColor)
                            }
                        }
                    } header: {
                        HStack {
                            Label("To Review", systemImage: "sparkles")
                            Spacer()
                            if review.count > 1 {
                                Button("Add All") { withAnimation { model.acceptAll() } }
                                    .font(.subheadline.weight(.semibold))
                                    .textCase(nil)
                            }
                        }
                    } footer: {
                        Text("Suggested from your calls. Tap + to add, swipe to dismiss.")
                    }
                }
                ForEach(TaskStatus.ordered) { status in
                    let items = model.tasks.filter { $0.status == status && matches($0.projectID) }
                        .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { task in
                                TaskRow(task: task)
                                    .contentShape(.rect)
                                    .onTapGesture { editing = task }
                                    .swipeActions(edge: .leading) {
                                        Button { model.setStatus(task.id, task.done ? .todo : .done) } label: {
                                            Label(task.done ? "Reopen" : "Done", systemImage: task.done ? "arrow.uturn.backward" : "checkmark")
                                        }
                                        .tint(.green)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { model.deleteTask(task.id) } label: { Label("Delete", systemImage: "trash") }
                                        Button { model.setStatus(task.id, .blocked) } label: { Label("Blocked", systemImage: "exclamationmark.circle") }
                                            .tint(.orange)
                                    }
                            }
                        } header: {
                            Label(status.title, systemImage: status.symbol).foregroundStyle(status.tint)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.sync() }
            .navigationTitle(projectFilter == "none" ? "No Project" : model.project(projectFilter)?.name ?? "Tasks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Project", selection: $projectFilter) {
                            Text("All Projects").tag("")
                            ForEach(model.projects) { p in Text(p.name).tag(p.id) }
                            Text("No Project").tag("none")
                        }
                    } label: {
                        Label("Project", systemImage: projectFilter.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                            : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Label("New Task", systemImage: "plus") }
                }
            }
            .sheet(item: $editing) { task in TaskEditor(task: task) }
        }
    }
}

struct TaskRow: View {
    @Environment(PhoneModel.self) private var model
    let task: TaskItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                let next: TaskStatus = task.status == .todo ? .inProgress : task.status == .done ? .todo : .done
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                model.setStatus(task.id, next)
            } label: {
                Image(systemName: task.status.symbol).foregroundStyle(task.status.tint).font(.title3)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.text).strikethrough(task.done).foregroundStyle(task.done ? .secondary : .primary)
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if let reason = task.blockedReason, task.status == .blocked {
                    Text(reason).font(.subheadline).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    if let due = task.due {
                        Label(task.isOverdue() ? "Overdue · \(due.dayHeader)" : due.dayHeader, systemImage: "calendar")
                            .foregroundStyle(task.isOverdue() ? Color.orange : .secondary)
                    }
                    if let call = model.call(task.callID) { Text(call.title).foregroundStyle(.secondary).lineLimit(1) }
                }
                .font(.footnote)
            }
            Spacer()
            Dot(project: model.project(task.projectID))
        }
    }
}

struct TaskEditor: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var task: TaskItem
    @State private var hasDue = false
    @State private var due = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $task.text)
                        .font(.body.weight(.medium))
                    TextField("Notes", text: Binding(get: { task.notes ?? "" }, set: { task.notes = $0.isEmpty ? nil : $0 }),
                              axis: .vertical)
                        .lineLimit(3...10)
                }
                Picker("Status", selection: $task.status) {
                    ForEach(TaskStatus.ordered) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                if task.status == .blocked {
                    TextField("Waiting on…", text: Binding(get: { task.blockedReason ?? "" }, set: { task.blockedReason = $0 }))
                }
                Toggle("Deadline", isOn: $hasDue)
                if hasDue { DatePicker("Date", selection: $due, displayedComponents: .date) }
                Picker("Project", selection: Binding(get: { task.projectID ?? "" }, set: { task.projectID = $0.isEmpty ? nil : $0 })) {
                    Text("None").tag("")
                    ForEach(model.projects) { Text($0.name).tag($0.id) }
                }
            }
            .navigationTitle("Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        task.due = hasDue ? due : nil
                        model.update(task)
                        dismiss()
                    }
                }
            }
            .onAppear { hasDue = task.due != nil; due = task.due ?? Date() }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: Upcoming

struct UpcomingTab: View {
    @Environment(PhoneModel.self) private var model
    @Binding var recording: Bool

    var body: some View {
        NavigationStack {
            List {
                let days = Dictionary(grouping: model.events) { Calendar.current.startOfDay(for: $0.start) }
                ForEach(days.keys.sorted(), id: \.self) { day in
                    Section(day.dayHeader) {
                        ForEach(days[day]!.sorted { $0.start < $1.start }) { e in
                            HStack(spacing: 12) {
                                Text(e.start.formatted(.dateTime.hour().minute())).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .leading)
                                Image(systemName: e.appName == nil ? "person.2.fill" : (["FaceTime", "WhatsApp"].contains(e.appName!) ? "phone.fill" : "video.fill"))
                                    .foregroundStyle(.secondary).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title).font(.body.weight(.medium)).lineLimit(2)
                                    Text([e.appName, e.attendees.prefix(2).joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }
                                        .joined(separator: " · "))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                // In the room only: video calls are recorded on the Mac.
                                if e.appName == nil, abs(e.start.timeIntervalSinceNow) < 15 * 60 || (e.start < Date() && e.end > Date()) {
                                    Button {
                                        Recorder.shared.nextTitle = e.title
                                        recording = true
                                    } label: { Label("Record", systemImage: "record.circle.fill") }
                                        .buttonStyle(.glassProminent).tint(.red).controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if model.events.isEmpty {
                    ContentUnavailableView("Nothing scheduled", systemImage: "calendar",
                        description: Text("Meetings with a call link in the next 7 days, from your Mac's calendar."))
                }
            }
            .refreshable { await model.sync() }
            .navigationTitle("Upcoming")
            .navigationSubtitle("Next 7 days")
        }
    }
}

// MARK: Settings

struct SettingsSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: model.email ?? "")
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                        .confirmationDialog("Sign out of Mochi on this iPhone?", isPresented: $confirmSignOut) {
                            Button("Sign Out", role: .destructive) {
                                Task { await Account.shared.signOut(); await model.refreshAccount(); dismiss() }
                            }
                        }
                }
                Section("Sync") {
                    LabeledContent("Last synced") {
                        Text(model.lastSync.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet")
                    }
                    if let error = model.syncError { Text(error).foregroundStyle(.orange).font(.footnote) }
                    Button("Sync Now") { Task { await model.sync() } }
                }
                Section {
                    LabeledContent("Recordings on this iPhone", value: storageUsed)
                } footer: {
                    Text("Calls recorded on your Macs keep their audio on the Mac. Transcripts and summaries are here.")
                }
                Section {
                    LabeledContent("Version",
                        value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var storageUsed: String {
        let root = model.storage.callsFolder
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL]) ?? []
        let bytes = files.filter { $0.pathExtension == "m4a" }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: Record

/// One tap records: the cover opens already recording, because the fear is a meeting that started
/// without the recording. Swipe down or the chevron minimises to the accessory; only Stop stops.
struct RecordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PhoneModel.self) private var model
    private var recorder: Recorder { Recorder.shared }
    @State private var savedID: String?

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40) }
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel(savedID == nil ? "Minimise" : "Done")
                Spacer()
            }
            if let id = savedID {
                saved(id)
            } else {
                live
            }
        }
        .padding(20)
        .task {
            if recorder.state == .idle && savedID == nil {
                await recorder.start(title: recorder.nextTitle ?? "Meeting, \(Date().formatted(.dateTime.hour().minute()))")
                recorder.nextTitle = nil
            }
        }
    }

    private var live: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text(recorder.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text(recorder.state == .paused ? "Paused · in the room · this iPhone" : "Recording · in the room · this iPhone")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(TranscriptText.clock(recorder.elapsed))
                .font(.system(size: 72, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(recorder.state == .paused ? .secondary : .primary)
            Label("\(recorder.savedBytes) saved on this iPhone", systemImage: "checkmark.circle.fill")
                .font(.subheadline).foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
            Waveform(levels: recorder.levels, tint: recorder.state == .paused ? .secondary : .primary, height: 90)
            Text("The timer counts audio written to disk. You can lock the screen; recording continues.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let error = recorder.error { Text(error).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center) }
            Spacer()
            HStack(spacing: 34) {
                Button { recorder.togglePause() } label: {
                    Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill").font(.title).frame(width: 64, height: 64)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(recorder.state == .paused ? "Resume" : "Pause")
                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    savedID = recorder.stop()
                } label: {
                    Image(systemName: "stop.fill").font(.largeTitle).foregroundStyle(.white).frame(width: 76, height: 76)
                }
                .glassEffect(.regular.tint(.red).interactive(), in: .circle)
                .accessibilityLabel("Stop and save")
            }
            Text("Stop saves the meeting and transcribes it here.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func saved(_ id: String) -> some View {
        let call = model.call(id)
        let done = !model.processing.contains(id)
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
            Text("Saved").font(.title2.bold())
            Text([call?.title, call.map { TranscriptText.duration($0.duration) }, "on this iPhone"].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            GroupBox {
                HStack {
                    if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } else { ProgressView() }
                    Text(done ? "Transcript ready" : "Transcribing on this iPhone")
                    Spacer()
                }
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                    Text("Your Mac mini writes the summary").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 6)
            }
            Text("Keep Mochi open while it transcribes. The call is already in Calls.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.glassProminent)
        }
    }
}

struct Waveform: View {
    let levels: [Double]
    var tint: Color = .red
    var height: CGFloat = 90

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule().fill(tint).frame(width: 3, height: max(3, height * level))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}
