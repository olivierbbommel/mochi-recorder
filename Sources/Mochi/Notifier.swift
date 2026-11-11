import AppKit
import MochiKit
import UserNotifications

/// Banners: Meeting detected, Call ended?, Recording saved. Permission is asked the first time a
/// call app starts using the mic, not at launch.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "meetingDetected", actions: [
                UNNotificationAction(identifier: "record", title: "Record"),
                UNNotificationAction(identifier: "notNow", title: "Not Now"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "callEnded", actions: [
                UNNotificationAction(identifier: "keep", title: "Keep Recording"),
                UNNotificationAction(identifier: "stop", title: "Stop"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "recordingSaved", actions: [
                UNNotificationAction(identifier: "copy", title: "Copy Transcript"),
                UNNotificationAction(identifier: "open", title: "Open", options: .foreground),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "suggestedTasks", actions: [
                UNNotificationAction(identifier: "review", title: "Review", options: .foreground),
            ], intentIdentifiers: []),
        ])
    }

    private func post(_ category: String, title: String, body: String, info: [String: String] = [:],
                      sensitive: Bool = false) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            content.userInfo = info
            content.threadIdentifier = category
            if sensitive { content.interruptionLevel = .timeSensitive }
            self.center.add(UNNotificationRequest(identifier: category, content: content, trigger: nil))
        }
    }

    static func meetingDetected(app: String, event: String?) {
        shared.post("meetingDetected", title: "Meeting detected",
                    body: event.map { "\(app) is using your mic. Record \($0)?" } ?? "\(app) is using your mic. Record this call?")
    }

    static func callEnded(app: String) {
        shared.post("callEnded", title: "Call ended?",
                    body: "\(app) stopped using audio. Mochi stops recording in 60 seconds.", sensitive: true)
    }

    static func saved(_ call: Call) {
        let sides = call.micOnly ? "your side only" : "both sides"
        shared.post("recordingSaved", title: "Recording saved",
                    body: "\(call.title), \(TranscriptText.duration(call.duration)), \(sides). The transcript is being finished.",
                    info: ["call": call.id])
    }

    /// After a summary: tasks are waiting for your review (they are never added on their own).
    static func suggestions(_ count: Int, call: Call) {
        shared.post("suggestedTasks", title: count == 1 ? "1 task to review" : "\(count) tasks to review",
                    body: "From \(call.title). Add the ones you want in Tasks.", info: ["call": call.id, "review": "1"])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner] }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let callID = response.notification.request.content.userInfo["call"] as? String
        await MainActor.run {
            let model = AppModel.shared
            switch response.actionIdentifier {
            case "record": model.startRecording()
            case "notNow": CallWatcher.shared.snooze()
            case "keep": model.keepRecording()
            case "stop": model.stopRecording()
            case "copy": if let callID { model.copyTranscript(callID) }
            case "review":
                model.section = .tasks
                NSApp.activate()
            case "open", UNNotificationDefaultActionIdentifier:
                if response.notification.request.content.categoryIdentifier == "suggestedTasks" {
                    model.section = .tasks
                } else if let callID { model.selectedCallID = callID; model.section = .calls }
                NSApp.activate()
            default: break
            }
        }
    }
}
