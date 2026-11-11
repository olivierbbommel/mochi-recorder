import FluidAudio
import Foundation
import MochiKit
import WhisperKit

/// Which language the owner wants the transcript in.
public enum LanguageMode: String, Sendable, CaseIterable { case auto, english = "en", dutch = "nl" }

/// Second pass for Dutch. Parakeet TDT v3 garbles Dutch, so Dutch stretches are re-transcribed with
/// Whisper large-v3 turbo (WhisperKit, Core ML). Models download from Hugging Face on first use.
public actor WhisperRefiner {
    public static let shared = WhisperRefiner()

    /// WhisperKit folder name for large-v3-v20240930 turbo. Override with MOCHI_WHISPER_MODEL
    /// (e.g. openai_whisper-large-v3-v20240930_turbo_632MB for the smaller quantized build).
    public static let modelVariant = ProcessInfo.processInfo.environment["MOCHI_WHISPER_MODEL"]
        ?? "openai_whisper-large-v3-v20240930_turbo"

    private var kit: WhisperKit?
    private var loading: Task<WhisperKit, Error>?
    /// Refines running now. The model (over 1 GB in memory) is only needed for a minute or two
    /// after a call, so it is let go once nothing has used it for `idleUnload`.
    private var active = 0
    private var unloadTask: Task<Void, Never>?
    public static let idleUnload: Duration = .seconds(300)

    /// A window needs at least this much confidence in "nl" to be re-transcribed.
    static let minDutchProbability: Float = 0.5
    /// Windows quieter than this RMS are treated as silence.
    static let silenceRMS: Float = 0.003
    static let windowSeconds = 30.0
    static let minWindowSeconds = 12.0
    static let sampleRate = 16_000.0

    public init() {}

    /// Loads the model ahead of a refine (Mochi calls it at Stop). Let go again after
    /// `idleUnload` if no refine comes.
    public func prepare() async throws {
        unloadTask?.cancel()
        _ = try await loadKit()
        scheduleUnload()
    }

    /// True while the model is in memory (for tests and the debug tool).
    public var isLoaded: Bool { kit != nil }

    private func scheduleUnload() {
        unloadTask?.cancel()
        guard active == 0 else { return }
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnload)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard active == 0, loading == nil else { return }
        kit = nil
    }

    private func loadKit() async throws -> WhisperKit {
        if let kit { return kit }
        if let loading { return try await loading.value }
        let task = Task<WhisperKit, Error> {
            let folder = try await WhisperKit.download(variant: Self.modelVariant)
            let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, prewarm: true, load: true, download: false)
            return try await WhisperKit(config)
        }
        loading = task
        do {
            let k = try await task.value
            kit = k
            loading = nil
            return k
        } catch {
            loading = nil
            throw error
        }
    }

    /// Returns the segments with Dutch parts re-transcribed by Whisper.
    public func refine(file: URL, speaker: MochiKit.Speaker, segments: [Segment], mode: LanguageMode) async throws -> [Segment] {
        if mode == .english { return segments }
        return try await refine(samples: try AudioConverter().resampleAudioFile(file), speaker: speaker, segments: segments, mode: mode)
    }

    /// Same, from 16 kHz mono samples already decoded (Mochi decodes each track once for both passes).
    public func refine(samples: [Float], speaker: MochiKit.Speaker, segments: [Segment], mode: LanguageMode) async throws -> [Segment] {
        if mode == .english { return segments }
        active += 1
        unloadTask?.cancel()
        defer { active -= 1; scheduleUnload() }
        let kit = try await loadKit()
        let total = Double(samples.count) / Self.sampleRate

        if mode == .dutch {
            let rms = Self.rms(samples[...])
            guard rms >= Self.silenceRMS else { return segments }
            return try await transcribe(kit, samples: Array(samples), offset: 0, speaker: speaker, language: "nl")
        }

        // Auto: per window language detection, then a per segment check inside mixed windows.
        var out: [Segment] = []
        var kept = segments.sorted { $0.start < $1.start }
        func tag(_ list: [Segment]) -> [Segment] { list.map { var s = $0; if s.language == nil { s.language = "en" }; return s } }
        func slice(_ a: Double, _ b: Double) -> [Float] {
            let lo = max(0, Int(a * Self.sampleRate)), hi = min(samples.count, Int(b * Self.sampleRate))
            return hi > lo ? Array(samples[lo..<hi]) : []
        }
        for w in Self.windows(for: kept, total: total) {
            let audio = slice(w.start, w.end)
            let inside = kept.filter { ($0.start + $0.end) / 2 >= w.start && ($0.start + $0.end) / 2 < w.end }
            kept.removeAll { s in inside.contains { $0.id == s.id } }
            guard audio.count >= 16_000, Self.rms(audio[...]) >= Self.silenceRMS,
                  let det = await detect(kit, audio, label: "window \(String(format: "%.1f-%.1f", w.start, w.end))") else {
                out += tag(inside)
                continue
            }
            let speech = inside.reduce(0.0) { $0 + ($1.end - $1.start) }
            if det.nl >= Self.minDutchProbability, speech >= 3 {
                let dutch = try await transcribe(kit, samples: audio, offset: w.start, speaker: speaker, language: "nl")
                guard !dutch.isEmpty || inside.isEmpty else { out += tag(inside); continue }
                // Segments that are clearly English on their own stay Parakeet (code switching).
                var english: [Segment] = []
                for seg in inside where seg.end - seg.start >= 1.5 {
                    if let d = await detect(kit, slice(seg.start - 0.25, seg.end + 0.25), label: "  seg \(String(format: "%.1f", seg.start))"),
                       d.en >= 0.8 { english.append(seg) }
                }
                out += dutch.filter { d in !english.contains { ($0.start...$0.end).contains((d.start + d.end) / 2) } }
                out += tag(english)
            } else if det.en < 0.9 {
                // Uncertain or sparse window; look for short Dutch sentences segment by segment.
                for seg in inside {
                    guard seg.end - seg.start >= 1.5, let d = await detect(kit, slice(seg.start - 0.25, seg.end + 0.25), label: "  seg \(String(format: "%.1f", seg.start))"),
                          d.nl >= Self.minDutchProbability else { out += tag([seg]); continue }
                    let redo = try await transcribe(kit, samples: slice(seg.start - 0.25, seg.end + 0.25), offset: max(0, seg.start - 0.25), speaker: speaker, language: "nl")
                    out += redo.isEmpty ? tag([seg]) : redo
                }
            } else {
                out += tag(inside)
            }
        }
        out += tag(kept)
        return out.sorted { $0.start < $1.start }
    }

    private func detect(_ kit: WhisperKit, _ audio: [Float], label: String) async -> (nl: Float, en: Float)? {
        guard audio.count >= 8_000, let d = try? await kit.detectLangauge(audioArray: audio) else { return nil }
        // langProbs are log probabilities.
        let nl = Foundation.exp(d.langProbs["nl"] ?? -100), en = Foundation.exp(d.langProbs["en"] ?? -100)
        if ProcessInfo.processInfo.environment["MOCHI_WHISPER_DEBUG"] != nil {
            FileHandle.standardError.write(Data(String(format: "%@ detect %@ nl=%.2f en=%.2f\n", label, d.language, nl, en).utf8))
        }
        return (nl, en)
    }

    // MARK: Windows

    /// ~30 s windows, cut at existing segment ends where possible.
    static func windows(for segments: [Segment], total: Double) -> [(start: Double, end: Double)] {
        let ends = segments.map(\.end).sorted()
        var result: [(Double, Double)] = []
        var start = 0.0
        while start < total - 0.01 {
            let target = start + windowSeconds
            if target >= total { result.append((start, total)); break }
            let cut = ends.last { $0 <= target && $0 >= start + minWindowSeconds } ?? target
            result.append((start, cut))
            start = cut
        }
        return result
    }

    static func rms(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return 0 }
        var sum: Float = 0
        for v in s { sum += v * v }
        return (sum / Float(s.count)).squareRoot()
    }

    // MARK: Whisper

    private func transcribe(_ kit: WhisperKit, samples: [Float], offset: Double, speaker: MochiKit.Speaker, language: String) async throws -> [Segment] {
        var opts = DecodingOptions(
            verbose: false, task: .transcribe, language: language, temperature: 0,
            usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true,
            withoutTimestamps: false, wordTimestamps: false,
            compressionRatioThreshold: 2.4, logProbThreshold: -1.0, noSpeechThreshold: 0.6
        )
        opts.concurrentWorkerCount = 1
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: opts)
        var out: [Segment] = []
        for r in results {
            for s in r.segments {
                if s.noSpeechProb > 0.8 { continue }
                let cleaned = Self.stripSpecialTokens(s.text)
                let text = TranscriptText.collapseRepeats(cleaned)
                guard Self.hasWords(text), !Self.isHallucination(text) else { continue }
                let start = offset + Double(s.start)
                let end = offset + max(Double(s.end), Double(s.start))
                let seg = Segment(speaker: speaker, start: start, end: end, text: text, language: language)
                if TranscriptText.plausible(seg) { out.append(seg) }
            }
        }
        return out
    }

    /// Removes any leftover <|...|> tokens and trims.
    static func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasWords(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// Classic Whisper subtitle-credit and sign-off hallucinations on silence or noise.
    static func isHallucination(_ text: String) -> Bool {
        let t = text.lowercased()
        let phrases = [
            "ondertiteling", "ondertitels", "bedankt voor het kijken", "bedankt voor het luisteren",
            "tot de volgende keer", "thanks for watching", "thank you for watching",
            "subtitles by", "amara.org", "please subscribe", "like and subscribe",
        ]
        if phrases.contains(where: { t.contains($0) }) { return true }
        let stripped = t.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["you", "bye", "dank u wel", "dank je wel"].contains(stripped)
    }
}
