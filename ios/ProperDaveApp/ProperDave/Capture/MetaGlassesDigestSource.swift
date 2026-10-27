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

    private var deviceSession: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private let tokenBag = ListenerTokenBag()
    private var continuation: AsyncStream<FrameDigest>.Continuation?
    private var startTask: Task<Void, Never>?
    private var extractor = DigestExtractor()
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

    private func start(sessionID: UUID, interval: TimeInterval) async {
        WearablesBootstrap.configureIfNeeded()
        let wearables = Wearables.shared

        if wearables.registrationState != .registered {
            do { try await wearables.startRegistration() }
            catch { fail("Glasses registration failed: \(error.localizedDescription)"); return }
            guard wearables.registrationState == .registered else {
                fail("Glasses are not registered yet. Finish in the Meta AI app (Developer Mode on), then try again.")
                return
            }
        }

        do {
            if try await wearables.checkPermissionStatus(.camera) != .granted {
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

        let cam: MWDATCamera.Camera
        do {
            guard let created = try session.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 24)) else {
                fail("The glasses did not provide a camera."); return
            }
            cam = created
        } catch { fail("Could not add the glasses camera: \(error.localizedDescription)"); return }
        camera = cam

        cam.stream.errorPublisher.listen { [weak self] error in
            self?.fail("Glasses stream error: \(error.localizedDescription)")
        }.store(in: tokenBag)
        cam.stream.videoFramePublisher.listen { [weak self] frame in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(lastEmitted) >= interval else { return }
            lastEmitted = now
            sequence += 1
            if let digest = extractor.digest(sampleBuffer: frame.sampleBuffer, sessionID: sessionID,
                                             sequence: sequence, sourceID: sourceID) {
                continuation?.yield(digest)
            }
        }.store(in: tokenBag)
        cam.stream.start()
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
