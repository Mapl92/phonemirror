// SPDX-License-Identifier: GPL-3.0-or-later
// RemoteXPC over HTTP/2, recreated after pymobiledevice3 (remote/remotexpc.py, GPL-3.0-or-later).
import Foundation
import Network
import os

public enum RemoteXPCError: LocalizedError {
    case connectionFailed(String)
    case closed
    case protocolError(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason): "Connection failed: \(reason)"
        case .closed: "Connection closed"
        case .protocolError(let reason): "RemoteXPC protocol error: \(reason)"
        case .timeout(let what): "Timed out: \(what)"
        }
    }
}

/// A TCP connection with `async` reading/writing (Network.framework).
final class TCPStream: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "PhoneMirror.tcp")
    private var buffer = Data()

    init(host: String, port: UInt16) {
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 5
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { state in
                let finish: (Result<Void, Error>) -> Void = { result in
                    guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                    continuation.resume(with: result)
                }
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error): finish(.failure(RemoteXPCError.connectionFailed(error.localizedDescription)))
                case .waiting(let error): finish(.failure(RemoteXPCError.connectionFailed(error.localizedDescription)))
                case .cancelled: finish(.failure(RemoteXPCError.closed))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: RemoteXPCError.connectionFailed(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    /// Reads exactly `count` bytes.
    func read(exactly count: Int) async throws -> Data {
        while buffer.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: RemoteXPCError.connectionFailed(error.localizedDescription)) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if isComplete { continuation.resume(throwing: RemoteXPCError.closed) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            buffer.append(chunk)
        }
        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(result)
    }

    func close() {
        connection.cancel()
    }

    var localAddress: String? {
        if case .hostPort(let host, _) = connection.currentPath?.localEndpoint { return "\(host)" }
        return nil
    }
}

/// Client side of a RemoteXPC connection (RSD or a single service).
public final class RemoteXPCConnection: @unchecked Sendable {
    static let rootChannel: UInt32 = 1
    static let replyChannel: UInt32 = 3
    static let initialWindowSize: UInt32 = 16 * 1024 * 1024
    static let windowUpdateThreshold = 1024 * 1024

    public let host: String
    public let port: UInt16
    private let stream: TCPStream
    private var nextMessageID: [UInt32: UInt64] = [rootChannel: 0, replyChannel: 0]
    private var pendingData = Data()
    private var pendingWindow: [UInt32: Int] = [:]
    // Outbound flow control: only file transfers come near the peer's windows, but every DATA frame
    // counts – otherwise a transfer overruns the window and the device answers GOAWAY (FLOW_CONTROL_ERROR).
    private var outboundConnectionWindow = 65_535
    private var peerInitialWindow = 65_535
    private var outboundStreamWindows: [UInt32: Int] = [:]
    private var bufferedDataFrames: [HTTP2Frame] = []
    private var finishedTransferStreams: Set<UInt32> = []
    private var nextOutboundStream: UInt32 = 5
    private let lock = NSLock()
    private static let logger = Logger(subsystem: "PhoneMirror", category: "remotexpc")

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        stream = TCPStream(host: host, port: port)
    }

    /// Connect via TCP and perform the HTTP/2/RemoteXPC handshake.
    /// The frame order matches devicectl (otherwise the device rejects with “missing version flags”).
    public func connect() async throws {
        try await stream.open()
        try await stream.send(HTTP2Frame.preface)
        try await send(.settings([
            (HTTP2Frame.settingsMaxConcurrentStreams, 100),
            (HTTP2Frame.settingsInitialWindowSize, Self.initialWindowSize),
        ]))
        try await send(.windowUpdate(streamID: 0, increment: Self.initialWindowSize - 65_535))
        try await send(HTTP2Frame(.headers, flags: .endHeaders, streamID: Self.rootChannel))
        try await sendRequest([:])
        try await send(HTTP2Frame(.headers, flags: .endHeaders, streamID: Self.replyChannel))
        try await send(HTTP2Frame(.data, streamID: Self.rootChannel, payload: XPCWrapper(flags: XPCFlags(rawValue: 0x0201)).encoded()))
        try await send(HTTP2Frame(.data, streamID: Self.replyChannel, payload: XPCWrapper(flags: [.alwaysSet, .initHandshake]).encoded()))
        nextMessageID[Self.replyChannel, default: 0] += 1

        // Read until the device's SETTINGS, then acknowledge.
        while true {
            let frame = try await withTimeout(seconds: 5, "HTTP/2-SETTINGS") { try await self.receiveFrame() }
            applyFlowControl(frame)
            if frame.type == .settings, !frame.flags.contains(.ack) { break }
            if frame.type == .goAway { throw RemoteXPCError.protocolError("GOAWAY in handshake") }
        }
        try await send(.settings([], ack: true))
    }

    /// RSD handshake: announces this client as a modern RemoteXPC peer.
    public func sendDeviceHandshake(uuid: UUID) async throws {
        try await sendRequest([
            "MessageType": "Handshake",
            "MessagingProtocolVersion": .uint64(7),
            "UUID": .uuid(uuid),
            "Properties": [
                "RemoteXPCVersionFlags": .uint64(0x0100_0000_0000_0006),
                "SensitivePropertiesVisible": true,
            ],
            "Services": [:],
        ])
    }

    public func sendRequest(_ dictionary: XPCValue, wantingReply: Bool = false) async throws {
        let messageID = nextMessageID[Self.rootChannel, default: 0]
        let wrapper = XPCWrapper.request(dictionary, messageID: messageID, wantingReply: wantingReply).encoded()
        // Split large messages into frames of at most 16 KiB (default MAX_FRAME_SIZE).
        var offset = 0
        while offset < wrapper.count {
            let end = min(offset + 16_384, wrapper.count)
            try await send(HTTP2Frame(.data, streamID: Self.rootChannel, payload: wrapper.subdata(in: offset..<end)))
            offset = end
        }
        // Our own IDs are odd (initiator); only the empty handshake message has 0.
        nextMessageID[Self.rootChannel] = (messageID + 1) | 1
    }

    /// Next response as a dictionary (empty dictionaries are skipped).
    public func receiveResponse() async throws -> XPCValue {
        while true {
            let frame = try await receiveDataFrame()
            pendingData.append(frame.payload)
            while !pendingData.isEmpty {
                let wrapper: XPCWrapper
                let consumed: Int
                do {
                    (wrapper, consumed) = try XPCWrapper.decode(pendingData)
                } catch XPCWireError.truncated {
                    break
                }
                pendingData.removeFirst(consumed)
                if let payload = wrapper.payload, let entries = payload.entries, !entries.isEmpty {
                    return payload
                }
            }
        }
    }

    public func sendReceive(_ dictionary: XPCValue) async throws -> XPCValue {
        try await sendRequest(dictionary, wantingReply: true)
        return try await receiveResponse()
    }

    public func close() {
        stream.close()
    }

    /// Own address in the tunnel (destination for RTP from the device).
    public var localAddress: String? {
        stream.localAddress?.split(separator: "%").first.map(String.init)
    }

    // MARK: Frames

    private func send(_ frame: HTTP2Frame) async throws {
        if frame.type == .data {
            outboundConnectionWindow -= frame.payload.count
            outboundStreamWindows[frame.streamID] = outboundWindow(frame.streamID) - frame.payload.count
        }
        try await stream.send(frame.encoded())
    }

    private func outboundWindow(_ stream: UInt32) -> Int {
        outboundStreamWindows[stream] ?? peerInitialWindow
    }

    /// Applies WINDOW_UPDATE and SETTINGS from the peer. Returns whether the frame was one of them.
    @discardableResult
    private func applyFlowControl(_ frame: HTTP2Frame) -> Bool {
        switch frame.type {
        case .windowUpdate:
            if frame.streamID == 0 {
                outboundConnectionWindow += Int(frame.windowIncrement)
            } else {
                outboundStreamWindows[frame.streamID] = outboundWindow(frame.streamID) + Int(frame.windowIncrement)
            }
            return true
        case .settings where !frame.flags.contains(.ack):
            if let value = frame.settingsValues.first(where: { $0.0 == HTTP2Frame.settingsInitialWindowSize })?.1 {
                // A new INITIAL_WINDOW_SIZE shifts every open stream's window retroactively.
                let delta = Int(value) - peerInitialWindow
                peerInitialWindow = Int(value)
                for key in outboundStreamWindows.keys { outboundStreamWindows[key]! += delta }
            }
            return true
        default:
            return false
        }
    }

    /// Pushes the payload of a `.fileTransfer(id:size:)` announced in the preceding request.
    /// The bytes travel on a new client stream (odd ID) whose first frame carries `id` as message ID;
    /// the device acknowledges only after the payload, so it is sent without waiting.
    public func sendFileTransfer(id: UInt64, data: Data) async throws {
        let streamID = nextOutboundStream
        nextOutboundStream += 2
        try await send(HTTP2Frame(.headers, flags: .endHeaders, streamID: streamID))
        let preamble = XPCWrapper(flags: [.alwaysSet, .fileTransferRequest], messageID: id).encoded()
        var pending = preamble + data
        while !pending.isEmpty {
            var budget = min(outboundConnectionWindow, outboundWindow(streamID), 16_384)
            while budget <= 0 {
                let frame = try await withTimeout(seconds: 30, "flow-control window for file transfer") {
                    try await self.receiveFrame()
                }
                if !applyFlowControl(frame) { try await handleWhileSending(frame) }
                budget = min(outboundConnectionWindow, outboundWindow(streamID), 16_384)
            }
            let chunk = pending.prefix(budget)
            try await send(HTTP2Frame(.data, streamID: streamID, payload: Data(chunk)))
            pending.removeFirst(chunk.count)
        }
        try await send(HTTP2Frame(.data, flags: .endStream, streamID: streamID))
        finishedTransferStreams.insert(streamID)
    }

    /// A frame that arrived while waiting for window: keep data for `receiveResponse`.
    private func handleWhileSending(_ frame: HTTP2Frame) async throws {
        switch frame.type {
        case .data:
            if !frame.payload.isEmpty { try await replenish(stream: frame.streamID, by: frame.payload.count) }
            bufferedDataFrames.append(frame)
        case .goAway:
            throw RemoteXPCError.protocolError("GOAWAY")
        case .rstStream where !finishedTransferStreams.contains(frame.streamID):
            throw RemoteXPCError.protocolError("RST_STREAM on stream \(frame.streamID)")
        case .ping where !frame.flags.contains(.ack):
            try await send(HTTP2Frame(.ping, flags: .ack, streamID: 0, payload: frame.payload))
        default:
            break
        }
    }

    private func receiveFrame() async throws -> HTTP2Frame {
        let header = try await stream.read(exactly: HTTP2Frame.headerSize)
        let length = HTTP2Frame.payloadLength(header: header)
        let payload = length > 0 ? try await stream.read(exactly: length) : Data()
        return HTTP2Frame.decode(header: header, payload: payload)
    }

    private func receiveDataFrame() async throws -> HTTP2Frame {
        if !bufferedDataFrames.isEmpty { return bufferedDataFrames.removeFirst() }
        while true {
            let frame = try await receiveFrame()
            if applyFlowControl(frame) { continue }
            switch frame.type {
            case .data:
                if !frame.payload.isEmpty { try await replenish(stream: frame.streamID, by: frame.payload.count) }
                return frame
            case .goAway:
                throw RemoteXPCError.protocolError("GOAWAY")
            case .rstStream:
                if finishedTransferStreams.contains(frame.streamID) { continue }
                throw RemoteXPCError.protocolError("RST_STREAM on stream \(frame.streamID)")
            case .ping where !frame.flags.contains(.ack):
                try await send(HTTP2Frame(.ping, flags: .ack, streamID: 0, payload: frame.payload))
            default:
                continue
            }
        }
    }

    /// Refill the receive window so the device may keep sending.
    private func replenish(stream id: UInt32, by count: Int) async throws {
        let pending = pendingWindow[id, default: 0] + count
        guard pending >= Self.windowUpdateThreshold else {
            pendingWindow[id] = pending
            return
        }
        pendingWindow[id] = 0
        try await send(.windowUpdate(streamID: 0, increment: UInt32(pending)))
        try await send(.windowUpdate(streamID: id, increment: UInt32(pending)))
    }
}

/// Runs `body` with a time limit.
func withTimeout<T: Sendable>(seconds: Double, _ what: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw RemoteXPCError.timeout(what)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
