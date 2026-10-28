import AppKit
import Carbon

/// A capture shortcut, stored in UserDefaults under a prefix. Area ⌃⌥S, full screen ⌃⌥⇧S, text ⌃⌥T.
struct Shortcut: Equatable {
    var keyCode: Int
    var modifiers: NSEvent.ModifierFlags
    var key: String

    enum Action: String, CaseIterable {
        case area = "shortcut", fullScreen = "fullScreenShortcut", text = "textShortcut"

        var title: String {
            switch self {
            case .area: return "Take Screenshot"
            case .fullScreen: return "Capture Full Screen"
            case .text: return "Capture Text (OCR)"
            }
        }

        var standard: Shortcut {
            switch self {
            case .area: return Shortcut(keyCode: kVK_ANSI_S, modifiers: [.control, .option], key: "S")
            case .fullScreen: return Shortcut(keyCode: kVK_ANSI_S, modifiers: [.control, .option, .shift], key: "S")
            case .text: return Shortcut(keyCode: kVK_ANSI_T, modifiers: [.control, .option], key: "T")
            }
        }
    }

    static func saved(_ action: Action) -> Shortcut {
        let d = UserDefaults.standard, k = action.rawValue
        guard d.object(forKey: k + "KeyCode") != nil else { return action.standard }
        return Shortcut(keyCode: d.integer(forKey: k + "KeyCode"),
                        modifiers: NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: k + "Modifiers"))),
                        key: keyName(d.integer(forKey: k + "KeyCode")) ?? d.string(forKey: k + "Key") ?? "?")
    }

    func save(_ action: Action) {
        let d = UserDefaults.standard, k = action.rawValue
        d.set(keyCode, forKey: k + "KeyCode")
        d.set(Int(modifiers.rawValue), forKey: k + "Modifiers")
        d.set(key, forKey: k + "Key")
    }

    /// Character on the key in the current layout without any modifier: ⇧3 is “3”, not “§”.
    static func keyName(_ keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw in
            UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let raw = String(utf16CodeUnits: chars, count: length), upper = raw.uppercased()
        let name = upper.count == raw.count ? upper : raw
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
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

/// Global keyboard shortcuts via Carbon (needs no Accessibility permission), one per action.
enum Hotkey {
    static var handler: ((Shortcut.Action) -> Void)?
    private static var refs: [Shortcut.Action: EventHotKeyRef] = [:]
    private static var installed = false
    private static var retries: [Shortcut.Action: DispatchWorkItem] = [:]
    private static let actions = Shortcut.Action.allCases

    static func register(_ shortcut: Shortcut, for action: Shortcut.Action) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                if Hotkey.actions.indices.contains(Int(id.id)) { Hotkey.handler?(Hotkey.actions[Int(id.id)]) }
                return noErr
            }, 1, &spec, nil, nil)
        }
        retries[action]?.cancel()
        if let ref = refs[action] { UnregisterEventHotKey(ref) }
        refs[action] = nil
        claim(shortcut, for: action)
    }

    /// If another app already holds the shortcut, retry every 5 s.
    private static func claim(_ shortcut: Shortcut, for action: Shortcut.Action) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4146_4442), id: UInt32(actions.firstIndex(of: action)!))
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status != noErr else { refs[action] = ref; return }
        NSLog("agent-feedback: \(shortcut.display) taken (\(status)), retrying in 5 s")
        let work = DispatchWorkItem { claim(shortcut, for: action) }
        retries[action] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}

/// Dialog that records the next pressed shortcut. Returns nil when cancelled.
func recordShortcut(_ action: Shortcut.Action) -> Shortcut? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "New Shortcut: \(action.title)"
    alert.informativeText = "Current: \(Shortcut.saved(action).display). Combine with ⌃ or ⌘."
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Default (\(action.standard.display))")
    var picked: Shortcut?
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let key = Shortcut.keyName(Int(event.keyCode)) ?? (event.charactersIgnoringModifiers ?? "").uppercased()
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
    if response == .alertSecondButtonReturn { return action.standard }
    return picked
}
