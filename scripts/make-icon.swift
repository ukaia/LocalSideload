import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor); transform.concat()
        let shape = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 195, yRadius: 195)
        NSGradient(starting: NSColor(red: 0.10, green: 0.18, blue: 0.26, alpha: 1),
                   ending: NSColor(red: 0.04, green: 0.08, blue: 0.13, alpha: 1))!
            .draw(in: shape, angle: -90)
        let phone = NSBezierPath(roundedRect: NSRect(x: 325, y: 225, width: 374, height: 596), xRadius: 65, yRadius: 65)
        NSColor(white: 0.94, alpha: 1).setStroke(); phone.lineWidth = 35; phone.stroke()
        let island = NSBezierPath(roundedRect: NSRect(x: 447, y: 756, width: 130, height: 20), xRadius: 10, yRadius: 10)
        NSColor(white: 0.94, alpha: 1).setFill(); island.fill()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 512, y: 652)); arrow.line(to: NSPoint(x: 512, y: 362))
        arrow.move(to: NSPoint(x: 407, y: 464)); arrow.line(to: NSPoint(x: 512, y: 357)); arrow.line(to: NSPoint(x: 617, y: 464))
        NSColor(red: 0.32, green: 0.90, blue: 0.75, alpha: 1).setStroke()
        arrow.lineWidth = 50; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
    }
}
