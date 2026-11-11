import AVFoundation
import CoreAudio
import Foundation

/// Call apps Mochi knows, by the bundle id prefix of the process that plays and captures audio.
public struct CallApp: Hashable, Sendable {
    public let name: String
    /// Matches by prefix: Chrome plays and captures through com.google.Chrome.helper.
    public let bundlePrefix: String

    public init(name: String, bundlePrefix: String) {
        self.name = name
        self.bundlePrefix = bundlePrefix
    }

    /// Plus `MOCHI_EXTRA_CALL_APP` (a bundle id prefix) for tests with a media player as the call.
    public static var known: [CallApp] {
        base + (ProcessInfo.processInfo.environment["MOCHI_EXTRA_CALL_APP"].map { [CallApp(name: "Test app", bundlePrefix: $0)] } ?? [])
    }

    static let base: [CallApp] = [
        CallApp(name: "Google Chrome", bundlePrefix: "com.google.Chrome"),
        CallApp(name: "Zoom", bundlePrefix: "us.zoom.xos"),
        CallApp(name: "FaceTime", bundlePrefix: "com.apple.avconferenced"),
        CallApp(name: "FaceTime", bundlePrefix: "com.apple.FaceTime"),
        CallApp(name: "WhatsApp", bundlePrefix: "net.whatsapp.WhatsApp"),
        CallApp(name: "Microsoft Teams", bundlePrefix: "com.microsoft.teams"),
        CallApp(name: "Safari", bundlePrefix: "com.apple.WebKit.GPU"),
        CallApp(name: "Arc", bundlePrefix: "company.thebrowser"),
        CallApp(name: "Microsoft Edge", bundlePrefix: "com.microsoft.edgemac"),
        CallApp(name: "Brave", bundlePrefix: "com.brave.Browser"),
        CallApp(name: "Slack", bundlePrefix: "com.tinyspeck.slackmacgap"),
        CallApp(name: "Discord", bundlePrefix: "com.hnc.Discord"),
    ]

    /// The known call app whose process holds an audio input open now, if any. Read only.
    public static func capturingNow(excluding pid: pid_t = ProcessInfo.processInfo.processIdentifier) -> CallApp? {
        guard let list = try? readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        else { return nil }
        for process in list {
            guard (try? readValue(process, kAudioProcessPropertyPID, pid_t(-1))) != pid,
                  (try? readValue(process, kAudioProcessPropertyIsRunningInput, UInt32(0))) ?? 0 != 0,
                  let bundle = readString(process, kAudioProcessPropertyBundleID),
                  let app = known.first(where: { bundle.hasPrefix($0.bundlePrefix) }) else { continue }
            return app
        }
        return nil
    }

    /// Whether any process of this app plays or captures audio now (the call end check). Read only.
    public func usesAudioNow() -> Bool? {
        guard let list = try? readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        else { return nil }
        for process in list {
            guard let bundle = readString(process, kAudioProcessPropertyBundleID), bundle.hasPrefix(bundlePrefix) else { continue }
            let input = (try? readValue(process, kAudioProcessPropertyIsRunningInput, UInt32(0))) ?? 0
            let output = (try? readValue(process, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0
            if input != 0 || output != 0 { return true }
        }
        return false
    }
}

/// How one side of the recording is doing, for the pill and the live view.
public struct SideHealth: Sendable, Equatable {
    /// RMS level since the last snapshot in dBFS, nil when no buffers arrived.
    public var level: Double?
    /// Seconds of audio written to disk so far.
    public var secondsWritten: Double
    /// Seconds since the last buffer arrived from Core Audio, nil before the first one.
    public var sinceLastBuffer: Double?
    /// The device (mic) or app (them) this side records.
    public var source: String?
}

public struct CaptureSnapshot: Sendable, Equatable {
    public var mic: SideHealth
    public var them: SideHealth
    /// The call app the tap follows, nil while none was found yet.
    public var callApp: CallApp?
}

/// Records one call as two tracks in `folder`: mic.wav (the device the call app reads, read only)
/// and them.wav (a Core Audio process tap on the call app only). Never changes a default device,
/// never opens an output, never uses a virtual driver.
public enum CaptureSide: Sendable { case mic, them }

public final class CallRecorder {
    /// Live samples for captions: 48 kHz mono, side, and seconds since the mic track started
    /// (the call's timeline). Called on audio IO queues; must not block.
    public var onSamples: ((CaptureSide, [Float], Double) -> Void)?
    private let offsetLock = NSLock()
    private var themOffset: Double?
    public let folder: URL
    private(set) public var callApp: CallApp?
    private let mic: MicRecorder
    private let them: TapRecorder
    private var scanner: Scanner?
    private var timers: [DispatchSourceTimer] = []
    private var listener: AudioObjectPropertyListenerBlock?

    /// `app` nil: follow the first known call app that captures audio during the recording.
    public init(folder: URL, app: CallApp?) {
        self.folder = folder
        callApp = app
        mic = MicRecorder(out: folder.appendingPathComponent("mic.wav"))
        them = TapRecorder(out: folder.appendingPathComponent("them.wav"))
    }

    /// Main thread.
    public func start() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        mic.setOnSamples { [weak self] samples, time in self?.onSamples?(.mic, samples, time) }
        them.setOnSamples { [weak self] samples, time in
            guard let self else { return }
            self.onSamples?(.them, samples, time + self.offset())
        }
        followMic()
        guard mic.running else { throw CAError(what: "open the microphone", status: -1) }
        attachIfNeeded()
        var listAddr = address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scanner?.scan() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddr, .main, block)
        listener = block
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.attachIfNeeded()
            self.scanner?.scan()
            self.followMic()
        }
        t.resume()
        timers.append(t)
    }

    private func attachIfNeeded() {
        if callApp == nil { callApp = CallApp.capturingNow() }
        guard scanner == nil, let app = callApp else { return }
        var options = RecordOptions(out: folder.appendingPathComponent("them.wav").path)
        options.bundle = app.bundlePrefix
        options.wait = true
        let s = Scanner(options: options, recorder: them)
        scanner = s
        log("tap: following \(app.name) (\(app.bundlePrefix)*)")
        s.scan()
    }

    private func followMic() {
        guard let pick = callInputDevice(bundle: callApp?.bundlePrefix) else { return }
        let alive = (try? readValue(pick.id, kAudioDevicePropertyDeviceIsAlive, UInt32(0))) ?? 0
        guard alive != 0 else { return }
        if !mic.running || readString(pick.id, kAudioObjectPropertyName) != mic.deviceName {
            log("mic: using \(readString(pick.id, kAudioObjectPropertyName) ?? "?"), \(pick.why)")
            do { try mic.use(pick.id) } catch { log("mic: could not open: \(error)") }
        }
    }

    /// Seconds between the mic track's first sample and the call track's first sample.
    private func offset() -> Double {
        offsetLock.lock(); defer { offsetLock.unlock() }
        if let themOffset { return themOffset }
        let m = mic.startWall(), t = them.startWall()
        guard m > 0, t > 0 else { return 0 }
        themOffset = max(0, t - m)
        return themOffset!
    }

    /// Where the call track starts on the mic track's timeline, for merging transcripts.
    public var callTrackOffset: Double { offset() }

    public func setPaused(_ paused: Bool) {
        mic.setPaused(paused)
        them.setPaused(paused)
    }

    /// Main thread, 4 times a second is plenty.
    public func snapshot() -> CaptureSnapshot {
        let now = Date()
        let m = mic.progress()
        let t = them.progress()
        return CaptureSnapshot(
            mic: SideHealth(level: mic.takeLevel(), secondsWritten: m.seconds,
                            sinceLastBuffer: m.lastBuffer.map { now.timeIntervalSince($0) },
                            source: mic.running ? mic.deviceName : nil),
            them: SideHealth(level: them.takeLevel().rms, secondsWritten: t.seconds,
                             sinceLastBuffer: t.lastBuffer.map { now.timeIntervalSince($0) },
                             source: callApp?.name),
            callApp: callApp)
    }

    public struct Result: Sendable {
        public var micSeconds: Double
        public var themSeconds: Double
        public var micPeak: Float
        public var themPeak: Float
    }

    /// Main thread. Finalises both WAV files.
    public func stop() -> Result {
        timers.forEach { $0.cancel() }
        timers = []
        if let listener {
            var listAddr = address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddr, .main, listener)
        }
        listener = nil
        let t = them.finish()
        let m = mic.finish()
        return Result(micSeconds: m.seconds, themSeconds: t.seconds, micPeak: m.peak, themPeak: t.peak)
    }
}

public enum CapturePermissions {
    /// Microphone permission, via AVFoundation.
    public static var microphone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
