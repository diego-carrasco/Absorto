import AppKit
import SwiftUI

/// Small NSPanel that floats above all apps and Spaces while studying.
@MainActor
final class FloatingBallPanelController {
    private var panel: NSPanel?
    private var host: NSHostingView<FloatingBallRoot>?

    func show(controller: SessionController) {
        if panel == nil {
            let root = FloatingBallRoot(controller: controller)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(x: 0, y: 0, width: 160, height: 160)

            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 160, height: 160),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.contentView = hosting
            p.isMovableByWindowBackground = true

            // Bottom-right of main screen
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                let origin = NSPoint(
                    x: frame.maxX - 180,
                    y: frame.minY + 24
                )
                p.setFrameOrigin(origin)
            }

            panel = p
            host = hosting
        }

        // Refresh root binding
        host?.rootView = FloatingBallRoot(controller: controller)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func sync(visible: Bool, controller: SessionController) {
        if visible {
            show(controller: controller)
        } else {
            hide()
        }
    }
}

struct FloatingBallRoot: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            FocusBallView(
                ballSize: controller.ballSize,
                timerProgress: controller.timerProgress,
                compact: true
            )
        }
        .frame(width: 160, height: 160)
    }
}
