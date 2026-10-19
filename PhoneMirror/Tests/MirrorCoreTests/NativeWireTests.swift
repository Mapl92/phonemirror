// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import MirrorNative
import Testing

@Suite struct XPCWireTests {
    @Test func roundTripsAllTypes() throws {
        let value: XPCValue = [
            "string": "Hello",
            "bool": true,
            "int": .int64(-5),
            "uint": .uint64(0x0100_0000_0000_0006),
            "double": .double(1.5),
            "data": .data(Data([1, 2, 3])),
            "uuid": .uuid(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!),
            "array": .array([.string("a"), .null, .int64(7)]),
            "nested": ["key": "value"],
            "empty": [:],
        ]
        let wrapper = XPCWrapper.request(value, messageID: 3, wantingReply: true)
        let (decoded, consumed) = try XPCWrapper.decode(wrapper.encoded())
        #expect(consumed == wrapper.encoded().count)
        #expect(decoded == wrapper)
        #expect(decoded.flags.contains(.dataPresent) && decoded.flags.contains(.wantingReply))
    }

    /// Alignment: strings/keys are padded to 4 bytes, measured from the start of the value.
    @Test func stringPaddingMatchesWireLayout() {
        var writer = ByteWriter()
        XPCCodec.encode(.string("abc"), into: &writer)
        // Type (4) + length 4 (4) + "abc\0" (4) = 12 bytes, no padding needed.
        #expect(writer.data == Data([0x00, 0x90, 0, 0, 4, 0, 0, 0, 0x61, 0x62, 0x63, 0]))
        var writer2 = ByteWriter()
        XPCCodec.encode(.string("ab"), into: &writer2)
        // Length 3 → 4 + 3 = 7 → 1 byte of padding.
        #expect(writer2.data.count == 4 + 4 + 3 + 1)
    }

    @Test func emptyHandshakeMessage() throws {
        // First message of the RemoteXPC handshake: empty dictionary, flags only ALWAYS_SET, ID 0.
        let bytes = XPCWrapper.request([:], messageID: 0, wantingReply: false).encoded()
        #expect(bytes.prefix(8) == Data([0x92, 0x0B, 0xB0, 0x29, 0x01, 0, 0, 0]))
        let (decoded, _) = try XPCWrapper.decode(bytes)
        #expect(decoded.payload == .dictionary([]))
    }

    @Test func truncatedFrameIsReported() {
        let bytes = XPCWrapper.request(["k": "v"], messageID: 1, wantingReply: false).encoded()
        #expect(throws: XPCWireError.truncated) { _ = try XPCWrapper.decode(bytes.dropLast(3)) }
    }

    @Test func http2FrameRoundTrip() {
        let frame = HTTP2Frame.settings([(3, 100), (4, 16 * 1024 * 1024)])
        let encoded = frame.encoded()
        #expect(encoded.prefix(9) == Data([0, 0, 12, 4, 0, 0, 0, 0, 0]))
        let decoded = HTTP2Frame.decode(header: encoded.prefix(9), payload: encoded.dropFirst(9))
        #expect(decoded.settingsValues.map(\.0) == [3, 4])
        #expect(decoded.settingsValues.map(\.1) == [100, 16 * 1024 * 1024])
        #expect(HTTP2Frame.windowUpdate(streamID: 0, increment: 77).windowIncrement == 77)
    }

    @Test func nettopEndpointParsing() {
        #expect(RSDLocator.splitEndpoint("fd9c::1.57726")?.1 == 57726)
        #expect(RSDLocator.splitEndpoint("fe80::1%utun4.5000")?.0 == "fe80::1")
        #expect(RSDLocator.splitEndpoint("10.0.0.1:443")?.1 == 443)
        #expect(RSDLocator.normalizedIPv6("fdf7:ea14:b677::1") == RSDLocator.normalizedIPv6("fdf7:ea14:b677:0::1"))
    }
}

@Suite struct MediaStreamOfferTests {
    /// Reference capture of an Xcode session (from pymobiledevice3): with the same parameters the
    /// builder must produce the same output byte for byte.
    @Test func videoBlobMatchesXcodeCapture() {
        let captured = Data(hex: """
        080110012a7f088182bae90810001a3f087b120a0801100118c387032000120a0801100218c387032000120a080110011
        8c387032000120a0801100218c38703 20001a09464c533b53573a313b20011a2e0864120a0801100118c387032000120a
        0801100218c3870320001a10464c533b565241453a303b53573a313b200e3801403f6001320d56696365726f7920312e
        372e3040004a0908ea1f1000188080014a0b080010c0d1e123188080204a0a08001080b489131880604a050810108420
        4a0b08001080dac409188080064a05080410e4324a0b080010809bee02188080084a0b08001080c2d72f188080404a0b
        080010808ece1c188080104a05080110ab026880c0dd87d2a0c0e9ed017002800100900101
        """)
        let built = MediaStreamOffer.videoBlob(
            sessionID: 2_368_635_137, ltrpEnabled: true, fecEnabled: false, avcFeatures: "FLS;VRAE:0;SW:1;"
        )
        #expect(built == captured)
    }

    @Test func audioBlobMatchesXcodeCapture() {
        let captured = Data(hex: """
        080110011a1208b4a1a5f70a1000180020ffbc0128003000320d56696365726f7920312e372e3040004a0908ea1f1000
        188080014a05080110ab024a0b080010808ece1c188080104a05080410e4324a0b08001080dac409188080064a0b0800
        1080c2d72f188080404a0a08001080b489131880604a0b080010809bee02188080084a0508101084204a0b080010c0d1
        e12318808020688080d2b28ebbdfe9ed017002800100900101
        """)
        #expect(MediaStreamOffer.audioBlob(sessionID: 2_934_526_132) == captured)
    }

    @Test func offerIsBinaryPlistWithCompressedBlob() throws {
        let offer = try MediaStreamOffer.videoOffer(callID: "ABC", sessionID: 42)
        #expect(offer.prefix(6) == Data("bplist".utf8))
        let plist = try #require(try PropertyListSerialization.propertyList(from: offer, format: nil) as? [String: Any])
        #expect(plist["avcMediaStreamNegotiatorMode"] as? Int == 5)
        let blob = try #require(plist["avcMediaStreamNegotiatorMediaBlob"] as? Data)
        #expect(blob.first == 0x78 && blob.dropFirst().first == 0xDA) // zlib header, level 9
    }
}

@Suite struct PasteboardExtractionTests {
    private func snapshot(types: [String], inline: [String: Data]) -> XPCValue {
        let data = XPCValue.dictionary(types.map { uti in
            XPCEntry(uti, inline[uti].map { ["data": .data($0)] } ?? [:])
        })
        return ["command": "PULL_REPLY", "pasteboard": ["items": .array([["types": .array(types.map { .string($0) }), "data": data]])]]
    }

    @Test func plainTextCopy() {
        let reply = snapshot(types: ["public.utf8-plain-text"], inline: ["public.utf8-plain-text": Data("Hello".utf8)])
        #expect(PasteboardService.extract(reply) == .text("Hello"))
    }

    /// As Safari on iOS 27: HTML is primary (inline), text and RTF are only promised.
    @Test func safariCopyComesAsHTML() {
        let html = Data("<b>Hello</b>".utf8)
        let reply = snapshot(types: ["public.html", "public.utf8-plain-text", "public.rtf"], inline: ["public.html": html])
        #expect(PasteboardService.extract(reply) == .html(html))
    }

    @Test func textWinsOverHTMLWhenBothInline() {
        let reply = snapshot(
            types: ["public.html", "public.utf8-plain-text"],
            inline: ["public.html": Data("<i>x</i>".utf8), "public.utf8-plain-text": Data("x".utf8)]
        )
        #expect(PasteboardService.extract(reply) == .text("x"))
    }

    @Test func emptyOrRemoteClipboardYieldsNothing() {
        #expect(PasteboardService.extract(["error": ["code": .int64(26006)]]) == nil)
        #expect(PasteboardService.extract(snapshot(types: ["public.utf8-plain-text"], inline: [:])) == nil)
    }
}
