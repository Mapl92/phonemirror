// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// Persistent settings (UserDefaults).
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.soundEnabled: true,
            Key.clipboardSync: true,
            Key.zoom: 0.85,
            Key.connection: ConnectionKind.native.rawValue,
            Key.mcpEnabled: true,
            Key.mcpPort: 8765,
        ])
    }

    var soundEnabled: Bool {
        get { defaults.bool(forKey: Key.soundEnabled) }
        set { defaults.set(newValue, forKey: Key.soundEnabled) }
    }

    var keepOnTop: Bool {
        get { defaults.bool(forKey: Key.keepOnTop) }
        set { defaults.set(newValue, forKey: Key.keepOnTop) }
    }

    var clipboardSync: Bool {
        get { defaults.bool(forKey: Key.clipboardSync) }
        set { defaults.set(newValue, forKey: Key.clipboardSync) }
    }

    /// Window size relative to the iPhone's point size (1 = 393 × 852 pt).
    var zoom: Double {
        get { defaults.double(forKey: Key.zoom) }
        set { defaults.set(min(max(newValue, 0.4), 2), forKey: Key.zoom) }
    }

    /// Connection type to the iPhone.
    var connection: ConnectionKind {
        get { ConnectionKind(rawValue: defaults.string(forKey: Key.connection) ?? "") ?? .native }
        set { defaults.set(newValue.rawValue, forKey: Key.connection) }
    }

    /// MCP server for agents (127.0.0.1 only).
    var mcpEnabled: Bool {
        get { defaults.bool(forKey: Key.mcpEnabled) }
        set { defaults.set(newValue, forKey: Key.mcpEnabled) }
    }

    var mcpPort: UInt16 {
        UInt16(clamping: defaults.integer(forKey: Key.mcpPort))
    }

    /// Random token, generated once and then kept (otherwise the agent would have to be set up again).
    var mcpToken: String {
        if let token = defaults.string(forKey: Key.mcpToken), token.count >= 32 { return token }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(token, forKey: Key.mcpToken)
        return token
    }

    private enum Key {
        static let mcpEnabled = "mcpEnabled"
        static let mcpPort = "mcpPort"
        static let mcpToken = "mcpToken"
        static let connection = "connection"
        static let soundEnabled = "soundEnabled"
        static let clipboardSync = "clipboardSync"
        static let zoom = "zoom"
        static let keepOnTop = "keepOnTop"
    }
}

enum ConnectionKind: String, CaseIterable {
    /// Own Swift transport over the CoreDevice tunnel.
    case native
    /// pymobiledevice3 `serve-web` as a local bridge.
    case serveWeb

    var title: String {
        switch self {
        case .native: "Native (no Python)"
        case .serveWeb: "pymobiledevice3 (serve-web)"
        }
    }
}
