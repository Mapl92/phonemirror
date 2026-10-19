// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Zerlegt den Bytestrom von `/stream.bin` (pymobiledevice3 `serve-web`) in Bilder.
/// Jede Nachricht: [4 Byte Länge BE][1 Byte Typ][Access Unit als 4-Byte-längenpräfixierte NALs].
/// Typ 0 = Keyframe, 1 = Delta, 2 = Keyframe mit Decoder-Reset.
public struct ServeWebStreamParser: Sendable {
    private var buffer = Data()
    private var frameIndex = 0
    private let frameDuration: TimeInterval

    public init(framesPerSecond: Double = 60) {
        frameDuration = 1 / framesPerSecond
    }

    public mutating func append(_ data: Data) -> [VideoPacket] {
        buffer.append(data)
        var packets: [VideoPacket] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 5 {
            let length = Int(buffer[offset]) << 24 | Int(buffer[offset + 1]) << 16 | Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3])
            guard length >= 1 else {
                offset += 4
                continue
            }
            guard buffer.endIndex - offset >= 4 + length else { break }
            let type = buffer[offset + 4]
            let accessUnit = buffer[(offset + 5)..<(offset + 4 + length)]
            offset += 4 + length
            guard type <= 2, let annexB = Self.annexB(fromLengthPrefixed: accessUnit) else { continue }
            // Zeitstempel nur für die Reihenfolge – angezeigt wird sofort (DisplayImmediately).
            packets.append(VideoPacket(annexB: annexB, timestamp: Double(frameIndex) * frameDuration, resetDecoder: type == 2))
            frameIndex += 1
        }
        buffer.removeSubrange(buffer.startIndex..<offset)
        return packets
    }

    static func annexB(fromLengthPrefixed data: Data) -> Data? {
        var units: [HEVCNALUnit] = []
        var offset = data.startIndex
        while data.endIndex - offset >= 4 {
            let length = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4
            guard length > 0, data.endIndex - offset >= length else { return nil }
            units.append(HEVCNALUnit(Data(data[offset..<offset + length])))
            offset += length
        }
        return units.isEmpty ? nil : AnnexB.join(units)
    }
}

/// Zerlegt `/audio.bin`: wiederholt [4 Byte Länge BE][Int16-PCM, 48 kHz, Stereo, interleaved].
/// serve-web dekodiert das AAC-ELD des Geräts bereits mit AudioToolbox.
public struct ServeWebAudioParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [AudioChunk] {
        buffer.append(data)
        var chunks: [AudioChunk] = []
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 4 {
            let length = Int(buffer[offset]) << 24 | Int(buffer[offset + 1]) << 16 | Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3])
            guard buffer.endIndex - offset >= 4 + length else { break }
            if length > 0 {
                chunks.append(AudioChunk(pcm: Data(buffer[(offset + 4)..<(offset + 4 + length)])))
            }
            offset += 4 + length
        }
        buffer.removeSubrange(buffer.startIndex..<offset)
        return chunks
    }
}

/// Antwort von `GET /clipboard/events` (Long-Poll, ≈ 25 s).
/// `text`/`image` sind nur gesetzt, wenn seit `since` auf dem Gerät kopiert wurde.
public struct ServeWebClipboardEvent: Decodable, Sendable, Equatable {
    public struct Image: Decodable, Sendable, Equatable {
        public var type: String?
        public var size: Int
    }

    public var seq: Int
    public var text: String?
    public var image: Image?
}

/// Eine HTTP-Anfrage an `serve-web` (POST mit JSON-Körper).
public struct ServeWebRequest: Sendable, Equatable {
    public var path: String
    public var json: [String: ServeWebValue]

    public init(path: String, json: [String: ServeWebValue]) {
        self.path = path
        self.json = json
    }

    public var body: Data {
        let object = json.mapValues(\.jsonObject)
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

public enum ServeWebValue: Sendable, Equatable {
    case int(Int)
    case string(String)
    case ints([Int])

    var jsonObject: Any {
        switch self {
        case .int(let value): value
        case .string(let value): value
        case .ints(let values): values
        }
    }
}

/// Übersetzt `InputEvent`s in `serve-web`-Anfragen (`/touch`, `/key`, `/button`).
/// Die Logik (gehaltene Tasten, Scroll als Wischgeste) steckt im transportneutralen `InputActionEncoder`.
public struct ServeWebInputEncoder: Sendable {
    private var actions: InputActionEncoder

    public init(screen: DeviceScreen) {
        actions = InputActionEncoder(screen: screen)
    }

    public var heldKeys: [UInt16] { actions.heldKeys }
    public var scrollPosition: TouchPoint? { actions.scrollPosition }

    public mutating func requests(for event: InputEvent) -> [ServeWebRequest] {
        actions.actions(for: event).map(Self.request)
    }

    /// Anfragen für einen Gestenschritt; Wartezeiten übernimmt der Aufrufer.
    public mutating func requests(forStep step: GestureStep) -> [ServeWebRequest] {
        actions.actions(forStep: step).map(Self.request)
    }

    public mutating func endScroll() -> [ServeWebRequest] {
        actions.endScroll().map(Self.request)
    }

    static func request(for action: DeviceAction) -> ServeWebRequest {
        switch action {
        case .touch(let contact, let point):
            ServeWebRequest(path: "/touch", json: ["type": .string(contact ? "contact" : "release"), "x": .int(Int(point.x)), "y": .int(Int(point.y))])
        case .keys(let usages):
            ServeWebRequest(path: "/key", json: ["usages": .ints(usages.map(Int.init))])
        case .button(let button, let action):
            // serve-web hält die Taste beim „press“ selbst passend lange (Sperren 0,5 s, Siri 1 s).
            ServeWebRequest(path: "/button", json: ["name": .string(button.serveWebName), "state": .string(action?.rawValue ?? "press")])
        }
    }
}

extension HardwareButton {
    var serveWebName: String {
        switch self {
        case .home: "home"
        case .lock: "lock"
        case .volumeUp: "volume-up"
        case .volumeDown: "volume-down"
        case .siri: "siri"
        }
    }
}
