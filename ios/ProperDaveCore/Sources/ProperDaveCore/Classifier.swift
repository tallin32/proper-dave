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
    }

    public static func evaluate(
        digest: FrameDigest, window: [FrameDigest], goal: GoalContext,
        lastCallout: String? = nil, secondsSinceEscalation: TimeInterval? = nil,
        reportedLandmarks: Set<String> = [], cooldown: TimeInterval = defaultCooldown
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
