import Foundation

/// TRD-003 seam. Which back end is live is DI + setting only (CLD-04).
public protocol CloudModelClient: Sendable {
    func parseGoal(_ rawText: String) async throws -> GoalContext
    func evaluate(_ request: EscalationRequest) async throws -> CalloutResult
    var modelName: String { get }
}

public enum CloudError: LocalizedError {
    case badStatus(Int, String)
    case unreachable(String)
    public var errorDescription: String? {
        switch self {
        case .badStatus(let code, let body): return "Server answered \(code): \(body)"
        case .unreachable(let why): return "Could not reach the server: \(why)"
        }
    }
}

/// Client for the TRD-004 server at a user-configured host/port (API-03).
public struct ServerCloudClient: CloudModelClient {
    public var host: String
    public var port: Int
    public var apiKey: String
    public var modelName: String { "server" }
    public init(host: String, port: Int, apiKey: String = "") {
        self.host = host; self.port = port; self.apiKey = apiKey
    }
    public var baseURL: URL { URL(string: "http://\(host):\(port)/v1")! }

    private func send<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)
        let data: Data
        do {
            let (d, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw CloudError.badStatus(http.statusCode, String(data: d, encoding: .utf8) ?? "")
            }
            data = d
        } catch let error as CloudError { throw error }
        catch { throw CloudError.unreachable(error.localizedDescription) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    public func health() async -> Bool {
        (try? await URLSession.shared.data(for: URLRequest(url: baseURL.appendingPathComponent("health")))) != nil
    }
    public func parseGoal(_ rawText: String) async throws -> GoalContext {
        struct Body: Encodable { var rawText: String }
        return try await send("goals/parse", body: Body(rawText: rawText))
    }
    public func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
        try await send("escalations", body: request)
    }
    private struct RefineBody: Encodable {
        let goal: GoalContext
        let refinement: String
    }
    public func refine(current: GoalContext, refinement: String) async throws -> GoalContext {
        try await send("goals/refine", body: RefineBody(goal: current, refinement: refinement))
    }
}

public enum RefinementError: Error { case unparseable }

public extension GoalPatch {
    /// Keyword fallback for demo/no-model paths ONLY (TRD-003 §2).
    /// Production understanding is model-backed; this exists so the
    /// demo can still patch a goal, and its phrase table is a test
    /// fixture, not a user interface.
    static func deterministic(refinement: String) -> GoalPatch {
        let low = refinement.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var patch = GoalPatch()
        if low.contains("landmark") && (low.contains("just") || low.contains("only")) {
            patch.verbosity = .landmarks
        } else if low.contains("more detail") || low.contains("detailed") || low.contains("everything") {
            patch.verbosity = .detailed
        } else if low.contains("less detail") || low.contains("fewer") {
            patch.verbosity = .landmarks
        }
        for marker in ["skip ", "exclude ", "no more ", "ignore "] where low.hasPrefix(marker) {
            let item = low.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !item.isEmpty { patch.addExclusions.append(item) }
        }
        if low.hasPrefix("only ") {
            let item = low.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !item.isEmpty { patch.setTargets = [item] }
        }
        for marker in ["include ", "add "] where low.hasPrefix(marker) {
            let item = low.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !item.isEmpty { patch.addTargets.append(item) }
        }
        return patch
    }
}

public extension CloudModelClient {
    /// Mid-goal refinement (CLS-16). Model-backed in production
    /// clients (server /v1/goals/refine, local structured output);
    /// the default refuses rather than guesses.
    func refine(current: GoalContext, refinement: String) async throws -> GoalContext {
        throw RefinementError.unparseable
    }
}

/// Offline stand-in so the app demos with no server (same behaviour family
/// as the Python FakeCloudModel).
public struct DemoCloudClient: CloudModelClient {
    public var modelName: String { "on-device-demo" }
    public init() {}

    /// Demo path: deterministic patcher is the fallback of last resort.
    public func refine(current: GoalContext, refinement: String) async throws -> GoalContext {
        let patch = GoalPatch.deterministic(refinement: refinement)
        guard !patch.isEmpty else { throw RefinementError.unparseable }
        return patch.applied(to: current)
    }
    public func parseGoal(_ rawText: String) async throws -> GoalContext {
        let lowered = rawText.lowercased()
        // One-shot question about the current scene (mirrors
        // FakeCloudModel): answer from the first frame, no watch.
        let questionMarkers = ["what's in front", "what is in front", "what do you see",
                               "in front of the camera", "in front of me"]
        if questionMarkers.contains(where: lowered.contains) {
            return GoalContext(rawText: rawText, targets: ["the scene in front of the camera"], kind: .question)
        }
        // Describe intent (mirrors FakeCloudModel): open-ended narration
        // runs on saliency, not targets (TRD-002 §5).
        let describeMarkers = ["what do i see", "tell me what i see", "describe",
                               "what's interesting", "what is interesting", "as i pass",
                               "as i stroll", "as i walk", "people watching",
                               "people-watching", "what i see"]
        if describeMarkers.contains(where: lowered.contains) {
            var focus: [String] = []
            if lowered.contains("shop") || lowered.contains("store") { focus.append("shops") }
            if lowered.contains("building name") { focus.append("building names") }
            if lowered.contains("people") { focus.append("people") }
            if lowered.contains("sign") { focus.append("signs") }
            if lowered.contains("landmark") { focus.append("landmarks") }
            var verbosity: Verbosity = .notable
            if lowered.contains("landmark") && (lowered.contains("just") || lowered.contains("only")) { verbosity = .landmarks }
            if lowered.contains("everything") || lowered.contains("detail") { verbosity = .detailed }
            return GoalContext(rawText: rawText, targets: focus.sorted(), kind: .describe, verbosity: verbosity)
        }
        var targets: [String] = []
        var progress: String?
        if let match = lowered.range(of: #"gate\s+([a-z]\d{1,3})"#, options: .regularExpression) {
            targets.append("Gate " + String(lowered[match]).split(separator: " ").last!.uppercased())
            progress = "gate numbers"
        }
        if lowered.contains("elevator") || lowered.contains("lift") { targets += ["elevator", "floor indicator"] }
        if lowered.contains("train") || lowered.contains("grand central") {
            targets += ["train", "Grand Central", "departures board"]
        }
        for word in ["verizon", "metro", "station", "coffee", "restaurant"] where lowered.contains(word) {
            targets.append(word)
        }
        if targets.isEmpty { targets = [rawText] }
        return GoalContext(rawText: rawText, targets: targets, progressLandmarks: progress)
    }
    public func evaluate(_ request: EscalationRequest) async throws -> CalloutResult {
        let visible = request.digest.labels.map(\.name) + request.digest.ocrText.map(\.text)
        if request.goal.kind == .question {
            if visible.isEmpty { return .noCallout(reason: "not_relevant") }
            return .callout(text: visible.prefix(3).joined(separator: ", ") + " in view.", relevance: 0.9)
        }
        if request.goal.kind == .describe {
            // The demo narrates the salient digest plainly; real models
            // summarise. Silence only when nothing is visible at all.
            if visible.isEmpty { return .noCallout(reason: "not_relevant") }
            return .callout(text: visible.prefix(3).joined(separator: ", ") + " in view.", relevance: 0.7)
        }
        for target in request.goal.targets {
            let needle = target.lowercased().replacingOccurrences(of: "gate ", with: "").trimmingCharacters(in: .whitespaces)
            if let hit = visible.first(where: { $0.lowercased().contains(needle) }), !needle.isEmpty {
                return .callout(text: "\(hit) in view.", relevance: 0.9)
            }
        }
        return .noCallout(reason: "not_relevant")
    }
}
