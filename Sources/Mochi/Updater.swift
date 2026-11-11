import AppKit
import CryptoKit
import Foundation
import MochiKit
import Observation

/// Keeps every Mac on the same Mochi. `release.sh` publishes a zip plus latest.json to the private
/// "releases" bucket of your Supabase project; each Mac asks mochi-api (with its sync key) at
/// launch and every 6 hours, and gets a short-lived download link.
/// An update is installed only when you press Install, never while recording, and only after
/// the download matches its SHA-256 and is signed by the same team as the running app.
@Observable
@MainActor
final class Updater {
    static let shared = Updater()

    struct Release: Decodable, Equatable {
        var version: String
        var build: Int
        var url: URL
        var sha256: String
        var notes: String?
    }

    private(set) var available: Release?
    private(set) var installing = false
    private(set) var error: String?
    private var timer: Timer?

    var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0 }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    func start() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check() }
        }
    }

    /// False when the check itself failed (offline, refused, unreadable reply).
    @discardableResult
    func check() async -> Bool {
        struct Reply: Decodable { var release: Release? }
        guard let json = try? await MochiAPI.call(["action": "latest"], legacyToken: CloudSync.token()),
              let data = try? JSONSerialization.data(withJSONObject: json),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return false }
        available = reply.release.flatMap { $0.build > currentBuild ? $0 : nil }
        return true
    }

    /// Check for Updates in the menu: always says what happened.
    func checkAndTell() async {
        let alert = NSAlert()
        if CloudSync.token() == nil, await Account.shared.email() == nil {
            alert.messageText = "This Mac is not connected yet"
            alert.informativeText = "Sign in to your Mochi account in Settings, then check again."
        } else {
            if !(await check()) {
                alert.messageText = "Mochi could not check for updates"
                alert.informativeText = "The update server did not answer. Check the connection and try again. You have build \(currentBuild)."
            } else if let release = available {
                alert.messageText = "Mochi build \(release.build) is ready"
                alert.informativeText = "Use Install and Relaunch on Today. You have build \(currentBuild)."
            } else {
                alert.messageText = "Mochi is up to date"
                alert.informativeText = "You have the newest build, \(currentBuild)."
            }
        }
        NSApp.activate()
        alert.runModal()
    }

    func install() {
        guard let release = available, !installing else { return }
        guard !AppModel.shared.isRecording else {
            error = "Stop the recording first; Mochi updates between calls."
            return
        }
        installing = true
        error = nil
        Task {
            do {
                try await download(release)
            } catch {
                self.error = error.localizedDescription
                installing = false
            }
        }
    }

    private func download(_ release: Release) async throws {
        await check()   // the link lasts 15 minutes: ask for a fresh one
        // The fresh answer may be a newer build than the banner showed: download and check that
        // one together (checking 234's zip against 233's digest said "damaged").
        let release = available ?? release
        let url = release.url
        let (file, _) = try await URLSession.shared.download(from: url)
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256.lowercased() else { throw Problem("The download was damaged. Try again later.") }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("mochi-update-\(release.build)")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("Mochi.zip")
        try data.write(to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let newApp = work.appendingPathComponent("Mochi.app")
        // Same signer as the running app, or nothing is installed.
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        let mine = try run("/usr/bin/codesign", ["-dv", Bundle.main.bundleURL.path], stderr: true)
        let info = try run("/usr/bin/codesign", ["-dv", newApp.path], stderr: true)
        guard let team = Self.teamID(in: mine), Self.teamID(in: info) == team else {
            throw Problem("The update is not signed by the same team as this Mochi. Not installed.")
        }

        // Swap the bundle once this process has quit, then open the new one.
        let target = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf '\(target).old' && mv '\(target)' '\(target).old' && mv '\(newApp.path)' '\(target)' && rm -rf '\(target).old'
        open '\(target)'
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try task.run()
        NSApp.terminate(nil)
    }

    /// The TeamIdentifier line of `codesign -dv` output. Nil for ad-hoc signatures ("not set"),
    /// so an unsigned build never installs updates.
    private static func teamID(in info: String) -> String? {
        guard let line = info.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else { return nil }
        let id = String(line.dropFirst("TeamIdentifier=".count))
        return id.isEmpty || id == "not set" ? nil : id
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String], stderr: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        if stderr { p.standardError = pipe } else { p.standardOutput = pipe }
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw Problem("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(out.prefix(200))") }
        return out
    }

    struct Problem: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
