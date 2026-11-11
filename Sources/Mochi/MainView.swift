import MochiKit
import SwiftUI

extension Project {
    var swiftColor: Color { Project.swiftColor(color) }

    static func swiftColor(_ name: String) -> Color {
        switch name {
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

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var adding = false
    @State private var editing: Project?

    private func confirmDelete(_ project: Project) {
        let alert = NSAlert()
        alert.messageText = "Delete \(project.name)?"
        alert.informativeText = "Calls and tasks tagged \(project.name) are kept, without a project."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.deleteProject(project.id) }
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(get: { Optional(model.section) }, set: { if let s = $0 { model.section = s } })) {
                Label("Today", systemImage: "sun.max").tag(Section.today)
                Label("Upcoming", systemImage: "calendar").tag(Section.upcoming)
                Label("Calls", systemImage: "phone").tag(Section.calls)
                // The badge must come before the tag: a modifier after .tag hides it from the
                // List's selection, and clicking Tasks then did nothing.
                Label("Tasks", systemImage: "checklist")
                    .badge(model.openTaskCount)
                    .tag(Section.tasks)
                SwiftUI.Section {
                    ForEach(model.projects) { project in
                        Label {
                            Text(project.name)
                        } icon: {
                            Circle().fill(project.swiftColor).frame(width: 10, height: 10)
                        }
                        .tag(Section.project(project.id))
                        .contextMenu {
                            Button("Edit Project…") { editing = project }
                            Divider()
                            Button("Delete Project…", role: .destructive) { confirmDelete(project) }
                        }
                    }
                    .onMove { model.moveProjects(from: $0, to: $1) }
                    Button { adding = true } label: {
                        Label("New Project", systemImage: "plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                } header: {
                    Text("Projects")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            switch model.section {
            case .today: TodayView()
            case .upcoming: UpcomingView()
            case .calls: CallsView(project: nil)
            case .tasks: TasksView(project: nil)
            case .project(let id):
                if let p = model.project(id) { ProjectView(project: p) } else { TodayView() }
            }
        }
        .sheet(isPresented: $adding) { ProjectEditor(project: nil) }
        .onAppear { if ProcessInfo.processInfo.environment["MOCHI_SHEET"] == "project" { adding = true } }
        .sheet(item: $editing) { ProjectEditor(project: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .showWelcome)) { _ in openWindow(id: "welcome") }
    }
}

// MARK: Shared pieces

struct ProjectDot: View {
    let project: Project?
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(project?.swiftColor ?? Color.secondary.opacity(0.35)).frame(width: size, height: size)
    }
}

/// The project tag: a pill that is a menu.
struct ProjectTag: View {
    @Environment(AppModel.self) private var model
    let project: Project?
    let onChange: (Project?) -> Void

    var body: some View {
        Menu {
            ForEach(model.projects) { p in Button(p.name) { onChange(p) } }
            Divider()
            Button("None") { onChange(nil) }
        } label: {
            HStack(spacing: 5) {
                ProjectDot(project: project)
                Text(project?.name ?? "No project")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.quaternary, in: .capsule)
        .fixedSize()
    }
}

struct CopyButton: View {
    let title: String
    var prominent = true
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        let b = Button {
            action()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .contentTransition(.symbolEffect(.replace))
        }
        if prominent { b.buttonStyle(.borderedProminent) } else { b.buttonStyle(.bordered) }
    }
}

/// A transcript: turns of Me and the other side, selectable, no timestamps (hover shows the time).
/// When the after-call pass told the other side's voices apart, each voice has its own label and
/// colour; clicking it plays a few seconds of that voice and names it.
struct TranscriptView: View {
    let segments: [Segment]
    let call: Call
    var live = false
    /// Calls without separate voices: the name for the whole other side.
    var onRenameThem: ((String) -> Void)?
    @State private var naming: Turn?
    @State private var newName = ""

    var body: some View {
        let turns = TranscriptText.turns(segments)
        let voices = TranscriptText.voiceCount(segments)
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(turns) { turn in
                TurnRow(turn: turn, call: call, voices: voices, live: live) {
                    let label = TranscriptText.label(turn, call: call, voices: voices)
                    newName = label == "Them" || label.hasPrefix("Speaker ") ? "" : label
                    naming = turn
                }
                .id(turn.id)
                .popover(isPresented: Binding(get: { naming?.id == turn.id }, set: { if !$0 { naming = nil } }),
                         arrowEdge: .leading) {
                    NameVoicePopover(call: call, turn: turn, voices: voices, name: $newName) { name in
                        if let speakerID = turn.speakerID { AppModel.shared.nameSpeaker(call.id, speakerID, name) }
                        else { onRenameThem?(name) }
                        naming = nil
                    }
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }
}

/// Names one voice: play a few seconds of it, take Mochi's guess, pick an invitee or type a name.
struct NameVoicePopover: View {
    @Environment(AppModel.self) private var model
    let call: Call
    let turn: Turn
    let voices: Int
    @Binding var name: String
    let done: (String) -> Void

    var body: some View {
        let speakerID = turn.speakerID
        let guess = speakerID.flatMap { model.guessName(call.id, $0) }
        let canPlay = speakerID.flatMap { model.speakers(call.id)?.speaker($0)?.sampleStart } != nil
        let suggestions = model.nameSuggestions(call.id).filter { $0.caseInsensitiveCompare(name) != .orderedSame }.prefix(6)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(speakerID == nil ? "Name for the other side" : "Who is this?").font(.headline)
                Spacer(minLength: 12)
                if let speakerID, canPlay {
                    let playing = model.playingSample == "\(call.id)/\(speakerID)"
                    Button {
                        model.playSample(call.id, speakerID)
                    } label: {
                        Label(playing ? "Stop" : "Listen", systemImage: playing ? "stop.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .controlSize(.small)
                    .help("Play a few seconds of this voice")
                }
            }
            if let guess, turn.name == nil {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.magnifyingglass").foregroundStyle(.secondary)
                    Text("Sounds like \(guess)").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Yes, \(guess)") { done(guess) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            TextField(voices > 1 ? "Speaker \(turn.speakerID.map(TranscriptText.speakerNumber) ?? 1)" : "Them", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { done(name) }
            if !suggestions.isEmpty {
                FlowChips(names: Array(suggestions)) { done($0) }
                    .frame(width: 240, alignment: .leading)
            }
            if speakerID != nil {
                Text("Mochi remembers this voice on this Mac and names it on your next calls.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(width: 240, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .onDisappear { model.stopSample() }
    }
}

/// Name suggestions as small buttons that wrap.
struct FlowChips: View {
    let names: [String]
    let pick: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
    }

    @ViewBuilder private var chips: some View {
        ForEach(names, id: \.self) { n in
            Button(n) { pick(n) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

struct TurnRow: View {
    @Environment(AppModel.self) private var model
    let turn: Turn
    let call: Call
    let voices: Int
    var live = false
    let onTapThem: () -> Void
    @State private var hovering = false

    /// Each voice of the other side keeps one colour through the call.
    static let voiceColors: [Color] = [.orange, .purple, .teal, .pink, .indigo, .brown, .mint]

    private var color: Color {
        if turn.speaker == .me { return .accentColor }
        guard voices > 1, let id = turn.speakerID else { return .secondary }
        return Self.voiceColors[(TranscriptText.speakerNumber(id) - 1) % Self.voiceColors.count]
    }

    /// "Lena?" while Mochi only thinks it is Lena.
    private var guess: String? {
        guard !live, turn.name == nil, let id = turn.speakerID else { return nil }
        return model.guessName(call.id, id)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Group {
                    if let guess {
                        Text(guess + "?").italic()
                    } else {
                        Text(TranscriptText.label(turn, call: call, voices: voices))
                    }
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .onTapGesture { if turn.speaker == .them, !live { onTapThem() } }
                .help(turn.speaker == .them && !live
                      ? (guess.map { "Sounds like \($0). Click to confirm or rename." }
                         ?? (turn.speakerID == nil ? "Click to name the other side" : "Click to hear and name this voice"))
                      : "")
                Text(TranscriptText.clock(turn.start))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    .opacity(hovering ? 1 : 0)
            }
            .frame(width: 76, alignment: .trailing)
            Text(turn.text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onHover { hovering = $0 }
    }
}

struct Banner: View {
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(text)
            Spacer()
            if let actionTitle, let action { Button(actionTitle, action: action) }
        }
        .padding(10)
        .background(.quaternary, in: .rect(cornerRadius: 10))
    }
}

extension Date {
    /// "Today, Sunday 1 November", "Tomorrow, Monday 2 November", "Tuesday 3 November".
    var dayHeader: String {
        let date = formatted(.dateTime.weekday(.wide).day().month(.wide))
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today, \(date)" }
        if cal.isDateInTomorrow(self) { return "Tomorrow, \(date)" }
        return date
    }

    /// "Today", "Yesterday", weekday this week, else "3 November".
    var dayGroup: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if cal.isDateInTomorrow(self) { return "Tomorrow" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: self), to: cal.startOfDay(for: Date())).day ?? 0
        if abs(days) < 7 { return formatted(.dateTime.weekday(.wide)) }
        return formatted(.dateTime.day().month(.wide))
    }
}

/// New or edit: a name, a colour, and a line on what it is about (for suggested tasks).
struct ProjectEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project?
    @State private var name = ""
    @State private var color = "blue"
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(project == nil ? "New Project" : "Edit Project").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            VStack(alignment: .leading, spacing: 6) {
                TextField("What it's about", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                Text("Optional. Helps Mochi put suggested tasks in the right project, for example \"Brand films: edits, grading and delivery\".")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Colour").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(Project.colors, id: \.self) { c in
                        Button { color = c } label: {
                            Circle().fill(Project.swiftColor(c)).frame(width: 18, height: 18)
                                .overlay { if c == color { Circle().strokeBorder(.primary, lineWidth: 2).padding(-3) } }
                        }
                        .buttonStyle(.plain)
                        .help(c.capitalized)
                        .accessibilityLabel(c.capitalized)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(project == nil ? "Add Project" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            name = project?.name ?? ""
            note = project?.note ?? ""
            color = project?.color ?? Project.freeColor(in: model.projects)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let about = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if var p = project {
            p.name = trimmed
            p.color = color
            p.note = about.isEmpty ? nil : about
            model.updateProject(p)
        } else {
            let p = model.addProject(name: trimmed, color: color, note: about.isEmpty ? nil : about)
            model.section = .project(p.id)
        }
        dismiss()
    }
}
