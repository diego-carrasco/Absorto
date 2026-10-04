import SwiftUI

/// Focus ball in a dark ring. Outer thin ring = timer progress.
/// Warning style expands a red ball after the white focus ball disappears.
struct FocusBallView: View {
    var ballSize: Double
    var timerProgress: Double
    var compact: Bool = false
    /// `.focus` white; `.warning` red crisis ball.
    var style: Style = .focus

    enum Style: Equatable {
        case focus
        case warning
    }

    private var clamped: Double { max(0, min(1, ballSize)) }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let line = max(3, side * 0.035)
            ZStack {
                // Timer ring (outer)
                Circle()
                    .stroke(Color.white.opacity(style == .warning ? 0.08 : 0.12), lineWidth: line)
                    .frame(width: side * 0.96, height: side * 0.96)

                Circle()
                    .trim(from: 0, to: max(0.001, timerProgress))
                    .stroke(
                        (style == .warning ? Color.red : Color.white).opacity(0.55),
                        style: StrokeStyle(lineWidth: line, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: side * 0.96, height: side * 0.96)
                    .animation(.linear(duration: 0.25), value: timerProgress)

                // Dark focus ring
                Circle()
                    .stroke(Color.white.opacity(style == .warning ? 0.14 : 0.22), lineWidth: line * 1.4)
                    .frame(width: side * 0.78, height: side * 0.78)

                // Soft glow
                Circle()
                    .fill(glowColor.opacity(0.08 + 0.14 * clamped))
                    .frame(width: side * 0.82, height: side * 0.82)
                    .blur(radius: compact ? 8 : 16)

                // Ball — shrinks with distraction / expands in warning red
                Circle()
                    .fill(
                        RadialGradient(
                            colors: ballColors,
                            center: .center,
                            startRadius: 0,
                            endRadius: side * 0.35
                        )
                    )
                    .frame(
                        width: side * 0.72 * clamped,
                        height: side * 0.72 * clamped
                    )
                    .shadow(color: glowColor.opacity(style == .warning ? 0.45 : 0.22), radius: compact ? 6 : 16)
                    .animation(.easeOut(duration: 0.35), value: clamped)
                    .animation(.easeInOut(duration: 0.3), value: style)

                if clamped <= 0.02 && style == .focus {
                    Circle()
                        .stroke(Color.white.opacity(0.35), lineWidth: line)
                        .frame(width: side * 0.72, height: side * 0.72)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(compact ? 8 : 24)
    }

    private var glowColor: Color {
        style == .warning ? Color.red : Color.white
    }

    private var ballColors: [Color] {
        switch style {
        case .focus:
            return [Color.white, Color.white.opacity(0.92)]
        case .warning:
            return [
                Color(red: 1.0, green: 0.45, blue: 0.42),
                Color(red: 0.85, green: 0.12, blue: 0.16)
            ]
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        HStack {
            FocusBallView(ballSize: 0.7, timerProgress: 0.35)
                .frame(width: 220, height: 220)
            FocusBallView(ballSize: 0.85, timerProgress: 0.5, style: .warning)
                .frame(width: 220, height: 220)
        }
    }
}
