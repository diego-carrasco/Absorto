import XCTest
@testable import AbsortoCore

final class DriftEngineTests: XCTestCase {
    private func reading(
        at offset: TimeInterval,
        face: Bool = true,
        yaw: Double = 0,
        pitch: Double = 0,
        from start: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> HeadReading {
        HeadReading(
            timestamp: start.addingTimeInterval(offset),
            facePresent: face,
            yawDelta: yaw,
            pitchDelta: pitch
        )
    }

    func testOneSecondGlanceNeverFires() {
        var engine = DriftEngine(config: .default)
        let start = Date(timeIntervalSince1970: 1_000_000)

        for t in stride(from: 0.0, through: 1.0, by: 0.25) {
            let out = engine.process(reading: reading(at: t, pitch: 30, from: start))
            if case .fire = out {
                XCTFail("1s glance should not fire, got fire at t=\(t)")
            }
        }

        let out = engine.process(reading: reading(at: 1.2, pitch: 0, from: start))
        XCTAssertEqual(out, .none)
    }

    func testSixSecondLookDownFiresOnce() {
        var engine = DriftEngine(config: .default)
        let start = Date(timeIntervalSince1970: 1_000_000)
        var fireCount = 0

        for t in stride(from: 0.0, through: 6.0, by: 0.5) {
            let out = engine.process(reading: reading(at: t, pitch: 30, from: start))
            if case .fire = out { fireCount += 1 }
        }

        XCTAssertEqual(fireCount, 1, "6s look-down should fire exactly once")
        XCTAssertLessThan(engine.ballSize, 1.0)
    }

    func testTwoDriftsInsideCooldownFireGeminiOnlyOnce() {
        var engine = DriftEngine(config: .default)
        let start = Date(timeIntervalSince1970: 1_000_000)
        var fireCount = 0

        for t in stride(from: 0.0, through: 5.5, by: 0.5) {
            if case .fire = engine.process(reading: reading(at: t, pitch: 30, from: start)) {
                fireCount += 1
            }
        }

        _ = engine.process(reading: reading(at: 6.0, pitch: 0, from: start))
        for t in stride(from: 6.5, through: 12.0, by: 0.5) {
            if case .fire = engine.process(reading: reading(at: t, pitch: 30, from: start)) {
                fireCount += 1
            }
        }

        XCTAssertEqual(fireCount, 1, "cooldown should suppress a second Gemini trigger")
    }

    func testNoFaceRule() {
        var engine = DriftEngine(config: .demo)
        let start = Date(timeIntervalSince1970: 1_000_000)
        var fired: DriftRule?

        for t in stride(from: 0.0, through: 4.5, by: 0.5) {
            if case .fire(let rule, _) = engine.process(reading: reading(at: t, face: false, from: start)) {
                fired = rule
            }
        }

        XCTAssertEqual(fired, .noFace)
    }

    func testYawRule() {
        var engine = DriftEngine(config: .demo)
        let start = Date(timeIntervalSince1970: 1_000_000)
        var fired: DriftRule?

        for t in stride(from: 0.0, through: 3.5, by: 0.5) {
            if case .fire(let rule, _) = engine.process(reading: reading(at: t, yaw: 40, from: start)) {
                fired = rule
            }
        }

        XCTAssertEqual(fired, .headTurned)
    }

    func testBallRecoversWhenFocused() {
        var engine = DriftEngine(config: .demo)
        engine.applyConfirmedDistraction(severity: 5, duration: 2)
        let shrunken = engine.ballSize
        XCTAssertLessThan(shrunken, 1.0)

        let start = Date(timeIntervalSince1970: 1_000_000)
        for t in stride(from: 0.0, through: 90.0, by: 1.0) {
            _ = engine.process(reading: reading(at: t, from: start))
        }

        XCTAssertGreaterThan(engine.ballSize, shrunken)
    }

    func testBreakMinutesFromBallAndScore() {
        var engine = DriftEngine(config: .default)
        XCTAssertEqual(engine.breakMinutes(quizScore: 1.0), 10)

        engine.applyConfirmedDistraction(severity: 5, duration: 10)
        let minutes = engine.breakMinutes(quizScore: 0.0)
        XCTAssertTrue([0, 5].contains(minutes))
    }

    func testVoiceSpacing() {
        var engine = DriftEngine(config: .default)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(engine.shouldSpeak(at: t0))
        engine.markVoiceSpoken(at: t0)
        XCTAssertFalse(engine.shouldSpeak(at: t0.addingTimeInterval(30)))
        XCTAssertTrue(engine.shouldSpeak(at: t0.addingTimeInterval(121)))
    }

    func testWindowDriftRespectsCooldown() {
        var engine = DriftEngine(config: .default)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        let first = engine.fireWindowDrift(at: t0)
        XCTAssertEqual(first, .fire(rule: .offTaskWindow, heldFor: 0))

        let second = engine.fireWindowDrift(at: t0.addingTimeInterval(2))
        XCTAssertEqual(second, .none)
    }

    func testRefocusDuringCooldownRecoversBall() {
        var engine = DriftEngine(config: .default)
        let start = Date(timeIntervalSince1970: 1_000_000)

        for t in stride(from: 0.0, through: 5.5, by: 0.5) {
            _ = engine.process(reading: reading(at: t, pitch: 30, from: start))
        }
        let afterFire = engine.ballSize

        var sawRefocus = false
        for t in stride(from: 6.0, through: 12.0, by: 0.5) {
            if case .refocused = engine.process(reading: reading(at: t, pitch: 0, from: start)) {
                sawRefocus = true
            }
        }

        XCTAssertTrue(sawRefocus)
        XCTAssertGreaterThanOrEqual(engine.ballSize, afterFire)
    }
}
