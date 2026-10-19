// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation

public enum HEVCSampleBuilderError: Error, Equatable {
    case formatDescription(OSStatus)
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)
}

/// Wandelt Annex-B-Access-Units in `CMSampleBuffer` (4-Byte-Längenpräfix, hvcC-Formatbeschreibung),
/// die `AVSampleBufferDisplayLayer` bzw. `VTDecompressionSession` direkt in Hardware dekodieren.
public struct HEVCSampleBuilder {
    public private(set) var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [UInt8: Data] = [:]
    private var hasSeenIRAP = false

    public init() {}

    /// Abmessungen laut aktuellem SPS, sobald bekannt.
    public var dimensions: CMVideoDimensions? {
        formatDescription.map(CMVideoFormatDescriptionGetDimensions)
    }

    public struct Output {
        public var sampleBuffer: CMSampleBuffer
        public var isKeyframe: Bool
        /// `true`, wenn sich mit diesem Bild die Formatbeschreibung geändert hat (z. B. Rotation).
        public var formatChanged: Bool
    }

    /// Liefert `nil`, solange noch kein IRAP-Bild mit gültigen Parameter-Sets gesehen wurde
    /// oder die Access Unit keine Bilddaten enthält.
    public mutating func makeSample(from packet: VideoPacket) throws -> Output? {
        let units = AnnexB.split(packet.annexB)
        var formatChanged = false

        let newSets = units.filter { HEVCNALType.isParameterSet($0.type) }
        if !newSets.isEmpty {
            var updated = parameterSets
            for unit in newSets { updated[unit.type] = unit.data }
            if updated != parameterSets || formatDescription == nil {
                parameterSets = updated
                if let description = try makeFormatDescription() {
                    formatDescription = description
                    formatChanged = true
                }
            }
        }

        let slices = units.filter { HEVCNALType.isVCL($0.type) || $0.type == HEVCNALType.prefixSEI }
        guard let formatDescription, slices.contains(where: { HEVCNALType.isVCL($0.type) }) else { return nil }

        let isKeyframe = slices.contains { HEVCNALType.isIRAP($0.type) }
        if isKeyframe { hasSeenIRAP = true }
        guard hasSeenIRAP else { return nil }

        let sample = try Self.makeSampleBuffer(
            slices: slices,
            formatDescription: formatDescription,
            timestamp: packet.timestamp,
            isKeyframe: isKeyframe
        )
        return Output(sampleBuffer: sample, isKeyframe: isKeyframe, formatChanged: formatChanged)
    }

    private func makeFormatDescription() throws -> CMVideoFormatDescription? {
        guard let vps = parameterSets[HEVCNALType.vps],
              let sps = parameterSets[HEVCNALType.sps],
              let pps = parameterSets[HEVCNALType.pps]
        else { return nil }

        let sets = [vps, sps, pps].map { [UInt8]($0) }
        let pointers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            pointer.initialize(from: set, count: set.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }

        var description: CMFormatDescription?
        let status = pointers.map { UnsafePointer($0) }.withUnsafeBufferPointer { pointerBuffer in
            sets.map(\.count).withUnsafeBufferPointer { sizeBuffer in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointerBuffer.baseAddress!,
                    parameterSetSizes: sizeBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { throw HEVCSampleBuilderError.formatDescription(status) }
        return description
    }

    private static func makeSampleBuffer(
        slices: [HEVCNALUnit],
        formatDescription: CMVideoFormatDescription,
        timestamp: TimeInterval,
        isKeyframe: Bool
    ) throws -> CMSampleBuffer {
        var payload = Data()
        for slice in slices {
            var length = UInt32(slice.data.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(slice.data)
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { throw HEVCSampleBuilderError.blockBuffer(status) }
        status = payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard status == noErr else { throw HEVCSampleBuilderError.blockBuffer(status) }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: 90_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw HEVCSampleBuilderError.sampleBuffer(status) }

        // Live-Bild: sofort anzeigen statt auf eine Timebase zu warten.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(isKeyframe ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}
