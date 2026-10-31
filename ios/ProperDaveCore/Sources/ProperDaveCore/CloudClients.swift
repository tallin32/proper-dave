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
}

public enum RefinementError: Error { case unparseable }

public extension CloudModelClient {
    /// Mid-goal refinement as a goal patch (CLS-16). Default
    /// deterministic patcher for the common phrasings; a model-backed
    /// refinement can replace it per client later. Throws
    /// RefinementError.unparseable when nothing recognisable is asked,
    /// leaving the caller to keep the running goal untouched.
    func refine(current: GoalContext, refinement: String) async throws -> GoalContext {
        let low = refinement.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var patched = current
        var changed = false
        if low.contains("landmark") && (low.contains("just") || low.contains("only")) {
            patched.verbosity = .landmarks; changed = true
        } else if low.contains("more detail") || low.contains("detailed") || low.contains("everything") {
            patched.verbosity = .detailed; changed = true
        } else if low.contains("less detail") || low.contains("fewer") {
            patched.verbosity = .landmarks; changed = true
        }
        for marker in ["skip ", "exclude ", "no more ", "ignore "] where low.hasPrefix(marker) {
            let item = low.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !item.isEmpty {
                patched.exclusions.append(item)
                patched.targets.removeAll { $0.lowercased() == item }
                changed = true
            }
        }
        if low.hasPrefix("only ") {
            let item = low.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !item.isEmpty { patched.targets = [item]; changed = true }
        }
        for marker in ["include ", "add "] where low.hasPrefix(marker) {
            let item = low.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !item.isEmpty { patched.targets.append(item); changed = true }
        }
        guard changed else { throw RefinementError.unparseable }
        return patched
    }
}

/// Offline stand-in so the app demos with no server (same behaviour family
/// as the Python FakeCloudModel).
public struct DemoCloudClient: CloudModelClient {
    public var modelName: String { "on-device-demo" }
    public init() {}
    public func parseGoal(_ rawText: String) async throws -> GoalContext {
        let lowered = rawText.lowercased()
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
        for target in request.goal.targets {
            let needle = target.lowercased().replacingOccurrences(of: "gate ", with: "").trimmingCharacters(in: .whitespaces)
            if let hit = visible.first(where: { $0.lowercased().contains(needle) }), !needle.isEmpty {
                return .callout(text: "\(hit) in view.", relevance: 0.9)
            }
        }
        return .noCallout(reason: "not_relevant")
    }
}
