// agent-feedback: menu bar app for feedback to Claude Code sessions.
// The shortcut (default ⌃⌥S) captures an area (⌃⌥⇧S the full screen, ⌃⌥T copies recognized text); mark it up in the editor, pick a session, write a note.
// Storage: <workspace>/feedback/{inbox,done,edit}/ or <project>/.feedback/…; the `feedback` skill works through them.
// The inbox shows all items with their status: answer questions, accept results or request rework.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = FeedbackStore()
    lazy var runner = Runner(store: store)
    var status: NSStatusItem!
    var editor: FeedbackEditor?
    var inbox: InboxWindow!
    var capturing = false
    var shortcuts = Dictionary(uniqueKeysWithValues: Shortcut.Action.allCases.map { ($0, Shortcut.saved($0)) })
    /// Last known status per item, to report agent results.
    private var known: [String: FeedbackItem.Status] = [:]
    private var notifyUntil = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where other.processIdentifier != me {
            other.forceTerminate()
        }
        NSApp.mainMenu = mainMenu()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        inbox = InboxWindow(actions: inboxActions())
        runner.onChange = { [weak self] in self?.refresh() }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refresh() }
        Hotkey.handler = { [weak self] action in
            switch action {
            case .area: self?.takeScreenshot()
            case .fullScreen: self?.captureFullScreen()
            case .text: self?.captureText()
            }
        }
        for (action, s) in shortcuts { Hotkey.register(s, for: action) }
    }

    // MARK: Status

    /// Items with the runtime status of the queue.
    private func items() -> [FeedbackItem] {
        store.allItems().map { item in
            var i = item
            if runner.isRunning(item.md) { i.status = .running; i.peer = runner.peer(of: item.md) }
            else if runner.isQueued(item.md) { i.status = .queued }
            return i
        }
    }

    private func forAgents(_ all: [FeedbackItem]) -> Int {
        all.filter { $0.needsAgent || $0.status == .queued || $0.status == .running }.count
    }

    /// Menu bar: 📸, then ⏳ (for agents), ❓ (questions) and ✅ (to review). Briefly reports new results.
    private func refresh() {
        runner.tick()
        let all = items()
        inbox?.update(items: all, sessions: activeSessions())
        var news: [String] = []
        for item in all {
            let before = known[item.md.path]
            if before != nil, before != item.status, [FeedbackItem.Status.implemented, .nothingToDo, .question, .failed].contains(item.status) {
                news.append("\(item.icon) \(item.headline.prefix(40))")
            }
            known[item.md.path] = item.status
        }
        if let first = news.first {
            notify(first + (news.count > 1 ? " (+\(news.count - 1))" : ""), seconds: 8)
            return
        }
        guard Date() > notifyUntil else { return }
        let agents = forAgents(all)
        let questions = all.filter { $0.status == .question }.count
        let check = all.filter { $0.status == .implemented || $0.status == .nothingToDo }.count
        status.button?.title = "📸" + (agents > 0 ? " ⏳\(agents)" : "") + (questions > 0 ? " ❓\(questions)" : "") + (check > 0 ? " ✅\(check)" : "")
    }

    /// Short feedback as the title in the menu bar.
    private func notify(_ text: String, seconds: Double = 4) {
        status.button?.title = "📸 \(text)"
        notifyUntil = Date().addingTimeInterval(seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.1) { [weak self] in self?.refresh() }
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = []) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            menu.addItem(i)
        }
        for (action, selector) in [(Shortcut.Action.area, #selector(takeScreenshot)), (.fullScreen, #selector(captureFullScreen)),
                                   (.text, #selector(captureText))] {
            let s = shortcuts[action]!
            add(action.title, selector, key: s.key.lowercased(), mods: s.modifiers)
        }
        add("Image from Clipboard …", #selector(fromClipboard))
        add("Image File …", #selector(fromFile))
        add("Text Only …", #selector(textOnly))
        menu.addItem(.separator())
        let all = items()
        add("Feedback Inbox …  (\(all.filter(\.needsUser).count) for you, \(forAgents(all)) for agents)", #selector(openInbox))
        menu.addItem(.separator())
        let change = NSMenuItem(title: "Change Shortcut", action: nil, keyEquivalent: "")
        change.submenu = NSMenu()
        for (i, action) in Shortcut.Action.allCases.enumerated() {
            let item = NSMenuItem(title: "\(action.title) … (\(shortcuts[action]!.display))", action: #selector(changeShortcut(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            change.submenu?.addItem(item)
        }
        menu.addItem(change)
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// Main menu, so ⌘C/⌘V/⌘Z work in text fields (menu bar apps don't have one otherwise).
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Agent Feedback", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        func add(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            edit.addItem(i)
        }
        add("Undo", #selector(editUndo), "z", target: self)
        add("Redo", #selector(editRedo), "z", [.command, .shift], target: self)
        edit.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), "x")
        add("Copy", #selector(NSText.copy(_:)), "c")
        add("Paste", #selector(editPaste), "v", target: self)
        add("Select All", #selector(NSText.selectAll(_:)), "a")
        add("Close Window", #selector(NSWindow.performClose(_:)), "w")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    @objc private func editUndo() {
        if let editor, editor.isKey { editor.handleUndo(redo: false) } else { NSApp.keyWindow?.firstResponder?.undoManager?.undo() }
    }

    @objc private func editRedo() {
        if let editor, editor.isKey { editor.handleUndo(redo: true) } else { NSApp.keyWindow?.firstResponder?.undoManager?.redo() }
    }

    @objc private func editPaste() {
        if let editor, editor.isKey { editor.handlePaste() } else { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
    }

    @objc private func openInbox() {
        refresh()
        inbox.show()
    }

    @objc private func changeShortcut(_ sender: NSMenuItem) {
        let action = Shortcut.Action.allCases[sender.tag]
        guard let s = recordShortcut(action) else { return }
        shortcuts[action] = s
        s.save(action)
        Hotkey.register(s, for: action)
        notify("\(action.title) is now \(s.display)")
    }

    // MARK: New items

    @objc func takeScreenshot() { capture(fullScreen: false) }

    @objc private func captureFullScreen() { capture(fullScreen: true) }

    private func capture(fullScreen: Bool) {
        guard !capturing, editor == nil, screenAccess() else { return }
        capturing = true
        Capture.screen(fullScreen: fullScreen) { [weak self] page in
            guard let self else { return }
            self.capturing = false
            if let page { self.compose([page]) }
        }
    }

    /// Area capture straight to text on the clipboard, without the editor.
    @objc private func captureText() {
        guard !capturing, screenAccess() else { return }
        capturing = true
        Capture.screen { [weak self] page in
            guard let self else { return }
            guard let page else { self.capturing = false; return }
            Capture.text(in: page.original) { text in
                self.capturing = false
                self.copyText(text)
            }
        }
    }

    private func copyText(_ text: String) {
        guard !text.isEmpty else { return notify("No text recognized.") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let lines = text.split(separator: "\n").count
        notify("📋 Copied \(lines) line\(lines == 1 ? "" : "s") of text")
    }

    private func screenAccess() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }
        CGRequestScreenCaptureAccess()
        notify("Please allow Screen Recording for Agent Feedback.")
        return false
    }

    @objc private func fromClipboard() {
        Capture.previousApp = NSWorkspace.shared.frontmostApplication
        guard let page = Capture.clipboard() else { return notify("No image on the clipboard.") }
        compose([page])
    }

    @objc private func fromFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        compose(panel.urls.compactMap(Capture.file))
    }

    @objc private func textOnly() { compose([]) }

    private func choices(for sessions: [AgentSession]) -> [FeedbackEditor.Choice] {
        sessions.map { .init(target: Target(id: $0.id, start: $0.start, label: $0.label), dir: feedbackDir(for: $0.root), detail: $0.detail) }
    }

    /// Editor for a new item.
    private func compose(_ pages: [Page]) {
        guard editor == nil else { return }
        let sessions = activeSessions()
        guard !sessions.isEmpty else { return notify("No running session to attach this to.") }
        let back = Capture.previousApp
        let last = UserDefaults.standard.string(forKey: "lastTarget")
        editor = FeedbackEditor(pages: pages, choices: choices(for: sessions),
                                preselect: sessions.firstIndex { $0.id == last } ?? 0) { [weak self] result in
            guard let self else { return }
            self.editor = nil
            defer { back?.activate() }
            guard let result else { return }
            UserDefaults.standard.set(result.choice.target.id, forKey: "lastTarget")
            self.save(result, existing: nil)
        }
        editor?.show()
    }

    private func save(_ result: FeedbackEditor.Result, existing: FeedbackItem?) {
        guard let md = store.save(pages: result.pages, note: result.note, target: result.choice.target, dir: result.choice.dir,
                                  existing: existing, now: result.now) else { return }
        let project = result.choice.dir.deletingLastPathComponent().lastPathComponent
        if result.now, let item = FeedbackItem(md: md) {
            runner.enqueue(item)
            let live = Runner.liveSession(result.choice.target.id)
            notify(live != nil ? "💬 Sent to \(live!) – running in its chat" : "⚙️ Task for \(project) running in the background")
        } else {
            notify(existing == nil ? "Filed with \(project). Say “work through feedback” there." : "Saved.")
        }
        refresh()
    }

    // MARK: Inbox actions

    private func inboxActions() -> InboxActions {
        InboxActions(
            run: { [weak self] item in self?.runner.enqueue(item); self?.refresh() },
            cancel: { [weak self] item in self?.runner.cancel(item.md) },
            edit: { [weak self] item in self?.edit(item) },
            assign: { [weak self] item, session in
                guard let self else { return }
                self.store.assign(item, to: session)
                if let fresh = FeedbackItem(md: item.md), fresh.needsAgent { self.runner.enqueue(fresh) }
                self.refresh()
            },
            answer: { [weak self] item in self?.answer(item) },
            accept: { [weak self] item in self?.store.accept(item); self?.refresh() },
            rework: { [weak self] item in self?.rework(item) },
            delete: { [weak self] items in self?.delete(items) },
            create: { [weak self] pages in self?.compose(pages) })
    }

    private func edit(_ item: FeedbackItem) {
        guard editor == nil else { return }
        let sessions = activeSessions()
        let current = sessions.first { $0.id == item.sessionID }
        var list = [FeedbackEditor.Choice(target: current.map { Target(id: $0.id, start: $0.start, label: $0.label) } ?? item.target,
                                          dir: item.dir, detail: current?.detail ?? "Session ended – item stays in the folder")]
        list += choices(for: sessions.filter { feedbackDir(for: $0.root) == item.dir && $0.id != item.sessionID })
        editor = FeedbackEditor(pages: store.pages(of: item), note: item.note.hasPrefix("(no note") || item.note.hasPrefix("(keine Notiz") ? "" : item.note,
                                title: "📸 Edit Feedback", choices: list, preselect: 0) { [weak self] result in
            guard let self else { return }
            self.editor = nil
            guard let result, let fresh = FeedbackItem(md: item.md) else { return }
            self.save(result, existing: fresh)
        }
        editor?.show()
    }

    private func answer(_ item: FeedbackItem) {
        guard let a = askText(title: "Question about “\(item.headline.prefix(50))”", message: item.question,
                              buttons: ["Continue Work", "Save Only"]) else { return }
        store.answer(item, text: a.text)
        if a.button == 0, let fresh = FeedbackItem(md: item.md) { runner.enqueue(fresh) }
        refresh()
    }

    private func rework(_ item: FeedbackItem) {
        let done = item.last("Change")
        guard let r = askText(title: "Rework: “\(item.headline.prefix(50))”",
                              message: (done.isEmpty ? "" : "So far: \(done)\n\n") + "What is still not right? Screenshot and previous results stay with the item.",
                              buttons: ["Request Rework", "Just Note It"]) else { return }
        let md = store.rework(item, text: r.text)
        if r.button == 0, let fresh = FeedbackItem(md: md) { runner.enqueue(fresh) }
        refresh()
    }

    /// Deletes items permanently: note, rendered images, originals and marks; running tasks are cancelled.
    private func delete(_ items: [FeedbackItem]) {
        guard !items.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = items.count == 1 ? "Permanently delete “\(items[0].headline.prefix(50))”?" : "Permanently delete \(items.count) items?"
        let images = items.reduce(0) { $0 + $1.images.count }
        alert.informativeText = "Note\(items.count == 1 ? "" : "s"), \(images) screenshot\(images == 1 ? "" : "s") and all marks will be removed from disk. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for item in items {
            runner.cancel(item.md)
            store.delete(item)
        }
        refresh()
    }
}

/// `--screenshots <dir>` renders the README screenshots from demo data instead of starting the menu bar app.
final class DemoDelegate: NSObject, NSApplicationDelegate {
    let dir: URL
    init(dir: URL) { self.dir = dir }
    func applicationDidFinishLaunching(_ notification: Notification) { Demo.run(into: dir) }
}

let app = NSApplication.shared
let args = CommandLine.arguments
let delegate: NSApplicationDelegate
if let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count {
    delegate = DemoDelegate(dir: URL(fileURLWithPath: args[i + 1]))
} else {
    delegate = AppDelegate()
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
