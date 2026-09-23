// PinnedChatsTests.swift — om-pin-top: Mentions/Notifications pinned above recency.
import XCTest

import OstMacChatList
@testable import OstMacCore

@MainActor
final class PinnedChatsTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func chat(
        id: String, name: String, preview: String? = nil
    ) -> ChatItem {
        ChatItem(
            chatId: id, name: name,
            last_message_time: "2026-09-22T09:00:00Z",
            last_message_sender: "S",
            last_message_preview: preview ?? "hi")
    }

    nonisolated static func response(_ chats: [ChatItem]) -> ChatsResponse {
        ChatsResponse(ok: true, chats: chats)
    }

    nonisolated static func live(
        chat: String, text: String = "live hello"
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chat, msgId: "m-live", sender: "S",
            text: text, time: "2026-09-22T10:00:00Z", isEdit: false)
    }

    // MARK: - Synthetic identity

    func testSyntheticIDsAreStableAndDistinct() {
        XCTAssertFalse(PinnedChats.mentionsID.isEmpty)
        XCTAssertFalse(PinnedChats.notificationsID.isEmpty)
        XCTAssertNotEqual(PinnedChats.mentionsID, PinnedChats.notificationsID)
        XCTAssertTrue(PinnedChats.isSynthetic(PinnedChats.mentionsID))
        XCTAssertTrue(PinnedChats.isSynthetic(PinnedChats.notificationsID))
        XCTAssertFalse(PinnedChats.isSynthetic("8:a"))
        XCTAssertFalse(PinnedChats.isSynthetic("19:meeting@thread.v2"))
        XCTAssertFalse(PinnedChats.isSynthetic("demo"))
        XCTAssertFalse(PinnedChats.isSynthetic(""))
    }

    func testFactoryRows() {
        XCTAssertEqual(PinnedChats.mentionsRow.id, PinnedChats.mentionsID)
        XCTAssertEqual(PinnedChats.mentionsRow.name, "Mentions")
        XCTAssertEqual(PinnedChats.notificationsRow.id, PinnedChats.notificationsID)
        XCTAssertEqual(PinnedChats.notificationsRow.name, "Notifications")
        // Group-marked: no 1:1 presence dot on synthetic rows.
        XCTAssertTrue(PinnedChats.mentionsRow.is_group)
        XCTAssertTrue(PinnedChats.notificationsRow.is_group)
    }

    func testRowForID() {
        XCTAssertEqual(
            PinnedChats.row(for: PinnedChats.mentionsID)?.name, "Mentions")
        XCTAssertEqual(
            PinnedChats.row(for: PinnedChats.notificationsID)?.name, "Notifications")
        XCTAssertNil(PinnedChats.row(for: "8:a"))
        XCTAssertNil(PinnedChats.row(for: ""))
    }

    // MARK: - Comparator

    func testComparatorRanksPinnedAboveRecency() {
        let mentions = PinnedChats.mentionsRow
        let notifs = PinnedChats.notificationsRow
        let a = Self.chat(id: "8:a", name: "A")
        let b = Self.chat(id: "8:b", name: "B")
        XCTAssertTrue(PinnedChats.orderedBefore(mentions, notifs))
        XCTAssertFalse(PinnedChats.orderedBefore(notifs, mentions))
        XCTAssertTrue(PinnedChats.orderedBefore(mentions, a))
        XCTAssertTrue(PinnedChats.orderedBefore(notifs, a))
        XCTAssertFalse(PinnedChats.orderedBefore(a, mentions))
        XCTAssertFalse(PinnedChats.orderedBefore(a, notifs))
        // Real chats never reorder each other here (stable partition keeps recency).
        XCTAssertFalse(PinnedChats.orderedBefore(a, b))
        XCTAssertFalse(PinnedChats.orderedBefore(b, a))
    }

    func testRank() {
        XCTAssertEqual(PinnedChats.rank(of: PinnedChats.mentionsID), 0)
        XCTAssertEqual(PinnedChats.rank(of: PinnedChats.notificationsID), 1)
        XCTAssertEqual(PinnedChats.rank(of: "8:a"), 2)
        XCTAssertEqual(PinnedChats.rank(of: ""), 2)
    }

    // MARK: - Sort invariant

    func testSortedPinsOrderThenRecency() {
        let b = Self.chat(id: "8:b", name: "B")
        let a = Self.chat(id: "8:a", name: "A")
        let out = PinnedChats.sorted([b, a])
        XCTAssertEqual(
            out.map(\.id),
            [PinnedChats.mentionsID, PinnedChats.notificationsID, "8:b", "8:a"])
        // Input order (recency) passes through untouched.
        XCTAssertEqual(
            Array(PinnedChats.sorted([a, b]).map(\.id)[2...]), ["8:a", "8:b"])
    }

    func testSortedEmptyYieldsOnlyPinned() {
        XCTAssertEqual(
            PinnedChats.sorted([]).map(\.id),
            [PinnedChats.mentionsID, PinnedChats.notificationsID])
    }

    func testSortedIdempotentAndDedupes() {
        let input = [
            Self.chat(id: "8:b", name: "B"),
            Self.chat(id: "8:b", name: "B-dup"),
            PinnedChats.mentionsRow,
            Self.chat(id: "8:a", name: "A"),
            PinnedChats.notificationsRow,
            PinnedChats.mentionsRow,
        ]
        let once = PinnedChats.sorted(input)
        XCTAssertEqual(
            once.map(\.id),
            [PinnedChats.mentionsID, PinnedChats.notificationsID, "8:b", "8:a"])
        XCTAssertEqual(PinnedChats.sorted(once), once)
    }

    func testSortedPreservesIncomingSyntheticPreview() {
        let live = ChatItem(
            chatId: PinnedChats.mentionsID, name: "Mentions", is_group: true,
            last_message_time: "2026-09-22T10:00:00Z",
            last_message_sender: "Priya Nair",
            last_message_preview: "@you check the mocks")
        let out = PinnedChats.sorted([Self.chat(id: "8:a", name: "A"), live])
        XCTAssertEqual(out[0].last_message_preview, "@you check the mocks")
        XCTAssertEqual(out[0].last_message_sender, "Priya Nair")
        XCTAssertEqual(
            out.map(\.id),
            [PinnedChats.mentionsID, PinnedChats.notificationsID, "8:a"])
    }

    // MARK: - ViewModel projection

    func testDisplayChatsAfterLoad() async {
        let model = ChatListViewModel(fetcher: { _ in
            Self.response([
                Self.chat(id: "8:a", name: "A"),
                Self.chat(id: "8:b", name: "B"),
            ])
        })
        await model.load()
        XCTAssertEqual(model.state, .loaded)
        // Stored rows stay real-chats-only (existing contract).
        XCTAssertEqual(model.chats.map(\.id), ["8:a", "8:b"])
        XCTAssertEqual(
            model.displayChats.map(\.id),
            [PinnedChats.mentionsID, PinnedChats.notificationsID, "8:a", "8:b"])
    }

    func testPinSurvivesReorder() async {
        let model = ChatListViewModel(fetcher: { _ in
            Self.response([
                Self.chat(id: "8:a", name: "A"),
                Self.chat(id: "8:b", name: "B"),
            ])
        })
        await model.load()
        model.ingest(realtime: Self.live(chat: "8:b"))
        XCTAssertEqual(model.chats.map(\.id), ["8:b", "8:a"])
        XCTAssertEqual(
            model.displayChats.map(\.id),
            [PinnedChats.mentionsID, PinnedChats.notificationsID, "8:b", "8:a"])
    }

    func testPinSurvivesBatchIngest() async {
        let model = ChatListViewModel(fetcher: { _ in DemoData.churnChatsResponse() })
        await model.load()
        model.ingest(batch: DemoData.churnBurst())
        let ids = model.displayChats.map(\.id)
        XCTAssertEqual(Array(ids.prefix(2)), [PinnedChats.mentionsID, PinnedChats.notificationsID])
        XCTAssertEqual(
            Array(ids.dropFirst(2)),
            [DemoData.churnSyncID, DemoData.churnMeetingID,
             DemoData.churnPollyID, DemoData.churnStandupID])
    }

    // MARK: - Filter-clear + restart

    func testPinSurvivesFilterClear() async {
        let model = ChatListViewModel(fetcher: { _ in
            Self.response([
                Self.chat(id: "8:a", name: "Alice"),
                Self.chat(id: "8:b", name: "Bob"),
            ])
        })
        await model.load()
        let full = model.displayChats
        XCTAssertTrue(ChatListFormat.filter(full, query: "zzz").isEmpty)
        XCTAssertEqual(
            ChatListFormat.filter(full, query: "bob").map(\.id), ["8:b"])
        XCTAssertEqual(
            ChatListFormat.filter(full, query: "mentions").map(\.id),
            [PinnedChats.mentionsID])
        // Clearing the filter restores the pinned order.
        XCTAssertEqual(ChatListFormat.filter(full, query: ""), full)
        XCTAssertEqual(ChatListFormat.filter(full, query: "   "), full)
        XCTAssertEqual(
            Array(ChatListFormat.filter(full, query: "").map(\.id).prefix(2)),
            [PinnedChats.mentionsID, PinnedChats.notificationsID])
    }

    func testPinSurvivesRestartRestore() async {
        func makeModel() -> ChatListViewModel {
            ChatListViewModel(fetcher: { _ in
                Self.response([
                    Self.chat(id: "8:a", name: "A"),
                    Self.chat(id: "8:b", name: "B"),
                ])
            })
        }
        let first = makeModel()
        await first.load()
        first.ingest(realtime: Self.live(chat: "8:b"))
        let before = first.displayChats.map(\.id)
        // Restart = a fresh instance over the same fetch: same pinned order.
        let second = makeModel()
        await second.load()
        second.ingest(realtime: Self.live(chat: "8:b"))
        XCTAssertEqual(second.displayChats.map(\.id), before)
        XCTAssertEqual(
            Array(before.prefix(2)),
            [PinnedChats.mentionsID, PinnedChats.notificationsID])
    }

    func testSyntheticSelectionSurvivesLoad() async {
        let model = ChatListViewModel(fetcher: { _ in
            Self.response([Self.chat(id: "8:a", name: "A")])
        })
        model.selectedChatID = PinnedChats.mentionsID
        await model.load()
        XCTAssertEqual(model.selectedChatID, PinnedChats.mentionsID)
        XCTAssertEqual(model.selectedChat?.name, "Mentions")
        model.selectedChatID = PinnedChats.notificationsID
        await model.load()
        XCTAssertEqual(model.selectedChatID, PinnedChats.notificationsID)
        XCTAssertEqual(model.selectedChat?.name, "Notifications")
    }

    // MARK: - Unread counts preserved

    func testUnreadCountsPreservedAcrossReorder() async {
        let dock = FakeDockBadge()
        let unread = UnreadStore(dock: dock)
        unread.ingest(
            decision: .notify(reason: "owner-mention"),
            chatID: PinnedChats.mentionsID, openChatID: nil)
        unread.ingest(
            decision: .notify(reason: "chat-message"),
            chatID: "8:b", openChatID: nil)
        let model = ChatListViewModel(fetcher: { _ in
            Self.response([
                Self.chat(id: "8:a", name: "A"),
                Self.chat(id: "8:b", name: "B"),
            ])
        })
        await model.load()
        // Reorder + batch churn never touch the counts.
        model.ingest(realtime: Self.live(chat: "8:b"))
        model.ingest(batch: [Self.live(chat: "8:a"), Self.live(chat: "8:b")])
        XCTAssertEqual(unread.count(for: PinnedChats.mentionsID), 1)
        XCTAssertEqual(unread.count(for: "8:b"), 1)
        XCTAssertEqual(unread.total, 2)
        // …and the pinned rows (badge anchors) are still on top.
        XCTAssertEqual(
            Array(model.displayChats.map(\.id).prefix(2)),
            [PinnedChats.mentionsID, PinnedChats.notificationsID])
        // Synthetic rows mark read like real chats.
        unread.markRead(chatID: PinnedChats.mentionsID)
        XCTAssertEqual(unread.count(for: PinnedChats.mentionsID), 0)
        XCTAssertEqual(unread.total, 1)
    }

    func testEmptyFetchKeepsExistingContract() async {
        let model = ChatListViewModel(fetcher: { _ in Self.response([]) })
        await model.load()
        XCTAssertEqual(model.state, .empty)
        XCTAssertTrue(model.chats.isEmpty)
    }

    // MARK: - Pin dedupe (om-pindedupe)

    func testDupNotificationsKeepsOnePinnedRow() {
        let real = Self.chat(id: "19:notify@thread.v2", name: "Notifications")
        XCTAssertEqual(PinnedChats.stableID(for: real), PinnedChats.notificationsID)
        let out = PinnedChats.sorted([Self.chat(id: "8:a", name: "A"), real])
        // Exactly one Notifications row: the real thread, pinned second.
        XCTAssertEqual(out.map(\.id), [PinnedChats.mentionsID, "19:notify@thread.v2", "8:a"])
        XCTAssertEqual(out[1].name, "Notifications")
        XCTAssertEqual(PinnedChats.sorted(out), out)
        // Counts key off the survivor's own id.
        let dock = FakeDockBadge()
        let unread = UnreadStore(dock: dock)
        unread.ingest(
            decision: .notify(reason: "chat-message"),
            chatID: real.id, openChatID: nil)
        XCTAssertEqual(unread.count(for: out[1].id), 1)
    }

    func testDupMentionsKeepsOnePinnedRow() async {
        let real = Self.chat(id: "8:m", name: "  MENTIONS ")
        XCTAssertEqual(PinnedChats.stableID(for: real), PinnedChats.mentionsID)
        let model = ChatListViewModel(fetcher: { _ in
            Self.response([Self.chat(id: "8:a", name: "A"), real])
        })
        await model.load()
        // Exactly one Mentions row: the real thread, pinned first —
        // and the pinned position survives recency bubbling.
        XCTAssertEqual(
            model.displayChats.map(\.id),
            ["8:m", PinnedChats.notificationsID, "8:a"])
        model.ingest(realtime: Self.live(chat: "8:a"))
        XCTAssertEqual(
            model.displayChats.map(\.id),
            ["8:m", PinnedChats.notificationsID, "8:a"])
        // Counts key off the survivor's own id.
        let mentions = MentionStore()
        mentions.adopt([real.id])
        XCTAssertEqual(mentions.count, 1)
        XCTAssertTrue(mentions.contains(chatID: model.displayChats[0].id))
    }

    func testNoDupKeepsFactoryRows() {
        let out = PinnedChats.sorted([
            Self.chat(id: "8:a", name: "A"),
            Self.chat(id: "8:b", name: "B"),
        ])
        XCTAssertEqual(
            out.map(\.id),
            [PinnedChats.mentionsID, PinnedChats.notificationsID, "8:a", "8:b"])
        // Near-misses never claim a slot.
        XCTAssertEqual(
            PinnedChats.stableID(for: Self.chat(id: "8:c", name: "Notification prefs")), "8:c")
        XCTAssertEqual(
            PinnedChats.stableID(for: Self.chat(id: "8:d", name: "My mentions digest")), "8:d")
        XCTAssertEqual(
            PinnedChats.stableID(for: Self.chat(id: "8:e", name: "  ")), "8:e")
    }
}
