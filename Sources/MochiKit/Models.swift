import Foundation

/// A project tag (Work, Personal, or any you add). Calls and tasks store its id.
public struct Project: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// A system colour name from `Project.colors`.
    public var color: String
    /// What the project is about, in a line. Helps Mochi pick the right project for a suggested task.
    public var note: String?
    /// Last edit, for sync between devices (the newer side wins). Nil on projects never edited since.
    public var updatedAt: Date?

    public init(id: String = UUID().uuidString.lowercased(), name: String, color: String, note: String? = nil,
                updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.note = note
        self.updatedAt = updatedAt
    }

    /// The first colour no project uses yet (blue when all are taken).
    public static func freeColor(in projects: [Project]) -> String {
        colors.first { c in !projects.contains { $0.color == c } } ?? "blue"
    }

    public static let defaults = [
        Project(id: "work", name: "Work", color: "orange"),
        Project(id: "personal", name: "Personal", color: "green"),
    ]

    public static let colors = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray"]

    /// The first project whose name appears in a meeting title, nil when none does.
    public static func guess(from title: String, in projects: [Project]) -> Project? {
        let t = title.lowercased().replacingOccurrences(of: " ", with: "")
        return projects.first { t.contains($0.name.lowercased().replacingOccurrences(of: " ", with: "")) }
    }
}

public enum Speaker: String, Codable, Sendable {
    case me
    case them
}

public struct Segment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var speaker: Speaker
    /// Seconds from the start of the recording.
    public var start: Double
    public var end: Double
    public var text: String
    /// ISO code the engine heard ("en", "nl"), never shown.
    public var language: String?
    /// Which voice on the other side said it ("s1", "s2", in order of first words), when the
    /// after-call pass told the voices apart. Nil on Me lines, live lines and older calls.
    public var speakerID: String?
    /// That voice's name ("Lena") once you named it or Mochi recognised it. Kept on the line so
    /// the name travels with the transcript to the other devices and to Claude.
    public var name: String?

    public init(id: UUID = UUID(), speaker: Speaker, start: Double, end: Double, text: String, language: String? = nil,
                speakerID: String? = nil, name: String? = nil) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.language = language
        self.speakerID = speakerID
        self.name = name
    }
}

public enum CallStatus: String, Codable, Sendable {
    case recording
    case transcribing
    case ready
    case failed
}

public struct Call: Codable, Hashable, Sendable, Identifiable {
    /// Also the folder name: 2026-11-01_143000.
    public var id: String
    public var title: String
    public var startedAt: Date
    /// Recorded seconds (pauses excluded).
    public var duration: Double
    public var appName: String?
    public var projectID: String?
    public var eventID: String?
    public var status: CallStatus
    /// The other side's name ("Dana"), nil shows "Them".
    public var themName: String?
    /// The call app's audio was never captured.
    public var micOnly: Bool
    public var failure: String?
    /// The Mac that recorded it ("Sam's Mac mini"). The audio lives only there.
    public var device: String?
    /// Last change to anything that syncs (title, project, notes, transcript, summary).
    public var updatedAt: Date?

    public init(id: String, title: String, startedAt: Date, duration: Double = 0, appName: String? = nil,
                projectID: String? = nil, eventID: String? = nil, status: CallStatus = .recording,
                themName: String? = nil, micOnly: Bool = false, failure: String? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.appName = appName
        self.projectID = projectID
        self.eventID = eventID
        self.status = status
        self.themName = themName
        self.micOnly = micOnly
        self.failure = failure
    }

    public static func newID(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date)
    }

    public var themLabel: String { themName?.isEmpty == false ? themName! : "Them" }

    enum CodingKeys: String, CodingKey {
        case id, title, startedAt, duration, appName, eventID, status, themName, micOnly, failure, device, updatedAt
        case projectID = "project"
    }
}

public enum TaskStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case todo
    case inProgress = "in-progress"
    case blocked
    case done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .todo: "To Do"
        case .inProgress: "In Progress"
        case .blocked: "Blocked"
        case .done: "Done"
        }
    }

    /// The order the board and the list show them in.
    public static let ordered: [TaskStatus] = [.todo, .inProgress, .blocked, .done]
}

public struct TaskItem: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The title: short, one line, like a reminder's.
    public var text: String
    /// Optional detail under the title, any length.
    public var notes: String?
    public var status: TaskStatus
    public var callID: String?
    public var projectID: String?
    /// The deadline (a day; the time part is ignored).
    public var due: Date?
    /// Why it is blocked, or what it waits on.
    public var blockedReason: String?
    public var createdAt: Date
    public var doneAt: Date?
    /// Last change, for two-way sync (the newer side wins).
    public var updatedAt: Date
    /// Where it was made: "mochi" or "claude".
    public var source: String?

    public var done: Bool { status == .done }

    public init(id: UUID = UUID(), text: String, status: TaskStatus = .todo, callID: String? = nil,
                projectID: String? = nil, due: Date? = nil, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.status = status
        self.callID = callID
        self.projectID = projectID
        self.due = due
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Past its deadline and not done.
    public func isOverdue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let due, status != .done else { return false }
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }

    enum CodingKeys: String, CodingKey { case id, text, notes, status, done, callID, project, due, blockedReason, createdAt, doneAt, updatedAt, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        // Files from before statuses existed only say done or not.
        status = try c.decodeIfPresent(TaskStatus.self, forKey: .status)
            ?? ((try c.decodeIfPresent(Bool.self, forKey: .done)) == true ? .done : .todo)
        callID = try c.decodeIfPresent(String.self, forKey: .callID)
        projectID = try c.decodeIfPresent(String.self, forKey: .project)
        due = try? c.decodeIfPresent(Date.self, forKey: .due)
        blockedReason = try c.decodeIfPresent(String.self, forKey: .blockedReason)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(callID, forKey: .callID)
        try c.encodeIfPresent(projectID, forKey: .project)
        try c.encodeIfPresent(due, forKey: .due)
        try c.encodeIfPresent(blockedReason, forKey: .blockedReason)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(doneAt, forKey: .doneAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(source, forKey: .source)
    }
}

/// The written summary of a call, in Spark's shape: a one-line overview, key points grouped by
/// topic (a title, a one-line lead, bullets), and action items grouped by person.
public struct Summary: Codable, Hashable, Sendable {
    public struct Topic: Codable, Hashable, Sendable {
        public var title: String
        public var lead: String
        public var points: [String]
        public init(title: String, lead: String, points: [String]) {
            self.title = title
            self.lead = lead
            self.points = points
        }
    }

    public struct Owner: Codable, Hashable, Sendable {
        public var name: String
        public var items: [String]
        public init(name: String, items: [String]) {
            self.name = name
            self.items = items
        }
    }

    /// The one-line overview.
    public var text: String
    public var topics: [Topic]
    public var actionItems: [Owner]
    public var provider: String
    public var writtenAt: Date
    /// Tasks Mochi suggests for you, waiting for your review. Nil on summaries written before
    /// suggestions existed (those show the old Action Items with + buttons).
    public var suggestions: [TaskSuggestion]?

    public init(text: String, topics: [Topic], actionItems: [Owner], provider: String, writtenAt: Date = Date(),
                suggestions: [TaskSuggestion]? = nil) {
        self.text = text
        self.topics = topics
        self.actionItems = actionItems
        self.provider = provider
        self.writtenAt = writtenAt
        self.suggestions = suggestions
    }

    enum CodingKeys: String, CodingKey { case text, topics, actionItems, provider, writtenAt, suggestions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        topics = try c.decodeIfPresent([Topic].self, forKey: .topics) ?? []
        actionItems = try c.decodeIfPresent([Owner].self, forKey: .actionItems) ?? []
        provider = try c.decode(String.self, forKey: .provider)
        writtenAt = try c.decode(Date.self, forKey: .writtenAt)
        // One unreadable suggestion must not cost the whole summary.
        suggestions = try? c.decodeIfPresent([TaskSuggestion].self, forKey: .suggestions)
    }

    /// The names you go by in action items: "Me" and the name set in Settings.
    public static var ownNames: Set<String> { ["Me", OwnerName.name] }

    public var pendingSuggestions: [TaskSuggestion] { (suggestions ?? []).filter(\.isPending) }

    /// The same layout as Markdown, for Copy Summary.
    public var markdown: String {
        var out = [text, "", "### Key Points"]
        for t in topics {
            out += ["", "#### \(t.title)", "", t.lead, ""]
            out += t.points.map { "* \($0)" }
        }
        if !actionItems.isEmpty {
            out += ["", "### Action Items"]
            for o in actionItems {
                out += ["", "#### \(o.name)", ""]
                out += o.items.map { "* \($0)" }
            }
        }
        return out.joined(separator: "\n")
    }
}
