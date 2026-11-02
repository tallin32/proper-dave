import AVFoundation
import Foundation
import ProperDaveCore

/// Phone-camera source: AVFoundation frames throttled to the session
/// interval, digested on device. Works with no glasses present (CAP-13).
final class CameraDigestSource: NSObject, DigestSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let sourceID = "iphone-camera"
    private let captureSession = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "properdave.camera")
    private var continuation: AsyncStream<FrameDigest>.Continuation?
    private var sessionID = UUID()
    private var sequence = 0
    private var lastEmitted = Date.distantPast
    private var interval: TimeInterval = 1
    private var extractor = DigestExtractor()
    private var configured = false
    private var framesBySequence: [Int: Data] = [:]

    func imageData(for digest: FrameDigest) -> Data? { framesBySequence[digest.sequence] }

    func setCadence(_ interval: TimeInterval) {
        queue.async { [weak self] in self?.interval = interval }
    }

    func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
        self.sessionID = sessionID
        self.interval = interval
        return AsyncStream { [weak self] continuation in
            self?.continuation = continuation
            self?.startCapture()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.captureSession.stopRunning() }
        continuation?.finish()
        continuation = nil
    }

    private func startCapture() {
        queue.async { [weak self] in
            guard let self else { return }
            if !configured {
                captureSession.beginConfiguration()
                captureSession.sessionPreset = .medium
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   captureSession.canAddInput(input) {
                    captureSession.addInput(input)
                }
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: queue)
                if captureSession.canAddOutput(output) { captureSession.addOutput(output) }
                captureSession.commitConfiguration()
                configured = true
            }
            if !captureSession.isRunning { captureSession.startRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Every frame feeds the motion probe, even though digests
        // stay throttled: a motion spike earns an early digest
        // (event-driven sampling) instead of waiting out the
        // interval while the scene passes unexamined.
        var frameMotion = -1.0
        if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            frameMotion = extractor.noteFrame(pixelBuffer: buffer)
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastEmitted)
        let due = elapsed >= interval
        let spike = frameMotion >= 0.30 && elapsed >= 0.4
        guard due || spike else { return }
        lastEmitted = now
        sequence += 1
        if let digest = extractor.digest(sampleBuffer: sampleBuffer, sessionID: sessionID,
                                         sequence: sequence, sourceID: sourceID) {
            if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
               let jpeg = extractor.jpegData(pixelBuffer: buffer) {
                framesBySequence[sequence] = jpeg
                framesBySequence = framesBySequence.filter { $0.key > sequence - 5 }
            }
            continuation?.yield(digest)
        }
    }
}
