import Foundation

/// Your own backend, read from the app's Info.plist. `build.sh` fills these in from `mochi.env`
/// (see README, "Sync and the Claude connector"). Left empty, Mochi runs local only: recording,
/// transcripts, summaries, tasks and projects all work, and sync, sign-in and updates stay off.
public enum MochiConfig {
    /// Your Supabase project, e.g. https://<project ref>.supabase.co
    public static let supabaseURL: URL? = {
        guard let s = value("MochiSupabaseURL"), let url = URL(string: s), url.scheme == "https" else { return nil }
        return url
    }()

    /// The project's publishable key: public by design, it only lets a device ask for a sign-in link.
    public static let publishableKey: String? = value("MochiSupabaseKey")

    /// True when a Supabase project is set, so sign-in and sync can work.
    public static var cloudConfigured: Bool { supabaseURL != nil && publishableKey != nil }

    /// The URL of one of the project's edge functions (mochi-api, mochi-mcp).
    public static func function(_ name: String) -> URL? {
        supabaseURL?.appendingPathComponent("functions/v1/\(name)")
    }

    private static func value(_ key: String) -> String? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        // Unfilled build placeholders ("$(MOCHI_SUPABASE_URL)", "__SUPABASE_URL__") count as empty.
        guard !raw.isEmpty, !raw.hasPrefix("$("), !raw.hasPrefix("${"), !raw.hasPrefix("__") else { return nil }
        return raw
    }
}

/// The name you go by. Summaries use it for your own action items, and Mochi uses it to tell your
/// tasks from other people's. Set in Settings; "Me" (the transcript label) always counts too.
public enum OwnerName {
    public static var name: String {
        let n = UserDefaults.standard.string(forKey: "ownerName")?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? "Me" : n
    }
}
