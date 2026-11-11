import MochiKit
import SwiftUI

// Suggested tasks: what Mochi thinks you have to do after a call, waiting for your review.
// Nothing here becomes a task until you press + (or Add All).

/// The project chip on a suggestion: the project it goes to, or a proposed new one ("New: Lumen"),
/// as a menu to change it.
struct SuggestionProjectChip: View {
    @Environment(AppModel.self) private var model
    let callID: String
    let suggestion: TaskSuggestion

    var body: some View {
        Menu {
            ForEach(model.projects) { p in
                Button { model.setSuggestionProject(callID, suggestion.id, p) } label: {
                    if p.id == suggestion.projectID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            Divider()
            Button("No Project") { model.setSuggestionProject(callID, suggestion.id, nil) }
        } label: {
            HStack(spacing: 5) {
                if let name = suggestion.newProjectName {
                    Image(systemName: "plus").font(.caption2.weight(.bold))
                    Text("New: \(name)")
                } else {
                    let project = model.project(suggestion.projectID)
                    ProjectDot(project: project)
                    Text(project?.name ?? "No project")
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .font(.subheadline)
        .foregroundStyle(suggestion.newProjectName == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background {
            if suggestion.newProjectName == nil {
                Capsule().fill(.quaternary)
            } else {
                Capsule().strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .fixedSize()
        .help(suggestion.newProjectName == nil ? "Change the project"
              : "Mochi suggests a new project. It is created when you add this task.")
    }
}

/// One suggestion: + to add it, the text, its project, deadline and why, and × to dismiss it.
struct SuggestionRow: View {
    @Environment(AppModel.self) private var model
    let callID: String
    let suggestion: TaskSuggestion
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                title
                details
            }
            Spacer(minLength: 8)
            if suggestion.isPending {
                Button { withAnimation(.snappy) { model.dismissSuggestion(callID, suggestion.id) } } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0.7)
                .help("Dismiss")
                .accessibilityLabel("Dismiss suggestion")
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var leading: some View {
        switch suggestion.state {
        case .pending:
            Button { withAnimation(.snappy) { model.acceptSuggestion(callID, suggestion.id) } } label: {
                Image(systemName: suggestion.kind == .add ? "plus.circle" : "arrow.right.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(suggestion.kind == .add ? "Add to Tasks" : "Apply to the task")
            .accessibilityLabel(suggestion.kind == .add ? "Add to Tasks" : "Apply change")
        case .added:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.green)
                .help(suggestion.kind == .add ? "In Tasks" : "Applied")
        case .dismissed:
            Image(systemName: "minus.circle").font(.system(size: 16)).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var title: some View {
        let done = !suggestion.isPending
        switch suggestion.kind {
        case .add:
            Text(suggestion.text)
                .font(.body.weight(.medium))
                .foregroundStyle(done ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        case .update:
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.text)
                    .font(.body.weight(.medium))
                    .foregroundStyle(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    if let status = suggestion.status {
                        Image(systemName: status.symbol).foregroundStyle(status.tint)
                        Text(changeLine(status))
                    } else if let due = suggestion.due {
                        Image(systemName: "calendar").foregroundStyle(.secondary)
                        Text("New deadline: \(DueLabel.text(due))")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func changeLine(_ status: TaskStatus) -> String {
        var line = "Mark \(status.title)"
        if status == .blocked, let r = suggestion.blockedReason { line += ": \(r)" }
        if let due = suggestion.due { line += " · due \(DueLabel.text(due))" }
        return line
    }

    /// Where an added task went: its project now (you may have moved it since).
    private var placedProject: Project? {
        let task = model.tasks.first { $0.id == suggestion.taskCreated }
        return model.project(task?.projectID ?? suggestion.projectID)
    }

    @ViewBuilder private var details: some View {
        if suggestion.kind == .add {
            HStack(spacing: 8) {
                switch suggestion.state {
                case .pending: SuggestionProjectChip(callID: callID, suggestion: suggestion)
                case .added, .dismissed:
                    HStack(spacing: 5) {
                        ProjectDot(project: placedProject)
                        Text(placedProject?.name ?? suggestion.newProjectName ?? "No project")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                if let due = suggestion.due {
                    Label(DueLabel.text(due), systemImage: "calendar").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        if let why = suggestion.why {
            Text(why).font(.subheadline).foregroundStyle(.tertiary).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(why)
        }
    }
}

/// Under a call's summary: the tasks Mochi suggests from this call, with Add All.
struct SuggestedTasksCard: View {
    @Environment(AppModel.self) private var model
    let callID: String
    let suggestions: [TaskSuggestion]
    @State private var showDismissed = false

    var body: some View {
        let dismissed = suggestions.filter { $0.state == .dismissed }
        let visible = suggestions.filter { $0.state != .dismissed }
        let pending = suggestions.filter(\.isPending)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Suggested Tasks").font(.title3.weight(.semibold))
                if !pending.isEmpty {
                    Text("\(pending.count) to review").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if pending.count > 1 {
                    Button("Add All") { withAnimation(.snappy) { model.acceptAll(callID: callID) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if visible.isEmpty && dismissed.isEmpty {
                Text("Nothing for you to do from this call.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visible) { SuggestionRow(callID: callID, suggestion: $0) }
                }
            }
            if !dismissed.isEmpty {
                // Dismissed by mistake? They can come back.
                Button { withAnimation(.snappy) { showDismissed.toggle() } } label: {
                    Text(showDismissed ? "Hide Dismissed" : "\(dismissed.count) Dismissed")
                }
                .buttonStyle(.link)
                .font(.caption)
                if showDismissed {
                    ForEach(dismissed) { s in
                        HStack(alignment: .firstTextBaseline) {
                            Text(s.text).font(.subheadline).foregroundStyle(.secondary).strikethrough(color: .secondary)
                            Spacer()
                            Button("Restore") { withAnimation(.snappy) { model.restoreSuggestion(callID, s.id) } }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.quinary, in: .rect(cornerRadius: 12))
        .animation(.snappy, value: suggestions)
    }
}

/// At the top of Tasks: every suggestion still waiting, grouped by call. Folds away.
struct ReviewTray: View {
    @Environment(AppModel.self) private var model
    let items: [PendingSuggestion]
    @AppStorage("reviewTrayOpen") private var open = true
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { withAnimation(.snappy) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                        Text("To Review").font(.headline)
                        Text("\(items.count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Hide suggested tasks" : "Show suggested tasks")
                Text("Suggested from your calls").font(.subheadline).foregroundStyle(.tertiary)
                Spacer()
                if items.count > 1 {
                    Button("Add All") { withAnimation(.snappy) { for p in items { model.acceptSuggestion(p.callID, p.id) } } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if open {
                // Scrolls past a few calls' worth, so the tray never takes the window from Tasks. The
                // scroll view also gives the rows a known width: without it their wrapping text asked
                // for so much height that the whole window's content slid up out of view.
                ScrollView {
                    rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                .frame(height: min(max(rowsHeight, 1), 320))
                .scrollBounceBehavior(.basedOnSize)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(.quinary, in: .rect(cornerRadius: 12))
    }

    private var rows: some View {
        let groups = Dictionary(grouping: items, by: \.callID)
            .map { ($0.key, $0.value) }
            .sorted { ($0.1.first?.callDate ?? .distantPast) > ($1.1.first?.callDate ?? .distantPast) }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.0) { callID, list in
                VStack(alignment: .leading, spacing: 2) {
                    Button { model.selectedCallID = callID; model.section = .calls } label: {
                        HStack(spacing: 4) {
                            Text(list.first?.callTitle ?? "Call")
                            Text("·")
                            Text(list.first.map { $0.callDate.dayGroup } ?? "")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open the call")
                    ForEach(list) { SuggestionRow(callID: callID, suggestion: $0.suggestion) }
                }
            }
        }
    }
}

/// On Today: a quiet line when suggested tasks are waiting.
struct ReviewNudge: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        Button { model.section = .tasks } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text(count == 1 ? "1 suggested task to review" : "\(count) suggested tasks to review")
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quinary, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
