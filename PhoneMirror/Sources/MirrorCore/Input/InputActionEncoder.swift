// SPDX-License-Identifier: GPL-3.0-or-later
/// What should arrive at the device – regardless of whether serve-web or the native transport delivers it.
public enum DeviceAction: Sendable, Equatable {
    /// Touchscreen sample: `contact` = finger is down, otherwise release.
    case touch(contact: Bool, TouchPoint)
    /// Complete set of pressed HID keyboard usages.
    case keys([UInt16])
    /// Hardware button; `nil` = press and hold for the appropriate time.
    case button(HardwareButton, ButtonAction?)
}

/// Translates `InputEvent`s into `DeviceAction`s and keeps the necessary state:
/// the set of pressed keys and an ongoing scroll movement emulated as a swipe gesture.
public struct InputActionEncoder: Sendable {
    public var screen: DeviceScreen
    public private(set) var heldKeys: [UInt16] = []
    /// Finger position of a scroll gesture, unrounded – otherwise rounding errors add up.
    private var scrollX: Double?
    private var scrollY: Double?

    public init(screen: DeviceScreen) {
        self.screen = screen
    }

    public var scrollPosition: TouchPoint? {
        guard let scrollX, let scrollY else { return nil }
        return TouchPoint(x: UInt16(scrollX.rounded()), y: UInt16(scrollY.rounded()))
    }

    public mutating func actions(for event: InputEvent) -> [DeviceAction] {
        switch event {
        case .touch(let phase, let point):
            return endScroll() + [.touch(contact: phase != .ended, point)]

        case .scroll(let dx, let dy, let start):
            var actions: [DeviceAction] = []
            if scrollX == nil || scrollY == nil {
                scrollX = Double(start.x)
                scrollY = Double(start.y)
                actions.append(.touch(contact: true, start))
            }
            let max = Double(TouchPoint.maxValue)
            scrollX = Swift.min(Swift.max(scrollX! + dx / screen.pointSize.width * max, 0), max)
            scrollY = Swift.min(Swift.max(scrollY! + dy / screen.pointSize.height * max, 0), max)
            actions.append(.touch(contact: true, scrollPosition!))
            return actions

        case .scrollEnded:
            return endScroll()

        case .key(let usage, let isDown):
            if isDown {
                guard !heldKeys.contains(usage) else { return [] }
                heldKeys.append(usage)
            } else {
                guard heldKeys.contains(usage) else { return [] }
                heldKeys.removeAll { $0 == usage }
            }
            return [.keys(heldKeys)]

        case .button(let button, let isDown):
            // Only send on press – the transport handles holding.
            return isDown ? [.button(button, nil)] : []

        case .gesture:
            // Needs timing between the steps – the session plays it back via `steps`.
            return endScroll()
        }
    }

    public mutating func actions(forStep step: GestureStep) -> [DeviceAction] {
        switch step {
        case .wait: []
        case .touch(let phase, let point): actions(for: .touch(phase, point))
        case .button(let button, let action): [.button(button, action)]
        }
    }

    /// Ends an ongoing scroll gesture (lifts the finger).
    public mutating func endScroll() -> [DeviceAction] {
        guard let position = scrollPosition else { return [] }
        scrollX = nil
        scrollY = nil
        return [.touch(contact: false, position)]
    }
}
