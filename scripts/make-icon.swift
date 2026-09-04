// Renders the Vela app icon: a dark macOS squircle, the app's signature edge light glowing
// around an inner frame, and three lyric lines with the middle one lit like a sung word.
// Usage: swift scripts/make-icon.swift <output.png> [size]
import AppKit

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1 ? arguments[1] : "icon.png"
let size = arguments.count > 2 ? Double(arguments[2]) ?? 1024 : 1024
let scale = size / 1024

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: scale, y: scale)
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// Apple's icon grid: the shape is 824 pt inside a 1024 pt canvas.
let inset = 100.0
let shape = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
let radius = shape.width * 0.2237
let squircle = CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft drop shadow beneath the shape.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: color(0, 0, 0, 0.45))
ctx.addPath(squircle)
ctx.setFillColor(color(0.05, 0.045, 0.09))
ctx.fillPath()
ctx.restoreGState()

// Background: deep violet-navy gradient with a faint warm corner.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let background = CGGradient(colorsSpace: space,
                            colors: [color(0.16, 0.10, 0.30), color(0.06, 0.05, 0.12), color(0.03, 0.03, 0.06)] as CFArray,
                            locations: [0, 0.55, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: shape.minX, y: shape.maxY), end: CGPoint(x: shape.maxX, y: shape.minY), options: [])
let warm = CGGradient(colorsSpace: space, colors: [color(0.95, 0.45, 0.35, 0.35), color(0.95, 0.45, 0.35, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(warm, startCenter: CGPoint(x: shape.maxX - 120, y: shape.minY + 140), startRadius: 0,
                       endCenter: CGPoint(x: shape.maxX - 120, y: shape.minY + 140), endRadius: 420, options: [])
let cool = CGGradient(colorsSpace: space, colors: [color(0.35, 0.55, 1.0, 0.30), color(0.35, 0.55, 1.0, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(cool, startCenter: CGPoint(x: shape.minX + 160, y: shape.maxY - 120), startRadius: 0,
                       endCenter: CGPoint(x: shape.minX + 160, y: shape.maxY - 120), endRadius: 460, options: [])

// Edge light: a glowing rounded frame inset from the shape, coloured around its perimeter.
let frame = shape.insetBy(dx: 78, dy: 78)
let frameRadius = frame.width * 0.2
let framePath = CGPath(roundedRect: frame, cornerWidth: frameRadius, cornerHeight: frameRadius, transform: nil)
let stops: [(CGColor, Double)] = [
    (color(1.00, 0.55, 0.42), 0.0), (color(0.90, 0.36, 0.72), 0.25), (color(0.45, 0.42, 1.00), 0.5),
    (color(0.25, 0.85, 0.92), 0.75), (color(1.00, 0.55, 0.42), 1.0),
]
func drawGlowRing(lineWidth: Double, blur: Double, alpha: Double) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: blur, color: color(1, 1, 1, 0))
    // Conic gradient masked to the ring: draw the ring into a mask, then fill the gradient through it.
    let ring = framePath.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.addPath(ring)
    ctx.clip()
    ctx.setAlpha(alpha)
    // Angular sweep: fill the clipped ring with thin wedges, each interpolated between stops.
    let centre = CGPoint(x: shape.midX, y: shape.midY)
    let wedges = 720
    let reach = 900.0
    for i in 0..<wedges {
        let t0 = Double(i) / Double(wedges)
        let a0 = t0 * 2 * .pi + 0.6
        let a1 = Double(i + 2) / Double(wedges) * 2 * .pi + 0.6   // slight overlap hides seams
        ctx.setFillColor(sampleStops(at: t0))
        ctx.move(to: centre)
        ctx.addLine(to: CGPoint(x: centre.x + cos(a0) * reach, y: centre.y + sin(a0) * reach))
        ctx.addLine(to: CGPoint(x: centre.x + cos(a1) * reach, y: centre.y + sin(a1) * reach))
        ctx.closePath()
        ctx.fillPath()
    }
    ctx.restoreGState()
}

func sampleStops(at t: Double) -> CGColor {
    var lower = stops[0], upper = stops[stops.count - 1]
    for i in 0..<(stops.count - 1) where t >= stops[i].1 && t <= stops[i + 1].1 {
        lower = stops[i]; upper = stops[i + 1]; break
    }
    let span = max(0.0001, upper.1 - lower.1)
    let k = (t - lower.1) / span
    let a = lower.0.components!, b = upper.0.components!
    return color(a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k)
}
// Wide soft halo built from many faint rings (a smooth falloff, like the app's SDF glow),
// then a tighter bright core.
let haloRings = 40
for i in 0..<haloRings {
    let t = Double(i) / Double(haloRings - 1)          // 0 = widest, 1 = narrowest
    let width = 12 + (190 - 12) * pow(1 - t, 1.6)
    drawGlowRing(lineWidth: width, blur: 0, alpha: 0.022 + 0.02 * t)
}
drawGlowRing(lineWidth: 22, blur: 0, alpha: 0.45)
drawGlowRing(lineWidth: 9, blur: 0, alpha: 1.0)

// Lyric lines: quiet line above and below, the sung line bright with an accent sweep.
let lineHeight = 46.0
let centreY = shape.midY
func drawLine(width: Double, y: Double, fill: CGColor) {
    let rect = CGRect(x: shape.midX - width / 2, y: y - lineHeight / 2, width: width, height: lineHeight)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
    ctx.setFillColor(fill)
    ctx.fillPath()
}
drawLine(width: 290, y: centreY + 118, fill: color(1, 1, 1, 0.22))
drawLine(width: 330, y: centreY - 118, fill: color(1, 1, 1, 0.16))
// Sung line: white base with a glowing coral sweep across the first part, like a word being filled.
let sungWidth = 420.0
let sungRect = CGRect(x: shape.midX - sungWidth / 2, y: centreY - lineHeight / 2, width: sungWidth, height: lineHeight)
let sungPath = CGPath(roundedRect: sungRect, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 34, color: color(1.0, 0.55, 0.42, 0.75))
ctx.addPath(sungPath)
ctx.setFillColor(color(1, 1, 1, 0.95))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(sungPath)
ctx.clip()
let sweep = CGGradient(colorsSpace: space, colors: [color(1.0, 0.55, 0.42), color(1.0, 0.55, 0.42), color(1.0, 0.55, 0.42, 0)] as CFArray, locations: [0, 0.52, 0.66])!
ctx.drawLinearGradient(sweep, start: CGPoint(x: sungRect.minX, y: 0), end: CGPoint(x: sungRect.maxX, y: 0), options: [])
ctx.restoreGState()

// Subtle top highlight for depth.
let sheen = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.10), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: shape.maxY), end: CGPoint(x: 0, y: shape.maxY - 260), options: [])
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) \(Int(size))x\(Int(size))")
