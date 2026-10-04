import Vision
import AppKit
import ImageIO

/// Vision face detection → face present + yaw/pitch vs calibrated baseline.
/// Brief blinks are ignored via a no-face grace window so the ball does not twitch.
@MainActor
final class HeadTracker: ObservableObject {
    @Published private(set) var baseline: HeadBaseline?
    @Published private(set) var lastReading: HeadReading?
    @Published private(set) var liveYaw: Double = 0
    @Published private(set) var livePitch: Double = 0
    @Published private(set) var facePresent: Bool = false

    /// Ignore raw no-face shorter than this (typical blink ≪ 400ms).
    private let noFaceGrace: TimeInterval = 0.8
    /// Exponential smoothing on pose deltas to cut single-frame yaw/pitch spikes.
    private let poseSmoothing: Double = 0.35

    private var calibrationSamples: [(yaw: Double, pitch: Double)] = []
    private(set) var isCalibrating = false

    private var missingSince: Date?
    private var lastGoodYaw: Double = 0
    private var lastGoodPitch: Double = 0
    private var smoothedYaw: Double?
    private var smoothedPitch: Double?
    private var hadFace = false

    func startCalibration() {
        isCalibrating = true
        calibrationSamples = []
        baseline = nil
        missingSince = nil
        hadFace = false
        smoothedYaw = nil
        smoothedPitch = nil
    }

    func finishCalibration() -> HeadBaseline? {
        isCalibrating = false
        guard !calibrationSamples.isEmpty else { return nil }
        // Prefer the median of later samples so early posture settle doesn't skew baseline.
        let sorted = calibrationSamples.suffix(max(1, calibrationSamples.count / 2))
        let yawVals = sorted.map(\.yaw).sorted()
        let pitchVals = sorted.map(\.pitch).sorted()
        let yaw = yawVals[yawVals.count / 2]
        let pitch = pitchVals[pitchVals.count / 2]
        let b = HeadBaseline(yaw: yaw, pitch: pitch)
        baseline = b
        return b
    }

    func process(cgImage: CGImage, at time: Date) -> HeadReading {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])

        var rawFace = false
        var yaw: Double = 0
        var pitch: Double = 0

        do {
            try handler.perform([request])
            if let face = request.results?.first {
                rawFace = true
                let yawRad = face.yaw?.doubleValue ?? estimateYaw(from: face)
                let pitchRad = face.pitch?.doubleValue ?? estimatePitch(from: face)
                yaw = yawRad * 180.0 / .pi
                pitch = pitchRad * 180.0 / .pi
            }
        } catch {
            rawFace = false
        }

        let facePresent = smoothedFacePresent(rawFace: rawFace, at: time)
        if rawFace {
            if let sy = smoothedYaw, let sp = smoothedPitch {
                yaw = sy + (yaw - sy) * poseSmoothing
                pitch = sp + (pitch - sp) * poseSmoothing
            }
            smoothedYaw = yaw
            smoothedPitch = pitch
            lastGoodYaw = yaw
            lastGoodPitch = pitch
            hadFace = true
        } else if facePresent {
            // Still inside grace — reuse last good pose so blinks don't spike yaw/pitch.
            yaw = lastGoodYaw
            pitch = lastGoodPitch
        }

        self.facePresent = facePresent
        self.liveYaw = yaw
        self.livePitch = pitch

        if isCalibrating, rawFace {
            calibrationSamples.append((yaw, pitch))
        }

        let base = baseline ?? HeadBaseline(yaw: 0, pitch: 0)
        let reading = HeadReading(
            timestamp: time,
            facePresent: facePresent,
            yawDelta: yaw - base.yaw,
            pitchDelta: pitch - base.pitch
        )
        lastReading = reading
        return reading
    }

    private func smoothedFacePresent(rawFace: Bool, at time: Date) -> Bool {
        if rawFace {
            missingSince = nil
            return true
        }
        // Never treat "no face yet" at session start as a blink-grace hold.
        guard hadFace else { return false }

        if missingSince == nil {
            missingSince = time
        }
        let missingFor = time.timeIntervalSince(missingSince ?? time)
        return missingFor < noFaceGrace
    }

    /// Fallback yaw from eye/nose geometry when Vision angles unavailable.
    private func estimateYaw(from face: VNFaceObservation) -> Double {
        guard let landmarks = face.landmarks,
              let leftEye = landmarks.leftEye?.normalizedPoints.first,
              let rightEye = landmarks.rightEye?.normalizedPoints.first,
              let nose = landmarks.noseCrest?.normalizedPoints.first
                    ?? landmarks.nose?.normalizedPoints.first else {
            return 0
        }
        let midX = (leftEye.x + rightEye.x) / 2
        let offset = nose.x - midX
        return Double(offset) * 1.2
    }

    private func estimatePitch(from face: VNFaceObservation) -> Double {
        guard let landmarks = face.landmarks,
              let nose = landmarks.noseCrest?.normalizedPoints.first
                    ?? landmarks.nose?.normalizedPoints.first,
              let chin = landmarks.outerLips?.normalizedPoints.map(\.y).max() else {
            let box = face.boundingBox
            let centered = box.midY - 0.5
            return Double(-centered) * 0.8
        }
        let eyeY: CGFloat
        if let le = landmarks.leftEye?.normalizedPoints.first,
           let re = landmarks.rightEye?.normalizedPoints.first {
            eyeY = (le.y + re.y) / 2
        } else {
            eyeY = 0.65
        }
        let span = chin - eyeY
        let noseRel = (nose.y - eyeY) / max(span, 0.01)
        return Double(noseRel - 0.45) * 1.5
    }
}
