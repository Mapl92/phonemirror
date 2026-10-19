// SPDX-License-Identifier: GPL-3.0-or-later
// Access to the existing CoreDevice tunnel via remotepairingd, recreated after pymobiledevice3
// (remote/native_tunnel.py, GPL-3.0-or-later).
import Darwin
import Foundation
import os
@preconcurrency import XPC

/// Value used from several threads (XPC queue, caller), protected by a lock.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

public enum NativeTunnelError: LocalizedError {
    case deviceNotFound
    case pairing(String)
    case noTunnelAddress
    case noRSDPort(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound: "remotepairingd reports no paired device"
        case .pairing(let message): "Pairing: \(message)"
        case .noTunnelAddress: "remotepairingd returned no tunnel address"
        case .noRSDPort(let address): "No RSD port from remoted to \(address) found"
        case .timeout(let what): "Timed out waiting for \(what)"
        }
    }
}

/// Holds an assertion on the device's tunnel via `com.apple.CoreDevice.remotepairingd`.
/// The tunnel address is routable for normal processes – without root, entitlement or Xcode.
public final class RemotePairingTunnel: @unchecked Sendable {
    public private(set) var tunnelAddress: String?
    public private(set) var udid: String?

    private let queue = DispatchQueue(label: "PhoneMirror.remotepairing")
    private var browseConnection: xpc_connection_t?
    private var deviceConnection: xpc_connection_t?
    private var assertionIdentifier: xpc_object_t?
    private static let logger = Logger(subsystem: "PhoneMirror", category: "tunnel")
    private static let replyTimeout: Double = 10

    public init() {}

    deinit {
        close()
    }

    /// Find the device (`udid` or the first one), pair if needed, create an assertion. Returns the tunnel IPv6.
    public func open(udid wanted: String? = nil) throws -> String {
        let endpoint = try browse(udid: wanted)
        let device = xpc_connection_create_from_endpoint(endpoint)
        xpc_connection_set_event_handler(device) { _ in }
        xpc_connection_activate(device)
        deviceConnection = device

        // Already paired is reported as RemotePairingError 1002 – harmless.
        let initiate = try request(device, "RemotePairing.InitiatePairingCommand") { body in
            xpc_dictionary_set_bool(body, "requireNonInteractive", false)
        }
        if let error = xpc_dictionary_get_value(initiate, "error") {
            let code = xpc_dictionary_get_int64(error, "code")
            if code != 1002 { throw NativeTunnelError.pairing("Code \(code)") }
        }

        let assertion = try request(device, "RemotePairing.CreateAssertionCommand") { body in
            xpc_dictionary_set_int64(body, "flags", 0)
        }
        guard let response = xpc_dictionary_get_value(assertion, "response") else {
            throw NativeTunnelError.pairing("CreateAssertion without response")
        }
        assertionIdentifier = xpc_dictionary_get_value(response, "assertionIdentifier")
        guard let info = xpc_dictionary_get_value(response, "info"),
              let address = xpc_dictionary_get_string(info, "tunnelIPAddress")
        else { throw NativeTunnelError.noTunnelAddress }
        tunnelAddress = String(cString: address)
        return tunnelAddress!
    }

    public func close() {
        if let device = deviceConnection, let assertion = assertionIdentifier {
            _ = try? request(device, "RemotePairing.ReleaseAssertionRequest") { body in
                xpc_dictionary_set_value(body, "assertionIdentifier", assertion)
            }
        }
        assertionIdentifier = nil
        if let deviceConnection { xpc_connection_cancel(deviceConnection) }
        if let browseConnection { xpc_connection_cancel(browseConnection) }
        deviceConnection = nil
        browseConnection = nil
    }

    private func browse(udid wanted: String?) throws -> xpc_endpoint_t {
        let connection = xpc_connection_create_mach_service("com.apple.CoreDevice.remotepairingd", queue, 0)
        let found = DispatchSemaphore(value: 0)
        let result = LockedBox<(endpoint: xpc_endpoint_t, udid: String)?>(nil)

        xpc_connection_set_event_handler(connection) { event in
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY,
                  let value = xpc_dictionary_get_value(event, "value"),
                  let deviceFound = xpc_dictionary_get_value(value, "deviceFound"),
                  let zero = xpc_dictionary_get_value(deviceFound, "_0"),
                  let info = xpc_dictionary_get_value(zero, "deviceInfo"),
                  let endpoint = xpc_dictionary_get_value(info, "endpoint")
            else { return }
            let udid = xpc_dictionary_get_string(info, "udid").map { String(cString: $0) } ?? ""
            if let wanted, udid != wanted { return }
            let isFirst = result.withLock { current in
                guard current == nil else { return false }
                current = (endpoint, udid)
                return true
            }
            if isFirst { found.signal() }
        }
        xpc_connection_activate(connection)
        browseConnection = connection

        // Mercury discards requests without a reply channel – so send with reply and ignore the reply.
        let message = xpc_dictionary_create(nil, nil, 0)
        let body = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(body, "currentDevicesOnly", false)
        xpc_dictionary_set_string(message, "mangledTypeName", "RemotePairing.BrowseRequest")
        xpc_dictionary_set_value(message, "value", body)
        xpc_connection_send_message_with_reply(connection, message, queue) { _ in }

        guard found.wait(timeout: .now() + Self.replyTimeout) == .success,
              let device = result.withLock({ $0 })
        else { throw NativeTunnelError.deviceNotFound }
        udid = device.udid
        return device.endpoint
    }

    /// Send `{mangledTypeName, value}` and wait synchronously for the reply.
    private func request(_ connection: xpc_connection_t, _ typeName: String, body setup: (xpc_object_t) -> Void) throws -> xpc_object_t {
        let body = xpc_dictionary_create(nil, nil, 0)
        setup(body)
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "mangledTypeName", typeName)
        xpc_dictionary_set_value(message, "value", body)
        let done = DispatchSemaphore(value: 0)
        let reply = LockedBox<xpc_object_t?>(nil)
        xpc_connection_send_message_with_reply(connection, message, queue) { response in
            reply.withLock { $0 = response }
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.replyTimeout) == .success, let response = reply.withLock({ $0 }) else {
            throw NativeTunnelError.timeout(typeName)
        }
        if xpc_get_type(response) == XPC_TYPE_ERROR {
            throw NativeTunnelError.pairing("\(typeName): XPC error")
        }
        return response
    }
}

/// Finds the RSD port in the tunnel and the handshake UUID of `remoted`.
public enum RSDLocator {
    /// `remoted`'s TCP connections to the tunnel address – according to `nettop` (the only Apple tool with a
    /// suitable entitlement that sees other processes' sockets; from macOS 27 on also without root).
    public static func candidatePorts(tunnelAddress: String) -> [UInt16] {
        guard let output = run("/usr/bin/nettop", ["-n", "-x", "-L", "1", "-m", "tcp", "-J", "interface,state"]) else { return [] }
        let target = normalizedIPv6(tunnelAddress)
        var ports: [UInt16] = []
        var pid: Int32?
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let first = fields.first else { continue }
            if first.hasPrefix("tcp4 ") || first.hasPrefix("tcp6 ") {
                guard let pid, fields.count >= 3, fields[2] == "Established",
                      let arrow = first.range(of: "<->")
                else { continue }
                let foreign = String(first[arrow.upperBound...])
                guard let (address, port) = splitEndpoint(foreign), normalizedIPv6(address) == target,
                      processPath(pid) == "/usr/libexec/remoted"
                else { continue }
                ports.append(port)
            } else if let dot = first.lastIndex(of: "."), let number = Int32(first[first.index(after: dot)...]) {
                pid = number
            } else {
                pid = nil
            }
        }
        return ports
    }

    /// UUID with which `remoted` registers with the device (`remotectl dumpstate`). The same value must be
    /// sent on `remoted`'s tunnel, otherwise iOS 27.2 and later closes the services just offered.
    public static func remotedUUID() -> UUID? {
        guard let output = run("/usr/libexec/remotectl", ["dumpstate"]) else { return nil }
        let lines = output.components(separatedBy: "\n")
        guard let index = lines.firstIndex(of: "Local device"), index + 1 < lines.count else { return nil }
        let line = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("UUID: ") else { return nil }
        return UUID(uuidString: String(line.dropFirst(6)))
    }

    static func splitEndpoint(_ endpoint: String) -> (String, UInt16)? {
        let separator: Character = endpoint.filter { $0 == ":" }.count == 1 ? ":" : "."
        guard let index = endpoint.lastIndex(of: separator), let port = UInt16(endpoint[endpoint.index(after: index)...]) else { return nil }
        let address = endpoint[..<index].split(separator: "%").first.map(String.init) ?? ""
        return (address, port)
    }

    static func normalizedIPv6(_ address: String) -> [UInt8]? {
        var raw = in6_addr()
        guard inet_pton(AF_INET6, address, &raw) == 1 else { return nil }
        return withUnsafeBytes(of: raw) { Array($0) }
    }

    static func processPath(_ pid: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
