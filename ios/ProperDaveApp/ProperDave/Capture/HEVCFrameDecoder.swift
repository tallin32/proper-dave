import CoreMedia
import Foundation
import VideoToolbox

/// Minimal synchronous HEVC decompressor for DAT hvc1 frames (the SDK
/// delivers compressed sample buffers; Vision needs pixel buffers).
/// One session, recreated when the format description changes; decode
/// failures drop the frame — the next keyframe recovers the stream.
final class HEVCFrameDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private let lock = NSLock()

    func decode(_ sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        if let current = format, let existing = session,
           !CMFormatDescriptionEqual(current, otherFormatDescription: formatDescription) {
            VTDecompressionSessionInvalidate(existing)
            session = nil
            format = nil
        }
        if session == nil {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
            var created: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: formatDescription,
                decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &created)
            guard status == noErr, let created else { return nil }
            session = created
            format = formatDescription
        }
        guard let session else { return nil }
        nonisolated(unsafe) var output: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
        ) { decodeStatus, _, imageBuffer, _, _ in
            if decodeStatus == noErr { output = imageBuffer }
        }
        if status != noErr {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            format = nil
            return nil
        }
        return output
    }
}
