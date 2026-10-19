// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo

/// Erkennt den „Resolution Collapse“ des iOS-Encoders: Bei viel Bewegung kodiert iOS den Bildschirm
/// verkleinert in die linke obere Ecke und füllt den Rest mit Grau (RGB 128). Liefert dann die Größe
/// des Inhalts in Pixeln, sonst `nil`. Gleiche Schwellen wie der Web-Viewer von pymobiledevice3:
/// Spalten/Zeilen gelten ab 60 % Grauanteil als Rand, ein Collapse nur zwischen 20 % und 92 % der Größe.
public enum ContentRectDetector {
    public static let grayTolerance = 6
    public static let grayFraction = 0.6

    /// Arbeitet auf einem BGRA-Bild (8 Bit pro Kanal).
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

        // Schneller Ausschluss: Im Normalfall ist der rechte/untere Rand schwarz (Padding) oder Inhalt.
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

    /// Sichtbarer Ausschnitt als `contentsRect` (Einheitskoordinaten, Ursprung oben links):
    /// bei einem Collapse der erkannte Inhalt, sonst das echte Display ohne Padding.
    public static func visibleFraction(codedPixels: CGSize, screenPixels: CGSize, collapsed: CGSize?) -> CGSize {
        guard codedPixels.width > 0, codedPixels.height > 0 else { return CGSize(width: 1, height: 1) }
        let visible = collapsed ?? screenPixels
        return CGSize(
            width: min(visible.width / codedPixels.width, 1),
            height: min(visible.height / codedPixels.height, 1)
        )
    }
}
