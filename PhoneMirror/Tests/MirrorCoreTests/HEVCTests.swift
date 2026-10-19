// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import MirrorCore
import MirrorTestSupport
import Testing
import VideoToolbox

@Suite struct AnnexBTests {
    @Test func splitsThreeAndFourByteStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x40, 0x01, 0xAA, 0, 0, 1, 0x42, 0x01, 0xBB, 0xCC, 0, 0, 0, 1, 0x26, 0x01, 0x80])
        let units = AnnexB.split(stream)
        #expect(units.map(\.type) == [HEVCNALType.vps, HEVCNALType.sps, 19])
        #expect(units[1].data == Data([0x42, 0x01, 0xBB, 0xCC]))
        #expect(units[2].isFirstSliceOfPicture)
    }

    @Test func joinIsInverseOfSplit() {
        let units = [HEVCNALUnit(Data([0x40, 0x01, 1])), HEVCNALUnit(Data([0x26, 0x01, 0x80, 7]))]
        #expect(AnnexB.split(AnnexB.join(units)) == units)
    }

    @Test func assemblerGroupsPicturesWithTheirParameterSets() {
        let vps = HEVCNALUnit(Data([0x40, 0x01, 0]))
        let sps = HEVCNALUnit(Data([0x42, 0x01, 0]))
        let pps = HEVCNALUnit(Data([0x44, 0x01, 0]))
        let idr = HEVCNALUnit(Data([0x26, 0x01, 0x80]))          // IDR_W_RADL, first slice
        let trail = HEVCNALUnit(Data([0x02, 0x01, 0x80]))        // TRAIL_R, first slice
        let trailSecondSlice = HEVCNALUnit(Data([0x02, 0x01, 0x00]))
        let stream = AnnexB.join([vps, sps, pps, idr, trail, trailSecondSlice, trail])
        let units = HEVCAccessUnitAssembler.accessUnits(in: stream)
        #expect(units == [[vps, sps, pps, idr], [trail, trailSecondSlice], [trail]])
    }
}

@Suite struct HEVCPipelineTests {
    /// Small stream: 2 keyframe intervals, so that parameter sets occur repeatedly.
    static let stream: Data = {
        (try? HEVCTestStreamEncoder.encode(width: 320, height: 640, frameCount: 20, framesPerSecond: 30, keyframeInterval: 10)) ?? Data()
    }()

    @Test func encoderProducesKeyframesWithParameterSets() throws {
        let units = HEVCAccessUnitAssembler.accessUnits(in: Self.stream)
        #expect(units.count == 20)
        let first = try #require(units.first)
        #expect(first.prefix(3).map(\.type) == [HEVCNALType.vps, HEVCNALType.sps, HEVCNALType.pps])
        #expect(first.contains { HEVCNALType.isIRAP($0.type) })
        let keyframes = units.filter { $0.contains { HEVCNALType.isIRAP($0.type) } }
        #expect(keyframes.count >= 2)
    }

    @Test func builderWaitsForKeyframe() throws {
        let units = HEVCAccessUnitAssembler.accessUnits(in: Self.stream)
        var builder = HEVCSampleBuilder()
        // Frame 1 is not a keyframe and comes without parameter sets: nothing displayable yet.
        #expect(try builder.makeSample(from: VideoPacket(annexB: AnnexB.join(units[1]), timestamp: 0)) == nil)
        let output = try #require(try builder.makeSample(from: VideoPacket(annexB: AnnexB.join(units[0]), timestamp: 0)))
        #expect(output.isKeyframe)
        #expect(output.formatChanged)
        let dimensions = try #require(builder.dimensions)
        #expect(dimensions.width == 320 && dimensions.height == 640)
    }

    /// End to end: Annex B → CMSampleBuffer → hardware decoder → pixel buffer of the right size.
    @Test func samplesDecodeWithVideoToolbox() throws {
        var builder = HEVCSampleBuilder()
        let samples = try HEVCAccessUnitAssembler.accessUnits(in: Self.stream).enumerated().compactMap { index, unit in
            try builder.makeSample(from: VideoPacket(annexB: AnnexB.join(unit), timestamp: Double(index) / 30))
        }
        #expect(samples.count == 20)
        #expect(samples.filter(\.formatChanged).count == 1)

        let format = try #require(builder.formatDescription)
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        #expect(status == noErr)
        let decoder = try #require(session)
        defer { VTDecompressionSessionInvalidate(decoder) }

        let results = DecodeResults()
        for sample in samples {
            let decodeStatus = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample.sampleBuffer, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
                results.record(status: status, imageBuffer: imageBuffer)
            }
            #expect(decodeStatus == noErr)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)

        let summary = results.summary
        #expect(summary.errors.isEmpty)
        #expect(summary.frames == 20)
        #expect(summary.sizes == [CGSize(width: 320, height: 640)])
    }
}

private final class DecodeResults: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var errors: [OSStatus] = []
    private var sizes: Set<CGSize> = []

    func record(status: OSStatus, imageBuffer: CVImageBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        guard status == noErr, let imageBuffer else {
            errors.append(status)
            return
        }
        frames += 1
        sizes.insert(CGSize(width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer)))
    }

    var summary: (frames: Int, errors: [OSStatus], sizes: Set<CGSize>) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, errors, sizes)
    }
}

@Suite struct FileReplayTests {
    @Test func replayDeliversScreenThenVideoAndRecordsInput() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString).h265")
        try HEVCPipelineTests.stream.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let transport = FileReplayTransport(fileURL: url, screen: .iPhone15, framesPerSecond: 240)
        let session = try await transport.connect()
        var iterator = session.events.makeAsyncIterator()
        #expect(await iterator.next() == .screenChanged(.iPhone15))
        guard case .video(let packet) = await iterator.next() else {
            Issue.record("Erwartet: Videopaket")
            return
        }
        #expect(AnnexB.split(packet.annexB).first?.type == HEVCNALType.vps)

        try await session.send(.touch(.began, TouchPoint(x: 1, y: 2)))
        let replay = try #require(session as? FileReplaySession)
        #expect(replay.receivedInputs == [.touch(.began, TouchPoint(x: 1, y: 2))])
        await session.close()
    }
}
