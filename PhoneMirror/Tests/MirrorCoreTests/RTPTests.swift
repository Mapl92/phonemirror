// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import MirrorCore
import MirrorTestSupport
import Testing

@Suite struct RTPHEVCDepacketizerTests {
    static let accessUnits = HEVCAccessUnitAssembler.accessUnits(in: HEVCPipelineTests.stream)

    private func packetizeAll(maxPayload: Int = 1200) -> [Data] {
        var packetizer = RTPHEVCPacketizer(maxPayload: maxPayload)
        return Self.accessUnits.enumerated().flatMap { index, unit in
            packetizer.packetize(accessUnit: unit, timestamp: UInt32(index * 3000))
        }
    }

    @Test func roundTripRestoresEveryAccessUnit() {
        var depacketizer = RTPHEVCDepacketizer()
        let frames = packetizeAll().compactMap { depacketizer.push($0) }
        #expect(frames.count == Self.accessUnits.count)
        #expect(frames.map { AnnexB.split($0.annexB) } == Self.accessUnits)
        #expect(frames[1].timestamp == 3000.0 / RTPHEVCDepacketizer.iOSDisplayClockRate)
        #expect(depacketizer.droppedFrames == 0)
    }

    @Test func smallPayloadsForceManyFragments() {
        var depacketizer = RTPHEVCDepacketizer()
        let packets = packetizeAll(maxPayload: 100)
        #expect(packets.count > Self.accessUnits.count * 3)
        let frames = packets.compactMap { depacketizer.push($0) }
        #expect(frames.map { AnnexB.split($0.annexB) } == Self.accessUnits)
    }

    @Test func lostPacketDropsOnlyThatFrame() {
        var packets = packetizeAll(maxPayload: 300)
        // Ein Fragment aus der Mitte des dritten Bildes entfernen.
        var packetizer = RTPHEVCPacketizer(maxPayload: 300)
        let before = (0..<2).reduce(0) { sum, index in
            sum + packetizer.packetize(accessUnit: Self.accessUnits[index], timestamp: UInt32(index * 3000)).count
        }
        packets.remove(at: before + 1)
        var depacketizer = RTPHEVCDepacketizer()
        let frames = packets.compactMap { depacketizer.push($0) }
        #expect(depacketizer.droppedFrames == 1)
        #expect(frames.count == Self.accessUnits.count - 1)
    }

    /// Verliert ein Bild sein letztes Paket (mit Marker), darf nur dieses Bild fehlen – nicht das nächste.
    @Test func lostFinalPacketDropsOnlyThatFrame() throws {
        var packetizer = RTPHEVCPacketizer(maxPayload: 300)
        var perFrame = Self.accessUnits.enumerated().map { index, unit in
            packetizer.packetize(accessUnit: unit, timestamp: UInt32(index * 3000))
        }
        let victim = try #require(perFrame.indices.dropFirst().first { perFrame[$0].count >= 2 })
        perFrame[victim].removeLast()
        var depacketizer = RTPHEVCDepacketizer()
        let frames = perFrame.joined().compactMap { depacketizer.push($0) }
        #expect(depacketizer.droppedFrames == 1)
        var expected = Self.accessUnits
        expected.remove(at: victim)
        // Das letzte Bild wird erst durch ein Folgepaket abgeschlossen; hier fehlt keins, weil es seinen Marker hat.
        #expect(frames.map { AnnexB.split($0.annexB) } == expected)
    }

    @Test func rtcpIsIgnored() {
        // Sender Report (PT 200) im selben Strom.
        let senderReport = Data([0x80, 200, 0x00, 0x06] + [UInt8](repeating: 0, count: 24))
        #expect(RTPPacket.isRTCP(senderReport))
        var depacketizer = RTPHEVCDepacketizer()
        #expect(depacketizer.push(senderReport) == nil)
    }

    @Test func dumpFileFramingRoundTrips() {
        let packets = packetizeAll()
        var file = Data()
        for packet in packets {
            file.append(contentsOf: withUnsafeBytes(of: UInt32(packet.count).bigEndian, Array.init))
            file.append(packet)
        }
        #expect(RTPDumpFile.packets(in: file) == packets)
    }
}
