import AppKit

/// Drawing surface of an image in image coordinates (the view is as large as the image; zooming uses the
/// magnification of the enclosing scroll view). Draw, select, move, delete, undo/redo.
final class MarkupCanvas: NSView, NSTextFieldDelegate {
    var page: Page
    /// nil = select.
    var tool: Mark.Kind? = .arrow
    var color = NSColor.systemRed
    var onChange: (() -> Void)?
    private(set) var selected: Int?
    private var undoStack: [[Mark]] = []
    private var redoStack: [[Mark]] = []
    private var dragFrom: NSPoint?
    private var dragSnapshot = false
    private var field: NSTextField?
    private var fieldPoint = NSPoint.zero
    private var fieldReplaces: Int?

    init(page: Page) {
        self.page = page
        super.init(frame: NSRect(origin: .zero, size: page.original.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    private var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }

    override func draw(_ dirtyRect: NSRect) {
        page.original.draw(in: bounds)
        page.marks.forEach { $0.draw() }
        if let selected, selected < page.marks.count {
            let r = page.marks[selected].bounds.insetBy(dx: -4 / zoom, dy: -4 / zoom)
            let path = NSBezierPath(rect: r)
            path.lineWidth = 1.5 / zoom
            path.setLineDash([5 / zoom, 3 / zoom], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    private func change(_ body: () -> Void) {
        undoStack.append(page.marks)
        redoStack.removeAll()
        body()
        needsDisplay = true
        onChange?()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(page.marks)
        page.marks = last
        selected = nil
        needsDisplay = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(page.marks)
        page.marks = next
        selected = nil
        needsDisplay = true
    }

    func deleteSelected() {
        guard let i = selected, i < page.marks.count else { return }
        change { page.marks.remove(at: i) }
        selected = nil
    }

    /// Change color: also recolors a selected mark.
    func setColor(_ c: NSColor) {
        color = c
        if let i = selected, i < page.marks.count { change { page.marks[i].color = c } }
    }

    private func hit(_ p: NSPoint) -> Int? {
        page.marks.indices.reversed().first { page.marks[$0].bounds.insetBy(dx: -6 / zoom, dy: -6 / zoom).contains(p) }
    }

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let tool else {
            selected = hit(p)
            dragFrom = selected == nil ? nil : p
            dragSnapshot = false
            if event.clickCount == 2, let i = selected, page.marks[i].kind == .text { editText(at: page.marks[i].points[0], replacing: i) }
            needsDisplay = true
            return
        }
        selected = nil
        switch tool {
        case .number:
            let n = (page.marks.filter { $0.kind == .number }.compactMap { Int($0.text) }.max() ?? 0) + 1
            change { page.marks.append(Mark(kind: .number, color: color, width: 13 / zoom, points: [p], text: "\(n)")) }
        case .text:
            editText(at: p, replacing: nil)
        case .marker:
            change { page.marks.append(Mark(kind: .marker, color: color, width: 18 / zoom, points: [p, p])) }
        default:
            change { page.marks.append(Mark(kind: tool, color: color, width: 4 / zoom, points: [p, p])) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if tool == nil, let i = selected, let from = dragFrom {
            if !dragSnapshot { undoStack.append(page.marks); redoStack.removeAll(); dragSnapshot = true }
            let dx = p.x - from.x, dy = p.y - from.y
            page.marks[i].points = page.marks[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            dragFrom = p
            needsDisplay = true
            return
        }
        guard field == nil, let last = page.marks.last, [.arrow, .box, .pen, .marker].contains(last.kind), tool != nil else { return }
        if last.kind == .pen || last.kind == .marker {
            page.marks[page.marks.count - 1].points.append(p)
        } else {
            page.marks[page.marks.count - 1].points[1] = p
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { deleteSelected() } else { super.keyDown(with: event) }
    }

    private func editText(at p: NSPoint, replacing: Int?) {
        let size = 16 / zoom
        let f = NSTextField(frame: NSRect(x: p.x, y: p.y - 4 / zoom, width: 260 / zoom, height: size * 1.6))
        f.placeholderString = "Text, ↩ to apply"
        f.font = .systemFont(ofSize: size, weight: .bold)
        f.textColor = color
        f.stringValue = replacing.map { page.marks[$0].text } ?? ""
        f.delegate = self
        f.target = self
        f.action = #selector(commitText)
        addSubview(f)
        window?.makeFirstResponder(f)
        field = f
        fieldPoint = p
        fieldReplaces = replacing
    }

    @objc func commitText() {
        guard let f = field else { return }
        field = nil
        let text = f.stringValue.trimmingCharacters(in: .whitespaces)
        f.removeFromSuperview()
        let replacing = fieldReplaces
        fieldReplaces = nil
        if let i = replacing, i < page.marks.count {
            change { if text.isEmpty { page.marks.remove(at: i) } else { page.marks[i].text = text } }
            selected = nil
        } else if !text.isEmpty {
            change { page.marks.append(Mark(kind: .text, color: color, width: 16 / zoom, points: [fieldPoint], text: text)) }
        }
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        field?.removeFromSuperview()
        field = nil
        fieldReplaces = nil
        return true
    }
}

/// Keeps smaller images centered in the scroll view.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

/// Left area of the editor: shows the image (scroll view with zoom) or, without an image, a hint.
/// Accepts image files via drag and drop and ⌘V.
final class DropArea: NSView {
    let scroll = NSScrollView()
    private let hint = NSTextField(wrappingLabelWithString: "Text only – or drag an image here, ⌘V to paste, “+ Image” for a capture.")
    var onImages: (([Page]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.contentView = CenteringClipView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 6
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: 0.35, of: .black) ?? .darkGray
        scroll.drawsBackground = true
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 14)
        for v in [scroll, hint] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor), hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ canvas: MarkupCanvas?) {
        scroll.documentView = canvas
        hint.isHidden = canvas != nil
        fit()
    }

    func fit() {
        layoutSubtreeIfNeeded()
        guard let doc = scroll.documentView else { return }
        let size = scroll.contentSize
        scroll.magnification = min(size.width / doc.frame.width, size.height / doc.frame.height, 1)
    }

    func zoom(by factor: CGFloat) {
        scroll.magnification = min(max(scroll.magnification * factor, scroll.minMagnification), scroll.maxMagnification)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL] ?? []
        var pages = urls.compactMap(Capture.file)
        if pages.isEmpty, let image = NSImage(pasteboard: sender.draggingPasteboard) {
            pages = [Page(original: image, context: PageContext(source: "Drag & Drop", appearance: Capture.appearance()))]
        }
        guard !pages.isEmpty else { return false }
        onImages?(pages)
        return true
    }
}

/// Strip of thumbnails: click shows an image, ⌘-click adds it to or removes it from the selection,
/// ⇧-click selects a range, ⌫ deletes the selection.
final class ThumbStrip: NSView {
    private let scroll = NSScrollView()
    private let row = NSStackView()
    private(set) var selection: Set<Int> = []
    private var anchor = 0
    var current = 0
    var onShow: ((Int) -> Void)?
    var onDelete: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(row)
        scroll.documentView = doc
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 76),
            row.leadingAnchor.constraint(equalTo: doc.leadingAnchor), row.topAnchor.constraint(equalTo: doc.topAnchor),
            row.trailingAnchor.constraint(equalTo: doc.trailingAnchor), row.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// Selected images; without an explicit selection, the one currently shown.
    var targets: Set<Int> { selection.isEmpty ? [current] : selection }

    func reload(_ images: [NSImage]) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        selection = selection.filter { $0 < images.count }
        for (i, image) in images.enumerated() {
            let b = NSButton(image: image, target: self, action: #selector(click(_:)))
            b.tag = i
            b.imageScaling = .scaleProportionallyUpOrDown
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 4
            b.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            let picked = selection.contains(i)
            b.layer?.borderWidth = picked ? 3 : i == current ? 2 : 0
            b.layer?.borderColor = (picked ? NSColor.systemRed : NSColor.controlAccentColor).cgColor
            b.toolTip = "Image \(i + 1) – ⌘-click: select, ⇧-click: range"
            b.widthAnchor.constraint(equalToConstant: 96).isActive = true
            b.heightAnchor.constraint(equalToConstant: 64).isActive = true
            row.addArrangedSubview(b)
        }
    }

    @objc private func click(_ sender: NSButton) {
        window?.makeFirstResponder(self)
        let i = sender.tag
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        if mods.contains(.command) {
            if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
            anchor = i
        } else if mods.contains(.shift) {
            selection = Set(min(anchor, i)...max(anchor, i))
        } else {
            selection = []
            anchor = i
        }
        current = i
        onShow?(i)
    }

    func clearSelection() { selection = [] }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?() } else { super.keyDown(with: event) }
    }
}

/// Window for an item: mark up images, add more (capture, clipboard, file), pick a session,
/// write a note, optionally have it worked on right away. Also opens saved items for further editing.
/// ⌘↩ saves, Esc discards.
final class FeedbackEditor: NSObject, NSWindowDelegate {
    struct Choice {
        let target: Target
        let dir: URL
        let detail: String
    }

    struct Result {
        let pages: [Page]
        let choice: Choice
        let note: String
        let now: Bool
    }

    private let window: NSWindow
    private let area = DropArea()
    private var canvases: [MarkupCanvas] = []
    private var current = 0
    private let strip = ThumbStrip()
    private let pagesLabel = NSTextField(labelWithString: "")
    private let tools = NSSegmentedControl()
    private let colors = NSSegmentedControl()
    private let picker = NSPopUpButton()
    private let sessionDetail = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextView()
    private let now = NSButton(checkboxWithTitle: "Send to the session now", target: nil, action: nil)
    private let choices: [Choice]
    private let done: (Result?) -> Void
    private var finished = false
    private static let toolKinds: [Mark.Kind?] = [nil, .arrow, .box, .pen, .marker, .number, .text]
    private static let palette: [NSColor] = [.systemRed, .systemYellow, .systemBlue, .systemGreen]

    init(pages: [Page], note text: String = "", title: String = "📸 Feedback", choices: [Choice], preselect: Int,
         done: @escaping (Result?) -> Void) {
        self.choices = choices
        self.done = done
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let side: CGFloat = 340
        let img = pages.first?.original.size ?? NSSize(width: 700, height: 500)
        let s = min((vf.width * 0.85 - side) / img.width, vf.height * 0.85 / img.height, 1)
        let size = NSSize(width: max(620, img.width * s) + side, height: max(620, img.height * s))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 860, height: 620)

        let root = NSStackView()
        root.orientation = .horizontal
        root.spacing = 0
        root.alignment = .top
        area.translatesAutoresizingMaskIntoConstraints = false
        area.setContentHuggingPriority(.defaultLow, for: .horizontal)
        area.onImages = { [weak self] in self?.add($0) }
        root.addArrangedSubview(area)
        root.addArrangedSubview(sidebar(width: side, preselect: preselect))
        area.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        window.contentView = root
        note.string = text
        add(pages)
        if pages.isEmpty { refreshPages() }
        window.center()
    }

    /// For the README screenshots (Demo.swift).
    var nsWindow: NSWindow { window }

    func selectFirstPage() { show(page: 0) }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        area.fit()
        window.makeFirstResponder(note)
    }

    private var canvas: MarkupCanvas? { canvases.indices.contains(current) ? canvases[current] : nil }

    private func add(_ pages: [Page]) {
        guard !pages.isEmpty else { return }
        for p in pages {
            let c = MarkupCanvas(page: p)
            c.tool = Self.toolKinds[max(0, tools.selectedSegment)]
            c.color = Self.palette[max(0, colors.selectedSegment)]
            canvases.append(c)
        }
        current = canvases.count - 1
        refreshPages()
    }

    private func refreshPages() {
        strip.current = current
        strip.reload(canvases.map(\.page.original))
        strip.isHidden = canvases.isEmpty
        let picked = strip.selection.count
        pagesLabel.stringValue = canvases.isEmpty ? "No image – text-only task"
            : "\(canvases.count) image\(canvases.count == 1 ? "" : "s")" + (picked > 0 ? " · \(picked) selected" : "")
        area.show(canvas)
    }

    private func sidebar(width: CGFloat, preselect: Int) -> NSView {
        let toolNames = [("↖", "Select, move, ⌫ deletes, double-click edits text"), ("➚", "Arrow"), ("▢", "Box"),
                         ("✎", "Pen"), ("▮", "Marker"), ("①", "Number"), ("T", "Text")]
        tools.segmentCount = toolNames.count
        for (i, t) in toolNames.enumerated() {
            tools.setLabel(t.0, forSegment: i)
            tools.setToolTip(t.1, forSegment: i)
        }
        tools.trackingMode = .selectOne
        tools.selectedSegment = 1
        tools.target = self
        tools.action = #selector(pickTool)
        let colorNames = ["Red", "Yellow", "Blue", "Green"]
        colors.segmentCount = colorNames.count
        for (i, c) in colorNames.enumerated() { colors.setLabel(c, forSegment: i) }
        colors.trackingMode = .selectOne
        colors.selectedSegment = 0
        colors.target = self
        colors.action = #selector(pickColor)

        func button(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, tip: String? = nil) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.keyEquivalent = key
            b.keyEquivalentModifierMask = mods
            b.toolTip = tip
            b.bezelStyle = .rounded
            return b
        }
        let editRow = NSStackView(views: [
            button("↶", #selector(undo), tip: "Undo ⌘Z"),
            button("↷", #selector(redo), tip: "Redo ⇧⌘Z"),
            button("⌫", #selector(deleteSelected), tip: "Delete selection (⌫)"),
            button("−", #selector(zoomOut), "-", tip: "Zoom out ⌘−"),
            button("⤢", #selector(zoomFit), "0", tip: "Fit ⌘0"),
            button("+", #selector(zoomIn), "+", tip: "Zoom in ⌘+"),
        ])
        editRow.distribution = .fillEqually

        strip.onShow = { [weak self] i in self?.show(page: i) }
        strip.onDelete = { [weak self] in self?.removeSelected() }
        pagesLabel.font = .systemFont(ofSize: 11)
        pagesLabel.textColor = .secondaryLabelColor
        let addMenu = NSPopUpButton(frame: .zero, pullsDown: true)
        addMenu.addItem(withTitle: "+ Image")
        for (title, action) in [("Take Screenshot", #selector(addShot)), ("From Clipboard  ⌘V", #selector(paste(_:))),
                                ("Choose File …", #selector(addFile))] {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            addMenu.menu?.addItem(i)
        }
        let removeButton = button("Delete", #selector(removeSelected), tip: "Delete the selected images (otherwise the one shown), ⌫ in the strip")
        let clearButton = button("Delete All", #selector(removeAll), tip: "Remove all images – leaves a text-only task")
        let pageButtons = NSStackView(views: [addMenu, removeButton, clearButton])
        pageButtons.distribution = .fillEqually
        let pageRow = NSStackView(views: [strip, pagesLabel, pageButtons])
        pageRow.orientation = .vertical
        pageRow.alignment = .leading
        pageRow.spacing = 6
        strip.widthAnchor.constraint(equalTo: pageRow.widthAnchor).isActive = true
        pageButtons.widthAnchor.constraint(equalTo: pageRow.widthAnchor).isActive = true

        for c in choices {
            picker.addItem(withTitle: c.target.label)
            picker.lastItem?.subtitle = c.detail
        }
        picker.selectItem(at: preselect)
        picker.target = self
        picker.action = #selector(pickSession)
        sessionDetail.font = .systemFont(ofSize: 11)
        sessionDetail.textColor = .secondaryLabelColor
        sessionDetail.maximumNumberOfLines = 3
        pickSession()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        note.font = .systemFont(ofSize: 13)
        note.isRichText = false
        note.isVerticallyResizable = true
        note.autoresizingMask = [.width]
        note.textContainerInset = NSSize(width: 4, height: 6)
        scroll.documentView = note
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        let hint = NSTextField(wrappingLabelWithString: "Refer to numbers in the image (①②) in the note: “1 too far right, 2 wrong color”.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        now.toolTip = "If the session is running, the task arrives as a message in its chat; otherwise a fork works in the background. One after another per workspace."
        now.state = UserDefaults.standard.object(forKey: "sendNow") as? Bool ?? true ? .on : .off

        let discard = button("Discard", #selector(cancel), "\u{1b}", [])
        let save = button("Save  ⌘↩", #selector(saveIt), "\r")
        save.bezelColor = .controlAccentColor
        let buttons = NSStackView(views: [discard, save])
        buttons.distribution = .fillEqually

        func label(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
            return l
        }
        let stack = NSStackView(views: [label("MARK UP"), tools, colors, editRow, label("IMAGES"), pageRow,
                                        label("TO SESSION"), picker, sessionDetail, label("NOTE"), scroll, hint, now, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for v in [editRow, pageRow, sessionDetail, hint] { stack.setCustomSpacing(18, after: v) }
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        for v in [tools, colors, editRow, pageRow, picker, sessionDetail, scroll, hint, buttons] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        return stack
    }

    @objc private func pickTool() {
        canvases.forEach { $0.commitText(); $0.tool = Self.toolKinds[tools.selectedSegment] }
    }

    @objc private func pickColor() {
        let c = Self.palette[colors.selectedSegment]
        canvas?.setColor(c)
        canvases.forEach { $0.color = c }
    }

    private func show(page i: Int) {
        canvas?.commitText()
        current = i
        refreshPages()
    }

    @objc private func pickSession() {
        guard choices.indices.contains(picker.indexOfSelectedItem) else { return }
        let c = choices[picker.indexOfSelectedItem]
        sessionDetail.stringValue = c.detail + "\n" + c.dir.path.replacingOccurrences(of: homeURL.path, with: "~")
    }

    @objc private func undo() { canvas?.undo() }
    @objc private func redo() { canvas?.redo() }
    @objc private func deleteSelected() { canvas?.deleteSelected() }
    @objc private func zoomIn() { area.zoom(by: 1.25) }
    @objc private func zoomOut() { area.zoom(by: 0.8) }
    @objc private func zoomFit() { area.fit() }

    /// Hide the window, capture another area, append it as a new image.
    @objc private func addShot() {
        canvas?.commitText()
        window.orderOut(nil)
        Capture.screen { [weak self] page in
            guard let self else { return }
            if let page { self.add([page]) }
            self.show()
        }
    }

    @objc func paste(_ sender: Any?) {
        if let page = Capture.clipboard() { add([page]) } else { NSSound.beep() }
    }

    private var typing: Bool { window.firstResponder is NSTextView }

    /// ⌘Z/⇧⌘Z/⌘V from the Edit menu: text while typing, otherwise marks or an image from the clipboard.
    func handleUndo(redo again: Bool) {
        if typing, let um = window.firstResponder?.undoManager { again ? um.redo() : um.undo() }
        else if again { canvas?.redo() } else { canvas?.undo() }
    }

    func handlePaste() {
        let pb = NSPasteboard.general
        if typing, pb.string(forType: .string) != nil {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        } else {
            paste(nil)
        }
    }

    var isKey: Bool { window.isKeyWindow }

    @objc private func addFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls.compactMap(Capture.file))
    }

    @objc private func removeSelected() {
        guard !canvases.isEmpty else { return }
        let gone = strip.targets
        canvases = canvases.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
        strip.clearSelection()
        current = max(0, min(current - gone.filter { $0 < current }.count, canvases.count - 1))
        refreshPages()
    }

    @objc private func removeAll() {
        guard !canvases.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Remove all \(canvases.count) images?"
        alert.informativeText = "A text-only task remains. Nothing is saved until you click “Save”."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.canvases.removeAll()
            self.strip.clearSelection()
            self.current = 0
            self.refreshPages()
        }
    }

    @objc private func saveIt() {
        canvases.forEach { $0.commitText() }
        guard choices.indices.contains(picker.indexOfSelectedItem) else { return }
        let text = note.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if canvases.isEmpty && text.isEmpty { NSSound.beep(); return }
        UserDefaults.standard.set(now.state == .on, forKey: "sendNow")
        finish(Result(pages: canvases.map(\.page), choice: choices[picker.indexOfSelectedItem], note: text, now: now.state == .on))
    }

    @objc private func cancel() { finish(nil) }

    func windowWillClose(_ notification: Notification) { finish(nil, close: false) }

    private func finish(_ result: Result?, close: Bool = true) {
        guard !finished else { return }
        finished = true
        if close { window.close() }
        done(result)
    }
}
