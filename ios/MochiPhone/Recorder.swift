import AVFoundation
import Foundation
import MochiKit
import MochiTranscribe
import Observation

/// Records an in-person meeting with the iPhone's mic to AAC (.m4a), keeps going with the screen
/// locked (background audio), then transcribes it on the phone and saves it as a call that syncs.
/// One mic cannot tell speakers apart, so the transcript shows everyone as "Room".
@Observable
@MainActor
final class Recorder {
    static let shared = Recorder()

    enum State: Equatable { case idle, recording, paused, saving }
    private(set) var state: State = .idle
    private(set) var elapsed: Double = 0
    /// Recent input levels 0...1, newest last, for the waveform.
    private(set) var levels: [Double] = Array(repeating: 0, count: 40)
    private(set) var error: String?
    /// The title for the next recording (from an Upcoming meeting), else "Meeting, 15:10".
    var nextTitle: String?
    private(set) var title = ""
    /// The recording file's size so far, "42 MB": proof that audio reaches the disk.
    private(set) var savedBytes = "0 KB"
    private var fileURL: URL?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var call: Call?

    func start(title: String) async {
        error = nil
        let session = AVAudioSession.sharedInstance()
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                error = "Mochi needs the microphone. Turn it on in Settings, Privacy, Microphone."
                return
            }
            try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true)
            let now = Date()
            var call = Call(id: Call.newID(at: now), title: title, startedAt: now, appName: "In person", status: .recording)
            call.themName = "Room"
            call.device = PhoneModel.deviceName
            let folder = PhoneModel.shared.storage.folder(for: call.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("them.m4a")
            fileURL = url
            self.title = title
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { throw NSError(domain: "Mochi", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recording could not start."]) }
            recorder = r
            self.call = call
            try? PhoneModel.shared.storage.save(call)
            state = .recording
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated { Recorder.shared.tick() }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func tick() {
        guard let r = recorder else { return }
        elapsed = r.currentTime
        r.updateMeters()
        let db = Double(r.averagePower(forChannel: 0))
        let level = state == .paused ? 0.03 : max(0.03, min(1, (db + 55) / 45))
        levels.removeFirst()
        levels.append(level)
        if let url = fileURL, Int(elapsed * 10) % 20 == 0,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            savedBytes = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
    }

    func togglePause() {
        guard let r = recorder else { return }
        if state == .recording { r.pause(); state = .paused } else if state == .paused { r.record(); state = .recording }
    }

    /// Stops, saves the call at once, and transcribes it on the phone behind the scenes.
    @discardableResult
    func stop() -> String? {
        guard let r = recorder, var call else { return nil }
        let seconds = r.currentTime
        r.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        call.duration = seconds
        call.status = .ready
        self.call = nil
        let model = PhoneModel.shared
        model.save(call)
        let id = call.id
        model.transcribe(id)
        return id
    }
}
