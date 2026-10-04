import Foundation
import AppKit
import SwiftUI

/// Orchestrates permissions → calibration → watch loop → Gemini → end gate → break → next session.
@MainActor
final class SessionController: ObservableObject {
    @Published var phase: SessionPhase = .idle
    @Published var session: Session?
    @Published var engine = DriftEngine()
    @Published var drifts: [DriftEvent] = []
    @Published var statusText: String = "Ready"
    @Published var lastNudge: String = ""
    @Published var demoMode: Bool = true
    @Published var timerProgress: Double = 0 // 0…1 outer ring
    @Published var attentionMap: AttentionMapResult?
    @Published var questions: [Question] = []
    @Published var gradeResult: GradeResult?
    @Published var showFloatingBall: Bool = false
    @Published var liveYaw: Double = 0
    @Published var livePitch: Double = 0
    @Published var facePresent: Bool = false
    @Published var errorMessage: String?
    @Published var geminiStatus: String = ""
    @Published var breakSecondsRemaining: Int = 0
    @Published var breakTotalSeconds: Int = 0

    let camera = CameraService()
    let head = HeadTracker()
    let screen = ScreenCaptureService()
    let windows = WindowWatcher()
    let audio = AudioService()
    let gemini = GeminiClient()

    private var startScreenJPEG: Data?
    private var endScreenJPEG: Data?
    private var sessionDuration: TimeInterval = 25 * 60
    private var demoDuration: TimeInterval = 90
    private var timerTask: Task<Void, Never>?
    private var breakTask: Task<Void, Never>?
    private var calibrationTask: Task<Void, Never>?
    private var geminiBusy = false
    private var titleCacheAnswers: [String: GeminiClient.WindowJudgment] = [:]
    private var autoContinueAfterBreak = true
    private var lastGeminiClassifyAt: Date?
    private let geminiClassifyMinSpacing: TimeInterval = 12

    var ballSize: Double { engine.ballSize }
    var effectiveDuration: TimeInterval { demoMode ? demoDuration : sessionDuration }

    func toggleDemoMode() {
        demoMode.toggle()
        mutateEngine { $0.setDemoMode(demoMode) }
        statusText = demoMode ? "Demo mode: 3s hold" : "Normal: 5s hold"
    }

    private func mutateEngine(_ body: (inout DriftEngine) -> Void) {
        var eng = engine
        body(&eng)
        engine = eng
    }

    // MARK: - Session lifecycle

    func startSession() {
        errorMessage = nil
        breakTask?.cancel()
        engine = DriftEngine(config: demoMode ? .demo : .default)
        drifts = []
        attentionMap = nil
        questions = []
        gradeResult = nil
        titleCacheAnswers = [:]
        windows.resetCache()
        timerProgress = 0
        breakSecondsRemaining = 0
        breakTotalSeconds = 0
        phase = .requestingPermissions
        statusText = "Requesting permissions…"

        Task {
            let camOK = await camera.requestAccess()
            if !camOK {
                errorMessage = "Camera access is required."
                phase = .idle
                return
            }

            let screenOK = await screen.prepareAccess()
            if screenOK {
                startScreenJPEG = await screen.captureMainDisplayJPEG()
                if startScreenJPEG == nil, screen.permissionHint != nil {
                    statusText = "Camera only — restart after granting Screen Recording."
                }
            } else {
                startScreenJPEG = nil
                // Non-fatal — webcam + title checks still work. Hint already on screen service.
                statusText = "Camera only — grant Screen Recording, then restart Absorto."
            }

            await refreshGeminiStatus()
            beginCalibration()
        }
    }

    private func refreshGeminiStatus() async {
        guard await gemini.isConfigured else {
            geminiStatus = "Gemini: no API key"
            return
        }
        if await gemini.isRateLimited {
            geminiStatus = await gemini.rateLimitStatusText ?? "Gemini rate-limited — using offline fallback"
            return
        }
        // Avoid burning free-tier quota on a ping every session; just show model readiness.
        geminiStatus = "Gemini: ready (\(AppConfig.geminiModel))"
    }

    private func noteGeminiFallback(_ error: Error) {
        if let g = error as? GeminiError, g.isRateLimitLike {
            geminiStatus = "Gemini rate-limited — using offline fallback"
            return
        }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("429")
            || text.localizedCaseInsensitiveContains("503")
            || text.localizedCaseInsensitiveContains("rate") {
            geminiStatus = "Gemini rate-limited — using offline fallback"
            return
        }
        // Keep non-quota failures quiet in the banner; status line is enough.
        geminiStatus = "Gemini offline fallback"
    }

    private func beginCalibration() {
        phase = .calibrating(secondsLeft: 5)
        statusText = "Look at the screen — calibrating…"
        head.startCalibration()
        showFloatingBall = false

        camera.start { [weak self] cg, time in
            guard let self else { return }
            let reading = self.head.process(cgImage: cg, at: time)
            self.liveYaw = reading.yawDelta
            self.livePitch = reading.pitchDelta
            self.facePresent = reading.facePresent
        }

        calibrationTask?.cancel()
        calibrationTask = Task {
            for left in stride(from: 5, through: 1, by: -1) {
                phase = .calibrating(secondsLeft: left)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            _ = head.finishCalibration()

            var topic = "Study session"
            if let jpeg = startScreenJPEG, await gemini.isConfigured, !(await gemini.isRateLimited) {
                do {
                    topic = try await gemini.inferTopic(screenJPEG: jpeg)
                } catch {
                    noteGeminiFallback(error)
                }
            }

            session = Session(topic: topic, startedAt: Date(), ballSize: 1)
            phase = .studying
            statusText = "Focusing on: \(topic)"
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
        }

        windows.start { [weak self] app, title in
            guard let self, self.phase == .studying else { return }
            Task { await self.handleNewWindowTitle(app: app, title: title) }
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        let duration = effectiveDuration
        let started = Date()
        timerTask = Task {
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(started)
                timerProgress = min(1, elapsed / duration)
                if elapsed >= duration {
                    await endSession()
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func endSessionEarly() {
        Task { await endSession() }
    }

    private func endSession() async {
        guard phase == .studying else { return }
        timerTask?.cancel()
        windows.stop()
        showFloatingBall = false
        phase = .ending
        statusText = "Wrapping up…"

        if screen.isAuthorized {
            endScreenJPEG = await screen.captureMainDisplayJPEG()
        } else {
            endScreenJPEG = nil
        }
        camera.stop()

        session?.endedAt = Date()
        session?.focusScore = engine.focusScore
        session?.ballSize = engine.ballSize

        await buildEndGate()
    }

    private func buildEndGate() async {
        let topic = session?.topic ?? ""
        let useLocal: Bool
        if await gemini.isConfigured {
            useLocal = await gemini.isRateLimited
        } else {
            useLocal = true
        }

        if useLocal {
            if await gemini.isConfigured, await gemini.isRateLimited {
                geminiStatus = "Gemini rate-limited — using offline fallback"
            }
            attentionMap = AttentionMapResult(
                topic: topic,
                summary: localSummary(),
                hotspots: localHotspots(),
                questions: localQuestions()
            )
            questions = attentionMap?.questions ?? []
        } else {
            do {
                let map = try await gemini.buildAttentionMap(
                    drifts: drifts,
                    startScreenJPEG: startScreenJPEG,
                    endScreenJPEG: endScreenJPEG,
                    topicHint: topic
                )
                attentionMap = map
                questions = map.questions
            } catch {
                noteGeminiFallback(error)
                attentionMap = AttentionMapResult(
                    topic: topic,
                    summary: localSummary(),
                    hotspots: localHotspots(),
                    questions: localQuestions()
                )
                questions = attentionMap?.questions ?? []
            }
        }
        phase = .attentionMap
        statusText = "Focus check"
    }

    func continueToRecall() {
        phase = .recall
        statusText = "Focus check"
    }

    func submitAnswers() {
        Task {
            statusText = "Grading…"
            do {
                if await gemini.isConfigured, !(await gemini.isRateLimited) {
                    let result = try await gemini.gradeAnswers(questions: questions)
                    applyGrade(result)
                } else {
                    if await gemini.isConfigured {
                        geminiStatus = "Gemini rate-limited — using offline fallback"
                    }
                    applyGrade(localGrade())
                }
            } catch {
                noteGeminiFallback(error)
                applyGrade(localGrade())
            }
        }
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
        let minutes = engine.breakMinutes(quizScore: result.overallScore)
        session?.breakMinutes = minutes
        session?.focusScore = engine.focusScore
        phase = .breakReady
        statusText = minutes == 0 ? "Short review block" : "Break: \(minutes) min"
    }

    /// Begin the timed break; when it ends, automatically start the next study session.
    func startBreak(autoContinue: Bool = true) {
        autoContinueAfterBreak = autoContinue
        let minutes = session?.breakMinutes ?? 5
        let seconds: Int
        if demoMode {
            // Demo: 45s / 30s / 20s instead of waiting many minutes.
            seconds = minutes >= 10 ? 45 : (minutes >= 5 ? 30 : 20)
        } else if minutes == 0 {
            seconds = 2 * 60 // short review block
        } else {
            seconds = max(60, minutes * 60)
        }

        breakTotalSeconds = seconds
        breakSecondsRemaining = seconds
        phase = .onBreak
        statusText = "On break"
        showFloatingBall = false
        camera.stop()
        windows.stop()

        breakTask?.cancel()
        breakTask = Task {
            while breakSecondsRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                breakSecondsRemaining -= 1
            }
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
        startSession()
    }

    func endBreakToIdle() {
        breakTask?.cancel()
        phase = .idle
        statusText = "Ready"
    }

    func resetToIdle() {
        timerTask?.cancel()
        calibrationTask?.cancel()
        breakTask?.cancel()
        camera.stop()
        windows.stop()
        showFloatingBall = false
        phase = .idle
        statusText = "Ready"
    }

    // MARK: - Drift handling

    private func handleEngineOutput(_ output: DriftEngine.Output, at time: Date) {
        switch output {
        case .none:
            break
        case .stillDrifting:
            session?.ballSize = engine.ballSize
        case .refocused:
            statusText = "Back on track"
        case .fire(let rule, let held):
            Task { await confirmDriftWithGemini(rule: rule, heldFor: held, at: time) }
        }
    }

    private func confirmDriftWithGemini(rule: DriftRule, heldFor: TimeInterval, at time: Date) async {
        guard !geminiBusy else { return }
        geminiBusy = true
        defer { geminiBusy = false }

        audio.playChime()
        statusText = "Checking distraction…"

        let webcam = camera.snapshotJPEG(maxDimension: 480)
        // Only capture screen when already authorized — never re-prompt mid-session.
        let screenJPEG: Data? = screen.isAuthorized ? await screen.captureMainDisplayJPEG() : nil

        var event = DriftEvent(
            sessionId: session?.id ?? UUID(),
            time: time,
            source: .camera,
            rule: rule,
            seconds: heldFor
        )

        let preferLocal: Bool = {
            if let last = lastGeminiClassifyAt,
               time.timeIntervalSince(last) < geminiClassifyMinSpacing {
                return true
            }
            return false
        }()

        do {
            let rateLimited = await gemini.isRateLimited
            if await gemini.isConfigured, let webcam, !preferLocal, !rateLimited {
                lastGeminiClassifyAt = time
                let result = try await gemini.classifyDrift(
                    webcamJPEG: webcam,
                    screenJPEG: screenJPEG,
                    rule: rule
                )
                if result.isFalseAlarm {
                    mutateEngine { $0.applyFalseAlarm(at: Date()) }
                    event.falseAlarm = true
                    event.category = .falseAlarm
                    drifts.append(event)
                    statusText = "False alarm — keep going"
                    return
                }
                mutateEngine { $0.applyConfirmedDistraction(severity: result.severity, duration: heldFor) }
                event.category = result.category
                event.severity = result.severity
                event.studying = result.studying
                event.nudgeText = result.nudgeText
                lastNudge = result.nudgeText
                if session?.topic == "Study session", !result.studying.isEmpty {
                    session?.topic = result.studying
                }
                drifts.append(event)
                statusText = result.studying.isEmpty ? "Distraction noted" : result.studying

                if engine.shouldSpeak(at: Date()) {
                    mutateEngine { $0.markVoiceSpoken(at: Date()) }
                    let audioData = try? await gemini.synthesizeSpeech(nudgeText: result.nudgeText)
                    audio.speakNudge(data: audioData, text: result.nudgeText)
                }
            } else {
                if rateLimited {
                    geminiStatus = "Gemini rate-limited — using offline fallback"
                }
                applyLocalDriftConfirmation(rule: rule, heldFor: heldFor, event: &event)
            }
        } catch {
            noteGeminiFallback(error)
            applyLocalDriftConfirmation(rule: rule, heldFor: heldFor, event: &event)
        }

        session?.ballSize = engine.ballSize
    }

    private func applyLocalDriftConfirmation(rule: DriftRule, heldFor: TimeInterval, event: inout DriftEvent) {
        mutateEngine { $0.applyConfirmedDistraction(severity: 3, duration: heldFor) }
        event.category = localCategory(for: rule)
        event.severity = 3
        event.studying = session?.topic
        event.nudgeText = localNudge(for: rule)
        lastNudge = event.nudgeText ?? ""
        drifts.append(event)
        statusText = "Distraction noted"
        if engine.shouldSpeak(at: Date()) {
            mutateEngine { $0.markVoiceSpoken(at: Date()) }
            audio.speakNudge(event.nudgeText ?? "Eyes back on your work.")
        }
    }

    private func handleNewWindowTitle(app: String, title: String) async {
        let topic = session?.topic ?? ""
        let key = "\(app)|\(title)".lowercased()
        let lowered = title.lowercased()
        if lowered.isEmpty { return }

        do {
            let judgment: GeminiClient.WindowJudgment
            if let cached = titleCacheAnswers[key] {
                judgment = cached
            } else {
                // Local-first: obvious recreational titles never spend a Gemini call.
                let local = localWindowJudgment(app: app, title: title, topic: topic)
                if local.onTask == "no" || local.onTask == "yes" {
                    judgment = local
                    titleCacheAnswers[key] = judgment
                } else if await gemini.isConfigured, !(await gemini.isRateLimited) {
                    judgment = try await gemini.checkWindowTitle(appName: app, windowTitle: title, topic: topic)
                    titleCacheAnswers[key] = judgment
                } else {
                    if await gemini.isConfigured {
                        geminiStatus = "Gemini rate-limited — using offline fallback"
                    }
                    judgment = local
                    titleCacheAnswers[key] = judgment
                }
            }

            guard judgment.onTask == "no" else { return }

            let now = Date()
            var fired = false
            mutateEngine { eng in
                if case .fire = eng.fireWindowDrift(at: now) {
                    fired = true
                }
            }
            guard fired else { return }

            audio.playChime()
            var event = DriftEvent(
                sessionId: session?.id ?? UUID(),
                time: now,
                source: .window,
                rule: .offTaskWindow,
                category: .lookingElsewhere,
                severity: 3,
                studying: topic,
                nudgeText: "Back to \(topic.isEmpty ? "your slides" : topic) — \(title) is off-task."
            )
            event.nudgeText = "Off-task tab: \(title). \(judgment.reason)"
            lastNudge = event.nudgeText ?? ""
            drifts.append(event)
            statusText = "Off-task: \(title)"

            if engine.shouldSpeak(at: now) {
                mutateEngine { $0.markVoiceSpoken(at: now) }
                audio.speakNudge(event.nudgeText ?? "That tab is off-task.")
            }
            session?.ballSize = engine.ballSize
        } catch {
            noteGeminiFallback(error)
            // Cache unsure so we do not retry the same title while limited.
            titleCacheAnswers[key] = .init(onTask: "unsure", reason: "Deferred while Gemini is limited.")
        }
    }

    // MARK: - Local fallbacks

    private func localCategory(for rule: DriftRule) -> DriftCategory {
        switch rule {
        case .noFace: return .away
        case .headTurned: return .lookingElsewhere
        case .headDown: return .other
        case .offTaskWindow: return .lookingElsewhere
        }
    }

    private func localNudge(for rule: DriftRule) -> String {
        let topic = session?.topic ?? "your material"
        switch rule {
        case .noFace: return "Come back — you were on \(topic)."
        case .headTurned: return "Eyes forward. Still on \(topic)."
        case .headDown: return "Eyes up — stay with \(topic)."
        case .offTaskWindow: return "That tab is not \(topic)."
        }
    }

    private func localSummary() -> String {
        let confirmed = drifts.filter { !$0.falseAlarm }
        if confirmed.isEmpty {
            return "Clean session — no confirmed drifts."
        }
        let topics = confirmed.compactMap(\.studying).filter { !$0.isEmpty }
        let spot = topics.first ?? session?.topic ?? "your material"
        return "\(confirmed.count) drift\(confirmed.count == 1 ? "" : "s"), mostly around \(spot)."
    }

    private func localHotspots() -> [String] {
        let studying = drifts.compactMap(\.studying).filter { !$0.isEmpty }
        if studying.isEmpty {
            return [session?.topic ?? "General review"].filter { !$0.isEmpty }
        }
        return Array(Set(studying)).prefix(3).map { $0 }
    }

    private func localQuestions() -> [Question] {
        let sid = session?.id ?? UUID()
        let topic = session?.topic ?? "your course"
        let spots = localHotspots()
        let a = spots[safe: 0] ?? topic
        let b = spots[safe: 1] ?? topic
        return [
            Question(
                sessionId: sid,
                hotspot: a,
                text: "Which best matches what you were studying about \(a)?",
                kind: .multipleChoice,
                options: [
                    "A core concept or definition from \(a)",
                    "A social media feed",
                    "Unrelated entertainment",
                    "Nothing in particular"
                ],
                correctOptionIndex: 0
            ),
            Question(
                sessionId: sid,
                hotspot: b,
                text: "If you had to quiz yourself on \(b) next, what would you open?",
                kind: .multipleChoice,
                options: [
                    "The notes/slides for \(b)",
                    "A random video recommendation",
                    "A shopping tab",
                    "A chat unrelated to class"
                ],
                correctOptionIndex: 0
            ),
            Question(
                sessionId: sid,
                hotspot: a,
                text: "In 1–2 sentences, explain the main idea of \(a) in your own words.",
                kind: .teachBack
            )
        ]
    }

    private func localGrade() -> GradeResult {
        var scores: [Bool] = []
        var feedback: [String] = []
        for q in questions {
            switch q.kind {
            case .multipleChoice:
                let ok = q.selectedOptionIndex != nil && q.selectedOptionIndex == q.correctOptionIndex
                scores.append(ok)
                if ok {
                    feedback.append("Correct.")
                } else if let idx = q.correctOptionIndex, idx < q.options.count {
                    feedback.append("Review: \(q.options[idx])")
                } else {
                    feedback.append("No selection.")
                }
            case .teachBack:
                let ok = !q.myAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                scores.append(ok)
                feedback.append(ok ? "Answer recorded — revisit this on the next block." : "No teach-back — mark for review.")
            }
        }
        let overall = questions.isEmpty ? 0 : Double(scores.filter { $0 }.count) / Double(questions.count)
        return GradeResult(
            scorePerQuestion: scores,
            feedback: feedback,
            weakTopic: localHotspots().first ?? "",
            overallScore: overall
        )
    }

    private func localWindowJudgment(app: String, title: String, topic: String) -> GeminiClient.WindowJudgment {
        let t = title.lowercased()
        let offKeywords = ["youtube", "tiktok", "reddit", "twitter", "instagram", "netflix", "cat", "meme", "facebook", "twitch"]
        if offKeywords.contains(where: { t.contains($0) }) {
            return .init(onTask: "no", reason: "Title looks recreational.")
        }
        let topicKey = String(topic.lowercased().prefix(8))
        if !topicKey.isEmpty, t.contains(topicKey) {
            return .init(onTask: "yes", reason: "Title matches topic.")
        }
        return .init(onTask: "unsure", reason: "No clear signal from title alone.")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
