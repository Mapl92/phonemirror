// SPDX-License-Identifier: GPL-3.0-or-later
/// Normalisierte Touch-Koordinate wie beim Universal-HID-Dienst:
/// (0, 0) oben links, (65535, 65535) unten rechts, unabhängig von der Auflösung.
public struct TouchPoint: Sendable, Equatable, CustomStringConvertible {
    public static let maxValue = UInt16.max

    public var x: UInt16
    public var y: UInt16

    public init(x: UInt16, y: UInt16) {
        self.x = x
        self.y = y
    }

    public var description: String { "(\(x), \(y))" }
}

public enum TouchPhase: Sendable, Equatable {
    case began, moved, ended
}

public enum HardwareButton: String, Sendable, CaseIterable {
    case home, lock, volumeUp, volumeDown, siri
}

public enum InputEvent: Sendable, Equatable {
    case touch(TouchPhase, TouchPoint)
    /// Scrollen als Fingerbewegung in Punkten (positiv = Finger nach rechts/unten, wie beim natürlichen Scrollen),
    /// beginnend an der Zeigerposition. Wird auf dem iPhone als Wischgeste nachgebildet.
    case scroll(dx: Double, dy: Double, at: TouchPoint)
    /// Trackpad-Geste beendet (Finger gehoben) – die nachgebildete Wischgeste loslassen.
    case scrollEnded
    /// HID-Usage aus der Keyboard-Page (0x07).
    case key(usage: UInt16, isDown: Bool)
    case button(HardwareButton, isDown: Bool)
    /// Vorgefertigte Geste (z. B. App-Umschalter); der Transport spielt sie mit passendem Timing ab.
    case gesture(SystemGesture)
}
