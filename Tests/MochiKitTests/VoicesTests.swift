import Foundation
import Testing
@testable import MochiKit

// Made-up people only.

private let call = Call(id: "2026-11-09_100000", title: "Harbor Studio sync",
                        startedAt: ISO8601DateFormatter().date(from: "2026-11-09T02:00:00Z")!,
                        duration: 20 * 60, appName: "Google Meet")

/// A unit vector along one axis, with a little of another mixed in.
private func vec(_ axis: Int, _ mix: Float = 0, _ other: Int = 0, dims: Int = 8) -> [Float] {
    var v = [Float](repeating: 0, count: dims)
    v[axis] = 1
    v[other] += mix
    return Voices.normalized(v)
}

@Test func renumbersVoicesByFirstWordsAndDropsBlips() {
    let raw = [
        VoiceSpan(speakerID: "S3", start: 0, end: 4),
        VoiceSpan(speakerID: "S1", start: 4.5, end: 9),
        VoiceSpan(speakerID: "S2", start: 9.2, end: 9.6),   // 0.4 s in all: a blip
        VoiceSpan(speakerID: "S3", start: 10, end: 12),
    ]
    let (spans, renamed) = Voices.ordered(raw)
    #expect(spans.map(\.speakerID) == ["s1", "s2", "s1"])
    #expect(renamed == ["S3": "s1", "S1": "s2"])
    #expect(Voices.changes(spans) == [4.5, 10])
}

@Test func linesTakeTheVoiceThatSpeaksMostDuringThem() {
    let spans = [VoiceSpan(speakerID: "s1", start: 0, end: 5), VoiceSpan(speakerID: "s2", start: 5, end: 12)]
    let segs = [
        Segment(speaker: .them, start: 10.5, end: 14.5, text: "Mostly the first."),
        Segment(speaker: .them, start: 14, end: 21, text: "Mostly the second."),
        Segment(speaker: .me, start: 12, end: 13, text: "Mine."),
        Segment(speaker: .them, start: 23, end: 24, text: "Just after."),   // 1.5 s after the second voice
        Segment(speaker: .them, start: 40, end: 41, text: "Far away."),
    ]
    let out = Voices.assign(segs, spans: spans, offset: 10)
    #expect(out.map(\.speakerID) == ["s1", "s2", nil, "s2", nil])
}

@Test func compactRenumbersByFirstLineAndDropsSilentVoices() {
    let segs = [
        Segment(speaker: .them, start: 1, end: 2, text: "Hi.", speakerID: "s2"),
        Segment(speaker: .them, start: 3, end: 4, text: "Hello.", speakerID: "s3"),
    ]
    let speakers = ["s1", "s2", "s3"].map { CallSpeaker(id: $0, seconds: 3) }
    let (out, kept) = Voices.compact(segs, speakers: speakers)
    #expect(out.map(\.speakerID) == ["s1", "s2"])
    #expect(kept.map(\.id) == ["s1", "s2"])
}

@Test func labelsShowNamesSpeakerNumbersOrThem() {
    let segs = [
        Segment(speaker: .me, start: 0, end: 1, text: "Morning."),
        Segment(speaker: .them, start: 1, end: 2, text: "Morning!", speakerID: "s1", name: "Noor"),
        Segment(speaker: .them, start: 2, end: 3, text: "Hey there.", speakerID: "s2"),
        Segment(speaker: .them, start: 3, end: 4, text: "Shall we start?", speakerID: "s2"),
    ]
    let text = TranscriptText.copyText(call: call, segments: segs)
    #expect(text.contains("Me: Morning.\n\nNoor: Morning!\n\nSpeaker 2: Hey there. Shall we start?"))

    // One voice, unnamed: the call's name for the other side, as before.
    let one = [Segment(speaker: .them, start: 0, end: 1, text: "Hello.", speakerID: "s1")]
    #expect(TranscriptText.copyText(call: call, segments: one).contains("Them: Hello."))
}

@Test func recognisesKnownVoicesSureMaybeOrNot() {
    let noor = Voice(name: "Noor", prints: [.init(callID: "old", speakerID: "s1", vector: vec(0))])
    let bram = Voice(name: "Bram", prints: [.init(callID: "old", speakerID: "s2", vector: vec(1))])
    let speakers = [
        CallSpeaker(id: "s1", seconds: 60, voiceprint: vec(0, 0.1, 3)),   // very close to Noor
        CallSpeaker(id: "s2", seconds: 60, voiceprint: vec(1, 1.2, 4)),   // somewhat like Bram
        CallSpeaker(id: "s3", seconds: 60, voiceprint: vec(5)),           // nobody known
    ]
    let matches = Voices.recognise(speakers, among: [noor, bram])
    #expect(matches["s1"] == .sure(noor.id))
    #expect(matches["s2"] == .maybe(bram.id))
    #expect(matches["s3"] == nil)

    var sp = speakers
    var segs = [
        Segment(speaker: .them, start: 0, end: 1, text: "A.", speakerID: "s1"),
        Segment(speaker: .them, start: 1, end: 2, text: "B.", speakerID: "s2"),
    ]
    Voices.applyRecognition(matches, speakers: &sp, segments: &segs, voices: [noor, bram])
    #expect(segs.map(\.name) == ["Noor", nil])
    #expect(sp[0].voiceID == noor.id)
    #expect(sp[1].guessID == bram.id && sp[1].voiceID == nil)
}

@Test func onePersonIsNeverGivenToTwoVoicesOfACall() {
    let noor = Voice(name: "Noor", prints: [.init(callID: "old", speakerID: "s1", vector: vec(0))])
    let speakers = [
        CallSpeaker(id: "s1", seconds: 60, voiceprint: vec(0, 0.3, 2)),
        CallSpeaker(id: "s2", seconds: 60, voiceprint: vec(0, 0.05, 2)),
    ]
    let matches = Voices.recognise(speakers, among: [noor])
    #expect(matches["s2"] == .sure(noor.id))
    #expect(matches["s1"] == nil)
}

@Test func namingLearnsAndACorrectionUnlearns() {
    let speaker = CallSpeaker(id: "s1", seconds: 40, voiceprint: vec(2))
    var (voices, id) = Voices.learn(name: "Noor", speaker: speaker, callID: "c1", voices: [])
    #expect(voices.count == 1 && voices[0].prints.count == 1 && id == voices[0].id)

    // Same name in other letters: the same person.
    (voices, _) = Voices.learn(name: "noor ", speaker: CallSpeaker(id: "s2", seconds: 10, voiceprint: vec(2)),
                               callID: "c2", voices: voices)
    #expect(voices.count == 1 && voices[0].prints.count == 2)

    // It was Bram on c1 after all: Noor keeps only c2.
    (voices, _) = Voices.learn(name: "Bram", speaker: speaker, callID: "c1", voices: voices)
    let noor = voices.first { $0.name == "Noor" }!
    let bram = voices.first { $0.name == "Bram" }!
    #expect(noor.prints.map(\.callID) == ["c2"])
    #expect(bram.prints.map(\.callID) == ["c1"])

    // Clearing the name takes the print back and links nobody.
    let cleared = Voices.learn(name: "  ", speaker: speaker, callID: "c1", voices: voices)
    #expect(cleared.voiceID == nil)
    #expect(cleared.voices.first { $0.name == "Bram" }!.prints.isEmpty)
}

@Test func aCallsOwnPrintsDoNotRecogniseItself() {
    let noor = Voice(name: "Noor", prints: [.init(callID: "c1", speakerID: "s1", vector: vec(0))])
    let speakers = [CallSpeaker(id: "s1", seconds: 30, voiceprint: vec(0))]
    #expect(Voices.recognise(speakers, among: [noor], excludingCall: "c1").isEmpty)
    #expect(Voices.recognise(speakers, among: [noor], excludingCall: "c2")["s1"] == .sure(noor.id))
}

@Test func sampleIsTheMiddleOfTheLongestSpan() {
    let spans = [VoiceSpan(speakerID: "s1", start: 0, end: 3), VoiceSpan(speakerID: "s1", start: 10, end: 30)]
    let s = Voices.sample(of: "s1", in: spans)!
    #expect(s.start == 17.5 && s.end == 22.5)
    #expect(Voices.sample(of: "s2", in: spans) == nil)
}

@Test func oldTranscriptsWithoutVoicesStillDecode() throws {
    let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","speaker":"them","start":1,"end":2,"text":"Hi."}]"#
    let segs = try JSONDecoder().decode([Segment].self, from: Data(json.utf8))
    #expect(segs[0].speakerID == nil && segs[0].name == nil)
}

@Test func dropsFillerOnlyLines() {
    let segs = [
        Segment(speaker: .them, start: 0, end: 0.4, text: "Uh."),
        Segment(speaker: .them, start: 1, end: 1.5, text: "Mm-hmm."),
        Segment(speaker: .them, start: 2, end: 3, text: "Uh, sounds good."),
    ]
    #expect(TranscriptText.clean(segs).map(\.text) == ["Uh, sounds good."])
}
