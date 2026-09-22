// DemoMedia.swift — om-richmedia: offline `demo://` image fixtures.
//
// Programmatic PNGs (no binary blobs): seed 1 is a sunset, seed 2 a lake
// dawn. Deterministic pixels; unknown names throw (failure-state demo).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum DemoMedia {
    public static let photo1 = "demo://photo-1"
    public static let photo2 = "demo://photo-2"

    public static func data(for url: String) throws -> Data {
        switch url {
        case photo1: return render(seed: 1)
        case photo2: return render(seed: 2)
        default: throw MediaFetchError.failed("unknown demo media: \(url)")
        }
    }

    static func render(seed: Int, width: Int = 480, height: Int = 320) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let w = CGFloat(width), h = CGFloat(height)
        // Sky gradient (seed picks the palette).
        let top: CGColor = seed == 1
            ? CGColor(red: 0.13, green: 0.16, blue: 0.38, alpha: 1)
            : CGColor(red: 0.08, green: 0.23, blue: 0.42, alpha: 1)
        let bottom: CGColor = seed == 1
            ? CGColor(red: 0.98, green: 0.55, blue: 0.30, alpha: 1)
            : CGColor(red: 0.62, green: 0.86, blue: 0.95, alpha: 1)
        let grad = CGGradient(
            colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        // Sun / moon disc.
        ctx.setFillColor(seed == 1
            ? CGColor(red: 1, green: 0.85, blue: 0.55, alpha: 1)
            : CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.52, width: w * 0.16, height: w * 0.16))
        // Mountain silhouettes.
        ctx.setFillColor(CGColor(red: 0.16, green: 0.14, blue: 0.26, alpha: 1))
        ctx.move(to: CGPoint(x: 0, y: 0))
        ctx.addLine(to: CGPoint(x: w * 0.28, y: h * 0.52))
        ctx.addLine(to: CGPoint(x: w * 0.55, y: 0))
        ctx.closePath()
        ctx.fillPath()
        ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.20, alpha: 1))
        ctx.move(to: CGPoint(x: w * 0.38, y: 0))
        ctx.addLine(to: CGPoint(x: w * 0.70, y: h * 0.62))
        ctx.addLine(to: CGPoint(x: w, y: 0))
        ctx.closePath()
        ctx.fillPath()
        // Lake strip.
        ctx.setFillColor(CGColor(red: 0.12, green: 0.20, blue: 0.34, alpha: 0.92))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.22))
        let img = ctx.makeImage()!
        let out = CFDataCreateMutable(nil, 0)!
        let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
