// SPDX-License-Identifier: GPL-3.0-or-later
/// iOS only recognizes edge gestures at the top (Notifications, Control Center) and left (Back) when the finger
/// touches down at the edge. With the mouse you hardly ever hit the edge, so a touch that starts near one of these
/// edges is moved onto the edge. Only the start point is moved; the movement follows the mouse.
///
/// The bottom edge is deliberately excluded: on iPhone 15 / iOS 27, iOS discards injected touches
/// that start at the home bar (tested). `HomeIndicatorGestureRecognizer` handles that.
public struct EdgeSnapping: Sendable, Equatable {
    /// Snap zone in device points (iPhone 15: 393 × 852 pt).
    public var topZone: Double
    public var leftZone: Double

    public init(topZone: Double = 12, leftZone: Double = 8) {
        self.topZone = topZone
        self.leftZone = leftZone
    }

    public func snap(_ point: TouchPoint, on screen: DeviceScreen) -> TouchPoint {
        let max = Double(TouchPoint.maxValue)
        let size = screen.pointSize
        var snapped = point
        if Double(point.y) / max * size.height <= topZone {
            snapped.y = 0
        }
        if Double(point.x) / max * size.width <= leftZone {
            snapped.x = 0
        }
        return snapped
    }
}

/// Recognizes the mouse's home bar gesture (click at the bottom edge and drag up) and translates it
/// into what iOS accepts via HID: short swipe = Home, swipe with a pause = App Switcher.
/// While the gesture is in progress, no touches go to the device.
public struct HomeIndicatorGestureRecognizer: Sendable {
    public enum Result: Sendable, Equatable {
        case home, appSwitcher
    }

    /// Start zone above the bottom edge in device points.
    public var zone: Double = 28
    /// Minimum upward travel to count as a swipe (points).
    public var minimumTravel: Double = 40
    /// Hold still this long before releasing → App Switcher (as on the iPhone).
    public var pauseForSwitcher: Double = 0.3
    /// Movement below this threshold (points) counts as pausing.
    public var stillThreshold: Double = 3

    private var screen: DeviceScreen
    private var startY: Double?
    private var lastY: Double = 0
    private var lastMovementTime: Double = 0

    public init(screen: DeviceScreen) {
        self.screen = screen
    }

    public var isActive: Bool { startY != nil }

    /// Returns `true` if the touch starts at the home bar and is taken over by the gesture.
    public mutating func began(at point: TouchPoint, time: Double) -> Bool {
        let y = points(point.y)
        guard screen.pointSize.height - y <= zone else { return false }
        startY = y
        lastY = y
        lastMovementTime = time
        return true
    }

    public mutating func moved(to point: TouchPoint, time: Double) {
        guard isActive else { return }
        let y = points(point.y)
        if abs(y - lastY) > stillThreshold {
            lastMovementTime = time
            lastY = y
        }
    }

    public mutating func ended(at point: TouchPoint, time: Double) -> Result? {
        guard let start = startY else { return nil }
        moved(to: point, time: time)
        startY = nil
        guard start - points(point.y) >= minimumTravel else { return nil }
        return time - lastMovementTime >= pauseForSwitcher ? .appSwitcher : .home
    }

    private func points(_ value: UInt16) -> Double {
        Double(value) / Double(TouchPoint.maxValue) * screen.pointSize.height
    }
}

public enum ButtonAction: String, Sendable {
    case down, up
}

/// One step of a predefined gesture.
public enum GestureStep: Sendable, Equatable {
    case wait(Double)
    case touch(TouchPhase, TouchPoint)
    case button(HardwareButton, ButtonAction)
}

/// Synthetic system gestures for menu commands and the home bar (like ⌘2 in Apple's iPhone Mirroring).
public enum SystemGesture: String, Sendable, CaseIterable {
    /// Press Home twice quickly – opens the App Switcher on the iPhone (tested, iOS 27).
    case appSwitcher

    public var steps: [GestureStep] {
        switch self {
        case .appSwitcher:
            [.button(.home, .down), .wait(0.05), .button(.home, .up), .wait(0.08),
             .button(.home, .down), .wait(0.05), .button(.home, .up)]
        }
    }
}
