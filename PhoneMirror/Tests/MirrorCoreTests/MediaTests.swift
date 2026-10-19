// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo
import Foundation
import MirrorCore
import MirrorTestSupport
import Testing

@Suite struct ContentRectDetectorTests {
    /// BGRA image: content (dark with bright spots) in the `content` area, the rest in `padding` gray.
    private func image(width: Int, height: Int, content: CGSize, padding: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let inside = Double(x) < content.width && Double(y) < content.height
                let value: UInt8 = inside ? ((x / 7 + y / 5) % 3 == 0 ? 230 : 20) : padding
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value; bytes[i + 3] = 255
            }
        }
        return bytes
    }

    private func detect(_ bytes: [UInt8], _ width: Int, _ height: Int) -> CGSize? {
        bytes.withUnsafeBytes {
            ContentRectDetector.collapsedContentSize(bytes: $0.baseAddress!, width: width, height: height, bytesPerRow: width * 4)
        }
    }

    @Test func detectsGrayCollapsePadding() throws {
        let size = try #require(detect(image(width: 296, height: 644, content: CGSize(width: 207, height: 451), padding: 128), 296, 644))
        #expect(abs(size.width - 207) <= 3)
        #expect(abs(size.height - 451) <= 3)
    }

    @Test func blackAlignmentPaddingIsNotACollapse() {
        // Normal case: 1184×2576 with a black margin on the right/bottom (scaled down here).
        #expect(detect(image(width: 296, height: 644, content: CGSize(width: 295, height: 639), padding: 0), 296, 644) == nil)
    }

    @Test func fullFrameContentIsNotACollapse() {
        #expect(detect(image(width: 200, height: 400, content: CGSize(width: 200, height: 400), padding: 128), 200, 400) == nil)
    }

    @Test func visibleFractionUsesScreenOrCollapse() {
        let coded = CGSize(width: 1184, height: 2576)
        let normal = ContentRectDetector.visibleFraction(codedPixels: coded, screenPixels: CGSize(width: 1179, height: 2556), collapsed: nil)
        #expect(abs(normal.width - 1179.0 / 1184) < 1e-9 && abs(normal.height - 2556.0 / 2576) < 1e-9)
        let collapsed = ContentRectDetector.visibleFraction(codedPixels: coded, screenPixels: CGSize(width: 1179, height: 2556), collapsed: CGSize(width: 592, height: 1288))
        #expect(collapsed == CGSize(width: 0.5, height: 0.5))
    }
}

@Suite struct VideoDecoderTests {
    /// Real pipeline: test encoder (with collapsed frames) → SampleBuilder → VideoDecoder → detection.
    @Test func decodesToBGRAAndDetectsCollapsedFrames() async throws {
        let stream = try HEVCTestStreamEncoder.encode(
            width: 320, height: 640, frameCount: 20, framesPerSecond: 30, keyframeInterval: 10,
            collapsedFrames: { $0 >= 10 }
        )
        let results = DetectionResults()
        let decoder = VideoDecoder { pixelBuffer in
            results.record(
                format: CVPixelBufferGetPixelFormatType(pixelBuffer),
                size: CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)),
                collapse: ContentRectDetector.collapsedContentSize(in: pixelBuffer),
                hasSurface: CVPixelBufferGetIOSurface(pixelBuffer) != nil
            )
        }
        var builder = HEVCSampleBuilder()
        for (index, unit) in HEVCAccessUnitAssembler.accessUnits(in: stream).enumerated() {
            if let output = try builder.makeSample(from: VideoPacket(annexB: AnnexB.join(unit), timestamp: Double(index) / 30)) {
                try decoder.decode(output.sampleBuffer)
            }
        }
        decoder.reset() // waits for pending frames
        let frames = results.frames
        #expect(frames.count == 20)
        #expect(frames.allSatisfy { $0.format == kCVPixelFormatType_32BGRA && $0.hasSurface })
        #expect(frames.allSatisfy { $0.size == CGSize(width: 320, height: 640) })
        #expect(frames.prefix(10).allSatisfy { $0.collapse == nil })
        let collapsed = frames.suffix(10).compactMap(\.collapse)
        #expect(collapsed.count == 10)
        for size in collapsed {
            #expect(abs(size.width - 320 * HEVCTestStreamEncoder.collapseScale) <= 8)
            #expect(abs(size.height - 640 * HEVCTestStreamEncoder.collapseScale) <= 8)
        }
    }
}

private final class DetectionResults: @unchecked Sendable {
    struct Frame { var format: OSType; var size: CGSize; var collapse: CGSize?; var hasSurface: Bool }
    private let lock = NSLock()
    private var stored: [Frame] = []

    func record(format: OSType, size: CGSize, collapse: CGSize?, hasSurface: Bool) {
        lock.lock(); defer { lock.unlock() }
        stored.append(Frame(format: format, size: size, collapse: collapse, hasSurface: hasSurface))
    }

    var frames: [Frame] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

@Suite struct ServeWebAudioAndClipboardTests {
    @Test func audioChunksSurviveSplitDelivery() {
        let pcm = Data((0..<1920).map { UInt8($0 % 251) })
        var message = Data(withUnsafeBytes(of: UInt32(pcm.count).bigEndian, Array.init))
        message.append(pcm)
        let stream = message + message
        var parser = ServeWebAudioParser()
        var chunks: [AudioChunk] = []
        var offset = 0
        for size in [3, 100, 1500, 2000, 5000] where offset < stream.count {
            let end = min(offset + size, stream.count)
            chunks += parser.append(stream[offset..<end])
            offset = end
        }
        chunks += parser.append(stream[offset...])
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.pcm == pcm && $0.sampleRate == 48_000 && $0.channels == 2 })
    }

    @Test func clipboardEventDecodes() throws {
        let json = #"{"seq": 4, "text": "Hello", "image": null}"#
        let event = try JSONDecoder().decode(ServeWebClipboardEvent.self, from: Data(json.utf8))
        #expect(event.seq == 4 && event.text == "Hello" && event.image == nil)
        let image = try JSONDecoder().decode(ServeWebClipboardEvent.self, from: Data(#"{"seq": 5, "text": null, "image": {"type": "image/png", "size": 1234}}"#.utf8))
        #expect(image.image?.size == 1234 && image.text == nil)
    }
}
