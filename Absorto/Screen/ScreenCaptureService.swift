import ScreenCaptureKit
import AppKit
import CoreGraphics
import CoreImage

/// One-shot screen screenshots via ScreenCaptureKit (macOS 14+).
/// Permission is requested once; failed captures do not re-prompt mid-session.
@MainActor
final class ScreenCaptureService: ObservableObject {
    @Published private(set) var lastImage: NSImage?
    @Published var permissionHint: String?
    @Published private(set) var isAuthorized = false

    private var didRequestAccess = false
    /// After a permission failure (or preflight-false post-grant), never call SCKit again this process.
    private var captureDisabled = false
    /// Once a capture succeeds, trust that for the rest of the process even if preflight flickers.
    private var cachedCaptureSuccess = false
    private var showedRestartHint = false

    private static let restartHint =
        "Screen Recording may need an app restart after you grant it. Enable Absorto in System Settings → Privacy & Security → Screen Recording, then quit and reopen Absorto."

    /// Call once at session start. Returns whether capture is usable.
    @discardableResult
    func prepareAccess() async -> Bool {
        if cachedCaptureSuccess || CGPreflightScreenCaptureAccess() {
            isAuthorized = true
            captureDisabled = false
            permissionHint = nil
            return true
        }

        if captureDisabled {
            surfaceRestartHintIfNeeded()
            isAuthorized = false
            return false
        }

        if !didRequestAccess {
            didRequestAccess = true
            permissionHint = "If prompted, allow Screen Recording for Absorto, then restart the app."
            // Shows the system prompt at most once per process lifetime here.
            _ = CGRequestScreenCaptureAccess()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        if CGPreflightScreenCaptureAccess() {
            isAuthorized = true
            captureDisabled = false
            permissionHint = nil
            return true
        }

        // Preflight often stays false until restart even after the user grants access.
        // Do NOT call SCShareableContent here — it re-surfaces the permission sheet.
        isAuthorized = false
        captureDisabled = true
        surfaceRestartHintIfNeeded()
        return false
    }

    func requestAccessHint() {
        if !showedRestartHint {
            permissionHint = "If prompted, allow Screen Recording for Absorto, then restart the app."
        }
    }

    func captureMainDisplayJPEG(quality: CGFloat = 0.75) async -> Data? {
        if cachedCaptureSuccess {
            isAuthorized = true
        } else if captureDisabled {
            return nil
        } else if !isAuthorized && !CGPreflightScreenCaptureAccess() {
            // Do not call ScreenCaptureKit APIs — they re-trigger the permission sheet.
            captureDisabled = true
            isAuthorized = false
            surfaceRestartHintIfNeeded()
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = min(display.width, 1600)
            config.height = min(display.height, 1000)
            config.capturesAudio = false
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            let ns = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            lastImage = ns
            cachedCaptureSuccess = true
            isAuthorized = true
            captureDisabled = false
            permissionHint = nil
            return ImageCodec.jpeg(from: cgImage, quality: quality)
        } catch {
            let message = error.localizedDescription
            if Self.isPermissionError(message) {
                captureDisabled = true
                isAuthorized = false
                cachedCaptureSuccess = false
                surfaceRestartHintIfNeeded()
            } else {
                // Transient capture failure — do not re-prompt; keep authorization state.
                permissionHint = "Screen capture failed: \(message)"
            }
            return nil
        }
    }

    private func surfaceRestartHintIfNeeded() {
        guard !showedRestartHint else { return }
        showedRestartHint = true
        permissionHint = Self.restartHint
    }

    private static func isPermissionError(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("deny")
            || m.contains("denied")
            || m.contains("not authorized")
            || m.contains("permission")
            || m.contains("tcc")
            || m.contains("screen capture")
    }
}
