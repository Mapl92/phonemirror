// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// Rechnet Positionen im Mac-Fenster in normalisierte Gerätekoordinaten um und zurück.
/// Das Video wird seitenverhältnistreu eingepasst (wie `AVLayerVideoGravity.resizeAspect`),
/// Koordinaten der View haben den Ursprung oben links (geflippte NSView).
public struct TouchMapper: Sendable, Equatable {
    public var contentSize: CGSize
    public var viewBounds: CGRect

    public init(contentSize: CGSize, viewBounds: CGRect) {
        self.contentSize = contentSize
        self.viewBounds = viewBounds
    }

    /// Fläche innerhalb der View, die das Video tatsächlich belegt.
    public var videoRect: CGRect {
        guard contentSize.width > 0, contentSize.height > 0, viewBounds.width > 0, viewBounds.height > 0 else {
            return .zero
        }
        let scale = min(viewBounds.width / contentSize.width, viewBounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: viewBounds.minX + (viewBounds.width - size.width) / 2,
            y: viewBounds.minY + (viewBounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Liefert `nil`, wenn der Punkt außerhalb des Videos liegt (z. B. Letterbox-Rand).
    public func devicePoint(for viewPoint: CGPoint) -> TouchPoint? {
        let rect = videoRect
        // Inklusiv prüfen: Der Mauszeiger kann genau auf der rechten/unteren Kante liegen.
        guard !rect.isEmpty,
              (rect.minX...rect.maxX).contains(viewPoint.x),
              (rect.minY...rect.maxY).contains(viewPoint.y)
        else { return nil }
        return clampedDevicePoint(for: viewPoint)
    }

    /// Wie `devicePoint(for:)`, klemmt aber auf den Videobereich – für laufende Gesten,
    /// die über den Rand hinausgezogen werden.
    public func clampedDevicePoint(for viewPoint: CGPoint) -> TouchPoint {
        let rect = videoRect
        guard !rect.isEmpty else { return TouchPoint(x: 0, y: 0) }
        return TouchPoint(
            x: Self.normalize(viewPoint.x - rect.minX, over: rect.width),
            y: Self.normalize(viewPoint.y - rect.minY, over: rect.height)
        )
    }

    /// Umkehrung: normalisierte Gerätekoordinate → Punkt in der View.
    public func viewPoint(for devicePoint: TouchPoint) -> CGPoint {
        let rect = videoRect
        let max = Double(TouchPoint.maxValue)
        return CGPoint(
            x: rect.minX + Double(devicePoint.x) / max * rect.width,
            y: rect.minY + Double(devicePoint.y) / max * rect.height
        )
    }

    private static func normalize(_ offset: CGFloat, over length: CGFloat) -> UInt16 {
        let fraction = min(max(offset / length, 0), 1)
        return UInt16((fraction * Double(TouchPoint.maxValue)).rounded())
    }
}
