// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import MirrorCore
import os

/// Startet und überwacht WebDriverAgent auf dem iPhone (`xcodebuild test-without-building`).
/// WDA wird an die Tunnel-Adresse gebunden (`USE_IP`) und ist damit nur über den CoreDevice-Tunnel
/// dieses Macs erreichbar, nicht im WLAN. Wechselt der Tunnel, wird neu gestartet.
@MainActor
final class WDARunner {
    enum State: Equatable {
        case stopped
        case starting(String)
        case ready(String)
        case failed(String)
    }

    private(set) var state: State = .stopped
    private var process: Process?
    private var endpoint: DeviceEndpoint?
    private var startTask: Task<WebDriverAgentClient, Error>?
    private static let logger = Logger(subsystem: "PhoneMirror", category: "wda")
    static let port: UInt16 = 8100

    /// Standardort der mit `Scripts/build-wda.sh` gebauten Testlauf-Beschreibung. Bewusst nicht unter
    /// ~/Documents: Dort fragt macOS die (ad-hoc signierte) App bei jedem Neubau nach Ordnerzugriff und
    /// blockiert solange den Zugriff.
    static var defaultProductsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneMirror/WDA/wda-build/Build/Products")
    }

    static func findXCTestRun() -> URL? {
        if let custom = UserDefaults.standard.string(forKey: "wdaXCTestRun") {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: defaultProductsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "xctestrun" }
            .max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
    }

    var statusDescription: String {
        switch state {
        case .stopped: "gestoppt"
        case .starting(let address): "startet ([\(address)]:\(Self.port))"
        case .ready(let address): "bereit ([\(address)]:\(Self.port))"
        case .failed(let reason): "Fehler: \(reason)"
        }
    }

    /// Liefert einen einsatzbereiten Client; startet WDA bei Bedarf (erster Start ≈ 20–40 s).
    func client(for endpoint: DeviceEndpoint) async throws -> WebDriverAgentClient {
        if let startTask, self.endpoint == endpoint { return try await startTask.value }
        let client = WebDriverAgentClient(host: endpoint.tunnelAddress, port: Self.port)
        if self.endpoint == endpoint, case .ready = state, (try? await client.status(timeout: 2))?.ready == true {
            return client
        }
        stop()
        self.endpoint = endpoint
        let task = Task { [weak self] () throws -> WebDriverAgentClient in
            guard let self else { throw CancellationError() }
            return try await self.start(endpoint: endpoint, client: client)
        }
        startTask = task
        defer { startTask = nil }
        return try await task.value
    }

    private func start(endpoint: DeviceEndpoint, client: WebDriverAgentClient) async throws -> WebDriverAgentClient {
        // Läuft schon ein passend gebundenes WDA (z. B. nach App-Neustart)? Dann übernehmen.
        if (try? await client.status(timeout: 2))?.ready == true {
            state = .ready(endpoint.tunnelAddress)
            return client
        }
        guard let xctestrun = Self.findXCTestRun() else {
            state = .failed("WebDriverAgent nicht gebaut")
            throw AgentError("WebDriverAgent ist nicht gebaut. Einmalig ausführen: PhoneMirror/Scripts/build-wda.sh <Team-ID>")
        }
        state = .starting(endpoint.tunnelAddress)
        let logURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/PhoneMirror/wda.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild", "test-without-building", "-xctestrun", xctestrun.path, "-destination", "id=\(endpoint.udid)"]
        var environment = ProcessInfo.processInfo.environment
        // TEST_RUNNER_-Variablen reicht xcodebuild ohne Präfix an den Test-Runner weiter.
        environment["TEST_RUNNER_USE_IP"] = endpoint.tunnelAddress
        environment["TEST_RUNNER_USE_PORT"] = String(Self.port)
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.process === process else { return }
                Self.logger.notice("WebDriverAgent beendet (Status \(process.terminationStatus))")
                self.process = nil
                self.state = .failed("beendet (Status \(process.terminationStatus))")
            }
        }
        try process.run()
        self.process = process
        Self.logger.notice("WebDriverAgent startet: [\(endpoint.tunnelAddress, privacy: .public)]:\(Self.port)")

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            guard self.process === process, process.isRunning else {
                throw AgentError("WebDriverAgent wurde beendet – Details in ~/Library/Logs/PhoneMirror/wda.log")
            }
            if (try? await client.status(timeout: 2))?.ready == true {
                state = .ready(endpoint.tunnelAddress)
                Self.logger.notice("WebDriverAgent bereit")
                return client
            }
        }
        stop()
        state = .failed("Zeitüberschreitung beim Start")
        throw AgentError("WebDriverAgent ist nicht rechtzeitig gestartet – Details in ~/Library/Logs/PhoneMirror/wda.log")
    }

    func stop() {
        if let process, process.isRunning {
            process.interrupt() // xcodebuild beendet den Testlauf und damit WDA auf dem iPhone
        }
        process = nil
        state = .stopped
    }
}

private extension URL {
    var modificationDate: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}
