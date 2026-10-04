import AVFoundation
import AppKit
import CoreImage

/// Low-resolution webcam capture ~4–5 fps; late frames dropped.
@MainActor
final class CameraService: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastImage: NSImage?
    @Published private(set) var authorizationStatus: AVAuthorizationStatus = .notDetermined

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.absorto.camera", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private var lastEmit = Date.distantPast
    private let minInterval: TimeInterval = 0.22 // ~4.5 fps
    private var onFrame: ((CGImage, Date) -> Void)?
    private var busy = false

    func requestAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        authorizationStatus = status
        if status == .authorized { return true }
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
            return granted
        }
        return false
    }

    func start(onFrame: @escaping (CGImage, Date) -> Void) {
        self.onFrame = onFrame
        guard !session.isRunning else { return }

        session.beginConfiguration()
        session.sessionPreset = .low

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(videoOutput)
        session.commitConfiguration()

        queue.async { [weak self] in
            self?.session.startRunning()
            Task { @MainActor in self?.isRunning = true }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.session.stopRunning()
            Task { @MainActor in
                self?.isRunning = false
                self?.onFrame = nil
            }
        }
    }

    func snapshotJPEG(maxDimension: CGFloat = 512) -> Data? {
        guard let image = lastImage else { return nil }
        return ImageCodec.jpeg(from: image, maxDimension: maxDimension, quality: 0.6)
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        Task { @MainActor in
            guard now.timeIntervalSince(self.lastEmit) >= self.minInterval else { return }
            guard !self.busy else { return }
            self.busy = true
            self.lastEmit = now

            let ciImage = CIImage(cvPixelBuffer: pixel)
            guard let cg = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                self.busy = false
                return
            }
            self.lastImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            self.onFrame?(cg, now)
            self.busy = false
        }
    }
}
