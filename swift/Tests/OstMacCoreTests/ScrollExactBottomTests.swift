// ScrollExactBottomTests.swift — om-fix-scroll: chats land scrolled ALL
// the way down (zero gap). Pins the exact-bottom scroll target (the
// bottom sentinel = true content end, never the last bubble) and the
// tail-visible-at-rest state on a 300-msg open.
import XCTest

@testable import OstMacCore

@MainActor
final class ScrollExactBottomTests: XCTestCase {
    /// Exact-bottom target is the sentinel, never the tail bubble:
    /// targeting the last bubble parks ~1 wheel-click short (sentinel +
    /// trailing inset below the fold); every settle re-assert repeats it.
    func testBottomTargetIsSentinelNotTail() {
        XCTAssertEqual(
            ScrollPolicy.bottomTargetID(tailID: "lchan-300"),
            ScrollPolicy.bottomSentinelID)
        XCTAssertNotEqual(ScrollPolicy.bottomSentinelID, "lchan-300")
    }

    /// Empty thread: nothing to land on (no scroll, same as before).
    func testBottomTargetNilWhenEmpty() {
        XCTAssertNil(ScrollPolicy.bottomTargetID(tailID: nil))
    }

    /// Sentinel id never collides with a real bubble id (a collision
    /// would scroll to a bubble mid-list instead of the content end).
    func testSentinelIDNeverCollidesWithBubbles() {
        XCTAssertFalse(ScrollPolicy.bottomSentinelID.isEmpty)
        let ids = Set(DemoData.longChannelMessages().map(\.id))
        XCTAssertEqual(ids.count, 300)
        XCTAssertFalse(ids.contains(ScrollPolicy.bottomSentinelID))
    }

    /// 300-msg open lands tail-visible-at-rest: read frontier adopts the
    /// tail, zero unseen, no pill/jump overlay (already at the tail).
    func test300MsgOpenTailVisibleAtRest() {
        let store = ConversationStore()
        store.showDemo(
            chatID: DemoData.longChannelID, chatName: "long",
            messages: DemoData.longChannelMessages())
        XCTAssertEqual(store.messages.count, 300)
        let scroll = ChatScrollModel()
        // Landing path (mirrors ChatTimelineView onAppear + dwell).
        scroll.lastSeenID = store.messages.last?.id
        scroll.jumpToLatest(tailID: store.messages.last?.id)
        scroll.noteBottomDwell(tailID: store.messages.last?.id)
        XCTAssertTrue(scroll.nearBottom)
        XCTAssertEqual(scroll.lastReadID, "lchan-300")
        XCTAssertEqual(scroll.unseenCount(messages: store.messages), 0)
        XCTAssertNil(ScrollPolicy.bottomAction(
            unseen: scroll.unseenCount(messages: store.messages),
            nearBottom: scroll.nearBottom))
        // Landing target is the content end, not the tail bubble.
        XCTAssertEqual(
            ScrollPolicy.bottomTargetID(tailID: store.messages.last?.id),
            ScrollPolicy.bottomSentinelID)
    }
}
