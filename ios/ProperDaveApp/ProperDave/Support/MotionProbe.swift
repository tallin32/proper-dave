import CoreMotion
import Foundation

/// Log-only motion probe: records CMMotionActivity changes to the
/// event log so field sessions can show whether walking/stationary
/// correlates with classifier behaviour (label churn, cooldown
/// suppressions) before motion is allowed to steer anything.
///
/// The motion coprocessor computes activity whether or not we
/// listen, and updates are event-driven (on change only), so the
/// incremental compute/battery cost beside the camera+Vision
/// pipeline is negligible. Denied permission or an unavailable
/// sensor is logged once and never treated as an error — the hint
/// is simply absent, like the glasses.
final class MotionProbe {
    private let manager = CMMotionActivityManager()
    private var lastDetail: String?

    /// (event, detail) — component is always "motion".
    var onEvent: ((String, String) -> Void)?

    func start() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            onEvent?("motion_unavailable", "CoreMotion activity is not available on this device.")
            return
        }
        onEvent?("motion_probe_started",
                 "authorization=\(Self.authorizationName(CMMotionActivityManager.authorizationStatus()))")
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            // Dedupe on the activity *kind*, not the full detail:
            // stationary(low) <-> unknown(high) flapping (observed
            // in the field while holding the phone up) otherwise
            // floods the log without saying anything new.
            let detail = Self.describe(activity)
            let kind = detail.components(separatedBy: " confidence=").first ?? detail
            guard kind != lastDetail else { return }
            lastDetail = kind
            onEvent?("motion_activity", detail)
        }
    }

    static func describe(_ activity: CMMotionActivity) -> String {
        var kinds: [String] = []
        if activity.stationary { kinds.append("stationary") }
        if activity.walking { kinds.append("walking") }
        if activity.running { kinds.append("running") }
        if activity.cycling { kinds.append("cycling") }
        if activity.automotive { kinds.append("automotive") }
        if activity.unknown || kinds.isEmpty { kinds.append("unknown") }
        let confidence: String
        switch activity.confidence {
        case .low: confidence = "low"
        case .medium: confidence = "medium"
        case .high: confidence = "high"
        @unknown default: confidence = "unknown"
        }
        return kinds.joined(separator: "+") + " confidence=\(confidence)"
    }

    private static func authorizationName(_ status: CMAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }
}
