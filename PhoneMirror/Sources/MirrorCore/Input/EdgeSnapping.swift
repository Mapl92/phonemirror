// SPDX-License-Identifier: GPL-3.0-or-later
/// iOS erkennt Randgesten oben (Mitteilungen, Kontrollzentrum) und links (Zurück) nur, wenn der Finger
/// am Rand aufsetzt. Mit der Maus trifft man die Kante kaum, deshalb wird ein Touch, der nahe einer dieser
/// Kanten beginnt, auf die Kante gesetzt. Nur der Startpunkt wird verschoben, die Bewegung folgt der Maus.
///
/// Die Unterkante ist bewusst ausgenommen: Am iPhone 15 / iOS 27 verwirft iOS injizierte Touches,
/// die am Home-Balken beginnen (getestet). Das übernimmt `HomeIndicatorGestureRecognizer`.
public struct EdgeSnapping: Sendable, Equatable {
    /// Fangbereich in Punkten des Geräts (iPhone 15: 393 × 852 pt).
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

/// Erkennt die Home-Balken-Geste der Maus (am unteren Rand klicken und nach oben ziehen) und übersetzt sie
/// in das, was iOS per HID annimmt: kurzes Wischen = Home, Wischen mit Innehalten = App-Umschalter.
/// Solange die Geste läuft, gehen keine Touches ans Gerät.
public struct HomeIndicatorGestureRecognizer: Sendable {
    public enum Result: Sendable, Equatable {
        case home, appSwitcher
    }

    /// Startbereich über der Unterkante in Gerätepunkten.
    public var zone: Double = 28
    /// Mindestweg nach oben, damit es als Wischen zählt (Punkte).
    public var minimumTravel: Double = 40
    /// So lange ruhig halten vor dem Loslassen → App-Umschalter (wie am iPhone).
    public var pauseForSwitcher: Double = 0.3
    /// Bewegung unter dieser Schwelle (Punkte) gilt als Innehalten.
    public var stillThreshold: Double = 3

    private var screen: DeviceScreen
    private var startY: Double?
    private var lastY: Double = 0
    private var lastMovementTime: Double = 0

    public init(screen: DeviceScreen) {
        self.screen = screen
    }

    public var isActive: Bool { startY != nil }

    /// Gibt `true` zurück, wenn der Touch am Home-Balken beginnt und von der Geste übernommen wird.
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

/// Ein Schritt einer vorgefertigten Geste.
public enum GestureStep: Sendable, Equatable {
    case wait(Double)
    case touch(TouchPhase, TouchPoint)
    case button(HardwareButton, ButtonAction)
}

/// Synthetische Systemgesten für Menübefehle und den Home-Balken (wie ⌘2 bei Apples iPhone-Mirroring).
public enum SystemGesture: String, Sendable, CaseIterable {
    /// Home zweimal schnell drücken – öffnet am iPhone den App-Umschalter (getestet, iOS 27).
    case appSwitcher

    public var steps: [GestureStep] {
        switch self {
        case .appSwitcher:
            [.button(.home, .down), .wait(0.05), .button(.home, .up), .wait(0.08),
             .button(.home, .down), .wait(0.05), .button(.home, .up)]
        }
    }
}
