// A11yLabelsTests — om-a2-labels: VoiceOver label contracts.
import XCTest
@testable import OstMacCore

final class A11yLabelsTests: XCTestCase {
    func testJumpPillTitled() {
        XCTAssertEqual(
            A11yLabels.jumpPill(title: "3 new messages"),
            "3 new messages. Jump to latest.")
    }

    func testJumpPillPlain() {
        XCTAssertEqual(
            A11yLabels.jumpPill(title: nil), "Jump to latest messages")
        XCTAssertEqual(
            A11yLabels.jumpPill(title: ""), "Jump to latest messages")
    }

    func testReminderComplete() {
        XCTAssertEqual(
            A11yLabels.reminderComplete(title: "Buy milk", completed: false),
            "Mark done: Buy milk")
        XCTAssertEqual(
            A11yLabels.reminderComplete(title: "Buy milk", completed: true),
            "Completed: Buy milk")
    }
}
