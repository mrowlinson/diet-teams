// MeetingSentinelTests.swift — om-lt6-meetsentinel: meeting chat lands
// exact-bottom on new mail (FIX-scroll sentinel port). Pins the landing
// target (sentinel = true content end, never the tail bubble) and the
// at-rest follow state over meeting fixtures.
import XCTest

@testable import OstMacCore

@MainActor
final class MeetingSentinelTests: XCTestCase {
    /// Landing target is the sentinel, never the tail bubble: targeting
    /// the last bubble parks the 16pt trailing inset below the fold.
    func testMeetingLandingTargetIsSentinelNotTail() {
        XCTAssertEqual(
            MeetingChatPanel.landingTarget(tailID: "meet-3"),
            ScrollPolicy.bottomSentinelID)
        XCTAssertNotEqual(MeetingChatPanel.landingTarget(tailID: "meet-3"), "meet-3")
    }

    /// Empty thread: nothing to land on (no scroll).
    func testMeetingLandingTargetNilWhenEmpty() {
        XCTAssertNil(MeetingChatPanel.landingTarget(tailID: nil))
    }

    /// Sentinel id never collides with a meeting bubble id (a collision
    /// would land mid-list instead of the content end).
    func testMeetingSentinelNeverCollidesWithBubbles() {
        let ids = Set(MeetingDemo.messages.map(\.id))
        XCTAssertFalse(ids.isEmpty)
        XCTAssertFalse(ids.contains(ScrollPolicy.bottomSentinelID))
    }

    /// New mail at rest follows exact-bottom: read frontier adopts the
    /// tail, zero unseen, no pill/jump overlay, sentinel target.
    func testMeetingNewMailFollowsAtRest() {
        let scroll = ChatScrollModel()
        var messages = MeetingDemo.messages
        // Landing path (mirrors MeetingChatPanel onAppear + dwell).
        scroll.lastSeenID = messages.last?.id
        scroll.jumpToLatest(tailID: messages.last?.id)
        scroll.noteBottomDwell(tailID: messages.last?.id)
        // One new mail lands while hugging the tail.
        messages.append(ChatMessage(
            id: "meet-4", sender: "Tom Becker",
            timestamp: "2026-09-22T09:09:01Z", content: "agenda posted"))
        XCTAssertEqual(
            scroll.consumeTail(
                currentTailID: messages.last?.id,
                isOwnTail: messages.last?.isOwn ?? false),
            .follow)
        XCTAssertEqual(scroll.unseenCount(messages: messages), 0)
        XCTAssertNil(ScrollPolicy.bottomAction(
            unseen: scroll.unseenCount(messages: messages),
            nearBottom: scroll.nearBottom))
        XCTAssertEqual(
            MeetingChatPanel.landingTarget(tailID: messages.last?.id),
            ScrollPolicy.bottomSentinelID)
    }
}
