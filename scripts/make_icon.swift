// Generates app/AppIcon.icns. Run with: swift scripts/make_icon.swift
// Pass --preview PATH to also write the 1024 px PNG.
import AppKit

let outRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = outRoot.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func roundRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

func drawText(_ text: String, size: CGFloat, color: NSColor, center: NSPoint) {
    let font = NSFont.systemFont(ofSize: size, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: -size * 0.03]
    let str = NSAttributedString(string: text, attributes: attrs)
    let bounds = str.size()
    str.draw(at: NSPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2 + size * 0.02))
}

// Coordinates are on a 1024 canvas, origin bottom-left, following the macOS
// icon grid: an 824 pt rounded square inset 100 pt, with a soft drop shadow.
func drawIcon(pixels: Int) -> Data {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }
    let s = CGFloat(pixels) / 1024.0
    ctx.scaleBy(x: s, y: s)

    // Tile with shadow
    let tile = roundRect(100, 100, 824, 824, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    rgb(0x1A1033).setFill()
    tile.fill()
    ctx.restoreGState()
    NSGradient(colors: [rgb(0x3A2475), rgb(0x1B1138)])!.draw(in: tile, angle: -90)

    // Soft glow behind the cards
    ctx.saveGState()
    tile.addClip()
    NSGradient(colors: [rgb(0x8B6CFF, 0.30), rgb(0x8B6CFF, 0.10), rgb(0x8B6CFF, 0)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: NSBezierPath(ovalIn: NSRect(x: 60, y: 90, width: 900, height: 900)), relativeCenterPosition: .zero)
    ctx.restoreGState()

    // Back card: the 2026 project
    let back = roundRect(372, 452, 432, 352, 52)
    rgb(0xFFFFFF, 0.07).setFill()
    back.fill()
    rgb(0xFFFFFF, 0.28).setStroke()
    back.lineWidth = 8
    back.stroke()
    drawText("26", size: 120, color: rgb(0xFFFFFF, 0.45), center: NSPoint(x: 716, y: 712))

    // Step-down arrow from 26 to 24
    let arrow = NSBezierPath()
    arrow.lineWidth = 22
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 748, y: 600))
    arrow.line(to: NSPoint(x: 748, y: 440))
    arrow.move(to: NSPoint(x: 708, y: 480))
    arrow.line(to: NSPoint(x: 748, y: 440))
    arrow.line(to: NSPoint(x: 788, y: 480))
    rgb(0xFFFFFF, 0.75).setStroke()
    arrow.stroke()

    // Front card: the 2024 project, a light timeline panel
    let frontX: CGFloat = 220, frontY: CGFloat = 250, frontW: CGFloat = 470, frontH: CGFloat = 384
    let front = roundRect(frontX, frontY, frontW, frontH, 56)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    rgb(0xF5F2FF).setFill()
    front.fill()
    ctx.restoreGState()

    // Clip rows
    let rows: [[(CGFloat, CGFloat, UInt32)]] = [
        [(262, 150, 0x7C5CFF), (424, 150, 0x35C9B5)],
        [(300, 190, 0xFF6B9A), (502, 120, 0xFFB547)],
        [(262, 110, 0x35C9B5), (384, 236, 0x7C5CFF)],
    ]
    for (i, row) in rows.enumerated() {
        let y = frontY + frontH - 108 - CGFloat(i) * 92
        for (x, w, color) in row {
            rgb(color).setFill()
            roundRect(x, y, w, 58, 18).fill()
        }
    }

    // Playhead
    let playX: CGFloat = 474
    rgb(0xFF4D6D).setFill()
    roundRect(playX - 5, frontY + 36, 10, frontH - 72, 5).fill()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: playX - 26, y: frontY + frontH - 30))
    head.line(to: NSPoint(x: playX + 26, y: frontY + frontH - 30))
    head.line(to: NSPoint(x: playX, y: frontY + frontH - 64))
    head.close()
    head.fill()

    // "24" badge with a step-down arrow
    let badgeCenter = NSPoint(x: 700, y: 278)
    let badge = NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 118, y: badgeCenter.y - 118, width: 236, height: 236))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    rgb(0x7C5CFF).setFill()
    badge.fill()
    ctx.restoreGState()
    NSGradient(colors: [rgb(0x9D85FF), rgb(0x6A47F5)])!.draw(in: badge, angle: -90)
    rgb(0xFFFFFF, 0.9).setStroke()
    badge.lineWidth = 10
    badge.stroke()
    drawText("24", size: 116, color: .white, center: badgeCenter)

    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed")
    }
    return png
}

for (name, px) in variants {
    try! drawIcon(pixels: px).write(to: iconset.appendingPathComponent(name))
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
    try! drawIcon(pixels: 1024).write(to: URL(fileURLWithPath: args[i + 1]))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path,
                  "-o", outRoot.appendingPathComponent("app/AppIcon.icns").path]
try! proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)
print("Wrote app/AppIcon.icns")
