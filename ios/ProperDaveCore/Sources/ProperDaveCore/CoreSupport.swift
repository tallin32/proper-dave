import Foundation

public struct LogEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var ts: Date
    public var sessionID: UUID?
    public var component: String
    public var event: String
    public var detail: String
    public init(sessionID: UUID? = nil, component: String, event: String, detail: String = "") {
        self.id = UUID(); self.ts = Date(); self.sessionID = sessionID
        self.component = component; self.event = event; self.detail = detail
    }
}

/// Append-only session log with JSONL export (TRD-005 INS-01/02).
@MainActor
public final class EventLog: ObservableObject {
    @Published public private(set) var events: [LogEvent] = []
    private let cap = 5_000
    public init() {}
    public func append(sessionID: UUID? = nil, component: String, event: String, detail: String = "") {
        events.append(LogEvent(sessionID: sessionID, component: component, event: event, detail: detail))
        if events.count > cap { events.removeFirst(events.count - cap) }
    }
    public func clear() { events.removeAll() }
    public func jsonl() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return events.compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}

/// Experimental-API gate (TRD-001 CAP-12): user opt-in AND build support.
/// Production ignores a stored "on"; promotion after Meta graduates an
/// API is this one constant plus removing "experimental" labels.
public enum ExperimentalFeatures {
    #if DEBUG
    public static let buildAllowsGlassesMicrophone = true
    #else
    public static let buildAllowsGlassesMicrophone = false
    #endif
    public static func glassesMicrophoneEnabled(userEnabled: Bool,
                                                buildAllows: Bool = buildAllowsGlassesMicrophone) -> Bool {
        userEnabled && buildAllows
    }
}
