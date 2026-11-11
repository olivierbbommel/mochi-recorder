import AVFoundation
import Foundation

/// Shrinks a call's two WAV tracks to AAC (.m4a) once its transcript is written: about 1 GB per
/// hour becomes about 60 MB. Speech-quality AAC at 64 kbit/s per track still transcribes the same,
/// so Transcribe Again keeps working. A WAV is deleted only after its .m4a is checked to be
/// complete (same length within half a second).
enum Compressor {
    struct Problem: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func compress(_ folder: URL) {
        DispatchQueue.global(qos: .utility).async {
            for name in ["mic", "them"] {
                let wav = folder.appendingPathComponent("\(name).wav")
                guard FileManager.default.fileExists(atPath: wav.path) else { continue }
                let m4a = folder.appendingPathComponent("\(name).m4a")
                try? FileManager.default.removeItem(at: m4a)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
                p.arguments = ["-f", "m4af", "-d", "aac", "-b", "64000", wav.path, m4a.path]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { continue }
                p.waitUntilExit()
                guard p.terminationStatus == 0, let a = seconds(wav), let b = seconds(m4a), abs(a - b) < 0.5 else {
                    try? FileManager.default.removeItem(at: m4a)
                    continue
                }
                try? FileManager.default.removeItem(at: wav)
            }
        }
    }

    static func seconds(_ url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }
}
