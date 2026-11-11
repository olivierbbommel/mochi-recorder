import Foundation
import MochiKit
import MochiTranscribe

/// Live captions during a recording: the capture's samples go to the local engine, finished
/// lines come back on `onSegment`.
final class LiveCaptions: @unchecked Sendable {
    var onSegment: ((Segment) -> Void)?
    private var transcriber: LiveTranscriber!

    init() {
        transcriber = LiveTranscriber { [weak self] segment in self?.onSegment?(segment) }
    }

    /// Called on audio IO queues; never blocks.
    func append(_ samples: [Float], speaker: Speaker, time: Double) {
        transcriber.append(samples, speaker: speaker, time: time)
    }

    func finish() async {
        await transcriber.finish()
    }
}
