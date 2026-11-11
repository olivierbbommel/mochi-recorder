import AppKit
import AVFoundation
import MochiKit
import SwiftUI

@main
struct MochiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @AppStorage("showMenuBar") private var showMenuBar = true
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Mochi", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)
        .commands { MochiCommands(model: model) }

        Window("Welcome to Mochi", id: "welcome") {
            WelcomeView().environment(model)
        }
        .windowResizability(.contentSize)
        // Opened on first launch (or from Help) only; never restored or opened with the app.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)

        Settings {
            SettingsView().environment(model)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent().environment(model)
        } label: {
            MenuBarLabel(recording: model.isRecording, paused: model.session?.paused ?? false,
                         health: model.session?.health,
                         timer: model.session.map { TranscriptText.clock($0.savedSeconds) })
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The sign-in link from the email: mochi://auth#access_token=...
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "mochi" {
            Task { @MainActor in
                do {
                    try await Account.shared.handle(url)
                    await CloudSync.shared.refreshAccount()
                    CloudSync.shared.start()
                    _ = await Updater.shared.check()
                    NotificationCenter.default.post(name: .accountChanged, object: nil)
                } catch {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.setUp()
        HotKeys.register()
        MainActor.assumeIsolated {
            DevHooks.apply()
            CallWatcher.shared.start()
            ReminderController.shared.start()
            Task {
                await CloudSync.shared.refreshAccount()
                CloudSync.shared.start()
            }
            Updater.shared.start()
            if !UserDefaults.standard.bool(forKey: "didFinishWelcome") {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .showWelcome, object: nil)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppModel.shared.isRecording else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Stop recording and quit?"
            alert.informativeText = "The recording so far is kept."
            alert.addButton(withTitle: "Keep Recording")
            alert.addButton(withTitle: "Stop and Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            // Quit only once mic.wav and them.wav are closed (a fixed delay could cut them short),
            // with a backstop so a stuck device cannot block quitting.
            var replied = false
            let reply = { if !replied { replied = true; NSApp.reply(toApplicationShouldTerminate: true) } }
            AppModel.shared.stopRecording(closed: reply)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: reply)
            return .terminateLater
        }
    }
}

extension Notification.Name {
    static let showWelcome = Notification.Name("MochiShowWelcome")
    static let accountChanged = Notification.Name("MochiAccountChanged")
}

enum CapturePermission {
    static var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var microphoneDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        return s == .denied || s == .restricted
    }

    static func requestMicrophone() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct MochiCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Task") {
                model.section = .tasks
                _ = model.addTask()
            }
            .keyboardShortcut("n")
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Transcript") {
                if let id = model.session?.call.id ?? model.selectedCallID { model.copyTranscript(id) }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.session == nil && model.selectedCallID == nil)
        }
        CommandMenu("Recording") {
            Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording() }
                .keyboardShortcut("r", modifiers: [.control, .option])
            Button(model.session?.paused == true ? "Resume" : "Pause") { model.togglePause() }
                .keyboardShortcut("p", modifiers: [.control, .option])
                .disabled(!model.isRecording)
            Button("Keep Recording") { model.keepRecording() }
                .disabled(model.session?.endedCountdown == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Today") { model.section = .today }.keyboardShortcut("1")
            Button("Upcoming") { model.section = .upcoming }.keyboardShortcut("2")
            Button("Calls") { model.section = .calls }.keyboardShortcut("3")
            Button("Tasks") { model.section = .tasks }.keyboardShortcut("4")
            Divider()
        }
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await Updater.shared.checkAndTell() } }
        }
        CommandGroup(replacing: .help) {
            WelcomeMenuButton()
        }
    }
}

struct WelcomeMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Welcome to Mochi") { openWindow(id: "welcome") }
    }
}
