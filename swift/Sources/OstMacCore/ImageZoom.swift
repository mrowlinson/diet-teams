// ImageZoom.swift — om-imgzoom: resizable viewer zoom model + scroll host.
//
// Pure zoom math (ImageZoom), per-session window-size memory
// (ImageViewerSession), and the NSScrollView host (ZoomScrollView) that gives
// trackpad scrolling for free plus drag-to-pan when zoomed past the viewport.
// Native macOS UI only (AppKit + SwiftUI).
import AppKit
import SwiftUI

/// Pure zoom math for the image viewer. Slider and scale share one range,
/// 25%…400%, with fit-width as the default scale.
public enum ImageZoom {
    public static let minScale = 0.25
    public static let maxScale = 4.0
    public static let minPercent = 25.0
    public static let maxPercent = 400.0

    /// Clamp a raw scale into 0.25…4.0.
    public static func clampScale(_ scale: Double) -> Double {
        min(max(scale, minScale), maxScale)
    }

    /// Magnification-slider position (percent, 25…400) → scale. Clamps
    /// out-of-range input instead of escaping the range.
    public static func scale(forSliderPercent percent: Double) -> Double {
        clampScale(percent / 100)
    }

    /// Scale → slider position in percent. Clamps.
    public static func sliderPercent(forScale scale: Double) -> Double {
        clampScale(scale) * 100
    }

    /// Fit-width default: the scale that makes the image span the viewport
    /// width, clamped into range. Degenerate inputs fall back to 100%.
    public static func fitWidthScale(imageWidth: CGFloat, viewportWidth: CGFloat) -> Double {
        guard imageWidth > 0, viewportWidth > 0 else { return 1 }
        return clampScale(Double(viewportWidth / imageWidth))
    }

    /// Scaled content size for an image at a scale (scale clamped first).
    public static func contentSize(imageSize: CGSize, scale: Double) -> CGSize {
        let s = CGFloat(clampScale(scale))
        return CGSize(width: imageSize.width * s, height: imageSize.height * s)
    }

    /// Clamp a scroll origin so the viewport stays over the content: each
    /// axis pins to 0…(content − viewport), collapsing to 0 when the content
    /// fits inside the viewport (nothing to pan).
    public static func clampOffset(
        _ offset: CGPoint, contentSize: CGSize, viewportSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: clampAxis(offset.x, content: contentSize.width, viewport: viewportSize.width),
            y: clampAxis(offset.y, content: contentSize.height, viewport: viewportSize.height)
        )
    }

    private static func clampAxis(_ value: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat {
        let maxOrigin = max(0, content - viewport)
        return min(max(value, 0), maxOrigin)
    }
}

/// Remembers the viewer window size for the session (at least): the next
/// image opened reuses the last size instead of the default.
public enum ImageViewerSession {
    public static let minSize = CGSize(width: 480, height: 360)
    public static let defaultSize = CGSize(width: 720, height: 540)

    public static var lastSize: CGSize?

    public static func initialSize() -> CGSize {
        lastSize ?? defaultSize
    }

    public static func remember(_ size: CGSize) {
        lastSize = CGSize(
            width: max(size.width, minSize.width),
            height: max(size.height, minSize.height)
        )
    }

    public static func resetForTesting() {
        lastSize = nil
    }
}

/// NSScrollView host for the zoomed image: the document view is sized to
/// image × scale (live with the slider), trackpad scroll pans natively, and a
/// drag gesture pans when the image overflows the viewport. Zooming preserves
/// the visible-center fraction; content smaller than the viewport centers.
struct ZoomScrollView: NSViewRepresentable {
    let image: NSImage
    var scale: Double

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let doc = FlippedImageView()
        doc.image = image
        doc.imageScaling = .scaleProportionallyUpOrDown
        scroll.documentView = doc
        context.coordinator.scroll = scroll
        let pan = NSPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        scroll.contentView.addGestureRecognizer(pan)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context _: Context) {
        guard let doc = scroll.documentView as? FlippedImageView else { return }
        if doc.image !== image {
            doc.image = image
        }
        let scaled = ImageZoom.contentSize(imageSize: image.size, scale: scale)
        let clip = scroll.contentView
        let old = doc.frame.size
        let firstLayout = old.width <= 0 || old.height <= 0
        let sizeChanged = old != scaled
        // Center content smaller than the viewport; else pin top-left.
        let clipSize = clip.bounds.size
        let origin = CGPoint(
            x: max(0, (clipSize.width - scaled.width) / 2),
            y: max(0, (clipSize.height - scaled.height) / 2)
        )
        doc.frame = CGRect(origin: origin, size: scaled)
        guard sizeChanged else { return }
        if firstLayout {
            clip.scroll(to: .zero)
        } else {
            // Preserve the visible-center fraction across zoom steps.
            let bounds = clip.bounds
            let cx = (bounds.origin.x + bounds.size.width / 2) / old.width
            let cy = (bounds.origin.y + bounds.size.height / 2) / old.height
            let next = CGPoint(
                x: cx * scaled.width - bounds.size.width / 2,
                y: cy * scaled.height - bounds.size.height / 2
            )
            clip.scroll(to: ImageZoom.clampOffset(
                next, contentSize: scaled, viewportSize: bounds.size))
        }
        scroll.reflectScrolledClipView(clip)
    }

    final class Coordinator: NSObject {
        weak var scroll: NSScrollView?

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard gesture.state == .changed,
                  let scroll,
                  let doc = scroll.documentView
            else { return }
            let clip = scroll.contentView
            let move = gesture.translation(in: clip)
            let origin = CGPoint(
                x: clip.bounds.origin.x - move.x,
                y: clip.bounds.origin.y - move.y
            )
            clip.scroll(to: ImageZoom.clampOffset(
                origin, contentSize: doc.frame.size, viewportSize: clip.bounds.size))
            gesture.setTranslation(.zero, in: clip)
            scroll.reflectScrolledClipView(clip)
        }
    }
}

/// Top-left-origin image view so pan math matches scroll-view conventions
/// (drag up moves the viewport up over the content).
final class FlippedImageView: NSImageView {
    override var isFlipped: Bool { true }
}
