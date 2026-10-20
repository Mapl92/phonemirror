// SPDX-License-Identifier: GPL-3.0-or-later
// RemoteXPC wire format recreated after pymobiledevice3 (remote/xpc_message.py, GPL-3.0-or-later).
import Foundation

/// An XPC object as RemoteXPC serializes it over HTTP/2.
public indirect enum XPCValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    /// Nanoseconds since 1970.
    case date(Int64)
    case data(Data)
    case string(String)
    case uuid(UUID)
    case array([XPCValue])
    /// Order as on the wire.
    case dictionary([XPCEntry])
    /// Announces an out-of-band file transfer: the payload follows on its own HTTP/2 stream whose
    /// opening frame carries `id` as message ID (see `RemoteXPCConnection.sendFileTransfer`).
    case fileTransfer(id: UInt64, size: UInt64)
    /// Type without a known layout (e.g. file transfer); only for passing through when reading.
    case unsupported(UInt32)

    public subscript(key: String) -> XPCValue? {
        guard case .dictionary(let entries) = self else { return nil }
        return entries.first { $0.key == key }?.value
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int64(let value): Int(value)
        case .uint64(let value): Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var dataValue: Data? {
        if case .data(let value) = self { return value }
        return nil
    }

    public var arrayValue: [XPCValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var entries: [XPCEntry]? {
        if case .dictionary(let value) = self { return value }
        return nil
    }
}

public struct XPCEntry: Equatable, Sendable {
    public var key: String
    public var value: XPCValue

    public init(_ key: String, _ value: XPCValue) {
        self.key = key
        self.value = value
    }
}

extension XPCValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, XPCValue)...) {
        self = .dictionary(elements.map { XPCEntry($0.0, $0.1) })
    }
}

extension XPCValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension XPCValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

public enum XPCWireError: Error, Equatable {
    case truncated
    case badMagic(UInt32)
    case malformed(String)
}

enum XPCType: UInt32 {
    case null = 0x1000, bool = 0x2000, int64 = 0x3000, uint64 = 0x4000, double = 0x5000
    case date = 0x7000, data = 0x8000, string = 0x9000, uuid = 0xA000, fd = 0xB000
    case array = 0xE000, dictionary = 0xF000, fileTransfer = 0x1A000
}

/// Flags of the RemoteXPC frame.
public struct XPCFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let alwaysSet = XPCFlags(rawValue: 0x0000_0001)
    public static let ping = XPCFlags(rawValue: 0x0000_0002)
    public static let dataPresent = XPCFlags(rawValue: 0x0000_0100)
    public static let wantingReply = XPCFlags(rawValue: 0x0001_0000)
    public static let reply = XPCFlags(rawValue: 0x0002_0000)
    public static let fileTransferRequest = XPCFlags(rawValue: 0x0010_0000)
    public static let fileTransferResponse = XPCFlags(rawValue: 0x0020_0000)
    public static let initHandshake = XPCFlags(rawValue: 0x0040_0000)
}

/// A RemoteXPC frame: header (magic, flags, length, message ID) plus optional XPC object.
public struct XPCWrapper: Equatable, Sendable {
    static let magic: UInt32 = 0x29B0_0B92
    static let payloadMagic: UInt32 = 0x4213_3742
    static let payloadVersion: UInt32 = 5
    static let headerSize = 24

    public var flags: XPCFlags
    public var messageID: UInt64
    public var payload: XPCValue?

    public init(flags: XPCFlags = .alwaysSet, messageID: UInt64 = 0, payload: XPCValue? = nil) {
        self.flags = flags
        self.messageID = messageID
        self.payload = payload
    }

    public static func == (lhs: XPCWrapper, rhs: XPCWrapper) -> Bool {
        lhs.flags.rawValue == rhs.flags.rawValue && lhs.messageID == rhs.messageID && lhs.payload == rhs.payload
    }

    /// Frame for a request (like `create_xpc_wrapper`).
    public static func request(_ dictionary: XPCValue, messageID: UInt64, wantingReply: Bool) -> XPCWrapper {
        var flags: XPCFlags = .alwaysSet
        if let entries = dictionary.entries, !entries.isEmpty { flags.insert(.dataPresent) }
        if wantingReply { flags.insert(.wantingReply) }
        return XPCWrapper(flags: flags, messageID: messageID, payload: dictionary)
    }

    public func encoded() -> Data {
        var body = ByteWriter()
        if let payload {
            body.u32(Self.payloadMagic)
            body.u32(Self.payloadVersion)
            XPCCodec.encode(payload, into: &body)
        }
        var out = ByteWriter()
        out.u32(Self.magic)
        out.u32(flags.rawValue)
        out.u64(UInt64(body.data.count))
        out.u64(messageID)
        out.data.append(body.data)
        return out.data
    }

    /// Reads a frame from the start of `data`. Returns the frame and the consumed length.
    /// - Throws: `.truncated` if `data` contains only part of the frame.
    public static func decode(_ data: Data) throws -> (XPCWrapper, Int) {
        var reader = ByteReader(data)
        let magic = try reader.u32()
        guard magic == Self.magic else { throw XPCWireError.badMagic(magic) }
        let flags = XPCFlags(rawValue: try reader.u32())
        let size = Int(try reader.u64())
        let messageID = try reader.u64()
        guard reader.remaining >= size else { throw XPCWireError.truncated }
        var payload: XPCValue?
        if size >= 8 {
            var body = ByteReader(reader.bytes(size))
            if (try? body.u32()) == Self.payloadMagic, (try? body.u32()) == Self.payloadVersion {
                payload = try? XPCCodec.decode(&body)
            }
        }
        return (XPCWrapper(flags: flags, messageID: messageID, payload: payload), headerSize + size)
    }
}

enum XPCCodec {
    static func encode(_ value: XPCValue, into out: inout ByteWriter) {
        switch value {
        case .null:
            out.u32(XPCType.null.rawValue)
        case .bool(let flag):
            out.u32(XPCType.bool.rawValue)
            out.u32(flag ? 1 : 0)
        case .int64(let number):
            out.u32(XPCType.int64.rawValue)
            out.u64(UInt64(bitPattern: number))
        case .uint64(let number):
            out.u32(XPCType.uint64.rawValue)
            out.u64(number)
        case .double(let number):
            out.u32(XPCType.double.rawValue)
            out.u64(number.bitPattern)
        case .date(let nanoseconds):
            out.u32(XPCType.date.rawValue)
            out.u64(UInt64(bitPattern: nanoseconds))
        case .data(let bytes):
            out.u32(XPCType.data.rawValue)
            out.u32(UInt32(bytes.count))
            out.data.append(bytes)
            out.pad(fromLength: 4 + bytes.count)
        case .string(let text):
            out.u32(XPCType.string.rawValue)
            let bytes = Data(text.utf8) + [0]
            out.u32(UInt32(bytes.count))
            out.data.append(bytes)
            out.pad(fromLength: 4 + bytes.count)
        case .uuid(let uuid):
            out.u32(XPCType.uuid.rawValue)
            out.data.append(withUnsafeBytes(of: uuid.uuid) { Data($0) })
        case .array(let items):
            out.u32(XPCType.array.rawValue)
            var body = ByteWriter()
            body.u32(UInt32(items.count))
            for item in items { encode(item, into: &body) }
            out.u32(UInt32(body.data.count))
            out.data.append(body.data)
        case .dictionary(let entries):
            out.u32(XPCType.dictionary.rawValue)
            var body = ByteWriter()
            body.u32(UInt32(entries.count))
            for entry in entries {
                let key = Data(entry.key.utf8) + [0]
                body.data.append(key)
                body.pad(fromLength: key.count)
                encode(entry.value, into: &body)
            }
            out.u32(UInt32(body.data.count))
            out.data.append(body.data)
        case .fileTransfer(let id, let size):
            out.u32(XPCType.fileTransfer.rawValue)
            out.u64(id)
            encode(["s": .uint64(size)], into: &out)
        case .unsupported(let type):
            out.u32(type)
        }
    }

    static func decode(_ reader: inout ByteReader) throws -> XPCValue {
        let rawType = try reader.u32()
        guard let type = XPCType(rawValue: rawType) else { return .unsupported(rawType) }
        switch type {
        case .null:
            return .null
        case .bool:
            return .bool(try reader.u32() != 0)
        case .int64:
            return .int64(Int64(bitPattern: try reader.u64()))
        case .uint64:
            return .uint64(try reader.u64())
        case .double:
            return .double(Double(bitPattern: try reader.u64()))
        case .date:
            return .date(Int64(bitPattern: try reader.u64()))
        case .fd:
            _ = try reader.u32()
            return .unsupported(rawType)
        case .data:
            let length = Int(try reader.u32())
            let bytes = try reader.take(length)
            try reader.skipPadding(afterLength: 4 + length)
            return .data(bytes)
        case .string:
            let length = Int(try reader.u32())
            let bytes = try reader.take(length)
            try reader.skipPadding(afterLength: 4 + length)
            let text = bytes.prefix { $0 != 0 }
            return .string(String(decoding: text, as: UTF8.self))
        case .uuid:
            let bytes = try reader.take(16)
            let uuid = bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
            return .uuid(UUID(uuid: uuid))
        case .array:
            let length = Int(try reader.u32())
            var body = ByteReader(try reader.take(length))
            let count = Int(try body.u32())
            var items: [XPCValue] = []
            items.reserveCapacity(min(count, 4096))
            for _ in 0..<count { items.append(try decode(&body)) }
            return .array(items)
        case .dictionary:
            let length = Int(try reader.u32())
            var body = ByteReader(try reader.take(length))
            let count = Int(try body.u32())
            var entries: [XPCEntry] = []
            for _ in 0..<count {
                let key = try body.cString()
                entries.append(XPCEntry(key, try decode(&body)))
            }
            return .dictionary(entries)
        case .fileTransfer:
            let id = try reader.u64()
            let info = try decode(&reader)
            if case .uint64(let size)? = info["s"] { return .fileTransfer(id: id, size: size) }
            return .fileTransfer(id: id, size: 0)
        }
    }
}

// MARK: - Byte helpers (little endian)

struct ByteWriter {
    var data = Data()

    mutating func u16be(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32be(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    /// Pad to 4 bytes, measured from the start of the value (like `Aligned(4, …)`).
    mutating func pad(fromLength length: Int) {
        let padding = (4 - length % 4) % 4
        data.append(contentsOf: [UInt8](repeating: 0, count: padding))
    }
}

struct ByteReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        offset = 0
    }

    var remaining: Int { data.count - offset }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw XPCWireError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func bytes(_ count: Int) -> Data {
        (try? take(count)) ?? Data()
    }

    mutating func u32() throws -> UInt32 {
        let bytes = try take(4)
        return bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    mutating func u64() throws -> UInt64 {
        let bytes = try take(8)
        return bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }

    mutating func skipPadding(afterLength length: Int) throws {
        _ = try take((4 - length % 4) % 4)
    }

    /// Null-terminated string, padded to 4 bytes.
    mutating func cString() throws -> String {
        guard let end = data[offset...].firstIndex(of: 0) else { throw XPCWireError.truncated }
        let length = end - offset + 1
        let bytes = try take(length)
        try skipPadding(afterLength: length)
        return String(decoding: bytes.dropLast(), as: UTF8.self)
    }
}
