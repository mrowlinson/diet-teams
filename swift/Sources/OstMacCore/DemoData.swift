// DemoData.swift — om-app-union: ONE canned dataset for `Diet Teams --demo`.
// Merges the om-package sidebar rows (stable ids demo/demo-2/demo-3) with
// the om-integrate threads. Single source: chatsResponse()/messages()/name()
// all derive from `chats`; every row's preview/sender/time matches the
// last message of its thread.
import Foundation

public enum DemoData {
    public static let demoID = "demo"
    public static let avaID = "demo-2"
    public static let standupID = "demo-3"
    public static let richID = "demo-rich"
    public static let mediaID = "demo-media"

    /// Sidebar rows. [0] is "demo" (matches ConversationStore.demo()).
    /// The rich row derives from the rich thread's last message, so its
    /// preview/sender/time track the floating Today timestamps.
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
        richChat(),
        mediaChat(),
    ]

    /// Rich sidebar row: preview/sender/time from the rich thread's tail.
    public static func richChat(now: Date = Date()) -> ChatItem {
        let msgs = ConversationStore.richDemoMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: richID, name: "Demo — Rich Conversation", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    /// Media sidebar row: preview/sender/time from the media thread's tail.
    public static func mediaChat(now: Date = Date()) -> ChatItem {
        let msgs = mediaMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: mediaID, name: "Demo — Photos & Emoji", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    public static func chatsResponse() -> ChatsResponse {
        ChatsResponse(ok: true, chats: chats)
    }

    /// Canned teams for `--demo` (om-teams lane). Channel ids route to
    /// `channelMessages` via `messages(for:)` so opening a channel shows
    /// a thread offline.
    public static let teams: [TeamItem] = [
        TeamItem(teamId: "demo-team-eng", name: "Engineering", channels: [
            TeamChannel(channelId: "demo-chan-general", name: "General"),
            TeamChannel(channelId: "demo-chan-shipping", name: "Shipping"),
        ]),
        TeamItem(teamId: "demo-team-design", name: "Design", channels: [
            TeamChannel(channelId: "demo-chan-crit", name: "Crit"),
        ]),
    ]

    public static func teamsResponse() -> TeamsResponse {
        TeamsResponse(ok: true, teams: teams)
    }

    /// Canned own presence for --demo (Available, offline adopted).
    public static func ownPresence() -> PresenceResponse {
        PresenceResponse(ok: true, availability: "Available", activity: "Available")
    }

    /// Canned chatmate pins for --demo: chatID → presence.
    /// Ava (the only 1:1 row) is Busy; groups carry no dots.
    public static func peerPresence() -> [String: UserPresenceResponse] {
        [avaID: UserPresenceResponse(
            ok: true, id: "ava-demo", availability: "Busy", activity: "InACall")]
    }

    public static func messages(for chatID: String) -> [ChatMessage] {
        switch chatID {
        case demoID: return ConversationStore.demoMessages
        case avaID: return avaMessages
        case standupID: return standupMessages
        case richID: return ConversationStore.richDemoMessages()
        case mediaID: return mediaMessages()
        default: break
        }
        if chatID.hasPrefix("demo-chan-") { return channelMessages }
        return []
    }

    /// Pre-failed bubble ids per demo chat (rich thread's failed own send).
    public static func failedIDs(for chatID: String) -> Set<String> {
        chatID == richID ? ["rich-fail"] : []
    }

    /// Canned shared files for `--demo` (om-shared lane). Design Sync has
    /// three (pdf + image + sheet, one with a sender); Ava has one; the
    /// rich thread and channels share the design set; standup is empty.
    public static func sharedFiles(for chatID: String) -> [SharedFile] {
        switch chatID {
        case demoID, richID: return designFiles
        case avaID: return [avaFile]
        case standupID: return []
        default:
            if chatID.hasPrefix("demo-chan-") { return designFiles }
            return []
        }
    }

    private static let designFiles: [SharedFile] = [
        SharedFile(
            id: "demo-f1", name: "onboarding-mocks.pdf", size: 48211,
            mime: "application/pdf",
            web_url: "https://example.sharepoint.com/onboarding-mocks.pdf",
            download_url: "https://example.sharepoint.com/download/onboarding-mocks.pdf",
            drive_id: "demo-drive-1",
            created: "2026-09-21T10:02:11Z", sender: "Tom Becker"),
        SharedFile(
            id: "demo-f2", name: "empty-states.png", size: 184320,
            mime: "image/png",
            web_url: "https://example.sharepoint.com/empty-states.png",
            download_url: "https://example.sharepoint.com/download/empty-states.png",
            drive_id: "demo-drive-1",
            created: "2026-09-22T08:41:02Z", sender: "Ava Lindqvist"),
        SharedFile(
            id: "demo-f3", name: "launch-checklist.xlsx", size: 9216,
            mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            web_url: "https://example.sharepoint.com/launch-checklist.xlsx",
            drive_id: "demo-drive-1",
            created: "2026-09-20T16:20:11Z", sender: "Priya Nair"),
    ]

    private static let avaFile = SharedFile(
        id: "demo-f-ava1", name: "standup-notes.md", size: 2048,
        mime: "text/markdown",
        web_url: "https://example.sharepoint.com/standup-notes.md",
        download_url: "https://example.sharepoint.com/download/standup-notes.md",
        drive_id: "demo-drive-2",
        created: "2026-09-22T08:47:33Z", sender: "Ava Lindqvist")

    public static func name(for chatID: String) -> String? {
        if let chat = chats.first(where: { $0.id == chatID }) { return chat.name }
        for team in teams {
            if let ch = team.channels.first(where: { $0.id == chatID }) {
                return "\(team.name) > #\(ch.name)"
            }
        }
        return nil
    }

    /// Rich-media thread (om-richmedia): unicode emoji, `(code)`
    /// shortcodes, a captioned photo, an image-only bubble, a broken-image
    /// failure, and an emoticon-sized reply. Fully offline (`demo://`
    /// fixtures). Timestamps float off now (Today).
    public static func mediaMessages(now: Date = Date()) -> [ChatMessage] {
        func iso(_ d: Date) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f.string(from: d)
        }
        func at(h: Int, m: Int) -> Date {
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            return cal.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now
        }
        return [
            ChatMessage(
                id: "media-1", sender: "Priya Nair",
                timestamp: iso(at(h: 9, m: 2)),
                content: "Ship day! 🚀 (party) the build is green",
                raw: "<p>Ship day! 🚀 (party) the build is green</p>"),
            ChatMessage(
                id: "media-2", sender: "Tom Becker",
                timestamp: iso(at(h: 9, m: 5)),
                content: "Sunset from the offsite 🌅",
                raw: #"<p>Sunset from the offsite 🌅</p><p><img src="demo://photo-1" alt="offsite sunset"></p>"#),
            ChatMessage(
                id: "media-3", sender: "Priya Nair",
                timestamp: iso(at(h: 9, m: 7)),
                content: "",
                raw: #"<p><img src="demo://photo-2" alt="lake dawn"></p>"#),
            ChatMessage(
                id: "media-4", sender: "Me",
                timestamp: iso(at(h: 9, m: 9)),
                content: "(thumbsup) Gorgeous (clap)",
                isOwn: true),
            ChatMessage(
                id: "media-5", sender: "Tom Becker",
                timestamp: iso(at(h: 9, m: 11)),
                content: "This upload never landed",
                raw: #"<p>This upload never landed</p><p><img src="demo://missing" alt="broken upload"></p>"#),
            ChatMessage(
                id: "media-6", sender: "Me",
                timestamp: iso(at(h: 9, m: 12)),
                content: "Resending the vibe instead",
                isOwn: true,
                raw: #"<p>Resending the vibe instead <img src="demo://photo-1" width="20" height="20" alt="(smile)"></p>"#),
        ]
    }

    /// Shared offline thread shown when a demo channel opens.
    private static let channelMessages: [ChatMessage] = [
        ChatMessage(
            id: "chan-m1", sender: "Priya Nair",
            timestamp: "2026-09-22T09:02:11Z",
            content: "Kickoff notes are pinned — goals, dates, owners."),
        ChatMessage(
            id: "chan-m2", sender: "Tom Becker",
            timestamp: "2026-09-22T09:10:44Z",
            content: "Build is green, packaging lane is next."),
    ]

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
