import AppKit
import ApplicationServices

/// Event-driven front-app / window-title watcher. Costs nothing while the title stays the same.
@MainActor
final class WindowWatcher: ObservableObject {
    @Published private(set) var appName: String = ""
    @Published private(set) var windowTitle: String = ""

    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var seenTitles = Set<String>()
    private var onNewTitle: ((String, String) -> Void)?

    func start(onNewTitle: @escaping (_ appName: String, _ title: String) -> Void) {
        stop()
        self.onNewTitle = onNewTitle
        seenTitles.removeAll()
        requestAccessibilityIfNeeded()

        let center = NSWorkspace.shared.notificationCenter
        let obs = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkFront() }
        }
        observers.append(obs)

        // Light poll for Chrome tab title changes without app switch
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkFront() }
        }
        checkFront()
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        onNewTitle = nil
    }

    func resetCache() {
        seenTitles.removeAll()
    }

    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func checkFront() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Ignore ourselves
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }

        let name = app.localizedName ?? app.bundleIdentifier ?? "App"
        let rawTitle = frontWindowTitle(for: app) ?? name
        let title = Self.normalizeTitle(rawTitle)
        let key = "\(name.lowercased())|\(title.lowercased())"

        appName = name
        windowTitle = title

        // Ignore trivial / unstable AX flicker (empty, same as app name only once).
        guard !title.isEmpty else { return }

        if seenTitles.insert(key).inserted {
            onNewTitle?(name, title)
        }
    }

    private static func normalizeTitle(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip common unread / loading prefixes that churn and re-trigger Gemini.
        while t.hasPrefix("•") || t.hasPrefix("*") || t.hasPrefix("●") {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let range = t.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) {
            t.removeSubrange(range)
        }
        // Collapse whitespace
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t
    }

    private func frontWindowTitle(for app: NSRunningApplication) -> String? {
        // Requires Accessibility permission for reliable titles; best-effort otherwise.
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window)
        guard result == .success, let window else {
            return app.localizedName
        }
        var title: CFTypeRef?
        let tResult = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        guard tResult == .success, let title = title as? String, !title.isEmpty else {
            return app.localizedName
        }
        return title
    }
}
