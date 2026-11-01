import XCTest
@testable import ProperDaveCore

final class ProperDaveCoreTests: XCTestCase {
    private var seq = 0
    private func digest(labels: [String] = [], ocr: [String] = [], pixel: Double = 0) -> FrameDigest {
        seq += 1
        return FrameDigest(sessionID: UUID(), sequence: seq, sourceID: "test",
                           labels: labels.map { ScoredLabel(name: $0, confidence: 0.9) },
                           ocrText: ocr.map { OCRSpan(text: $0, confidence: 0.9) },
                           sceneChange: ChangeMetrics(pixelDiff: pixel))
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
