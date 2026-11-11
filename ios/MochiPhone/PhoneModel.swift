import Foundation
import MochiKit
import MochiTranscribe
import Observation
import UIKit

/// Everything the iPhone shows, kept as local files (the same layout as the Mac, under the app's
/// Documents/Mochi) and synced with the account through mochi-api: calls, transcripts, summaries,
/// notes, tasks, projects and upcoming meetings. The newer change wins, like on the Mac.
@Observable
@MainActor
final class PhoneModel {
    static let shared = PhoneModel()

    let storage = Storage(root: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mochi", isDirectory: true))
    private(set) var calls: [Call] = []
    var tasks: [TaskItem] = []
    private(set) var projects: [Project] = []
    private(set) var events: [UpcomingEvent] = []
    private(set) var email: String?
    private(set) var syncing = false
    private(set) var lastSync: Date?
    private(set) var syncError: String?
    /// Bumped when transcripts or summaries change on disk, so open views reload them.
    private(set) var version = 0
    var processing: Set<String> = []
    /// Why a transcript could not be written, by call id. The call shows it with a Retry button.
    var transcribeErrors: [String: String] = [:]
    /// While the speech model downloads (first use only): what is happening and how far, 0...1.
    private(set) var modelStatus: (text: String, fraction: Double)?

    private var pendingMeetings: Set<String> = []
    private var pushTasks = false
    /// Projects made here (from a suggested task), not in the cloud yet.
    private var newProjects: [Project] = []
    private var taskTombstones: [[String: Any]] = []
    private var meetingTombstones: [[String: Any]] = []

    static let deviceName = UIDevice.current.name.isEmpty ? "iPhone" : UIDevice.current.name

    struct UpcomingEvent: Identifiable, Hashable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var appName: String?
        var attendees: [String]
        var calendar: String?
    }

    init() {
        load()
    }

    func load() {
        calls = storage.loadCalls()
        tasks = storage.loadTasks()
        projects = storage.loadProjects()
        if let data = try? Data(contentsOf: eventsFile), let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            events = rows.compactMap(Self.event)
        }
    }

    func refreshAccount() async {
        email = await Account.shared.email()
    }

    var signedIn: Bool { email != nil }

    // MARK: Lookups

    func call(_ id: String?) -> Call? { calls.first { $0.id == id } }
    func project(_ id: String?) -> Project? { projects.first { $0.id == id } }
    func transcript(_ id: String) -> [Segment] { TranscriptText.clean(storage.transcript(for: id)) }
    func summary(_ id: String) -> Summary? { storage.summary(for: id) }
    var openTaskCount: Int { tasks.filter { !$0.done }.count }

    // MARK: Edits (all sync)

    /// Transcribes a call recorded on this iPhone, on the phone. The first time it also downloads the
    /// speech model (about 500 MB), and shows that progress so it never looks stuck.
    func transcribe(_ id: String) {
        guard !processing.contains(id) else { return }
        let file = storage.folder(for: id).appendingPathComponent("them.m4a")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        processing.insert(id)
        transcribeErrors[id] = nil
        // Keeps the first download going for a while if the app is sent to the background.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Transcribe")
        Task {
            defer {
                processing.remove(id)
                modelStatus = nil
                UIApplication.shared.endBackgroundTask(background)
            }
            do {
                try await Transcriber.shared.prepare { fraction, text in
                    Task { @MainActor in PhoneModel.shared.modelStatus = (text, fraction) }
                }
                modelStatus = nil
                let segments = try await Transcriber.shared.transcribe(file: file, speaker: .them)
                try storage.saveTranscript(TranscriptText.clean(segments), for: id)
            } catch {
                transcribeErrors[id] = error.localizedDescription
            }
            if let c = call(id) { save(c) }
        }
    }

    /// Calls recorded here whose transcript never got written (the app was closed mid-way, or the
    /// model download failed). Picked up again at launch.
    func resumeTranscriptions() {
        // Audio only exists on the device that recorded it, so its presence is the test.
        for c in calls where c.appName == "In person"
            && !FileManager.default.fileExists(atPath: storage.folder(for: c.id).appendingPathComponent("transcript.json").path)
            && !processing.contains(c.id) {
            let file = storage.folder(for: c.id).appendingPathComponent("them.m4a")
            if FileManager.default.fileExists(atPath: file.path) { transcribe(c.id) }
        }
    }

    func save(_ call: Call) {
        var call = call
        call.updatedAt = Date()
        if call.device == nil { call.device = Self.deviceName }
        try? storage.save(call)
        if let i = calls.firstIndex(where: { $0.id == call.id }) { calls[i] = call } else { calls.insert(call, at: 0) }
        calls.sort { $0.startedAt > $1.startedAt }
        pendingMeetings.insert(call.id)
        scheduleSync()
    }

    func saveNotes(_ text: String, for id: String) {
        guard text != storage.notes(for: id) else { return }
        try? storage.saveNotes(text, for: id)
        if let call = call(id) { save(call) }
    }

    /// Removes the call here and, through a tombstone, on every device.
    func deleteCall(_ id: String) {
        guard let call = call(id) else { return }
        var row = meetingRow(call)
        row["deleted"] = true
        row["updated_at"] = Self.iso(Date())
        meetingTombstones.append(row)
        try? FileManager.default.removeItem(at: storage.folder(for: id))
        calls.removeAll { $0.id == id }
        pendingMeetings.remove(id)
        scheduleSync(after: 0.2)
    }

    func setProject(_ id: String, _ project: Project?) {
        guard var call = call(id) else { return }
        call.projectID = project?.id
        save(call)
    }

    func addTask(_ text: String, callID: String? = nil, projectID: String? = nil, due: Date? = nil) {
        var task = TaskItem(text: text, callID: callID, projectID: projectID, due: due)
        task.source = "mochi"
        tasks.insert(task, at: 0)
        saveTasks()
    }

    func update(_ task: TaskItem) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var t = task
        t.updatedAt = Date()
        if t.status == .done && t.doneAt == nil { t.doneAt = Date() }
        if t.status != .done { t.doneAt = nil }
        tasks[i] = t
        saveTasks()
    }

    func setStatus(_ id: UUID, _ status: TaskStatus) {
        guard var t = tasks.first(where: { $0.id == id }) else { return }
        t.status = status
        if status != .blocked { t.blockedReason = nil }
        update(t)
    }

    // MARK: Suggested tasks (the Mac writes them with the summary; reviewed here or there)

    /// Every suggestion still waiting, newest call first (last 90 days).
    var pendingSuggestions: [PendingSuggestion] {
        let key = "\(version)/\(calls.count)"
        if let cached = suggestionCache, cached.key == key { return cached.list }
        let since = Date().addingTimeInterval(-90 * 86_400)
        let list = calls.filter { $0.startedAt > since }.flatMap { call in
            (summary(call.id)?.pendingSuggestions ?? []).map {
                PendingSuggestion(callID: call.id, callTitle: call.title, callDate: call.startedAt, suggestion: $0)
            }
        }
        suggestionCache = (key, list)
        return list
    }

    /// Summaries are files: read them again only after a sync or an edit, not on every redraw.
    @ObservationIgnored private var suggestionCache: (key: String, list: [PendingSuggestion])?

    private func editSuggestion(_ callID: String, _ id: UUID, _ change: (inout TaskSuggestion) -> Void) {
        guard var s = storage.summary(for: callID), var list = s.suggestions,
              let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        s.suggestions = list
        try? storage.saveSummary(s, for: callID)
        version += 1
        if let c = call(callID) { save(c) }
    }

    func acceptSuggestion(_ callID: String, _ id: UUID) {
        guard let s = summary(callID)?.suggestions?.first(where: { $0.id == id }), s.isPending else { return }
        switch s.kind {
        case .add:
            var projectID = s.projectID
            if projectID == nil, let name = s.newProjectName {
                if let existing = Suggestions.project(named: name, in: projects) {
                    projectID = existing.id
                } else {
                    let p = Project(name: name, color: Project.freeColor(in: projects), updatedAt: Date())
                    projects.append(p)
                    try? storage.saveProjects(projects)
                    newProjects.append(p)
                    projectID = p.id
                }
            }
            if let existing = tasks.first(where: { $0.callID == callID && Suggestions.normalized($0.text) == Suggestions.normalized(s.text) }) {
                editSuggestion(callID, id) { $0.state = .added; $0.taskCreated = existing.id; $0.projectID = projectID }
                return
            }
            let task = s.makeTask(callID: callID, projectID: projectID)
            tasks.insert(task, at: 0)
            saveTasks()
            editSuggestion(callID, id) {
                $0.state = .added
                $0.taskCreated = task.id
                $0.projectID = projectID
                if projectID != nil { $0.newProjectName = nil }
            }
        case .update:
            if let tid = s.taskID, let i = tasks.firstIndex(where: { $0.id == tid }), let changed = s.applied(to: tasks[i]) {
                tasks[i] = changed
                saveTasks()
            }
            editSuggestion(callID, id) { $0.state = .added }
        }
    }

    func dismissSuggestion(_ callID: String, _ id: UUID) {
        editSuggestion(callID, id) { $0.state = .dismissed }
    }

    func setSuggestionProject(_ callID: String, _ id: UUID, _ project: Project?) {
        editSuggestion(callID, id) { $0.projectID = project?.id; $0.newProjectName = nil }
    }

    func acceptAll(callID: String? = nil) {
        for p in pendingSuggestions where callID == nil || p.callID == callID { acceptSuggestion(p.callID, p.id) }
    }

    func deleteTask(_ id: UUID) {
        guard let t = tasks.first(where: { $0.id == id }) else { return }
        var row = Self.taskRow(t)
        row["deleted"] = true
        row["updated_at"] = Self.iso(Date())
        taskTombstones.append(row)
        tasks.removeAll { $0.id == id }
        saveTasks()
    }

    private func saveTasks() {
        try? storage.saveTasks(tasks)
        pushTasks = true
        scheduleSync()
    }

    // MARK: Sync

    private var debounce: Task<Void, Never>?

    func scheduleSync(after seconds: Double = 1.5) {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    func sync() async {
        guard signedIn, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            var push: [String: Any] = ["action": "push"]
            // Projects first: the tasks and calls sent with them point at them.
            let sentProjects = newProjects
            if !sentProjects.isEmpty {
                push["projects"] = sentProjects.map { p in
                    ["id": p.id, "name": p.name, "color": p.color, "sort": projects.firstIndex(of: p) ?? projects.count,
                     "note": p.note ?? NSNull(), "updated_at": Self.iso(p.updatedAt ?? Date())] as [String: Any]
                }
            }
            let meetingIDs = pendingMeetings
            let sentMeetingTombstones = meetingTombstones.count
            push["meetings"] = meetingIDs.compactMap { call($0).map(meetingRow) } + meetingTombstones
            let sentTombstones = taskTombstones.count
            if pushTasks || !taskTombstones.isEmpty { push["tasks"] = tasks.map(Self.taskRow) + taskTombstones }
            if (push["meetings"] as? [Any])?.isEmpty == false || push["tasks"] != nil || push["projects"] != nil {
                _ = try await MochiAPI.call(push)
            }
            newProjects.removeAll { p in sentProjects.contains { $0.id == p.id } }
            pendingMeetings.subtract(meetingIDs)
            pushTasks = false
            taskTombstones.removeFirst(min(sentTombstones, taskTombstones.count))
            meetingTombstones.removeFirst(min(sentMeetingTombstones, meetingTombstones.count))

            // Pull until caught up (the API returns at most 50 calls at a time).
            var rounds = 0
            repeat {
                let since = UserDefaults.standard.string(forKey: "pulledAt") ?? "1970-01-01T00:00:00Z"
                let pulled = try await MochiAPI.call(["action": "pull", "since": since])
                mergeProjects(pulled["projects"] as? [[String: Any]] ?? [])
                mergeTasks(pulled["tasks"] as? [[String: Any]] ?? [])
                let meetings = pulled["meetings"] as? [[String: Any]] ?? []
                mergeMeetings(meetings)
                if let rows = pulled["events"] as? [[String: Any]] {
                    events = rows.compactMap(Self.event)
                    if let data = try? JSONSerialization.data(withJSONObject: rows) { try? data.write(to: eventsFile) }
                }
                if let at = pulled["at"] as? String { UserDefaults.standard.set(at, forKey: "pulledAt") }
                rounds += 1
                if meetings.count < 50 { break }
            } while rounds < 20
            lastSync = Date()
            syncError = nil
            version += 1
        } catch {
            syncError = error.localizedDescription
        }
    }

    private var eventsFile: URL { storage.root.appendingPathComponent("events.json") }

    private func mergeProjects(_ rows: [[String: Any]]) {
        guard !rows.isEmpty else { return }
        var list = projects
        for row in rows {
            guard let id = row["id"] as? String, let name = row["name"] as? String else { continue }
            let p = Project(id: id, name: name, color: row["color"] as? String ?? "blue", note: row["note"] as? String,
                            updatedAt: (row["updated_at"] as? String).flatMap(Self.date))
            if let i = list.firstIndex(where: { $0.id == id }) { list[i] = p } else { list.append(p) }
        }
        projects = list
        try? storage.saveProjects(list)
    }

    private func mergeTasks(_ rows: [[String: Any]]) {
        var changed = false
        for row in rows {
            guard let idText = row["id"] as? String, let id = UUID(uuidString: idText),
                  let updated = (row["updated_at"] as? String).flatMap(Self.date) else { continue }
            let local = tasks.firstIndex { $0.id == id }
            if let i = local, tasks[i].updatedAt >= updated.addingTimeInterval(-0.5) { continue }
            if row["deleted"] as? Bool == true {
                if let i = local { tasks.remove(at: i); changed = true }
                continue
            }
            var t = TaskItem(id: id, text: row["text"] as? String ?? "", createdAt: (row["created_at"] as? String).flatMap(Self.date) ?? Date())
            t.notes = row["notes"] as? String
            t.status = TaskStatus(rawValue: row["status"] as? String ?? "") ?? .todo
            t.callID = row["meeting_id"] as? String
            t.projectID = row["project_id"] as? String
            t.due = (row["due"] as? String).flatMap(Self.day)
            t.blockedReason = row["blocked_reason"] as? String
            t.doneAt = (row["done_at"] as? String).flatMap(Self.date)
            t.source = row["source"] as? String
            t.updatedAt = updated
            if let i = local { tasks[i] = t } else { tasks.insert(t, at: 0) }
            changed = true
        }
        if changed { try? storage.saveTasks(tasks) }
    }

    private func mergeMeetings(_ rows: [[String: Any]]) {
        var changed = false
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            if row["deleted"] as? Bool == true {
                if call(id) != nil {
                    try? FileManager.default.removeItem(at: storage.folder(for: id))
                    calls.removeAll { $0.id == id }
                    changed = true
                }
                continue
            }
            guard let title = row["title"] as? String,
                  let started = (row["started_at"] as? String).flatMap(Self.date),
                  let updated = (row["updated_at"] as? String).flatMap(Self.date) else { continue }
            if let local = call(id), (local.updatedAt ?? local.startedAt) >= updated.addingTimeInterval(-0.5) { continue }
            var c = call(id) ?? Call(id: id, title: title, startedAt: started, status: .ready)
            c.title = title
            c.duration = row["duration_s"] as? Double ?? c.duration
            c.appName = row["app_name"] as? String
            c.projectID = row["project_id"] as? String
            c.themName = row["them_name"] as? String
            c.micOnly = row["mic_only"] as? Bool ?? false
            c.device = row["device"] as? String
            c.status = .ready
            c.updatedAt = updated
            try? storage.save(c)
            if let segs = row["transcript"] as? [[String: Any]],
               let data = try? JSONSerialization.data(withJSONObject: segs.map { s -> [String: Any] in
                   var s = s
                   if s["id"] == nil { s["id"] = UUID().uuidString }
                   return s
               }),
               let segments = try? JSONDecoder().decode([Segment].self, from: data) {
                try? storage.saveTranscript(segments, for: id)
            }
            if let summary = row["summary"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: summary),
               let decoded = try? Self.isoDecoder.decode(Summary.self, from: data) {
                try? storage.saveSummary(decoded, for: id)
            }
            if let notes = row["notes"] as? String { try? storage.saveNotes(notes, for: id) }
            changed = true
        }
        if changed { calls = storage.loadCalls() }
    }

    // MARK: Rows

    private func meetingRow(_ call: Call) -> [String: Any] {
        let segments = storage.transcript(for: call.id)
        var row: [String: Any] = [
            "id": call.id, "title": call.title, "started_at": Self.iso(call.startedAt), "duration_s": call.duration,
            "status": call.status.rawValue, "mic_only": call.micOnly,
            "transcript": segments.map { ["id": $0.id.uuidString, "speaker": $0.speaker.rawValue, "start": $0.start,
                                          "end": $0.end, "text": $0.text, "language": $0.language as Any,
                                          "speakerID": $0.speakerID as Any, "name": $0.name as Any] },
            "transcript_text": TranscriptText.copyText(call: call, segments: segments),
            "notes": storage.notes(for: call.id),
            "updated_at": Self.iso(call.updatedAt ?? call.startedAt),
        ]
        row["app_name"] = call.appName ?? NSNull()
        row["project_id"] = call.projectID ?? NSNull()
        row["event_id"] = call.eventID ?? NSNull()
        row["them_name"] = call.themName ?? NSNull()
        row["device"] = call.device ?? NSNull()
        if let summary = storage.summary(for: call.id), let data = try? Self.isoEncoder.encode(summary),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            row["summary"] = obj
        }
        return row
    }

    static func taskRow(_ t: TaskItem) -> [String: Any] {
        [
            "id": t.id.uuidString.lowercased(), "text": t.text, "notes": t.notes ?? NSNull(), "status": t.status.rawValue,
            "meeting_id": t.callID ?? NSNull(), "project_id": t.projectID ?? NSNull(),
            "due": t.due.map(dayString) ?? NSNull(), "blocked_reason": t.blockedReason ?? NSNull(),
            "created_at": iso(t.createdAt), "done_at": t.doneAt.map(iso) ?? NSNull(),
            "updated_at": iso(t.updatedAt), "deleted": false, "source": t.source ?? "mochi",
        ]
    }

    static func event(_ row: [String: Any]) -> UpcomingEvent? {
        guard let id = row["id"] as? String, let title = row["title"] as? String,
              let start = (row["starts_at"] as? String).flatMap(date), let end = (row["ends_at"] as? String).flatMap(date),
              end > Date() else { return nil }
        return UpcomingEvent(id: id, title: title, start: start, end: end, appName: row["app_name"] as? String,
                             attendees: row["attendees"] as? [String] ?? [], calendar: row["calendar"] as? String)
    }

    // MARK: Dates

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Postgres style "2026-11-01 11:23:38.47+00"
        let g = DateFormatter()
        g.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd HH:mm:ss.SSSXXXXX", "yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"] {
            g.dateFormat = fmt
            if let d = g.date(from: s) { return d }
        }
        return nil
    }

    static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func day(_ s: String) -> Date? {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    static let isoDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = PhoneModel.date(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: s))
            }
            return date
        }
        return d
    }()

    static let isoEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
