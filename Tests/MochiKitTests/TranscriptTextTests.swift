import Foundation
import Testing
@testable import MochiKit

@Test func mergesTurnsAndFormatsCopy() {
    let call = Call(id: "2026-10-31_140200", title: "Northwind creative review",
                    startedAt: ISO8601DateFormatter().date(from: "2026-10-31T06:02:00Z")!,
                    duration: 38 * 60, appName: "Google Meet", themName: "Ilse")
    let segs = [
        Segment(speaker: .me, start: 0, end: 2, text: "Quick one."),
        Segment(speaker: .me, start: 2, end: 4, text: "Before the cut."),
        Segment(speaker: .them, start: 5, end: 7, text: "Agreed."),
    ]
    let text = TranscriptText.copyText(call: call, segments: segs)
    #expect(text.contains("Me: Quick one. Before the cut.\n\nIlse: Agreed."))
    #expect(text.hasPrefix("Northwind creative review\n"))
    #expect(!text.contains("00:"))
}

@Test func collapsesLoops() {
    #expect(TranscriptText.collapseRepeats("you can see you can see you can see you can see you can see the reef")
            == "you can see the reef")
    #expect(TranscriptText.collapseRepeats("yes yes yes") == "yes yes yes")
}

@Test func dropsWordlessLines() {
    let segs = [Segment(speaker: .me, start: 0, end: 1, text: " ."), Segment(speaker: .me, start: 2, end: 3, text: "Okay.")]
    #expect(TranscriptText.clean(segs).map(\.text) == ["Okay."])
}

@Test func durations() {
    #expect(TranscriptText.duration(38 * 60) == "38 min")
    #expect(TranscriptText.duration(124 * 60) == "2 h 04 min")
    #expect(TranscriptText.clock(763) == "12:43")
}

@Test func dropsSpeakerBleed() {
    let segs = [
        Segment(speaker: .them, start: 0, end: 6, text: "Hello everyone, thanks for joining the call today."),
        Segment(speaker: .me, start: 0.3, end: 6.2, text: "Hello everyone. Thanks for joining the call today."),
        Segment(speaker: .me, start: 8, end: 10, text: "Thanks, glad to be here with you all."),
    ]
    let kept = TranscriptText.removeBleed(segs)
    #expect(kept.count == 2)
    #expect(kept.last?.text.hasPrefix("Thanks, glad") == true)
}

@Test func oldTaskFilesStillLoad() throws {
    let json = #"[{"id":"2B1C3E0A-6E52-4A0B-9C59-2A9D8E0F1A11","text":"Old","done":true,"createdAt":"2026-10-31T06:00:00Z"}]"#
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    let tasks = try d.decode([TaskItem].self, from: Data(json.utf8))
    #expect(tasks.first?.status == .done)
}

@Test func taskNotesRoundTrip() throws {
    var task = TaskItem(text: "Send the quote")
    task.notes = "Lena wants the grading line split out.\nBy Friday."
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    let back = try d.decode(TaskItem.self, from: e.encode(task))
    #expect(back.text == "Send the quote" && back.notes == task.notes)
    // Tasks saved before notes existed have none.
    let old = #"{"id":"2B1C3E0A-6E52-4A0B-9C59-2A9D8E0F1A11","text":"Old","status":"todo","createdAt":"2026-10-31T06:00:00Z"}"#
    #expect(try d.decode(TaskItem.self, from: Data(old.utf8)).notes == nil)
}

@Test func overdue() {
    let yesterday = Date().addingTimeInterval(-86_400)
    #expect(TaskItem(text: "a", due: yesterday).isOverdue())
    #expect(!TaskItem(text: "a", status: .done, due: yesterday).isOverdue())
    #expect(!TaskItem(text: "a", due: Date()).isOverdue())
}
