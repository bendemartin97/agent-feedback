import AppKit

/// What the inbox can do with an item; implemented in the AppDelegate.
struct InboxActions {
    var run: (FeedbackItem) -> Void
    var cancel: (FeedbackItem) -> Void
    var edit: (FeedbackItem) -> Void
    var assign: (FeedbackItem, AgentSession) -> Void
    var answer: (FeedbackItem) -> Void
    var accept: (FeedbackItem) -> Void
    var rework: (FeedbackItem) -> Void
    /// Deletes permanently (note, images, marks) after a confirmation.
    var delete: ([FeedbackItem]) -> Void
    var create: ([Page]) -> Void
}

/// Accepts image files via drag and drop.
final class ImageDropView: NSView {
    var onImages: (([Page]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL] ?? []
        let pages = urls.compactMap(Capture.file)
        guard !pages.isEmpty else { return false }
        onImages?(pages)
        return true
    }
}

/// Persistent overview of all items from all known feedback folders, regardless of whether the
/// original session is still running. Dragging images in creates a new item.
final class InboxWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let list = NSStackView()
    private let filter = NSSegmentedControl(labels: ["For You", "For Agents", "All"], trackingMode: .selectOne, target: nil, action: nil)
    private let empty = NSTextField(labelWithString: "")
    private let actions: InboxActions
    private var items: [FeedbackItem] = []
    private var sessions: [AgentSession] = []
    private var signature = ""
    private var thumbs: [String: NSImage] = [:]
    private var thumbViews: [NSImageView] = []
    private let hint = NSTextField(labelWithString: "Drag images here = new item")
    /// Checked items (path of the `.md`).
    private var picked: Set<String> = []
    private let deletePicked = ClosureButton(title: "", action: {})
    private let deleteAll = ClosureButton(title: "", action: {})

    init(actions: InboxActions) {
        self.actions = actions
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Feedback Inbox"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 420, height: 320)
        window.setFrameAutosaveName("FeedbackInbox")

        let content = ImageDropView()
        content.onImages = { [weak self] in self?.actions.create($0) }
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(refilter)
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        for b in [deletePicked, deleteAll] {
            b.controlSize = .small
            b.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.contentTintColor = .systemRed
        }
        deletePicked.setHandler { [weak self] in
            guard let self else { return }
            self.actions.delete(self.items.filter { self.picked.contains($0.md.path) })
        }
        deleteAll.setHandler { [weak self] in
            guard let self else { return }
            self.actions.delete(self.visible)
        }
        let bar = NSStackView(views: [filter, NSView(), hint, deletePicked, deleteAll])
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 4, right: 14)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        list.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 14, right: 14)
        list.translatesAutoresizingMaskIntoConstraints = false
        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = flipped
        scroll.drawsBackground = false
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center

        for v in [bar, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: flipped.topAnchor), list.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: flipped.trailingAnchor), list.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor), empty.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.contentView = content
        window.center()
    }

    var isVisible: Bool { window.isVisible }

    /// For the README screenshots (Demo.swift).
    var nsWindow: NSWindow { window }

    func selectFilter(_ index: Int) {
        filter.selectedSegment = index
        refilter()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func update(items: [FeedbackItem], sessions: [AgentSession]) {
        self.items = items
        self.sessions = sessions
        picked = picked.filter { p in items.contains { $0.md.path == p } }
        let sig = items.map { "\($0.md.path)|\($0.status)|\($0.changed.timeIntervalSince1970)" }.joined() + sessions.map(\.id).joined()
            + "\(filter.selectedSegment)"
        guard sig != signature else { return }
        signature = sig
        rebuild()
    }

    @objc private func refilter() {
        signature = ""
        update(items: items, sessions: sessions)
    }

    private var visible: [FeedbackItem] {
        switch filter.selectedSegment {
        case 0: return items.filter(\.needsUser)
        case 1: return items.filter { $0.needsAgent || $0.status == .queued || $0.status == .running }
        default: return items
        }
    }

    private func rebuild() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        thumbViews = []
        let shown = visible
        empty.stringValue = ["Nothing to review or answer.", "No open tasks.", "No items yet."][filter.selectedSegment]
        empty.isHidden = !shown.isEmpty
        for item in shown {
            let row = self.row(item)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -28).isActive = true
        }
        applyWidth()
        updateBar()
        filter.setLabel("For You (\(items.filter(\.needsUser).count))", forSegment: 0)
        filter.setLabel("For Agents (\(items.filter { $0.needsAgent || $0.status == .queued || $0.status == .running }.count))", forSegment: 1)
    }

    private func updateBar() {
        let shown = visible.count
        deletePicked.title = "Delete Selected (\(picked.count))"
        deletePicked.isHidden = picked.isEmpty
        deleteAll.title = filter.selectedSegment == 2 ? "Delete All (\(shown))" : "Delete All Here (\(shown))"
        deleteAll.isHidden = shown == 0
    }

    private func thumb(_ item: FeedbackItem) -> NSImage? {
        guard let url = item.imageURLs.first else { return nil }
        let key = url.path + "\(item.changed.timeIntervalSince1970)"
        if let t = thumbs[key] { return t }
        guard let image = NSImage(contentsOf: url) else { return nil }
        thumbs[key] = image
        return image
    }

    private func row(_ item: FeedbackItem) -> NSView {
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        image.layer?.masksToBounds = true
        image.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        if let t = thumb(item) {
            image.image = t
        } else {
            image.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Text")
            image.symbolConfiguration = .init(pointSize: 22, weight: .regular)
            image.contentTintColor = .tertiaryLabelColor
            image.imageScaling = .scaleNone
        }
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 132).isActive = true
        image.heightAnchor.constraint(equalToConstant: 84).isActive = true
        thumbViews.append(image)

        let title = WrappingLabel(wrappingLabelWithString: item.headline)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let active = sessions.contains { $0.id == item.sessionID }
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm"
        let pictures = item.images.count > 1 ? " · \(item.images.count) images" : item.images.isEmpty ? " · text only" : ""
        let meta = NSTextField(labelWithString: "\(item.project) · \(f.string(from: item.changed))\(pictures)")
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = NSStackView(views: [Badge(text: item.statusText, color: statusColor(item.status)), meta])
        status.spacing = 8

        let session = NSTextField(labelWithString: (item.sessionLabel.isEmpty ? "no session" : item.sessionLabel) + (active ? "" : " · session ended"))
        session.font = .systemFont(ofSize: 11)
        session.textColor = active ? .secondaryLabelColor : .systemOrange
        session.lineBreakMode = .byTruncatingTail
        session.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var texts: [NSView] = [title, status, session]
        let extra: String
        switch item.status {
        case .failed: extra = "Error: " + item.last("Error")
        case .question: extra = "Question: " + item.question
        case .implemented, .nothingToDo: extra = item.last("Change")
        default: extra = ""
        }
        if !extra.isEmpty {
            let e = WrappingLabel(wrappingLabelWithString: extra)
            e.font = .systemFont(ofSize: 11)
            e.textColor = item.status == .failed ? .systemRed : .labelColor
            e.maximumNumberOfLines = 2
            e.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            texts.append(e)
        }
        let bar = NSStackView(views: buttonsFor(item, active: active))
        bar.spacing = 6
        texts.append(bar)

        let info = NSStackView(views: texts)
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 4
        info.setCustomSpacing(6, after: title)
        info.setCustomSpacing(2, after: status)
        info.setCustomSpacing(8, after: session)
        info.setCustomSpacing(12, after: texts[texts.count - 2])
        info.setContentHuggingPriority(.defaultLow, for: .horizontal)
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in texts where v !== bar { v.widthAnchor.constraint(lessThanOrEqualTo: info.widthAnchor).isActive = true }

        let check = ClosureButton(title: "", action: {})
        check.setButtonType(.switch)
        check.toolTip = "Select for deletion"
        check.state = picked.contains(item.md.path) ? .on : .off
        check.setHandler { [weak self, weak check] in
            guard let self, let check else { return }
            if check.state == .on { self.picked.insert(item.md.path) } else { self.picked.remove(item.md.path) }
            self.updateBar()
        }
        let row = NSStackView(views: [check, image, info])
        row.alignment = .top
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 14, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        let card = CardView()
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor), row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor), row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    private func statusColor(_ status: FeedbackItem.Status) -> NSColor {
        switch status {
        case .question: return .systemOrange
        case .implemented, .accepted: return .systemGreen
        case .nothingToDo: return .systemGray
        case .failed: return .systemRed
        case .queued, .running: return .systemBlue
        case .open, .rework, .answered: return .systemPurple
        }
    }

    /// Main action(s) as buttons, everything else in the ⋯ menu.
    private func buttonsFor(_ item: FeedbackItem, active: Bool) -> [NSView] {
        func b(_ title: String, primary: Bool = false, _ action: @escaping () -> Void) -> NSButton {
            let button = ClosureButton(title: title, action: action)
            button.controlSize = .small
            if primary { button.bezelColor = .controlAccentColor }
            return button
        }
        var out: [NSView] = []
        switch item.status {
        case .question:
            out.append(b("Answer", primary: true) { [weak self] in self?.actions.answer(item) })
        case .implemented, .nothingToDo:
            out.append(b("Looks Good", primary: true) { [weak self] in self?.actions.accept(item) })
            out.append(b("Rework") { [weak self] in self?.actions.rework(item) })
        case .queued, .running:
            out.append(b("Cancel") { [weak self] in self?.actions.cancel(item) })
        case .failed:
            out.append(b("Try Again", primary: true) { [weak self] in self?.actions.run(item) })
        case .open, .rework, .answered:
            out.append(b("Work On It", primary: true) { [weak self] in self?.actions.run(item) })
        case .accepted:
            break
        }
        let busy = item.status == .queued || item.status == .running
        if !busy {
            out.append(b("Edit") { [weak self] in self?.actions.edit(item) })
        }

        let menu = NSMenu()
        if !busy {
            let candidates = sessions.filter { feedbackDir(for: $0.root) == item.dir && $0.id != item.sessionID }
            if !candidates.isEmpty {
                let assign = NSMenuItem(title: active ? "Assign to Another Session" : "Assign to New Session", action: nil, keyEquivalent: "")
                assign.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
                let sub = NSMenu()
                for s in candidates {
                    let mi = ClosureMenuItem(title: s.label) { [weak self] in self?.actions.assign(item, s) }
                    mi.subtitle = s.detail
                    sub.addItem(mi)
                }
                assign.submenu = sub
                menu.addItem(assign)
                menu.addItem(.separator())
            }
        }
        menu.addItem(ClosureMenuItem(title: "Open Note", symbol: "doc.text") { NSWorkspace.shared.open(item.md) })
        menu.addItem(ClosureMenuItem(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([item.md]) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Delete Permanently", symbol: "trash") { [weak self] in self?.actions.delete([item]) })

        let more = ClosureButton(title: "", action: {})
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More Actions")
        more.controlSize = .small
        more.toolTip = "More Actions"
        more.setHandler { [weak more] in
            guard let more else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
        }
        out.append(more)
        return out
    }

    func windowDidResize(_ notification: Notification) { applyWidth() }

    /// Below 600 pt width, thumbnails and the drag hint are hidden so text and actions have room.
    private func applyWidth() {
        let compact = window.frame.width < 600
        thumbViews.forEach { $0.isHidden = compact }
        hint.isHidden = compact
    }
}

/// Multi-line label that reports its height for the actual width. Without this the stack view assumes
/// one line, and buttons below slide into the card's edge.
final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// Rounded card whose colors follow light/dark switches.
final class CardView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// Colored status badge.
final class Badge: NSView {
    private let color: NSColor

    init(text: String, color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// Menu item with a closure instead of target/action.
final class ClosureMenuItem: NSMenuItem {
    private var handler: () -> Void = {}

    convenience init(title: String, symbol: String? = nil, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @objc private func fire() { handler() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// NSButton with a closure instead of target/action.
final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        handler = action
        target = self
        self.action = #selector(fire)
    }

    func setHandler(_ action: @escaping () -> Void) { handler = action }

    @objc private func fire() { handler?() }
}

/// Small dialog with text on top and a multi-line input field. Returns the text and pressed button (0, 1, …), nil when cancelled.
func askText(title: String, message: String, buttons: [String], placeholder: String = "") -> (text: String, button: Int)? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    buttons.forEach { alert.addButton(withTitle: $0) }
    alert.addButton(withTitle: "Cancel")
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let field = NSTextView(frame: scroll.bounds)
    field.font = .systemFont(ofSize: 13)
    field.isRichText = false
    field.autoresizingMask = [.width]
    field.textContainerInset = NSSize(width: 4, height: 6)
    scroll.documentView = field
    alert.accessoryView = scroll
    alert.window.initialFirstResponder = field
    let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    let text = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard response < buttons.count, !text.isEmpty else { return nil }
    return (text, response)
}
