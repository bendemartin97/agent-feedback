import AppKit

/// Where images come from: screen area, clipboard or file. Each image gets its own context.
enum Capture {
    /// App that was frontmost before the capture; we return to it after saving.
    static var previousApp: NSRunningApplication?

    /// Starts `screencapture -i` (drag an area, Space = window, Esc = cancel); nil when cancelled.
    static func screen(_ done: @escaping (Page?) -> Void) {
        let context = currentContext()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-\(UUID().uuidString).png")
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", file.path]
            try? p.run()
            p.waitUntilExit()
            let image = NSImage(contentsOf: file)
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async { done(image.map { Page(original: $0, context: context) }) }
        }
    }

    /// Image from the clipboard (screenshot with ⌃⇧⌘4, copied image or copied image file).
    static func clipboard() -> Page? {
        let pb = NSPasteboard.general
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL])?.first {
            return file(url)
        }
        guard let image = NSImage(pasteboard: pb) else { return nil }
        return Page(original: image, context: PageContext(source: "Clipboard", appearance: appearance()))
    }

    static func file(_ url: URL) -> Page? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let at = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date ?? Date()
        return Page(original: image, context: PageContext(source: "File \(url.lastPathComponent)", at: at))
    }

    static func appearance() -> String {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
    }

    /// Context at capture time: active app, Chrome tab, window size, light/dark.
    static func currentContext() -> PageContext {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
        var c = PageContext(source: front?.localizedName ?? "", appearance: appearance())
        if let pid = front?.processIdentifier, let size = windowSize(pid) { c.window = size }
        if front?.bundleIdentifier == "com.google.Chrome" {
            let lines = osascript("""
            tell application "Google Chrome"
              set t to active tab of front window
              return (URL of t) & linefeed & (title of t)
            end tell
            """).components(separatedBy: "\n")
            c.url = lines.first ?? ""
            c.tab = lines.count > 1 ? lines[1] : ""
        }
        return c
    }

    /// Size of the app's frontmost window in points, e.g. “1512×945”.
    private static func windowSize(_ pid: pid_t) -> String? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where w[kCGWindowOwnerPID as String] as? pid_t == pid && w[kCGWindowLayer as String] as? Int == 0 {
            if let b = w[kCGWindowBounds as String] as? [String: CGFloat], let width = b["Width"], let height = b["Height"] {
                return "\(Int(width))×\(Int(height))"
            }
        }
        return nil
    }

    /// Runs AppleScript (the first time, macOS asks for Automation permission).
    private static func osascript(_ script: String) -> String {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
