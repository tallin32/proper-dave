import CoreMedia
import CoreVideo
import Foundation
import ProperDaveCore
import Vision

/// Shared on-device digest extraction (TRD-001), used by phone camera and
/// glasses frames alike so a digest means the same thing from any source.
struct DigestExtractor {
    private var previous = Set<String>()

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

    mutating func digest(sampleBuffer: CMSampleBuffer, sessionID: UUID, sequence: Int,
                         sourceID: String) -> FrameDigest? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        return digest(pixelBuffer: pixelBuffer, sessionID: sessionID, sequence: sequence, sourceID: sourceID)
    }
}
