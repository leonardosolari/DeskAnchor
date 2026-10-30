import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func writeIcon(size: Int, file: String) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let background = CGPath(roundedRect: CGRect(x: 55, y: 55, width: 914, height: 914), cornerWidth: 205, cornerHeight: 205, transform: nil)
    context.addPath(background); context.clip()
    let colors = [CGColor(red: 0.16, green: 0.35, blue: 0.85, alpha: 1), CGColor(red: 0.34, green: 0.58, blue: 1, alpha: 1)]
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 150, y: 130), end: CGPoint(x: 900, y: 950), options: [])
    for (index, rect) in [CGRect(x: 170, y: 390, width: 590, height: 390), CGRect(x: 245, y: 285, width: 590, height: 390), CGRect(x: 320, y: 180, width: 535, height: 390)].enumerated() {
        let shape = CGPath(roundedRect: rect, cornerWidth: 36, cornerHeight: 36, transform: nil)
        context.setFillColor(CGColor(gray: 1, alpha: [0.20, 0.40, 0.98][index])); context.addPath(shape); context.fillPath()
        if index == 2 {
            context.setFillColor(CGColor(red: 0.24, green: 0.47, blue: 0.91, alpha: 1))
            context.fill(CGRect(x: rect.minX + 25, y: rect.maxY - 72, width: rect.width - 50, height: 3))
            for offset in [0, 24, 48] { context.fillEllipse(in: CGRect(x: rect.minX + 30 + CGFloat(offset), y: rect.maxY - 45, width: 12, height: 12)) }
            context.setStrokeColor(CGColor(red: 0.24, green: 0.47, blue: 0.91, alpha: 1)); context.setLineWidth(21); context.setLineCap(.round)
            context.addArc(center: CGPoint(x: 590, y: 335), radius: 67, startAngle: 0.3, endAngle: 5.0, clockwise: false); context.strokePath()
            context.move(to: CGPoint(x: 614, y: 255)); context.addLine(to: CGPoint(x: 608, y: 285)); context.addLine(to: CGPoint(x: 640, y: 282)); context.strokePath()
        }
    }
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(file) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Icon", code: 1) }
}
for size in [16, 32, 128, 256, 512] {
    try writeIcon(size: size, file: "icon_\(size)x\(size).png")
    try writeIcon(size: size * 2, file: "icon_\(size)x\(size)@2x.png")
}
