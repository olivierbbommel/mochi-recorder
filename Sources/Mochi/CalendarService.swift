import EventKit
import Foundation
import MochiKit
import Observation

/// A calendar event that looks like a call.
struct Meeting: Identifiable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var appName: String?
    var attendees: [String]
    /// The calendar it is in ("Work", "sam@example.com").
    var calendarName: String
    /// The call link (Meet, Zoom, Teams, FaceTime...) from the event's URL, location or notes.
    var link: URL? = nil

    /// SF Symbol for the app.
    var symbol: String {
        switch appName {
        case "FaceTime", "WhatsApp": "phone.fill"
        default: "video.fill"
        }
    }
}

/// Reads the macOS Calendar (which holds your Google Calendar when it is added in System Settings).
/// Read only: Mochi never writes to a calendar.
@Observable
@MainActor
final class CalendarService {
    private let store = EKEventStore()
    private(set) var authorized = false
    private(set) var meetings: [Meeting] = []

    init() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        if authorized { refresh() }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    func requestAccess() async {
        authorized = (try? await store.requestFullAccessToEvents()) ?? false
        refresh()
    }

    struct Choice: Identifiable, Hashable {
        var id: String
        var title: String
        var account: String
        var included: Bool
    }

    /// Every event calendar on this Mac and whether Mochi reads it. Default: your own calendars;
    /// subscribed, birthday and read-only (someone else's, shared to you) calendars are off.
    var choices: [Choice] {
        let overrides = UserDefaults.standard.dictionary(forKey: "calendarChoices") as? [String: Bool] ?? [:]
        return store.calendars(for: .event).map { c in
            Choice(id: c.calendarIdentifier, title: c.title, account: c.source?.title ?? "Other",
                   included: overrides[c.calendarIdentifier] ?? Self.includedByDefault(c))
        }
        .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    static func includedByDefault(_ c: EKCalendar) -> Bool {
        c.type != .subscription && c.type != .birthday && c.allowsContentModifications
    }

    func setIncluded(_ id: String, _ on: Bool) {
        var overrides = UserDefaults.standard.dictionary(forKey: "calendarChoices") as? [String: Bool] ?? [:]
        overrides[id] = on
        UserDefaults.standard.set(overrides, forKey: "calendarChoices")
        refresh()
    }

    /// The next 7 days, events with a call link or a call-like title, no all-day events, only from
    /// the calendars chosen in Settings, and not the ones you declined.
    func refresh() {
        guard authorized else { meetings = []; return }
        let start = Date().addingTimeInterval(-3600)
        let end = Calendar.current.date(byAdding: .day, value: 7, to: Date())!
        guard let found = callEvents(from: start, to: end) else {
            if !meetings.isEmpty { meetings = []; CloudSync.shared.eventsChanged() }
            return
        }
        let fresh = found.filter { $0.end > Date() }
        // Refreshed every minute for the reminders: push to the cloud only when something changed.
        guard fresh != meetings else { return }
        meetings = fresh
        CloudSync.shared.eventsChanged()
        onChange?()
    }

    /// Runs after the meetings changed (a recording re-checks its title).
    var onChange: (() -> Void)?

    /// Call-like events between two dates from the chosen calendars, not declined, by start.
    /// nil when no calendar is chosen.
    private func callEvents(from start: Date, to end: Date) -> [Meeting]? {
        let chosen = Set(choices.filter(\.included).map(\.id))
        let calendars = store.calendars(for: .event).filter { chosen.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return nil }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .filter { e in !(e.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined } }
            .compactMap(Self.meeting).sorted { $0.start < $1.start }
    }

    /// Asks the calendar accounts (your Google Calendar) to fetch now instead of at their next
    /// scheduled refresh, so an event added a minute ago shows up. EventKit posts
    /// EKEventStoreChanged when new events land, and `refresh` runs then.
    func syncNow() {
        guard authorized else { return }
        store.refreshSourcesIfNecessary()
    }

    /// The calendars Mochi reads, by account: "Google: sam@..., iCloud: Home".
    var sourceSummary: String {
        let calendars = store.calendars(for: .event)
        let accounts = Set(calendars.compactMap { $0.source?.title }).sorted()
        return accounts.isEmpty ? "macOS Calendar" : accounts.joined(separator: ", ")
    }

    /// The meeting a recording starting now belongs to. Back to back, the one about to start
    /// beats the one ending (see EventMatch).
    func eventNow() -> Meeting? {
        EventMatch.atStart(meetings, now: Date(), start: \.start, end: \.end)
    }

    /// The meeting a finished recording overlapped most, read fresh from the calendar (events
    /// that already ended are no longer in `meetings`).
    func event(forRecordingFrom start: Date, to end: Date) -> Meeting? {
        guard authorized, let events = callEvents(from: start.addingTimeInterval(-6 * 3600), to: end.addingTimeInterval(3600))
        else { return nil }
        return EventMatch.forRecording(events, from: start, to: end, start: \.start, end: \.end)
    }

    static func meeting(_ e: EKEvent) -> Meeting? {
        guard !e.isAllDay, let id = e.eventIdentifier else { return nil }
        let text = [e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
        let app: String? =
            text.contains("meet.google.com") ? "Google Meet" :
            text.contains("zoom.us") ? "Zoom" :
            text.contains("facetime.apple.com") ? "FaceTime" :
            text.contains("teams.microsoft.com") ? "Teams" :
            text.contains("wa.me") || text.contains("whatsapp") ? "WhatsApp" : nil
        let title = e.title ?? "Untitled"
        let lower = title.lowercased()
        guard app != nil || lower.contains("call") || lower.contains("bellen") else { return nil }
        let names = (e.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { $0.name?.components(separatedBy: " ").first }
        return Meeting(id: id, title: title, start: e.startDate, end: e.endDate, appName: app, attendees: names,
                       calendarName: e.calendar?.title ?? "Calendar",
                       link: callLink(in: [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }))
    }

    private static let callHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
                                    "facetime.apple.com", "webex.com", "whereby.com", "wa.me"]

    /// The first web link to a call service in these texts, in order (the event URL wins).
    static func callLink(in texts: [String]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, let host = url.host?.lowercased(),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                if callHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }
}
