// SPDX-License-Identifier: GPL-3.0-or-later
/// Normalized touch coordinate as used by the Universal HID service:
/// (0, 0) top left, (65535, 65535) bottom right, independent of the resolution.
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
    /// Scrolling as finger movement in points (positive = finger to the right/down, as with natural scrolling),
    /// starting at the pointer position. Emulated on the iPhone as a swipe gesture.
    case scroll(dx: Double, dy: Double, at: TouchPoint)
    /// Trackpad gesture ended (finger lifted) – release the emulated swipe gesture.
    case scrollEnded
    /// HID usage from the keyboard page (0x07).
    case key(usage: UInt16, isDown: Bool)
    case button(HardwareButton, isDown: Bool)
    /// Predefined gesture (e.g. App Switcher); the transport plays it back with appropriate timing.
    case gesture(SystemGesture)
}
