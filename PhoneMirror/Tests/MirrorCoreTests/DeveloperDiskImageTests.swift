// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import MirrorNative
import Testing

@Suite struct DeveloperDiskImageTests {
    @Test func fileTransferRoundTrips() throws {
        let value: XPCValue = ["image": .fileTransfer(id: 3, size: 33_554_432), "auth": .uint64(0)]
        let wrapper = XPCWrapper.request(value, messageID: 1, wantingReply: true)
        let (decoded, consumed) = try XPCWrapper.decode(wrapper.encoded())
        #expect(consumed == wrapper.encoded().count)
        #expect(decoded.payload == value)
    }

    @Test func fileTransferWireLayout() {
        var out = ByteWriter()
        XPCCodec.encode(.fileTransfer(id: 2, size: 7), into: &out)
        let bytes = [UInt8](out.data)
        // type 0x1A000, message ID (u64 LE), then the dictionary {"s": uint64}
        #expect(Array(bytes[0..<4]) == [0x00, 0xA0, 0x01, 0x00])
        #expect(Array(bytes[4..<12]) == [2, 0, 0, 0, 0, 0, 0, 0])
        #expect(Array(bytes[12..<16]) == [0x00, 0xF0, 0x00, 0x00])
    }

    @Test func unwrapsCryptexdNonce() {
        let nonce = Data((1...48).map { UInt8($0) })
        let blob = Data([0xAA, 0xBB]) + nonce + Data(repeating: 0, count: 2) + Data([48, 0, 0, 0])
        #expect(CryptexdService.unwrapNonce(blob) == nonce)
    }

    @Test func cryptexUDIDIsChipAndECIDBigEndian() {
        let chip = ChipInstance(chipID: 0x8120, ecid: 0x0001_65DC_0A50_A01E, productionMode: true)
        #expect([UInt8](chip.cryptexUDID) == [0, 0, 0, 0, 0, 0, 0x81, 0x20, 0, 0x01, 0x65, 0xDC, 0x0A, 0x50, 0xA0, 0x1E])
        let parsed = ChipInstance(["img4_chip_chip": .uint64(0x8120), "img4_chip_ecid": .uint64(5), "img4_chip_cpro": .bool(false)])
        #expect(parsed == ChipInstance(chipID: 0x8120, ecid: 5, productionMode: false))
    }

    @Test func parsesTSSResponses() throws {
        let ticket = Data([0x30, 0x82, 0x01])
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Cryptex1,Ticket": ticket], format: .xml, options: 0)
        let success = Data("STATUS=0&MESSAGE=SUCCESS&REQUEST_STRING=".utf8) + plist
        #expect(try TSSClient.parse(success) == ticket)
        #expect(throws: DeveloperDiskImageError.self) {
            try TSSClient.parse(Data("STATUS=94&MESSAGE=This device isn't eligible for the requested build.".utf8))
        }
    }

    @Test func parsesManifestNumbers() {
        #expect(DeveloperDiskImageBundle.integer("0xFF10") == 0xFF10)
        #expect(DeveloperDiskImageBundle.integer(NSNumber(value: 4)) == 4)
        #expect(DeveloperDiskImageBundle.integer("12") == 12)
    }

    /// Uses Xcode's DDI if this Mac has one; otherwise there is nothing to check.
    @Test func buildsRequestFromInstalledDDI() throws {
        guard FileManager.default.fileExists(atPath: DeveloperDiskImageBundle.defaultRestoreDirectory.path) else { return }
        let bundle = try DeveloperDiskImageBundle(restoreDirectory: DeveloperDiskImageBundle.defaultRestoreDirectory)
        #expect(!bundle.image.isEmpty && !bundle.trustCache.isEmpty && !bundle.info.isEmpty && !bundle.volumeHash.isEmpty)
        let request = bundle.tssRequest(chip: ChipInstance(chipID: 0x8120, ecid: 1, productionMode: true), nonce: Data(count: 48))
        #expect(request["@Cryptex1,Ticket"] as? Bool == true)
        #expect(request["Cryptex1,GenericDmg"] == nil) // not personalized
        #expect(request["Cryptex1,GenericTrustCache"] != nil)
        #expect((request["Cryptex1,UDID"] as? Data)?.count == 16)
    }
}

@Suite struct DDIHintTests {
    let hint = DDIHint(
        xip: "Xcode_27.1/Xcode_27.1.xip", archiveSize: 2_027_400_000, build: nil,
        outer: [DDIHint.Chunk(offset: 1_000_016, compressed: 16_777_216, start: 33_554_432, length: 16_777_216)],
        package: DDIHint.Member(name: "./Xcode.app/Contents/Resources/Packages/XcodeSystemResources.pkg", dataStart: 33_600_000, size: 147_000_000),
        inner: [DDIHint.Chunk(offset: 9_000, compressed: 16_777_216, start: 0, length: 16_777_216)],
        image: DDIHint.Member(name: "./Library/Developer/CoreDevice/CandidateDDIs/iOS_DDI.dmg", dataStart: 100, size: 32_000_000)
    )

    @Test func roundTripsAndMatches() throws {
        #expect(DDIHints.decode(DDIHints.encode([hint])) == [hint])
        let url = URL(string: "https://download.developer.apple.com/Developer_Tools/Xcode_27.1/Xcode_27.1.xip")!
        #expect(hint.matches(url, size: 2_027_400_000))
        #expect(!hint.matches(url, size: 1))
        #expect(!hint.matches(URL(string: "https://download.developer.apple.com/Developer_Tools/Xcode_27/Xcode_27.xip")!, size: 2_027_400_000))
    }

    @Test func chunkHeaderIsBigEndianLengths() {
        #expect([UInt8](hint.outer[0].header) == [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0])
    }

    @Test func requiresKolyTrailer() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("koly-\(UUID().uuidString).dmg")
        defer { try? FileManager.default.removeItem(at: file) }
        try (Data(repeating: 1, count: 1000) + Data("koly".utf8) + Data(count: 508)).write(to: file)
        try RemoteXIPFetcher.requireDiskImageTrailer(file)
        try Data(repeating: 1, count: 2000).write(to: file)
        #expect(throws: RemoteXIPError.self) { try RemoteXIPFetcher.requireDiskImageTrailer(file) }
    }
}
