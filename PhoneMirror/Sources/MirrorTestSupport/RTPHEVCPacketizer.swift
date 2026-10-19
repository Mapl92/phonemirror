// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import MirrorCore

/// Minimal RTP packetizer per RFC 7798 – only for testing the depacketizer.
/// Parameter sets go out as an aggregation packet, large NALs as fragmentation units.
public struct RTPHEVCPacketizer {
    public var maxPayload: Int
    public var payloadType: UInt8 = 100
    public var ssrc: UInt32 = 0x1234_5678
    public private(set) var sequenceNumber: UInt16

    public init(maxPayload: Int = 1200, firstSequenceNumber: UInt16 = 65_530) {
        self.maxPayload = maxPayload
        self.sequenceNumber = firstSequenceNumber
    }

    public mutating func packetize(accessUnit: [HEVCNALUnit], timestamp: UInt32) -> [Data] {
        var payloads: [Data] = []
        let parameterSets = accessUnit.filter { HEVCNALType.isParameterSet($0.type) }
        if !parameterSets.isEmpty {
            var aggregation = Data([48 << 1, 1])
            for unit in parameterSets {
                aggregation.append(contentsOf: [UInt8(unit.data.count >> 8), UInt8(unit.data.count & 0xFF)])
                aggregation.append(unit.data)
            }
            payloads.append(aggregation)
        }
        for unit in accessUnit where !HEVCNALType.isParameterSet(unit.type) {
            if unit.data.count <= maxPayload {
                payloads.append(unit.data)
                continue
            }
            let bytes = [UInt8](unit.data)
            let header = [(bytes[0] & 0x81) | (49 << 1), bytes[1]]
            var offset = 2
            while offset < bytes.count {
                let end = min(offset + maxPayload - 3, bytes.count)
                var fuHeader = unit.type
                if offset == 2 { fuHeader |= 0x80 }
                if end == bytes.count { fuHeader |= 0x40 }
                payloads.append(Data(header + [fuHeader] + bytes[offset..<end]))
                offset = end
            }
        }
        return payloads.enumerated().map { index, payload in
            makePacket(payload: payload, timestamp: timestamp, marker: index == payloads.count - 1)
        }
    }

    private mutating func makePacket(payload: Data, timestamp: UInt32, marker: Bool) -> Data {
        var packet = Data([0x90, (marker ? 0x80 : 0) | payloadType]) // V=2, X=1 as on iOS
        packet.append(contentsOf: [UInt8(sequenceNumber >> 8), UInt8(sequenceNumber & 0xFF)])
        packet.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian, Array.init))
        packet.append(contentsOf: withUnsafeBytes(of: ssrc.bigEndian, Array.init))
        packet.append(contentsOf: [0x90, 0x01, 0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF]) // 1 word of header extension
        packet.append(payload)
        sequenceNumber &+= 1
        return packet
    }
}
