import AppKit

/// Renders the README screenshots from demo data: `AgentFeedback --screenshots <dir>` (see scripts/screenshots.sh).
/// Opens the editor and the inbox with made-up items, captures each window with `screencapture -l` and quits.
enum Demo {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("agent-feedback-demo-\(UUID().uuidString)")
        let feedback = data.appendingPathComponent("my-app/.feedback")

        let session = Target(id: "demo-session", start: data.appendingPathComponent("my-app").path, label: "Alex · my-app — Booking form")
        let shown = homeURL.appendingPathComponent("code/my-app/.feedback")
        let choice = FeedbackEditor.Choice(target: session, dir: shown, detail: "“match the booking form to the design” · 3 min ago")
        let other = FeedbackEditor.Choice(target: Target(id: "demo-2", start: "", label: "Sam · api — Availability endpoint"),
                                          dir: shown, detail: "“add the timezone to the response” · 12 min ago")

        var form = Page(original: mockPage(dark: true, selected: 1),
                        context: PageContext(source: "Google Chrome", url: "http://localhost:3000/bookings/new", tab: "New booking",
                                             window: "1512×945", appearance: "dark"))
        form.marks = [
            Mark(kind: .box, color: .systemRed, width: 3, points: [CGPoint(x: 892, y: 132), CGPoint(x: 1048, y: 84)]),
            Mark(kind: .number, color: .systemRed, width: 14, points: [CGPoint(x: 1070, y: 128)], text: "1"),
            Mark(kind: .arrow, color: .systemYellow, width: 3, points: [CGPoint(x: 690, y: 190), CGPoint(x: 560, y: 112)]),
            Mark(kind: .number, color: .systemYellow, width: 14, points: [CGPoint(x: 706, y: 200)], text: "2"),
            Mark(kind: .text, color: .systemYellow, width: 17, points: [CGPoint(x: 728, y: 190)], text: "should be primary blue"),
        ]
        let second = Page(original: mockPage(dark: true, selected: 2),
                          context: PageContext(source: "Google Chrome", url: "http://localhost:3000/bookings", tab: "Bookings",
                                               window: "1512×945", appearance: "dark"))
        let note = "1 “Add customer” floats far right – move it next to the Customer field\n2 Save button has the wrong colour, should be the primary blue like on the list page"
        let editor = FeedbackEditor(pages: [form, second], note: note, choices: [choice, other], preselect: 0) { _ in }
        editor.show()
        editor.nsWindow.setContentSize(NSSize(width: 1500, height: 900))
        editor.nsWindow.center()
        editor.selectFirstPage()

        let store = FeedbackStore()
        func item(_ note: String, _ blocks: [String], page: Page?, status: FeedbackItem.Status? = nil, peer: String? = nil) -> FeedbackItem? {
            guard let md = store.save(pages: page.map { [$0] } ?? [], note: note, target: session, dir: feedback, existing: nil, now: false),
                  var i = FeedbackItem(md: md) else { return nil }
            blocks.forEach { store.append($0, to: i) }
            i = FeedbackItem(md: md) ?? i
            if let status { i.status = status; i.peer = peer }
            return i
        }
        let thumb = Page(original: mockPage(dark: false, selected: 0), context: PageContext(source: "Google Chrome"))
        let items = [
            item("“Add customer” floats far right", ["## Result\n**Status:** implemented\n**Change:** The button now sits next to the Customer field and uses the secondary style."], page: form),
            item("Empty state looks broken on mobile", ["## Result\n**Status:** open (question)\n**Question:** Should the illustration be hidden below 480 px or just scaled down?"], page: thumb),
            item("Same spacing bug in the edit dialog", [], page: nil, status: .running, peer: "my-app-42"),
            item("Date picker opens behind the modal", [], page: second, status: .queued),
            item("Export button does nothing", ["## Run failed\n**Error:** Claude is not signed in. Run `claude` once in a terminal and sign in, then retry.\n**Status:** failed"], page: thumb),
        ].compactMap { $0 }

        let inbox = InboxWindow(actions: InboxActions(run: { _ in }, cancel: { _ in }, edit: { _ in }, assign: { _, _ in }, answer: { _ in },
                                                      accept: { _ in }, rework: { _ in }, delete: { _ in }, create: { _ in }))
        let live = AgentSession(id: session.id, root: session.start, start: session.start, project: "my-app", title: "Booking form",
                                prompt: "match the booking form to the design", updated: Date(), pet: "Alex", headline: "Booking form")
        inbox.update(items: items, sessions: [live])
        inbox.selectFilter(2)
        inbox.show()
        inbox.nsWindow.setContentSize(NSSize(width: 980, height: 690))
        inbox.nsWindow.setFrameOrigin(NSPoint(x: 40, y: 40))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            capture(editor.nsWindow, to: dir.appendingPathComponent("editor.png"))
            editor.nsWindow.orderOut(nil)
            capture(inbox.nsWindow, to: dir.appendingPathComponent("inbox.png"))
            inbox.nsWindow.orderOut(nil)
            try? FileManager.default.removeItem(at: data)
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-l\(window.windowNumber)", url.path]
        try? p.run()
        p.waitUntilExit()
        print(FileManager.default.fileExists(atPath: url.path) ? "wrote \(url.path)" : "failed \(url.path)")
    }

    /// A made-up web app page ("New booking" form) to draw on.
    static func mockPage(dark: Bool, selected: Int) -> NSImage {
        NSImage(size: NSSize(width: 1200, height: 760), flipped: true) { r in
            let bg = dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.97, alpha: 1)
            let panel = dark ? NSColor(white: 0.16, alpha: 1) : .white
            let line = dark ? NSColor(white: 0.26, alpha: 1) : NSColor(white: 0.86, alpha: 1)
            let text = dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.12, alpha: 1)
            let muted = dark ? NSColor(white: 0.6, alpha: 1) : NSColor(white: 0.45, alpha: 1)
            let blue = NSColor(srgbRed: 0.17, green: 0.42, blue: 0.97, alpha: 1)
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor, radius: CGFloat = 8) {
                c.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius).fill()
            }
            func label(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: NSColor, bold: Bool = false) {
                (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: c])
            }
            bg.setFill()
            r.fill()
            rect(0, 0, 220, 760, panel, radius: 0)
            label("my-app", 28, 26, 20, text, bold: true)
            for (i, item) in ["Dashboard", "Bookings", "Customers", "Resources", "Settings"].enumerated() {
                if i == 1 { rect(14, 82 + CGFloat(i) * 44, 192, 36, blue.withAlphaComponent(0.18)) }
                label(item, 30, 90 + CGFloat(i) * 44, 15, i == 1 ? blue : muted, bold: i == 1)
            }
            label(selected == 2 ? "Bookings" : "New booking", 260, 34, 26, text, bold: true)
            label(selected == 2 ? "24 upcoming this week" : "Create a booking for a customer", 260, 72, 14, muted)
            if selected == 2 {
                rect(260, 120, 900, 560, panel)
                for row in 0..<8 {
                    let y = 150 + CGFloat(row) * 64
                    rect(284, y, 44, 44, blue.withAlphaComponent(0.25), radius: 22)
                    label(["Mia Weber", "Jonas Klein", "Lea Fischer", "Tom Becker", "Nina Wolf", "Paul Schulz", "Eva Braun", "Max Hoff"][row], 344, y + 4, 15, text, bold: true)
                    label("Meeting room \(row + 2) · 10:00–11:30", 344, y + 24, 13, muted)
                    rect(1040, y + 8, 96, 28, blue, radius: 6)
                    label("Details", 1063, y + 13, 13, .white, bold: true)
                }
                return true
            }
            rect(260, 120, 900, 600, panel)
            let fields = [("Customer", "Mia Weber"), ("Resource", "Meeting room 3"), ("Date", "Tue, 3 Nov 2026"), ("Time", "10:00 – 11:30")]
            for (i, f) in fields.enumerated() {
                let y = 150 + CGFloat(i) * 86
                label(f.0, 290, y, 13, muted, bold: true)
                rect(290, y + 24, 520, 42, bg, radius: 6)
                line.setStroke()
                NSBezierPath(roundedRect: NSRect(x: 290, y: y + 24, width: 520, height: 42), xRadius: 6, yRadius: 6).stroke()
                label(f.1, 306, y + 35, 15, text)
            }
            label("Notes", 290, 494, 13, muted, bold: true)
            rect(290, 518, 520, 90, bg, radius: 6)
            rect(400, 640, 150, 44, NSColor.systemTeal.withAlphaComponent(0.85), radius: 8)
            label("Save booking", 425, 652, 15, .white, bold: true)
            rect(290, 640, 96, 44, line, radius: 8)
            label("Cancel", 312, 652, 15, text)
            rect(900, 630, 140, 44, blue, radius: 8)
            label("Add customer", 918, 642, 15, .white, bold: true)
            return true
        }
    }
}
