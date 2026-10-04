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
        }
        .defaultSize(width: 560, height: 640)
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
                Button("Start session") {
                    openWindow(id: "session")
                    NSApp.activate(ignoringOtherApps: true)
                    controller.startSession()
                }
            } else if controller.phase == .studying {
                Button("End session") {
                    openWindow(id: "session")
                    controller.endSessionEarly()
                }
                Text("Ball \(Int(controller.ballSize * 100))%")
                Text(controller.session?.topic ?? "Studying…")
                    .lineLimit(1)
            } else {
                Text(statusLabel)
            }

            Divider()

            Toggle("Demo mode", isOn: Binding(
                get: { controller.demoMode },
                set: { _ in controller.toggleDemoMode() }
            ))
            .disabled(controller.phase != .idle)

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
        case .calibrating(let s): return "Calibrating (\(s)s)"
        case .studying: return "Studying"
        case .ending: return "Ending…"
        case .attentionMap: return "Focus check"
        case .recall: return "Focus check"
        case .breakReady: return "Break ready"
        case .onBreak: return "On break"
        }
    }
}
