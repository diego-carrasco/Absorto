import AppKit
import ApplicationServices

/// Snapshot of whatever is in front right now.
struct FrontWindowSnapshot: Equatable {
    var appName: String
    var bundleID: String
    var title: String
    /// True when Absorto itself is frontmost (ignore for judgments).
    var isSelf: Bool
    /// True when `title` came from a real window/tab, not just the app name.
    var titleIsReal: Bool

    var cacheKey: String {
        "\(bundleID.lowercased())|\(title.lowercased())"
    }
}

/// Polls the frontmost app/tab and reports the **current** state on every tick.
///
/// State-based on purpose: the session needs to know when the user comes *back*
/// to an on-task tab, which an "only new titles" event stream can never tell it.
@MainActor
final class WindowWatcher: ObservableObject {
    @Published private(set) var appName: String = ""
    @Published private(set) var windowTitle: String = ""
    @Published private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    /// True once we successfully read a real window/tab title.
    @Published private(set) var canReadWindowTitles: Bool = false

    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var onUpdate: ((FrontWindowSnapshot) -> Void)?
    private var lastSnapshot: FrontWindowSnapshot?

    /// Browsers we can query with AppleScript (Automation permission, not Accessibility).
    private static let scriptableBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser"
    ]

    func start(onUpdate: @escaping (FrontWindowSnapshot) -> Void) {
        stopTimers()
        self.onUpdate = onUpdate
        lastSnapshot = nil
        refreshAccessibilityTrust()

        let obs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        observers.append(obs)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        stopTimers()
        onUpdate = nil
        lastSnapshot = nil
    }

    private func stopTimers() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func resetCache() {
        lastSnapshot = nil
    }

    /// Cache key of the window currently in front (nil while Absorto is frontmost).
    var currentKey: String? {
        guard let lastSnapshot, !lastSnapshot.isSelf else { return nil }
        return lastSnapshot.cacheKey
    }

    // MARK: - Permissions

    /// Check trust silently. Never shows a system dialog.
    @discardableResult
    func refreshAccessibilityTrust() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted {
            isAccessibilityTrusted = trusted
        }
        return trusted
    }

    /// User-initiated only: ask macOS to show the Accessibility dialog.
    func requestAccessibilityPrompt() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(opts)
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Polling

    private func tick() {
        refreshAccessibilityTrust()

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundleID = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? bundleID
        let isSelf = bundleID == Bundle.main.bundleIdentifier

        var title = ""
        var titleIsReal = false
        if !isSelf {
            if let resolved = resolveTitle(for: app, bundleID: bundleID), !resolved.isEmpty {
                title = Self.normalizeTitle(resolved)
                titleIsReal = title.caseInsensitiveCompare(name) != .orderedSame
            }
        }
        if title.isEmpty { title = name }
        if titleIsReal { canReadWindowTitles = true }

        let snapshot = FrontWindowSnapshot(
            appName: name,
            bundleID: bundleID,
            title: title,
            isSelf: isSelf,
            titleIsReal: titleIsReal
        )

        if !isSelf {
            appName = name
            windowTitle = title
        }

        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }

    private func resolveTitle(for app: NSRunningApplication, bundleID: String) -> String? {
        // AppleScript first for browsers: it gives the *tab* title and needs only Automation.
        if Self.scriptableBrowsers.contains(bundleID),
           let scripted = browserScriptTitle(bundleID: bundleID), !scripted.isEmpty {
            return scripted
        }
        if let ax = accessibilityTitle(for: app), !ax.isEmpty {
            return ax
        }
        return app.localizedName
    }

    // MARK: - Accessibility titles

    private func accessibilityTitle(for app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if let focused = copyElement(appElement, kAXFocusedWindowAttribute as CFString),
           let title = copyString(focused, kAXTitleAttribute as CFString),
           !title.isEmpty {
            return title
        }

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        if result == .success, let array = windowsRef as? [AnyObject] {
            for item in array {
                let window = item as! AXUIElement
                if let title = copyString(window, kAXTitleAttribute as CFString), !title.isEmpty {
                    return title
                }
            }
        }
        return nil
    }

    private func copyString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: - Browser AppleScript (Automation)

    private func browserScriptTitle(bundleID: String) -> String? {
        let source: String
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            source = """
            tell application id "\(bundleID)"
              if (count of windows) is 0 then return ""
              return name of current tab of front window
            end tell
            """
        default:
            source = """
            tell application id "\(bundleID)"
              if (count of windows) is 0 then return ""
              return title of active tab of front window
            end tell
            """
        }

        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let output = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let title = output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        return title
    }

    private static func normalizeTitle(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("•") || t.hasPrefix("*") || t.hasPrefix("●") {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if let range = t.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) {
            t.removeSubrange(range)
        }
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
