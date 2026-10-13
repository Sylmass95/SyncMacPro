// Dessine l'icône de SyncMacPro (carré arrondi bleu, deux flèches de synchronisation) dans un dossier .iconset.
//
//   swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Fond : carré arrondi (gabarit macOS : 80 % de la surface), dégradé bleu.
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let colors = [CGColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1), CGColor(red: 0.05, green: 0.30, blue: 0.85, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    // Deux arcs blancs avec pointes de flèche.
    let center = CGPoint(x: s / 2, y: s / 2)
    let radius = rect.width * 0.27
    let line = rect.width * 0.075
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)
    for start in [CGFloat.pi * 0.15, CGFloat.pi * 1.15] {
        let end = start + CGFloat.pi * 0.7
        ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        ctx.strokePath()
        let tip = CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end))
        // Sens du mouvement (arc parcouru dans le sens trigonométrique) et normale à l'arc.
        let direction = CGPoint(x: -sin(end), y: cos(end))
        let normal = CGPoint(x: cos(end), y: sin(end))
        let head = line * 1.9
        ctx.move(to: CGPoint(x: tip.x + direction.x * head, y: tip.y + direction.y * head))
        ctx.addLine(to: CGPoint(x: tip.x + normal.x * head, y: tip.y + normal.y * head))
        ctx.addLine(to: CGPoint(x: tip.x - normal.x * head, y: tip.y - normal.y * head))
        ctx.closePath()
        ctx.fillPath()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: folder.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: folder.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Icône : \(folder.path)")
