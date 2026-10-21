// Genera el ícono original de Holgura (un anillo de espacio con un hueco libre) como .iconset.
// Uso: swift scripts/make-icon.swift <carpeta.iconset>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let ctx = NSGraphicsContext.current!.cgContext

    // Fondo: "squircle" con degradado verde azulado → índigo.
    let inset = s * 0.09
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.black.setFill(); path.fill()
    ctx.restoreGState()
    path.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.70, alpha: 1),
        NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.92, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.80, alpha: 1),
    ])!
    gradient.draw(in: body, angle: -60)

    // Anillo: segmentos ocupados y un hueco libre (el "espacio" recuperado).
    let center = CGPoint(x: s / 2, y: s / 2)
    let radius = body.width * 0.30
    let lineWidth = body.width * 0.11
    ctx.setLineCap(.round)
    ctx.setLineWidth(lineWidth)
    let segments: [(CGFloat, CGFloat, CGFloat)] = [(100, 205, 0.95), (220, 300, 0.75), (315, 375, 0.55)]
    for (start, end, alpha) in segments {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: start * .pi / 180, endAngle: end * .pi / 180,
                   clockwise: false)
        ctx.strokePath()
    }
    // Destello en el hueco libre.
    let sparkle = CGPoint(x: center.x + radius * cos(48 * .pi / 180), y: center.y + radius * sin(48 * .pi / 180))
    let r = lineWidth * 0.75
    let star = NSBezierPath()
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 + .pi / 2
        let len = i % 2 == 0 ? r : r * 0.32
        let p = CGPoint(x: sparkle.x + len * cos(angle), y: sparkle.y + len * sin(angle))
        if i == 0 { star.move(to: p) } else { star.line(to: p) }
    }
    star.close()
    NSColor.white.setFill()
    star.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: outDir.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: outDir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("Iconset generado en \(outDir.path)")
