// ScrollBottomTests.swift — om-scrollbottom: stick/pill/jump states.
//
// Pins the tail-advance state machine (ChatScrollModel.consumeTail),
// the bottom overlay decision (ScrollPolicy.bottomAction), and the
// dwell/jump transitions: stick at the tail, pill while reading
// history, accurate counts, jump-to-latest from anywhere up.
import XCTest

@testable import OstMacCore

@MainActor
final class ScrollBottomTests: XCTestCase {
    private static func msgs(_ ids: String...) -> [ChatMessage] {
        ids.map { ChatMessage(id: $0, sender: "A", timestamp: "t", content: "x") }
    }

    /// Fresh model parked mid-history: frontier + detector on "a".
    private static func readingHistory() -> ChatScrollModel {
        let m = ChatScrollModel()
        m.noteLeftBottom()
        m.lastSeenID = "a"
        m.lastReadID = "a"
        return m
    }

    // MARK: - Stick (at the tail, follow advances)

    func testStickFollowsAtBottom() {
        let m = ChatScrollModel() // nearBottom defaults true
        m.lastSeenID = "a"
        m.lastReadID = "a"
        XCTAssertEqual(m.consumeTail(currentTailID: "b", isOwnTail: false), .follow)
        XCTAssertEqual(m.lastSeenID, "b")
        XCTAssertEqual(m.lastReadID, "b")
        XCTAssertEqual(m.unseenCount(messages: Self.msgs("a", "b")), 0)
        XCTAssertNil(ScrollPolicy.bottomAction(unseen: 0, nearBottom: m.nearBottom))
    }

    func testStickTracksRepeatedAdvances() {
        let m = ChatScrollModel()
        m.lastSeenID = "a"
        m.lastReadID = "a"
        XCTAssertEqual(m.consumeTail(currentTailID: "b", isOwnTail: false), .follow)
        XCTAssertEqual(m.consumeTail(currentTailID: "c", isOwnTail: false), .follow)
        XCTAssertEqual(m.lastReadID, "c")
        XCTAssertEqual(m.unseenCount(messages: Self.msgs("a", "b", "c")), 0)
    }

    // MARK: - Pill (reading history, hold + count)

    func testPillHoldsWhenReadingHistory() {
        let m = Self.readingHistory()
        XCTAssertEqual(m.consumeTail(currentTailID: "c", isOwnTail: false), .pill)
        XCTAssertEqual(m.lastSeenID, "c") // detector consumed…
        XCTAssertEqual(m.lastReadID, "a") // …but the frontier holds (no scroll)
        let unseen = m.unseenCount(messages: Self.msgs("a", "b", "c"))
        XCTAssertEqual(unseen, 2)
        XCTAssertEqual(ScrollPolicy.pillTitle(unseen: unseen), "2 new messages")
        XCTAssertEqual(
            ScrollPolicy.bottomAction(unseen: unseen, nearBottom: m.nearBottom),
            .pill("2 new messages"))
    }

    func testPillCountGrowsWithFurtherAdvances() {
        let m = Self.readingHistory()
        XCTAssertEqual(m.consumeTail(currentTailID: "b", isOwnTail: false), .pill)
        XCTAssertEqual(m.consumeTail(currentTailID: "c", isOwnTail: false), .pill)
        XCTAssertEqual(m.consumeTail(currentTailID: "d", isOwnTail: false), .pill)
        XCTAssertEqual(m.lastReadID, "a")
        XCTAssertEqual(m.unseenCount(messages: Self.msgs("a", "b", "c", "d")), 3)
    }

    func testPillCountSurvivesPrepend() {
        // Frontier is id-based: older pages landing above never shift it.
        let m = Self.readingHistory()
        m.lastSeenID = "b"
        m.lastReadID = "b"
        XCTAssertEqual(m.unseenCount(messages: Self.msgs("a", "b", "c")), 1)
        XCTAssertEqual(m.unseenCount(messages: Self.msgs("x", "a", "b", "c")), 1)
    }

    func testStableTailConsumesNothing() {
        // Same tail (prepend / in-place refresh): no frontier move, so the
        // caller takes the anchor-hold path instead of follow/pill.
        let m = Self.readingHistory()
        XCTAssertEqual(m.consumeTail(currentTailID: "a", isOwnTail: false), .none)
        XCTAssertEqual(m.lastSeenID, "a")
        XCTAssertEqual(m.lastReadID, "a")
    }

    // MARK: - Jump (back to latest from anywhere up)

    func testJumpToLatestClearsPill() {
        let m = Self.readingHistory()
        XCTAssertEqual(m.consumeTail(currentTailID: "c", isOwnTail: false), .pill)
        XCTAssertEqual(m.unseenCount(messages: Self.msgs("a", "b", "c")), 2)
        m.jumpToLatest(tailID: "c")
        XCTAssertTrue(m.nearBottom)
        XCTAssertEqual(m.lastReadID, "c")
        XCTAssertEqual(m.unseenCount(messages: Self.msgs("a", "b", "c")), 0)
        XCTAssertNil(ScrollPolicy.pillTitle(unseen: 0))
        XCTAssertNil(ScrollPolicy.bottomAction(unseen: 0, nearBottom: m.nearBottom))
    }

    func testJumpActionWhenScrolledUpWithNothingNew() {
        // Scrolled up, no unread mail: plain jump control, not the pill.
        XCTAssertEqual(ScrollPolicy.bottomAction(unseen: 0, nearBottom: false), .jump)
        XCTAssertNil(ScrollPolicy.bottomAction(unseen: 0, nearBottom: true))
        // Unread mail wins over position (transient pre-dwell included).
        XCTAssertEqual(
            ScrollPolicy.bottomAction(unseen: 1, nearBottom: true),
            .pill("1 new message"))
        XCTAssertEqual(
            ScrollPolicy.bottomAction(unseen: 3, nearBottom: false),
            .pill("3 new messages"))
    }

    // MARK: - Dwell / leave transitions

    func testBottomDwellMarksRead() {
        let m = Self.readingHistory()
        XCTAssertEqual(m.consumeTail(currentTailID: "c", isOwnTail: false), .pill)
        XCTAssertEqual(m.unseenCount(messages: Self.msgs("a", "b", "c")), 2)
        m.noteBottomDwell(tailID: "c")
        XCTAssertTrue(m.nearBottom)
        XCTAssertEqual(m.unseenCount(messages: Self.msgs("a", "b", "c")), 0)
        XCTAssertNil(ScrollPolicy.bottomAction(unseen: 0, nearBottom: m.nearBottom))
    }

    func testLeftBottomShowsJumpAndCancelsSettle() {
        let m = ChatScrollModel()
        m.settleTask = Task {}
        m.noteLeftBottom()
        XCTAssertFalse(m.nearBottom)
        XCTAssertNil(m.settleTask)
        XCTAssertEqual(ScrollPolicy.bottomAction(unseen: 0, nearBottom: false), .jump)
    }

    // MARK: - Own echo + reset edges

    func testOwnEchoFollowsFromHistory() {
        // The Send tap implies the jump: own tail always follows.
        let m = Self.readingHistory()
        XCTAssertEqual(m.consumeTail(currentTailID: "b", isOwnTail: true), .follow)
        XCTAssertEqual(m.lastReadID, "b")
        XCTAssertEqual(m.unseenCount(messages: Self.msgs("a", "b")), 0)
    }

    func testFreshEmptyConsumesNothing() {
        let m = ChatScrollModel()
        XCTAssertEqual(m.consumeTail(currentTailID: nil, isOwnTail: false), .none)
        XCTAssertNil(m.lastSeenID)
        XCTAssertNil(m.lastReadID)
    }

    func testOpenClearResetsFrontierAtBottom() {
        // Open clears the thread (tail nil) before pages land: the stale
        // frontier resets instead of pinning a pill to a dead id.
        let m = ChatScrollModel()
        m.lastSeenID = "a"
        m.lastReadID = "a"
        XCTAssertEqual(m.consumeTail(currentTailID: nil, isOwnTail: false), .follow)
        XCTAssertNil(m.lastSeenID)
        XCTAssertNil(m.lastReadID)
    }
}
