import Foundation

/// Automatic-flashlight policy (pure, testable): when the camera's
/// measured brightness falls into the dark band during a goal, the
/// torch earns its keep; it stands down only on sustained genuinely
/// bright ambient, so torch-lit scenes (which read bright at once)
/// don't flicker it off, and it never outlives the goal (the source
/// resets it on stop). Unmeasured brightness (-1) earns no opinion.
public struct TorchPolicy: Equatable, Sendable {
    public private(set) var torchOn = false
    private var brightStreak = 0

    /// Brightness below this is the dark band (mirrors the
    /// low-light diagnostic threshold's neighbourhood).
    public static let darkThreshold = 0.10
    /// Torch light at conversational distance rarely sustains
    /// readings above this; daylight does.
    public static let brightThreshold = 0.45
    public static let brightStreakRequired = 3

    public init() {}

    /// Returns the desired torch state when it changes, else nil.
    public mutating func update(brightness: Double) -> Bool? {
        guard brightness >= 0 else { return nil }
        if !torchOn {
            brightStreak = 0
            if brightness < Self.darkThreshold { torchOn = true; return true }
            return nil
        }
        if brightness > Self.brightThreshold {
            brightStreak += 1
        } else {
            brightStreak = 0
        }
        if brightStreak >= Self.brightStreakRequired {
            torchOn = false
            brightStreak = 0
            return false
        }
        return nil
    }

    /// Goal over: the torch never outlives the watch.
    public mutating func reset() -> Bool? {
        brightStreak = 0
        guard torchOn else { return nil }
        torchOn = false
        return false
    }
}
