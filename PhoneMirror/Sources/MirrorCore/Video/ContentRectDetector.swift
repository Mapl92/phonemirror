// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo

/// Detects the iOS encoder's “resolution collapse”: with a lot of motion, iOS encodes the screen
/// scaled down into the top left corner and fills the rest with gray (RGB 128). Then returns the size
/// of the content in pixels, otherwise `nil`. Same thresholds as pymobiledevice3's web viewer:
/// columns/rows count as margin from 60 % gray, a collapse only between 20 % and 92 % of the size.
public enum ContentRectDetector {
    public static let grayTolerance = 6
    public static let grayFraction = 0.6

    /// Works on a BGRA image (8 bits per channel).
    public static func collapsedContentSize(
        bytes: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int
    ) -> CGSize? {
        guard width >= 16, height >= 16 else { return nil }
        let pixels = bytes.assumingMemoryBound(to: UInt8.self)
        func isGray(_ x: Int, _ y: Int) -> Bool {
            let p = pixels + y * bytesPerRow + x * 4
            return abs(Int(p[0]) - 128) < grayTolerance && abs(Int(p[1]) - 128) < grayTolerance && abs(Int(p[2]) - 128) < grayTolerance
        }
        let rowStep = max(1, height / 96)
        let columnStep = max(1, width / 96)
        func columnIsPadding(_ x: Int) -> Bool {
            var gray = 0, total = 0
            for y in stride(from: 0, to: height, by: rowStep) {
                total += 1
                if isGray(x, y) { gray += 1 }
            }
            return Double(gray) / Double(total) >= grayFraction
        }
        func rowIsPadding(_ y: Int) -> Bool {
            var gray = 0, total = 0
            for x in stride(from: 0, to: width, by: columnStep) {
                total += 1
                if isGray(x, y) { gray += 1 }
            }
            return Double(gray) / Double(total) >= grayFraction
        }

        // Quick rejection: normally the right/bottom margin is black (padding) or content.
        guard columnIsPadding(width - 2), rowIsPadding(height - 2) else { return nil }

        let scan = max(1, width / 512)
        var right = width - 1
        while right > 0, columnIsPadding(right) { right -= scan }
        var bottom = height - 1
        while bottom > 0, rowIsPadding(bottom) { bottom -= max(1, height / 512) }

        let contentWidth = Double(right + 1), contentHeight = Double(bottom + 1)
        guard contentWidth > Double(width) * 0.2, contentWidth < Double(width) * 0.92,
              contentHeight > Double(height) * 0.2, contentHeight < Double(height) * 0.92
        else { return nil }
        return CGSize(width: contentWidth, height: contentHeight)
    }

    public static func collapsedContentSize(in pixelBuffer: CVPixelBuffer) -> CGSize? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        return collapsedContentSize(
            bytes: base,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
    }

    /// Visible region as `contentsRect` (unit coordinates, origin top left):
    /// on a collapse the detected content, otherwise the real display without padding.
    public static func visibleFraction(codedPixels: CGSize, screenPixels: CGSize, collapsed: CGSize?) -> CGSize {
        guard codedPixels.width > 0, codedPixels.height > 0 else { return CGSize(width: 1, height: 1) }
        let visible = collapsed ?? screenPixels
        return CGSize(
            width: min(visible.width / codedPixels.width, 1),
            height: min(visible.height / codedPixels.height, 1)
        )
    }
}
