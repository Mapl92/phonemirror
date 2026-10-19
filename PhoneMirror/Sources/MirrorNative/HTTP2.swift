// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Minimale HTTP/2-Rahmen für RemoteXPC (keine Header-Kompression nötig: RemoteXPC schickt leere HEADERS).
public struct HTTP2Frame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case data = 0, headers = 1, priority = 2, rstStream = 3, settings = 4
        case pushPromise = 5, ping = 6, goAway = 7, windowUpdate = 8, continuation = 9
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let endStream = Flags(rawValue: 0x1)
        public static let ack = Flags(rawValue: 0x1)
        public static let endHeaders = Flags(rawValue: 0x4)
    }

    public static let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    public static let headerSize = 9

    public var kind: UInt8
    public var flags: Flags
    public var streamID: UInt32
    public var payload: Data

    public init(_ kind: Kind, flags: Flags = [], streamID: UInt32, payload: Data = Data()) {
        self.kind = kind.rawValue
        self.flags = flags
        self.streamID = streamID
        self.payload = payload
    }

    public static func == (lhs: HTTP2Frame, rhs: HTTP2Frame) -> Bool {
        lhs.kind == rhs.kind && lhs.flags.rawValue == rhs.flags.rawValue && lhs.streamID == rhs.streamID && lhs.payload == rhs.payload
    }

    public var type: Kind? { Kind(rawValue: kind) }

    public func encoded() -> Data {
        var out = Data()
        let length = UInt32(payload.count)
        out.append(contentsOf: [UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF), kind, flags.rawValue])
        withUnsafeBytes(of: (streamID & 0x7FFF_FFFF).bigEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Länge des Payloads aus einem 9-Byte-Header.
    static func payloadLength(header: Data) -> Int {
        let b = [UInt8](header.prefix(3))
        return Int(b[0]) << 16 | Int(b[1]) << 8 | Int(b[2])
    }

    static func decode(header: Data, payload: Data) -> HTTP2Frame {
        let b = [UInt8](header)
        let stream = (UInt32(b[5]) << 24 | UInt32(b[6]) << 16 | UInt32(b[7]) << 8 | UInt32(b[8])) & 0x7FFF_FFFF
        var frame = HTTP2Frame(.data, streamID: stream, payload: payload)
        frame.kind = b[3]
        frame.flags = Flags(rawValue: b[4])
        return frame
    }

    // MARK: Bausteine

    public static func settings(_ values: [(UInt16, UInt32)], ack: Bool = false) -> HTTP2Frame {
        var payload = ByteWriter()
        for (id, value) in values {
            payload.u16be(id)
            payload.u32be(value)
        }
        return HTTP2Frame(.settings, flags: ack ? .ack : [], streamID: 0, payload: payload.data)
    }

    public static func windowUpdate(streamID: UInt32, increment: UInt32) -> HTTP2Frame {
        var payload = ByteWriter()
        payload.u32be(increment & 0x7FFF_FFFF)
        return HTTP2Frame(.windowUpdate, streamID: streamID, payload: payload.data)
    }

    /// SETTINGS als (ID, Wert)-Paare.
    public var settingsValues: [(UInt16, UInt32)] {
        let b = [UInt8](payload)
        return stride(from: 0, to: b.count - 5, by: 6).map { i in
            (UInt16(b[i]) << 8 | UInt16(b[i + 1]), UInt32(b[i + 2]) << 24 | UInt32(b[i + 3]) << 16 | UInt32(b[i + 4]) << 8 | UInt32(b[i + 5]))
        }
    }

    public var windowIncrement: UInt32 {
        let b = [UInt8](payload.prefix(4))
        guard b.count == 4 else { return 0 }
        return (UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) & 0x7FFF_FFFF
    }

    public static let settingsMaxConcurrentStreams: UInt16 = 3
    public static let settingsInitialWindowSize: UInt16 = 4
}
