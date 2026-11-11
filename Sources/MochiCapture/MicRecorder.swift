// Records the microphone the call app reads, read only, as its own track.
//
// It opens an IO proc straight on the input device: no AUHAL, no voice processing, no default
// device change, no aggregate. Core Audio lets any number of processes read one input device, so
// the call app keeps its own stream on the same AirPods exactly as before.
//
// Which device: the one the call app (matched by bundle prefix) captures from now, read with
// kAudioProcessPropertyDevices. Before the call app opens a mic, the system default input. When
// the call app switches device, or the device disappears (AirPods taken out), the recorder
// follows it and writes the gap as silence, so the file stays as long as the call and in step
// with them.wav.

import AVFoundation
import CoreAudio
import Foundation

final class MicRecorder {
    static let fileRate = 48_000.0
    private let out: URL
    private let sidecar: URL
    private let queue = DispatchQueue(label: "mochi.mic.io", qos: .userInitiated)

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var deviceName = ""

    // Touched on `queue` only.
    private var file: AVAudioFile?
    private var target: AVAudioFormat?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var framesWritten: AVAudioFramePosition = 0
    private var firstHostNanos: UInt64 = 0
    private var lastIO: (nanos: UInt64, frames: AVAudioFrameCount, rate: Double)?
    private var stoppedAt: UInt64 = 0
    private var rates = RateTracker()
    private var levelSumSq: Double = 0
    private var levelCount = 0
    private var peak: Float = 0
    private(set) var gaps: [(at: Double, seconds: Double, why: String)] = []
    private var paused = false
    /// 48 kHz mono samples as written, with the file time of the first one. Called on the IO queue.
    var onSamples: (([Float], Double) -> Void)?
    /// Wall clock of the first sample (seconds since 1970), 0 before it.
    private(set) var firstWall: Double = 0
    private var lastBuffer: Date?

    init(out: URL) {
        self.out = out
        sidecar = out.deletingPathExtension().appendingPathExtension("start.json")
    }

    var running: Bool { procID != nil }

    /// Start on `id`, or move to it. A no-op when already on it.
    func use(_ id: AudioObjectID) throws {
        guard id != deviceID || procID == nil else { return }
        stopDevice(why: "switching to \(readString(id, kAudioObjectPropertyName) ?? "?")")
        var asbd = AudioStreamBasicDescription()
        var addr = address(kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &asbd), "input stream format")
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CAError(what: "input format", status: -1) }
        deviceID = id
        deviceName = readString(id, kAudioObjectPropertyName) ?? "?"
        queue.sync {
            if file == nil {
                target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MicRecorder.fileRate,
                                       channels: 1, interleaved: false)
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: MicRecorder.fileRate,
                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                               AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
                file = try? AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            rates.reset()
            setInput(format)
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, id, queue) { [weak self] _, input, inputTime, _, _ in
            self?.handle(input, inputTime)
        }, "AudioDeviceCreateIOProcIDWithBlock (mic)")
        do {
            try check(AudioDeviceStart(id, procID), "AudioDeviceStart (mic)")
        } catch {
            if let procID { AudioDeviceDestroyIOProcID(id, procID) }
            procID = nil
            throw error
        }
        log("mic: recording \(deviceName) at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    private func stopDevice(why: String) {
        guard let procID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
        queue.sync { stoppedAt = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) }
        log("mic: stopped \(deviceName) (\(why))")
    }

    /// On `queue`.
    private func setInput(_ format: AVAudioFormat) {
        if let current = inputFormat, current == format { return }
        inputFormat = format
        converter = target.flatMap { AVAudioConverter(from: format, to: $0) }
        converter?.downmix = true
    }

    private func handle(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        guard let file, var format = inputFormat,
              var buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0 else { return }
        let valid = time.pointee.mFlags.contains(.hostTimeValid)
        let nanos = valid ? AudioConvertHostTimeToNanos(time.pointee.mHostTime) : AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        if firstHostNanos == 0 {
            firstHostNanos = nanos
            // Wall clock of the first sample, from its host time (not from when the callback ran).
            let nowNanos = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
            let wall = Date().timeIntervalSince1970 - Double(nowNanos - nanos) / 1e9
            firstWall = wall
            let info: [String: Any] = ["first_sample_wall": wall, "first_sample_host_ns": nanos, "device": deviceName]
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) { try? data.write(to: sidecar) }
        }
        // Device switched or paused: the missing time is silence.
        if stoppedAt > 0, let last = lastIO, nanos > last.nanos {
            fillSilence(Double(nanos - last.nanos) / 1e9 - Double(last.frames) / last.rate, why: "while the mic switched device")
            stoppedAt = 0
        } else if let last = lastIO, nanos > last.nanos {
            let pause = Double(nanos - last.nanos) / 1e9 - Double(last.frames) / last.rate
            if pause > 0.03 { fillSilence(pause, why: "while the device paused") }
        }
        if let rate = rates.observe(nanos: nanos, frames: buffer.frameLength, current: format.sampleRate),
           let next = AVAudioFormat(commonFormat: format.commonFormat, sampleRate: rate,
                                    channels: format.channelCount, interleaved: format.isInterleaved),
           let rewrapped = AVAudioPCMBuffer(pcmFormat: next, bufferListNoCopy: input, deallocator: nil) {
            log("mic: buffers now arrive at \(Int(rate)) Hz")
            setInput(next)
            format = next
            buffer = rewrapped
        }
        lastIO = (nanos, buffer.frameLength, format.sampleRate)
        if let data = buffer.floatChannelData {
            let n = Int(buffer.frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1)
            for i in 0..<n {
                let v = abs(data[0][i])
                peak = max(peak, v)
                levelSumSq += Double(v * v)
            }
            levelCount += n
        }
        lastBuffer = Date()
        if paused { return }
        guard let converter, let target else { return }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * target.sampleRate / format.sampleRate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if output.frameLength > 0 {
            try? file.write(from: output)
            if let onSamples, let data = output.floatChannelData {
                onSamples(Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength))),
                          Double(framesWritten) / MicRecorder.fileRate)
            }
            framesWritten += AVAudioFramePosition(output.frameLength)
        }
    }

    /// On `queue`.
    private func fillSilence(_ seconds: Double, why: String) {
        guard seconds > 0, let file, let target, framesWritten > 0 else { return }
        let frames = AVAudioFrameCount(seconds * MicRecorder.fileRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else { return }
        silence.frameLength = frames
        try? file.write(from: silence)
        let at = Double(framesWritten) / MicRecorder.fileRate
        framesWritten += AVAudioFramePosition(frames)
        gaps.append((at, seconds, why))
        log(String(format: "mic: filled %.2f s with silence at %.1f s %@", seconds, at, why))
    }

    func startWall() -> Double { queue.sync { firstWall } }
    func setOnSamples(_ f: (([Float], Double) -> Void)?) { queue.sync { onSamples = f } }

    func progress() -> (seconds: Double, lastBuffer: Date?) {
        queue.sync { (Double(framesWritten) / MicRecorder.fileRate, lastBuffer) }
    }

    func setPaused(_ value: Bool) { queue.sync { paused = value } }

    func takeLevel() -> Double? {
        queue.sync {
            defer { levelSumSq = 0; levelCount = 0 }
            guard levelCount > 0 else { return nil }
            return dbfs(Float((levelSumSq / Double(levelCount)).squareRoot()))
        }
    }

    func finish() -> (seconds: Double, peak: Float, gaps: Int) {
        stopDevice(why: "finished")
        return queue.sync {
            file = nil
            return (Double(framesWritten) / MicRecorder.fileRate, peak, gaps.count)
        }
    }
}

/// The input device the call app reads now (first matching capturing process), else the system
/// default input. Read only.
func callInputDevice(bundle: String?) -> (id: AudioObjectID, why: String)? {
    let system = AudioObjectID(kAudioObjectSystemObject)
    if let bundle, let list = try? readArray(system, kAudioHardwarePropertyProcessObjectList) {
        for process in list {
            let bundleID = readString(process, kAudioProcessPropertyBundleID) ?? ""
            guard bundleID.hasPrefix(bundle),
                  (try? readValue(process, kAudioProcessPropertyIsRunningInput, UInt32(0))) ?? 0 != 0 else { continue }
            var addr = address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(process, &addr, 0, nil, &size) == noErr, size > 0 else { continue }
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &ids) == noErr else { continue }
            // Skip aggregates (our own private tap device, or a call app's) and devices with no input.
            if let id = ids.first(where: { channelCount($0, kAudioObjectPropertyScopeInput) > 0
                && (try? readValue($0, kAudioDevicePropertyTransportType, UInt32(0))) != kAudioDeviceTransportTypeAggregate }) {
                return (id, "the device \(bundleID) reads")
            }
        }
    }
    if let id = try? readValue(system, kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(0)), id != 0 {
        return (id, "the system default input (the call app has no mic open yet)")
    }
    return nil
}
