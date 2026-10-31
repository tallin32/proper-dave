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
}
