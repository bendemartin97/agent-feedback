// Checks storage, status and re-editing of feedback items against a throwaway folder (./tests/model.sh).
import AppKit

var failed = false
func check(_ name: String, _ ok: Bool) {
    print(ok ? "ok   \(name)" : "FAIL \(name)")
    if !ok { failed = true }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("af-model-\(UUID().uuidString)")
let dir = root.appendingPathComponent("proj/.feedback")
defer { try? FileManager.default.removeItem(at: root) }
let store = FeedbackStore()
let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { r in NSColor.white.setFill(); r.fill(); return true }
var p1 = Page(original: image, context: PageContext(source: "Google Chrome", url: "https://a.test/1", window: "1440×900"))
p1.marks = [Mark(kind: .number, color: .systemRed, width: 5, points: [CGPoint(x: 10, y: 10)], text: "1")]
let p2 = Page(original: image, context: PageContext(source: "Google Chrome", url: "https://a.test/2"))
let target = Target(id: "s1", start: root.path, label: "Alex · proj")

let md = store.save(pages: [p1, p2], note: "1 too far right", target: target, dir: dir, existing: nil, now: false)!
var item = FeedbackItem(md: md)!
check("new: open in inbox", item.status == .open && item.inInbox)
check("new: two images", item.images.count == 2 && item.imageURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
check("new: context per image", item.text.contains("image-2: ") && item.text.contains("https://a.test/2"))
check("new: English frontmatter", item.text.contains("\nimages: ") && item.text.contains("\nmode: later") && item.field("window") == "1440×900")
check("new: note", item.note == "1 too far right")
check("new: agent defaults to claude", item.agent == "claude" && item.text.contains("\nagent: claude"))

let codexMD = store.save(pages: [], note: "Codex task", target: Target(id: "c1", start: root.path, label: "proj (Codex)", agent: "codex"),
                         dir: dir, existing: nil, now: false)!
check("codex: agent kept for the runner", FeedbackItem(md: codexMD)!.target.agent == "codex")
check("new: .gitignore", FileManager.default.fileExists(atPath: dir.appendingPathComponent(".gitignore").path))
let pages = store.pages(of: item)
check("edit: marks restored", pages.count == 2 && pages[0].marks.count == 1 && pages[0].marks[0].text == "1")
check("edit: context restored", pages[1].context.url == "https://a.test/2")

store.save(pages: [pages[0]], note: "just one now", target: target, dir: dir, existing: item, now: false)
item = FeedbackItem(md: md)!
check("edit: image removed", item.images.count == 1 && !FileManager.default.fileExists(atPath: md.deletingLastPathComponent().appendingPathComponent(md.deletingPathExtension().lastPathComponent + "-2.png").path))
check("edit: new note", item.note == "just one now")

store.append("## Result\n**Status:** open (question)\n**Question:** Which color?", to: item)
item = FeedbackItem(md: md)!
check("question detected", item.status == .question && item.question == "Which color?")
store.answer(item, text: "Blue")
item = FeedbackItem(md: md)!
check("answer: answered", item.status == .answered && item.needsAgent)

// Agent implements it and moves it to done/
let done = dir.appendingPathComponent("done")
for u in item.imageURLs + [item.md] { try! FileManager.default.moveItem(at: u, to: done.appendingPathComponent(u.lastPathComponent)) }
var moved = FeedbackItem(md: done.appendingPathComponent(md.lastPathComponent))!
store.append("## Result\n**Status:** implemented\n**Change:** Button blue", to: moved)
moved = FeedbackItem(md: moved.md)!
check("implemented: waits for the user", moved.status == .implemented && moved.needsUser)
let back = store.rework(moved, text: "A bit darker")
let rework = FeedbackItem(md: back)!
check("rework: back in inbox with image", rework.inInbox && rework.status == .rework && FileManager.default.fileExists(atPath: rework.imageURLs[0].path))
check("rework: history kept", rework.text.contains("Button blue") && rework.text.contains("A bit darker"))
store.accept(rework)
check("accepted", FeedbackItem(md: back)!.status == .accepted)

let textOnly = store.save(pages: [], note: "Same bug on mobile", target: target, dir: dir, existing: nil, now: false)!
let t = FeedbackItem(md: textOnly)!
check("text-only task without images", t.images.isEmpty && t.note == "Same bug on mobile")
store.fail(textOnly, message: "Exit code 1: broken")
check("failure with message", FeedbackItem(md: textOnly)!.status == .failed && FeedbackItem(md: textOnly)!.last("Error") == "Exit code 1: broken")

// Legacy German items written before the switch to English are still read.
let inbox = dir.appendingPathComponent("inbox")
let legacy = inbox.appendingPathComponent("2020-01-01_120000.md")
try! """
---
session: Alex · proj
session_id: s1
start: \(root.path)
projekt: proj
zeit: 2020-01-01 12:00:00
fenster: 1280×800
darstellung: dunkel
bilder: 2020-01-01_120000.png, 2020-01-01_120000-2.png
auftrag: später
---

Knopf zu weit links

## Ergebnis 2020-01-01 12:05
**Status:** offen (Frage)
**Frage:** Wie weit?
""".write(to: legacy, atomically: true, encoding: .utf8)
var old = FeedbackItem(md: legacy)!
check("legacy: bilder: read", old.images == ["2020-01-01_120000.png", "2020-01-01_120000-2.png"])
check("legacy: German keys as fallback", old.field("window") == "1280×800" && old.field("time") == "2020-01-01 12:00:00" && old.field("mode") == "später")
check("legacy: offen (Frage) is a question", old.status == .question && old.question == "Wie weit?")
store.append("## Ergebnis 2020-01-01 12:10\n**Status:** umgesetzt\n**Änderung:** Knopf verschoben", to: old)
old = FeedbackItem(md: legacy)!
check("legacy: umgesetzt is implemented", old.status == .implemented && old.last("Change") == "Knopf verschoben")
let legacyText = inbox.appendingPathComponent("2020-01-01_130000.md")
try! "---\nsession_id: s1\nbilder: \n---\n\n(keine Notiz)\n".write(to: legacyText, atomically: true, encoding: .utf8)
check("legacy: empty bilder: is text only", FeedbackItem(md: legacyText)!.images.isEmpty)

exit(failed ? 1 : 0)
