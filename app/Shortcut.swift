import AppKit
import Carbon

/// The capture shortcut, stored in UserDefaults. Default ⌃⌥S.
struct Shortcut: Equatable {
    var keyCode: Int
    var modifiers: NSEvent.ModifierFlags
    var key: String

    static let standard = Shortcut(keyCode: kVK_ANSI_S, modifiers: [.control, .option], key: "S")

    static var saved: Shortcut {
        let d = UserDefaults.standard
        guard d.object(forKey: "shortcutKeyCode") != nil else { return .standard }
        return Shortcut(keyCode: d.integer(forKey: "shortcutKeyCode"),
                        modifiers: NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "shortcutModifiers"))),
                        key: d.string(forKey: "shortcutKey") ?? "?")
    }

    func save() {
        let d = UserDefaults.standard
        d.set(keyCode, forKey: "shortcutKeyCode")
        d.set(Int(modifiers.rawValue), forKey: "shortcutModifiers")
        d.set(key, forKey: "shortcutKey")
    }

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key
    }

    var carbonModifiers: UInt32 {
        var m = 0
        if modifiers.contains(.control) { m |= controlKey }
        if modifiers.contains(.option) { m |= optionKey }
        if modifiers.contains(.shift) { m |= shiftKey }
        if modifiers.contains(.command) { m |= cmdKey }
        return UInt32(m)
    }

    /// macOS (15+) silently ignores global shortcuts with only ⌥ or ⌥⇧: registration reports noErr, the key press
    /// never arrives. So every shortcut needs ⌃ or ⌘.
    var problem: String? {
        if !modifiers.contains(.control) && !modifiers.contains(.command) {
            return "Please use ⌃ or ⌘ – macOS does not allow only ⌥/⇧ globally."
        }
        return nil
    }
}

/// Global keyboard shortcut via Carbon (needs no Accessibility permission).
enum Hotkey {
    static var handler: (() -> Void)?
    private static var ref: EventHotKeyRef?
    private static var installed = false
    private static var retry: DispatchWorkItem?

    static func register(_ shortcut: Shortcut) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Hotkey.handler?()
                return noErr
            }, 1, &spec, nil, nil)
        }
        retry?.cancel()
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        claim(shortcut)
    }

    /// If another app already holds the shortcut, retry every 5 s.
    private static func claim(_ shortcut: Shortcut) {
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                         EventHotKeyID(signature: OSType(0x4146_4442), id: 1), GetApplicationEventTarget(), 0, &ref)
        guard status != noErr else { return }
        NSLog("agent-feedback: \(shortcut.display) taken (\(status)), retrying in 5 s")
        let work = DispatchWorkItem { claim(shortcut) }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}

/// Dialog that records the next pressed shortcut. Returns nil when cancelled.
func recordShortcut() -> Shortcut? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Press New Shortcut"
    alert.informativeText = "Current: \(Shortcut.saved.display). Combine with ⌃ or ⌘."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Default (⌃⌥S)")
    var picked: Shortcut?
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let key = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !mods.isEmpty, !key.isEmpty, event.keyCode != UInt16(kVK_Escape) else { return event }
        let s = Shortcut(keyCode: Int(event.keyCode), modifiers: mods, key: key)
        if let problem = s.problem {
            alert.informativeText = "\(s.display): \(problem)"
            return nil
        }
        picked = s
        NSApp.stopModal(withCode: .alertThirdButtonReturn)
        return nil
    }
    let response = alert.runModal()
    if let monitor { NSEvent.removeMonitor(monitor) }
    if response == .alertSecondButtonReturn { return .standard }
    return picked
}
