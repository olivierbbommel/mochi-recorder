import Foundation

/// A stretch of the other side's track where one voice speaks. Seconds on that track.
public struct VoiceSpan: Codable, Hashable, Sendable {
    public var speakerID: String
    public var start: Double
    public var end: Double

    public init(speakerID: String, start: Double, end: Double) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// One voice heard on the other side of a call. Kept only on this Mac, in the call's
/// speakers.json, because the voiceprint is biometric data. The name lives on the transcript lines.
public struct CallSpeaker: Codable, Hashable, Sendable, Identifiable {
    /// "s1", "s2", in order of first words.
    public var id: String
    /// How long they spoke, in seconds.
    public var seconds: Double
    /// A clear few seconds of this voice on the other side's track, for the play button.
    public var sampleStart: Double?
    public var sampleEnd: Double?
    /// What the voice sounds like (a speaker embedding). Nil when there was too little speech.
    public var voiceprint: [Float]?
    /// The known voice this one was named as, or recognised as for sure.
    public var voiceID: UUID?
    /// A known voice it probably is, waiting for you to confirm.
    public var guessID: UUID?

    public init(id: String, seconds: Double, sampleStart: Double? = nil, sampleEnd: Double? = nil,
                voiceprint: [Float]? = nil, voiceID: UUID? = nil, guessID: UUID? = nil) {
        self.id = id
        self.seconds = seconds
        self.sampleStart = sampleStart
        self.sampleEnd = sampleEnd
        self.voiceprint = voiceprint
        self.voiceID = voiceID
        self.guessID = guessID
    }
}

/// speakers.json in a call's folder.
public struct CallSpeakers: Codable, Hashable, Sendable {
    public var speakers: [CallSpeaker]
    /// Where the other side's track starts on the call's timeline (transcript times), seconds.
    public var trackOffset: Double
    public var foundAt: Date

    public init(speakers: [CallSpeaker], trackOffset: Double, foundAt: Date = Date()) {
        self.speakers = speakers
        self.trackOffset = trackOffset
        self.foundAt = foundAt
    }

    public func speaker(_ id: String) -> CallSpeaker? { speakers.first { $0.id == id } }
}

/// A person Mochi knows by voice. Kept only on this Mac in ~/Mochi/voices.json.
public struct Voice: Codable, Hashable, Sendable, Identifiable {
    /// One call's voiceprint of this person. Kept per call so a wrong name can be taken back.
    public struct Print: Codable, Hashable, Sendable {
        public var callID: String
        public var speakerID: String
        public var vector: [Float]
        public init(callID: String, speakerID: String, vector: [Float]) {
            self.callID = callID
            self.speakerID = speakerID
            self.vector = vector
        }
    }

    public var id: UUID
    public var name: String
    public var prints: [Print]
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, prints: [Print] = [], updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.prints = prints
        self.updatedAt = updatedAt
    }

    /// The average of its prints, length one. Nil with no prints.
    public var centroid: [Float]? { Voices.mean(prints.map(\.vector)) }

    /// The most prints kept per person: the newest win.
    public static let maxPrints = 20
}

/// Telling voices apart and recognising known ones. Pure functions, no audio.
public enum Voices {
    /// Cosine distance at or under which a voice is taken as the known person without asking.
    public static let sureDistance: Float = 0.30
    /// Cosine distance at or under which Mochi asks "Lena?".
    public static let maybeDistance: Float = 0.45

    // MARK: Vectors

    public static func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard n > 0, n.isFinite else { return v }
        return v.map { $0 / n }
    }

    /// 1 minus cosine similarity: 0 is the same direction, 2 the opposite. 2 for vectors that cannot be compared.
    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 2 }
        return 1 - dot / (sqrt(na) * sqrt(nb))
    }

    /// The mean of the normalised vectors, normalised. Nil when empty or the lengths differ.
    public static func mean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty, vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors {
            let n = normalized(v)
            for i in sum.indices { sum[i] += n[i] }
        }
        return normalized(sum)
    }

    // MARK: Spans and lines

    /// Renumbers the diarizer's speaker names ("S3", "S1") as "s1", "s2" in order of first words,
    /// and drops spans of voices heard for under `minSeconds` in all (a cough, a one-word blip),
    /// which are almost always a split-off piece of a real voice. `renamed` maps the diarizer's
    /// names to the new ones.
    public static func ordered(_ spans: [VoiceSpan], minSeconds: Double = 1.5) -> (spans: [VoiceSpan], renamed: [String: String]) {
        var total: [String: Double] = [:]
        for s in spans { total[s.speakerID, default: 0] += max(0, s.end - s.start) }
        let kept = spans.filter { (total[$0.speakerID] ?? 0) >= minSeconds && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var names: [String: String] = [:]
        for s in kept where names[s.speakerID] == nil { names[s.speakerID] = "s\(names.count + 1)" }
        return (kept.map { VoiceSpan(speakerID: names[$0.speakerID]!, start: $0.start, end: $0.end) }, names)
    }

    /// The times where the voice changes, for splitting lines there.
    public static func changes(_ spans: [VoiceSpan]) -> [Double] {
        var out: [Double] = []
        var last: String?
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last, last != s.speakerID { out.append(s.start) }
            last = s.speakerID
        }
        return out
    }

    /// Gives each line of the other side the voice that speaks most during it. `offset` is where
    /// the spans' track starts on the lines' timeline. A line no span touches takes the nearest
    /// voice within 2 s; lines further away stay unassigned. Me lines are left alone.
    public static func assign(_ segments: [Segment], spans: [VoiceSpan], offset: Double = 0) -> [Segment] {
        guard !spans.isEmpty else { return segments }
        let shifted = spans.map { VoiceSpan(speakerID: $0.speakerID, start: $0.start + offset, end: $0.end + offset) }
        return segments.map { seg in
            guard seg.speaker == .them else { return seg }
            var overlap: [String: Double] = [:]
            for s in shifted {
                let o = min(seg.end, s.end) - max(seg.start, s.start)
                if o > 0 { overlap[s.speakerID, default: 0] += o }
            }
            var out = seg
            if let best = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
                out.speakerID = best.key
            } else {
                let mid = (seg.start + seg.end) / 2
                let nearest = shifted.min { gap(mid, $0) < gap(mid, $1) }
                out.speakerID = nearest.flatMap { gap(mid, $0) <= 2 ? $0.speakerID : nil }
            }
            return out
        }
    }

    private static func gap(_ t: Double, _ s: VoiceSpan) -> Double {
        t < s.start ? s.start - t : (t > s.end ? t - s.end : 0)
    }

    /// Keeps only the voices that ended up with lines, renumbered "s1", "s2" in order of their
    /// first line, on both the lines and the voices.
    public static func compact(_ segments: [Segment], speakers: [CallSpeaker]) -> (segments: [Segment], speakers: [CallSpeaker]) {
        var names: [String: String] = [:]
        for s in segments.sorted(by: { $0.start < $1.start }) where s.speaker == .them {
            if let id = s.speakerID, names[id] == nil { names[id] = "s\(names.count + 1)" }
        }
        let segs = segments.map { seg -> Segment in
            var s = seg
            if s.speaker == .them, let id = s.speakerID { s.speakerID = names[id] }
            return s
        }
        let kept = speakers.compactMap { sp -> CallSpeaker? in
            guard let new = names[sp.id] else { return nil }
            var s = sp
            s.id = new
            return s
        }.sorted { TranscriptText.speakerNumber($0.id) < TranscriptText.speakerNumber($1.id) }
        return (segs, kept)
    }

    /// The seconds each voice speaks.
    public static func seconds(_ spans: [VoiceSpan]) -> [String: Double] {
        var out: [String: Double] = [:]
        for s in spans { out[s.speakerID, default: 0] += s.end - s.start }
        return out
    }

    /// A clear stretch to play: the middle `length` seconds of the voice's longest span.
    public static func sample(of speakerID: String, in spans: [VoiceSpan], length: Double = 5) -> (start: Double, end: Double)? {
        guard let longest = spans.filter({ $0.speakerID == speakerID }).max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
        else { return nil }
        let span = longest.end - longest.start
        guard span > length else { return (longest.start, longest.end) }
        let start = longest.start + (span - length) / 2
        return (start, start + length)
    }

    // MARK: Recognising

    public enum Match: Equatable, Sendable {
        case sure(UUID)
        case maybe(UUID)
    }

    /// Which known voice each of a call's voices is. Closest pairs first, and one person is never
    /// given to two voices of the same call. Voices without a print, or with nobody close enough,
    /// are left out.
    public static func recognise(_ speakers: [CallSpeaker], among voices: [Voice], excludingCall callID: String? = nil)
        -> [String: Match] {
        var pairs: [(speaker: String, voice: UUID, distance: Float)] = []
        for s in speakers {
            guard let print = s.voiceprint else { continue }
            for v in voices {
                // This call's own prints say nothing about whether it matches.
                let others = v.prints.filter { $0.callID != callID }
                guard let centroid = mean(others.map(\.vector)) else { continue }
                let d = distance(print, centroid)
                if d <= maybeDistance { pairs.append((s.id, v.id, d)) }
            }
        }
        var out: [String: Match] = [:]
        var taken: Set<UUID> = []
        for p in pairs.sorted(by: { $0.distance < $1.distance }) where out[p.speaker] == nil && !taken.contains(p.voice) {
            out[p.speaker] = p.distance <= sureDistance ? .sure(p.voice) : .maybe(p.voice)
            taken.insert(p.voice)
        }
        return out
    }

    /// Writes the names of the known voices onto the call's lines and links the voices: sure
    /// matches get the name, maybes become a guess. Voices you named stay as they are.
    public static func applyRecognition(_ matches: [String: Match], speakers: inout [CallSpeaker],
                                        segments: inout [Segment], voices: [Voice]) {
        for i in speakers.indices {
            let id = speakers[i].id
            guard speakers[i].voiceID == nil, let match = matches[id] else { continue }
            switch match {
            case .sure(let voiceID):
                guard let name = voices.first(where: { $0.id == voiceID })?.name else { continue }
                speakers[i].voiceID = voiceID
                speakers[i].guessID = nil
                segments = rename(segments, speakerID: id, to: name)
            case .maybe(let voiceID):
                speakers[i].guessID = voiceID
            }
        }
    }

    /// Puts a name on every line of one voice (nil or blank clears it).
    public static func rename(_ segments: [Segment], speakerID: String, to name: String?) -> [Segment] {
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return segments.map { seg in
            guard seg.speakerID == speakerID, seg.speaker == .them else { return seg }
            var s = seg
            s.name = (clean?.isEmpty ?? true) ? nil : clean
            return s
        }
    }

    // MARK: Learning

    /// You named a call's voice: link it to the person with that name (a new one when nobody
    /// has it) and learn the voiceprint. Any earlier link of that voice is taken back first, so a
    /// correction unlearns the wrong person. Returns the voices and the person's id (nil for a blank name).
    public static func learn(name: String, speaker: CallSpeaker, callID: String, voices: [Voice],
                             now: Date = Date()) -> (voices: [Voice], voiceID: UUID?) {
        var voices = forget(speakerID: speaker.id, callID: callID, voices: voices)
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return (voices, nil) }
        let index: Int
        if let existing = voices.firstIndex(where: { $0.name.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            index = existing
        } else {
            voices.append(Voice(name: clean, updatedAt: now))
            index = voices.count - 1
        }
        if let vector = speaker.voiceprint {
            voices[index].prints.append(Voice.Print(callID: callID, speakerID: speaker.id, vector: vector))
            if voices[index].prints.count > Voice.maxPrints { voices[index].prints.removeFirst(voices[index].prints.count - Voice.maxPrints) }
        }
        voices[index].updatedAt = now
        return (voices, voices[index].id)
    }

    /// Takes back what one call's voice taught. People left with no prints at all are kept: the
    /// name is still useful as a suggestion.
    public static func forget(speakerID: String, callID: String, voices: [Voice]) -> [Voice] {
        voices.map { v in
            var v = v
            v.prints.removeAll { $0.callID == callID && $0.speakerID == speakerID }
            return v
        }
    }
}
