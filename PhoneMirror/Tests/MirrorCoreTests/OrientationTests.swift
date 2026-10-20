// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import MirrorCore
@testable import MirrorNative
import Testing

@Suite struct OrientationTests {
    @Test func nativeAndDisplayedAreInverse() {
        let points = [TouchPoint(x: 0, y: 0), TouchPoint(x: 1000, y: 60000), TouchPoint(x: 65535, y: 12345)]
        for orientation in DeviceOrientation.allCases {
            for point in points {
                #expect(orientation.displayed(orientation.native(point)) == point)
            }
        }
    }

    /// Landscape (rot90): the upright image's top-left corner is the native framebuffer's bottom-left.
    @Test func quarterTurnMapsCorners() {
        let orientation = DeviceOrientation.landscapeLeft
        #expect(orientation.native(TouchPoint(x: 0, y: 0)) == TouchPoint(x: 0, y: 65535))
        #expect(orientation.native(TouchPoint(x: 65535, y: 0)) == TouchPoint(x: 0, y: 0))
        #expect(DeviceOrientation.landscapeRight.native(TouchPoint(x: 0, y: 0)) == TouchPoint(x: 65535, y: 0))
        let move = orientation.native(dx: 10, dy: 0)
        #expect(move.dx == 0 && move.dy == -10)
    }

    @Test func displayedScreenSwapsInLandscape() {
        let screen = DeviceScreen.iPhone15
        #expect(DeviceOrientation.portrait.displayed(screen) == screen)
        let landscape = DeviceOrientation.landscapeRight.displayed(screen)
        #expect(landscape.pixelWidth == 2556 && landscape.pixelHeight == 1179)
    }

    @Test func parsesDisplayInfo() throws {
        let info: XPCValue = [
            "displays": .array([
                ["primary": false, "currentMode": ["size": .array([.double(0), .double(0)])], "currentOrientation": "rot0"],
                [
                    "primary": true, "pointScale": .int64(3), "currentOrientation": "rot270",
                    "currentMode": ["preferredUIScale": .int64(3), "size": .array([.double(1290), .double(2796)])],
                ],
            ]),
        ]
        let screen = try #require(DeviceScreen(displayInfo: info))
        #expect(screen.pixelWidth == 1290 && screen.pixelHeight == 2796 && screen.scale == 3)
        #expect(screen.cornerRadius == 60)
        #expect(DeviceOrientation(displayInfo: info) == .landscapeRight)
    }

    @Test func cornerRadiusEstimate() {
        #expect(DeviceScreen.estimatedCornerRadius(pixelWidth: 1179, pixelHeight: 2556, scale: 3) == 55)
        #expect(DeviceScreen.estimatedCornerRadius(pixelWidth: 750, pixelHeight: 1334, scale: 2) == 0) // iPhone SE
    }
}
