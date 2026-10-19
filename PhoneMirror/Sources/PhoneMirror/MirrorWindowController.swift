// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MirrorCore
import os

/// Ein Fenster pro Gerät: hält die Verbindung (mit automatischem Wiederverbinden) und verbindet
/// Video, Ton, Zwischenablage und Eingabe.
@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    private var transport: any MirrorTransport
    private let settings = AppSettings.shared
    private let mirrorView = MirrorView()
    private let audioPlayer = AudioPlayer()
    private let clipboard = ClipboardBridge()
    private var session: (any MirrorSession)?
    private var connectionTask: Task<Void, Never>?
    private var inputPump: InputPump?
    private var sampleBuilder = HEVCSampleBuilder()
    private var decoder: VideoDecoder?
    private var screen = DeviceScreen.iPhone15
    private var isResizingProgrammatically = false

    /// Zuletzt angezeigtes Bild – Quelle für Agent-Screenshots.
    struct Frame {
        var pixelBuffer: CVPixelBuffer
        var visible: CGSize
        var time: Date
    }
    private(set) var latestFrame: Frame?
    var activeSession: (any MirrorSession)? { session }
    var currentScreen: DeviceScreen { screen }
    var transportName: String { transport.displayName }

    /// Agent hat etwas getan: Hinweis im Fenster, bei Touches mit Position.
    func noteAgentActivity(at point: TouchPoint?) {
        mirrorView.showAgentActivity(at: point)
    }

    /// Eigenen Inhalt der Mac-Zwischenablage nicht aufs iPhone übertragen (z. B. den MCP-Befehl mit Token).
    func ignoreCurrentMacClipboard() {
        clipboard.ignoreCurrentContent()
    }
    private static let logger = Logger(subsystem: "PhoneMirror", category: "window")

    init(transport: any MirrorTransport) {
        self.transport = transport
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = transport.displayName
        window.backgroundColor = .black
        window.isMovableByWindowBackground = false
        window.contentView = mirrorView
        super.init(window: window)
        window.delegate = self
        mirrorView.onInput = { [weak self] event in self?.inputPump?.enqueue(event) }
        audioPlayer.isEnabled = settings.soundEnabled
        clipboard.isEnabled = settings.clipboardSync
        clipboard.onLocalChange = { [weak self] content in self?.pushClipboard(content) }
        apply(screen: screen, resize: true)
        window.center()
        // Position (und Größe) über Neustarts merken.
        window.setFrameAutosaveName("PhoneMirrorWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Verbindung

    /// Verbindungsart wechseln: laufende Session schließen und mit dem neuen Transport verbinden.
    func replaceTransport(_ newTransport: any MirrorTransport) {
        connectionTask?.cancel()
        connectionTask = nil
        Task {
            await tearDownSession()
            transport = newTransport
            window?.title = newTransport.displayName
            connect()
        }
    }

    func connect() {
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in await self?.connectionLoop() }
    }

    /// Verbinden, Ereignisse verarbeiten, bei Abbruch mit wachsender Pause neu verbinden.
    private func connectionLoop() async {
        var failures = 0
        while !Task.isCancelled {
            if transport.requiresDevicePreparation {
                mirrorView.showStatus("Bereite iPhone vor …")
                switch await DevicePreparation.ensureDeveloperDiskImage() {
                case .ready:
                    break
                case .locked(let name):
                    mirrorView.showStatus("Bitte „\(name)“ entsperren …")
                    try? await Task.sleep(for: .seconds(3))
                    continue
                case .noDevice:
                    mirrorView.showStatus("Kein gekoppeltes iPhone gefunden.\nKopplung über Xcode/Device Hub nötig.")
                    try? await Task.sleep(for: .seconds(5))
                    continue
                case .failed(let reason):
                    // Das DDI ist evtl. schon gemountet – trotzdem verbinden.
                    Self.logger.notice("DDI-Vorbereitung: \(reason, privacy: .public)")
                }
            }
            guard !Task.isCancelled else { return }
            mirrorView.showStatus("Verbinde mit \(transport.displayName) …")
            var reason = "Verbindung beendet"
            do {
                let session = try await transport.connect()
                failures = 0
                await run(session)
            } catch is CancellationError {
                return
            } catch {
                reason = error.localizedDescription
            }
            await tearDownSession()
            guard !Task.isCancelled else { return }
            failures += 1
            let delay = min(pow(2, Double(failures - 1)), 15)
            mirrorView.showStatus("\(reason)\n\nNeuer Versuch in \(Int(delay)) s …")
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func run(_ session: any MirrorSession) async {
        self.session = session
        inputPump = InputPump(session: session)
        sampleBuilder = HEVCSampleBuilder()
        apply(screen: session.screen, resize: false)
        decoder = makeDecoder()
        for await event in session.events {
            if case .disconnected(let reason) = event {
                if let reason { Self.logger.notice("Getrennt: \(reason, privacy: .public)") }
                return
            }
            handle(event)
        }
    }

    private func tearDownSession() async {
        inputPump = nil
        latestFrame = nil
        decoder?.reset()
        decoder = nil
        audioPlayer.stop()
        let session = session
        self.session = nil
        await session?.close()
    }

    private func makeDecoder() -> VideoDecoder {
        let screenPixels = CGSize(width: screen.pixelWidth, height: screen.pixelHeight)
        return VideoDecoder { [weak self] pixelBuffer in
            // Erkennung auf dem Decoder-Thread, Anzeige auf dem Main Thread.
            let coded = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            let collapsed = ContentRectDetector.collapsedContentSize(in: pixelBuffer)
            let visible = ContentRectDetector.visibleFraction(codedPixels: coded, screenPixels: screenPixels, collapsed: collapsed)
            nonisolated(unsafe) let frame = pixelBuffer
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.mirrorView.display(frame, visible: visible)
                    self?.latestFrame = Frame(pixelBuffer: frame, visible: visible, time: Date())
                }
            }
        }
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .video(let packet):
            do {
                if packet.resetDecoder { decoder?.reset() }
                guard let output = try sampleBuilder.makeSample(from: packet) else { return }
                if output.formatChanged, let dimensions = sampleBuilder.dimensions {
                    Self.logger.notice("Videoformat: \(dimensions.width)×\(dimensions.height)")
                }
                try decoder?.decode(output.sampleBuffer)
            } catch {
                Self.logger.error("Bild verworfen: \(String(describing: error), privacy: .public)")
                // Nach einem Dekodierfehler braucht der Decoder ein Keyframe.
                let session = session
                Task { await session?.requestKeyframe() }
            }
        case .audio(let chunk):
            audioPlayer.play(chunk)
        case .clipboard(let content):
            clipboard.applyRemote(content)
        case .screenChanged(let newScreen):
            apply(screen: newScreen, resize: newScreen.pointSize != screen.pointSize)
        case .disconnected:
            break
        }
    }

    private func pushClipboard(_ content: ClipboardContent) {
        guard let session else { return }
        Task {
            do {
                try await session.setClipboard(content)
            } catch {
                Self.logger.error("Zwischenablage → iPhone: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Fenster

    private func apply(screen: DeviceScreen, resize: Bool) {
        self.screen = screen
        mirrorView.screen = screen
        guard let window else { return }
        window.contentAspectRatio = screen.pointSize
        if resize {
            let size = CGSize(width: screen.pointSize.width * settings.zoom, height: screen.pointSize.height * settings.zoom)
            isResizingProgrammatically = true
            window.setContentSize(size)
            isResizingProgrammatically = false
        }
    }

    /// Größe, die der Nutzer per Ziehen einstellt, als Zoom merken.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window, !isResizingProgrammatically else { return }
        settings.zoom = window.contentLayoutRect.width / screen.pointSize.width
    }

    func windowWillClose(_ notification: Notification) {
        Task { await shutdown() }
    }

    /// Schließt die Session (beendet bei Live-Betrieb den pymobiledevice3-Prozess).
    func shutdown() async {
        connectionTask?.cancel()
        connectionTask = nil
        clipboard.invalidate()
        await tearDownSession()
    }

    // MARK: - Menü-Aktionen

    func send(_ event: InputEvent) {
        inputPump?.enqueue(event)
    }

    var soundEnabled: Bool {
        get { audioPlayer.isEnabled }
        set {
            audioPlayer.isEnabled = newValue
            settings.soundEnabled = newValue
        }
    }

    var clipboardSync: Bool {
        get { clipboard.isEnabled }
        set {
            clipboard.isEnabled = newValue
            settings.clipboardSync = newValue
        }
    }

    @objc func pressHardwareButton(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let button = HardwareButton(rawValue: raw) else { return }
        inputPump?.enqueue(.button(button, isDown: true))
        inputPump?.enqueue(.button(button, isDown: false))
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(settings.zoom * 1.15) }
    @objc func zoomOut(_ sender: Any?) { setZoom(settings.zoom / 1.15) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ value: Double) {
        settings.zoom = value
        apply(screen: screen, resize: true)
    }
}

/// Reicht Eingaben strikt in Reihenfolge an die Session weiter (Touch-Phasen dürfen sich nicht überholen).
@MainActor
final class InputPump {
    private let continuation: AsyncStream<InputEvent>.Continuation
    private let task: Task<Void, Never>
    private static let logger = Logger(subsystem: "PhoneMirror", category: "input")

    init(session: any MirrorSession) {
        let (stream, continuation) = AsyncStream.makeStream(of: InputEvent.self)
        self.continuation = continuation
        task = Task {
            for await event in stream {
                do {
                    try await session.send(event)
                } catch {
                    Self.logger.error("Eingabe fehlgeschlagen: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    func enqueue(_ event: InputEvent) {
        continuation.yield(event)
    }

    isolated deinit {
        continuation.finish()
        task.cancel()
    }
}
