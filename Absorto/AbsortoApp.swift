import SwiftUI
import AppKit

@main
struct AbsortoApp: App {
    @StateObject private var controller = SessionController()
    @StateObject private var panelBridge = PanelBridge()

    var body: some Scene {
        MenuBarExtra("Absorto", systemImage: "circle.circle") {
            MenuBarContent(controller: controller, panelBridge: panelBridge)
        }

        Window("Absorto", id: "session") {
            SessionWindow(controller: controller)
                .onChange(of: controller.showFloatingBall) { _, visible in
                    panelBridge.sync(visible: visible, controller: controller)
                }
                .onChange(of: controller.ballSize) { _, _ in
                    if controller.showFloatingBall {
                        panelBridge.sync(visible: true, controller: controller)
                    }
                }
                .onChange(of: controller.isWarningBall) { _, _ in
                    if controller.showFloatingBall {
                        panelBridge.sync(visible: true, controller: controller)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    controller.refreshAccessibilityPermission()
                }
        }
        .defaultSize(width: 560, height: 700)
        .windowResizability(.contentSize)
    }
}

@MainActor
final class PanelBridge: ObservableObject {
    private let panel = FloatingBallPanelController()

    func sync(visible: Bool, controller: SessionController) {
        panel.sync(visible: visible, controller: controller)
    }
}

struct MenuBarContent: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var panelBridge: PanelBridge
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button("Open Absorto") {
                openWindow(id: "session")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            if controller.phase == .idle {
                Button("Start session…") {
                    openWindow(id: "session")
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else if controller.phase == .studying {
                Button("End session") {
                    openWindow(id: "session")
                    controller.endSessionEarly()
                }
                Text("Ball \(Int(controller.ballSize * 100))%")
                Text(controller.session?.topic ?? "Studying…")
                    .lineLimit(1)
            } else if controller.phase == .attentionLost {
                Button("I'm back") {
                    openWindow(id: "session")
                    controller.resumeFromAttentionLost()
                }
                Button("Start over") {
                    openWindow(id: "session")
                    controller.startOverFromAttentionLost()
                }
            } else {
                Text(statusLabel)
            }

            Divider()

            Text("Session \(controller.selectedSessionMinutes) min")
                .foregroundStyle(.secondary)

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
    }

    private var statusLabel: String {
        switch controller.phase {
        case .idle: return "Ready"
        case .requestingPermissions: return "Permissions…"
        case .preparingCalibration(let s): return "Get ready (\(s)s)"
        case .calibrating(let s): return "Calibrating (\(s)s)"
        case .studying: return "Studying"
        case .attentionLost: return "Attention lost"
        case .ending: return "Ending…"
        case .submitEvidence: return "Submit photo"
        case .recall: return "Recall quiz"
        case .breakStarting(let s): return "Break in \(s)s"
        case .onBreak: return "On break"
        }
    }
}
