// ChatListTests.swift — ViewModel states/selection + format helpers (mocked fetch).
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
}
