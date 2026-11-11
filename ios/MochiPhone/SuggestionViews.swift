import MochiKit
import SwiftUI
import UIKit

// Suggested tasks on the iPhone: the same review as on the Mac. Nothing is added until you tap +.

struct PhoneSuggestionRow: View {
    @Environment(PhoneModel.self) private var model
    let callID: String
    let suggestion: TaskSuggestion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.text)
                    .foregroundStyle(suggestion.isPending ? .primary : .secondary)
                if suggestion.kind == .update, let line = changeLine {
                    Label(line, systemImage: suggestion.status?.symbol ?? "calendar")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if suggestion.kind == .add && suggestion.isPending { projectMenu }
                    if suggestion.kind == .add, let due = suggestion.due {
                        Label(due.dayHeader, systemImage: "calendar").foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                if let why = suggestion.why {
                    Text(why).font(.footnote).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var leading: some View {
        switch suggestion.state {
        case .pending:
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation { model.acceptSuggestion(callID, suggestion.id) }
            } label: {
                Image(systemName: suggestion.kind == .add ? "plus.circle" : "arrow.right.circle")
                    .font(.title3).foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(suggestion.kind == .add ? "Add to Tasks" : "Apply change")
        case .added:
            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
        case .dismissed:
            Image(systemName: "minus.circle").font(.title3).foregroundStyle(.tertiary)
        }
    }

    private var changeLine: String? {
        if let status = suggestion.status {
            var line = "Mark \(status.title)"
            if status == .blocked, let r = suggestion.blockedReason { line += ": \(r)" }
            if let due = suggestion.due { line += " · due \(due.dayHeader)" }
            return line
        }
        return suggestion.due.map { "New deadline: \($0.dayHeader)" }
    }

    private var projectMenu: some View {
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
                    let p = model.project(suggestion.projectID)
                    Dot(project: p)
                    Text(p?.name ?? "No project")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(suggestion.newProjectName == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            .background {
                if suggestion.newProjectName == nil {
                    Capsule().fill(Color(.tertiarySystemFill))
                } else {
                    Capsule().strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Under a call's summary.
struct PhoneSuggestedTasks: View {
    @Environment(PhoneModel.self) private var model
    let callID: String
    let suggestions: [TaskSuggestion]

    var body: some View {
        let visible = suggestions.filter { $0.state != .dismissed }
        let pending = suggestions.filter(\.isPending)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Suggested Tasks").font(.title3.weight(.semibold))
                Spacer()
                if pending.count > 1 {
                    Button("Add All") { withAnimation { model.acceptAll(callID: callID) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if visible.isEmpty {
                Text(suggestions.isEmpty ? "Nothing for you to do from this call." : "All dismissed.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(visible) { s in
                HStack(alignment: .firstTextBaseline) {
                    PhoneSuggestionRow(callID: callID, suggestion: s)
                    if s.isPending {
                        Button { withAnimation { model.dismissSuggestion(callID, s.id) } } label: {
                            Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss suggestion")
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
    }
}
