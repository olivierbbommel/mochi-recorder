import Foundation

/// One speaker's consecutive segments, shown as one block.
public struct Turn: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var speaker: Speaker
    public var start: Double
    public var text: String
    /// The voice on the other side ("s2") and its name, when the call's voices were told apart.
    public var speakerID: String? = nil
    public var name: String? = nil
}

public enum TranscriptText {
    /// Merges consecutive segments of the same speaker, in time order.
    public static func turns(_ segments: [Segment]) -> [Turn] {
        var out: [Turn] = []
        for s in segments.sorted(by: { $0.start < $1.start }) {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = out.last, last.speaker == s.speaker, last.speakerID == s.speakerID, last.name == s.name {
                out[out.count - 1].text += " " + text
            } else {
                out.append(Turn(id: s.id, speaker: s.speaker, start: s.start, text: text, speakerID: s.speakerID, name: s.name))
            }
        }
        return out
    }

    /// Whose line it is, as the transcript shows it: "Me", the voice's name, "Speaker 2" when the
    /// call has several unnamed voices, else the call's name for the other side ("Them", "Dana").
    /// `voices` is how many different voices the call's transcript has (`voiceCount`).
    public static func label(speaker: Speaker, speakerID: String?, name: String?, call: Call, voices: Int) -> String {
        if speaker == .me { return "Me" }
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        if let speakerID, voices > 1 { return "Speaker \(speakerNumber(speakerID))" }
        return call.themLabel
    }

    public static func label(_ turn: Turn, call: Call, voices: Int) -> String {
        label(speaker: turn.speaker, speakerID: turn.speakerID, name: turn.name, call: call, voices: voices)
    }

    /// How many different voices the other side has in these lines (0 when they were never told apart).
    public static func voiceCount(_ segments: [Segment]) -> Int {
        Set(segments.compactMap { $0.speaker == .them ? $0.speakerID : nil }).count
    }

    /// "s2" is Speaker 2.
    public static func speakerNumber(_ speakerID: String) -> Int {
        Int(speakerID.drop { !$0.isNumber }) ?? 1
    }

    /// A recording made with one microphone (the iPhone in the room): no speaker split.
    public static func isInPerson(_ call: Call) -> Bool { call.appName == "In person" }

    /// One-microphone recordings read as paragraphs: a new one after a pause over 1.5 s, or at a
    /// sentence end after 40 s of continuous speech.
    public static func paragraphs(_ segments: [Segment]) -> [Turn] {
        var out: [Turn] = []
        var lastEnd = -10.0
        for s in segments.sorted(by: { $0.start < $1.start }) {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let pause = s.start - lastEnd
            if let last = out.last, pause <= 1.5,
               !(s.start - last.start > 40 && (last.text.hasSuffix(".") || last.text.hasSuffix("?") || last.text.hasSuffix("!"))) {
                out[out.count - 1].text += " " + text
            } else {
                out.append(Turn(id: s.id, speaker: s.speaker, start: s.start, text: text))
            }
            lastEnd = s.end
        }
        return out
    }

    /// The Copy Transcript format: a header, then "Me: ..." and "Them: ..." (or "Lena: ...", "Speaker 2: ...") turns, a blank line
    /// between turns, no timestamps. This is what you paste into Claude.
    public static func copyText(call: Call, segments: [Segment]) -> String {
        if isInPerson(call) {
            var lines = [call.title, header(call), "In person, recorded on iPhone", ""]
            for p in paragraphs(segments) { lines.append(p.text); lines.append("") }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        var lines = [call.title, header(call), ""]
        let voices = voiceCount(segments)
        for turn in turns(segments) {
            lines.append("\(label(turn, call: call, voices: voices)): \(turn.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// "Friday 31 October 2026, 14:02 · 38 min · Google Meet"
    public static func header(_ call: Call) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var parts = [f.string(from: call.startedAt), duration(call.duration)]
        if let app = call.appName { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    /// "38 min", "2 h 04 min", "under 1 min".
    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 30 { return "under 1 min" }
        if minutes < 60 { return "\(max(1, minutes)) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// "12:43" or "1:02:05".
    public static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Drops "Me" lines that are the call's own audio picked up by the mic (speakers instead of a
    /// headset): a Them line overlapping in time with mostly the same words.
    /// Bleed removed, and lines with no words at all (a lone "." the engine emits on a breath) or
    /// only a filler ("Uh.", "Mm-hmm") dropped.
    public static func clean(_ segments: [Segment]) -> [Segment] {
        removeBleed(segments.filter { $0.text.contains { $0.isLetter || $0.isNumber } && !isFiller($0.text) })
    }

    static let fillers: Set<String> = ["uh", "uhm", "um", "umm", "hmm", "hm", "mm", "mmm", "mhm", "ah", "eh", "er", "erm", "uhh", "ehm", "euh"]

    /// "Uh.", "Um, uh", "Mm-hmm": nothing but filler sounds.
    public static func isFiller(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty, words.count <= 3 else { return false }
        return words.allSatisfy { fillers.contains($0) }
    }

    public static func removeBleed(_ segments: [Segment]) -> [Segment] {
        func words(_ t: String) -> Set<String> {
            Set(t.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let them = segments.filter { $0.speaker == .them }.map { ($0, words($0.text)) }
        return segments.filter { seg in
            guard seg.speaker == .me else { return true }
            let mine = words(seg.text)
            guard mine.count >= 3 else { return true }
            return !them.contains { other, theirs in
                other.start < seg.end + 2 && seg.start < other.end + 2 &&
                    Double(mine.intersection(theirs).count) / Double(mine.count) >= 0.6
            }
        }
    }

    // MARK: Cleanup, ported from old Mochi (transcribe.collapse_repeats)

    static let maxRepeats = 3
    static let maxLoopWords = 8
    static let maxWordsPerSecond = 8.0

    /// Keeps one copy of a 1 to 8 word phrase repeated more than 3 times in a row, the loop
    /// speech engines fall into on silence or garbled audio ("you can see you can see ...").
    public static func collapseRepeats(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        guard words.count > maxRepeats else { return text }
        func norm(_ w: String) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var i = 0
        while i < words.count {
            var collapsed = false
            for n in 1...maxLoopWords where i + n * (maxRepeats + 1) <= words.count {
                let phrase = words[i..<i + n].map(norm)
                var reps = 1
                while i + (reps + 1) * n <= words.count,
                      words[(i + reps * n)..<(i + (reps + 1) * n)].map(norm) == phrase {
                    reps += 1
                }
                if reps > maxRepeats {
                    words.removeSubrange((i + n)..<(i + reps * n))
                    collapsed = true
                    break
                }
            }
            if !collapsed { i += 1 }
        }
        return words.joined(separator: " ")
    }

    /// Drops text that claims more words than anyone can say in its time span.
    public static func plausible(_ segment: Segment) -> Bool {
        let words = segment.text.split(separator: " ").count
        let span = max(segment.end - segment.start, 0.5)
        return Double(words) / span <= maxWordsPerSecond || words <= 4
    }
}
