// Generates app/AppIcon.icns. Run with: swift scripts/make_icon.swift
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

func drawIcon(pixels: Int) -> Data {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }
    let s = CGFloat(pixels) / 1024.0
    ctx.scaleBy(x: s, y: s)

    // Background
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                          xRadius: 220, yRadius: 220)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.17, blue: 0.27, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.12, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: -90)

    // Project card
    let cardRect = NSRect(x: 218, y: 238, width: 588, height: 620)
    let card = NSBezierPath(roundedRect: cardRect, xRadius: 54, yRadius: 54)
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    card.fill()

    // Timeline rows
    NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
    let rows: [(CGFloat, CGFloat, CGFloat)] = [
        (330, 700, 360), (330, 606, 250), (330, 512, 320), (330, 418, 190),
    ]
    for (x, y, w) in rows {
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: 44),
                     xRadius: 22, yRadius: 22).fill()
    }

    // Accent badge
    let badgeRect = NSRect(x: 574, y: 96, width: 344, height: 344)
    NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.42, alpha: 1).setFill()
    NSBezierPath(ovalIn: badgeRect).fill()

    // Down arrow
    let arrow = NSBezierPath()
    arrow.lineWidth = 46
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 746, y: 358))
    arrow.line(to: NSPoint(x: 746, y: 178))
    arrow.move(to: NSPoint(x: 654, y: 268))
    arrow.line(to: NSPoint(x: 746, y: 178))
    arrow.line(to: NSPoint(x: 838, y: 268))
    NSColor.white.setStroke()
    arrow.stroke()

    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed")
    }
    return png
}

for (name, px) in variants {
    let data = drawIcon(pixels: px)
    try! data.write(to: iconset.appendingPathComponent(name))
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
