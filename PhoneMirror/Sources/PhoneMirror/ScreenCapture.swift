// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreImage
import MirrorCore
import os

/// Turns decoded frames into upright images: crop to the visible area (padding, resolution collapse),
/// then rotate by the interface orientation.
enum FrameRenderer {
    static let context = CIContext()

    /// Full-resolution upright image; origin at (0, 0).
    static func upright(_ pixelBuffer: CVPixelBuffer, visible: CGSize, orientation: DeviceOrientation) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        // The visible area is at the top left; CoreImage counts y from the bottom.
        let crop = CGRect(x: 0, y: extent.height * (1 - visible.height),
                          width: extent.width * visible.width, height: extent.height * visible.height)
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        let turned = image.cropped(to: crop).oriented(orientations[orientation.quarterTurns])
        return turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
    }

    static func png(_ image: CIImage) -> Data? {
        context.pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// `~/Pictures/PhoneMirror` and `~/Movies/PhoneMirror` – folders macOS does not guard with a privacy prompt.
    static func outputURL(in directory: FileManager.SearchPathDirectory, prefix: String, extension pathExtension: String) throws -> URL {
        let folder = FileManager.default.urls(for: directory, in: .userDomainMask)[0].appendingPathComponent("PhoneMirror")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return folder.appendingPathComponent("\(prefix) \(formatter.string(from: Date())).\(pathExtension)")
    }
}

/// Records the mirrored screen (HEVC) and the iPhone's audio (AAC) into a .mov file.
/// Frames are re-rendered upright; the size is fixed at the start (later rotations are letterboxed).
final class ScreenRecorder: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "PhoneMirror.recorder")
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput
    private let size: CGSize
    private let start = Date()
    private var audioFormat: CMAudioFormatDescription?
    /// Where the next audio chunk continues seamlessly (seconds since the start).
    private var audioNext: Double?
    private var finished = false
    private var videoFrames = 0
    private static let logger = Logger(subsystem: "PhoneMirror", category: "recorder")

    /// `size`: upright pixel size of the first frame (rounded to even numbers for the encoder).
    init(url: URL, size: CGSize) throws {
        self.url = url
        self.size = CGSize(width: (size.width / 2).rounded() * 2, height: (size.height / 2).rounded() * 2)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(self.size.width),
            AVVideoHeightKey: Int(self.size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoExpectedSourceFrameRateKey: 60],
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(self.size.width),
            kCVPixelBufferHeightKey as String: Int(self.size.height),
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000,
        ])
        audio.expectsMediaDataInRealTime = true
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
    }

    private var now: CMTime { CMTime(seconds: Date().timeIntervalSince(start), preferredTimescale: 600) }

    func append(_ pixelBuffer: CVPixelBuffer, visible: CGSize, orientation: DeviceOrientation) {
        let time = now
        nonisolated(unsafe) let pixelBuffer = pixelBuffer // read-only from here on
        queue.async { [self] in
            guard !finished else { return }
            guard video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
                Self.logger.debug("Frame skipped (ready: \(self.video.isReadyForMoreMediaData), pool: \(self.adaptor.pixelBufferPool != nil), status: \(self.writer.status.rawValue))")
                return
            }
            var output: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return }
            let image = FrameRenderer.upright(pixelBuffer, visible: visible, orientation: orientation)
            // Fit into the recording size (letterbox if the orientation changed meanwhile).
            let scale = min(size.width / image.extent.width, size.height / image.extent.height)
            let fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let placed = fitted.transformed(by: CGAffineTransform(
                translationX: (size.width - fitted.extent.width) / 2, y: (size.height - fitted.extent.height) / 2))
            let canvas = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
            FrameRenderer.context.render(placed.composited(over: canvas), to: output)
            if adaptor.append(output, withPresentationTime: time) {
                videoFrames += 1
            } else {
                Self.logger.error("Frame not appended: \(self.writer.error?.localizedDescription ?? "?", privacy: .public)")
            }
        }
    }

    /// Interleaved Int16 PCM, as delivered by the native transport.
    func append(_ chunk: AudioChunk) {
        let arrival = Date().timeIntervalSince(start)
        queue.async { [self] in
            guard !finished, audio.isReadyForMoreMediaData, chunk.channels > 0 else { return }
            guard let buffer = sampleBuffer(chunk, arrival: arrival) else { return }
            audio.append(buffer)
        }
    }

    private func sampleBuffer(_ chunk: AudioChunk, arrival: Double) -> CMSampleBuffer? {
        let bytesPerFrame = 2 * chunk.channels
        let frames = chunk.pcm.count / bytesPerFrame
        guard frames > 0 else { return nil }
        if audioFormat == nil {
            var description = AudioStreamBasicDescription(
                mSampleRate: chunk.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame),
                mChannelsPerFrame: UInt32(chunk.channels), mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
        }
        guard let audioFormat else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: chunk.pcm.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: chunk.pcm.count,
                                                 flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block
        else { return nil }
        let copied = chunk.pcm.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: chunk.pcm.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        // Chunks follow each other seamlessly; after a pause (the iPhone sends nothing while silent) restart at
        // the arrival time so sound stays in sync with the picture.
        var seconds = audioNext ?? arrival
        if arrival > seconds + 0.2 { seconds = arrival }
        audioNext = seconds + Double(frames) / chunk.sampleRate
        let time = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(chunk.sampleRate))
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: audioFormat,
                                                             sampleCount: frames, presentationTimeStamp: time,
                                                             packetDescriptions: nil, sampleBufferOut: &buffer)
        return buffer
    }

    func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                finished = true
                video.markAsFinished()
                audio.markAsFinished()
                Self.logger.notice("Recording finished: \(self.videoFrames) frames")
                writer.finishWriting {
                    if let error = self.writer.error {
                        Self.logger.error("Recording: \(error.localizedDescription, privacy: .public)")
                    }
                    continuation.resume()
                }
            }
        }
    }
}
