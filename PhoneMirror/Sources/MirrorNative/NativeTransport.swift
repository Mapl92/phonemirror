// SPDX-License-Identifier: GPL-3.0-or-later
// Native transport without Python, built on the findings from pymobiledevice3 (GPL-3.0-or-later).
import Foundation
import MirrorCore
import os

/// Mirrors the iPhone directly over the CoreDevice tunnel: RemoteXPC to `dtremotedisplayd` (video/audio),
/// `dtuhidd` (touch/keyboard/buttons) and the pasteboard service. Uses the existing pairing via
/// `remotepairingd` – without root, without Python, without an Xcode process.
public struct NativeTransport: MirrorTransport {
    public var screen: DeviceScreen
    public var udid: String?

    public init(screen: DeviceScreen = .iPhone15, udid: String? = nil) {
        self.screen = screen
        self.udid = udid
    }

    public var displayName: String { "iPhone (nativ)" }
    /// The session mounts the Developer Disk Image itself (`DeveloperDiskImageMounter`), without devicectl.
    public var requiresDevicePreparation: Bool { false }

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
        let rsd = try await Self.connectWithDeveloperServices(udid: udid)
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
        Self.logger.notice("Video running: [\(localIP, privacy: .public)]:\(videoReceiver.port)")

        // Audio (own connection, same client session ID as Xcode)
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
            Self.logger.error("Audio not available: \(error.localizedDescription, privacy: .public)")
        }

        // HID: backboardd only accepts input once the stream has “authenticated” the surfaces.
        try await Task.sleep(for: .milliseconds(500))
        hid = try await Self.connectHID(rsd)

        let pasteboard = PasteboardService { [rsd] in try await rsd.connect(service: PasteboardService.name) }
        self.pasteboard = pasteboard
        lastClipboardChange = try? await pasteboard.changeID()

        tasks.append(Task { [weak self] in await self?.watchClipboard() })
        tasks.append(Task { [weak self] in await self?.watchVideo() })
    }

    /// RSD connection that offers the DDI services. If they are missing, the Developer Disk Image is
    /// mounted natively; RSD only lists the new services after a fresh handshake, so it reconnects.
    private static func connectWithDeveloperServices(udid: String?) async throws -> RemoteServiceDiscovery {
        let rsd = try await RemoteServiceDiscovery.connect(udid: udid)
        guard rsd.port(of: DisplayService.name) == nil else { return rsd }
        if (try? await DeveloperMode.isEnabled(rsd: rsd)) == false {
            rsd.close()
            throw DeveloperDiskImageError.developerModeOff
        }
        do {
            try await DeveloperDiskImageMounter.mountIfNeeded(rsd: rsd)
            rsd.close()
        } catch let error as DeveloperDiskImageError {
            rsd.close()
            switch error {
            case .bundleMissing, .unsupportedOS:
                // Fallback for older iOS versions or a different DDI layout: Xcode's devicectl, if installed.
                logger.notice("Native DDI mount not possible (\(error.localizedDescription, privacy: .public)), trying devicectl")
                guard case .ready = await DevicePreparation.ensureDeveloperDiskImage() else { throw error }
            default:
                throw error
            }
        } catch {
            rsd.close()
            throw error
        }
        for _ in 0..<10 {
            try await Task.sleep(for: .seconds(1))
            let fresh = try await RemoteServiceDiscovery.connect(udid: udid)
            if fresh.port(of: DisplayService.name) != nil { return fresh }
            fresh.close()
        }
        throw DeveloperDiskImageError.cryptexd("the display service did not appear after mounting")
    }

    // MARK: Input

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

    /// iOS occasionally closes the HID connections (e.g. when camera apps start) while video
    /// keeps running. Then reconnect once and repeat the action.
    private func perform(_ action: DeviceAction) async throws {
        guard let hid else { return }
        do {
            try await perform(action, hid)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !closed, let rsd else { throw error }
            Self.logger.notice("HID disconnected (\(error.localizedDescription, privacy: .public)) – reconnecting")
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

    /// Mouse wheels deliver no gesture end: lift the finger after a short idle period.
    private func scheduleScrollRelease() {
        scrollIdleTask?.cancel()
        scrollIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            try? await self?.send(.scrollEnded)
        }
    }

    // MARK: Clipboard

    public func setClipboard(_ content: ClipboardContent) async throws {
        guard !closed, let pasteboard else { return }
        try await pasteboard.set(content)
        // Don't report our own change back as a copy from the iPhone.
        lastClipboardChange = try? await pasteboard.changeID()
    }

    /// Polls the change identifier every second (without data) and fetches content only on changes.
    private func watchClipboard() async {
        while !Task.isCancelled, !closed {
            try? await Task.sleep(for: .seconds(1))
            guard let pasteboard, let change = try? await pasteboard.changeID(), change != lastClipboardChange else { continue }
            lastClipboardChange = change
            if let content = try? await pasteboard.content() {
                Self.logger.notice("Clipboard taken over from iPhone (\(content.kindDescription, privacy: .public))")
                continuation.yield(.clipboard(content))
            } else {
                Self.logger.notice("Clipboard changed on the iPhone, but no text/PNG readable")
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
        return try await withTimeout(seconds: 20, "Listing apps") {
            try await AppService(connection: connection).installedApps()
        }
    }

    public func launchApp(bundleID: String) async throws {
        guard let rsd else { return }
        let connection = try await rsd.connect(service: AppService.name)
        defer { connection.close() }
        try await withTimeout(seconds: 15, "Launching app") {
            try await AppService(connection: connection).launch(bundleID: bundleID)
        }
    }

    // MARK: Video watchdog

    public func requestKeyframe() async {
        videoReceiver?.sendPictureLossIndication()
    }

    /// If the stream hangs: first request a keyframe, then let it reconnect.
    private func watchVideo() async {
        var lastPLI = Date.distantPast
        let started = Date()
        while !Task.isCancelled, !closed {
            try? await Task.sleep(for: .seconds(1))
            guard let videoReceiver else { continue }
            // Before the first packet, the time since the start counts.
            let silence = videoReceiver.hasReceivedPackets ? videoReceiver.secondsSinceLastPacket : Date().timeIntervalSince(started)
            if silence > 10 {
                continuation.yield(.disconnected(reason: "No more picture from the iPhone (\(Int(silence)) s)"))
                return
            }
            if silence > 4, Date().timeIntervalSince(lastPLI) > 2 {
                lastPLI = Date()
                videoReceiver.sendPictureLossIndication()
            }
            // Packets arrive, but no keyframe yet (start IDR missed): without a keyframe the picture stays
            // black or frozen – keep requesting until one arrives.
            if videoReceiver.hasReceivedPackets, assembler?.hasKeyframe == false, Date().timeIntervalSince(lastPLI) > 1.5 {
                lastPLI = Date()
                videoReceiver.sendPictureLossIndication()
                Self.logger.notice("No keyframe yet – PLI sent")
            }
        }
    }

    // MARK: Teardown

    public func close() async {
        guard !closed else { return }
        closed = true
        tasks.forEach { $0.cancel() }
        scrollIdleTask?.cancel()
        videoReceiver?.stop()
        audioReceiver?.stop()
        // End the streams on the device – otherwise it stays marked as “remote controlled” (camera/mic blocked).
        if let videoConnection {
            _ = try? await withTimeout(seconds: 3, "Stopping stream") {
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

/// Assembles RTP packets into frames on the receive thread; requests a keyframe on loss.
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

    /// Has a keyframe been received since the start? (Read by the watchdog.)
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
        // Lost frame: subsequent frames reference it – request a fresh keyframe (at most 2×/s).
        if depacketizer.droppedFrames > dropped, Date().timeIntervalSince(lastPLI) > 0.5 {
            lastPLI = Date()
            requestKeyframe()
        }
    }
}

extension HardwareButton {
    /// HID consumer usage and hold duration: Lock needs ≈ 0.5 s, Siri ≈ 1 s (otherwise discarded as bounce).
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
        case .text(let text): "Text, \(text.count) characters"
        case .png(let png): "PNG, \(png.count) Bytes"
        case .html(let html): "HTML, \(html.count) Bytes"
        case .rtf(let rtf): "RTF, \(rtf.count) Bytes"
        }
    }
}
