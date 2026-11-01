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

public enum EvaluatorError: LocalizedError {
    case timedOut(seconds: Int)
    public var errorDescription: String? {
        switch self {
        case .timedOut(let seconds): return "The model did not answer within \(seconds) seconds."
        }
    }
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
    /// Hard cap on one evaluator call. A first Qwen load on device
    /// exceeded 32s in the field with the consume loop blocked
    /// behind it; beyond this the session treats the model as
    /// unavailable instead of freezing.
    public var evaluatorTimeoutSeconds: TimeInterval = 45
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
            if let intent = GoalIntent.intentGoal(for: goalText) {
                log.append(sessionID: sessionID, component: "session", event: "goal_intent_prefilter",
                           detail: intent.kind.rawValue)
                parsed = intent
            } else {
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
            }
            guard parsed.kind != .watch || !parsed.targets.isEmpty else {
                state = .failed("No targets in that goal.")
                onCriticalError?("Could not start watching", "No targets were found. Try rephrasing the goal.")
                return
            }
            goal = parsed
            // Describe narrates on scene transitions, not frame churn:
            // a longer floor under the cooldown (CLS-14). Scene-change
            // goals are the exception — their whole point is prompt
            // notice when the view swaps, so they keep the caller's
            // cooldown rather than the stroll floor.
            if parsed.kind == .describe && !parsed.isSceneChangeGoal { self.cooldown = max(self.cooldown, 20) }
            log.append(sessionID: sessionID, component: "session", event: "goal_started",
                       detail: "kind=\(parsed.kind.rawValue) verbosity=\(parsed.verbosity.rawValue) targets=\(parsed.targets.joined(separator: ","))")
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
        var describeBaselineAttempted = false
        var modelBackoffUntil: Date?
        for await digest in source.stream(sessionID: sessionID, interval: interval) {
            // A cancelled task belongs to a superseded source: stop eating
            // its frames even though the session itself is still watching.
            if Task.isCancelled { break }
            received += 1
            if state == .pausedForDebug { continue }
            guard state == .watching else { break }
            if goal.kind == .question {
                // One-shot (TRD-000 §6): answer from the first
                // *usable* frame, then end. A camera's first digest
                // is routinely black/still-exposing; answering from
                // it produced field noCallouts ("No visual
                // information is present", 01:27). Wait for a digest
                // carrying any label or OCR, up to 3 digests, then
                // answer from the latest regardless.
                let usable = digest.labels.contains { $0.confidence >= 0.5 } || !digest.ocrText.isEmpty
                if !usable && received < 3 {
                    log.append(sessionID: sessionID, component: "capture", event: "question_waiting_frame",
                               detail: "digest #\(received) has no confident labels or OCR yet")
                    continue
                }
                escalationCount += 1
                let image = source.imageData(for: digest)?.base64EncodedString()
                let request = EscalationRequest(sessionID: sessionID, goal: goal, digest: digest,
                                                recentDigests: [], image: image, lastCallout: nil)
                log.append(sessionID: sessionID, component: "cloud", event: "question_sent", detail: goal.rawText)
                do {
                    switch try await evaluateWithTimeout(client, request) {
                    case .callout(let text, _) where Self.isPromptEcho(text):
                        log.append(sessionID: sessionID, component: "speech", event: "callout_suppressed_echo", detail: text)
                        if !Task.isCancelled { onNotice?("I couldn't tell what's there from this view.") }
                    case .callout(let text, _):
                        if !Task.isCancelled {
                            lastCallout = text
                            log.append(sessionID: sessionID, component: "speech", event: "callout_spoken", detail: text)
                            onCallout?(text)
                        }
                    case .noCallout(let reason):
                        log.append(sessionID: sessionID, component: "cloud", event: "no_callout", detail: reason)
                        if !Task.isCancelled { onNotice?("I couldn't tell what's there from this view.") }
                    }
                } catch {
                    log.append(sessionID: sessionID, component: "cloud", event: "model_error", detail: error.localizedDescription)
                    if !Task.isCancelled { onNotice?("I couldn't answer that just now.") }
                }
                log.append(sessionID: sessionID, component: "session", event: "question_answered", detail: "")
                state = .ended
                source.stop()
                return
            }
            if goal.kind == .describe && !describeBaselineAttempted {
                // The baseline report is owed on the first *usable*
                // scene, not the camera's first black warmup digest
                // (same trap as one-shot questions). Wait for a digest
                // carrying any label or OCR, up to 3 digests; after
                // that the scene is reported as-is — a genuine dark
                // or blank view is itself the first description.
                // "Usable" also means settled: the first frame after
                // capture starts is routinely a black, still-exposing
                // warmup frame that Vision nonetheless labels, and a
                // frontier model judged exactly that frame "completely
                // black" as a describe baseline (field log 05:56).
                // Skip digest #1 outright and require a label Vision
                // held with real confidence (or OCR) after that.
                let usable = digest.labels.contains { $0.confidence >= 0.5 } || !digest.ocrText.isEmpty
                if (!usable || received < 2) && received < 3 {
                    log.append(sessionID: sessionID, component: "capture", event: "describe_waiting_frame",
                               detail: "digest #\(received) is not a settled, usable scene yet")
                    continue
                }
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
            if let modelBackoffUntil, Date() < modelBackoffUntil {
                // The model told us to slow down (rate limited in
                // the field after an escalation storm); hammering
                // it every digest only extends the penalty.
                log.append(sessionID: sessionID, component: "cloud", event: "escalation_suppressed_backoff",
                           detail: "model backoff until \(modelBackoffUntil)")
                continue
            }
            if let landmark = scores.landmark { reportedLandmarks.insert(landmark) }
            if goal.kind == .describe { announcedTopics.formUnion(scores.topics) }
            lastEscalationAt = Date()
            escalationCount += 1
            let image = source.imageData(for: digest)?.base64EncodedString()
            let request = EscalationRequest(sessionID: sessionID, goal: goal, digest: digest,
                                            recentDigests: window, image: image,
                                            lastCallout: lastCallout)
            log.append(sessionID: sessionID, component: "cloud", event: "escalation_sent", detail: decision.name)
            // A describe goal owes the user one first report even
            // when the model stays silent — including "the view is
            // dark or blank", which is a truthful description of a
            // void, not a "target not found" narration. The wording
            // comes only from the digest itself, never invented.
            let isDescribeBaseline = goal.kind == .describe && !describeBaselineAttempted && lastCallout == nil
            describeBaselineAttempted = true
            func speakDescribeBaselineFallback() {
                // Only labels Vision held with real confidence may
                // be named; its low-confidence guesses on a dark
                // bathroom produced a phantom "night sky" in the
                // field. Below the bar, the honest report is the
                // dark/blank one.
                let visible = digest.labels.filter { $0.confidence >= 0.5 }.map(\.name) + digest.ocrText.map(\.text)
                let text = visible.isEmpty
                    ? "I can't make anything out from the camera right now. The view looks dark or blank."
                    : visible.prefix(3).joined(separator: ", ") + " in view."
                lastCallout = text
                log.append(sessionID: sessionID, component: "speech", event: "describe_baseline_fallback", detail: text)
                onCallout?(text)
            }
            let callStarted = Date()
            let result: Result<CalloutResult, Error>
            do { result = .success(try await evaluateWithTimeout(client, request)) }
            catch { result = .failure(error) }
            log.append(sessionID: sessionID, component: "cloud", event: "model_call_finished",
                       detail: "\(Int(Date().timeIntervalSince(callStarted) * 1000))ms model=\(client.modelName)")
            // A result that lands after the goal ended (the user
            // stopped while Qwen was still loading) must never be
            // spoken: the field log showed a baseline fallback
            // firing after goal_ended.
            if Task.isCancelled { break }
            switch result {
            case .success(.callout(let text, _)):
                if Self.isPromptEcho(text) {
                    log.append(sessionID: sessionID, component: "speech", event: "callout_suppressed_echo", detail: text)
                    if isDescribeBaseline { speakDescribeBaselineFallback() }
                } else if let lastCallout, Self.isDuplicateCallout(text, of: lastCallout) {
                    // Never say the same thing twice in a row:
                    // a model that describes every room as "a
                    // cluttered area" must not become a loop.
                    log.append(sessionID: sessionID, component: "speech", event: "callout_suppressed_duplicate", detail: text)
                } else {
                    lastCallout = text
                    log.append(sessionID: sessionID, component: "speech", event: "callout_spoken", detail: text)
                    onCallout?(text)
                }
            case .success(.noCallout(let reason)):
                log.append(sessionID: sessionID, component: "cloud", event: "no_callout", detail: reason)
                if reason == "too_soon" {
                    // Our own server's anti-storm backstop, not a
                    // model judgement: never let it trigger the
                    // baseline fallback (field log 05:56 chain).
                    // Pause briefly and silently; a baseline stays owed.
                    modelBackoffUntil = Date().addingTimeInterval(5)
                    log.append(sessionID: sessionID, component: "cloud", event: "model_backoff",
                               detail: "escalations paused briefly after server said too_soon")
                    if isDescribeBaseline { describeBaselineAttempted = false }
                } else if reason == "model_unavailable" || reason == "rate_limited" {
                    // A backend health signal, not a judgement
                    // about the scene: it must never trigger the
                    // dark/blank fallback (field log 04:29, first
                    // server session — every escalation returned
                    // one of these and the baseline announced a
                    // void). Back off, keep the baseline owed, and
                    // say what actually happened, once.
                    modelBackoffUntil = Date().addingTimeInterval(reason == "rate_limited" ? 10 : 30)
                    log.append(sessionID: sessionID, component: "cloud", event: "model_backoff",
                               detail: "escalations paused after server said \(reason)")
                    if isDescribeBaseline {
                        describeBaselineAttempted = false
                        onNotice?(reason == "rate_limited"
                            ? "The model is rate limited right now. I'll keep watching and try again shortly."
                            : "The model isn't responding right now. I'll keep watching and try again shortly.")
                    }
                } else if isDescribeBaseline {
                    speakDescribeBaselineFallback()
                }
            case .failure(let error):
                log.append(sessionID: sessionID, component: "cloud", event: "model_error", detail: error.localizedDescription)
                let lowered = error.localizedDescription.lowercased()
                if lowered.contains("rate limit") || lowered.contains("did not answer within") {
                    modelBackoffUntil = Date().addingTimeInterval(30)
                    log.append(sessionID: sessionID, component: "cloud", event: "model_backoff",
                               detail: "escalations paused 30s after: \(error.localizedDescription)")
                }
                if lowered.contains("rate limit") && isDescribeBaseline {
                    // A rate limit says nothing about the scene;
                    // it must not trigger the dark/blank fallback
                    // (field log 03:45, where a new goal opened
                    // during a system-model limit and announced a
                    // void). Say what actually happened, keep the
                    // baseline owed, and retry after the backoff.
                    describeBaselineAttempted = false
                    onNotice?("The model is rate limited right now. I'll keep watching and try again shortly.")
                } else if isDescribeBaseline {
                    speakDescribeBaselineFallback()
                }
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
    /// Prompt-echo check: a model that copies its directions into
    /// the answer text ("The on-device gate has already
    /// established…", field log 03:19) must never be spoken. The
    /// phrases are boilerplate from our own prompts/instructions,
    /// never legitimate scene descriptions.
    nonisolated static func isPromptEcho(_ text: String) -> Bool {
        let low = text.lowercased()
        return ["on-device gate", "not yours to re-make", "silence preference",
                "silence is preferred", "these instructions", "these directions",
                "no change occurred", "materially changed — that",
                "direct scene report", "direct question",
                "nothing has been spoken for this goal"].contains { low.contains($0) }
    }

    /// Near-duplicate speech check: same words, or one text's
    /// words almost wholly contained in the other's ("The scene
    /// is a cluttered area…" vs "A cluttered area…").
    nonisolated static func isDuplicateCallout(_ text: String, of previous: String) -> Bool {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let a = words(text), b = words(previous)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let overlap = Double(a.intersection(b).count) / Double(min(a.count, b.count))
        return overlap >= 0.8
    }

    private func evaluateWithTimeout(_ client: any CloudModelClient,
                                     _ request: EscalationRequest) async throws -> CalloutResult {
        let seconds = evaluatorTimeoutSeconds
        return try await withThrowingTaskGroup(of: CalloutResult.self) { group in
            group.addTask { try await client.evaluate(request) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw EvaluatorError.timedOut(seconds: Int(seconds))
            }
            guard let result = try await group.next() else {
                throw EvaluatorError.timedOut(seconds: Int(seconds))
            }
            group.cancelAll()
            return result
        }
    }

    public func stop(confirm: Bool = true) {
        task?.cancel(); task = nil
        currentSource?.stop(); currentSource = nil
        if state != .idle { log.append(sessionID: sessionID, component: "session", event: "goal_ended") }
        activeSourceID = nil
        state = confirm ? .ended : .idle
    }
}
