import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Orchestrates topic → calibrate → local Vision watch → Gemini tab checks → photo quiz → scaled break.
@MainActor
final class SessionController: ObservableObject {
    @Published var phase: SessionPhase = .idle
    @Published var session: Session?
    @Published var engine = DriftEngine()
    @Published var drifts: [DriftEvent] = []
    @Published var statusText: String = "Ready"
    @Published var lastNudge: String = ""
    /// Crown-selected study length: 5, 25, or 50 minutes.
    @Published var selectedSessionMinutes: Int = 25
    @Published var timerProgress: Double = 0
    @Published var questions: [Question] = []
    @Published var gradeResult: GradeResult?
    @Published var showFloatingBall: Bool = false
    @Published var liveYaw: Double = 0
    @Published var livePitch: Double = 0
    @Published var facePresent: Bool = false
    @Published var errorMessage: String?
    @Published var geminiStatus: String = "Gemini: checking…"
    /// Compact badge text shown in every phase.
    @Published var geminiBadgeText: String = "Gemini…"
    /// true = green (usable), false = amber/red (offline / limited / no key).
    @Published var geminiBadgeOnline: Bool = false
    @Published var breakSecondsRemaining: Int = 0
    @Published var breakTotalSeconds: Int = 0
    @Published var studyTopicDraft: String = ""
    @Published var studyPhotoJPEG: Data?
    @Published var studyPhotoPreview: NSImage?
    @Published var breakSummary: String = ""
    @Published var breakPenaltyLines: [BreakPenaltyLine] = []
    @Published var isBuildingQuiz: Bool = false
    @Published var quizSourceNote: String = ""
    @Published var isDropTargeted: Bool = false
    /// After white ball hits zero: red ball expands (0…1).
    @Published var warningBallSize: Double = 0
    /// True while showing the red warning ball (before attention-lost pause).
    @Published var isWarningBall: Bool = false

    let camera = CameraService()
    let head = HeadTracker()
    let windows = WindowWatcher()
    let audio = AudioService()
    let gemini = GeminiClient()

    private var timerTask: Task<Void, Never>?
    private var breakTask: Task<Void, Never>?
    private var calibrationTask: Task<Void, Never>?
    private var geminiStatusTask: Task<Void, Never>?
    private var titleCacheAnswers: [String: GeminiClient.WindowJudgment] = [:]
    private var autoContinueAfterBreak = true
    private var declaredTopic: String = ""
    /// After a Vision drift, ignore tab Gemini briefly so look-away ≠ API call.
    private var suppressTabGeminiUntil: Date = .distantPast
    private var lastTabGeminiAt: Date = .distantPast
    private let tabGeminiMinSpacing: TimeInterval = 12
    private let prepareCalibrationSeconds = 5
    private let calibrateSeconds = 10
    private let breakStartDelaySeconds = 5
    private let crisisHoldSeconds: TimeInterval = 5
    /// Window key with a Gemini tab check in flight.
    private var pendingTabCheckKey: String?
    private var warningHoldStartedAt: Date?
    private var lastCrisisTickAt: Date?
    /// Wall-clock pause support for the study timer.
    private var studyElapsedBeforePause: TimeInterval = 0
    private var studySegmentStartedAt: Date?
    private var lastCountdownSecondPlayed: Int?

    var ballSize: Double {
        isWarningBall || phase == .attentionLost ? warningBallSize : engine.ballSize
    }

    var ballStyle: FocusBallView.Style {
        (isWarningBall || phase == .attentionLost) ? .warning : .focus
    }

    var effectiveDuration: TimeInterval {
        TimeInterval(max(1, selectedSessionMinutes)) * 60
    }

    var confirmedDriftCount: Int { drifts.filter { !$0.falseAlarm }.count }
    var canStartSession: Bool {
        !studyTopicDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Start lightweight status polling so the badge stays accurate.
    func startGeminiStatusMonitoring() {
        guard geminiStatusTask == nil else { return }
        geminiStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshGeminiStatus()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    private func mutateEngine(_ body: (inout DriftEngine) -> Void) {
        var eng = engine
        body(&eng)
        engine = eng
    }

    // MARK: - Session lifecycle

    func startSession() {
        let topic = studyTopicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else {
            errorMessage = "Tell Absorto what you are studying today."
            return
        }

        errorMessage = nil
        breakTask?.cancel()
        audio.stopElevatorMusic()
        declaredTopic = topic
        engine = DriftEngine(config: .default)
        drifts = []
        questions = []
        gradeResult = nil
        studyPhotoJPEG = nil
        studyPhotoPreview = nil
        breakSummary = ""
        breakPenaltyLines = []
        isBuildingQuiz = false
        quizSourceNote = ""
        isDropTargeted = false
        clearCrisisState()
        studyElapsedBeforePause = 0
        studySegmentStartedAt = nil
        titleCacheAnswers = [:]
        windows.resetCache()
        timerProgress = 0
        breakSecondsRemaining = 0
        breakTotalSeconds = 0
        phase = .requestingPermissions
        statusText = "Requesting camera…"

        Task {
            let camOK = await camera.requestAccess()
            if !camOK {
                errorMessage = "Camera access is required."
                phase = .idle
                return
            }
            await refreshGeminiStatus()
            beginPreparationThenCalibration()
        }
    }

    func refreshGeminiStatus() async {
        guard await gemini.isConfigured else {
            applyGeminiBadge(
                detail: "Gemini: no API key — offline fallbacks only",
                badge: "Gemini offline",
                online: false
            )
            return
        }
        if await gemini.isRateLimited {
            let detail = await gemini.rateLimitStatusText ?? "Gemini rate-limited — using offline fallback"
            applyGeminiBadge(detail: detail, badge: "Gemini limited", online: false)
            return
        }
        applyGeminiBadge(
            detail: "Gemini online (\(AppConfig.geminiModel))",
            badge: "Gemini online",
            online: true
        )
    }

    private func applyGeminiBadge(detail: String, badge: String, online: Bool) {
        geminiStatus = detail
        geminiBadgeText = badge
        geminiBadgeOnline = online
    }

    private func noteGeminiFallback(_ error: Error) {
        if let g = error as? GeminiError, g.isRateLimitLike {
            applyGeminiBadge(
                detail: "Gemini rate-limited — using offline fallback",
                badge: "Gemini limited",
                online: false
            )
            return
        }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("429")
            || text.localizedCaseInsensitiveContains("503")
            || text.localizedCaseInsensitiveContains("rate") {
            applyGeminiBadge(
                detail: "Gemini rate-limited — using offline fallback",
                badge: "Gemini limited",
                online: false
            )
            return
        }
        applyGeminiBadge(
            detail: "Gemini offline fallback — \(text)",
            badge: "Gemini offline",
            online: false
        )
    }

    private func beginPreparationThenCalibration() {
        showFloatingBall = false
        calibrationTask?.cancel()
        calibrationTask = Task {
            // Prep window — camera preview live, but no baseline samples yet.
            camera.start { [weak self] cg, time in
                guard let self else { return }
                let reading = self.head.process(cgImage: cg, at: time)
                self.liveYaw = reading.yawDelta
                self.livePitch = reading.pitchDelta
                self.facePresent = reading.facePresent
            }

            for left in stride(from: prepareCalibrationSeconds, through: 1, by: -1) {
                phase = .preparingCalibration(secondsLeft: left)
                statusText = "Get ready — face the camera"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }

            head.startCalibration()
            statusText = "Hold still — calibrating…"

            for left in stride(from: calibrateSeconds, through: 1, by: -1) {
                phase = .calibrating(secondsLeft: left)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            _ = head.finishCalibration()

            session = Session(topic: declaredTopic, startedAt: Date(), ballSize: 1)
            phase = .studying
            statusText = "Focusing on: \(declaredTopic)"
            showFloatingBall = true
            startWatchLoop()
            startTimer()
        }
    }

    private func startWatchLoop() {
        camera.start { [weak self] cg, time in
            guard let self, self.phase == .studying else { return }
            let reading = self.head.process(cgImage: cg, at: time)
            self.liveYaw = reading.yawDelta
            self.livePitch = reading.pitchDelta
            self.facePresent = reading.facePresent

            var eng = self.engine
            let output = eng.process(reading: reading)
            self.engine = eng
            self.session?.ballSize = self.engine.ballSize
            self.handleEngineOutput(output, at: time)
            self.updateHoldStatus(reading: reading)
            self.updateCrisisBall(at: time, reading: reading)
        }

        windows.start { [weak self] front in
            guard let self, self.phase == .studying else { return }
            self.evaluateFrontWindow(front)
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        studySegmentStartedAt = Date()
        lastCountdownSecondPlayed = nil
        let duration = effectiveDuration
        timerTask = Task {
            while !Task.isCancelled {
                // Pause the study clock while the red warning ball is up.
                guard phase == .studying, !isWarningBall else {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                let segment = studySegmentStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                let elapsed = studyElapsedBeforePause + max(0, segment)
                timerProgress = min(1, elapsed / duration)
                let remaining = max(0, duration - elapsed)
                playSessionCountdownIfNeeded(remaining: remaining)
                if elapsed >= duration {
                    await endSession()
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func playSessionCountdownIfNeeded(remaining: TimeInterval) {
        let sec = Int(ceil(remaining))
        guard sec >= 1, sec <= 5 else { return }
        guard lastCountdownSecondPlayed != sec else { return }
        lastCountdownSecondPlayed = sec
        audio.playCountdownTick(secondsRemaining: sec)
        if !isWarningBall {
            statusText = "Session ending in \(sec)…"
        }
    }

    // MARK: - Hold countdown + red warning ball

    private func updateHoldStatus(reading: HeadReading) {
        guard phase == .studying, !isWarningBall else { return }
        if let rule = engine.activeHoldRule, engine.activeHoldElapsed > 0 {
            let left = max(0, engine.config.holdDuration - engine.activeHoldElapsed)
            let secs = Int(ceil(left))
            statusText = "\(ruleLabel(rule).capitalized) — shrinking in \(secs)s"
        } else if engine.isDrifting, engine.ballSize > 0.02 {
            statusText = "Distracted — focus ball shrinking"
        }
    }

    private func updateCrisisBall(at time: Date, reading: HeadReading) {
        let thresholds = (
            yaw: engine.config.yawThresholdDegrees,
            pitch: engine.config.pitchThresholdDegrees
        )
        let distracted = reading.activeRule(
            yawThreshold: thresholds.yaw,
            pitchThreshold: thresholds.pitch
        ) != nil

        let dt: TimeInterval
        if let last = lastCrisisTickAt {
            dt = min(0.25, max(0, time.timeIntervalSince(last)))
        } else {
            dt = 1.0 / 30.0
        }
        lastCrisisTickAt = time

        let whiteGone = engine.ballSize <= 0.02

        // Off-task tabs count as distracted even when the face faces the screen.
        let tabDistracted = engine.isWindowDriftActive

        if whiteGone && (distracted || tabDistracted) {
            if !isWarningBall {
                isWarningBall = true
                warningBallSize = 0
                warningHoldStartedAt = nil
                statusText = "Focus gone — come back"
                audio.playWarningRise()
                // Freeze the study timer while red is up.
                if let started = studySegmentStartedAt {
                    studyElapsedBeforePause += Date().timeIntervalSince(started)
                }
                studySegmentStartedAt = nil
            }

            // Stepped red grow (~3s + 2s + 1.5s ≈ 6.5s) — still time to come back.
            if warningBallSize < 1 {
                warningBallSize = min(1, warningBallSize + steppedRedGrowRate(for: warningBallSize) * dt)
            }

            if warningBallSize >= 0.95 {
                if warningHoldStartedAt == nil {
                    warningHoldStartedAt = time
                } else if let start = warningHoldStartedAt,
                          time.timeIntervalSince(start) >= crisisHoldSeconds {
                    enterAttentionLost()
                }
            }
        } else if isWarningBall && !distracted && !tabDistracted {
            // User returned before the pause — clear red, resume timer, recover white.
            clearCrisisState()
            mutateEngine { $0.restoreFocusBall(to: 0.4) }
            session?.ballSize = engine.ballSize
            studySegmentStartedAt = Date()
            statusText = "Back on track"
        }
    }

    private func enterAttentionLost() {
        guard phase == .studying else { return }
        // Freeze study timer.
        if let started = studySegmentStartedAt {
            studyElapsedBeforePause += Date().timeIntervalSince(started)
        }
        studySegmentStartedAt = nil

        warningBallSize = 1
        isWarningBall = true
        showFloatingBall = false
        windows.stop()
        camera.stop()
        phase = .attentionLost
        statusText = "Session paused — attention lost"
        audio.playSessionHalted()
    }

    /// Resume after the red-ball pause.
    func resumeFromAttentionLost() {
        guard phase == .attentionLost else { return }
        clearCrisisState()
        mutateEngine { $0.restoreFocusBall(to: 1) }
        session?.ballSize = 1
        phase = .studying
        statusText = "Welcome back — focusing on: \(session?.topic ?? declaredTopic)"
        showFloatingBall = true
        studySegmentStartedAt = Date()
        startWatchLoop()
    }

    /// Abandon the paused session and return to setup.
    func startOverFromAttentionLost() {
        guard phase == .attentionLost else { return }
        timerTask?.cancel()
        clearCrisisState()
        camera.stop()
        windows.stop()
        showFloatingBall = false
        session = nil
        drifts = []
        phase = .idle
        statusText = "Ready"
        timerProgress = 0
        studyElapsedBeforePause = 0
        studySegmentStartedAt = nil
    }

    private func clearCrisisState() {
        isWarningBall = false
        warningBallSize = 0
        warningHoldStartedAt = nil
        lastCrisisTickAt = nil
    }

    /// Red expands in three constant stages (1× → 2× → 3× pace), like the white shrink.
    private func steppedRedGrowRate(for size: Double) -> Double {
        // Each stage covers 1/3 of the ball; durations ≈ 3s, 2s, 1.5s.
        if size < (1.0 / 3.0) { return (1.0 / 3.0) / 3.0 }
        if size < (2.0 / 3.0) { return (1.0 / 3.0) / 2.0 }
        return (1.0 / 3.0) / 1.5
    }

    func endSessionEarly() {
        Task { await endSession() }
    }

    private func endSession() async {
        guard phase == .studying || phase == .attentionLost else { return }
        timerTask?.cancel()
        windows.stop()
        showFloatingBall = false
        camera.stop()
        clearCrisisState()
        phase = .ending
        statusText = "Wrapping up…"

        session?.endedAt = Date()
        session?.focusScore = engine.focusScore
        session?.ballSize = engine.ballSize

        phase = .submitEvidence
        statusText = "Submit study evidence"
    }

    // MARK: - Photo evidence + quiz (drag-and-drop only)

    @discardableResult
    func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let u = item as? URL {
                        url = u
                    } else {
                        url = nil
                    }
                    guard let url else { return }
                    Task { @MainActor in
                        self.acceptDroppedImage(from: url)
                    }
                }
                return true
            }
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage else { return }
                    Task { @MainActor in
                        self.acceptDroppedImage(image)
                    }
                }
                return true
            }
        }
        return false
    }

    private func acceptDroppedImage(from url: URL) {
        guard let img = NSImage(contentsOf: url) else {
            errorMessage = "Could not read that image."
            return
        }
        acceptDroppedImage(img)
    }

    private func acceptDroppedImage(_ image: NSImage) {
        guard let data = jpegData(from: image) else {
            errorMessage = "Could not read that image."
            return
        }
        studyPhotoPreview = image
        studyPhotoJPEG = data
        errorMessage = nil
        generateQuizFromPhoto()
    }

    private func jpegData(from image: NSImage) -> Data? {
        ImageCodec.jpeg(from: image, maxDimension: 1600, quality: 0.82)
    }

    func generateQuizFromPhoto() {
        guard let jpeg = studyPhotoJPEG else {
            errorMessage = "Drag a study photo into the box first."
            return
        }
        isBuildingQuiz = true
        statusText = "Gemini is writing your quiz…"
        errorMessage = nil
        quizSourceNote = ""

        Task {
            defer { isBuildingQuiz = false }
            let sid = session?.id ?? UUID()
            let topic = session?.topic ?? declaredTopic

            do {
                if await gemini.isConfigured, !(await gemini.isRateLimited) {
                    questions = try await gemini.buildPhotoQuiz(
                        photoJPEG: jpeg,
                        topic: topic,
                        drifts: drifts,
                        sessionId: sid
                    )
                    quizSourceNote = "Questions generated by Gemini from your photo."
                    applyGeminiBadge(
                        detail: "Gemini online — quiz from your photo",
                        badge: "Gemini online",
                        online: true
                    )
                } else {
                    if await gemini.isConfigured {
                        applyGeminiBadge(
                            detail: "Gemini rate-limited — using offline fallback",
                            badge: "Gemini limited",
                            online: false
                        )
                    }
                    questions = localQuestions()
                    quizSourceNote = "Gemini unavailable — using topic fallback questions."
                }
            } catch {
                noteGeminiFallback(error)
                errorMessage = error.localizedDescription
                questions = localQuestions()
                quizSourceNote = "Gemini failed — using topic fallback questions."
            }

            phase = .recall
            statusText = "Recall quiz"
        }
    }

    func submitAnswers() {
        let unanswered = questions.contains { $0.selectedOptionIndex == nil }
        if unanswered {
            errorMessage = "Answer all 3 questions to start your break."
            return
        }
        errorMessage = nil
        statusText = "Grading…"
        applyGrade(localGrade())
        beginBreakAfterDelay()
    }

    private func applyGrade(_ result: GradeResult) {
        gradeResult = result
        for i in questions.indices {
            if i < result.scorePerQuestion.count {
                questions[i].correct = result.scorePerQuestion[i]
            }
            if i < result.feedback.count {
                questions[i].feedback = result.feedback[i]
            }
        }

        let correct = result.scorePerQuestion.filter { $0 }.count
        let wrong = max(0, questions.count - correct)
        let drifts = confirmedDriftCount
        let minutes = DriftEngine.breakMinutes(
            correctCount: correct,
            questionCount: max(questions.count, 1),
            confirmedDrifts: drifts
        )
        session?.breakMinutes = minutes
        session?.focusScore = engine.focusScore

        var lines: [BreakPenaltyLine] = []
        for (idx, q) in questions.enumerated() {
            let ok = q.correct == true
            if ok {
                lines.append(BreakPenaltyLine(
                    title: "Q\(idx + 1) correct",
                    detail: "0 min withdrawn",
                    isCredit: true
                ))
            } else {
                lines.append(BreakPenaltyLine(
                    title: "Q\(idx + 1) missed",
                    detail: "−1 min withdrawn",
                    isCredit: false
                ))
            }
        }
        if drifts == 0 {
            lines.append(BreakPenaltyLine(
                title: "Distractions · 0",
                detail: "0 min withdrawn",
                isCredit: true
            ))
        } else {
            lines.append(BreakPenaltyLine(
                title: "Distractions · \(drifts)",
                detail: "−\(drifts) min withdrawn",
                isCredit: false
            ))
        }
        breakPenaltyLines = lines

        let withdrawn = wrong + drifts
        if wrong == 0 && drifts == 0 {
            breakSummary = "Full break — \(minutes) min, no penalties."
        } else {
            breakSummary = "Break \(minutes) min after −\(withdrawn) min penalties."
        }
        statusText = "Break starting…"
    }

    private func beginBreakAfterDelay() {
        breakTask?.cancel()
        breakTask = Task {
            for left in stride(from: breakStartDelaySeconds, through: 1, by: -1) {
                phase = .breakStarting(secondsLeft: left)
                statusText = "Break starts in \(left)s"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            startBreak(autoContinue: true)
        }
    }

    /// Begin the timed break; when it ends, automatically start the next study session.
    func startBreak(autoContinue: Bool = true) {
        autoContinueAfterBreak = autoContinue
        let minutes = max(1, session?.breakMinutes ?? 5)
        let seconds = minutes * 60

        breakTotalSeconds = seconds
        breakSecondsRemaining = seconds
        phase = .onBreak
        statusText = "On break"
        showFloatingBall = false
        camera.stop()
        windows.stop()
        audio.startElevatorMusic()

        breakTask?.cancel()
        breakTask = Task {
            while breakSecondsRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                breakSecondsRemaining -= 1
            }
            audio.stopElevatorMusic()
            if autoContinueAfterBreak {
                statusText = "Break over — starting next session"
                startSession()
            } else {
                phase = .idle
                statusText = "Ready"
            }
        }
    }

    func skipBreakAndContinue() {
        breakTask?.cancel()
        audio.stopElevatorMusic()
        startSession()
    }

    func endBreakToIdle() {
        breakTask?.cancel()
        audio.stopElevatorMusic()
        phase = .idle
        statusText = "Ready"
    }

    func resetToIdle() {
        timerTask?.cancel()
        calibrationTask?.cancel()
        breakTask?.cancel()
        audio.stopElevatorMusic()
        camera.stop()
        windows.stop()
        showFloatingBall = false
        phase = .idle
        statusText = "Ready"
    }

    // MARK: - Drift handling (local Vision only)

    private func handleEngineOutput(_ output: DriftEngine.Output, at time: Date) {
        switch output {
        case .none:
            break
        case .stillDrifting:
            session?.ballSize = engine.ballSize
        case .refocused:
            statusText = "Back on track"
        case .fire(let rule, let held):
            confirmDriftLocally(rule: rule, heldFor: held, at: time)
        }
    }

    private func confirmDriftLocally(rule: DriftRule, heldFor: TimeInterval, at time: Date) {
        // Vision-only path — never call Gemini here (keeps nudges instant).
        suppressTabGeminiUntil = time.addingTimeInterval(6)
        audio.playChime()
        var event = DriftEvent(
            sessionId: session?.id ?? UUID(),
            time: time,
            source: .camera,
            rule: rule,
            seconds: heldFor
        )
        applyLocalDriftConfirmation(rule: rule, heldFor: heldFor, event: &event)
        session?.ballSize = engine.ballSize
    }

    private func applyLocalDriftConfirmation(rule: DriftRule, heldFor: TimeInterval, event: inout DriftEvent) {
        // Shrink is owned by DriftEngine continuous taper while distracted — no extra burst here.
        event.category = localCategory(for: rule)
        event.severity = 3
        event.studying = session?.topic
        event.nudgeText = localNudge(for: rule)
        lastNudge = event.nudgeText ?? ""
        drifts.append(event)
        statusText = "Distracted — focus ball shrinking"
        // UI sound only (chime already played) — no spoken narrator.
        if engine.shouldSpeak(at: Date()) {
            mutateEngine { $0.markVoiceSpoken(at: Date()) }
        }
    }

    private func ruleLabel(_ rule: DriftRule) -> String {
        switch rule {
        case .noFace: return "no face"
        case .eyesClosed: return "eyes closed"
        case .yawn: return "yawn"
        case .headTurned: return "head turned"
        case .headDown: return "head down"
        case .offTaskWindow: return "off-task tab"
        }
    }

    // MARK: - Tab / window state

    /// Called on every watcher tick with the *current* front window.
    /// State-based so returning to an on-task tab stops the shrink immediately.
    private func evaluateFrontWindow(_ front: FrontWindowSnapshot) {
        guard phase == .studying else { return }
        // Looking at Absorto itself is neutral — keep whatever state we had.
        if front.isSelf { return }

        let topic = session?.topic ?? declaredTopic
        let key = front.cacheKey

        if let cached = titleCacheAnswers[key] {
            applyTabVerdict(cached, front: front, topic: topic)
            return
        }

        let local = localWindowJudgment(
            app: front.appName,
            title: front.title,
            topic: topic,
            bundleID: front.bundleID
        )
        if local.onTask != "unsure" {
            titleCacheAnswers[key] = local
            applyTabVerdict(local, front: front, topic: topic)
            return
        }

        // Unknown title: assume on-task (no false shrink) and ask Gemini once.
        applyTabVerdict(local, front: front, topic: topic)
        requestGeminiTabCheck(key: key, front: front, topic: topic)
    }

    private func applyTabVerdict(
        _ judgment: GeminiClient.WindowJudgment,
        front: FrontWindowSnapshot,
        topic: String
    ) {
        if judgment.onTask == "no" {
            let now = Date()
            var firedNewEvent = false
            mutateEngine { eng in
                if case .fire = eng.fireWindowDrift(at: now) { firedNewEvent = true }
            }
            session?.ballSize = engine.ballSize

            if firedNewEvent {
                audio.playChime()
                let label = front.titleIsReal ? front.title : front.appName
                var event = DriftEvent(
                    sessionId: session?.id ?? UUID(),
                    time: now,
                    source: .window,
                    rule: .offTaskWindow,
                    category: .lookingElsewhere,
                    severity: 3,
                    studying: topic,
                    nudgeText: "Off-task: \(label). \(judgment.reason)"
                )
                lastNudge = event.nudgeText ?? ""
                drifts.append(event)
                if engine.shouldSpeak(at: now) {
                    mutateEngine { $0.markVoiceSpoken(at: now) }
                }
            }
            if !isWarningBall {
                let label = front.titleIsReal ? front.title : front.appName
                statusText = "Off-task: \(label) — ball shrinking"
            }
            return
        }

        // On-task (or unknown): stop any tab-driven shrink.
        guard engine.isWindowDriftActive else { return }
        mutateEngine { $0.clearWindowDrift() }
        session?.ballSize = engine.ballSize
        lastNudge = ""
        if !isWarningBall {
            statusText = "Back on task — focusing on: \(topic)"
        }
    }

    private func requestGeminiTabCheck(key: String, front: FrontWindowSnapshot, topic: String) {
        // One in-flight check at a time, spaced so free-tier quota is not burned.
        guard pendingTabCheckKey != key else { return }
        let now = Date()
        guard now >= suppressTabGeminiUntil,
              now.timeIntervalSince(lastTabGeminiAt) >= tabGeminiMinSpacing else { return }

        pendingTabCheckKey = key
        Task {
            defer { if pendingTabCheckKey == key { pendingTabCheckKey = nil } }
            guard await gemini.isConfigured else { return }
            if await gemini.isRateLimited {
                applyGeminiBadge(
                    detail: "Gemini rate-limited — using offline fallback",
                    badge: "Gemini limited",
                    online: false
                )
                return
            }

            lastTabGeminiAt = Date()
            do {
                let judgment = try await gemini.checkWindowTitle(
                    appName: front.appName,
                    windowTitle: front.title,
                    topic: topic
                )
                titleCacheAnswers[key] = judgment
                applyGeminiBadge(
                    detail: "Gemini online (\(AppConfig.geminiModel))",
                    badge: "Gemini online",
                    online: true
                )
                // Only act if the user is still on that same window.
                if phase == .studying, windows.currentKey == key {
                    applyTabVerdict(judgment, front: front, topic: topic)
                }
            } catch {
                noteGeminiFallback(error)
            }
        }
    }

    /// Silent re-check after the user flips Accessibility / Automation in System Settings.
    func refreshAccessibilityPermission() {
        windows.refreshAccessibilityTrust()
    }

    func requestAccessibilityAccess() {
        windows.requestAccessibilityPrompt()
    }

    // MARK: - Local helpers

    private func localCategory(for rule: DriftRule) -> DriftCategory {
        switch rule {
        case .noFace: return .away
        case .eyesClosed, .yawn: return .tired
        case .headTurned: return .lookingElsewhere
        case .headDown: return .other
        case .offTaskWindow: return .lookingElsewhere
        }
    }

    private func localNudge(for rule: DriftRule) -> String {
        let topic = session?.topic ?? declaredTopic
        let label = topic.isEmpty ? "your material" : topic
        switch rule {
        case .noFace: return "Come back — you were on \(label)."
        case .eyesClosed: return "Eyes open — stay with \(label)."
        case .yawn: return "Shake it off — back to \(label)."
        case .headTurned: return "Eyes forward. Still on \(label)."
        case .headDown: return "Eyes up — stay with \(label)."
        case .offTaskWindow: return "That tab is not \(label)."
        }
    }

    private func localQuestions() -> [Question] {
        let sid = session?.id ?? UUID()
        let topic = session?.topic ?? declaredTopic
        let stems = [
            ("Definition", "Which best describes a core idea in \(topic)?"),
            ("Practice", "What should you open to keep studying \(topic)?"),
            ("Distraction", "Which of these is off-task while studying \(topic)?")
        ]
        return stems.map { hotspot, text in
            Question(
                sessionId: sid,
                hotspot: hotspot,
                text: text,
                kind: .multipleChoice,
                options: [
                    "Engage with the actual \(topic) material",
                    "Open an unrelated entertainment tab",
                    "Skip recall and hope for the best",
                    "Switch topics every thirty seconds"
                ],
                correctOptionIndex: 0
            )
        }
    }

    private func localGrade() -> GradeResult {
        var scores: [Bool] = []
        var feedback: [String] = []
        for q in questions {
            let ok = q.selectedOptionIndex != nil && q.selectedOptionIndex == q.correctOptionIndex
            scores.append(ok)
            if ok {
                feedback.append("Correct.")
            } else if let idx = q.correctOptionIndex, idx < q.options.count {
                feedback.append("Correct answer: \(q.options[idx])")
            } else {
                feedback.append("No selection.")
            }
        }
        let overall = questions.isEmpty ? 0 : Double(scores.filter { $0 }.count) / Double(questions.count)
        return GradeResult(
            scorePerQuestion: scores,
            feedback: feedback,
            weakTopic: session?.topic ?? declaredTopic,
            overallScore: overall
        )
    }

    private func localWindowJudgment(
        app: String,
        title: String,
        topic: String,
        bundleID: String = ""
    ) -> GeminiClient.WindowJudgment {
        // Known entertainment apps are caught by bundle id — needs no permission at all.
        let offBundles = [
            "com.spotify.client", "com.hnc.Discord", "com.apple.Music", "com.apple.TV",
            "com.netflix.Netflix", "com.valvesoftware.steam", "tv.twitch",
            "com.apple.iChat", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
            "com.tinyspeck.slackmacgap", "com.facebook.archon"
        ]
        let bid = bundleID.lowercased()
        if offBundles.contains(where: { bid == $0.lowercased() }) {
            return .init(onTask: "no", reason: "\(app) is not study material.")
        }

        let t = (title + " " + app).lowercased()
        let offKeywords = [
            "youtube", "tiktok", "reddit", "twitter", "x.com", "instagram", "netflix",
            "twitch", "facebook", "meme", "espn", "hulu", "disney+", "prime video",
            "steam", "discord", "spotify", "imessage", "messages", "whatsapp"
        ]
        if offKeywords.contains(where: { t.contains($0) }) {
            return .init(onTask: "no", reason: "Looks recreational.")
        }
        let tokens = topic.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
        if tokens.contains(where: { t.contains($0) }) {
            return .init(onTask: "yes", reason: "Title matches declared topic.")
        }
        let studyHints = [
            "pdf", "slides", "docs.google", "notion", "textbook", "lecture", "canvas",
            "course", "wikipedia", "khan", "preview", "pages", "keynote", "powerpoint",
            "word", "excel", "vscode", "xcode", "github", "overleaf", "jupyter"
        ]
        if studyHints.contains(where: { t.contains($0) }) {
            return .init(onTask: "yes", reason: "Title looks like study material.")
        }
        // Desktop / Finder / empty-ish → not a distraction fire
        if t.contains("finder") || t == app.lowercased() {
            return .init(onTask: "yes", reason: "System UI — ignore.")
        }
        return .init(onTask: "unsure", reason: "No clear signal from title alone.")
    }
}
