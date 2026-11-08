import Foundation

/// The tool/skill registry (TRD-007).
///
/// Two layers, deliberately different in kind:
///
/// - **Tools are native.** A fixed vocabulary of verbs implemented in
///   compiled code — on the device (`torch`, `guide_to_target`,
///   `read_sign`) or on the user's own server (`read_package`, …).
///   The vocabulary of *action on the device* stays bounded and
///   enumerable; server-side tools can reason and report, but can
///   only ever request device verbs from this shelf.
/// - **Skills are data.** A declarative manifest composing registered
///   tools with parameters. Skills ship as files, are authored on a
///   desktop, and contain no executable code — which keeps them on
///   the configuration side of App Store guideline 2.5.2. Anything
///   needing real logic runs on the user's server tier, never in the
///   app binary.
///
/// The registry is also where one-off commands land: "read that sign"
/// parses (deterministically, here) into a *scoped request* — a
/// narrow, expiring sub-goal pushed over the running goal. Scoped
/// requests complete, are cancelled ("never mind"), supersede, or
/// decay out of scope on their own; the user is never required to
/// tidy up after a request they have walked away from.

public enum ToolLocation: String, Codable, Equatable, Sendable {
    /// Runs in the app: capture, speech, torch, guidance.
    case device
    /// Runs on the user's server tier: perception/reasoning over a
    /// frame or digest. Unavailable in offline mode — the same
    /// trade the model tiers already make.
    case server
}

public struct RegisteredTool: Equatable, Sendable {
    public var id: String
    public var summary: String
    public var location: ToolLocation
    /// Declared parameter names; a skill invocation may only set
    /// these. Keeps manifests enumerable and reviewable.
    public var parameters: [String]
    public init(id: String, summary: String, location: ToolLocation,
                parameters: [String] = []) {
        self.id = id; self.summary = summary; self.location = location
        self.parameters = parameters
    }
}

public enum RegistryError: Error, Equatable {
    case duplicateTool(String)
    case unknownTool(String)
    case undeclaredParameter(tool: String, parameter: String)
}

public struct ToolRegistry: Equatable, Sendable {
    public private(set) var tools: [String: RegisteredTool] = [:]
    public init() {}

    public mutating func register(_ tool: RegisteredTool) throws {
        guard tools[tool.id] == nil else { throw RegistryError.duplicateTool(tool.id) }
        tools[tool.id] = tool
    }

    public func tool(_ id: String) -> RegisteredTool? { tools[id] }
    public var toolIDs: [String] { tools.keys.sorted() }

    /// The shelf shipped in the binary. Device verbs are few,
    /// generic, and stable by design; server tools listed here are
    /// the built-in perception packs — users may register more on
    /// their own server without an app update.
    public static func builtin() -> ToolRegistry {
        var r = ToolRegistry()
        // try! is safe: ids below are unique literals.
        try! r.register(RegisteredTool(
            id: "read_sign", summary: "Read the text of a sign in view, in full.",
            location: .device, parameters: ["target"]))
        try! r.register(RegisteredTool(
            id: "read_text", summary: "Read visible text (label, display, document) verbatim.",
            location: .device, parameters: ["target"]))
        try! r.register(RegisteredTool(
            id: "describe_scene", summary: "Describe the current scene once.",
            location: .device, parameters: ["verbosity"]))
        try! r.register(RegisteredTool(
            id: "guide_to_target", summary: "Steer the camera toward a located target until it fills the frame.",
            location: .device, parameters: ["target"]))
        try! r.register(RegisteredTool(
            id: "torch", summary: "Turn the flashlight on or off.",
            location: .device, parameters: ["on"]))
        try! r.register(RegisteredTool(
            id: "repeat_last", summary: "Repeat the last spoken report.",
            location: .device))
        try! r.register(RegisteredTool(
            id: "read_package", summary: "Look for packages and read any sender/addressee text.",
            location: .server, parameters: ["target"]))
        return r
    }
}

/// A declarative skill: front-matter-style composition of registered
/// tools. Codable so skills can be authored as JSON/plist files on a
/// desktop and imported. Contains no executable content by design.
public struct SkillManifest: Codable, Equatable, Sendable {
    public struct Invocation: Codable, Equatable, Sendable {
        public var tool: String
        public var parameters: [String: String]
        public init(tool: String, parameters: [String: String] = [:]) {
            self.tool = tool; self.parameters = parameters
        }
    }
    public var id: String
    public var displayName: String
    /// Utterance shapes that bring this skill into scope.
    public var triggers: [String]
    public var invocations: [Invocation]
    public init(id: String, displayName: String, triggers: [String] = [],
                invocations: [Invocation]) {
        self.id = id; self.displayName = displayName
        self.triggers = triggers; self.invocations = invocations
    }

    /// A skill is only importable if every tool it names exists and
    /// every parameter it sets is declared by that tool.
    public func validated(against registry: ToolRegistry) throws {
        for inv in invocations {
            guard let tool = registry.tool(inv.tool) else {
                throw RegistryError.unknownTool(inv.tool)
            }
            for key in inv.parameters.keys where !tool.parameters.contains(key) {
                throw RegistryError.undeclaredParameter(tool: inv.tool, parameter: key)
            }
        }
    }
}

/// Why a scoped request left scope. `fulfilled` and `cancelled` are
/// the tidy exits; the rest are decay — the request going out of
/// scope because the world moved on.
public enum ScopedRequestEnd: Equatable, Sendable {
    case fulfilled
    case cancelled
    case superseded
    case timedOut
    case targetLost
}

/// A narrow, expiring sub-goal pushed over the running goal:
/// "read *that* sign" against a background of "tell me what I see".
/// Completion or decay pops it; the parent goal resumes untouched
/// and unrestated.
public struct ScopedRequest: Equatable, Sendable {
    public var toolID: String
    /// What the request is about ("sign", "package", …) — matched
    /// against digest labels and OCR to judge target visibility.
    public var target: String
    public var createdAt: Date
    public var expiresAt: Date
    public var lastTargetSeenAt: Date
    /// True when Dave was actively steering the user toward the
    /// target. Only then is a lost target worth one spoken "lost it";
    /// otherwise decay is silent (TRD-007 §3).
    public var guidanceActive: Bool

    public init(toolID: String, target: String, now: Date,
                timeout: TimeInterval = 45, guidanceActive: Bool = false) {
        self.toolID = toolID; self.target = target
        self.createdAt = now; self.expiresAt = now.addingTimeInterval(timeout)
        self.lastTargetSeenAt = now; self.guidanceActive = guidanceActive
    }
}

public struct ScopedRequestStack: Equatable, Sendable {
    public private(set) var active: ScopedRequest?
    /// Seconds the target may stay unseen before the request decays
    /// as lost. Kept well under the timeout: a sign you have walked
    /// past is gone long before 45 s are up.
    public var lostGrace: TimeInterval = 10
    public init() {}

    /// Push a request. A new request for the same tool supersedes
    /// the old one (the user re-asked; the old ask is moot) and the
    /// superseded request is returned so the caller can log it.
    @discardableResult
    public mutating func push(_ request: ScopedRequest) -> ScopedRequest? {
        defer { active = request }
        return active
    }

    @discardableResult
    public mutating func complete() -> ScopedRequest? {
        defer { active = nil }
        return active
    }

    @discardableResult
    public mutating func cancel() -> ScopedRequest? { complete() }

    /// Per-digest decay evaluation. Returns why the request ended,
    /// or nil if it is still in scope. Target visibility refreshes
    /// the lost-clock; timeout is absolute from creation.
    public mutating func evaluate(now: Date, targetVisible: Bool) -> ScopedRequestEnd? {
        guard var req = active else { return nil }
        if targetVisible { req.lastTargetSeenAt = now; active = req }
        if now >= req.expiresAt {
            active = nil; return .timedOut
        }
        if now.timeIntervalSince(req.lastTargetSeenAt) > lostGrace {
            active = nil; return .targetLost
        }
        return nil
    }

    /// Whether an end is worth one spoken notice. Fulfilled speaks
    /// its result anyway; decay is announced only when the user was
    /// being actively guided and is plausibly still waiting.
    public static func shouldAnnounce(_ end: ScopedRequestEnd,
                                      for request: ScopedRequest) -> Bool {
        switch end {
        case .targetLost, .timedOut: return request.guidanceActive
        case .fulfilled, .cancelled, .superseded: return false
        }
    }
}

/// Deterministic one-off commands (TRD-007 §2). Whole-utterance
/// matching, like ConversationCommand, so "watch for the stop sign"
/// can never be mistaken for an instruction about a sign. Anything
/// unmatched flows on to goal parsing/refinement — and, later, to a
/// model dispatcher over this same registry.
public enum OneOffCommand: Equatable, Sendable {
    case readSign
    case cancelScopedRequest

    private static let table: [(OneOffCommand, Set<String>)] = [
        (.readSign, ["read that sign", "read the sign",
                     "read that sign for me", "read the sign for me",
                     "help me read that sign", "help me read the sign",
                     "read this sign", "what does that sign say",
                     "what does the sign say", "what did that sign say",
                     "what was that sign"]),
        (.cancelScopedRequest, ["never mind", "nevermind", "forget it",
                                "forget the sign", "skip it", "skip that",
                                "drop it", "cancel that", "cancel the sign"]),
    ]

    /// Bare pronouns ("read it", "read that") are only meaningful
    /// with a noun already attached — a scoped request in flight or
    /// a referent Dave just named. Without one they must not parse:
    /// a pronoun in search of a referent is a refinement's job, not
    /// a one-off's (PR #64 review).
    private static let barePronouns: Set<String> = ["read it", "read that",
                                                    "read this"]

    public static func parse(_ rawText: String, referent: String? = nil) -> OneOffCommand? {
        var text = rawText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("please ") { text = String(text.dropFirst("please ".count)) }
        if text.hasPrefix("dave, ") { text = String(text.dropFirst("dave, ".count)) }
        if text.hasPrefix("dave ") { text = String(text.dropFirst("dave ".count)) }
        if referent != nil, barePronouns.contains(text) { return .readSign }
        for (command, phrases) in table where phrases.contains(text) {
            return command
        }
        return nil
    }

    /// The registry tool a fulfilled-parse invokes, where applicable.
    public var toolID: String? {
        switch self {
        case .readSign: return "read_sign"
        case .cancelScopedRequest: return nil
        }
    }
}
