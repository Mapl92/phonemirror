// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// iOS encodes the display rounded up to multiples of 16 (iPhone 15: 1179 × 2556 → 1184 × 2576)
/// and pads on the right/bottom. So that only the real display area is visible, the video layer
/// is drawn larger than the display area and clipped by the container.
public enum VideoLayout {
    /// Frame of the (larger) video layer relative to the container, which shows exactly `displaySize`.
    /// - Parameters:
    ///   - displaySize: size of the display area in the window (points).
    ///   - screenPixels: real display size of the device in pixels.
    ///   - codedPixels: picture size according to the SPS; `nil` as long as no picture has arrived.
    public static func videoLayerFrame(displaySize: CGSize, screenPixels: CGSize, codedPixels: CGSize?) -> CGRect {
        guard let codedPixels, screenPixels.width > 0, screenPixels.height > 0 else {
            return CGRect(origin: .zero, size: displaySize)
        }
        let scaleX = displaySize.width / screenPixels.width
        let scaleY = displaySize.height / screenPixels.height
        return CGRect(x: 0, y: 0, width: codedPixels.width * scaleX, height: codedPixels.height * scaleY)
    }
}
