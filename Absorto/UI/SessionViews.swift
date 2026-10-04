import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SessionWindow: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        ZStack {
            background

            Group {
                switch controller.phase {
                case .idle:
                    IdleView(controller: controller)
                case .requestingPermissions:
                    StatusCard(title: "Absorto", subtitle: controller.statusText)
                case .preparingCalibration(let secondsLeft):
                    CalibrationView(controller: controller, mode: .prepare, secondsLeft: secondsLeft)
                case .calibrating(let secondsLeft):
                    CalibrationView(controller: controller, mode: .calibrate, secondsLeft: secondsLeft)
                case .studying:
                    StudyingView(controller: controller)
                case .attentionLost:
                    AttentionLostView(controller: controller)
                case .ending:
                    StatusCard(title: "Session ending", subtitle: controller.statusText)
                case .submitEvidence:
                    SubmitEvidenceView(controller: controller)
                case .recall:
                    RecallView(controller: controller)
                case .breakStarting(let secondsLeft):
                    BreakStartingView(controller: controller, secondsLeft: secondsLeft)
                case .onBreak:
                    BreakTimerView(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            GeminiStatusBadge(controller: controller)
                .padding(.top, 12)
                .padding(.trailing, 14)
        }
        .frame(minWidth: 540, minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear {
            controller.startGeminiStatusMonitoring()
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.06, blue: 0.08),
                Color(red: 0.09, green: 0.10, blue: 0.13),
                Color(red: 0.04, green: 0.05, blue: 0.07)
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
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            Text("Absorto")
                .font(.system(size: 48, weight: .semibold, design: .serif))
                .foregroundStyle(.white)

            Text("Proof-of-Work Pomodoro")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))

            SessionCrownView(
                selectedMinutes: $controller.selectedSessionMinutes,
                onTick: { controller.audio.playCrownTick() }
            )
                .padding(.vertical, 2)

            Text("Vision tracks focus on-device. Gemini checks tabs and builds your quiz from a photo you drag in.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            VStack(alignment: .leading, spacing: 8) {
                Text("What are you studying today?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                TextField("e.g. Calculus — derivatives", text: $controller.studyTopicDraft)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: 360)

            Button {
                controller.startSession()
            } label: {
                Text("Start \(controller.selectedSessionMinutes)-minute session")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: 260)
                    .padding(.vertical, 12)
                    .background(controller.canStartSession ? Color.white : Color.white.opacity(0.28))
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!controller.canStartSession)

            Text(controller.geminiStatus)
                .font(.system(size: 11))
                .foregroundStyle(controller.geminiBadgeOnline ? .white.opacity(0.4) : .orange.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if let err = controller.errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.85))
            }

            Spacer(minLength: 8)
        }
        .padding(32)
    }
}

struct CalibrationView: View {
    enum Mode { case prepare, calibrate }

    @ObservedObject var controller: SessionController
    var mode: Mode
    var secondsLeft: Int

    var body: some View {
        VStack(spacing: 18) {
            Text(mode == .prepare ? "Get ready" : "Calibrating")
                .font(.system(size: 32, weight: .semibold, design: .serif))
                .foregroundStyle(.white)

            FocusBallView(ballSize: 1, timerProgress: 0)
                .frame(width: 220, height: 220)

            Text(mode == .prepare
                 ? "Sit centered. Face the webcam."
                 : "Hold still — sampling your baseline.")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 8) {
                tipRow("Look at the center of your main display — not the menubar or a side monitor.")
                tipRow("Keep your face lit and fully in frame (eyes visible).")
                tipRow(mode == .prepare
                       ? "You have a few seconds to settle before calibration starts."
                       : "Don’t turn your head until the countdown ends.")
            }
            .frame(maxWidth: 400)
            .padding(.top, 4)

            Text("\(secondsLeft)s")
                .font(.system(size: 42, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
                .padding(.top, 4)

            HStack(spacing: 12) {
                liveChip(String(format: "yaw %.0f°", controller.liveYaw))
                liveChip(String(format: "pitch %.0f°", controller.livePitch))
                liveChip(controller.facePresent ? "face: yes" : "face: no")
            }
            .padding(.top, 8)

            Text("Keep a neutral face during calibration — Absorto learns your open-eye / resting-mouth baseline for yawn & eyes-closed detection.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 4)
        }
        .padding(32)
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func liveChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

struct AttentionLostView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(spacing: 20) {
            Text("Still with us?")
                .font(.system(size: 32, weight: .semibold, design: .serif))
                .foregroundStyle(.white)

            FocusBallView(
                ballSize: 1,
                timerProgress: controller.timerProgress,
                style: .warning
            )
            .frame(width: 240, height: 240)

            Text("Your focus ball vanished, then the warning held for 5 seconds.\nSession is paused.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            HStack(spacing: 14) {
                Button {
                    controller.resumeFromAttentionLost()
                } label: {
                    Text("I'm back")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 120)
                        .padding(.vertical, 11)
                        .padding(.horizontal, 16)
                        .background(Color.white)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    controller.startOverFromAttentionLost()
                } label: {
                    Text("Let's start over")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 120)
                        .padding(.vertical, 11)
                        .padding(.horizontal, 16)
                        .background(Color.white.opacity(0.1))
                        .foregroundStyle(.white.opacity(0.9))
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(32)
    }
}

struct StudyingView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(spacing: 16) {
            Text("Absorto")
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(.white)

            Text(controller.session?.topic ?? "Studying")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            FocusBallView(
                ballSize: controller.ballSize,
                timerProgress: controller.timerProgress,
                style: controller.ballStyle
            )
            .frame(width: 270, height: 270)

            Text(controller.statusText)
                .font(.system(size: 13))
                .foregroundStyle(controller.isWarningBall ? Color.red.opacity(0.85) : Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if !controller.lastNudge.isEmpty {
                Text(controller.lastNudge)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            HStack(spacing: 14) {
                metric("Drifts", "\(controller.confirmedDriftCount)")
                metric("Ball", String(format: "%.0f%%", controller.ballSize * 100))
                metric("Focus", String(format: "%.0f%%", controller.engine.focusScore * 100))
            }
            .padding(.top, 6)

            Text("\(controller.selectedSessionMinutes) min session")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))

            if !controller.windows.canReadWindowTitles {
                VStack(spacing: 8) {
                    Text("App names are detected. For browser *tab* titles, allow Absorto under Accessibility (and Automation when macOS asks).")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    HStack(spacing: 14) {
                        Button("Grant access…") {
                            controller.requestAccessibilityAccess()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))

                        Button("Open Settings") {
                            controller.windows.openAccessibilitySettings()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(.top, 4)
            }

            Button("End session") {
                controller.endSessionEarly()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.5))
            .padding(.top, 6)
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

struct SubmitEvidenceView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(spacing: 18) {
            Text("Study evidence")
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundStyle(.white)

            Text("No screen recording. Drag a photo of your notes — Gemini writes 3 quiz questions from it.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            dropZone
                .frame(maxWidth: 420, minHeight: 220)
                .onDrop(of: [.fileURL, .image, .png, .jpeg, .webP, .tiff], isTargeted: $controller.isDropTargeted) { providers in
                    controller.handleDroppedProviders(providers)
                }

            if controller.isBuildingQuiz {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Gemini is writing your quiz…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            Text("\(controller.confirmedDriftCount) distraction\(controller.confirmedDriftCount == 1 ? "" : "s") this session")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))

            if let err = controller.errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(maxWidth: 360)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }

    @ViewBuilder
    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(controller.isDropTargeted ? 0.12 : 0.05))
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: controller.studyPhotoPreview == nil ? [7, 5] : [])
                )
                .foregroundStyle(
                    controller.isDropTargeted
                        ? Color.white.opacity(0.55)
                        : Color.white.opacity(0.18)
                )

            if let preview = controller.studyPhotoPreview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.arrow.down")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Drag a picture here")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("PNG, JPEG, or HEIC")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }
}

struct RecallView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recall quiz")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)

                Text("Answer all 3. After you submit, your break starts in 5 seconds.")
                    .foregroundStyle(.white.opacity(0.55))

                if !controller.quizSourceNote.isEmpty {
                    Text(controller.quizSourceNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }

                ForEach(controller.questions.indices, id: \.self) { i in
                    questionBlock(i)
                }

                Button {
                    controller.submitAnswers()
                } label: {
                    Text("Submit answers")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(Color.white)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)

                if let err = controller.errorMessage {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.85))
                }
            }
            .padding(32)
            .frame(maxWidth: 520)
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
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(controller.questions[i].selectedOptionIndex == opt ? 0.12 : 0.05))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 6)
    }
}

struct BreakStartingView: View {
    @ObservedObject var controller: SessionController
    var secondsLeft: Int

    var body: some View {
        VStack(spacing: 16) {
            Text("Break starting")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(.white)

            Text("\(secondsLeft)")
                .font(.system(size: 64, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()

            Text("Reviewing your results…")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))

            PenaltyListView(controller: controller, creditAsCheckmark: true)
                .padding(.top, 8)
        }
        .padding(32)
    }
}

struct BreakTimerView: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
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

                if let minutes = controller.session?.breakMinutes {
                    Text("\(minutes) minute break")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }

                if !controller.breakSummary.isEmpty {
                    Text(controller.breakSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }

                PenaltyListView(controller: controller, creditAsCheckmark: true)

                Text("When this hits zero, the next session starts automatically.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                HStack(spacing: 18) {
                    Button("Study now") {
                        controller.skipBreakAndContinue()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))

                    Button("Stop for now") {
                        controller.endBreakToIdle()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: 480)
        }
    }

    private func timeString(_ total: Int) -> String {
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct PenaltyListView: View {
    @ObservedObject var controller: SessionController
    /// Credit lines show a checkmark instead of green “0 min withdrawn” copy.
    var creditAsCheckmark: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.breakPenaltyLines) { line in
                HStack(alignment: .center, spacing: 10) {
                    Text(line.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(line.isCredit ? Color.white.opacity(0.75) : Color.red.opacity(0.9))
                    Spacer(minLength: 12)
                    if line.isCredit, creditAsCheckmark {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.green.opacity(0.9))
                            .accessibilityLabel("Correct")
                    } else {
                        Text(line.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red.opacity(0.85))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
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

struct GeminiStatusBadge: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(controller.geminiBadgeOnline ? Color.green.opacity(0.9) : Color.orange.opacity(0.95))
                .frame(width: 7, height: 7)
            Text(controller.geminiBadgeText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.45))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .help(controller.geminiStatus)
        .accessibilityLabel(controller.geminiStatus)
    }
}
