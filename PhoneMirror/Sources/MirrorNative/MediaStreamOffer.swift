// SPDX-License-Identifier: GPL-3.0-or-later
// AVConference offer for `mediastreamstart`, recreated after pymobiledevice3
// (remote/core_device/media_stream_offer.py, GPL-3.0-or-later).
import CZlib
import Foundation

/// Builds the `negotiatorOffer` (binary property list with zlib-compressed protobuf “MediaBlob”).
public enum MediaStreamOffer {
    public static let decoderName = "Viceroy 1.7.0"
    public static let modeVideo = 5
    public static let modeAudio = 6
    /// According to pymobiledevice3, `VRAE:0` (no resolution adaptation) leads to dropped frames – leave it out.
    public static let defaultFeatures = "FLS;SW:1;"
    static let resEntryCodecCapID: UInt64 = 50_115
    static let capturedVideoTimestamp: UInt64 = 17_137_042_128_614_416_384
    static let capturedAudioTimestamp: UInt64 = 17_137_179_377_605_574_656

    typealias Tier = (kind: UInt64, bps: UInt64, buffer: UInt64?)
    static let videoTiers: [Tier] = [
        (4074, 0, 16384), (0, 75_000_000, 524_288), (0, 40_000_000, 12288), (16, 4100, nil),
        (0, 20_000_000, 98304), (4, 6500, nil), (0, 6_000_000, 131_072), (0, 100_000_000, 1_048_576),
        (0, 60_000_000, 262_144), (1, 299, nil),
    ]
    static let audioTiers: [Tier] = [
        (4074, 0, 16384), (1, 299, nil), (0, 60_000_000, 262_144), (4, 6500, nil), (0, 20_000_000, 98304),
        (0, 100_000_000, 1_048_576), (0, 40_000_000, 12288), (0, 6_000_000, 131_072), (16, 4100, nil),
        (0, 75_000_000, 524_288),
    ]

    public static func videoOffer(callID: String, sessionID: UInt32) throws -> Data {
        try offer(mode: modeVideo, blob: videoBlob(sessionID: sessionID), callID: callID, hostModel: "Mac15,9")
    }

    public static func audioOffer(callID: String, sessionID: UInt32) throws -> Data {
        try offer(mode: modeAudio, blob: audioBlob(sessionID: sessionID), callID: callID, hostModel: "Mac16,11")
    }

    static func offer(mode: Int, blob: Data, callID: String, hostModel: String) throws -> Data {
        let endpointInfo = Protobuf.varint(1, 0) + Protobuf.varint(2, 1)
            + Protobuf.string(3, hostModel) + Protobuf.string(4, "2205.3.1") + Protobuf.string(5, "25F80")
        let plist: [String: Any] = [
            "avcMediaStreamOptionRemoteEndpointInfo": endpointInfo,
            "avcMediaStreamNegotiatorMode": mode,
            "avcMediaStreamNegotiatorMediaBlob": try zlibCompress(blob),
            "avcMediaStreamOptionCallID": callID,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    public static func videoBlob(
        sessionID: UInt32,
        allowRTCPFB: Bool = false,
        ltrpEnabled: Bool = false,
        fecEnabled: Bool = true,
        hevcFeatures: String = defaultFeatures,
        avcFeatures: String = defaultFeatures
    ) -> Data {
        var settings = Protobuf.tag(1, 0) + Protobuf.paddedVarint(UInt64(sessionID), width: 5)
        settings += Protobuf.varint(2, allowRTCPFB ? 1 : 0)
        settings += Protobuf.bytes(3, codecBank(payloadType: 123, features: hevcFeatures, f4: 1, pairs: 4))
        settings += Protobuf.bytes(3, codecBank(payloadType: 100, features: avcFeatures, f4: 14, pairs: 2))
        settings += Protobuf.varint(7, ltrpEnabled ? 1 : 0)
        settings += Protobuf.varint(8, 63)
        if fecEnabled { settings += Protobuf.varint(10, 1) }
        settings += Protobuf.varint(12, 1)
        return topLevel(settingsField: 5, settings: settings, timestamp: capturedVideoTimestamp, tiers: videoTiers)
    }

    public static func audioBlob(sessionID: UInt32) -> Data {
        var settings = Protobuf.tag(1, 0) + Protobuf.paddedVarint(UInt64(sessionID), width: 5)
        settings += Protobuf.varint(2, 0) + Protobuf.varint(3, 0) + Protobuf.varint(4, 24191)
        settings += Protobuf.varint(5, 0) + Protobuf.varint(6, 0)
        return topLevel(settingsField: 3, settings: settings, timestamp: capturedAudioTimestamp, tiers: audioTiers)
    }

    static func codecBank(payloadType: UInt64, features: String, f4: UInt64, pairs: Int) -> Data {
        var body = Protobuf.varint(1, payloadType)
        for index in 0..<pairs {
            let entry = Protobuf.varint(1, 1) + Protobuf.varint(2, UInt64(1 + index % 2))
                + Protobuf.varint(3, resEntryCodecCapID) + Protobuf.varint(4, 0)
            body += Protobuf.bytes(2, entry)
        }
        return body + Protobuf.string(3, features) + Protobuf.varint(4, f4)
    }

    static func topLevel(settingsField: Int, settings: Data, timestamp: UInt64, tiers: [Tier]) -> Data {
        var out = Protobuf.varint(1, 1) + Protobuf.varint(2, 1) + Protobuf.bytes(settingsField, settings)
        out += Protobuf.string(6, decoderName) + Protobuf.varint(8, 0)
        for tier in tiers {
            var body = Protobuf.varint(1, tier.kind) + Protobuf.varint(2, tier.bps)
            if let buffer = tier.buffer { body += Protobuf.varint(3, buffer) }
            out += Protobuf.bytes(9, body)
        }
        out += Protobuf.varint(13, timestamp) + Protobuf.varint(14, 2) + Protobuf.varint(16, 0) + Protobuf.varint(18, 1)
        return out
    }

    /// zlib format, level 9 – like Python's `zlib.compress(…, 9)`; the device rejects other levels.
    static func zlibCompress(_ data: Data) throws -> Data {
        var destinationLength = compressBound(uLong(data.count))
        var destination = [UInt8](repeating: 0, count: Int(destinationLength))
        let status = data.withUnsafeBytes { source in
            compress2(&destination, &destinationLength, source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), 9)
        }
        guard status == Z_OK else { throw RemoteXPCError.protocolError("zlib \(status)") }
        return Data(destination.prefix(Int(destinationLength)))
    }
}

/// Minimal protobuf encoder.
enum Protobuf {
    static func rawVarint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    /// Varint padded to exactly `width` bytes (redundant continuation bytes) – as in Apple's captures.
    static func paddedVarint(_ value: UInt64, width: Int) -> Data {
        var raw = [UInt8](rawVarint(value))
        if raw.count > width { return paddedVarint(value & ((1 << (7 * UInt64(width))) - 1), width: width) }
        while raw.count < width {
            raw[raw.count - 1] |= 0x80
            raw.append(0)
        }
        return Data(raw)
    }

    static func tag(_ field: Int, _ wire: Int) -> Data { rawVarint(UInt64(field << 3 | wire)) }
    static func varint(_ field: Int, _ value: UInt64) -> Data { tag(field, 0) + rawVarint(value) }
    static func bytes(_ field: Int, _ value: Data) -> Data { tag(field, 2) + rawVarint(UInt64(value.count)) + value }
    static func string(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
}
