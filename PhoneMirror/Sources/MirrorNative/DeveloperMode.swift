// SPDX-License-Identifier: GPL-3.0-or-later
// Lockdown services over RSD (".shim.remote") and AMFI's Developer Mode switch, recreated after
// pymobiledevice3 (remote/remote_service_discovery.py, services/amfi.py; GPL-3.0-or-later).
import Foundation

public enum LockdownShimError: LocalizedError {
    case unavailable(String)
    case checkin(String)
    case malformed

    public var errorDescription: String? {
        switch self {
        case .unavailable(let service): "The iPhone does not offer \(service)"
        case .checkin(let message): "Lockdown check-in failed: \(message)"
        case .malformed: "Unexpected lockdown reply"
        }
    }
}

/// A lockdown service reached through the tunnel: plists framed with a 4-byte big-endian length,
/// started with an `RSDCheckin` instead of lockdownd's StartService.
final class LockdownShimConnection: @unchecked Sendable {
    private let stream: TCPStream

    private init(stream: TCPStream) {
        self.stream = stream
    }

    static func open(rsd: RemoteServiceDiscovery, service: String) async throws -> LockdownShimConnection {
        guard let port = rsd.port(of: service) else { throw LockdownShimError.unavailable(service) }
        let stream = TCPStream(host: rsd.address, port: port)
        try await stream.open()
        let connection = LockdownShimConnection(stream: stream)
        do {
            try await connection.send(["Label": "PhoneMirror", "ProtocolVersion": "2", "Request": "RSDCheckin"])
            let checkin = try await connection.receive()
            guard checkin["Request"] as? String == "RSDCheckin" else { throw LockdownShimError.checkin("\(checkin)") }
            let start = try await connection.receive()
            if let error = start["Error"] as? String { throw LockdownShimError.checkin(error) }
        } catch {
            stream.close()
            throw error
        }
        return connection
    }

    func send(_ message: [String: Any]) async throws {
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var frame = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
        frame.append(body)
        try await stream.send(frame)
    }

    func receive() async throws -> [String: Any] {
        try Self.parse(try await receiveRaw())
    }

    private func receiveRaw() async throws -> Data {
        let header = [UInt8](try await stream.read(exactly: 4))
        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        return try await stream.read(exactly: length)
    }

    private static func parse(_ body: Data) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw LockdownShimError.malformed
        }
        return plist
    }

    func request(_ message: [String: Any]) async throws -> [String: Any] {
        try await send(message)
        return try Self.parse(try await withTimeout(seconds: 15, "lockdown reply") { try await self.receiveRaw() })
    }

    func close() {
        stream.close()
    }
}

/// Developer Mode: status via lockdown, the hidden Settings switch via AMFI.
public enum DeveloperMode {
    static let lockdownService = "com.apple.mobile.lockdown.remote.trusted"
    static let amfiService = "com.apple.amfi.lockdown.shim.remote"

    /// `nil` if the device does not say (older iOS).
    public static func isEnabled(rsd: RemoteServiceDiscovery) async throws -> Bool? {
        let lockdown = try await LockdownShimConnection.open(rsd: rsd, service: lockdownService)
        defer { lockdown.close() }
        let reply = try await lockdown.request([
            "Label": "PhoneMirror", "Request": "GetValue",
            "Domain": "com.apple.security.mac.amfi", "Key": "DeveloperModeStatus",
        ])
        return reply["Value"] as? Bool
    }

    /// Makes Settings › Privacy & Security › Developer Mode visible on the iPhone (AMFI "reveal").
    /// Turning it on stays with the user: iOS asks for a restart and a confirmation.
    public static func revealSetting(rsd: RemoteServiceDiscovery) async throws {
        let amfi = try await LockdownShimConnection.open(rsd: rsd, service: amfiService)
        defer { amfi.close() }
        let reply = try await amfi.request(["action": 0])
        guard reply["success"] as? Bool == true else {
            throw LockdownShimError.checkin((reply["Error"] as? String) ?? "AMFI did not confirm (\(reply))")
        }
    }
}
