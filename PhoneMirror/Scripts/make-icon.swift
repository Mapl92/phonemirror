// SPDX-License-Identifier: GPL-3.0-or-later
// Zeichnet das App-Icon (iPhone-Silhouette auf Verlauf) und schreibt ein .iconset.
// Aufruf: swift Scripts/make-icon.swift <ausgabe.iconset>   danach: iconutil -c icns <ausgabe.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS-Icon-Raster: Inhalt in 80 % der Fläche, abgerundetes Quadrat.
    let inset = s * 0.1
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
    ctx.addPath(tilePath)
    ctx.clip()
    let colors = [CGColor(red: 0.16, green: 0.45, blue: 0.98, alpha: 1), CGColor(red: 0.47, green: 0.22, blue: 0.88, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

    // iPhone: dunkler Rahmen, heller Bildschirm, Dynamic Island.
    let phoneHeight = tile.height * 0.68
    let phoneWidth = phoneHeight * 0.48
    let phone = CGRect(x: tile.midX - phoneWidth / 2, y: tile.midY - phoneHeight / 2, width: phoneWidth, height: phoneHeight)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
    ctx.addPath(CGPath(roundedRect: phone, cornerWidth: phoneWidth * 0.2, cornerHeight: phoneWidth * 0.2, transform: nil))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    let screen = phone.insetBy(dx: phoneWidth * 0.06, dy: phoneWidth * 0.06)
    let screenColors = [CGColor(red: 0.85, green: 0.93, blue: 1, alpha: 1), CGColor(red: 0.62, green: 0.78, blue: 1, alpha: 1)] as CFArray
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: phoneWidth * 0.15, cornerHeight: phoneWidth * 0.15, transform: nil))
    ctx.clip()
    let screenGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: screenColors, locations: [0, 1])!
    ctx.drawLinearGradient(screenGradient, start: CGPoint(x: screen.midX, y: screen.maxY), end: CGPoint(x: screen.midX, y: screen.minY), options: [])
    ctx.restoreGState()

    let island = CGRect(x: screen.midX - phoneWidth * 0.17, y: screen.maxY - phoneWidth * 0.16, width: phoneWidth * 0.34, height: phoneWidth * 0.09)
    ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
    ctx.addPath(CGPath(roundedRect: island, cornerWidth: island.height / 2, cornerHeight: island.height / 2, transform: nil))
    ctx.fillPath()

    // Spiegel-Pfeile links/rechts: „Mac ↔ iPhone“.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
    ctx.setLineWidth(max(1, s * 0.025))
    ctx.setLineCap(.round)
    for direction in [-1.0, 1.0] {
        let x = tile.midX + direction * (phoneWidth / 2 + tile.width * 0.1)
        let arm = tile.width * 0.05
        ctx.move(to: CGPoint(x: x - direction * arm, y: tile.midY + arm * 1.4))
        ctx.addLine(to: CGPoint(x: x, y: tile.midY))
        ctx.addLine(to: CGPoint(x: x - direction * arm, y: tile.midY - arm * 1.4))
        ctx.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try drawIcon(size: base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try drawIcon(size: base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print(output.path)
