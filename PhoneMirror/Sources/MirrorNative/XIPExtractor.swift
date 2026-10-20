// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum XIPError: LocalizedError {
    case notXAR
    case noContent
    case unsupported(String)
    case memberNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notXAR: "Not a .xip/xar archive"
        case .noContent: "The archive has no “Content” entry"
        case .unsupported(let what): "Unsupported archive layout: \(what)"
        case .memberNotFound(let name): "\(name) not found in the archive"
        }
    }
}

/// Pulls a single file out of an Xcode `.xip` without expanding the whole archive:
/// xar container → `Content` (pbzx: chunked XZ) → cpio stream, read sequentially.
enum XIPExtractor {
    /// Extracts the first member whose path ends with `memberSuffix` to `destination`.
    static func extract(xip: URL, memberSuffix: String, to destination: URL,
                        progress: (Double) -> Void = { _ in }) throws {
        let file = try FileHandle(forReadingFrom: xip)
        defer { try? file.close() }
        let (contentOffset, contentLength) = try locateContent(file)
        try file.seek(toOffset: contentOffset)
        var reader = BoundedReader(file: file, remaining: contentLength)

        guard try reader.read(4) == Data("pbzx".utf8) else { throw XIPError.unsupported("Content is not pbzx") }
        _ = try reader.read(8) // chunk size flags
        var cpio = CPIOStream(memberSuffix: memberSuffix, destination: destination)
        while reader.remaining > 0 {
            let uncompressedSize = try reader.uint64()
            let compressedSize = try reader.uint64()
            let data = try decodeChunk(try reader.read(Int(compressedSize)))
            _ = uncompressedSize
            if try cpio.feed(data) { return }
            progress(1 - Double(reader.remaining) / Double(contentLength))
        }
        throw XIPError.memberNotFound(memberSuffix)
    }

    /// xar header (big endian): magic, header size, version, TOC compressed/uncompressed length, checksum type.
    static func locateContent(_ file: FileHandle) throws -> (offset: UInt64, length: UInt64) {
        try file.seek(toOffset: 0)
        guard let header = try file.read(upToCount: 28) else { throw XIPError.notXAR }
        let layout = try parseHeader(header)
        try file.seek(toOffset: layout.tocOffset)
        guard let toc = try file.read(upToCount: Int(layout.tocLength)) else { throw XIPError.noContent }
        let content = try parseTOC(toc)
        return (layout.heapOffset + content.offset, content.length)
    }

    struct XARLayout {
        var tocOffset: UInt64
        var tocLength: UInt64
        var heapOffset: UInt64 { tocOffset + tocLength }
    }

    static func parseHeader(_ header: Data) throws -> XARLayout {
        guard header.count >= 28, header.prefix(4) == Data("xar!".utf8) else { throw XIPError.notXAR }
        let bytes = [UInt8](header)
        let headerSize = UInt64(bytes[4]) << 8 | UInt64(bytes[5])
        let tocCompressed = bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return XARLayout(tocOffset: headerSize, tocLength: tocCompressed)
    }

    /// Offset (relative to the heap) and length of a stored entry (`Content` in a .xip, `Payload` in a .pkg).
    static func parseTOC(_ toc: Data, entry: String = "Content") throws -> (offset: UInt64, length: UInt64) {
        guard toc.count > 6,
              // zlib stream: skip the 2-byte header and the 4-byte Adler-32 for raw DEFLATE
              let xml = try? (toc.dropFirst(2).dropLast(4) as NSData).decompressed(using: .zlib) as Data,
              let document = try? XMLDocument(data: xml),
              let data = try document.nodes(forXPath: "//file[name='\(entry)']/data").first as? XMLElement,
              let offset = data.elements(forName: "offset").first?.stringValue.flatMap(UInt64.init),
              let length = data.elements(forName: "length").first?.stringValue.flatMap(UInt64.init)
        else { throw XIPError.noContent }
        let encoding = data.elements(forName: "encoding").first?.attribute(forName: "style")?.stringValue ?? "application/octet-stream"
        guard encoding == "application/octet-stream" else { throw XIPError.unsupported("Content encoding \(encoding)") }
        return (offset, length)
    }

    /// Decodes one pbzx chunk (XZ or stored).
    static func decodeChunk(_ chunk: Data) throws -> Data {
        guard chunk.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) else { return chunk }
        guard let decoded = try? (chunk as NSData).decompressed(using: .lzma) as Data else {
            throw XIPError.unsupported("XZ chunk could not be decoded")
        }
        return decoded
    }
}

/// Sequential reads from a file region.
struct BoundedReader {
    let file: FileHandle
    var remaining: UInt64

    mutating func read(_ count: Int) throws -> Data {
        guard UInt64(count) <= remaining, let data = try file.read(upToCount: count), data.count == count else {
            throw XIPError.unsupported("truncated archive")
        }
        remaining -= UInt64(count)
        return data
    }

    mutating func uint64() throws -> UInt64 {
        try read(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}

/// Incremental cpio parser (odc "070707" and newc "070701"/"070702"). Writes one matching member.
/// Works with a read cursor instead of removing consumed bytes: Xcode's archive has ~200,000 entries.
struct CPIOStream {
    let memberSuffix: String
    let destination: URL
    private var buffer: [UInt8] = []
    private var position = 0
    private var skip: UInt64 = 0
    private var output: FileHandle?
    private var outputRemaining: UInt64 = 0

    init(memberSuffix: String, destination: URL) {
        self.memberSuffix = memberSuffix
        self.destination = destination
    }

    private var available: Int { buffer.count - position }

    /// Returns `true` once the member has been written completely.
    mutating func feed(_ data: Data) throws -> Bool {
        buffer.removeFirst(position)
        position = 0
        buffer.append(contentsOf: data)
        while true {
            if let output {
                let take = Int(min(UInt64(available), outputRemaining))
                try output.write(contentsOf: Data(buffer[position..<position + take]))
                position += take
                outputRemaining -= UInt64(take)
                if outputRemaining == 0 {
                    try output.close()
                    return true
                }
                return false
            }
            if skip > 0 {
                let take = Int(min(UInt64(available), skip))
                position += take
                skip -= UInt64(take)
                if skip > 0 { return false }
            }
            guard let entry = try parseHeader() else { return false }
            if entry.name == "TRAILER!!!" { throw XIPError.memberNotFound(memberSuffix) }
            if entry.name.hasSuffix(memberSuffix), entry.isRegularFile {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                output = try FileHandle(forWritingTo: destination)
                outputRemaining = entry.size
                if entry.size == 0 {
                    try output?.close()
                    return true
                }
            } else {
                skip = entry.size + entry.padding
            }
        }
    }

    private struct Entry {
        var name: String
        var size: UInt64
        var padding: UInt64
        var isRegularFile: Bool
    }

    private func field(_ offset: Int, _ length: Int, radix: Int) -> UInt64 {
        let start = position + offset
        return UInt64(String(decoding: buffer[start..<start + length], as: UTF8.self), radix: radix) ?? 0
    }

    private func name(at offset: Int, size: Int) -> String {
        String(decoding: buffer[(position + offset)..<(position + offset + max(size - 1, 0))], as: UTF8.self)
    }

    /// Consumes a header + name if completely buffered.
    private mutating func parseHeader() throws -> Entry? {
        guard available >= 6 else { return nil }
        let magic = String(decoding: buffer[position..<position + 6], as: UTF8.self)
        switch magic {
        case "070707":
            guard available >= 76 else { return nil }
            let mode = field(18, 6, radix: 8)
            let nameSize = Int(field(59, 6, radix: 8))
            let size = field(65, 11, radix: 8)
            guard available >= 76 + nameSize else { return nil }
            let entry = Entry(name: name(at: 76, size: nameSize), size: size, padding: 0, isRegularFile: mode & 0o170000 == 0o100000)
            position += 76 + nameSize
            return entry
        case "070701", "070702":
            guard available >= 110 else { return nil }
            let mode = field(14, 8, radix: 16)
            let size = field(54, 8, radix: 16)
            let nameSize = Int(field(94, 8, radix: 16))
            let headerAndName = (110 + nameSize + 3) & ~3
            guard available >= headerAndName else { return nil }
            let entry = Entry(name: name(at: 110, size: nameSize), size: size, padding: (4 - size % 4) % 4, isRegularFile: mode & 0o170000 == 0o100000)
            position += headerAndName
            return entry
        default:
            throw XIPError.unsupported("cpio magic \(magic)")
        }
    }
}
