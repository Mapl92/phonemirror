// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// Orientation of the iPhone's interface (named like `UIInterfaceOrientation`; the device itself reports the
/// opposite landscape name). The video always arrives in the display's native portrait orientation; in landscape the
/// content inside it is rotated, so the view turns it upright and maps input back.
public enum DeviceOrientation: String, Sendable, CaseIterable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    public init(deviceInfo name: String) {
        self = DeviceOrientation(rawValue: name) ?? .portrait
    }

    public var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }

    /// Clockwise quarter turns that make the native framebuffer upright for the viewer.
    public var quarterTurns: Int {
        switch self {
        case .portrait: 0
        case .landscapeLeft: 1
        case .portraitUpsideDown: 2
        case .landscapeRight: 3
        }
    }

    /// The screen as the viewer sees it (width and height swapped in landscape).
    public func displayed(_ screen: DeviceScreen) -> DeviceScreen {
        guard isLandscape else { return screen }
        return DeviceScreen(pixelWidth: screen.pixelHeight, pixelHeight: screen.pixelWidth, scale: screen.scale, cornerRadius: screen.cornerRadius)
    }

    /// Point in the upright (displayed) image → point in the native framebuffer.
    public func native(_ point: TouchPoint) -> TouchPoint {
        let max = TouchPoint.maxValue
        switch quarterTurns {
        case 1: return TouchPoint(x: point.y, y: max - point.x)
        case 2: return TouchPoint(x: max - point.x, y: max - point.y)
        case 3: return TouchPoint(x: max - point.y, y: point.x)
        default: return point
        }
    }

    /// Native framebuffer → upright image (inverse of `native`).
    public func displayed(_ point: TouchPoint) -> TouchPoint {
        let max = TouchPoint.maxValue
        switch quarterTurns {
        case 1: return TouchPoint(x: max - point.y, y: point.x)
        case 2: return TouchPoint(x: max - point.x, y: max - point.y)
        case 3: return TouchPoint(x: point.y, y: max - point.x)
        default: return point
        }
    }

    /// A movement in the upright image → the same movement in native coordinates.
    public func native(dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        switch quarterTurns {
        case 1: (dy, -dx)
        case 2: (-dx, -dy)
        case 3: (-dy, dx)
        default: (dx, dy)
        }
    }
}
