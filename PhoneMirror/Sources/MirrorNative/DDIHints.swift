// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// Where the iOS Developer Disk Image sits inside a specific Xcode `.xip` – positions only, no Apple content.
/// With a hint PhoneMirror skips the slow archive index (hundreds of sequential requests) and reads the image
/// directly. Every hint is checked against the archive before use; on any mismatch the full search runs.
public struct DDIHint: Codable, Sendable, Equatable {
    public struct Chunk: Codable, Sendable, Equatable {
        /// Position of the chunk payload in its container (the .xip, or the package for inner chunks).
        public var offset: UInt64
        public var compressed: Int
        /// Position and length in the uncompressed stream.
        public var start: UInt64
        public var length: UInt64
    }

    public struct Member: Codable, Sendable, Equatable {
        public var name: String
        public var dataStart: UInt64
        public var size: UInt64
    }

    /// Path of the .xip below `Developer_Tools/`, e.g. `Xcode_27.1/Xcode_27.1.xip`.
    public var xip: String
    public var archiveSize: UInt64
    public var build: String?
    /// Outer pbzx chunks covering the package.
    public var outer: [Chunk]
    public var package: Member
    /// Inner pbzx chunks (package `Payload`) covering the disk image.
    public var inner: [Chunk]
    public var image: Member

    func matches(_ url: URL, size: UInt64) -> Bool {
        size == archiveSize && url.path.hasSuffix("/" + xip)
    }
}

extension DDIHint.Chunk {
    init(_ chunk: PBZXStream.Chunk) {
        self.init(offset: chunk.dataOffset, compressed: chunk.compressedSize, start: chunk.uncompressedStart, length: chunk.uncompressedSize)
    }

    var pbzx: PBZXStream.Chunk {
        PBZXStream.Chunk(dataOffset: offset, compressedSize: compressed, uncompressedStart: start, uncompressedSize: length)
    }

    /// The 16 bytes in front of the payload: uncompressed and compressed length, big endian.
    var header: Data {
        withUnsafeBytes(of: length.bigEndian) { Data($0) } + withUnsafeBytes(of: UInt64(compressed).bigEndian) { Data($0) }
    }
}

/// Hint sources: the copy in the app bundle, the newest list in the GitHub repository, and hints this Mac
/// learned from a full search (so a repeated download is fast too).
public enum DDIHints {
    public static let remoteURL = URL(string: "https://raw.githubusercontent.com/Mapl92/phonemirror/main/PhoneMirror/Resources/ddi-hints.json")!
    private static let logger = Logger(subsystem: "PhoneMirror", category: "ddi")

    static var learnedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneMirror/DDI/learned-hints.json")
    }

    public static func load() async -> [DDIHint] {
        var hints: [DDIHint] = []
        var request = URLRequest(url: remoteURL, timeoutInterval: 5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            hints += decode(data)
        }
        if let bundled = Bundle.main.url(forResource: "ddi-hints", withExtension: "json"), let data = try? Data(contentsOf: bundled) {
            hints += decode(data)
        }
        if let data = try? Data(contentsOf: learnedURL) { hints += decode(data) }
        return hints
    }

    static func decode(_ data: Data) -> [DDIHint] {
        (try? JSONDecoder().decode([DDIHint].self, from: data)) ?? []
    }

    static func encode(_ hints: [DDIHint]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(hints)) ?? Data("[]".utf8)
    }

    /// Stores a hint found by a full search (and a copy in the logs, for adding it to the repository).
    static func learn(_ hint: DDIHint) {
        var hints = (try? Data(contentsOf: learnedURL)).map(decode) ?? []
        hints.removeAll { $0.xip == hint.xip && $0.archiveSize == hint.archiveSize }
        hints.append(hint)
        try? FileManager.default.createDirectory(at: learnedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encode(hints).write(to: learnedURL, options: .atomic)
        let log = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/PhoneMirror/ddi-hint.json")
        try? encode([hint]).write(to: log, options: .atomic)
        logger.notice("Learned DDI position for \(hint.xip, privacy: .public)")
    }
}
