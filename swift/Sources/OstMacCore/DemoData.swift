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
    public static let historyID = "demo-history"
    public static let botpostsID = "demo-botposts"

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
        historyChat(),
        botPostsChat(),
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

    /// History sidebar row: preview/sender/time from the long tail.
    public static func historyChat(now: Date = Date()) -> ChatItem {
        let msgs = historyMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: historyID, name: "Demo — Long History", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    /// Bot-posts sidebar row: preview/sender/time from the bot thread's tail.
    public static func botPostsChat(now: Date = Date()) -> ChatItem {
        let msgs = botPostsMessages(now: now)
        let last = msgs.last
        return ChatItem(
            chatId: botpostsID, name: "Demo — Bot Posts", is_group: true,
            last_message_time: last?.timestamp,
            last_message_sender: last?.sender,
            last_message_preview: last?.content)
    }

    /// True for canned demo/chat ids (om-demo-select). Single namespace
    /// check: the exact "demo" root plus the "demo-" prefix (rows,
    /// channels, churn rows, reminder/note fixtures), plus the churn
    /// meeting id (a real-shaped 19: thread that only exists in the
    /// --show-sidebarchurn dataset). Live Teams ids never match.
    public static func isDemoID(_ id: String) -> Bool {
        id == demoID || id.hasPrefix("demo-") || id == churnMeetingID
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
        case churnMeetingID: return churnMeetingMessages
        case churnSyncID: return churnSyncMessages
        case churnPollyID: return churnPollyMessages
        case churnStandupID: return churnStandupMessages
        case historyID: return historyMessages()
        case botpostsID: return botPostsMessages()
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

    /// History thread (om-history): a 3-day release-review conversation
    /// (38 bubbles) exercising the 24h window + day separators at every
    /// scroll state. Fully offline. Timestamps float off now so the
    /// separators always read <date>/Yesterday/Today.
    public static func historyMessages(now: Date = Date()) -> [ChatMessage] {
        func iso(_ d: Date) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f.string(from: d)
        }
        func at(dayOffset: Int, h: Int, m: Int) -> Date {
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            let base = cal.date(byAdding: .day, value: dayOffset, to: now) ?? now
            return cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
        }
        // (dayOffset, hour, minute, sender, text, isOwn)
        let script: [(Int, Int, Int, String, String, Bool)] = [
            (-2, 9, 2, "Priya Nair", "Kicking off the release review thread — three days of notes live here.", false),
            (-2, 9, 5, "Tom Becker", "Agenda: window load, day paging, then the blank-state fixes.", false),
            (-2, 9, 9, "Priya Nair", "First up: opening a long thread should show the last day, not everything.", false),
            (-2, 9, 14, "Me", "Agreed — a 24h window keeps the initial load fast.", true),
            (-2, 9, 21, "Tom Becker", "And older days load lazily from the top of the scroll.", false),
            (-2, 10, 3, "Priya Nair", "What about threads that went quiet for a week?", false),
            (-2, 10, 11, "Me", "Then the newest page still shows — the window never blanks the view.", true),
            (-2, 11, 26, "Tom Becker", "Right: bound the fetch, not the display.", false),
            (-2, 13, 2, "Priya Nair", "Lunch break. Back with the paging sketches.", false),
            (-2, 14, 40, "Priya Nair", "Sketches are up: one tap loads one more day back.", false),
            (-2, 14, 47, "Tom Becker", "Love it. No more auto-chaining the whole history.", false),
            (-2, 15, 12, "Me", "That auto-chain was the churn bug — spinner swap refires the loader.", true),
            (-2, 16, 5, "Tom Becker", "Explicit taps only from now on.", false),
            (-2, 16, 58, "Priya Nair", "Day one notes done. Tomorrow: error states.", false),
            (-1, 9, 1, "Priya Nair", "Day two: what does a failed history fetch look like?", false),
            (-1, 9, 6, "Tom Becker", "A banner over the messages we already have — never a blank pane.", false),
            (-1, 9, 13, "Me", "And when nothing loaded at all, an empty state with retry.", true),
            (-1, 9, 29, "Priya Nair", "Retry re-runs the open, right? Not just the failed page?", false),
            (-1, 9, 34, "Me", "Exactly — Try Again re-opens the chat.", true),
            (-1, 10, 15, "Tom Becker", "Mid-chain failures keep partial pages too.", false),
            (-1, 10, 22, "Priya Nair", "Good. Partial progress plus a visible error.", false),
            (-1, 11, 48, "Tom Becker", "Switching chats mid-load drops the stale work?", false),
            (-1, 11, 55, "Me", "Yes — generation guard on every page, open and day-load alike.", true),
            (-1, 13, 20, "Priya Nair", "Edge case: a page that arrives empty but points further back.", false),
            (-1, 13, 31, "Tom Becker", "Keep paging — blank pages don't cover the window.", false),
            (-1, 15, 2, "Priya Nair", "And garbage timestamps stop the window after the current page.", false),
            (-1, 15, 19, "Me", "Right, we can't window what we can't parse.", true),
            (-1, 16, 44, "Tom Becker", "Day two notes done. Tomorrow we ship it.", false),
            (0, 9, 0, "Priya Nair", "Ship day. Final pass over the scroll states.", false),
            (0, 9, 4, "Tom Becker", "Top of thread: oldest day separator plus the load-more button.", false),
            (0, 9, 9, "Me", "Middle: day separators between the three days.", true),
            (0, 9, 15, "Priya Nair", "Bottom: the tail of the last 24 hours.", false),
            (0, 9, 28, "Tom Becker", "Screenshots at every state, all viewed.", false),
            (0, 9, 41, "Priya Nair", "One more check: the error state with its Try Again.", false),
            (0, 10, 2, "Me", "Covered — canned fetch failure, fully offline.", true),
            (0, 10, 20, "Tom Becker", "Then we're green. Merging the lane.", false),
            (0, 10, 35, "Priya Nair", "Release review complete. Great thread, everyone.", false),
            (0, 10, 41, "Me", "Archiving these notes — see you at the next review.", true),
        ]
        return script.enumerated().map { i, line in
            ChatMessage(
                id: "hist-\(i + 1)", sender: line.3,
                timestamp: iso(at(dayOffset: line.0, h: line.1, m: line.2)),
                content: line.4, isOwn: line.5)
        }
    }

    /// Bot-posts thread (om-botposts): an RSS digest (prose + two
    /// title+link rows), a build card (marked JSON → row, blob
    /// suppressed), an unparseable card (server-held attachment →
    /// placeholder), and a mixed deploy note (prose + one row). Fully
    /// offline. Timestamps float off now (Today). `content` mirrors
    /// core strip semantics (tags removed, no spaces added).
    public static func botPostsMessages(now: Date = Date()) -> [ChatMessage] {
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
                id: "bot-1", sender: "Tech News RSS",
                timestamp: iso(at(h: 8, m: 2)),
                content: "Tech news digest — 2 new stories:"
                    + "Swift 6.2 releasedConcurrency notes and migration guide."
                    + "Rust 1.89 shipsConst generics progress.",
                raw: "<p>Tech news digest — 2 new stories:</p>"
                    + #"<attachment><p><a href="https://example.com/swift-62">Swift 6.2 released</a></p>"#
                    + "<p>Concurrency notes and migration guide.</p></attachment>"
                    + #"<attachment><p><a href="https://example.com/rust-189">Rust 1.89 ships</a></p>"#
                    + "<p>Const generics progress.</p></attachment>"),
            ChatMessage(
                id: "bot-2", sender: "Build Bot",
                timestamp: iso(at(h: 8, m: 5)),
                content: #"{"@type":"MessageCard","@context":"https://schema.org/extensions","title":"Build green","text":"main passed all checks","potentialAction":[{"@type":"OpenUri","name":"View run","targets":[{"os":"default","uri":"https://example.com/builds/7"}]}]}"#,
                raw: #"{"@type":"MessageCard","@context":"https://schema.org/extensions","title":"Build green","text":"main passed all checks","potentialAction":[{"@type":"OpenUri","name":"View run","targets":[{"os":"default","uri":"https://example.com/builds/7"}]}]}"#),
            ChatMessage(
                id: "bot-3", sender: "RSS Bot",
                timestamp: iso(at(h: 8, m: 7)),
                content: "",
                raw: #"<attachment id="abc123"></attachment>"#),
            ChatMessage(
                id: "bot-4", sender: "Deploy Bot",
                timestamp: iso(at(h: 8, m: 9)),
                content: "Deploy finished: release 42 notes",
                raw: #"<p>Deploy finished: </p><attachment><a href="https://example.com/deploys/42">release 42 notes</a></attachment>"#),
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

    // MARK: - Sidebar churn demo (om-sidebarchurn: --show-sidebarchurn)

    /// Churn-demo rows (NOT part of `chats`: the shot hook swaps the
    /// whole fetcher so the standard demo + its count assertions stay
    /// untouched). Initial order: meeting on top; the burst moves ONLY
    /// the user-active chat above it.
    public static let churnMeetingID = "19:meeting_churn123@thread.v2"
    public static let churnSyncID = "demo-churn-sync"
    public static let churnPollyID = "demo-churn-polly"
    public static let churnStandupID = "demo-churn-standup"

    public static func churnChatsResponse() -> ChatsResponse {
        ChatsResponse(ok: true, chats: [
            ChatItem(
                chatId: churnMeetingID, name: "Sprint Planning", is_group: true,
                last_message_time: "2026-09-23T09:00:00Z",
                last_message_sender: "Priya Nair",
                last_message_preview: "Running 5 late, start without me"),
            ChatItem(
                chatId: churnPollyID, name: "Polly",
                last_message_time: "2026-09-23T08:50:00Z",
                last_message_sender: "Polly",
                last_message_preview: "Yesterday's poll is closed"),
            ChatItem(
                chatId: churnStandupID, name: "Platform Standup", is_group: true,
                last_message_time: "2026-09-23T08:40:00Z",
                last_message_sender: "Tom Becker",
                last_message_preview: "Build is green"),
            ChatItem(
                chatId: churnSyncID, name: "Design Sync", is_group: true,
                last_message_time: "2026-09-23T08:30:00Z",
                last_message_sender: "Tom Becker",
                last_message_preview: "Mocks are up for review"),
        ])
    }

    /// The burst the shot hook folds after load: a meeting beacon storm
    /// (skipped), a reaction-only patch (skipped), a media card
    /// (skipped), a mixed card (its human lines refresh the meeting
    /// preview in place), a bot poll note + a system notice (in place),
    /// a user message (bubbles) + its edit (in place). Final order:
    /// Sync, Meeting, Polly, Standup.
    public static func churnBurst() -> [RealtimeMessage] {
        [
            RealtimeMessage(
                chatID: churnMeetingID, msgId: "ch-b1", sender: "?",
                text: "Sprint PlanningPlay", time: "2026-09-23T09:01:00Z",
                isEdit: false, messageType: "Text"),
            RealtimeMessage(
                chatID: churnMeetingID, msgId: "ch-b2", sender: "?",
                text: #"{"scopeId":"s","storageId":"t","meetingTenantId":"m"}"#,
                time: "2026-09-23T09:02:00Z", isEdit: false, messageType: "Text"),
            RealtimeMessage(
                chatID: churnMeetingID, msgId: "ch-b3", sender: "Facilitator",
                text: "Hi! I'm here to help with the meeting — ask me for a recap.",
                time: "2026-09-23T09:03:00Z", isEdit: false, messageType: "Text"),
            RealtimeMessage(
                chatID: churnSyncID, msgId: "ch-b4", sender: "Tom Becker",
                text: "", time: "2026-09-23T09:04:00Z", isEdit: false,
                reactions: [ReactionCount(emoji: "👍", count: 2)],
                messageType: "RichText/Html"),
            RealtimeMessage(
                chatID: churnMeetingID, msgId: "ch-b5", sender: "?",
                text: "Q3 Review recording", time: "2026-09-23T09:05:00Z",
                isEdit: false, messageType: "RichText/Media_Card"),
            RealtimeMessage(
                chatID: churnMeetingID, msgId: "ch-b6", sender: "?",
                text: "{\n\"scopeId\": \"s\",\n\"storageId\": \"t\"\n}\nStandup notes are posted in the thread",
                time: "2026-09-23T09:06:00Z", isEdit: false, messageType: "Text"),
            RealtimeMessage(
                chatID: churnSyncID, msgId: "ch-b7", sender: "Tom Becker",
                text: "Recording is up — link in the thread",
                time: "2026-09-23T09:07:00Z", isEdit: false,
                messageType: "RichText/Html"),
            RealtimeMessage(
                chatID: churnPollyID, msgId: "ch-b8", sender: "Polly",
                senderID: "28:00001111-2222-3333-4444-555566667777",
                text: "Priya voted: Thursday works best",
                time: "2026-09-23T09:08:00Z", isEdit: false, messageType: "Text"),
            RealtimeMessage(
                chatID: churnStandupID, msgId: "ch-b9", sender: "?",
                text: "Tom Becker added Priya Nair to the chat",
                time: "2026-09-23T09:09:00Z", isEdit: false,
                messageType: "ThreadActivity/AddMember"),
            RealtimeMessage(
                chatID: churnSyncID, msgId: "ch-b10", sender: "Tom Becker",
                text: "Recording is up — link in the thread (fixed)",
                time: "2026-09-23T09:10:00Z", isEdit: true, editedID: "ch-b7",
                messageType: "RichText/Html"),
        ]
    }

    private static let churnMeetingMessages: [ChatMessage] = [
        ChatMessage(
            id: "chm-1", sender: "Tom Becker",
            timestamp: "2026-09-23T08:55:00Z",
            content: "Agenda: sprint review, then retro. Starting in 5."),
        ChatMessage(
            id: "chm-2", sender: "Priya Nair",
            timestamp: "2026-09-23T09:00:00Z",
            content: "Running 5 late, start without me"),
    ]

    private static let churnSyncMessages: [ChatMessage] = [
        ChatMessage(
            id: "chs-1", sender: "Tom Becker",
            timestamp: "2026-09-23T08:30:00Z",
            content: "Mocks are up for review"),
    ]

    private static let churnPollyMessages: [ChatMessage] = [
        ChatMessage(
            id: "chp-1", sender: "Polly",
            timestamp: "2026-09-23T08:50:00Z",
            content: "Yesterday's poll is closed"),
    ]

    private static let churnStandupMessages: [ChatMessage] = [
        ChatMessage(
            id: "chh-1", sender: "Tom Becker",
            timestamp: "2026-09-23T08:40:00Z",
            content: "Build is green"),
    ]
}
