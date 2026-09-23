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
    public static let reactionsID = "demo-react"
    public static let repliesID = "demo-replies"

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
        reactionsChat(),
        repliesChat(),
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

    /// Reactions sidebar row: preview/sender/time from the reacted tail.
    public static func reactionsChat(now: Date = Date()) -> ChatItem {
        let msgs = reactionsMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: reactionsID, name: "Demo — Reactions", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    /// Replies sidebar row: preview/sender/time from the replies thread's tail.
    public static func repliesChat(now: Date = Date()) -> ChatItem {
        let msgs = repliesMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: repliesID, name: "Demo — Threaded Replies", is_group: true,
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

    /// Canned To Do lists for `--demo` (om-remind lane).
    public static let reminderLists: [ReminderList] = [
        ReminderList(listId: "demo-list-tasks", name: "Tasks", wellknown: "defaultList"),
        ReminderList(listId: "demo-list-groceries", name: "Groceries"),
    ]

    public static func remindersResponse() -> RemindersResponse {
        RemindersResponse(ok: true, lists: reminderLists)
    }

    /// Canned tasks per demo list. Unknown ids stay empty.
    public static func reminderTasks(for listID: String) -> [ReminderTask] {
        switch listID {
        case "demo-list-tasks": return [
            ReminderTask(
                taskId: "demo-task-1", title: "Review empty-states mock",
                importance: "high", due: "2026-09-23T10:00:00.0000000"),
            ReminderTask(
                taskId: "demo-task-2", title: "Book dentist",
                reminder: "2026-09-24T08:00:00.0000000"),
            ReminderTask(
                taskId: "demo-task-3", title: "Ship review deck",
                status: "completed", completed: true),
        ]
        case "demo-list-groceries": return [
            ReminderTask(taskId: "demo-task-4", title: "Oat milk"),
            ReminderTask(taskId: "demo-task-5", title: "Coffee beans", importance: "high"),
        ]
        default: return []
        }
    }

    public static func reminderTasksResponse(for listID: String) -> ReminderTasksResponse {
        ReminderTasksResponse(ok: true, list_id: listID, tasks: reminderTasks(for: listID))
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
        case reactionsID: return reactionsMessages()
        case repliesID: return repliesMessages()
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

    /// Reactions thread (om-reactions): reacted bubbles (single + multi
    /// counts), one bare bubble for the picker shot. Fully offline.
    /// Timestamps float off now (Today).
    public static func reactionsMessages(now: Date = Date()) -> [ChatMessage] {
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
                id: "react-1", sender: "Priya Nair",
                timestamp: iso(at(h: 10, m: 2)),
                content: "Review deck is ready — link in the channel. Thumbs up when you've seen it?",
                reactions: [
                    ReactionCount(emoji: "👍", count: 3),
                    ReactionCount(emoji: "❤️", count: 1),
                ]),
            ChatMessage(
                id: "react-2", sender: "Tom Becker",
                timestamp: iso(at(h: 10, m: 4)),
                content: "Seen — the empty-states slide made me laugh out loud.",
                reactions: [ReactionCount(emoji: "😂", count: 2)]),
            ChatMessage(
                id: "react-3", sender: "Me",
                timestamp: iso(at(h: 10, m: 6)),
                content: "Glad it landed. Right-click any bubble to try the picker — counts update live.",
                isOwn: true),
        ]
    }

    /// Replies thread (om-replies): a question answered inline, a nested
    /// reply-to-reply, one own reply, and one reply whose parent aged out
    /// of history (evicted-parent fallback). Fully offline. Timestamps
    /// float off now (Today). `raw` mirrors the core quote-block format.
    public static func repliesMessages(now: Date = Date()) -> [ChatMessage] {
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
                id: "rep-1", sender: "Priya Nair",
                timestamp: iso(at(h: 9, m: 2)),
                content: "Review thread is open — drop questions on the onboarding mock here and I'll answer inline."),
            ChatMessage(
                id: "rep-2", sender: "Tom Becker",
                timestamp: iso(at(h: 9, m: 5)),
                content: "First one: is the empty-state illustration final, or still placeholder?",
                raw: #"<quote author="Priya Nair" guid="rep-1">Review thread is open — drop questions on the onboarding mock here and I'll answer inline.</quote><p>First one: is the empty-state illustration final, or still placeholder?</p>"#,
                reply_to: "rep-1"),
            ChatMessage(
                id: "rep-3", sender: "Priya Nair",
                timestamp: iso(at(h: 9, m: 8)),
                content: "Final — approved in yesterday's crit. The copy around it is still TBD though, so flag anything that reads odd.",
                raw: #"<quote author="Tom Becker" guid="rep-2">First one: is the empty-state illustration final, or still placeholder?</quote><p>Final — approved in yesterday's crit. The copy around it is still TBD though, so flag anything that reads odd.</p>"#,
                reply_to: "rep-2"),
            ChatMessage(
                id: "rep-4", sender: "Me",
                timestamp: iso(at(h: 9, m: 11)),
                content: "I'll take the copy pass — replying inline as I go.",
                isOwn: true),
            ChatMessage(
                id: "rep-5", sender: "Me",
                timestamp: iso(at(h: 9, m: 13)),
                content: "One more: do we keep the progress dots on step 1?",
                isOwn: true,
                raw: #"<quote author="Priya Nair" guid="rep-1">Review thread is open — drop questions on the onboarding mock here and I'll answer inline.</quote><p>One more: do we keep the progress dots on step 1?</p>"#,
                reply_to: "rep-1"),
            ChatMessage(
                id: "rep-6", sender: "Tom Becker",
                timestamp: iso(at(h: 9, m: 15)),
                content: "Following up on last week's thread — build is green now.",
                reply_to: "rep-0-evicted"),
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
