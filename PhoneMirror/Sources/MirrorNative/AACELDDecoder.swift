// SPDX-License-Identifier: GPL-3.0-or-later
// AAC-ELD decoding of the iPhone audio, after pymobiledevice3 (remote/core_device/aac_eld.py, GPL-3.0-or-later).
import AudioToolbox
import Foundation

/// Decodes AAC-ELD (48 kHz, stereo, 480 samples per packet) to Int16 PCM via AudioConverter.
/// Not thread-safe – use from a single receive thread.
public final class AACELDDecoder: @unchecked Sendable {
    static let magicCookie: [UInt8] = [0xF8, 0xE6, 0x40, 0x00] // AudioSpecificConfig
    static let framesPerPacket: UInt32 = 480

    private var converter: AudioConverterRef?
    /// Packet data for the input callback; owned by the decoder as long as the converter points to it.
    fileprivate var packet: UnsafeMutableRawPointer?
    fileprivate var packetSize = 0
    fileprivate var packetDelivered = false
    fileprivate var description = AudioStreamPacketDescription()

    public init() throws {
        var source = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: Self.framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        var destination = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
        )
        var converter: AudioConverterRef?
        var status = AudioConverterNew(&source, &destination, &converter)
        _ = status
        guard status == noErr, let converter else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        // Like pymobiledevice3: the result is deliberately ignored – AudioToolbox reports `!dat` here,
        // but decodes the ELD packets correctly anyway.
        var cookie = Self.magicCookie
        status = AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), &cookie)
        self.converter = converter
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        packet?.deallocate()
    }

    /// One AAC-ELD packet (RTP payload) → interleaved Int16 PCM (48 kHz, stereo).
    public func decode(_ data: Data) throws -> Data {
        guard let converter, !data.isEmpty else { return Data() }
        packet?.deallocate()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 16)
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        packet = buffer
        packetSize = data.count
        packetDelivered = false

        var frames = Self.framesPerPacket
        let output = UnsafeMutableRawPointer.allocate(byteCount: Int(frames) * 4, alignment: 16)
        defer { output.deallocate() }
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: frames * 4, mData: output)
        )
        let status = AudioConverterFillComplexBuffer(
            converter, aacInputProc, Unmanaged.passUnretained(self).toOpaque(), &frames, &bufferList, nil
        )
        // `noMoreData` is our own “packet used up” signal, not an error.
        guard status == noErr || status == noMoreData else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return Data(bytes: output, count: Int(frames) * 4)
    }
}

let noMoreData: OSStatus = 0x6E6F_6D6F // 'nomo'

private func aacInputProc(
    _ converter: AudioConverterRef,
    _ ioPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    let decoder = Unmanaged<AACELDDecoder>.fromOpaque(userData!).takeUnretainedValue()
    guard !decoder.packetDelivered, let packet = decoder.packet else {
        ioPackets.pointee = 0
        return noMoreData
    }
    decoder.packetDelivered = true
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mData = packet
    ioData.pointee.mBuffers.mDataByteSize = UInt32(decoder.packetSize)
    ioData.pointee.mBuffers.mNumberChannels = 2
    decoder.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(decoder.packetSize))
    if let outDescription {
        withUnsafeMutablePointer(to: &decoder.description) { outDescription.pointee = $0 }
    }
    ioPackets.pointee = 1
    return noErr
}
