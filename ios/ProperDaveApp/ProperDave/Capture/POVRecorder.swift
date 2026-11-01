import AVFoundation
import CoreImage
import Foundation

/// Point-of-view demo footage: while a watch runs (and only when the
/// user enabled it in Settings), every frame Dave judged from is
/// kept on disk with its timestamp, then exported as one MP4 where
/// each frame is held for its real duration. This is the footage a
/// second camera would otherwise have to shoot — the user's own
/// point of view, recorded by the system that used it.
///
/// Frames land in a temp directory as JPEGs plus a manifest; the
/// export is explicit (Settings button) so a long watch never pays
/// encoding cost it didn't ask for. Nothing is recorded unless the
/// toggle is on.
final class POVRecorder {
    private let queue = DispatchQueue(label: "properdave.pov-recorder")
    private var directory: URL?
    private var startedAt: Date?
    private var entries: [(file: String, offset: TimeInterval)] = []
    private var counter = 0

    var hasFootage: Bool { queue.sync { !entries.isEmpty } }
    var frameCount: Int { queue.sync { entries.count } }

    func begin() {
        queue.sync {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("pov-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            directory = dir
            startedAt = Date()
            entries = []
            counter = 0
        }
    }

    func record(jpeg: Data, at capturedAt: Date) {
        queue.async { [weak self] in
            guard let self, let directory = self.directory, let startedAt = self.startedAt else { return }
            self.counter += 1
            let name = String(format: "frame-%06d.jpg", self.counter)
            do {
                try jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)
                self.entries.append((file: name, offset: max(0, capturedAt.timeIntervalSince(startedAt))))
            } catch {
                // A dropped frame is a gap in footage, never a failed watch.
            }
        }
    }

    func finish() {
        queue.sync { startedAt = nil }
    }

    /// Build the MP4. Returns nil when there is nothing usable.
    func exportMP4() async -> URL? {
        let snapshot: (URL, [(String, TimeInterval)])? = queue.sync {
            guard let directory, !entries.isEmpty else { return nil }
            return (directory, entries)
        }
        guard let (directory, frames) = snapshot else { return nil }

        let firstURL = directory.appendingPathComponent(frames[0].0)
        guard let firstImage = CIImage(contentsOf: firstURL) else { return nil }
        let width = Int(firstImage.extent.width)
        let height = Int(firstImage.extent.height)
        guard width > 0, height > 0 else { return nil }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("proper-dave-pov-\(UUID().uuidString).mp4")
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        var appended = 0
        for (index, frame) in frames.enumerated() {
            guard let image = CIImage(contentsOf: directory.appendingPathComponent(frame.0)),
                  let pool = adaptor.pixelBufferPool else { continue }
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard writer.status == .writing else { break }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                  let buffer = pixelBuffer else { continue }
            // Scale-to-fill so mixed frame sizes (camera vs glasses)
            // cannot distort the timeline's canvas.
            let scale = max(CGFloat(width) / image.extent.width, CGFloat(height) / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            context.render(scaled, to: buffer)
            let pts = CMTime(seconds: frame.1, preferredTimescale: 600)
            if adaptor.append(buffer, withPresentationTime: pts) { appended += 1 }
            _ = index
        }
        guard appended > 0 else {
            writer.cancelWriting()
            return nil
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? output : nil
    }
}
