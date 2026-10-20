// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Geometry of the mirrored device screen.
public struct DeviceScreen: Sendable, Equatable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Pixels per point (iPhone 15: 3).
    public var scale: Double
    /// Corner radius of the display in points.
    public var cornerRadius: Double

    public init(pixelWidth: Int, pixelHeight: Int, scale: Double, cornerRadius: Double) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.cornerRadius = cornerRadius
    }

    public var pointSize: CGSize {
        CGSize(width: Double(pixelWidth) / scale, height: Double(pixelHeight) / scale)
    }

    /// Approximate display corner radius in points: none for 16:9 displays (Home button), otherwise
    /// about 14 % of the width (iPhone 15: 55 pt). Devices don't report it.
    public static func estimatedCornerRadius(pixelWidth: Int, pixelHeight: Int, scale: Double) -> Double {
        let ratio = Double(max(pixelWidth, pixelHeight)) / Double(max(min(pixelWidth, pixelHeight), 1))
        guard ratio > 1.9 else { return 0 }
        return (Double(min(pixelWidth, pixelHeight)) / scale * 0.14).rounded()
    }

    /// iPhone 15 (iPhone15,4): 1179 × 2556 px, @3x.
    public static let iPhone15 = DeviceScreen(pixelWidth: 1179, pixelHeight: 2556, scale: 3, cornerRadius: 55)
}

/// A complete HEVC access unit in Annex B format (start codes before every NAL unit).
/// Parameter sets (VPS/SPS/PPS), if present, come before the slice NALs.
public struct VideoPacket: Sendable, Equatable {
    public var annexB: Data
    /// Presentation time in seconds relative to the session start.
    public var timestamp: TimeInterval
    /// The sender skipped frames: reset the decoder before this (key) frame.
    public var resetDecoder: Bool

    public init(annexB: Data, timestamp: TimeInterval, resetDecoder: Bool = false) {
        self.annexB = annexB
        self.timestamp = timestamp
        self.resetDecoder = resetDecoder
    }
}

/// Audio from the device: interleaved Int16 PCM (little endian).
public struct AudioChunk: Sendable, Equatable {
    public var pcm: Data
    public var sampleRate: Double
    public var channels: Int

    public init(pcm: Data, sampleRate: Double = 48_000, channels: Int = 2) {
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Contents of a clipboard.
public enum ClipboardContent: Sendable, Equatable {
    case text(String)
    case png(Data)
    /// Formatted text (e.g. from Safari/Mail) – the Mac additionally puts plain text next to it.
    case html(Data)
    /// Formatted text (e.g. from Notes/Pages).
    case rtf(Data)
}

public enum TransportEvent: Sendable, Equatable {
    case video(VideoPacket)
    case audio(AudioChunk)
    /// Something was copied on the device.
    case clipboard(ClipboardContent)
    case screenChanged(DeviceScreen)
    /// The iPhone was rotated (the video stays in native portrait orientation).
    case orientationChanged(DeviceOrientation)
    /// Connection lost; the app tries again.
    case disconnected(reason: String?)
}

/// An app installed on the device.
public struct InstalledApp: Sendable, Equatable {
    public var bundleID: String
    public var name: String
    public var isSystemApp: Bool

    public init(bundleID: String, name: String, isSystemApp: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.isSystemApp = isSystemApp
    }
}

/// Where the device is reachable in the CoreDevice tunnel (for services such as WebDriverAgent).
public struct DeviceEndpoint: Sendable, Equatable {
    public var tunnelAddress: String
    public var udid: String

    public init(tunnelAddress: String, udid: String) {
        self.tunnelAddress = tunnelAddress
        self.udid = udid
    }
}

public struct UnsupportedFeatureError: LocalizedError {
    public var feature: String
    public init(_ feature: String) { self.feature = feature }
    public var errorDescription: String? { "\(feature) is not available with this connection type (only “Native”)." }
}

/// A running connection to a device: delivers video, accepts input.
public protocol MirrorSession: AnyObject, Sendable {
    var screen: DeviceScreen { get }
    var events: AsyncStream<TransportEvent> { get }
    func send(_ event: InputEvent) async throws
    /// Puts content into the device's clipboard.
    func setClipboard(_ content: ClipboardContent) async throws
    /// Forces a fresh keyframe (e.g. after a change of video resolution).
    func requestKeyframe() async
    /// Current contents of the device's clipboard.
    func clipboardContent() async throws -> ClipboardContent?
    func installedApps() async throws -> [InstalledApp]
    func launchApp(bundleID: String) async throws
    /// Tunnel address and UDID, if the transport knows them.
    func deviceEndpoint() async -> DeviceEndpoint?
    /// Rotates the device's UI by 90° (as Xcode's Device Hub does).
    func rotate(clockwise: Bool) async throws
    func close() async
}

public extension MirrorSession {
    func setClipboard(_ content: ClipboardContent) async throws {}
    func requestKeyframe() async {}
    func clipboardContent() async throws -> ClipboardContent? { nil }
    func installedApps() async throws -> [InstalledApp] { throw UnsupportedFeatureError("Listing apps") }
    func launchApp(bundleID: String) async throws { throw UnsupportedFeatureError("Launching apps") }
    func deviceEndpoint() async -> DeviceEndpoint? { nil }
    func rotate(clockwise: Bool) async throws { throw UnsupportedFeatureError("Rotating") }
}

/// Sets up sessions. Implementations: `FileReplayTransport` (test file),
/// later the CoreDevice transport (`com.apple.coredevice.displayservice` + Universal HID).
public protocol MirrorTransport: Sendable {
    var displayName: String { get }
    /// Ensure the Developer Disk Image before every connection attempt (see `DevicePreparation`).
    var requiresDevicePreparation: Bool { get }
    func connect() async throws -> any MirrorSession
}

public extension MirrorTransport {
    var requiresDevicePreparation: Bool { false }
}

extension ClipboardContent {
    var isImage: Bool {
        if case .png = self { return true }
        return false
    }
}
