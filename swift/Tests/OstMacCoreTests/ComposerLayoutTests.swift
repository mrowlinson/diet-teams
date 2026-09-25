// ComposerLayoutTests.swift — composer-2line: 2-line input min-height +
// uniform tool-button metrics + preserved insert behaviors.
import XCTest

@testable import DietDesign
@testable import OstMacCore

final class ComposerLayoutTests: XCTestCase {
    /// Input is 2 lines tall at rest, grows past that (lineLimit 2...).
    func testInputMinLinesIsTwo() {
        XCTAssertEqual(ComposerMetrics.inputMinLines, 2)
        XCTAssertEqual(ComposerMetrics.inputMinHeight, DietSpace.xxl)
        XCTAssertEqual(ComposerMetrics.inputMinHeight, 48)
    }

    /// All 5 tool buttons share one width + one height (GIF matched).
    func testToolButtonsUniform() {
        XCTAssertEqual(ComposerMetrics.toolButtonWidth, 32)
        XCTAssertEqual(ComposerMetrics.toolButtonHeight, DietSize.controlHeight)
        XCTAssertEqual(ComposerMetrics.toolButtonHeight, 28)
        // GIF caption-bold label must fit the uniform cell.
        XCTAssertGreaterThanOrEqual(ComposerMetrics.toolButtonWidth, 28)
    }

    /// GIF pick still appends space-separated (behavior preserved).
    func testGIFAppendPreserved() {
        XCTAssertEqual(ConversationView.appendGIF("https://k/g", to: ""), "https://k/g")
        XCTAssertEqual(
            ConversationView.appendGIF("https://k/g", to: "hello"),
            "hello https://k/g")
    }

    /// Template pick still appends, never replaces (behavior preserved).
    func testTemplateInsertPreserved() {
        XCTAssertEqual(CannedResponses.insert("thanks!", into: ""), "thanks!")
        XCTAssertEqual(
            CannedResponses.insert("thanks!", into: "hello"), "hello thanks!")
    }
}
