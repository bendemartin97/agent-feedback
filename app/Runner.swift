import AppKit

/// Works through items, one after another per feedback folder (i.e. per workspace), so two agents don't
/// change the same files out from under each other.
///
/// If the target session is still running, it gets the task as a message in its chat (Claude Code: peer message,
/// delivered by a short `claude -p` with SendMessage; Codex: `codex queue`): you can see there that and how it works on it.
/// The task is done as soon as the `.md` has a result. If the session no longer runs, a fork of it works
/// in the background (`--resume … --fork-session`); without a known session, a fresh one in the project.
final class Runner {
    private struct Job {
        let md: URL
        let target: Target
        let cwd: String
    }

    /// Running task: either our own process or a session whose result we wait for.
    private struct Run {
        let job: Job
        var process: Process?
        var peer: String?
        /// Content of the `.md` at start; only done once it has changed (matters for "Try again").
        var startText = ""
    }

    private let store: FeedbackStore
    private var queues: [String: [Job]] = [:]
    private var running: [String: Run] = [:]
    private var cancelled: Set<String> = []
    var onChange: (() -> Void)?

    init(store: FeedbackStore) { self.store = store }

    func isQueued(_ md: URL) -> Bool { queues.values.contains { $0.contains { same($0.md, md) } } }
    func isRunning(_ md: URL) -> Bool { running.values.contains { same($0.job.md, md) } }
    /// Name of the session in whose chat the item is currently being worked on.
    func peer(of md: URL) -> String? { running.values.first { same($0.job.md, md) }?.peer }

    /// Agents move the `.md` to `done/`; the file name stays.
    private func same(_ a: URL, _ b: URL) -> Bool {
        a.lastPathComponent == b.lastPathComponent && a.deletingLastPathComponent().deletingLastPathComponent() == b.deletingLastPathComponent().deletingLastPathComponent()
    }

    func enqueue(_ item: FeedbackItem) {
        guard !isQueued(item.md), !isRunning(item.md) else { return }
        // Without a start directory (older items) the session can't be resumed: start fresh in the project.
        let resumable = !item.start.isEmpty
        let target = resumable || !item.sessionID.isEmpty && Self.liveSession(item.sessionID) != nil
            ? item.target : Target(id: "", start: "", label: item.sessionLabel, agent: item.agent)
        let job = Job(md: item.md, target: target, cwd: resumable ? item.start : item.dir.deletingLastPathComponent().path)
        queues[item.dir.path, default: []].append(job)
        next(item.dir.path)
        onChange?()
    }

    /// Remove queued jobs, terminate our own processes. A running session can't be stopped from outside;
    /// the queue just frees the slot.
    func cancel(_ md: URL) {
        for key in queues.keys { queues[key]?.removeAll { same($0.md, md) } }
        if let (key, run) = running.first(where: { same($0.value.job.md, md) }) {
            if let p = run.process {
                cancelled.insert(key)
                p.terminate()
            } else {
                running[key] = nil
                next(key)
            }
        }
        onChange?()
    }

    /// Called regularly from outside: frees the slot as soon as a session has written its result.
    func tick() {
        var changed = false
        for (key, run) in running where run.process == nil {
            let dir = URL(fileURLWithPath: key)
            let name = run.job.md.lastPathComponent
            let item = ["inbox", "done"].lazy.compactMap { FeedbackItem(md: dir.appendingPathComponent($0).appendingPathComponent(name)) }.first
            let finished = item.map { $0.text != run.startText && [.implemented, .nothingToDo, .question, .accepted, .failed].contains($0.status) } ?? true
            if finished {
                running[key] = nil
                next(key)
                changed = true
            }
        }
        if changed { onChange?() }
    }

    private func next(_ key: String) {
        guard running[key] == nil, var queue = queues[key], !queue.isEmpty else { return }
        let job = queue.removeFirst()
        queues[key] = queue
        if !job.target.id.isEmpty, let live = Self.live(job.target.id) {
            deliver(job, to: live.peer, pid: live.pid, key: key)
        } else if job.target.agent == "codex", Self.codexOpen(job.target.id) {
            enqueueInCodex(job, key: key)
        } else {
            fork(job, key: key)
        }
    }

    private static var env: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(homeURL.path)/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["SHELL"] = "/bin/zsh"
        env["AGENT_FEEDBACK_RUN"] = "1"
        return env
    }

    /// Peer name of a running interactive session from `~/.claude/sessions/<pid>.json`.
    static func liveSession(_ id: String) -> String? { live(id)?.peer ?? (codexOpen(id) ? "the Codex session" : nil) }

    /// A Codex session counts as open until its SessionEnd hook removed it (closed, archived or idle for 30 min).
    private static func codexOpen(_ id: String) -> Bool {
        guard !id.isEmpty, let data = try? Data(contentsOf: sessionsDir.appendingPathComponent("\(id).json")),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return j["agent"] as? String == "codex"
    }

    private static func live(_ id: String) -> (peer: String, pid: Int32)? {
        let dir = homeURL.appendingPathComponent(".claude/sessions")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  j["sessionId"] as? String == id, j["kind"] as? String == "interactive",
                  let pid = j["pid"] as? Int32, kill(pid, 0) == 0,
                  let peer = j["name"] as? String else { continue }
            return (peer, pid)
        }
        return nil
    }

    /// Permission flags the session was started with: the sender must be in the same permission mode class,
    /// otherwise the message waits for a manual confirmation instead of arriving in the chat.
    private static func permissionArgs(of pid: Int32) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "args=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return [] }
        let args = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: " ").map(String.init)
        p.waitUntilExit()
        if args.contains("--dangerously-skip-permissions") { return ["--dangerously-skip-permissions"] }
        if let i = args.firstIndex(of: "--permission-mode"), i + 1 < args.count { return ["--permission-mode", args[i + 1]] }
        return []
    }

    /// Sends the task into the running session's chat and then waits for its result (see `tick`).
    private func deliver(_ job: Job, to peer: String, pid: Int32, key: String) {
        running[key] = Run(job: job, process: nil, peer: peer, startText: (try? String(contentsOf: job.md, encoding: .utf8)) ?? "")
        let message = Self.message(for: job.md)
        let prompt = """
        Use the SendMessage tool and send this exact message to the session "\(peer)":
        \(message)
        Then reply only with OK, or with ERROR: <reason> if sending failed.
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let args = ["-p", "--model", Config.model("transport") ?? "haiku", "--output-format", "json"] + Self.effort("transport")
                + Self.permissionArgs(of: pid) + [prompt]
            let (ok, output) = Self.claude(args, cwd: FileManager.default.temporaryDirectory.path)
            let sent = ok && output.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("OK")
            DispatchQueue.main.async {
                guard !sent else { self.onChange?(); return }
                self.running[key] = nil
                self.store.fail(job.md, message: "Message to the session \(peer) was not delivered: \(output.prefix(200)). Try again or assign to another session.")
                self.next(key)
                self.onChange?()
            }
        }
    }

    /// Queues the task in the open Codex session (`codex queue`, no model involved): it runs as the next turn,
    /// right away if the session is idle. Then waits for the result like a Claude delivery.
    private func enqueueInCodex(_ job: Job, key: String) {
        running[key] = Run(job: job, process: nil, peer: "the Codex session", startText: (try? String(contentsOf: job.md, encoding: .utf8)) ?? "")
        let args = ["queue", "--thread", job.target.id, "--message", Self.message(for: job.md)]
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, output) = Self.codex(args, cwd: job.cwd, process: Process(), lastMessage: false)
            DispatchQueue.main.async {
                guard !ok else { self.onChange?(); return }
                self.running[key] = nil
                self.store.fail(job.md, message: "Could not queue the item in the Codex session: \(output.prefix(200)). Try again or assign to another session.")
                self.next(key)
                self.onChange?()
            }
        }
    }

    /// Message for the chat: note and context readable up front, so the chat shows what it is about.
    private static func message(for md: URL) -> String {
        let item = FeedbackItem(md: md)
        let note = (item?.note ?? "").replacingOccurrences(of: "\n", with: " ")
        /// Text after the last of these headings (English or the German one of older items), nil if none.
        func after(_ headings: String...) -> String? {
            guard let text = item?.text,
                  let hit = headings.compactMap({ text.range(of: $0, options: .backwards) }).max(by: { $0.lowerBound < $1.lowerBound })
            else { return nil }
            return String(text[hit.upperBound...])
        }
        let rework = after("## Rework", "## Nachbesserung")
        let answer = after("## Answer", "## Antwort")
        func clip(_ t: String) -> String {
            let one = t.split(separator: "\n").dropFirst().filter { !$0.hasPrefix("**Status:**") }.joined(separator: " ")
            return one.count > 300 ? String(one.prefix(300)) + "…" : one
        }
        let who = NSFullUserName().split(separator: " ").first.map(String.init) ?? "you"
        var lines = ["📸 Feedback from \(who): “\(note.count > 400 ? String(note.prefix(400)) + "…" : note)”"]
        if let item {
            var ctx: [String] = []
            if !item.images.isEmpty { ctx.append("\(item.images.count) Screenshot\(item.images.count == 1 ? "" : "s")") }
            if !item.field("url").isEmpty { ctx.append(item.field("url")) }
            if !ctx.isEmpty { lines.append(ctx.joined(separator: " · ")) }
            if item.status == .rework, let r = rework { lines.append("Rework: \(clip(r))") }
            if item.status == .answered, let a = answer { lines.append("Answer to your question: \(clip(a))") }
        }
        lines.append("Please work through this now with the `feedback` skill – only this item: \(md.path) – write the result as usual as a `## Result` block into the .md. No reply to the sender is needed.")
        return lines.joined(separator: "\n")
    }

    /// Works through the item in the background: fork of the session, otherwise a fresh session in the project.
    private func fork(_ job: Job, key: String) {
        let prompt = "work through feedback – only this item: \(job.md.path)"
        let codex = job.target.agent == "codex"
        let args: [String]
        if codex {
            // Workspace sandbox plus the feedback folder, which can lie outside the checkout.
            let feedback = job.md.deletingLastPathComponent().deletingLastPathComponent().path
            let config = ["-c", "sandbox_mode=\"workspace-write\"", "-c", "sandbox_workspace_write.writable_roots=[\"\(feedback)\"]",
                          "--skip-git-repo-check"] + (Config.model("codex").map { ["-m", $0] } ?? [])
                + (Config.raw("codex", in: "efforts").isEmpty ? [] : ["-c", "model_reasoning_effort=\"\(Config.raw("codex", in: "efforts"))\""])
            args = job.target.id.isEmpty ? ["exec"] + config + [prompt] : ["exec", "fork"] + config + [job.target.id, prompt]
        } else {
            let model = (Config.model("claude").map { ["--model", $0] } ?? []) + Self.effort("claude")
            args = job.target.id.isEmpty
                ? ["-p", "--output-format", "json"] + model + [prompt]
                : ["-p", "--resume", job.target.id, "--fork-session", "--output-format", "json"] + model + [prompt]
        }
        let p = Process()
        running[key] = Run(job: job, process: p, peer: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, output) = codex ? Self.codex(args, cwd: job.cwd, process: p) : Self.claude(args, cwd: job.cwd, process: p)
            DispatchQueue.main.async {
                self.running[key] = nil
                if self.cancelled.remove(key) == nil, !ok {
                    self.store.fail(job.md, message: Self.explain(output, status: p.isRunning ? -1 : p.terminationStatus, resumed: !job.target.id.isEmpty))
                }
                self.next(key)
                self.onChange?()
            }
        }
    }

    /// Starts `claude` and returns success plus `result` (or stderr on errors). Blocking.
    private static func claude(_ args: [String], cwd: String, process: Process = Process()) -> (Bool, String) {
        let p = process
        guard let claude = Config.claude else {
            return (false, "claude CLI not found. Set its path under \"claude\" in ~/.claude/agent-feedback/config.json.")
        }
        p.executableURL = claude
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = env
        let out = Pipe()
        let errFile = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-run-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errFile) }
        p.standardOutput = out
        p.standardError = try? FileHandle(forWritingTo: errFile)
        do {
            try p.run()
        } catch {
            return (false, "claude could not be started (\(error.localizedDescription)): \(claude.path)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let result = obj?["result"] as? String ?? ""
        if p.terminationStatus != 0 || obj?["is_error"] as? Bool == true {
            let err = String(data: (try? Data(contentsOf: errFile)) ?? Data(), encoding: .utf8) ?? ""
            return (false, result.isEmpty ? err : result)
        }
        return (true, result)
    }

    /// `--effort <level>` for a Claude run if one is set under `efforts`.
    private static func effort(_ key: String) -> [String] {
        let e = Config.raw(key, in: "efforts")
        return e.isEmpty ? [] : ["--effort", e]
    }

    /// Starts `codex exec …` and returns success plus its last message (or stderr on errors). Blocking.
    private static func codex(_ args: [String], cwd: String, process p: Process, lastMessage: Bool = true) -> (Bool, String) {
        guard let codex = Config.codex else {
            return (false, "codex CLI not found. Set its path under \"codex\" in ~/.claude/agent-feedback/config.json.")
        }
        let tmp = FileManager.default.temporaryDirectory
        let last = tmp.appendingPathComponent("feedback-codex-\(UUID().uuidString).txt")
        let errFile = tmp.appendingPathComponent("feedback-run-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer { [last, errFile].forEach { try? FileManager.default.removeItem(at: $0) } }
        p.executableURL = codex
        p.arguments = args + (lastMessage ? ["-o", last.path] : [])
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        // npm/nvm installs need their node next to codex.
        var e = env
        e["PATH"] = codex.deletingLastPathComponent().path + ":" + (e["PATH"] ?? "")
        p.environment = e
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = try? FileHandle(forWritingTo: errFile)
        do {
            try p.run()
        } catch {
            return (false, "codex could not be started (\(error.localizedDescription)): \(codex.path)")
        }
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let result = lastMessage ? (try? String(contentsOf: last, encoding: .utf8)) ?? "" : stdout
        guard p.terminationStatus == 0 else {
            let err = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
            return (false, String(err.suffix(600)))
        }
        return (true, result)
    }

    /// Turns exit code and output into an understandable error message.
    private static func explain(_ detail: String, status: Int32, resumed: Bool) -> String {
        let text = detail.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let short = text.count > 300 ? String(text.prefix(300)) + "…" : text
        if resumed, text.lowercased().contains("no conversation found") {
            return "The session could not be resumed (not found in its start directory). Assign the item to a running session and try again."
        }
        if text.lowercased().contains("not logged in") || text.contains("/login") {
            return "Claude is not logged in. Run `claude` once in the terminal and log in, then try again."
        }
        return short.isEmpty ? "Agent exited with exit code \(status), without output." : "Exit code \(status): \(short)"
    }
}
