import AppKit

/// Feedback folder of a session: `<workspaces>/<name>/feedback` inside a workspace, otherwise `<cwd>/.feedback`.
/// Same rule as `hooks/feedback-dir.sh`, which the `feedback` skill uses.
func feedbackDir(for cwd: String) -> URL {
    guard let ws = Config.workspaces else { return URL(fileURLWithPath: cwd).appendingPathComponent(".feedback") }
    let root = ws + "/"
    if cwd.hasPrefix(root), let slug = cwd.dropFirst(root.count).split(separator: "/").first {
        return URL(fileURLWithPath: root + slug + "/feedback")
    }
    return URL(fileURLWithPath: cwd).appendingPathComponent(".feedback")
}

/// Context of a single image: where it came from and what the screen looked like.
struct PageContext: Codable {
    var source = ""
    var url = ""
    var tab = ""
    var window = ""
    var appearance = ""
    var at = Date()

    var line: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return [f.string(from: at), source, url, tab.isEmpty ? "" : "“\(tab)”", window, appearance]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A mark, in image coordinates (points of `NSImage.size`, origin bottom left).
/// `width` is the stroke width, the radius for numbers, the font size for text.
struct Mark: Codable {
    enum Kind: String, Codable { case arrow, box, pen, marker, number, text }
    var kind: Kind
    var rgba: [CGFloat]
    var width: CGFloat
    var points: [CGPoint]
    var text = ""

    var color: NSColor {
        get { NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]) }
        set {
            let c = newValue.usingColorSpace(.sRGB) ?? newValue
            rgba = [c.redComponent, c.greenComponent, c.blueComponent, kind == .marker ? 0.35 : c.alphaComponent]
        }
    }

    init(kind: Kind, color: NSColor, width: CGFloat, points: [CGPoint], text: String = "") {
        self.kind = kind
        self.rgba = []
        self.width = width
        self.points = points
        self.text = text
        self.color = color
    }

    private var label: NSAttributedString {
        NSAttributedString(string: text, attributes: kind == .number
            ? [.font: NSFont.systemFont(ofSize: width * 1.15, weight: .heavy), .foregroundColor: NSColor.white]
            : [.font: NSFont.systemFont(ofSize: width, weight: .bold), .foregroundColor: color])
    }

    /// Outline for selection and hit testing.
    var bounds: NSRect {
        guard let first = points.first else { return .zero }
        switch kind {
        case .number:
            return NSRect(x: first.x - width, y: first.y - width, width: width * 2, height: width * 2)
        case .text:
            let size = label.size(), pad = width * 0.3
            return NSRect(x: first.x - pad, y: first.y - pad, width: size.width + pad * 2, height: size.height + pad * 2)
        default:
            let xs = points.map(\.x), ys = points.map(\.y)
            let r = NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return r.insetBy(dx: -width * 2, dy: -width * 2)
        }
    }

    func draw() {
        guard let first = points.first, let last = points.last else { return }
        switch kind {
        case .number:
            color.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            let size = label.size()
            label.draw(at: NSPoint(x: first.x - size.width / 2, y: first.y - size.height / 2))
            return
        case .text:
            let pad = width * 0.3
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: pad, yRadius: pad).fill()
            label.draw(at: first)
            return
        default:
            break
        }
        color.set()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch kind {
        case .box:
            path.appendRect(NSRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                   width: abs(last.x - first.x), height: abs(last.y - first.y)))
        case .arrow:
            path.move(to: first)
            path.line(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x), head = width * 4.5
            for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                path.move(to: last)
                path.line(to: NSPoint(x: last.x + cos(angle + side) * head, y: last.y + sin(angle + side) * head))
            }
        default:
            path.move(to: first)
            points.dropFirst().forEach(path.line(to:))
        }
        path.stroke()
    }
}

/// An image in the editor: original, marks and context. `file` is the file name if it was already saved.
struct Page {
    var original: NSImage
    var marks: [Mark] = []
    var context: PageContext
    var file: String?

    /// PNG at original resolution with all marks.
    func render() -> Data? {
        guard let src = original.representations.first else { return nil }
        let w = max(src.pixelsWide, Int(original.size.width)), h = max(src.pixelsHigh, Int(original.size.height))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = original.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        original.draw(in: NSRect(origin: .zero, size: original.size))
        marks.forEach { $0.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    func originalPNG() -> Data? {
        guard let tiff = original.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Where an item belongs: session ID, start directory (for `--resume`) and display name.
struct Target {
    var id: String
    var start: String
    var label: String
}

/// A feedback item: an `.md` in `inbox/` or `done/` with its images.
struct FeedbackItem {
    enum Status { case open, rework, answered, queued, running, failed, question, implemented, nothingToDo, accepted }

    let md: URL
    let text: String
    var status: Status
    /// Session in whose chat the item is currently being worked on (runtime only).
    var peer: String?
    let changed: Date

    var dir: URL { md.deletingLastPathComponent().deletingLastPathComponent() }
    var base: String { md.deletingPathExtension().lastPathComponent }
    var inInbox: Bool { md.deletingLastPathComponent().lastPathComponent == "inbox" }
    var project: String { dir.deletingLastPathComponent().lastPathComponent }
    var sessionID: String { field("session_id") }
    var sessionLabel: String { field("session") }
    var start: String { field("start") }
    var images: [String] {
        let list = field("images").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // An empty `images:` (or legacy `bilder:`) line means text only; no line at all is the old one-image format.
        if !list.isEmpty || text.contains("\nimages:") || text.contains("\nbilder:") { return list }
        return [base + ".png"]
    }
    var imageURLs: [URL] { images.map { md.deletingLastPathComponent().appendingPathComponent($0) } }

    var target: Target { Target(id: sessionID, start: start, label: sessionLabel) }

    /// German frontmatter keys of items written before the switch to English.
    static let legacyKeys = ["project": "projekt", "time": "zeit", "window": "fenster", "appearance": "darstellung",
                             "images": "bilder", "mode": "auftrag"]
    /// German `**Label:**` names of items written before the switch to English.
    static let legacyLabels = ["Question": "Frage", "Change": "Änderung", "Cause": "Ursache", "Files": "Dateien", "Error": "Fehler"]

    /// Frontmatter value; falls back to the German key of older items.
    func field(_ key: String) -> String {
        for k in [key] + (Self.legacyKeys[key].map { [$0] } ?? []) {
            let prefix = k + ": "
            if let line = frontmatter.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) { return String(line.dropFirst(prefix.count)) }
        }
        return ""
    }

    var frontmatter: String {
        let parts = text.components(separatedBy: "\n---\n")
        return parts.count > 1 ? parts[0] : ""
    }

    /// The user's note: everything between the frontmatter and the first `## ` block.
    var note: String {
        guard let end = text.range(of: "\n---\n") else { return text }
        let body = text[end.upperBound...]
        let cut = body.range(of: "\n## ")?.lowerBound ?? body.endIndex
        return body[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var headline: String {
        let n = note.split(separator: "\n").first.map(String.init) ?? ""
        return n.isEmpty ? "(no note)" : n
    }

    /// Value of a `**Label:**` line from the last block that contains it (e.g. Question, Error, Change).
    /// Also matches the German label of older items.
    func last(_ label: String) -> String {
        let prefixes = ([label] + (Self.legacyLabels[label].map { [$0] } ?? [])).map { "**\($0):**" }
        guard let line = text.split(separator: "\n").last(where: { l in prefixes.contains { l.hasPrefix($0) } }),
              let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { return "" }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    var question: String {
        let q = last("Question")
        return q.isEmpty ? last("Change") : q
    }

    var icon: String {
        switch status {
        case .open: return "⏳"
        case .rework: return "🔁"
        case .answered: return "💬"
        case .queued: return "🕒"
        case .running: return "⚙️"
        case .failed: return "💥"
        case .question: return "❓"
        case .implemented: return "✅"
        case .nothingToDo: return "➖"
        case .accepted: return "🟢"
        }
    }

    var statusText: String {
        switch status {
        case .open: return "open"
        case .rework: return "rework"
        case .answered: return "answered"
        case .queued: return "queued"
        case .running: return peer.map { "running in \($0)'s chat" } ?? "running in the background"
        case .failed: return "failed"
        case .question: return "question"
        case .implemented: return "implemented – review"
        case .nothingToDo: return "nothing to do – review"
        case .accepted: return "accepted"
        }
    }

    /// Waiting for an agent (open, rework, answered, failed).
    var needsAgent: Bool { [.open, .rework, .answered, .failed].contains(status) }
    /// Waiting for the user (question or visual review).
    var needsUser: Bool { [.question, .implemented, .nothingToDo].contains(status) }

    init?(md: URL) {
        let fm = FileManager.default
        guard let text = try? String(contentsOf: md, encoding: .utf8),
              let changed = (try? fm.attributesOfItem(atPath: md.path))?[.modificationDate] as? Date else { return nil }
        self.md = md
        self.text = text
        self.changed = changed
        status = .open
        status = parsedStatus
    }

    private var parsedStatus: Status {
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("**Status:**") })?.lowercased() else {
            return inInbox ? .open : .implemented
        }
        // English first, then the German words of older items. Order matters: the user's verdicts win over "question".
        func has(_ words: String...) -> Bool { words.contains { line.contains($0) } }
        if has("accepted", "abgenommen") { return .accepted }
        if has("rework", "nachbessern") { return .rework }
        if has("answered", "beantwortet") { return .answered }
        if has("failed", "fehlgeschlagen") { return .failed }
        if has("question", "frage") { return .question }
        if has("nothing to do", "kein handlungsbedarf") { return .nothingToDo }
        if has("implemented", "umgesetzt", "erledigt") { return .implemented }
        return .open
    }
}

/// Reads and writes feedback items. Remembers every folder anything was ever saved to in
/// `~/.claude/agent-feedback/dirs.json`, so the inbox also finds items of ended sessions.
final class FeedbackStore {
    private let dirsFile = appHome.appendingPathComponent("dirs.json")

    var dirs: [URL] {
        var paths = Set((try? Data(contentsOf: dirsFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? [])
        if let ws = Config.workspaces {
            for slug in (try? FileManager.default.contentsOfDirectory(atPath: ws)) ?? [] where !slug.hasPrefix(".") {
                paths.insert(ws + "/" + slug + "/feedback")
            }
        }
        activeSessions().forEach { paths.insert(feedbackDir(for: $0.root).path) }
        return paths.sorted().map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func remember(_ dir: URL) {
        guard !dir.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
        var list = (try? Data(contentsOf: dirsFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        guard !list.contains(dir.path) else { return }
        list.append(dir.path)
        try? JSONSerialization.data(withJSONObject: list).write(to: dirsFile, options: .atomic)
    }

    /// All open items plus finished ones that still need review or were accepted in the last 3 days.
    func allItems() -> [FeedbackItem] {
        let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
        return dirs.flatMap { dir in
            ["inbox", "done"].flatMap { sub -> [FeedbackItem] in
                let folder = dir.appendingPathComponent(sub)
                return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                    .filter { $0.hasSuffix(".md") }
                    .compactMap { FeedbackItem(md: folder.appendingPathComponent($0)) }
                    .filter { $0.status != .accepted || $0.changed > cutoff }
            }
        }.sorted { $0.changed > $1.changed }
    }

    // MARK: Writing

    /// Creates a new item or overwrites an existing one (`existing`). Saves the rendered PNG of each image next to
    /// the `.md`, and the original and marks under `<dir>/edit/<base>/`, so it can be edited again later.
    @discardableResult
    func save(pages: [Page], note: String, target: Target, dir: URL, existing: FeedbackItem?, now: Bool) -> URL? {
        let fm = FileManager.default
        let inbox = dir.appendingPathComponent("inbox")
        for sub in ["inbox", "done", "edit"] { try? fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true) }
        let ignore = dir.appendingPathComponent(".gitignore")
        if dir.lastPathComponent == ".feedback", !fm.fileExists(atPath: ignore.path) {
            try? "*\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
        remember(dir)

        let first = pages.first?.context ?? PageContext(source: "Text")
        var folder = existing?.md.deletingLastPathComponent() ?? inbox
        var base = existing?.base ?? ""
        if existing == nil {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd_HHmmss"
            base = f.string(from: first.at)
            var n = 2
            while fm.fileExists(atPath: inbox.appendingPathComponent(base + ".md").path) {
                base = f.string(from: first.at) + "-\(n)"
                n += 1
            }
        }
        if now, let existing, !existing.inInbox {
            move(existing, to: inbox)
            folder = inbox
        }

        let edit = dir.appendingPathComponent("edit").appendingPathComponent(base)
        try? fm.removeItem(at: edit)
        try? fm.createDirectory(at: edit, withIntermediateDirectories: true)
        var names: [String] = []
        var meta: [[String: Any]] = []
        for (i, page) in pages.enumerated() {
            let name = base + (i == 0 ? "" : "-\(i + 1)") + ".png"
            try? page.render()?.write(to: folder.appendingPathComponent(name))
            try? page.originalPNG()?.write(to: edit.appendingPathComponent("\(i + 1).orig.png"))
            try? JSONEncoder().encode(page.marks).write(to: edit.appendingPathComponent("\(i + 1).marks.json"))
            if let ctx = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(page.context)) { meta.append(["file": name, "context": ctx]) }
            names.append(name)
        }
        try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]).write(to: edit.appendingPathComponent("pages.json"))
        for old in existing?.images ?? [] where !names.contains(old) {
            try? fm.removeItem(at: folder.appendingPathComponent(old))
        }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = [
            "session: \(target.label)",
            "session_id: \(target.id)",
            "start: \(target.start)",
            "project: \(dir.deletingLastPathComponent().lastPathComponent)",
            "time: \(existing?.field("time") ?? f.string(from: first.at))",
            "app: \(first.source)",
            "url: \(first.url)",
            "tab: \(first.tab)",
            "window: \(first.window)",
            "appearance: \(first.appearance)",
            "branch: \(existing?.field("branch") ?? branches(in: dir))",
            "images: \(names.joined(separator: ", "))",
            "mode: \(now ? "now" : "later")",
        ]
        if pages.count > 1 {
            for (i, page) in pages.enumerated() { lines.append("image-\(i + 1): \(names[i]) · \(page.context.line)") }
        }
        let rest = existing.map { e -> String in
            guard let end = e.text.range(of: "\n---\n") else { return "" }
            let body = e.text[end.upperBound...]
            return body.range(of: "\n## ").map { String(body[$0.lowerBound...]) } ?? ""
        } ?? ""
        let noteText = note.isEmpty ? (pages.isEmpty ? "(no note)" : "(no note – the image is the task)") : note
        let md = "---\n" + lines.joined(separator: "\n") + "\n---\n\n" + noteText + "\n" + rest + (rest.hasSuffix("\n") || rest.isEmpty ? "" : "\n")
        let url = folder.appendingPathComponent(base + ".md")
        try? md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Loads images and marks of a saved item for further editing. Without `edit/` data (old items)
    /// the rendered images become the originals.
    func pages(of item: FeedbackItem) -> [Page] {
        let edit = item.dir.appendingPathComponent("edit").appendingPathComponent(item.base)
        let meta = (try? Data(contentsOf: edit.appendingPathComponent("pages.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        return item.imageURLs.enumerated().compactMap { i, url -> Page? in
            let orig = NSImage(contentsOf: edit.appendingPathComponent("\(i + 1).orig.png")) ?? NSImage(contentsOf: url)
            guard let orig else { return nil }
            let marks = (try? Data(contentsOf: edit.appendingPathComponent("\(i + 1).marks.json")))
                .flatMap { try? JSONDecoder().decode([Mark].self, from: $0) } ?? []
            let ctx = (i < meta.count ? meta[i]["context"] : nil)
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(PageContext.self, from: $0) }
                ?? PageContext(source: item.field("app"), url: item.field("url"), tab: item.field("tab"),
                               window: item.field("window"), appearance: item.field("appearance"))
            return Page(original: orig, marks: marks, context: ctx, file: url.lastPathComponent)
        }
    }

    /// Appends a block to the `.md` (answer, rework, acceptance, error).
    func append(_ block: String, to item: FeedbackItem) {
        let text = (try? String(contentsOf: item.md, encoding: .utf8)) ?? item.text
        try? (text.trimmingCharacters(in: .newlines) + "\n\n" + block.trimmingCharacters(in: .newlines) + "\n")
            .write(to: item.md, atomically: true, encoding: .utf8)
    }

    func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    func accept(_ item: FeedbackItem) {
        append("## Accepted \(stamp())\n**Status:** accepted", to: item)
    }

    /// Rework: append the request and move back to `inbox/` with the images. Returns the new `.md`.
    func rework(_ item: FeedbackItem, text: String) -> URL {
        append("## Rework \(stamp())\n\(text)\n\n**Status:** rework", to: item)
        return move(item, to: item.dir.appendingPathComponent("inbox"))
    }

    func answer(_ item: FeedbackItem, text: String) {
        append("## Answer \(stamp())\n\(text)\n\n**Status:** answered", to: item)
    }

    func fail(_ item: URL, message: String) {
        guard let i = FeedbackItem(md: item) else { return }
        append("## Run failed \(stamp())\n**Error:** \(message)\n**Status:** failed", to: i)
    }

    /// New session for an item (e.g. because the original one has ended).
    func assign(_ item: FeedbackItem, to session: AgentSession) {
        var lines = item.frontmatter.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func set(_ key: String, _ value: String) {
            if let i = lines.firstIndex(where: { $0.hasPrefix(key + ": ") }) { lines[i] = "\(key): \(value)" }
            else { lines.append("\(key): \(value)") }
        }
        set("session", session.label)
        set("session_id", session.id)
        set("start", session.start)
        let body = item.text.components(separatedBy: "\n---\n").dropFirst().joined(separator: "\n---\n")
        try? (lines.joined(separator: "\n") + "\n---\n" + body).write(to: item.md, atomically: true, encoding: .utf8)
    }

    func delete(_ item: FeedbackItem) {
        let fm = FileManager.default
        item.imageURLs.forEach { try? fm.removeItem(at: $0) }
        try? fm.removeItem(at: item.dir.appendingPathComponent("edit").appendingPathComponent(item.base))
        try? fm.removeItem(at: item.md)
    }

    @discardableResult
    private func move(_ item: FeedbackItem, to folder: URL) -> URL {
        let fm = FileManager.default
        for url in item.imageURLs + [item.md] {
            let dest = folder.appendingPathComponent(url.lastPathComponent)
            if dest != url { try? fm.removeItem(at: dest); try? fm.moveItem(at: url, to: dest) }
        }
        return folder.appendingPathComponent(item.md.lastPathComponent)
    }

    /// Branches of the git checkouts next to the feedback folder (in a workspace, all checkouts in it).
    private func branches(in dir: URL) -> String {
        let fm = FileManager.default
        let parent = dir.deletingLastPathComponent()
        let candidates = dir.lastPathComponent == "feedback"
            ? ((try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            : [parent]
        return candidates.compactMap { d -> String? in
            let git = d.appendingPathComponent(".git")
            guard fm.fileExists(atPath: git.path) else { return nil }
            var head = (try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8)) ?? ""
            if head.isEmpty, let pointer = try? String(contentsOf: git, encoding: .utf8), pointer.hasPrefix("gitdir: ") {
                let gitdir = pointer.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                head = (try? String(contentsOf: URL(fileURLWithPath: gitdir).appendingPathComponent("HEAD"), encoding: .utf8)) ?? ""
            }
            let branch = head.hasPrefix("ref: refs/heads/") ? String(head.dropFirst(16)) : String(head.prefix(8))
            return "\(d.lastPathComponent)=\(branch.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: ", ")
    }
}
