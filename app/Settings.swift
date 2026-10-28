import AppKit

/// Settings window (⌘,): shortcuts, models and CLI paths. Shortcuts live in UserDefaults, everything else in
/// `~/.claude/agent-feedback/config.json`, which the hooks and the runner read on every use.
final class SettingsWindow: NSObject, NSWindowDelegate, NSComboBoxDelegate, NSTextFieldDelegate {
    /// A shortcut was recorded or reset.
    var onShortcut: ((Shortcut.Action, Shortcut) -> Void)?
    /// Pause the global shortcuts while recording, so pressing the current one doesn't trigger it.
    var onRecording: ((Bool) -> Void)?

    private let window: NSWindow
    private var shortcutButtons: [Shortcut.Action: NSButton] = [:]
    private var recording: Shortcut.Action?
    private var monitor: Any?
    /// Text fields and the config key they edit.
    private var fields: [(NSTextField, key: String, group: String?)] = []
    /// Effort pop-ups per model key (`transport`, `claude`, `codex`, `pi`), stored under `efforts`.
    private var efforts: [String: NSPopUpButton] = [:]
    private var catalog = ModelCatalog()
    private let hint = NSTextField(labelWithString: "")

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Agent Feedback Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
    }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        func header(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
            return l
        }
        func label(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right
            return l
        }
        var rows: [[NSView]] = []

        rows.append([header("SHORTCUTS"), NSGridCell.emptyContentView])
        for action in Shortcut.Action.allCases {
            let b = NSButton(title: "", target: self, action: #selector(record(_:)))
            b.tag = Shortcut.Action.allCases.firstIndex(of: action)!
            b.bezelStyle = .rounded
            b.toolTip = "Click, then press the new shortcut (with ⌃ or ⌘). Esc cancels."
            let reset = NSButton(title: "Default", target: self, action: #selector(resetShortcut(_:)))
            reset.tag = b.tag
            reset.bezelStyle = .rounded
            shortcutButtons[action] = b
            let row = NSStackView(views: [b, reset])
            b.widthAnchor.constraint(equalToConstant: 140).isActive = true
            rows.append([label(action.title), row])
        }

        func field(_ key: String, group: String? = nil, suggestions: [String]? = nil, width: CGFloat = 340) -> NSTextField {
            let f: NSTextField
            if let suggestions {
                let c = NSComboBox()
                c.addItems(withObjectValues: suggestions)
                c.completes = true
                c.delegate = self
                f = c
            } else {
                f = NSTextField()
                f.delegate = self
            }
            f.widthAnchor.constraint(equalToConstant: width).isActive = true
            fields.append((f, key, group))
            return f
        }

        func model(_ key: String) -> NSView {
            let f = field(key, group: "models", suggestions: [], width: 222)
            let e = NSPopUpButton()
            e.target = self
            e.action = #selector(pickEffort(_:))
            e.widthAnchor.constraint(equalToConstant: 110).isActive = true
            efforts[key] = e
            return NSStackView(views: [f, e])
        }
        rows.append([header("MODELS AND EFFORT"), NSGridCell.emptyContentView])
        rows.append([label("Delivery into a Claude chat"), model("transport")])
        rows.append([label("Claude background runs"), model("claude")])
        rows.append([label("Codex background runs"), model("codex")])
        rows.append([label("pi background runs"), model("pi")])

        rows.append([header("FOLDERS AND PATHS"), NSGridCell.emptyContentView])
        rows.append([label("Workspaces folder"), field("workspaces")])
        rows.append([label("claude CLI"), field("claude")])
        rows.append([label("codex CLI"), field("codex")])
        rows.append([label("pi CLI"), field("pi")])

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        hint.stringValue = "Empty = the CLI's default. Codex models come from `codex debug models`; any name can be typed. Applies from the next run."
        rows.append([NSGridCell.emptyContentView, hint])

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        for (i, row) in rows.enumerated() where (row.first as? NSTextField)?.font?.pointSize == 11 && i > 0 {
            grid.row(at: i).topPadding = 12
        }
        for (i, row) in rows.enumerated() where (row.first as? NSTextField)?.font?.pointSize == 11 {
            grid.cell(atColumnIndex: 0, rowIndex: i).xPlacement = .leading
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: i, length: 1))
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
    }

    private func reload() {
        for action in Shortcut.Action.allCases { shortcutButtons[action]?.title = Shortcut.saved(action).display }
        fillModels()
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = ModelCatalog.load()
            DispatchQueue.main.async {
                self.catalog = fresh
                self.fillModels()
            }
        }
        for (f, key, group) in fields {
            f.stringValue = Config.raw(key, in: group)
            switch (group, key) {
            case ("models", "transport"): f.placeholderString = "haiku"
            case ("models", _): f.placeholderString = "CLI default"
            case (nil, "workspaces"): f.placeholderString = "none – feedback lives in <project>/.feedback"
            case (nil, "claude"): f.placeholderString = Config.claude.map { "found: \($0.path.replacingOccurrences(of: homeURL.path, with: "~"))" } ?? "not found"
            case (nil, "codex"): f.placeholderString = Config.codex.map { "found: \($0.path.replacingOccurrences(of: homeURL.path, with: "~"))" } ?? "not found"
            case (nil, "pi"): f.placeholderString = Config.pi.map { "found: \($0.path.replacingOccurrences(of: homeURL.path, with: "~"))" } ?? "not found"
            default: break
            }
        }
    }

    // MARK: Models

    private func modelField(_ key: String) -> NSComboBox? {
        fields.first { $0.group == "models" && $0.key == key }?.0 as? NSComboBox
    }

    private func fillModels() {
        for key in ["transport", "claude", "codex", "pi"] {
            guard let box = modelField(key), let popup = efforts[key] else { continue }
            let models = key == "codex" ? catalog.codex.map(\.slug) : key == "pi" ? [] : catalog.claude
            box.removeAllItems()
            box.addItems(withObjectValues: models)
            let chosen = box.stringValue.isEmpty ? Config.raw(key, in: "models") : box.stringValue
            let levels = key == "pi" ? catalog.piThinking : key == "codex"
                ? (catalog.codex.first { $0.slug == chosen }?.efforts ?? Array(Set(catalog.codex.flatMap(\.efforts))).sorted { ModelCatalog.rank($0) < ModelCatalog.rank($1) })
                : catalog.claudeEfforts
            let stored = Config.raw(key, in: "efforts")
            popup.removeAllItems()
            popup.addItem(withTitle: "Default effort")
            popup.addItems(withTitles: levels + (stored.isEmpty || levels.contains(stored) ? [] : [stored]))
            if stored.isEmpty { popup.selectItem(at: 0) } else { popup.selectItem(withTitle: stored) }
        }
    }

    @objc private func pickEffort(_ sender: NSPopUpButton) {
        guard let key = efforts.first(where: { $0.value === sender })?.key else { return }
        Config.set(key, sender.indexOfSelectedItem <= 0 ? "" : sender.titleOfSelectedItem ?? "", in: "efforts")
    }

    // MARK: Shortcuts

    @objc private func record(_ sender: NSButton) {
        stopRecording()
        let action = Shortcut.Action.allCases[sender.tag]
        recording = action
        sender.title = "Press shortcut …"
        onRecording?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recording else { return event }
            if event.keyCode == 53 { self.stopRecording(); return nil }
            let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
            let key = Shortcut.keyName(Int(event.keyCode)) ?? (event.charactersIgnoringModifiers ?? "").uppercased()
            guard !mods.isEmpty, !key.isEmpty else { return nil }
            let s = Shortcut(keyCode: Int(event.keyCode), modifiers: mods, key: key)
            if let problem = s.problem { self.hint.stringValue = "\(s.display): \(problem)"; return nil }
            if let other = Shortcut.Action.allCases.first(where: { $0 != action && Shortcut.saved($0) == s }) {
                self.hint.stringValue = "\(s.display) is already used for “\(other.title)”."
                return nil
            }
            s.save(action)
            self.onShortcut?(action, s)
            self.hint.stringValue = "\(action.title): \(s.display)"
            self.stopRecording()
            return nil
        }
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        stopRecording()
        let action = Shortcut.Action.allCases[sender.tag]
        action.standard.save(action)
        onShortcut?(action, action.standard)
        reload()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil { onRecording?(false) }
        recording = nil
        reload()
    }

    // MARK: Config fields

    private func store(_ f: NSTextField) {
        guard let entry = fields.first(where: { $0.0 === f }) else { return }
        Config.set(entry.key, f.stringValue, in: entry.group)
        if entry.group == "models" { fillModels() }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let f = obj.object as? NSTextField { store(f) }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let c = notification.object as? NSComboBox, c.indexOfSelectedItem >= 0 else { return }
        c.stringValue = c.itemObjectValue(at: c.indexOfSelectedItem) as? String ?? c.stringValue
        store(c)
    }

    func windowWillClose(_ notification: Notification) {
        window.makeFirstResponder(nil)
        stopRecording()
    }
}

/// Models offered in the settings: Claude aliases and current full names, effort levels from `claude --help`,
/// Codex models with their effort levels from `codex debug models`.
struct ModelCatalog {
    var claude = ["fable", "opus", "sonnet", "haiku", "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
    var claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    var codex: [(slug: String, efforts: [String])] = []
    /// pi's `--thinking` levels.
    var piThinking = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    static func rank(_ effort: String) -> Int {
        ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"].firstIndex(of: effort) ?? 99
    }

    /// Asks both CLIs; keeps the defaults for whatever is not installed. Blocking.
    static func load() -> ModelCatalog {
        var c = ModelCatalog()
        if let claude = Config.claude, let help = run(claude, ["--help"]),
           let line = help.range(of: #"\(low[a-z, ]*\)"#, options: .regularExpression) {
            c.claudeEfforts = help[line].dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let codex = Config.codex, let json = run(codex, ["debug", "models"]),
           let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) {
            let list = (obj as? [String: Any])?["models"] as? [[String: Any]] ?? obj as? [[String: Any]] ?? []
            c.codex = list.filter { $0["visibility"] as? String != "hide" }.compactMap { m in
                guard let slug = m["slug"] as? String else { return nil }
                let levels = (m["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
                return (slug, levels)
            }
        }
        return c
    }

    private static func run(_ tool: URL, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = tool.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
