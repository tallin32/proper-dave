import XCTest
@testable import ProperDaveCore

final class ProperDaveCoreTests: XCTestCase {
    private var seq = 0
    private func digest(labels: [String] = [], ocr: [String] = [], pixel: Double = 0,
                        brightness: Double = -1) -> FrameDigest {
        seq += 1
        return FrameDigest(sessionID: UUID(), sequence: seq, sourceID: "test",
                           labels: labels.map { ScoredLabel(name: $0, confidence: 0.9) },
                           ocrText: ocr.map { OCRSpan(text: $0, confidence: 0.9) },
                           sceneChange: ChangeMetrics(pixelDiff: pixel, brightness: brightness))
    }

    func testStaticSceneIsSilent() {
        let goal = GoalContext(rawText: "g", targets: ["Gate B62"])
        let window = (0..<5).map { _ in digest(ocr: ["Concourse B"], pixel: 0.02) }
        let (d, _) = Classifier.evaluate(digest: digest(ocr: ["Concourse B"], pixel: 0.02), window: window, goal: goal)
        XCTAssertEqual(d, .suppress(reason: "noMaterialChange"))
    }
    func testGateSignEscalates() {
        let goal = GoalContext(rawText: "g", targets: ["Gate B62"])
        let (d, _) = Classifier.evaluate(digest: digest(ocr: ["Gate B62"], pixel: 0.6),
                                         window: [digest(ocr: ["Concourse B"])], goal: goal)
        XCTAssertTrue(d.isEscalation)
    }
    func testCooldownSuppresses() {
        let goal = GoalContext(rawText: "g", targets: ["Gate B62"])
        let (d, _) = Classifier.evaluate(digest: digest(ocr: ["Gate B62"], pixel: 0.6),
                                         window: [digest(ocr: ["Concourse B"])], goal: goal, secondsSinceEscalation: 2)
        XCTAssertEqual(d, .suppress(reason: "cooldown"))
    }
    func testProgressLandmark() {
        let goal = GoalContext(rawText: "g", targets: ["Gate B62"], progressLandmarks: "gate numbers")
        let (d, s) = Classifier.evaluate(digest: digest(ocr: ["Gate B40"], pixel: 0.6),
                                         window: [digest(ocr: ["Concourse B"])], goal: goal)
        XCTAssertTrue(d.isEscalation); XCTAssertEqual(s.landmark, "B40")
    }
    func testGlassesMicGateNeedsBuildAndUser() {
        XCTAssertTrue(ExperimentalFeatures.glassesMicrophoneEnabled(userEnabled: true, buildAllows: true))
        XCTAssertFalse(ExperimentalFeatures.glassesMicrophoneEnabled(userEnabled: true, buildAllows: false))
        XCTAssertFalse(ExperimentalFeatures.glassesMicrophoneEnabled(userEnabled: false, buildAllows: true))
    }
    func testDownloadablePackSpecIsPinnedAndSized() {
        let spec = ModelPackSpec.qwen3VL2B
        XCTAssertEqual(spec.totalBytes, 1_798_022_204)
        XCTAssertEqual(Set(spec.files.map(\.name)).count, spec.files.count)
        XCTAssertTrue(spec.files.contains { $0.name == "model.safetensors" && $0.bytes > 1_700_000_000 })
        XCTAssertEqual(spec.license, "Apache-2.0")
    }

    func testLocalModelPromptCarriesDigestAndImageHonesty() {
        let goal = GoalContext(rawText: "find gate B62", targets: ["Gate B62"])
        let request = EscalationRequest(
            sessionID: UUID(), goal: goal,
            digest: digest(labels: ["sign"], ocr: ["Gate B62"]),
            recentDigests: [], image: nil, lastCallout: "Gate B40 ahead.")
        let prompt = LocalModelPrompt.escalation(request)
        XCTAssertTrue(prompt.contains("Gate B62"))
        XCTAssertTrue(prompt.contains("Attached image: no"))
        XCTAssertTrue(prompt.contains("do not invent visual details"))
    }

    final class ImageSpySource: DigestSource, @unchecked Sendable {
        let sourceID = "image-spy"
        func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
            AsyncStream { continuation in
                continuation.yield(FrameDigest(
                    sessionID: sessionID, sequence: 1, sourceID: sourceID,
                    ocrText: [OCRSpan(text: "Gate B62")],
                    sceneChange: ChangeMetrics(pixelDiff: 0.7)))
                continuation.finish()
            }
        }
        func stop() {}
        func imageData(for digest: FrameDigest) -> Data? { Data("jpeg".utf8) }
    }

    final class RecordingClient: CloudModelClient, @unchecked Sendable {
        var modelName = "recording"
        private(set) var images: [String?] = []
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: ["Gate B62"])
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            images.append(request.image)
            return .noCallout(reason: "test")
        }
    }

    @MainActor
    func testSessionAttachesSourceImageToEscalation() async throws {
        let session = SessionController(log: EventLog())
        let client = RecordingClient()
        session.start(goalText: "find gate B62", client: client,
                      source: ImageSpySource(), interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.5))
        session.stop()
        XCTAssertEqual(client.images, [Data("jpeg".utf8).base64EncodedString()])
    }

    func testCalloutDecodesServerJSON() throws {
        let json = #"{"kind":"noCallout","text":null,"relevance":null,"reason":"rate_limited"}"#
        XCTAssertEqual(try JSONDecoder().decode(CalloutResult.self, from: Data(json.utf8)),
                       .noCallout(reason: "rate_limited"))
    }

    @MainActor
    func testGoalLifecycleWithoutAnyGlasses() async throws {
        // CAP-13: no glasses source exists in this test at all; a full goal
        // must still run and produce its callout with zero errors.
        let session = SessionController(log: EventLog())
        var callouts: [String] = []
        var errors: [String] = []
        session.onCallout = { callouts.append($0) }
        session.onCriticalError = { title, _ in errors.append(title) }
        session.start(goalText: "Tell me when I reach gate B62",
                      client: DemoCloudClient(), source: MockDigestSource(), interval: 0.05, cooldown: 0.08)
        try await Task.sleep(for: .seconds(1.2))
        session.stop()
        XCTAssertTrue(callouts.contains { $0.contains("B62") }, "callouts: \(callouts)")
        XCTAssertTrue(errors.isEmpty, "errors: \(errors)")
    }

    /// Regression: switching sources must stop the old producer, and a
    /// superseded consume loop must not keep eating its frames (this was
    /// the "everything still comes from the camera after switching to
    /// glasses" bug).
    final class SpySource: DigestSource, @unchecked Sendable {
        let sourceID: String
        private(set) var stopped = false
        private var task: Task<Void, Never>?
        init(id: String) { sourceID = id }
        func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
            AsyncStream { continuation in
                task = Task {
                    var seq = 0
                    while !Task.isCancelled {
                        seq += 1
                        continuation.yield(FrameDigest(
                            sessionID: sessionID, sequence: seq, sourceID: sourceID,
                            ocrText: [OCRSpan(text: "Concourse B")],
                            sceneChange: ChangeMetrics(pixelDiff: 0.05)))
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    continuation.finish()
                }
            }
        }
        func stop() { stopped = true; task?.cancel() }
    }

    @MainActor
    func testSwitchStopsOldSource() async throws {
        let session = SessionController(log: EventLog())
        let first = SpySource(id: "first-source")
        session.start(goalText: "Tell me when I reach gate B62",
                      client: DemoCloudClient(), source: first, interval: 0.02, cooldown: 0.05)
        try await Task.sleep(for: .seconds(0.4))
        XCTAssertFalse(first.stopped)
        session.switchSource(to: SpySource(id: "second-source"))
        try await Task.sleep(for: .seconds(0.2))
        session.stop()
        XCTAssertTrue(first.stopped, "switchSource must stop the previous source")
    }

    @MainActor
    func testMidGoalSourceSwitchKeepsSession() async throws {
        // CAP-14: switching sources mid-goal keeps the same goal/session
        // and callouts continue afterwards.
        let session = SessionController(log: EventLog())
        var callouts: [String] = []
        session.onCallout = { callouts.append($0) }
        session.start(goalText: "Tell me when I reach gate B62",
                      client: DemoCloudClient(), source: MockDigestSource(), interval: 0.05, cooldown: 0.08)
        try await Task.sleep(for: .seconds(0.5))
        let sessionBefore = session.currentSessionID
        session.switchSource(to: MockDigestSource())
        try await Task.sleep(for: .seconds(1.0))
        session.stop()
        XCTAssertEqual(session.currentSessionID, sessionBefore)
        XCTAssertTrue(callouts.contains { $0.contains("B62") }, "callouts: \(callouts)")
    }
}

extension ProperDaveCoreTests {
    private func dgoal(targets: [String] = [], verbosity: Verbosity = .notable) -> GoalContext {
        GoalContext(rawText: "describe", targets: targets, kind: .describe, verbosity: verbosity)
    }
    func testDescribeStorefrontEscalates() {
        let (d, s) = Classifier.evaluate(digest: digest(labels: ["storefront"], ocr: ["Verizon"], pixel: 0.6),
                                         window: [digest(ocr: ["Concourse B"])], goal: dgoal())
        XCTAssertTrue(d.isEscalation); XCTAssertTrue(s.topics.contains("verizon"))
    }
    func testDescribeCandyWrapperIsBeneathNotice() {
        let (d, _) = Classifier.evaluate(digest: digest(labels: ["wrapper"], pixel: 0.6),
                                         window: [digest(ocr: ["Fifth Avenue"])], goal: dgoal())
        XCTAssertEqual(d, .suppress(reason: "notSalient"))
    }
    func testDescribeWrapperMattersOnFloorCheck() {
        let (d, s) = Classifier.evaluate(digest: digest(labels: ["wrapper"], pixel: 0.6),
                                         window: [digest(labels: ["floor"], pixel: 0.1)],
                                         goal: dgoal(targets: ["small items on the floor"]))
        XCTAssertTrue(d.isEscalation); XCTAssertEqual(s.relevance, 0.85)
    }
    func testDescribeAnnouncedTopicNotRepeated() {
        let (d, _) = Classifier.evaluate(digest: digest(labels: ["storefront"], ocr: ["Verizon"], pixel: 0.6),
                                         window: [digest(ocr: ["Concourse B"])], goal: dgoal(),
                                         announcedTopics: ["verizon", "storefront"])
        XCTAssertEqual(d, .suppress(reason: "alreadyAnnounced"))
    }
    func testDescribePeopleWatchingFocus() {
        let (d, _) = Classifier.evaluate(digest: digest(labels: ["person"], pixel: 0.6),
                                         window: [digest(labels: ["platform"])], goal: dgoal(targets: ["people"]))
        XCTAssertTrue(d.isEscalation)
    }
    func testDescribeLandmarksVerbosityIsStricter() {
        let (d, _) = Classifier.evaluate(digest: digest(ocr: ["Bakery"], pixel: 0.6),
                                         window: [digest(ocr: ["Street"])], goal: dgoal(verbosity: .landmarks))
        XCTAssertEqual(d, .suppress(reason: "notSalient"))
    }
}

extension ProperDaveCoreTests {
    func testRefinementPatchesGoal() async throws {
        let client = DemoCloudClient()
        let base = GoalContext(rawText: "describe", targets: ["shops"], kind: .describe)
        let p1 = try await client.refine(current: base, refinement: "just the landmarks")
        XCTAssertEqual(p1.verbosity, .landmarks)
        let p2 = try await client.refine(current: base, refinement: "skip shops")
        XCTAssertEqual(p2.exclusions, ["shops"]); XCTAssertTrue(p2.targets.isEmpty)
        do {
            _ = try await client.refine(current: base, refinement: "make it nicer somehow")
            XCTFail("unparseable refinement must throw")
        } catch { /* expected: running goal stays untouched */ }
    }

    func testDemoParserClassifiesDescribe() async throws {
        let g = try await DemoCloudClient().parseGoal("Tell me what I see as I pass. Watch the shops")
        XCTAssertEqual(g.kind, .describe); XCTAssertEqual(g.targets, ["shops"])
    }

    @MainActor
    func testDescribeGoalStartsWithoutTargets() async throws {
        let session = SessionController(log: EventLog())
        var errors: [String] = []
        session.onCriticalError = { title, _ in errors.append(title) }
        session.start(goalText: "Tell me what I see as I pass",
                      client: DemoCloudClient(), source: MockDigestSource(), interval: 0.05, cooldown: 0.08)
        try await Task.sleep(for: .seconds(0.6))
        session.stop()
        XCTAssertEqual(session.goal?.kind, .describe)
        XCTAssertTrue(errors.isEmpty, "errors: \(errors)")
    }
}

extension ProperDaveCoreTests {
    func testGoalPatchApplication() {
        let goal = GoalContext(rawText: "stroll", targets: ["shops", "signs"], kind: .describe)
        let patched = GoalPatch(verbosity: .landmarks, addExclusions: ["shops"]).applied(to: goal)
        XCTAssertEqual(patched.verbosity, .landmarks)
        XCTAssertEqual(patched.targets, ["signs"])
        XCTAssertEqual(patched.exclusions, ["shops"])
    }

    @MainActor
    func testSessionSplitsParserFromEvaluator() async throws {
        let session = SessionController(log: EventLog())
        let evaluator = RecordingClient()
        session.start(goalText: "Tell me when I reach gate B62",
                      parser: DemoCloudClient(), evaluator: evaluator,
                      source: ImageSpySource(), interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.5))
        session.stop()
        XCTAssertEqual(session.goal?.targets, ["Gate B62"])
        XCTAssertEqual(evaluator.images, [Data("jpeg".utf8).base64EncodedString()])
    }
}

extension ProperDaveCoreTests {
    func testDescribeFirstDigestAlwaysEscalatesBaseline() {
        let (d, _) = Classifier.evaluate(digest: digest(labels: ["wrapper"], pixel: 0.6),
                                         window: [], goal: dgoal())
        XCTAssertTrue(d.isEscalation)
    }

    func testDescribeBrightnessSwingBypassesCooldown() {
        // Field log 00:25: a "how well lit" goal's dimming events
        // died under the cooldown; lights changing produces no new
        // labels and zero saliency, so brightness must bypass both.
        let window = [digest(labels: ["room"], pixel: 0.1, brightness: 0.65)]
        let (d, _) = Classifier.evaluate(digest: digest(labels: ["room"], pixel: 0.1, brightness: 0.12),
                                         window: window, goal: dgoal(verbosity: .detailed),
                                         secondsSinceEscalation: 5)
        XCTAssertTrue(d.isEscalation, "\(d)")
        if case .escalateFrame = d {} else { XCTFail("expected frame escalation, got \(d)") }
        let (small, _) = Classifier.evaluate(digest: digest(labels: ["room"], pixel: 0.1, brightness: 0.55),
                                             window: window, goal: dgoal(verbosity: .detailed),
                                             secondsSinceEscalation: 5)
        XCTAssertFalse(small.isEscalation, "\(small)")
    }

    final class AnswerClient: CloudModelClient, @unchecked Sendable {
        var modelName = "answer"
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: ["the scene in front of the camera"], kind: .question)
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            .callout(text: "A door and a sign.", relevance: 1)
        }
    }

    @MainActor
    func testQuestionGoalAnswersOnceAndEnds() async throws {
        let session = SessionController(log: EventLog())
        var spoken: [String] = []
        session.onCallout = { spoken.append($0) }
        session.start(goalText: "Tell me what's in front of the camera",
                      client: AnswerClient(), source: ImageSpySource(), interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.6))
        XCTAssertEqual(spoken, ["A door and a sign."])
        XCTAssertEqual(session.state, .ended)
    }
}

extension ProperDaveCoreTests {
    func testQuestionPromptDemandsAnAnswer() {
        let goal = GoalContext(rawText: "Tell me what's in front of the camera",
                               targets: ["the scene in front of the camera"], kind: .question)
        let request = EscalationRequest(sessionID: UUID(), goal: goal,
                                        digest: digest(labels: ["fan"], pixel: 0.5), recentDigests: [])
        let prompt = LocalModelPrompt.escalation(request)
        XCTAssertTrue(prompt.contains("DIRECT QUESTION"))
        XCTAssertTrue(prompt.contains("does NOT apply"))
    }
    func testWatchPromptKeepsSilencePreference() {
        let goal = GoalContext(rawText: "find gate B62", targets: ["Gate B62"])
        let request = EscalationRequest(sessionID: UUID(), goal: goal,
                                        digest: digest(ocr: ["Gate B62"], pixel: 0.5), recentDigests: [])
        XCTAssertTrue(LocalModelPrompt.escalation(request).contains("Silence is preferred"))
    }
    func testWatchFirstDigestAlwaysEscalatesBaseline() {
        let (d, _) = Classifier.evaluate(digest: digest(ocr: ["Concourse B"], pixel: 0),
                                         window: [], goal: GoalContext(rawText: "g", targets: ["Gate B62"]))
        XCTAssertTrue(d.isEscalation)
        let (d2, _) = Classifier.evaluate(digest: digest(ocr: ["Thermostat 72"], pixel: 0),
                                          window: [], goal: GoalContext(
                                            rawText: "tell me when the thermostat reaches 75",
                                            targets: ["thermostat", "75"]))
        XCTAssertTrue(d2.isEscalation)
    }
}

extension ProperDaveCoreTests {
    final class WarmupSource: DigestSource, @unchecked Sendable {
        let sourceID = "warmup"
        func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
            AsyncStream { continuation in
                // First digest: camera still exposing — nothing in it.
                continuation.yield(FrameDigest(sessionID: sessionID, sequence: 1, sourceID: sourceID,
                                               sceneChange: ChangeMetrics(pixelDiff: 0.1)))
                continuation.yield(FrameDigest(sessionID: sessionID, sequence: 2, sourceID: sourceID,
                                               ocrText: [OCRSpan(text: "Gate B62")],
                                               sceneChange: ChangeMetrics(pixelDiff: 0.6)))
                continuation.finish()
            }
        }
        func stop() {}
    }

    final class CountingAnswerClient: CloudModelClient, @unchecked Sendable {
        var modelName = "counting"
        private(set) var evaluations = 0
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: ["the scene in front of the camera"], kind: .question)
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            evaluations += 1
            return .callout(text: "Gate B62 ahead.", relevance: 1)
        }
    }

    @MainActor
    func testQuestionWaitsForUsableFrame() async throws {
        let session = SessionController(log: EventLog())
        let client = CountingAnswerClient()
        var spoken: [String] = []
        session.onCallout = { spoken.append($0) }
        session.start(goalText: "What is in front of this camera?",
                      client: client, source: WarmupSource(), interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.6))
        XCTAssertEqual(client.evaluations, 1, "must not evaluate the empty warmup digest")
        XCTAssertEqual(spoken, ["Gate B62 ahead."])
        XCTAssertEqual(session.state, .ended)
    }
}

extension ProperDaveCoreTests {
    func testQuestionIntentPrefilter() {
        let q = GoalIntent.questionGoal(for: "What is in front of this camera?")
        XCTAssertEqual(q?.kind, .question)
        XCTAssertNil(GoalIntent.questionGoal(for: "Tell me when I reach gate B62"))
    }
}

extension ProperDaveCoreTests {
    func testSceneInterestQuestionsPrefilter() {
        XCTAssertEqual(GoalIntent.questionGoal(for: "Anything interesting to see here?")?.kind, .question)
        XCTAssertEqual(GoalIntent.questionGoal(for: "What's interesting here?")?.kind, .question)
        // Ongoing narration stays describe-shaped: the pre-filter
        // must not grab it even though it mentions interest.
        XCTAssertNil(GoalIntent.questionGoal(for: "Tell me anything interesting as I pass"))
        XCTAssertNil(GoalIntent.questionGoal(for: "Keep telling me what's interesting as I walk"))
    }

    func testDescribeBaselinePromptDemandsFirstReport() {
        let digest = FrameDigest(sessionID: UUID(), sequence: 1, sourceID: "mock",
                                 labels: [ScoredLabel(name: "laptop", confidence: 0.9)])
        let goal = GoalContext(rawText: "Anything interesting?", targets: [], kind: .describe)
        let first = LocalModelPrompt.escalation(EscalationRequest(
            sessionID: UUID(), goal: goal, digest: digest, lastCallout: nil))
        XCTAssertTrue(first.contains("BASELINE"), first)
        let later = LocalModelPrompt.escalation(EscalationRequest(
            sessionID: UUID(), goal: goal, digest: digest, lastCallout: "A laptop."))
        XCTAssertFalse(later.contains("BASELINE"), later)
    }
}

extension ProperDaveCoreTests {
    final class SilentDescribeClient: CloudModelClient, @unchecked Sendable {
        var modelName = "silent-describe"
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: [], kind: .describe)
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            .noCallout(reason: "No new notable elements observed.")
        }
    }

    final class ScriptedDescribeSource: DigestSource, @unchecked Sendable {
        let sourceID = "scripted-describe"
        let labels: [String]
        init(labels: [String]) { self.labels = labels }
        func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
            AsyncStream { continuation in
                Task {
                    var sequence = 0
                    while !Task.isCancelled {
                        sequence += 1
                        continuation.yield(FrameDigest(
                            sessionID: sessionID, sequence: sequence, sourceID: sourceID,
                            labels: labels.map { ScoredLabel(name: $0, confidence: 0.9) },
                            sceneChange: ChangeMetrics(pixelDiff: 0.1)))
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    continuation.finish()
                }
            }
        }
        func stop() {}
    }

    @MainActor
    func testDescribeBaselineSpeaksEvenForBlackVoid() async throws {
        let session = SessionController(log: EventLog())
        var spoken: [String] = []
        session.onCallout = { spoken.append($0) }
        session.start(goalText: "Tell me what I see as I pass",
                      client: SilentDescribeClient(), source: ScriptedDescribeSource(labels: []),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.8))
        session.stop()
        XCTAssertEqual(spoken, ["I can't make anything out from the camera right now. The view looks dark or blank."],
                       "a describe goal must report its first scene even when that scene is a void")
    }

    @MainActor
    func testDescribeBaselineFallbackNamesVisibleLabelsOnce() async throws {
        let session = SessionController(log: EventLog())
        var spoken: [String] = []
        session.onCallout = { spoken.append($0) }
        session.start(goalText: "Tell me what I see as I pass",
                      client: SilentDescribeClient(), source: ScriptedDescribeSource(labels: ["laptop", "desk"]),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.8))
        session.stop()
        XCTAssertEqual(spoken, ["laptop, desk in view."])
    }

    final class WarmupThenSceneSource: DigestSource, @unchecked Sendable {
        let sourceID = "warmup-then-scene"
        func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
            AsyncStream { continuation in
                Task {
                    var sequence = 0
                    while !Task.isCancelled {
                        sequence += 1
                        let labels = sequence == 1
                            ? [ScoredLabel(name: "night_sky", confidence: 0.2)]
                            : [ScoredLabel(name: "laptop", confidence: 0.9)]
                        continuation.yield(FrameDigest(
                            sessionID: sessionID, sequence: sequence, sourceID: sourceID,
                            labels: labels, sceneChange: ChangeMetrics(pixelDiff: 0.1)))
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    continuation.finish()
                }
            }
        }
        func stop() {}
    }

    final class TooSoonClient: CloudModelClient, @unchecked Sendable {
        var modelName = "too-soon"
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: [], kind: .describe)
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            .noCallout(reason: "too_soon")
        }
    }

    @MainActor
    func testDescribeBaselineWaitsForSettledFrame() async throws {
        // Field log 05:56: the baseline was judged on the first,
        // still-exposing warmup frame and announced a black view.
        // Digest #1 (and low-confidence labels) must be skipped.
        let session = SessionController(log: EventLog())
        var spoken: [String] = []
        session.onCallout = { spoken.append($0) }
        session.start(goalText: "Tell me what I see as I pass",
                      client: SilentDescribeClient(), source: WarmupThenSceneSource(),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.8))
        session.stop()
        XCTAssertEqual(spoken, ["laptop in view."], "spoken: \(spoken)")
    }

    final class LowLightSource: DigestSource, @unchecked Sendable {
        let sourceID = "low-light"
        func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
            AsyncStream { continuation in
                Task {
                    var sequence = 0
                    while !Task.isCancelled {
                        sequence += 1
                        continuation.yield(FrameDigest(
                            sessionID: sessionID, sequence: sequence, sourceID: sourceID,
                            labels: [ScoredLabel(name: "door", confidence: 0.9)],
                            sceneChange: ChangeMetrics(pixelDiff: 0.1, brightness: 0.05)))
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    continuation.finish()
                }
            }
        }
        func stop() {}
    }

    final class EmptyWatchClient: CloudModelClient, @unchecked Sendable {
        var modelName = "empty-watch"
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: ["elevator"])
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            .noCallout(reason: "not_relevant")
        }
    }

    @MainActor
    func testLowLightDiagnosticSaidOnce() async throws {
        let log = EventLog()
        let session = SessionController(log: log)
        var notices: [String] = []
        session.onNotice = { notices.append($0) }
        session.start(goalText: "Watch for the elevator",
                      client: EmptyWatchClient(), source: LowLightSource(),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.8))
        session.stop()
        XCTAssertEqual(notices, ["It's quite dark here, so I may be missing things. More light would help me see."],
                       "notices: \(notices)")
        XCTAssertTrue(log.events.contains { $0.event == "low_light_diagnostic" })
    }

    @MainActor
    func testTooSoonNeverTriggersBaselineFallback() async throws {
        // The server's anti-storm backstop is not a scene judgement:
        // it must not make the baseline announce a void or labels.
        let log = EventLog()
        let session = SessionController(log: log)
        var spoken: [String] = []
        session.onCallout = { spoken.append($0) }
        session.start(goalText: "Tell me what I see as I pass",
                      client: TooSoonClient(), source: ScriptedDescribeSource(labels: ["laptop"]),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.8))
        session.stop()
        XCTAssertTrue(spoken.isEmpty, "spoken: \(spoken)")
        XCTAssertFalse(log.events.contains { $0.event == "describe_baseline_fallback" })
    }

    @MainActor
    func testModelCallFinishedLogNamesTheAnsweringModel() async throws {
        // Field log 05:32: a session believed to be on a frontier
        // model was answered by a deterministic stand-in, and the
        // log could not say so. The finished-call event must name
        // the client that answered.
        let log = EventLog()
        let session = SessionController(log: log)
        session.start(goalText: "Tell me what I see as I pass",
                      client: SilentDescribeClient(), source: ScriptedDescribeSource(labels: ["laptop"]),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.8))
        session.stop()
        let finished = log.events.filter { $0.event == "model_call_finished" }
        XCTAssertFalse(finished.isEmpty)
        XCTAssertTrue(finished.allSatisfy { $0.detail.contains("model=silent-describe") },
                      "details: \(finished.map(\.detail))")
    }
}

extension ProperDaveCoreTests {
    func testOneShotVsContinuingFrontOfCamera() {
        XCTAssertEqual(GoalIntent.intentGoal(for: "What is currently in front of this camera?")?.kind, .question)
        XCTAssertEqual(GoalIntent.intentGoal(for: "Continue telling me what is in front of this camera.")?.kind, .describe)
        XCTAssertEqual(GoalIntent.intentGoal(for: "Keep telling me what you see")?.kind, .describe)
        XCTAssertNil(GoalIntent.questionGoal(for: "Continue telling me what is in front of this camera."))
    }

    func testDemoParserKeepsContinuingNarrationRunning() async throws {
        let g = try await DemoCloudClient().parseGoal("Continue telling me what is in front of this camera.")
        XCTAssertEqual(g.kind, .describe)
        let q = try await DemoCloudClient().parseGoal("What is currently in front of this camera?")
        XCTAssertEqual(q.kind, .question)
    }
}

extension ProperDaveCoreTests {
    func testSceneChangeNarrationIsDescribeNotWatch() {
        XCTAssertEqual(GoalIntent.intentGoal(for: "Keep letting me know when the scene changes.")?.kind, .describe)
        XCTAssertEqual(GoalIntent.intentGoal(for: "Let me know when anything changes")?.kind, .describe)
        // A specific arrival is still a watch for the model parser:
        // the deterministic floor must not grab it.
        XCTAssertNil(GoalIntent.intentGoal(for: "Let me know when the train to Grand Central arrives"))
    }
}

extension ProperDaveCoreTests {
    @MainActor
    func testSceneChangeGoalStartsAsDescribeWithoutModelParse() async throws {
        // Field log 01:58: "Keep letting me know when the scene
        // changes." died at goal_parse_failed when the model parser
        // returned a watch with no targets. The deterministic floor
        // must classify it before any parser is consulted.
        let session = SessionController(log: EventLog())
        var errors: [String] = []
        var spoken: [String] = []
        session.onCriticalError = { title, _ in errors.append(title) }
        session.onCallout = { spoken.append($0) }
        session.start(goalText: "Keep letting me know when the scene changes.",
                      client: SilentDescribeClient(), source: ScriptedDescribeSource(labels: ["laptop"]),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.8))
        session.stop()
        XCTAssertEqual(session.goal?.kind, .describe)
        XCTAssertTrue(errors.isEmpty, "errors: \(errors)")
        XCTAssertEqual(spoken, ["laptop in view."])
    }
}

extension ProperDaveCoreTests {
    private func sceneGoal() -> GoalContext {
        GoalContext(rawText: "Keep letting me know when the scene changes.",
                    targets: ["scene changes"], kind: .describe)
    }
    func testSceneChangeGoalEscalatesOnGenericSceneSwap() {
        // Field report: laptop -> window -> face produced no
        // callout, because stroll saliency scores those topics
        // 0.40/0.40/0.15 against a 0.60 threshold. For a
        // scene-change goal the change itself is the relevance.
        // The window holds one digest of the new scene already:
        // a scene must survive one digest to be announced.
        let window = [digest(labels: ["laptop", "desk"], pixel: 0.1),
                      digest(labels: ["window", "curtain"], pixel: 0.7)]
        let (d, _) = Classifier.evaluate(digest: digest(labels: ["window", "curtain"], pixel: 0.7),
                                         window: window, goal: sceneGoal(), secondsSinceEscalation: 30)
        XCTAssertTrue(d.isEscalation, "\(d)")
        let faceWindow = [digest(labels: ["laptop", "desk"], pixel: 0.1),
                          digest(labels: ["person", "face"], pixel: 0.7)]
        let (d2, _) = Classifier.evaluate(digest: digest(labels: ["person", "face"], pixel: 0.7),
                                          window: faceWindow, goal: sceneGoal(), secondsSinceEscalation: 30)
        XCTAssertTrue(d2.isEscalation, "\(d2)")
        // A clear swap inside the cooldown still fires: otherwise
        // it is absorbed into the window and never reported.
        let (d3, _) = Classifier.evaluate(digest: digest(labels: ["window", "curtain"], pixel: 0.7),
                                          window: window, goal: sceneGoal(), secondsSinceEscalation: 2)
        XCTAssertTrue(d3.isEscalation, "\(d3)")
    }
    func testSceneChangeMidSwingIsUnstable() {
        // First digest of a brand-new scene, mid-swing: not yet.
        let (d, _) = Classifier.evaluate(digest: digest(labels: ["window", "curtain"], pixel: 0.7),
                                         window: [digest(labels: ["laptop", "desk"], pixel: 0.1)],
                                         goal: sceneGoal(), secondsSinceEscalation: 30)
        XCTAssertEqual(d, .suppress(reason: "sceneUnstable"))
    }
    func testDuplicateCalloutDetection() {
        XCTAssertTrue(SessionController.isDuplicateCallout(
            "A cluttered area with various objects and a blurred background.",
            of: "The scene is a cluttered area with various objects and a blurred background."))
        XCTAssertFalse(SessionController.isDuplicateCallout(
            "A kitchen with a stove and a sink.",
            of: "A cluttered area with various objects."))
    }
    func testSceneChangeGoalStaysSilentWhenNothingChanges() {
        let window = [digest(labels: ["laptop"], pixel: 0.02)]
        let (d, _) = Classifier.evaluate(digest: digest(labels: ["laptop"], pixel: 0.02),
                                         window: window, goal: sceneGoal(), secondsSinceEscalation: 30)
        XCTAssertEqual(d, .suppress(reason: "noMaterialChange"))
    }
    func testStrollDescribeStillGatesGenericTopics() {
        // The scene-change bypass must not leak into stroll goals.
        let (d, _) = Classifier.evaluate(digest: digest(labels: ["laptop"], pixel: 0.6),
                                         window: [digest(labels: ["desk"])], goal: dgoal(),
                                         secondsSinceEscalation: 30)
        XCTAssertEqual(d, .suppress(reason: "notSalient"))
    }
    func testSceneChangePromptFramesFirstReportAsStartingScene() {
        let request = EscalationRequest(sessionID: UUID(), goal: sceneGoal(),
                                        digest: digest(labels: ["laptop"]), recentDigests: [])
        let prompt = LocalModelPrompt.escalation(request)
        XCTAssertTrue(prompt.contains("starting scene"), prompt)
        XCTAssertTrue(prompt.contains("never as a change"), prompt)
    }
}

extension ProperDaveCoreTests {
    final class RepetitiveClient: CloudModelClient, @unchecked Sendable {
        var modelName = "repetitive"
        private(set) var evaluations = 0
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: ["scene changes"], kind: .describe)
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            evaluations += 1
            return .callout(text: "A cluttered area with various objects.", relevance: 0.9)
        }
    }

    final class AlternatingSceneSource: DigestSource, @unchecked Sendable {
        let sourceID = "alternating"
        func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
            AsyncStream { continuation in
                Task {
                    let scenes = [["laptop"], ["laptop"], ["window"], ["window"],
                                  ["person"], ["person"], ["laptop"], ["laptop"]]
                    var sequence = 0
                    while !Task.isCancelled {
                        sequence += 1
                        let labels = scenes[(sequence - 1) % scenes.count]
                        continuation.yield(FrameDigest(
                            sessionID: sessionID, sequence: sequence, sourceID: sourceID,
                            labels: labels.map { ScoredLabel(name: $0, confidence: 0.9) },
                            sceneChange: ChangeMetrics(pixelDiff: 0.7)))
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    continuation.finish()
                }
            }
        }
        func stop() {}
    }

    @MainActor
    func testSceneChangeSessionNeverRepeatsSameCallout() async throws {
        // Field log 02:29: the same sentence spoken four times in
        // six seconds. Escalations may repeat; speech must not.
        let session = SessionController(log: EventLog())
        let client = RepetitiveClient()
        var spoken: [String] = []
        session.onCallout = { spoken.append($0) }
        session.start(goalText: "Keep letting me know when the scene changes.",
                      client: client, source: AlternatingSceneSource(), interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(1.2))
        session.stop()
        XCTAssertGreaterThanOrEqual(client.evaluations, 2, "evaluations: \(client.evaluations)")
        XCTAssertEqual(spoken, ["A cluttered area with various objects."], "spoken: \(spoken)")
    }
}

extension ProperDaveCoreTests {
    final class DelayedClient: CloudModelClient, @unchecked Sendable {
        var modelName = "delayed"
        let delay: Double
        init(delay: Double) { self.delay = delay }
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: ["scene changes"], kind: .describe)
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            try await Task.sleep(for: .seconds(delay))
            return .callout(text: "A late answer.", relevance: 0.9)
        }
    }

    @MainActor
    func testEvaluatorTimeoutFallsBackInsteadOfFreezing() async throws {
        // Field log 02:56: Qwen's first evaluate ran past 32s with
        // the consume loop blocked behind it.
        let session = SessionController(log: EventLog())
        session.evaluatorTimeoutSeconds = 0.2
        var spoken: [String] = []
        session.onCallout = { spoken.append($0) }
        session.start(goalText: "Keep letting me know when the scene changes.",
                      client: DelayedClient(delay: 5), source: ScriptedDescribeSource(labels: ["laptop"]),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(1.5))
        session.stop()
        XCTAssertEqual(spoken, ["laptop in view."], "spoken: \(spoken)")
    }

    @MainActor
    func testNothingIsSpokenAfterGoalEnds() async throws {
        // Field log 02:57: a baseline fallback fired after
        // goal_ended, announcing a phantom scene to nobody.
        let session = SessionController(log: EventLog())
        var spoken: [String] = []
        session.onCallout = { spoken.append($0) }
        session.start(goalText: "Keep letting me know when the scene changes.",
                      client: DelayedClient(delay: 0.4), source: ScriptedDescribeSource(labels: ["laptop"]),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.15))
        session.stop()
        try await Task.sleep(for: .seconds(1.0))
        XCTAssertTrue(spoken.isEmpty, "spoken after end: \(spoken)")
    }
}

extension ProperDaveCoreTests {
    func testSceneChangeStableAcrossLabelFlicker() {
        // Held scene, Vision labels flickering between digests:
        // current resembles the digest two back, not the last one.
        let window = [digest(labels: ["laptop", "desk"], pixel: 0.1),
                      digest(labels: ["stove", "sink", "cabinet"], pixel: 0.7)]
        let (d, _) = Classifier.evaluate(digest: digest(labels: ["stove", "counter", "cabinet"], pixel: 0.7),
                                         window: window, goal: sceneGoal(), secondsSinceEscalation: 30)
        XCTAssertTrue(d.isEscalation, "\(d)")
    }
    func testSceneChangePromptIsDirectNotSilent() {
        let request = EscalationRequest(sessionID: UUID(), goal: sceneGoal(),
                                        digest: digest(labels: ["stove"]), recentDigests: [])
        let prompt = LocalModelPrompt.escalation(request)
        XCTAssertTrue(prompt.contains("DIRECT SCENE REPORT"), prompt)
        XCTAssertFalse(prompt.contains("Silence is preferred"), prompt)
    }
}

extension ProperDaveCoreTests {
    func testPromptEchoDetection() {
        XCTAssertTrue(SessionController.isPromptEcho(
            "The on-device gate has already established that the scene materially changed — that judgement is not yours to re-make."))
        XCTAssertFalse(SessionController.isPromptEcho("A kitchen with a stove and a sink."))
    }

    final class EchoClient: CloudModelClient, @unchecked Sendable {
        var modelName = "echo"
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: ["scene changes"], kind: .describe)
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            .callout(text: "The on-device gate has already established that the scene materially changed — that judgement is not yours to re-make.", relevance: 0.9)
        }
    }

    @MainActor
    func testPromptEchoIsNeverSpoken() async throws {
        // Field log 03:19: the model read our directions aloud.
        // The echo must be suppressed and the baseline fallback
        // spoken instead.
        let session = SessionController(log: EventLog())
        var spoken: [String] = []
        session.onCallout = { spoken.append($0) }
        session.start(goalText: "Keep letting me know when the scene changes.",
                      client: EchoClient(), source: ScriptedDescribeSource(labels: ["laptop"]),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.8))
        session.stop()
        XCTAssertEqual(spoken, ["laptop in view."], "spoken: \(spoken)")
    }
}

extension ProperDaveCoreTests {
    func testSceneChangeInMotionAnnouncesSnapshotAfterInterval() {
        let window = [digest(labels: ["laptop", "desk"], pixel: 0.1),
                      digest(labels: ["window", "curtain"], pixel: 0.8)]
        let current = digest(labels: ["stove", "sink"], pixel: 0.95)
        let (held, _) = Classifier.evaluate(digest: current, window: window,
                                            goal: sceneGoal(), secondsSinceEscalation: 5)
        XCTAssertEqual(held, .suppress(reason: "sceneUnstable"))
        let (moving, _) = Classifier.evaluate(digest: current, window: window,
                                              goal: sceneGoal(), secondsSinceEscalation: 16)
        XCTAssertTrue(moving.isEscalation, "\(moving)")
    }

    func testContinuingWhatYouSeeIsDetailedDescribe() {
        let goal = GoalIntent.intentGoal(for: "Keep telling me what you see")
        XCTAssertEqual(goal?.kind, .describe)
        XCTAssertEqual(goal?.verbosity, .detailed)
    }

    struct RateLimitError: LocalizedError {
        var errorDescription: String? { "The session has been rate limited." }
    }

    final class RateLimitedClient: CloudModelClient, @unchecked Sendable {
        var modelName = "rate-limited"
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: ["scene changes"], kind: .describe)
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            throw RateLimitError()
        }
    }

    @MainActor
    func testRateLimitedBaselineDoesNotAnnounceVoid() async throws {
        let session = SessionController(log: EventLog())
        var spoken: [String] = []
        var notices: [String] = []
        session.onCallout = { spoken.append($0) }
        session.onNotice = { notices.append($0) }
        session.start(goalText: "Keep letting me know when the scene changes.",
                      client: RateLimitedClient(), source: ScriptedDescribeSource(labels: ["laptop"]),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.8))
        session.stop()
        XCTAssertTrue(spoken.isEmpty, "spoken: \(spoken)")
        XCTAssertEqual(notices, ["The model is rate limited right now. I'll keep watching and try again shortly."])
    }
}

extension ProperDaveCoreTests {
    final class UnavailableClient: CloudModelClient, @unchecked Sendable {
        var modelName = "unavailable"
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: ["scene changes"], kind: .describe)
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            .noCallout(reason: "model_unavailable")
        }
    }

    @MainActor
    func testServerUnavailableBaselineDoesNotAnnounceVoid() async throws {
        // Field log 04:29: server said model_unavailable (Ollama
        // could not load its model) and the baseline announced
        // "dark or blank" about a lit room.
        let session = SessionController(log: EventLog())
        var spoken: [String] = []
        var notices: [String] = []
        session.onCallout = { spoken.append($0) }
        session.onNotice = { notices.append($0) }
        session.start(goalText: "Keep letting me know when the scene changes.",
                      client: UnavailableClient(), source: ScriptedDescribeSource(labels: ["laptop"]),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.8))
        session.stop()
        XCTAssertTrue(spoken.isEmpty, "spoken: \(spoken)")
        XCTAssertEqual(notices, ["The model isn't responding right now. I'll keep watching and try again shortly."])
    }
}

extension ProperDaveCoreTests {
    func testConversationCommandParsing() {
        XCTAssertEqual(ConversationCommand.parse("What are you doing?"), .status)
        XCTAssertEqual(ConversationCommand.parse("please stop"), .stop)
        XCTAssertEqual(ConversationCommand.parse("Stop watching."), .stop)
        XCTAssertEqual(ConversationCommand.parse("Say that again"), .repeatLast)
        XCTAssertEqual(ConversationCommand.parse("tell me more"), .moreDetail)
        XCTAssertEqual(ConversationCommand.parse("TELL ME LESS!"), .lessDetail)
        XCTAssertEqual(ConversationCommand.parse("just the landmarks"), .landmarksOnly)
        XCTAssertEqual(ConversationCommand.parse("Speak faster"), .speakFaster)
        XCTAssertEqual(ConversationCommand.parse("increase rate"), .speakFaster)
        XCTAssertEqual(ConversationCommand.parse("speak slower"), .speakSlower)
        XCTAssertEqual(ConversationCommand.parse("Please decrease the rate."), .speakSlower)
        XCTAssertEqual(ConversationCommand.speakFaster.speechRateDelta(from: 100), 25)
        XCTAssertEqual(ConversationCommand.speakSlower.speechRateDelta(from: 100), -25)
        XCTAssertNil(ConversationCommand.speakFaster.speechRateDelta(from: 200))
        XCTAssertNil(ConversationCommand.speakSlower.speechRateDelta(from: 50))
        // Goals and refinements must never be swallowed as commands.
        XCTAssertNil(ConversationCommand.parse("watch for the stop sign"))
        XCTAssertNil(ConversationCommand.parse("tell me when the train stops"))
        XCTAssertNil(ConversationCommand.parse("tell me more about the gate number"))
        XCTAssertNil(ConversationCommand.parse("what are you doing about the elevator"))
    }

    func testVerbosityPatchSteps() {
        XCTAssertEqual(ConversationCommand.moreDetail.verbosityPatch(from: .notable)?.verbosity, .detailed)
        XCTAssertEqual(ConversationCommand.moreDetail.verbosityPatch(from: .landmarks)?.verbosity, .notable)
        XCTAssertNil(ConversationCommand.moreDetail.verbosityPatch(from: .detailed))
        XCTAssertEqual(ConversationCommand.lessDetail.verbosityPatch(from: .detailed)?.verbosity, .notable)
        XCTAssertEqual(ConversationCommand.lessDetail.verbosityPatch(from: .notable)?.verbosity, .landmarks)
        XCTAssertNil(ConversationCommand.lessDetail.verbosityPatch(from: .landmarks))
        XCTAssertEqual(ConversationCommand.landmarksOnly.verbosityPatch(from: .detailed)?.verbosity, .landmarks)
    }

    final class CyclingSceneSource: DigestSource, @unchecked Sendable {
        let sourceID = "cycling-scene"
        func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
            AsyncStream { continuation in
                Task {
                    var sequence = 0
                    while !Task.isCancelled {
                        sequence += 1
                        // Fresh topics every digest: a repeating
                        // cycle would (correctly) die on topic dedupe.
                        let labels = ["place\(sequence)", "view\(sequence)", "thing\(sequence)"]
                        continuation.yield(FrameDigest(
                            sessionID: sessionID, sequence: sequence, sourceID: sourceID,
                            labels: labels.map { ScoredLabel(name: $0, confidence: 0.9) },
                            sceneChange: ChangeMetrics(pixelDiff: 1.0)))
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    continuation.finish()
                }
            }
        }
        func stop() {}
    }

    final class RefiningClient: CloudModelClient, @unchecked Sendable {
        var modelName = "refining"
        private(set) var evaluatedVerbosity: [Verbosity] = []
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: [], kind: .describe, verbosity: .landmarks)
        }
        func refine(current: GoalContext, refinement: String) async throws -> GoalContext {
            var patched = current
            patched.verbosity = .detailed
            return patched
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            evaluatedVerbosity.append(request.goal.verbosity)
            return .noCallout(reason: "not_relevant")
        }
    }

    @MainActor
    func testRefinementReachesTheRunningLoop() async throws {
        // Regression, two stacked bugs: refine() was not a protocol
        // requirement, so the throwing extension default ran instead
        // of any client's own refine; and consume() kept judging
        // against the goal captured at start. Either alone made
        // mid-goal refinements change nothing.
        let client = RefiningClient()
        let session = SessionController(log: EventLog())
        session.start(goalText: "Narrate the surroundings for me",
                      client: client, source: CyclingSceneSource(),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.5))
        session.refineGoal(text: "tell me more")
        try await Task.sleep(for: .seconds(0.7))
        session.stop()
        XCTAssertTrue(client.evaluatedVerbosity.contains(.landmarks),
                      "before refine: \(client.evaluatedVerbosity)")
        XCTAssertEqual(client.evaluatedVerbosity.last, .detailed,
                       "after refine: \(client.evaluatedVerbosity)")
    }

    @MainActor
    func testApplyPatchAndStatusSummary() async throws {
        let log = EventLog()
        let session = SessionController(log: log)
        XCTAssertEqual(session.statusSummary(), "I'm not watching right now.")
        session.start(goalText: "Tell me what I see as I pass",
                      client: SilentDescribeClient(), source: ScriptedDescribeSource(labels: ["laptop"]),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.4))
        XCTAssertTrue(session.applyPatch(GoalPatch(verbosity: .landmarks), origin: "conversation"))
        XCTAssertEqual(session.goal?.verbosity, .landmarks)
        let status = session.statusSummary()
        XCTAssertTrue(status.contains("telling you what I see"), status)
        XCTAssertTrue(log.events.contains { $0.event == "goal_patched" })
        session.stop()
    }
}

extension ProperDaveCoreTests {
    final class FlakyConnectivityClient: CloudModelClient, @unchecked Sendable {
        var modelName = "flaky-server"
        private var failuresLeft: Int
        init(failures: Int) { failuresLeft = failures }
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: [], kind: .describe, verbosity: .detailed)
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            if failuresLeft > 0 {
                failuresLeft -= 1
                throw CloudError.unreachable("connection dropped")
            }
            return .callout(text: "A laptop on a desk.", relevance: 0.9)
        }
    }

    final class FixedAnswerClient: CloudModelClient, @unchecked Sendable {
        var modelName = "fixed-answer"
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: [], kind: .describe)
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            .callout(text: "A kettle by a window.", relevance: 0.9)
        }
    }

    @MainActor
    func testConnectivityEpisodeFiresOnceAndRestores() async throws {
        let session = SessionController(log: EventLog())
        var lost = 0
        var restored = 0
        session.onConnectivityLost = { lost += 1 }
        session.onConnectivityRestored = { restored += 1 }
        session.start(goalText: "Narrate the surroundings for me",
                      client: FlakyConnectivityClient(failures: 3),
                      source: CyclingSceneSource(), interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(1.2))
        session.stop()
        XCTAssertEqual(lost, 1, "one loss report per episode")
        XCTAssertEqual(restored, 1, "restored when the same evaluator answers again")
    }

    final class SwapUnavailableClient: CloudModelClient, @unchecked Sendable {
        var modelName = "swap-unavailable"
        func parseGoal(_ rawText: String) async throws -> GoalContext {
            GoalContext(rawText: rawText, targets: [], kind: .describe, verbosity: .detailed)
        }
        func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
            .noCallout(reason: "model_unavailable")
        }
    }

    @MainActor
    func testFrameTapDeliversDigestImages() async throws {
        let session = SessionController(log: EventLog())
        var tapped: [Data?] = []
        session.onFrame = { _, data in tapped.append(data) }
        session.start(goalText: "Tell me what's in front of the camera",
                      client: AnswerClient(), source: ImageSpySource(),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.6))
        session.stop()
        XCTAssertEqual(tapped.count, 1)
        XCTAssertEqual(tapped.first ?? nil, Data("jpeg".utf8))
    }

    @MainActor
    func testReplaceEvaluatorSwapsJudgingAndClearsBackoff() async throws {
        let log = EventLog()
        let session = SessionController(log: log)
        var spoken: [String] = []
        session.onCallout = { spoken.append($0) }
        session.start(goalText: "Narrate the surroundings for me",
                      client: SwapUnavailableClient(), source: CyclingSceneSource(),
                      interval: 0.05, cooldown: 0)
        try await Task.sleep(for: .seconds(0.5))
        session.replaceEvaluator(FixedAnswerClient(), reason: "connectivity loss")
        try await Task.sleep(for: .seconds(0.9))
        session.stop()
        XCTAssertTrue(spoken.contains("A kettle by a window."), "spoken: \(spoken)")
        XCTAssertTrue(log.events.contains { $0.event == "evaluator_swapped" })
    }
}
