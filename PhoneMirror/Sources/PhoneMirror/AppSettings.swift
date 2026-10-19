// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// Persistente Einstellungen (UserDefaults).
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

    var clipboardSync: Bool {
        get { defaults.bool(forKey: Key.clipboardSync) }
        set { defaults.set(newValue, forKey: Key.clipboardSync) }
    }

    /// Fenstergröße relativ zur Punktgröße des iPhones (1 = 393 × 852 pt).
    var zoom: Double {
        get { defaults.double(forKey: Key.zoom) }
        set { defaults.set(min(max(newValue, 0.4), 2), forKey: Key.zoom) }
    }

    /// Verbindungsart zum iPhone.
    var connection: ConnectionKind {
        get { ConnectionKind(rawValue: defaults.string(forKey: Key.connection) ?? "") ?? .native }
        set { defaults.set(newValue.rawValue, forKey: Key.connection) }
    }

    /// MCP-Server für Agents (nur 127.0.0.1).
    var mcpEnabled: Bool {
        get { defaults.bool(forKey: Key.mcpEnabled) }
        set { defaults.set(newValue, forKey: Key.mcpEnabled) }
    }

    var mcpPort: UInt16 {
        UInt16(clamping: defaults.integer(forKey: Key.mcpPort))
    }

    /// Zufälliges Token, einmal erzeugt und dann beibehalten (sonst müsste der Agent neu eingerichtet werden).
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
    }
}

enum ConnectionKind: String, CaseIterable {
    /// Eigener Swift-Transport über den CoreDevice-Tunnel.
    case native
    /// pymobiledevice3 `serve-web` als lokale Brücke.
    case serveWeb

    var title: String {
        switch self {
        case .native: "Nativ (ohne Python)"
        case .serveWeb: "pymobiledevice3 (serve-web)"
        }
    }
}
