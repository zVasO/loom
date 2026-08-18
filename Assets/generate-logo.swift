import AppKit

// Loom logo: a weave. Three warp threads (orange) crossed by two weft
// threads — one orange, one cyan (the session woven into the project).
// Over/under interlacing drawn by re-painting warp segments on top.

func drawLogo(into ctx: CGContext, size: CGFloat) {
    let s = size / 1024.0   // design in 1024 space
    // NO white backing: everything outside the rounded square stays transparent.
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // Background: rounded square, near-black with a hint of depth.
    let corner = 232 * s
    let bgRect = CGRect(x: 32 * s, y: 32 * s, width: 960 * s, height: 960 * s)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.addPath(bgPath)
    ctx.setFillColor(CGColor(red: 0.051, green: 0.051, blue: 0.055, alpha: 1))
    ctx.fillPath()
    // Subtle inner border
    ctx.addPath(CGPath(roundedRect: bgRect.insetBy(dx: 6 * s, dy: 6 * s),
                       cornerWidth: corner - 6 * s, cornerHeight: corner - 6 * s, transform: nil))
    ctx.setStrokeColor(CGColor(red: 0.149, green: 0.149, blue: 0.169, alpha: 1))
    ctx.setLineWidth(8 * s)
    ctx.strokePath()

    let orange = CGColor(red: 0.910, green: 0.580, blue: 0.360, alpha: 1)
    let orangeDim = CGColor(red: 0.910, green: 0.580, blue: 0.360, alpha: 0.82)
    let cyan = CGColor(red: 0.36, green: 0.784, blue: 0.76, alpha: 1)

    let thread = 96 * s          // thread thickness
    let radius = thread / 2

    // Warp: three vertical threads.
    let warpX: [CGFloat] = [296, 464, 632].map { $0 * s }
    // Weft: two horizontal threads (upper orange, lower cyan).
    let weftY: [CGFloat] = [560, 368].map { $0 * s }

    let warpTop = 792 * s
    let warpBottom = 232 * s
    let weftLeft = 232 * s
    let weftRight = 792 * s

    func roundedBar(_ rect: CGRect, _ color: CGColor) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    // 1. Warp threads (vertical, orange).
    for x in warpX {
        roundedBar(CGRect(x: x, y: warpBottom, width: thread, height: warpTop - warpBottom), orangeDim)
    }
    // 2. Weft threads (horizontal) — full bars.
    roundedBar(CGRect(x: weftLeft, y: weftY[0], width: weftRight - weftLeft, height: thread), orange)
    roundedBar(CGRect(x: weftLeft, y: weftY[1], width: weftRight - weftLeft, height: thread), cyan)
    // 3. Interlacing: warp goes OVER the weft at alternating crossings.
    //    Row 0 (upper): threads 0 and 2 over. Row 1 (lower): thread 1 over.
    let overUpper = [warpX[0], warpX[2]]
    let overLower = [warpX[1]]
    for x in overUpper {
        roundedBar(CGRect(x: x, y: weftY[0] - 14 * s, width: thread, height: thread + 28 * s), orangeDim)
    }
    for x in overLower {
        roundedBar(CGRect(x: x, y: weftY[1] - 14 * s, width: thread, height: thread + 28 * s), orangeDim)
    }

}

func writePNG(to path: String, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawLogo(into: context.cgContext, size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
for px in [16, 32, 64, 128, 256, 512, 1024] {
    writePNG(to: "\(out)/icon_\(px).png", pixels: px)
}
print("done")
