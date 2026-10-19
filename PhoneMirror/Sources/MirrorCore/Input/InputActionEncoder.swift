// SPDX-License-Identifier: GPL-3.0-or-later
/// Was beim Gerät ankommen soll – unabhängig davon, ob serve-web oder der native Transport es überträgt.
public enum DeviceAction: Sendable, Equatable {
    /// Touchscreen-Sample: `contact` = Finger liegt auf, sonst loslassen.
    case touch(contact: Bool, TouchPoint)
    /// Vollständige Menge gedrückter HID-Keyboard-Usages.
    case keys([UInt16])
    /// Hardwaretaste; `nil` = drücken und passend lange halten.
    case button(HardwareButton, ButtonAction?)
}

/// Übersetzt `InputEvent`s in `DeviceAction`s und hält den nötigen Zustand:
/// die Menge gedrückter Tasten und eine laufende, als Wischgeste nachgebildete Scroll-Bewegung.
public struct InputActionEncoder: Sendable {
    public var screen: DeviceScreen
    public private(set) var heldKeys: [UInt16] = []
    /// Fingerposition einer Scroll-Geste, ungerundet – sonst summieren sich Rundungsfehler.
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
            // Nur beim Drücken senden – Halten übernimmt der Transport.
            return isDown ? [.button(button, nil)] : []

        case .gesture:
            // Braucht Timing zwischen den Schritten – spielt die Session über `steps` ab.
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

    /// Beendet eine laufende Scroll-Geste (Finger heben).
    public mutating func endScroll() -> [DeviceAction] {
        guard let position = scrollPosition else { return [] }
        scrollX = nil
        scrollY = nil
        return [.touch(contact: false, position)]
    }
}
