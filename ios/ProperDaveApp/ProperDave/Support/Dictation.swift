import AVFoundation
import Foundation
import Speech

/// Optional dictated prompt. Typing always works (noise, privacy, being
/// on a call); dictation is an alternative, never a requirement.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var isListening = false
    @Published var transcript = ""
    @Published var errorText: String?

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?

    /// Reports the active input route once listening starts
    /// ("bluetoothHFP: Ray-Ban Meta" vs the built-in mic), so a
    /// field log can prove which microphone actually captured a
    /// dictation. Wired by the owning views to the event log.
    var onRoute: ((String) -> Void)?

    func toggle() { isListening ? stop() : start() }

    private func start() {
        errorText = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard status == .authorized else {
                    self?.errorText = "Speech recognition is not authorised. You can still type the prompt."
                    return
                }
                self?.begin()
            }
        }
    }

    private func begin() {
        // Each listening session starts from an empty transcript:
        // a quick Talk->Stop with nothing said must not re-send the
        // previous turn's words (Conversation now sends on Stop).
        transcript = ""
        do {
            let session = AVAudioSession.sharedInstance()
            // Full duplex, never .record: a record-only category
            // has no output path at all, so tapping Talk silenced
            // Dave — and, far worse, VoiceOver, leaving a blind
            // user with no access to the phone mid-dictation.
            // .playAndRecord + .voiceChat is the configuration
            // phone calls use: mic and speaker live together, the
            // system provides echo cancellation (so Dave's own
            // voice is largely cancelled out of the capture), and
            // accessibility audio keeps working. Bluetooth HFP is
            // allowed so paired glasses (or any headset) can be the
            // microphone through the standard iOS route — separate
            // from Meta's experimental DAT mic (TRD-001 CAP-12).
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            // Voice processing (echo cancellation) on the engine's
            // I/O before the tap goes in; best-effort by design.
            try? audioEngine.inputNode.setVoiceProcessingEnabled(true)
            if let bluetooth = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
                try? session.setPreferredInput(bluetooth)
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            let input = audioEngine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            let inputs = session.currentRoute.inputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ", ")
            onRoute?(inputs.isEmpty ? "no input route" : inputs)
            task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    if let result { self?.transcript = result.bestTranscription.formattedString }
                    if error != nil { self?.stop() }
                }
            }
            isListening = true
        } catch {
            // A half-started begin() may already have set .record;
            // never leave the session unable to speak.
            try? AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .spokenAudio, options: [.allowBluetoothA2DP])
            errorText = "Microphone unavailable. You can still type the prompt."
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil
        isListening = false
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        // Restore a playback-capable category. Leaving the session
        // in .record (set in begin()) silences EVERYTHING the app
        // says afterwards — speech synthesis and the heartbeat
        // produce no output in a record-only category, on any
        // route (field report: wired, Bluetooth, and glasses all
        // mute after one dictation in conversation mode).
        try? session.setCategory(.playback, mode: .spokenAudio,
                                 options: [.allowBluetoothA2DP])
        // Leave it active: speech and the heartbeat expect a live
        // playback session, and reactivation must not depend on
        // whichever sound happens to be attempted first.
        try? session.setActive(true)
    }
}
