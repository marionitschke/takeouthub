// Draws the app icon and writes an .iconset.
// Usage: ./build.sh --icon
//
// Same layout as the WatchDiary logo (watchdiary/public/images/favicons/favicon.svg) and the icons of
// PhotoHub, FileHub and BackupHub: a tile in the main color at 18 % opacity (over white, as in
// WatchDiary's PNG icons, so it looks the same in a light and a dark Dock), inside it a square in the
// full main color, and inside that only the glyph in white. Each hub app has its own main color:
// TakeoutHub raspberry, PhotoHub violet, FileHub teal, BackupHub blue. The glyph is the previous one:
// a white cloud with a down arrow cut out in the main color.
// Drawn in the logo's coordinates (viewBox 512, y pointing down); the logo's tile (8…504) sits on
// Apple's icon grid (824 × 824 with a 100 px margin at 1024).
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// TakeoutHub's main color: raspberry.
let mainColor: UInt32 = 0xC8356A
/// Stroke width of the other hub icons (26 on their 292 square), scaled to the 340 square.
let barWidth: CGFloat = 30

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let s = CGFloat(pixels) / 1024
    let k = 824 / 496 * s
    let transform = NSAffineTransform()
    transform.translateX(by: 100 * s - 8 * k, yBy: CGFloat(pixels) - 100 * s + 8 * k)
    transform.scaleX(by: k, yBy: -k)
    transform.concat()

    // Tile: white with a shadow, the main color at 18 % opacity on top.
    let tile = NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 496, height: 496), xRadius: 112, yRadius: 112)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 16 * s
    shadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    shadow.set()
    NSColor.white.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(mainColor, 0.18).setFill()
    tile.fill()

    // Square in the full main color, as in the WatchDiary logo: 86…426 with radius 68.
    color(mainColor).setFill()
    NSBezierPath(roundedRect: NSRect(x: 86, y: 86, width: 340, height: 340), xRadius: 68, yRadius: 68).fill()

    // Cloud with the proportions of the previous icon (base and three circles), 250 wide, centered in
    // the square: x 131…381, y 175…337.
    let cloud = NSBezierPath()
    cloud.appendRoundedRect(NSRect(x: 131, y: 270, width: 250, height: 67), xRadius: 33.5, yRadius: 33.5)
    cloud.appendOval(in: NSRect(x: 151, y: 214.5, width: 105, height: 105))
    cloud.appendOval(in: NSRect(x: 206, y: 175, width: 130, height: 130))
    cloud.appendOval(in: NSRect(x: 276, y: 232.5, width: 90, height: 90))
    cloud.windingRule = .nonZero
    NSColor.white.setFill()
    cloud.fill()

    // Down arrow in the main color, fully inside the cloud (tip 14 above the base edge).
    let arrow = NSBezierPath()
    arrow.lineWidth = barWidth
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 256, y: 214))
    arrow.line(to: NSPoint(x: 256, y: 308))
    arrow.move(to: NSPoint(x: 216, y: 268))
    arrow.line(to: NSPoint(x: 256, y: 308))
    arrow.line(to: NSPoint(x: 296, y: 268))
    color(mainColor).setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in sizes {
    try render(pixels: entry.pixels).write(to: output.appendingPathComponent("\(entry.name).png"))
}
print("Icon-Set geschrieben: \(output.path)")
