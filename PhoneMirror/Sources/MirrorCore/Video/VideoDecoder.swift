// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

/// Hardware-Dekodierung (VideoToolbox) in IOSurface-gestützte BGRA-Pixelbuffer.
/// Anders als `AVSampleBufferDisplayLayer` erlaubt das, das Bild vor der Anzeige zu untersuchen
/// (siehe `ContentRectDetector`). Die Ausgabe kommt auf einem VideoToolbox-Thread.
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
                if status != noErr { Self.logger.error("Dekodierfehler \(status)") }
                return
            }
            handler(imageBuffer)
        }
        if status != noErr {
            // Der Decoder ist in einem schlechten Zustand – beim nächsten Keyframe neu aufbauen.
            reset()
            throw VideoDecoderError.decode(status)
        }
    }

    /// Verwirft die Decoder-Session (Referenzbilder), z. B. vor einem Reset-Keyframe.
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
