import Foundation

/// Pure Swift drift detector: head readings + time → events and ball size.
/// No UI, camera, or Gemini code. Fully XCTest-able.
public struct DriftEngine: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        public var holdDuration: TimeInterval
        public var cooldownDuration: TimeInterval
        public var voiceSpacing: TimeInterval
        public var recoverRatePerSecond: Double
        public var shrinkBasePerSecond: Double
        public var yawThresholdDegrees: Double
        public var pitchThresholdDegrees: Double

        public static let `default` = Config(
            holdDuration: 5.0,
            cooldownDuration: 10.0,
            voiceSpacing: 120.0,
            recoverRatePerSecond: 1.0 / 150.0, // full recovery ~2.5 minutes
            shrinkBasePerSecond: 0.025,
            yawThresholdDegrees: 32,
            pitchThresholdDegrees: 24
        )

        public static let demo = Config(
            holdDuration: 3.0,
            cooldownDuration: 6.0,
            voiceSpacing: 30.0,
            recoverRatePerSecond: 1.0 / 60.0,
            shrinkBasePerSecond: 0.05,
            yawThresholdDegrees: 34,
            pitchThresholdDegrees: 26
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

    private var holdRule: DriftRule?
    private var holdStartedAt: Date?
    private var cooldownUntil: Date?
    private var lastVoiceAt: Date?
    private var currentlyDrifting: Bool
    private var activeDriftRule: DriftRule?
    private var lastTickAt: Date?
    /// Continuous shrink stops after this many seconds of an active drift bout.
    private var driftShrinkBudget: TimeInterval

    public init(config: Config = .default, ballSize: Double = 1.0) {
        self.config = config
        self.ballSize = max(0, min(1, ballSize))
        self.focusScoreAccumulated = 0
        self.focusedTime = 0
        self.totalTrackedTime = 0
        self.holdRule = nil
        self.holdStartedAt = nil
        self.cooldownUntil = nil
        self.lastVoiceAt = nil
        self.currentlyDrifting = false
        self.activeDriftRule = nil
        self.lastTickAt = nil
        self.driftShrinkBudget = 0
    }

    public mutating func setDemoMode(_ enabled: Bool) {
        config = enabled ? .demo : .default
    }

    public var focusScore: Double {
        guard totalTrackedTime > 0 else { return 1.0 }
        return focusedTime / totalTrackedTime
    }

    public var isInCooldown: Bool {
        guard let until = cooldownUntil, let last = lastTickAt else { return false }
        return last < until
    }

    /// Whether a spoken nudge is allowed now (spacing gate).
    public func shouldSpeak(at time: Date) -> Bool {
        guard let last = lastVoiceAt else { return true }
        return time.timeIntervalSince(last) >= config.voiceSpacing
    }

    public mutating func markVoiceSpoken(at time: Date) {
        lastVoiceAt = time
    }

    /// Apply a confirmed distraction burst. Does **not** force `currentlyDrifting`
    /// (gaze ownership stays in `process`, so a late Gemini reply cannot re-lock shrink).
    public mutating func applyConfirmedDistraction(severity: Int, duration: TimeInterval = 0) {
        let sev = max(1, min(5, severity))
        let burst = Double(sev) * 0.08
        let ongoing = min(duration, 3.0) * config.shrinkBasePerSecond * (Double(sev) / 3.0)
        ballSize = max(0, ballSize - burst - ongoing)
    }

    /// Call when Gemini says false alarm — undo optimistic shrink; cooldown still applies.
    public mutating func applyFalseAlarm(at time: Date) {
        currentlyDrifting = false
        activeDriftRule = nil
        driftShrinkBudget = 0
        // Undo the optimistic severity-2 burst from process()
        ballSize = min(1, ballSize + 0.16)
        cooldownUntil = time.addingTimeInterval(config.cooldownDuration)
        resetHold()
    }

    /// Process one head reading. Returns fire once when hold threshold is crossed.
    public mutating func process(reading: HeadReading) -> Output {
        let time = reading.timestamp
        let rule = reading.activeRule(
            yawThreshold: config.yawThresholdDegrees,
            pitchThreshold: config.pitchThresholdDegrees
        )

        // Recover whenever gaze is on-screen, even during Gemini cooldown.
        if rule == nil, currentlyDrifting {
            currentlyDrifting = false
            activeDriftRule = nil
            driftShrinkBudget = 0
            tickBall(at: time, shouldShrink: false)
            resetHold()
            lastTickAt = time
            return .refocused
        }

        let shouldShrink = currentlyDrifting && rule != nil && driftShrinkBudget > 0
        tickBall(at: time, shouldShrink: shouldShrink)

        if let until = cooldownUntil, time < until {
            // Cooldown blocks new fires, but never blocks recovery (handled above).
            if currentlyDrifting, let rule {
                activeDriftRule = rule
                lastTickAt = time
                return .stillDrifting(rule: rule)
            }
            resetHold()
            lastTickAt = time
            return .none
        }

        guard let rule else {
            resetHold()
            lastTickAt = time
            return .none
        }

        if currentlyDrifting {
            activeDriftRule = rule
            lastTickAt = time
            return .stillDrifting(rule: rule)
        }

        // Require a longer hold for no-face so blinks never unlock a fire.
        let neededHold = rule == .noFace ? max(config.holdDuration, 4.0) : config.holdDuration

        if holdRule != rule {
            holdRule = rule
            holdStartedAt = time
            lastTickAt = time
            return .none
        }

        guard let start = holdStartedAt else {
            holdStartedAt = time
            lastTickAt = time
            return .none
        }

        let held = time.timeIntervalSince(start)
        lastTickAt = time
        if held >= neededHold {
            currentlyDrifting = true
            activeDriftRule = rule
            driftShrinkBudget = 4.0 // brief taper after fire, not forever
            cooldownUntil = time.addingTimeInterval(config.cooldownDuration)
            // Optimistic shrink while Gemini answers
            applyConfirmedDistraction(severity: 2, duration: 0)
            resetHold()
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
        driftShrinkBudget = 3.0
        cooldownUntil = time.addingTimeInterval(config.cooldownDuration)
        applyConfirmedDistraction(severity: 3, duration: 0)
        resetHold()
        lastTickAt = time
        return .fire(rule: .offTaskWindow, heldFor: 0)
    }

    public func breakMinutes(quizScore: Double) -> Int {
        // Ball final size + quiz score → 10 / 5 / short review (0)
        let combined = (ballSize * 0.6) + (quizScore * 0.4)
        if combined >= 0.7 { return 10 }
        if combined >= 0.4 { return 5 }
        return 0 // short review block
    }

    // MARK: - Private

    private mutating func resetHold() {
        holdRule = nil
        holdStartedAt = nil
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
            let applied = min(dt, driftShrinkBudget)
            driftShrinkBudget = max(0, driftShrinkBudget - dt)
            let rate = config.shrinkBasePerSecond
            ballSize = max(0, ballSize - rate * applied)
        } else {
            ballSize = min(1, ballSize + config.recoverRatePerSecond * dt)
        }
    }
}
