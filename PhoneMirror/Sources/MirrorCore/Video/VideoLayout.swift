// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// iOS kodiert das Display auf Vielfache von 16 aufgerundet (iPhone 15: 1179 × 2556 → 1184 × 2576)
/// und füllt rechts/unten auf. Damit nur der echte Displaybereich sichtbar ist, wird der Videolayer
/// größer als die Anzeigefläche gezeichnet und vom Container abgeschnitten.
public enum VideoLayout {
    /// Rahmen des (größeren) Videolayers relativ zum Container, der genau `displaySize` zeigt.
    /// - Parameters:
    ///   - displaySize: Größe der Anzeigefläche im Fenster (Punkte).
    ///   - screenPixels: echte Displaygröße des Geräts in Pixeln.
    ///   - codedPixels: Bildgröße laut SPS; `nil`, solange noch kein Bild da ist.
    public static func videoLayerFrame(displaySize: CGSize, screenPixels: CGSize, codedPixels: CGSize?) -> CGRect {
        guard let codedPixels, screenPixels.width > 0, screenPixels.height > 0 else {
            return CGRect(origin: .zero, size: displaySize)
        }
        let scaleX = displaySize.width / screenPixels.width
        let scaleY = displaySize.height / screenPixels.height
        return CGRect(x: 0, y: 0, width: codedPixels.width * scaleX, height: codedPixels.height * scaleY)
    }
}
