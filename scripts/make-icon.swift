// Generates the app icon. Run from the repo root:
//   swift scripts/make-icon.swift --icon "MVR Exploder/AppIcon.icon"
//
// That writes an Icon Composer .icon with Liquid Glass switched off, which
// is what keeps macOS 26 from adding its glossy bevel and gradient. Given
// a folder instead of --icon, it writes the old flat PNG set.
//
// Drawn from vector at every size rather than scaled down from 1024. It is
// an original drawing in the SF Symbols style, not the symbols themselves:
// Apple's licence doesn't allow SF Symbols in app icons.

import AppKit

// Draws the MVR Exploder icon at any pixel size from vector, so the small
// sizes are drawn for their size rather than scaled down from 1024.
func drawIcon(pixels: Int, glyphOnly: Bool = false) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(pixels) / 1024          // everything below is in a 1024 canvas
    ctx.scaleBy(x: s, y: s)

    if glyphOnly {
        // The tile is 824 of the 1024; in a .icon the system draws the tile
        // and the layer covers all of it, so the cube is scaled to match.
        ctx.translateBy(x: 512, y: 512)
        ctx.scaleBy(x: 1024 / 824, y: 1024 / 824)
        ctx.translateBy(x: -512, y: -512)
    }

    // The tile: macOS icon grid, 824 square with a 100 margin.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    if !glyphOnly {
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    // One flat colour, the same grey as the tool cards — no gradient, no
    // highlight. The shadow only falls outside the tile, where the Dock
    // expects one.
    NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.18, alpha: 1).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    }

    // The glyph: an isometric cube with its three faces pulled apart.
    // The two smallest sizes get a bolder drawing — a bigger cube, heavier
    // strokes, wider gaps — or the faces run together into one blob.
    let small = pixels <= 32
    let a: CGFloat = small ? 250 : 220          // edge length
    let c = cos(CGFloat.pi / 6) * a
    let o = CGPoint(x: 512, y: small ? 480 : 486) // the cube's near corner
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x, y: o.y + y) }
    let top = [p(0, a), p(c, a / 2), p(0, 0), p(-c, a / 2)]
    let left = [p(-c, a / 2), p(0, 0), p(0, -a), p(-c, -a / 2)]
    let right = [p(0, 0), p(c, a / 2), p(c, -a / 2), p(0, -a)]

    let explode: CGFloat = small ? 58 : 48
    let inset: CGFloat = small ? 0.80 : 0.84
    let line: CGFloat = small ? 58 : 36

    func face(_ points: [CGPoint], push: CGVector, stroke: NSColor, fill: NSColor?) {
        let cx = points.map(\.x).reduce(0, +) / 4
        let cy = points.map(\.y).reduce(0, +) / 4
        let moved = points.map {
            CGPoint(x: cx + ($0.x - cx) * inset + push.dx * explode,
                    y: cy + ($0.y - cy) * inset + push.dy * explode)
        }
        let path = NSBezierPath()
        path.move(to: moved[0])
        for point in moved.dropFirst() { path.line(to: point) }
        path.close()
        path.lineWidth = line
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        if let fill { fill.setFill(); path.fill() }
        stroke.setStroke()
        path.stroke()
    }

    let white = NSColor(calibratedWhite: 0.93, alpha: 1)
    face(left, push: CGVector(dx: -cos(.pi / 6), dy: -0.5), stroke: white, fill: nil)
    face(right, push: CGVector(dx: cos(.pi / 6), dy: -0.5), stroke: white, fill: nil)
    face(top, push: CGVector(dx: 0, dy: 1), stroke: white, fill: nil)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// With --icon, writes an Icon Composer .icon instead: the tile as a flat
// fill and the cube as a layer, with every Liquid Glass effect switched
// off, which is the only way to keep macOS 26 from glazing it.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--icon" {
    let bundle = URL(fileURLWithPath: CommandLine.arguments[2])
    let assets = bundle.appendingPathComponent("Assets")
    try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let glyph = drawIcon(pixels: 1024, glyphOnly: true).representation(using: .png, properties: [:])!
    try! glyph.write(to: assets.appendingPathComponent("cube.png"))
    let json = """
    {
      "fill" : {
        "solid" : "srgb:0.17000,0.17000,0.18000,1.00000"
      },
      "groups" : [
        {
          "layers" : [
            {
              "glass" : false,
              "image-name" : "cube.png",
              "name" : "cube"
            }
          ],
          "shadow" : {
            "kind" : "neutral",
            "opacity" : 0
          },
          "specular" : false,
          "translucency" : {
            "enabled" : false,
            "value" : 0
          }
        }
      ],
      "supported-platforms" : {
        "squares" : "shared"
      }
    }
    """
    try! json.write(to: bundle.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    print("wrote \(bundle.path)")
    exit(0)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// The app's icon is the .icon now; the PNG set is only for a folder that
// already exists, so a stale command can't recreate the old icon set
// beside the new one.
var isFolder: ObjCBool = false
guard FileManager.default.fileExists(atPath: out, isDirectory: &isFolder), isFolder.boolValue else {
    print("""
    No folder at \(out).
    The app's icon is MVR Exploder/AppIcon.icon now. To regenerate it:
      swift scripts/make-icon.swift --icon "MVR Exploder/AppIcon.icon"
    """)
    exit(1)
}
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ("icon_1024_universal.png", 1024),
]
for (name, pixels) in sizes {
    let data = drawIcon(pixels: pixels).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
}
print("wrote \(sizes.count) files to \(out)")
