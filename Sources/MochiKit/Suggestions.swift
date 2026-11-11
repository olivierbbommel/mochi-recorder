import Foundation

/// A task Mochi suggests after a call, waiting for you to review it. It lives in the call's
/// summary (summary.json, and the meeting row's summary in the cloud), so the review state syncs
/// with the call to the other Mac and the iPhone. Nothing becomes a task until you add it.
public struct TaskSuggestion: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A new task.
        case add
        /// A change to a task you already have: a new status, a reason it is blocked, or a deadline.
        case update
    }

    public enum State: String, Codable, Sendable {
        case pending, added, dismissed
    }

    public var id: UUID
    public var kind: Kind
    /// add: the task, short. update: the existing task's text when the suggestion was made.
    public var text: String
    /// add: the project it goes to. You can change it before adding.
    public var projectID: String?
    /// add: the project Mochi picked first, kept so later suggestions learn from your changes.
    public var guessedProjectID: String?
    /// add: a new project Mochi proposes when none fits. Created only when you add the task.
    public var newProjectName: String?
    /// add: the deadline. update: a new deadline.
    public var due: Date?
    /// update: the task it changes.
    public var taskID: UUID?
    /// update: the new status.
    public var status: TaskStatus?
    /// update to blocked: what it waits on.
    public var blockedReason: String?
    /// One short line on why, from the call.
    public var why: String?
    public var state: State
    /// add: the task it became.
    public var taskCreated: UUID?

    public init(id: UUID = UUID(), kind: Kind, text: String, projectID: String? = nil, guessedProjectID: String? = nil,
                newProjectName: String? = nil, due: Date? = nil, taskID: UUID? = nil, status: TaskStatus? = nil,
                blockedReason: String? = nil, why: String? = nil, state: State = .pending, taskCreated: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.projectID = projectID
        self.guessedProjectID = guessedProjectID
        self.newProjectName = newProjectName
        self.due = due
        self.taskID = taskID
        self.status = status
        self.blockedReason = blockedReason
        self.why = why
        self.state = state
        self.taskCreated = taskCreated
    }

    public var isPending: Bool { state == .pending }

    /// add: the task this suggestion becomes, linked to the call. The project is set by the caller
    /// (a proposed new project has no id until it is created).
    public func makeTask(callID: String?, projectID: String?, now: Date = Date()) -> TaskItem {
        var task = TaskItem(text: text, callID: callID, projectID: projectID, due: due, createdAt: now)
        task.source = "mochi"
        // Where it came from goes in the notes, so the title stays short.
        if let why = why?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty { task.notes = why }
        return task
    }

    /// update: the task with this suggestion's change applied. Nil when it changes nothing.
    public func applied(to task: TaskItem, now: Date = Date()) -> TaskItem? {
        var t = task
        if let status, status != t.status {
            t.status = status
            t.doneAt = status == .done ? now : nil
            if status != .blocked { t.blockedReason = nil }
        }
        if t.status == .blocked, let reason = blockedReason, !reason.isEmpty { t.blockedReason = reason }
        if let due { t.due = due }
        guard t != task else { return nil }
        t.updatedAt = now
        return t
    }
}

/// What Claude sends back for suggestions, before it is checked against your projects and tasks.
public struct RawSuggestedTask: Sendable {
    public var text: String
    public var project: String
    public var newProject: String
    public var due: String
    public var why: String
    public init(text: String, project: String = "", newProject: String = "", due: String = "", why: String = "") {
        self.text = text
        self.project = project
        self.newProject = newProject
        self.due = due
        self.why = why
    }
}

public struct RawTaskUpdate: Sendable {
    public var taskID: String
    public var status: String
    public var blockedReason: String
    public var due: String
    public var why: String
    public init(taskID: String, status: String = "", blockedReason: String = "", due: String = "", why: String = "") {
        self.taskID = taskID
        self.status = status
        self.blockedReason = blockedReason
        self.due = due
        self.why = why
    }
}

/// The checks and bookkeeping around suggestions, shared by the Mac and the iPhone.
public enum Suggestions {
    /// At most this many new tasks per call: a short list you can review in a glance.
    public static let maxNew = 6
    /// Open tasks Claude sees (the newest first), so it can skip duplicates and suggest changes.
    public static let maxOpenTasks = 60

    /// "Send the deck!" and "send the deck" are the same task.
    public static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// The open tasks Claude is shown, newest first.
    public static func openTasks(_ tasks: [TaskItem]) -> [TaskItem] {
        Array(tasks.filter { !$0.done && !$0.text.isEmpty }.sorted { $0.createdAt > $1.createdAt }.prefix(maxOpenTasks))
    }

    /// A day in "YYYY-MM-DD", read as noon local time (deadlines are days).
    public static func day(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The project with this name or id, ignoring case and spaces.
    public static func project(named name: String, in projects: [Project]) -> Project? {
        let n = normalized(name)
        guard !n.isEmpty else { return nil }
        return projects.first { normalized($0.name) == n || normalized($0.id) == n }
    }

    /// Claude's answer, checked: projects matched by name, new projects only when nothing fits,
    /// duplicates of open tasks dropped, updates only for open tasks and only when they change
    /// something.
    public static func build(tasks raw: [RawSuggestedTask], updates rawUpdates: [RawTaskUpdate],
                             projects: [Project], openTasks: [TaskItem], calendar: Calendar = .current) -> [TaskSuggestion] {
        var out: [TaskSuggestion] = []
        var seen = Set(openTasks.map { normalized($0.text) })
        for r in raw {
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized(text)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            var projectID = project(named: r.project, in: projects)?.id
            var newName: String?
            let proposed = r.newProject.trimmingCharacters(in: .whitespacesAndNewlines)
            if projectID == nil, !proposed.isEmpty {
                // A "new" project that already exists is that project.
                if let existing = project(named: proposed, in: projects) { projectID = existing.id } else { newName = proposed }
            }
            out.append(TaskSuggestion(kind: .add, text: text, projectID: projectID, guessedProjectID: projectID,
                                      newProjectName: newName, due: day(r.due, calendar: calendar), why: clean(r.why)))
            if out.count == maxNew { break }
        }
        var updated = Set<UUID>()
        for r in rawUpdates {
            guard let id = UUID(uuidString: r.taskID.trimmingCharacters(in: .whitespaces)), !updated.contains(id),
                  let task = openTasks.first(where: { $0.id == id }) else { continue }
            let suggestion = TaskSuggestion(kind: .update, text: task.text, projectID: task.projectID,
                                            due: day(r.due, calendar: calendar), taskID: id,
                                            status: TaskStatus(rawValue: r.status),
                                            blockedReason: clean(r.blockedReason), why: clean(r.why))
            guard suggestion.applied(to: task) != nil else { continue }
            updated.insert(id)
            out.append(suggestion)
        }
        return out
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Summarise Again keeps your choices: what you added or dismissed is not suggested again, and an
    /// earlier answer that is still waiting stays when the new one asks the same.
    public static func carryOver(new: [TaskSuggestion], old: [TaskSuggestion]?) -> [TaskSuggestion] {
        guard let old, !old.isEmpty else { return new }
        let decided = old.filter { !$0.isPending }
        let decidedAdds = Set(decided.filter { $0.kind == .add }.map { normalized($0.text) })
        let decidedUpdates = Set(decided.compactMap(\.taskID))
        let fresh = new.filter {
            $0.kind == .add ? !decidedAdds.contains(normalized($0.text)) : !decidedUpdates.contains($0.taskID ?? UUID())
        }
        return decided + fresh
    }

    /// What you changed: suggested tasks that ended up in a different project than Mochi picked
    /// (changed before adding, or moved later). Newest first, for the next call's request.
    public static func corrections(_ summaries: [Summary], tasks: [TaskItem], projects: [Project], limit: Int = 20)
        -> [(text: String, picked: String?, chosen: String?)] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func name(_ id: String?) -> String? { id.flatMap { pid in projects.first { $0.id == pid }?.name } }
        var out: [(Date, String, String?, String?)] = []
        for s in summaries {
            for sug in s.suggestions ?? [] where sug.kind == .add && sug.state == .added {
                let chosen = sug.taskCreated.flatMap { byID[$0] }?.projectID ?? sug.projectID
                guard chosen != sug.guessedProjectID, sug.newProjectName == nil || chosen != nil else { continue }
                out.append((s.writtenAt, sug.text, name(sug.guessedProjectID), name(chosen)))
            }
        }
        return out.sorted { $0.0 > $1.0 }.prefix(limit).map { (text: $0.1, picked: $0.2, chosen: $0.3) }
    }

    /// The facts Claude needs to suggest well, as text before the transcript: the call's date, his
    /// projects with their notes and a few recent tasks each, your open tasks with ids, and the
    /// projects you corrected.
    public static func context(callDate: Date, projects: [Project], tasks: [TaskItem],
                               corrections: [(text: String, picked: String?, chosen: String?)],
                               calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE yyyy-MM-dd"
        var lines = ["# For the suggested tasks", "", "The call was on \(f.string(from: callDate)).", "", "## Their projects"]
        if projects.isEmpty { lines.append("(none yet)") }
        for p in projects {
            var line = "- \(p.name)"
            if let note = p.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { line += ": \(note)" }
            lines.append(line)
            let recent = tasks.filter { $0.projectID == p.id && !$0.text.isEmpty }
                .sorted { $0.createdAt > $1.createdAt }.prefix(5)
            if !recent.isEmpty { lines.append("  recent tasks: " + recent.map { "\"\($0.text)\"" }.joined(separator: "; ")) }
        }
        lines += ["", "## Their open tasks"]
        let open = openTasks(tasks)
        if open.isEmpty { lines.append("(none)") }
        for t in open {
            var line = "- id \(t.id.uuidString.lowercased()) [\(t.status.rawValue)] \(t.text)"
            if let p = projects.first(where: { $0.id == t.projectID }) { line += " (project: \(p.name))" }
            if let due = t.due { line += " (due \(dayString(due, calendar: calendar)))" }
            if t.status == .blocked, let r = t.blockedReason, !r.isEmpty { line += " (waiting on: \(r))" }
            lines.append(line)
        }
        if !corrections.isEmpty {
            lines += ["", "## Projects they corrected (learn from these)"]
            for c in corrections {
                lines.append("- \"\(c.text)\": they put it in \(c.chosen ?? "no project"), not \(c.picked ?? "no project")")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// One suggestion waiting for review, with the call it came from (for the To Review list).
public struct PendingSuggestion: Hashable, Sendable, Identifiable {
    public var callID: String
    public var callTitle: String
    public var callDate: Date
    public var suggestion: TaskSuggestion
    public var id: UUID { suggestion.id }
    public init(callID: String, callTitle: String, callDate: Date, suggestion: TaskSuggestion) {
        self.callID = callID
        self.callTitle = callTitle
        self.callDate = callDate
        self.suggestion = suggestion
    }
}
