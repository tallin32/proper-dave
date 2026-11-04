import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ProperDaveCore
import UIKit
import Vision

/// Shared on-device digest extraction (TRD-001), used by phone camera and
/// glasses frames alike so a digest means the same thing from any source.
struct DigestExtractor {
    private var previous = Set<String>()
    private let ciContext = CIContext()
    private var previousThumbnail: [UInt8] = []
    private var motionPeak: Double = -1

    /// Per-frame motion probe (cheap at full camera rate): a
    /// 32x24 luma thumbnail diffed against the previous frame.
    /// Returns this frame's motion 0..1, and tracks the peak since
    /// the last digest, which digest() attaches and resets. This
    /// is the frame-rate change signal label deltas cannot give:
    /// mid-swing, Vision labels vanish, but the pixels still move.
    mutating func noteFrame(pixelBuffer: CVPixelBuffer) -> Double {
        guard let thumb = thumbnail(pixelBuffer) else { return -1 }
        defer { previousThumbnail = thumb }
        guard previousThumbnail.count == thumb.count, !thumb.isEmpty else { return -1 }
        var total = 0
        for i in thumb.indices { total += abs(Int(thumb[i]) - Int(previousThumbnail[i])) }
        let value = Double(total) / Double(thumb.count) / 255.0
        if value > motionPeak { motionPeak = value }
        return value
    }

    private func thumbnail(_ pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard image.extent.width > 0, image.extent.height > 0 else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: 32 / image.extent.width, y: 24 / image.extent.height))
        var bytes = [UInt8](repeating: 0, count: 32 * 24 * 4)
        ciContext.render(scaled, toBitmap: &bytes, rowBytes: 32 * 4,
                         bounds: CGRect(x: 0, y: 0, width: 32, height: 24),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var luma = [UInt8]()
        luma.reserveCapacity(32 * 24)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            luma.append(UInt8((Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])) / 3))
        }
        return luma
    }

    /// Bounded JPEG retention for ESCALATE_FRAME: the model can only
    /// look at a frame the source actually kept. Oriented upright:
    /// the raw camera buffer is landscape-rotated, and until now the
    /// model, the POV footage, and every recorded frame were all
    /// sideways (field frames 2026-11-03). Glasses keep .up (their
    /// frames arrive upright); the phone camera passes .right.
    func jpegData(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if orientation != .up { image = image.oriented(orientation) }
        return ciContext.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.72])
    }

    mutating func digest(pixelBuffer: CVPixelBuffer, sessionID: UUID, sequence: Int,
                         sourceID: String) -> FrameDigest {
        var labels: [ScoredLabel] = []
        var ocr: [OCRSpan] = []
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)

        let classify = VNClassifyImageRequest()
        try? handler.perform([classify])
        if let observations = classify.results {
            labels = observations.filter { $0.confidence > 0.1 }.prefix(8).map {
                ScoredLabel(name: $0.identifier, confidence: Double($0.confidence))
            }
        }
        let textRequest = VNRecognizeTextRequest()
        // Accurate, not fast: sign text at walking angles is exactly
        // where fast OCR gives up, and a sign the digest never
        // contains is a sign the gate can never report (frame 135,
        // field walk 2026-11-03). At digest cadence the cost is fine.
        textRequest.recognitionLevel = .accurate
        try? handler.perform([textRequest])
        if let observations = textRequest.results {
            ocr = observations.compactMap { $0.topCandidates(1).first }
                .map { OCRSpan(text: $0.string, confidence: Double($0.confidence)) }
        }

        let current = Set(labels.map(\.name) + ocr.map(\.text))
        let delta = previous.isEmpty ? 0.0
            : Double(current.symmetricDifference(previous).count)
                / Double(max(current.union(previous).count, 1))
        previous = current
        let motion = motionPeak
        motionPeak = -1
        return FrameDigest(sessionID: sessionID, sequence: sequence, sourceID: sourceID,
                           labels: labels, ocrText: ocr,
                           sceneChange: ChangeMetrics(pixelDiff: delta, labelDelta: delta,
                                                      brightness: meanLuminance(pixelBuffer: pixelBuffer),
                                                      motion: motion))
    }

    /// Mean luminance 0..1 via a 1x1 area-average render — cheap at
    /// digest rates, and the signal that tells "lights went off"
    /// apart from "labels churned" (field log 00:25).
    private func meanLuminance(pixelBuffer: CVPixelBuffer) -> Double {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: image,
                kCIInputExtentKey: CIVector(cgRect: image.extent)]),
              let output = filter.outputImage else { return -1 }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &pixel, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: nil)
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1])
                + 0.0722 * Double(pixel[2])) / 255.0
    }

    /// Decoded-image path (DAT hvc1 frames via VideoFrameDecoder, as in
    /// Meta's sample). Renders the image into a pixel buffer once, at our
    /// throttled rate, so cost is bounded.
    mutating func digest(image: UIImage, sessionID: UUID, sequence: Int,
                         sourceID: String) -> FrameDigest? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32ARGB, attrs as CFDictionary,
                                  &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return digest(pixelBuffer: buffer, sessionID: sessionID, sequence: sequence, sourceID: sourceID)
    }

    mutating func digest(sampleBuffer: CMSampleBuffer, sessionID: UUID, sequence: Int,
                         sourceID: String) -> FrameDigest? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        return digest(pixelBuffer: pixelBuffer, sessionID: sessionID, sequence: sequence, sourceID: sourceID)
    }
}
