// ChannelHistoryTests.swift — om-channel-history: few-days initial cap,
// paging helpers, open-chain anchor suppression, land-on-latest.
import XCTest

@testable import OstMacCore

@MainActor
final class ChannelHistoryTests: XCTestCase {
    private static func msg(_ id: String, _ ts: String) -> ChatMessage {
        ChatMessage(id: id, sender: "A", timestamp: ts, content: "x")
    }

    // MARK: - Initial-load caps (few days, few pages)

    func testInitialLoadCaps() {
        // Initial open covers the last few days, bounded page fetches;
        // older history pages back on scroll (day-chunks unchanged).
        XCTAssertEqual(ConversationStore.historyWindowHours, 72)
        XCTAssertEqual(ConversationStore.openMaxPages, 3)
        XCTAssertEqual(ConversationStore.dayLoadMaxPages, 4)
    }

    func testWindowCoversFewDays() {
        let now = ConversationStore.messageDate("2026-09-23T12:00:00Z")!
        // 71h-old oldest: window not covered, keep paging.
        XCTAssertFalse(ConversationStore.windowCovered(
            [Self.msg("a", "2026-09-20T13:00:00Z")], now: now))
        // 73h-old oldest: covered, stop.
        XCTAssertTrue(ConversationStore.windowCovered(
            [Self.msg("a", "2026-09-20T11:00:00Z")], now: now))
        // Empty pages cover nothing: keep paging (blank-page chains
        // still terminate on the page cap / token end).
        XCTAssertFalse(ConversationStore.windowCovered([], now: now))
        // Unparseable stamps stop the window (never spin on garbage).
        XCTAssertTrue(ConversationStore.windowCovered([Self.msg("a", "t")], now: now))
    }

    // MARK: - Pagination purity (long-channel page joins)

    func testPrependExistingWinsNoDupes() {
        let list = [Self.msg("b", "t"), Self.msg("c", "t")]
        let older = [Self.msg("a", "t"), Self.msg("b", "t")]
        let out = ConversationStore.prepend(older, to: list)
        XCTAssertEqual(out.map(\.id), ["a", "b", "c"])
    }

    // MARK: - Open-chain anchor suppression (blank-park fix)

    func testAnchorHeldOnlyOutsideOpenChain() {
        // During the open page-chain, prepends must not fire anchor
        // scrolls (queued scrollTos race rebuilds and park mid-list).
        XCTAssertFalse(ScrollPolicy.shouldAnchorPrepend(loading: true))
        // Scroll-up paging still holds the first-visible row.
        XCTAssertTrue(ScrollPolicy.shouldAnchorPrepend(loading: false))
    }

    // MARK: - Land on latest (open completion)

    func testOpenCompletionLandsOnLatest() {
        let m = ChatScrollModel()
        // Parked mid-list when the chain ends (settle-cancel shape).
        m.noteLeftBottom()
        XCTAssertFalse(m.nearBottom)
        // Completion re-hugs the tail and marks read through it.
        m.jumpToLatest(tailID: "tail-9")
        XCTAssertTrue(m.nearBottom)
        XCTAssertEqual(m.lastReadID, "tail-9")
        XCTAssertEqual(
            ScrollPolicy.bottomAction(unseen: m.unseenCount(messages: Self.msgs()), nearBottom: m.nearBottom),
            nil)
    }

    func testInitialPublishFollowsTail() {
        let m = ChatScrollModel()
        // Fresh open: first publish moves the tail while hugging it.
        XCTAssertEqual(m.consumeTail(currentTailID: "t1", isOwnTail: false), .follow)
        // Chain prepends hold the tail: no follow, no pill.
        XCTAssertEqual(m.consumeTail(currentTailID: "t1", isOwnTail: false), .none)
    }

    // MARK: - Open-chain progress + capped marker (om-hu-polish)

    func testOpenProgressTitle() {
        // Idle: no progress row.
        XCTAssertNil(ScrollPolicy.openProgressTitle(loading: false, messageCount: 10))
        // Chain running but nothing landed: the centered "Loading
        // recent" block covers it, no top row.
        XCTAssertNil(ScrollPolicy.openProgressTitle(loading: true, messageCount: 0))
        // Mid-chain: count of bubbles landed so far.
        XCTAssertEqual(
            ScrollPolicy.openProgressTitle(loading: true, messageCount: 42),
            "Loading older messages… 42 loaded")
    }

    func testShowingLastTitle() {
        // End of history: no marker (the thread starts here).
        XCTAssertNil(ScrollPolicy.showingLastTitle(
            didLoad: true, loading: false, messageCount: 50,
            hasMoreHistory: false, isDemo: false))
        // Mid-chain: progress row owns the top, no marker.
        XCTAssertNil(ScrollPolicy.showingLastTitle(
            didLoad: true, loading: true, messageCount: 50,
            hasMoreHistory: true, isDemo: false))
        // Never loaded / empty: no marker.
        XCTAssertNil(ScrollPolicy.showingLastTitle(
            didLoad: false, loading: false, messageCount: 50,
            hasMoreHistory: true, isDemo: false))
        XCTAssertNil(ScrollPolicy.showingLastTitle(
            didLoad: true, loading: false, messageCount: 0,
            hasMoreHistory: true, isDemo: false))
        // Demo threads never page: no marker on stale tokens.
        XCTAssertNil(ScrollPolicy.showingLastTitle(
            didLoad: true, loading: false, messageCount: 50,
            hasMoreHistory: true, isDemo: true))
        // Capped: marker names the visible slice.
        XCTAssertEqual(
            ScrollPolicy.showingLastTitle(
                didLoad: true, loading: false, messageCount: 50,
                hasMoreHistory: true, isDemo: false),
            "Showing last 50 messages")
    }

    private static func msgs() -> [ChatMessage] {
        [msg("a", "t"), msg("tail-9", "t")]
    }
}
