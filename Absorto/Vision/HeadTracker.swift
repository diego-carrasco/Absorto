import Vision
import AppKit
import ImageIO

/// Vision face detection → face present, pose, eye closure, and yawn vs calibrated baselines.
@MainActor
final class HeadTracker: ObservableObject {
    @Published private(set) var baseline: HeadBaseline?
    @Published private(set) var lastReading: HeadReading?
    @Published private(set) var liveYaw: Double = 0
    @Published private(set) var livePitch: Double = 0
    @Published private(set) var facePresent: Bool = false
    @Published private(set) var liveEyeAspect: Double = 0
    @Published private(set) var liveMouthAspect: Double = 0

    /// Ignore raw no-face shorter than this (typical blink ≪ 300ms).
    private let noFaceGrace: TimeInterval = 0.35
    private let poseSmoothing: Double = 0.28
    private let ratioSmoothing: Double = 0.35

    /// Eyes closed if EAR drops below this fraction of the calibrated open-eye baseline.
    private let eyesClosedFraction: Double = 0.58
    /// Absolute EAR floor — catches closed eyes even if calibration was slightly squinted.
    private let eyesClosedAbsolute: Double = 0.13
    /// Yawn if MAR rises above this multiple of the calibrated resting mouth.
    private let yawnMultiple: Double = 2.1
    /// Absolute MAR floor for yawn when baseline is very small.
    private let yawnAbsolute: Double = 0.42

    private var calibrationSamples: [(yaw: Double, pitch: Double, ear: Double, mar: Double)] = []
    private(set) var isCalibrating = false

    private var missingSince: Date?
    private var lastGoodYaw: Double = 0
    private var lastGoodPitch: Double = 0
    private var smoothedYaw: Double?
    private var smoothedPitch: Double?
    private var smoothedEAR: Double?
    private var smoothedMAR: Double?
    private var baselineEAR: Double?
    private var baselineMAR: Double?
    private var hadFace = false

    func startCalibration() {
        isCalibrating = true
        calibrationSamples = []
        baseline = nil
        baselineEAR = nil
        baselineMAR = nil
        missingSince = nil
        hadFace = false
        smoothedYaw = nil
        smoothedPitch = nil
        smoothedEAR = nil
        smoothedMAR = nil
    }

    func finishCalibration() -> HeadBaseline? {
        isCalibrating = false
        guard !calibrationSamples.isEmpty else { return nil }

        let sorted = Array(calibrationSamples.suffix(max(1, calibrationSamples.count / 2)))
        let yawVals = sorted.map(\.yaw).sorted()
        let pitchVals = sorted.map(\.pitch).sorted()
        let earVals = sorted.map(\.ear).filter { $0 > 0.05 }.sorted()
        let marVals = sorted.map(\.mar).filter { $0 > 0.01 }.sorted()

        let yaw = yawVals[yawVals.count / 2]
        let pitch = pitchVals[pitchVals.count / 2]
        if !earVals.isEmpty {
            baselineEAR = earVals[earVals.count / 2]
        }
        if !marVals.isEmpty {
            baselineMAR = marVals[marVals.count / 2]
        }

        let b = HeadBaseline(yaw: yaw, pitch: pitch)
        baseline = b
        return b
    }

    func process(cgImage: CGImage, at time: Date) -> HeadReading {
        let rectRequest = VNDetectFaceRectanglesRequest()
        let landmarkRequest = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])

        var rawFace = false
        var yaw: Double = 0
        var pitch: Double = 0
        var ear: Double = 0
        var mar: Double = 0

        do {
            try handler.perform([rectRequest, landmarkRequest])
            if let face = rectRequest.results?.first {
                rawFace = true
                if let detailed = landmarkRequest.results?.first {
                    let yawRad = detailed.yaw?.doubleValue ?? estimateYaw(from: detailed)
                    let pitchRad = detailed.pitch?.doubleValue ?? estimatePitch(from: detailed)
                    yaw = yawRad * 180.0 / .pi
                    pitch = pitchRad * 180.0 / .pi
                    ear = eyeAspectRatio(from: detailed)
                    mar = mouthAspectRatio(from: detailed)
                } else {
                    yaw = lastGoodYaw
                    pitch = lastGoodPitch
                    ear = smoothedEAR ?? baselineEAR ?? 0
                    mar = smoothedMAR ?? baselineMAR ?? 0
                }
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

            if ear > 0 {
                if let se = smoothedEAR {
                    ear = se + (ear - se) * ratioSmoothing
                }
                smoothedEAR = ear
            } else {
                ear = smoothedEAR ?? 0
            }
            if mar > 0 {
                if let sm = smoothedMAR {
                    mar = sm + (mar - sm) * ratioSmoothing
                }
                smoothedMAR = mar
            } else {
                mar = smoothedMAR ?? 0
            }
        } else if facePresent {
            yaw = lastGoodYaw
            pitch = lastGoodPitch
            ear = smoothedEAR ?? 0
            mar = smoothedMAR ?? 0
        }

        self.facePresent = facePresent
        self.liveYaw = yaw
        self.livePitch = pitch
        self.liveEyeAspect = ear
        self.liveMouthAspect = mar

        if isCalibrating, rawFace, ear > 0.05 {
            calibrationSamples.append((yaw, pitch, ear, mar))
        }

        let base = baseline ?? HeadBaseline(yaw: 0, pitch: 0)
        let eyesClosed = facePresent && isEyesClosed(ear: ear)
        let yawning = facePresent && !eyesClosed && isYawning(mar: mar)

        let reading = HeadReading(
            timestamp: time,
            facePresent: facePresent,
            yawDelta: yaw - base.yaw,
            pitchDelta: pitch - base.pitch,
            eyesClosed: eyesClosed,
            yawning: yawning,
            eyeAspectRatio: ear,
            mouthAspectRatio: mar
        )
        lastReading = reading
        return reading
    }

    private func isEyesClosed(ear: Double) -> Bool {
        guard ear > 0 else { return false }
        if let base = baselineEAR, base > 0.08 {
            return ear < max(eyesClosedAbsolute, base * eyesClosedFraction)
        }
        // Without a solid baseline, use a conservative absolute cut.
        return ear < eyesClosedAbsolute
    }

    private func isYawning(mar: Double) -> Bool {
        guard mar > 0 else { return false }
        if let base = baselineMAR, base > 0.02 {
            return mar > max(yawnAbsolute, base * yawnMultiple)
        }
        return mar > yawnAbsolute
    }

    private func smoothedFacePresent(rawFace: Bool, at time: Date) -> Bool {
        if rawFace {
            missingSince = nil
            return true
        }
        guard hadFace else { return false }

        if missingSince == nil {
            missingSince = time
        }
        let missingFor = time.timeIntervalSince(missingSince ?? time)
        return missingFor < noFaceGrace
    }

    /// Eye aspect ratio = eyelid height / eye width (drops when eyes close).
    private func eyeAspectRatio(from face: VNFaceObservation) -> Double {
        guard let landmarks = face.landmarks else { return 0 }
        let left = regionAspectRatio(landmarks.leftEye)
        let right = regionAspectRatio(landmarks.rightEye)
        let vals = [left, right].filter { $0 > 0 }
        guard !vals.isEmpty else { return 0 }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// Mouth aspect ratio = lip opening height / mouth width (rises when yawning).
    private func mouthAspectRatio(from face: VNFaceObservation) -> Double {
        guard let landmarks = face.landmarks else { return 0 }
        // Prefer inner lips for opening; fall back to outer.
        let inner = regionAspectRatio(landmarks.innerLips)
        if inner > 0 { return inner }
        return regionAspectRatio(landmarks.outerLips)
    }

    private func regionAspectRatio(_ region: VNFaceLandmarkRegion2D?) -> Double {
        guard let region, region.pointCount >= 4 else { return 0 }
        let points = region.normalizedPoints
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return 0 }
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0.001 else { return 0 }
        return Double(height / width)
    }

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
