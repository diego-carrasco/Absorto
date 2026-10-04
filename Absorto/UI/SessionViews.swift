import SwiftUI

struct SessionWindow: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        ZStack {
            background

            switch controller.phase {
            case .idle:
                IdleView(controller: controller)
            case .requestingPermissions:
                StatusCard(title: "Absorto", subtitle: controller.statusText)
            case .calibrating(let secondsLeft):
                CalibrationView(controller: controller, secondsLeft: secondsLeft)
            case .studying:
                StudyingView(controller: controller)
            case .ending:
                StatusCard(title: "Session ending", subtitle: controller.statusText)
            case .attentionMap:
                AttentionMapView(controller: controller)
            case .recall:
                RecallView(controller: controller)
            case .breakReady:
                BreakReadyView(controller: controller)
            case .onBreak:
                BreakTimerView(controller: controller)
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.07, blue: 0.09),
                Color(red: 0.10, green: 0.11, blue: 0.14),
                Color(red: 0.05, green: 0.05, blue: 0.07)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct IdleView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("Absorto")
                .font(.system(size: 48, weight: .semibold, design: .serif))
                .foregroundStyle(.white)

            Text("Proof-of-Work Pomodoro")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))

            FocusBallView(ballSize: 1, timerProgress: 0)
                .frame(width: 220, height: 220)
                .padding(.vertical, 8)

            Text("A study timer that can tell focus from drift.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button {
                controller.startSession()
            } label: {
                Text("Start session")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Toggle("Demo mode (3s hold, ~90s session)", isOn: Binding(
                get: { controller.demoMode },
                set: { newValue in
                    if controller.demoMode != newValue {
                        controller.toggleDemoMode()
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .foregroundStyle(.white.opacity(0.65))
            .padding(.top, 4)

            if !AppConfig.hasAPIKey {
                Text("No Gemini key yet — add it to Config.plist (repo root).")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.top, 8)
            } else if !controller.geminiStatus.isEmpty {
                Text(controller.geminiStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if let err = controller.errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(maxWidth: 360)
            }

            Spacer()
        }
        .padding(32)
    }
}

struct CalibrationView: View {
    @ObservedObject var controller: SessionController
    var secondsLeft: Int

    var body: some View {
        VStack(spacing: 20) {
            Text("Absorto")
                .font(.system(size: 36, weight: .semibold, design: .serif))
                .foregroundStyle(.white)

            FocusBallView(ballSize: 1, timerProgress: 0)
                .frame(width: 260, height: 260)

            Text("Look at the screen")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)

            Text("Calibrating head position — \(secondsLeft)s")
                .foregroundStyle(.white.opacity(0.6))

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "yaw Δ %.1f°", controller.liveYaw))
                Text(String(format: "pitch Δ %.1f°", controller.livePitch))
                Text(controller.facePresent ? "face: yes" : "face: no")
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.top, 12)
        }
        .padding(32)
    }
}

struct StudyingView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(spacing: 18) {
            Text("Absorto")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(.white)

            Text(controller.session?.topic ?? "Studying")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            FocusBallView(
                ballSize: controller.ballSize,
                timerProgress: controller.timerProgress
            )
            .frame(width: 280, height: 280)

            Text(controller.statusText)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if !controller.lastNudge.isEmpty {
                Text(controller.lastNudge)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if let hint = controller.screen.permissionHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 16) {
                metric("Drifts", "\(controller.drifts.filter { !$0.falseAlarm }.count)")
                metric("Ball", String(format: "%.0f%%", controller.ballSize * 100))
                metric("Focus", String(format: "%.0f%%", controller.engine.focusScore * 100))
            }
            .padding(.top, 8)

            Button("End session") {
                controller.endSessionEarly()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))
            .padding(.top, 12)
        }
        .padding(32)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(width: 72)
    }
}

struct AttentionMapView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Focus check")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)

                Text(controller.attentionMap?.topic ?? "")
                    .foregroundStyle(.white.opacity(0.55))

                Text(controller.attentionMap?.summary ?? "")
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)

                if let spots = controller.attentionMap?.hotspots, !spots.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hotspots")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                        ForEach(spots, id: \.self) { spot in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.white.opacity(0.8))
                                    .frame(width: 6, height: 6)
                                Text(spot)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(.top, 8)
                }

                FocusBallView(
                    ballSize: controller.ballSize,
                    timerProgress: 1
                )
                .frame(height: 160)
                .padding(.vertical, 8)

                Button {
                    controller.continueToRecall()
                } label: {
                    Text("Continue to focus check")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: 480)
        }
    }
}

struct RecallView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Focus check")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)

                Text("Two quick checks on what was on your screen, then a short teach-back. That unlocks your break.")
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 8)

                ForEach(controller.questions.indices, id: \.self) { i in
                    questionBlock(i)
                        .padding(.bottom, 8)
                }

                Button {
                    controller.submitAnswers()
                } label: {
                    Text("Submit & unlock break")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: 480)
        }
    }

    @ViewBuilder
    private func questionBlock(_ i: Int) -> some View {
        let q = controller.questions[i]
        VStack(alignment: .leading, spacing: 8) {
            Text("Q\(i + 1) · \(q.hotspot)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            Text(q.text)
                .foregroundStyle(.white)

            switch q.kind {
            case .multipleChoice:
                ForEach(q.options.indices, id: \.self) { opt in
                    Button {
                        controller.questions[i].selectedOptionIndex = opt
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: controller.questions[i].selectedOptionIndex == opt ? "circle.inset.filled" : "circle")
                                .foregroundStyle(.white.opacity(0.8))
                            Text(q.options[opt])
                                .foregroundStyle(.white.opacity(0.9))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(controller.questions[i].selectedOptionIndex == opt ? 0.12 : 0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            case .teachBack:
                TextField(
                    "Explain in your own words…",
                    text: Binding(
                        get: { controller.questions[i].myAnswer },
                        set: { controller.questions[i].myAnswer = $0 }
                    ),
                    axis: .vertical
                )
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            }
        }
    }
}

struct BreakReadyView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(spacing: 18) {
            Text("Break unlocked")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(.white)

            FocusBallView(ballSize: controller.ballSize, timerProgress: 1)
                .frame(width: 180, height: 180)

            let minutes = controller.session?.breakMinutes ?? 0
            Text(minutes == 0 ? "Short review block unlocked." : "\(minutes) minute break unlocked")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)

            if let g = controller.gradeResult {
                Text(String(format: "Quiz score %.0f%% · focus %.0f%%", g.overallScore * 100, controller.engine.focusScore * 100))
                    .foregroundStyle(.white.opacity(0.55))
                if !g.weakTopic.isEmpty {
                    Text("Next focus: \(g.weakTopic)")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            ForEach(controller.questions) { q in
                if let fb = q.feedback {
                    Text("• \(fb)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: 360, alignment: .leading)
                }
            }

            Button {
                controller.startBreak(autoContinue: true)
            } label: {
                Text(controller.demoMode ? "Start break (auto-continues)" : "Start break")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)

            Button("Skip break — next session") {
                controller.skipBreakAndContinue()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))
        }
        .padding(32)
    }
}

struct BreakTimerView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(spacing: 20) {
            Text("Break")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(.white)

            Text(timeString(controller.breakSecondsRemaining))
                .font(.system(size: 56, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()

            ProgressView(
                value: Double(max(controller.breakTotalSeconds - controller.breakSecondsRemaining, 0)),
                total: Double(max(controller.breakTotalSeconds, 1))
            )
            .tint(.white)
            .frame(maxWidth: 280)

            Text("When this hits zero, the next study session starts automatically.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if let weak = controller.gradeResult?.weakTopic, !weak.isEmpty {
                Text("Optional: skim \(weak)")
                    .foregroundStyle(.white.opacity(0.7))
            }

            HStack(spacing: 18) {
                Button("End break → study now") {
                    controller.skipBreakAndContinue()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))

                Button("Stop for now") {
                    controller.endBreakToIdle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 8)
        }
        .padding(32)
    }

    private func timeString(_ total: Int) -> String {
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct StatusCard: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.system(size: 32, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
            ProgressView()
                .controlSize(.small)
            Text(subtitle)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}
