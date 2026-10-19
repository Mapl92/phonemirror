// SPDX-License-Identifier: GPL-3.0-or-later
import MirrorCore
import Testing

/// Punkt in Gerätepunkten (iPhone 15: 393 × 852 pt) → normalisierte Koordinate.
private func point(x: Double, y: Double) -> TouchPoint {
    TouchPoint(x: UInt16((x / 393 * 65535).rounded()), y: UInt16((y / 852 * 65535).rounded()))
}

@Suite struct EdgeSnappingTests {
    let snapping = EdgeSnapping()
    let screen = DeviceScreen.iPhone15

    @Test func touchNearTopAndLeftEdges() {
        #expect(snapping.snap(point(x: 350, y: 5), on: screen).y == 0)
        #expect(snapping.snap(point(x: 3, y: 400), on: screen).x == 0)
    }

    @Test func bottomAndRightEdgesAreNotSnapped() {
        // Unten übernimmt der Home-Balken-Erkenner; rechts gibt es keine Systemgeste.
        let bottom = point(x: 196, y: 845)
        #expect(snapping.snap(bottom, on: screen) == bottom)
        let right = point(x: 390, y: 400)
        #expect(snapping.snap(right, on: screen) == right)
    }

    @Test func touchesAwayFromEdgesAreUnchanged() {
        let middle = point(x: 196, y: 700)
        #expect(snapping.snap(middle, on: screen) == middle)
    }
}

@Suite struct HomeIndicatorGestureTests {
    var recognizer = HomeIndicatorGestureRecognizer(screen: .iPhone15)

    @Test mutating func ignoresTouchesAboveTheZone() {
        let captured = recognizer.began(at: point(x: 196, y: 800), time: 0)
        #expect(!captured)
        #expect(!recognizer.isActive)
    }

    @Test mutating func quickSwipeUpIsHome() {
        let began = recognizer.began(at: point(x: 196, y: 845), time: 0)
        #expect(began)
        recognizer.moved(to: point(x: 196, y: 760), time: 0.08)
        recognizer.moved(to: point(x: 196, y: 600), time: 0.16)
        let result = recognizer.ended(at: point(x: 196, y: 590), time: 0.18)
        #expect(result == .home)
        #expect(!recognizer.isActive)
    }

    @Test mutating func swipeAndPauseIsAppSwitcher() {
        let began = recognizer.began(at: point(x: 196, y: 848), time: 10)
        #expect(began)
        recognizer.moved(to: point(x: 196, y: 700), time: 10.15)
        recognizer.moved(to: point(x: 197, y: 520), time: 10.30)
        recognizer.moved(to: point(x: 198, y: 519), time: 10.55) // zittert nur – zählt als Halten
        let result = recognizer.ended(at: point(x: 198, y: 519), time: 10.70)
        #expect(result == .appSwitcher)
    }

    @Test mutating func tooShortIsIgnored() {
        let began = recognizer.began(at: point(x: 196, y: 845), time: 0)
        #expect(began)
        let result = recognizer.ended(at: point(x: 196, y: 820), time: 0.1)
        #expect(result == nil)
    }

    @Test func appSwitcherIsDoubleHome() {
        let buttons = SystemGesture.appSwitcher.steps.compactMap { step -> ButtonAction? in
            if case .button(.home, let action) = step { return action }
            return nil
        }
        #expect(buttons == [.down, .up, .down, .up])
    }

    @Test func gestureStepsEncodeExplicitButtonStates() {
        var encoder = ServeWebInputEncoder(screen: .iPhone15)
        let requests = SystemGesture.appSwitcher.steps.flatMap { encoder.requests(forStep: $0) }
        #expect(requests.map { $0.json["state"] } == [.string("down"), .string("up"), .string("down"), .string("up")])
        #expect(requests.allSatisfy { $0.path == "/button" && $0.json["name"] == .string("home") })
    }

    @Test func gestureEndsRunningScroll() {
        var encoder = ServeWebInputEncoder(screen: .iPhone15)
        _ = encoder.requests(for: .scroll(dx: 0, dy: 10, at: TouchPoint(x: 100, y: 100)))
        #expect(encoder.requests(for: .gesture(.appSwitcher)).first?.json["type"] == .string("release"))
        #expect(encoder.scrollPosition == nil)
    }
}
