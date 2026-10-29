import Foundation
import MWDATCamera
import MWDATCore
import ProperDaveCore

enum WearablesBootstrap {
    private static var configured = false
    static func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        try? Wearables.configure()
    }
}

/// Meta glasses source over DAT 1.0 (TRD-001 CAP-03). Raw frames, sampled
/// down to the session interval, digested by the shared Vision extractor.
/// Any failure finishes the stream; the session then falls back to the
/// phone camera (CAP-14) or ends with one terminal notice (CAP-09) —
/// never a retry loop, and never a startup prerequisite (CAP-13).
final class MetaGlassesDigestSource: DigestSource, @unchecked Sendable {
    let sourceID = "meta-glasses"
    private(set) var lastFailure: String?
    var onFailure: ((String) -> Void)?
    /// Lifecycle diagnostics (event, detail) -> event log, component "capture".
    var onEvent: ((String, String) -> Void)?
    /// User-facing one-line status (e.g. waiting for the glasses to send).
    var onStatus: ((String) -> Void)?

    private var deviceSession: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private let tokenBag = ListenerTokenBag()
    private var continuation: AsyncStream<FrameDigest>.Continuation?
    private var startTask: Task<Void, Never>?
    private var extractor = DigestExtractor()
    private let frameDecoder = HEVCFrameDecoder()
    private var lastEmitted = Date.distantPast
    private var sequence = 0

    func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
        AsyncStream { [weak self] continuation in
            self?.continuation = continuation
            self?.startTask = Task { [weak self] in await self?.start(sessionID: sessionID, interval: interval) }
        }
    }

    func stop() {
        startTask?.cancel()
        camera?.stop(); camera = nil
        deviceSession?.stop(); deviceSession = nil
        tokenBag.clear()
        continuation?.finish(); continuation = nil
    }

    private func fail(_ message: String) {
        lastFailure = message
        onFailure?(message)
        stop()
    }

    private var frameCount = 0
    private var droppedFrames = 0
    private var sawFirstFrame = false

    private func start(sessionID: UUID, interval: TimeInterval) async {
        WearablesBootstrap.configureIfNeeded()
        let wearables = Wearables.shared
        onEvent?("glasses_registration_state", "\(wearables.registrationState)")

        if wearables.registrationState != .registered {
            do { try await wearables.startRegistration() }
            catch { fail("Glasses registration failed: \(error.localizedDescription)"); return }
            guard wearables.registrationState == .registered else {
                fail("Glasses are not registered yet. Finish in the Meta AI app (Developer Mode on), then try again.")
                return
            }
        }

        do {
            let status = try await wearables.checkPermissionStatus(.camera)
            onEvent?("glasses_camera_permission", "\(status)")
            if status != .granted {
                guard try await wearables.requestPermission(.camera) == .granted else {
                    fail("Camera permission for the glasses was not granted."); return
                }
            }
        } catch { fail("Glasses camera permission check failed: \(error.localizedDescription)"); return }

        let session: DeviceSession
        do { session = try wearables.createSession(deviceSelector: AutoDeviceSelector(wearables: wearables)) }
        catch { fail("Could not create a glasses session: \(error.localizedDescription)"); return }
        deviceSession = session
        session.errorPublisher.listen { [weak self] error in
            self?.fail("Glasses session error: \(error.localizedDescription)")
        }.store(in: tokenBag)

        do { try session.start() }
        catch { fail("Could not start the glasses session: \(error.localizedDescription)"); return }
        guard await waitUntilStarted(session, timeoutSeconds: 20) else {
            fail("The glasses session did not become ready in time. Check they are on and nearby."); return
        }
        onEvent?("glasses_session_started", "")

        // What SDK-visible devices exist right now? Zero devices here is
        // the signature of "registered, but no glasses in range/awake".
        let devices = wearables.devices.map { id -> String in
            guard let device = wearables.deviceForIdentifier(id) else { return "\(id) (unresolved)" }
            return "\(device.nameOrId()) link=\(device.linkState) compat=\(device.compatibility())"
        }
        onEvent?("glasses_devices", devices.isEmpty ? "none visible" : devices.joined(separator: "; "))

        let cam: MWDATCamera.Camera
        do {
            // hvc1 + VideoFrameDecoder, exactly Meta's sample path. (Raw
            // frames were our divergence; their sampleBuffer route is the
            // proven one.)
            guard let created = try session.addCamera(config: StreamConfiguration(videoCodec: .hvc1, resolution: .low, frameRate: 24)) else {
                fail("The glasses did not provide a camera."); return
            }
            cam = created
        } catch { fail("Could not add the glasses camera: \(error.localizedDescription)"); return }
        camera = cam
        onEvent?("glasses_camera_added", "codec=hvc1 low 24fps")

        cam.stream.statePublisher.listen { [weak self] state in
            guard let self else { return }
            onEvent?("glasses_stream_state", "\(state)")
            if state == .waitingForDevice {
                onStatus?("Waiting for the glasses to send video — try waking them or pressing their capture button.")
            }
        }.store(in: tokenBag)
        cam.stream.errorPublisher.listen { [weak self] error in
            self?.fail("Glasses stream error: \(error.localizedDescription)")
        }.store(in: tokenBag)
        cam.stream.videoFramePublisher.listen { [weak self] frame in
            guard let self else { return }
            frameCount += 1
            if !sawFirstFrame {
                sawFirstFrame = true
                onEvent?("glasses_first_frame", "frames are arriving")
                onStatus?("Glasses are sending video.")
            }
            if frameCount % 120 == 0 {
                onEvent?("glasses_frames", "count=\(frameCount) droppedNoPixelBuffer=\(droppedFrames)")
            }
            let now = Date()
            guard now.timeIntervalSince(lastEmitted) >= interval else { return }
            lastEmitted = now
            sequence += 1
            // Compressed hvc1 must be decompressed before Vision sees it
            // (Meta's sample does the equivalent via its own decoder).
            if let pixelBuffer = frameDecoder.decode(frame.sampleBuffer) {
                continuation?.yield(extractor.digest(pixelBuffer: pixelBuffer, sessionID: sessionID,
                                                     sequence: sequence, sourceID: sourceID))
            } else {
                droppedFrames += 1
                if droppedFrames == 1 {
                    onEvent?("glasses_frame_undecodable", "frames are arriving but HEVC decoding produced no pixel buffer")
                }
            }
        }.store(in: tokenBag)
        cam.stream.start()
        onEvent?("glasses_stream_started", "")
        // No-frame watchdog: silence here looks identical to a dead stream
        // in the log without this, so say so once and keep waiting.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !sawFirstFrame else { return }
            onEvent?("glasses_no_frames_yet", "stream started 15s ago, zero frames")
            onStatus?("No video from the glasses yet. Check they are on, worn, and nearby — and try their capture button.")
        }
    }

    private func waitUntilStarted(_ session: DeviceSession, timeoutSeconds: Int) async -> Bool {
        if session.state == .started { return true }
        return await withCheckedContinuation { continuation in
            var resumed = false
            let bag = ListenerTokenBag()
            session.statePublisher.listen { state in
                if state == .started && !resumed {
                    resumed = true; bag.clear(); continuation.resume(returning: true)
                }
            }.store(in: bag)
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                if !resumed { resumed = true; bag.clear(); continuation.resume(returning: false) }
            }
        }
    }
}
