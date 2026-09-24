// ImageDecode.swift — om-s3-mediahot: off-main, downsampled image decode.
//
// Bubble and viewer models used to run `NSImage(data:)` on the main actor
// at full pixel size. Decode now runs detached and downsamples to the
// display slot via ImageIO thumbnails: bubbles to the 260pt slot @2x,
// the zoom viewer to a 2048px cap (still full-detail at its zoom range).
import AppKit
import ImageIO

public enum ImageDecode {
    /// Bubble slot (260×200pt) at 2x retina.
    public static let bubbleMaxPixels: CGFloat = 520
    /// Zoom-viewer cap: keeps full detail for fit-width + 400% zoom on
    /// typical photos while bounding huge-image memory.
    public static let viewerMaxPixels: CGFloat = 2048

    /// Downsampled decode, synchronous (call off the main thread).
    /// Nil for empty/non-image data, like `NSImage(data:)`.
    public static func thumbnail(data: Data, maxPixels: CGFloat) -> NSImage? {
        guard !data.isEmpty else { return nil }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let opts: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Downsampled decode off the caller's actor.
    public static func decodeOffMain(data: Data, maxPixels: CGFloat) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            thumbnail(data: data, maxPixels: maxPixels)
        }.value
    }
}
