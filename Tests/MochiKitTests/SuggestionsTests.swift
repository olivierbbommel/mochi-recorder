import Foundation
import Testing
@testable import MochiKit

// Made-up people and projects only.

private let projects = [
    Project(id: "harbor", name: "Harbor Studio", color: "teal", note: "Documentary edits for a harbour museum"),
    Project(id: "garden", name: "Garden Planner", color: "green"),
]

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

@Test func buildMatchesProjectsAndDropsDuplicates() {
    let open = [TaskItem(text: "Send Dana the edit list", projectID: "harbor")]
    let out = Suggestions.build(tasks: [
        RawSuggestedTask(text: "Send Dana the edit list!", project: "Harbor Studio"),       // already open
        RawSuggestedTask(text: "Book the colour grade", project: "harbor studio", due: "2026-11-07"),
        RawSuggestedTask(text: "Book the colour grade", project: "Harbor Studio"),         // twice
        RawSuggestedTask(text: "Draft the kiosk brief", newProject: "Kiosk App"),
        RawSuggestedTask(text: "Plan the beds", newProject: "garden planner"),             // "new" but exists
        RawSuggestedTask(text: "   ", project: "Harbor Studio"),
    ], updates: [], projects: projects, openTasks: open, calendar: utc)
    #expect(out.map(\.text) == ["Book the colour grade", "Draft the kiosk brief", "Plan the beds"])
    #expect(out[0].projectID == "harbor" && out[0].guessedProjectID == "harbor")
    #expect(out[0].due.map { Suggestions.dayString($0, calendar: utc) } == "2026-11-07")
    #expect(out[1].projectID == nil && out[1].newProjectName == "Kiosk App")
    #expect(out[2].projectID == "garden" && out[2].newProjectName == nil)
    #expect(out.allSatisfy { $0.kind == .add && $0.isPending })
}

@Test func buildCapsNewTasks() {
    let raw = (1...10).map { RawSuggestedTask(text: "Task number \($0)") }
    #expect(Suggestions.build(tasks: raw, updates: [], projects: projects, openTasks: []).count == Suggestions.maxNew)
}

@Test func updatesOnlyForOpenTasksThatChange() {
    let a = TaskItem(text: "Send the quote", status: .todo)
    let b = TaskItem(text: "Call the printer", status: .inProgress)
    let done = TaskItem(text: "Old thing", status: .done)
    let out = Suggestions.build(tasks: [], updates: [
        RawTaskUpdate(taskID: a.id.uuidString.lowercased(), status: "done", why: "Said it went out"),
        RawTaskUpdate(taskID: b.id.uuidString, status: "in-progress"),                     // no change
        RawTaskUpdate(taskID: done.id.uuidString, status: "todo"),                         // not open
        RawTaskUpdate(taskID: "not-a-uuid", status: "done"),
        RawTaskUpdate(taskID: b.id.uuidString, status: "blocked", blockedReason: "Waiting on Leo"),
    ], projects: projects, openTasks: [a, b], calendar: utc)
    #expect(out.count == 2)
    #expect(out[0].taskID == a.id && out[0].status == .done && out[0].text == "Send the quote")
    #expect(out[1].taskID == b.id && out[1].status == .blocked && out[1].blockedReason == "Waiting on Leo")
}

@Test func appliedChangesStatusReasonAndDue() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var task = TaskItem(text: "Call the printer", status: .blocked)
    task.blockedReason = "Old reason"
    let toDone = TaskSuggestion(kind: .update, text: task.text, taskID: task.id, status: .done)
    let done = toDone.applied(to: task, now: now)!
    #expect(done.status == .done && done.doneAt == now && done.blockedReason == nil && done.updatedAt == now)

    let due = Suggestions.day("2026-12-01", calendar: utc)!
    let moved = TaskSuggestion(kind: .update, text: task.text, due: due, taskID: task.id).applied(to: task, now: now)!
    #expect(moved.status == .blocked && moved.due == due && moved.blockedReason == "Old reason")

    #expect(TaskSuggestion(kind: .update, text: task.text, taskID: task.id, status: .blocked).applied(to: task) == nil)
}

@Test func makeTaskLinksCallAndProject() {
    let s = TaskSuggestion(kind: .add, text: "Book the colour grade", projectID: "harbor", due: Date(timeIntervalSince1970: 0))
    let t = s.makeTask(callID: "2026-11-03_101500", projectID: "garden")
    #expect(t.text == "Book the colour grade" && t.callID == "2026-11-03_101500" && t.projectID == "garden")
    #expect(t.due == Date(timeIntervalSince1970: 0) && t.status == .todo && t.source == "mochi")
    #expect(t.notes == nil)
    let why = TaskSuggestion(kind: .add, text: "Send Lena the quote", why: " Lena asked for it by Friday ")
    #expect(why.makeTask(callID: nil, projectID: nil).notes == "Lena asked for it by Friday")
}

@Test func carryOverKeepsDecisions() {
    let added = TaskSuggestion(kind: .add, text: "Book the grade", state: .added)
    let dismissed = TaskSuggestion(kind: .add, text: "Email Tess", state: .dismissed)
    let taskID = UUID()
    let applied = TaskSuggestion(kind: .update, text: "Send quote", taskID: taskID, status: .done, state: .added)
    let waiting = TaskSuggestion(kind: .add, text: "Old waiting one")
    let fresh = [
        TaskSuggestion(kind: .add, text: "book the grade."),
        TaskSuggestion(kind: .add, text: "Email Tess"),
        TaskSuggestion(kind: .update, text: "Send quote", taskID: taskID, status: .done),
        TaskSuggestion(kind: .add, text: "Something new"),
    ]
    let out = Suggestions.carryOver(new: fresh, old: [added, dismissed, applied, waiting])
    #expect(out.map(\.text) == ["Book the grade", "Email Tess", "Send quote", "Something new"])
    #expect(Suggestions.carryOver(new: fresh, old: nil) == fresh)
}

@Test func correctionsComeFromChangedAndMovedTasks() {
    let moved = TaskItem(text: "Plan the beds", projectID: "garden")
    let kept = TaskItem(text: "Book the grade", projectID: "harbor")
    let summary = Summary(text: "x", topics: [], actionItems: [], provider: "Claude", suggestions: [
        // Added in Harbor, later moved to Garden Planner.
        TaskSuggestion(kind: .add, text: "Plan the beds", projectID: "harbor", guessedProjectID: "harbor", state: .added, taskCreated: moved.id),
        TaskSuggestion(kind: .add, text: "Book the grade", projectID: "harbor", guessedProjectID: "harbor", state: .added, taskCreated: kept.id),
        // Chip changed before adding (task since deleted).
        TaskSuggestion(kind: .add, text: "Draft brief", projectID: "harbor", guessedProjectID: nil, state: .added, taskCreated: UUID()),
        TaskSuggestion(kind: .add, text: "Pending one", projectID: "garden", guessedProjectID: "harbor"),
    ])
    let out = Suggestions.corrections([summary], tasks: [moved, kept], projects: projects)
    #expect(out.count == 2)
    #expect(out.contains { $0.text == "Plan the beds" && $0.picked == "Harbor Studio" && $0.chosen == "Garden Planner" })
    #expect(out.contains { $0.text == "Draft brief" && $0.picked == nil && $0.chosen == "Harbor Studio" })
}

@Test func contextListsProjectsTasksAndCorrections() {
    var open = TaskItem(text: "Call the printer", status: .blocked, projectID: "harbor",
                        due: Suggestions.day("2026-11-10", calendar: utc))
    open.blockedReason = "Waiting on Leo"
    let date = ISO8601DateFormatter().date(from: "2026-11-03T10:00:00Z")!
    let text = Suggestions.context(callDate: date, projects: projects, tasks: [open, TaskItem(text: "Done one", status: .done)],
                                   corrections: [("Plan the beds", "Harbor Studio", "Garden Planner")], calendar: utc)
    #expect(text.contains("The call was on Tuesday 2026-11-03."))
    #expect(text.contains("- Harbor Studio: Documentary edits for a harbour museum"))
    #expect(text.contains("- Garden Planner\n"))
    #expect(text.contains("id \(open.id.uuidString.lowercased()) [blocked] Call the printer (project: Harbor Studio) (due 2026-11-10) (waiting on: Waiting on Leo)"))
    #expect(!text.contains("[done]"))
    #expect(text.contains("\"Plan the beds\": they put it in Garden Planner, not Harbor Studio"))
}

@Test func summaryKeepsSuggestionsThroughJSONAndReadsOldFiles() throws {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    let s = Summary(text: "Overview", topics: [], actionItems: [], provider: "Claude",
                    writtenAt: Date(timeIntervalSince1970: 1_800_000_000),
                    suggestions: [TaskSuggestion(kind: .add, text: "Book the grade", newProjectName: "Kiosk App")])
    let back = try d.decode(Summary.self, from: e.encode(s))
    #expect(back == s)
    let old = #"{"text":"Overview","topics":[],"actionItems":[],"provider":"Claude","writtenAt":"2026-11-01T10:00:00Z"}"#
    #expect(try d.decode(Summary.self, from: Data(old.utf8)).suggestions == nil)
    // A suggestion this build cannot read costs only the suggestions, never the summary.
    let odd = #"{"text":"O","topics":[],"actionItems":[],"provider":"Claude","writtenAt":"2026-11-01T10:00:00Z","suggestions":[{"kind":"teleport"}]}"#
    let decoded = try d.decode(Summary.self, from: Data(odd.utf8))
    #expect(decoded.text == "O" && decoded.suggestions == nil)
}

@Test func projectNoteIsOptionalInOldFiles() throws {
    let old = #"[{"id":"harbor","name":"Harbor Studio","color":"teal"}]"#
    let p = try JSONDecoder().decode([Project].self, from: Data(old.utf8))
    #expect(p.first?.note == nil && p.first?.updatedAt == nil)
    #expect(Project.freeColor(in: projects) == "red")
}
