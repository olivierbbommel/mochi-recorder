import Foundation
import MochiKit
import Security

/// Writes a call summary with Claude: a short summary, decisions, and suggested tasks for review.
/// Raw HTTP (there is no official Swift SDK). What leaves the Mac, and only when summaries are on:
/// the transcript text, the call's title, and for the suggestions your project names and notes and
/// the text of your open and recent tasks.
enum Summarizer {
    static let model = "claude-opus-5-5"

    enum Failure: LocalizedError {
        case noKey, http(Int, String), refused, unreadable
        var errorDescription: String? {
            switch self {
            case .noKey: "No Claude API key. Add one in Settings."
            case .http(let code, let body): "Claude returned \(code): \(body.prefix(160))"
            case .refused: "Claude declined to summarise this call."
            case .unreadable: "The summary came back in a form Mochi could not read."
            }
        }
    }

    /// The key old Mochi stored: Keychain service "mochi", account "ANTHROPIC_API_KEY".
    static func apiKey() -> String? {
        // Demo and test runs never read the Keychain; a review run can pass a key in the environment.
        guard !CloudSync.isDemoRun else {
            return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "mochi",
                                    kSecAttrAccount as String: "ANTHROPIC_API_KEY",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func saveKey(_ key: String) {
        guard !CloudSync.isDemoRun else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "mochi",
                                   kSecAttrAccount as String: "ANTHROPIC_API_KEY"]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["overview", "topics", "action_items", "tasks", "task_updates"],
        "properties": [
            "overview": ["type": "string"],
            "topics": ["type": "array", "items": [
                "type": "object",
                "additionalProperties": false,
                "required": ["title", "lead", "points"],
                "properties": [
                    "title": ["type": "string"],
                    "lead": ["type": "string"],
                    "points": ["type": "array", "items": ["type": "string"]],
                ],
            ]],
            "action_items": ["type": "array", "items": [
                "type": "object",
                "additionalProperties": false,
                "required": ["owner", "items"],
                "properties": [
                    "owner": ["type": "string"],
                    "items": ["type": "array", "items": ["type": "string"]],
                ],
            ]],
            "tasks": ["type": "array", "items": [
                "type": "object",
                "additionalProperties": false,
                "required": ["text", "project", "new_project", "due", "why"],
                "properties": [
                    "text": ["type": "string"],
                    "project": ["type": "string"],
                    "new_project": ["type": "string"],
                    "due": ["type": "string"],
                    "why": ["type": "string"],
                ],
            ]],
            "task_updates": ["type": "array", "items": [
                "type": "object",
                "additionalProperties": false,
                "required": ["task_id", "status", "blocked_reason", "due", "why"],
                "properties": [
                    "task_id": ["type": "string"],
                    "status": ["type": "string", "enum": ["", "todo", "in-progress", "blocked", "done"]],
                    "blocked_reason": ["type": "string"],
                    "due": ["type": "string"],
                    "why": ["type": "string"],
                ],
            ]],
        ],
    ]

    /// Rebuilt per call so a changed name in Settings takes effect at once.
    private static var system: String {
    let me = OwnerName.name
    return """
    You write meeting summaries for the person who recorded the call. \
    "Me" in the transcript is them; call them \(me) in owners and points. Other labels are the people on the \
    other side: a name when Mochi knows the voice, "Speaker 2" and so on when it does not (use a name for them \
    only when the conversation makes it clear), or "Them" for the whole other side. The transcript comes from \
    speech recognition, so fix obvious recognition mistakes silently.

    Write it the way Spark's meeting notes do:
    overview: one sentence that says what the meeting achieved and the key dates or next steps.
    topics: 2 to 6 key-point topics in the order they came up (fewer for a short call). Each has a short title \
    (3 to 5 words, Title Case), a lead (one sentence summing up the topic), and 2 to 6 points: complete, \
    specific sentences with names, numbers and dates kept.
    action_items: grouped by person (owner = first name, "\(me)" for the person who recorded it), each item a short imperative \
    sentence ("Send the template deck by Monday."). Only real commitments. Empty for a call without any.

    Then suggest tasks for \(me) to review. The first message part lists their projects, their open tasks and \
    the call's date.
    tasks: only things \(me) has to do after this call (never tasks for other people). 0 to 6, none is \
    fine. Each text is short: a verb first, at most 8 words ("Send Lena the revised quote"). Skip anything their \
    open tasks already cover.
    project: the exact name of the one project it belongs to, judged from the project notes, their recent tasks, \
    the meeting title and what was said, and from the corrections they made before. "" when none clearly fits.
    new_project: only when no project fits and the call is clearly about a new client or a new piece of ongoing \
    work that will need more tasks: a short name (1 to 3 words). Otherwise "". Never both project and new_project.
    due: "YYYY-MM-DD" when a day was said or clearly implied, counted from the call's date ("by Friday" is the \
    coming Friday). Otherwise "".
    why: a few words from the call on where it came from ("Lena asked for it by Friday"), or "".
    task_updates: changes this call makes clear for their open tasks, by their id: "done" when they say it is done \
    or sent, "in-progress" when they have started, "blocked" with blocked_reason (what or who it waits on) when it \
    is stuck, and due when a new deadline was agreed (status "" when only the deadline changes). Go through \
    every open task against the call: include a change whenever the call says it, even in passing ("I sent that \
    yesterday" is done). Leave out only guesses.

    Write in the language most of the call was in. Never use em dashes; use commas, colons or full stops.
    """
    }

    struct Output: Decodable {
        struct Topic: Decodable { var title: String; var lead: String; var points: [String] }
        struct Owner: Decodable { var owner: String; var items: [String] }
        var overview: String
        var topics: [Topic]
        struct NewTask: Decodable { var text: String; var project: String; var new_project: String; var due: String; var why: String }
        struct Update: Decodable { var task_id: String; var status: String; var blocked_reason: String; var due: String; var why: String }
        var action_items: [Owner]
        var tasks: [NewTask]?
        var task_updates: [Update]?
    }

    /// `context` is Suggestions.context(...): your projects, open tasks and corrections, sent before
    /// the transcript so the suggested tasks fit what you already have.
    static func summarize(call: Call, segments: [Segment], context: String, projects: [Project],
                          openTasks: [TaskItem]) async throws -> Summary {
        guard let key = apiKey() else { throw Failure.noKey }
        let transcript = TranscriptText.copyText(call: call, segments: segments)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
            // On a safety decline the API retries on a fallback model inside the same call.
            "fallbacks": "default",
            "messages": [["role": "user", "content": [
                ["type": "text", "text": context],
                ["type": "text", "text": "# The transcript\n\n" + transcript],
            ]]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status, String(decoding: data, as: UTF8.self)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        if json["stop_reason"] as? String == "refusal" { throw Failure.refused }
        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard let out = try? JSONDecoder().decode(Output.self, from: Data(text.utf8)) else { throw Failure.unreadable }
        let suggestions = Suggestions.build(
            tasks: (out.tasks ?? []).map { RawSuggestedTask(text: $0.text, project: $0.project, newProject: $0.new_project,
                                                            due: $0.due, why: $0.why) },
            updates: (out.task_updates ?? []).map { RawTaskUpdate(taskID: $0.task_id, status: $0.status,
                                                                  blockedReason: $0.blocked_reason, due: $0.due, why: $0.why) },
            projects: projects, openTasks: openTasks)
        return Summary(text: out.overview,
                       topics: out.topics.map { Summary.Topic(title: $0.title, lead: $0.lead, points: $0.points) },
                       actionItems: out.action_items.filter { !$0.items.isEmpty }
                           .map { Summary.Owner(name: $0.owner, items: $0.items) },
                       provider: "Claude", suggestions: suggestions)
    }
}
