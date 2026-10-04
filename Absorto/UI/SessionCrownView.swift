import SwiftUI
import AppKit

/// Digital-crown style ring around the Absorto ball for picking session length.
struct SessionCrownView: View {
    @Binding var selectedMinutes: Int
    var options: [Int] = [1, 25, 50]

    @State private var isHovering = false
    @State private var dragAngle: Double?
    @State private var lastTickIndex: Int = 0
    @State private var pulse = false
    @StateObject private var scrollBridge = CrownScrollBridge()

    private var selectedIndex: Int {
        options.firstIndex(of: selectedMinutes) ?? 1
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(pulse ? 0.10 : 0.04), lineWidth: isHovering ? 18 : 10)
                    .frame(width: 200, height: 200)
                    .blur(radius: 8)
                    .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: pulse)

                crownRing
                    .frame(width: 210, height: 210)

                FocusBallView(ballSize: 1, timerProgress: 0)
                    .frame(width: 150, height: 150)
                    .allowsHitTesting(false)
            }
            .frame(width: 230, height: 230)
            .onHover { hovering in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    isHovering = hovering
                }
                scrollBridge.isHovering = hovering
            }
            .onAppear {
                pulse = true
                lastTickIndex = selectedIndex
                scrollBridge.onScroll = { delta in
                    guard abs(delta) > 0.5 else { return }
                    nudge(by: delta > 0 ? 1 : -1)
                }
                scrollBridge.start()
            }
            .onDisappear {
                scrollBridge.stop()
            }
            .gesture(crownDrag)

            Text("\(selectedMinutes) min session")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedMinutes)

            HStack(spacing: 18) {
                ForEach(options, id: \.self) { minutes in
                    Button {
                        select(minutes)
                    } label: {
                        Text("\(minutes)m")
                            .font(.system(size: 12, weight: minutes == selectedMinutes ? .semibold : .medium, design: .rounded))
                            .foregroundStyle(minutes == selectedMinutes ? .white : .white.opacity(0.4))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(minutes == selectedMinutes ? Color.white.opacity(0.14) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(isHovering ? "Scroll or drag the ring to set length" : "Hover the ring · pick a session length")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .animation(.easeOut(duration: 0.2), value: isHovering)
        }
    }

    private var crownRing: some View {
        let thickness: CGFloat = isHovering ? 16 : 7
        let progress = (Double(selectedIndex) + 1) / Double(options.count)

        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: thickness)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        colors: [
                            Color.white.opacity(0.35),
                            Color.white.opacity(0.85),
                            Color.white.opacity(0.55)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: thickness, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: selectedIndex)

            ForEach(options.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == selectedIndex ? 0.9 : 0.28))
                    .frame(width: i == selectedIndex ? 3.5 : 2, height: i == selectedIndex ? thickness + 6 : thickness * 0.7)
                    .offset(y: -105)
                    .rotationEffect(.degrees(Double(i) / Double(max(options.count - 1, 1)) * 240 - 120))
            }

            Capsule()
                .fill(Color.white.opacity(isHovering ? 0.95 : 0.55))
                .frame(width: isHovering ? 5 : 3.5, height: thickness + (isHovering ? 10 : 4))
                .offset(y: -105)
                .rotationEffect(.degrees(Double(selectedIndex) / Double(max(options.count - 1, 1)) * 240 - 120))
                .shadow(color: .white.opacity(isHovering ? 0.35 : 0), radius: 6)
                .animation(.spring(response: 0.32, dampingFraction: 0.75), value: selectedIndex)
                .animation(.spring(response: 0.32, dampingFraction: 0.75), value: isHovering)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isHovering)
    }

    private var crownDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let center = CGPoint(x: 115, y: 115)
                let angle = atan2(value.location.y - center.y, value.location.x - center.x)
                if let last = dragAngle {
                    var delta = angle - last
                    if delta > .pi { delta -= 2 * .pi }
                    if delta < -.pi { delta += 2 * .pi }
                    if abs(delta) > 0.35 {
                        nudge(by: delta > 0 ? 1 : -1)
                        dragAngle = angle
                    }
                } else {
                    dragAngle = angle
                }
            }
            .onEnded { _ in
                dragAngle = nil
            }
    }

    private func nudge(by step: Int) {
        let next = min(max(selectedIndex + step, 0), options.count - 1)
        guard next != selectedIndex else { return }
        select(options[next])
    }

    private func select(_ minutes: Int) {
        guard minutes != selectedMinutes else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            selectedMinutes = minutes
        }
        if lastTickIndex != (options.firstIndex(of: minutes) ?? 0) {
            lastTickIndex = options.firstIndex(of: minutes) ?? 0
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}

@MainActor
private final class CrownScrollBridge: ObservableObject {
    var isHovering = false
    var onScroll: ((CGFloat) -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isHovering else { return event }
            if abs(event.scrollingDeltaY) > 0.1 {
                self.onScroll?(event.scrollingDeltaY)
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        onScroll = nil
    }
}
