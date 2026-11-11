import Foundation
import Testing
@testable import MochiKit

private struct Ev { let name: String; let start: Date; let end: Date }

private let day = ISO8601DateFormatter().date(from: "2026-11-03T09:00:00Z")!   // 17:00 at UTC+8
private func at(_ h: Int, _ m: Int) -> Date { day.addingTimeInterval(Double((h - 17) * 3600 + m * 60)) }
private func ev(_ name: String, _ sh: Int, _ sm: Int, _ eh: Int, _ em: Int) -> Ev { Ev(name: name, start: at(sh, sm), end: at(eh, em)) }

private func startPick(_ evs: [Ev], _ now: Date) -> String? {
    EventMatch.atStart(evs, now: now, start: \.start, end: \.end)?.name
}
private func recPick(_ evs: [Ev], _ a: Date, _ b: Date) -> String? {
    EventMatch.forRecording(evs, from: a, to: b, start: \.start, end: \.end)?.name
}

@Suite struct EventMatchTests {
    // Back to back: "Design review: Northwind" 5:00-5:45, "Call: Sam Lee" 5:45-6:00, recording started 5:44.
    private let backToBack = [ev("Design review: Northwind", 17, 0, 17, 45), ev("Call: Sam Lee", 17, 45, 18, 0)]

    @Test func picksTheCallAboutToStartOverTheOneEnding() {
        #expect(startPick(backToBack, at(17, 44)) == "Call: Sam Lee")
    }

    @Test func picksTheRunningCallWhenNothingFollows() {
        #expect(startPick([ev("Design review: Northwind", 17, 0, 17, 45)], at(17, 1)) == "Design review: Northwind")
        #expect(startPick(backToBack, at(17, 2)) == "Design review: Northwind")
    }

    @Test func joiningEarlyCounts() {
        #expect(startPick([ev("Call: Sam Lee", 17, 45, 18, 0)], at(17, 37)) == "Call: Sam Lee")
        #expect(startPick([ev("Call: Sam Lee", 17, 45, 18, 0)], at(17, 30)) == nil)
    }

    @Test func noEventAfterItEnded() {
        #expect(startPick([ev("Design review: Northwind", 17, 0, 17, 45)], at(17, 46)) == nil)
    }

    @Test func aLongCallJoinedLateStillWins() {
        // Joined the 5:00-6:00 call at 5:20; a short 5:30 call is coming but the long one is on.
        let evs = [ev("Board", 17, 0, 18, 0), ev("Call: quick", 17, 30, 17, 35)]
        #expect(startPick(evs, at(17, 20)) == "Board")
    }

    @Test func afterTheRecordingTheMostOverlapWins() {
        #expect(recPick(backToBack, at(17, 44), at(18, 4)) == "Call: Sam Lee")
        #expect(recPick(backToBack, at(17, 1), at(17, 40)) == "Design review: Northwind")
        // Started 15 min early for the 5:45 call: no match at the start, the right one at the end.
        #expect(recPick([ev("Call: Sam Lee", 17, 45, 18, 0)], at(17, 30), at(18, 0)) == "Call: Sam Lee")
    }

    @Test func noOverlapNoEvent() {
        #expect(recPick(backToBack, at(18, 5), at(18, 30)) == nil)
    }
}
