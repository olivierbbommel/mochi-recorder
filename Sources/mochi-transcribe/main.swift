import Foundation
import MochiKit

typealias Speaker = MochiKit.Speaker
import MochiTranscribe
import AVFoundation
import FluidAudio

// usage: mochi-transcribe <file.wav> [me|them] [--live] [--refine auto|nl|en] [--speakers]
//        mochi-transcribe --distance <a.wav> <b.wav>   voiceprint distance of the main voice in each
var args = Array(CommandLine.arguments.dropFirst())
let live = args.contains("--live")
args.removeAll { $0 == "--live" }
let speakersMode = args.contains("--speakers")
args.removeAll { $0 == "--speakers" }
if args.first == "--distance", args.count == 3 {
    // Calibrates Voices.sureDistance and maybeDistance: run it on clips of the same and of different people.
    var prints: [[Float]] = []
    for path in args[1...] {
        let found = try await SpeakerFinder.shared.find(samples: try Transcriber.samples(of: URL(fileURLWithPath: path)))
        guard let main = found.speakers.max(by: { $0.seconds < $1.seconds }), let p = main.voiceprint else {
            print("no voice found in \(path)"); exit(1)
        }
        print(String(format: "%@: %d voices, main %@ %.0fs", path, found.speakers.count, main.id, main.seconds))
        prints.append(p)
    }
    let d = Voices.distance(prints[0], prints[1])
    print(String(format: "distance %.3f (sure <= %.2f, maybe <= %.2f)", d, Voices.sureDistance, Voices.maybeDistance))
    exit(0)
}
var refine: LanguageMode?
if let i = args.firstIndex(of: "--refine") {
    guard i + 1 < args.count, let m = LanguageMode(rawValue: args[i + 1]) else {
        FileHandle.standardError.write(Data("--refine needs auto|nl|en\n".utf8))
        exit(2)
    }
    refine = m
    args.removeSubrange(i...(i + 1))
}
guard let path = args.first else {
    FileHandle.standardError.write(Data("usage: mochi-transcribe <file.wav> [me|them] [--live] [--refine auto|nl|en] [--speakers]\n       mochi-transcribe --distance <a.wav> <b.wav>\n".utf8))
    exit(2)
}
let speaker: Speaker = args.count > 1 && args[1] == "them" ? .them : .me
let url = URL(fileURLWithPath: path)

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func line(_ s: Segment) -> String { String(format: "[%7.2f - %7.2f] %@ (%@): %@", s.start, s.end, s.speaker.rawValue, s.language ?? "-", s.text) }

let t0 = now()
try await Transcriber.shared.prepare()
print(String(format: "models ready in %.1fs", now() - t0))

if live {
    let samples = try AudioConverter(sampleRate: 48_000).resampleAudioFile(url)
    let seconds = Double(samples.count) / 48_000
    let start = now()
    let lt = LiveTranscriber { s in print(String(format: "+%5.1fs ", now() - start) + line(s)) }
    let chunk = 480
    var i = 0
    while i < samples.count {
        let j = min(i + chunk, samples.count)
        lt.append(Array(samples[i..<j]), speaker: speaker, time: Double(i) / 48_000)
        i = j
    }
    let fed = now()
    await lt.finish()
    print(String(format: "audio %.1fs, fed in %.2fs, drained %.2fs after feed", seconds, fed - start, now() - fed))
} else {
    let seconds = try { let f = try AVAudioFile(forReading: url); return Double(f.length) / f.processingFormat.sampleRate }()
    let start = now()
    var segs: [Segment]
    if speakersMode {
        let samples = try Transcriber.samples(of: url)
        let found = try await SpeakerFinder.shared.find(samples: samples)
        print(String(format: "voices in %.2fs: ", now() - start) + found.speakers.map {
            String(format: "%@ %.0fs%@", $0.id, $0.seconds, $0.voiceprint == nil ? " (no print)" : "")
        }.joined(separator: ", "))
        for (i, a) in found.speakers.enumerated() {
            for b in found.speakers.dropFirst(i + 1) {
                if let pa = a.voiceprint, let pb = b.voiceprint {
                    print(String(format: "  %@ vs %@: distance %.3f", a.id, b.id, Voices.distance(pa, pb)))
                }
            }
        }
        segs = try await Transcriber.shared.transcribe(track: samples, speaker: speaker, breaks: Voices.changes(found.spans))
        segs = Voices.assign(segs, spans: found.spans)
    } else {
        segs = try await Transcriber.shared.transcribe(file: url, speaker: speaker)
    }
    let took = now() - start
    for s in segs { print((s.speakerID.map { "\($0) " } ?? "") + line(s)) }
    print(String(format: "audio %.1fs, took %.2fs, RTF %.3f (%.0fx realtime)", seconds, took, took / max(seconds, 0.001), seconds / max(took, 0.001)))
    if let refine {
        func rss() -> Double {
            var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
            return r == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
        }
        let l0 = now()
        try await WhisperRefiner.shared.prepare()
        print(String(format: "whisper ready in %.1fs (rss %.0f MB)", now() - l0, rss()))
        let r0 = now()
        let refined = try await WhisperRefiner.shared.refine(file: url, speaker: speaker, segments: segs, mode: refine)
        let rtook = now() - r0
        print("--- refined (\(refine.rawValue)) ---")
        for s in refined { print(line(s)) }
        print(String(format: "refine took %.2fs, RTF %.3f, rss %.0f MB", rtook, rtook / max(seconds, 0.001), rss()))
    }
}
