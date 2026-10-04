import SwiftUI

/// White focus ball in a dark ring. Outer thin ring = timer progress.
struct FocusBallView: View {
    var ballSize: Double
    var timerProgress: Double
    var compact: Bool = false

    private var clamped: Double { max(0, min(1, ballSize)) }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let line = max(3, side * 0.035)
            ZStack {
                // Timer ring (outer)
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: line)
                    .frame(width: side * 0.96, height: side * 0.96)

                Circle()
                    .trim(from: 0, to: max(0.001, timerProgress))
                    .stroke(
                        Color.white.opacity(0.55),
                        style: StrokeStyle(lineWidth: line, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: side * 0.96, height: side * 0.96)
                    .animation(.linear(duration: 0.25), value: timerProgress)

                // Dark focus ring
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: line * 1.4)
                    .frame(width: side * 0.78, height: side * 0.78)

                // White ball — shrinks with distraction
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white,
                                Color.white.opacity(0.92)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: side * 0.35
                        )
                    )
                    .frame(
                        width: side * 0.72 * clamped,
                        height: side * 0.72 * clamped
                    )
                    .shadow(color: .white.opacity(0.25), radius: compact ? 6 : 18)
                    .animation(.easeOut(duration: 0.35), value: clamped)

                if clamped <= 0.02 {
                    Circle()
                        .stroke(Color.white.opacity(0.35), lineWidth: line)
                        .frame(width: side * 0.72, height: side * 0.72)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(compact ? 8 : 24)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        FocusBallView(ballSize: 0.7, timerProgress: 0.35)
            .frame(width: 320, height: 320)
    }
}
