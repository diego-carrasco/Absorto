import Foundation

/// Pure Swift drift detector: head readings + time → events and ball size.
/// No UI, camera, or Gemini code. Fully XCTest-able.
public struct DriftEngine: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        public var holdDuration: TimeInterval
        public var cooldownDuration: TimeInterval
        public var voiceSpacing: TimeInterval
        public var recoverRatePerSecond: Double
        /// Base shrink rate (1×). Applied as 1× / 2× / 3× by remaining ball size.
        /// With defaults, full white → 0 while distracted is ~10s (≈5s + 2.5s + 1.7s).
        public var shrinkBasePerSecond: Double
        public var yawThresholdDegrees: Double
        public var pitchThresholdDegrees: Double

        public static let `default` = Config(
            holdDuration: 5.0,
            cooldownDuration: 10.0,
            voiceSpacing: 120.0,
            recoverRatePerSecond: 1.0 / 150.0, // full recovery ~2.5 minutes
            shrinkBasePerSecond: 1.0 / 15.0,   // 1× stage; then 2× / 3× as the ball shrinks
            yawThresholdDegrees: 36,
            pitchThresholdDegrees: 28
        )

        public static let demo = Config(
            holdDuration: 3.0,
            cooldownDuration: 6.0,
            voiceSpacing: 30.0,
            recoverRatePerSecond: 1.0 / 60.0,
            shrinkBasePerSecond: 1.0 / 12.0,
            yawThresholdDegrees: 36,
            pitchThresholdDegrees: 28
        )

        public static var yawThresholdDegrees: Double { Config.default.yawThresholdDegrees }
        public static var pitchThresholdDegrees: Double { Config.default.pitchThresholdDegrees }

        public init(
            holdDuration: TimeInterval,
            cooldownDuration: TimeInterval,
            voiceSpacing: TimeInterval,
            recoverRatePerSecond: Double,
            shrinkBasePerSecond: Double,
            yawThresholdDegrees: Double,
            pitchThresholdDegrees: Double
        ) {
            self.holdDuration = holdDuration
            self.cooldownDuration = cooldownDuration
            self.voiceSpacing = voiceSpacing
            self.recoverRatePerSecond = recoverRatePerSecond
            self.shrinkBasePerSecond = shrinkBasePerSecond
            self.yawThresholdDegrees = yawThresholdDegrees
            self.pitchThresholdDegrees = pitchThresholdDegrees
        }
    }

    public enum Output: Equatable, Sendable {
        case none
        case fire(rule: DriftRule, heldFor: TimeInterval)
        case stillDrifting(rule: DriftRule)
        case refocused
    }

    public private(set) var config: Config
    public private(set) var ballSize: Double
    public private(set) var focusScoreAccumulated: TimeInterval
    public private(set) var focusedTime: TimeInterval
    public private(set) var totalTrackedTime: TimeInterval
    /// Rule currently accumulating toward a fire (nil if not holding).
    public private(set) var activeHoldRule: DriftRule?
    /// Seconds into the current hold (0 if not holding).
    public private(set) var activeHoldElapsed: TimeInterval

    private var holdRule: DriftRule?
    private var holdStartedAt: Date?
    private var cooldownUntil: Date?
    private var lastVoiceAt: Date?
    private var currentlyDrifting: Bool
    private var activeDriftRule: DriftRule?
    private var lastTickAt: Date?

    public init(config: Config = .default, ballSize: Double = 1.0) {
        self.config = config
        self.ballSize = max(0, min(1, ballSize))
        self.focusScoreAccumulated = 0
        self.focusedTime = 0
        self.totalTrackedTime = 0
        self.activeHoldRule = nil
        self.activeHoldElapsed = 0
        self.holdRule = nil
        self.holdStartedAt = nil
        self.cooldownUntil = nil
        self.lastVoiceAt = nil
        self.currentlyDrifting = false
        self.activeDriftRule = nil
        self.lastTickAt = nil
    }

    public mutating func setDemoMode(_ enabled: Bool) {
        config = enabled ? .demo : .default
    }

    /// Restore the focus ball after an attention-lost pause or “I’m back”.
    public mutating func restoreFocusBall(to size: Double = 1.0) {
        ballSize = max(0, min(1, size))
        currentlyDrifting = false
        activeDriftRule = nil
        resetHold()
        clearHoldProgress()
    }

    public mutating func setBallSize(_ size: Double) {
        ballSize = max(0, min(1, size))
    }

    public var focusScore: Double {
        guard totalTrackedTime > 0 else { return 1.0 }
        return focusedTime / totalTrackedTime
    }

    public var isInCooldown: Bool {
        guard let until = cooldownUntil, let last = lastTickAt else { return false }
        return last < until
    }

    public var isDrifting: Bool { currentlyDrifting }

    /// Whether a spoken nudge is allowed now (spacing gate).
    public func shouldSpeak(at time: Date) -> Bool {
        guard let last = lastVoiceAt else { return true }
        return time.timeIntervalSince(last) >= config.voiceSpacing
    }

    public mutating func markVoiceSpoken(at time: Date) {
        lastVoiceAt = time
    }

    /// Apply a confirmed distraction burst (window drifts / explicit penalties).
    public mutating func applyConfirmedDistraction(severity: Int, duration: TimeInterval = 0) {
        let sev = max(1, min(5, severity))
        let burst = Double(sev) * 0.05
        let ongoing = min(duration, 3.0) * config.shrinkBasePerSecond * (Double(sev) / 3.0)
        ballSize = max(0, ballSize - burst - ongoing)
    }

    /// Call when Gemini says false alarm — undo optimistic shrink; cooldown still applies.
    public mutating func applyFalseAlarm(at time: Date) {
        currentlyDrifting = false
        activeDriftRule = nil
        ballSize = min(1, ballSize + 0.12)
        cooldownUntil = time.addingTimeInterval(config.cooldownDuration)
        resetHold()
        clearHoldProgress()
    }

    /// Process one head reading. Returns fire once when hold threshold is crossed.
    public mutating func process(reading: HeadReading) -> Output {
        let time = reading.timestamp
        let rule = reading.activeRule(
            yawThreshold: config.yawThresholdDegrees,
            pitchThreshold: config.pitchThresholdDegrees
        )

        // Recover whenever gaze is on-screen.
        if rule == nil, currentlyDrifting {
            currentlyDrifting = false
            activeDriftRule = nil
            tickBall(at: time, shouldShrink: false)
            resetHold()
            clearHoldProgress()
            lastTickAt = time
            return .refocused
        }

        // Shrink for as long as the distraction continues — no short budget.
        let shouldShrink = currentlyDrifting && rule != nil
        tickBall(at: time, shouldShrink: shouldShrink)

        if let until = cooldownUntil, time < until {
            if currentlyDrifting, let rule {
                activeDriftRule = rule
                clearHoldProgress()
                lastTickAt = time
                return .stillDrifting(rule: rule)
            }
            // Still in cooldown and not drifting: hold does not accumulate.
            resetHold()
            clearHoldProgress()
            lastTickAt = time
            return .none
        }

        guard let rule else {
            resetHold()
            clearHoldProgress()
            lastTickAt = time
            return .none
        }

        if currentlyDrifting {
            activeDriftRule = rule
            clearHoldProgress()
            lastTickAt = time
            return .stillDrifting(rule: rule)
        }

        // Exact hold for every rule (no-face included): blinks are filtered in HeadTracker.
        let neededHold = config.holdDuration

        if holdRule != rule {
            holdRule = rule
            holdStartedAt = time
            activeHoldRule = rule
            activeHoldElapsed = 0
            lastTickAt = time
            return .none
        }

        guard let start = holdStartedAt else {
            holdStartedAt = time
            activeHoldRule = rule
            activeHoldElapsed = 0
            lastTickAt = time
            return .none
        }

        let held = time.timeIntervalSince(start)
        activeHoldRule = rule
        activeHoldElapsed = held
        lastTickAt = time

        if held >= neededHold {
            currentlyDrifting = true
            activeDriftRule = rule
            cooldownUntil = time.addingTimeInterval(config.cooldownDuration)
            // Tiny kick so the ball reacts immediately; continuous shrink does the rest.
            ballSize = max(0, ballSize - 0.04)
            resetHold()
            clearHoldProgress()
            return .fire(rule: rule, heldFor: held)
        }

        return .none
    }

    /// Force a window-title drift (no hold — Gemini already judged off-task).
    public mutating func fireWindowDrift(at time: Date) -> Output {
        if let until = cooldownUntil, time < until {
            return .none
        }
        currentlyDrifting = true
        activeDriftRule = .offTaskWindow
        cooldownUntil = time.addingTimeInterval(config.cooldownDuration)
        applyConfirmedDistraction(severity: 3, duration: 0)
        resetHold()
        clearHoldProgress()
        lastTickAt = time
        return .fire(rule: .offTaskWindow, heldFor: 0)
    }

    /// Break length from quiz accuracy + confirmed distraction count.
    /// Base 10 minutes; −1 per wrong answer; −1 per confirmed drift; floor 1, cap 10.
    public static func breakMinutes(correctCount: Int, questionCount: Int, confirmedDrifts: Int) -> Int {
        let total = max(questionCount, 1)
        let correct = min(max(correctCount, 0), total)
        let wrong = total - correct
        let drifts = max(0, confirmedDrifts)
        return max(1, min(10, 10 - wrong - drifts))
    }

    public func breakMinutes(quizScore: Double, questionCount: Int = 3, confirmedDrifts: Int = 0) -> Int {
        let correct = Int((quizScore * Double(max(questionCount, 1))).rounded())
        return Self.breakMinutes(
            correctCount: correct,
            questionCount: questionCount,
            confirmedDrifts: confirmedDrifts
        )
    }

    // MARK: - Private

    private mutating func resetHold() {
        holdRule = nil
        holdStartedAt = nil
    }

    private mutating func clearHoldProgress() {
        activeHoldRule = nil
        activeHoldElapsed = 0
    }

    private mutating func tickBall(at time: Date, shouldShrink: Bool) {
        defer { lastTickAt = time }
        guard let last = lastTickAt else { return }
        let dt = max(0, time.timeIntervalSince(last))
        guard dt > 0 else { return }

        totalTrackedTime += dt
        if ballSize >= 0.95 {
            focusedTime += dt
        }

        if shouldShrink {
            // Stepped constant rates: slow while large, faster as it disappears.
            // ball > 2/3 → 1×, > 1/3 → 2×, else → 3×.
            ballSize = max(0, ballSize - steppedShrinkRate(for: ballSize) * dt)
        } else {
            ballSize = min(1, ballSize + config.recoverRatePerSecond * dt)
        }
    }

    private func steppedShrinkRate(for size: Double) -> Double {
        let base = config.shrinkBasePerSecond
        if size > (2.0 / 3.0) { return base * 1.0 }
        if size > (1.0 / 3.0) { return base * 2.0 }
        return base * 3.0
    }
}
