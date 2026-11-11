import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// The tap and the private aggregate device that runs it.
struct TapDevice {
    var tapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var procID: AudioDeviceIOProcID?
    var description: CATapDescription
    var format: AVAudioFormat
    /// Follows the aggregate's rate; removed before the aggregate goes, so a late notice from a
    /// destroyed device cannot reset the input format of the one that replaced it.
    var rateListener: (block: AudioObjectPropertyListenerBlock, queue: DispatchQueue)?

    func destroy() {
        if aggregateID != kAudioObjectUnknown {
            if let rateListener {
                var addr = address(kAudioDevicePropertyNominalSampleRate)
                AudioObjectRemovePropertyListenerBlock(aggregateID, &addr, rateListener.queue, rateListener.block)
            }
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }
}

/// Records the tapped processes into one WAV. The set of processes can change while it records:
/// first by updating the tap in place, else by rebuilding the tap and filling the gap with silence.
final class TapRecorder {
    private var device: TapDevice?
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    /// The file is always FILE_RATE. The tap's buffers come at the aggregate device's clock, which is
    /// the default output's rate: a headset in call mode runs at 24 or 16 kHz, not the 48 kHz the
    /// tap's own format says (until 22 Oct 2026 every them.wav held 24 kHz audio under a 48 kHz header).
    static let fileRate = 48_000.0
    // Touched on `queue` only: the format the IO buffers really come in, and the converter to the file.
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let out: URL
    private let startMarker: URL
    private let queue = DispatchQueue(label: "mochi.tap.io", qos: .userInitiated)
    private(set) var tapped: [AudioProcess] = []

    // Touched on `queue` only.
    private var framesWritten: AVAudioFramePosition = 0
    private var peak: Float = 0
    private var levelSumSq: Double = 0
    private var levelCount = 0
    private var levelPeak: Float = 0
    private var lastBuffer: Date?
    private var fillGap = false
    private var markedStart = false
    /// While paused, buffers are dropped (both tracks pause together, so they stay in step).
    var paused = false
    /// 48 kHz mono mixdown as written, with the file time of the first sample. Called on the IO queue.
    var onSamples: (([Float], Double) -> Void)?
    private var firstWall: Double = 0
    private var rates = RateTracker()
    /// The last IO buffer: host time (ns), frames and rate, to see the device pause.
    private var lastIO: (nanos: UInt64, frames: AVAudioFrameCount, rate: Double)?
    /// The tap's own format (its rate is not what the buffers come at), for rate switches.
    private var tapFormat: AVAudioFormat?

    init(out: URL) {
        self.out = out
        startMarker = out.deletingPathExtension().appendingPathExtension("start")
    }

    var running: Bool { device != nil }

    /// Starts recording these processes, or switches the running tap over to them. Throws when it
    /// could not; `tapped` then says exactly what is still being recorded (possibly nothing).
    func setProcesses(_ processes: [AudioProcess]) throws {
        let ids = processes.map(\.objectID)
        guard let current = device else {
            try start(ids)
            tapped = processes
            return
        }
        let previous = current.description.processes
        current.description.processes = ids
        var ref: CATapDescription = current.description
        var addr = address(kAudioTapPropertyDescription)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectSetPropertyData(current.tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status == noErr {
            tapped = processes
            return
        }
        current.description.processes = previous
        log("updating the tap in place failed (OSStatus \(status)); rebuilding it")
        // Build the new tap before touching the old one: if it cannot be built, or would record in
        // another format, the old one keeps recording what it had.
        let next = try makeDevice(ids)
        guard next.format.channelCount == current.format.channelCount else {
            next.destroy()
            throw CAError(what: "rebuild (the new tap records \(next.format.channelCount) channels, the file "
                          + "\(current.format.channelCount))", status: -1)
        }
        current.destroy()
        device = nil
        tapped = []
        queue.sync { fillGap = true }
        try run(next)   // on failure it destroys `next` and leaves device nil: the next scan starts afresh
        tapped = processes
    }

    private func start(_ ids: [AudioObjectID]) throws {
        let next = try makeDevice(ids)
        if let format = fileFormat, format.channelCount != next.format.channelCount {
            next.destroy()
            throw CAError(what: "restart (the tap now records \(next.format.channelCount) channels, the file "
                          + "\(format.channelCount))", status: -1)
        }
        if fileFormat != nil { queue.sync { fillGap = true } }
        try run(next)
    }

    /// A tap plus its private aggregate device. On any failure it destroys what it made.
    private func makeDevice(_ ids: [AudioObjectID]) throws -> TapDevice {
        let desc = CATapDescription(stereoMixdownOfProcesses: ids)
        desc.uuid = UUID()
        desc.name = "Mochi call tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted   // you still hear the call normally
        if #available(macOS 26.0, *) {
            // A tapped process that exits and starts again (Chrome's audio helper does) comes back
            // into the tap by bundle ID, on top of the re-scan below.
            desc.isProcessRestoreEnabled = true
        }
        var dev = TapDevice(description: desc, format: AVAudioFormat())
        try check(AudioHardwareCreateProcessTap(desc, &dev.tapID), "AudioHardwareCreateProcessTap")
        do {
            var format = try readValue(dev.tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            guard let avFormat = AVAudioFormat(streamDescription: &format) else {
                throw CAError(what: "tap format", status: -1)
            }
            dev.format = avFormat
            let outputDevice = try readValue(AudioObjectID(kAudioObjectSystemObject),
                                             kAudioHardwarePropertyDefaultSystemOutputDevice, AudioObjectID(0))
            guard let outputUID = readString(outputDevice, kAudioDevicePropertyDeviceUID) else {
                throw CAError(what: "default output device UID", status: -1)
            }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Mochi Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                   kAudioSubTapUIDKey: desc.uuid.uuidString]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &dev.aggregateID),
                      "AudioHardwareCreateAggregateDevice")
            dev.format = TapRecorder.atRate(avFormat, aggregateRate(dev.aggregateID))
        } catch {
            dev.destroy()
            throw error
        }
        return dev
    }

    /// Opens the WAV the first time, then starts `dev`. Sets `device` only once it runs; on any
    /// failure `dev` is destroyed and `device` stays nil.
    private func run(_ dev: TapDevice) throws {
        var dev = dev
        let avFormat = dev.format
        do {
            if file == nil {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: TapRecorder.fileRate,
                    AVNumberOfChannelsKey: avFormat.channelCount,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                file = try AVAudioFile(forWriting: out, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: avFormat.isInterleaved)
                fileFormat = file?.processingFormat
                log("recording at \(Int(TapRecorder.fileRate)) Hz, \(avFormat.channelCount) ch -> \(out.path)")
            }
            queue.sync {
                rates.reset()   // a new device: its clock starts afresh
                lastIO = nil    // its gap is filled by `fillGap`
                setInput(avFormat)
            }
            try check(AudioDeviceCreateIOProcIDWithBlock(&dev.procID, dev.aggregateID, queue) { [weak self] _, input, inputTime, _, _ in
                guard let self, let file = self.file, var format = self.inputFormat,
                      var buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
                else { return }
                let valid = inputTime.pointee.mFlags.contains(.hostTimeValid)
                let nanos = valid ? AudioConvertHostTimeToNanos(inputTime.pointee.mHostTime) : 0
                // A headset that changes profile (call mode on or off) stops its IO for 0.2 to 0.7 s:
                // that time is silence in the file, so it stays as long as the call (and in step with
                // the mic file). Measured on AirPods Pro, 22 Oct 2026.
                if valid, let last = self.lastIO, nanos > last.nanos {
                    let pause = Double(nanos - last.nanos) / 1e9 - Double(last.frames) / last.rate
                    if pause > TapRecorder.pauseToFill { self.writeSilence(seconds: pause, to: file, why: "while the device paused") }
                }
                if valid { self.lastIO = (nanos, buffer.frameLength, format.sampleRate) }
                // The rate from the buffers' own timestamps, ahead of the nominal-rate notice.
                if valid,
                   let rate = self.rates.observe(nanos: nanos, frames: buffer.frameLength, current: format.sampleRate),
                   let base = self.tapFormat {
                    self.setInput(TapRecorder.atRate(base, rate))
                    guard let next = self.inputFormat,
                          let rewrapped = AVAudioPCMBuffer(pcmFormat: next, bufferListNoCopy: input, deallocator: nil) else { return }
                    format = next
                    buffer = rewrapped
                    self.lastIO = (nanos, buffer.frameLength, next.sampleRate)
                }
                self.write(buffer, to: file, format: format)
            }, "AudioDeviceCreateIOProcIDWithBlock")
            // The headset can change rate mid-call (it enters call mode after Mochi started): follow it.
            var rateAddr = address(kAudioDevicePropertyNominalSampleRate)
            let aggregateID = dev.aggregateID
            let base = TapRecorder.atRate(avFormat, TapRecorder.fileRate)
            queue.sync { tapFormat = base }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                // Unreadable (the device is going away): keep the format the buffers come in now.
                guard let rate = aggregateRate(aggregateID) else { return }
                self?.setInput(TapRecorder.atRate(base, rate))
            }
            if AudioObjectAddPropertyListenerBlock(aggregateID, &rateAddr, queue, listener) == noErr {
                dev.rateListener = (listener, queue)
            }
            try check(AudioDeviceStart(dev.aggregateID, dev.procID), "AudioDeviceStart")
        } catch {
            dev.destroy()
            device = nil
            tapped = []
            throw error
        }
        device = dev
    }

    /// Longer pauses between IO buffers are written as silence (shorter ones are scheduling jitter).
    static let pauseToFill = 0.03

    /// On `queue`: `seconds` of silence at the file's rate.
    private func writeSilence(seconds: Double, to file: AVAudioFile, why: String) {
        guard let target = fileFormat, framesWritten > 0 else { return }
        let missing = AVAudioFrameCount(seconds * TapRecorder.fileRate)
        guard missing > 0, let silence = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: missing) else { return }
        silence.frameLength = missing   // zero-filled
        try? file.write(from: silence)
        framesWritten += AVAudioFramePosition(missing)
        log(String(format: "filled %.2f s with silence %@", seconds, why))
    }

    /// A copy of the tap's format at the rate the IO buffers really come in.
    static func atRate(_ format: AVAudioFormat, _ rate: Double?) -> AVAudioFormat {
        guard let rate, rate > 0, rate != format.sampleRate,
              let real = AVAudioFormat(commonFormat: format.commonFormat, sampleRate: rate,
                                       channels: format.channelCount, interleaved: format.isInterleaved)
        else { return format }
        return real
    }

    /// On `queue`: the IO buffers now come in `format`; a converter to the file's rate when it differs.
    private func setInput(_ format: AVAudioFormat) {
        if let current = inputFormat, current == format { return }
        inputFormat = format
        converter = nil
        if let target = fileFormat, format.sampleRate != target.sampleRate {
            converter = AVAudioConverter(from: format, to: target)
        }
        log("call audio arrives at \(Int(format.sampleRate)) Hz\(converter != nil ? ", converted to \(Int(TapRecorder.fileRate)) Hz" : "")")
    }

    /// On `queue`. `buffer` in the file's format: converted when the IO rate differs.
    private func toFile(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if let error { FileHandle.standardError.write("convert failed: \(error)\n".data(using: .utf8)!) }
        return output
    }

    /// On `queue`.
    private func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile, format: AVAudioFormat) {
        if paused { lastBuffer = Date(); return }
        let now = Date()
        if fillGap, let last = lastBuffer, let target = fileFormat {
            fillGap = false
            let rate = TapRecorder.fileRate
            let missing = AVAudioFrameCount(max(0, now.timeIntervalSince(last) - Double(buffer.frameLength) / format.sampleRate)
                                            * rate)
            if missing > 0, let silence = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: missing) {
                silence.frameLength = missing   // zero-filled
                try? file.write(from: silence)
                framesWritten += AVAudioFramePosition(missing)
                log(String(format: "filled a %.2f s gap with silence while the tap was rebuilt", Double(missing) / rate))
            }
        }
        lastBuffer = now
        if let data = buffer.floatChannelData {
            let n = Int(buffer.frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1)
            var sumsq: Double = 0
            var top: Float = 0
            for i in 0..<n {
                let v = abs(data[0][i])
                top = max(top, v)
                sumsq += Double(v * v)
            }
            peak = max(peak, top)
            levelPeak = max(levelPeak, top)
            levelSumSq += sumsq
            levelCount += n
        }
        if !markedStart {
            // Wall-clock time of the first sample, so transcripts line up with the mic file. Once:
            // the converter can hold back the first buffer's frames, so framesWritten may stay 0.
            markedStart = true
            firstWall = Date().timeIntervalSince1970 - Double(buffer.frameLength) / format.sampleRate
            try? String(format: "%.3f", Date().timeIntervalSince1970).write(to: startMarker, atomically: true, encoding: .utf8)
        }
        do {
            guard let converted = toFile(buffer) else { return }
            try file.write(from: converted)
            if let onSamples, let data = converted.floatChannelData {
                let n = Int(converted.frameLength)
                let channels = Int(converted.format.channelCount)
                var mono = [Float](repeating: 0, count: n)
                if converted.format.isInterleaved {
                    for i in 0..<n { var sum: Float = 0; for c in 0..<channels { sum += data[0][i * channels + c] }; mono[i] = sum / Float(channels) }
                } else {
                    for c in 0..<channels { for i in 0..<n { mono[i] += data[c][i] / Float(channels) } }
                }
                onSamples(mono, Double(framesWritten) / TapRecorder.fileRate)
            }
            framesWritten += AVAudioFramePosition(converted.frameLength)
        } catch {
            FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
        }
    }

    /// Seconds written to the file and when the last buffer arrived.
    func progress() -> (seconds: Double, lastBuffer: Date?) {
        queue.sync { (Double(framesWritten) / TapRecorder.fileRate, lastBuffer) }
    }

    func setPaused(_ value: Bool) { queue.sync { paused = value } }

    /// Read without the queue: called from the IO queue itself (a sync there would deadlock). A
    /// Double written once before the first callback returns; a stale 0 only delays the offset.
    func startWall() -> Double { firstWall }
    func setOnSamples(_ f: (([Float], Double) -> Void)?) { queue.sync { onSamples = f } }

    /// RMS and peak since the last call, nil when no audio came in.
    func takeLevel() -> (rms: Double?, peak: Double?) {
        queue.sync {
            defer { levelSumSq = 0; levelCount = 0; levelPeak = 0 }
            guard levelCount > 0 else { return (nil, nil) }
            return (dbfs(Float((levelSumSq / Double(levelCount)).squareRoot())), dbfs(levelPeak))
        }
    }

    func finish() -> (seconds: Double, peak: Float) {
        device?.destroy()
        let rate = TapRecorder.fileRate
        device = nil
        return queue.sync {
            file = nil   // closes and finalises the WAV header
            return (Double(framesWritten) / rate, peak)
        }
    }
}

struct RecordOptions {
    init(out: String) { self.out = out }
    var out: String
    var bundle: String?
    var pid: pid_t?
    var name: String?
    var seconds: Double?
    var wait = false
    var verbose = false
    var levels: URL?
    var rescan = 1.0

    func matches(_ p: AudioProcess) -> Bool {
        if let pid, p.pid == pid { return true }
        if let bundle, !bundle.isEmpty, p.bundleID.hasPrefix(bundle) { return true }
        if let name, !name.isEmpty, p.name.lowercased().hasPrefix(name.lowercased()) { return true }
        return false
    }
}

/// Watches the system's audio processes and keeps the recorder on every matching one.
final class Scanner {
    var options: RecordOptions
    let recorder: TapRecorder
    private var seen: [pid_t: AudioProcess] = [:]
    private var retry = RetryPolicy()
    /// A matching process existed at some point (even if tapping it failed).
    private(set) var foundAny = false
    private var loudest: Double?
    private var lastLevelLog = Date()

    init(options: RecordOptions, recorder: TapRecorder) {
        self.options = options
        self.recorder = recorder
    }

    /// On the main queue.
    func scan() {
        guard let all = try? audioProcesses() else { return }
        let found = all.filter(options.matches)
        foundAny = foundAny || !found.isEmpty
        let now = Dictionary(found.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for p in found where seen[p.pid] == nil {
            log("+ found pid \(p.pid) \(p.bundleID) \(p.name)\(p.playing ? " (playing)" : "")")
        }
        for (pid, p) in seen where now[pid] == nil {
            log("- gone  pid \(pid) \(p.bundleID) \(p.name)")
        }
        if options.verbose {
            for p in found {
                if let before = seen[p.pid], before.playing != p.playing {
                    log("  pid \(p.pid) \(p.name) \(p.playing ? "started" : "stopped") playing")
                }
            }
        }
        seen = now

        let wanted = Set(found.map(\.objectID))
        guard !found.isEmpty, wanted != Set(recorder.tapped.map(\.objectID)), retry.shouldTry(wanted) else { return }
        let before = Set(recorder.tapped.map(\.pid))
        do {
            try recorder.setProcesses(found.sorted { $0.pid < $1.pid })
            retry.succeeded()
            for p in recorder.tapped where !before.contains(p.pid) { log("+ tap pid \(p.pid) \(p.bundleID) \(p.name)") }
            log("tapping \(recorder.tapped.count) process(es): \(recorder.tapped.map(\.short).joined(separator: ", "))")
        } catch {
            retry.failed(wanted)
            let still = recorder.tapped.isEmpty ? "nothing is being recorded"
                : "still recording \(recorder.tapped.map(\.short).joined(separator: ", "))"
            log(String(format: "could not tap %@: %@; %@; next try in %.0f s",
                       found.map(\.short).joined(separator: ", "), "\(error)", still,
                       max(0, retry.notBefore.timeIntervalSinceNow)))
        }
    }

    /// On the main queue, 4 times a second.
    func writeLevel() {
        let level = recorder.takeLevel()
        if let rms = level.rms { loudest = max(loudest ?? -100, rms) }
        if options.verbose, Date().timeIntervalSince(lastLevelLog) >= 5 {
            lastLevelLog = Date()
            log(loudest.map { String(format: "level: loudest %.0f dBFS in the last 5 s", $0) }
                ?? (recorder.running ? "level: no audio buffers in the last 5 s" : "level: waiting for a matching process"))
            loudest = nil
        }
        guard let url = options.levels else { return }
        let entry: [String: Any] = [
            "wall": (Date().timeIntervalSince1970 * 1000).rounded() / 1000,
            "rms_db": level.rms ?? NSNull(),
            "peak_db": level.peak ?? NSNull(),
            "processes": recorder.tapped.map(\.short),
            "waiting": !recorder.running,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: entry) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

