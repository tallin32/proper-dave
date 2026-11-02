import AVFoundation
import Foundation
import SwiftUI
import UIKit
import UserNotifications

extension View {
    /// Every text field needs an explicit way out of the keyboard: the
    /// standard keyboard toolbar with a plain "Done" button that ends
    /// editing (plus drag-to-dismiss where applied). Relying on tapping
    /// another control or scrolling is not a dismissal path.
    func keyboardDoneToolbar(focus: FocusState<Bool>.Binding) -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus.wrappedValue = false }
            }
        }
    }
}

/// Spoken callouts (TRD-003): one at a time. Voice, rate, and
/// pitch come from the user's Speech settings (CONV-12); defaults
/// reproduce the plain system behaviour exactly.
final class Speaker: NSObject, ObservableObject {
    private let synthesizer = AVSpeechSynthesizer()
    /// "" means no voice is set: the system default speaks.
    var voiceIdentifier = ""
    /// Percentage of the system default rate (100 = unchanged).
    var ratePercent = 100
    var pitch: Float = 1.0

    /// Speech cannot leave the device in a record-only audio
    /// session category (dictation sets .record; an early return or
    /// a race could leave it there). Ensure playback before every
    /// utterance — cheap when already correct, decisive when not.
    private func ensurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback, session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .spokenAudio,
                                     options: [.allowBluetoothA2DP])
        }
        // Activation is not implied by a correct category: dictation
        // deactivates the session on stop, and a deactivated session
        // swallows synthesis even in .playback (field report: audio
        // never returned after tapping Stop). Activating is cheap
        // and idempotent, so do it unconditionally.
        try? session.setActive(true)
    }

    func speak(_ text: String) {
        ensurePlaybackSession()
        let utterance = AVSpeechUtterance(string: text)
        let scaled = AVSpeechUtteranceDefaultSpeechRate * Float(ratePercent) / 100
        utterance.rate = min(max(scaled, AVSpeechUtteranceMinimumSpeechRate),
                             AVSpeechUtteranceMaximumSpeechRate)
        utterance.pitchMultiplier = min(max(pitch, 0.5), 2.0)
        if !voiceIdentifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

extension Notification.Name {
    static let deviceDidShake = Notification.Name("properDave.deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        #if DEBUG
        if motion == .motionShake { NotificationCenter.default.post(name: .deviceDidShake, object: nil) }
        #endif
    }
}

#if DEBUG
/// Debug-incident alerting per TRD-005: local notification, not a
/// voice-first ceremony. Debug/test builds only.
enum DebugNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func notifyCritical(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
#endif
