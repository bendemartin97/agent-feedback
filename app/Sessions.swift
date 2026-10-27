import Foundation

let homeURL = FileManager.default.homeDirectoryForCurrentUser
let appHome = homeURL.appendingPathComponent(".claude/agent-feedback")
let sessionsDir = appHome.appendingPathComponent("sessions")

/// Settings from `~/.claude/agent-feedback/config.json` (all optional):
/// `workspaces` – folder of workspaces (`<workspaces>/<name>/<checkout>`) that share one feedback folder;
/// `claude` – path to the claude CLI if it is not in one of the usual places.
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

    static var workspaces: String? { ProcessInfo.processInfo.environment["AGENT_FEEDBACK_WORKSPACES"] ?? path("workspaces") }

    /// claude CLI: the setting, otherwise the usual install locations.
    static var claude: URL? {
        let candidates = [path("claude"), homeURL.path + "/.local/bin/claude", homeURL.path + "/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].compactMap { $0 }
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
    /// Last prompt, shortened.
    let prompt: String
    let updated: Date
    /// Nickname and headline from a labels file (see `activeSessions`), if present.
    var pet = ""
    var headline = ""

    /// Main line in the picker: “Fred · project — headline”.
    var label: String {
        let topic = !headline.isEmpty ? headline : !title.isEmpty ? title : ""
        return (pet.isEmpty ? "" : "\(pet) · ") + project + (topic.isEmpty ? "" : " — \(topic)")
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
        var s = AgentSession(id: id, root: root, start: j["start"] ?? root, project: j["project"] ?? "",
                             title: j["title"] ?? "", prompt: j["prompt"] ?? "", updated: updated)
        s.pet = pets[id]?["name"] ?? ""
        s.headline = pets[id]?["headline"] ?? ""
        return s
    }.sorted { $0.updated > $1.updated }
}
