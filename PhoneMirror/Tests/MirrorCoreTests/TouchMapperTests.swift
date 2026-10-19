// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import MirrorCore
import Testing

@Suite struct TouchMapperTests {
    let iPhone = DeviceScreen.iPhone15.pointSize // 393 × 852

    @Test func cornersMapToExtremes() {
        let mapper = TouchMapper(contentSize: iPhone, viewBounds: CGRect(origin: .zero, size: iPhone))
        #expect(mapper.devicePoint(for: .zero) == TouchPoint(x: 0, y: 0))
        #expect(mapper.devicePoint(for: CGPoint(x: iPhone.width, y: iPhone.height)) == TouchPoint(x: 65535, y: 65535))
        #expect(mapper.devicePoint(for: CGPoint(x: iPhone.width / 2, y: iPhone.height / 2)) == TouchPoint(x: 32768, y: 32768))
    }

    @Test func letterboxIsIgnored() {
        // Breiteres Fenster: Video wird mittig eingepasst, links und rechts bleibt Rand.
        let mapper = TouchMapper(contentSize: iPhone, viewBounds: CGRect(x: 0, y: 0, width: 1000, height: 852))
        let rect = mapper.videoRect
        #expect(abs(rect.width - 393) < 0.001)
        #expect(abs(rect.minX - 303.5) < 0.001)
        #expect(mapper.devicePoint(for: CGPoint(x: 100, y: 400)) == nil)
        #expect(mapper.devicePoint(for: CGPoint(x: rect.minX, y: 0)) == TouchPoint(x: 0, y: 0))
    }

    @Test func scaledWindowKeepsProportions() {
        let mapper = TouchMapper(contentSize: iPhone, viewBounds: CGRect(x: 0, y: 0, width: 393 * 0.5, height: 852 * 0.5))
        let point = mapper.devicePoint(for: CGPoint(x: 393 * 0.25, y: 852 * 0.125))
        // 106,5 von 426 Punkten Höhe = 25 %.
        #expect(point == TouchPoint(x: 32768, y: 16384))
    }

    @Test func dragsBeyondEdgeAreClamped() {
        let mapper = TouchMapper(contentSize: iPhone, viewBounds: CGRect(origin: .zero, size: iPhone))
        #expect(mapper.clampedDevicePoint(for: CGPoint(x: -50, y: 2000)) == TouchPoint(x: 0, y: 65535))
    }

    @Test(arguments: [CGPoint(x: 10, y: 20), CGPoint(x: 200, y: 600), CGPoint(x: 392, y: 851)])
    func roundTripIsSubPixelAccurate(viewPoint: CGPoint) throws {
        let mapper = TouchMapper(contentSize: iPhone, viewBounds: CGRect(x: 0, y: 28, width: 393, height: 852))
        let shifted = CGPoint(x: viewPoint.x, y: viewPoint.y + 28)
        let device = try #require(mapper.devicePoint(for: shifted))
        let back = mapper.viewPoint(for: device)
        #expect(abs(back.x - shifted.x) < 0.01)
        #expect(abs(back.y - shifted.y) < 0.02)
    }

    @Test func emptyViewDoesNotCrash() {
        let mapper = TouchMapper(contentSize: iPhone, viewBounds: .zero)
        #expect(mapper.devicePoint(for: .zero) == nil)
        #expect(mapper.clampedDevicePoint(for: CGPoint(x: 5, y: 5)) == TouchPoint(x: 0, y: 0))
    }
}

@Suite struct VideoLayoutTests {
    @Test func paddedStreamIsCroppedToDisplay() {
        // Gemessen: iPhone 15 unter iOS 27 sendet 1184 × 2576 für ein 1179 × 2556-Display.
        let frame = VideoLayout.videoLayerFrame(
            displaySize: CGSize(width: 393, height: 852),
            screenPixels: CGSize(width: 1179, height: 2556),
            codedPixels: CGSize(width: 1184, height: 2576)
        )
        #expect(frame.origin == .zero)
        #expect(abs(frame.width - 1184.0 / 3) < 0.001)
        #expect(abs(frame.height - 2576.0 / 3) < 0.001)
    }

    @Test func unknownCodedSizeFillsDisplay() {
        let size = CGSize(width: 300, height: 650)
        #expect(VideoLayout.videoLayerFrame(displaySize: size, screenPixels: CGSize(width: 1179, height: 2556), codedPixels: nil) == CGRect(origin: .zero, size: size))
    }
}

@Suite struct KeyMappingTests {
    @Test func lettersDigitsAndControls() {
        #expect(KeyMapping.hidUsage(forMacKeyCode: 0x00) == 0x04) // A
        #expect(KeyMapping.hidUsage(forMacKeyCode: 0x06) == 0x1D) // Z (ANSI)
        #expect(KeyMapping.hidUsage(forMacKeyCode: 0x1D) == 0x27) // 0
        #expect(KeyMapping.hidUsage(forMacKeyCode: 0x24) == 0x28) // Return
        #expect(KeyMapping.hidUsage(forMacKeyCode: 0x7E) == 0x52) // Pfeil hoch
        #expect(KeyMapping.hidUsage(forMacKeyCode: 0x37) == 0xE3) // Command links
        #expect(KeyMapping.hidUsage(forMacKeyCode: 0x7A) == nil)  // F1 nicht belegt
    }

    @Test func modifiersAreRecognized() {
        #expect(KeyMapping.isModifier(0x38))
        #expect(!KeyMapping.isModifier(0x00))
    }
}
