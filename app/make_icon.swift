// Draws the StockGrid app icon (a 2x2 grid of mini charts) to a 1024px PNG.
import Cocoa

let size: CGFloat = 1024
let out = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.10, green: 0.14, blue: 0.19, alpha: 1), ending: NSColor(red: 0.06, green: 0.08, blue: 0.11, alpha: 1))!
    .draw(in: bg, angle: -90)

let up = NSColor(red: 0.20, green: 0.78, blue: 0.55, alpha: 1)
let down = NSColor(red: 1.0, green: 0.42, blue: 0.45, alpha: 1)
let blue = NSColor(red: 0.49, green: 0.61, blue: 1.0, alpha: 1)
let tiles: [(CGFloat, CGFloat, NSColor, [CGFloat])] = [
    (180, 530, up, [0.2, 0.35, 0.3, 0.55, 0.5, 0.8]),
    (530, 530, blue, [0.5, 0.4, 0.6, 0.45, 0.7, 0.65]),
    (180, 180, down, [0.8, 0.7, 0.75, 0.45, 0.5, 0.25]),
    (530, 180, up, [0.3, 0.5, 0.4, 0.6, 0.75, 0.85]),
]
for (x, y, color, pts) in tiles {
    let tile = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 314, height: 314), xRadius: 48, yRadius: 48)
    NSColor(white: 1, alpha: 0.06).setFill(); tile.fill()
    let line = NSBezierPath()
    for (i, p) in pts.enumerated() {
        let pt = NSPoint(x: x + 44 + CGFloat(i) / CGFloat(pts.count - 1) * 226, y: y + 50 + p * 214)
        i == 0 ? line.move(to: pt) : line.line(to: pt)
    }
    line.lineWidth = 26; line.lineCapStyle = .round; line.lineJoinStyle = .round
    color.setStroke(); line.stroke()
}
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
