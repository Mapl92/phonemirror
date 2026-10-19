// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import MirrorCore
import MirrorTestSupport
import Testing

@Suite struct ServeWebStreamParserTests {
    private func message(type: UInt8, nals: [Data]) -> Data {
        var accessUnit = Data()
        for nal in nals {
            accessUnit.append(contentsOf: withUnsafeBytes(of: UInt32(nal.count).bigEndian, Array.init))
            accessUnit.append(nal)
        }
        var message = Data(withUnsafeBytes(of: UInt32(accessUnit.count + 1).bigEndian, Array.init))
        message.append(type)
        message.append(accessUnit)
        return message
    }

    let vps = Data([0x40, 0x01, 0x0C])
    let idr = Data([0x26, 0x01, 0x80, 0x55])
    let trail = Data([0x02, 0x01, 0x80, 0x66])

    @Test func convertsLengthPrefixedToAnnexB() {
        var parser = ServeWebStreamParser()
        let packets = parser.append(message(type: 0, nals: [vps, idr]) + message(type: 1, nals: [trail]))
        #expect(packets.count == 2)
        #expect(AnnexB.split(packets[0].annexB).map(\.data) == [vps, idr])
        #expect(AnnexB.split(packets[1].annexB).map(\.data) == [trail])
        #expect(packets.allSatisfy { !$0.resetDecoder })
        #expect(packets[1].timestamp > packets[0].timestamp)
    }

    @Test func handlesArbitraryChunkBoundaries() {
        let stream = message(type: 2, nals: [vps, idr]) + message(type: 1, nals: [trail]) + message(type: 1, nals: [trail])
        var parser = ServeWebStreamParser()
        var packets: [VideoPacket] = []
        for byte in stream { packets += parser.append(Data([byte])) }
        #expect(packets.count == 3)
        #expect(packets[0].resetDecoder)
        #expect(AnnexB.split(packets[2].annexB).map(\.data) == [trail])
    }

    @Test func skipsMalformedAccessUnits() {
        // Längenangabe der NAL größer als die Nachricht – Nachricht verwerfen, Strom weiterlesen.
        var broken = Data([0, 0, 0, 6, 1, 0, 0, 0, 99, 0x02])
        broken.append(message(type: 1, nals: [trail]))
        var parser = ServeWebStreamParser()
        let packets = parser.append(broken)
        #expect(packets.count == 1)
        #expect(AnnexB.split(packets[0].annexB).map(\.data) == [trail])
    }
}

@Suite struct ServeWebInputEncoderTests {
    var encoder = ServeWebInputEncoder(screen: .iPhone15)

    private func touch(_ type: String, _ x: Int, _ y: Int) -> ServeWebRequest {
        ServeWebRequest(path: "/touch", json: ["type": .string(type), "x": .int(x), "y": .int(y)])
    }

    @Test mutating func touchPhasesMapToContactAndRelease() {
        #expect(encoder.requests(for: .touch(.began, TouchPoint(x: 100, y: 200))) == [touch("contact", 100, 200)])
        #expect(encoder.requests(for: .touch(.moved, TouchPoint(x: 150, y: 250))) == [touch("contact", 150, 250)])
        #expect(encoder.requests(for: .touch(.ended, TouchPoint(x: 150, y: 250))) == [touch("release", 150, 250)])
    }

    @Test mutating func keysAreSentAsHeldSet() {
        let shift: UInt16 = 0xE1, a: UInt16 = 0x04
        #expect(encoder.requests(for: .key(usage: shift, isDown: true)).first?.json["usages"] == .ints([0xE1]))
        #expect(encoder.requests(for: .key(usage: a, isDown: true)).first?.json["usages"] == .ints([0xE1, 0x04]))
        #expect(encoder.requests(for: .key(usage: a, isDown: true)).isEmpty) // doppeltes Down ignorieren
        #expect(encoder.requests(for: .key(usage: shift, isDown: false)).first?.json["usages"] == .ints([0x04]))
        #expect(encoder.requests(for: .key(usage: a, isDown: false)).first?.json["usages"] == .ints([]))
        #expect(encoder.heldKeys.isEmpty)
    }

    @Test mutating func scrollBecomesDragUntilEnded() {
        let start = TouchPoint(x: 32768, y: 32768)
        // 85,2 Punkte = 10 % der Höhe (852 pt) → 6553,5 Einheiten.
        let first = encoder.requests(for: .scroll(dx: 0, dy: 85.2, at: start))
        #expect(first == [touch("contact", 32768, 32768), touch("contact", 32768, 39322)])
        let second = encoder.requests(for: .scroll(dx: 0, dy: -85.2, at: start))
        #expect(second == [touch("contact", 32768, 32768)])
        #expect(encoder.requests(for: .scrollEnded) == [touch("release", 32768, 32768)])
        #expect(encoder.requests(for: .scrollEnded).isEmpty)
    }

    @Test mutating func scrollIsClampedAndEndedByTouch() {
        _ = encoder.requests(for: .scroll(dx: -5000, dy: 0, at: TouchPoint(x: 1000, y: 1000)))
        #expect(encoder.scrollPosition == TouchPoint(x: 0, y: 1000))
        let requests = encoder.requests(for: .touch(.began, TouchPoint(x: 5, y: 5)))
        #expect(requests == [touch("release", 0, 1000), touch("contact", 5, 5)])
    }

    @Test mutating func buttonsArePressedOnce() {
        #expect(encoder.requests(for: .button(.lock, isDown: true)) == [ServeWebRequest(path: "/button", json: ["name": .string("lock"), "state": .string("press")])])
        #expect(encoder.requests(for: .button(.lock, isDown: false)).isEmpty)
        #expect(encoder.requests(for: .button(.volumeUp, isDown: true)).first?.json["name"] == .string("volume-up"))
    }

    @Test func requestBodyIsValidJSON() throws {
        let body = ServeWebRequest(path: "/key", json: ["usages": .ints([4, 5])]).body
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: [Int]])
        #expect(object["usages"] == [4, 5])
    }
}

@Suite struct DisplayServiceTrailerTests {
    @Test func trailerIsStrippedFromSingleNALPackets() {
        var packetizer = RTPHEVCPacketizer(maxPayload: 1200)
        let slice = HEVCNALUnit(Data([0x02, 0x01, 0x80, 0x11, 0x22]) + RTPHEVCDepacketizer.displayServiceTrailer)
        var depacketizer = RTPHEVCDepacketizer()
        let frames = packetizer.packetize(accessUnit: [slice], timestamp: 0).compactMap { depacketizer.push($0) }
        #expect(AnnexB.split(frames[0].annexB).map(\.data) == [Data([0x02, 0x01, 0x80, 0x11, 0x22])])
    }
}
