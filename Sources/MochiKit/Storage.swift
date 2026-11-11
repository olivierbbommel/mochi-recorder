import Foundation

/// Where Mochi keeps everything. Local files only: one folder per call, plus tasks.json.
///
///   ~/Mochi/calls/<call id>/call.json, mic.wav and them.wav (mic.m4a and them.m4a once compressed), transcript.json, summary.json, notes.md, capture.log, speakers.json
///   ~/Mochi/tasks.json, projects.json, voices.json
public struct Storage: Sendable {
    public let root: URL

    /// `MOCHI_ROOT` overrides the folder (demo data, tests); default ~/Mochi.
    public init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["MOCHI_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? Storage.defaultRoot
    }

    /// ~/Mochi on a Mac, Documents/Mochi on an iPhone.
    static var defaultRoot: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mochi")
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Mochi")
        #endif
    }

    public var callsFolder: URL { root.appendingPathComponent("calls", isDirectory: true) }
    public var tasksFile: URL { root.appendingPathComponent("tasks.json") }

    public func folder(for id: String) -> URL { callsFolder.appendingPathComponent(id, isDirectory: true) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Storage.encoder.encode(value).write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Storage.decoder.decode(type, from: data)
    }

    // MARK: Calls

    public func loadCalls() -> [Call] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: callsFolder.path) else { return [] }
        return names.compactMap { read(Call.self, from: folder(for: $0).appendingPathComponent("call.json")) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func save(_ call: Call) throws {
        try write(call, to: folder(for: call.id).appendingPathComponent("call.json"))
    }

    public func transcript(for id: String) -> [Segment] {
        read([Segment].self, from: folder(for: id).appendingPathComponent("transcript.json")) ?? []
    }

    public func saveTranscript(_ segments: [Segment], for id: String) throws {
        try write(segments, to: folder(for: id).appendingPathComponent("transcript.json"))
    }

    public func summary(for id: String) -> Summary? {
        read(Summary.self, from: folder(for: id).appendingPathComponent("summary.json"))
    }

    public func saveSummary(_ summary: Summary, for id: String) throws {
        try write(summary, to: folder(for: id).appendingPathComponent("summary.json"))
    }

    public func notes(for id: String) -> String {
        (try? String(contentsOf: folder(for: id).appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
    }

    public func saveNotes(_ text: String, for id: String) throws {
        try FileManager.default.createDirectory(at: folder(for: id), withIntermediateDirectories: true)
        try text.write(to: folder(for: id).appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    }

    /// A track of a call ("mic" or "them"): the WAV while it is fresh, the compressed .m4a after.
    public func track(_ name: String, of id: String) -> URL? {
        for ext in ["wav", "m4a"] {
            let url = folder(for: id).appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Moves the call's folder to the Trash (recoverable), never a hard delete.
    public func trash(_ id: String) throws {
        try FileManager.default.trashItem(at: folder(for: id), resultingItemURL: nil)
    }

    // MARK: Voices (this Mac only, never synced: voiceprints are biometric data)

    /// The voices told apart in one call: speakers.json in its folder. Nil before that ran.
    public func speakers(for id: String) -> CallSpeakers? {
        read(CallSpeakers.self, from: folder(for: id).appendingPathComponent("speakers.json"))
    }

    public func saveSpeakers(_ speakers: CallSpeakers, for id: String) throws {
        try write(speakers, to: folder(for: id).appendingPathComponent("speakers.json"))
    }

    public var voicesFile: URL { root.appendingPathComponent("voices.json") }

    /// The people Mochi knows by voice.
    public func loadVoices() -> [Voice] { read([Voice].self, from: voicesFile) ?? [] }

    public func saveVoices(_ voices: [Voice]) throws { try write(voices, to: voicesFile) }

    // MARK: Projects

    public var projectsFile: URL { root.appendingPathComponent("projects.json") }

    public func loadProjects() -> [Project] { read([Project].self, from: projectsFile) ?? Project.defaults }

    public func saveProjects(_ projects: [Project]) throws { try write(projects, to: projectsFile) }

    // MARK: Tasks

    public func loadTasks() -> [TaskItem] { read([TaskItem].self, from: tasksFile) ?? [] }

    public func saveTasks(_ tasks: [TaskItem]) throws { try write(tasks, to: tasksFile) }

    /// Free space on the volume that holds the recordings, in bytes.
    public func freeSpace() -> Int64? {
        let values = try? root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
