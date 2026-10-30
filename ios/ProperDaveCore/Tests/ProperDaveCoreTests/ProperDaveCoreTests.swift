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
