// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreMedia
import CoreText
import Foundation
import MirrorCore
import VideoToolbox

public enum HEVCTestStreamError: Error {
    case session(OSStatus)
    case pixelBuffer(CVReturn)
    case encode(OSStatus)
    case missingParameterSet(OSStatus)
}

/// Erzeugt einen synthetischen HEVC-Stream im Annex-B-Format, der wie ein Gerätebildschirm aussieht:
/// Bildnummer, Raster mit Eckmarken (zum Prüfen des Koordinaten-Mappings) und ein wandernder Kreis.
/// Jede Access Unit mit IRAP-Bild beginnt mit VPS/SPS/PPS – wie bei einem Live-Stream.
public enum HEVCTestStreamEncoder {
    public static func encode(
        width: Int,
        height: Int,
        frameCount: Int,
        framesPerSecond: Int = 60,
        keyframeInterval: Int = 60,
        collapsedFrames: (Int) -> Bool = { _ in false }
    ) throws -> Data {
        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw HEVCTestStreamError.session(status) }
        defer { VTCompressionSessionInvalidate(session) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: framesPerSecond as CFNumber)

        let output = EncodedOutput()
        for index in 0..<frameCount {
            let pixelBuffer = try makeFrame(
                index: index, width: width, height: height, framesPerSecond: framesPerSecond, collapsed: collapsedFrames(index)
            )
            let pts = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(framesPerSecond))
            status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: nil,
                infoFlagsOut: nil
            ) { status, _, sampleBuffer in
                output.append(status: status, sampleBuffer: sampleBuffer)
            }
            guard status == noErr else { throw HEVCTestStreamError.encode(status) }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return try output.result()
    }

    /// Anteil, auf den ein „kollabiertes“ Bild verkleinert wird (Rest grau wie beim iOS-Encoder).
    public static let collapseScale = 0.7

    private static func makeFrame(index: Int, width: Int, height: Int, framesPerSecond: Int, collapsed: Bool) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer)
        guard result == kCVReturnSuccess, let pixelBuffer else { throw HEVCTestStreamError.pixelBuffer(result) }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw HEVCTestStreamError.pixelBuffer(kCVReturnError) }

        // CoreGraphics zählt y von unten; für "oben links" spiegeln wir das Koordinatensystem.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        if collapsed {
            // Resolution Collapse nachstellen: grauer Grund, Inhalt verkleinert in der linken oberen Ecke.
            // Direkt im Gerätefarbraum setzen – CGColor(gray:) würde farbmanagt zu ≈ 146 umgerechnet.
            context.setFillColor(red: 128.0 / 255, green: 128.0 / 255, blue: 128.0 / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.clip(to: CGRect(x: 0, y: 0, width: Double(width) * collapseScale, height: Double(height) * collapseScale))
            context.scaleBy(x: collapseScale, y: collapseScale)
        }

        let w = CGFloat(width), h = CGFloat(height)
        let hue = CGFloat(index % 360) / 360
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Raster in Zehnteln der Fläche – entspricht Schritten von 6553,5 in Gerätekoordinaten.
        context.setStrokeColor(CGColor(gray: 0.3, alpha: 1))
        context.setLineWidth(2)
        for step in 1..<10 {
            let x = w * CGFloat(step) / 10, y = h * CGFloat(step) / 10
            context.strokeLineSegments(between: [CGPoint(x: x, y: 0), CGPoint(x: x, y: h), CGPoint(x: 0, y: y), CGPoint(x: w, y: y)])
        }

        // Eckmarken: oben links rot, oben rechts grün, unten links blau, unten rechts gelb.
        let marker = w * 0.08
        let corners: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: 0, width: marker, height: marker), CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)),
            (CGRect(x: w - marker, y: 0, width: marker, height: marker), CGColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1)),
            (CGRect(x: 0, y: h - marker, width: marker, height: marker), CGColor(red: 0.2, green: 0.4, blue: 1, alpha: 1)),
            (CGRect(x: w - marker, y: h - marker, width: marker, height: marker), CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)),
        ]
        for (rect, color) in corners {
            context.setFillColor(color)
            context.fill(rect)
        }

        // Wandernder Kreis zeigt, dass das Bild läuft.
        let phase = CGFloat(index) / CGFloat(framesPerSecond * 4) * 2 * .pi
        let radius = w * 0.1
        let center = CGPoint(x: w / 2 + cos(phase) * w * 0.3, y: h / 2 + sin(phase) * h * 0.3)
        context.setFillColor(CGColor(srgbRed: hue, green: 0.6, blue: 1 - hue, alpha: 1))
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        drawText("Frame \(index)", in: context, at: CGPoint(x: w * 0.1, y: h * 0.45), fontSize: w * 0.09)
        drawText("PhoneMirror Test", in: context, at: CGPoint(x: w * 0.1, y: h * 0.52), fontSize: w * 0.06)
        return pixelBuffer
    }

    private static func drawText(_ text: String, in context: CGContext, at origin: CGPoint, fontSize: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1),
        ] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
        context.saveGState()
        // Text wieder aufrecht zeichnen (Kontext ist gespiegelt).
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = origin
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// Sammelt die Encoder-Ausgabe threadsicher und wandelt sie in Annex B.
private final class EncodedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stream = Data()
    private var error: Error?

    func append(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        guard error == nil else { return }
        guard status == noErr, let sampleBuffer else {
            error = HEVCTestStreamError.encode(status)
            return
        }
        do {
            stream.append(try Self.annexB(from: sampleBuffer))
        } catch {
            self.error = error
        }
    }

    func result() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        return stream
    }

    private static func annexB(from sampleBuffer: CMSampleBuffer) throws -> Data {
        var data = Data()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                guard status == noErr, let pointer else { throw HEVCTestStreamError.missingParameterSet(status) }
                data.append(AnnexB.startCode)
                data.append(pointer, count: size)
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return data }
        var length = 0
        var base: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &base)
        guard let base else { return data }
        let bytes = UnsafeRawBufferPointer(start: base, count: length)
        var offset = 0
        while offset + 4 <= length {
            let nalLength = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian)
            offset += 4
            guard offset + nalLength <= length else { break }
            data.append(AnnexB.startCode)
            data.append(contentsOf: bytes[offset..<offset + nalLength])
            offset += nalLength
        }
        return data
    }
}
