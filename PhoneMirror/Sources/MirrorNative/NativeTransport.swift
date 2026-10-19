// SPDX-License-Identifier: GPL-3.0-or-later
// Nativer Transport ohne Python, aufgebaut auf den Erkenntnissen aus pymobiledevice3 (GPL-3.0-or-later).
import Foundation
import MirrorCore
import os

/// Spiegelt das iPhone direkt über den CoreDevice-Tunnel: RemoteXPC zu `dtremotedisplayd` (Video/Ton),
/// `dtuhidd` (Touch/Tastatur/Tasten) und dem Pasteboard-Dienst. Nutzt die bestehende Kopplung über
/// `remotepairingd` – ohne Root, ohne Python, ohne Xcode-Prozess.
public struct NativeTransport: MirrorTransport {
    public var screen: DeviceScreen
    public var udid: String?

    public init(screen: DeviceScreen = .iPhone15, udid: String? = nil) {
        self.screen = screen
        self.udid = udid
    }

    public var displayName: String { "iPhone (nativ)" }
    public var requiresDevicePreparation: Bool { true }

    public func connect() async throws -> any MirrorSession {
        let session = NativeSession(screen: screen)
        do {
            try await session.start(udid: udid)
        } catch {
            await session.close()
            throw error
        }
        return session
    }
}

public actor NativeSession: MirrorSession {
    public nonisolated let screen: DeviceScreen
    public nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    private var rsd: RemoteServiceDiscovery?
    private var videoConnection: RemoteXPCConnection?
    private var audioConnection: RemoteXPCConnection?
    private var videoReceiver: RTPReceiver?
    private var audioReceiver: RTPReceiver?
    private var hid: HIDService?
    private var assembler: VideoAssembler?
    private var pasteboard: PasteboardService?
    private var encoder: InputActionEncoder
    private var tasks: [Task<Void, Never>] = []
    private var scrollIdleTask: Task<Void, Never>?
    private var lastClipboardChange: String?
    private var closed = false
    private static let logger = Logger(subsystem: "PhoneMirror", category: "native")

    init(screen: DeviceScreen) {
        self.screen = screen
        encoder = InputActionEncoder(screen: screen)
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
    }

    func start(udid: String?) async throws {
        continuation.yield(.screenChanged(screen))
        let rsd = try await RemoteServiceDiscovery.connect(udid: udid)
        self.rsd = rsd
        let sessionID = UUID()

        // Video
        let videoConnection = try await rsd.connect(service: DisplayService.name)
        self.videoConnection = videoConnection
        let videoReceiver = try RTPReceiver()
        self.videoReceiver = videoReceiver
        let display = DisplayService(connection: videoConnection)
        let localIP = videoConnection.localAddress ?? ""
        let videoAnswer = try await display.startStream(
            .video, receiverIP: localIP, receiverPort: videoReceiver.port, senderIP: rsd.address, sessionID: sessionID
        )
        let assembler = VideoAssembler(continuation: continuation) { [weak videoReceiver] in
            videoReceiver?.sendPictureLossIndication()
        }
        self.assembler = assembler
        videoReceiver.start(deviceAddress: rsd.address, answer: videoAnswer) { assembler.push($0) }
        Self.logger.notice("Video läuft: [\(localIP, privacy: .public)]:\(videoReceiver.port)")

        // Ton (eigene Verbindung, gleiche Client-Session-ID wie Xcode)
        do {
            let audioConnection = try await rsd.connect(service: DisplayService.name)
            self.audioConnection = audioConnection
            let audioReceiver = try RTPReceiver()
            self.audioReceiver = audioReceiver
            let audioAnswer = try await DisplayService(connection: audioConnection).startStream(
                .audio, receiverIP: audioConnection.localAddress ?? localIP, receiverPort: audioReceiver.port,
                senderIP: rsd.address, sessionID: sessionID
            )
            let decoder = try AACELDDecoder()
            let continuation = continuation
            audioReceiver.start(deviceAddress: rsd.address, answer: audioAnswer) { packet in
                guard let rtp = RTPPacket(packet), let pcm = try? decoder.decode(rtp.payload), !pcm.isEmpty else { return }
                continuation.yield(.audio(AudioChunk(pcm: pcm)))
            }
        } catch {
            Self.logger.error("Ton nicht verfügbar: \(error.localizedDescription, privacy: .public)")
        }

        // HID: backboardd akzeptiert Eingaben erst, wenn der Stream die Flächen „authentifiziert“ hat.
        try await Task.sleep(for: .milliseconds(500))
        hid = try await Self.connectHID(rsd)

        let pasteboard = PasteboardService { [rsd] in try await rsd.connect(service: PasteboardService.name) }
        self.pasteboard = pasteboard
        lastClipboardChange = try? await pasteboard.changeID()

        tasks.append(Task { [weak self] in await self?.watchClipboard() })
        tasks.append(Task { [weak self] in await self?.watchVideo() })
    }

    // MARK: Eingabe

    public func send(_ event: InputEvent) async throws {
        guard !closed, hid != nil else { return }
        for action in encoder.actions(for: event) {
            try await perform(action)
        }
        if case .scroll = event { scheduleScrollRelease() }
        if case .gesture(let gesture) = event {
            for step in gesture.steps {
                if case .wait(let seconds) = step { try await Task.sleep(for: .seconds(seconds)) }
                for action in encoder.actions(forStep: step) {
                    try await perform(action)
                }
            }
        }
    }

    private static func connectHID(_ rsd: RemoteServiceDiscovery) async throws -> HIDService {
        HIDService(
            universal: try await rsd.connect(service: HIDService.universalName),
            indigo: try await rsd.connect(service: HIDService.indigoName)
        )
    }

    /// iOS schließt die HID-Verbindungen gelegentlich (z. B. beim Start von Kamera-Apps), während Video
    /// weiterläuft. Dann einmal neu verbinden und die Aktion wiederholen.
    private func perform(_ action: DeviceAction) async throws {
        guard let hid else { return }
        do {
            try await perform(action, hid)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !closed, let rsd else { throw error }
            Self.logger.notice("HID getrennt (\(error.localizedDescription, privacy: .public)) – verbinde neu")
            hid.close()
            let fresh = try await Self.connectHID(rsd)
            self.hid = fresh
            try await perform(action, fresh)
        }
    }

    private func perform(_ action: DeviceAction, _ hid: HIDService) async throws {
        switch action {
        case .touch(let contact, let point):
            try await hid.touch(contact: contact, at: point)
        case .keys(let usages):
            try await hid.keyboard(usages: usages)
        case .button(let button, let state):
            let (page, usage, hold) = button.consumerUsage
            switch state {
            case nil: try await hid.press(usagePage: page, usage: usage, hold: hold)
            case .down: try await hid.button(usagePage: page, usage: usage, state: 1)
            case .up: try await hid.button(usagePage: page, usage: usage, state: 2)
            }
        }
    }

    /// Mausräder liefern kein Gestenende: Finger nach kurzer Ruhe heben.
    private func scheduleScrollRelease() {
        scrollIdleTask?.cancel()
        scrollIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            try? await self?.send(.scrollEnded)
        }
    }

    // MARK: Zwischenablage

    public func setClipboard(_ content: ClipboardContent) async throws {
        guard !closed, let pasteboard else { return }
        try await pasteboard.set(content)
        // Die eigene Änderung nicht als Kopie vom iPhone zurückmelden.
        lastClipboardChange = try? await pasteboard.changeID()
    }

    /// Fragt jede Sekunde die Änderungskennung ab (ohne Daten) und holt Inhalt nur bei Änderungen.
    private func watchClipboard() async {
        while !Task.isCancelled, !closed {
            try? await Task.sleep(for: .seconds(1))
            guard let pasteboard, let change = try? await pasteboard.changeID(), change != lastClipboardChange else { continue }
            lastClipboardChange = change
            if let content = try? await pasteboard.content() {
                Self.logger.notice("Zwischenablage vom iPhone übernommen (\(content.kindDescription, privacy: .public))")
                continuation.yield(.clipboard(content))
            } else {
                Self.logger.notice("Zwischenablage auf dem iPhone geändert, aber kein Text/PNG lesbar")
            }
        }
    }

    public func clipboardContent() async throws -> ClipboardContent? {
        guard let pasteboard else { return nil }
        return try await pasteboard.content()
    }

    public func deviceEndpoint() async -> DeviceEndpoint? {
        guard let rsd, let udid = rsd.tunnel.udid else { return nil }
        return DeviceEndpoint(tunnelAddress: rsd.address, udid: udid)
    }

    // MARK: Apps

    public func installedApps() async throws -> [InstalledApp] {
        guard let rsd else { return [] }
        let connection = try await rsd.connect(service: AppService.name)
        defer { connection.close() }
        return try await withTimeout(seconds: 20, "Apps auflisten") {
            try await AppService(connection: connection).installedApps()
        }
    }

    public func launchApp(bundleID: String) async throws {
        guard let rsd else { return }
        let connection = try await rsd.connect(service: AppService.name)
        defer { connection.close() }
        try await withTimeout(seconds: 15, "App starten") {
            try await AppService(connection: connection).launch(bundleID: bundleID)
        }
    }

    // MARK: Video-Überwachung

    public func requestKeyframe() async {
        videoReceiver?.sendPictureLossIndication()
    }

    /// Hängt der Stream: erst Keyframe anfordern, dann neu verbinden lassen.
    private func watchVideo() async {
        var lastPLI = Date.distantPast
        let started = Date()
        while !Task.isCancelled, !closed {
            try? await Task.sleep(for: .seconds(1))
            guard let videoReceiver else { continue }
            // Vor dem ersten Paket zählt die Zeit seit dem Start.
            let silence = videoReceiver.hasReceivedPackets ? videoReceiver.secondsSinceLastPacket : Date().timeIntervalSince(started)
            if silence > 10 {
                continuation.yield(.disconnected(reason: "Kein Bild mehr vom iPhone (\(Int(silence)) s)"))
                return
            }
            if silence > 4, Date().timeIntervalSince(lastPLI) > 2 {
                lastPLI = Date()
                videoReceiver.sendPictureLossIndication()
            }
            // Pakete kommen, aber noch kein Keyframe (Start-IDR verpasst): ohne Keyframe bleibt das Bild
            // schwarz bzw. eingefroren – nachfordern, bis eins da ist.
            if videoReceiver.hasReceivedPackets, assembler?.hasKeyframe == false, Date().timeIntervalSince(lastPLI) > 1.5 {
                lastPLI = Date()
                videoReceiver.sendPictureLossIndication()
                Self.logger.notice("Noch kein Keyframe – PLI gesendet")
            }
        }
    }

    // MARK: Ende

    public func close() async {
        guard !closed else { return }
        closed = true
        tasks.forEach { $0.cancel() }
        scrollIdleTask?.cancel()
        videoReceiver?.stop()
        audioReceiver?.stop()
        // Streams auf dem Gerät beenden – sonst bleibt es „ferngesteuert“ markiert (Kamera/Mikro gesperrt).
        if let videoConnection {
            _ = try? await withTimeout(seconds: 3, "Stream stoppen") {
                try await DisplayService(connection: videoConnection).stopAllStreams()
            }
        }
        hid?.close()
        videoConnection?.close()
        audioConnection?.close()
        rsd?.close()
        continuation.finish()
    }
}

/// Setzt RTP-Pakete auf dem Empfangs-Thread zu Bildern zusammen; fordert bei Verlust ein Keyframe an.
final class VideoAssembler: @unchecked Sendable {
    private var depacketizer = RTPHEVCDepacketizer()
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let requestKeyframe: @Sendable () -> Void
    private var lastPLI = Date.distantPast

    init(continuation: AsyncStream<TransportEvent>.Continuation, requestKeyframe: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.requestKeyframe = requestKeyframe
    }

    private let lock = NSLock()
    private var sawKeyframe = false

    /// Wurde seit dem Start ein Keyframe empfangen? (Vom Watchdog gelesen.)
    var hasKeyframe: Bool {
        lock.lock(); defer { lock.unlock() }
        return sawKeyframe
    }

    func push(_ packet: Data) {
        let dropped = depacketizer.droppedFrames
        if let frame = depacketizer.push(packet) {
            if !hasKeyframe, AnnexB.split(frame.annexB).contains(where: { HEVCNALType.isIRAP($0.type) }) {
                lock.lock(); sawKeyframe = true; lock.unlock()
            }
            continuation.yield(.video(frame))
        }
        // Verlorenes Bild: Folgebilder verweisen darauf – frisches Keyframe anfordern (höchstens 2×/s).
        if depacketizer.droppedFrames > dropped, Date().timeIntervalSince(lastPLI) > 0.5 {
            lastPLI = Date()
            requestKeyframe()
        }
    }
}

extension HardwareButton {
    /// HID-Consumer-Usage und Haltedauer: Sperren braucht ≈ 0,5 s, Siri ≈ 1 s (sonst als Prellen verworfen).
    var consumerUsage: (page: UInt16, usage: UInt16, hold: Double) {
        switch self {
        case .home: (0x0C, 0x40, 0.05)
        case .lock: (0x0C, 0x30, 0.5)
        case .volumeUp: (0x0C, 0xE9, 0.05)
        case .volumeDown: (0x0C, 0xEA, 0.05)
        case .siri: (0x0C, 0xCF, 1.0)
        }
    }
}

extension ClipboardContent {
    var kindDescription: String {
        switch self {
        case .text(let text): "Text, \(text.count) Zeichen"
        case .png(let png): "PNG, \(png.count) Bytes"
        case .html(let html): "HTML, \(html.count) Bytes"
        case .rtf(let rtf): "RTF, \(rtf.count) Bytes"
        }
    }
}
