import Carbon.HIToolbox
import Foundation
import MochiCapture

/// Asks "Meeting detected, record?" when a call app has held the mic for 8 s and Mochi is not
/// recording. Never starts a recording on its own. Read only: it looks at Core Audio's process list.
@MainActor
final class CallWatcher {
    static let shared = CallWatcher()
    private var timer: Timer?
    private var heldSince: Date?
    private var asked: CallApp?
    private var snoozedApp: CallApp?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { CallWatcher.shared.check() }
        }
    }

    func snooze() {
        snoozedApp = asked ?? AppModel.shared.detectedApp
        AppModel.shared.detectedApp = nil
    }

    private func check() {
        let model = AppModel.shared
        guard !model.isRecording, let app = CallApp.capturingNow() else {
            heldSince = nil
            model.detectedApp = nil
            if CallApp.capturingNow() == nil { asked = nil; snoozedApp = nil }
            return
        }
        heldSince = heldSince ?? Date()
        guard Date().timeIntervalSince(heldSince!) >= 8 else { return }
        if snoozedApp != app { model.detectedApp = app }
        guard asked != app, snoozedApp != app else { return }
        asked = app
        Notifier.meetingDetected(app: app.name, event: model.calendar.eventNow()?.title)
    }
}

/// The global start/stop hotkey, ⌃⌥R, and pause, ⌃⌥P, as Carbon hot keys (work from any app,
/// need no Accessibility permission).
enum HotKeys {
    nonisolated(unsafe) private static var refs: [EventHotKeyRef?] = []

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if id.id == 1 { AppModel.shared.toggleRecording() } else { AppModel.shared.togglePause() }
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        for (n, key) in [(UInt32(1), UInt32(kVK_ANSI_R)), (2, UInt32(kVK_ANSI_P))] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(key, UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x4D4F4348), id: n),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}
