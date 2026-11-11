import Foundation
import MochiKit


/// Live captions: cuts per-speaker 48 kHz audio into utterances on silence and transcribes them serially.
public final class LiveTranscriber: @unchecked Sendable {
    private struct Job { let samples: [Float]; let speaker: Speaker; let start: Double }

    private final class Track {
        var carry: [Float] = []          // samples not yet forming a full frame
        var carryTime = 0.0              // time of carry[0]
        var utterance: [Float] = []      // 16 kHz
        var utteranceStart = 0.0
        var inUtterance = false
        var voiced = 0.0                 // voiced seconds in the current utterance
        var silentRun = 0.0
        var floor = 0.002
        var preroll: [[Float]] = []      // recent silent frames (16 kHz)
    }

    private static let frame = 960                 // 20 ms at 48 kHz
    private static let frameSeconds = 0.02
    private static let silenceCut = 0.6
    private static let maxUtterance = 12.0
    private static let minVoiced = 0.3
    private static let prerollFrames = 8

    private let lock = NSLock()
    private var tracks: [Speaker: Track] = [:]
    private let continuation: AsyncStream<Job>.Continuation
    private let worker: Task<Void, Never>

    public init(onSegment: @escaping @Sendable (Segment) -> Void) {
        let (stream, cont) = AsyncStream<Job>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        worker = Task.detached(priority: .utility) {
            for await job in stream {
                do {
                    let segs = try await Transcriber.shared.transcribe(samples: job.samples, speaker: job.speaker, offset: job.start)
                    for s in segs { onSegment(s) }
                } catch {
                    // A failed utterance is skipped; the final pass over the files is the source of truth.
                }
            }
        }
    }

    /// `time`: seconds since recording start of the first sample in `samples`.
    public func append(_ samples: [Float], speaker: MochiKit.Speaker, time: Double) {
        lock.lock()
        defer { lock.unlock() }
        let t = tracks[speaker] ?? { let n = Track(); tracks[speaker] = n; return n }()
        if t.carry.isEmpty { t.carryTime = time }
        t.carry.append(contentsOf: samples)
        var offset = 0
        while t.carry.count - offset >= Self.frame {
            let frameStart = t.carryTime + Double(offset) / 48_000
            process(Array(t.carry[offset..<offset + Self.frame]), track: t, speaker: speaker, time: frameStart)
            offset += Self.frame
        }
        if offset > 0 {
            t.carry.removeFirst(offset)
            t.carryTime += Double(offset) / 48_000
        }
    }

    /// Flushes pending audio and waits until every queued utterance is transcribed.
    public func finish() async {
        flushAll()
        continuation.finish()
        await worker.value
    }

    private func flushAll() {
        lock.lock()
        defer { lock.unlock() }
        for (speaker, t) in tracks { cut(t, speaker: speaker, trimSilence: true) }
    }

    // MARK: VAD (call with lock held)

    private func process(_ frame48: [Float], track t: Track, speaker: Speaker, time: Double) {
        var sum: Float = 0
        for s in frame48 { sum += s * s }
        let rms = Double((sum / Float(frame48.count)).squareRoot())
        // Min-tracking noise floor: drops fast, rises slowly.
        if rms < t.floor { t.floor = max(rms, 1e-4) } else { t.floor += (rms - t.floor) * 0.002 }
        let voiced = rms > max(t.floor * 3, 0.0008)
        let frame16 = Self.downsample(frame48)

        if !t.inUtterance {
            if voiced {
                t.inUtterance = true
                t.utterance = t.preroll.flatMap { $0 }
                t.utteranceStart = max(0, time - Double(t.preroll.count) * Self.frameSeconds)
                t.preroll.removeAll()
                t.voiced = 0
                t.silentRun = 0
            } else {
                t.preroll.append(frame16)
                if t.preroll.count > Self.prerollFrames { t.preroll.removeFirst() }
                return
            }
        }
        t.utterance.append(contentsOf: frame16)
        if voiced { t.voiced += Self.frameSeconds; t.silentRun = 0 } else { t.silentRun += Self.frameSeconds }
        let length = Double(t.utterance.count) / 16_000
        if t.silentRun >= Self.silenceCut { cut(t, speaker: speaker, trimSilence: true) }
        else if length >= Self.maxUtterance { cut(t, speaker: speaker, trimSilence: false) }
    }

    private func cut(_ t: Track, speaker: Speaker, trimSilence: Bool) {
        defer {
            t.utterance = []
            t.inUtterance = false
            t.voiced = 0
            t.silentRun = 0
        }
        guard t.inUtterance, t.voiced >= Self.minVoiced else { return }
        var samples = t.utterance
        if trimSilence {
            let keep = Int(max(0, t.silentRun - 0.15) * 16_000)
            samples.removeLast(min(keep, samples.count))
        }
        continuation.yield(Job(samples: samples, speaker: speaker, start: t.utteranceStart))
    }

    /// 48 kHz to 16 kHz: mean of three samples (box low-pass, adequate for speech).
    private static func downsample(_ x: [Float]) -> [Float] {
        let n = x.count / 3
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = (x[3 * i] + x[3 * i + 1] + x[3 * i + 2]) / 3 }
        return out
    }
}
