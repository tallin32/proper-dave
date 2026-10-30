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

    /// Bounded JPEG retention for ESCALATE_FRAME: the model can only
    /// look at a frame the source actually kept.
    func jpegData(pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
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
        textRequest.recognitionLevel = .fast
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
        return FrameDigest(sessionID: sessionID, sequence: sequence, sourceID: sourceID,
                           labels: labels, ocrText: ocr,
                           sceneChange: ChangeMetrics(pixelDiff: delta, labelDelta: delta))
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
