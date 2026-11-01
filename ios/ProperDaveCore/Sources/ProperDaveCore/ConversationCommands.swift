import Foundation

/// Deterministic conversation commands (TRD-006 control plane).
///
/// Conversation turns that operate the *session* — status, stop,
/// repeat, verbosity — are answered from state, never from a model:
/// they must be instant, free, and incapable of hallucinating what
/// the session is doing. Matching is deliberately conservative:
/// the whole normalized utterance must equal a known command (a
/// leading "please" is stripped). Anything else is not a command
/// and flows on to goal parsing / refinement, so "watch for the
/// stop sign" can never be mistaken for "stop".
public enum ConversationCommand: Equatable, Sendable {
    case status
    case stop
    case repeatLast
    case moreDetail
    case lessDetail
    case landmarksOnly
    case speakFaster
    case speakSlower

    private static let table: [(ConversationCommand, Set<String>)] = [
        (.status, ["what are you doing", "what are you doing right now",
                   "what are you watching for", "what are you looking for",
                   "what are you up to", "status", "what's happening",
                   "what is happening", "what's your status",
                   "what is your status"]),
        (.stop, ["stop", "stop watching", "stop it", "cancel", "cancel watching",
                 "that's enough", "that is enough", "enough", "quiet",
                 "be quiet", "stop talking"]),
        (.repeatLast, ["say that again", "repeat that", "repeat", "say again",
                       "what did you say", "what was that", "come again"]),
        (.moreDetail, ["tell me more", "more detail", "more details",
                       "tell me more detail", "describe more", "be more detailed",
                       "more descriptions", "tell me more about what's around",
                       "tell me more about what is around"]),
        (.lessDetail, ["tell me less", "less detail", "fewer details",
                       "less details", "keep it brief", "be brief",
                       "only the important stuff", "just the important stuff"]),
        (.landmarksOnly, ["just the landmarks", "only landmarks", "landmarks only",
                          "just landmarks", "only the landmarks",
                          "landmarks, nothing else", "just the big things",
                          "only the big things"]),
        (.speakFaster, ["speak faster", "talk faster", "increase rate",
                        "increase the rate", "speed up", "faster",
                        "speak more quickly", "talk more quickly"]),
        (.speakSlower, ["speak slower", "talk slower", "decrease rate",
                        "decrease the rate", "slow down", "slower",
                        "speak more slowly", "talk more slowly"]),
    ]

    public static func parse(_ rawText: String) -> ConversationCommand? {
        var text = rawText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("please ") { text = String(text.dropFirst("please ".count)) }
        for (command, phrases) in table where phrases.contains(text) {
            return command
        }
        return nil
    }

    /// The verbosity patch a detail command means, stepped relative
    /// to the current level; nil for non-detail commands and when
    /// already at the requested end of the scale.
    public func verbosityPatch(from current: Verbosity) -> GoalPatch? {
        switch self {
        case .landmarksOnly:
            return current == .landmarks ? nil : GoalPatch(verbosity: .landmarks)
        case .moreDetail:
            switch current {
            case .landmarks: return GoalPatch(verbosity: .notable)
            case .notable: return GoalPatch(verbosity: .detailed)
            case .detailed: return nil
            }
        case .lessDetail:
            switch current {
            case .detailed: return GoalPatch(verbosity: .notable)
            case .notable, .landmarks: return current == .landmarks ? nil : GoalPatch(verbosity: .landmarks)
            }
        case .status, .stop, .repeatLast, .speakFaster, .speakSlower:
            return nil
        }
    }

    /// The speech-rate step a rate command means, in percentage
    /// points relative to the system rate; nil for other commands.
    public func speechRateDelta(from currentPercent: Int) -> Int? {
        switch self {
        case .speakFaster: return currentPercent >= 200 ? nil : 25
        case .speakSlower: return currentPercent <= 50 ? nil : -25
        default: return nil
        }
    }
}
