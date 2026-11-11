import FluidAudio
import Foundation
import MochiKit

/// Tells the voices on the other side of a call apart, on this Mac: pyannote community-1
/// segmentation, WeSpeaker voiceprints and VBx clustering, through FluidAudio's offline pipeline on
/// the Neural Engine (about 150x real time). The models (about 30 MB) download on first use into
/// FluidAudio's cache.
public actor SpeakerFinder {
    public static let shared = SpeakerFinder()

    /// What one pass found: who speaks when (seconds on the track), and each voice.
    public struct Found: Sendable {
        public var spans: [VoiceSpan]
        public var speakers: [CallSpeaker]
    }

    private var manager: OfflineDiarizerManager?

    public init() {}

    private func loaded() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        var config = OfflineDiarizerConfig.default
        // Whisper may be loaded next to it after a call: keep the peak around 100 MB.
        config.segmentation.batchSize = 8
        let m = OfflineDiarizerManager(config: config)
        try await m.prepareModels()
        manager = m
        return m
    }

    /// The other side's whole track as 16 kHz mono (`Transcriber.samples(of:)`).
    public func find(samples: [Float]) async throws -> Found {
        // Under 2 s there is nothing to tell apart.
        guard samples.count >= 32_000 else { return Found(spans: [], speakers: []) }
        let manager = try await loaded()
        let result = try await manager.process(audio: samples)
        return Self.found(from: result)
    }

    /// Turns the pipeline's result into Mochi's spans and voices, numbered in order of first words.
    static func found(from result: DiarizationResult) -> Found {
        let raw = result.segments.map {
            VoiceSpan(speakerID: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        let (ordered, renamed) = Voices.ordered(raw)
        var original: [String: String] = [:]   // s1 -> the pipeline's "S3"
        for (from, to) in renamed { original[to] = from }
        let seconds = Voices.seconds(ordered)
        let ids = Array(Set(ordered.map(\.speakerID))).sorted { TranscriptText.speakerNumber($0) < TranscriptText.speakerNumber($1) }
        let speakers = ids.map { id -> CallSpeaker in
            let sample = Voices.sample(of: id, in: ordered)
            var vector = original[id].flatMap { result.speakerDatabase?[$0] }
            if let p = vector, p.isEmpty || p.contains(where: { !$0.isFinite }) { vector = nil }
            return CallSpeaker(id: id, seconds: seconds[id] ?? 0, sampleStart: sample?.start, sampleEnd: sample?.end,
                               voiceprint: vector.map(Voices.normalized))
        }
        return Found(spans: ordered, speakers: speakers)
    }
}
