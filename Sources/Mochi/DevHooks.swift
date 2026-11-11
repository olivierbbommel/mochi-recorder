import AppKit
import MochiCapture
import MochiKit

/// Screenshot and review runs only: environment variables that set the appearance and the screen
/// shown at launch. Ignored in normal use (none of them is set).
@MainActor
enum DevHooks {
    static func apply() {
        let env = ProcessInfo.processInfo.environment
        if let look = env["MOCHI_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        let model = AppModel.shared
        switch env["MOCHI_SECTION"] {
        case "upcoming": model.section = .upcoming
        case "calls": model.section = .calls
        case "tasks": model.section = .tasks
        case "work": model.section = .project("work")
        default: break
        }
        if let bundle = env["MOCHI_AUTOSTART_APP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                model.startRecording(app: CallApp(name: "Test app", bundlePrefix: bundle))
            }
            // The made-up call app never uses audio, so "Call ended?" would fire: hold it off.
            if env["MOCHI_KEEP"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.keepRecording() }
            }
            if let after = env["MOCHI_AUTOSTOP_AFTER"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + after) { model.stopRecording() }
            }
        }
        // A made-up meeting for the reminder card, starting in this many seconds.
        if let seconds = env["MOCHI_FAKE_MEETING"].flatMap(Double.init) {
            let names = (env["MOCHI_FAKE_ATTENDEES"] ?? "Dana,Leo,Tess,Mira,Sam,Ivo,Noor").split(separator: ",").map(String.init)
            ReminderController.shared.fake = Meeting(
                id: "fake-1", title: env["MOCHI_FAKE_TITLE"] ?? "Kick-off: Garden Planner Redesign",
                start: Date().addingTimeInterval(seconds), end: Date().addingTimeInterval(seconds + 1800),
                appName: "Google Meet", attendees: names, calendarName: "Work",
                link: env["MOCHI_FAKE_NOLINK"] == nil ? URL(string: "https://meet.google.com/abc-defg-hij") : nil)
        }
        if env["MOCHI_TUCKED"] != nil { PillController.shared.tucked = env["MOCHI_TUCKED"] == "1" }
        if let id = env["MOCHI_CALL"], !id.isEmpty { model.selectedCallID = id }
        // Opens this task in place for editing, like a double-click (list or board, per taskLayout).
        if let id = env["MOCHI_EDIT_TASK"].flatMap(UUID.init(uuidString:)) { model.newTaskID = id }
        if let id = env["MOCHI_SUMMARIZE"], !id.isEmpty { model.summarize(id) }
        if env["MOCHI_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.activate(ignoringOtherApps: true)
                // showSettingsWindow: no longer opens SwiftUI's Settings scene; press the menu item.
                if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }),
                   let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                }
            }
        }
        if env["MOCHI_SECTION"] != nil {
            // Screenshots need the active window look (red buttons, coloured traffic lights).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.title == "Mochi" }?.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Review captures only (MOCHI_CAPTURE): a plain wallpaper-like window just behind a floating
    /// panel, so captures show the glass over a neutral desktop instead of whatever is on screen.
    private static var backdrops: [ObjectIdentifier: NSWindow] = [:]
    static func backdrop(behind panel: NSWindow) {
        guard ProcessInfo.processInfo.environment["MOCHI_CAPTURE"] != nil else { return }
        let window = backdrops[ObjectIdentifier(panel)] ?? {
            let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = panel.level
            w.ignoresMouseEvents = true
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let view = NSView()
            view.wantsLayer = true
            let gradient = CAGradientLayer()
            gradient.colors = dark ? [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 1).cgColor,
                                      NSColor(calibratedRed: 0.22, green: 0.16, blue: 0.26, alpha: 1).cgColor]
                                   : [NSColor(calibratedRed: 0.80, green: 0.87, blue: 0.95, alpha: 1).cgColor,
                                      NSColor(calibratedRed: 0.95, green: 0.88, blue: 0.84, alpha: 1).cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 0)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            view.layer = gradient
            w.contentView = view
            backdrops[ObjectIdentifier(panel)] = w
            return w
        }()
        window.setFrame(panel.frame.insetBy(dx: -24, dy: -24), display: true)
        window.order(.below, relativeTo: panel.windowNumber)
    }
}
