import AppKit

@main
struct RenderAssets {
    static func bitmap(width: Int, height: Int, draw: () -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    static func main() throws {
        _ = NSApplication.shared
        let root = CommandLine.arguments[1]
        let icons = root + "/build/AppIcon.iconset"
        try FileManager.default.createDirectory(atPath: icons, withIntermediateDirectories: true)
        var state = SystemStatus.preview(); state.battery.percent = 100
        for size in [16,32,128,256,512] {
            for scale in [1,2] {
                let pixels = size * scale
                let rep = bitmap(width: pixels, height: pixels) {
                    let p = CGFloat(pixels)
                    NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
                    NSBezierPath(roundedRect: NSRect(x: p*0.05, y: p*0.05, width: p*0.90, height: p*0.90), xRadius: p*0.20, yRadius: p*0.20).fill()
                    DuoIcon.draw(status: state, in: NSRect(x: p*0.07, y: p*0.15, width: p*0.86, height: p*0.70), color: .white)
                }
                let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: icons + "/" + name))
            }
        }
        print("Rendered app icon")
    }
}
