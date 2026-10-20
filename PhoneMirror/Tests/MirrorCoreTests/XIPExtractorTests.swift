// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import MirrorNative
import Testing

/// Builds a miniature `.xip` like Apple's (xar → pbzx/XZ → cpio odc) with the system tools and extracts one member.
@Suite struct XIPExtractorTests {
    @Test func extractsMemberFromSyntheticXIP() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xip-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("tree")
        let packages = tree.appendingPathComponent("Xcode.app/Contents/Resources/Packages")
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)

        let wanted = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try wanted.write(to: packages.appendingPathComponent("XcodeSystemResources.pkg"))
        try Data(repeating: 0xAB, count: 2_500_000).write(to: tree.appendingPathComponent("Xcode.app/Contents/big.bin"))
        for index in 0..<50 {
            try Data("file \(index)".utf8).write(to: packages.appendingPathComponent("other-\(index).txt"))
        }

        try shell("cd '\(tree.path)' && find . | /usr/bin/cpio -o -H odc > '\(root.path)/archive.cpio' 2>/dev/null")
        let cpio = try Data(contentsOf: root.appendingPathComponent("archive.cpio"))

        // pbzx: alternate XZ-compressed and raw (stored) chunks of 1 MiB.
        let chunkSize = 1 << 20
        var pbzx = Data("pbzx".utf8) + bigEndian(UInt64(chunkSize))
        var offset = 0
        var index = 0
        while offset < cpio.count {
            let chunk = cpio.subdata(in: offset..<min(offset + chunkSize, cpio.count))
            let stored = index % 2 == 1
            let payload = stored ? chunk : try #require((chunk as NSData).compressed(using: .lzma) as Data)
            if !stored { #expect(payload.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])) }
            pbzx += bigEndian(UInt64(chunk.count)) + bigEndian(UInt64(payload.count)) + payload
            offset += chunk.count
            index += 1
        }
        let content = root.appendingPathComponent("Content")
        try pbzx.write(to: content)
        try shell("cd '\(root.path)' && /usr/bin/xar -c -f test.xip --compression=none Content")

        let output = root.appendingPathComponent("out.pkg")
        var reported: [Double] = []
        try XIPExtractor.extract(xip: root.appendingPathComponent("test.xip"),
                                 memberSuffix: DeveloperDiskImageStore.packageMember, to: output) { reported.append($0) }
        #expect(try Data(contentsOf: output) == wanted)
        #expect(!reported.isEmpty)

        #expect(throws: XIPError.self) {
            try XIPExtractor.extract(xip: root.appendingPathComponent("test.xip"), memberSuffix: "/missing.pkg",
                                     to: root.appendingPathComponent("none"))
        }
    }

    @Test func rejectsNonXAR() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("not-xip-\(UUID().uuidString).xip")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0, count: 64).write(to: file)
        #expect(throws: XIPError.self) {
            try XIPExtractor.extract(xip: file, memberSuffix: "x", to: file.appendingPathExtension("out"))
        }
    }

    private func bigEndian(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private func shell(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(command)")
    }
}
