// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import MirrorCore
import os

/// Starts and monitors WebDriverAgent on the iPhone (`xcodebuild test-without-building`).
/// WDA is bound to the tunnel address (`USE_IP`) and is therefore only reachable through this Mac's
/// CoreDevice tunnel, not over Wi-Fi. If the tunnel changes, it is restarted.
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

    /// Default location of the test run description built with `Scripts/build-wda.sh`. Deliberately not under
    /// ~/Documents: there macOS asks the (ad-hoc signed) app for folder access on every rebuild and
    /// blocks access until then.
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
        case .stopped: "stopped"
        case .starting(let address): "starting ([\(address)]:\(Self.port))"
        case .ready(let address): "ready ([\(address)]:\(Self.port))"
        case .failed(let reason): "error: \(reason)"
        }
    }

    /// Returns a ready-to-use client; starts WDA if needed (first start ≈ 20–40 s).
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
        // Is a suitably bound WDA already running (e.g. after an app restart)? Then take it over.
        if (try? await client.status(timeout: 2))?.ready == true {
            state = .ready(endpoint.tunnelAddress)
            return client
        }
        guard let xctestrun = Self.findXCTestRun() else {
            state = .failed("WebDriverAgent not built")
            throw AgentError("WebDriverAgent is not built. Run once: PhoneMirror/Scripts/build-wda.sh <Team-ID>")
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
        // xcodebuild passes TEST_RUNNER_ variables on to the test runner without the prefix.
        environment["TEST_RUNNER_USE_IP"] = endpoint.tunnelAddress
        environment["TEST_RUNNER_USE_PORT"] = String(Self.port)
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.process === process else { return }
                Self.logger.notice("WebDriverAgent exited (status \(process.terminationStatus))")
                self.process = nil
                self.state = .failed("exited (status \(process.terminationStatus))")
            }
        }
        try process.run()
        self.process = process
        Self.logger.notice("WebDriverAgent starting: [\(endpoint.tunnelAddress, privacy: .public)]:\(Self.port)")

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            guard self.process === process, process.isRunning else {
                throw AgentError("WebDriverAgent exited – details in ~/Library/Logs/PhoneMirror/wda.log")
            }
            if (try? await client.status(timeout: 2))?.ready == true {
                state = .ready(endpoint.tunnelAddress)
                Self.logger.notice("WebDriverAgent ready")
                return client
            }
        }
        stop()
        state = .failed("timed out while starting")
        throw AgentError("WebDriverAgent did not start in time – details in ~/Library/Logs/PhoneMirror/wda.log")
    }

    func stop() {
        if let process, process.isRunning {
            process.interrupt() // xcodebuild ends the test run and with it WDA on the iPhone
        }
        process = nil
        state = .stopped
    }
}

private extension URL {
    var modificationDate: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}
