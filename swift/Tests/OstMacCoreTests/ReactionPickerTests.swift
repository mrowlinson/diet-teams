// ReactionPickerTests.swift — om-react-polish lane: more-picker
// catalog/search/recents plus the widened Swift-side acceptance
// (any single emoji reacts; live sends stay canonical-only).
import XCTest

@testable import OstMacCore

@MainActor
final class ReactionPickerTests: XCTestCase {
    // MARK: - Acceptance

    func testIsReactableSingleGraphemeOnly() {
        XCTAssertTrue(ConversationStore.isReactable("👍"))
        XCTAssertTrue(ConversationStore.isReactable("🎉"))
        // Flag, ZWJ sequence, and modifier sequence are one Character.
        XCTAssertTrue(ConversationStore.isReactable("🇫🇷"))
        XCTAssertTrue(ConversationStore.isReactable("👨‍👩‍👧"))
        XCTAssertTrue(ConversationStore.isReactable("👍🏽"))
        XCTAssertFalse(ConversationStore.isReactable(""))
        XCTAssertFalse(ConversationStore.isReactable("ab"))
        XCTAssertFalse(ConversationStore.isReactable("👍👍"))
    }

    func testExtendedEmojiTogglesInDemo() {
        let store = ConversationStore.demo()
        let id = store.messages[0].id
        store.toggleReaction(messageID: id, emoji: "🎉")
        XCTAssertEqual(
            store.messages[0].reactions, [ReactionCount(emoji: "🎉", count: 1)])
        store.toggleReaction(messageID: id, emoji: "🎉")
        XCTAssertTrue(store.messages[0].reactions.isEmpty)
    }

    func testExtendedEmojiRefusedLiveWithClearError() {
        let store = ConversationStore()
        store.ingest(realtime: RealtimeMessage(
            chatID: "c", msgId: "live-1", sender: "A",
            text: "hi", time: "t", isEdit: false))
        store.toggleReaction(messageID: "live-1", emoji: "🎉")
        // Synchronously undone: nothing sticks, and the error names Teams.
        XCTAssertTrue(store.messages[0].reactions.isEmpty)
        XCTAssertTrue(store.error?.contains("Teams") ?? false)
    }

    func testCanonicalLiveWithoutChatStaysApplied() {
        // No chatID yet: canonical applies and waits (pre-existing path).
        let store = ConversationStore()
        store.ingest(realtime: RealtimeMessage(
            chatID: "c", msgId: "live-1", sender: "A",
            text: "hi", time: "t", isEdit: false))
        store.toggleReaction(messageID: "live-1", emoji: "👍")
        XCTAssertEqual(
            store.messages[0].reactions, [ReactionCount(emoji: "👍", count: 1)])
        XCTAssertNil(store.error)
    }

    // MARK: - Catalog

    func testCatalogEntriesAreSingleCharacters() {
        XCTAssertFalse(ReactionCatalog.categories.isEmpty)
        for e in ReactionCatalog.all {
            XCTAssertEqual(e.emoji.count, 1, "not single: \(e.emoji)")
            XCTAssertFalse(e.keywords.isEmpty)
        }
    }

    func testCatalogCoversCanonicalSix() {
        for e in ConversationStore.reactionEmojis {
            XCTAssertTrue(ReactionCatalog.contains(e), "missing: \(e)")
        }
        // Category lookup resolves, unknown ids do not.
        XCTAssertNotNil(ReactionCatalog.entries(forCategory: "faces"))
        XCTAssertNil(ReactionCatalog.entries(forCategory: "nope"))
    }

    func testSearchMatchesKeywordsCaseInsensitively() {
        let party = ReactionCatalog.search("party").map(\.emoji)
        XCTAssertTrue(party.contains("🎉"))
        XCTAssertTrue(party.contains("🥳"))
        XCTAssertEqual(
            ReactionCatalog.search("PARTY").map(\.emoji), party)
        // Multi-term AND: hearts + eyes narrows to 😍.
        XCTAssertEqual(
            ReactionCatalog.search("hearts eyes").map(\.emoji), ["😍"])
        XCTAssertTrue(ReactionCatalog.search("zzz-no-match").isEmpty)
        XCTAssertTrue(ReactionCatalog.search("   ").isEmpty)
    }

    // MARK: - Recents

    func testRecentsMoveToFrontDedupAndCap() {
        XCTAssertEqual(
            ReactionRecents.withRecorded([], emoji: "👍"), ["👍"])
        XCTAssertEqual(
            ReactionRecents.withRecorded(["👍", "❤️"], emoji: "❤️"),
            ["❤️", "👍"])
        let full = (0 ..< ReactionRecents.maxCount).map { "\($0)" }
        let capped = ReactionRecents.withRecorded(full, emoji: "new")
        XCTAssertEqual(capped.count, ReactionRecents.maxCount)
        XCTAssertEqual(capped.first, "new")
        XCTAssertFalse(capped.contains("11"))
    }

    func testRecentsDefaultsRoundTripFiltersJunk() {
        let suite = "om.reactpolish.test"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("no suite defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["👍", "", "ab"], forKey: ReactionRecents.defaultsKey)
        XCTAssertEqual(ReactionRecents.load(defaults: defaults), ["👍"])
        ReactionRecents.record("🎉", defaults: defaults)
        XCTAssertEqual(
            ReactionRecents.load(defaults: defaults), ["🎉", "👍"])
        // Non-emoji never records.
        ReactionRecents.record("", defaults: defaults)
        XCTAssertEqual(
            ReactionRecents.load(defaults: defaults), ["🎉", "👍"])
    }
}
