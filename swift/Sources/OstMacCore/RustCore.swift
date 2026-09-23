// RustCore.swift — thin Swift wrapper over the ostmac-core C ABI.
import COstMac
import Foundation

public enum RustCore {
    public static func version() -> String {
        String(cString: ostmac_version())
    }

    public static func initialize() -> Int32 { ostmac_init() }

    public static func status() throws -> StatusResponse {
        try call(ostmac_status(), as: StatusResponse.self)
    }

    public static func deviceStart() throws -> DeviceStart {
        try call(ostmac_device_start(), as: DeviceStart.self)
    }

    public static func devicePoll(session: String) throws -> DevicePoll {
        try session.withCString { ptr in
            try call(ostmac_device_poll(ptr), as: DevicePoll.self)
        }
    }

    public static func refresh() throws -> RefreshResponse {
        try call(ostmac_refresh(), as: RefreshResponse.self)
    }

    public static func signOut() throws -> SignOutResponse {
        try call(ostmac_sign_out(), as: SignOutResponse.self)
    }

    /// Browser-capture start (auth-code + PKCE, no network): returns the
    /// session + authorize URL to load in the webview.
    public static func browserStart() throws -> AuthCodeStart {
        try call(ostmac_authcode_start(), as: AuthCodeStart.self)
    }

    /// Browser-capture complete: exchanges the intercepted callback URL
    /// for tokens (state verified in core). Blocking FFI (network): call
    /// off the main thread.
    public static func browserComplete(session: String, callback: String) throws -> AuthCodeComplete {
        try session.withCString { sPtr in
            try callback.withCString { cPtr in
                try call(ostmac_authcode_complete(sPtr, cPtr), as: AuthCodeComplete.self)
            }
        }
    }

    /// Drop one pending browser session (cancel path; never throws fatally).
    public static func browserCancel(session: String) throws -> AuthCodeCancel {
        try session.withCString { ptr in
            try call(ostmac_authcode_cancel(ptr), as: AuthCodeCancel.self)
        }
    }

    public static func whoami() throws -> WhoamiResponse {
        try call(ostmac_whoami(), as: WhoamiResponse.self)
    }

    public static func chats(limit: Int32 = 20) throws -> ChatsResponse {
        try call(ostmac_chats(limit), as: ChatsResponse.self)
    }

    public static func teams() throws -> TeamsResponse {
        try call(ostmac_teams(), as: TeamsResponse.self)
    }

    public static func messages(chatID: String, limit: Int32 = 50) throws -> MessagesResponse {
        try chatID.withCString { ptr in
            try call(ostmac_messages(ptr, limit), as: MessagesResponse.self)
        }
    }

    public static func messagesPage(chatID: String, pageToken: String, limit: Int32 = 50) throws -> MessagesResponse {
        try chatID.withCString { idPtr in
            try pageToken.withCString { tokPtr in
                try call(ostmac_messages_page(idPtr, tokPtr, limit), as: MessagesResponse.self)
            }
        }
    }

    public static func send(chatID: String, text: String) throws -> SendResponse {
        try chatID.withCString { idPtr in
            try text.withCString { textPtr in
                try call(ostmac_send(idPtr, textPtr), as: SendResponse.self)
            }
        }
    }

    /// Add one emoji reaction to a message (om-reactions).
    /// Blocking FFI (network): call off the main thread.
    public static func react(chatID: String, messageID: String, emoji: String) throws -> SendResponse {
        try chatID.withCString { idPtr in
            try messageID.withCString { midPtr in
                try emoji.withCString { ePtr in
                    try call(ostmac_react(idPtr, midPtr, ePtr), as: SendResponse.self)
                }
            }
        }
    }

    /// Edit one own message via core (blocking FFI: call off main thread).
    public static func edit(chatID: String, messageID: String, text: String) throws -> EditResponse {
        try chatID.withCString { idPtr in
            try messageID.withCString { midPtr in
                try text.withCString { textPtr in
                    try call(ostmac_edit(idPtr, midPtr, textPtr), as: EditResponse.self)
                }
            }
        }
    }

    /// Remove one emoji reaction from a message (om-reactions).
    /// Blocking FFI (network): call off the main thread.
    public static func removeReaction(chatID: String, messageID: String, emoji: String) throws -> SendResponse {
        try chatID.withCString { idPtr in
            try messageID.withCString { midPtr in
                try emoji.withCString { ePtr in
                    try call(ostmac_react_remove(idPtr, midPtr, ePtr), as: SendResponse.self)
                }
            }
        }
    }

    /// Post one quote reply to a chat message. `parentSender`/`parentText`
    /// attribute the quote block (core truncates the snippet + falls back
    /// on blanks). Blocking FFI (network): call off the main thread.
    public static func reply(
        chatID: String, parentID: String,
        parentSender: String, parentText: String, text: String
    ) throws -> SendResponse {
        try chatID.withCString { idPtr in
            try parentID.withCString { parentPtr in
                try parentSender.withCString { senderPtr in
                    try parentText.withCString { snippetPtr in
                        try text.withCString { textPtr in
                            try call(
                                ostmac_reply(idPtr, parentPtr, senderPtr, snippetPtr, textPtr),
                                as: SendResponse.self)
                        }
                    }
                }
            }
        }
    }

    /// Delete one own message via core (blocking FFI: call off main thread).
    public static func deleteMessage(chatID: String, messageID: String) throws -> DeleteResponse {
        try chatID.withCString { idPtr in
            try messageID.withCString { midPtr in
                try call(ostmac_delete(idPtr, midPtr), as: DeleteResponse.self)
            }
        }
    }

    /// One fetched inline image: decoded bytes + content type, if any.
    /// Blocking FFI (network): call off the main thread.
    public static func mediaFetch(url: String) throws -> (data: Data, contentType: String?) {
        let resp: MediaResponse = try url.withCString { ptr in
            try call(ostmac_media_fetch(ptr), as: MediaResponse.self)
        }
        guard let data = Data(base64Encoded: resp.data_base64) else {
            throw CoreCallError.failed("media: bad base64 from core")
        }
        return (data, resp.content_type)
    }

    public static func sharedFiles(chatID: String, limit: Int32 = 20) throws -> SharedFilesResponse {
        try chatID.withCString { ptr in
            try call(ostmac_files(ptr, limit), as: SharedFilesResponse.self)
        }
    }

    public static func sharedUpload(chatID: String, path: String) throws -> SharedFileUploadResponse {
        try chatID.withCString { idPtr in
            try path.withCString { pathPtr in
                try call(ostmac_files_upload(idPtr, pathPtr), as: SharedFileUploadResponse.self)
            }
        }
    }

    public static func sharedDownload(driveID: String, itemID: String, dest: String) throws -> SharedFileDownloadResponse {
        try driveID.withCString { dPtr in
            try itemID.withCString { iPtr in
                try dest.withCString { destPtr in
                    try call(ostmac_files_download(dPtr, iPtr, destPtr), as: SharedFileDownloadResponse.self)
                }
            }
        }
    }

    public static func presence() throws -> PresenceResponse {
        try call(ostmac_presence(), as: PresenceResponse.self)
    }

    public static func setPresence(status: String) throws -> PresenceResponse {
        try status.withCString { ptr in
            try call(ostmac_presence_set(ptr), as: PresenceResponse.self)
        }
    }

    public static func userPresence(id: String) throws -> UserPresenceResponse {
        try id.withCString { ptr in
            try call(ostmac_presence_user(ptr), as: UserPresenceResponse.self)
        }
    }

    public static func resolveMri(mri: String) throws -> ResolveMriResponse {
        try mri.withCString { ptr in
            try call(ostmac_resolve_mri(ptr), as: ResolveMriResponse.self)
        }
    }

    public static func reminders() throws -> RemindersResponse {
        try call(ostmac_reminders(), as: RemindersResponse.self)
    }

    public static func reminderTasks(listID: String, limit: Int32 = 50) throws -> ReminderTasksResponse {
        try listID.withCString { ptr in
            try call(ostmac_reminder_tasks(ptr, limit), as: ReminderTasksResponse.self)
        }
    }

    public static func reminderAdd(listID: String, title: String) throws -> ReminderTaskResult {
        try listID.withCString { idPtr in
            try title.withCString { titlePtr in
                try call(ostmac_reminder_add(idPtr, titlePtr), as: ReminderTaskResult.self)
            }
        }
    }

    public static func notebooks(groupID: String? = nil) throws -> NotebooksResponse {
        try withOptionalCString(groupID) { ptr in
            try call(ostmac_notes(ptr), as: NotebooksResponse.self)
        }
    }

    public static func noteSections(notebookID: String, groupID: String? = nil) throws -> NoteSectionsResponse {
        try notebookID.withCString { nbPtr in
            try withOptionalCString(groupID) { ptr in
                try call(ostmac_note_sections(nbPtr, ptr), as: NoteSectionsResponse.self)
            }
        }
    }

    public static func reminderDone(listID: String, taskID: String) throws -> ReminderTaskResult {
        try listID.withCString { idPtr in
            try taskID.withCString { taskPtr in
                try call(ostmac_reminder_done(idPtr, taskPtr), as: ReminderTaskResult.self)
            }
        }
    }

    public static func notePage(pageID: String, groupID: String? = nil) throws -> NotePageResponse {
        try pageID.withCString { idPtr in
            try withOptionalCString(groupID) { ptr in
                try call(ostmac_note_page(idPtr, ptr), as: NotePageResponse.self)
            }
        }
    }

    public static func noteAppend(pageID: String, text: String, groupID: String? = nil) throws -> NoteAppendResponse {
        try pageID.withCString { idPtr in
            try text.withCString { textPtr in
                try withOptionalCString(groupID) { ptr in
                    try call(ostmac_note_append(idPtr, textPtr, ptr), as: NoteAppendResponse.self)
                }
            }
        }
    }

    /// Run `body` with a nullable C string (nil stays NULL for core).
    private static func withOptionalCString<T>(
        _ value: String?, _ body: (UnsafePointer<CChar>?) throws -> T
    ) rethrows -> T {
        guard let value else { return try body(nil) }
        return try value.withCString { try body($0) }
    }

    public static func trouterStart() -> Int32 { ostmac_trouter_start() }
    public static func trouterStop() -> Int32 { ostmac_trouter_stop() }

    public static func trouterPoll() throws -> TrouterPoll {
        try call(ostmac_trouter_poll(), as: TrouterPoll.self)
    }

    public static func trouterPollTyped() throws -> RealtimePoll {
        try call(ostmac_trouter_poll_typed(), as: RealtimePoll.self)
    }

    public static func callStatus() throws -> CallStatus {
        try call(ostmac_call_status(), as: CallStatus.self)
    }

    public static func callPlace(threadID: String, timeoutSecs: Int32 = 30) throws -> CallResult {
        try threadID.withCString { ptr in
            try call(ostmac_call_place(ptr, timeoutSecs), as: CallResult.self)
        }
    }

    public static func callEcho(timeoutSecs: Int32 = 30) throws -> CallResult {
        try call(ostmac_call_echo(timeoutSecs), as: CallResult.self)
    }

    /// Blocks up to `timeoutSecs` like callPlace; live media attaches on accept.
    public static func callPlaceLive(threadID: String, timeoutSecs: Int32 = 30) throws -> CallResult {
        try threadID.withCString { ptr in
            try call(ostmac_call_place_live(ptr, timeoutSecs), as: CallResult.self)
        }
    }

    public static func callEchoLive(timeoutSecs: Int32 = 30) throws -> CallResult {
        try call(ostmac_call_echo_live(timeoutSecs), as: CallResult.self)
    }

    public static func callAccept() throws -> CallResult {
        try call(ostmac_call_accept(), as: CallResult.self)
    }

    public static func callAcceptLive() throws -> CallResult {
        try call(ostmac_call_accept_live(), as: CallResult.self)
    }

    public static func callEnd() throws -> CallResult {
        try call(ostmac_call_end(), as: CallResult.self)
    }

    public static func callRecordInject() throws -> CallResult {
        try call(ostmac_call_record_inject(), as: CallResult.self)
    }

    // Take ownership of a Rust-allocated C string, decode, free.
    static func call<T: Decodable>(
        _ raw: UnsafeMutablePointer<CChar>?, as type: T.Type
    ) throws -> T {
        guard let raw else { throw CoreCallError.failed("null from core") }
        defer { ostmac_free(raw) }
        guard let data = String(cString: raw).data(using: .utf8) else {
            throw CoreCallError.badUTF8
        }
        return try decodeOrThrow(type, from: data)
    }
}
