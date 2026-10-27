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

/// Offline stand-in so the app demos with no server (same behaviour family
/// as the Python FakeCloudModel).
public struct DemoCloudClient: CloudModelClient {
    public var modelName: String { "on-device-demo" }
    public init() {}
    public func parseGoal(_ rawText: String) async throws -> GoalContext {
        let lowered = rawText.lowercased()
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
