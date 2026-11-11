import Foundation
import MochiKit
import Security

/// Keeps a text-only copy of calls, summaries, tasks, projects and upcoming meetings in your own
/// Supabase project (MochiConfig), so Claude (through the mochi-mcp connector) can read them and add
/// tasks. Audio never leaves the Mac. Tasks sync both ways: the newer change wins.
///
/// Off when the sync token is missing from the Keychain (service "mochi", account
/// "MOCHI_SYNC_TOKEN") or the Settings switch is off. Failures are kept quiet and retried on the
/// next change or the next minute: the Mac copy is always the source of truth for calls.
@MainActor
final class CloudSync {
    static let shared = CloudSync()

    private(set) var lastError: String?
    private(set) var lastSync: Date?
    private var pendingMeetings: Set<String> = []
    private var pushTasks = false
    private var pushProjects = false
    private var pushEvents = false
    // Deletes waiting to reach the cloud survive a quit: kept in ~/Mochi/pending-deletes.json.
    private var tombstones: [[String: Any]] = CloudSync.loadPending("tasks") { didSet { savePending() } }
    private var meetingTombstones: [[String: Any]] = CloudSync.loadPending("meetings") { didSet { savePending() } }

    /// Storage() itself, not AppModel.shared: CloudSync is first touched while AppModel is still
    /// being created (its calendar refresh), and asking for AppModel there crashed build 222 at launch.
    private static var pendingFile: URL { Storage().root.appendingPathComponent("pending-deletes.json") }

    private static func loadPending(_ key: String) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: pendingFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return json[key] as? [[String: Any]] ?? []
    }

    private func savePending() {
        let json: [String: Any] = ["tasks": tombstones, "meetings": meetingTombstones]
        if tombstones.isEmpty && meetingTombstones.isEmpty {
            try? FileManager.default.removeItem(at: Self.pendingFile)
        } else if let data = try? JSONSerialization.data(withJSONObject: json) {
            try? data.write(to: Self.pendingFile, options: .atomic)
        }
    }
    private var debounce: Task<Void, Never>?
    private var timer: Timer?
    private var syncing = false
    private var syncAgain = false

    /// Never for demo or test data (MOCHI_ROOT set): on 1 Nov 2026 a screenshot run pushed demo
    /// calls and tasks into the real sync.
    var enabled: Bool {
        !Self.isDemoRun && MochiConfig.cloudConfigured && (UserDefaults.standard.object(forKey: "cloudSync") as? Bool ?? true)
            && (signedInEmail != nil || Self.token() != nil)
    }

    /// The account this Mac is signed in to (refreshed at launch and after signing in or out).
    private(set) var signedInEmail: String?

    func refreshAccount() async {
        signedInEmail = await Account.shared.email()
    }

    /// The connector address for claude.ai > Settings > Connectors (no secret in it).
    static var connectorURL: String? { MochiConfig.function("mochi-mcp")?.absoluteString }

    /// The value for the connector's x-api-key request header. It is the key, so it is only ever
    /// copied to the clipboard, never shown.
    static func connectorHeaderValue() -> String? {
        token(account: "MOCHI_MCP_TOKEN")
    }

    /// Demo and test runs (MOCHI_ROOT set) never touch the real Keychain either: a test build
    /// with another bundle id otherwise raises a Keychain password prompt and hangs Settings.
    nonisolated static var isDemoRun: Bool { ProcessInfo.processInfo.environment["MOCHI_ROOT"] != nil }

    static func token(account: String = "MOCHI_SYNC_TOKEN") -> String? {
        guard !isDemoRun else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "mochi",
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores a key pasted on another Mac (sync key or connector key) in this Mac's Keychain.
    static func saveToken(_ value: String, account: String) {
        guard !isDemoRun else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "mochi",
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// The keys another Mac needs, as one line: "mochi-setup:<sync key>:<connector key>[:<Claude key>]".
    static func setupCode() -> String? {
        guard let sync = token(), let mcp = token(account: "MOCHI_MCP_TOKEN") else { return nil }
        let claude = Summarizer.apiKey().map { ":\($0)" } ?? ""
        return "mochi-setup:\(sync):\(mcp)\(claude)"
    }

    /// Takes a setup code from the other Mac. Returns false when it is not one.
    static func apply(setupCode: String) -> Bool {
        let parts = setupCode.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        guard parts.count >= 3, parts[0] == "mochi-setup", !parts[1].isEmpty, !parts[2].isEmpty else { return false }
        saveToken(parts[1], account: "MOCHI_SYNC_TOKEN")
        saveToken(parts[2], account: "MOCHI_MCP_TOKEN")
        if parts.count >= 4, !parts[3].isEmpty { Summarizer.saveKey(parts[3...].joined(separator: ":")) }
        return true
    }

    /// When the last push that reached the cloud was put together. Calls changed after it are
    /// pushed at launch; older ones are already there. Missing (first run of this build): all.
    private static let pushedKey = "cloudPushedAt"

    /// At launch: push what changed since the last push, then pull every minute.
    func start() {
        guard enabled else { return }
        // Calls recorded before calls synced between Macs: they are from this Mac if their audio is here.
        let model = AppModel.shared
        var stamped = false
        for var call in model.calls where call.device == nil {
            if model.storage.track("mic", of: call.id) != nil {
                call.device = AppModel.deviceName
                try? model.storage.save(call)
                stamped = true
            }
        }
        if stamped { model.reloadFromSync() }
        let pushedAt = UserDefaults.standard.object(forKey: Self.pushedKey) as? Date ?? .distantPast
        pendingMeetings = Set(model.calls.filter { $0.status != .recording && ($0.updatedAt ?? $0.startedAt) > pushedAt }.map(\.id))
        pushTasks = true
        pushProjects = true
        pushEvents = true
        schedule(after: 2)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { CloudSync.shared.schedule(after: 0) }
        }
    }

    static var summarisesForPhone: Bool {
        UserDefaults.standard.object(forKey: "summarisePhoneCalls") as? Bool
            ?? AppModel.deviceName.localizedCaseInsensitiveContains("mini")
    }

    func meetingChanged(_ id: String) { pendingMeetings.insert(id); schedule() }
    func tasksChanged() { pushTasks = true; schedule() }
    func projectsChanged() { pushProjects = true; schedule() }
    func eventsChanged() { pushEvents = true; schedule() }
    /// A whole row (the table's required columns must be there), marked deleted and newer.
    func meetingDeleted(_ call: Call) {
        guard !Self.isDemoRun else { return }
        var row = meetingRow(call)
        row["deleted"] = true
        row["updated_at"] = Self.iso(Date())
        meetingTombstones.append(row)
        pendingMeetings.remove(call.id)
        schedule(after: 0)
    }

    func taskDeleted(_ task: TaskItem) {
        guard !Self.isDemoRun else { return }
        var row = Self.row(task)
        row["deleted"] = true
        row["updated_at"] = Self.iso(Date())
        tombstones.append(row)
        schedule()
    }

    private func schedule(after seconds: Double = 2) {
        guard enabled else { return }
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    private func sync() async {
        // One at a time: two overlapping runs would both count the same tombstones as sent and
        // drop one queued during the first run.
        guard !syncing else { syncAgain = true; return }
        syncing = true
        defer {
            syncing = false
            if syncAgain { syncAgain = false; schedule(after: 1) }
        }
        let model = AppModel.shared
        // Changes made after this moment are not in this push, so they stay newer than the mark.
        let builtAt = Date()
        do {
            var push: [String: Any] = ["action": "push"]
            // Projects first: meetings and tasks point at them.
            if pushProjects || pushTasks || !pendingMeetings.isEmpty {
                // Each project's own edit time: the cloud keeps the newer edit, so the other Mac's
                // changes (a note, a new name) are not overwritten by this Mac's older copy.
                push["projects"] = model.projects.enumerated().map { i, p in
                    ["id": p.id, "name": p.name, "color": p.color, "sort": i, "note": p.note ?? NSNull(),
                     "updated_at": Self.iso(p.updatedAt ?? Date(timeIntervalSince1970: 0))] as [String: Any]
                }
            }
            let meetingIDs = pendingMeetings
            push["meetings"] = meetingIDs.compactMap { id in model.call(id).map { meetingRow($0) } } + meetingTombstones
            let sentMeetingTombstones = meetingTombstones.count
            if pushTasks { push["tasks"] = model.tasks.map(Self.row) + tombstones }
            else if !tombstones.isEmpty { push["tasks"] = tombstones }
            if pushEvents && model.calendar.authorized { push["events"] = model.calendar.meetings.map(Self.eventRow) }
            let sentTombstones = tombstones.count
            _ = try await post(push)
            pendingMeetings.subtract(meetingIDs)
            // Every call changed before builtAt is in the cloud now, unless one is still queued
            // (it arrived while this push was in flight): then keep the old mark.
            if pendingMeetings.isEmpty { UserDefaults.standard.set(builtAt, forKey: Self.pushedKey) }
            pushTasks = false
            pushProjects = false
            pushEvents = false
            tombstones.removeFirst(min(sentTombstones, tombstones.count))
            meetingTombstones.removeFirst(min(sentMeetingTombstones, meetingTombstones.count))

            let since = UserDefaults.standard.string(forKey: "cloudPulledAt2")
            let pulled = try await post(["action": "pull", "since": since ?? "1970-01-01T00:00:00Z"])
            model.mergeProjects((pulled["projects"] as? [[String: Any]] ?? []).compactMap(Self.project))
            merge(pulled)
            mergeMeetings(pulled["meetings"] as? [[String: Any]] ?? [])
            if let at = pulled["at"] as? String { UserDefaults.standard.set(at, forKey: "cloudPulledAt2") }
            lastSync = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Tasks changed elsewhere (by Claude) come in; the newer side wins.
    private func merge(_ pulled: [String: Any]) {
        let model = AppModel.shared
        var changed = false
        for row in pulled["tasks"] as? [[String: Any]] ?? [] {
            guard let idText = row["id"] as? String, let id = UUID(uuidString: idText),
                  let updated = (row["updated_at"] as? String).flatMap(Self.date) else { continue }
            let local = model.tasks.firstIndex { $0.id == id }
            if let i = local, model.tasks[i].updatedAt >= updated.addingTimeInterval(-0.5) { continue }
            if row["deleted"] as? Bool == true {
                if let i = local { model.tasks.remove(at: i); changed = true }
                continue
            }
            var task = local.map { model.tasks[$0] } ?? TaskItem(text: "", createdAt: (row["created_at"] as? String).flatMap(Self.date) ?? Date())
            task.text = row["text"] as? String ?? task.text
            task.notes = row["notes"] as? String
            task.status = TaskStatus(rawValue: row["status"] as? String ?? "") ?? task.status
            task.callID = row["meeting_id"] as? String
            task.projectID = row["project_id"] as? String
            task.due = (row["due"] as? String).flatMap(Self.day)
            task.blockedReason = row["blocked_reason"] as? String
            task.doneAt = (row["done_at"] as? String).flatMap(Self.date)
            task.source = row["source"] as? String
            task.updatedAt = updated
            if let i = local { model.tasks[i] = task } else { model.tasks.insert(TaskItem.withID(id, from: task), at: 0) }
            changed = true
        }
        if changed { model.saveTasksQuietly() }
    }

    /// Calls from the other Mac (or edits made there) come in as text: transcript, summary, notes,
    /// title and project. The audio stays on the Mac that recorded it.
    private func mergeMeetings(_ rows: [[String: Any]]) {
        let model = AppModel.shared
        let storage = model.storage
        var changed = false
        for row in rows {
            if row["deleted"] as? Bool == true, let id = row["id"] as? String {
                if model.call(id) != nil, model.session?.call.id != id { model.delete(id, sync: false); changed = true }
                continue
            }
            guard let id = row["id"] as? String, let title = row["title"] as? String,
                  let started = (row["started_at"] as? String).flatMap(Self.date),
                  let updated = (row["updated_at"] as? String).flatMap(Self.date) else { continue }
            let local = model.call(id)
            if let local, (local.updatedAt ?? local.startedAt) >= updated.addingTimeInterval(-0.5) { continue }
            var call = local ?? Call(id: id, title: title, startedAt: started, status: .ready)
            call.title = title
            call.duration = row["duration_s"] as? Double ?? call.duration
            call.appName = row["app_name"] as? String ?? call.appName
            call.projectID = row["project_id"] as? String
            call.themName = row["them_name"] as? String
            call.micOnly = row["mic_only"] as? Bool ?? call.micOnly
            call.device = row["device"] as? String ?? call.device
            call.updatedAt = updated
            if call.status == .recording { continue }   // never touch a call recording here
            try? storage.save(call)
            if let segs = row["transcript"] as? [[String: Any]],
               let data = try? JSONSerialization.data(withJSONObject: segs.map { s -> [String: Any] in
                   var s = s
                   s["id"] = s["id"] ?? UUID().uuidString
                   return s
               }),
               let segments = try? JSONDecoder().decode([Segment].self, from: data) {
                try? storage.saveTranscript(segments, for: id)
            }
            if let summary = row["summary"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: summary),
               let decoded = try? JSONDecoder.isoDecoder.decode(Summary.self, from: data) {
                try? storage.saveSummary(decoded, for: id)
            }
            if let notes = row["notes"] as? String { try? storage.saveNotes(notes, for: id) }
            changed = true
        }
        if changed { model.reloadFromSync() }
        // Calls recorded on the iPhone have no Claude key there: one Mac writes their summary.
        // The Mac mini does it by default (it is always on); Settings can turn it on elsewhere.
        if Self.summarisesForPhone, model.summariesOn, Summarizer.apiKey() != nil {
            for row in rows {
                guard row["deleted"] as? Bool != true, let id = row["id"] as? String,
                      let device = row["device"] as? String, device.localizedCaseInsensitiveContains("iPhone"),
                      row["summary"] == nil || row["summary"] is NSNull,
                      !model.storage.transcript(for: id).isEmpty, model.summary(id) == nil else { continue }
                model.summarize(id)
            }
        }
    }

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        try await MochiAPI.call(body, legacyToken: Self.token())
    }

    // MARK: Rows

    private func meetingRow(_ call: Call) -> [String: Any] {
        let model = AppModel.shared
        let segments = model.transcript(call.id)
        var row: [String: Any] = [
            "id": call.id, "title": call.title, "started_at": Self.iso(call.startedAt), "duration_s": call.duration,
            "status": call.status.rawValue, "mic_only": call.micOnly,
            "transcript": segments.map { ["speaker": $0.speaker.rawValue, "start": $0.start, "end": $0.end, "text": $0.text,
                                          "language": $0.language as Any, "speakerID": $0.speakerID as Any,
                                          "name": $0.name as Any] },
            "transcript_text": TranscriptText.copyText(call: call, segments: segments),
            "notes": model.storage.notes(for: call.id),
            "updated_at": Self.iso(call.updatedAt ?? call.startedAt),
        ]
        row["device"] = call.device ?? NSNull()
        row["app_name"] = call.appName ?? NSNull()
        row["project_id"] = call.projectID ?? NSNull()
        row["event_id"] = call.eventID ?? NSNull()
        row["them_name"] = call.themName ?? NSNull()
        if let summary = model.summary(call.id),
           let data = try? JSONEncoder.iso.encode(summary), let obj = try? JSONSerialization.jsonObject(with: data) {
            row["summary"] = obj
        } else {
            row["summary"] = NSNull()
        }
        return row
    }

    static func row(_ t: TaskItem) -> [String: Any] {
        [
            "id": t.id.uuidString.lowercased(), "text": t.text, "notes": t.notes ?? NSNull(), "status": t.status.rawValue,
            "meeting_id": t.callID ?? NSNull(), "project_id": t.projectID ?? NSNull(),
            "due": t.due.map(dayString) ?? NSNull(), "blocked_reason": t.blockedReason ?? NSNull(),
            "created_at": iso(t.createdAt), "done_at": t.doneAt.map(iso) ?? NSNull(),
            "updated_at": iso(t.updatedAt), "deleted": false, "source": t.source ?? "mochi",
        ]
    }

    static func project(_ row: [String: Any]) -> Project? {
        guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
        return Project(id: id, name: name, color: row["color"] as? String ?? "blue", note: row["note"] as? String,
                       updatedAt: (row["updated_at"] as? String).flatMap(date))
    }

    static func eventRow(_ m: Meeting) -> [String: Any] {
        ["id": m.id, "title": m.title, "starts_at": iso(m.start), "ends_at": iso(m.end),
         "app_name": m.appName ?? NSNull(), "attendees": m.attendees, "calendar": m.calendarName]
    }

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
        return f.date(from: s)
    }

    /// Deadlines are days: stored as YYYY-MM-DD in the local time zone.
    static func dayString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func day(_ s: String) -> Date? {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

extension JSONDecoder {
    static let isoDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = CloudSync.date(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date \(s)"))
            }
            return date
        }
        return d
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension TaskItem {
    /// A copy with a given id (tasks made by Claude keep the id the cloud gave them).
    static func withID(_ id: UUID, from t: TaskItem) -> TaskItem {
        var copy = TaskItem(id: id, text: t.text, status: t.status, callID: t.callID, projectID: t.projectID,
                            due: t.due, createdAt: t.createdAt)
        copy.blockedReason = t.blockedReason
        copy.doneAt = t.doneAt
        copy.source = t.source
        copy.updatedAt = t.updatedAt
        return copy
    }
}
