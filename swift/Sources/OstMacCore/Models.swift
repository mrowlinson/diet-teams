// Models.swift — pure Codable for ostmac-core JSON envelopes. No C calls.
import Foundation

/// Generic error envelope: {"ok":false,"error":code,"detail":...}
public struct CoreError: Decodable, Sendable {
    public let error: String
    public let detail: String?

    public var message: String {
        detail.map { "\(error): \($0)" } ?? error
    }
}

public struct TokenSlot: Decodable, Sendable {
    public let present: Bool
    public let expired: Bool
}

public struct TokenSummary: Decodable, Sendable {
    public let aad: TokenSlot
    public let refresh_present: Bool
    public let graph: TokenSlot
    public let ic3: TokenSlot
    public let recorder: TokenSlot
    public let skype: TokenSlot
    public let region_gtms_present: Bool
}

public struct StatusResponse: Decodable, Sendable {
    public let ok: Bool
    public let signed_in: Bool
    public let tokens: TokenSummary
}

public struct DeviceStart: Decodable, Sendable {
    public let ok: Bool
    public let session: String
    public let verification_uri: String
    public let user_code: String
    public let message: String
    public let expires_in: Int
    public let interval: Int
}

public struct DevicePoll: Decodable, Sendable {
    public let ok: Bool
    public let status: String
    public let interval: Int?
    public let tokens: TokenSummary?
}

// MARK: - Auth refresh / sign-out (om-authux lane)

/// Refresh envelope: `refreshed=false` means no refresh token is stored
/// (run the device-code flow); `tokens` is present only when refreshed.
public struct RefreshResponse: Decodable, Sendable {
    public let ok: Bool
    public let refreshed: Bool
    public let tokens: TokenSummary?
}

/// `{ok:true}` after tokens are cleared.
public struct SignOutResponse: Decodable, Sendable {
    public let ok: Bool
}

// MARK: - Browser-capture fallback (om-pwauth lane)

/// Auth-code + PKCE start: load `authorize_url` in the webview; the
/// `redirect_uri` hit carries `?code&state` for `browserComplete`.
public struct AuthCodeStart: Decodable, Sendable {
    public let ok: Bool
    public let session: String
    public let authorize_url: String
    public let redirect_uri: String
    public let expires_in: Int
}

/// Auth-code complete: `status` is "complete" (tokens saved, same shape
/// as the device flow) — anything else arrives as a thrown CoreCallError.
public struct AuthCodeComplete: Decodable, Sendable {
    public let ok: Bool
    public let status: String
    public let tokens: TokenSummary?
}

/// `{ok:true, cancelled}` after dropping a pending browser session.
public struct AuthCodeCancel: Decodable, Sendable {
    public let ok: Bool
    public let cancelled: Bool
}

// MARK: - Identity (om-identity-own lane)

/// Current user from core `ostmac_whoami` (Graph /me, core-cached).
/// `display_name` is the `ChatMessage.sender` match key for `isOwn`
/// (same sender==name rule the ost TUI uses).
public struct WhoamiResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String
    public let display_name: String
    public let mail: String?
}

public struct ChatItem: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { chatId }
    public let chatId: String
    public let name: String
    public let is_group: Bool
    public let last_message_time: String?
    public let last_message_sender: String?
    public let last_message_preview: String?

    enum CodingKeys: String, CodingKey {
        case chatId = "id"
        case name, is_group, last_message_time
        case last_message_sender, last_message_preview
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(
        chatId: String, name: String, is_group: Bool = false,
        last_message_time: String? = nil,
        last_message_sender: String? = nil,
        last_message_preview: String? = nil
    ) {
        self.chatId = chatId
        self.name = name
        self.is_group = is_group
        self.last_message_time = last_message_time
        self.last_message_sender = last_message_sender
        self.last_message_preview = last_message_preview
    }
}

public struct ChatsResponse: Decodable, Sendable {
    public let ok: Bool
    public let chats: [ChatItem]

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(ok: Bool, chats: [ChatItem]) {
        self.ok = ok
        self.chats = chats
    }
}

// MARK: - Teams (om-teams lane)

/// One channel inside a team. Wire format from core `ostmac_teams`:
/// `{"id","name"}`. The id opens as a conversation through the same
/// messages/send path as chat ids (ost TUI parity).
public struct TeamChannel: Decodable, Sendable, Identifiable {
    public var id: String { channelId }
    public let channelId: String
    public let name: String

    enum CodingKeys: String, CodingKey {
        case channelId = "id"
        case name
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(channelId: String, name: String) {
        self.channelId = channelId
        self.name = name
    }
}

/// One joined team with its channels.
public struct TeamItem: Decodable, Sendable, Identifiable {
    public var id: String { teamId }
    public let teamId: String
    public let name: String
    public let channels: [TeamChannel]

    enum CodingKeys: String, CodingKey {
        case teamId = "id"
        case name, channels
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(teamId: String, name: String, channels: [TeamChannel]) {
        self.teamId = teamId
        self.name = name
        self.channels = channels
    }
}

public struct TeamsResponse: Decodable, Sendable {
    public let ok: Bool
    public let teams: [TeamItem]

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(ok: Bool, teams: [TeamItem]) {
        self.ok = ok
        self.teams = teams
    }
}

public struct TrouterPoll: Decodable, Sendable {
    public let ok: Bool
    public let events: [AnyJSON]
}

// MARK: - Reminders (om-remind lane: Microsoft To Do via Graph /me/todo)

/// One To Do list from core `ostmac_reminders`: `{"id","name","wellknown?"}`.
public struct ReminderList: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { listId }
    public let listId: String
    public let name: String
    public let wellknown: String?

    enum CodingKeys: String, CodingKey {
        case listId = "id"
        case name, wellknown
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(listId: String, name: String, wellknown: String? = nil) {
        self.listId = listId
        self.name = name
        self.wellknown = wellknown
    }
}

public struct RemindersResponse: Decodable, Sendable {
    public let ok: Bool
    public let lists: [ReminderList]

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(ok: Bool, lists: [ReminderList]) {
        self.ok = ok
        self.lists = lists
    }
}

/// One To Do task from core `ostmac_reminder_tasks`: `{"id","title",
/// "status","importance","due?","reminder?","completed"}`.
public struct ReminderTask: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { taskId }
    public let taskId: String
    public let title: String
    public let status: String
    public let importance: String
    public let due: String?
    public let reminder: String?
    public let completed: Bool

    enum CodingKeys: String, CodingKey {
        case taskId = "id"
        case title, status, importance, due, reminder, completed
    }

    /// Host-side construction (demo data, previews). Wire decoding is untouched.
    public init(
        taskId: String, title: String, status: String = "notStarted",
        importance: String = "normal", due: String? = nil,
        reminder: String? = nil, completed: Bool = false
    ) {
        self.taskId = taskId
        self.title = title
        self.status = status
        self.importance = importance
        self.due = due
        self.reminder = reminder
        self.completed = completed
    }

    /// "2026-09-23T12:00:00.0000000" -> "12:00 23 Sep" (ChatMessage rules).
    public var displayDue: String? {
        due.map { ChatMessage.shortTime($0) }
    }
}

public struct ReminderTasksResponse: Decodable, Sendable {
    public let ok: Bool
    public let list_id: String?
    public let tasks: [ReminderTask]
}

/// `{ok,task}` from `ostmac_reminder_add` / `ostmac_reminder_done`.
public struct ReminderTaskResult: Decodable, Sendable {
    public let ok: Bool
    public let task: ReminderTask
}

// MARK: - Conversation (om-conv lane)

/// One chat message. Wire format from core `ostmac_messages`:
/// `{"id","sender","timestamp","content"}`.
/// `isOwn` is host-side only (core never sends it; defaults false) and
/// drives bubble alignment. The realtime lane feeds this same model into
/// `ConversationStore.ingest(_:)`; matching `id` => in-place edit update.
/// One grouped reaction count: picker emoji + number of reactors.
/// Wire format from core: `{"emoji","count"}`. Absent on old payloads.
public struct ReactionCount: Decodable, Sendable, Equatable {
    public let emoji: String
    public let count: Int

    public init(emoji: String, count: Int) {
        self.emoji = emoji
        self.count = count
    }
}

public struct ChatMessage: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let sender: String
    public let timestamp: String
    public var content: String
    public var isOwn: Bool
    /// Unstripped server HTML (om-convrich): mention/code mining source.
    /// Absent on old payloads, realtime ingests, and local echoes.
    public var raw: String?
    /// Host-side: set when a realtime edit rewrites `content`.
    public var edited: Bool
    /// Grouped reaction counts (om-reactions). Empty on old payloads,
    /// realtime ingests without counts, and local echoes.
    public var reactions: [ReactionCount]
    /// Parent message id for quote replies (om-replies): mined by core
    /// from the `<quote guid>` block; absent on old payloads and
    /// non-reply bubbles.
    public var reply_to: String?

    enum CodingKeys: String, CodingKey {
        case id, sender, timestamp, content, raw, reactions, reply_to
    }

    public init(
        id: String, sender: String, timestamp: String,
        content: String, isOwn: Bool = false,
        raw: String? = nil, edited: Bool = false,
        reactions: [ReactionCount] = [],
        reply_to: String? = nil
    ) {
        self.id = id
        self.sender = sender
        self.timestamp = timestamp
        self.content = content
        self.isOwn = isOwn
        self.raw = raw
        self.edited = edited
        self.reactions = reactions
        self.reply_to = reply_to
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sender = try c.decode(String.self, forKey: .sender)
        timestamp = try c.decode(String.self, forKey: .timestamp)
        content = try c.decode(String.self, forKey: .content)
        raw = try c.decodeIfPresent(String.self, forKey: .raw)
        reactions = try c.decodeIfPresent([ReactionCount].self, forKey: .reactions) ?? []
        reply_to = try c.decodeIfPresent(String.self, forKey: .reply_to)
        isOwn = false
        edited = false
    }

    /// "2026-09-22T12:53:06.9690000Z" -> "12:53" (today) or "12:53 22 Sep".
    /// Falls back to the raw prefix when the timestamp is missing/odd.
    public var displayTime: String {
        Self.shortTime(timestamp)
    }

    public static func shortTime(_ iso: String) -> String {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 16 else {
            return trimmed.isEmpty ? "?" : trimmed
        }
        // Fast path: fixed-offset slice, no Date parsing on the hot path.
        // "2026-09-22T12:53:06..." -> date "2026-09-22", clock "12:53".
        let datePart = String(trimmed.prefix(10))
        let clockPart: String = {
            let idx = trimmed.index(trimmed.startIndex, offsetBy: 11)
            let end = trimmed.index(idx, offsetBy: 5, limitedBy: trimmed.endIndex)
            return end.map { String(trimmed[idx ..< $0]) } ?? String(trimmed.dropFirst(11).prefix(5))
        }()
        let today: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone.current
            return f.string(from: Date())
        }()
        if datePart == today { return clockPart }
        let monthDay: String = {
            let parts = datePart.split(separator: "-")
            guard parts.count == 3 else { return datePart }
            let months = [
                "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
            ]
            let m = Int(parts[1]).flatMap { (1 ... 12).contains($0) ? months[$0 - 1] : nil } ?? String(parts[1])
            return "\(Int(parts[2]) ?? 0) \(m)"
        }()
        return "\(clockPart) \(monthDay)"
    }
}

public struct MessagesResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
    public let messages: [ChatMessage]
    /// Opaque cursor for the next older page; nil when history is exhausted.
    /// Absent (nil) on old core builds — treat as end of history.
    public let page_token: String?

    /// Host-side construction (demo data, MCP mocks). Wire decoding is untouched.
    public init(ok: Bool, chat_id: String?, messages: [ChatMessage], page_token: String? = nil) {
        self.ok = ok
        self.chat_id = chat_id
        self.messages = messages
        self.page_token = page_token
    }
}

public struct SendResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?

    /// Host-side construction (MCP mocks). Wire decoding is untouched.
    public init(ok: Bool, chat_id: String?) {
        self.ok = ok
        self.chat_id = chat_id
    }
}

/// `{ok,chat_id,message_id}` from `ostmac_edit`.
public struct EditResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
    public let message_id: String?

    public init(ok: Bool, chat_id: String? = nil, message_id: String? = nil) {
        self.ok = ok
        self.chat_id = chat_id
        self.message_id = message_id
    }
}

/// `{ok,chat_id,message_id}` from `ostmac_delete`.
public struct DeleteResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
    public let message_id: String?

    public init(ok: Bool, chat_id: String? = nil, message_id: String? = nil) {
        self.ok = ok
        self.chat_id = chat_id
        self.message_id = message_id
    }
}

// MARK: - Read receipts (om-receipts lane)

/// `{ok,chat_id,message_id}` from `ostmac_mark_read`.
public struct MarkReadResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
    public let message_id: String?

    public init(ok: Bool, chat_id: String? = nil, message_id: String? = nil) {
        self.ok = ok
        self.chat_id = chat_id
        self.message_id = message_id
    }
}

/// One peer read position from core `ostmac_receipts`.
/// `user` is the peer key (MRI/id, "" when unknown); `message_id` is the
/// last-read frontier; `horizon` is the raw server value.
public struct ReadReceipt: Decodable, Sendable, Equatable {
    public let user: String
    public let message_id: String
    public let horizon: String?

    public init(user: String, message_id: String, horizon: String? = nil) {
        self.user = user
        self.message_id = message_id
        self.horizon = horizon
    }
}

public struct ReceiptsResponse: Decodable, Sendable {
    public let ok: Bool
    public let thread_id: String?
    public let receipts: [ReadReceipt]

    public init(ok: Bool, thread_id: String? = nil, receipts: [ReadReceipt] = []) {
        self.ok = ok
        self.thread_id = thread_id
        self.receipts = receipts
    }
}

// MARK: - Rich media (om-richmedia lane)

/// One fetched inline image: base64 bytes + the server's content type.
public struct MediaResponse: Decodable, Sendable {
    public let ok: Bool
    public let data_base64: String
    public let content_type: String?

    /// Host-side construction (tests, mock fetchers). Wire decoding untouched.
    public init(ok: Bool, data_base64: String, content_type: String? = nil) {
        self.ok = ok
        self.data_base64 = data_base64
        self.content_type = content_type
    }
}

// MARK: - Shared files (om-shared lane)

/// One shared file from core `ostmac_files` (Graph driveItem projection).
/// `download_url` is a pre-authenticated short-lived URL: Swift downloads
/// directly (no bearer). `drive_id`+`id` drive `ostmac_files_download`
/// when the pre-signed URL expired.
public struct SharedFile: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let size: UInt64
    public let mime: String?
    public let web_url: String?
    public let download_url: String?
    public let drive_id: String?
    public let created: String?
    public let modified: String?
    public let sender: String?
    /// File-attachment GUID from the driveItem eTag (om-inline-docs): the
    /// bubble-match key for `<attachment id>` refs. Nil on old core builds
    /// and for items whose eTag carries no GUID.
    public let attachment_id: String?

    public init(
        id: String, name: String, size: UInt64 = 0,
        mime: String? = nil, web_url: String? = nil,
        download_url: String? = nil, drive_id: String? = nil,
        created: String? = nil, modified: String? = nil,
        sender: String? = nil, attachment_id: String? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.mime = mime
        self.web_url = web_url
        self.download_url = download_url
        self.drive_id = drive_id
        self.created = created
        self.modified = modified
        self.sender = sender
        self.attachment_id = attachment_id
    }

    /// "48211" -> "47.1 KB" (1 decimal, B/KB/MB/GB).
    public var sizeLabel: String {
        Self.sizeLabel(size)
    }

    public static func sizeLabel(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }

    /// SF Symbol for the mime/extension (doc, image, film, music, archive).
    public var iconName: String {
        Self.iconName(mime: mime, filename: name)
    }

    public static func iconName(mime: String?, filename: String) -> String {
        let m = (mime ?? "").lowercased()
        if m.hasPrefix("image/") { return "photo" }
        if m.hasPrefix("video/") { return "film" }
        if m.hasPrefix("audio/") { return "music.note" }
        if m == "application/pdf" { return "doc.richtext" }
        if m.contains("zip") || m.contains("tar") || m.contains("gzip") { return "archivebox" }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "mov", "mp4", "m4v": return "film"
        case "mp3", "m4a", "wav": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "tar", "gz": return "archivebox"
        case "doc", "docx", "pages", "txt", "md": return "doc.text"
        case "xls", "xlsx", "numbers", "csv": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        default: return "doc"
        }
    }
}

public struct SharedFilesResponse: Decodable, Sendable {
    public let ok: Bool
    public let chat_id: String?
    public let files: [SharedFile]

    public init(ok: Bool, chat_id: String? = nil, files: [SharedFile]) {
        self.ok = ok
        self.chat_id = chat_id
        self.files = files
    }
}

public struct SharedFileUploadResponse: Decodable, Sendable {
    public let ok: Bool
    public let file: SharedFile
}

public struct SharedFileDownloadResponse: Decodable, Sendable {
    public let ok: Bool
    public let path: String
    public let bytes: UInt64
}

// MARK: - Presence (om-presence lane)

/// Own presence from core `ostmac_presence` / `ostmac_presence_set`
/// (Graph /me/presence): availability ∈ Available, Busy, DoNotDisturb,
/// Away, Offline, PresenceUnknown (+ future server values, passed through).
public struct PresenceResponse: Decodable, Sendable {
    public let ok: Bool
    public let availability: String
    public let activity: String

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, availability: String, activity: String) {
        self.ok = ok
        self.availability = availability
        self.activity = activity
    }
}

/// One other user's presence from core `ostmac_presence_user`
/// (Graph /users/{id}/presence). Same shape as own, plus the echoed id.
public struct UserPresenceResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String
    public let availability: String
    public let activity: String

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, id: String, availability: String, activity: String) {
        self.ok = ok
        self.id = id
        self.availability = availability
        self.activity = activity
    }
}

// MARK: - MRI resolution (om-steal-ids lane)

/// Graph user behind a Teams MRI, from core `ostmac_resolve_mri`
/// (Graph /users/{aad-oid}). `email` is nil for guests (no mail).
public struct ResolveMriResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String
    public let email: String?
    public let display_name: String

    /// Host-side construction (mock fetchers, caches).
    public init(ok: Bool, id: String, email: String?, display_name: String) {
        self.ok = ok
        self.id = id
        self.email = email
        self.display_name = display_name
    }
}

// MARK: - Token health (om-steal-ids lane)

/// One timed probe in a health report (port of teams-access
/// `HealthProbeResult`: name/ok/status/detail/durationMs).
public struct HealthProbe: Sendable, Equatable {
    public let name: String
    public let ok: Bool
    public let status: Int?
    public let detail: String
    public let durationMs: Int

    public init(name: String, ok: Bool, status: Int? = nil, detail: String, durationMs: Int) {
        self.name = name
        self.ok = ok
        self.status = status
        self.detail = detail
        self.durationMs = durationMs
    }
}

/// Overall health verdict (teams-access `overall`, verbatim).
public enum HealthOverall: String, Sendable {
    case ok, degraded, broken
}

/// One audience token slot in a health report (offline, from status).
public struct HealthToken: Sendable, Equatable {
    public let audience: String
    public let present: Bool
    public let expired: Bool

    public init(audience: String, present: Bool, expired: Bool) {
        self.audience = audience
        self.present = present
        self.expired = expired
    }

    public var state: String {
        !present ? "missing" : expired ? "expired" : "fresh"
    }
}

/// Full diagnostics report: offline per-audience token slots + live
/// probe results + verdict. Built host-side (no core envelope).
public struct HealthReport: Sendable {
    public let overall: HealthOverall
    public let tokens: [HealthToken]
    public let probes: [HealthProbe]
    public let accountUPN: String?

    public init(overall: HealthOverall, tokens: [HealthToken], probes: [HealthProbe], accountUPN: String? = nil) {
        self.overall = overall
        self.tokens = tokens
        self.probes = probes
        self.accountUPN = accountUPN
    }
}

// MARK: - Notes (om-notes lane: OneNote read + paragraph append)

/// One OneNote notebook. Wire format from core `ostmac_notes`:
/// `{"id","name"}`.
public struct NotebookItem: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { notebookId }
    public let notebookId: String
    public let name: String

    enum CodingKeys: String, CodingKey {
        case notebookId = "id"
        case name
    }

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(notebookId: String, name: String) {
        self.notebookId = notebookId
        self.name = name
    }
}

public struct NotebooksResponse: Decodable, Sendable {
    public let ok: Bool
    public let notebooks: [NotebookItem]

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, notebooks: [NotebookItem]) {
        self.ok = ok
        self.notebooks = notebooks
    }
}

/// One OneNote page (metadata; content arrives via `ostmac_note_page`).
public struct NotePageItem: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { pageId }
    public let pageId: String
    public let title: String
    public let updated: String?

    enum CodingKeys: String, CodingKey {
        case pageId = "id"
        case title, updated
    }

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(pageId: String, title: String, updated: String? = nil) {
        self.pageId = pageId
        self.title = title
        self.updated = updated
    }
}

/// One OneNote section with its pages (nested by core to save round trips).
public struct NoteSectionItem: Decodable, Sendable, Identifiable, Equatable {
    public var id: String { sectionId }
    public let sectionId: String
    public let name: String
    public let pages: [NotePageItem]

    enum CodingKeys: String, CodingKey {
        case sectionId = "id"
        case name, pages
    }

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(sectionId: String, name: String, pages: [NotePageItem]) {
        self.sectionId = sectionId
        self.name = name
        self.pages = pages
    }
}

public struct NoteSectionsResponse: Decodable, Sendable {
    public let ok: Bool
    public let sections: [NoteSectionItem]

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, sections: [NoteSectionItem]) {
        self.ok = ok
        self.sections = sections
    }
}

/// One page's content. `title` is empty when the page ships no `<title>`.
public struct NotePageResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String
    public let title: String
    public let html: String

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, id: String, title: String, html: String) {
        self.ok = ok
        self.id = id
        self.title = title
        self.html = html
    }
}

/// `{ok,id}` after a paragraph append.
public struct NoteAppendResponse: Decodable, Sendable {
    public let ok: Bool
    public let id: String

    /// Host-side construction (demo data, previews, mock fetchers).
    public init(ok: Bool, id: String) {
        self.ok = ok
        self.id = id
    }
}

// MARK: - Calls (om-signal lane: signaling only, no audio/video)

/// One call record from core `ostmac_call_*`. `state` is
/// placing|ringing|connected|ended|failed; `dir` is in|out.
public struct CallInfo: Decodable, Sendable, Equatable {
    public let id: String
    public let dir: String
    public let peer: String
    public let peerName: String
    public let thread: String
    public let state: String
    public let controller: String?
    public let startedAt: UInt64
    public let detail: String?
    /// True once the live media engine (ICE/SRTP/RTP) is attached.
    public let liveMedia: Bool?

    enum CodingKeys: String, CodingKey {
        case id, dir, peer, thread, state, controller, detail
        case peerName = "peer_name"
        case startedAt = "started_at"
        case liveMedia = "live_media"
    }

    public var isActive: Bool {
        state == "placing" || state == "ringing" || state == "connected"
    }

    public var displayPeer: String {
        peerName.isEmpty ? (peer.isEmpty ? thread : peer) : peerName
    }

    public init(
        id: String, dir: String, peer: String, peerName: String = "",
        thread: String = "", state: String, controller: String? = nil,
        startedAt: UInt64 = 0, detail: String? = nil, liveMedia: Bool? = nil
    ) {
        self.id = id
        self.dir = dir
        self.peer = peer
        self.peerName = peerName
        self.thread = thread
        self.state = state
        self.controller = controller
        self.startedAt = startedAt
        self.detail = detail
        self.liveMedia = liveMedia
    }
}

/// `{ok, call?}` from `ostmac_call_status`.
public struct CallStatus: Decodable, Sendable {
    public let ok: Bool
    public let call: CallInfo?
}

/// Place/accept/end envelope. Only the keys the action sets are read;
/// the rest stay nil (one shape for all call actions).
public struct CallResult: Decodable, Sendable {
    public let ok: Bool
    public let placed: Bool?
    public let accepted: Bool?
    public let ended: Bool?
    public let injected: Bool?
    public let mediaAnswered: Bool?
    public let liveMedia: Bool?
    public let rejection: String?
    public let responseBytes: Int?
    public let call: CallInfo?

    enum CodingKeys: String, CodingKey {
        case ok, placed, accepted, ended, injected, rejection, call
        case mediaAnswered = "media_answered"
        case liveMedia = "live_media"
        case responseBytes = "response_bytes"
    }
}

/// One typed call event from the feed (`calls[]` in the typed poll).
/// `kind` is incoming|end|rejected.
public struct CallEvent: Decodable, Sendable, Equatable {
    public let kind: String
    public let callID: String
    public let peer: String
    public let peerName: String
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case kind, peer, detail
        case callID = "call_id"
        case peerName = "peer_name"
    }

    public init(kind: String, callID: String, peer: String = "", peerName: String = "", detail: String? = nil) {
        self.kind = kind
        self.callID = callID
        self.peer = peer
        self.peerName = peerName
        self.detail = detail
    }
}

/// Minimal Any-Decodable for opaque Trouter event payloads.
public struct AnyJSON: Decodable, Sendable {
    public let value: String
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s; return }
        if let n = try? c.decode(Int.self) { value = String(n); return }
        if let b = try? c.decode(Bool.self) { value = String(b); return }
        if let a = try? c.decode([AnyJSON].self) {
            value = "[" + a.map(\.value).joined(separator: ",") + "]"; return
        }
        if let o = try? c.decode([String: AnyJSON].self) {
            value = "{" + o.map { "\($0):\($1.value)" }.joined(separator: ",") + "}"
            return
        }
        if c.decodeNil() { value = "null"; return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unsupported JSON")
    }
}

/// Decode success `T` or throw the envelope error.
public func decodeOrThrow<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    if let err = try? JSONDecoder().decode(CoreError.self, from: data),
       (try? JSONDecoder().decode(OkFlag.self, from: data))?.ok == false
    {
        throw CoreCallError.failed(err.message)
    }
    return try JSONDecoder().decode(type, from: data)
}

struct OkFlag: Decodable { let ok: Bool }

public enum CoreCallError: Error, Sendable {
    case failed(String)
    case badUTF8
}
