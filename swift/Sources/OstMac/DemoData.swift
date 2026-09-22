// DemoData.swift — canned chats/messages for `OstMac --demo` (offline).
import Foundation
import OstMacCore

enum DemoData {
    static let designID = "demo-design"
    static let priyaID = "demo-priya"
    static let standupID = "demo-standup"

    static func chatsResponse() throws -> ChatsResponse {
        try decodeOrThrow(ChatsResponse.self, from: Data(chatsJSON.utf8))
    }

    static func messages(for chatID: String) -> [ChatMessage] {
        switch chatID {
        case designID: ConversationStore.demoMessages
        case priyaID: priyaMessages
        case standupID: standupMessages
        default: []
        }
    }

    static func name(for chatID: String) -> String? {
        switch chatID {
        case designID: "Design Sync"
        case priyaID: "Priya Nair"
        case standupID: "Team Standup"
        default: nil
        }
    }

    private static let chatsJSON = """
        {"ok":true,"chats":[
        {"id":"demo-design","name":"Design Sync","is_group":true,
         "last_message_time":"2026-09-22T09:12:05Z",
         "last_message_sender":"Priya Nair",
         "last_message_preview":"Ship it. Screenshots for the review deck."},
        {"id":"demo-priya","name":"Priya Nair","is_group":false,
         "last_message_time":"2026-09-22T08:41:20Z",
         "last_message_sender":"Priya Nair",
         "last_message_preview":"Can you review the empty-states mock?"},
        {"id":"demo-standup","name":"Team Standup","is_group":true,
         "last_message_time":"2026-09-21T17:02:44Z",
         "last_message_sender":"Tom Becker",
         "last_message_preview":"Blocked on API keys, pairing tomorrow."}
        ]}
        """

    private static let priyaMessages: [ChatMessage] = [
        ChatMessage(
            id: "priya-1", sender: "Priya Nair",
            timestamp: "2026-09-22T08:37:02Z",
            content: "Morning! Can you review the empty-states mock when you get a chance?"),
        ChatMessage(
            id: "priya-2", sender: "Me",
            timestamp: "2026-09-22T08:39:51Z",
            content: "Sure — looking now. The illustration is great.", isOwn: true),
        ChatMessage(
            id: "priya-3", sender: "Priya Nair",
            timestamp: "2026-09-22T08:41:20Z",
            content: "Can you review the empty-states mock?"),
    ]

    private static let standupMessages: [ChatMessage] = [
        ChatMessage(
            id: "standup-1", sender: "Tom Becker",
            timestamp: "2026-09-21T17:01:10Z",
            content: "Update: sidebar done, conversation view in review."),
        ChatMessage(
            id: "standup-2", sender: "Tom Becker",
            timestamp: "2026-09-21T17:02:44Z",
            content: "Blocked on API keys, pairing tomorrow."),
    ]
}
