import Foundation
import MochiCapture
import MochiKit
import Observation

/// How sure Mochi is that the call is being recorded, for the pill, the live view and the menu bar.
enum RecordingHealth: Equatable {
    /// The first second: devices opening.
    case starting
    /// Both sides (or the mic before a call app appears) arrive and reach the disk.
    case healthy
    /// Something worth a look, recording continues. Amber.
    case attention(String)
    /// Audio stopped reaching the disk. Red, with a fix.
    case broken(String)
}

/// One recording in progress: the two-track capture, the timer, live captions, health, and the
/// call end rule (the call app stops using audio for 3 checks, then 60 s, never the calendar).
@Observable
@MainActor
final class RecordingSession {
    /// Kept in step with the stored call (a rename or calendar retitle while recording).
    var call: Call
    private(set) var elapsed: Double = 0
    private(set) var paused = false
    private(set) var health: RecordingHealth = .starting
    private(set) var snapshot: CaptureSnapshot?
    private(set) var segments: [Segment] = []
    /// Recent levels for the waveform (0...1), newest last, both sides combined.
    private(set) var wave: [Double] = Array(repeating: 0, count: 28)
    private(set) var micLevel: Double = 0
    private(set) var themLevel: Double = 0
    /// Seconds of audio safely on disk (the shorter of the two tracks once both run).
    private(set) var savedSeconds: Double = 0
    /// The call app stopped using audio: counting down to stop.
    private(set) var endedCountdown: Int?

    private let recorder: CallRecorder
    private let live: LiveCaptions
    private var timer: Timer?
    private var startedAt = Date()
    private var accumulated: Double = 0
    private var quietChecks = 0
    private var suppressEndedUntil: Date?
    private var micSilentSince: Date?
    private var themSilentSince: Date?
    private var noCallAppSince = Date()
    private var tick = 0
    private var lastSaved: Double = 0
    private var lastGrowth = Date()
    var onEnded: (() -> Void)?
    var onCallEndedPrompt: (() -> Void)?

    init(call: Call, folder: URL, app: CallApp?) {
        self.call = call
        recorder = CallRecorder(folder: folder, app: app)
        live = LiveCaptions()
        live.onSegment = { [weak self] segment in
            Task { @MainActor in self?.segments.append(segment) }
        }
        recorder.onSamples = { [live] side, samples, time in
            live.append(samples, speaker: side == .mic ? .me : .them, time: time)
        }
    }

    func start() throws {
        try FileManager.default.createDirectory(at: recorder.folder, withIntermediateDirectories: true)
        let logURL = recorder.folder.appendingPathComponent("capture.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        CaptureLog.handler = { line in handle?.write((line + "\n").data(using: .utf8)!) }
        try recorder.start()
        startedAt = Date()
        lastGrowth = Date()
        noCallAppSince = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    var callApp: CallApp? { snapshot?.callApp ?? recorder.callApp }
    var callTrackOffset: Double { recorder.callTrackOffset }

    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        if value { accumulated += Date().timeIntervalSince(startedAt) } else { startedAt = Date(); lastGrowth = Date() }
        paused = value
        recorder.setPaused(value)
    }

    func keepRecording() {
        endedCountdown = nil
        quietChecks = 0
        suppressEndedUntil = Date().addingTimeInterval(600)
    }

    /// Stops capture and live captions. Returns the result; the caller saves the call.
    /// The live lines and the recorded length right now, for the instant after Stop.
    var snapshotAtStop: (segments: [Segment], seconds: Double) { (segments, savedSeconds) }

    /// Closes the devices off the main thread (destroying a tap's aggregate device can take a
    /// second, which made Stop feel stuck), then waits for the last live lines.
    func stop() async -> (CallRecorder.Result, [Segment]) {
        timer?.invalidate()
        timer = nil
        let recorder = self.recorder
        let result = await withCheckedContinuation { (done: CheckedContinuation<CallRecorder.Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: recorder.stop()) }
        }
        await live.finish()
        return (result, segments)
    }

    private static func normalised(_ db: Double?) -> Double {
        guard let db else { return 0 }
        return max(0, min(1, (db + 60) / 45))
    }

    private func update() {
        tick += 1
        if !paused { elapsed = accumulated + Date().timeIntervalSince(startedAt) }
        let snap = recorder.snapshot()
        snapshot = snap
        micLevel = Self.normalised(snap.mic.level)
        themLevel = Self.normalised(snap.them.level)
        wave.removeFirst()
        wave.append(paused ? 0.04 : max(micLevel, themLevel, 0.04))
        let both = snap.them.secondsWritten > 0 ? min(snap.mic.secondsWritten, snap.them.secondsWritten + callTrackOffset)
                                                 : snap.mic.secondsWritten
        savedSeconds = max(savedSeconds, both)
        health = evaluate(snap)
        if tick % 8 == 0 { checkCallEnd(snap) }   // every 2 s
    }

    /// The rules from the design (SPEC section 15): a real mic never delivers digital zeros, so 5 s
    /// of them is a fault; the call side gets 45 s because muted rooms and listening are common;
    /// audio that stops reaching the disk for 5 s is a failure.
    private func evaluate(_ snap: CaptureSnapshot) -> RecordingHealth {
        let now = Date()
        if savedSeconds > lastSaved + 0.01 { lastSaved = savedSeconds; lastGrowth = now }
        if snap.mic.sinceLastBuffer == nil || (elapsed < 2 && savedSeconds == 0) {
            return elapsed > 4 ? .broken("Mochi cannot open your mic") : .starting
        }
        if !paused, now.timeIntervalSince(lastGrowth) > 5 { return .broken("Audio stopped reaching the disk") }
        if let micAge = snap.mic.sinceLastBuffer, micAge > 5 { return .broken("Your mic stopped reaching Mochi") }
        if paused { return .healthy }
        let micZero = (snap.mic.level ?? -100) <= -99
        let themZero = (snap.them.level ?? -100) <= -99
        if micZero { micSilentSince = micSilentSince ?? now } else { micSilentSince = nil }
        if themZero { themSilentSince = themSilentSince ?? now } else { themSilentSince = nil }
        if let since = micSilentSince, now.timeIntervalSince(since) > 5 { return .attention("Your mic is silent") }
        guard let app = snap.callApp else {
            return now.timeIntervalSince(noCallAppSince) > 20 ? .attention("No call app yet, recording your mic") : .healthy
        }
        if snap.them.sinceLastBuffer == nil, now.timeIntervalSince(noCallAppSince) > 15 { return .attention("Not hearing the call") }
        if let since = themSilentSince, now.timeIntervalSince(since) > 45, app.usesAudioNow() == true {
            return .attention("Not hearing the call")
        }
        return .healthy
    }

    private func checkCallEnd(_ snap: CaptureSnapshot) {
        guard !paused, let app = snap.callApp else { return }
        if let until = suppressEndedUntil, until > Date() { return }
        if let countdown = endedCountdown {
            if app.usesAudioNow() == true {
                endedCountdown = nil   // a new audio session from the same app cancels silently
                quietChecks = 0
                return
            }
            let next = countdown - 2
            if next <= 0 { endedCountdown = nil; onEnded?() } else { endedCountdown = next }
            return
        }
        if app.usesAudioNow() == false { quietChecks += 1 } else { quietChecks = 0 }
        if quietChecks >= 3 {
            endedCountdown = 60
            onCallEndedPrompt?()
        }
    }
}
