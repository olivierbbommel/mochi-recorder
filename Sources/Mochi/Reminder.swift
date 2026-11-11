import AppKit
import MochiKit
import Observation
import SwiftUI

/// The meeting reminder: a small floating card at the top right a set time before a meeting with a
/// call link (like Spark's), with Join, Start Recording, Copy Link, Snooze and Open Calendar.
/// A non-activating panel like the pill, so it never takes the keyboard from the app in front, and
/// hidden from screen sharing.
@Observable
@MainActor
final class ReminderController {
    static let shared = ReminderController()

    /// The meeting on the card now, nil when hidden.
    private(set) var meeting: Meeting?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    /// Closed (X, Join, Start Recording) for good, and snoozed until a time, by meeting id.
    @ObservationIgnored private var dismissed: Set<String> = []
    @ObservationIgnored private var snoozed: [String: Date] = [:]
    /// Dev runs: a made-up meeting (MOCHI_FAKE_MEETING=seconds until it starts).
    @ObservationIgnored var fake: Meeting?

    static let width: CGFloat = 560
    static let height: CGFloat = 84

    /// Minutes before the start: -1 off, 0 at the start. Default 1, like Spark.
    static var lead: Int { UserDefaults.standard.object(forKey: "remindBefore") as? Int ?? 1 }
    static var recordOnJoin: Bool { UserDefaults.standard.object(forKey: "recordOnJoin") as? Bool ?? true }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    private func check() {
        tick += 1
        let model = AppModel.shared
        // Meetings go stale (an event moved, a new one added on the phone): re-read every minute.
        // Also ask the calendar accounts to fetch, so an event added in Notion Calendar or on the
        // phone shows up in about a minute rather than at macOS's own next refresh.
        if tick % 30 == 0 { model.calendar.syncNow(); model.calendar.refresh() }
        let next = due(in: (fake.map { [$0] } ?? []) + model.calendar.meetings, now: Date(), model: model)
        if next?.id != meeting?.id { show(next) }
    }

    /// The earliest meeting whose reminder time has come and that is not over for the card yet.
    private func due(in meetings: [Meeting], now: Date, model: AppModel) -> Meeting? {
        let lead = Self.lead
        guard lead >= 0 else { return nil }
        return meetings.sorted { $0.start < $1.start }.first { m in
            guard !dismissed.contains(m.id), now >= m.start.addingTimeInterval(-Double(lead) * 60 - 1),
                  now < m.start.addingTimeInterval(5 * 60), m.end > now else { return false }
            if let until = snoozed[m.id], until > now { return false }
            // Never while that meeting is being recorded.
            return model.session?.call.eventID != m.id
        }
    }

    private func show(_ next: Meeting?) {
        withAnimation(.spring(duration: 0.35)) { meeting = next }
        guard next != nil else {
            // Let the card fade out before the panel goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.meeting == nil { self?.panel?.orderOut(nil) }
            }
            return
        }
        if panel == nil { panel = makePanel() }
        place()
        panel?.orderFrontRegardless()
        if let panel { DevHooks.backdrop(behind: panel) }
    }

    /// Top right, under the menu bar; below the recording pill when it is up.
    private func place() {
        guard let panel, let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let below = AppModel.shared.isRecording && PillController.shared.enabled ? 72.0 : 0
        panel.setFrameOrigin(NSPoint(x: v.maxX - Self.width - 10, y: v.maxY - Self.height - 6 - below))
    }

    func close() {
        if let id = meeting?.id { dismissed.insert(id) }
        show(nil)
    }

    func snooze(_ meeting: Meeting, until date: Date) {
        snoozed[meeting.id] = date
        show(nil)
    }

    func join(_ meeting: Meeting) {
        if let link = meeting.link { NSWorkspace.shared.open(link) }
        if Self.recordOnJoin, !AppModel.shared.isRecording { AppModel.shared.startRecording(event: meeting) }
        close()
    }

    func record(_ meeting: Meeting) {
        AppModel.shared.startRecording(event: meeting)
        close()
    }

    func openCalendar(_ meeting: Meeting) {
        // Calendar shows the event for its id; for a made-up or vanished event it just opens.
        if let url = URL(string: "ical://ekevent/\(meeting.id)?method=show&options=more"),
           !meeting.id.hasPrefix("fake-"), NSWorkspace.shared.open(url) { return }
        if let calendar = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: calendar, configuration: .init())
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        // A meeting title is private: keep the card out of screen shares (not out of review captures).
        if ProcessInfo.processInfo.environment["MOCHI_CAPTURE"] == nil { panel.sharingType = .none }
        panel.setAccessibilityLabel("Mochi meeting reminder")
        let host = PillHostingView(rootView: AnyView(ReminderPanelView().environment(AppModel.shared).environment(\.controlActiveState, .key).environment(\.appearsActive, true)))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// The Settings window, from a panel that is not part of the main window's scene.
    static func openSettings() {
        NSApp.activate()
        // showSettingsWindow: no longer opens SwiftUI's Settings scene; press the menu item.
        if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }),
           let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }
}

struct ReminderPanelView: View {
    private var controller: ReminderController { .shared }

    var body: some View {
        VStack(alignment: .trailing) {
            if let meeting = controller.meeting {
                ReminderCard(meeting: meeting)
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: ReminderController.width, height: ReminderController.height, alignment: .topTrailing)
    }
}

/// The card, in the pill's language: one glass capsule, the Mochi icon with a ring counting down
/// to the start, the title, who is in it, a red Record and a Join. Everything else in "…".
struct ReminderCard: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    @State private var hovering = false
    private var controller: ReminderController { .shared }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                CountdownIcon(start: meeting.start, now: context.date)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    // The countdown leads the second line, so a long title never cuts it off.
                    HStack(spacing: 0) {
                        Text(Self.countdown(meeting.start, now: context.date))
                            .foregroundStyle(meeting.start > context.date ? Color.accentColor : .red)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                        if let detail = Self.detail(meeting) {
                            Text(" · " + detail).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12))
                    .lineLimit(1)
                }
                .frame(maxWidth: 230, alignment: .leading)
                Button { controller.record(meeting) } label: {
                    Label("Record", systemImage: "record.circle.fill")
                }
                .buttonStyle(SolidButtonStyle(color: .red))
                .disabled(model.isRecording)
                .help("Start recording this meeting")
                if meeting.link != nil {
                    Button("Join") { controller.join(meeting) }
                        .buttonStyle(.glass)
                        .help(ReminderController.recordOnJoin ? "Open the call and start recording" : "Open the call")
                }
                Button { moreMenu() } label: {
                    Image(systemName: "ellipsis").frame(width: 14, height: 14)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Snooze, copy link, open in Calendar")
            }
            .controlSize(.large)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 60)
            .glassEffect(.regular, in: .capsule)
            .overlay(alignment: .topLeading) {
                // Close, like a notification: a small x that shows on hover.
                if hovering {
                    Button { controller.close() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .frame(width: 20, height: 20)
                            .glassEffect(.regular, in: .circle)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: -4, y: -4)
                    .help("Close")
                    .accessibilityLabel("Close")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .onHover { inside in withAnimation(.snappy(duration: 0.18)) { hovering = inside } }
    }

    /// "in 46 s", "in 3 min", "starting now", "started 3 min ago".
    static func countdown(_ start: Date, now: Date) -> String {
        let s = Int(start.timeIntervalSince(now).rounded())
        if s > 90 { return "in \(Int((Double(s) / 60).rounded(.up))) min" }
        if s > 1 { return "in \(s) s" }
        if s >= -59 { return "starting now" }
        return "started \(-s / 60) min ago"
    }

    /// "Google Meet · with Dana, Leo +5"
    static func detail(_ m: Meeting) -> String? {
        var parts: [String] = []
        if let app = m.appName { parts.append(app) }
        if !m.attendees.isEmpty {
            let shown = m.attendees.prefix(2).joined(separator: ", ")
            parts.append("with \(shown)" + (m.attendees.count > 2 ? " +\(m.attendees.count - 2)" : ""))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func moreMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ run: @escaping () -> Void) {
            let action = MenuAction(run)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            item.target = action
            item.representedObject = action   // keeps the target alive while the menu is open
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        let m = meeting
        add("Remind Me in 1 Minute", "clock") { ReminderController.shared.snooze(m, until: Date().addingTimeInterval(60)) }
        add("Remind Me in 5 Minutes", "clock") { ReminderController.shared.snooze(m, until: Date().addingTimeInterval(300)) }
        if m.start.timeIntervalSinceNow > 60 {
            add("Remind Me When It Starts", "bell") { ReminderController.shared.snooze(m, until: m.start) }
        }
        menu.addItem(.separator())
        if let link = m.link {
            add("Copy Meeting Link", "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
            }
        }
        add("Open in Calendar", "calendar") { ReminderController.shared.openCalendar(m) }
        menu.addItem(.separator())
        add("Reminder Settings…", "gearshape") { ReminderController.openSettings() }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// The Mochi icon in a ring that empties as the meeting comes closer (full at the reminder, gone at
/// the start), then a red ring once it has started.
struct CountdownIcon: View {
    let start: Date
    let now: Date

    var body: some View {
        let lead = Double(max(ReminderController.lead, 1)) * 60
        let left = start.timeIntervalSince(now)
        let progress = max(0, min(1, left / lead))
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: left > 0 ? progress : 1)
                .stroke(left > 0 ? Color.accentColor : .red, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 34, height: 34)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

/// An NSMenuItem target that runs a closure.
final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
