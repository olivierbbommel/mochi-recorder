import AppKit
import AVFoundation
import Foundation
import MochiCapture
import MochiKit
import MochiTranscribe
import Observation
import SwiftUI

enum Section: Hashable {
    case today, upcoming, calls, tasks
    case project(String)
}

/// What the pill shows for a few seconds after Stop.
struct SavedNotice: Equatable {
    var callID: String
    var title: String
    var duration: Double
    var bothSides: Bool
}

@Observable
@MainActor
final class AppModel {
    static let shared = AppModel()

    let storage = Storage()
    var section: Section = .today
    var selectedCallID: String?
    private(set) var calls: [Call] = []
    var tasks: [TaskItem] = []
    private(set) var projects: [Project] = []
    /// The task just created with ⌘N or New Task, for the list to focus once its row exists.
    var newTaskID: UUID?
    private(set) var session: RecordingSession?
    var savedNotice: SavedNotice?
    var startError: String?
    /// A call app that has held the mic for 8 s while Mochi is not recording (shown in the app, so
    /// the prompt works even when notifications are off).
    var detectedApp: CallApp?
    let calendar = CalendarService()
    /// Set by "Rename" in the calls list: the call's detail opens its title for editing.
    var renamingCallID: String?
    /// Calls whose better after-call transcript is still being written (the live one shows meanwhile).
    private(set) var refining: Set<String> = []
    /// Bumped when a transcript file changes, so open views reload it.
    private(set) var transcriptVersion = 0
    /// Calls whose summary is being written, and the last summary error per call.
    private(set) var summarizing: Set<String> = []
    private(set) var summaryErrors: [String: String] = [:]
    /// Bumped when a summary is written, so views that read it from disk refresh.
    private(set) var summaryVersion = 0
    /// Transcripts and summaries as last read from disk, so views do not re-read and re-decode
    /// the JSON on every redraw. Dropped whenever transcriptVersion or summaryVersion moves.
    @ObservationIgnored private var transcriptCache: [String: [Segment]] = [:]
    @ObservationIgnored private var transcriptCacheVersion = -1
    @ObservationIgnored private var summaryCache: [String: Summary?] = [:]
    @ObservationIgnored private var summaryCacheVersion = -1
    var summariesOn: Bool { (UserDefaults.standard.string(forKey: "summaries") ?? "claude") == "claude" }

    private init() {
        reload()
        // A meeting that lands mid-recording (added late on the phone or in Notion Calendar) can
        // still name the call.
        calendar.onChange = { [weak self] in
            guard let self, let id = self.session?.call.id else { return }
            self.retitleFromCalendar(id)
        }
        // Parakeet stays loaded for live captions. Whisper (over 1 GB) is not loaded here: it is
        // only needed after a call, so Stop loads it and it is let go a few minutes after.
        Task {
            try? await Transcriber.shared.prepare()
            await warmWhisperOnce()
        }
    }

    /// The first Whisper load after an install or a macOS update compiles the model for the
    /// Neural Engine (about 90 s); later loads take about 8 s. Do that once per build and macOS
    /// version a minute after launch, while nothing waits on it, then let the model go again.
    private func warmWhisperOnce() async {
        guard languageMode != .english, !CloudSync.isDemoRun else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let stamp = "\(build)/\(ProcessInfo.processInfo.operatingSystemVersionString)"
        guard UserDefaults.standard.string(forKey: "whisperWarmed") != stamp else { return }
        try? await Task.sleep(for: .seconds(60))
        guard !isRecording else { return }   // Stop loads it anyway
        do {
            try await Task.detached(priority: .background) { try await WhisperRefiner.shared.prepare() }.value
            UserDefaults.standard.set(stamp, forKey: "whisperWarmed")
        } catch {}
    }

    private var languageMode: LanguageMode {
        LanguageMode(rawValue: UserDefaults.standard.string(forKey: "language") ?? "auto") ?? .auto
    }

    func reload() {
        calls = storage.loadCalls()
        tasks = storage.loadTasks()
        projects = storage.loadProjects()
        // Calls from before compression existed: shrink their WAVs once.
        for call in calls where call.status == .ready && session?.call.id != call.id {
            if storage.track("mic", of: call.id)?.pathExtension == "wav" { Compressor.compress(storage.folder(for: call.id)) }
        }
        // A crash mid-recording leaves a call in "recording": it has audio, so finish it.
        for call in calls where call.status == .recording && session?.call.id != call.id {
            var fixed = call
            fixed.status = .transcribing
            update(fixed)
            finishTranscript(fixed.id, offset: 0)
        }
    }

    var isRecording: Bool { session != nil }
    var openTaskCount: Int { tasks.filter { !$0.done }.count }

    func call(_ id: String?) -> Call? { calls.first { $0.id == id } }

    /// After a sync brought in calls or edits from the other Mac.
    func reloadFromSync() {
        calls = storage.loadCalls()
        if let current = session?.call, !calls.contains(where: { $0.id == current.id }) { calls.insert(current, at: 0) }
        transcriptVersion += 1
        summaryVersion += 1
    }

    /// The call changed in a way that syncs: stamp it so the other Mac takes this version.
    func touch(_ id: String) {
        if let call = call(id) { update(call) }   // update stamps updatedAt
    }

    /// This Mac's name, on the calls it records.
    static let deviceName = Host.current().localizedName ?? "Mac"

    var isRemote: (Call) -> Bool { { $0.device != nil && $0.device != AppModel.deviceName } }

    func update(_ call: Call) {
        var call = call
        call.updatedAt = Date()
        if call.device == nil { call.device = AppModel.deviceName }
        try? storage.save(call)
        if let session, session.call.id == call.id { session.call = call }
        if call.status != .recording { CloudSync.shared.meetingChanged(call.id) }
        if let i = calls.firstIndex(where: { $0.id == call.id }) { calls[i] = call } else {
            calls.insert(call, at: 0)
        }
    }

    // MARK: Recording

    /// `app` nil: Mochi follows the first call app that uses the mic.
    func startRecording(event: Meeting? = nil, app: CallApp? = nil) {
        guard session == nil else { return }
        startError = nil
        savedNotice = nil
        let now = Date()
        let detected = app ?? CallApp.capturingNow()
        // A meeting added a minute ago may not be on this Mac yet: ask the calendar to fetch now,
        // and re-check the title when new events land and again at Stop.
        calendar.syncNow()
        calendar.refresh()
        let matched = event ?? calendar.eventNow()
        let title = matched?.title ?? detected.map { "\($0.name) call" } ?? "Recording"
        let call = Call(id: Call.newID(at: now), title: title, startedAt: now, appName: matched?.appName ?? detected?.name,
                        projectID: Project.guess(from: title, in: projects)?.id, eventID: matched?.id)
        // Picked from the Join card: that event is the call. Otherwise the title is Mochi's guess,
        // which a better calendar match may replace until you type your own.
        autoTitle = event == nil ? AutoTitle(callID: call.id, title: title) : nil
        let session = RecordingSession(call: call, folder: storage.folder(for: call.id), app: detected)
        session.onEnded = { [weak self] in self?.stopRecording() }
        session.onCallEndedPrompt = { Notifier.callEnded(app: session.callApp?.name ?? "The call app") }
        do {
            try session.start()
        } catch {
            startError = "Recording could not start: \(error)"
            return
        }
        self.session = session
        update(call)
        section = .today
        Sounds.started()
        PillController.shared.show()
    }

    /// The title Mochi gave the call being recorded, while you have not changed it.
    private struct AutoTitle { var callID: String; var title: String }
    @ObservationIgnored private var autoTitle: AutoTitle?

    /// Re-checks the calendar for the call being recorded: the event it overlaps most names it.
    /// While it runs, the first 15 minutes count as the recording (a call about to start beats
    /// one ending); at Stop (`stopping`), the recording as it was. Never replaces a title you typed.
    func retitleFromCalendar(_ id: String, stopping: Bool = false) {
        guard let auto = autoTitle, auto.callID == id, var call = call(id) else { return }
        guard call.title == auto.title else { autoTitle = nil; return }   // renamed by hand
        let now = Date()
        let end = stopping ? now : max(now, call.startedAt.addingTimeInterval(EventMatch.lookAhead))
        guard let m = calendar.event(forRecordingFrom: call.startedAt, to: end), m.id != call.eventID || m.title != call.title else { return }
        let guessed = Project.guess(from: call.title, in: projects)?.id
        call.title = m.title
        call.eventID = m.id
        if call.projectID == guessed { call.projectID = Project.guess(from: m.title, in: projects)?.id }
        if call.appName == nil { call.appName = m.appName }
        autoTitle = AutoTitle(callID: id, title: m.title)
        update(call)
    }

    func togglePause() {
        guard let session else { return }
        session.setPaused(!session.paused)
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    /// Stop feels instant: the call is saved and shown with its live transcript at once, like
    /// Granola. Closing the devices, the last live lines and the better after-call pass all happen
    /// behind it, and the better transcript swaps in when it is ready.
    /// `closed` runs once both audio files are closed on disk (quit waits for it).
    func stopRecording(closed: (() -> Void)? = nil) {
        guard let session else { closed?(); return }
        // Last look at the calendar while it is still the session's call: a meeting added late
        // has usually landed by now.
        retitleFromCalendar(session.call.id, stopping: true)
        autoTitle = nil
        self.session = nil
        Sounds.stopped()
        let (liveNow, seconds) = session.snapshotAtStop
        var call = self.call(session.call.id) ?? session.call
        call.duration = seconds
        call.appName = session.callApp?.name ?? call.appName
        call.status = .ready
        try? storage.saveTranscript(TranscriptText.clean(liveNow), for: call.id)
        transcriptVersion += 1
        update(call)
        savedNotice = SavedNotice(callID: call.id, title: call.title, duration: seconds, bothSides: session.callApp != nil)
        selectedCallID = call.id
        section = .calls
        refining.insert(call.id)
        // Load Whisper while the devices close and Parakeet runs, so the Dutch pass does not wait.
        if languageMode != .english { Task.detached(priority: .utility) { try? await WhisperRefiner.shared.prepare() } }
        Task {
            let (result, live) = await session.stop()
            // Re-read: a rename or project picked while the devices closed must survive.
            if var latest = self.call(call.id) {
                latest.duration = max(result.micSeconds, result.themSeconds)
                latest.micOnly = result.themSeconds < 1
                update(latest)
                call = latest
            }
            closed?()   // after the final duration is on disk: quitting may follow at once
            Notifier.saved(call)
            // Nothing was said: say so now instead of running the engines over silence.
            if max(result.micPeak, result.themPeak) < 0.003 {
                try? storage.saveTranscript([], for: call.id)
                refining.remove(call.id)
                transcriptVersion += 1
            } else {
                if live.count > liveNow.count { try? storage.saveTranscript(TranscriptText.clean(live), for: call.id) }
                transcriptVersion += 1
                finishTranscript(call.id, offset: session.callTrackOffset)
            }
            try? await Task.sleep(for: .seconds(8))
            if savedNotice?.callID == call.id { savedNotice = nil }
        }
    }

    /// The after-call pass over both full tracks. The call is already readable with its live lines;
    /// the better transcript replaces them only if it has something in it.
    func finishTranscript(_ id: String, offset: Double) {
        refining.insert(id)
        let folder = storage.folder(for: id)
        Task {
            defer { refining.remove(id) }
            guard self.call(id) != nil else { return }
            var status = CallStatus.ready
            var failure: String?
            do {
                let mode = languageMode
                guard let micFile = storage.track("mic", of: id) else { throw Compressor.Problem("The recording is not on this Mac.") }
                // Each track is decoded once (off the main thread) and shared by both passes.
                let mic = try await Self.decode(micFile)
                var segments = try await Transcriber.shared.transcribe(track: mic, speaker: .me)
                segments = await refined(segments, samples: mic, speaker: .me, mode: mode)
                var voices: (found: SpeakerFinder.Found, offset: Double)?
                if let themFile = storage.track("them", of: id) {
                    let start = offset > 0 ? offset : themOffset(folder)
                    let themSamples = try await Self.decode(themFile)
                    // Who speaks when on the other side. Optional: without it the lines say "Them".
                    let found = try? await SpeakerFinder.shared.find(samples: themSamples)
                    var them = try await Transcriber.shared.transcribe(track: themSamples, speaker: .them,
                                                                       breaks: Voices.changes(found?.spans ?? []))
                    them = await refined(them, samples: themSamples, speaker: .them, mode: mode)
                    segments += them.map { var s = $0; s.start += start; s.end += start; return s }
                    if let found, !found.spans.isEmpty { voices = (found, start) }
                }
                segments.sort { $0.start < $1.start }
                segments = TranscriptText.clean(segments)
                if let voices { segments = labelVoices(id, found: voices.found, offset: voices.offset, segments: segments) }
                if !segments.isEmpty || storage.transcript(for: id).isEmpty {
                    try? storage.saveTranscript(segments, for: id)
                    transcriptVersion += 1
                }
            } catch {
                // The live lines stay; only a call with none at all counts as failed.
                if storage.transcript(for: id).isEmpty {
                    status = .failed
                    failure = "\(error.localizedDescription)"
                }
            }
            // The pass can take minutes: change only the status on the call as it is now, so a
            // rename, project or name typed meanwhile is kept.
            guard var call = self.call(id) else { return }
            if status == .failed || call.status == .failed { call.status = status; call.failure = failure }
            else { call.status = .ready }
            update(call)
            if call.status == .ready { Compressor.compress(folder) }
            if call.status == .ready, summariesOn, storage.summary(for: id) == nil,
               !storage.transcript(for: id).isEmpty, Summarizer.apiKey() != nil {
                summarize(id)
            }
        }
    }

    /// The Whisper pass for Dutch. If it fails (first-time model download offline, say), the
    /// Parakeet lines stay: a worse Dutch line beats no transcript.
    private func refined(_ segments: [Segment], samples: [Float], speaker: Speaker, mode: LanguageMode) async -> [Segment] {
        guard mode != .english else { return segments }
        return (try? await WhisperRefiner.shared.refine(samples: samples, speaker: speaker, segments: segments, mode: mode)) ?? segments
    }

    private nonisolated static func decode(_ file: URL) async throws -> [Float] {
        try await Task.detached(priority: .userInitiated) { try Transcriber.samples(of: file) }.value
    }

    /// Where them.wav starts on mic.wav's timeline, from the start markers both recorders write.
    private func themOffset(_ folder: URL) -> Double {
        guard let micData = try? Data(contentsOf: folder.appendingPathComponent("mic.start.json")),
              let mic = (try? JSONSerialization.jsonObject(with: micData)) as? [String: Any],
              let micWall = mic["first_sample_wall"] as? Double,
              let themText = try? String(contentsOf: folder.appendingPathComponent("them.start"), encoding: .utf8),
              let themWall = Double(themText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
        return max(0, themWall - micWall)
    }

    func keepRecording() { session?.keepRecording() }

    // MARK: Voices

    /// Bumped when a call's voices or the known voices change, so views reload them.
    private(set) var voicesVersion = 0
    /// Calls whose voices are being told apart from the Calls view (older calls).
    private(set) var findingSpeakers: Set<String> = []
    /// "<call id>/<speaker id>" while its sample plays.
    private(set) var playingSample: String?
    @ObservationIgnored private var samplePlayer: AVAudioPlayer?
    @ObservationIgnored private var sampleStop: Task<Void, Never>?

    /// Read once per change, not on every redraw of every line.
    @ObservationIgnored private var speakersCache: [String: CallSpeakers?] = [:]
    @ObservationIgnored private var voicesCache: [Voice]?
    @ObservationIgnored private var voicesCacheVersion = -1

    private func refreshVoiceCaches() {
        if voicesCacheVersion != voicesVersion {
            speakersCache = [:]
            voicesCache = nil
            voicesCacheVersion = voicesVersion
        }
    }

    /// The call's voices as found on this Mac (nil before, or on a call recorded on the other Mac).
    func speakers(_ id: String) -> CallSpeakers? {
        refreshVoiceCaches()
        if let cached = speakersCache[id] { return cached }
        let found = storage.speakers(for: id)
        speakersCache[id] = .some(found)
        return found
    }

    /// The people Mochi knows by voice.
    func knownVoices() -> [Voice] {
        refreshVoiceCaches()
        if let voicesCache { return voicesCache }
        let voices = storage.loadVoices()
        voicesCache = voices
        return voices
    }

    /// Links a fresh pass's voices to the lines: keeps those with lines (renumbered by first line),
    /// names the ones Mochi knows for sure, notes guesses, and saves speakers.json. A new pass over
    /// a call starts over: what the call's voices taught before is taken back.
    private func labelVoices(_ id: String, found: SpeakerFinder.Found, offset: Double, segments: [Segment]) -> [Segment] {
        let assigned = Voices.assign(segments, spans: found.spans, offset: offset)
        var (segs, speakers) = Voices.compact(assigned, speakers: found.speakers)
        var known = storage.loadVoices()
        if let old = storage.speakers(for: id) {
            for sp in old.speakers { known = Voices.forget(speakerID: sp.id, callID: id, voices: known) }
            try? storage.saveVoices(known)
        }
        let matches = Voices.recognise(speakers, among: known, excludingCall: id)
        Voices.applyRecognition(matches, speakers: &speakers, segments: &segs, voices: known)
        try? storage.saveSpeakers(CallSpeakers(speakers: speakers, trackOffset: offset), for: id)
        // One voice that Mochi knows: that is the other side's name too.
        if speakers.count == 1, let name = segs.first(where: { $0.speaker == .them && $0.name != nil })?.name,
           var call = call(id), call.themName == nil {
            call.themName = name
            update(call)
        }
        voicesVersion += 1
        return segs
    }

    /// Tells the voices apart on a call recorded before Mochi did that, keeping its transcript.
    func findSpeakers(_ id: String) {
        guard let file = storage.track("them", of: id), !findingSpeakers.contains(id) else { return }
        findingSpeakers.insert(id)
        let folder = storage.folder(for: id)
        Task {
            defer { findingSpeakers.remove(id) }
            guard let samples = try? await Self.decode(file),
                  let found = try? await SpeakerFinder.shared.find(samples: samples) else { return }
            let segments = storage.transcript(for: id)
            guard !found.spans.isEmpty, !segments.isEmpty else {
                try? storage.saveSpeakers(CallSpeakers(speakers: [], trackOffset: 0), for: id)
                voicesVersion += 1
                return
            }
            let labelled = labelVoices(id, found: found, offset: themOffset(folder), segments: segments)
            try? storage.saveTranscript(labelled, for: id)
            transcriptVersion += 1
            touch(id)
        }
    }

    /// You named one voice of a call (blank clears the name): every line of it gets the name,
    /// and Mochi learns the voice for later calls. A correction takes back what the old name learned.
    func nameSpeaker(_ id: String, _ speakerID: String, _ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = Voices.rename(storage.transcript(for: id), speakerID: speakerID, to: clean)
        try? storage.saveTranscript(segments, for: id)
        if var info = storage.speakers(for: id), let i = info.speakers.firstIndex(where: { $0.id == speakerID }) {
            let (known, voiceID) = Voices.learn(name: clean, speaker: info.speakers[i], callID: id, voices: storage.loadVoices())
            info.speakers[i].voiceID = voiceID
            info.speakers[i].guessID = nil
            try? storage.saveVoices(known)
            try? storage.saveSpeakers(info, for: id)
        }
        transcriptVersion += 1
        voicesVersion += 1
        guard var call = call(id) else { return }
        if TranscriptText.voiceCount(segments) <= 1 { call.themName = clean.isEmpty ? nil : clean }
        update(call)   // stamps it, so the names sync
    }

    /// The name Mochi thinks a voice has but is not sure of.
    func guessName(_ id: String, _ speakerID: String) -> String? {
        guard let guess = speakers(id)?.speaker(speakerID)?.guessID else { return nil }
        return knownVoices().first { $0.id == guess }?.name
    }

    /// Plays a few seconds of one voice from the other side's track. Again stops it.
    func playSample(_ id: String, _ speakerID: String) {
        let key = "\(id)/\(speakerID)"
        let wasPlaying = playingSample == key
        stopSample()
        guard !wasPlaying, let sp = speakers(id)?.speaker(speakerID), let start = sp.sampleStart,
              let end = sp.sampleEnd, let file = storage.track("them", of: id),
              let player = try? AVAudioPlayer(contentsOf: file) else { return }
        player.currentTime = start
        guard player.play() else { return }
        samplePlayer = player
        playingSample = key
        sampleStop = Task {
            try? await Task.sleep(for: .seconds(max(1, end - start)))
            guard !Task.isCancelled else { return }
            stopSample()
        }
    }

    func stopSample() {
        sampleStop?.cancel()
        sampleStop = nil
        samplePlayer?.stop()
        samplePlayer = nil
        playingSample = nil
    }

    /// Forgets a person's voice everywhere. Lines already named keep the name.
    func forgetVoice(_ voiceID: UUID) {
        try? storage.saveVoices(storage.loadVoices().filter { $0.id != voiceID })
        voicesVersion += 1
    }

    /// Names to offer for a voice: the meeting's invitees first, then people Mochi knows.
    func nameSuggestions(_ id: String) -> [String] {
        var out: [String] = []
        if let eventID = call(id)?.eventID, let meeting = calendar.meetings.first(where: { $0.id == eventID }) {
            out += meeting.attendees
        }
        out += knownVoices().sorted { $0.updatedAt > $1.updatedAt }.map(\.name)
        var seen: Set<String> = []
        return out.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }


    // MARK: Summaries

    func summary(_ id: String) -> Summary? {
        if summaryCacheVersion != summaryVersion { summaryCache = [:]; summaryCacheVersion = summaryVersion }
        if let cached = summaryCache[id] { return cached }
        let summary = storage.summary(for: id)
        summaryCache[id] = .some(summary)
        return summary
    }

    func summarize(_ id: String) {
        guard let call = call(id), !summarizing.contains(id) else { return }
        summarizing.insert(id)
        summaryErrors[id] = nil
        let segments = transcript(id)
        let open = Suggestions.openTasks(tasks)
        let context = Suggestions.context(callDate: call.startedAt, projects: projects, tasks: tasks,
                                          corrections: Suggestions.corrections(recentSummaries(), tasks: tasks, projects: projects))
        let projectList = projects
        Task {
            defer { summarizing.remove(id) }
            do {
                var summary = try await Summarizer.summarize(call: call, segments: segments, context: context,
                                                             projects: projectList, openTasks: open)
                let before = storage.summary(for: id)
                summary.suggestions = Suggestions.carryOver(new: summary.suggestions ?? [], old: before?.suggestions)
                try? storage.saveSummary(summary, for: id)
                summaryVersion += 1
                touch(id)
                let waiting = summary.pendingSuggestions.count
                if waiting > (before?.pendingSuggestions.count ?? 0) { Notifier.suggestions(waiting, call: call) }
            } catch {
                summaryErrors[id] = error.localizedDescription
            }
        }
    }

    /// A summary's suggested task, ticked: it becomes a task linked to the call and its project.
    /// (Summaries from before suggestions existed: their Action Items have + buttons.)
    func addSuggestedTask(_ text: String, callID: String) {
        guard !tasks.contains(where: { $0.callID == callID && $0.text == text }) else { return }
        let task = TaskItem(text: text, callID: callID, projectID: call(callID)?.projectID)
        tasks.insert(task, at: 0)
        saveTasks()
    }

    // MARK: Suggested tasks (reviewed by you, never added on their own)

    /// Summaries of the last 90 days, for the To Review list and for learning from your corrections.
    func recentSummaries() -> [Summary] {
        let since = Date().addingTimeInterval(-90 * 86_400)
        return calls.filter { $0.startedAt > since }.compactMap { summary($0.id) }
    }

    /// Every suggestion still waiting, newest call first.
    var pendingSuggestions: [PendingSuggestion] {
        let _ = summaryVersion
        let since = Date().addingTimeInterval(-90 * 86_400)
        return calls.filter { $0.startedAt > since && $0.status != .recording }.flatMap { call in
            (summary(call.id)?.pendingSuggestions ?? []).map {
                PendingSuggestion(callID: call.id, callTitle: call.title, callDate: call.startedAt, suggestion: $0)
            }
        }
    }

    /// Changes one suggestion in its call's summary, saves it and syncs it with the call.
    private func editSuggestion(_ callID: String, _ id: UUID, _ change: (inout TaskSuggestion) -> Void) {
        guard var summary = storage.summary(for: callID), var list = summary.suggestions,
              let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        summary.suggestions = list
        try? storage.saveSummary(summary, for: callID)
        summaryVersion += 1
        touch(callID)
    }

    /// Adds a suggested task (creating its proposed project if it has one), or applies a suggested
    /// change to an existing task.
    func acceptSuggestion(_ callID: String, _ id: UUID) {
        guard let s = storage.summary(for: callID)?.suggestions?.first(where: { $0.id == id }), s.isPending else { return }
        switch s.kind {
        case .add:
            var projectID = s.projectID
            if projectID == nil, let name = s.newProjectName {
                projectID = (Suggestions.project(named: name, in: projects)
                             ?? addProject(name: name, color: Project.freeColor(in: projects))).id
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

    /// A dismissed suggestion back in review.
    func restoreSuggestion(_ callID: String, _ id: UUID) {
        editSuggestion(callID, id) { if $0.state == .dismissed { $0.state = .pending } }
    }

    /// The project chip: an existing project, nil for none.
    func setSuggestionProject(_ callID: String, _ id: UUID, _ project: Project?) {
        editSuggestion(callID, id) { $0.projectID = project?.id; $0.newProjectName = nil }
    }

    func editSuggestionText(_ callID: String, _ id: UUID, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        editSuggestion(callID, id) { $0.text = t }
    }

    /// Add All: every waiting suggestion of one call, or of all calls.
    func acceptAll(callID: String? = nil) {
        for p in pendingSuggestions where callID == nil || p.callID == callID { acceptSuggestion(p.callID, p.id) }
    }

    // MARK: Calls

    func transcript(_ id: String) -> [Segment] {
        if let session, session.call.id == id { return TranscriptText.clean(session.segments) }
        if transcriptCacheVersion != transcriptVersion { transcriptCache = [:]; transcriptCacheVersion = transcriptVersion }
        if let cached = transcriptCache[id] { return cached }
        let segments = TranscriptText.clean(storage.transcript(for: id))
        transcriptCache[id] = segments
        return segments
    }

    func copyTranscript(_ id: String) {
        guard let call = call(id) ?? session?.call else { return }
        let text = TranscriptText.copyText(call: call, segments: transcript(id))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func rename(_ id: String, to title: String) {
        guard var call = call(id), !title.isEmpty else { return }
        call.title = title
        update(call)
    }

    func setProject(_ id: String, _ project: Project?) {
        guard var call = call(id) else { return }
        call.projectID = project?.id
        update(call)
    }

    func setThemName(_ id: String, _ name: String) {
        guard var call = call(id) else { return }
        call.themName = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
        update(call)
    }

    /// `sync` false when the delete came from the other Mac (it is already a tombstone there).
    func delete(_ id: String, sync: Bool = true) {
        if sync, let call = call(id) { CloudSync.shared.meetingDeleted(call) }
        try? storage.trash(id)
        calls.removeAll { $0.id == id }
        if selectedCallID == id { selectedCallID = calls.first?.id }
    }

    func showInFinder(_ id: String) {
        NSWorkspace.shared.activateFileViewerSelecting([storage.folder(for: id)])
    }

    // MARK: Projects

    func project(_ id: String?) -> Project? { projects.first { $0.id == id } }

    @discardableResult
    func addProject(name: String, color: String, note: String? = nil) -> Project {
        let project = Project(name: name, color: color, note: note, updatedAt: Date())
        projects.append(project)
        try? storage.saveProjects(projects)
        CloudSync.shared.projectsChanged()
        return project
    }

    func updateProject(_ project: Project) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[i] = project
        projects[i].updatedAt = Date()
        try? storage.saveProjects(projects)
        CloudSync.shared.projectsChanged()
    }

    func moveProjects(from source: IndexSet, to destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        let now = Date()
        for i in projects.indices { projects[i].updatedAt = now }
        try? storage.saveProjects(projects)
        CloudSync.shared.projectsChanged()
    }

    /// Removes the tag. Calls and tasks stay, without a project.
    func deleteProject(_ id: String) {
        projects.removeAll { $0.id == id }
        // Kept so a sync never brings it back from the cloud copy.
        var deleted = UserDefaults.standard.stringArray(forKey: "deletedProjects") ?? []
        deleted.append(id)
        UserDefaults.standard.set(deleted, forKey: "deletedProjects")
        try? storage.saveProjects(projects)
        CloudSync.shared.projectsChanged()
        for call in calls where call.projectID == id { var c = call; c.projectID = nil; update(c) }
        for i in tasks.indices where tasks[i].projectID == id { tasks[i].projectID = nil }
        saveTasks()
        if case .project(id) = section { section = .today }
    }

    /// Projects from the cloud (made on the other Mac or the iPhone, or edited there): new ones are
    /// added at the end, known ones take the newer edit. Never one deleted on this Mac.
    func mergeProjects(_ incoming: [Project]) {
        let deleted = Set(UserDefaults.standard.stringArray(forKey: "deletedProjects") ?? [])
        var changed = false
        for p in incoming where !deleted.contains(p.id) {
            if let i = projects.firstIndex(where: { $0.id == p.id }) {
                guard let theirs = p.updatedAt, theirs > (projects[i].updatedAt ?? .distantPast).addingTimeInterval(0.5) else { continue }
                projects[i].name = p.name
                projects[i].color = p.color
                projects[i].note = p.note
                projects[i].updatedAt = theirs
            } else {
                projects.append(p)
            }
            changed = true
        }
        if changed { try? storage.saveProjects(projects) }
    }

    // MARK: Tasks

    func addTask(_ text: String = "", status: TaskStatus = .todo, project: Project? = nil, callID: String? = nil) -> TaskItem {
        let task = TaskItem(text: text, status: status, callID: callID, projectID: project?.id)
        tasks.insert(task, at: 0)
        if text.isEmpty { newTaskID = task.id }
        saveTasks()
        return task
    }

    func setStatus(_ id: UUID, _ status: TaskStatus) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].status = status
        tasks[i].updatedAt = Date()
        tasks[i].doneAt = status == .done ? Date() : nil
        if status != .blocked { tasks[i].blockedReason = nil }
        saveTasks()
    }

    func setDue(_ id: UUID, _ due: Date?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].due = due
        tasks[i].updatedAt = Date()
        saveTasks()
    }

    func updateTask(_ task: TaskItem) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i] = task
        tasks[i].updatedAt = Date()
        saveTasks()
    }

    func deleteTask(_ id: UUID) {
        if let task = tasks.first(where: { $0.id == id }), !task.text.isEmpty { CloudSync.shared.taskDeleted(task) }
        tasks.removeAll { $0.id == id }
        saveTasks()
    }

    func saveTasks() {
        try? storage.saveTasks(tasks)
        CloudSync.shared.tasksChanged()
    }

    /// After a pull: saved without pushing the same changes straight back.
    func saveTasksQuietly() { try? storage.saveTasks(tasks) }
}

enum Sounds {
    static func started() { NSSound(named: "Tink")?.play() }
    static func stopped() { NSSound(named: "Pop")?.play() }
}
