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

    public static func callAccept() throws -> CallResult {
        try call(ostmac_call_accept(), as: CallResult.self)
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
