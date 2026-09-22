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
    public static let richID = "demo-rich"

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
        default: break
        }
        if chatID.hasPrefix("demo-chan-") { return channelMessages }
        return []
    }

    /// Pre-failed bubble ids per demo chat (rich thread's failed own send).
    public static func failedIDs(for chatID: String) -> Set<String> {
        chatID == richID ? ["rich-fail"] : []
    }

    public static func name(for chatID: String) -> String? {
        if let chat = chats.first(where: { $0.id == chatID }) { return chat.name }
        for team in teams {
            if let ch = team.channels.first(where: { $0.id == chatID }) {
                return "\(team.name) > #\(ch.name)"
            }
        }
        return nil
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

    // MARK: - Notes (om-notes lane: canned OneNote for --demo)

    public static let notebooks: [NotebookItem] = [
        NotebookItem(notebookId: "demo-nb-work", name: "Design Sync Notes"),
        NotebookItem(notebookId: "demo-nb-team", name: "Team Wiki"),
    ]

    public static func notebooksResponse() -> NotebooksResponse {
        NotebooksResponse(ok: true, notebooks: notebooks)
    }

    public static func noteSections(for notebookID: String) -> [NoteSectionItem] {
        switch notebookID {
        case "demo-nb-work":
            return [
                NoteSectionItem(sectionId: "demo-sec-sync", name: "Syncs", pages: [
                    NotePageItem(
                        pageId: "demo-page-kickoff", title: "Kickoff Notes",
                        updated: "2026-09-22T09:12:05Z"),
                    NotePageItem(
                        pageId: "demo-page-empty", title: "Empty States Review",
                        updated: "2026-09-21T16:20:11Z"),
                ]),
                NoteSectionItem(sectionId: "demo-sec-ideas", name: "Ideas", pages: [
                    NotePageItem(pageId: "demo-page-roadmap", title: "Roadmap Draft"),
                ]),
            ]
        case "demo-nb-team":
            return [
                NoteSectionItem(sectionId: "demo-sec-wiki", name: "General", pages: [
                    NotePageItem(pageId: "demo-page-onboard", title: "Onboarding"),
                ]),
            ]
        default:
            return []
        }
    }

    private static let demoPageBodies: [String: (title: String, html: String)] = [
        "demo-page-kickoff": ("Kickoff Notes",
            "<html><head><title>Kickoff Notes</title></head><body>" +
                "<h1>Kickoff Notes</h1>" +
                "<p>Goals: ship the chat window, keep edits in place.</p>" +
                "<p>Owners: Priya (design), Tom (render), Me (core).</p>" +
                "</body></html>"),
        "demo-page-empty": ("Empty States Review",
            "<html><head><title>Empty States Review</title></head><body>" +
                "<h1>Empty States Review</h1>" +
                "<p>Illustration approved. Copy still TBD.</p>" +
                "</body></html>"),
        "demo-page-roadmap": ("Roadmap Draft",
            "<html><head><title>Roadmap Draft</title></head><body>" +
                "<h1>Roadmap Draft</h1>" +
                "<p>Q4: notes, search, polish.</p>" +
                "</body></html>"),
        "demo-page-onboard": ("Onboarding",
            "<html><head><title>Onboarding</title></head><body>" +
                "<h1>Onboarding</h1>" +
                "<p>Welcome! Start with the Design Sync notebook.</p>" +
                "</body></html>"),
    ]

    /// Paragraphs appended in this demo session (pageID → bodies).
    private static var demoAppended: [String: [String]] = [:]

    public static func notePage(for pageID: String) -> NotePageResponse? {
        guard let base = demoPageBodies[pageID] else { return nil }
        var html = base.html
        for para in demoAppended[pageID] ?? [] {
            let escaped = para
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            html = html.replacingOccurrences(
                of: "</body></html>", with: "<p>\(escaped)</p></body></html>")
        }
        return NotePageResponse(ok: true, id: pageID, title: base.title, html: html)
    }

    /// Offline append (demo Notes tab): records the paragraph locally.
    public static func appendDemo(pageID: String, text: String) {
        demoAppended[pageID, default: []].append(text)
    }

    /// Reset demo appends (tests).
    public static func resetDemoAppends() {
        demoAppended = [:]
    }
}
