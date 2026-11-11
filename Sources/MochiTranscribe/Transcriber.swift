import FluidAudio
import Foundation
import MochiKit

typealias Speaker = MochiKit.Speaker

public enum TranscriberState: Sendable, Equatable { case notLoaded, loading, ready, failed(String) }

/// Local speech to text: Parakeet TDT v3 (multilingual, includes Dutch) on the Neural Engine via FluidAudio.
/// Models download from Hugging Face on first use into FluidAudio's default cache
/// (`AsrModels.defaultCacheDirectory()`, under Application Support/FluidAudio/Models).
public actor Transcriber {
    public static let shared = Transcriber()

    public private(set) var state: TranscriberState = .notLoaded
    private var manager: AsrManager?
    private var loading: Task<Void, Error>?

    public init() {}

    /// Downloads (first time) and loads the models. Safe to call repeatedly and concurrently.
    /// `progress` gets 0...1 and a short description while the first download runs.
    public func prepare(progress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        if manager != nil { return }
        if let loading { return try await loading.value }
        state = .loading
        let task = Task<Void, Error> { [weak self] in
            do {
                let models = try await AsrModels.downloadAndLoad(version: .v3) { p in
                    switch p.phase {
                    case .listing: progress?(0, "Getting the speech model ready")
                    case .downloading: progress?(p.fractionCompleted, "Downloading the speech model, first time only")
                    case .compiling: progress?(1, "Setting up the speech model, first time only")
                    }
                }
                let m = AsrManager(config: .default)
                try await m.loadModels(models)
                await self?.finishLoading(m)
            } catch {
                await self?.failLoading(error)
                throw error
            }
        }
        loading = task
        try await task.value
    }

    private func finishLoading(_ m: AsrManager) {
        manager = m
        state = .ready
        loading = nil
    }

    private func failLoading(_ error: Error) {
        state = .failed(error.localizedDescription)
        loading = nil
    }

    /// Whole file (any rate, mono or stereo; mixed down and resampled to 16 kHz). FluidAudio chunks long
    /// audio internally. Timestamps are seconds from the file start.
    public func transcribe(file: URL, speaker: MochiKit.Speaker) async throws -> [Segment] {
        try await prepare()
        let samples = try Self.samples(of: file)
        return try await transcribe(samples: samples, speaker: speaker, offset: 0)
    }

    /// A whole track as 16 kHz mono, decoded once and shared by the Parakeet and Whisper passes.
    public nonisolated static func samples(of file: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(file)
    }

    /// Whole track, already decoded with `samples(of:)`. `breaks` are times (seconds on the track)
    /// where the voice changes: a line never runs across one.
    public func transcribe(track samples: [Float], speaker: MochiKit.Speaker, breaks: [Double] = []) async throws -> [Segment] {
        try await transcribe(samples: samples, speaker: speaker, offset: 0, breaks: breaks)
    }

    /// 16 kHz mono samples. `offset` is added to every timestamp.
    func transcribe(samples: [Float], speaker: Speaker, offset: Double, breaks: [Double] = []) async throws -> [Segment] {
        try await prepare()
        guard let manager else { return [] }
        var input = samples
        // The model needs at least one second of audio.
        if input.count < 16_000 { input += [Float](repeating: 0, count: 16_000 - input.count) }
        var decoder = try TdtDecoderState()
        let result = try await manager.transcribe(input, decoderState: &decoder)
        return Self.segments(from: result, speaker: speaker, offset: offset, totalSeconds: Double(samples.count) / 16_000,
                             breaks: breaks)
    }

    /// Splits token timings into segments at pauses (>0.8 s), at `breaks` (voice changes, in the
    /// same seconds as the token timings) and, past 12 s, at sentence ends.
    static func segments(from result: ASRResult, speaker: Speaker, offset: Double, totalSeconds: Double,
                         breaks: [Double] = []) -> [Segment] {
        var out: [Segment] = []
        func emit(_ text: String, _ start: Double, _ end: Double) {
            let collapsed = TranscriptText.collapseRepeats(text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !collapsed.isEmpty else { return }
            let seg = Segment(speaker: speaker, start: offset + start, end: offset + max(end, start), text: collapsed, language: nil)
            if TranscriptText.plausible(seg) { out.append(seg) }
        }
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            emit(result.text, 0, totalSeconds)
            return out
        }
        var text = ""
        var start = timings[0].startTime
        var lastEnd = start
        let cuts = Self.cutPoints(timings.map { (start: $0.startTime, end: $0.endTime, token: $0.token) }, breaks: breaks)
        for (i, t) in timings.enumerated() {
            let gap = t.startTime - lastEnd
            let sentenceEnd = text.last.map { ".?!".contains($0) } ?? false
            let cutForVoice = cuts.contains(i)
            if !text.isEmpty && (gap > 0.8 || cutForVoice || (sentenceEnd && lastEnd - start > 12)) {
                emit(text, start, lastEnd)
                text = ""
                start = t.startTime
            }
            text += t.token.replacingOccurrences(of: "\u{2581}", with: " ")
            lastEnd = max(lastEnd, t.endTime)
        }
        emit(text, start, lastEnd)
        return out
    }

    /// Where to start a new line for each voice change. The diarizer marks a new voice a little
    /// off (usually late), so the cut moves to the most natural word start from 0.8 s before the
    /// change to 0.3 s after, in this order:
    /// 1. a sentence start (the word before ends in . ? !), nearest the change;
    /// 2. a real pause, at least 0.15 s and well over this stretch's usual gap between words, nearest the change;
    /// 3. else the first word starting at the change, as the diarizer said.
    /// Nearest, not longest: in crosstalk the longest gap is often just one between a speaker's own
    /// words, which cut sentences short ("I think that's | everyone.").
    static func cutPoints(_ tokens: [(start: Double, end: Double, token: String)], breaks: [Double]) -> Set<Int> {
        func isWordStart(_ i: Int) -> Bool { tokens[i].token.hasPrefix("\u{2581}") || tokens[i].token.hasPrefix(" ") }
        func gap(_ i: Int) -> Double { tokens[i].start - tokens[i - 1].end }
        var cuts: Set<Int> = []
        for b in breaks {
            var sentence: [Int] = [], pauses: [Int] = [], local: [Double] = []
            var fallback: Int?
            for i in tokens.indices where i > 0 && isWordStart(i) {
                let t = tokens[i]
                if t.start >= b - 5 && t.start <= b + 5 { local.append(max(0, gap(i))) }
                if fallback == nil, t.start >= b - 0.15 { fallback = i }
                guard t.start >= b - 0.8, t.start <= b + 0.3 else { continue }
                let before = tokens[i - 1].token.trimmingCharacters(in: .whitespaces)
                if let last = before.last, ".?!".contains(last) { sentence.append(i) } else { pauses.append(i) }
            }
            let usual = local.isEmpty ? 0 : local.sorted()[local.count / 2]
            let real = pauses.filter { gap($0) >= max(0.15, usual * 2.5) }
            func nearest(_ list: [Int]) -> Int? { list.min { abs(tokens[$0].start - b) < abs(tokens[$1].start - b) } }
            if let i = nearest(sentence) ?? nearest(real) ?? fallback { cuts.insert(i) }
        }
        return cuts
    }
}
