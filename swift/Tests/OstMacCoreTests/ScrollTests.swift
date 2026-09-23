// ScrollTests.swift — om-scroll: follow policy, pill counts, load-more
// debounce, prepend anchors, settle schedule, stable image slots.
import XCTest

@testable import OstMacCore

@MainActor
final class ScrollTests: XCTestCase {
    private static func msgs(_ ids: String...) -> [ChatMessage] {
        ids.map { ChatMessage(id: $0, sender: "A", timestamp: "t", content: "x") }
    }

    // MARK: - Follow policy

    func testFollowNearBottom() {
        XCTAssertTrue(ScrollPolicy.shouldFollow(nearBottom: true, isOwnTail: false))
        XCTAssertTrue(ScrollPolicy.shouldFollow(nearBottom: true, isOwnTail: true))
    }

    func testNoFollowWhenScrolledUp() {
        XCTAssertFalse(ScrollPolicy.shouldFollow(nearBottom: false, isOwnTail: false))
    }

    func testOwnEchoAlwaysFollows() {
        XCTAssertTrue(ScrollPolicy.shouldFollow(nearBottom: false, isOwnTail: true))
    }

    // MARK: - Unseen / pill

    func testUnseenAfterFrontier() {
        let ms = Self.msgs("a", "b", "c")
        XCTAssertEqual(ScrollPolicy.unseenCount(messages: ms, after: "b"), 1)
        XCTAssertEqual(ScrollPolicy.unseenCount(messages: ms, after: "c"), 0)
        XCTAssertEqual(ScrollPolicy.unseenCount(messages: ms, after: "a"), 2)
    }

    func testUnseenUnknownFrontierIsZero() {
        let ms = Self.msgs("a", "b")
        XCTAssertEqual(ScrollPolicy.unseenCount(messages: ms, after: nil), 0)
        XCTAssertEqual(ScrollPolicy.unseenCount(messages: ms, after: "gone"), 0)
        XCTAssertEqual(ScrollPolicy.unseenCount(messages: [], after: "a"), 0)
    }

    func testPillTitle() {
        XCTAssertNil(ScrollPolicy.pillTitle(unseen: 0))
        XCTAssertEqual(ScrollPolicy.pillTitle(unseen: 1), "1 new message")
        XCTAssertEqual(ScrollPolicy.pillTitle(unseen: 3), "3 new messages")
    }

    // MARK: - Load-more debounce

    func testShouldLoadMoreCooldown() {
        let t0 = Date()
        XCTAssertTrue(ScrollPolicy.shouldLoadMore(now: t0, lastFire: .distantPast))
        XCTAssertFalse(ScrollPolicy.shouldLoadMore(now: t0, lastFire: t0))
        XCTAssertFalse(ScrollPolicy.shouldLoadMore(
            now: t0.addingTimeInterval(1), lastFire: t0))
        XCTAssertTrue(ScrollPolicy.shouldLoadMore(
            now: t0.addingTimeInterval(2), lastFire: t0))
    }

    func testModelDebounceCollapsesRefires() {
        let m = ChatScrollModel()
        XCTAssertTrue(m.shouldFireLoadMore(now: Date()))
        XCTAssertFalse(m.shouldFireLoadMore(now: Date()))
        XCTAssertTrue(m.shouldFireLoadMore(
            now: Date().addingTimeInterval(ScrollPolicy.loadMoreCooldown + 1)))
    }

    // MARK: - Prepend anchor

    func testFirstVisibleInHistoryOrder() {
        let m = ChatScrollModel()
        m.visibleIDs = ["c", "b"]
        XCTAssertEqual(m.firstVisibleID(in: Self.msgs("a", "b", "c")), "b")
        XCTAssertNil(m.firstVisibleID(in: Self.msgs("a")))
    }

    func testModelDefaultsToFollowing() {
        let m = ChatScrollModel()
        XCTAssertTrue(m.nearBottom)
        XCTAssertNil(m.lastReadID)
        XCTAssertNil(m.prePrependFirstID)
    }

    // MARK: - Settle schedule

    func testSettleDelaysAscending() {
        let d = ScrollPolicy.settleDelays
        XCTAssertFalse(d.isEmpty)
        XCTAssertEqual(d, d.sorted())
        XCTAssertTrue(d.allSatisfy { $0 > 0 })
    }

    // MARK: - Stable slots

    func testSlotIdenticalAllPhases() {
        let loading = RemoteImageSlot.size(for: .loading)
        XCTAssertEqual(loading, RemoteImageSlot.size(for: .loaded))
        XCTAssertEqual(loading, RemoteImageSlot.size(for: .failed("boom")))
        XCTAssertEqual(loading.width, 260)
        XCTAssertEqual(loading.height, 200)
    }

    func testEmoticonHeight() {
        XCTAssertEqual(RemoteImageSlot.emoticonHeight, 22)
    }
}
