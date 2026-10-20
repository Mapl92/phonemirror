// SPDX-License-Identifier: GPL-3.0-or-later
// Tests the native transport layer by layer against a real iPhone.
// Usage: native-probe tunnel | rsd | video [seconds] | audio [seconds] | ddi [status|unmount|mount]
import Foundation
import MirrorCore
import MirrorNative

let command = CommandLine.arguments.dropFirst().first ?? "rsd"

do {
    switch command {
    case "tunnel":
        let tunnel = RemotePairingTunnel()
        let address = try tunnel.open()
        print("Tunnel: [\(address)] udid=\(tunnel.udid ?? "?")")
        print("RSD ports from remoted: \(RSDLocator.candidatePorts(tunnelAddress: address))")
        print("remoted UUID: \(RSDLocator.remotedUUID()?.uuidString ?? "unknown")")
        tunnel.close()
    case "rsd":
        let rsd = try await RemoteServiceDiscovery.connect()
        let properties = rsd.properties
        print("Device: \(properties["ProductType"]?.stringValue ?? "?") iOS \(properties["OSVersion"]?.stringValue ?? "?")")
        print("\(rsd.services.count) services")
        let all = CommandLine.arguments.dropFirst(2).first == "all"
        for name in rsd.services.keys.sorted() where all || name.contains("display") || name.contains("hid") || name.contains("pasteboard") || name.contains("devicecontrol") {
            print("  \(name) → Port \(rsd.port(of: name).map(String.init) ?? "?")")
        }
        rsd.close()
    case "device":
        // native-probe device – what remotepairingd knows about the device (no tunnel).
        let tunnel = RemotePairingTunnel()
        try tunnel.find()
        print(tunnel.deviceDescription)
        tunnel.close()
    case "pairing":
        // native-probe pairing <MangledType> [timeout] [key=true …] – e.g. RemotePairing.UnpairRequest
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        let type = arguments.first ?? "RemotePairing.InitiatePairingCommand"
        let timeout = arguments.count > 1 ? Double(arguments[1]) ?? 10 : 10
        var flags: [String: Bool] = [:]
        var strings: [String: String] = [:]
        for pair in arguments.dropFirst(2) {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[1] == "true" || parts[1] == "false" { flags[parts[0]] = parts[1] == "true" } else { strings[parts[0]] = parts[1] }
        }
        let tunnel = RemotePairingTunnel()
        print(try tunnel.command(type, timeout: timeout, flags: flags, strings: strings))
        tunnel.close()
    case "devmode":
        // native-probe devmode [reveal]
        let rsd = try await RemoteServiceDiscovery.connect()
        defer { rsd.close() }
        print("Developer Mode enabled: \(try await DeveloperMode.isEnabled(rsd: rsd).map(String.init) ?? "unknown")")
        if CommandLine.arguments.dropFirst(2).first == "reveal" {
            try await DeveloperMode.revealSetting(rsd: rsd)
            print("Developer Mode switch revealed in Settings")
        }
    case "deviceinfo":
        let rsd = try await RemoteServiceDiscovery.connect()
        defer { rsd.close() }
        let info = DeviceInfoService(connection: try await rsd.connect(service: DeviceInfoService.name))
        func dump(_ value: XPCValue, _ indent: String = "") -> String {
            switch value {
            case .dictionary(let entries):
                return entries.filter { $0.key != "availableModes" }.map { "\(indent)\($0.key): " + dump($0.value, indent + "  ").trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            case .array(let items): return "[" + items.map { dump($0) }.joined(separator: ", ") + "]"
            case .double(let d): return String(d)
            case .int64(let i): return String(i)
            case .uint64(let u): return String(u)
            case .bool(let b): return String(b)
            case .string(let t): return t
            default: return "\(value)"
            }
        }
        print("== display info"); print(dump(try await info.displayInfo()))
        print("== lock state"); print(dump(try await info.lockState()))
        if rsd.port(of: "com.apple.coredevice.devicecontrol") != nil { print("devicecontrol available") }
    case "rotate":
        // native-probe rotate left|right
        let rsd = try await RemoteServiceDiscovery.connect()
        defer { rsd.close() }
        let control = DeviceControlService(connection: try await rsd.connect(service: DeviceControlService.name))
        let result = try await control.rotate(clockwise: CommandLine.arguments.dropFirst(2).first == "right")
        try await Task.sleep(for: .seconds(1))
        let info = DeviceInfoService(connection: try await rsd.connect(service: DeviceInfoService.name))
        let display = try await info.displayInfo()
        print("device: \(result ?? "?"), content: \(DeviceOrientation(displayInfo: display).map { "\($0)" } ?? "?")")
    case "ddi":
        // native-probe ddi [status|unmount|mount]
        let action = CommandLine.arguments.dropFirst(2).first ?? "status"
        if action == "import" {
            // native-probe ddi import <Xcode.xip | Xcode.app | .pkg | .dmg | folder>
            let source = URL(fileURLWithPath: CommandLine.arguments.dropFirst(3).first ?? "/Applications/Xcode.app")
            let started = Date()
            let info = try await DeveloperDiskImageStore.importDDI(from: source) { print("  \($0)") }
            print("Imported \(info.build) to \(info.restoreDirectory.path) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            print("Selected DDI: \(DeveloperDiskImageStore.installed().map { "\($0.build) at \($0.restoreDirectory.path)" } ?? "none")")
            break
        }
        let rsd = try await RemoteServiceDiscovery.connect()
        defer { rsd.close() }
        print("iOS \(rsd.properties["OSVersion"]?.stringValue ?? "?"), display service: \(rsd.port(of: DisplayService.name) != nil ? "present" : "missing")")
        switch action {
        case "unmount":
            try await DeveloperDiskImageMounter.unmount(rsd: rsd)
            print("DDI removed")
        case "mount":
            let started = Date()
            let mounted = try await DeveloperDiskImageMounter.mountIfNeeded(rsd: rsd)
            print(mounted ? "DDI mounted natively in \(String(format: "%.1f", Date().timeIntervalSince(started))) s" : "DDI was already mounted")
        default:
            print("DDI mounted: \(try await DeveloperDiskImageMounter.isMounted(rsd: rsd))")
        }
    case "video", "audio":
        let seconds = Double(CommandLine.arguments.dropFirst(2).first ?? "5") ?? 5
        let rsd = try await RemoteServiceDiscovery.connect()
        defer { rsd.close() }
        let connection = try await rsd.connect(service: DisplayService.name)
        let display = DisplayService(connection: connection)
        print("Media-Support: \(try await display.mediaSupportInfo()["avcFrameworkVersion"]?.stringValue ?? "?")")
        let receiver = try RTPReceiver()
        let localIP = connection.localAddress ?? "?"
        let kind: DisplayService.Kind = command == "video" ? .video : .audio
        let answer = try await display.startStream(kind, receiverIP: localIP, receiverPort: receiver.port, senderIP: rsd.address, sessionID: UUID())
        print("Stream started: local [\(localIP)]:\(receiver.port), device port \(answer.sourcePort), SSRC \(answer.deviceSSRC)/\(answer.ourSSRC)")
        let stats = ProbeStats()
        let decoder = kind == .audio ? try AACELDDecoder() : nil
        receiver.start(deviceAddress: rsd.address, answer: answer) { packet in
            if let decoder {
                guard let rtp = RTPPacket(packet), let pcm = try? decoder.decode(rtp.payload) else { stats.add(error: true); return }
                stats.add(bytes: pcm.count)
            } else {
                stats.add(packet: packet)
            }
        }
        try await Task.sleep(for: .seconds(seconds))
        receiver.stop()
        try? await display.stopAllStreams()
        print(stats.summary(kind: kind, seconds: seconds))
    case "apps":
        let rsd = try await RemoteServiceDiscovery.connect()
        defer { rsd.close() }
        let connection = try await rsd.connect(service: AppService.name)
        let raw = try await AppService(connection: connection).service.streamInvoke(feature: "com.apple.coredevice.feature.streamapplist", input: [
            "includeAppClips": false, "includeRemovableApps": true, "includeHiddenApps": false, "includeInternalApps": false,
            "includeDefaultApps": true, "requireContainerAccess": false, "includeAppGroupIdentifiers": false, "includeContainerPaths": false,
        ])
        connection.close()
        print("\(raw.count) apps; fields: \(raw.first?.entries?.map(\.key).sorted().joined(separator: ", ") ?? "-")")
        let settings = raw.first { $0["bundleIdentifier"]?.stringValue == "com.apple.Preferences" }
        print("Settings: \(settings.map { describeStructure($0, indent: 1) } ?? "not found")")
        if CommandLine.arguments.dropFirst(2).first == "launch" {
            let launcher = try await rsd.connect(service: AppService.name)
            let bundleID = CommandLine.arguments.dropFirst(3).first ?? "com.apple.Preferences"
            try await AppService(connection: launcher).launch(bundleID: bundleID)
            launcher.close()
            print("\(bundleID) launched")
        }
    case "clipboard":
        // Print only the structure (keys, types, lengths) – no contents.
        let rsd = try await RemoteServiceDiscovery.connect()
        defer { rsd.close() }
        if CommandLine.arguments.dropFirst(2).first == "set-rich" {
            // Like a Safari copy: HTML as the primary type, text only as a secondary type.
            let text = CommandLine.arguments.dropFirst(3).first ?? "PhoneMirror Rich"
            let connection = try await rsd.connect(service: PasteboardService.name)
            let html = XPCValue.data(Data("<b>\(text)</b>".utf8)), plain = XPCValue.data(Data(text.utf8))
            _ = try await connection.sendReceive([
                "command": "SET", "pasteboardName": "general",
                "items": .array([["types": .array(["public.html", "public.utf8-plain-text"]),
                                   "data": ["public.html": ["data": html], "public.utf8-plain-text": ["data": plain]]]]),
                "sourceMetadata": .null,
            ])
            connection.close()
            print("Rich test text set")
        }
        if CommandLine.arguments.dropFirst(2).first == "set" {
            let setter = PasteboardService { try await rsd.connect(service: PasteboardService.name) }
            try await setter.set(.text(CommandLine.arguments.dropFirst(3).first ?? "PhoneMirror Test"))
            print("Test text set")
        }
        for policy in ["allPromised", "promiseSecondary"] {
            let connection = try await rsd.connect(service: PasteboardService.name)
            let reply = try await connection.sendReceive(["command": "PULL", "pasteboardName": "general", "dataPolicy": [policy: [:]]])
            connection.close()
            print("== \(policy)")
            print(describeStructure(reply, indent: 1))
            if let error = reply["error"] {
                print("   domain: \(error["domain"]?.stringValue ?? "?")")
                print("   text: \(error["userInfo"]?["NSLocalizedDescription"]?.stringValue ?? "?")")
            }
        }
        let pasteboard = PasteboardService { try await rsd.connect(service: PasteboardService.name) }
        print("changeID: \(String(describing: try await pasteboard.changeID()))")
        switch try await pasteboard.content() {
        case .text(let text): print("content: Text, \(text.count) characters")
        case .png(let png): print("content: PNG, \(png.count) bytes")
        case .html(let html): print("content: HTML, \(html.count) bytes")
        case .rtf(let rtf): print("content: RTF, \(rtf.count) bytes")
        case nil: print("content: nil")
        }
    default:
        print("Unknown command \(command)")
    }
} catch {
    print("ERROR: \(error.localizedDescription)")
    exit(1)
}

final class ProbeStats: @unchecked Sendable {
    private let lock = NSLock()
    private var depacketizer = RTPHEVCDepacketizer()
    private var packets = 0, frames = 0, keyframes = 0, errors = 0, pcmBytes = 0
    private var size: String = "?"
    private var builder = HEVCSampleBuilder()

    func add(packet: Data) {
        lock.lock(); defer { lock.unlock() }
        packets += 1
        guard let frame = depacketizer.push(packet) else { return }
        frames += 1
        if AnnexB.split(frame.annexB).contains(where: { HEVCNALType.isIRAP($0.type) }) { keyframes += 1 }
        if let output = try? builder.makeSample(from: frame), output.formatChanged, let d = builder.dimensions {
            size = "\(d.width)×\(d.height)"
        }
    }

    func add(bytes: Int = 0, error: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        packets += 1
        pcmBytes += bytes
        if error { errors += 1 }
    }

    func summary(kind: DisplayService.Kind, seconds: Double) -> String {
        lock.lock(); defer { lock.unlock() }
        if kind == .audio {
            return "Audio: \(packets) packets, \(errors) errors, \(String(format: "%.1f", Double(pcmBytes) / 4 / 48_000)) s PCM in \(seconds) s"
        }
        return "Video: \(packets) RTP packets → \(frames) frames (\(keyframes) keyframes, \(depacketizer.droppedFrames) dropped), \(size), ≈ \(String(format: "%.1f", Double(frames) / seconds)) fps"
    }
}

func describeStructure(_ value: XPCValue, indent: Int) -> String {
    let pad = String(repeating: "  ", count: indent)
    switch value {
    case .dictionary(let entries):
        return entries.map { entry -> String in
            switch entry.value {
            case .dictionary, .array: "\(pad)\(entry.key):\n" + describeStructure(entry.value, indent: indent + 1)
            default: "\(pad)\(entry.key): \(describeLeaf(entry.value))"
            }
        }.joined(separator: "\n")
    case .array(let items):
        return items.enumerated().map { "\(pad)[\($0.offset)]\n" + describeStructure($0.element, indent: indent + 1) }.joined(separator: "\n")
    default:
        return pad + describeLeaf(value)
    }
}

func describeLeaf(_ value: XPCValue) -> String {
    switch value {
    case .string(let s): "string(\(s.count))"
    case .data(let d): "data(\(d.count))"
    case .int64(let i): "int64(\(i))"
    case .uint64(let i): "uint64(\(i))"
    case .bool(let b): "bool(\(b))"
    case .uuid: "uuid"
    case .null: "null"
    case .double: "double"
    case .date: "date"
    case .unsupported(let t): "unsupported(0x\(String(t, radix: 16)))"
    default: "?"
    }
}
