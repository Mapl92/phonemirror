// SPDX-License-Identifier: GPL-3.0-or-later
// CoreDevice services on the device, recreated after pymobiledevice3
// (remote/core_device/core_device_service.py, display_service.py, hid_service.py, pasteboard_service.py;
// GPL-3.0-or-later).
import Foundation
import ImageIO
import MirrorCore
import UniformTypeIdentifiers

public struct CoreDeviceError: LocalizedError {
    public var code: Int?
    public var message: String
    public var errorDescription: String? { message + (code.map { " (Code \($0))" } ?? "") }

    /// Camera or microphone is in use by an app – iOS then refuses mirroring.
    public var isMediaInUse: Bool { code == 9022 }
}

/// Invocation of CoreDevice features over a RemoteXPC connection.
public final class CoreDeviceService: @unchecked Sendable {
    public let connection: RemoteXPCConnection

    public init(connection: RemoteXPCConnection) {
        self.connection = connection
    }

    static let coreDeviceVersion: XPCValue = [
        "components": .array([.uint64(629), .uint64(3)]),
        "originalComponentsCount": .int64(2),
        "stringValue": "629.3",
    ]

    public func invoke(feature: String, action: String? = nil, input: XPCValue = [:]) async throws -> XPCValue {
        var entries: [XPCEntry] = [
            XPCEntry("CoreDevice.CoreDeviceDDIProtocolVersion", .int64(2)),
            XPCEntry("CoreDevice.coreDeviceVersion", Self.coreDeviceVersion),
            XPCEntry("CoreDevice.deviceIdentifier", .string(UUID().uuidString)),
            XPCEntry("CoreDevice.input", input),
            XPCEntry("CoreDevice.invocationIdentifier", .string(UUID().uuidString)),
            XPCEntry("CoreDevice.featureIdentifier", .string(feature)),
            XPCEntry("CoreDevice.action", [:]),
        ]
        if let action { entries.append(XPCEntry("CoreDevice.actionIdentifier", .string(action))) }
        let response = try await connection.sendReceive(.dictionary(entries))
        if let output = response["CoreDevice.output"] { return output }
        let error = response["CoreDevice.error"]
        throw CoreDeviceError(
            code: error?["code"]?.intValue,
            message: error?["userInfo"]?["NSLocalizedDescription"]?.stringValue ?? "\(feature) failed"
        )
    }
}

extension CoreDeviceService {
    /// Streaming feature (e.g. `streamapplist`): the device sends elements in batches over a
    /// “side channel” and finishes with `finishStreaming`.
    public func streamInvoke(feature: String, input: XPCValue) async throws -> [XPCValue] {
        let request: XPCValue = [
            "CoreDevice.CoreDeviceDDIProtocolVersion": .int64(2),
            "CoreDevice.coreDeviceVersion": Self.coreDeviceVersion,
            "CoreDevice.deviceIdentifier": .string(UUID().uuidString),
            "CoreDevice.featureIdentifier": .string(feature),
            "CoreDevice.action": [:],
            "CoreDevice.input": ["actualInput": input, "streamProxy": ["sideChannel": .uuid(UUID())]],
            "CoreDevice.invocationIdentifier": .string(UUID().uuidString),
        ]
        try await connection.sendRequest(request, wantingReply: true)
        var elements: [XPCValue] = []
        while true {
            let response = try await connection.receiveResponse()
            guard let status = response["CoreDevice.XPCMessageKey.sideChannelStatus"] else {
                throw CoreDeviceError(code: response["CoreDevice.error"]?["code"]?.intValue, message: "\(feature) failed")
            }
            if status["receivedError"] != nil { throw CoreDeviceError(code: nil, message: "\(feature): error in stream") }
            if status["finishStreaming"] != nil { return elements }
            elements += status["pushing"]?["elements"]?.arrayValue ?? []
        }
    }
}

/// `com.apple.coredevice.appservice` (dtappserviced): list and launch apps.
public final class AppService: @unchecked Sendable {
    public static let name = "com.apple.coredevice.appservice"
    public let service: CoreDeviceService

    public init(connection: RemoteXPCConnection) {
        service = CoreDeviceService(connection: connection)
    }

    /// Since iOS 26 only available as a stream – the classic `listapps` no longer answers.
    public func installedApps() async throws -> [InstalledApp] {
        let elements = try await service.streamInvoke(feature: "com.apple.coredevice.feature.streamapplist", input: [
            "includeAppClips": false, "includeRemovableApps": true, "includeHiddenApps": false,
            "includeInternalApps": false, "includeDefaultApps": true, "requireContainerAccess": false,
            "includeAppGroupIdentifiers": false, "includeContainerPaths": false,
        ])
        return elements.compactMap { app in
            guard let bundleID = app["bundleIdentifier"]?.stringValue else { return nil }
            let name = app["name"]?.stringValue ?? bundleID
            let removable = app["isRemovable"]?.boolValue ?? true
            return InstalledApp(bundleID: bundleID, name: name, isSystemApp: !removable || bundleID.hasPrefix("com.apple."))
        }
    }

    public func launch(bundleID: String) async throws {
        let options = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        _ = try await service.invoke(feature: "com.apple.coredevice.feature.launchapplication", input: [
            "applicationSpecifier": ["bundleIdentifier": ["_0": .string(bundleID)]],
            "options": [
                "arguments": .array([]),
                "environmentVariables": [:],
                "standardIOUsesPseudoterminals": true,
                "startStopped": false,
                "terminateExisting": false,
                "user": ["shortName": "mobile"],
                "platformSpecificOptions": .data(options),
            ],
            "standardIOIdentifiers": [:],
        ])
    }
}

/// `com.apple.coredevice.displayservice` (dtremotedisplayd): screen and audio streams.
/// `com.apple.coredevice.deviceinfo`: display geometry and lock state (no Developer Disk Image needed).
public final class DeviceInfoService: @unchecked Sendable {
    public static let name = "com.apple.coredevice.deviceinfo"
    public let service: CoreDeviceService

    public init(connection: RemoteXPCConnection) {
        service = CoreDeviceService(connection: connection)
    }

    public func displayInfo() async throws -> XPCValue {
        try await service.invoke(feature: "com.apple.coredevice.feature.getdisplayinfo")
    }

    public func lockState() async throws -> XPCValue {
        try await service.invoke(feature: "com.apple.coredevice.feature.getlockstate")
    }
}

/// `com.apple.coredevice.devicecontrol`: rotates the device UI (Device Hub's rotate buttons).
public final class DeviceControlService: @unchecked Sendable {
    public static let name = "com.apple.coredevice.devicecontrol"
    private let connection: RemoteXPCConnection

    public init(connection: RemoteXPCConnection) {
        self.connection = connection
    }

    /// `clockwise == false` is Xcode's "rotate left". Returns the new device orientation.
    @discardableResult
    public func rotate(clockwise: Bool) async throws -> String? {
        let reply = try await withTimeout(seconds: 10, "rotate") { [connection] in
            try await connection.sendReceive([
                "featureIdentifier": "com.apple.coredevice.feature.remote.devicecontrol.orientation",
                "messageType": "OrientationRequest",
                "payload": ["rotate": ["_0": .string(clockwise ? "right" : "left")]],
            ])
        }
        return reply["currentDeviceOrientation"]?.stringValue
    }

    public func close() {
        connection.close()
    }
}

extension DeviceScreen {
    /// Native (portrait) geometry of the primary display from `getdisplayinfo`.
    public init?(displayInfo: XPCValue) {
        guard let displays = displayInfo["displays"]?.arrayValue,
              let primary = displays.first(where: { $0["primary"]?.boolValue == true }) ?? displays.first,
              let size = (primary["currentMode"]?["size"] ?? primary["nativeSize"])?.arrayValue, size.count == 2,
              case .double(let first) = size[0], case .double(let second) = size[1], first > 0, second > 0
        else { return nil }
        let width = Int(min(first, second))
        let height = Int(max(first, second))
        let scale = Double(primary["pointScale"]?.intValue ?? primary["currentMode"]?["preferredUIScale"]?.intValue ?? 3)
        self.init(pixelWidth: width, pixelHeight: height, scale: scale,
                  cornerRadius: DeviceScreen.estimatedCornerRadius(pixelWidth: width, pixelHeight: height, scale: scale))
    }
}

extension DeviceOrientation {
    /// Orientation of the primary display's content (`currentOrientation`: rot0/rot90/rot180/rot270).
    public init?(displayInfo: XPCValue) {
        guard let displays = displayInfo["displays"]?.arrayValue,
              let primary = displays.first(where: { $0["primary"]?.boolValue == true }) ?? displays.first,
              let rotation = primary["currentOrientation"]?.stringValue
        else { return nil }
        switch rotation {
        case "rot90": self = .landscapeLeft
        case "rot180": self = .portraitUpsideDown
        case "rot270": self = .landscapeRight
        default: self = .portrait
        }
    }
}

public final class DisplayService: @unchecked Sendable {
    public static let name = "com.apple.coredevice.displayservice"
    public let service: CoreDeviceService

    public init(connection: RemoteXPCConnection) {
        service = CoreDeviceService(connection: connection)
    }

    public func mediaSupportInfo() async throws -> XPCValue {
        try await service.invoke(
            feature: "com.apple.coredevice.feature.getmediasupportinfo",
            action: "com.apple.coredevice.action.mediastreamgetsupportinfo"
        )
    }

    public struct StreamAnswer: Sendable {
        /// The device's sender port – destination for RTCP.
        public var sourcePort: UInt16
        /// The device's SSRC (“LocalSSRC” from the device's point of view).
        public var deviceSSRC: UInt32
        /// Our SSRC (“RemoteSSRC” from the device's point of view).
        public var ourSSRC: UInt32
    }

    public enum Kind: String, Sendable { case video, audio }

    /// Starts a stream. The UDP receiver must already be listening on `receiverPort`.
    public func startStream(
        _ kind: Kind, receiverIP: String, receiverPort: UInt16, senderIP: String,
        sessionID: UUID, displayID: Int = 1
    ) async throws -> StreamAnswer {
        let callID = UUID().uuidString.uppercased()
        let blobSession = UInt32.random(in: 0...UInt32.max)
        let offer = kind == .video
            ? try MediaStreamOffer.videoOffer(callID: callID, sessionID: blobSession)
            : try MediaStreamOffer.audioOffer(callID: callID, sessionID: blobSession)
        var options: [XPCEntry] = [
            XPCEntry("AVCMediaStreamNegotiatorAccessNetworkType", ["int": .int64(1)]),
            XPCEntry("AVCMediaStreamNegotiatorTransportProtocolType", ["int": .int64(2)]),
        ]
        if kind == .video {
            options.append(XPCEntry("CoreDeviceVideoDisplayMode", ["string": "DisplayByID"]))
            options.append(XPCEntry("VideoStreamForDisplayID", ["int": .int64(Int64(displayID))]))
        }
        options.append(XPCEntry("avcMediaStreamOptionClientSessionID", ["uuid": .uuid(sessionID)]))
        let request: XPCValue = [
            "clientSupportedFeatures": .uint64(140),
            "direction": "output",
            "negotiatorOffer": .data(offer),
            "options": .dictionary(options),
            "receiverIP": .string(receiverIP),
            "receiverPort": .uint64(UInt64(receiverPort)),
            "senderIP": .string(senderIP),
            "timeout": .uint64(20),
            "type": .string(kind.rawValue),
        ]
        let output = try await service.invoke(
            feature: "com.apple.coredevice.feature.startmediastream",
            action: "com.apple.coredevice.action.mediastreamstart",
            input: request
        )
        let config = output["connection"]?["streamConfig"]
        return StreamAnswer(
            sourcePort: UInt16(clamping: config?["SourcePort"]?.intValue ?? 0),
            deviceSSRC: UInt32(truncatingIfNeeded: config?["LocalSSRC"]?.intValue ?? 0),
            ourSSRC: UInt32(truncatingIfNeeded: config?["RemoteSSRC"]?.intValue ?? 0)
        )
    }

    /// Ends all streams; without this the iPhone stays marked as “remote controlled” (camera/mic blocked).
    public func stopAllStreams() async throws {
        _ = try await service.invoke(
            feature: "com.apple.coredevice.feature.stopmediastream",
            action: "com.apple.coredevice.action.mediastreamstop",
            input: ["stopAll": true]
        )
    }
}

/// HID via `dtuhidd`: touch (mainTouchscreen), virtual keyboard, hardware buttons.
public final class HIDService: @unchecked Sendable {
    public static let universalName = "com.apple.coredevice.hid.universalhidservice"
    public static let indigoName = "com.apple.coredevice.hid.indigo"
    static let touchscreenServiceID: UInt64 = 257
    static let keyboardServiceID: UInt64 = 0x1_0000_2001
    static let keyboardDescriptor = Data(hex: "05010906a101050719e029e7150025019508750181029501750881010507190029ff150026ff0095067508810005081901290515002501950575019102950175039101c0")

    private let universal: RemoteXPCConnection
    private let indigo: RemoteXPCConnection
    private var keyboardID: UInt64?

    public init(universal: RemoteXPCConnection, indigo: RemoteXPCConnection) {
        self.universal = universal
        self.indigo = indigo
    }

    public func close() {
        universal.close()
        indigo.close()
    }

    /// Touch: `contact` (finger is down) or release, coordinates 0…65535.
    public func touch(contact: Bool, at point: TouchPoint) async throws {
        var report = Data([0x09, 0x01, 0x05, contact ? 0xC2 : 0x02])
        report.append(littleEndian: point.x)
        report.append(littleEndian: point.y)
        report.append(Data(count: 32))
        report.append(contentsOf: [0x02, 0x00, 0x00, 0x00])
        report.append(Self.timestamp())
        report.append(Data(count: 8))
        try await send(report: report, to: Self.touchscreenServiceID)
    }

    /// Keyboard: complete set of pressed HID usages (empty = all released).
    public func keyboard(usages: [UInt16]) async throws {
        let id = try await ensureKeyboard()
        var bitmap = [UInt8](repeating: 0, count: 30)
        for usage in usages where usage < 240 {
            bitmap[Int(usage) / 8] |= 1 << (usage % 8)
        }
        var report = Data([0x01])
        report.append(contentsOf: bitmap)
        report.append(Self.timestamp())
        report.append(Data(count: 2))
        try await send(report: report, to: id)
    }

    /// Press, hold and release a hardware button (consumer page usage).
    public func press(usagePage: UInt16, usage: UInt16, hold: Double) async throws {
        try await button(usagePage: usagePage, usage: usage, state: 1)
        try await Task.sleep(for: .seconds(hold))
        try await button(usagePage: usagePage, usage: usage, state: 2)
    }

    public func button(usagePage: UInt16, usage: UInt16, state: UInt64) async throws {
        try await indigo.sendRequest([
            "messageType": "IndigoButtonEvent",
            "payload": [
                "state": .uint64(state),
                "usagePage": .uint64(UInt64(usagePage)),
                "usageCode": .uint64(UInt64(usage)),
            ],
            "featureIdentifier": "com.apple.coredevice.feature.remote.hid.button",
        ])
    }

    private func send(report: Data, to serviceID: UInt64) async throws {
        try await universal.sendRequest([
            "featureIdentifier": "com.apple.coredevice.feature.remote.universalhidservice",
            "messageType": "Request",
            "payload": ["send": ["_0": .data(report), "_1": .uint64(serviceID)]],
        ])
    }

    /// Register a virtual keyboard with dtuhidd (like Universal Control). Values in the storage block need
    /// Swift Codable wrappers (`{"int": …}`), otherwise dtuhidd rejects with `typeMismatch`.
    private func ensureKeyboard() async throws -> UInt64 {
        if let keyboardID { return keyboardID }
        let usage = XPCValue.int64(6), page = XPCValue.int64(1)
        let storage: XPCValue = [
            "Manufacturer": ["string": "PhoneMirror"],
            "Product": ["string": "PhoneMirror Keyboard"],
            "ProductID": ["int": .int64(0x0250)],
            "VendorID": ["int": .int64(0x05AC)],
            "PrimaryUsage": ["int": usage],
            "PrimaryUsagePage": ["int": page],
            "DeviceUsagePairs": ["array": .array([["dictionary": ["DeviceUsage": ["int": usage], "DeviceUsagePage": ["int": page]]]])],
            "Transport": ["string": "USB"],
            "ReportDescriptor": ["data": .data(Self.keyboardDescriptor)],
            "UniversalControlVirtualService": ["bool": true],
            "_ServiceID": ["uint": .uint64(Self.keyboardServiceID)],
        ]
        let response = try await universal.sendReceive([
            "featureIdentifier": "com.apple.coredevice.feature.remote.universalhidservice",
            "messageType": "Request",
            "payload": [
                "createService": [
                    "_0": [
                        "DeviceUsagePairs": .array([["DeviceUsage": usage, "DeviceUsagePage": page]]),
                        "PrimaryUsage": .uint64(6),
                        "PrimaryUsagePage": .uint64(1),
                        "Product": "PhoneMirror Keyboard",
                        "ProductID": .int64(0x0250),
                        "VendorID": .int64(0x05AC),
                        "_CoreDevice_codablePropertyStorage": storage,
                        "_ServiceID": .uint64(Self.keyboardServiceID),
                    ],
                ],
            ],
        ])
        let id = response["serviceID"]?.intValue.map(UInt64.init) ?? Self.keyboardServiceID
        keyboardID = id
        // iOS needs a moment until the keyboard is attached (otherwise Shift gets stuck).
        try await Task.sleep(for: .milliseconds(300))
        return id
    }

    static func timestamp() -> Data {
        var value = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) & ((1 << 48) - 1)
        return Data(bytes: &value, count: 6)
    }
}

/// `com.apple.coredevice.pasteboardservice`: read and set the clipboard.
/// Each request on its own connection – the service can take a long time for “rich” copies.
public final class PasteboardService: @unchecked Sendable {
    public static let name = "com.apple.coredevice.pasteboardservice"
    private let open: @Sendable () async throws -> RemoteXPCConnection

    public init(open: @escaping @Sendable () async throws -> RemoteXPCConnection) {
        self.open = open
    }

    /// Change identifier (nonce, changeCount) without data – fast.
    public func changeID() async throws -> String? {
        let snapshot = try await pull(policy: ["allPromised": [:]])
        let metadata = snapshot["pasteboard"]?["metadata"]
        guard let metadata else { return nil }
        return "\(metadata["nonce"].map { "\($0)" } ?? "")|\(metadata["changeCount"]?.intValue ?? -1)"
    }

    static let textTypes = ["public.utf8-plain-text", "public.plain-text", "public.text", "public.url"]
    static let imageTypes = ["public.png", "public.jpeg", "public.heic", "public.tiff"]

    /// Contents of the current copy from the primary types (`promiseSecondary`). Deliberately not fetching all
    /// representations: for that, iOS e.g. converts HTML to RTF and blocks the service for up to a minute.
    /// Formatted copies (Safari: HTML first, Notes: RTF first) therefore arrive as HTML/RTF.
    public func content() async throws -> ClipboardContent? {
        Self.extract(try await pull(policy: ["promiseSecondary": [:]]))
    }

    static func items(_ snapshot: XPCValue) -> [XPCValue] {
        snapshot["pasteboard"]?["items"]?.arrayValue ?? []
    }

    static func extract(_ snapshot: XPCValue) -> ClipboardContent? {
        for item in items(snapshot) {
            let data = item["data"]
            for uti in textTypes {
                if let bytes = data?[uti]?["data"]?.dataValue, let text = String(data: bytes, encoding: .utf8), !text.isEmpty {
                    return .text(text)
                }
            }
            if let png = data?["public.png"]?["data"]?.dataValue { return .png(png) }
            for uti in imageTypes.dropFirst() {
                if let bytes = data?[uti]?["data"]?.dataValue, let png = ImageConversion.png(from: bytes) { return .png(png) }
            }
            if let html = data?["public.html"]?["data"]?.dataValue { return .html(html) }
            if let rtf = data?["public.rtf"]?["data"]?.dataValue { return .rtf(rtf) }
        }
        return nil
    }

    static func promises(_ snapshot: XPCValue, anyOf types: [String]) -> Bool {
        items(snapshot).contains { item in
            (item["types"]?.arrayValue ?? []).contains { types.contains($0.stringValue ?? "") }
        }
    }

    public func set(_ content: ClipboardContent) async throws {
        let item: XPCValue
        switch content {
        case .text(let text):
            let bytes = XPCValue.data(Data(text.utf8))
            let utis = ["public.utf8-plain-text", "public.plain-text", "public.text"]
            item = ["types": .array(utis.map { .string($0) }), "data": .dictionary(utis.map { XPCEntry($0, ["data": bytes]) })]
        case .png(let png):
            item = ["types": .array(["public.png"]), "data": ["public.png": ["data": .data(png)]]]
        case .html(let html):
            item = ["types": .array(["public.html"]), "data": ["public.html": ["data": .data(html)]]]
        case .rtf(let rtf):
            item = ["types": .array(["public.rtf"]), "data": ["public.rtf": ["data": .data(rtf)]]]
        }
        let connection = try await open()
        defer { connection.close() }
        try await connection.sendRequest([
            "command": "SET",
            "pasteboardName": "general",
            "items": .array([item]),
            "sourceMetadata": .null,
        ], wantingReply: true)
        _ = try? await withTimeout(seconds: 5, "Setting clipboard") { try await connection.receiveResponse() }
    }

    private func pull(policy: XPCValue, timeout: Double = 10) async throws -> XPCValue {
        let connection = try await open()
        defer { connection.close() }
        return try await withTimeout(seconds: timeout, "Reading clipboard") {
            try await connection.sendReceive(["command": "PULL", "pasteboardName": "general", "dataPolicy": policy])
        }
    }
}

extension Data {
    init(hex: String) {
        let digits = Array(hex.utf8).filter { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
        var bytes = [UInt8]()
        var index = 0
        while index + 1 < digits.count {
            bytes.append(UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16)!)
            index += 2
        }
        self.init(bytes)
    }

    mutating func append(littleEndian value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// Converts JPEG/HEIC/TIFF to PNG (the Mac side only knows text and PNG).
enum ImageConversion {
    static func png(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
