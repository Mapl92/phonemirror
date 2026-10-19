// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

/// Hardware decoding (VideoToolbox) into IOSurface-backed BGRA pixel buffers.
/// Unlike `AVSampleBufferDisplayLayer`, this allows inspecting the picture before display
/// (see `ContentRectDetector`). Output arrives on a VideoToolbox thread.
public final class VideoDecoder: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (CVPixelBuffer) -> Void

    private let handler: FrameHandler
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var sessionFormat: CMVideoFormatDescription?
    private static let logger = Logger(subsystem: "PhoneMirror", category: "decoder")

    public init(handler: @escaping FrameHandler) {
        self.handler = handler
    }

    deinit {
        reset()
    }

    public func decode(_ sampleBuffer: CMSampleBuffer) throws {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let session = try session(for: format)
        let handler = handler
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                if status != noErr { Self.logger.error("Decoding error \(status)") }
                return
            }
            handler(imageBuffer)
        }
        if status != noErr {
            // The decoder is in a bad state – rebuild it at the next keyframe.
            reset()
            throw VideoDecoderError.decode(status)
        }
    }

    /// Discards the decoder session (reference frames), e.g. before a reset keyframe.
    public func reset() {
        lock.lock()
        let old = session
        session = nil
        sessionFormat = nil
        lock.unlock()
        if let old {
            VTDecompressionSessionWaitForAsynchronousFrames(old)
            VTDecompressionSessionInvalidate(old)
        }
    }

    private func session(for format: CMVideoFormatDescription) throws -> VTDecompressionSession {
        lock.lock()
        defer { lock.unlock() }
        if let session, let sessionFormat {
            if CMFormatDescriptionEqual(sessionFormat, otherFormatDescription: format)
                || VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) {
                return session
            }
            VTDecompressionSessionInvalidate(session)
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else { throw VideoDecoderError.session(status) }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        sessionFormat = format
        return newSession
    }
}

public enum VideoDecoderError: Error, Equatable {
    case session(OSStatus)
    case decode(OSStatus)
}
