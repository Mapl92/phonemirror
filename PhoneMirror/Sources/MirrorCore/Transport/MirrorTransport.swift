// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Geometrie des gespiegelten Gerätebildschirms.
public struct DeviceScreen: Sendable, Equatable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Pixel pro Punkt (iPhone 15: 3).
    public var scale: Double
    /// Eckenradius des Displays in Punkten.
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

    /// iPhone 15 (iPhone15,4): 1179 × 2556 px, @3x.
    public static let iPhone15 = DeviceScreen(pixelWidth: 1179, pixelHeight: 2556, scale: 3, cornerRadius: 55)
}

/// Eine vollständige HEVC Access Unit im Annex-B-Format (Startcodes vor jeder NAL Unit).
/// Parameter-Sets (VPS/SPS/PPS) stehen, falls vorhanden, vor den Slice-NALs.
public struct VideoPacket: Sendable, Equatable {
    public var annexB: Data
    /// Präsentationszeit in Sekunden relativ zum Sessionstart.
    public var timestamp: TimeInterval
    /// Der Sender hat Bilder ausgelassen: Decoder vor diesem (Key-)Bild zurücksetzen.
    public var resetDecoder: Bool

    public init(annexB: Data, timestamp: TimeInterval, resetDecoder: Bool = false) {
        self.annexB = annexB
        self.timestamp = timestamp
        self.resetDecoder = resetDecoder
    }
}

/// Ton vom Gerät: interleaved Int16-PCM (Little Endian).
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

/// Inhalt einer Zwischenablage.
public enum ClipboardContent: Sendable, Equatable {
    case text(String)
    case png(Data)
    /// Formatierter Text (z. B. aus Safari/Mail) – der Mac legt zusätzlich reinen Text daneben.
    case html(Data)
    /// Formatierter Text (z. B. aus Notizen/Pages).
    case rtf(Data)
}

public enum TransportEvent: Sendable, Equatable {
    case video(VideoPacket)
    case audio(AudioChunk)
    /// Auf dem Gerät wurde etwas kopiert.
    case clipboard(ClipboardContent)
    case screenChanged(DeviceScreen)
    /// Verbindung verloren; die App versucht es erneut.
    case disconnected(reason: String?)
}

/// Eine auf dem Gerät installierte App.
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

/// Wo das Gerät im CoreDevice-Tunnel erreichbar ist (für Dienste wie WebDriverAgent).
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
    public var errorDescription: String? { "\(feature) ist mit dieser Verbindungsart nicht verfügbar (nur „Nativ“)." }
}

/// Eine laufende Verbindung zu einem Gerät: liefert Video, nimmt Eingaben entgegen.
public protocol MirrorSession: AnyObject, Sendable {
    var screen: DeviceScreen { get }
    var events: AsyncStream<TransportEvent> { get }
    func send(_ event: InputEvent) async throws
    /// Legt Inhalt in die Zwischenablage des Geräts.
    func setClipboard(_ content: ClipboardContent) async throws
    /// Erzwingt ein frisches Keyframe (z. B. nach einem Wechsel der Videoauflösung).
    func requestKeyframe() async
    /// Aktueller Inhalt der Zwischenablage des Geräts.
    func clipboardContent() async throws -> ClipboardContent?
    func installedApps() async throws -> [InstalledApp]
    func launchApp(bundleID: String) async throws
    /// Tunnel-Adresse und UDID, sofern der Transport sie kennt.
    func deviceEndpoint() async -> DeviceEndpoint?
    func close() async
}

public extension MirrorSession {
    func setClipboard(_ content: ClipboardContent) async throws {}
    func requestKeyframe() async {}
    func clipboardContent() async throws -> ClipboardContent? { nil }
    func installedApps() async throws -> [InstalledApp] { throw UnsupportedFeatureError("Apps auflisten") }
    func launchApp(bundleID: String) async throws { throw UnsupportedFeatureError("Apps starten") }
    func deviceEndpoint() async -> DeviceEndpoint? { nil }
}

/// Baut Sessions auf. Implementierungen: `FileReplayTransport` (Testdatei),
/// später der CoreDevice-Transport (`com.apple.coredevice.displayservice` + Universal HID).
public protocol MirrorTransport: Sendable {
    var displayName: String { get }
    /// Vor jedem Verbindungsaufbau das Developer Disk Image sicherstellen (siehe `DevicePreparation`).
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
