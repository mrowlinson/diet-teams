// ComposerLayoutTests.swift — composer-rearrange: 2-line input min-height +
// uniform tool-button metrics + leading 3+2 stack geometry + preserved inserts.
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
    /// Stacked height: two rows + one xs gap fit the 48pt input exactly.
    func testToolButtonsUniform() {
        XCTAssertEqual(ComposerMetrics.toolButtonWidth, 32)
        XCTAssertEqual(ComposerMetrics.toolButtonHeight, 22)
        // GIF caption-bold label must fit the uniform cell.
        XCTAssertGreaterThanOrEqual(ComposerMetrics.toolButtonWidth, 28)
    }

    /// Leading stack holds all 5 controls in 3-over-2 rows.
    func testLeadingStackRows() {
        XCTAssertEqual(ComposerMetrics.leadingTopCount, 3)
        XCTAssertEqual(ComposerMetrics.leadingBottomCount, 2)
        XCTAssertEqual(
            ComposerMetrics.leadingTopCount + ComposerMetrics.leadingBottomCount, 5)
    }

    /// Two stacked rows + one xs gap equal the input min-height (48pt).
    func testStackFitsInputHeight() {
        XCTAssertEqual(
            ComposerMetrics.toolButtonHeight * 2 + DietSpace.xs,
            ComposerMetrics.inputMinHeight)
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
