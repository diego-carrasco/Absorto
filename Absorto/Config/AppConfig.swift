import Foundation

enum AppConfig {
    static var geminiAPIKey: String {
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !env.isEmpty {
            return env
        }
        return loadPlist()?["GEMINI_API_KEY"] as? String ?? ""
    }

    static var geminiModel: String {
        if let env = ProcessInfo.processInfo.environment["GEMINI_MODEL"], !env.isEmpty {
            return env
        }
        // Free-tier-friendly default; override via Config.plist / GEMINI_MODEL.
        return loadPlist()?["GEMINI_MODEL"] as? String ?? "gemini-2.5-flash-lite"
    }

    static var hasAPIKey: Bool {
        let key = geminiAPIKey
        return !key.isEmpty && key != "YOUR_GEMINI_API_KEY_HERE"
    }

    private static func loadPlist() -> [String: Any]? {
        for url in configCandidateURLs() {
            if let dict = NSDictionary(contentsOf: url) as? [String: Any] {
                return dict
            }
        }
        return nil
    }

    /// Search bundle, home folder, cwd, and walk up from the .app for repo-root Config.plist.
    private static func configCandidateURLs() -> [URL] {
        var urls: [URL] = []

        if let bundled = Bundle.main.url(forResource: "Config", withExtension: "plist") {
            urls.append(bundled)
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        urls.append(home.appendingPathComponent(".absorto/Config.plist"))
        urls.append(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Absorto/Config.plist")
        )
        urls.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Config.plist")
        )

        // Walk up from the running .app — Xcode puts builds in DerivedData, far from the repo.
        var dir = Bundle.main.bundleURL
        for _ in 0..<12 {
            dir = dir.deletingLastPathComponent()
            urls.append(dir.appendingPathComponent("Config.plist"))
            // Prefer the repo that also contains the Xcode project.
            let withProject = dir.appendingPathComponent("Absorto.xcodeproj")
            if FileManager.default.fileExists(atPath: withProject.path) {
                urls.insert(dir.appendingPathComponent("Config.plist"), at: 0)
            }
        }

        // De-dupe while preserving order
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}
