import Foundation

let homeURL = FileManager.default.homeDirectoryForCurrentUser
let appHome = homeURL.appendingPathComponent(".claude/agent-feedback")
let sessionsDir = appHome.appendingPathComponent("sessions")

/// Settings from `~/.claude/agent-feedback/config.json` (all optional):
/// `workspaces` – folder of workspaces (`<workspaces>/<name>/<checkout>`) that share one feedback folder;
/// `claude`, `codex`, `pi` – paths to the CLIs if they are not in one of the usual places;
/// `models` – `transport` (delivery into a running Claude chat, default haiku), `claude`, `codex` and `pi` (background
/// runs, default: the CLI's own default).
enum Config {
    private static var values: [String: Any] {
        (try? Data(contentsOf: appHome.appendingPathComponent("config.json")))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    }

    private static func path(_ key: String) -> String? {
        guard var p = values[key] as? String, !p.isEmpty else { return nil }
        if p.hasPrefix("~") { p = homeURL.path + p.dropFirst() }
        return p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    /// Value as written in the file (for the settings window); `group` is a nested object such as `models`.
    static func raw(_ key: String, in group: String? = nil) -> String {
        let dict = group.map { values[$0] as? [String: Any] ?? [:] } ?? values
        return dict[key] as? String ?? ""
    }

    /// Writes one value, keeping everything else in the file; an empty value removes the key.
    static func set(_ key: String, _ value: String, in group: String? = nil) {
        var all = values
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let group {
            var dict = all[group] as? [String: Any] ?? [:]
            dict[key] = v.isEmpty ? nil : v
            all[group] = dict.isEmpty ? nil : dict
        } else {
            all[key] = v.isEmpty ? nil : v
        }
        try? FileManager.default.createDirectory(at: appHome, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: appHome.appendingPathComponent("config.json"))
    }

    static func model(_ key: String) -> String? {
        guard let m = (values["models"] as? [String: Any])?[key] as? String, !m.isEmpty else { return nil }
        return m
    }

    static var workspaces: String? { ProcessInfo.processInfo.environment["AGENT_FEEDBACK_WORKSPACES"] ?? path("workspaces") }

    /// claude CLI: the setting, otherwise the usual install locations.
    static var claude: URL? {
        let candidates = [path("claude"), homeURL.path + "/.local/bin/claude", homeURL.path + "/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// codex CLI: the setting `codex`, otherwise Homebrew, npm or nvm locations.
    static var codex: URL? {
        let nvm = homeURL.appendingPathComponent(".nvm/versions/node")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []).sorted(by: >)
        let candidates = [path("codex"), "/opt/homebrew/bin/codex", "/usr/local/bin/codex", homeURL.path + "/.local/bin/codex"].compactMap { $0 }
            + versions.map { nvm.appendingPathComponent($0).appendingPathComponent("bin/codex").path }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// pi CLI: the setting `pi`, otherwise the pi installer's, Homebrew, npm or nvm locations.
    static var pi: URL? {
        let nvm = homeURL.appendingPathComponent(".nvm/versions/node")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []).sorted(by: >)
        let candidates = [path("pi"), homeURL.path + "/.local/bin/pi", homeURL.path + "/.pi/agent/bin/pi",
                          "/opt/homebrew/bin/pi", "/usr/local/bin/pi"].compactMap { $0 }
            + versions.map { nvm.appendingPathComponent($0).appendingPathComponent("bin/pi").path }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
}

/// A running agent session, reported by `hooks/session.sh`.
struct AgentSession {
    let id: String
    let root: String
    /// Start directory of the session; `claude --resume` only finds it there.
    let start: String
    let project: String
    let title: String
    /// `claude`, `codex` or `pi`.
    var agent = "claude"
    /// Last prompt, shortened.
    let prompt: String
    let updated: Date
    /// Nickname and headline from a labels file (see `activeSessions`), if present.
    var pet = ""
    var headline = ""

    /// Main line in the picker: “Fred · project — headline”.
    var label: String {
        let topic = !headline.isEmpty ? headline : !title.isEmpty ? title : ""
        return (pet.isEmpty ? "" : "\(pet) · ") + project + (topic.isEmpty ? "" : " — \(topic)") + (agent == "claude" ? "" : " (\(agent.capitalized))")
    }

    /// Second line: last prompt and how long ago it was.
    var detail: String {
        let mins = Int(Date().timeIntervalSince(updated) / 60)
        let ago = mins < 1 ? "just now" : mins < 60 ? "\(mins) min ago" : "\(mins / 60) h ago"
        return (prompt.isEmpty ? "" : "“\(prompt)” · ") + ago
    }
}

/// Sessions of the last 8 hours, most recently active first. The SessionEnd hook deletes ended ones.
func activeSessions() -> [AgentSession] {
    let fm = FileManager.default
    let cutoff = Date().addingTimeInterval(-8 * 3600)
    // Optional names for sessions: {"<session_id>": {"name": "…", "headline": "…"}}, e.g. from a desktop companion.
    let pets = (try? Data(contentsOf: appHome.appendingPathComponent("labels.json")))
        .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: [String: String]] } ?? [:]
    let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return files.compactMap { url -> AgentSession? in
        guard url.pathExtension == "json",
              let updated = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              updated > cutoff,
              let data = try? Data(contentsOf: url),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let id = j["id"], let root = j["root"], !root.isEmpty else { return nil }
        // pi sessions report their process; one that is gone (killed, terminal closed) is not offered any more.
        if let pid = j["pid"].flatMap(Int32.init), kill(pid, 0) != 0 { return nil }
        var s = AgentSession(id: id, root: root, start: j["start"] ?? root, project: j["project"] ?? "",
                             title: j["title"] ?? "", prompt: j["prompt"] ?? "", updated: updated)
        s.agent = j["agent"] ?? "claude"
        s.pet = pets[id]?["name"] ?? ""
        s.headline = pets[id]?["headline"] ?? ""
        return s
    }.sorted { $0.updated > $1.updated }
}
