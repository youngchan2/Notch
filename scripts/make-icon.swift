import AppKit

// Vector artwork, rendered at each macOS icon size so small icons stay crisp.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func color(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let p = CGFloat(pixels)
        let tile = NSBezierPath(roundedRect: NSRect(x: p * 0.08, y: p * 0.08, width: p * 0.84, height: p * 0.84),
                                xRadius: p * 0.20, yRadius: p * 0.20)
        NSGradient(starting: color(0x181E22), ending: color(0x303A40))!.draw(in: tile, angle: 90)
        color(0xFFFFFF, alpha: 0.08).setStroke()
        tile.lineWidth = max(0.5, p * 0.002)
        tile.stroke()

        let capsule = NSBezierPath(roundedRect: NSRect(x: p * 0.18, y: p * 0.30, width: p * 0.64, height: p * 0.40),
                                   xRadius: p * 0.20, yRadius: p * 0.20)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0x000000, alpha: 0.35)
        shadow.shadowBlurRadius = p * 0.04
        shadow.shadowOffset = NSSize(width: 0, height: -p * 0.018)
        shadow.set()
        color(0x080E12).setFill()
        capsule.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: color(0x285343), ending: color(0x94F1D0))!.draw(in: capsule, angle: 90)
        let inner = NSBezierPath(roundedRect: NSRect(x: p * 0.19, y: p * 0.31, width: p * 0.62, height: p * 0.38),
                                 xRadius: p * 0.19, yRadius: p * 0.19)
        NSGradient(starting: color(0x080D12), ending: color(0x172629))!.draw(in: inner, angle: 90)

        let heights: [CGFloat] = [0.10, 0.19, 0.28, 0.19, 0.10]
        let palette = [0xB2FFD8, 0x86F2C1, 0x5EE3B6, 0x52D7C4, 0x52CAD2]
        for index in heights.indices {
            let width = p * 0.042
            let height = p * heights[index]
            let x = p * (0.5 + CGFloat(index - 2) * 0.085) - width / 2
            color(palette[index]).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: (p - height) / 2, width: width, height: height),
                         xRadius: width / 2, yRadius: width / 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

// Package the PNG representations without requiring a separate graphics dependency.
func word(_ value: Int) -> Data {
    var big = UInt32(value).bigEndian
    return withUnsafeBytes(of: &big) { Data($0) }
}
var records = Data()
for (kind, name) in [("icp4", "16x16"), ("icp5", "32x32"), ("icp6", "32x32@2x"),
                     ("ic07", "128x128"), ("ic08", "256x256"), ("ic09", "512x512"), ("ic10", "512x512@2x")] {
    let png = try Data(contentsOf: destination.appendingPathComponent("icon_" + name + ".png"))
    records.append(Data(kind.utf8)); records.append(word(png.count + 8)); records.append(png)
}
var icon = Data("icns".utf8)
icon.append(word(records.count + 8)); icon.append(records)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
