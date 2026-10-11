// Пересборка: xcrun swift tools/make-icon.swift "GlucoseWatch Watch App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
import AppKit

// Значок страницы (web/favicon.svg) в квадрате 1024 без скругления: часы сами
// режут иконку кругом, поэтому рисунок сжат к центру.
let size = 1024
let scale = 25.0
func p(_ x: Double, _ y: Double) -> CGPoint {
    CGPoint(x: 512 + (x - 16) * scale, y: 1024 - (512 + (y - 15.5) * scale))
}
func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(color(0x0d0d14))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

let band = CGRect(x: p(4, 24).x, y: p(4, 24).y, width: 24 * scale, height: 9 * scale)
ctx.addPath(CGPath(roundedRect: band, cornerWidth: 1.5 * scale, cornerHeight: 1.5 * scale, transform: nil))
ctx.setFillColor(color(0x7efcb0, 0.16))
ctx.fillPath()

let curve = [(4.0, 20.0), (8, 22), (12, 17), (16, 7), (20, 13), (24, 19), (28, 17)]
ctx.move(to: p(curve[0].0, curve[0].1))
for point in curve.dropFirst() { ctx.addLine(to: p(point.0, point.1)) }
ctx.setStrokeColor(color(0x7eb8f7))
ctx.setLineWidth(2.75 * scale)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
