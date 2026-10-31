import Foundation

/// TRD-002 reference classifier, Swift side. Must pass the same golden
/// vectors as src/proper_dave/classifier.py (CLS-03). Pure (CLS-01).
public enum Classifier {
    public static let changeThreshold = 0.25
    public static let relevanceThreshold = 0.30
    public static let majorChangeThreshold = 0.80
    public static let defaultCooldown: TimeInterval = 10

    public enum Decision: Equatable, Sendable {
        case suppress(reason: String)
        case escalateDigest(confidence: Double, landmark: String?)
        case escalateFrame(confidence: Double, landmark: String?)

        public var isEscalation: Bool { if case .suppress = self { return false }; return true }
        public var name: String {
            switch self {
            case .suppress(let r): return "SUPPRESS(\(r))"
            case .escalateDigest: return "ESCALATE_DIGEST"
            case .escalateFrame: return "ESCALATE_FRAME"
            }
        }
    }

    public struct Scores: Equatable, Sendable {
        public var change: Double
        public var relevance: Double
        public var landmark: String?
        /// Describe goals: saliency (in `relevance`) and the new topics
        /// at/above the verbosity threshold, for session dedupe.
        public var topics: [String] = []
    }

    public static let verbosityThresholds: [Verbosity: Double] = [
        .landmarks: 0.85, .notable: 0.60, .detailed: 0.35,
    ]
    private static let litterTokens: Set<String> = ["wrapper", "litter", "trash", "leaf", "leaves", "paper", "cup", "straw", "crumb", "crumbs"]
    private static let smallFocusTokens: Set<String> = ["small", "floor", "objects", "items", "anything", "left", "dropped"]
    private static let highTokens: Set<String> = ["entrance", "exit", "station", "platform", "gate", "elevator", "lift",
                                                  "escalator", "subway", "terminal", "museum", "library", "hospital",
                                                  "stairs", "curb", "barrier", "construction", "detour", "caution"]

    /// Task-conditioned saliency of one gained item (CLS-13/17).
    /// Mirrored line-for-line in classifier.py.
    public static func itemScore(_ item: String, isOCR: Bool, focus: [String], exclusions: [String]) -> Double {
        let itemTokens = tokens(item)
        if exclusions.contains(where: { !tokens($0).intersection(itemTokens).isEmpty }) { return 0 }
        var focusTokens = Set<String>()
        for f in focus { focusTokens.formUnion(tokens(f)) }
        if !itemTokens.intersection(litterTokens).isEmpty {
            return focusTokens.intersection(smallFocusTokens).isEmpty ? 0.05 : 0.85
        }
        var score: Double
        if !itemTokens.intersection(highTokens).isEmpty { score = 0.90 }
        else if isOCR { score = 0.80 }
        else if itemTokens.contains("person") || itemTokens.contains("people") { score = 0.15 }
        else if !itemTokens.intersection(["car", "bus", "train", "vehicle", "truck"]).isEmpty { score = 0.45 }
        else if itemTokens.contains("building") { score = 0.55 }
        else if !itemTokens.intersection(["sign", "store", "shop", "restaurant", "cafe", "storefront"]).isEmpty { score = 0.75 }
        else { score = 0.40 }
        let focused = !focusTokens.intersection(itemTokens).isEmpty
            || ((focusTokens.contains("people") || focusTokens.contains("person"))
                && !itemTokens.intersection(["person", "people", "crowd"]).isEmpty)
        if focused { score = max(score, 0.70) } else if !focusTokens.isEmpty { score -= 0.10 }
        return max(0, min(1, score))
    }

    public static func saliency(digest: FrameDigest, gained: Set<String>, goal: GoalContext,
                                announced: Set<String> = []) -> (score: Double, topics: [String]) {
        var isOCR: [String: Bool] = [:]
        for x in digest.ocrText { isOCR[x.text.lowercased()] = true }
        for x in digest.labels where isOCR[x.name.lowercased()] == nil { isOCR[x.name.lowercased()] = false }
        let threshold = verbosityThresholds[goal.verbosity] ?? 0.60
        let scored = gained.subtracting(announced).sorted().map {
            (item: $0, score: itemScore($0, isOCR: isOCR[$0] ?? false, focus: goal.targets, exclusions: goal.exclusions))
        }
        return (scored.map(\.score).max() ?? 0, scored.filter { $0.score >= threshold }.map(\.item))
    }

    public static func evaluate(
        digest: FrameDigest, window: [FrameDigest], goal: GoalContext,
        lastCallout: String? = nil, secondsSinceEscalation: TimeInterval? = nil,
        reportedLandmarks: Set<String> = [], announcedTopics: Set<String> = [],
        cooldown: TimeInterval = defaultCooldown
    ) -> (decision: Decision, scores: Scores) {
        let current = texts(digest)
        var seen = Set<String>()
        for past in window { seen.formUnion(texts(past)) }
        let gained = current.subtracting(seen)
        let lost = seen.subtracting(current)

        let change = min(1, 0.5 * digest.sceneChange.pixelDiff
            + 0.25 * min(1, Double(gained.count) / 3)
            + 0.25 * min(1, Double(lost.count) / 3))

        var landmark: String?
        if goal.progressLandmarks != nil {
            landmark = gateCodes(current).subtracting(gateCodes(seen))
                .subtracting(reportedLandmarks).subtracting(gateCodes(Set(goal.targets)))
                .sorted().first
        }

        var relevance = matchScore(gained: gained, phrases: goal.targets)
        relevance -= 0.5 * matchScore(gained: gained, phrases: goal.exclusions)
        relevance = max(0, min(1, relevance))
        if landmark != nil { relevance = max(relevance, relevanceThreshold) }

        if goal.kind == .describe {
            let (sal, topics) = saliency(digest: digest, gained: gained, goal: goal, announced: announcedTopics)
            let scores = Scores(change: change, relevance: sal, landmark: landmark, topics: topics)
            if let since = secondsSinceEscalation, since < cooldown, change < majorChangeThreshold {
                return (.suppress(reason: "cooldown"), scores)
            }
            if !gained.isEmpty && gained.subtracting(announcedTopics).isEmpty {
                return (.suppress(reason: "alreadyAnnounced"), scores)
            }
            if change < changeThreshold { return (.suppress(reason: "noMaterialChange"), scores) }
            if sal < (verbosityThresholds[goal.verbosity] ?? 0.60) {
                return (.suppress(reason: "notSalient"), scores)
            }
            if topics.isEmpty && change >= majorChangeThreshold {
                return (.escalateFrame(confidence: sal, landmark: landmark), scores)
            }
            return (.escalateDigest(confidence: sal, landmark: landmark), scores)
        }

        let scores = Scores(change: change, relevance: relevance, landmark: landmark)

        if let since = secondsSinceEscalation, since < cooldown, change < majorChangeThreshold {
            return (.suppress(reason: "cooldown"), scores)
        }
        if let lastCallout, !gained.isEmpty, gained.allSatisfy({ lastCallout.lowercased().contains($0) }) {
            return (.suppress(reason: "alreadyReported"), scores)
        }
        if change < changeThreshold { return (.suppress(reason: "noMaterialChange"), scores) }
        if relevance < relevanceThreshold { return (.suppress(reason: "notRelevant"), scores) }
        if gained.isEmpty && change >= majorChangeThreshold {
            return (.escalateFrame(confidence: relevance, landmark: landmark), scores)
        }
        return (.escalateDigest(confidence: relevance, landmark: landmark), scores)
    }

    static func texts(_ digest: FrameDigest) -> Set<String> {
        Set(digest.labels.map { $0.name.lowercased() } + digest.ocrText.map { $0.text.lowercased() })
    }
    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
    static func matchScore(gained: Set<String>, phrases: [String]) -> Double {
        guard !phrases.isEmpty else { return 0 }
        var pool = Set<String>()
        for item in gained { pool.formUnion(tokens(item)) }
        let hits = phrases.filter { !tokens($0).intersection(pool).isEmpty || gained.contains($0.lowercased()) }.count
        return Double(hits) / Double(phrases.count)
    }
    static func gateCodes(_ texts: Set<String>) -> Set<String> {
        var codes = Set<String>()
        let regex = try! NSRegularExpression(pattern: #"\b([a-z])\s?-?\s?(\d{1,3})\b"#)
        for text in texts {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let l = Range(match.range(at: 1), in: text), let d = Range(match.range(at: 2), in: text) {
                    codes.insert(text[l].uppercased() + text[d])
                }
            }
        }
        return codes
    }
}
