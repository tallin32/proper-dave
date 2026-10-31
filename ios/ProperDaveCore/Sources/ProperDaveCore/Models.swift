import Foundation

// Wire contract shared with src/proper_dave/models.py (TRD-001 CAP-08).
// TRD field names are kept verbatim (sessionID, ocrText, ...) on the wire.

public struct ScoredLabel: Codable, Equatable, Sendable {
    public var name: String
    public var confidence: Double
    public init(name: String, confidence: Double = 1) { self.name = name; self.confidence = confidence }
}

public struct OCRSpan: Codable, Equatable, Sendable {
    public var text: String
    public var confidence: Double
    public init(text: String, confidence: Double = 1) { self.text = text; self.confidence = confidence }
}

public struct ChangeMetrics: Codable, Equatable, Sendable {
    public var pixelDiff: Double
    public var labelDelta: Double
    public init(pixelDiff: Double = 0, labelDelta: Double = 0) {
        self.pixelDiff = pixelDiff; self.labelDelta = labelDelta
    }
}

public struct FrameDigest: Codable, Equatable, Sendable, Identifiable {
    public var sessionID: UUID
    public var sequence: Int
    public var capturedAt: Date
    public var sourceID: String
    public var labels: [ScoredLabel]
    public var ocrText: [OCRSpan]
    public var sceneChange: ChangeMetrics
    public var imageRef: String?
    public var id: Int { sequence }
    public init(sessionID: UUID, sequence: Int, capturedAt: Date = Date(), sourceID: String,
                labels: [ScoredLabel] = [], ocrText: [OCRSpan] = [],
                sceneChange: ChangeMetrics = ChangeMetrics(), imageRef: String? = nil) {
        self.sessionID = sessionID; self.sequence = sequence; self.capturedAt = capturedAt
        self.sourceID = sourceID; self.labels = labels; self.ocrText = ocrText
        self.sceneChange = sceneChange; self.imageRef = imageRef
    }
}

public enum GoalKind: String, Codable, Equatable, Sendable {
    case watch, question, describe
}

public enum Verbosity: String, Codable, Equatable, Sendable {
    case landmarks, notable, detailed
}

public struct GoalContext: Codable, Equatable, Sendable {
    public var rawText: String
    /// Additive /v1 fields (TRD-004): absent keys decode to the
    /// pre-describe defaults, so old payloads keep their meaning.
    public var kind: GoalKind
    public var verbosity: Verbosity
    public var targets: [String]
    public var exclusions: [String]
    public var progressLandmarks: String?
    public var expiresAt: Date?
    public init(rawText: String, targets: [String], exclusions: [String] = [],
                progressLandmarks: String? = nil, expiresAt: Date? = nil,
                kind: GoalKind = .watch, verbosity: Verbosity = .notable) {
        self.rawText = rawText; self.targets = targets; self.exclusions = exclusions
        self.progressLandmarks = progressLandmarks; self.expiresAt = expiresAt
        self.kind = kind; self.verbosity = verbosity
    }

    private enum CodingKeys: String, CodingKey {
        case rawText, kind, verbosity, targets, exclusions, progressLandmarks, expiresAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rawText = try c.decode(String.self, forKey: .rawText)
        kind = try c.decodeIfPresent(GoalKind.self, forKey: .kind) ?? .watch
        verbosity = try c.decodeIfPresent(Verbosity.self, forKey: .verbosity) ?? .notable
        targets = try c.decode([String].self, forKey: .targets)
        exclusions = try c.decodeIfPresent([String].self, forKey: .exclusions) ?? []
        progressLandmarks = try c.decodeIfPresent(String.self, forKey: .progressLandmarks)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
    }
}

/// A structured goal patch (TRD-003 §2): what a model — never a
/// keyword table — produces from a free-form refinement utterance.
public struct GoalPatch: Codable, Equatable, Sendable {
    public var verbosity: Verbosity?
    public var setTargets: [String]?
    public var addTargets: [String] = []
    public var removeTargets: [String] = []
    public var addExclusions: [String] = []
    public init(verbosity: Verbosity? = nil, setTargets: [String]? = nil,
                addTargets: [String] = [], removeTargets: [String] = [],
                addExclusions: [String] = []) {
        self.verbosity = verbosity; self.setTargets = setTargets
        self.addTargets = addTargets; self.removeTargets = removeTargets
        self.addExclusions = addExclusions
    }
    public var isEmpty: Bool {
        verbosity == nil && setTargets == nil && addTargets.isEmpty
            && removeTargets.isEmpty && addExclusions.isEmpty
    }
    public func applied(to goal: GoalContext) -> GoalContext {
        var g = goal
        if let verbosity { g.verbosity = verbosity }
        if let setTargets { g.targets = setTargets }
        let removed = Set(removeTargets.map { $0.lowercased() })
        g.targets.removeAll { removed.contains($0.lowercased()) }
        for t in addTargets where !g.targets.contains(where: { $0.lowercased() == t.lowercased() }) {
            g.targets.append(t)
        }
        for e in addExclusions {
            g.exclusions.append(e)
            g.targets.removeAll { $0.lowercased() == e.lowercased() }
        }
        return g
    }
}

public struct EscalationRequest: Codable, Sendable {
    public var sessionID: UUID
    public var goal: GoalContext
    public var digest: FrameDigest
    public var recentDigests: [FrameDigest]
    public var image: String?
    public var lastCallout: String?
    public var skillID: String?
    public init(sessionID: UUID, goal: GoalContext, digest: FrameDigest,
                recentDigests: [FrameDigest] = [], image: String? = nil,
                lastCallout: String? = nil, skillID: String? = nil) {
        self.sessionID = sessionID; self.goal = goal; self.digest = digest
        self.recentDigests = recentDigests; self.image = image
        self.lastCallout = lastCallout; self.skillID = skillID
    }
}

public enum CalloutResult: Codable, Equatable, Sendable {
    case callout(text: String, relevance: Double)
    case noCallout(reason: String)

    private enum CodingKeys: String, CodingKey { case kind, text, relevance, reason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(String.self, forKey: .kind) == "callout" {
            self = .callout(text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                            relevance: try c.decodeIfPresent(Double.self, forKey: .relevance) ?? 1)
        } else {
            self = .noCallout(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "unknown")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .callout(let text, let relevance):
            try c.encode("callout", forKey: .kind); try c.encode(text, forKey: .text)
            try c.encode(relevance, forKey: .relevance)
        case .noCallout(let reason):
            try c.encode("noCallout", forKey: .kind); try c.encode(reason, forKey: .reason)
        }
    }
}
