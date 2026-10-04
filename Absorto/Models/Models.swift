import Foundation

public struct Session: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var topic: String
    public var startedAt: Date
    public var endedAt: Date?
    public var focusScore: Double
    public var ballSize: Double
    public var breakMinutes: Int

    public init(
        id: UUID = UUID(),
        topic: String = "",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        focusScore: Double = 1.0,
        ballSize: Double = 1.0,
        breakMinutes: Int = 10
    ) {
        self.id = id
        self.topic = topic
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusScore = focusScore
        self.ballSize = ballSize
        self.breakMinutes = breakMinutes
    }
}

public enum DriftSource: String, Codable, Equatable, Sendable {
    case camera
    case window
}

public enum DriftRule: String, Codable, Equatable, Sendable {
    case noFace = "no_face"
    case eyesClosed = "eyes_closed"
    case yawn = "yawn"
    case headTurned = "head_turned"
    case headDown = "head_down"
    case offTaskWindow = "off_task_window"
}

public enum DriftCategory: String, Codable, Equatable, CaseIterable, Sendable {
    case phone
    case away
    case lookingElsewhere = "looking_elsewhere"
    case tired
    case other
    case falseAlarm = "false_alarm"
}

public struct DriftEvent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sessionId: UUID
    public let time: Date
    public let source: DriftSource
    public let rule: DriftRule
    public var category: DriftCategory?
    public var severity: Int
    public var falseAlarm: Bool
    public var seconds: TimeInterval
    public var studying: String?
    public var nudgeText: String?

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        time: Date = Date(),
        source: DriftSource,
        rule: DriftRule,
        category: DriftCategory? = nil,
        severity: Int = 1,
        falseAlarm: Bool = false,
        seconds: TimeInterval = 0,
        studying: String? = nil,
        nudgeText: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.time = time
        self.source = source
        self.rule = rule
        self.category = category
        self.severity = severity
        self.falseAlarm = falseAlarm
        self.seconds = seconds
        self.studying = studying
        self.nudgeText = nudgeText
    }
}

public enum QuestionKind: String, Codable, Equatable, Sendable {
    case multipleChoice = "multiple_choice"
    case teachBack = "teach_back"
}

public struct Question: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sessionId: UUID
    public let hotspot: String
    public let text: String
    public var kind: QuestionKind
    public var options: [String]
    public var correctOptionIndex: Int?
    public var selectedOptionIndex: Int?
    public var myAnswer: String
    public var correct: Bool?
    public var feedback: String?

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        hotspot: String,
        text: String,
        kind: QuestionKind = .teachBack,
        options: [String] = [],
        correctOptionIndex: Int? = nil,
        selectedOptionIndex: Int? = nil,
        myAnswer: String = "",
        correct: Bool? = nil,
        feedback: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.hotspot = hotspot
        self.text = text
        self.kind = kind
        self.options = options
        self.correctOptionIndex = correctOptionIndex
        self.selectedOptionIndex = selectedOptionIndex
        self.myAnswer = myAnswer
        self.correct = correct
        self.feedback = feedback
    }
}

public struct HeadReading: Equatable, Sendable {
    public let timestamp: Date
    public let facePresent: Bool
    /// Yaw relative to calibrated baseline, degrees. Positive = turned right.
    public let yawDelta: Double
    /// Pitch relative to calibrated baseline, degrees. Positive = looking down.
    public let pitchDelta: Double
    /// True when both eyes stay clearly more closed than the calibrated baseline.
    public let eyesClosed: Bool
    /// True when mouth opening clearly exceeds the calibrated baseline (yawn).
    public let yawning: Bool
    /// Live eye aspect ratio (height/width); 0 if unavailable.
    public let eyeAspectRatio: Double
    /// Live mouth aspect ratio (height/width); 0 if unavailable.
    public let mouthAspectRatio: Double

    public init(
        timestamp: Date,
        facePresent: Bool,
        yawDelta: Double,
        pitchDelta: Double,
        eyesClosed: Bool = false,
        yawning: Bool = false,
        eyeAspectRatio: Double = 0,
        mouthAspectRatio: Double = 0
    ) {
        self.timestamp = timestamp
        self.facePresent = facePresent
        self.yawDelta = yawDelta
        self.pitchDelta = pitchDelta
        self.eyesClosed = eyesClosed
        self.yawning = yawning
        self.eyeAspectRatio = eyeAspectRatio
        self.mouthAspectRatio = mouthAspectRatio
    }

    public var isLookingAway: Bool {
        isLookingAway(yawThreshold: DriftEngine.Config.yawThresholdDegrees)
    }

    public var isLookingDown: Bool {
        isLookingDown(pitchThreshold: DriftEngine.Config.pitchThresholdDegrees)
    }

    public var activeRule: DriftRule? {
        activeRule(
            yawThreshold: DriftEngine.Config.yawThresholdDegrees,
            pitchThreshold: DriftEngine.Config.pitchThresholdDegrees
        )
    }

    public func isLookingAway(yawThreshold: Double) -> Bool {
        facePresent && abs(yawDelta) >= yawThreshold
    }

    public func isLookingDown(pitchThreshold: Double) -> Bool {
        facePresent && pitchDelta >= pitchThreshold
    }

    /// Priority: no face → eyes closed → yawn → head down → head turned.
    public func activeRule(yawThreshold: Double, pitchThreshold: Double) -> DriftRule? {
        if !facePresent { return .noFace }
        if eyesClosed { return .eyesClosed }
        if yawning { return .yawn }
        if isLookingDown(pitchThreshold: pitchThreshold) { return .headDown }
        if isLookingAway(yawThreshold: yawThreshold) { return .headTurned }
        return nil
    }
}

public struct HeadBaseline: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double

    public init(yaw: Double, pitch: Double) {
        self.yaw = yaw
        self.pitch = pitch
    }
}

public enum SessionPhase: Equatable, Sendable {
    case idle
    case requestingPermissions
    /// Get seated / face the camera before samples are taken.
    case preparingCalibration(secondsLeft: Int)
    case calibrating(secondsLeft: Int)
    case studying
    /// White ball hit zero; red warning held ~5s — waiting for user choice.
    case attentionLost
    case ending
    case submitEvidence
    case recall
    /// Brief pause after quiz submit before the break timer starts.
    case breakStarting(secondsLeft: Int)
    case onBreak
}

/// One line in the break penalty breakdown (quiz item or distractions).
public struct BreakPenaltyLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var detail: String
    /// true = green (no penalty / correct), false = red (time withdrawn)
    public var isCredit: Bool

    public init(id: UUID = UUID(), title: String, detail: String, isCredit: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isCredit = isCredit
    }
}

public struct AttentionMapResult: Equatable, Sendable {
    public var topic: String
    public var summary: String
    public var hotspots: [String]
    public var questions: [Question]

    public init(topic: String, summary: String, hotspots: [String], questions: [Question]) {
        self.topic = topic
        self.summary = summary
        self.hotspots = hotspots
        self.questions = questions
    }
}

public struct GradeResult: Equatable, Sendable {
    public var scorePerQuestion: [Bool]
    public var feedback: [String]
    public var weakTopic: String
    public var overallScore: Double

    public init(scorePerQuestion: [Bool], feedback: [String], weakTopic: String, overallScore: Double) {
        self.scorePerQuestion = scorePerQuestion
        self.feedback = feedback
        self.weakTopic = weakTopic
        self.overallScore = overallScore
    }
}
