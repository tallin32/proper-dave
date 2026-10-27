import AVFoundation
import Foundation

/// Synthesized "still working" heartbeat. No audio asset exists: each ping
/// is a short sine burst with a decaying envelope, rendered in code, so it
/// works fully offline and pitch/volume/interval are plain settings.
/// Off by default; the session only lets it sound while watching.
final class HeartbeatPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var timer: Timer?
    private var running = false

    var interval: TimeInterval = 4
    var volume: Float = 0.25
    var frequency: Double = 660
    /// Debug observability hook (wired to the event log in DEBUG builds).
    var onPing: (() -> Void)?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    }

    func setActive(_ active: Bool) {
        active ? start() : stop()
    }

    private func start() {
        guard !running else { return }
        running = true
        do {
            if !engine.isRunning { try engine.start() }
            player.play()
        } catch { return }
        ping()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.ping()
        }
    }

    func restartTiming() {
        guard running else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.ping()
        }
    }

    private func stop() {
        running = false
        timer?.invalidate(); timer = nil
        player.stop()
        engine.stop()
    }

    private func ping() {
        let sampleRate = 44_100.0
        let duration = 0.35
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let envelope = exp(-t * 14)  // quick attack, gentle decay
            channel[i] = Float(sin(2 * Double.pi * frequency * t) * envelope) * volume
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
        onPing?()
    }
}
