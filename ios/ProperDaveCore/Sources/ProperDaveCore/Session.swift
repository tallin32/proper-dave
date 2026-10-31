import Foundation

/// Replaceable digest source (TRD-001). The session never knows which
/// physical camera — or none — sits behind a source.
public protocol DigestSource: Sendable {
    var sourceID: String { get }
    /// Specific, user-actionable failure detail when the source has one
    /// (e.g. "the app on your glasses needs an update"), so a terminal
    /// failure can say that instead of a generic stopped message.
    var failureDetail: String? { get }
    func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest>
    func stop()
    /// JPEG frame corresponding to a digest, when the source can retain
    /// it. ESCALATE_FRAME exists to ask a model to look; sources that
    /// only produce digests return nil and the model is told so.
    func imageData(for digest: FrameDigest) -> Data?
}

public extension DigestSource {
    var failureDetail: String? { nil }
    func imageData(for digest: FrameDigest) -> Data? { nil }
}

/// Scripted concourse walk for demos/tests. No camera, no glasses.
public final class MockDigestSource: DigestSource, @unchecked Sendable {
    public let sourceID = "mock"
    private var task: Task<Void, Never>?
    public init() {}
    static let scenes: [(labels: [String], ocr: [String], pixel: Double)] = [
        (["concourse"], ["Concourse B"], 0.05),
        (["person", "sign"], ["Concourse B"], 0.15),
        (["sign"], ["Gate B40"], 0.65),
        (["sign"], ["Gate B40", "Coffee"], 0.10),
        (["sign"], ["Gate B42"], 0.60),
        (["person"], ["Gate B42"], 0.12),
        (["sign"], ["Gate B62"], 0.70),
        (["sign"], ["Gate B62"], 0.03),
    ]
    public func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
        AsyncStream { continuation in
            task = Task {
                var sequence = 0
                while !Task.isCancelled {
                    let scene = Self.scenes[sequence % Self.scenes.count]
                    sequence += 1
                    continuation.yield(FrameDigest(
                        sessionID: sessionID, sequence: sequence, sourceID: sourceID,
                        labels: scene.labels.map { ScoredLabel(name: $0, confidence: 0.9) },
                        ocrText: scene.ocr.map { OCRSpan(text: $0, confidence: 0.9) },
                        sceneChange: ChangeMetrics(pixelDiff: scene.pixel, labelDelta: 0.2)))
                    try? await Task.sleep(for: .seconds(interval))
                }
                continuation.finish()
            }
        }
    }
    public func stop() { task?.cancel() }
}

@MainActor
public final class SessionController: ObservableObject {
    public enum State: Equatable { case idle, starting, watching, pausedForDebug, ended, failed(String) }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var goal: GoalContext?
    @Published public private(set) var lastCallout: String?
    @Published public private(set) var decisionTrail: [String] = []
    @Published public private(set) var escalationCount = 0
    @Published public private(set) var activeSourceID: String?

    public var onCallout: ((String) -> Void)?
    public var onCriticalError: ((String, String) -> Void)?
    /// One-line spoken notices that are neither callouts nor errors
    /// (refinement applied/declined, describe-mode notes).
    public var onNotice: ((String) -> Void)?
    /// Called when a stream belonging to the *active* source ends while
    /// watching. The app may return a fallback source (e.g. phone camera)
    /// to keep the goal alive — CAP-14 degradation, not an error.
    public var fallbackSource: (() -> (any DigestSource)?)?
    /// Notified when a live source that had been delivering frames dies
    /// and the session falls back, so the user is told once.
    public var onSourceFallback: ((String) -> Void)?

    private let log: EventLog
    private var task: Task<Void, Never>?
    private var sessionID = UUID()
    private var client: (any CloudModelClient)?
    /// Understanding (parse/refine) split from judging (evaluate):
    /// the best local understander parses even when escalation
    /// judgement routes elsewhere by policy (TRD-003 §2).
    private var parser: (any CloudModelClient)?
    private var interval: TimeInterval = 2
    private var cooldown: TimeInterval = Classifier.defaultCooldown
    private var lastEscalationAt: Date?
    private var reportedLandmarks = Set<String>()
    private var announcedTopics = Set<String>()
    private var window: [FrameDigest] = []
    private var currentSource: (any DigestSource)?

    public init(log: EventLog) { self.log = log }
    public var currentSessionID: UUID { sessionID }

    public func start(goalText: String, client: any CloudModelClient, source: any DigestSource,
                      interval: TimeInterval = 2, cooldown: TimeInterval = Classifier.defaultCooldown) {
        start(goalText: goalText, parser: client, evaluator: client, source: source,
              interval: interval, cooldown: cooldown)
    }

    public func start(goalText: String, parser: any CloudModelClient, evaluator: any CloudModelClient,
                      source: any DigestSource, interval: TimeInterval = 2,
                      cooldown: TimeInterval = Classifier.defaultCooldown) {
        stop(confirm: false)
        sessionID = UUID()
        self.client = evaluator
        self.parser = parser
        self.interval = interval
        self.cooldown = cooldown
        state = .starting
        lastCallout = nil; decisionTrail = []; escalationCount = 0
        reportedLandmarks = []; announcedTopics = []; window = []; lastEscalationAt = nil
        log.append(sessionID: sessionID, component: "session", event: "goal_start_requested", detail: goalText)
        task = Task { [weak self] in
            guard let self else { return }
            let parsed: GoalContext
            do { parsed = try await parser.parseGoal(goalText) }
            catch {
                // Log the actual error, not just the modal title:
                // a field report that says only "Could not start
                // watching" is undiagnosable (owner field log, 04:58).
                log.append(sessionID: sessionID, component: "session", event: "goal_parse_failed",
                           detail: error.localizedDescription)
                state = .failed(error.localizedDescription)
                onCriticalError?("Could not start watching", "The goal could not be understood: \(error.localizedDescription)")
                return
            }
            guard parsed.kind != .watch || !parsed.targets.isEmpty else {
                state = .failed("No targets in that goal.")
                onCriticalError?("Could not start watching", "No targets were found. Try rephrasing the goal.")
                return
            }
            goal = parsed
            // Describe narrates on scene transitions, not frame churn:
            // a longer floor under the cooldown (CLS-14).
            if parsed.kind == .describe { self.cooldown = max(self.cooldown, 20) }
            log.append(sessionID: sessionID, component: "session", event: "goal_started",
                       detail: "targets=\(parsed.targets.joined(separator: ","))")
            await consume(source: source, goal: parsed, client: evaluator)
        }
    }

    /// CAP-14: swap the frame source mid-goal. Goal, session, window, and
    /// cooldown all carry over; only the frame supply changes.
    public func switchSource(to source: any DigestSource) {
        guard state == .watching || state == .pausedForDebug, let goal, let client else { return }
        // Stop the old source explicitly: cancelling the task alone leaves
        // its producer (e.g. an AVCaptureSession) running, and its loop
        // would keep consuming the shared session after the switch.
        let old = currentSource
        task?.cancel()
        old?.stop()
        log.append(sessionID: sessionID, component: "capture", event: "source_switched",
                   detail: "from=\(old?.sourceID ?? "none") to=\(source.sourceID)")
        task = Task { [weak self] in
            await self?.consume(source: source, goal: goal, client: client)
        }
    }

    /// CLS-16: patch the running goal in place. Session, source,
    /// window, cooldown, and announced-topic state all carry over; a
    /// refinement that cannot be applied changes nothing and says so
    /// exactly once.
    public func refineGoal(text: String) {
        guard let current = goal, let parser,
              state == .watching || state == .pausedForDebug else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let patched = try await parser.refine(current: current, refinement: text)
                goal = patched
                log.append(sessionID: sessionID, component: "session", event: "goal_refined",
                           detail: "verbosity=\(patched.verbosity.rawValue) targets=\(patched.targets.joined(separator: ",")) exclusions=\(patched.exclusions.joined(separator: ","))")
                onNotice?("Goal updated.")
            } catch {
                log.append(sessionID: sessionID, component: "session", event: "goal_refine_failed",
                           detail: text)
                onNotice?("I couldn't apply that change, so I'm keeping the current goal.")
            }
        }
    }

    private func consume(source: any DigestSource, goal: GoalContext, client: any CloudModelClient) async {
        state = .watching
        activeSourceID = source.sourceID
        currentSource = source
        log.append(sessionID: sessionID, component: "capture", event: "capture_started", detail: source.sourceID)
        var received = 0
        for await digest in source.stream(sessionID: sessionID, interval: interval) {
            // A cancelled task belongs to a superseded source: stop eating
            // its frames even though the session itself is still watching.
            if Task.isCancelled { break }
            received += 1
            if state == .pausedForDebug { continue }
            guard state == .watching else { break }
            if goal.kind == .question {
                // One-shot (TRD-000 §6): answer from the first frame,
                // then end. Never becomes a watch, never gated by
                // saliency — the user asked about *this* scene.
                escalationCount += 1
                let image = source.imageData(for: digest)?.base64EncodedString()
                let request = EscalationRequest(sessionID: sessionID, goal: goal, digest: digest,
                                                recentDigests: [], image: image, lastCallout: nil)
                log.append(sessionID: sessionID, component: "cloud", event: "question_sent", detail: goal.rawText)
                do {
                    switch try await client.evaluate(request) {
                    case .callout(let text, _):
                        lastCallout = text
                        log.append(sessionID: sessionID, component: "speech", event: "callout_spoken", detail: text)
                        onCallout?(text)
                    case .noCallout(let reason):
                        log.append(sessionID: sessionID, component: "cloud", event: "no_callout", detail: reason)
                        onNotice?("I couldn't tell what's there from this view.")
                    }
                } catch {
                    log.append(sessionID: sessionID, component: "cloud", event: "model_error", detail: error.localizedDescription)
                    onNotice?("I couldn't answer that just now.")
                }
                log.append(sessionID: sessionID, component: "session", event: "question_answered", detail: "")
                state = .ended
                source.stop()
                return
            }
            let since = lastEscalationAt.map { Date().timeIntervalSince($0) }
            let (decision, scores) = Classifier.evaluate(
                digest: digest, window: window, goal: goal, lastCallout: lastCallout,
                secondsSinceEscalation: since, reportedLandmarks: reportedLandmarks,
                announcedTopics: announcedTopics, cooldown: cooldown)
            log.append(sessionID: sessionID, component: "classifier", event: "decision",
                       detail: "#\(digest.sequence) \(decision.name) change=\(String(format: "%.2f", scores.change)) relevance=\(String(format: "%.2f", scores.relevance)) src=\(digest.sourceID)")
            decisionTrail.append("#\(digest.sequence) \(decision.name)")
            if decisionTrail.count > 30 { decisionTrail.removeFirst() }
            window.append(digest)
            if window.count > 5 { window.removeFirst() }
            guard decision.isEscalation else { continue }
            if let landmark = scores.landmark { reportedLandmarks.insert(landmark) }
            if goal.kind == .describe { announcedTopics.formUnion(scores.topics) }
            lastEscalationAt = Date()
            escalationCount += 1
            let image = source.imageData(for: digest)?.base64EncodedString()
            let request = EscalationRequest(sessionID: sessionID, goal: goal, digest: digest,
                                            recentDigests: window, image: image,
                                            lastCallout: lastCallout)
            log.append(sessionID: sessionID, component: "cloud", event: "escalation_sent", detail: decision.name)
            do {
                switch try await client.evaluate(request) {
                case .callout(let text, _):
                    lastCallout = text
                    log.append(sessionID: sessionID, component: "speech", event: "callout_spoken", detail: text)
                    onCallout?(text)
                case .noCallout(let reason):
                    log.append(sessionID: sessionID, component: "cloud", event: "no_callout", detail: reason)
                }
            } catch {
                log.append(sessionID: sessionID, component: "cloud", event: "model_error", detail: error.localizedDescription)
            }
        }
        guard state == .watching, !Task.isCancelled else { return }
        // Active source ended mid-goal. Fall back if we can (CAP-14);
        // otherwise one terminal notice — never a retry loop (CAP-09/11).
        log.append(sessionID: sessionID, component: "capture", event: "capture_source_ended",
                   detail: "\(source.sourceID) afterFrames=\(received)")
        // Fallback is for a source that was working and died (CAP-14), not
        // for one that never delivered: silently switching cameras after a
        // failed glasses start hides exactly the failure the user must see.
        if received > 0, let fallback = fallbackSource?(), fallback.sourceID != source.sourceID {
            log.append(sessionID: sessionID, component: "capture", event: "source_fallback", detail: "to=\(fallback.sourceID)")
            onSourceFallback?(fallback.sourceID)
            await consume(source: fallback, goal: goal, client: client)
            return
        }
        activeSourceID = nil
        state = .failed("Frame source stopped.")
        // Surface the source's own actionable message when it has one;
        // a generic stopped notice would bury the actual instruction.
        onCriticalError?("Frame source stopped",
                         source.failureDetail
                            ?? "The camera or glasses stopped sending frames. Check the source is on and nearby; for glasses, that they are registered and Developer Mode is on.")
    }

    public func pauseForDebugLog() {
        guard state == .watching else { return }
        state = .pausedForDebug
        log.append(sessionID: sessionID, component: "capture", event: "capture_paused_debug")
    }
    public func resumeFromDebugLog() {
        guard state == .pausedForDebug else { return }
        state = .watching
        log.append(sessionID: sessionID, component: "capture", event: "capture_resumed_debug")
    }
    public func stop(confirm: Bool = true) {
        task?.cancel(); task = nil
        currentSource?.stop(); currentSource = nil
        if state != .idle { log.append(sessionID: sessionID, component: "session", event: "goal_ended") }
        activeSourceID = nil
        state = confirm ? .ended : .idle
    }
}
