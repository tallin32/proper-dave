import Foundation

/// Recorded-session bundle (developer feature): everything needed to
/// replay a walk through the current classifier without re-walking
/// it — "that walk should have reported X, it reports Y; twist the
/// knobs and try the same data." On-device only; a bundle leaves the
/// phone solely by explicit dev-server upload (Log tab).
///
/// Layout under a base directory:
///   <sessionID>/meta.json       goal, counts, recorded model answers
///   <sessionID>/digests.jsonl   one FrameDigest per line
///   <sessionID>/frames/NNNNNN.jpg  JPEG per digest, when the source
///                                  retained one (digest.imageRef)
///   <sessionID>/log.jsonl       the session's slice of the event log
public struct RecordedSessionMeta: Codable, Equatable, Sendable {
    public var id: UUID
    public var goalText: String
    public var goal: GoalContext?
    public var sourceID: String
    public var startedAt: Date
    public var endedAt: Date?
    public var digestCount: Int
    public var frameCount: Int
    /// The live session's evaluator answers, in escalation order, so
    /// replay can speak what the model said then while the gate
    /// re-decides now. Divergence shifts alignment; the decision
    /// trail is the authoritative comparison.
    public var answers: [CalloutResult]
    public init(id: UUID, goalText: String, goal: GoalContext? = nil, sourceID: String,
                startedAt: Date, endedAt: Date? = nil, digestCount: Int = 0,
                frameCount: Int = 0, answers: [CalloutResult] = []) {
        self.id = id; self.goalText = goalText; self.goal = goal
        self.sourceID = sourceID; self.startedAt = startedAt; self.endedAt = endedAt
        self.digestCount = digestCount; self.frameCount = frameCount
        self.answers = answers
    }
}

public enum RecordedSessionStore {
    public static let retention = 10

    public static func directory(base: URL, id: UUID) -> URL {
        base.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]; return e
    }
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    public static func writeMeta(_ meta: RecordedSessionMeta, base: URL) {
        let dir = directory(base: base, id: meta.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? encoder().encode(meta) {
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }

    public static func readMeta(base: URL, id: UUID) -> RecordedSessionMeta? {
        let url = directory(base: base, id: id).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(RecordedSessionMeta.self, from: data)
    }

    public static func summaries(base: URL) -> [RecordedSessionMeta] {
        let ids = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil)) ?? []
        return ids.compactMap { url -> RecordedSessionMeta? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return readMeta(base: base, id: id)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    public static func loadDigests(base: URL, id: UUID) -> [FrameDigest] {
        let url = directory(base: base, id: id).appendingPathComponent("digests.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = decoder()
        return text.split(separator: "\n").compactMap {
            try? dec.decode(FrameDigest.self, from: Data($0.utf8))
        }.sorted { $0.sequence < $1.sequence }
    }

    public static func frameData(base: URL, meta: RecordedSessionMeta, digest: FrameDigest) -> Data? {
        guard let ref = digest.imageRef else { return nil }
        return try? Data(contentsOf: directory(base: base, id: meta.id).appendingPathComponent(ref))
    }

    public static func byteSize(base: URL, id: UUID) -> Int {
        let dir = directory(base: base, id: id)
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return en.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }
            .reduce(0) { $0 + ($1 ?? 0) }
    }

    /// Path of a bundle file relative to its session directory, for
    /// upload. Never string-prefix, and never a bare component-count
    /// drop: iOS spells the same container path two ways — the
    /// directory URL as /var/mobile/... and enumerator children as
    /// /private/var/mobile/... — so a count-based drop left the
    /// session directory's own name in the result and the server
    /// refused the doubled path (400, field report 2026-11-02).
    /// Standardize both, then fall back to anchoring on the
    /// directory's own last component.
    public static func relativePath(of file: URL, in dir: URL) -> String {
        let f = file.standardizedFileURL.pathComponents
        let d = dir.standardizedFileURL.pathComponents
        if f.count > d.count, Array(f.prefix(d.count)) == d {
            return f.dropFirst(d.count).joined(separator: "/")
        }
        if let anchor = f.lastIndex(of: dir.lastPathComponent), anchor < f.count - 1 {
            return f[(anchor + 1)...].joined(separator: "/")
        }
        return file.lastPathComponent
    }

    public static func delete(base: URL, id: UUID) {
        try? FileManager.default.removeItem(at: directory(base: base, id: id))
    }

    /// Repair a bundle orphaned by app termination (crash, swipe
    /// kill, jetsam) before any stop path could finish it: counts
    /// and end time are recoverable from what's on disk; the log
    /// slice and recorded answers are not (both live in memory),
    /// and stay absent rather than being reconstructed.
    public static func finalizeIfStub(base: URL, meta: RecordedSessionMeta) -> RecordedSessionMeta {
        guard meta.endedAt == nil else { return meta }
        var m = meta
        let digests = loadDigests(base: base, id: meta.id)
        m.digestCount = digests.count
        m.endedAt = digests.last?.capturedAt ?? meta.startedAt
        let framesDir = directory(base: base, id: meta.id).appendingPathComponent("frames")
        let frames = (try? FileManager.default.contentsOfDirectory(atPath: framesDir.path)) ?? []
        m.frameCount = frames.filter { $0.hasSuffix(".jpg") }.count
        writeMeta(m, base: base)
        return m
    }

    /// Keep the newest `retention` bundles; a walk is ~1 digest/sec
    /// and frames dominate, so unbounded retention eats the phone.
    public static func prune(base: URL) {
        for meta in summaries(base: base).dropFirst(retention) {
            delete(base: base, id: meta.id)
        }
    }
}

/// Writes one bundle from the session's per-digest frame tap.
/// Thread-safe; all IO on a serial queue so the watching loop
/// never waits on disk.
public final class SessionRecorder: @unchecked Sendable {
    private let base: URL
    private let queue = DispatchQueue(label: "nyc.bytemaster.ProperDave.session-recorder")
    private var meta: RecordedSessionMeta?
    private var digests: [FrameDigest] = []
    private var digestFile: FileHandle?

    public init(base: URL) { self.base = base }

    public var activeSessionID: UUID? { queue.sync { meta?.id } }

    public func begin(sessionID: UUID, goalText: String, sourceID: String) {
        queue.sync {
            if meta != nil { finishLocked(events: [], goal: nil) }
            meta = RecordedSessionMeta(id: sessionID, goalText: goalText,
                                       sourceID: sourceID, startedAt: Date())
            digests = []
            let dir = RecordedSessionStore.directory(base: base, id: sessionID)
            try? FileManager.default.createDirectory(
                at: dir.appendingPathComponent("frames", isDirectory: true),
                withIntermediateDirectories: true)
            // Digests flush incrementally from here on: a bundle
            // must be analyzable (and replayable) even if the goal
            // is still running or the app dies mid-walk — the first
            // field bundle arrived with frames only because finish
            // was the sole writer of digests.jsonl.
            let digestsURL = dir.appendingPathComponent("digests.jsonl")
            FileManager.default.createFile(atPath: digestsURL.path, contents: nil)
            digestFile = try? FileHandle(forWritingTo: digestsURL)
            if let meta { RecordedSessionStore.writeMeta(meta, base: base) }
        }
    }

    public func record(digest: FrameDigest, jpeg: Data?) {
        queue.async { [weak self] in
            guard let self, var m = meta, digest.sessionID == m.id else { return }
            var stored = digest
            if let jpeg {
                let name = String(format: "frames/%06d.jpg", digest.sequence)
                let url = RecordedSessionStore.directory(base: base, id: m.id)
                    .appendingPathComponent(name)
                if (try? jpeg.write(to: url, options: .atomic)) != nil {
                    stored.imageRef = name
                    m.frameCount += 1
                }
            }
            digests.append(stored)
            m.digestCount = digests.count
            meta = m
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.sortedKeys]
            if let line = try? enc.encode(stored),
               let text = String(data: line, encoding: .utf8) {
                digestFile?.write(Data((text + "\n").utf8))
            }
            if digests.count % 10 == 0 { RecordedSessionStore.writeMeta(m, base: base) }
        }
    }

    public func finish(events: [LogEvent], goal: GoalContext?) {
        queue.sync { finishLocked(events: events, goal: goal) }
    }

    private func finishLocked(events: [LogEvent], goal: GoalContext?) {
        guard var m = meta else { return }
        meta = nil
        try? digestFile?.close()
        digestFile = nil
        m.endedAt = Date()
        if let goal { m.goal = goal }
        m.answers = events.filter { $0.sessionID == m.id }.compactMap { event in
            switch event.event {
            case "callout_spoken": return .callout(text: event.detail, relevance: 1)
            case "no_callout": return .noCallout(reason: event.detail)
            default: return nil
            }
        }
        let dir = RecordedSessionStore.directory(base: base, id: m.id)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let digestLines = digests.compactMap { try? enc.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n")
        try? digestLines.write(to: dir.appendingPathComponent("digests.jsonl"),
                               atomically: true, encoding: .utf8)
        let logLines = events.filter { $0.sessionID == m.id }
            .compactMap { try? enc.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n")
        try? logLines.write(to: dir.appendingPathComponent("log.jsonl"),
                            atomically: true, encoding: .utf8)
        RecordedSessionStore.writeMeta(m, base: base)
        digests = []
        RecordedSessionStore.prune(base: base)
    }
}

/// DigestSource that replays a recorded bundle in original order,
/// then finishes (which ends the goal, like a camera stopping).
public final class ReplayDigestSource: DigestSource, @unchecked Sendable {
    public let sourceID = "replay"
    private let digests: [FrameDigest]
    private let frameProvider: (FrameDigest) -> Data?
    private var task: Task<Void, Never>?

    public init(digests: [FrameDigest], frameProvider: @escaping (FrameDigest) -> Data?) {
        self.digests = digests
        self.frameProvider = frameProvider
    }

    public func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest> {
        AsyncStream { continuation in
            task = Task { [digests] in
                for digest in digests {
                    if Task.isCancelled { break }
                    // The replay gets its own session identity; the
                    // recorded digests keep theirs in the bundle.
                    var d = digest; d.sessionID = sessionID
                    continuation.yield(d)
                    try? await Task.sleep(for: .seconds(interval))
                }
                continuation.finish()
            }
        }
    }

    public func imageData(for digest: FrameDigest) -> Data? { frameProvider(digest) }
    public func stop() { task?.cancel() }
}

/// Evaluator for replay: parses to the recorded goal verbatim (the
/// live session may have model-parsed it; replay must judge the
/// same goal, not a re-parse) and answers escalations from the
/// recorded answer stream. No model is consulted — deterministic,
/// free, and repeatable. Exhaustion answers silence, never invents.
public final class RecordedAnswersClient: CloudModelClient, @unchecked Sendable {
    public var modelName: String { "replay" }
    private let goal: GoalContext?
    private let goalText: String
    private var answers: [CalloutResult]
    private let lock = NSLock()

    public init(meta: RecordedSessionMeta) {
        self.goal = meta.goal
        self.goalText = meta.goalText
        self.answers = meta.answers
    }

    public func parseGoal(_ rawText: String) async throws -> GoalContext {
        if let goal { return goal }
        if let intent = GoalIntent.intentGoal(for: goalText) { return intent }
        throw CloudError.unreachable("Recording has no stored goal.")
    }

    public func refine(current: GoalContext, refinement: String) async throws -> GoalContext { current }

    public func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
        lock.lock(); defer { lock.unlock() }
        guard !answers.isEmpty else { return .noCallout(reason: "replay_exhausted") }
        return answers.removeFirst()
    }
}
