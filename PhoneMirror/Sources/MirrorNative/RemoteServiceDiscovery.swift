// SPDX-License-Identifier: GPL-3.0-or-later
// RemoteServiceDiscovery (RSD) over the native tunnel, after pymobiledevice3
// (remote/remote_service_discovery.py, native_tunnel.py; GPL-3.0-or-later).
import Foundation
import os

/// Connection to the device's RSD: provides device properties and the service ports.
/// The RSD connection must stay open as long as services are in use.
public final class RemoteServiceDiscovery: @unchecked Sendable {
    public let tunnel: RemotePairingTunnel
    public let address: String
    public private(set) var peerInfo: XPCValue = .null
    private var control: RemoteXPCConnection?
    private static let logger = Logger(subsystem: "PhoneMirror", category: "rsd")

    private init(tunnel: RemotePairingTunnel, address: String) {
        self.tunnel = tunnel
        self.address = address
    }

    /// Open the tunnel and perform the RSD handshake (with retries: right after the tunnel is set up
    /// the device likes to reset the RSD connection and `remoted` picks a new port).
    public static func connect(udid: String? = nil) async throws -> RemoteServiceDiscovery {
        let tunnel = RemotePairingTunnel()
        let address = try await Task.detached { try tunnel.open(udid: udid) }.value
        let rsd = RemoteServiceDiscovery(tunnel: tunnel, address: address)
        let handshakeUUID = RSDLocator.remotedUUID() ?? UUID()
        var lastError: Error = NativeTunnelError.noRSDPort(address)
        for attempt in 0..<5 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(500)) }
            for port in RSDLocator.candidatePorts(tunnelAddress: address) {
                let connection = RemoteXPCConnection(host: address, port: port)
                do {
                    try await connection.connect()
                    try await connection.sendDeviceHandshake(uuid: handshakeUUID)
                    rsd.peerInfo = try await withTimeout(seconds: 5, "RSD-Handshake") { try await connection.receiveResponse() }
                    rsd.control = connection
                    logger.notice("RSD connected: [\(address, privacy: .public)]:\(port), \(rsd.services.count) services")
                    return rsd
                } catch {
                    lastError = error
                    connection.close()
                }
            }
        }
        tunnel.close()
        throw lastError
    }

    public var services: [String: XPCValue] {
        guard let entries = peerInfo["Services"]?.entries else { return [:] }
        return Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    public var properties: XPCValue { peerInfo["Properties"] ?? .null }

    public func port(of service: String) -> UInt16? {
        services[service]?["Port"]?.intValue.flatMap(UInt16.init(exactly:))
    }

    /// New RemoteXPC connection to a service (`UsesRemoteXPC`).
    public func connect(service: String) async throws -> RemoteXPCConnection {
        guard let port = port(of: service) else { throw RemoteXPCError.protocolError("Service \(service) not available") }
        let connection = RemoteXPCConnection(host: address, port: port)
        try await connection.connect()
        return connection
    }

    public func close() {
        control?.close()
        control = nil
        tunnel.close()
    }
}
