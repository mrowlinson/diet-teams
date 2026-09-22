// DemoData.swift — om-app-union: ONE canned dataset for `OstMac --demo`.
// Merges the om-package sidebar rows (stable ids demo/demo-2/demo-3) with
// the om-integrate threads. Single source: chatsResponse()/messages()/name()
// all derive from `chats`; every row's preview/sender/time matches the
// last message of its thread.
import Foundation

public enum DemoData {
    public static let demoID = "demo"
    public static let avaID = "demo-2"
    public static let standupID = "demo-3"

    /// Sidebar rows. [0] is "demo" (matches ConversationStore.demo()).
    public static let chats: [ChatItem] = [
        ChatItem(
            chatId: "demo", name: "Demo — Design Sync", is_group: true,
            last_message_time: "2026-09-22T09:12:05Z",
            last_message_sender: "Priya Nair",
            last_message_preview: "Ship it. I'll take screenshots for the review deck."),
        ChatItem(
            chatId: "demo-2", name: "Ava Lindqvist",
            last_message_time: "2026-09-22T08:47:33Z",
            last_message_sender: "Ava Lindqvist",
            last_message_preview: "Standup moved to 10 — see you there."),
        ChatItem(
            chatId: "demo-3", name: "Platform Standup", is_group: true,
            last_message_time: "2026-09-21T16:20:11Z",
            last_message_sender: "Tom Becker",
            last_message_preview: "Build is green, packaging lane is next."),
    ]

    public static func chatsResponse() -> ChatsResponse {
        ChatsResponse(ok: true, chats: chats)
    }

    public static func messages(for chatID: String) -> [ChatMessage] {
        switch chatID {
        case demoID: ConversationStore.demoMessages
        case avaID: avaMessages
        case standupID: standupMessages
        default: []
        }
    }

    public static func name(for chatID: String) -> String? {
        chats.first { $0.id == chatID }?.name
    }

    private static let avaMessages: [ChatMessage] = [
        ChatMessage(
            id: "ava-1", sender: "Ava Lindqvist",
            timestamp: "2026-09-22T08:41:02Z",
            content: "Morning! Can you review the empty-states mock when you get a chance?"),
        ChatMessage(
            id: "ava-2", sender: "Me",
            timestamp: "2026-09-22T08:44:51Z",
            content: "Sure — looking now. The illustration is great.", isOwn: true),
        ChatMessage(
            id: "ava-3", sender: "Ava Lindqvist",
            timestamp: "2026-09-22T08:47:33Z",
            content: "Standup moved to 10 — see you there."),
    ]

    private static let standupMessages: [ChatMessage] = [
        ChatMessage(
            id: "standup-1", sender: "Tom Becker",
            timestamp: "2026-09-21T16:18:02Z",
            content: "Update: sidebar done, conversation view in review."),
        ChatMessage(
            id: "standup-2", sender: "Tom Becker",
            timestamp: "2026-09-21T16:20:11Z",
            content: "Build is green, packaging lane is next."),
    ]
}
