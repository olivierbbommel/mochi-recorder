import Foundation

/// Picks the calendar event a recording belongs to.
///
/// Back-to-back meetings are the hard case: at 5:44 a call that runs 5:00-5:45 and one that runs
/// 5:45-6:00 both "contain" the moment, and the one about to start is nearly always the call.
/// So events are scored by how much of them falls inside the window (the next 15 minutes when
/// recording starts, the whole recording once it stops), and ties go to the event whose start is
/// nearest the recording's start.
public enum EventMatch {
    /// How far ahead the start of a recording looks: a call that starts within this window
    /// is the one being joined early.
    public static let lookAhead: TimeInterval = 15 * 60
    /// Joining up to this much before an event's start still counts as that event.
    public static let earlyJoin: TimeInterval = 10 * 60

    /// The event for a recording that starts at `now`.
    public static func atStart<T>(_ events: [T], now: Date, start: (T) -> Date, end: (T) -> Date) -> T? {
        best(events, from: now, to: now.addingTimeInterval(lookAhead), startsBy: now.addingTimeInterval(earlyJoin),
             start: start, end: end)
    }

    /// The event for a finished recording: the one it overlapped most.
    public static func forRecording<T>(_ events: [T], from: Date, to: Date, start: (T) -> Date, end: (T) -> Date) -> T? {
        best(events, from: from, to: max(to, from.addingTimeInterval(60)),
             startsBy: max(to, from.addingTimeInterval(earlyJoin)), start: start, end: end)
    }

    static func best<T>(_ events: [T], from: Date, to: Date, startsBy: Date,
                        start: (T) -> Date, end: (T) -> Date) -> T? {
        var winner: (event: T, overlap: TimeInterval, distance: TimeInterval)?
        for e in events {
            let s = start(e), en = end(e)
            guard s <= startsBy, en > from else { continue }
            let overlap = min(en, to).timeIntervalSince(max(s, from))
            guard overlap > 0 else { continue }
            let distance = abs(s.timeIntervalSince(from))
            if let w = winner {
                // Within a minute counts as a tie: then the nearer start wins.
                if overlap > w.overlap + 60 || (abs(overlap - w.overlap) <= 60 && distance < w.distance) {
                    winner = (e, overlap, distance)
                }
            } else {
                winner = (e, overlap, distance)
            }
        }
        return winner?.event
    }
}
