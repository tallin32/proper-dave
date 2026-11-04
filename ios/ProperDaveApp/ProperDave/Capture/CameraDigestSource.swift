import AVFoundation
import Foundation
import ProperDaveCore
import UIKit

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
    private var stopped = true
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        // iOS stops the camera when the app leaves the foreground
        // (answering a notification mid-goal is enough) and does not
        // promise to restart it on return: without this, the goal
        // survives the switch but comes back blind. Termination is
        // still possible — that side is durability (incremental
        // bundle flush + launch repair), not resurrection.
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: captureSession, queue: nil) { [weak self] _ in
            self?.resumeIfNeeded(reason: "interruption ended")
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: nil) { [weak self] _ in
            self?.resumeIfNeeded(reason: "returned to foreground")
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    private func resumeIfNeeded(reason: String) {
        queue.async { [weak self] in
            guard let self, !stopped, configured, !captureSession.isRunning else { return }
            captureSession.startRunning()
            onEvent?("capture_resumed", reason)
        }
    }

    private var captureDevice: AVCaptureDevice?
    private var torchPolicy = TorchPolicy()
    /// Automatic flashlight (Settings, on by default): applied from
    /// the digest brightness on this queue. Glasses have no torch
    /// here — absence is a no-op, never a failure (CAP-13).
    var autoTorchEnabled = true
    var onEvent: ((String, String) -> Void)?

    func imageData(for digest: FrameDigest) -> Data? { framesBySequence[digest.sequence] }

    private func applyTorch(_ on: Bool) {
        guard let device = captureDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if on { try device.setTorchModeOn(level: 1.0) } else { device.torchMode = .off }
            device.unlockForConfiguration()
            onEvent?("torch_\(on ? "on" : "off")", "auto flashlight")
        } catch {
            onEvent?("torch_failed", error.localizedDescription)
        }
    }

    func setCadence(_ interval: TimeInterval) {
        queue.async { [weak self] in self?.interval = interval }
    }

    func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
        self.sessionID = sessionID
        self.interval = interval
        queue.async { [weak self] in self?.stopped = false }
        return AsyncStream { [weak self] continuation in
            self?.continuation = continuation
            self?.startCapture()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            stopped = true
            if let off = torchPolicy.reset() { applyTorch(off) }
            captureSession.stopRunning()
        }
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
                    captureDevice = device
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
            if autoTorchEnabled, let want = torchPolicy.update(brightness: digest.sceneChange.brightness) {
                applyTorch(want)
            }
            if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
               let jpeg = extractor.jpegData(pixelBuffer: buffer, orientation: .right) {
                framesBySequence[sequence] = jpeg
                framesBySequence = framesBySequence.filter { $0.key > sequence - 5 }
            }
            continuation?.yield(digest)
        }
    }
}
