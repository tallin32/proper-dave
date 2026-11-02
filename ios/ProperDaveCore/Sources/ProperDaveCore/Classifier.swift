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
        // A parser that answers "object" to "what's in front of the
        // camera" has expressed no focus at all; it must not penalise
        // every real item for failing to match it.
        focusTokens.subtract(["object", "objects", "thing", "things", "camera", "front", "view", "see"])
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

    /// Largest luminance swing against the comparison window.
    /// Brightness is a first-class scene property for this product's
    /// users — "how well lit is it?" is a goal, and lights going off
    /// (or on) is salient even when no label changes. -1 (unmeasured)
    /// on either side means no signal, never a delta.
    public static func brightnessDelta(digest: FrameDigest, window: [FrameDigest]) -> Double {
        let now = digest.sceneChange.brightness
        guard now >= 0 else { return 0 }
        return window.compactMap { past -> Double? in
            past.sceneChange.brightness >= 0 ? abs(now - past.sceneChange.brightness) : nil
        }.max() ?? 0
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
            if window.isEmpty {
                // Baseline: the user just asked to be told what is
                // here. The first digest always escalates; saliency
                // gates only what follows. Without this, a generic
                // indoor scene (labels ~0.3) is silent forever.
                if topics.isEmpty { return (.escalateFrame(confidence: max(sal, 0.5), landmark: landmark), scores) }
                return (.escalateDigest(confidence: max(sal, 0.5), landmark: landmark), scores)
            }
            if goal.isSceneChangeGoal {
                // The change is the subject: a laptop giving way to
                // a window to a face must speak even though none of
                // those topics is stroll-salient, and returning to
                // an earlier scene is still a change, so topic
                // dedupe does not apply either. A clear swap (half
                // the label set turned over) also bypasses the
                // cooldown — otherwise a scene presented inside the
                // cooldown is absorbed into the comparison window
                // and never reported at all.
                if let since = secondsSinceEscalation, since < cooldown, change < 0.5 {
                    return (.suppress(reason: "cooldown"), scores)
                }
                if change < changeThreshold { return (.suppress(reason: "noMaterialChange"), scores) }
                // Stability: while the camera is swinging between
                // scenes every digest differs from the last, and
                // escalating mid-swing produced an escalation storm
                // in the field (25 calls in a minute, then model
                // rate-limiting). A new scene must survive one
                // digest — still present in the next frame — before
                // it is announced.
                // Stability is "resembles either of the last two
                // digests", not the immediate predecessor: Vision's
                // label set flickers between frames of the *same*
                // held scene (field log 03:09 — deliberate point-
                // at-something-new died as sceneUnstable), while a
                // genuine swing-through resembles none of them.
                let stable = window.suffix(2).contains { past in
                    let prev = texts(past)
                    let union = current.union(prev)
                    return union.isEmpty
                        || Double(current.symmetricDifference(prev).count) / Double(union.count) <= 0.5
                }
                if !window.isEmpty && !stable {
                    // In motion no scene survives two digests, so
                    // waiting for stability would mean never
                    // announcing. After a sustained interval with a
                    // major change, announce the current passing
                    // scene as a snapshot instead (at most once per
                    // interval, because this resets the escalation
                    // clock). Stationary scene presentation still
                    // uses the stable path and announces sooner.
                    if let since = secondsSinceEscalation, since >= 15, change >= majorChangeThreshold {
                        let changeScores = Scores(change: change, relevance: change, landmark: landmark, topics: topics)
                        return (.escalateFrame(confidence: change, landmark: landmark), changeScores)
                    }
                    return (.suppress(reason: "sceneUnstable"), scores)
                }
                let changeScores = Scores(change: change, relevance: change, landmark: landmark, topics: topics)
                if topics.isEmpty && change >= majorChangeThreshold {
                    return (.escalateFrame(confidence: change, landmark: landmark), changeScores)
                }
                return (.escalateDigest(confidence: change, landmark: landmark), changeScores)
            }
            // A large brightness swing bypasses the cooldown and
            // the saliency gate: lights going off in a room produces
            // no new labels and scores zero saliency, yet it is one
            // of the most salient events this product exists for
            // (field log 00:25 — a "how well lit" goal's changes at
            // 0.62-0.75 died under the 0.80 bypass for 20 seconds).
            let bDelta = brightnessDelta(digest: digest, window: window)
            if bDelta >= 0.30 {
                let lit = Scores(change: max(change, min(1, bDelta / 0.35)),
                                 relevance: max(sal, 0.6), landmark: landmark, topics: topics)
                return (.escalateFrame(confidence: max(sal, 0.6), landmark: landmark), lit)
            }
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

        if window.isEmpty {
            // Baseline (watch goals): the first digest always
            // escalates — from-nothing-to-anything IS the change.
            // The model decides whether current status is worth
            // speaking ("Thermostat: 72" toward 75 is; an empty
            // corridor toward a gate goal is not). Mirrors classifier.py.
            if gained.isEmpty { return (.escalateFrame(confidence: max(relevance, 0.5), landmark: landmark), scores) }
            return (.escalateDigest(confidence: max(relevance, 0.5), landmark: landmark), scores)
        }

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
