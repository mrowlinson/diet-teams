// ChatListTests.swift — ViewModel states/selection + format helpers (mocked fetch).
import Combine
import XCTest

import OstMacChatList
@testable import OstMacCore

/// Sendable box for asserting the limit crossed the detached-task boundary.
private final class LimitBox: @unchecked Sendable {
    var value: Int32 = -1
}

@MainActor
final class ChatListTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func chatsJSON(_ chats: String) -> ChatsResponse {
        let json = #"{"ok":true,"chats":[\#(chats)]}"#
        return try! decodeOrThrow(ChatsResponse.self, from: Data(json.utf8))
    }

    nonisolated static func chatJSON(
        id: String, name: String, group: Bool = false,
        time: String? = nil, sender: String? = nil, preview: String? = nil
    ) -> String {
        func str(_ v: String?) -> String {
            v.map { #""\#($0)""# } ?? "null"
        }
        return #"{"id":"\#(id)","name":"\#(name)","is_group":\#(group ? "true" : "false"),"# +
            #""last_message_time":\#(str(time)),"# +
            #""last_message_sender":\#(str(sender)),"# +
            #""last_message_preview":\#(str(preview))}"#
    }

    // MARK: - ViewModel states

    func testLoadPopulatesChats() async {
        let response = Self.chatsJSON([
            Self.chatJSON(id: "19:a@thread", name: "Grp", group: true),
            Self.chatJSON(id: "8:b", name: "Solo"),
        ].joined(separator: ","))
        let model = ChatListViewModel(fetcher: { _ in response })
        XCTAssertEqual(model.state, .loading)
        await model.load()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.chats.count, 2)
        XCTAssertEqual(model.chats[0].name, "Grp")
    }

    func testLoadEmpty() async {
        let model = ChatListViewModel(fetcher: { _ in Self.chatsJSON("") })
        await model.load()
        XCTAssertEqual(model.state, .empty)
        XCTAssertTrue(model.chats.isEmpty)
    }

    func testLoadError() async {
        let model = ChatListViewModel(fetcher: { _ -> ChatsResponse in
            throw CoreCallError.failed("boom")
        })
        await model.load()
        XCTAssertEqual(model.state, .error("boom"))
    }

    func testLoadPassesLimit() async {
        let seen = LimitBox()
        let model = ChatListViewModel(fetcher: {
            seen.value = $0
            return Self.chatsJSON("")
        })
        await model.load(limit: 7)
        XCTAssertEqual(seen.value, 7)
    }

    // MARK: - Selection

    func testSelectionKeptWhenPresent() async {
        let response = Self.chatsJSON(Self.chatJSON(id: "8:b", name: "Solo"))
        let model = ChatListViewModel(fetcher: { _ in response })
        model.selectedChatID = "8:b"
        await model.load()
        XCTAssertEqual(model.selectedChatID, "8:b")
        XCTAssertEqual(model.selectedChat?.name, "Solo")
    }

    func testSelectionClearedWhenMissing() async {
        let response = Self.chatsJSON(Self.chatJSON(id: "8:b", name: "Solo"))
        let model = ChatListViewModel(fetcher: { _ in response })
        model.selectedChatID = "19:gone@thread"
        await model.load()
        XCTAssertNil(model.selectedChatID)
        XCTAssertNil(model.selectedChat)
    }

    func testSelectedChatNilWhenUnselected() {
        let model = ChatListViewModel(fetcher: { _ in Self.chatsJSON("") })
        XCTAssertNil(model.selectedChat)
    }

    // MARK: - Realtime ingest

    nonisolated static func realtime(
        chat: String, text: String = "live hello",
        sender: String = "S", time: String = "2026-09-22T10:00:00Z",
        edit: Bool = false, edited: String? = nil
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chat, msgId: "m-live", sender: sender,
            text: text, time: time, isEdit: edit, editedID: edited)
    }

    nonisolated static func twoChats() -> ChatsResponse {
        chatsJSON([
            chatJSON(
                id: "8:a", name: "A", time: "2026-09-22T09:00:00Z",
                sender: "Ann", preview: "old a"),
            chatJSON(
                id: "8:b", name: "B", time: "2026-09-22T08:00:00Z",
                sender: "Bob", preview: "old b"),
        ].joined(separator: ","))
    }

    func testIngestUpdatesPreviewAndMovesToTop() async {
        let model = ChatListViewModel(fetcher: { _ in Self.twoChats() })
        await model.load()
        model.ingest(realtime: Self.realtime(chat: "8:b", text: "live hello"))
        XCTAssertEqual(model.chats.map(\.id), ["8:b", "8:a"])
        XCTAssertEqual(model.chats[0].last_message_preview, "live hello")
        XCTAssertEqual(model.chats[0].last_message_sender, "S")
        XCTAssertEqual(model.chats[0].last_message_time, "2026-09-22T10:00:00Z")
        XCTAssertEqual(model.state, .loaded)
    }

    func testIngestUnknownChatIsNoop() async {
        let model = ChatListViewModel(fetcher: { _ in Self.twoChats() })
        await model.load()
        model.ingest(realtime: Self.realtime(chat: "8:ghost"))
        XCTAssertEqual(model.chats.map(\.id), ["8:a", "8:b"])
        XCTAssertEqual(model.chats[0].last_message_preview, "old a")
    }

    func testIngestEditUpdatesInPlaceWithoutReorder() async {
        let model = ChatListViewModel(fetcher: { _ in Self.twoChats() })
        await model.load()
        model.ingest(realtime: Self.realtime(
            chat: "8:b", text: "fixed", edit: true, edited: "m1"))
        XCTAssertEqual(model.chats.map(\.id), ["8:a", "8:b"])
        XCTAssertEqual(model.chats[1].last_message_preview, "fixed")
    }

    func testIngestKeepsSelection() async {
        let model = ChatListViewModel(fetcher: { _ in Self.twoChats() })
        model.selectedChatID = "8:a"
        await model.load()
        model.ingest(realtime: Self.realtime(chat: "8:b"))
        XCTAssertEqual(model.selectedChatID, "8:a")
        XCTAssertEqual(model.selectedChat?.name, "A")
    }

    // MARK: - Format: previewTime

    nonisolated static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    nonisolated static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testPreviewTimeNilAndBlank() {
        XCTAssertEqual(ChatListFormat.previewTime(nil), "")
        XCTAssertEqual(ChatListFormat.previewTime("  "), "")
    }

    func testPreviewTimePassthroughWhenUnparseable() {
        XCTAssertEqual(ChatListFormat.previewTime("t"), "t")
        XCTAssertEqual(ChatListFormat.previewTime("  yesterday-ish "), "yesterday-ish")
    }

    func testPreviewTimeToday() {
        let now = Self.date("2026-09-22T15:00:00Z")
        XCTAssertEqual(
            ChatListFormat.previewTime("2026-09-22T10:05:00Z", now: now, calendar: Self.utc),
            "10:05")
        XCTAssertEqual(
            ChatListFormat.previewTime("2026-09-22T10:05:00.123Z", now: now, calendar: Self.utc),
            "10:05")
    }

    func testPreviewTimeThisWeek() {
        let now = Self.date("2026-09-22T15:00:00Z") // a Tuesday
        let got = ChatListFormat.previewTime(
            "2026-09-20T10:05:00Z", now: now, calendar: Self.utc)
        XCTAssertEqual(got, "Sun")
    }

    func testPreviewTimeOlder() {
        let now = Self.date("2026-09-22T15:00:00Z")
        XCTAssertEqual(
            ChatListFormat.previewTime("2026-08-01T10:05:00Z", now: now, calendar: Self.utc),
            "8/1")
    }

    // MARK: - Format: filter

    nonisolated static func items() -> [ChatItem] {
        let r = chatsJSON([
            chatJSON(id: "1", name: "Team Standup", sender: "Ann", preview: "daily sync"),
            chatJSON(id: "2", name: "Bob", sender: "Bob", preview: "lunch?"),
            chatJSON(id: "3", name: "Random", preview: "standup notes"),
        ].joined(separator: ","))
        return r.chats
    }

    func testFilterBlankReturnsAll() {
        let items = Self.items()
        XCTAssertEqual(ChatListFormat.filter(items, query: "").count, 3)
        XCTAssertEqual(ChatListFormat.filter(items, query: "   ").count, 3)
    }

    func testFilterMatchesNameSenderPreview() {
        let items = Self.items()
        XCTAssertEqual(ChatListFormat.filter(items, query: "standup").map(\.id), ["1", "3"])
        XCTAssertEqual(ChatListFormat.filter(items, query: "BOB").map(\.id), ["2"])
        XCTAssertEqual(ChatListFormat.filter(items, query: "lunch").map(\.id), ["2"])
        XCTAssertTrue(ChatListFormat.filter(items, query: "zzz").isEmpty)
    }

    // MARK: - Format: previewLine

    func testPreviewLine() {
        XCTAssertEqual(
            ChatListFormat.previewLine(sender: "Ann", preview: "hi there"),
            "Ann: hi there")
        XCTAssertEqual(ChatListFormat.previewLine(sender: nil, preview: "hi"), "hi")
        XCTAssertEqual(ChatListFormat.previewLine(sender: "Ann", preview: nil), "Ann")
        XCTAssertEqual(ChatListFormat.previewLine(sender: nil, preview: nil), "")
        XCTAssertEqual(ChatListFormat.previewLine(sender: " ", preview: "  "), "")
    }

    // MARK: - Sidebar churn (om-sidebarchurn)

    nonisolated static func evt(
        chat: String, text: String, sender: String = "S",
        senderID: String? = nil, type: String? = nil,
        edit: Bool = false, reactions: [ReactionCount]? = nil,
        raw: String? = nil
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chat, msgId: UUID().uuidString, sender: sender,
            senderID: senderID, text: text,
            time: "2026-09-23T10:00:00Z", isEdit: edit,
            raw: raw, reactions: reactions, messageType: type)
    }

    static func churnModel() -> ChatListViewModel {
        ChatListViewModel(fetcher: { _ in DemoData.churnChatsResponse() })
    }

    /// Beacons, blobs, bookends, media cards, and reaction-only patches
    /// leave every row byte-identical (stable identity, no publish).
    func testChurnSkipsBeaconsBlobsCardsAndReactionOnly() async {
        let model = Self.churnModel()
        await model.load()
        let before = model.chats
        let meeting = DemoData.churnMeetingID
        let skips: [RealtimeMessage] = [
            Self.evt(chat: meeting, text: "Sprint PlanningPlay", sender: "?", type: "Text"),
            Self.evt(
                chat: meeting, text: #"{"scopeId":"s","storageId":"t","meetingTenantId":"m"}"#,
                sender: "?", type: "Text"),
            Self.evt(
                chat: meeting, text: "Hi! I'm here to help with the meeting.",
                sender: "Facilitator", type: "Text"),
            Self.evt(
                chat: meeting, text: "Q3 Review recording",
                sender: "?", type: "RichText/Media_Card"),
            Self.evt(
                chat: DemoData.churnSyncID, text: "",
                sender: "Tom Becker", type: "RichText/Html",
                reactions: [ReactionCount(emoji: "👍", count: 2)]),
            Self.evt(chat: "8:ghost", text: "live hello"),
        ]
        for m in skips { model.ingest(realtime: m) }
        XCTAssertEqual(model.chats, before)
        model.ingest(batch: skips)
        XCTAssertEqual(model.chats, before)
    }

    /// Bots, system notices, and edits refresh the preview in place:
    /// no reorder, no "?:" prefix on unattributed notices.
    func testChurnBotSystemRefreshInPlace() async {
        let model = Self.churnModel()
        await model.load()
        let order = model.chats.map(\.id)
        model.ingest(realtime: Self.evt(
            chat: DemoData.churnPollyID, text: "Megan voted: Thursday works best",
            sender: "Polly", senderID: "28:00001111-2222-3333-4444-555566667777",
            type: "Text"))
        model.ingest(realtime: Self.evt(
            chat: DemoData.churnStandupID, text: "Tom Becker added Megan Harper to the chat",
            sender: "?", type: "ThreadActivity/AddMember"))
        model.ingest(realtime: Self.evt(
            chat: DemoData.churnSyncID, text: "Facilitator residue stays put",
            sender: "Facilitator", type: "Text"))
        XCTAssertEqual(model.chats.map(\.id), order)
        let polly = model.chats.first { $0.id == DemoData.churnPollyID }!
        XCTAssertEqual(polly.last_message_preview, "Megan voted: Thursday works best")
        XCTAssertEqual(polly.last_message_sender, "Polly")
        let standup = model.chats.first { $0.id == DemoData.churnStandupID }!
        XCTAssertEqual(standup.last_message_preview, "Tom Becker added Megan Harper to the chat")
        XCTAssertNil(standup.last_message_sender)
        let sync = model.chats.first { $0.id == DemoData.churnSyncID }!
        XCTAssertEqual(sync.last_message_preview, "Facilitator residue stays put")
    }

    /// Meeting previews are last user text: mixed cards refresh in place
    /// with their human lines, chrome-only cards hold the row, and real
    /// user text (even multi-line) still bubbles.
    func testChurnMeetingPreviewIsHumanCardLines() async {
        let model = Self.churnModel()
        await model.load()
        let meeting = DemoData.churnMeetingID
        let order = model.chats.map(\.id)
        model.ingest(realtime: Self.evt(
            chat: meeting, text: "{\n\"scopeId\": \"s\"\n}\nStandup notes are posted in the thread",
            sender: "?", type: "Text"))
        XCTAssertEqual(model.chats.map(\.id), order)
        XCTAssertEqual(
            model.chats.first?.last_message_preview,
            "Standup notes are posted in the thread")
        XCTAssertNil(model.chats.first?.last_message_sender)
        // Chrome-only cards: row (preview + sender) untouched, whether
        // valid JSON (structural skip) or broken brackets (no human
        // lines — the row keeps its last user text).
        let held = model.chats
        model.ingest(realtime: Self.evt(
            chat: meeting, text: "{\n\"scopeId\": \"s\"\n}",
            sender: "?", type: "Text"))
        XCTAssertEqual(model.chats, held)
        model.ingest(realtime: Self.evt(
            chat: meeting, text: "{\n[broken\n}",
            sender: "?", type: "Text"))
        XCTAssertEqual(model.chats, held)
        // Real user text bubbles with its full text.
        model.ingest(realtime: Self.evt(
            chat: meeting, text: "Starting now,\njoin when ready",
            sender: "Megan Harper", type: "Text"))
        XCTAssertEqual(model.chats.first?.id, meeting)
        XCTAssertEqual(
            model.chats.first?.last_message_preview,
            "Starting now, join when ready")
        // Human JSON paste in a normal chat still surfaces (status quo).
        model.ingest(realtime: Self.evt(
            chat: DemoData.churnSyncID, text: #"{"a":1}"#,
            sender: "Tom Becker", type: "Text"))
        XCTAssertEqual(model.chats.first?.id, DemoData.churnSyncID)
    }

    /// Image-only messages bubble with a sender-line preview; human
    /// text in any thread bubbles; unknown types bubble (old cores).
    func testChurnSurfacesImagesAndUnknownTypes() {
        let list = DemoData.churnChatsResponse().chats
        let img = ChatListViewModel.ingested(
            Self.evt(
                chat: DemoData.churnSyncID, text: "", sender: "Tom Becker",
                type: "RichText/Html", raw: #"<p><img src="https://h/v1/imgo"></p>"#),
            into: list)
        XCTAssertEqual(img.first?.id, DemoData.churnSyncID)
        XCTAssertEqual(img.first?.last_message_preview, "")
        let unknown = ChatListViewModel.ingested(
            Self.evt(chat: DemoData.churnPollyID, text: "untyped hello"),
            into: list)
        XCTAssertEqual(unknown.first?.id, DemoData.churnPollyID)
    }

    func testHumanLines() {
        XCTAssertEqual(SidebarIngest.humanLines("single"), "single")
        XCTAssertEqual(
            SidebarIngest.humanLines("first\nsecond"),
            "first second")
        XCTAssertEqual(
            SidebarIngest.humanLines("{\n\"k\": \"v\"\n}\nHuman line here"),
            "Human line here")
        XCTAssertNil(SidebarIngest.humanLines("{\n\"k\": \"v\"\n}"))
        XCTAssertNil(SidebarIngest.humanLines("  \n "))
        XCTAssertEqual(
            SidebarIngest.decide(
                message: Self.evt(chat: "19:meeting_x@thread.v2", text: "hi"),
                chatName: "M"),
            .bubble)
        XCTAssertEqual(
            SidebarIngest.decide(
                message: Self.evt(
                    chat: "19:meeting_x@thread.v2", text: "MPlay",
                    sender: "?", type: "Text"),
                chatName: "M"),
            .skip)
    }

    /// The demo burst folds to a stable order with ONE publish: only the
    /// user-active chat moves; selection survives; a beacons-only batch
    /// publishes nothing.
    func testChurnBurstCoalescesToOnePublish() async {
        let model = Self.churnModel()
        await model.load()
        model.selectedChatID = DemoData.churnStandupID
        var publishes = 0
        let sub = model.$chats.dropFirst().sink { _ in publishes += 1 }
        model.ingest(batch: DemoData.churnBurst())
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(
            model.chats.map(\.id),
            [DemoData.churnSyncID, DemoData.churnMeetingID,
             DemoData.churnPollyID, DemoData.churnStandupID])
        XCTAssertEqual(
            model.chats[0].last_message_preview,
            "Recording is up — link in the thread (fixed)")
        XCTAssertEqual(
            model.chats[1].last_message_preview,
            "Standup notes are posted in the thread")
        XCTAssertNil(model.chats[1].last_message_sender)
        XCTAssertEqual(
            model.chats[2].last_message_preview,
            "Megan voted: Thursday works best")
        XCTAssertEqual(
            model.chats[3].last_message_preview,
            "Tom Becker added Megan Harper to the chat")
        XCTAssertEqual(model.selectedChatID, DemoData.churnStandupID)
        model.ingest(batch: Array(DemoData.churnBurst().prefix(5)))
        XCTAssertEqual(publishes, 1)
        withExtendedLifetime(sub) {}
    }
}
