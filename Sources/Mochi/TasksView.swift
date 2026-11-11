import MochiKit
import SwiftUI
import UniformTypeIdentifiers

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

    /// What a click on the status circle moves to: To Do, In Progress, Done. Blocked is chosen in the menu.
    var next: TaskStatus {
        switch self {
        case .todo: .inProgress
        case .inProgress, .blocked: .done
        case .done: .todo
        }
    }
}

enum TaskLayout: String { case list, board }

/// What a task list or board is doing: the selected row, the task being edited in place, and the
/// task whose deadline picker is open. One per view, so only one task is ever edited at a time.
struct TaskEditState: Equatable {
    var selection: UUID?
    var editing: UUID?
    var pickingDate: UUID?

    /// Editing clears the row highlight, like Reminders, so the fields sit on the plain row.
    mutating func edit(_ id: UUID) { selection = nil; editing = id }

    /// Done editing: the row it was on stays selected.
    mutating func endEditing(_ id: UUID) {
        guard editing == id else { return }
        editing = nil
        selection = id
    }
}

struct TasksView: View {
    @Environment(AppModel.self) private var model
    let project: Project?
    @AppStorage("taskLayout") private var layout: TaskLayout = .list
    /// All tasks, or one project's: "" is all, "none" is tasks without a project.
    @AppStorage("taskProjectFilter") private var projectFilter = ""
    @State private var state = TaskEditState()

    /// The project shown: the one this view is for, else the filter's.
    private var shown: Project? { project ?? model.project(projectFilter) }
    private var showingNone: Bool { project == nil && projectFilter == "none" }

    private func matches(_ projectID: String?) -> Bool {
        if showingNone { return projectID == nil }
        guard let shown else { return true }
        return projectID == shown.id
    }

    private var tasks: [TaskItem] { model.tasks.filter { matches($0.projectID) } }

    /// Suggested tasks waiting for review (for a project: the ones Mochi put in it).
    private var review: [PendingSuggestion] {
        model.pendingSuggestions.filter { matches($0.suggestion.projectID) }
    }

    private var title: String {
        if let project { return project.name }
        if showingNone { return "Tasks · No Project" }
        return shown.map { "Tasks · \($0.name)" } ?? "Tasks"
    }

    var body: some View {
        let review = self.review
        VStack(spacing: 0) {
            if !review.isEmpty {
                // Folds away with its chevron, so a long list never pushes Tasks off screen for good.
                ReviewTray(items: review)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
            }
            content
        }
        .animation(.snappy, value: review)
        .navigationTitle(title)
            .navigationSubtitle("\(tasks.filter { !$0.done }.count) open")
            .task(id: model.newTaskID) {
                // Edit the new task once its row exists: focusing in the same tick as the insert is ignored.
                guard let id = model.newTaskID else { return }
                try? await Task.sleep(for: .milliseconds(80))
                state.edit(id)
                model.newTaskID = nil
            }
    }

    @ViewBuilder private var content: some View {
        Group {
            if tasks.isEmpty {
                ContentUnavailableView(shown == nil && !showingNone ? "No tasks" : "No tasks here", systemImage: "checklist",
                                       description: Text("Press ⌘N to add one."))
            } else if layout == .board {
                TaskBoard(tasks: tasks, project: shown, state: $state)
            } else {
                List(selection: $state.selection) {
                    ForEach(TaskStatus.ordered) { status in
                        let items = sorted(tasks.filter { $0.status == status })
                        if !items.isEmpty {
                            SwiftUI.Section {
                                ForEach(items) { TaskListRow(task: $0, state: $state) }
                            } header: {
                                StatusHeader(status: status, count: items.count)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .taskListActions($state)
                .animation(.default, value: model.tasks)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Layout", selection: $layout) {
                    Label("List", systemImage: "list.bullet").tag(TaskLayout.list)
                    Label("Board", systemImage: "rectangle.split.3x1").tag(TaskLayout.board)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Show tasks as a list or a board")
            }
            if project == nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Project", selection: $projectFilter) {
                            Text("All Projects").tag("")
                            Divider()
                            ForEach(model.projects) { p in
                                Label { Text(p.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(p.swiftColor) }
                                    .tag(p.id)
                            }
                            Divider()
                            Text("No Project").tag("none")
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Project", systemImage: projectFilter.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                     : "line.3.horizontal.decrease.circle.fill")
                    }
                    .help(shown.map { "Showing \($0.name). Choose a project to show." } ?? "Show one project's tasks")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { _ = model.addTask(project: shown) } label: {
                    Label("New Task", systemImage: "plus")
                }
            }
        }
    }

    /// Overdue first, then by deadline, then tasks with no deadline, newest first.
    private func sorted(_ items: [TaskItem]) -> [TaskItem] {
        items.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.createdAt > b.createdAt
            }
        }
    }
}

extension View {
    /// A task list that works like Reminders and Finder: a click selects a row, a double-click or
    /// Return edits it in place, a right-click anywhere on a row opens its menu, Delete deletes it.
    func taskListActions(_ state: Binding<TaskEditState>) -> some View {
        modifier(TaskListActions(state: state))
    }
}

private struct TaskListActions: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var state: TaskEditState

    func body(content: Content) -> some View {
        content
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let task = model.tasks.first(where: { $0.id == id }) {
                    TaskMenuItems(task: task, edit: { state.edit(id) }, pickDate: { state.pickingDate = id })
                }
            } primaryAction: { ids in
                if let id = ids.first { state.edit(id) }
            }
            .onDeleteCommand {
                if state.editing == nil, let id = state.selection { model.deleteTask(id) }
            }
            .onChange(of: state.selection) { _, new in
                // Picking another row ends the edit (the editor saves as it closes).
                if let editing = state.editing, let new, editing != new { state.editing = nil }
            }
    }
}

struct StatusHeader: View {
    let status: TaskStatus
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.symbol).foregroundStyle(status.tint)
            Text(status.title)
            Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// The deadline as a small label: "Today", "Tomorrow", "Fri 7 Nov", orange "Overdue · Mon 3 Nov".
struct DueLabel: View {
    let task: TaskItem

    var body: some View {
        if let due = task.due {
            let overdue = task.isOverdue()
            Label(overdue ? "Overdue · \(Self.text(due))" : Self.text(due), systemImage: "calendar")
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .foregroundStyle(overdue ? Color.orange : task.done ? Color.secondary : Self.soon(due) ? .primary : .secondary)
        }
    }

    static func text(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func soon(_ date: Date) -> Bool { date.timeIntervalSinceNow < 2 * 86_400 }
}

/// Edit, status, deadline, project and delete, shared by the list row and the board card.
struct TaskMenuItems: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    let edit: () -> Void
    let pickDate: () -> Void

    var body: some View {
        Button("Edit") { edit() }
        Divider()
        Menu("Status") {
            ForEach(TaskStatus.ordered) { s in
                Button { model.setStatus(task.id, s) } label: { Label(s.title, systemImage: s.symbol) }
            }
        }
        Menu("Deadline") {
            Button("Today") { model.setDue(task.id, Date()) }
            Button("Tomorrow") { model.setDue(task.id, Calendar.current.date(byAdding: .day, value: 1, to: Date())) }
            Button("Next Week") { model.setDue(task.id, Calendar.current.date(byAdding: .day, value: 7, to: Date())) }
            Button("Pick a Date…") { pickDate() }
            if task.due != nil {
                Divider()
                Button("Remove Deadline") { model.setDue(task.id, nil) }
            }
        }
        Menu("Project") {
            ForEach(model.projects) { p in Button(p.name) { var t = task; t.projectID = p.id; model.updateTask(t) } }
            Divider()
            Button("None") { var t = task; t.projectID = nil; model.updateTask(t) }
        }
        if let callID = task.callID {
            Button("Open Call") { model.selectedCallID = callID; model.section = .calls }
        }
        Divider()
        Button("Delete", role: .destructive) { model.deleteTask(task.id) }
    }
}

struct DuePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: TaskItem
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            DatePicker("Deadline", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            Button("Set Deadline") { model.setDue(task.id, date); dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .onAppear { date = task.due ?? Date() }
    }
}

extension View {
    /// The deadline picker for this task, when its menu's "Pick a Date…" was chosen.
    func duePicker(for task: TaskItem, _ state: Binding<TaskEditState>) -> some View {
        popover(isPresented: Binding(get: { state.wrappedValue.pickingDate == task.id },
                                     set: { if !$0, state.wrappedValue.pickingDate == task.id { state.wrappedValue.pickingDate = nil } })) {
            DuePicker(task: task)
        }
    }
}

struct StatusButton: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem

    var body: some View {
        Button {
            let next = task.status.next
            Task {
                // A short pause before a finished task moves to Done, so a mis-click can be undone in place.
                if next == .done { try? await Task.sleep(for: .milliseconds(450)) }
                model.setStatus(task.id, next)
            }
        } label: {
            Image(systemName: task.status.symbol)
                .font(.system(size: 16))
                .foregroundStyle(task.status.tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help("\(task.status.title). Click for \(task.status.next.title).")
        .accessibilityLabel("Status: \(task.status.title)")
    }
}

/// The title and notes as text, the way Reminders shows a reminder that is not being edited.
struct TaskText: View {
    let task: TaskItem
    var notesLines = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.text.isEmpty ? "New Task" : task.text)
                .font(.body.weight(.medium))
                .foregroundStyle(task.text.isEmpty ? .tertiary : task.done ? .secondary : .primary)
                .strikethrough(task.done, color: .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notes = task.notes, !notes.isEmpty {
                Text(notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(notesLines)
            }
            if task.status == .blocked, let reason = task.blockedReason, !reason.isEmpty {
                Text(reason).font(.subheadline).foregroundStyle(.orange)
            }
        }
    }
}

/// Editing in place: a one-line title, notes under it, and for a blocked task what it waits on.
/// Return in the title, Escape, or clicking elsewhere saves and closes it. A new task left empty is removed.
struct TaskEditFields: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    let done: () -> Void
    @State private var title = ""
    @State private var notes = ""
    @State private var reason = ""
    @State private var saved = false
    @FocusState private var focus: Field?

    enum Field { case title, notes, reason }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Wraps like the title it replaces; Return still ends editing.
            TextField("Title", text: $title, axis: .vertical)
                .font(.body.weight(.medium))
                .lineLimit(1...5)
                .focused($focus, equals: .title)
                .onSubmit { finish() }
            TextField("Notes", text: $notes, axis: .vertical)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1...12)
                .focused($focus, equals: .notes)
            if task.status == .blocked {
                TextField("Waiting on…", text: $reason)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .focused($focus, equals: .reason)
                    .onSubmit { finish() }
            }
        }
        .textFieldStyle(.plain)
        .onAppear { title = task.text; notes = task.notes ?? ""; reason = task.blockedReason ?? "" }
        .task {
            // Focus once the fields are on screen: setting it in the same tick is ignored.
            try? await Task.sleep(for: .milliseconds(60))
            focus = .title
        }
        .onChange(of: focus) { old, new in if old != nil && new == nil { finish() } }
        .onExitCommand { finish() }
        .onDisappear { save() }
    }

    private func finish() {
        save()
        done()
    }

    private func save() {
        guard !saved, let current = model.tasks.first(where: { $0.id == task.id }) else { return }
        saved = true
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            if !current.text.isEmpty {
                t = current.text
            } else if n.isEmpty {
                model.deleteTask(task.id)   // a new task left empty
                return
            } else {
                // Only notes were typed: the first line becomes the title.
                let lines = n.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                t = String(lines[0]).trimmingCharacters(in: .whitespaces)
                n = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
        }
        var updated = current
        updated.text = t
        updated.notes = n.isEmpty ? nil : n
        if current.status == .blocked {
            let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.blockedReason = r.isEmpty ? nil : r
        }
        guard updated != current else { return }
        model.updateTask(updated)
    }
}

struct TaskListRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    @Binding var state: TaskEditState

    private var editing: Bool { state.editing == task.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusButton(task: task)
            VStack(alignment: .leading, spacing: 3) {
                if editing {
                    TaskEditFields(task: task) { state.endEditing(task.id) }
                } else {
                    TaskText(task: task)
                }
                if task.due != nil || sourceLine != nil {
                    HStack(spacing: 10) {
                        DueLabel(task: task)
                        if let line = sourceLine { Text(line).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            Spacer()
            ProjectDot(project: model.project(task.projectID))
        }
        .padding(.vertical, 3)
        .duePicker(for: task, $state)
    }

    private var sourceLine: String? { model.call(task.callID)?.title }
}

/// The board: one column per status, cards dragged between columns.
struct TaskBoard: View {
    @Environment(AppModel.self) private var model
    let tasks: [TaskItem]
    let project: Project?
    @Binding var state: TaskEditState

    var body: some View {
        GeometryReader { geo in
            // Four columns share the width; below 165 pt each the board scrolls sideways.
            let width = max(165, (geo.size.width - 40 - 3 * 14) / 4)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(TaskStatus.ordered) { status in
                        BoardColumn(status: status, tasks: tasks.filter { $0.status == status }, project: project,
                                    width: width, state: $state)
                    }
                }
                .padding(20)
                .frame(height: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }
}

struct BoardColumn: View {
    @Environment(AppModel.self) private var model
    let status: TaskStatus
    let tasks: [TaskItem]
    let project: Project?
    let width: CGFloat
    @Binding var state: TaskEditState
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusHeader(status: status, count: tasks.count)
                Spacer()
                Button { _ = model.addTask(status: status, project: project) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New task in \(status.title)")
            }
            .padding(.horizontal, 4)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(tasks.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }) { task in
                        BoardCard(task: task, state: $state)
                    }
                    if tasks.isEmpty {
                        Text("Drop tasks here").font(.subheadline).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(10)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(targeted ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.quinary),
                    in: .rect(cornerRadius: 12))
        .dropDestination(for: String.self) { items, _ in
            for item in items { if let id = UUID(uuidString: item) { model.setStatus(id, status) } }
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// A card on the board. Double-click it to edit the title and notes in place.
struct BoardCard: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    @Binding var state: TaskEditState

    private var editing: Bool { state.editing == task.id }

    var body: some View {
        if editing {
            card
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2))
        } else {
            card
                .contentShape(.rect(cornerRadius: 8))
                .onTapGesture(count: 2) { state.edit(task.id) }
                .draggable(task.id.uuidString) { TaskText(task: task).padding(10).frame(width: 220, alignment: .leading)
                    .background(.background, in: .rect(cornerRadius: 8)) }
                .contextMenu {
                    TaskMenuItems(task: task, edit: { state.edit(task.id) }, pickDate: { state.pickingDate = task.id })
                }
                .help("Double-click to edit")
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusButton(task: task)
                if editing {
                    TaskEditFields(task: task) { if state.editing == task.id { state.editing = nil } }
                } else {
                    TaskText(task: task, notesLines: 4)
                }
            }
            if task.due != nil || task.projectID != nil {
                HStack(spacing: 8) {
                    DueLabel(task: task)
                    Spacer()
                    ProjectDot(project: model.project(task.projectID))
                }
            }
            if let call = model.call(task.callID) {
                Text(call.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 8))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        .duePicker(for: task, $state)
    }
}
