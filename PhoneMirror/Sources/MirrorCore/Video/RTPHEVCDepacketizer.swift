// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Kopf eines RTP-Pakets (RFC 3550) samt Nutzdaten ohne CSRC, Header-Extension und Padding.
public struct RTPPacket: Sendable, Equatable {
    public var payloadType: UInt8
    public var marker: Bool
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var payload: Data

    /// RTCP im selben Port (rtcp-mux, RFC 5761): Pakettypen 200–204 erscheinen als PT 72–76 mit gesetztem Marker-Bit.
    public static func isRTCP(_ packet: Data) -> Bool {
        guard packet.count >= 2 else { return false }
        return (200...204).contains(packet[packet.startIndex + 1])
    }

    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }
        let hasPadding = bytes[0] & 0x20 != 0
        let hasExtension = bytes[0] & 0x10 != 0
        let csrcCount = Int(bytes[0] & 0x0F)
        var headerLength = 12 + 4 * csrcCount
        if hasExtension {
            guard bytes.count >= headerLength + 4 else { return nil }
            let extensionWords = Int(bytes[headerLength + 2]) << 8 | Int(bytes[headerLength + 3])
            headerLength += 4 + 4 * extensionWords
        }
        var end = bytes.count
        if hasPadding, let padding = bytes.last { end -= Int(padding) }
        guard end > headerLength else { return nil }

        marker = bytes[1] & 0x80 != 0
        payloadType = bytes[1] & 0x7F
        sequenceNumber = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        ssrc = UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11])
        payload = Data(bytes[headerLength..<end])
    }
}

/// Setzt HEVC-RTP-Pakete (RFC 7798) wieder zu Annex-B-Access-Units zusammen.
/// Unterstützt Einzel-NALs, Aggregation Packets (Typ 48) und Fragmentation Units (Typ 49), ohne DONL.
/// Bei Paketverlust wird das betroffene Bild verworfen.
public struct RTPHEVCDepacketizer: Sendable {
    /// iOS 27 (`dtremotedisplayd`) taktet Video-RTP mit 24 kHz: 400 Ticks pro Bild bei 60 fps (gemessen).
    public static let iOSDisplayClockRate = 24_000.0

    public var clockRate: Double
    public private(set) var droppedFrames = 0
    private var units: [HEVCNALUnit] = []
    private var fragment: Data?
    private var currentTimestamp: UInt32?
    private var expectedSequence: UInt16?
    private var frameCorrupted = false
    private var firstTimestamp: UInt32?

    public init(clockRate: Double = Self.iOSDisplayClockRate) {
        self.clockRate = clockRate
    }

    /// Verarbeitet ein rohes RTP-Paket. Liefert ein fertiges Bild, sobald das Marker-Bit oder
    /// ein neuer Zeitstempel das vorige abschließt.
    public mutating func push(_ data: Data) -> VideoPacket? {
        guard !RTPPacket.isRTCP(data), let packet = RTPPacket(data) else { return nil }
        var completed: VideoPacket?
        let hasGap = expectedSequence.map { packet.sequenceNumber != $0 } ?? false
        let frameOpen = !units.isEmpty || fragment != nil

        if let current = currentTimestamp, current != packet.timestamp {
            // Neues Bild ohne Marker am alten: Bei einer Lücke fehlt dem alten Bild sein Ende.
            // Ein verlorener Anfang des neuen Bildes fällt in `consume` auf (Fragment ohne Start).
            if frameOpen {
                if hasGap { frameCorrupted = true }
                completed = finishFrame()
            } else if hasGap {
                frameCorrupted = true // altes Bild war vollständig – die Lücke gehört zum neuen
            }
        } else if hasGap {
            frameCorrupted = true
        }
        expectedSequence = packet.sequenceNumber &+ 1
        currentTimestamp = packet.timestamp

        consume(packet.payload)

        if packet.marker {
            completed = finishFrame() ?? completed
        }
        return completed
    }

    private mutating func consume(_ payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 else { return }
        let type = (bytes[0] >> 1) & 0x3F
        switch type {
        case 48: // Aggregation Packet: [2-Byte-Länge][NAL] …
            var offset = 2
            while offset + 2 <= bytes.count {
                let size = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard size > 0, offset + size <= bytes.count else {
                    frameCorrupted = true
                    return
                }
                units.append(HEVCNALUnit(Data(bytes[offset..<offset + size])))
                offset += size
            }
        case 49: // Fragmentation Unit: Payload-Header (2) + FU-Header (1) + Fragment
            guard bytes.count >= 3 else { return }
            let fuHeader = bytes[2]
            let isStart = fuHeader & 0x80 != 0
            let isEnd = fuHeader & 0x40 != 0
            if isStart {
                // Ursprünglichen NAL-Header aus Payload-Header und FU-Typ wiederherstellen.
                let nalType = fuHeader & 0x3F
                let header0 = (bytes[0] & 0x81) | (nalType << 1)
                fragment = Data([header0, bytes[1]]) + Data(bytes[3...])
            } else if fragment != nil {
                fragment?.append(contentsOf: bytes[3...])
            } else {
                frameCorrupted = true // Fortsetzung ohne Anfang (Verlust)
            }
            if isEnd, let complete = fragment {
                units.append(HEVCNALUnit(Self.strippingDisplayServiceTrailer(complete)))
                fragment = nil
            }
        case 50: // PACI – wird von iOS nicht genutzt
            break
        default:
            units.append(HEVCNALUnit(Self.strippingDisplayServiceTrailer(payload)))
        }
    }

    /// `dtremotedisplayd` hängt an jede Slice-NAL einen festen 14-Byte-Anhang, der nicht zum HEVC-Bitstrom gehört.
    /// Apples Empfänger (avconferenced) entfernt ihn vor dem Dekodieren (Befund aus pymobiledevice3).
    public static let displayServiceTrailer = Data([0x04, 0xF0, 0x0A, 0xC0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x04, 0xEC, 0x0A, 0xB0, 0x03])

    static func strippingDisplayServiceTrailer(_ nal: Data) -> Data {
        guard nal.count > displayServiceTrailer.count, nal.suffix(displayServiceTrailer.count) == displayServiceTrailer else { return nal }
        return nal.dropLast(displayServiceTrailer.count)
    }

    private mutating func finishFrame() -> VideoPacket? {
        defer {
            units = []
            fragment = nil
            frameCorrupted = false
        }
        // Unvollständiges Fragment = Ende des Bildes verloren.
        if frameCorrupted || fragment != nil {
            if !units.isEmpty || fragment != nil { droppedFrames += 1 }
            return nil
        }
        guard !units.isEmpty else { return nil }
        let timestamp = currentTimestamp ?? 0
        let first = firstTimestamp ?? timestamp
        firstTimestamp = first
        let seconds = Double(timestamp &- first) / clockRate
        return VideoPacket(annexB: AnnexB.join(units), timestamp: seconds)
    }
}

/// Liest das Mitschnittformat von `pymobiledevice3 … start-video-stream`: wiederholt [4-Byte-Länge BE][RTP-Paket].
public enum RTPDumpFile {
    public static func packets(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var packets: [Data] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard offset + length <= bytes.count else { break }
            packets.append(Data(bytes[offset..<offset + length]))
            offset += length
        }
        return packets
    }
}
