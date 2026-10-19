// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// Makes sure the Developer Disk Image is mounted on the iPhone – only then do
/// `com.apple.coredevice.displayservice` and the HID services exist. Uses Xcode's `devicectl`, which
/// personalizes and mounts the DDI if needed (only possible while the iPhone is unlocked).
///
/// Must run *before* `serve-web --native`: afterwards pymobiledevice3 shares the tunnel with `remoted`,
/// and devicectl temporarily sees the device as disconnected.
public enum DevicePreparation {
    public enum Outcome: Sendable, Equatable {
        case ready(deviceName: String)
        case locked(deviceName: String)
        case noDevice
        case failed(String)
    }

    public static func ensureDeveloperDiskImage() async -> Outcome {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneMirror-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let listURL = directory.appendingPathComponent("devices.json")
        guard await run(["devicectl", "list", "devices", "--json-output", listURL.path]) == 0,
              let data = try? Data(contentsOf: listURL),
              let list = try? JSONDecoder().decode(DeviceList.self, from: data)
        else { return .failed("devicectl list devices failed") }

        guard let device = list.result.devices.first(where: { $0.isPairedIPhone }) else { return .noDevice }
        let name = device.deviceProperties?.name ?? "iPhone"
        let target = device.hardwareProperties?.udid ?? device.identifier

        let ddiURL = directory.appendingPathComponent("ddi.json")
        let status = await run(["devicectl", "device", "info", "ddiServices", "--device", target, "--json-output", ddiURL.path])
        if status == 0 { return .ready(deviceName: name) }
        let details = (try? String(contentsOf: ddiURL, encoding: .utf8)) ?? ""
        if details.contains("locked") || details.contains("10003") { return .locked(deviceName: name) }
        return .failed("Developer Disk Image could not be mounted (status \(status))")
    }

    /// Tunnel address and UDID of the paired iPhone according to devicectl (only when connected).
    public static func currentEndpoint() async -> DeviceEndpoint? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneMirror-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let listURL = directory.appendingPathComponent("devices.json")
        guard await run(["devicectl", "list", "devices", "--json-output", listURL.path]) == 0,
              let data = try? Data(contentsOf: listURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]]
        else { return nil }
        for device in devices {
            let hardware = device["hardwareProperties"] as? [String: Any]
            let connection = device["connectionProperties"] as? [String: Any]
            guard hardware?["platform"] as? String == "iOS", let udid = hardware?["udid"] as? String,
                  let address = connection?["tunnelIPAddress"] as? String
            else { continue }
            return DeviceEndpoint(tunnelAddress: address, udid: udid)
        }
        return nil
    }

    private static func run(_ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                Logger(subsystem: "PhoneMirror", category: "prepare").error("xcrun: \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: -1)
            }
        }
    }

    private struct DeviceList: Decodable {
        struct Result: Decodable { var devices: [Device] }
        var result: Result
    }

    struct Device: Decodable {
        struct Hardware: Decodable {
            var platform: String?
            var udid: String?
            var deviceType: String?
        }
        struct Connection: Decodable { var pairingState: String? }
        struct Properties: Decodable { var name: String? }
        var identifier: String
        var hardwareProperties: Hardware?
        var connectionProperties: Connection?
        var deviceProperties: Properties?

        var isPairedIPhone: Bool {
            hardwareProperties?.platform == "iOS" && hardwareProperties?.deviceType == "iPhone"
                && connectionProperties?.pairingState == "paired"
        }
    }
}
