import Foundation
import AbsortoCore

/// Lightweight assertions so we can verify the drift engine without XCTest/Xcode.
@main
struct DriftEngineSmoke {
    static func main() {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("PASS  \(name)")
            } else {
                failures += 1
                print("FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            }
        }

        func reading(
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

        // 1-second glance never fires
        do {
            var engine = DriftEngine(config: .default)
            let start = Date(timeIntervalSince1970: 1_000_000)
            var fired = false
            for t in stride(from: 0.0, through: 1.0, by: 0.25) {
                if case .fire = engine.process(reading: reading(at: t, pitch: 30, from: start)) {
                    fired = true
                }
            }
            check("1s glance never fires", !fired)
        }

        // 6s look-down fires once
        do {
            var engine = DriftEngine(config: .default)
            let start = Date(timeIntervalSince1970: 1_000_000)
            var fireCount = 0
            for t in stride(from: 0.0, through: 6.0, by: 0.5) {
                if case .fire = engine.process(reading: reading(at: t, pitch: 30, from: start)) {
                    fireCount += 1
                }
            }
            check("6s look-down fires once", fireCount == 1, "count=\(fireCount)")
            check("ball shrinks after fire", engine.ballSize < 1.0, "ball=\(engine.ballSize)")
        }

        // Cooldown suppresses second fire
        do {
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
            check("cooldown: only one fire", fireCount == 1, "count=\(fireCount)")
        }

        // Default no-face: exact 5s hold, then fire (blinks filtered in HeadTracker)
        do {
            var engine = DriftEngine(config: .default)
            let start = Date(timeIntervalSince1970: 1_000_000)
            var firedAt: TimeInterval?
            for t in stride(from: 0.0, through: 6.0, by: 0.25) {
                if case .fire(let rule, _) = engine.process(reading: reading(at: t, face: false, from: start)) {
                    check("no-face rule", rule == .noFace)
                    firedAt = t
                    break
                }
            }
            check("no-face fires at 5s", abs((firedAt ?? -1) - 5.0) < 0.3, "t=\(String(describing: firedAt))")
        }

        // Continuous distraction empties the ball (red-path prerequisite)
        do {
            var engine = DriftEngine(config: .default)
            let start = Date(timeIntervalSince1970: 1_000_000)
            for t in stride(from: 0.0, through: 30.0, by: 0.5) {
                _ = engine.process(reading: reading(at: t, face: false, from: start))
            }
            check("continuous drift empties ball", engine.ballSize <= 0.02, "ball=\(engine.ballSize)")
        }

        // Eyes closed / yawn use the same 5s hold
        do {
            var engine = DriftEngine(config: .default)
            let start = Date(timeIntervalSince1970: 1_000_000)
            var fired: DriftRule?
            for t in stride(from: 0.0, through: 5.5, by: 0.25) {
                let r = HeadReading(
                    timestamp: start.addingTimeInterval(t),
                    facePresent: true,
                    yawDelta: 0,
                    pitchDelta: 0,
                    eyesClosed: true
                )
                if case .fire(let rule, _) = engine.process(reading: r) { fired = rule }
            }
            check("eyes-closed fires after hold", fired == .eyesClosed)
        }
        do {
            var engine = DriftEngine(config: .default)
            let start = Date(timeIntervalSince1970: 1_000_000)
            var fired: DriftRule?
            for t in stride(from: 0.0, through: 5.5, by: 0.25) {
                let r = HeadReading(
                    timestamp: start.addingTimeInterval(t),
                    facePresent: true,
                    yawDelta: 0,
                    pitchDelta: 0,
                    yawning: true
                )
                if case .fire(let rule, _) = engine.process(reading: r) { fired = rule }
            }
            check("yawn fires after hold", fired == .yawn)
        }

        // Brief no-face must not shrink ball before fire
        do {
            var engine = DriftEngine(config: .demo)
            let start = Date(timeIntervalSince1970: 1_000_000)
            for t in stride(from: 0.0, through: 1.5, by: 0.25) {
                _ = engine.process(reading: reading(at: t, face: false, from: start))
            }
            check("blink does not shrink ball", abs(engine.ballSize - 1.0) < 0.001, "ball=\(engine.ballSize)")
        }

        // Voice spacing
        do {
            var engine = DriftEngine(config: .default)
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            check("voice allowed first time", engine.shouldSpeak(at: t0))
            engine.markVoiceSpoken(at: t0)
            check("voice blocked inside spacing", !engine.shouldSpeak(at: t0.addingTimeInterval(30)))
            check("voice allowed after spacing", engine.shouldSpeak(at: t0.addingTimeInterval(121)))
        }

        // Window drift cooldown
        do {
            var engine = DriftEngine(config: .default)
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            let first = engine.fireWindowDrift(at: t0)
            let second = engine.fireWindowDrift(at: t0.addingTimeInterval(2))
            check("window drift fires", first == .fire(rule: .offTaskWindow, heldFor: 0))
            check("window drift respects cooldown", second == .none)
        }

        // After fire, looking at screen during cooldown must recover (not keep shrinking)
        do {
            var engine = DriftEngine(config: .default)
            let start = Date(timeIntervalSince1970: 1_000_000)
            for t in stride(from: 0.0, through: 5.5, by: 0.5) {
                _ = engine.process(reading: reading(at: t, pitch: 30, from: start))
            }
            let afterFire = engine.ballSize
            var sawRefocus = false
            for t in stride(from: 6.0, through: 12.0, by: 0.5) {
                let out = engine.process(reading: reading(at: t, pitch: 0, from: start))
                if case .refocused = out { sawRefocus = true }
            }
            check("refocus clears drift during cooldown", sawRefocus)
            check("ball recovers while focused in cooldown", engine.ballSize > afterFire - 0.001, "ball=\(engine.ballSize) afterFire=\(afterFire)")
        }

        // Focused gaze must not shrink without a fire
        do {
            var engine = DriftEngine(config: .default)
            let start = Date(timeIntervalSince1970: 1_000_000)
            for t in stride(from: 0.0, through: 20.0, by: 0.5) {
                _ = engine.process(reading: reading(at: t, yaw: 10, pitch: 8, from: start))
            }
            check("on-screen gaze keeps ball full", abs(engine.ballSize - 1.0) < 0.001, "ball=\(engine.ballSize)")
        }

        // Break minutes: quiz misses + drifts
        do {
            check(
                "break full score no drifts",
                DriftEngine.breakMinutes(correctCount: 10, questionCount: 10, confirmedDrifts: 0) == 10
            )
            check(
                "break 6/10 and 3 drifts",
                DriftEngine.breakMinutes(correctCount: 6, questionCount: 10, confirmedDrifts: 3) == 3
            )
            check(
                "break floors at 1",
                DriftEngine.breakMinutes(correctCount: 0, questionCount: 10, confirmedDrifts: 20) == 1
            )
        }

        if failures == 0 {
            print("\nAll drift-engine smoke checks passed.")
            exit(0)
        } else {
            print("\n\(failures) check(s) failed.")
            exit(1)
        }
    }
}
