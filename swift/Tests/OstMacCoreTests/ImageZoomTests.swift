// ImageZoomTests.swift — om-imgzoom: scale clamp, slider mapping, fit-width,
// pan-offset bounds, content size, session size memory.
import AppKit
import XCTest

@testable import OstMacCore

final class ImageZoomTests: XCTestCase {
    // MARK: - Scale clamp

    func testClampScale() {
        XCTAssertEqual(ImageZoom.clampScale(1), 1)
        XCTAssertEqual(ImageZoom.clampScale(0.25), 0.25)
        XCTAssertEqual(ImageZoom.clampScale(4), 4)
        XCTAssertEqual(ImageZoom.clampScale(0), 0.25)
        XCTAssertEqual(ImageZoom.clampScale(-2), 0.25)
        XCTAssertEqual(ImageZoom.clampScale(0.249), 0.25)
        XCTAssertEqual(ImageZoom.clampScale(4.001), 4)
        XCTAssertEqual(ImageZoom.clampScale(10), 4)
    }

    // MARK: - Slider mapping

    func testSliderToScaleMapping() {
        XCTAssertEqual(ImageZoom.scale(forSliderPercent: 25), 0.25)
        XCTAssertEqual(ImageZoom.scale(forSliderPercent: 100), 1)
        XCTAssertEqual(ImageZoom.scale(forSliderPercent: 200), 2)
        XCTAssertEqual(ImageZoom.scale(forSliderPercent: 400), 4)
        // Out-of-range slider input clamps instead of escaping.
        XCTAssertEqual(ImageZoom.scale(forSliderPercent: 0), 0.25)
        XCTAssertEqual(ImageZoom.scale(forSliderPercent: 1000), 4)
    }

    func testScaleToSliderRoundTrip() {
        for scale in [0.25, 0.5, 1.0, 1.5, 2.0, 4.0] {
            let percent = ImageZoom.sliderPercent(forScale: scale)
            XCTAssertEqual(
                ImageZoom.scale(forSliderPercent: percent), scale, accuracy: 1e-9,
                "round trip failed for \(scale)")
        }
        XCTAssertEqual(ImageZoom.sliderPercent(forScale: 1), 100)
        XCTAssertEqual(ImageZoom.sliderPercent(forScale: 0), 25) // clamps
        XCTAssertEqual(ImageZoom.sliderPercent(forScale: 99), 400) // clamps
    }

    // MARK: - Fit-width default

    func testFitWidthDefault() {
        XCTAssertEqual(ImageZoom.fitWidthScale(imageWidth: 480, viewportWidth: 720), 1.5)
        XCTAssertEqual(ImageZoom.fitWidthScale(imageWidth: 480, viewportWidth: 240), 0.5)
        // Clamped to the slider range.
        XCTAssertEqual(ImageZoom.fitWidthScale(imageWidth: 480, viewportWidth: 480 * 5), 4)
        XCTAssertEqual(ImageZoom.fitWidthScale(imageWidth: 480, viewportWidth: 10), 0.25)
        // Degenerate inputs fall back to 100%.
        XCTAssertEqual(ImageZoom.fitWidthScale(imageWidth: 0, viewportWidth: 720), 1)
        XCTAssertEqual(ImageZoom.fitWidthScale(imageWidth: 480, viewportWidth: 0), 1)
        XCTAssertEqual(ImageZoom.fitWidthScale(imageWidth: -5, viewportWidth: 720), 1)
        XCTAssertEqual(ImageZoom.fitWidthScale(imageWidth: 480, viewportWidth: -3), 1)
    }

    // MARK: - Content size

    func testContentSize() {
        XCTAssertEqual(
            ImageZoom.contentSize(imageSize: CGSize(width: 480, height: 320), scale: 2),
            CGSize(width: 960, height: 640))
        // Scale clamps before sizing.
        XCTAssertEqual(
            ImageZoom.contentSize(imageSize: CGSize(width: 480, height: 320), scale: 0.1),
            CGSize(width: 120, height: 80))
        XCTAssertEqual(
            ImageZoom.contentSize(imageSize: CGSize(width: 480, height: 320), scale: 9),
            CGSize(width: 1920, height: 1280))
    }

    // MARK: - Pan-offset bounds

    func testPanOffsetBounds() {
        let content = CGSize(width: 960, height: 640)
        let viewport = CGSize(width: 480, height: 320)
        XCTAssertEqual(
            ImageZoom.clampOffset(
                CGPoint(x: 100, y: 50), contentSize: content, viewportSize: viewport),
            CGPoint(x: 100, y: 50))
        // Negative pins to zero…
        XCTAssertEqual(
            ImageZoom.clampOffset(
                CGPoint(x: -40, y: -1), contentSize: content, viewportSize: viewport),
            CGPoint(x: 0, y: 0))
        // …overflow pins to content − viewport.
        XCTAssertEqual(
            ImageZoom.clampOffset(
                CGPoint(x: 9000, y: 9000), contentSize: content, viewportSize: viewport),
            CGPoint(x: 480, y: 320))
        // Axes clamp independently.
        XCTAssertEqual(
            ImageZoom.clampOffset(
                CGPoint(x: -5, y: 9999), contentSize: content, viewportSize: viewport),
            CGPoint(x: 0, y: 320))
    }

    func testPanOffsetBoundsContentFitsViewport() {
        // Nothing to pan: every offset collapses to zero.
        let small = CGSize(width: 100, height: 80)
        let big = CGSize(width: 480, height: 320)
        for offset in [CGPoint.zero, CGPoint(x: 50, y: 50), CGPoint(x: -10, y: 500)] {
            XCTAssertEqual(
                ImageZoom.clampOffset(offset, contentSize: small, viewportSize: big), .zero,
                "offset \(offset) should collapse")
        }
        // Exact fit: max origin is zero on both axes.
        XCTAssertEqual(
            ImageZoom.clampOffset(CGPoint(x: 3, y: 3), contentSize: big, viewportSize: big),
            .zero)
    }

    // MARK: - Session size memory

    func testSessionRemembersSize() {
        ImageViewerSession.resetForTesting()
        XCTAssertEqual(ImageViewerSession.initialSize(), ImageViewerSession.defaultSize)
        ImageViewerSession.remember(CGSize(width: 900, height: 700))
        XCTAssertEqual(ImageViewerSession.initialSize(), CGSize(width: 900, height: 700))
        // Below-minimum sizes clamp up to the minimum.
        ImageViewerSession.remember(CGSize(width: 10, height: 10))
        XCTAssertEqual(ImageViewerSession.initialSize(), ImageViewerSession.minSize)
        ImageViewerSession.resetForTesting()
    }

    func testViewerSizeConstantsSane() {
        XCTAssertLessThan(
            ImageViewerSession.minSize.width, ImageViewerSession.defaultSize.width)
        XCTAssertLessThan(
            ImageViewerSession.minSize.height, ImageViewerSession.defaultSize.height)
        XCTAssertGreaterThanOrEqual(ImageViewerSession.minSize.width, 320)
        XCTAssertGreaterThanOrEqual(ImageViewerSession.minSize.height, 240)
    }
}
