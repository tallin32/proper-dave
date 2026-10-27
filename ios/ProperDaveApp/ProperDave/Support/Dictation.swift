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
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
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
            task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    if let result { self?.transcript = result.bestTranscription.formattedString }
                    if error != nil { self?.stop() }
                }
            }
            isListening = true
        } catch {
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
