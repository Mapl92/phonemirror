// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

public enum ServeWebTransportError: LocalizedError {
    case executableNotFound([String])
    case processExited(status: Int32, output: String)
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let candidates):
            "pymobiledevice3 nicht gefunden (gesucht: \(candidates.joined(separator: ", ")))."
        case .processExited(let status, let output):
            "pymobiledevice3 wurde beendet (Status \(status)).\n\(output)"
        case .notReady(let reason):
            "Der Stream ist nicht bereit: \(reason)"
        }
    }
}

/// Live-Verbindung über pymobiledevice3 `serve-web` als lokale Brücke:
/// Der Prozess hält Tunnel, RTCP, Keyframe-Wiederanlauf und HID-Dienste;
/// PhoneMirror liest `/stream.bin` und sendet Eingaben an `/touch`, `/key`, `/button`.
/// Der Tunnel nutzt `--native` (bestehende Kopplung über Apples `remotepairingd`, kein Root).
public struct ServeWebTransport: MirrorTransport {
    public var executable: URL?
    public var screen: DeviceScreen
    public var extraArguments: [String]

    public init(executable: URL? = nil, screen: DeviceScreen = .iPhone15, extraArguments: [String] = []) {
        self.executable = executable
        self.screen = screen
        self.extraArguments = extraArguments
    }

    public var displayName: String { "iPhone (live)" }
    public var requiresDevicePreparation: Bool { true }

    public static let executableCandidates: [String] = [
        "~/.local/bin/pymobiledevice3",
        "/opt/homebrew/bin/pymobiledevice3",
        "/usr/local/bin/pymobiledevice3",
    ]

    public func connect() async throws -> any MirrorSession {
        let executable = try executable ?? Self.findExecutable()
        let session = try ServeWebSession(executable: executable, screen: screen, extraArguments: extraArguments)
        do {
            try await session.start()
        } catch {
            await session.close()
            throw error
        }
        return session
    }

    static func findExecutable() throws -> URL {
        let paths = executableCandidates.map { ($0 as NSString).expandingTildeInPath }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ServeWebTransportError.executableNotFound(paths)
        }
        return URL(fileURLWithPath: path)
    }
}

public actor ServeWebSession: MirrorSession {
    public nonisolated let screen: DeviceScreen
    public nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let process = Process()
    private let output = ProcessOutput()
    private let baseURL: URL
    private let authorization: String
    private let urlSession: URLSession
    private let streamReceiver: StreamReceiver
    private var encoder: ServeWebInputEncoder
    private var scrollIdleTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    private var closed = false
    private static let logger = Logger(subsystem: "PhoneMirror", category: "serve-web")

    init(executable: URL, screen: DeviceScreen, extraArguments: [String]) throws {
        self.screen = screen
        encoder = ServeWebInputEncoder(screen: screen)
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation

        let port = try Self.freeLocalPort()
        let password = UUID().uuidString
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        authorization = "Basic " + Data("phonemirror:\(password)".utf8).base64EncodedString()

        process.executableURL = executable
        process.arguments = [
            "developer", "core-device", "display", "serve-web",
            "--native", "--bind", "127.0.0.1", "--http-port", String(port),
            "--password", password, "--no-audio",
        ] + extraArguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        output.attach(pipe)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = .infinity
        configuration.httpMaximumConnectionsPerHost = 4
        let receiver = StreamReceiver(continuation: continuation)
        streamReceiver = receiver
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        urlSession = URLSession(configuration: configuration, delegate: receiver, delegateQueue: delegateQueue)
    }

    func start() async throws {
        continuation.yield(.screenChanged(screen))
        let output = output
        let continuation = continuation
        process.terminationHandler = { process in
            let tail = output.tail
            Self.logger.notice("serve-web beendet: \(process.terminationStatus) \(tail, privacy: .public)")
            continuation.yield(.disconnected(reason: "pymobiledevice3 beendet (Status \(process.terminationStatus))\n\(tail)"))
            continuation.finish()
        }
        try process.run()
        Self.logger.notice("serve-web gestartet: \(self.baseURL.absoluteString, privacy: .public)")

        // /codec antwortet 200, sobald VPS/SPS/PPS und ein Keyframe da sind (startet den Gerätestream).
        let deadline = Date().addingTimeInterval(45)
        var lastStatus = "keine Antwort"
        while Date() < deadline {
            guard process.isRunning else {
                throw ServeWebTransportError.processExited(status: process.terminationStatus, output: output.tail)
            }
            if let status = try? await get("/codec") {
                if status == 200 { break }
                lastStatus = "HTTP \(status)"
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        guard Date() < deadline else { throw ServeWebTransportError.notReady(lastStatus) }

        for path in ["/stream.bin", "/audio.bin"] {
            var request = URLRequest(url: baseURL.appending(path: path))
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            urlSession.dataTask(with: request).resume()
        }
        clipboardTask = Task { [weak self] in await self?.watchDeviceClipboard() }
    }

    /// Long-Poll auf `/clipboard/events`: meldet, was auf dem Gerät kopiert wird.
    private func watchDeviceClipboard() async {
        var since: Int?
        var failures = 0
        while !Task.isCancelled, !closed {
            do {
                var components = URLComponents(url: baseURL.appending(path: "/clipboard/events"), resolvingAgainstBaseURL: false)!
                if let since { components.queryItems = [URLQueryItem(name: "since", value: String(since))] }
                var request = URLRequest(url: components.url!)
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 40
                let (data, _) = try await urlSession.data(for: request)
                let event = try JSONDecoder().decode(ServeWebClipboardEvent.self, from: data)
                failures = 0
                if since != nil {
                    if let text = event.text {
                        continuation.yield(.clipboard(.text(text)))
                    } else if event.image != nil, let png = try? await fetch("/clipboard/image") {
                        continuation.yield(.clipboard(.png(png)))
                    }
                }
                since = event.seq
            } catch {
                failures += 1
                if failures >= 5 {
                    Self.logger.error("Zwischenablage-Abgleich beendet: \(error.localizedDescription, privacy: .public)")
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func setClipboard(_ content: ClipboardContent) async throws {
        guard !closed else { return }
        var request = URLRequest(url: baseURL.appending(path: "/clipboard" + (content.isImage ? "/image" : "")))
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        switch content {
        case .text(let text):
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        case .png(let png):
            request.setValue("image/png", forHTTPHeaderField: "Content-Type")
            request.httpBody = png
        case .html, .rtf:
            return
        }
        let (_, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 { Self.logger.error("Zwischenablage setzen → HTTP \(status)") }
    }

    public func clipboardContent() async throws -> ClipboardContent? {
        let data = try await fetch("/clipboard")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"].flatMap { $0 as? String }.map(ClipboardContent.text)
    }

    public func requestKeyframe() async {
        guard !closed else { return }
        var request = URLRequest(url: baseURL.appending(path: "/pli"))
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        _ = try? await urlSession.data(for: request)
    }

    private func fetch(_ path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private func get(_ path: String) async throws -> Int {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (_, response) = try await urlSession.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    public func send(_ event: InputEvent) async throws {
        guard !closed else { return }
        for request in encoder.requests(for: event) {
            try await post(request)
        }
        if case .scroll = event { scheduleScrollRelease() }
        if case .gesture(let gesture) = event {
            for step in gesture.steps {
                if case .wait(let seconds) = step {
                    try await Task.sleep(for: .seconds(seconds))
                }
                for request in encoder.requests(forStep: step) {
                    try await post(request)
                }
            }
        }
    }

    /// Mausräder liefern kein Gestenende: Finger nach kurzer Ruhe automatisch heben.
    private func scheduleScrollRelease() {
        scrollIdleTask?.cancel()
        scrollIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            try? await self?.send(.scrollEnded)
        }
    }

    private func post(_ request: ServeWebRequest) async throws {
        var urlRequest = URLRequest(url: baseURL.appending(path: request.path))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = request.body
        let (_, response) = try await urlSession.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            Self.logger.error("\(request.path, privacy: .public) → HTTP \(status)")
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        scrollIdleTask?.cancel()
        clipboardTask?.cancel()
        urlSession.invalidateAndCancel()
        if process.isRunning {
            // SIGINT: serve-web beendet den Gerätestream sauber (stopmediastream) bevor es aussteigt.
            process.interrupt()
            for _ in 0..<30 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { process.terminate() }
        }
        continuation.finish()
    }

    private static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// Empfängt `/stream.bin` stückweise und liefert fertige Bilder an die Session.
/// Läuft ausschließlich auf der seriellen Delegate-Queue der URLSession.
private final class StreamReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var parser = ServeWebStreamParser()
    private var audioParser = ServeWebAudioParser()
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private static let logger = Logger(subsystem: "PhoneMirror", category: "serve-web")

    init(continuation: AsyncStream<TransportEvent>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        switch dataTask.originalRequest?.url?.path {
        case "/stream.bin":
            for packet in parser.append(data) { continuation.yield(.video(packet)) }
        case "/audio.bin":
            for chunk in audioParser.append(data) { continuation.yield(.audio(chunk)) }
        default:
            break
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard task.originalRequest?.url?.path == "/stream.bin" else { return }
        let reason = error.map { $0.localizedDescription } ?? "Stream beendet"
        Self.logger.notice("/stream.bin beendet: \(reason, privacy: .public)")
        if (error as? URLError)?.code != .cancelled {
            continuation.yield(.disconnected(reason: reason))
        }
    }
}

/// Sammelt die Ausgabe von pymobiledevice3 fürs Log und für Fehlermeldungen (letzte Zeilen).
private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private static let logger = Logger(subsystem: "PhoneMirror", category: "pymobiledevice3")

    func attach(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.append(text)
        }
    }

    private func append(_ text: String) {
        let newLines = text.split(separator: "\n").map(String.init)
        for line in newLines {
            Self.logger.notice("\(line, privacy: .public)")
        }
        lock.lock()
        lines.append(contentsOf: newLines)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        lock.unlock()
    }

    var tail: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.suffix(8).joined(separator: "\n")
    }
}
