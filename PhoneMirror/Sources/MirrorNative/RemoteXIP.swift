// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// Random access to a file on an HTTP server via Range requests, counting what is downloaded.
/// Cookies are attached by hand (also on redirects to Apple's CDN), and the Range header is kept on redirects.
final class RangeReader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let url: URL
    /// Where Apple's server redirected the first request (a signed CDN URL); later requests go there directly.
    private var resolvedURL: URL?
    private(set) var redirects = 0
    private let cookies: [HTTPCookie]
    private var session: URLSession!
    private(set) var bytesDownloaded = 0
    private(set) var requests = 0
    private(set) var totalSize: UInt64?
    private static let logger = Logger(subsystem: "PhoneMirror", category: "ddi")

    /// `cookies` authenticate the download (Apple Developer sign-in); they stay in this object only.
    init(url: URL, cookies: [HTTPCookie]) {
        self.url = url
        self.cookies = cookies
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private func authorize(_ request: inout URLRequest) {
        guard let target = request.url else { return }
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return target.host == domain || target.host?.hasSuffix("." + domain) == true
        }
        for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var redirected = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            redirected.setValue(range, forHTTPHeaderField: "Range")
        }
        authorize(&redirected)
        redirects += 1
        Self.logger.debug("Redirect to \(request.url?.host ?? "?", privacy: .public)\(request.url?.path ?? "", privacy: .public)")
        return redirected
    }

    func read(_ offset: UInt64, _ length: Int) async throws -> Data {
        do {
            return try await fetch(resolvedURL ?? url, offset, length)
        } catch where resolvedURL != nil {
            resolvedURL = nil // the signed URL may have expired: go through the redirect again
            return try await fetch(url, offset, length)
        }
    }

    private func fetch(_ target: URL, _ offset: UInt64, _ length: Int) async throws -> Data {
        var request = URLRequest(url: target, timeoutInterval: 60)
        request.setValue("bytes=\(offset)-\(offset + UInt64(length) - 1)", forHTTPHeaderField: "Range")
        authorize(&request)
        let (bytes, response) = try await session.bytes(for: request)
        requests += 1
        guard let http = response as? HTTPURLResponse else { throw RemoteXIPError.http("no HTTP response") }
        guard http.statusCode == 206 else {
            // Never pull a full 3 GB body: describe what came back and stop.
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? "?"
            let place = "\(http.url?.host ?? "?")\(http.url?.path ?? "")"
            bytes.task.cancel()
            throw RemoteXIPError.http("HTTP \(http.statusCode), \(type) from \(place) – expected a partial response")
        }
        if resolvedURL == nil, let final = http.url, final != url { resolvedURL = final }
        if totalSize == nil, let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ UInt64($0) }) {
            totalSize = total
        }
        var data = Data()
        data.reserveCapacity(length)
        for try await byte in bytes { data.append(byte) }
        bytesDownloaded += data.count
        guard data.count == length else { throw RemoteXIPError.http("short read (\(data.count) of \(length) bytes)") }
        return data
    }
}

public enum RemoteXIPError: LocalizedError {
    case http(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .http(let message): "Download from Apple failed: \(message)"
        case .notFound(let message): message
        }
    }
}

/// What a partial download cost – the point of the prototype.
public struct RemoteXIPReport: Sendable, CustomStringConvertible {
    public var archiveSize: UInt64 = 0
    public var chunks = 0
    public var rawRuns = 0
    public var bytesDownloaded = 0
    public var requests = 0
    public var seconds: Double = 0
    public var indexSeconds: Double = 0
    public var redirects = 0
    public var result = ""
    public var notes: [String] = []

    public var description: String {
        let megabytes = { (bytes: Double) in String(format: "%.1f MB", bytes / 1_000_000) }
        return "Downloaded \(megabytes(Double(bytesDownloaded))) of \(megabytes(Double(archiveSize))) in \(requests) requests and "
            + "\(String(format: "%.0f", seconds)) s (index: \(chunks) chunks, \(String(format: "%.0f", indexSeconds)) s); \(result)"
    }
}

/// A pbzx stream (chunked XZ) read at random positions. Stored (raw) chunks are read byte-exactly with Range
/// requests; compressed chunks are downloaded and decoded whole (one cached).
final class PBZXStream: @unchecked Sendable {
    struct Chunk {
        var dataOffset: UInt64 // payload position in the source
        var compressedSize: Int
        var uncompressedStart: UInt64
        var uncompressedSize: UInt64
        var isRaw: Bool { UInt64(compressedSize) == uncompressedSize }
    }

    typealias Source = (UInt64, Int) async throws -> Data
    let chunks: [Chunk]
    private let source: Source
    private var cached: (index: Int, data: Data)?

    private init(chunks: [Chunk], source: @escaping Source) {
        self.chunks = chunks
        self.source = source
    }

    /// Reads the chunk headers of a pbzx stream at `start` (16 bytes each; payloads are skipped).
    static func index(source: @escaping Source, start: UInt64, length: UInt64,
                      progress: (Double) -> Void = { _ in }) async throws -> PBZXStream {
        guard try await source(start, 4) == Data("pbzx".utf8) else { throw XIPError.unsupported("not a pbzx stream") }
        var chunks: [Chunk] = []
        var position = start + 12
        var uncompressed: UInt64 = 0
        while position < start + length {
            let header = [UInt8](try await source(position, 16))
            let uncompressedSize = header[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let compressedSize = header[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            chunks.append(Chunk(dataOffset: position + 16, compressedSize: Int(compressedSize),
                                uncompressedStart: uncompressed, uncompressedSize: uncompressedSize))
            uncompressed += uncompressedSize
            position += 16 + compressedSize
            if chunks.count % 20 == 0 { progress(Double(position - start) / Double(length)) }
        }
        return PBZXStream(chunks: chunks, source: source)
    }

    var length: UInt64 { chunks.last.map { $0.uncompressedStart + $0.uncompressedSize } ?? 0 }

    func decoded(_ index: Int) async throws -> Data {
        if let cached, cached.index == index { return cached.data }
        let chunk = chunks[index]
        let data = try XIPExtractor.decodeChunk(try await source(chunk.dataOffset, chunk.compressedSize))
        cached = (index, data)
        return data
    }

    /// Bytes `[offset, offset + length)` of the uncompressed stream.
    func read(_ offset: UInt64, _ length: Int) async throws -> Data {
        var result = Data()
        result.reserveCapacity(length)
        let end = offset + UInt64(length)
        for (index, chunk) in chunks.enumerated()
        where chunk.uncompressedStart < end && chunk.uncompressedStart + chunk.uncompressedSize > offset {
            let from = max(offset, chunk.uncompressedStart) - chunk.uncompressedStart
            let to = min(end, chunk.uncompressedStart + chunk.uncompressedSize) - chunk.uncompressedStart
            if chunk.isRaw {
                result.append(try await source(chunk.dataOffset + from, Int(to - from)))
            } else {
                let data = try await decoded(index)
                result.append(data[data.startIndex + Int(from)..<data.startIndex + Int(to)])
            }
        }
        guard result.count == length else { throw XIPError.unsupported("read past the end of the stream") }
        return result
    }

    /// Runs of consecutive stored chunks – already compressed files (.pkg, .dmg) end up in them.
    var rawRuns: [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for (index, chunk) in chunks.enumerated() {
            if chunk.isRaw {
                if start == nil { start = index }
            } else if let first = start {
                runs.append(first...(index - 1))
                start = nil
            }
        }
        if let first = start { runs.append(first...(chunks.count - 1)) }
        return runs
    }
}

/// Takes the iOS Developer Disk Image out of an Xcode `.xip` on Apple's server with as few bytes as possible:
/// archive index → stored chunk runs → `XcodeSystemResources.pkg` → its `Payload` (pbzx again) → `iOS_DDI.dmg`.
public enum RemoteXIPFetcher {
    private static let logger = Logger(subsystem: "PhoneMirror", category: "ddi")
    static let packageSuffix = DeveloperDiskImageStore.packageMember
    static let diskImageSuffix = "CandidateDDIs/iOS_DDI.dmg"

    struct CPIOHeader {
        var position: UInt64 // in the uncompressed stream
        var name: String
        var nameSize: Int
        var fileSize: UInt64
        var dataStart: UInt64 { position + 76 + UInt64(nameSize) }
    }

    public enum Outcome: Sendable {
        case diskImage(URL)
        case package(URL)
    }

    /// Writes `iOS_DDI.dmg` (or, if the package cannot be read in place, the whole package) into `directory`.
    public static func fetch(xipURL: URL, cookies: [HTTPCookie], into directory: URL,
                             progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> (Outcome, RemoteXIPReport) {
        let started = Date()
        let reader = RangeReader(url: xipURL, cookies: cookies)
        var report = RemoteXIPReport()
        func finish(_ result: String) -> RemoteXIPReport {
            report.bytesDownloaded = reader.bytesDownloaded
            report.requests = reader.requests
            report.redirects = reader.redirects
            report.seconds = Date().timeIntervalSince(started)
            report.result = result
            writeReport(report)
            return report
        }
        do {
            progress("Reading the archive index…")
            let layout = try XIPExtractor.parseHeader(try await reader.read(0, 28))
            report.archiveSize = reader.totalSize ?? 0
            let content = try XIPExtractor.parseTOC(try await reader.read(layout.tocOffset, Int(layout.tocLength)))
            let outer = try await PBZXStream.index(source: reader.read, start: layout.heapOffset + content.offset, length: content.length) { fraction in
                progress("Indexing the Xcode archive… \(Int(fraction * 100)) %")
            }
            report.chunks = outer.chunks.count
            report.rawRuns = outer.rawRuns.count
            report.indexSeconds = Date().timeIntervalSince(started)

            progress("Looking for the Developer Disk Image package…")
            let package = try await locate(suffix: packageSuffix, in: outer, minimumChunks: 3, report: &report)
            report.notes.append("package \(package.fileSize / 1_000_000) MB")

            do {
                let url = directory.appendingPathComponent("iOS_DDI.dmg")
                try await extractDiskImage(from: package, in: outer, to: url, report: &report, progress: progress)
                return (.diskImage(url), finish("disk image only"))
            } catch {
                report.notes.append("in-place read failed: \(error.localizedDescription)")
                progress("Downloading the whole package…")
                let url = directory.appendingPathComponent("XcodeSystemResources.pkg")
                try await copy(from: outer, start: package.dataStart, size: package.fileSize, to: url, progress: progress)
                return (.package(url), finish("whole package"))
            }
        } catch {
            _ = finish("failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Inside the package (xar): the `Payload` is pbzx again; the DMG sits in stored chunks there too.
    private static func extractDiskImage(from package: CPIOHeader, in outer: PBZXStream, to url: URL,
                                         report: inout RemoteXIPReport, progress: @escaping @Sendable (String) -> Void) async throws {
        let base = package.dataStart
        let packageRead: PBZXStream.Source = { offset, length in try await outer.read(base + offset, length) }
        let layout = try XIPExtractor.parseHeader(try await packageRead(0, 28))
        let payload = try XIPExtractor.parseTOC(try await packageRead(layout.tocOffset, Int(layout.tocLength)), entry: "Payload")
        let inner = try await PBZXStream.index(source: packageRead, start: layout.heapOffset + payload.offset, length: payload.length)
        report.notes.append("payload \(inner.chunks.count) chunks")
        progress("Looking for the iOS disk image…")
        let image = try await locate(suffix: diskImageSuffix, in: inner, minimumChunks: 1, report: &report)
        try await copy(from: inner, start: image.dataStart, size: image.fileSize, to: url, progress: progress)
    }

    /// Finds a large member by checking, for each run of stored chunks, which file starts there.
    private static func locate(suffix: String, in stream: PBZXStream, minimumChunks: Int,
                               report: inout RemoteXIPReport) async throws -> CPIOHeader {
        // Later runs first: Xcode's packages sit near the end of the archive.
        let runs = stream.rawRuns.filter { $0.count >= minimumChunks }.reversed()
        for run in runs {
            // The header is usually at the end of the (compressed) chunk before the run …
            if run.lowerBound > 0, !stream.chunks[run.lowerBound - 1].isRaw {
                let previous = run.lowerBound - 1
                let headers = scanHeaders(try await stream.decoded(previous), start: stream.chunks[previous].uncompressedStart)
                if let match = headers.last(where: { $0.name.hasSuffix(suffix) }) { return match }
                if let last = headers.last { report.notes.append("run \(run.lowerBound): \(last.name.split(separator: "/").last ?? "")") }
                if let last = headers.last, last.dataStart + last.fileSize > stream.chunks[run.lowerBound].uncompressedStart { continue }
            }
            // … otherwise inside the first stored chunk.
            let first = stream.chunks[run.lowerBound]
            let data = try await stream.read(first.uncompressedStart, Int(first.uncompressedSize))
            if let match = scanHeaders(data, start: first.uncompressedStart).first(where: { $0.name.hasSuffix(suffix) }) { return match }
        }
        throw RemoteXIPError.notFound("\(suffix) not found in \(runs.count) stored chunk runs")
    }

    private static func copy(from stream: PBZXStream, start: UInt64, size: UInt64, to url: URL,
                             progress: @escaping @Sendable (String) -> Void) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var offset: UInt64 = 0
        let step: UInt64 = 4 << 20
        while offset < size {
            let length = Int(min(step, size - offset))
            try output.write(contentsOf: try await stream.read(start + offset, length))
            offset += UInt64(length)
            progress("Downloading… \(Int(Double(offset) / Double(size) * 100)) % of \(size / 1_000_000) MB")
        }
    }

    /// Diagnostics for the prototype: ~/Library/Logs/PhoneMirror/ddi-fetch.txt
    private static func writeReport(_ report: RemoteXIPReport) {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/PhoneMirror/ddi-fetch.txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "\(Date())\n\(report)\nraw runs: \(report.rawRuns), redirects: \(report.redirects)\n" + report.notes.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        logger.notice("\(report.description, privacy: .public)")
    }

    /// cpio odc headers inside decoded data, validated strictly (binary data may contain "070707").
    static func scanHeaders(_ data: Data, start: UInt64) -> [CPIOHeader] {
        let bytes = [UInt8](data)
        let magic: [UInt8] = Array("070707".utf8)
        var result: [CPIOHeader] = []
        var index = 0
        func octal(_ start: Int, _ length: Int) -> UInt64? {
            var value: UInt64 = 0
            for byte in bytes[start..<start + length] {
                guard byte >= 0x30, byte <= 0x37 else { return nil }
                value = value << 3 | UInt64(byte - 0x30)
            }
            return value
        }
        while index + 76 <= bytes.count {
            guard bytes[index] == 0x30, Array(bytes[index..<index + 6]) == magic,
                  let nameSize = octal(index + 59, 6).map(Int.init), nameSize > 1, nameSize < 4096,
                  let fileSize = octal(index + 65, 11), octal(index + 6, 53) != nil,
                  index + 76 + nameSize <= bytes.count, bytes[index + 76 + nameSize - 1] == 0,
                  let name = String(bytes: bytes[(index + 76)..<(index + 76 + nameSize - 1)], encoding: .utf8),
                  name.hasPrefix(".") || name.hasPrefix("Xcode") || name.hasPrefix("Library") || name.hasPrefix("System")
            else { index += 1; continue }
            result.append(CPIOHeader(position: start + UInt64(index), name: name, nameSize: nameSize, fileSize: fileSize))
            index += 76 + nameSize
        }
        return result
    }
}
