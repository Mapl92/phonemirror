// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// HTTP client for WebDriverAgent on the iPhone (via the CoreDevice tunnel address).
/// Only reading the accessibility tree is used – taps go through PhoneMirror's own HID path.
public struct WebDriverAgentClient: Sendable {
    public var baseURL: URL

    public init(host: String, port: UInt16 = 8100) {
        let bracketed = host.contains(":") ? "[\(host)]" : host
        baseURL = URL(string: "http://\(bracketed):\(port)")!
    }

    public struct Status: Sendable {
        public var ready: Bool
        public var osVersion: String?
    }

    public func status(timeout: Double = 3) async throws -> Status {
        let value = try await get("/status", timeout: timeout)
        return Status(ready: value["ready"] as? Bool ?? false, osVersion: (value["os"] as? [String: Any])?["version"] as? String)
    }

    /// Tree of the foreground app (incl. SpringBoard/home screen).
    public func source(timeout: Double = 30) async throws -> UIElement {
        let value = try await get("/source?format=json", timeout: timeout)
        guard let root = UIElement(wdaJSON: value) else { throw URLError(.cannotParseResponse) }
        return root
    }

    private func get(_ path: String, timeout: Double) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["value"] as? [String: Any]
        else { throw URLError(.badServerResponse) }
        return value
    }
}
